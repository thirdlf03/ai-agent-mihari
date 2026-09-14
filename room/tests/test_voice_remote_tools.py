"""voice gateway → room 本体へのツール実行委譲の検証。

- ``POST /voice/tools/execute`` / ``DELETE``（room 側の受け口）: 認証・応答形式・
  session 単位 executor のライフサイクル。
- ``RemoteVoiceToolExecutor``（gateway 側）: 応答→VoiceToolOutcome 復元と
  HTTP 失敗時の graceful fail。
- ``MIHARI_ROOM_URL`` 設定時の gateway 配線と WS 経由の統合。
"""

from __future__ import annotations

import asyncio
import base64
import json
import time
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from mihari_room.app import create_app
from mihari_room.config import TOKEN_HEADER, RoomConfig
from mihari_room.contracts import JobStatus
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from mihari_room.voice.protocol import (
    EVENT_ASSISTANT_TOOL_ACTIVITY,
    EVENT_SESSION_READY,
)
from mihari_room.voice.remote_tools import (
    RemoteVoiceToolExecutor,
    remote_tool_executor_factory,
)
from mihari_room.voice.routes import _MAX_TOOL_EXECUTORS
from mihari_room.voice.tools import VoiceToolOutcome
from mihari_room.voice.upstream import FakeRealtimeUpstream
from mihari_room.voice_gateway import create_gateway_app
from tests.recording import RecordingBoard, ScriptedWorker

TOKEN = "room-secret"


def _make_room(tmp_path: Path):
    """room 本体（orchestrator あり）の app と TestClient。"""
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    orch = RoomOrchestrator(
        store, FileJobQueue(store, owner_id="owner"), board, ScriptedWorker([])
    )
    config = RoomConfig(
        token=TOKEN,
        root=tmp_path,
        owner_id="owner",
        openai_api_key="test-openai-key",
    )
    app = create_app(config, orch, start_pump=False)
    return app, TestClient(app), store


def _make_gateway(tmp_path: Path, **kwargs: Any):
    config = RoomConfig(
        token=TOKEN,
        root=tmp_path,
        owner_id="owner",
        openai_api_key="test-openai-key",
    )
    app = create_gateway_app(config, **kwargs)
    return app, TestClient(app)


def _auth() -> dict[str, str]:
    return {TOKEN_HEADER: TOKEN}


def _execute_body(session_id: str, name: str, args: dict[str, Any]) -> dict[str, str]:
    return {
        "session_id": session_id,
        "name": name,
        "arguments": json.dumps(args, ensure_ascii=False),
    }


class _StubExecutor:
    """VoiceToolExecutor と同じ口を持つ差し替えスタブ。"""

    def __init__(self, outcome: VoiceToolOutcome) -> None:
        self.outcome = outcome
        self.calls: list[tuple[str, str]] = []
        self.closed = False

    async def execute(self, name: str, arguments_json: str) -> VoiceToolOutcome:
        self.calls.append((name, arguments_json))
        return self.outcome

    async def close(self) -> None:
        self.closed = True


def _executor_pool(app: Any) -> dict[str, Any]:
    """app.state 上の session_id → executor 表（無ければ作る）。"""
    executors = getattr(app.state, "voice_tool_executors", None)
    if executors is None:
        executors = {}
        app.state.voice_tool_executors = executors
    return executors


# --- room 側エンドポイント -------------------------------------------------


def test_tools_execute_requires_token(tmp_path: Path) -> None:
    _, client, _ = _make_room(tmp_path)
    body = _execute_body("sess-auth0001", "list_running_jobs", {})
    assert client.post("/voice/tools/execute", json=body).status_code == 401
    assert (
        client.post(
            "/voice/tools/execute", json=body, headers={TOKEN_HEADER: "wrong"}
        ).status_code
        == 401
    )
    assert client.delete("/voice/tools/execute/sess-auth0001").status_code == 401


def test_tools_execute_rejects_bad_session_id(tmp_path: Path) -> None:
    _, client, _ = _make_room(tmp_path)
    for bad in ("../escape/dir", "short", "a b c d e f g h"):
        response = client.post(
            "/voice/tools/execute",
            json=_execute_body(bad, "list_running_jobs", {}),
            headers=_auth(),
        )
        assert response.status_code == 400, bad


def test_tools_execute_runs_tool_on_room(tmp_path: Path) -> None:
    _, client, store = _make_room(tmp_path)
    response = client.post(
        "/voice/tools/execute",
        json=_execute_body(
            "sess-exec0001", "submit_job", {"prompt": "レポートを直して"}
        ),
        headers=_auth(),
    )
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert body["client_side"] is False
    assert body["image_base64"] is None
    payload = json.loads(body["output"])
    assert payload["success"] is True
    job = store.get(payload["job_id"])
    assert job.title == "レポートを直して"


def test_tools_execute_image_base64_roundtrip(tmp_path: Path) -> None:
    app, client, _ = _make_room(tmp_path)
    stub = _StubExecutor(
        VoiceToolOutcome(
            output='{"success": true}', image_png=b"\x89PNG-data", ok=True
        )
    )
    _executor_pool(app)["sess-image001"] = stub
    body = client.post(
        "/voice/tools/execute",
        json=_execute_body("sess-image001", "mac_fetch_file", {"path": "/a.png"}),
        headers=_auth(),
    ).json()
    assert body["ok"] is True
    assert base64.b64decode(body["image_base64"]) == b"\x89PNG-data"


def test_tools_execute_reuses_executor_and_delete_closes(tmp_path: Path) -> None:
    app, client, _ = _make_room(tmp_path)
    stub = _StubExecutor(VoiceToolOutcome(output='{"success": true}'))
    _executor_pool(app)["sess-reuse001"] = stub
    body = _execute_body("sess-reuse001", "list_running_jobs", {})
    for _ in range(2):
        response = client.post("/voice/tools/execute", json=body, headers=_auth())
        assert response.status_code == 200
    # 同一 session_id は同じ executor が処理する（Mac run の begin/end 整合）。
    assert stub.calls == [("list_running_jobs", "{}")] * 2

    assert (
        client.delete("/voice/tools/execute/sess-reuse001", headers=_auth()).status_code
        == 200
    )
    assert stub.closed is True
    # 畳んだ後の同じ session_id は新しい executor で受ける。
    assert (
        client.post("/voice/tools/execute", json=body, headers=_auth()).status_code
        == 200
    )
    assert _executor_pool(app)["sess-reuse001"] is not stub
    # DELETE は冪等（無くても closed を返す）。
    assert (
        client.delete("/voice/tools/execute/sess-reuse001", headers=_auth()).status_code
        == 200
    )


def test_tools_execute_evicts_oldest_over_cap(tmp_path: Path) -> None:
    app, client, _ = _make_room(tmp_path)
    stubs: list[_StubExecutor] = []
    for i in range(_MAX_TOOL_EXECUTORS):
        stub = _StubExecutor(VoiceToolOutcome(output='{"success": true}'))
        stubs.append(stub)
        _executor_pool(app)[f"sess-cap{i:05d}"] = stub
    response = client.post(
        "/voice/tools/execute",
        json=_execute_body("sess-cap-new00", "list_running_jobs", {}),
        headers=_auth(),
    )
    assert response.status_code == 200
    assert len(_executor_pool(app)) == _MAX_TOOL_EXECUTORS
    # 最古の executor は close されて表から外れる。
    assert stubs[0].closed is True
    assert "sess-cap00000" not in _executor_pool(app)
    assert stubs[1].closed is False


# --- RemoteVoiceToolExecutor（gateway 側） -----------------------------------


async def test_remote_executor_execute_roundtrip(tmp_path: Path) -> None:
    app, _, store = _make_room(tmp_path)
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://room"
    ) as http:
        executor = RemoteVoiceToolExecutor(
            session_id="sess-remote01",
            room_url="http://room",
            token=TOKEN,
            client=http,
        )
        outcome = await executor.execute(
            "submit_job", json.dumps({"prompt": "おつかい"})
        )
        assert outcome.ok is True
        assert outcome.client_side is False
        assert outcome.image_png is None
        payload = json.loads(outcome.output)
        assert payload["success"] is True
        assert store.get(payload["job_id"]).title == "おつかい"
        # room 側に session executor が乗っている。
        assert "sess-remote01" in _executor_pool(app)


async def test_remote_executor_decodes_image_and_client_side(tmp_path: Path) -> None:
    del tmp_path
    payload = {
        "output": "",
        "ok": True,
        "client_side": True,
        "image_base64": base64.b64encode(b"PNGDATA").decode(),
    }
    transport = httpx.MockTransport(lambda request: httpx.Response(200, json=payload))
    async with httpx.AsyncClient(
        transport=transport, base_url="http://room"
    ) as http:
        executor = RemoteVoiceToolExecutor(
            session_id="sess-remote02",
            room_url="http://room",
            token=TOKEN,
            client=http,
        )
        outcome = await executor.execute("capture_screen", "{}")
        assert outcome.ok is True
        assert outcome.client_side is True
        assert outcome.image_png == b"PNGDATA"


async def test_remote_executor_fails_gracefully_on_http_error() -> None:
    def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    transport = httpx.MockTransport(refuse)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://room"
    ) as http:
        executor = RemoteVoiceToolExecutor(
            session_id="sess-remote03",
            room_url="http://room",
            token=TOKEN,
            client=http,
        )
        outcome = await executor.execute("list_running_jobs", "{}")
        assert outcome.ok is False
        payload = json.loads(outcome.output)
        assert payload["success"] is False
        assert "error" in payload


async def test_remote_executor_wrong_token_is_graceful(tmp_path: Path) -> None:
    app, _, _ = _make_room(tmp_path)
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://room"
    ) as http:
        executor = RemoteVoiceToolExecutor(
            session_id="sess-remote04",
            room_url="http://room",
            token="wrong-token",
            client=http,
        )
        outcome = await executor.execute("list_running_jobs", "{}")
        assert outcome.ok is False
        assert json.loads(outcome.output)["success"] is False
        assert "sess-remote04" not in _executor_pool(app)


async def test_remote_executor_close_calls_delete_once(tmp_path: Path) -> None:
    app, _, _ = _make_room(tmp_path)
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://room"
    ) as http:
        executor = RemoteVoiceToolExecutor(
            session_id="sess-remote05",
            room_url="http://room",
            token=TOKEN,
            client=http,
        )
        await executor.execute("list_running_jobs", "{}")
        assert "sess-remote05" in _executor_pool(app)
        await executor.close()
        assert "sess-remote05" not in _executor_pool(app)
        # close は冪等（2 回目は HTTP を飛ばさない）。
        await executor.close()


async def test_remote_executor_close_failure_is_swallowed() -> None:
    def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    transport = httpx.MockTransport(refuse)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://room"
    ) as http:
        executor = RemoteVoiceToolExecutor(
            session_id="sess-remote06",
            room_url="http://room",
            token=TOKEN,
            client=http,
        )
        await executor.close()  # 例外を上げない


# --- 配線 -----------------------------------------------------------------


def test_gateway_app_uses_remote_factory_with_room_url(tmp_path: Path) -> None:
    app, _ = _make_gateway(tmp_path, room_url="http://room")
    factory = getattr(app.state, "voice_tool_executor_factory", None)
    assert factory is not None
    executor = factory("sess-gw000001")
    assert isinstance(executor, RemoteVoiceToolExecutor)
    asyncio.run(executor.close())  # DELETE は ConnectError で握りつぶされ、client だけ畳む


def test_gateway_app_reads_room_url_from_env(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("MIHARI_ROOM_URL", "http://room")
    app, _ = _make_gateway(tmp_path)
    assert getattr(app.state, "voice_tool_executor_factory", None) is not None


def test_gateway_app_without_room_url_keeps_default(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("MIHARI_ROOM_URL", raising=False)
    app, _ = _make_gateway(tmp_path)
    assert getattr(app.state, "voice_tool_executor_factory", None) is None


def _disconnect_and_idle(ws: Any, client: TestClient, session_id: str) -> None:
    """WS を明示的に切り、ハンドラの後始末（executor close 含む）が終わるまで待つ。"""
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


def test_gateway_stream_delegates_tool_to_room(tmp_path: Path) -> None:
    """gateway の WS ストリームで upstream の function_call が room へ委譲される。"""
    room_app, _, _ = _make_room(tmp_path / "room")
    (tmp_path / "gw").mkdir()
    gateway_app, gateway_client = _make_gateway(
        tmp_path / "gw", room_url="http://room"
    )
    fake = FakeRealtimeUpstream()
    gateway_app.state.voice_upstream_factory = lambda: fake
    # テスト内では room への HTTP を ASGI transport に差し替える。
    http = httpx.AsyncClient(
        transport=httpx.ASGITransport(app=room_app), base_url="http://room"
    )
    gateway_app.state.voice_tool_executor_factory = remote_tool_executor_factory(
        room_url="http://room", token=TOKEN, client=http
    )
    session_id = gateway_client.post("/voice/sessions", headers=_auth()).json()[
        "session_id"
    ]
    tool_audio = base64.b64encode(b"tool:list_running_jobs").decode()
    with gateway_client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": tool_audio})
        activity = None
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY:
                activity = frame
                break
        assert activity is not None
        assert activity["name"] == "list_running_jobs"
        assert activity["status"] == "done"
        # room 側で session executor が生きている。
        assert session_id in _executor_pool(room_app)
        _disconnect_and_idle(ws, gateway_client, session_id)
    # stream 終了で remote close → room 側の executor も畳まれる。
    assert session_id not in _executor_pool(room_app)
    asyncio.run(http.aclose())
    # fco（function_call_output）が upstream へ積まれている。
    fco = [
        e
        for e in fake.sent_events()
        if e.get("type") == "conversation.item.create"
        and (e.get("item") or {}).get("type") == "function_call_output"
    ]
    assert len(fco) == 1
    assert json.loads(fco[0]["item"]["output"])["success"] is True


async def test_remote_executor_finished_jobs_polls_room(tmp_path: Path) -> None:
    """RemoteVoiceToolExecutor.finished_jobs は GET /jobs/{id} で終端を拾う。

    gateway には job store が無いため room の HTTP API をポーリングする。
    終端に達した job は追跡から外れ、2 回目は空を返す。
    """
    room_app, _, store = _make_room(tmp_path / "room")
    transport = httpx.ASGITransport(app=room_app)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://room"
    ) as http:
        executor = RemoteVoiceToolExecutor(
            session_id="sess-remote-job",
            room_url="http://room",
            token=TOKEN,
            client=http,
        )
        outcome = await executor.execute(
            "submit_job", json.dumps({"prompt": "おつかい", "title": "レポート"})
        )
        payload = json.loads(outcome.output)
        assert payload["success"] is True
        job_id = payload["job_id"]
        # 実行中は空。
        assert await executor.finished_jobs() == []
        # room 側で終端にする。
        store.set_status(job_id, JobStatus.DONE)
        results = await executor.finished_jobs()
        assert len(results) == 1
        assert results[0]["job_id"] == job_id
        assert results[0]["status"] == "done"
        assert results[0]["title"] == "レポート"
        # 2 回目は空（追跡から外れる）。
        assert await executor.finished_jobs() == []
        await executor.close()


def test_room_stream_ignores_factory_when_orchestrator_present(tmp_path: Path) -> None:
    """room 本体では orchestrator が居るため factory よりローカル実行器が優先。"""
    room_app, client, _ = _make_room(tmp_path)
    fake = FakeRealtimeUpstream()
    room_app.state.voice_upstream_factory = lambda: fake

    made: list[str] = []

    def factory(session_id: str) -> _StubExecutor:
        made.append(session_id)
        return _StubExecutor(VoiceToolOutcome(output='{"success": false}'))

    room_app.state.voice_tool_executor_factory = factory
    session_id = client.post("/voice/sessions", headers=_auth()).json()["session_id"]
    tool_audio = base64.b64encode(b"tool:list_running_jobs").decode()
    with client.websocket_connect(
        f"/voice/sessions/{session_id}/stream", headers=_auth()
    ) as ws:
        assert ws.receive_json()["type"] == EVENT_SESSION_READY
        ws.send_json({"type": "input.audio", "audio_base64": tool_audio})
        for _ in range(10):
            frame = ws.receive_json()
            if frame["type"] == EVENT_ASSISTANT_TOOL_ACTIVITY:
                assert frame["status"] == "done"
                break
        _disconnect_and_idle(ws, client, session_id)
    # factory は呼ばれず、room 内蔵の VoiceToolExecutor が成功を返した。
    assert made == []
    fco = [
        e
        for e in fake.sent_events()
        if e.get("type") == "conversation.item.create"
        and (e.get("item") or {}).get("type") == "function_call_output"
    ]
    assert json.loads(fco[0]["item"]["output"])["success"] is True
