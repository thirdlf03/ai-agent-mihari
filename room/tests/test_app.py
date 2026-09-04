"""ペットの POST /jobs が部屋の契約どおり届くこと。"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from mihari_room.app import create_app
from mihari_room.config import TOKEN_HEADER, RoomConfig
from mihari_room.contracts import JobStatus, ProgressEvent, ProgressKind
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from tests.recording import RecordingBoard, ScriptedWorker

TOKEN = "room-secret"


def _client(tmp_path: Path) -> TestClient:
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    worker = ScriptedWorker([ProgressEvent(kind=ProgressKind.SUMMARY, text="やった")])
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id="owner"), board, worker)
    config = RoomConfig(token=TOKEN, root=tmp_path, owner_id="owner")
    # ポンプを動かさない。速い Worker だと応答前に DONE へ進んでフレークする。
    app = create_app(config, orch, start_pump=False)
    return TestClient(app)


def test_health_needs_no_token(tmp_path: Path) -> None:
    body = _client(tmp_path).get("/health").json()
    assert body["status"] == "ok"


def test_post_jobs_requires_token(tmp_path: Path) -> None:
    response = _client(tmp_path).post("/jobs", json={"title": "掃除", "body": "頼む"})
    assert response.status_code == 401


def test_post_jobs_returns_queued_job(tmp_path: Path) -> None:
    client = _client(tmp_path)
    response = client.post(
        "/jobs",
        json={"title": "掃除", "body": "部屋を片付けて", "source": "pet"},
        headers={TOKEN_HEADER: TOKEN},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == JobStatus.QUEUED.value
    assert body["job_id"]
    assert body["thread_id"] == 1001


def test_empty_title_uses_first_line(tmp_path: Path) -> None:
    client = _client(tmp_path)
    response = client.post(
        "/jobs",
        json={"title": "  ", "body": "先頭が題\n二行目", "source": "pet"},
        headers={TOKEN_HEADER: TOKEN},
    )
    assert response.status_code == 200
    # スレッド作成時の題は store 側。id から読む。
    job_id = response.json()["job_id"]
    store = FileJobStore(tmp_path)
    assert store.get(job_id).title == "先頭が題"


def test_owner_can_cancel_without_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("MIHARI_OWNER_ID", raising=False)
    client = _client(tmp_path)
    created = client.post(
        "/jobs",
        json={"title": "掃除", "body": "頼む", "source": "pet"},
        headers={TOKEN_HEADER: TOKEN},
    )
    job_id = created.json()["job_id"]
    response = client.post(
        f"/jobs/{job_id}/cancel",
        json={},
        headers={TOKEN_HEADER: TOKEN},
    )
    assert response.status_code == 200
    assert response.json()["status"] == JobStatus.CANCELLED.value
