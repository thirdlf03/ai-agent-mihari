"""OpenAI Realtime voice セッション（§5-1 / §5-2）の room 側検証。"""

from __future__ import annotations

import base64
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from mihari_room.app import create_app
from mihari_room.config import TOKEN_HEADER, RoomConfig
from mihari_room.voice.upstream import response_create_event
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from mihari_room.voice.protocol import (
    EVENT_ASSISTANT_TEXT,
    EVENT_ASSISTANT_TOOL_CALL,
    EVENT_HISTORY_SYNC,
    EVENT_SESSION_CLOSED,
    EVENT_SESSION_READY,
    EVENT_USER_TEXT,
)
from mihari_room.voice.upstream import FakeRealtimeUpstream
from tests.recording import RecordingBoard, ScriptedWorker

TOKEN = "room-secret"
PNG_1X1 = base64.b64encode(
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
    b"\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01"
    b"\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82"
).decode()


def _make_app(
    tmp_path: Path,
    *,
    openai_api_key: str = "test-openai-key",
    upstream_factory=None,
) -> TestClient:
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    orch = RoomOrchestrator(
        store, FileJobQueue(store, owner_id="owner"), board, ScriptedWorker([])
    )
    config = RoomConfig(
        token=TOKEN,
        root=tmp_path,
        owner_id="owner",
        openai_api_key=openai_api_key,
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


def _disconnect_and_idle(ws, client: TestClient, session_id: str) -> None:
    """WS を明示的に切り、ハンドラの後始末が終わるまで待つ。

    ``websocket_connect`` の ``__exit__`` は disconnect を投げた直後に
    アプリタスクを cancel するため、ハンドラ（2タスクの畳み込みと
    upstream の close）が間に合わず CancelledError になる。
    事前に disconnect を送り、status が streaming から抜けるのを待てば
    その競合を避けられる。
    """
    ws.send({"type": "websocket.disconnect", "code": 1000, "reason": ""})
    for _ in range(200):
        status = (
            client.get(f"/voice/sessions/{session_id}", headers=_auth())
            .json()
            .get("status")
        )
        if status != "streaming":
            return
        time.sleep(0.02)
    raise AssertionError("session did not leave streaming state")


def test_post_session_requires_token(tmp_path: Path) -> None:
    client = _make_app(tmp_path)
    assert client.post("/voice/sessions").status_code == 401


def test_post_session_requires_openai_key(tmp_path: Path) -> None:
    client = _make_app(tmp_path, openai_api_key="")
    assert client.post("/voice/sessions", headers=_auth()).status_code == 503


def test_post_and_get_session(tmp_path: Path) -> None:
    client = _make_app(tmp_path)
    created = client.post("/voice/sessions", headers=_auth()).json()
    assert created["session_id"]
    assert created["model"] == "gpt-realtime-2.1-mini"
    assert created["status"] == "created"
    detail = client.get(f"/voice/sessions/{created['session_id']}", headers=_auth()).json()
    assert detail["session_id"] == created["session_id"]
    assert detail["output_modalities"] == ["text"]


def test_websocket_requires_token(tmp_path: Path) -> None:
    client = _make_app(tmp_path)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with pytest.raises((RuntimeError, WebSocketDisconnect)):
        with client.websocket_connect(f"/voice/sessions/{session_id}/stream"):
            pass


def test_websocket_text_via_fake_upstream(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()

    def factory():
        return fake

    client = _make_app(tmp_path, upstream_factory=factory)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ready = ws.receive_json()
        assert ready["type"] == EVENT_SESSION_READY
        assert ready["output_modalities"] == ["text"]
        ws.send_json(
            {
                "type": "input.image",
                "image_base64": PNG_1X1,
                "media_type": "image/png",
                "prompt": "ping",
            }
        )
        texts: list[str] = []
        tool_calls = 0
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TEXT:
                if frame.get("delta"):
                    texts.append(frame["delta"])
                if frame.get("done"):
                    texts.append(frame.get("text", ""))
                    break
            elif frame["type"] == EVENT_ASSISTANT_TOOL_CALL:
                tool_calls += 1
        assert "saw-image" in "".join(texts)
        assert tool_calls == 0
        _disconnect_and_idle(ws, client, session_id)
    sent_types = [e.get("type") for e in fake.sent_events()]
    assert "session.update" in sent_types
    assert "conversation.item.create" in sent_types
    assert fake.audio_output_events_seen() == 0


def test_websocket_audio_input_path(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        texts: list[str] = []
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TEXT and frame.get("done"):
                texts.append(frame.get("text", ""))
                break
        assert texts == ["heard-audio"]
        _disconnect_and_idle(ws, client, session_id)
    assert any(e.get("type") == "input_audio_buffer.append" for e in fake.sent_events())


def test_websocket_image_input_path(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        ws.send_json(
            {
                "type": "input.image",
                "image_base64": PNG_1X1,
                "media_type": "image/png",
            }
        )
        done_text = ""
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TEXT and frame.get("done"):
                done_text = frame.get("text", "")
                break
        assert done_text == "saw-image"
        _disconnect_and_idle(ws, client, session_id)


def test_websocket_tool_call_via_audio(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    tool_audio = base64.b64encode(b"tool").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        ws.send_json({"type": "input.audio", "audio_base64": tool_audio})
        tool = None
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TOOL_CALL:
                tool = frame
                break
        assert tool is not None
        assert tool["name"] == "echo_phrase"
        assert tool["call_id"] == "call_test_1"
        assert "audio-tool" in tool["arguments"]
        _disconnect_and_idle(ws, client, session_id)


def test_websocket_tool_call_via_image(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        ws.send_json(
            {
                "type": "input.image",
                "image_base64": PNG_1X1,
                "media_type": "image/png",
                "prompt": "__tool__ please",
            }
        )
        tool = None
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TOOL_CALL:
                tool = frame
                break
        assert tool is not None
        assert "image-tool" in tool["arguments"]
        _disconnect_and_idle(ws, client, session_id)


def test_capabilities_advertises_voice(tmp_path: Path) -> None:
    client = _make_app(tmp_path)
    body = client.get("/capabilities", headers=_auth()).json()
    assert body["voice_realtime"] is True
    assert body["voice_realtime_protocol"] == 1

    client_disabled = _make_app(tmp_path, openai_api_key="")
    body_disabled = client_disabled.get("/capabilities", headers=_auth()).json()
    assert body_disabled["voice_realtime"] is False


def test_session_metadata_tracks_no_audio_output(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        ws.send_json(
            {
                "type": "input.image",
                "image_base64": PNG_1X1,
                "media_type": "image/png",
            }
        )
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TEXT and frame.get("done"):
                break
        _disconnect_and_idle(ws, client, session_id)
    detail = client.get(f"/voice/sessions/{session_id}", headers=_auth()).json()
    assert detail["upstream_audio_output_events"] == 0


def test_session_update_uses_realtime_ga_shape(tmp_path: Path) -> None:
    """turn_detection 無効化は audio.input 配下で送る（トップレベルは beta 形）。"""
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        _disconnect_and_idle(ws, client, session_id)
    update = next(e for e in fake.sent_events() if e.get("type") == "session.update")
    session = update["session"]
    assert session["output_modalities"] == ["text"]
    assert "turn_detection" not in session
    audio_input = session["audio"]["input"]
    assert audio_input["turn_detection"] is None
    assert audio_input["format"] == {"type": "audio/pcm", "rate": 24000}
    assert audio_input["transcription"]["model"]


def test_user_transcript_relayed_as_user_text(tmp_path: Path) -> None:
    """input_audio_transcription.completed を user.text としてクライアントへ中継する。"""
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        transcript = None
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_USER_TEXT:
                transcript = frame.get("text", "")
                break
        assert transcript == "こんにちは"
        _disconnect_and_idle(ws, client, session_id)


def test_history_persists_text_not_audio(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01\x02").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TEXT and frame.get("done"):
                break
        ws.send_json(
            {
                "type": "input.image",
                "image_base64": PNG_1X1,
                "media_type": "image/png",
                "prompt": "look here",
            }
        )
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TEXT and frame.get("done"):
                break
        _disconnect_and_idle(ws, client, session_id)
    history = client.get(f"/voice/sessions/{session_id}/history", headers=_auth()).json()
    assert history["session_id"] == session_id
    user_messages = [message for message in history["messages"] if message["role"] == "user"]
    image_prompts = [m for m in user_messages if m.get("kind") == "image_prompt"]
    assert len(image_prompts) == 1
    assert image_prompts[0]["text"] == "look here"
    # 音声入力の文字起こしも user ターンとして履歴に残る。
    assert any(m["text"] == "こんにちは" for m in user_messages)
    assert any(message["role"] == "assistant" for message in history["messages"])
    history_path = tmp_path / "voice" / "sessions" / session_id / "history.jsonl"
    assert history_path.is_file()
    raw = history_path.read_text(encoding="utf-8")
    assert audio_b64 not in raw
    audio_files = list(tmp_path.rglob("*.wav")) + list(tmp_path.rglob("*.pcm"))
    assert audio_files == []


def test_disconnect_and_reconnect_continues_session(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ready = ws.receive_json()
        assert ready["type"] == EVENT_SESSION_READY
        assert ready.get("resumed") is False
        ws.send_json(
            {
                "type": "input.image",
                "image_base64": PNG_1X1,
                "media_type": "image/png",
                "prompt": "first turn",
            }
        )
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TEXT and frame.get("done"):
                break
        _disconnect_and_idle(ws, client, session_id)
    detail = client.get(f"/voice/sessions/{session_id}", headers=_auth()).json()
    assert detail["status"] == "created"

    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ready = ws.receive_json()
        assert ready["type"] == EVENT_SESSION_READY
        assert ready.get("resumed") is True
        sync = ws.receive_json()
        assert sync["type"] == EVENT_HISTORY_SYNC
        assert len(sync["messages"]) >= 2
        replay_count = sum(
            1 for event in fake.sent_events() if event.get("type") == "conversation.item.create"
        )
        assert replay_count >= 2
        ws.send_json(
            {
                "type": "input.image",
                "image_base64": PNG_1X1,
                "media_type": "image/png",
                "prompt": "second turn",
            }
        )
        done_text = ""
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TEXT and frame.get("done"):
                done_text = frame.get("text", "")
                break
        assert done_text == "saw-image"
        _disconnect_and_idle(ws, client, session_id)
    history = client.get(f"/voice/sessions/{session_id}/history", headers=_auth()).json()
    user_prompts = [
        message["text"]
        for message in history["messages"]
        if message["role"] == "user" and message.get("kind") == "image_prompt"
    ]
    assert user_prompts == ["first turn", "second turn"]


def test_concurrent_session_guard(tmp_path: Path) -> None:
    client = _make_app(tmp_path)
    first = client.post("/voice/sessions", headers=_auth())
    assert first.status_code == 200
    second = client.post("/voice/sessions", headers=_auth())
    assert second.status_code == 409


def test_close_session_allows_new_call(tmp_path: Path) -> None:
    client = _make_app(tmp_path)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    closed = client.post(f"/voice/sessions/{session_id}/close", headers=_auth())
    assert closed.status_code == 200
    assert closed.json()["status"] == "closed"
    detail = client.get(f"/voice/sessions/{session_id}", headers=_auth()).json()
    assert detail["status"] == "closed"
    created = client.post("/voice/sessions", headers=_auth())
    assert created.status_code == 200
    assert created.json()["session_id"] != session_id


def test_concurrent_stream_rejected(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]

    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        with pytest.raises((RuntimeError, WebSocketDisconnect)):
            with client.websocket_connect(
                f"/voice/sessions/{session_id}/stream", headers=_auth()
            ) as ws2:
                ws2.receive_json()
        _disconnect_and_idle(ws, client, session_id)


def test_websocket_auth_via_query_token(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(f"/voice/sessions/{session_id}/stream?token={TOKEN}") as ws:
        ready = ws.receive_json()
        assert ready["type"] == EVENT_SESSION_READY
        _disconnect_and_idle(ws, client, session_id)


def test_response_create_uses_text_output_modalities(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        ws.send_json(
            {
                "type": "input.image",
                "image_base64": PNG_1X1,
                "media_type": "image/png",
            }
        )
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TEXT and frame.get("done"):
                break
        _disconnect_and_idle(ws, client, session_id)
    creates = [e for e in fake.sent_events() if e.get("type") == "response.create"]
    assert creates
    assert all(e.get("response", {}).get("output_modalities") == ["text"] for e in creates)
    assert response_create_event()["response"]["output_modalities"] == ["text"]


def test_upstream_audio_output_counted_not_relayed(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    probe_audio = base64.b64encode(b"audio-out-probe").decode()
    client_frames: list[dict] = []
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        ws.send_json({"type": "input.audio", "audio_base64": probe_audio})
        for _ in range(10):
            frame = ws.receive_json()
            client_frames.append(frame)
            if frame["type"] == EVENT_ASSISTANT_TEXT and frame.get("done"):
                break
        _disconnect_and_idle(ws, client, session_id)
    assert all("audio" not in frame.get("type", "") for frame in client_frames)
    assert any(frame.get("text") == "text-only" for frame in client_frames if frame.get("done"))
    detail = client.get(f"/voice/sessions/{session_id}", headers=_auth()).json()
    assert detail["upstream_audio_output_events"] == 2


def test_config_reads_openai_key_from_environment(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("MIHARI_ROOM_TOKEN", TOKEN)
    monkeypatch.setenv("MIHARI_ROOM_ROOT", str(tmp_path))
    monkeypatch.setenv("MIHARI_OPENAI_API_KEY", "sk-from-mihari-env")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    cfg = RoomConfig.from_environment()
    assert cfg.openai_api_key == "sk-from-mihari-env"

    monkeypatch.delenv("MIHARI_OPENAI_API_KEY", raising=False)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-from-openai-env")
    cfg_fallback = RoomConfig.from_environment()
    assert cfg_fallback.openai_api_key == "sk-from-openai-env"


def test_history_survives_manager_reload(tmp_path: Path) -> None:
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        ws.send_json(
            {
                "type": "input.image",
                "image_base64": PNG_1X1,
                "media_type": "image/png",
                "prompt": "persist me",
            }
        )
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TEXT and frame.get("done"):
                break
        _disconnect_and_idle(ws, client, session_id)
    reloaded = _make_app(tmp_path, upstream_factory=lambda: fake)
    history = reloaded.get(f"/voice/sessions/{session_id}/history", headers=_auth()).json()
    assert any(message.get("text") == "persist me" for message in history["messages"])
    detail = reloaded.get(f"/voice/sessions/{session_id}", headers=_auth()).json()
    assert detail["status"] == "created"


def test_close_endpoint_ends_live_stream(tmp_path: Path) -> None:
    """接続中のストリームは POST /close で終わり、client に session.closed が届く。"""
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        closed = client.post(f"/voice/sessions/{session_id}/close", headers=_auth())
        assert closed.status_code == 200
        for _ in range(20):
            frame = ws.receive_json()
            if frame["type"] == EVENT_SESSION_CLOSED:
                break
        else:
            raise AssertionError("session.closed was not delivered")
    detail = client.get(f"/voice/sessions/{session_id}", headers=_auth()).json()
    assert detail["status"] == "closed"


def test_audio_transcript_recorded_in_history(tmp_path: Path) -> None:
    """音声→commit の文字起こしが user ロールで履歴に残る。"""
    fake = FakeRealtimeUpstream()
    client = _make_app(tmp_path, upstream_factory=lambda: fake)
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    audio_b64 = base64.b64encode(b"\x00\x01").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        ws.receive_json()
        ws.send_json({"type": "input.audio", "audio_base64": audio_b64})
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_USER_TEXT:
                break
        _disconnect_and_idle(ws, client, session_id)
    history = client.get(f"/voice/sessions/{session_id}/history", headers=_auth()).json()
    transcripts = [
        m for m in history["messages"] if m["role"] == "user" and m.get("kind") == "text"
    ]
    assert any(m["text"] == "こんにちは" for m in transcripts)


def test_invalid_session_id_rejected(tmp_path: Path) -> None:
    """パス連結に使えない session_id は 404 / WS 4404 で拒否する。"""
    client = _make_app(tmp_path)
    for bad_id in ("..", "%2E%2E", "bad..id", "bad id", "x" * 65):
        response = client.get(f"/voice/sessions/{bad_id}", headers=_auth())
        assert response.status_code == 404
        response = client.post(f"/voice/sessions/{bad_id}/close", headers=_auth())
        assert response.status_code == 404
    with client.websocket_connect(
        "/voice/sessions/bad..id/stream", headers=_auth()
    ) as ws:
        with pytest.raises(WebSocketDisconnect) as excinfo:
            ws.receive_json()
        assert excinfo.value.code == 4404
