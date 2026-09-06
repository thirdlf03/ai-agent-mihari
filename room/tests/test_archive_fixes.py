"""回帰: archive  correctness 5 件。実ネットワークなし。"""

from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

from mihari_room.archive.cli import main as archive_main
from mihari_room.archive.config import ArchiveConfig
from mihari_room.archive.db import ArchiveDatabase
from mihari_room.archive.export import export_message
from mihari_room.archive.fetch import FetchError, SafeFetcher
from mihari_room.archive.ingest import ArchiveIngester
from mihari_room.archive.models import StoredAttachment, StoredUrl
from mihari_room.contracts import CreateJobRequest, JobSource
from mihari_room.store.file_store import FileJobStore

from .archive_helpers import (
    PUBLIC_IP,
    fake_attachment,
    fake_message,
    fake_payload,
    fake_resolver,
    make_client,
    pdf_bytes,
)


def _config(root: Path, **overrides) -> ArchiveConfig:
    values: dict = {
        "root": root,
        "channel_ids": (111,),
        "queue_size": 16,
        "max_attachment_bytes": 64 * 1024,
        "fetch_urls": True,
    }
    values.update(overrides)
    return ArchiveConfig(**values)


def _ingester(config, *, responses=None, resolver=None):
    client = make_client(responses=responses)
    return ArchiveIngester(
        config, fetcher=SafeFetcher(client=client, resolver=resolver or fake_resolver)
    )


async def test_raw_partial_edit_preserves_attachments_and_urls(tmp_path: Path) -> None:
    responses = {
        "cdn.discordapp.com": httpx.Response(
            200,
            content=pdf_bytes("Mihari PDF report body"),
            headers={"content-type": "application/pdf"},
        ),
        "example.com": httpx.Response(
            200,
            content=b"<html><head><title>T</title></head></html>",
            headers={"content-type": "text/html"},
        ),
    }
    ing = _ingester(_config(tmp_path), responses=responses)
    ing.start()
    await ing.handle_message(
        fake_message(
            1,
            "見る https://example.com/page",
            attachments=(fake_attachment(5, "しりょう.pdf"),),
        )
    )
    # キューを流してから、attachments キー無しの部分編集を送る。
    await ing._queue.join()
    await ing.handle_raw_edit(
        fake_payload(1, {"id": 1, "content": "見る https://example.com/page"})
    )
    await ing.aclose()
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        atts = db.fetch_attachments_for_message(1)
        assert len(atts) == 1 and atts[0].filename == "しりょう.pdf"
        assert atts[0].extracted_text and "Mihari PDF" in atts[0].extracted_text
        urls = db.fetch_urls_for_message(1)
        assert len(urls) == 1 and urls[0].fetch_status == "ok"
        # content キー自体が無い編集では本文も URL 濃縮も残る。
    finally:
        db.close()
    # content 省略の raw edit
    ing2 = _ingester(_config(tmp_path))
    ing2.start()
    db3 = ArchiveDatabase(tmp_path / "messages.db")
    before = db3.get_message(1)
    db3.close()
    assert before is not None
    await ing2.handle_raw_edit(fake_payload(1, {"id": 1}))
    await ing2.aclose()
    db4 = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert db4.get_message(1).content == before.content
        assert len(db4.fetch_attachments_for_message(1)) == 1
        assert len(db4.fetch_urls_for_message(1)) == 1
    finally:
        db4.close()


async def test_queue_ordering_delete_after_message_without_yield(tmp_path: Path) -> None:
    ing = _ingester(_config(tmp_path, fetch_attachments=False, fetch_urls=False))
    ing.start()
    await ing.handle_message(fake_message(1, "すぐ消える"))
    await ing.handle_raw_delete(fake_payload(1, {}))
    await ing.aclose()
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert db.get_message(1) is not None
        assert db.get_message(1).deleted_at is not None
    finally:
        db.close()


async def test_queue_ordering_edit_after_message_without_yield(tmp_path: Path) -> None:
    ing = _ingester(_config(tmp_path, fetch_attachments=False, fetch_urls=False))
    ing.start()
    await ing.handle_message(fake_message(2, "元"))
    await ing.handle_raw_edit(
        fake_payload(
            2,
            {"id": 2, "content": "直後編集", "edited_timestamp": "2024-01-02T05:00:00+00:00"},
        )
    )
    await ing.aclose()
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert db.get_message(2).content == "直後編集"
    finally:
        db.close()


async def test_delete_sticky_against_late_upsert(tmp_path: Path) -> None:
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        from .test_archive_db import _message as make_msg

        db.upsert_message(make_msg(9, "本文"))
        assert db.mark_deleted(9) is True
        # 遅延したダウンロード完了相当の再 upsert は蘇生しない。
        db.upsert_message(make_msg(9, "本文"), attachments=[], urls=[])
        assert db.get_message(9).deleted_at is not None
    finally:
        db.close()


async def test_attachment_redirect_outside_cdn_blocked() -> None:
    responses = {
        "cdn.discordapp.com": httpx.Response(
            302, headers={"location": "https://evil.example/steal"}
        ),
    }
    client = make_client(responses=responses)
    fetcher = SafeFetcher(client=client, resolver=fake_resolver)
    with pytest.raises(FetchError, match="CDN"):
        await fetcher.download_attachment(
            "https://cdn.discordapp.com/attachments/1/2/a.png",
            max_bytes=10000,
            timeout=2,
        )


async def test_dns_rebind_double_resolve_blocked() -> None:
    responses = {
        "flip.example": httpx.Response(200, content=b"hi"),
    }
    calls = {"n": 0}

    async def flip_resolver(host: str) -> list[str]:
        calls["n"] += 1
        if calls["n"] == 1:
            return [PUBLIC_IP]
        return ["10.0.0.5"]

    client = make_client(responses=responses)
    fetcher = SafeFetcher(client=client, resolver=flip_resolver)
    meta = await fetcher.fetch_url_metadata("https://flip.example/x", max_bytes=1000, timeout=2)
    assert meta.fetch_status == "error"
    assert "プライベート" in (meta.error or "")


def test_fetch_urls_enabled_refused_by_validate(tmp_path: Path) -> None:
    config = _config(tmp_path, fetch_urls=True)
    with pytest.raises(ValueError, match="FETCH_URLS"):
        config.validate()


def test_like_search_and_terms_across_pdf_and_url(tmp_path: Path) -> None:
    from .test_archive_db import _attachment, _message

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        msg = _message(1, "本文 https://example.com/note")
        att = _attachment(1, 100, "研修資料.pdf")
        att = StoredAttachment(
            message_id=att.message_id,
            attachment_id=att.attachment_id,
            filename=att.filename,
            size=att.size,
            url=att.url,
            status="ok",
            extracted_text="猫の健康診断レポート",
        )
        url = StoredUrl(
            message_id=1,
            url_index=0,
            url="https://example.com/note",
            normalized_url="https://example.com/note",
            fetch_status="ok",
            title="猫の診療メモ",
            description="健康診断のまとめ",
        )
        db.upsert_message(msg, attachments=[att], urls=[url])
        # 短い日本語でも extracted_text を見る。
        hits = db.search_attachments(query="猫")
        assert [a.filename for a, _, _ in hits] == ["研修資料.pdf"]
        # 複数語 AND: 両方含むものだけ。
        hits = db.search_attachments(query="猫 健康診断")
        assert len(hits) == 1
        hits = db.search_attachments(query="猫 存在しない語")
        assert hits == []
        # URL は title/description 横断 AND。
        assert len(db.search_urls(query="猫")) == 1
        assert db.search_urls(query="猫 存在しない語") == []
        # 削除済みは既定で出ない。
        db.mark_deleted(1)
        assert db.search_attachments(query="猫") == []
        assert db.search_urls(query="猫") == []
        assert db.search_attachments(query="猫", include_deleted=True) != []
    finally:
        db.close()


def test_cli_unified_search_finds_pdf_and_url(tmp_path: Path, capsys) -> None:
    from .test_archive_db import _attachment, _message

    root = tmp_path / "room"
    root.mkdir()
    db = ArchiveDatabase(root / "messages.db")
    try:
        msg = _message(1, "本文 https://example.com/note")
        att = _attachment(1, 100, "研修資料.pdf")
        att = StoredAttachment(
            message_id=att.message_id,
            attachment_id=att.attachment_id,
            filename=att.filename,
            size=att.size,
            url=att.url,
            status="ok",
            extracted_text="猫の健康診断レポート",
        )
        url = StoredUrl(
            message_id=1,
            url_index=0,
            url="https://example.com/note",
            normalized_url="https://example.com/note",
            fetch_status="ok",
            title="猫の診療メモ",
        )
        db.upsert_message(msg, attachments=[att], urls=[url])
    finally:
        db.close()
    code = archive_main(["search", "--query", "猫", "--root", str(root)])
    assert code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "search"
    assert payload["attachment_hits"]
    assert payload["attachment_hits"][0]["filename"] == "研修資料.pdf"
    assert payload["attachment_hits"][0]["jump_url"].startswith("https://discord.com/channels/")
    assert payload["url_hits"]
    assert payload["url_hits"][0]["url"] == "https://example.com/note"


async def test_export_aggregates_and_preserves_model_summary(tmp_path: Path) -> None:
    root = tmp_path / "room"
    config = ArchiveConfig(root=root, channel_ids=(111,), max_attachment_bytes=64 * 1024)
    store = FileJobStore(root)
    job = store.create(CreateJobRequest(title="調査", body="b", source=JobSource.PET))

    async def _ingest(mid: int, text: str, aid: int, fname: str, body: str):
        responses = {
            "cdn.discordapp.com": httpx.Response(
                200, content=pdf_bytes(body), headers={"content-type": "application/pdf"}
            )
        }
        ing = _ingester(config, responses=responses)
        ing.start()
        await ing.handle_message(
            fake_message(mid, text, attachments=(fake_attachment(aid, fname),))
        )
        await ing.aclose()

    await _ingest(1, "一つ目", 11, "a.pdf", "First PDF body")
    await _ingest(2, "二つ目", 11, "a.pdf", "Second PDF body")  # 同 attachment_id 衝突
    db = ArchiveDatabase(root / "messages.db")
    db.close()
    await export_message(config, job_id=job.id, message_id=1, fetcher=None)
    # model が要約を書いた想定で追記する。
    summary_path = root / "jobs" / job.id / "research" / "summary.md"
    model_text = summary_path.read_text(encoding="utf-8") + "\n# モデル総合\n合成済みの考察\n"
    summary_path.write_text(model_text, encoding="utf-8")
    await export_message(config, job_id=job.id, message_id=2, fetcher=None)

    sources = json.loads(
        (root / "jobs" / job.id / "research" / "sources.json").read_text(encoding="utf-8")
    )
    ids = sources["source_ids"]
    assert "discord-message-1" in ids and "discord-message-2" in ids
    assert len(ids) == len(set(ids))
    downloads = list((root / "jobs" / job.id / "research" / "downloads").glob("*.pdf"))
    assert len(downloads) == 2  # 上書きされず両方残る
    assert len({p.name for p in downloads}) == 2  # ファイル名衝突なし
    summary = summary_path.read_text(encoding="utf-8")
    assert "合成済みの考察" in summary  # model 記述が消えていない
    # 再出力は冪等（増えない）。
    before = len(ids)
    await export_message(config, job_id=job.id, message_id=2, fetcher=None)
    again = json.loads(
        (root / "jobs" / job.id / "research" / "sources.json").read_text(encoding="utf-8")
    )
    assert len(again["source_ids"]) == before


async def test_export_symlink_file_rejected(tmp_path: Path) -> None:
    root = tmp_path / "room"
    config = ArchiveConfig(root=root, channel_ids=(111,), max_attachment_bytes=64 * 1024)
    store = FileJobStore(root)
    job = store.create(CreateJobRequest(title="T", body="b", source=JobSource.PET))
    ing = _ingester(config)
    ing.start()
    config2 = ArchiveConfig(
        root=root, channel_ids=(111,), fetch_attachments=False, fetch_urls=False
    )
    ing2 = ArchiveIngester(
        config2, fetcher=SafeFetcher(client=make_client(), resolver=fake_resolver)
    )
    ing2.start()
    await ing2.handle_message(fake_message(1, "本文"))
    await ing2.aclose()
    # downloads 内に外への symlink を置いても検証で弾く/無視する。
    dl = root / "jobs" / job.id / "research" / "downloads"
    dl.mkdir(parents=True, exist_ok=True)
    outside = tmp_path / "secret.txt"
    outside.write_text("secret")
    link = dl / "evil.pdf"
    try:
        link.symlink_to(outside)
    except OSError:
        pass
    from mihari_room.archive.pathutil import ensure_contained

    with pytest.raises(ValueError):
        ensure_contained(link, root / "jobs" / job.id)
    assert outside.read_text() == "secret"
