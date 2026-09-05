"""Backend memory contract: GET list / POST approve|reject.

Owner-only approval (trusted token owner from server config, never body identity).
"""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from mihari_room.app import create_app
from mihari_room.config import TOKEN_HEADER, RoomConfig
from mihari_room.contracts import CreateJobRequest, JobSource, ProgressEvent, ProgressKind
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from mihari_room.worker.memory import MemoryCandidateStore
from mihari_room.worker.runtime_lock import resolve_hermes_home
from tests.recording import RecordingBoard, ScriptedWorker

TOKEN = "room-secret"


def _make_app(tmp_path: Path, *, owner_id: str = "owner", hermes_home: Path | None = None):
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    worker = ScriptedWorker([ProgressEvent(kind=ProgressKind.SUMMARY, text="ok")])
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id=owner_id), board, worker)
    config = RoomConfig(token=TOKEN, root=tmp_path, owner_id=owner_id)
    app = create_app(config, orch, start_pump=False)
    return TestClient(app), orch, store, config


def _auth() -> dict[str, str]:
    return {TOKEN_HEADER: TOKEN}


def _seed(tmp_path: Path, store: FileJobStore, monkeypatch) -> str:
    monkeypatch.setenv("MIHARI_HERMES_HOME", str(tmp_path / "hermes-home"))
    job = store.create(CreateJobRequest(title="t", body="b", source=JobSource.PET))
    mem = MemoryCandidateStore(tmp_path, tmp_path / "hermes-home")
    candidate = mem.propose(job.id, "memory", "project uses uv")
    return job.id, candidate.id


def test_memory_list_shape(tmp_path: Path, monkeypatch) -> None:
    client, _, store, _ = _make_app(tmp_path)
    job_id, candidate_id = _seed(tmp_path, store, monkeypatch)
    body = client.get(f"/jobs/{job_id}/memory", headers=_auth()).json()
    assert set(body) == {"candidates"}
    assert len(body["candidates"]) == 1
    got = body["candidates"][0]
    assert got["id"] == candidate_id
    assert got["target"] == "MEMORY.md"
    assert got["content"] == "project uses uv"
    assert got["status"] == "pending"
    assert isinstance(got["created_at"], float)


def test_memory_list_requires_token_and_validates_job(tmp_path: Path, monkeypatch) -> None:
    client, _, store, _ = _make_app(tmp_path)
    job_id, _ = _seed(tmp_path, store, monkeypatch)
    assert client.get(f"/jobs/{job_id}/memory").status_code == 401
    assert client.get("/jobs/no-such-job-99/memory", headers=_auth()).status_code == 404
    assert client.get("/jobs/../escape/memory", headers=_auth()).status_code in (404, 422)


def test_approve_persists_and_is_idempotent(tmp_path: Path, monkeypatch) -> None:
    client, _, store, _ = _make_app(tmp_path)
    job_id, candidate_id = _seed(tmp_path, store, monkeypatch)
    first = client.post(f"/jobs/{job_id}/memory/{candidate_id}/approve", headers=_auth())
    assert first.status_code == 200
    assert first.json()["status"] == "approved"
    home = resolve_hermes_home(tmp_path)
    mem_text = (tmp_path / "hermes-home" / "memories" / "MEMORY.md").read_text(encoding="utf-8")
    assert "project uses uv" in mem_text
    assert home == tmp_path / "hermes-home"
    # Idempotent second approve: same status, no duplicate write.
    second = client.post(f"/jobs/{job_id}/memory/{candidate_id}/approve", headers=_auth())
    assert second.status_code == 200
    assert second.json()["status"] == "approved"
    mem_text2 = (tmp_path / "hermes-home" / "memories" / "MEMORY.md").read_text(encoding="utf-8")
    assert mem_text2.count("project uses uv") == 1


def test_reject_never_writes_and_is_idempotent(tmp_path: Path, monkeypatch) -> None:
    client, _, store, _ = _make_app(tmp_path)
    job_id, candidate_id = _seed(tmp_path, store, monkeypatch)
    response = client.post(f"/jobs/{job_id}/memory/{candidate_id}/reject", headers=_auth())
    assert response.status_code == 200
    assert response.json()["status"] == "rejected"
    assert not (tmp_path / "hermes-home" / "memories" / "MEMORY.md").exists()
    again = client.post(f"/jobs/{job_id}/memory/{candidate_id}/reject", headers=_auth())
    assert again.status_code == 200


def test_cross_transition_is_conflict_and_unknown_is_404(tmp_path: Path, monkeypatch) -> None:
    client, _, store, _ = _make_app(tmp_path)
    job_id, candidate_id = _seed(tmp_path, store, monkeypatch)
    client.post(f"/jobs/{job_id}/memory/{candidate_id}/reject", headers=_auth())
    conflict = client.post(f"/jobs/{job_id}/memory/{candidate_id}/approve", headers=_auth())
    assert conflict.status_code == 409
    missing = client.post(f"/jobs/{job_id}/memory/deadbeef1234/approve", headers=_auth())
    assert missing.status_code == 404
    bad_id = client.post(f"/jobs/{job_id}/memory/...../approve", headers=_auth())
    assert bad_id.status_code == 404
    assert client.post(f"/jobs/{job_id}/memory/{candidate_id}/approve").status_code == 401


def test_approve_needs_owner_configured(tmp_path: Path, monkeypatch) -> None:
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    worker = ScriptedWorker([ProgressEvent(kind=ProgressKind.SUMMARY, text="ok")])
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id=None), board, worker)
    config = RoomConfig(token=TOKEN, root=tmp_path, owner_id="")
    client = TestClient(create_app(config, orch, start_pump=False))
    monkeypatch.setenv("MIHARI_HERMES_HOME", str(tmp_path / "hermes-home"))
    job = store.create(CreateJobRequest(title="t", body="b", source=JobSource.PET))
    mem = MemoryCandidateStore(tmp_path, tmp_path / "hermes-home")
    candidate = mem.propose(job.id, "memory", "ownerless fact")
    response = client.post(f"/jobs/{job.id}/memory/{candidate.id}/approve", headers=_auth())
    assert response.status_code == 403
    # Candidate untouched.
    assert mem.list(job.id)[0].status == "pending"
