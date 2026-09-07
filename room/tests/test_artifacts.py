"""成果物の公開（プレビュー）と、バージョン・公開/非公開・安全除外。"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from mihari_room.artifacts import (
    VISIBILITY_PRIVATE,
    VISIBILITY_PUBLIC,
    ArtifactPublisher,
    read_publication,
)
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


def _content_dir(publisher: ArtifactPublisher, job_id: str, version: int) -> Path:
    token = publisher.content_token_for(job_id, version)
    return publisher._previews_root / token


def test_publish_disabled_without_base_url(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    _write_artifact(job)
    publisher = ArtifactPublisher(tmp_path, preview_base_url="")
    assert publisher.enabled is False
    assert publisher.publish(job) is None


def test_publish_creates_immutable_private_version(tmp_path: Path) -> None:
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
        "visibility",
        "view_url",
        "expires_at",
        "sha256",
        "source_ids",
        "documents",
    }
    assert manifest["documents"] == []
    assert manifest["job_id"] == job.id
    assert manifest["session_id"] == "sess-1"
    assert manifest["version"] == 1
    assert manifest["kind"] == "web"
    assert manifest["expires_at"] is None
    assert manifest["sha256"]  # 16 進 64 桁
    assert len(manifest["sha256"]) == 64
    assert manifest["source_ids"] == ["memo.txt"]
    # 新しくできた版は非公開。共有 URL は出さない。
    assert manifest["visibility"] == VISIBILITY_PRIVATE
    assert manifest["preview_url"] is None
    # 認証付きの取得経路（URL にトークンは載らない）だけがある。
    assert manifest["view_url"] == f"/jobs/{job.id}/artifacts/1/files/"

    # ランダム token の内容フォルダに、index と css だけが写る。
    preview_dir = _content_dir(publisher, job.id, 1)
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
    # 内容フォルダはバージョンごとに別。
    assert publisher.content_token_for(job.id, 1) != publisher.content_token_for(job.id, 2)
    # 前のバージョンは不変のまま残る。
    assert (
        publisher._previews_root / publisher.content_token_for(job.id, 1) / "index.html"
    ).is_file()

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
    # 旧レコードは公開状態として読み出し時に正規化される。
    assert [m["visibility"] for m in manifests] == [VISIBILITY_PUBLIC, VISIBILITY_PUBLIC]
    assert manifests[0]["preview_url"] == f"{BASE}/aaa/"


def test_rollback_republishes_old_files_as_new_private_version(tmp_path: Path) -> None:
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
    assert rolled["sha256"] == first["sha256"]
    # 新しい版は公開状態を引き継がない（非公開で始まる）。
    assert rolled["visibility"] == VISIBILITY_PRIVATE
    assert rolled["preview_url"] is None

    old_token = publisher.content_token_for(job.id, 1)
    new_token = publisher.content_token_for(job.id, 3)
    assert old_token != new_token
    assert (publisher._previews_root / old_token / "index.html").is_file()
    assert (publisher._previews_root / new_token / "index.html").read_text(
        encoding="utf-8"
    ) == "<h1>v1</h1>"
    assert (publisher._previews_root / new_token / "style.css").is_file()
    assert [m["version"] for m in publisher.manifests_for(job.id)] == [1, 2, 3]


def test_rollback_unknown_version(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    _write_artifact(job)
    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    publisher.publish(job)
    with pytest.raises(LookupError):
        publisher.rollback(job, 9)


def test_publish_and_unpublish_issues_and_revokes_share_url(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    _write_artifact(job)
    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    manifest = publisher.publish(job)
    assert manifest is not None

    # 公開すると共有 URL を発行する。
    published = publisher.publish_version(job.id, 1)
    assert published["visibility"] == VISIBILITY_PUBLIC
    assert published["preview_url"].startswith(BASE + "/")
    first_token = published["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    assert read_publication(tmp_path, first_token) is not None

    # 二重公開は拒否。
    with pytest.raises(ValueError):
        publisher.publish_version(job.id, 1)

    # 非公開に戻すと発行済み URL は無効になる。
    private = publisher.unpublish_version(job.id, 1)
    assert private["visibility"] == VISIBILITY_PRIVATE
    assert private["preview_url"] is None
    assert read_publication(tmp_path, first_token) is None

    # 再公開は新しい URL（同じ token は使わない）。
    republished = publisher.publish_version(job.id, 1)
    second_token = republished["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    assert second_token != first_token
    assert read_publication(tmp_path, second_token) is not None


def test_new_version_does_not_inherit_public_state(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    _write_artifact(job, index="<h1>v1</h1>")
    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    publisher.publish(job)
    publisher.publish_version(job.id, 1)  # v1 を公開

    _write_artifact(job, index="<h1>v2</h1>")
    v2 = publisher.publish(job)
    assert v2 is not None
    # 新しい版は公開状態を引き継がない。
    assert v2["visibility"] == VISIBILITY_PRIVATE
    assert v2["preview_url"] is None


def test_migrate_treats_legacy_as_public_and_can_revoke(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    registry = tmp_path / "registry"
    registry.mkdir()
    legacy_url = f"{BASE}/aaabbb/"
    (registry / f"{job.id}.json").write_text(
        json.dumps(
            {
                "artifact_id": f"art-{job.id}",
                "versions": [
                    {"id": f"art-{job.id}", "version": 1, "preview_url": legacy_url},
                ],
            }
        ),
        encoding="utf-8",
    )
    # 移行時に内容フォルダが在る想定（旧 token のまま公開済みとして動く）。
    (tmp_path / "previews" / "aaabbb").mkdir(parents=True)
    (tmp_path / "previews" / "aaabbb" / "index.html").write_text(
        "<h1>legacy</h1>", encoding="utf-8"
    )

    assert publisher.migrate() >= 1
    manifests = publisher.manifests_for(job.id)
    assert manifests[0]["visibility"] == VISIBILITY_PUBLIC
    assert manifests[0]["preview_url"] == legacy_url
    # 旧 token が publications 表に載り、公開 URL として解決できる。
    assert read_publication(tmp_path, "aaabbb") is not None

    # UI から停止できる（旧 URL を無効化）。
    private = publisher.unpublish_version(job.id, 1)
    assert private["visibility"] == VISIBILITY_PRIVATE
    assert read_publication(tmp_path, "aaabbb") is None


def test_restore_copies_selected_version_work_files(tmp_path: Path) -> None:
    _store, job = _make_job(tmp_path)
    _write_artifact(job, index="<h1>v1</h1>", extra={"style.css": "body{}"})
    publisher = ArtifactPublisher(tmp_path, preview_base_url=BASE)
    publisher.publish(job)
    _write_artifact(job, index="<h1>v2</h1>", extra={"app.js": "console.log(2)"})
    publisher.publish(job)

    # 古い版の作業ファイルを作業フォルダへ復元する。
    restored = publisher.restore(job, 1)
    assert restored == 2
    artifact = job.directory / "output" / "artifact"
    assert (artifact / "index.html").read_text(encoding="utf-8") == "<h1>v1</h1>"
    assert (artifact / "style.css").read_text(encoding="utf-8") == "body{}"
    # v2 で増えた app.js は復元で消える（その版の内容に一致する）。
    assert not (artifact / "app.js").exists()

    with pytest.raises(LookupError):
        publisher.restore(job, 99)


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
    preview_dir = _content_dir(publisher, job.id, manifest["version"])

    names = {p.name for p in preview_dir.iterdir()}
    assert "index.html" in names
    assert "ok.png" in names
    # 秘密・非 web アセット・シンボリックリンクは写らない。
    for banned in ("secret.txt", ".env", "claim_url", "script.py", "leak.txt"):
        assert banned not in names
    # Markdown は文書として版に載る（プレビュー直下＝ web アセットと同じ位置）。
    assert {doc["name"] for doc in manifest["documents"]} == {"notes.md"}
    assert (preview_dir / "notes.md").is_file()


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
