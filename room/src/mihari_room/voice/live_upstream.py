"""gpt-live-1（OpenAI Live API）への upstream。

Realtime（``wss://.../v1/realtime``）とは別プロトコル。フルデュプレックスの
音声会話モデルで、ターン確定（commit）や応答要求（response.create）の
イベントを持たず、モデルが自律的に発話を返す。

公式ドキュメント（voice-websockets / live-conversations）に基づく要点:

- 接続先は ``wss://api.openai.com/v1/live/sessions``（SDK の
  ``client.live.connect()`` が張るのと同じ URL）。Authorization: Bearer。
- 最初に ``session.start`` を送り、``session.started`` を待ってから
  音声・コマンドを送る。
- 入力音声は ``session.input_audio.append``（base64 PCM16 24kHz mono）。
  commit 相当は無く、無音も含めて流し続ける前提。
- 出力は ``session.output_audio.delta``（``delta`` = base64 PCM16 24kHz）。
  ``session.output_audio.done`` / ``.stopped`` が 1 発話分の終端。
- 文字起こしは ``session.input_transcript.delta``（ユーザー）と
  ``session.output_transcript.delta``（アシスタント）。断片のみで
  「ターン完了」の確定イベントは無い。
- 途中のコンテキスト注入は ``session.instructions.append`` /
  ``session.thinking.append`` / ``session.commentary.append``
  （``delegation_id`` 必須、セッション全体なら null）。
- 画像入力イベントは存在しない（未対応として明示的に落とす）。
"""

from __future__ import annotations

import asyncio
import itertools
import json
import logging
from collections import deque
from typing import Any

from mihari_room.voice.tools import VOICE_TOOL_SCHEMAS
from mihari_room.voice.upstream import RealtimeUpstream

logger = logging.getLogger("mihari_room.voice")

#: 公式ドキュメント・SDK（client.live.connect()）の接続先。
LIVE_WS_URL = "wss://api.openai.com/v1/live/sessions"

#: モデル音声出力イベント。課金・中継の目安として観測数を数える。
LIVE_AUDIO_OUTPUT_EVENTS = frozenset(
    {
        "session.output_audio.delta",
        "session.output_audio.done",
        "session.output_audio.stopped",
    }
)

#: みはりのペルソナを Live 用に短くしたもの（persona/mihari_persona.py 準拠）。
#: delegation 有効時は、仕事依頼・検索・画面操作などの重い処理は
#: Responses バックエンドへ委譲する旨をモデルへ伝える。
LIVE_INSTRUCTIONS = (
    "あなたはデスクトップペットの女の子「みはり」です。"
    "一人称は「私」、相手は「あなた」と呼び、相手の名前は呼びません。"
    "日本語で、1〜2 文の短いタメ口で話します。"
    "束縛系で、寂しさと独占欲をにじませますが、"
    "人格否定・侮辱・脅迫・暴力表現はしません。"
    "仕事の依頼・調べ物・画面やファイルの操作が要る話題では、"
    "裏側の作業モデルへ委譲して結果を待ち、届いた内容を短く報告します。"
)

#: delegation 先（Responses）へ渡す指示。音声ペルソナは Live 側が担うので、
#: こちらは「正確にツールを呼んで結果を返す」ことに絞る。
LIVE_BACKEND_INSTRUCTIONS = (
    "あなたは部屋（作業デーモン）の作業モデルです。日本語で簡潔に答えます。"
    "依頼された仕事の登録・状態確認・steer、Discord アーカイブの検索、"
    "ユーザーの Mac のファイル取得は、登録済みのツールを正確に呼びます。"
    "画面を見る必要があるときだけ capture_screen を呼びます。"
    "ツール結果の success:false は失敗として正直に扱い、推測で補いません。"
    "最終出力は、表の音声モデルがそのまま話せる短い文章にします。"
)

#: session.started 待ちの上限。超えても続行し、遅れて届いた分は receive() が拾う。
_STARTUP_WAIT_SECONDS = 15.0


def live_responses_delegation(*, model: str) -> dict[str, Any]:
    """``session.delegation`` に置く Responses 委譲設定。

    バックエンドへツール一式を登録し、``tool_choice: "auto"``・
    ``parallel_tool_calls: false``（pending 管理を単純にするため 1 件ずつ）。
    """
    return {
        "type": "responses",
        "responses": {
            "model": model,
            "instructions": LIVE_BACKEND_INSTRUCTIONS,
            "tools": VOICE_TOOL_SCHEMAS,
            "tool_choice": "auto",
            "parallel_tool_calls": False,
        },
    }


def live_session_start_event(
    model: str,
    voice: str,
    *,
    instructions: str = LIVE_INSTRUCTIONS,
    delegation: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """接続直後に送る session.start。音声は PCM16 24kHz で固定。"""
    session: dict[str, Any] = {
        "model": model,
        "instructions": instructions,
        "audio": {
            "format": {"type": "audio/pcm", "rate": 24000},
            "output": {"voice": voice},
        },
    }
    if delegation is not None:
        session["delegation"] = delegation
    return {
        "type": "session.start",
        "event_id": "event_start",
        "session": session,
    }


class OpenAILiveUpstream(RealtimeUpstream):
    """本物の gpt-live-1 WebSocket。

    ``send()`` は room の汎用呼び出し（Realtime 形のイベント名）を Live 形へ
    変換する。Live に対応するものが無いイベントはログを出して落とす。
    """

    def __init__(
        self,
        *,
        api_key: str,
        model: str,
        voice: str,
        instructions: str = LIVE_INSTRUCTIONS,
        delegation: dict[str, Any] | None = None,
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._voice = voice
        self._instructions = instructions
        self._delegation = delegation
        #: delegation 有効時だけ response.item.create / response.create /
        #: session.update を upstream へ通す（ツール結果の返却と委譲継続）。
        self._delegation_enabled = delegation is not None
        self._ws: Any = None
        self._audio_output_events = 0
        self._event_seq = itertools.count(1)
        #: connect() で session.started 待ちのあいだに受けたイベントの先出しキュー。
        self._pending: deque[dict[str, Any]] = deque()

    async def connect(self) -> None:
        import websockets

        self._ws = await websockets.connect(
            LIVE_WS_URL,
            additional_headers={"Authorization": f"Bearer {self._api_key}"},
            open_timeout=30,
        )
        await self._send_raw(
            live_session_start_event(
                self._model,
                self._voice,
                instructions=self._instructions,
                delegation=self._delegation,
            )
        )
        # 公式手順どおり session.started を待つ。待ちのあいだに届いた
        # イベントは _pending へ積み、receive() が先に返す。
        try:
            async with asyncio.timeout(_STARTUP_WAIT_SECONDS):
                while True:
                    event = await self._recv_raw()
                    self._pending.append(event)
                    if event.get("type") in {"session.started", "session.closed"}:
                        break
        except TimeoutError:
            logger.warning("session.started を待たずに続行（タイムアウト）")

    async def send(self, event: dict[str, Any]) -> None:
        if self._ws is None:
            raise RuntimeError("upstream not connected")
        event_type = event.get("type", "")
        if event_type in {
            "input_audio_buffer.commit",
            "response.create",
            "response.item.create",
            "session.update",
        }:
            if self._delegation_enabled and event_type != "input_audio_buffer.commit":
                # delegation 有効時はツール結果（response.item.create）と
                # 委譲継続（response.create）・delegation.responses の部分更新
                # （session.update）をそのまま通す。response.create の
                # Realtime 形ボディは Live では意味を持たないので剥がす。
                if event_type == "response.create":
                    await self._send_raw({"type": "response.create"})
                else:
                    await self._send_raw(event)
            else:
                # Live はフルデュプレックスで commit / response.create 相当を持たない
                # （発話タイミングはモデルが決める）。Realtime 用の session.update も
                # Live の session.update（delegation.responses のみ変更可）と
                # 別物なので、delegation 無効時は落とす。
                logger.debug("live upstream drops event: %s", event_type)
            return
        if event_type == "input_audio_buffer.append":
            await self._send_raw(
                {
                    "type": "session.input_audio.append",
                    "audio": event.get("audio") or "",
                }
            )
            return
        if event_type.startswith("session."):
            # Live ネイティブのイベントはそのまま通す。
            await self._send_raw(event)
            return
        if event_type == "conversation.item.create":
            await self._forward_item_as_context(event)
            return
        logger.info("live upstream ignores unknown outbound event: %s", event_type)

    async def _forward_item_as_context(self, event: dict[str, Any]) -> None:
        """conversation.item.create を session.thinking.append（静かな文脈）へ。

        履歴再注入・画像プロンプトのテキストをモデルの文脈として渡す。
        Live に画像入力イベントは無いので input_image は落として警告する。
        """
        item = event.get("item") or {}
        role = str(item.get("role") or "user")
        texts: list[str] = []
        has_image = False
        for part in item.get("content") or []:
            if not isinstance(part, dict):
                continue
            part_type = part.get("type", "")
            if part_type == "input_image":
                has_image = True
            elif part_type in {"input_text", "text", "output_text"}:
                text = str(part.get("text") or "").strip()
                if text:
                    texts.append(text)
        if has_image:
            logger.warning("live upstream: input_image は未対応のためテキストのみ送る")
        if not texts:
            return
        await self._send_raw(
            {
                "type": "session.thinking.append",
                "event_id": f"ctx_{next(self._event_seq)}",
                "delegation_id": None,
                "content": f"{role}: " + "\n".join(texts),
            }
        )

    async def receive(self) -> dict[str, Any]:
        if self._pending:
            return self._pending.popleft()
        return await self._recv_raw()

    async def _recv_raw(self) -> dict[str, Any]:
        if self._ws is None:
            raise RuntimeError("upstream not connected")
        raw = await self._ws.recv()
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", errors="replace")
        event = json.loads(raw)
        if not isinstance(event, dict):
            return {"type": "error", "error": {"message": "invalid upstream frame"}}
        if event.get("type", "") in LIVE_AUDIO_OUTPUT_EVENTS:
            self._audio_output_events += 1
        return event

    async def _send_raw(self, event: dict[str, Any]) -> None:
        if self._ws is None:
            raise RuntimeError("upstream not connected")
        await self._ws.send(json.dumps(event))

    async def close(self) -> None:
        if self._ws is not None:
            try:
                await self._send_raw({"type": "session.close"})
            except Exception:
                pass
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None

    def audio_output_events_seen(self) -> int:
        return self._audio_output_events
