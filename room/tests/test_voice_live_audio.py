"""live_audio モード（gpt-live-1 + VC 中継）の room 側検証。"""

from __future__ import annotations

import asyncio
import base64
import json
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
)
from mihari_room.voice.stream import LIVE_DELEGATION_INPUT_LIMIT, _send_tool_result
from mihari_room.voice.tools import VoiceToolOutcome
from mihari_room.voice.upstream import RealtimeUpstream
from mihari_room.voice.vc import (
    HTTPVoiceConverter,
    PassthroughConverter,
    f32_to_pcm16,
    pcm16_to_f32,
    voice_converter_from_config,
)
from tests.recording import RecordingBoard, ScriptedWorker
from tests.test_voice_realtime import PNG_1X1, _disconnect_and_idle

TOKEN = "room-secret"

#: 往復変換で誤差が出ない小さめの PCM16 サンプル。
PCM_SAMPLES = [0, 1000, -1000, 8000]
PCM_BYTES = struct.pack(f"<{len(PCM_SAMPLES)}h", *PCM_SAMPLES)
PCM_B64 = base64.b64encode(PCM_BYTES).decode()


class FakeLiveUpstream(RealtimeUpstream):
    """gpt-live-1 相当の応答を返すテスト用 upstream。

    room からは Realtime 形のイベントが届くので、
    ``input_audio_buffer.append`` を受けたら live 形のイベント列を返す。
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
            await self._queue.put({"type": "session.input_transcript.delta", "delta": "こんにちは"})
            await self._queue.put({"type": "session.output_transcript.delta", "delta": "やあ、"})
            await self._queue.put({"type": "session.output_transcript.delta", "delta": "見てるよ"})
            await self._queue.put({"type": "session.output_audio.delta", "delta": PCM_B64})
            await self._queue.put({"type": "session.output_audio.done"})

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
            # 委譲継続（response.create）は「ツール結果を受け取った」合図として
            # 1 発話ぶんの音声終端を返し、テスト側の待ち合わせに使う。
            await self._queue.put({"type": "session.output_audio.done"})
            return
        if event_type != "input_audio_buffer.append" or self._delegated:
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
            await self._queue.put({"type": "session.output_audio.done"})
            return
        if event_type != "input_audio_buffer.append" or self._delegated:
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


class QuietLiveUpstream(FakeLiveUpstream):
    """応答イベントを積まない静かなバリアント（無音ペーサーの観測用）。

    親の send は ``input_audio_buffer.append`` ごとに応答イベントをキューへ
    積むため、読み取らないテストでは溢れる。ここでは送信記録だけ残す。
    """

    async def send(self, event: dict) -> None:
        if self._closed:
            return
        self._sent.append(event)


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
    assert fake.audio_output_events_seen() == 2

    detail = client.get(f"/voice/sessions/{session_id}", headers=_auth()).json()
    assert detail["upstream_audio_output_events"] == 2
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
        ws.send_json({"type": "input.audio", "audio_base64": "AAAA"})
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
        # response.create を受けた fake が output_audio.done を返すのを待つ。
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
        # response.create への応答として fake が返す output_audio.done まで読む。
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
        # fco + response.create を受けた fake が output_audio.done を返す。
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
