"""Public preview route: symlink/metadata rejection, allowlisted assets, CSP."""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from mihari_room.app import create_app
from mihari_room.artifacts import ArtifactPublisher
from mihari_room.config import RoomConfig
from mihari_room.contracts import (
    CreateJobRequest,
    JobSource,
    ProgressEvent,
    ProgressKind,
)
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from tests.recording import RecordingBoard, ScriptedWorker

TOKEN = "room-secret"
BASE = "https://preview.example.test"


def _setup(tmp_path: Path):
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    worker = ScriptedWorker([ProgressEvent(kind=ProgressKind.SUMMARY, text="ok")])
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id="owner"), board, worker)
    config = RoomConfig(token=TOKEN, root=tmp_path, owner_id="owner", preview_base_url=BASE)
    orch.attach_publisher(ArtifactPublisher(root=tmp_path, preview_base_url=BASE))
    job = store.create(CreateJobRequest(title="t", body="b", source=JobSource.PET))
    artifact = job.directory / "output" / "artifact"
    artifact.mkdir(parents=True)
    (artifact / "index.html").write_text("<html><body>hi</body></html>", encoding="utf-8")
    publisher = ArtifactPublisher(root=tmp_path, preview_base_url=BASE)
    manifest = publisher.publish(job, "sess-1")
    assert manifest is not None
    token = manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    client = TestClient(create_app(config, orch, start_pump=False))
    return client, token


def test_csp_sandbox_without_same_origin(tmp_path: Path) -> None:
    client, token = _setup(tmp_path)
    response = client.get(f"/previews/{token}/")
    assert response.status_code == 200
    csp = response.headers["content-security-policy"]
    assert "sandbox allow-scripts" in csp
    assert "allow-same-origin" not in csp
    assert "connect-src 'none'" in csp
    assert response.headers["x-content-type-options"] == "nosniff"


def test_symlink_token_dir_rejected(tmp_path: Path) -> None:
    client, token = _setup(tmp_path)
    previews = tmp_path / "previews"
    real = previews / token
    moved = tmp_path / f"moved-{token}"
    real.rename(moved)
    try:
        real.symlink_to(moved, target_is_directory=True)
    except OSError:
        import pytest

        pytest.skip("symlink not permitted")
    try:
        assert client.get(f"/previews/{token}/").status_code == 404
    finally:
        real.unlink()
        moved.rename(real)


def test_dotfiles_and_metadata_paths_rejected(tmp_path: Path) -> None:
    client, token = _setup(tmp_path)
    assert client.get(f"/previews/{token}/.env").status_code == 404
    assert client.get(f"/previews/{token}/../registry/x").status_code == 404
    assert client.get("/previews/..%2Fregistry/x").status_code in (404, 422)


def test_non_allowlisted_extension_not_served_even_if_tampered(tmp_path: Path) -> None:
    client, token = _setup(tmp_path)
    (tmp_path / "previews" / token / "run.php").write_text("<?php", encoding="utf-8")
    assert client.get(f"/previews/{token}/run.php").status_code == 404
    # Tampered symlink inside the token dir is never followed.
    link = tmp_path / "previews" / token / "evil.html"
    try:
        link.symlink_to("/etc/hostname")
    except OSError:
        return
    try:
        assert client.get(f"/previews/{token}/evil.html").status_code == 404
    finally:
        link.unlink()


def test_no_keys_or_private_data_in_public_files(tmp_path: Path) -> None:
    client, token = _setup(tmp_path)
    body = client.get(f"/previews/{token}/").text
    for marker in ("MIHARI_ROOM_TOKEN", "DISCORD_BOT_TOKEN", "claim_url", "BEGIN PRIVATE KEY"):
        assert marker not in body
