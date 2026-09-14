"""live_audio モード（gpt-live-1 + VC 中継）の room 側検証。"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import struct
import time
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from mihari_room.app import create_app
from mihari_room.config import TOKEN_HEADER, RoomConfig
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from mihari_room.voice.live_upstream import (
    LIVE_INSTRUCTIONS,
    OpenAILiveUpstream,
    live_responses_delegation,
    live_session_start_event,
)
from mihari_room.voice.protocol import (
    EVENT_ASSISTANT_AUDIO,
    EVENT_ASSISTANT_TEXT,
    EVENT_ASSISTANT_TOOL_ACTIVITY,
    EVENT_ASSISTANT_TOOL_CALL,
    EVENT_SESSION_READY,
    EVENT_USER_TEXT,
    EVENT_USER_TRANSCRIPT_NONE,
)
from mihari_room.voice.stream import LIVE_DELEGATION_INPUT_LIMIT, _send_tool_result
from mihari_room.voice.tools import VoiceToolOutcome
from mihari_room.voice.upstream import FakeRealtimeUpstream, RealtimeUpstream
from mihari_room.voice.vc import (
    HTTPVoiceConverter,
    PassthroughConverter,
    f32_to_pcm16,
    pcm16_to_f32,
    voice_converter_from_config,
)
from mihari_room.voice_gateway import create_gateway_app
from tests.recording import RecordingBoard, ScriptedWorker
from tests.test_voice_realtime import PNG_1X1, _disconnect_and_idle

TOKEN = "room-secret"

#: 往復変換で誤差が出ない小さめの PCM16 サンプル。
PCM_SAMPLES = [0, 1000, -1000, 8000]
PCM_BYTES = struct.pack(f"<{len(PCM_SAMPLES)}h", *PCM_SAMPLES)
PCM_B64 = base64.b64encode(PCM_BYTES).decode()


@pytest.fixture(autouse=True)
def _fast_live_watchdogs(monkeypatch: pytest.MonkeyPatch) -> None:
    """実時間のウォッチドッグ既定値をテスト用に縮める。

    本番の gap 既定は出力 1.1s / 入力 1.8s / tick 0.25s。テストでは発話の
    「途切れ」を待つ必要があるため 1/10 程度に縮め、tick は gap より小さく
    する（区切り検出の粒度を保つ）。
    """
    import mihari_room.voice.stream as stream_module

    monkeypatch.setattr(stream_module, "_LIVE_WATCH_TICK_SEC", 0.05)
    monkeypatch.setattr(stream_module, "_LIVE_OUTPUT_GAP_SEC", 0.15)
    monkeypatch.setattr(stream_module, "_LIVE_INPUT_GAP_SEC", 0.2)


class FakeLiveUpstream(RealtimeUpstream):
    """gpt-live-1 相当の応答を返すテスト用 upstream。

    room からは Realtime 形のイベントが届くので、非無音の
    ``input_audio_buffer.append`` を受けたら live 形のイベント列を返す。
    ``session.output_audio.done``/``stopped`` は公式イベント一覧に存在
    しないため送らない — 発話終端は room 側ウォッチドッグの出力活動
    gap 判定が自前で作る。
    """

    def __init__(self) -> None:
        self._sent: list[dict] = []
        self._queue: asyncio.Queue[dict] = asyncio.Queue()
        self._closed = False
        self._audio_output_events = 0

    async def connect(self) -> None:
        await self._queue.put({"type": "session.started", "session": {"id": "live_fake"}})

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        if event.get("type") == "input_audio_buffer.append":
            raw = base64.b64decode(event.get("audio") or "")
            if not any(raw):
                # 無音フレーム（無音ペーサー含む）には応答しない。
                # 実機の Live も無音では出力を起こさず、応答し続けると
                # 出力活動が途切れずウォッチドッグの区切りが来なくなる。
                return
            await self._queue.put({"type": "session.input_transcript.delta", "delta": "こんにちは"})
            await self._queue.put({"type": "session.output_transcript.delta", "delta": "やあ、"})
            await self._queue.put({"type": "session.output_transcript.delta", "delta": "見てるよ"})
            await self._queue.put({"type": "session.output_audio.delta", "delta": PCM_B64})

    async def receive(self) -> dict:
        if self._closed:
            raise RuntimeError("upstream closed")
        event = await self._queue.get()
        if event.get("type", "").startswith("session.output_audio."):
            self._audio_output_events += 1
        return event

    async def close(self) -> None:
        self._closed = True
        try:
            self._queue.put_nowait({"type": "session.closed"})
        except asyncio.QueueFull:
            pass

    def audio_output_events_seen(self) -> int:
        return self._audio_output_events

    def sent_events(self) -> list[dict]:
        return list(self._sent)


class DelegatingLiveUpstream(FakeLiveUpstream):
    """最初の append で session.delegation.created + response.event 列を返す。

    delegation の function_call を 1 件だけ含み、response.completed で閉じる。
    ``tool_name`` / ``call_id`` で呼ばせるツールを選べる。
    """

    def __init__(
        self,
        tool_name: str = "get_job_status",
        call_id: str = "call_live_1",
        arguments: str = "{}",
    ) -> None:
        super().__init__()
        self._tool_name = tool_name
        self._call_id = call_id
        self._arguments = arguments
        self._delegated = False

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        event_type = event.get("type")
        if event_type == "response.create":
            # 委譲継続（response.create）は「ツール結果を受け取った」合図として
            # 1 発話ぶんの音声を返す。終端は watchdog の gap 判定が作るので、
            # テスト側は assistant.audio done を待ち合わせに使える。
            await self._queue.put(
                {"type": "session.output_audio.delta", "delta": PCM_B64}
            )
            return
        if event_type != "input_audio_buffer.append" or self._delegated:
            return
        raw = base64.b64decode(event.get("audio") or "")
        if not any(raw):
            return
        self._delegated = True
        await self._queue.put(
            {
                "type": "session.delegation.created",
                "delegation": {"id": "dlg-1", "target": "responses"},
                "response_id": "resp_live_1",
            }
        )
        await self._queue.put(
            {
                "type": "response.event",
                "delegation_id": "dlg-1",
                "event": {
                    "type": "response.created",
                    "response": {"id": "resp_live_1"},
                },
            }
        )
        await self._queue.put(
            {
                "type": "response.event",
                "delegation_id": "dlg-1",
                "event": {
                    "type": "response.output_item.done",
                    "item": {
                        "type": "function_call",
                        "status": "completed",
                        "name": self._tool_name,
                        "call_id": self._call_id,
                        "arguments": self._arguments,
                    },
                },
            }
        )
        await self._queue.put(
            {
                "type": "response.event",
                "delegation_id": "dlg-1",
                "event": {"type": "response.completed", "response": {"id": "resp_live_1"}},
            }
        )


class TalkingDelegatingLiveUpstream(FakeLiveUpstream):
    """委譲の前後にアシスタント発話が挟まるバリアント（turn 確定の観測用）。

    ``session.delegation.created`` の前と ``response.completed`` の直前に
    ``session.output_transcript.delta`` を流し、room 側がツール行の前に
    ``assistant.text(done=True)`` で断片を確定するかを見る。
    """

    def __init__(self, tool_name: str = "get_job_status", call_id: str = "call_live_1") -> None:
        super().__init__()
        self._tool_name = tool_name
        self._call_id = call_id
        self._delegated = False

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        event_type = event.get("type")
        if event_type == "response.create":
            await self._queue.put(
                {"type": "session.output_audio.delta", "delta": PCM_B64}
            )
            return
        if event_type != "input_audio_buffer.append" or self._delegated:
            return
        raw = base64.b64decode(event.get("audio") or "")
        if not any(raw):
            return
        self._delegated = True
        # 委譲前の発話断片。
        await self._queue.put(
            {"type": "session.output_transcript.delta", "delta": "調べるね、"}
        )
        await self._queue.put(
            {
                "type": "session.delegation.created",
                "delegation": {"id": "dlg-1", "target": "responses"},
                "response_id": "resp_live_1",
            }
        )
        await self._queue.put(
            {
                "type": "response.event",
                "delegation_id": "dlg-1",
                "event": {
                    "type": "response.created",
                    "response": {"id": "resp_live_1"},
                },
            }
        )
        # 委譲中（ツール呼び出し確定前）の続き断片。
        await self._queue.put(
            {"type": "session.output_transcript.delta", "delta": "ちょっと待って"}
        )
        await self._queue.put(
            {
                "type": "response.event",
                "delegation_id": "dlg-1",
                "event": {
                    "type": "response.output_item.done",
                    "item": {
                        "type": "function_call",
                        "status": "completed",
                        "name": self._tool_name,
                        "call_id": self._call_id,
                        "arguments": "{}",
                    },
                },
            }
        )
        await self._queue.put(
            {
                "type": "response.event",
                "delegation_id": "dlg-1",
                "event": {"type": "response.completed", "response": {"id": "resp_live_1"}},
            }
        )


class TextOnlyDelegatingLiveUpstream(FakeLiveUpstream):
    """テキストだけの委譲応答（function_call 無し）を返すバリアント。

    実機で観測されたとおり、委譲応答の進行・テキスト・完了は
    ``response.event`` 内側で届き、``session.output_audio.done`` 系の
    区切りは来ない。非無音の最初の append への応答として流す。
    """

    def __init__(self) -> None:
        super().__init__()
        self._delegated = False

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        if event.get("type") != "input_audio_buffer.append" or self._delegated:
            return
        raw = base64.b64decode(event.get("audio") or "")
        if not any(raw):
            return
        self._delegated = True
        await self._queue.put(
            {"type": "session.input_transcript.delta", "delta": "今何してるんだっけ"}
        )
        await self._queue.put(
            {
                "type": "session.delegation.created",
                "delegation": {"id": "dlg-1", "target": "responses"},
                "response_id": "resp_live_1",
            }
        )
        for inner in (
            {"type": "response.in_progress"},
            {"type": "response.created", "response": {"id": "resp_live_1"}},
            {"type": "response.output_item.added", "item": {"type": "message"}},
            {"type": "response.function_call_arguments.delta", "delta": "{"},
            {"type": "response.function_call_arguments.done", "arguments": "{}"},
            {"type": "response.content_part.added", "part": {"type": "output_text"}},
            {"type": "response.output_text.delta", "delta": "調べたよ、"},
            {"type": "response.output_text.delta", "delta": "結果はOKだった"},
        ):
            await self._queue.put(
                {"type": "response.event", "delegation_id": "dlg-1", "event": inner}
            )
        # 委譲応答の途中でのユーザー発話。response.completed で確定するはず。
        await self._queue.put(
            {"type": "session.input_transcript.delta", "delta": "あ、そうなんだ"}
        )
        for inner in (
            {"type": "response.output_text.done", "text": "調べたよ、結果はOKだった"},
            {"type": "response.content_part.done"},
            {"type": "response.completed", "response": {"id": "resp_live_1"}},
        ):
            await self._queue.put(
                {"type": "response.event", "delegation_id": "dlg-1", "event": inner}
            )
        # 既知だが中継しないイベント。unhandled 警告を出さないことの観測用。
        await self._queue.put(
            {"type": "session.usage.updated", "usage": {"total_tokens": 42}}
        )


class CumulativeDeltaLiveUpstream(FakeLiveUpstream):
    """transcript delta を累積全文形式・重複送出で返すバリアント（二重化対策用）。

    実機で「今何してるんだっけ今何してるんだっけ」と連結表示された障害の
    再現。非無音の append へのみ応答する。
    """

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        if event.get("type") != "input_audio_buffer.append":
            return
        raw = base64.b64decode(event.get("audio") or "")
        if not any(raw):
            return
        # 同一文の重複送出 → 累積全文の追記。
        await self._queue.put(
            {"type": "session.input_transcript.delta", "delta": "今何してるんだっけ"}
        )
        await self._queue.put(
            {"type": "session.input_transcript.delta", "delta": "今何してるんだっけ"}
        )
        await self._queue.put(
            {
                "type": "session.input_transcript.delta",
                "delta": "今何してるんだっけ、えっと",
            }
        )
        # assistant 側も累積全文形式で重複送出。
        await self._queue.put(
            {"type": "session.output_transcript.delta", "delta": "見てるよ"}
        )
        await self._queue.put(
            {"type": "session.output_transcript.delta", "delta": "見てるよ、ちゃんと"}
        )
        await self._queue.put({"type": "session.output_audio.delta", "delta": PCM_B64})


class _JobWatcherStubExecutor:
    """``finished_jobs`` で 1 回だけ結果を返す executor スタブ（gateway 経路用）。"""

    def __init__(self, results: list[dict]) -> None:
        self._results = list(results)
        self.closed = False

    async def execute(self, name: str, arguments_json: str) -> VoiceToolOutcome:
        return VoiceToolOutcome(output='{"success": true}')

    async def finished_jobs(self) -> list[dict]:
        results, self._results = self._results, []
        return results

    async def close(self) -> None:
        self.closed = True


class NoTranscriptLiveUpstream(FakeLiveUpstream):
    """input_transcript.delta を一切返さないバリアント（無転写ターンの観測用）。

    非無音の append にだけ応答を積む。無音キープアライブや無音ペーサーの
    append には反応しないので、出力区切りはクライアントの発話に同期する。
    """

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        if event.get("type") != "input_audio_buffer.append":
            return
        raw = base64.b64decode(event.get("audio") or "")
        if not any(raw):
            return
        await self._queue.put({"type": "session.output_transcript.delta", "delta": "返事だよ"})
        await self._queue.put({"type": "session.output_audio.delta", "delta": PCM_B64})


class SilentTurnLiveUpstream(FakeLiveUpstream):
    """無音 append への応答で「発話ゼロのターン」を作るバリアント。

    最初の append（無音ペーサー含む）へ 1 度だけ応答を積み、その後は
    静かになる。区切りは watchdog の出力 gap 判定が作るので、無音だけの
    ターンでも assistant.audio done が届き、かつ ``user.transcript_none``
    は出ない（無音は発話として数えない）ことを観測する。
    """

    def __init__(self) -> None:
        super().__init__()
        self._responded = False

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        if event.get("type") != "input_audio_buffer.append" or self._responded:
            return
        self._responded = True
        await self._queue.put(
            {"type": "session.output_transcript.delta", "delta": "返事だよ"}
        )
        await self._queue.put({"type": "session.output_audio.delta", "delta": PCM_B64})


class SpeechOnlyLiveUpstream(FakeLiveUpstream):
    """非無音の append にだけ応答する（ターン統計を確定的にするための命名）。

    親クラスが既に無音フレームを弾くため振る舞いは同一。
    """


class QuietLiveUpstream(FakeLiveUpstream):
    """応答イベントを積まない静かなバリアント（無音ペーサーの観測用）。

    親の send は ``input_audio_buffer.append`` ごとに応答イベントをキューへ
    積むため、読み取らないテストでは溢れる。ここでは送信記録だけ残す。
    """

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)


class TranscriptOnlyLiveUpstream(FakeLiveUpstream):
    """input_transcript.delta だけを返すバリアント（入力 watchdog の観測用）。

    出力イベントは一切返さない。ユーザー発話の区切りは出力側ではなく
    入力 transcript の gap ウォッチドッグで確定する。
    """

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        if event.get("type") != "input_audio_buffer.append":
            return
        raw = base64.b64decode(event.get("audio") or "")
        if not any(raw):
            return
        await self._queue.put(
            {"type": "session.input_transcript.delta", "delta": "声だけのターン"}
        )


class TimestampedTranscriptLiveUpstream(FakeLiveUpstream):
    """start_ms/end_ms 付きの input_transcript.delta を返すバリアント。

    発話区間が大きく離れた 2 delta を積み、room が時刻の飛びで
    別発話として先に確定するかを見る（実機の発話区間グルーピング）。
    """

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        if event.get("type") != "input_audio_buffer.append":
            return
        raw = base64.b64decode(event.get("audio") or "")
        if not any(raw):
            return
        await self._queue.put(
            {
                "type": "session.input_transcript.delta",
                "delta": "一つ目",
                "start_ms": 0,
                "end_ms": 400,
            }
        )
        await self._queue.put(
            {
                "type": "session.input_transcript.delta",
                "delta": "二つ目",
                "start_ms": 6000,
                "end_ms": 6400,
            }
        )


class DoneEmittingLiveUpstream(FakeLiveUpstream):
    """``session.output_audio.done`` を明示的に送るバリアント（保険分岐用）。

    公式イベント一覧には存在しないが、万一 upstream から届いた場合に
    区切り処理へ進める保険として残した分岐を検証する。
    """

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        if event.get("type") != "input_audio_buffer.append":
            return
        raw = base64.b64decode(event.get("audio") or "")
        if not any(raw):
            return
        await self._queue.put({"type": "session.output_audio.delta", "delta": PCM_B64})
        await self._queue.put({"type": "session.output_audio.done"})


class FailingDelegatingLiveUpstream(FakeLiveUpstream):
    """委譲応答が response.failed で終わるバリアント（失敗通知の観測用）。"""

    def __init__(self) -> None:
        super().__init__()
        self._delegated = False

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        if event.get("type") != "input_audio_buffer.append" or self._delegated:
            return
        raw = base64.b64decode(event.get("audio") or "")
        if not any(raw):
            return
        self._delegated = True
        await self._queue.put(
            {
                "type": "session.delegation.created",
                "delegation": {"id": "dlg-1", "target": "responses"},
                "response_id": "resp_fail_1",
            }
        )
        for inner in (
            {"type": "response.in_progress"},
            {
                "type": "response.failed",
                "response": {
                    "id": "resp_fail_1",
                    "error": {"message": "backend exploded"},
                },
            },
        ):
            await self._queue.put(
                {"type": "response.event", "delegation_id": "dlg-1", "event": inner}
            )


class NonCompletedItemDelegatingLiveUpstream(FakeLiveUpstream):
    """status != completed の function_call item を返すバリアント。

    output_item.done でも実行中（in_progress 等）の item は実行対象に
    しないことを観測する（completed 状態の item のみ回収）。
    """

    def __init__(self) -> None:
        super().__init__()
        self._delegated = False

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        if event.get("type") != "input_audio_buffer.append" or self._delegated:
            return
        raw = base64.b64decode(event.get("audio") or "")
        if not any(raw):
            return
        self._delegated = True
        await self._queue.put(
            {
                "type": "session.delegation.created",
                "delegation": {"id": "dlg-1", "target": "responses"},
                "response_id": "resp_live_1",
            }
        )
        for inner in (
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "status": "in_progress",
                    "name": "get_job_status",
                    "call_id": "call_live_1",
                    "arguments": "{}",
                },
            },
            {"type": "response.completed", "response": {"id": "resp_live_1"}},
        ):
            await self._queue.put(
                {"type": "response.event", "delegation_id": "dlg-1", "event": inner}
            )


class RepeatedDelegatingLiveUpstream(FakeLiveUpstream):
    """response.create ごとに新しい委譲を返すバリアント。

    1 回目の委譲は function_call 付きで完了させ、room が fco +
    response.create を返すと 2 回目の委譲（呼び出し無し）を流す。
    ``delegated_calls`` が委譲ごとにクリアされていなければ、2 回目の
    completed で同じ呼び出しが再実行されてしまう（回帰検出用）。
    """

    def __init__(self) -> None:
        super().__init__()
        self._delegated = False
        self._followups = 0

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)
        event_type = event.get("type")
        if event_type == "response.create":
            self._followups += 1
            if self._followups == 1:
                # 2 回目の委譲: function_call を含まずそのまま完了。
                await self._queue.put(
                    {
                        "type": "session.delegation.created",
                        "delegation": {"id": "dlg-2", "target": "responses"},
                        "response_id": "resp_live_2",
                    }
                )
                await self._queue.put(
                    {
                        "type": "response.event",
                        "delegation_id": "dlg-2",
                        "event": {
                            "type": "response.completed",
                            "response": {"id": "resp_live_2"},
                        },
                    }
                )
            return
        if event_type != "input_audio_buffer.append" or self._delegated:
            return
        raw = base64.b64decode(event.get("audio") or "")
        if not any(raw):
            return
        self._delegated = True
        await self._queue.put(
            {
                "type": "session.delegation.created",
                "delegation": {"id": "dlg-1", "target": "responses"},
                "response_id": "resp_live_1",
            }
        )
        for inner in (
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "status": "completed",
                    "name": "get_job_status",
                    "call_id": "call_live_1",
                    "arguments": "{}",
                },
            },
            {"type": "response.completed", "response": {"id": "resp_live_1"}},
        ):
            await self._queue.put(
                {"type": "response.event", "delegation_id": "dlg-1", "event": inner}
            )


class _RecordingWS:
    """OpenAILiveUpstream._ws 差し替え用の送受信スタブ。"""

    def __init__(self) -> None:
        self.frames: list[dict] = []

    async def send(self, raw: str) -> None:
        self.frames.append(json.loads(raw))


class _SilenceConverter(PassthroughConverter):
    """f32 をゼロ埋めで返す（VC が効いたことの目印）。"""

    async def convert(self, pcm_f32_24k: bytes) -> bytes:
        return b"\x00" * len(pcm_f32_24k)


def _make_live_app(
    tmp_path: Path,
    *,
    upstream_factory=None,
    vc_url: str = "",
) -> TestClient:
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id="owner"), board, ScriptedWorker([]))
    config = RoomConfig(
        token=TOKEN,
        root=tmp_path,
        owner_id="owner",
        openai_api_key="test-openai-key",
        voice_output_mode="live_audio",
        vc_url=vc_url,
    )
    app = create_app(
        config,
        orch,
        start_pump=False,
        voice_upstream_factory=upstream_factory,
    )
    return TestClient(app)


def _auth() -> dict[str, str]:
    return {TOKEN_HEADER: TOKEN}


def _collect_until(ws, predicate, limit: int = 30) -> list[dict]:
    frames: list[dict] = []
    for _ in range(limit):
        frame = ws.receive_json()
        frames.append(frame)
        if predicate(frame):
            break
    return frames


def test_live_session_created_with_live_model(tmp_path: Path) -> None:
    client = _make_live_app(tmp_path)
    created = client.post("/voice/sessions", headers=_auth()).json()
    assert created["model"] == "gpt-live-1"
    detail = client.get(f"/voice/sessions/{created['session_id']}", headers=_auth()).json()
    assert detail["output_modalities"] == ["audio", "text"]


def test_live_audio_relayed_as_assistant_audio(tmp_path: Path) -> None:
    """upstream の音声 delta が VC（ここではパススルー）経由で届く。"""
    fake = FakeLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(f"/voice/sessions/{session_id}/stream", headers=_auth()) as ws:
        ready = ws.receive_json()
        assert ready["type"] == EVENT_SESSION_READY
        assert ready["output_modalities"] == ["audio", "text"]
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_AUDIO and f.get("done"),
        )
        _disconnect_and_idle(ws, client, session_id)

    audio_frames = [f for f in frames if f["type"] == EVENT_ASSISTANT_AUDIO]
    assert len(audio_frames) == 2
    # パススルーなので PCM16 が往復変換でそのまま返る。
    assert base64.b64decode(audio_frames[0]["audio_base64"]) == PCM_BYTES
    assert audio_frames[0]["done"] is False
    assert audio_frames[1]["done"] is True

    user_frames = [f for f in frames if f["type"] == EVENT_USER_TEXT]
    assert user_frames[-1]["text"] == "こんにちは"
    assert user_frames[-1]["done"] is True

    text_frames = [f for f in frames if f["type"] == EVENT_ASSISTANT_TEXT]
    assert text_frames[-1]["text"] == "やあ、見てるよ"
    assert text_frames[-1]["done"] is True

    # FakeLiveUpstream は append しか反応しない。commit/response.create は届くが無害。
    sent_types = [e.get("type") for e in fake.sent_events()]
    assert "input_audio_buffer.append" in sent_types
    # output_audio.delta 1 回分のみ（done は実在しないので fake は送らない）。
    assert fake.audio_output_events_seen() == 1

    detail = client.get(f"/voice/sessions/{session_id}", headers=_auth()).json()
    assert detail["upstream_audio_output_events"] == 1
    history = client.get(f"/voice/sessions/{session_id}/history", headers=_auth()).json()
    texts = [m["text"] for m in history["messages"]]
    assert "こんにちは" in texts
    assert "やあ、見てるよ" in texts


def test_live_input_pacer_fills_silence(tmp_path: Path) -> None:
    """クライアントが音声を送らなくても upstream の入力が枯渇しない。

    Live API は入力ストリームで時間が進むため、room が 100ms 周期の
    無音フレーム（PCM16 24kHz mono = 4800 バイトのゼロ）を補填する。
    """
    fake = QuietLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(f"/voice/sessions/{session_id}/stream", headers=_auth()) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        # 何も送らずに待つと、ペーサーの無音 append が複数回 upstream へ届く。
        time.sleep(0.45)
        _disconnect_and_idle(ws, client, session_id)
    appends = [e for e in fake.sent_events() if e.get("type") == "input_audio_buffer.append"]
    assert len(appends) >= 2
    for event in appends:
        raw = base64.b64decode(event["audio"], validate=True)
        assert len(raw) == 4800
        assert raw == b"\x00" * 4800


def test_live_no_transcript_turn_sends_transcript_none(tmp_path: Path) -> None:
    """音声は届いたが input_transcript.delta が無いターンは user.transcript_none を送る。

    desktop の「（音声を送信）」プレースホルダが残り続ける障害の対策。
    文字起こしが無いターンは履歴にも残さない（user 行は増えない）。
    """
    fake = NoTranscriptLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_AUDIO and f.get("done"),
        )
        _disconnect_and_idle(ws, client, session_id)

    none_frames = [f for f in frames if f["type"] == EVENT_USER_TRANSCRIPT_NONE]
    assert len(none_frames) == 1
    # 文字起こしは来なかったので user.text は一切送らない。
    assert not any(f["type"] == EVENT_USER_TEXT for f in frames)
    # assistant 側の応答は従来どおり届く。
    text_frames = [f for f in frames if f["type"] == EVENT_ASSISTANT_TEXT]
    assert text_frames[-1]["text"] == "返事だよ"
    assert text_frames[-1]["done"] is True

    history = client.get(f"/voice/sessions/{session_id}/history", headers=_auth()).json()
    user_texts = [m["text"] for m in history["messages"] if m["role"] == "user"]
    assert user_texts == []
    assistant_texts = [
        m["text"] for m in history["messages"] if m["role"] == "assistant"
    ]
    assert "返事だよ" in assistant_texts


def test_live_silence_turn_does_not_send_transcript_none(tmp_path: Path) -> None:
    """無音キープアライブだけの区切りでは user.transcript_none を送らない。

    live_audio では非押下中も無音チャンクが流れ続けるため、全ゼロ PCM は
    「ユーザーが話した」判定に数えない。
    """
    fake = SilentTurnLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    silence_b64 = base64.b64encode(b"\x00" * 480).decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": silence_b64})
        # 最初の append へ 1 度だけ応答する fake。応答が途切れたあとは
        # ウォッチドッグの出力 gap 判定で区切りが来る。
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_AUDIO and f.get("done"),
        )
        _disconnect_and_idle(ws, client, session_id)

    assert not any(f["type"] == EVENT_USER_TRANSCRIPT_NONE for f in frames)
    assert not any(f["type"] == EVENT_USER_TEXT for f in frames)


def test_live_turn_diagnostic_log(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    """assistant 出力区切りでターン統計の 1 行ログを出す。"""
    fake = SpeechOnlyLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with caplog.at_level(logging.INFO, logger="mihari_room.voice"):
        with client.websocket_connect(
            f"/voice/sessions/{session_id}/stream", headers=_auth()
        ) as ws:
            assert ws.receive_json()["type"] == EVENT_SESSION_READY
            ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
            _collect_until(
                ws,
                lambda f: f["type"] == EVENT_ASSISTANT_AUDIO and f.get("done"),
            )
            _disconnect_and_idle(ws, client, session_id)
    messages = [record.getMessage() for record in caplog.records]
    # 非無音 2 バイト + transcript delta 1 回（"こんにちは"=5 文字）。
    assert "live turn: input_bytes=2 transcript_deltas=1 transcript_len=5" in messages


def test_live_audio_passes_through_converter(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """VC コンバータの出力がクライアントへ届く（ゼロ埋めスタブで検証）。"""
    import mihari_room.voice.stream as stream_module

    fake = FakeLiveUpstream()
    monkeypatch.setattr(
        stream_module, "voice_converter_from_config", lambda config: _SilenceConverter()
    )
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(f"/voice/sessions/{session_id}/stream", headers=_auth()) as ws:
        ws.receive_json()
        # 非無音でないと fake は応答しない（無音には Live も反応しない前提）。
        audio_b64 = base64.b64encode(b"\x00\x01").decode()
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_AUDIO and f.get("done"),
        )
        _disconnect_and_idle(ws, client, session_id)
    audio_frames = [f for f in frames if f["type"] == EVENT_ASSISTANT_AUDIO]
    # f32 ゼロ → PCM16 ゼロ。サンプル数は入力と同じ。
    assert base64.b64decode(audio_frames[0]["audio_base64"]) == b"\x00\x00" * len(PCM_SAMPLES)


def test_live_send_translates_realtime_events() -> None:
    """OpenAILiveUpstream.send が汎用イベントを Live 形へ変換する。"""
    upstream = OpenAILiveUpstream(api_key="test-key", model="gpt-live-1", voice="marin")
    ws = _RecordingWS()
    upstream._ws = ws

    asyncio.run(upstream.send({"type": "input_audio_buffer.append", "audio": "AAAA"}))
    assert ws.frames[-1] == {
        "type": "session.input_audio.append",
        "audio": "AAAA",
    }

    # Live に対応するものが無いイベントは送らない。
    asyncio.run(upstream.send({"type": "input_audio_buffer.commit"}))
    asyncio.run(upstream.send({"type": "response.create"}))
    asyncio.run(upstream.send({"type": "session.update", "session": {}}))
    assert len(ws.frames) == 1

    # conversation.item.create は静かな文脈として注入される。
    asyncio.run(
        upstream.send(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "前の話"}],
                },
            }
        )
    )
    assert ws.frames[-1]["type"] == "session.thinking.append"
    assert ws.frames[-1]["delegation_id"] is None
    assert "前の話" in ws.frames[-1]["content"]

    # session.* はそのまま通す。
    asyncio.run(upstream.send({"type": "session.close"}))
    assert ws.frames[-1] == {"type": "session.close"}


def test_live_session_start_event_shape() -> None:
    event = live_session_start_event(model="gpt-live-1", voice="marin")
    assert event["type"] == "session.start"
    session = event["session"]
    assert session["model"] == "gpt-live-1"
    assert session["audio"]["format"] == {"type": "audio/pcm", "rate": 24000}
    assert session["audio"]["output"]["voice"] == "marin"
    assert "みはり" in session["instructions"]
    assert LIVE_INSTRUCTIONS in session["instructions"]


def test_pcm16_f32_roundtrip() -> None:
    f32 = pcm16_to_f32(PCM_BYTES)
    assert len(f32) == len(PCM_SAMPLES) * 4
    assert f32_to_pcm16(f32) == PCM_BYTES
    # 端数バイトは捨てる。
    assert pcm16_to_f32(PCM_BYTES + b"\x01") == f32
    assert f32_to_pcm16(f32 + b"\x01\x02") == PCM_BYTES
    # 空・範囲外クリップ。
    assert pcm16_to_f32(b"") == b""
    clipped = f32_to_pcm16(struct.pack("<2f", 2.0, -2.0))
    assert struct.unpack("<2h", clipped) == (32767, -32768)


async def test_passthrough_converter() -> None:
    converter = PassthroughConverter()
    data = b"\x00\x01\x02\x03"
    assert await converter.convert(data) == data
    await converter.reset()
    await converter.close()


async def test_http_converter_convert_and_reset() -> None:
    seen: list[tuple[str, bytes]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append((request.url.path, request.content))
        if request.url.path == "/convert":
            return httpx.Response(200, content=request.content[::-1])
        return httpx.Response(200)

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://vc.test")
    converter = HTTPVoiceConverter(base_url="http://vc.test", client=client)
    data = b"\x01\x02\x03\x04"
    assert await converter.convert(data) == data[::-1]
    assert seen[0] == ("/convert", data)
    await converter.reset()
    assert seen[1][0] == "/reset"
    await client.aclose()


async def test_http_converter_falls_back_on_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/convert":
            return httpx.Response(500)
        return httpx.Response(200)

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://vc.test")
    converter = HTTPVoiceConverter(base_url="http://vc.test", client=client)
    data = b"\x01\x02\x03\x04"
    # 5xx は素通し。
    assert await converter.convert(data) == data
    await client.aclose()

    def broken(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    client2 = httpx.AsyncClient(transport=httpx.MockTransport(broken), base_url="http://vc.test")
    converter2 = HTTPVoiceConverter(base_url="http://vc.test", client=client2)
    # 接続失敗も素通し（例外を投げない）。
    assert await converter2.convert(data) == data
    # reset の失敗も例外にしない。
    await converter2.reset()
    await client2.aclose()


def test_voice_converter_from_config(tmp_path: Path) -> None:
    base = dict(token=TOKEN, root=tmp_path, owner_id="owner")
    assert isinstance(voice_converter_from_config(RoomConfig(**base)), PassthroughConverter)
    http_converter = voice_converter_from_config(RoomConfig(**base, vc_url="http://vc.local:9999"))
    assert isinstance(http_converter, HTTPVoiceConverter)


def test_config_reads_live_and_vc_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MIHARI_ROOM_TOKEN", TOKEN)
    monkeypatch.setenv("MIHARI_ROOM_ROOT", str(tmp_path))
    monkeypatch.setenv("MIHARI_VOICE_OUTPUT_MODE", "live_audio")
    monkeypatch.setenv("MIHARI_LIVE_MODEL", "gpt-live-1")
    monkeypatch.setenv("MIHARI_LIVE_VOICE", "quartz")
    monkeypatch.setenv("MIHARI_VC_URL", "http://127.0.0.1:9999")
    monkeypatch.setenv("MIHARI_VC_TIMEOUT", "3.5")
    cfg = RoomConfig.from_environment()
    assert cfg.voice_output_mode == "live_audio"
    assert cfg.live_model == "gpt-live-1"
    assert cfg.live_voice == "quartz"
    assert cfg.vc_url == "http://127.0.0.1:9999"
    assert cfg.vc_timeout == 3.5


def test_config_defaults_to_text_mode(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MIHARI_ROOM_TOKEN", TOKEN)
    monkeypatch.setenv("MIHARI_ROOM_ROOT", str(tmp_path))
    for name in (
        "MIHARI_VOICE_OUTPUT_MODE",
        "MIHARI_LIVE_MODEL",
        "MIHARI_LIVE_VOICE",
        "MIHARI_VC_URL",
        "MIHARI_VC_TIMEOUT",
    ):
        monkeypatch.delenv(name, raising=False)
    cfg = RoomConfig.from_environment()
    assert cfg.voice_output_mode == "text"
    assert cfg.live_model == "gpt-live-1"
    assert cfg.live_voice == "marin"
    assert cfg.vc_url == ""
    assert cfg.vc_timeout == 2.0


def test_config_rejects_bad_output_mode(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        RoomConfig(token=TOKEN, root=tmp_path, owner_id="owner", voice_output_mode="bogus")
    with pytest.raises(ValueError):
        RoomConfig(token=TOKEN, root=tmp_path, owner_id="owner", vc_url="ftp://x")


def test_live_session_start_includes_delegation() -> None:
    """delegation 指定時は session.delegation.responses にツール一式が載る。"""
    delegation = live_responses_delegation(model="gpt-5.6-terra")
    event = live_session_start_event("gpt-live-1", "marin", delegation=delegation)
    session = event["session"]
    assert session["delegation"]["type"] == "responses"
    responses = session["delegation"]["responses"]
    assert responses["model"] == "gpt-5.6-terra"
    assert responses["instructions"]
    assert responses["tool_choice"] == "auto"
    assert responses["parallel_tool_calls"] is False
    names = {tool["name"] for tool in responses["tools"]}
    assert "submit_job" in names
    assert "capture_screen" in names
    # delegation 無しなら session.delegation を出さない。
    bare = live_session_start_event("gpt-live-1", "marin")
    assert "delegation" not in bare["session"]


def test_live_send_passes_delegation_commands() -> None:
    """delegation 有効時は response.item.create / response.create / session.update を通す。"""
    upstream = OpenAILiveUpstream(
        api_key="test-key",
        model="gpt-live-1",
        voice="marin",
        delegation=live_responses_delegation(model="gpt-5.6-terra"),
    )
    ws = _RecordingWS()
    upstream._ws = ws
    asyncio.run(upstream.send({"type": "input_audio_buffer.commit"}))
    asyncio.run(
        upstream.send(
            {
                "type": "response.item.create",
                "item": {
                    "type": "function_call_output",
                    "call_id": "c1",
                    "output": "{}",
                },
            }
        )
    )
    asyncio.run(
        upstream.send(
            {
                "type": "response.create",
                "response": {"output_modalities": ["text"]},
            }
        )
    )
    asyncio.run(upstream.send({"type": "session.update", "session": {"x": 1}}))
    assert len(ws.frames) == 3
    assert ws.frames[0]["type"] == "response.item.create"
    # response.create の Realtime 形ボディは Live では意味を持たないので剥がす。
    assert ws.frames[1] == {"type": "response.create"}
    assert ws.frames[2]["type"] == "session.update"


def test_live_delegation_tool_call_executes_and_continues(tmp_path: Path) -> None:
    """response.event 内の function_call を room で実行し、fco + response.create を返す。"""
    fake = DelegatingLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_AUDIO and f.get("done"),
        )
        _disconnect_and_idle(ws, client, session_id)
    activities = [f for f in frames if f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY]
    assert activities[0]["name"] == "delegate"
    assert activities[0]["status"] == "running"
    tool_activity = activities[-1]
    assert tool_activity["name"] == "get_job_status"
    assert tool_activity["call_id"] == "call_live_1"
    assert tool_activity["status"] == "done"
    # room 実行ツールなので client へは tool_call を送らない。
    assert not any(f["type"] == EVENT_ASSISTANT_TOOL_CALL for f in frames)
    sent = fake.sent_events()
    fco = [
        e
        for e in sent
        if e.get("type") == "response.item.create"
        and (e.get("item") or {}).get("type") == "function_call_output"
    ]
    assert len(fco) == 1
    assert fco[0]["item"]["call_id"] == "call_live_1"
    assert json.loads(fco[0]["item"]["output"])["success"] is True
    creates_after = [
        e for e in sent[sent.index(fco[0]) :] if e.get("type") == "response.create"
    ]
    assert len(creates_after) == 1


def test_live_capture_screen_delegates_to_client(tmp_path: Path) -> None:
    """capture_screen は client へ tool_call で渡り、input.image が結果として返る。"""
    fake = DelegatingLiveUpstream(tool_name="capture_screen", call_id="call_live_cap")
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(ws, lambda f: f["type"] == EVENT_ASSISTANT_TOOL_CALL)
        tool = frames[-1]
        assert tool["name"] == "capture_screen"
        assert tool["call_id"] == "call_live_cap"
        # desktop が撮って返す input.image → fco + 画像メッセージ + response.create。
        ws.send_json(
            {
                "type": "input.image",
                "image_base64": PNG_1X1,
                "media_type": "image/png",
                "prompt": "見て",
            }
        )
        # response.create を受けた fake が 1 発話ぶんの音声を返し、
        # その途切れを watchdog が done 区切りにするのを待つ。
        _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_AUDIO and f.get("done"),
        )
        _disconnect_and_idle(ws, client, session_id)
    sent = fake.sent_events()
    message_items = [
        e
        for e in sent
        if e.get("type") == "response.item.create"
        and (e.get("item") or {}).get("type") == "message"
    ]
    assert len(message_items) == 1
    contents = message_items[0]["item"]["content"]
    assert any(part.get("type") == "input_image" for part in contents)
    fco = [
        e
        for e in sent
        if e.get("type") == "response.item.create"
        and (e.get("item") or {}).get("type") == "function_call_output"
    ]
    assert len(fco) == 1
    assert fco[0]["item"]["call_id"] == "call_live_cap"
    assert json.loads(fco[0]["item"]["output"])["success"] is True
    creates_after = [
        e for e in sent[sent.index(fco[0]) :] if e.get("type") == "response.create"
    ]
    assert len(creates_after) == 1


def test_config_reads_live_delegation_env(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("MIHARI_ROOM_TOKEN", TOKEN)
    monkeypatch.setenv("MIHARI_ROOM_ROOT", str(tmp_path))
    monkeypatch.setenv("MIHARI_LIVE_DELEGATION", "0")
    monkeypatch.setenv("MIHARI_LIVE_DELEGATION_MODEL", "gpt-x")
    cfg = RoomConfig.from_environment()
    assert cfg.live_delegation is False
    assert cfg.live_delegation_model == "gpt-x"


def test_live_delegation_flushes_assistant_transcript(tmp_path: Path) -> None:
    """委譲・ツール実行の前に発話中の断片が assistant.text(done=True) で確定する。

    desktop は tool_activity 受信で draft を閉じるが、room 側でも
    delegation.created / response.completed の時点で transcript を
    flush してターンを区切る必要がある。
    """
    fake = TalkingDelegatingLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        # response.create への応答として fake が返す音声の途切れ
        # （watchdog による done 区切り）まで読む。
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_AUDIO and f.get("done"),
        )
        _disconnect_and_idle(ws, client, session_id)

    activities = [
        (i, f)
        for i, f in enumerate(frames)
        if f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY
    ]
    delegate_idx = next(i for i, f in activities if f["name"] == "delegate")
    tool_idx = next(i for i, f in activities if f["name"] == "get_job_status")

    def done_texts(start: int, stop: int) -> list[str]:
        return [
            str(f.get("text") or "")
            for f in frames[start:stop]
            if f["type"] == EVENT_ASSISTANT_TEXT and f.get("done")
        ]

    # delegation.created の前に「調べるね、」が done=True で確定している。
    assert done_texts(0, delegate_idx) == ["調べるね、"]
    # response.completed（ツール実行）の前に「ちょっと待って」が確定している。
    assert done_texts(delegate_idx, tool_idx) == ["ちょっと待って"]

    # flush は履歴にも残る（切断時の send=False フラッシュに回らない）。
    history = client.get(
        f"/voice/sessions/{session_id}/history", headers=_auth()
    ).json()
    assistant_texts = [
        m["text"] for m in history["messages"] if m["role"] == "assistant"
    ]
    assert "調べるね、" in assistant_texts
    assert "ちょっと待って" in assistant_texts


def test_live_delegation_inner_text_and_completed_flush(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    """委譲応答のテキストは発話レーンと分離し、response.completed でターン確定。

    実機では委譲後に session.output_audio.done 系の区切りが来ないため、
    内側イベントで user/assistant の flush を行う。委譲バックエンドの
    ``response.output_text`` は「裏で考えた内容」で、発話内容を担う
    ``session.output_transcript`` とは別ストリーム — assistant.text へは
    流さず、履歴へ記録して delegate 活動行の title で抜粋表示する。
    既知の中間イベント（in_progress / output_item.added / *_arguments.* /
    content_part.added / usage.updated）は unhandled 警告を出さない。
    """
    fake = TextOnlyDelegatingLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with caplog.at_level(logging.WARNING, logger="mihari_room.voice"):
        with client.websocket_connect(
            f"/voice/sessions/{session_id}/stream", headers=_auth()
        ) as ws:
            assert ws.receive_json()["type"] == EVENT_SESSION_READY
            ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
            # 委譲途中のユーザー発話は response.completed の flush で done 確定。
            # delegate 活動行の done はその直後に届くので、ここまで読めば両方拾える。
            frames = _collect_until(
                ws,
                lambda f: f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY
                and f.get("name") == "delegate"
                and f.get("status") == "done",
            )
            _disconnect_and_idle(ws, client, session_id)

    # 委譲バックエンドのテキストは assistant.text へ流れない
    # （発話内容は表の session.output_transcript が担う。二重コンテンツ防止）。
    assert not any(f["type"] == EVENT_ASSISTANT_TEXT for f in frames)

    # delegate 活動行は running → done で閉じ、確定テキストを title で抜粋表示。
    delegate = [
        f
        for f in frames
        if f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY and f.get("name") == "delegate"
    ]
    assert [f["status"] for f in delegate] == ["running", "done"]
    assert delegate[-1]["title"] == "調べたよ、結果はOKだった"

    # ユーザーターンは 2 回とも done 確定している（出力区切り無しでも）。
    user_dones = [
        f["text"]
        for f in frames
        if f["type"] == EVENT_USER_TEXT and f.get("done")
    ]
    assert user_dones == ["今何してるんだっけ", "あ、そうなんだ"]

    # 委譲テキストは履歴には残る（assistant.text としては表示しないだけ）。
    history = client.get(
        f"/voice/sessions/{session_id}/history", headers=_auth()
    ).json()
    user_texts = [m["text"] for m in history["messages"] if m["role"] == "user"]
    assistant_texts = [
        m["text"] for m in history["messages"] if m["role"] == "assistant"
    ]
    assert "今何してるんだっけ" in user_texts
    assert "あ、そうなんだ" in user_texts
    assert "調べたよ、結果はOKだった" in assistant_texts

    # 既知の内側・外側イベントは unhandled 警告を出さない。
    warnings = [record.getMessage() for record in caplog.records]
    assert not any("unhandled" in message for message in warnings)


def test_live_transcript_dedup_cumulative_delta(tmp_path: Path) -> None:
    """累積全文形式・重複送出の transcript delta で二重化しない。"""
    fake = CumulativeDeltaLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_AUDIO and f.get("done"),
        )
        _disconnect_and_idle(ws, client, session_id)

    user_done = [
        f for f in frames if f["type"] == EVENT_USER_TEXT and f.get("done")
    ]
    assert user_done[-1]["text"] == "今何してるんだっけ、えっと"

    # assistant 側も累積全文ではなく新規部分だけ client へ流れる。
    text_frames = [f for f in frames if f["type"] == EVENT_ASSISTANT_TEXT]
    deltas = "".join(f.get("delta") or "" for f in text_frames)
    assert deltas == "見てるよ、ちゃんと"
    assert text_frames[-1]["done"] is True
    assert text_frames[-1]["text"] == "見てるよ、ちゃんと"

    history = client.get(
        f"/voice/sessions/{session_id}/history", headers=_auth()
    ).json()
    user_texts = [m["text"] for m in history["messages"] if m["role"] == "user"]
    assert user_texts == ["今何してるんだっけ、えっと"]


def _make_live_gateway_app(
    tmp_path: Path,
    *,
    upstream_factory=None,
    executor=None,
) -> TestClient:
    """orchestrator 無しの gateway 形 app（live_audio + 差し替え executor）。"""
    config = RoomConfig(
        token=TOKEN,
        root=tmp_path,
        owner_id="owner",
        openai_api_key="test-openai-key",
        voice_output_mode="live_audio",
    )
    app = create_gateway_app(config, room_url="")
    if upstream_factory is not None:
        app.state.voice_upstream_factory = upstream_factory
    if executor is not None:
        app.state.voice_tool_executor_factory = lambda _sid: executor
    return TestClient(app)


def _job_result() -> dict:
    return {
        "job_id": "job-abc123",
        "title": "レポートを直して",
        "status": "done",
        "summary": "全部終わった",
    }


def test_live_job_result_injected_via_delegation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """委譲有効の live ではジョブ終端が response.item.create + response.create で注入。"""
    import mihari_room.voice.stream as stream_module

    monkeypatch.setattr(stream_module, "_JOB_WATCH_INTERVAL_SEC", 0.05)
    fake = QuietLiveUpstream()
    fake.delegation_enabled = True
    executor = _JobWatcherStubExecutor([_job_result()])
    client = _make_live_gateway_app(
        tmp_path, upstream_factory=lambda: fake, executor=executor
    )
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY
            and f.get("name") == "submit_job",
            limit=40,
        )
        _disconnect_and_idle(ws, client, session_id)

    activity = frames[-1]
    assert activity["status"] == "done"
    assert activity["call_id"] == "job-abc123"
    assert activity["title"] == "レポートを直して"

    sent = fake.sent_events()
    message_items = [
        e
        for e in sent
        if e.get("type") == "response.item.create"
        and (e.get("item") or {}).get("type") == "message"
    ]
    assert len(message_items) == 1
    text = message_items[0]["item"]["content"][0]["text"]
    assert "レポートを直して" in text
    assert "全部終わった" in text
    creates_after = [
        e
        for e in sent[sent.index(message_items[0]) :]
        if e.get("type") == "response.create"
    ]
    assert len(creates_after) == 1


def test_live_job_result_injected_via_commentary(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """委譲無しの live では session.commentary.append で音声モデルへ直接伝える。"""
    import mihari_room.voice.stream as stream_module

    monkeypatch.setattr(stream_module, "_JOB_WATCH_INTERVAL_SEC", 0.05)
    fake = QuietLiveUpstream()  # delegation_enabled 未設定 → False 扱い
    executor = _JobWatcherStubExecutor([_job_result()])
    client = _make_live_gateway_app(
        tmp_path, upstream_factory=lambda: fake, executor=executor
    )
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY
            and f.get("name") == "submit_job",
            limit=40,
        )
        _disconnect_and_idle(ws, client, session_id)

    sent = fake.sent_events()
    commentary = [
        e for e in sent if e.get("type") == "session.commentary.append"
    ]
    assert len(commentary) == 1
    assert commentary[0]["delegation_id"] is None
    assert "レポートを直して" in commentary[0]["content"]
    assert "全部終わった" in commentary[0]["content"]
    # delegation コマンドは使わない（upstream 側でも落とされる）。
    assert not any(e.get("type") == "response.item.create" for e in sent)
    assert not any(e.get("type") == "response.create" for e in sent)


def test_text_mode_job_result_injected(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """text（Realtime）モードでも conversation.item.create + response.create で注入。"""
    import mihari_room.voice.stream as stream_module

    monkeypatch.setattr(stream_module, "_JOB_WATCH_INTERVAL_SEC", 0.05)
    fake = FakeRealtimeUpstream()
    executor = _JobWatcherStubExecutor([_job_result()])
    config = RoomConfig(
        token=TOKEN,
        root=tmp_path,
        owner_id="owner",
        openai_api_key="test-openai-key",
    )
    app = create_gateway_app(config, room_url="")
    app.state.voice_upstream_factory = lambda: fake
    app.state.voice_tool_executor_factory = lambda _sid: executor
    client = TestClient(app)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY
            and f.get("name") == "submit_job",
            limit=40,
        )
        _disconnect_and_idle(ws, client, session_id)

    assert frames[-1]["status"] == "done"
    sent = fake.sent_events()
    message_items = [
        e
        for e in sent
        if e.get("type") == "conversation.item.create"
        and (e.get("item") or {}).get("type") == "message"
        and "レポートを直して" in str(e.get("item"))
    ]
    assert len(message_items) == 1
    creates_after = [
        e
        for e in sent[sent.index(message_items[0]) :]
        if e.get("type") == "response.create"
    ]
    assert len(creates_after) == 1


def test_live_capture_screen_drops_oversized_image(tmp_path: Path) -> None:
    """delegation 入力上限を超える capture 画像は backend へ送らず note で伝える。"""
    fake = DelegatingLiveUpstream(tool_name="capture_screen", call_id="call_live_big")
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    big_b64 = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"\x00" * 20_000).decode()
    assert len(big_b64) > LIVE_DELEGATION_INPUT_LIMIT // 2
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(ws, lambda f: f["type"] == EVENT_ASSISTANT_TOOL_CALL)
        assert frames[-1]["name"] == "capture_screen"
        assert frames[-1]["call_id"] == "call_live_big"
        ws.send_json(
            {
                "type": "input.image",
                "image_base64": big_b64,
                "media_type": "image/png",
                "prompt": "見て",
            }
        )
        # fco + response.create を受けた fake が 1 発話ぶんの音声を返し、
        # その途切れを watchdog が done 区切りにするのを待つ。
        _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_AUDIO and f.get("done"),
        )
        _disconnect_and_idle(ws, client, session_id)
    sent = fake.sent_events()
    # 画像の message item は送られない。
    message_items = [
        e
        for e in sent
        if e.get("type") == "response.item.create"
        and (e.get("item") or {}).get("type") == "message"
    ]
    assert message_items == []
    fco = [
        e
        for e in sent
        if e.get("type") == "response.item.create"
        and (e.get("item") or {}).get("type") == "function_call_output"
    ]
    assert len(fco) == 1
    assert fco[0]["item"]["call_id"] == "call_live_big"
    output = json.loads(fco[0]["item"]["output"])
    assert output["success"] is True
    assert "入力上限" in output["note"]
    creates_after = [
        e for e in sent[sent.index(fco[0]) :] if e.get("type") == "response.create"
    ]
    assert len(creates_after) == 1


async def test_send_tool_result_live_drops_oversized_image() -> None:
    """room 実行ツールの画像結果も live では上限超過なら送らず note で伝える。"""
    upstream = FakeLiveUpstream()
    outcome = VoiceToolOutcome(
        output=json.dumps({"success": True, "saved_as": "a.png"}, ensure_ascii=False),
        image_png=b"\x89PNG\r\n\x1a\n" + b"\x00" * 20_000,
    )
    await _send_tool_result(upstream, call_id="c1", outcome=outcome, live=True)
    sent = upstream.sent_events()
    message_items = [
        e
        for e in sent
        if e.get("type") == "response.item.create"
        and (e.get("item") or {}).get("type") == "message"
    ]
    assert message_items == []
    fco = next(
        e
        for e in sent
        if e.get("type") == "response.item.create"
        and (e.get("item") or {}).get("type") == "function_call_output"
    )
    output = json.loads(fco["item"]["output"])
    assert output["success"] is True
    assert output["saved_as"] == "a.png"
    assert "入力上限" in output["note"]


async def test_send_tool_result_live_sends_small_image() -> None:
    """上限以内の画像は従来どおり message item として送る。"""
    upstream = FakeLiveUpstream()
    outcome = VoiceToolOutcome(
        output=json.dumps({"success": True}, ensure_ascii=False),
        image_png=base64.b64decode(PNG_1X1),
    )
    await _send_tool_result(upstream, call_id="c2", outcome=outcome, live=True)
    sent = upstream.sent_events()
    message_items = [
        e
        for e in sent
        if e.get("type") == "response.item.create"
        and (e.get("item") or {}).get("type") == "message"
    ]
    assert len(message_items) == 1
    contents = message_items[0]["item"]["content"]
    assert any(part.get("type") == "input_image" for part in contents)
    fco = next(
        e
        for e in sent
        if (e.get("item") or {}).get("type") == "function_call_output"
    )
    assert json.loads(fco["item"]["output"])["success"] is True


async def test_send_tool_result_live_truncates_output() -> None:
    """live では fco output を ~4000 文字に切り詰めて末尾に印を付ける。"""
    upstream = FakeLiveUpstream()
    outcome = VoiceToolOutcome(output="あ" * 5_000)
    await _send_tool_result(upstream, call_id="c3", outcome=outcome, live=True)
    sent = upstream.sent_events()
    fco = next(
        e
        for e in sent
        if (e.get("item") or {}).get("type") == "function_call_output"
    )
    output = fco["item"]["output"]
    assert output.endswith("…(truncated)")
    assert len(output) == 4_000 + len("…(truncated)")


async def test_send_tool_result_text_mode_unchanged() -> None:
    """text（Realtime）モードは上限ガード無し。画像も長文 output もそのまま。"""
    upstream = FakeLiveUpstream()
    outcome = VoiceToolOutcome(
        output="x" * 5_000,
        image_png=b"\x89PNG\r\n\x1a\n" + b"\x00" * 20_000,
    )
    await _send_tool_result(upstream, call_id="c4", outcome=outcome, live=False)
    sent = upstream.sent_events()
    message_items = [
        e
        for e in sent
        if e.get("type") == "conversation.item.create"
        and (e.get("item") or {}).get("type") == "message"
    ]
    assert len(message_items) == 1
    fco = next(
        e
        for e in sent
        if e.get("type") == "conversation.item.create"
        and (e.get("item") or {}).get("type") == "function_call_output"
    )
    assert fco["item"]["output"] == "x" * 5_000


def test_live_transcript_only_turn_flushes_via_watchdog(tmp_path: Path) -> None:
    """出力が一切無いターンでも input transcript の gap で user.text が確定する。

    session.output_audio.done 相当の区切りは Live API に存在しないため、
    ユーザー発話は transcript 途切れ（入力ウォッチドッグ）で畳む。
    """
    fake = TranscriptOnlyLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_USER_TEXT and f.get("done"),
        )
        _disconnect_and_idle(ws, client, session_id)

    assert frames[-1]["text"] == "声だけのターン"
    # 出力イベントは一度も無いので assistant 側は何も送らない。
    assert not any(f["type"] == EVENT_ASSISTANT_AUDIO for f in frames)
    assert not any(f["type"] == EVENT_ASSISTANT_TEXT for f in frames)

    history = client.get(f"/voice/sessions/{session_id}/history", headers=_auth()).json()
    user_texts = [m["text"] for m in history["messages"] if m["role"] == "user"]
    assert user_texts == ["声だけのターン"]


def test_live_quiet_upstream_sends_transcript_none(tmp_path: Path) -> None:
    """upstream が一切応答しないターンも音声到着だけで transcript_none が出る。

    出力イベントも transcript も無い状況では、最後の非無音クライアント
    音声からの入力 gap で区切りを判定し、desktop の発話プレースホルダを
    user.transcript_none で解放する。
    """
    fake = QuietLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_USER_TRANSCRIPT_NONE,
        )
        _disconnect_and_idle(ws, client, session_id)

    assert len(frames) == 1
    assert not any(f["type"] == EVENT_USER_TEXT for f in frames)


def test_live_transcript_start_end_ms_splits_turns(tmp_path: Path) -> None:
    """transcript delta の発話区間（start_ms/end_ms）が閾値以上離れたら別発話。

    実機の input_transcript.delta は発話区間を持つため、壁時計の gap を
    待たずに時刻の飛びで先の発話を確定できる（公式推奨の grouping）。
    """
    fake = TimestampedTranscriptLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_USER_TEXT
            and f.get("done")
            and f.get("text") == "二つ目",
        )
        _disconnect_and_idle(ws, client, session_id)

    user_dones = [
        f["text"] for f in frames if f["type"] == EVENT_USER_TEXT and f.get("done")
    ]
    # start_ms の飛び（400→6000ms）で「一つ目」が先に確定し、
    # 「二つ目」は後続の壁時計 gap で確定する。
    assert user_dones == ["一つ目", "二つ目"]


def test_live_output_audio_done_still_closes_turn(tmp_path: Path) -> None:
    """公式には存在しない session.output_audio.done が届いても区切り処理が動く。

    通常の区切りはウォッチドッグの出力 gap 判定。万一 upstream が
    done/stopped を送ってきた場合の保険分岐の確認用。
    """
    fake = DoneEmittingLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_AUDIO and f.get("done"),
            limit=5,
        )
        _disconnect_and_idle(ws, client, session_id)

    # gap を待たずイベント駆動で done が届く（delta + done の 2 枚）。
    audio_frames = [f for f in frames if f["type"] == EVENT_ASSISTANT_AUDIO]
    assert len(audio_frames) == 2
    assert audio_frames[-1]["done"] is True


def test_live_delegation_failed_notifies_error(tmp_path: Path) -> None:
    """委譲応答が response.failed で終わったら delegate 行を failed で閉じ通知する。

    失敗を沈黙させないため、確定できる断片を畳んだうえで
    delegate 活動行（status=failed）と error フレームを client へ送る。
    """
    fake = FailingDelegatingLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == "error",
        )
        _disconnect_and_idle(ws, client, session_id)

    delegate = [
        f
        for f in frames
        if f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY and f.get("name") == "delegate"
    ]
    assert [f["status"] for f in delegate] == ["running", "failed"]
    error = frames[-1]
    assert error["code"] == "delegation_error"
    assert "backend exploded" in error["message"]
    # 失敗した委譲の呼び出しは実行しない（fco / response.create は送らない）。
    sent = fake.sent_events()
    assert not any(e.get("type") == "response.item.create" for e in sent)
    assert not any(e.get("type") == "response.create" for e in sent)


def test_live_delegation_skips_noncompleted_item(tmp_path: Path) -> None:
    """output_item.done でも status != completed の function_call は実行しない。

    Twilio 公式サンプル準拠 — 委譲応答から回収するのは completed 状態の
    item のみ。in_progress の item が完了扱いされないことを確認する。
    """
    fake = NonCompletedItemDelegatingLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY
            and f.get("name") == "delegate"
            and f.get("status") == "done",
        )
        _disconnect_and_idle(ws, client, session_id)

    # in_progress の function_call は拾われない → ツール活動も upstream への
    # fco / response.create も発生しない。
    assert not any(
        f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY and f.get("name") == "get_job_status"
        for f in frames
    )
    sent = fake.sent_events()
    assert not any(e.get("type") == "response.item.create" for e in sent)
    assert not any(e.get("type") == "response.create" for e in sent)


def test_live_delegation_clears_calls_between_delegations(tmp_path: Path) -> None:
    """delegated_calls は委譲ごとにクリアされ、連続委譲で再実行されない。

    1 回目の委譲で function_call を実行し、room の response.create に
    応じた 2 回目の委譲（呼び出し無し）では何も起こらないことを確認する。
    """
    fake = RepeatedDelegatingLiveUpstream()
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        delegate_dones = 0

        def second_delegate_done(f: dict) -> bool:
            nonlocal delegate_dones
            if (
                f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY
                and f.get("name") == "delegate"
                and f.get("status") == "done"
            ):
                delegate_dones += 1
            return delegate_dones >= 2

        _collect_until(ws, second_delegate_done, limit=40)
        _disconnect_and_idle(ws, client, session_id)

    assert delegate_dones == 2
    sent = fake.sent_events()
    # 呼び出しの再実行が無ければ fco は 1 件だけ（1 回目の get_job_status）。
    fco = [
        e
        for e in sent
        if e.get("type") == "response.item.create"
        and (e.get("item") or {}).get("type") == "function_call_output"
    ]
    assert len(fco) == 1
    assert fco[0]["item"]["call_id"] == "call_live_1"
    creates = [e for e in sent if e.get("type") == "response.create"]
    assert len(creates) == 1


def test_live_submit_job_activity_carries_job_id(tmp_path: Path) -> None:
    """委譲の submit_job 実行成功時、tool_activity に job_id と title を載せる。

    desktop はこの job_id で RoomJobMonitor.attach して進捗購読を始める。
    """
    fake = DelegatingLiveUpstream(
        tool_name="submit_job",
        call_id="call_live_job",
        arguments=json.dumps(
            {"prompt": "レポートを書いて", "title": "レポート"}, ensure_ascii=False
        ),
    )
    client = _make_live_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        frames = _collect_until(
            ws,
            lambda f: f["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY
            and f.get("name") == "submit_job",
        )
        _disconnect_and_idle(ws, client, session_id)

    activity = frames[-1]
    assert activity["status"] == "done"
    assert activity["job_id"]
    assert activity["title"] == "レポート"
