"""成果物の公開（プレビュー）と、バージョン・安全除外。"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from mihari_room.artifacts import ArtifactPublisher
from mihari_room.contracts import CreateJobRequest, JobSource
from mihari_room.store.file_store import FileJobStore

BASE = "https://preview.example.com/previews"


def _make_job(tmp_path: Path) -> tuple[FileJobStore, object]:
    store = FileJobStore(tmp_path)
    job = store.create(CreateJobRequest(title="プレビュー", body="作って", source=JobSource.PET))
    return store, job


def _write_artifact(job, index: str = "<h1>hi</h1>", extra: dict[str, str] | None = None) -> Path:
    artifact = job.directory / "output" / "artifact"
    artifact.mkdir(parents=True, exist_ok=True)
    (artifact / "index.html").write_text(index, encoding="utf-8")
    for name, content in (extra or {}).items():
        (artifact / name).write_text(content, encoding="utf-8")
    return artifact


def test_publish_disabled_without_base_url(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    _write_artifact(job)
    publisher = ArtifactPublisher(tmp_path, preview_base_url="")
    assert publisher.enabled is False
    assert publisher.publish(job) is None


def test_publish_creates_immutable_version(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    (job.directory / "input" / "memo.txt").write_text("つくる", encoding="utf-8")
    _write_artifact(job, extra={"style.css": "body{}"})

    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    manifest = publisher.publish(job, session_id="sess-1")
    assert manifest is not None

    assert set(manifest) == {
        "id",
        "job_id",
        "session_id",
        "version",
        "kind",
        "preview_url",
        "expires_at",
        "sha256",
        "source_ids",
    }
    assert manifest["job_id"] == job.id
    assert manifest["session_id"] == "sess-1"
    assert manifest["version"] == 1
    assert manifest["kind"] == "web"
    assert manifest["expires_at"] is None
    assert manifest["sha256"]  # 16 進 64 桁
    assert len(manifest["sha256"]) == 64
    assert manifest["source_ids"] == ["memo.txt"]
    assert manifest["preview_url"].startswith(BASE + "/")
    assert manifest["preview_url"].endswith("/")

    # ランダム token のフォルダに、index と css だけが写る。
    token = manifest["preview_url"].rsplit("/", 2)[-2]
    preview_dir = tmp_path / "previews" / token
    assert (preview_dir / "index.html").is_file()
    assert (preview_dir / "style.css").is_file()
    assert manifest["id"] == f"art-{job.id}-v1"


def test_versions_increment_with_unique_ids(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    _write_artifact(job, index="<h1>v1</h1>")
    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)

    first = publisher.publish(job)
    second = publisher.publish(job)  # 続きでまた成功した想定
    assert first is not None and second is not None
    assert first["id"] == f"art-{job.id}-v1"
    assert second["id"] == f"art-{job.id}-v2"
    assert first["id"] != second["id"]
    assert first["version"] == 1
    assert second["version"] == 2
    assert first["preview_url"] != second["preview_url"]
    # 前のバージョンは不変のまま残る。
    old_token = first["preview_url"].rsplit("/", 2)[-2]
    assert (tmp_path / "previews" / old_token / "index.html").is_file()

    manifests = publisher.manifests_for(job.id)
    assert [m["version"] for m in manifests] == [1, 2]
    assert [m["id"] for m in manifests] == [f"art-{job.id}-v1", f"art-{job.id}-v2"]


def test_old_registry_ids_are_unique_on_read(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    registry = tmp_path / "registry"
    registry.mkdir()
    (registry / f"{job.id}.json").write_text(
        json.dumps(
            {
                "artifact_id": f"art-{job.id}",
                "versions": [
                    {"id": f"art-{job.id}", "version": 1, "preview_url": f"{BASE}/aaa/"},
                    {"id": f"art-{job.id}", "version": 2, "preview_url": f"{BASE}/bbb/"},
                ],
            }
        ),
        encoding="utf-8",
    )
    manifests = publisher.manifests_for(job.id)
    assert [m["id"] for m in manifests] == [f"art-{job.id}-v1", f"art-{job.id}-v2"]


def test_rollback_republishes_old_files_as_new_token(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    _write_artifact(job, index="<h1>v1</h1>", extra={"style.css": "body{}"})
    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    first = publisher.publish(job)
    assert first is not None
    _write_artifact(job, index="<h1>v2</h1>")
    second = publisher.publish(job)
    assert second is not None

    rolled = publisher.rollback(job, 1)
    assert rolled["version"] == 3
    assert rolled["id"] == f"art-{job.id}-v3"
    assert rolled["preview_url"] != first["preview_url"]
    assert rolled["sha256"] == first["sha256"]

    old_token = first["preview_url"].rsplit("/", 2)[-2]
    new_token = rolled["preview_url"].rsplit("/", 2)[-2]
    assert (tmp_path / "previews" / old_token / "index.html").is_file()
    assert (tmp_path / "previews" / new_token / "index.html").read_text(
        encoding="utf-8"
    ) == "<h1>v1</h1>"
    assert (tmp_path / "previews" / new_token / "style.css").is_file()
    assert [m["version"] for m in publisher.manifests_for(job.id)] == [1, 2, 3]


def test_rollback_unknown_version(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    _write_artifact(job)
    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    publisher.publish(job)
    with pytest.raises(LookupError):
        publisher.rollback(job, 9)


def test_excludes_secrets_symlinks_and_nonweb(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    artifact = _write_artifact(
        job,
        extra={
            "secret.txt": "hunter2",
            ".env": "TOKEN=x",
            "claim_url": "https://host/uploaded",
            "script.py": "print(1)",
            "notes.md": "## memo",
            "ok.png": b"\x89PNG\r\n\x1a\n".decode("latin1"),
        },
    )
    # 外を向くシンボリックリンク（写してはいけない）。
    outside = tmp_path / "outside.txt"
    outside.write_text("secret", encoding="utf-8")
    (artifact / "leak.txt").symlink_to(outside)

    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    manifest = publisher.publish(job)
    assert manifest is not None
    token = manifest["preview_url"].rsplit("/", 2)[-2]
    preview_dir = tmp_path / "previews" / token

    names = {p.name for p in preview_dir.iterdir()}
    assert "index.html" in names
    assert "ok.png" in names
    # 秘密・非 web アセット・シンボリックリンクは写らない。
    for banned in ("secret.txt", ".env", "claim_url", "script.py", "notes.md", "leak.txt"):
        assert banned not in names


def test_publish_skips_when_no_index(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    (job.directory / "output" / "artifact").mkdir(parents=True, exist_ok=True)
    (job.directory / "output" / "artifact" / "page.html").write_text("x", encoding="utf-8")
    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    assert publisher.publish(job) is None


def test_traversal_components_rejected(tmp_path: Path) -> None:
    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    dest = tmp_path / "previews" / "tok"
    with pytest.raises(ValueError):
        publisher._copy_file(tmp_path / "art", ["..", "evil"], dest)
    with pytest.raises(ValueError):
        publisher._copy_file(tmp_path / "art", ["sub", "..", "evil"], dest)
