"""live_audio モード（gpt-live-1 + VC 中継）の room 側検証。"""

from __future__ import annotations

import asyncio
import base64
import json
import struct
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
    live_session_start_event,
)
from mihari_room.voice.protocol import (
    EVENT_ASSISTANT_AUDIO,
    EVENT_ASSISTANT_TEXT,
    EVENT_SESSION_READY,
    EVENT_USER_TEXT,
)
from mihari_room.voice.upstream import RealtimeUpstream
from mihari_room.voice.vc import (
    HTTPVoiceConverter,
    PassthroughConverter,
    f32_to_pcm16,
    pcm16_to_f32,
    voice_converter_from_config,
)
from tests.recording import RecordingBoard, ScriptedWorker
from tests.test_voice_realtime import _disconnect_and_idle

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
