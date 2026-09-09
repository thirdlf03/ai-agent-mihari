"""OpenAI Realtime voice セッション（§5-1 / §5-2）の room 側検証。"""

from __future__ import annotations

import base64
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from mihari_room.app import create_app
from mihari_room.config import TOKEN_HEADER, RoomConfig
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from mihari_room.voice.protocol import (
    EVENT_ASSISTANT_TEXT,
    EVENT_ASSISTANT_TOOL_CALL,
    EVENT_HISTORY_SYNC,
    EVENT_SESSION_READY,
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
    detail = client.get(f"/voice/sessions/{session_id}", headers=_auth()).json()
    assert detail["upstream_audio_output_events"] == 0


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
    history = client.get(f"/voice/sessions/{session_id}/history", headers=_auth()).json()
    assert history["session_id"] == session_id
    user_messages = [message for message in history["messages"] if message["role"] == "user"]
    assert len(user_messages) == 1
    assert user_messages[0]["kind"] == "image_prompt"
    assert user_messages[0]["text"] == "look here"
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
    reloaded = _make_app(tmp_path, upstream_factory=lambda: fake)
    history = reloaded.get(f"/voice/sessions/{session_id}/history", headers=_auth()).json()
    assert any(message.get("text") == "persist me" for message in history["messages"])
    detail = reloaded.get(f"/voice/sessions/{session_id}", headers=_auth()).json()
    assert detail["status"] == "created"
