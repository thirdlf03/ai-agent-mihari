"""アーカイブ収録（ArchiveIngester）のテスト。偽 Discord と偽 HTTP で完結する。"""

from __future__ import annotations

import asyncio
import datetime as dt
from pathlib import Path

import httpx

from mihari_room.archive.config import ArchiveConfig
from mihari_room.archive.db import ArchiveDatabase
from mihari_room.archive.fetch import SafeFetcher
from mihari_room.archive.ingest import ArchiveIngester
from mihari_room.archive.models import AttachmentStatus

from .archive_helpers import (
    fake_attachment,
    fake_channel,
    fake_message,
    fake_payload,
    fake_resolver,
    fake_thread,
    make_client,
    pdf_bytes,
)


def _config(
    root: Path,
    *,
    channels: tuple[int, ...] = (111,),
    queue_size: int = 8,
    **overrides: object,
) -> ArchiveConfig:
    values: dict[str, object] = {
        "root": root,
        "channel_ids": channels,
        "queue_size": queue_size,
        "max_attachment_bytes": 64 * 1024,
    }
    values.update(overrides)
    return ArchiveConfig(**values)  # type: ignore[arg-type]


def _ingester(
    config: ArchiveConfig,
    *,
    responses: dict[str, httpx.Response] | None = None,
    resolver=None,
    db: ArchiveDatabase | None = None,
) -> ArchiveIngester:
    client = make_client(responses=responses)
    fetcher = SafeFetcher(client=client, resolver=resolver or fake_resolver)
    return ArchiveIngester(config, db, fetcher=fetcher)


async def test_empty_allowlist_records_all_guild_channels(tmp_path: Path) -> None:
    config = _config(tmp_path, channels=())
    ing = _ingester(config)
    ing.start()
    await ing.handle_message(fake_message(4, "どのチャンネルでも控える", channel_id=999))
    await ing.aclose()
    assert config.enabled
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert db.get_message(4) is not None
    finally:
        db.close()


async def test_bot_and_dm_are_skipped(tmp_path: Path) -> None:
    ing = _ingester(_config(tmp_path))
    ing.start()
    await ing.handle_message(fake_message(1, "bot の投稿", bot=True))
    await ing.handle_message(fake_message(2, "DM の投稿", guild_id=None))
    await ing.handle_message(fake_message(3, "別チャンネル", channel_id=999))
    await ing.handle_message(fake_message(4, "許可チャンネル", channel_id=111))
    await ing.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert db.get_message(1) is None
        assert db.get_message(2) is None
        assert db.get_message(3) is None
        assert db.get_message(4) is not None
    finally:
        db.close()


async def test_thread_in_allowlisted_channel_is_ingested(tmp_path: Path) -> None:
    ing = _ingester(_config(tmp_path, channels=(111,)))
    ing.start()
    parent = fake_channel(111, name="本家")
    await ing.handle_message(
        fake_message(9, "スレッドの書き込み", channel=fake_thread(500, parent))
    )
    await ing.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        stored = db.get_message(9)
        assert stored is not None
        assert stored.channel_id == 111
        assert stored.thread_id == 500
        assert stored.thread_name == "スレ"
    finally:
        db.close()


async def test_attachment_download_and_pdf_extract(tmp_path: Path) -> None:
    responses = {
        "cdn.discordapp.com": httpx.Response(
            200,
            content=pdf_bytes("Mihari PDF report body"),
            headers={"content-type": "application/pdf"},
        )
    }
    ing = _ingester(_config(tmp_path), responses=responses)
    ing.start()
    await ing.handle_message(
        fake_message(1, "添付を見て", attachments=(fake_attachment(5, "しりょう.pdf"),))
    )
    await ing.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        attachments = db.fetch_attachments_for_message(1)
        assert len(attachments) == 1
        attachment = attachments[0]
        assert attachment.status == AttachmentStatus.OK
        assert attachment.filename == "しりょう.pdf"
        assert attachment.extract_status == "pdf_text"
        assert attachment.extracted_text and "Mihari PDF" in attachment.extracted_text
        local = db.resolve_local(attachment.local_path)
        assert local is not None and local.is_file()
        assert db.resolve_local(attachment.local_path).is_relative_to(
            tmp_path / "archive" / "attachments"
        )
    finally:
        db.close()


async def test_attachment_size_and_type_limits(tmp_path: Path) -> None:
    ing = _ingester(
        _config(tmp_path, max_attachment_bytes=1000),
        responses={"cdn.discordapp.com": httpx.Response(200, content=b"x" * 20)},
    )
    ing.start()
    await ing.handle_message(
        fake_message(
            1,
            "大きな添付と不許可な添付",
            attachments=(
                fake_attachment(1, "big.png", size=9999, content_type="image/png"),
                fake_attachment(2, "virus.exe", size=10, content_type="application/x-msdownload"),
                fake_attachment(3, "ok.png", size=50, content_type="image/png"),
            ),
        )
    )
    await ing.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        by_id = {a.attachment_id: a for a in db.fetch_attachments_for_message(1)}
        assert by_id[1].status == AttachmentStatus.SKIPPED_SIZE
        assert by_id[2].status == AttachmentStatus.SKIPPED_TYPE
        assert by_id[3].status == AttachmentStatus.OK
        # スキップした分はダウンロードしていない。
        local = db.resolve_local(by_id[3].local_path)
        assert local is not None and local.is_file()
    finally:
        db.close()


async def test_edit_updates_content(tmp_path: Path) -> None:
    ing = _ingester(_config(tmp_path))
    ing.start()
    await ing.handle_message(fake_message(1, "最初の本文"))
    await ing.handle_message(fake_message(1, "編集後の本文", edited_at="2024-01-02T04:00:00+00:00"))
    await ing.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        stored = db.get_message(1)
        assert stored is not None
        assert stored.content == "編集後の本文"
        assert stored.edited_at is not None
    finally:
        db.close()


async def test_raw_edit_and_delete(tmp_path: Path) -> None:
    ing = _ingester(_config(tmp_path))
    ing.start()
    await ing.handle_message(fake_message(1, "元ネタ"))
    await ing.handle_message(fake_message(2, "消えるやつ"))
    await ing.aclose()

    ing2 = _ingester(_config(tmp_path))
    ing2.start()
    await ing2.handle_raw_edit(
        fake_payload(
            1, {"id": 1, "content": "raw で編集", "edited_timestamp": "2024-01-02T05:00:00+00:00"}
        )
    )
    # 未収録メッセージの edit は無視。
    await ing2.handle_raw_edit(fake_payload(999, {"id": 999, "content": "x"}))
    await ing2.handle_raw_delete(fake_payload(2, {}))
    await ing2.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        stored = db.get_message(1)
        assert stored is not None
        assert stored.content == "raw で編集"
        assert stored.edited_at is not None
        assert db.get_message(2).deleted_at is not None
        assert db.get_message(999) is None
    finally:
        db.close()


async def test_bulk_delete(tmp_path: Path) -> None:
    ing = _ingester(_config(tmp_path))
    ing.start()
    for mid in (1, 2, 3):
        await ing.handle_message(fake_message(mid, f"本文 {mid}"))
    await ing.aclose()

    ing2 = _ingester(_config(tmp_path))
    ing2.start()
    await ing2.handle_raw_bulk_delete(fake_payload(0, {"ids": [1, 3]}))
    await ing2.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert db.get_message(1).deleted_at is not None
        assert db.get_message(2).deleted_at is None
        assert db.get_message(3).deleted_at is not None
    finally:
        db.close()


async def test_bounded_queue_drops_instead_of_blocking(tmp_path: Path) -> None:
    config = _config(tmp_path, queue_size=2)
    ing = _ingester(config)

    # ワーカーを寝かせたままキューを満杯にして、溢れが落ちることを確かめる。
    async def _stall() -> None:
        await asyncio.Event().wait()

    stall = asyncio.create_task(_stall())
    ing._worker = stall
    ing._queue = asyncio.Queue(maxsize=2)
    try:
        await ing.handle_message(fake_message(1, "a"))
        await ing.handle_message(fake_message(2, "b"))
        assert ing._queue.qsize() == 2
        # 満杯でも on_message はブロックしない。
        await ing.handle_message(fake_message(3, "c"))
        assert ing._queue.qsize() == 2
    finally:
        stall.cancel()
        try:
            await stall
        except asyncio.CancelledError:
            pass
        await ing.aclose(drain_timeout=0.1)


async def test_graceful_shutdown_drains_queue(tmp_path: Path) -> None:
    ing = _ingester(_config(tmp_path))
    ing.start()
    await ing.handle_message(fake_message(1, "一本目"))
    await ing.handle_message(fake_message(2, "二本目"))
    await ing.aclose()
    assert ing._queue.empty()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert db.get_message(1) is not None
        assert db.get_message(2) is not None
    finally:
        db.close()


async def test_url_indexed_even_when_fetch_fails(tmp_path: Path) -> None:
    ing = _ingester(
        _config(tmp_path, fetch_urls=True),
        responses={"broken.example": httpx.Response(500, content=b"")},
        # DNS は通るが HTTP は 500 を返す
    )
    ing.start()
    await ing.handle_message(fake_message(1, "壊れたリンク https://broken.example/x を見て"))
    await ing.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        urls = db.fetch_urls_for_message(1)
        assert len(urls) == 1
        assert urls[0].normalized_url == "https://broken.example/x"
        assert urls[0].fetch_status == "error"
    finally:
        db.close()


async def test_url_fetch_disabled_still_indexes(tmp_path: Path) -> None:
    ing = _ingester(_config(tmp_path, fetch_urls=False))
    ing.start()
    await ing.handle_message(fake_message(1, "リンク https://example.com/page ここ"))
    await ing.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        urls = db.fetch_urls_for_message(1)
        assert len(urls) == 1
        assert urls[0].fetch_status == "disabled"
        assert urls[0].normalized_url == "https://example.com/page"
    finally:
        db.close()


async def test_url_metadata_extracted(tmp_path: Path) -> None:
    responses = {
        "example.com": httpx.Response(
            200,
            content=(
                "<html><head><title>良い記事</title>"
                "<meta name='description' content='素敵な説明'>"
                "</head><body><p>本文のテキスト</p></body></html>"
            ).encode(),
            headers={"content-type": "text/html"},
        )
    }
    ing = _ingester(_config(tmp_path, fetch_urls=True), responses=responses)
    ing.start()
    await ing.handle_message(fake_message(1, "https://example.com/article を見て"))
    await ing.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        urls = db.fetch_urls_for_message(1)
        assert urls[0].fetch_status == "ok"
        assert urls[0].title == "良い記事"
        assert urls[0].description == "素敵な説明"
    finally:
        db.close()


async def test_catchup_skips_already_stored_and_fills_gap(tmp_path: Path) -> None:
    from types import SimpleNamespace

    ing = _ingester(_config(tmp_path))
    ing.start()
    await ing.handle_message(fake_message(1, "既にある", created_at="2024-01-02T00:00:00+00:00"))
    assert ing._queue is not None
    await asyncio.wait_for(ing._queue.join(), timeout=2)

    newer = fake_message(2, "落ちてる間", created_at="2024-01-03T00:00:00+00:00")
    older = fake_message(1, "もうある", created_at="2024-01-02T00:00:00+00:00")

    class _Channel:
        def __init__(self) -> None:
            self.id = 111
            self.name = "main"
            self.parent = None
            self.threads = []

        def history(self, *, after=None, limit=None, oldest_first=True):
            async def _gen():
                for msg in (older, newer):
                    ts = dt.datetime.fromisoformat(str(msg.created_at).replace("Z", "+00:00"))
                    if after is not None and ts <= after:
                        continue
                    yield msg

            return _gen()

    guild = SimpleNamespace(id=777, text_channels=[_Channel()], forums=[])
    inserted = await ing.catchup_guilds([guild])
    await ing.aclose()
    assert inserted == 1
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert db.get_message(1) is not None
        assert db.get_message(2) is not None
        assert db.get_message(2).content == "落ちてる間"
    finally:
        db.close()
