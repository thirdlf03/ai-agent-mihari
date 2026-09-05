"""アーカイブ CLI のテスト。JSON 出力と export の containment 検証を中心に。"""

from __future__ import annotations

import json
import os
from pathlib import Path

import httpx
import pytest

from mihari_room.archive.cli import main
from mihari_room.archive.config import ArchiveConfig
from mihari_room.archive.db import ArchiveDatabase
from mihari_room.archive.fetch import SafeFetcher
from mihari_room.archive.ingest import ArchiveIngester
from mihari_room.contracts import CreateJobRequest, JobSource
from mihari_room.store.file_store import FileJobStore

from .archive_helpers import fake_attachment, fake_message, fake_resolver, make_client, pdf_bytes


@pytest.fixture
def root(tmp_path: Path) -> Path:
    return tmp_path / "room"


def _populate(root: Path, *, with_attachment_url: str | None = None) -> None:
    """メッセージ 2 件を収録する（1: みはり URL、2: 猫＋添付）。"""
    import asyncio

    config = ArchiveConfig(root=root, channel_ids=(111,), max_attachment_bytes=64 * 1024)
    responses = {}
    if with_attachment_url:
        host = with_attachment_url.split("//")[1].split("/")[0]
        responses[host] = httpx.Response(
            200,
            content=pdf_bytes("Yamada report PDF"),
            headers={"content-type": "application/pdf"},
        )
    client = make_client(responses=responses)

    async def _go() -> None:
        ing = ArchiveIngester(config, fetcher=SafeFetcher(client=client, resolver=fake_resolver))
        ing.start()
        attachments = (
            (fake_attachment(77, "report.pdf", url=with_attachment_url),)
            if with_attachment_url
            else ()
        )
        await ing.handle_message(fake_message(1, "みはりちゃんのごはん https://example.com/page"))
        await ing.handle_message(fake_message(2, "猫が好きな話", attachments=attachments))
        await ing.aclose()

    asyncio.run(_go())


def test_cli_search_outputs_json(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    root = tmp_path / "room"
    _populate(root)
    code = main(["search", "--query", "みはり", "--root", str(root)])
    assert code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "search"
    assert payload["count"] == 1
    hit = payload["hits"][0]
    assert hit["message"]["content"].startswith("みはりちゃんのごはん")
    assert hit["message"]["jump_url"].startswith("https://discord.com/channels/")
    assert "みはり" in hit["snippet"] or "みはり" in hit["message"]["content"]


def test_cli_search_channel_and_date_filter(tmp_path: Path, capsys) -> None:
    root = tmp_path / "room"
    _populate(root)
    main(["search", "--query", "みはり", "--channel", "999", "--root", str(root)])
    assert json.loads(capsys.readouterr().out)["count"] == 0

    main(
        [
            "search",
            "--query",
            "みはり",
            "--channel",
            "111",
            "--after",
            "2024-01-01",
            "--root",
            str(root),
        ]
    )
    assert json.loads(capsys.readouterr().out)["count"] == 1

    main(["search", "--query", "みはり", "--before", "2024-01-01", "--root", str(root)])
    assert json.loads(capsys.readouterr().out)["count"] == 0


def test_cli_search_missing_db(tmp_path: Path, capsys) -> None:
    root = tmp_path / "room"
    code = main(["search", "--query", "x", "--root", str(root)])
    assert code == 1
    payload = json.loads(capsys.readouterr().out)
    assert "error" in payload


def test_cli_context(tmp_path: Path, capsys) -> None:
    root = tmp_path / "room"
    _populate(root)
    code = main(["context", "--message-id", "2", "--root", str(root)])
    assert code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "context"
    assert payload["anchor"]["message_id"] == 2
    assert payload["before"][0]["message_id"] == 1

    code = main(["context", "--message-id", "9999", "--root", str(root)])
    assert code == 1


def test_cli_export_missing_job(tmp_path: Path, capsys) -> None:
    root = tmp_path / "room"
    _populate(root)
    code = main(["export", "--job-id", "nope", "--message-id", "1", "--root", str(root)])
    assert code == 1
    payload = json.loads(capsys.readouterr().out)
    assert "ジョブが無い" in payload["error"]


def test_cli_export_copies_attachments_and_sources(tmp_path: Path, capsys) -> None:
    root = tmp_path / "room"
    store = FileJobStore(root)
    job = store.create(
        CreateJobRequest(title="レポート調査", body="PDF を見て", source=JobSource.PET)
    )
    _populate(root, with_attachment_url="https://cdn.discordapp.com/attachments/1/2/report.pdf")

    code = main(["export", "--job-id", job.id, "--message-id", "2", "--root", str(root)])
    assert code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "export"
    assert payload["downloaded"], payload["skipped"]

    downloads = root / "jobs" / job.id / "research" / "downloads"
    sources_path = downloads / "sources.json"
    summary_path = downloads / "summary.md"
    assert sources_path.is_file()
    assert summary_path.is_file()
    files = list(downloads.iterdir())
    assert any(f.name.endswith(".pdf") for f in files)

    sources = json.loads(sources_path.read_text(encoding="utf-8"))
    jump_urls = [s.get("jump_url") for s in sources["sources"] if s["type"] == "discord-message"]
    assert jump_urls and jump_urls[0].startswith("https://discord.com/channels/")
    filenames = [s.get("filename") for s in sources["sources"] if s["type"] == "attachment"]
    assert "report.pdf" in filenames

    summary = summary_path.read_text(encoding="utf-8")
    assert "report.pdf" in summary
    assert "ジャンプ URL" in summary


def test_cli_export_no_fetch_skips_missing_file(tmp_path: Path, capsys) -> None:
    root = tmp_path / "room"
    store = FileJobStore(root)
    job = store.create(CreateJobRequest(title="添付なしで", body="本文だけ", source=JobSource.PET))
    _populate(root)  # attachments は無い

    code = main(
        ["export", "--job-id", job.id, "--message-id", "2", "--no-fetch", "--root", str(root)]
    )
    assert code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["downloaded"] == []
    assert payload["skipped"] == []  # 添付が無いので何もコピーしない
    sources_path = root / "jobs" / job.id / "research" / "downloads" / "sources.json"
    assert sources_path.is_file()


def test_cli_export_job_dir_symlink_escape_rejected(tmp_path: Path, capsys) -> None:
    root = tmp_path / "room"
    store = FileJobStore(root)
    job = store.create(CreateJobRequest(title="偽ジョブ", body="x", source=JobSource.PET))
    _populate(root)

    outside = tmp_path / "outside"
    outside.mkdir()
    job_dir = root / "jobs" / job.id
    moved = tmp_path / "moved"
    os.rename(job_dir, moved)
    job_dir.symlink_to(moved)

    code = main(["export", "--job-id", job.id, "--message-id", "1", "--root", str(root)])
    assert code == 1
    payload = json.loads(capsys.readouterr().out)
    assert "error" in payload


def test_cli_export_tampered_local_path_rejected(tmp_path: Path, capsys) -> None:
    """DB の local_path が root の外を差していたら、コピーせずスキップする。"""
    root = tmp_path / "room"
    store = FileJobStore(root)
    job = store.create(CreateJobRequest(title="外を指す添付", body="x", source=JobSource.PET))
    _populate(root)

    # 添付の local_path を tmp の外に書き換える。
    outside = tmp_path.parent / f"{tmp_path.name}-outside.txt"
    outside.write_text("secret")
    db = ArchiveDatabase(root / "messages.db")
    from mihari_room.archive.models import AttachmentStatus, StoredAttachment

    db.upsert_message(
        db.get_message(2),
        attachments=[
            StoredAttachment(
                message_id=2,
                attachment_id=77,
                filename="report.pdf",
                size=10,
                url="https://cdn.discordapp.com/attachments/1/2/report.pdf",
                content_type="application/pdf",
                local_path=str(outside),
                status=AttachmentStatus.OK,
            )
        ],
    )
    db.close()

    code = main(
        ["export", "--job-id", job.id, "--message-id", "2", "--no-fetch", "--root", str(root)]
    )
    assert code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["downloaded"] == []
    assert payload["skipped"]  # 外を指すパスはスキップ扱い
    # 本来の local_path が外に書かれていないこと
    assert outside.exists()
    downloads = root / "jobs" / job.id / "research" / "downloads"
    assert list(downloads.glob("*.pdf")) == []


def test_room_cli_dispatch_archive_subcommand(
    tmp_path: Path, capsys: pytest.CaptureFixture, monkeypatch: pytest.MonkeyPatch
) -> None:
    """mihari_room.cli の main も search をアーカイブ CLI へ流す。"""
    import sys

    from mihari_room import cli as room_cli

    root = tmp_path / "room"
    _populate(root)
    monkeypatch.setattr(
        sys, "argv", ["mihari-room", "search", "--query", "みはり", "--root", str(root)]
    )
    with pytest.raises(SystemExit) as excinfo:
        room_cli.main()
    assert excinfo.value.code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "search"
