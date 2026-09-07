"""文書（Markdown / PDF）成果物の公開・プレビュー・ダウンロード。

受け入れに対応する検証:

- HTML・Markdown・PDF を成果物一覧（``documents``）に載せる
- プレビュー・ダウンロードは既存の preview 許可（token 経路）に乗せる
- 未公開（別 token・token 無し）文書の閲覧・ダウンロードは拒否
- Markdown のプレビューは同梱 markdown-it 表示（生 HTML 無効・CDN なし）
- research/ ・秘密名の文書は成果物に載せない
"""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from mihari_room.app import create_app
from mihari_room.artifacts import ArtifactPublisher
from mihari_room.config import RoomConfig
from mihari_room.contracts import CreateJobRequest, JobSource, ProgressEvent, ProgressKind
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from tests.recording import RecordingBoard, ScriptedWorker

TOKEN = "room-secret"
BASE = "https://preview.example.test"

MARKDOWN = """# 資料タイトル

日本語の段落。

| 項目 | 説明 |
|---|---|
| 抽出 | pypdf |

```python
print("ok")
```

<script>alert(1)</script>
"""


def _make_job(tmp_path: Path) -> object:
    store = FileJobStore(tmp_path)
    return store.create(CreateJobRequest(title="文書", body="作って", source=JobSource.PET))


def _job_dir(job: object) -> Path:
    return Path(job.directory)


def _client(tmp_path: Path) -> tuple[TestClient, object]:
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    worker = ScriptedWorker([ProgressEvent(kind=ProgressKind.SUMMARY, text="ok")])
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id="owner"), board, worker)
    config = RoomConfig(token=TOKEN, root=tmp_path, owner_id="owner", preview_base_url=BASE)
    orch.attach_publisher(ArtifactPublisher(root=tmp_path, preview_base_url=BASE))
    client = TestClient(create_app(config, orch, start_pump=False))
    return client, orch


def _write_docs(job: object, *, web: bool = True, docs: dict[str, str] | None = None) -> Path:
    directory = _job_dir(job)
    artifact = directory / "output" / "artifact"
    artifact.mkdir(parents=True, exist_ok=True)
    if web:
        (artifact / "index.html").write_text("<h1>web</h1>", encoding="utf-8")
    output = directory / "output"
    for name, content in (docs or {}).items():
        (output / name).write_bytes(content if isinstance(content, bytes) else content.encode())
    return output


def _publish(job: object, tmp_path: Path) -> dict:
    publisher = ArtifactPublisher(root=tmp_path, preview_base_url=BASE)
    manifest = publisher.publish(job, session_id="sess-1")
    assert manifest is not None
    return manifest


def test_publish_lists_markdown_and_pdf_documents(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    _write_docs(job, docs={"report.md": MARKDOWN, "report.pdf": b"%PDF-1.4"})
    manifest = _publish(job, tmp_path)

    documents = manifest["documents"]
    assert [doc["kind"] for doc in documents] == ["markdown", "pdf"]
    names = {doc["name"] for doc in documents}
    assert names == {"report.md", "report.pdf"}
    md = next(doc for doc in documents if doc["kind"] == "markdown")
    assert (
        md["preview_url"]
        == BASE + "/" + manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1] + "/report.md.html"
    )
    assert md["download_url"].endswith("/report.md")
    pdf = next(doc for doc in documents if doc["kind"] == "pdf")
    assert pdf["preview_url"].endswith("/report.pdf")
    assert pdf["download_url"].endswith("/report.pdf")

    token = manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    preview_dir = tmp_path / "previews" / token
    assert (preview_dir / "report.md").is_file()
    assert (preview_dir / "report.md.html").is_file()
    assert (preview_dir / "report.pdf").is_file()
    assert (preview_dir / "index.html").is_file()  # web 版は従来どおり


def test_doc_only_publish_creates_listing_page(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    _write_docs(job, web=False, docs={"報告書.md": "# 報告\n\n本文\n"})
    manifest = _publish(job, tmp_path)
    assert manifest["documents"][0]["kind"] == "markdown"
    token = manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    listing = (tmp_path / "previews" / token / "index.html").read_text(encoding="utf-8")
    assert "報告書.md.html" in listing
    assert "ダウンロード" in listing
    assert "<script" not in listing


def test_markdown_preview_renders_and_escapes_raw_html(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    _write_docs(job, docs={"report.md": MARKDOWN})
    manifest = _publish(job, tmp_path)
    token = manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    preview = (tmp_path / "previews" / token / "report.md.html").read_text(encoding="utf-8")
    assert "<table>" in preview and "項目" in preview
    assert "print(" in preview
    assert "<script>alert" not in preview
    assert "&lt;script&gt;" in preview
    assert "cdn" not in preview.lower()


def test_unpublished_documents_require_preview_token(tmp_path: Path) -> None:
    """既存プレビュー許可（token 経路）に乗せる。token 無し・別 token は 404。"""
    client, orch = _client(tmp_path)
    job = _make_job(tmp_path)
    _write_docs(job, docs={"report.md": "# 秘密\n", "report.pdf": b"%PDF-1.4"})
    manifest = _publish(job, tmp_path)
    token = manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]

    assert client.get("/previews/" + token + "/report.md").status_code == 200
    assert client.get("/previews/" + token + "/report.md.html").status_code == 200
    assert client.get("/previews/" + token + "/report.pdf").status_code == 200
    # token が無い・でたらめな token → 未公開扱いで拒否。
    assert client.get("/previews/nope/report.md").status_code == 404
    assert client.get("/previews//report.md").status_code == 404
    # 別ジョブの token からは読めない。
    other = _make_job(tmp_path)
    _write_docs(other, docs={"other.md": "# x\n"})
    other_manifest = _publish(other, tmp_path)
    other_token = other_manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    assert client.get("/previews/" + other_token + "/report.md").status_code == 404
    _ = orch


def test_research_and_secret_documents_are_not_published(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    output = _write_docs(job, docs={"report.md": "# ok\n"})
    (output / "research").mkdir(exist_ok=True)
    (output / "research" / "notes.md").write_text("# 未公開\n", encoding="utf-8")
    (output / "secret.md").write_text("# secret\n", encoding="utf-8")
    (output / ".hidden.pdf").write_bytes(b"%PDF-1.4")
    manifest = _publish(job, tmp_path)
    names = {doc["name"] for doc in manifest["documents"]}
    assert names == {"report.md"}
    token = manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    preview_dir = tmp_path / "previews" / token
    assert not (preview_dir / "research").exists()
    assert not (preview_dir / "notes.md").exists()
    assert not (preview_dir / "secret.md").exists()


def test_markdown_inside_artifact_is_also_a_document(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    artifact = _job_dir(job) / "output" / "artifact"
    artifact.mkdir(parents=True, exist_ok=True)
    (artifact / "index.html").write_text("<h1>web</h1>", encoding="utf-8")
    (artifact / "notes.md").write_text("# メモ\n\n本文\n", encoding="utf-8")
    manifest = _publish(job, tmp_path)
    names = {doc["name"] for doc in manifest["documents"]}
    assert names == {"artifact/notes.md"}
    token = manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    assert (tmp_path / "previews" / token / "artifact" / "notes.md").is_file()
    assert (tmp_path / "previews" / token / "artifact" / "notes.md.html").is_file()


def test_markdown_related_image_rides_same_preview_permission(tmp_path: Path) -> None:
    """Markdown が参照する画像も同じ token 経路で公開・拒否される。"""
    job = _make_job(tmp_path)
    _write_docs(
        job,
        docs={
            "report.md": "# 図\n\n![図](./fig.png)\n",
            "fig.png": b"\x89PNG\r\n\x1a\nfakepng",
        },
    )
    manifest = _publish(job, tmp_path)

    client, orch = _client(tmp_path)
    token = manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    # 画像も文書も同じ token で見える。
    assert client.get("/previews/" + token + "/fig.png").status_code == 200
    assert client.get("/previews/" + token + "/report.md.html").status_code == 200
    assert "fig.png" in (tmp_path / "previews" / token / "report.md.html").read_bytes().decode()
    # 別 token（未公開扱い）では拒否。
    assert client.get("/previews/nope/fig.png").status_code == 404
    # 関連画像は文書と同じ token のファイルとして版に含まれる。
    assert (tmp_path / "previews" / token / "fig.png").is_file()
    _ = orch


def test_rollback_republishes_documents_with_new_urls(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    _write_docs(job, docs={"report.md": "# 版1\n", "report.pdf": b"%PDF-1.4"})
    publisher = ArtifactPublisher(root=tmp_path, preview_base_url=BASE)
    first = publisher.publish(job)
    assert first is not None
    rolled = publisher.rollback(job, 1)
    assert rolled is not None
    assert rolled["version"] == 2
    assert rolled["preview_url"] != first["preview_url"]
    documents = rolled["documents"]
    assert {doc["name"] for doc in documents} == {"report.md", "report.pdf"}
    new_token = rolled["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    for doc in documents:
        assert new_token in doc["preview_url"]
        assert new_token in doc["download_url"]


def test_publish_skips_when_no_artifact_and_no_documents(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    publisher = ArtifactPublisher(root=tmp_path, preview_base_url=BASE)
    assert publisher.publish(job) is None


def test_job_detail_includes_documents(tmp_path: Path) -> None:
    client, orch = _client(tmp_path)
    job = _make_job(tmp_path)
    _write_docs(job, docs={"report.md": "# x\n"})
    _publish(job, tmp_path)
    response = client.get(f"/jobs/{job.id}", headers={"X-Mihari-Token": TOKEN})
    assert response.status_code == 200
    artifacts = response.json()["artifacts"]
    assert artifacts and artifacts[0]["documents"]
    assert artifacts[0]["documents"][0]["kind"] == "markdown"
    _ = orch
