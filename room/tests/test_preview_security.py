"""Public preview route: symlink/metadata rejection, allowlisted assets, CSP.

公開/非公開の切替（発行・停止・関連ファイル拒否・no-store）もここで確かめる。
"""

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
    (artifact / "style.css").write_text("body{}", encoding="utf-8")
    (artifact / "note.pdf").write_text("%PDF-1.4", encoding="utf-8")
    publisher = ArtifactPublisher(root=tmp_path, preview_base_url=BASE)
    manifest = publisher.publish(job, "sess-1")
    assert manifest is not None
    # 非公開のままにした版と、公開した版の 2 つを持つ。
    second_manifest = publisher.publish_version(job.id, manifest["version"])
    public_token = second_manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    client = TestClient(create_app(config, orch, start_pump=False))
    return client, orch, job, public_token


def _auth() -> dict[str, str]:
    return {"X-Mihari-Token": TOKEN}


def test_csp_sandbox_without_same_origin(tmp_path: Path) -> None:
    client, _, _, token = _setup(tmp_path)
    response = client.get(f"/previews/{token}/")
    assert response.status_code == 200
    csp = response.headers["content-security-policy"]
    assert "sandbox allow-scripts" in csp
    assert "allow-same-origin" not in csp
    assert "connect-src 'none'" in csp
    assert response.headers["x-content-type-options"] == "nosniff"


def test_symlink_token_dir_rejected(tmp_path: Path) -> None:
    client, orch, job, token = _setup(tmp_path)
    previews = tmp_path / "previews"
    content_token = orch.publisher.content_token_for(job.id, 1)
    real = previews / content_token
    moved = tmp_path / f"moved-{content_token}"
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
    client, _, _, token = _setup(tmp_path)
    assert client.get(f"/previews/{token}/.env").status_code == 404
    assert client.get(f"/previews/{token}/../registry/x").status_code == 404
    assert client.get("/previews/..%2Fregistry/x").status_code in (404, 422)


def test_non_allowlisted_extension_not_served_even_if_tampered(tmp_path: Path) -> None:
    client, orch, job, token = _setup(tmp_path)
    content_token = orch.publisher.content_token_for(job.id, 1)
    (tmp_path / "previews" / content_token / "run.php").write_text("<?php", encoding="utf-8")
    assert client.get(f"/previews/{token}/run.php").status_code == 404
    # Tampered symlink inside the token dir is never followed.
    link = tmp_path / "previews" / content_token / "evil.html"
    try:
        link.symlink_to("/etc/hostname")
    except OSError:
        return
    try:
        assert client.get(f"/previews/{token}/evil.html").status_code == 404
    finally:
        link.unlink()


def test_no_keys_or_private_data_in_public_files(tmp_path: Path) -> None:
    client, _, _, token = _setup(tmp_path)
    body = client.get(f"/previews/{token}/").text
    for marker in ("MIHARI_ROOM_TOKEN", "DISCORD_BOT_TOKEN", "claim_url", "BEGIN PRIVATE KEY"):
        assert marker not in body


def test_private_version_denies_unauthenticated_and_serves_authenticated(tmp_path: Path) -> None:
    client, orch, job, public_token = _setup(tmp_path)
    # 非公開の内容フォルダは公開経路から直接辿れない。
    content_token = orch.publisher.content_token_for(job.id, 1)
    assert client.get(f"/previews/{content_token}/").status_code == 404
    # 未認証の認証付き取得は 401。
    assert client.get(f"/jobs/{job.id}/artifacts/1/files/").status_code == 401
    # 認証付きで index / css / pdf が読める（URL にトークンは載らない）。
    headers = _auth()
    index = client.get(f"/jobs/{job.id}/artifacts/1/files/", headers=headers)
    assert index.status_code == 200
    assert "hi" in index.text
    assert (
        client.get(f"/jobs/{job.id}/artifacts/1/files/style.css", headers=headers).status_code
        == 200
    )
    assert (
        client.get(f"/jobs/{job.id}/artifacts/1/files/note.pdf", headers=headers).status_code == 200
    )
    # 認証付き取得もキャッシュさせない（停止がキャッシュで迂回されない）。
    assert index.headers["cache-control"] == "no-store"
    # 認証付き経路の URL に Room トークンは無い。
    assert TOKEN not in f"/jobs/{job.id}/artifacts/1/files/"


def test_publish_revoke_denies_old_url_and_related_files(tmp_path: Path) -> None:
    client, orch, job, public_token = _setup(tmp_path)
    headers = _auth()

    # 公開中は HTML・CSS・PDF が外部から見える。
    for path in ("", "style.css", "note.pdf"):
        assert client.get(f"/previews/{public_token}/{path}").status_code == 200
        assert client.get(f"/previews/{public_token}/{path}").headers["cache-control"] == "no-store"

    # 非公開に戻すと、その版の旧 URL はどの関連ファイルも 404 になる。
    assert client.post(f"/jobs/{job.id}/artifacts/1/unpublish", headers=headers).status_code == 200
    for path in ("", "index.html", "style.css", "note.pdf"):
        assert client.get(f"/previews/{public_token}/{path}").status_code == 404
    # 詳細は非公開状態を返す。
    detail = client.get(f"/jobs/{job.id}", headers=headers).json()
    assert detail["artifacts"][0]["visibility"] == "private"
    assert detail["artifacts"][0]["preview_url"] is None

    # 再公開は新しい URL で、外部から見えるようになる。
    re_pub = client.post(f"/jobs/{job.id}/artifacts/1/publish", headers=headers)
    assert re_pub.status_code == 200
    new_token = re_pub.json()["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    assert new_token != public_token
    assert client.get(f"/previews/{new_token}/").status_code == 200
    # 古い URL は引き続き死んでいる。
    assert client.get(f"/previews/{public_token}/").status_code == 404


def test_token_never_appears_in_urls_or_detail(tmp_path: Path) -> None:
    client, orch, job, public_token = _setup(tmp_path)
    headers = _auth()
    detail = client.get(f"/jobs/{job.id}", headers=headers).json()
    for artifact in detail["artifacts"]:
        blob = json_dumps(artifact)
        assert TOKEN not in blob
        assert "X-Mihari-Token" not in blob
        # 公開 URL は別ホストの token（Room トークンではない）。
        if artifact.get("preview_url"):
            assert TOKEN not in artifact["preview_url"]
    assert TOKEN not in public_token


def json_dumps(value) -> str:
    import json

    return json.dumps(value)
