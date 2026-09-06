"""アーカイブ DB のテスト。WAL・FTS5・再起動・削除・日本語検索・フォールバック。"""

from __future__ import annotations

import datetime as dt
from pathlib import Path

import pytest

from mihari_room.archive.db import ArchiveDatabase, MessageNotFound
from mihari_room.archive.models import (
    AttachmentStatus,
    StoredAttachment,
    StoredMessage,
    StoredUrl,
)


def _message(
    message_id: int,
    content: str,
    *,
    channel_id: int = 111,
    channel_name: str = "main",
    created_at: dt.datetime | None = None,
    author_name: str = "たろー",
    thread_id: int | None = None,
) -> StoredMessage:
    return StoredMessage(
        message_id=message_id,
        guild_id=777,
        channel_id=channel_id,
        channel_name=channel_name,
        thread_id=thread_id,
        thread_name="スレ名" if thread_id else None,
        author_id=42,
        author_name=author_name,
        content=content,
        created_at=created_at or dt.datetime(2024, 1, 2, 3, 4, 5, tzinfo=dt.UTC),
        jump_url=f"https://discord.com/channels/777/{channel_id}/{message_id}",
    )


def _attachment(message_id: int, attachment_id: int, filename: str = "a.png") -> StoredAttachment:
    return StoredAttachment(
        message_id=message_id,
        attachment_id=attachment_id,
        filename=filename,
        size=10,
        url=f"https://cdn.discordapp.com/attachments/1/{message_id}/{attachment_id}",
        status=AttachmentStatus.OK,
    )


def _url(message_id: int, index: int, url: str = "https://example.com/a") -> StoredUrl:
    return StoredUrl(
        message_id=message_id,
        url_index=index,
        url=url,
        normalized_url=url,
        fetch_status="ok",
        title="Example",
    )


def test_init_creates_wal_and_fts(tmp_path: Path) -> None:
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert db.fts_available  # この環境の sqlite は FTS5 付き
        mode = db._conn.execute("PRAGMA journal_mode").fetchone()[0]
        assert mode == "wal"
        tables = {
            row[0]
            for row in db._conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        assert {"messages", "attachments", "urls"} <= tables
        assert {"messages_fts", "attachments_fts", "urls_fts"} <= tables
    finally:
        db.close()


def test_upsert_and_restart_persists(tmp_path: Path) -> None:
    path = tmp_path / "messages.db"
    db = ArchiveDatabase(path)
    db.upsert_message(_message(1, "みはりちゃんの朝ごはん"))
    db.close()

    reopened = ArchiveDatabase(path)
    try:
        stored = reopened.get_message(1)
        assert stored is not None
        assert stored.content == "みはりちゃんの朝ごはん"
        assert stored.channel_name == "main"
        assert stored.jump_url.endswith("/111/1")
    finally:
        reopened.close()


def test_edit_overwrites_content(tmp_path: Path) -> None:
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        db.upsert_message(_message(1, "元の本文"))
        db.upsert_message(
            _message(1, "編集後の本文", created_at=dt.datetime(2024, 1, 2, 3, 4, 6, tzinfo=dt.UTC))
        )
        assert db.get_message(1).content == "編集後の本文"
    finally:
        db.close()


def test_delete_hides_by_default(tmp_path: Path) -> None:
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        db.upsert_message(_message(1, "消える運命"))
        assert db.mark_deleted(1) is True
        assert db.get_message(1).deleted_at is not None
        assert db.search(query="消える") == []
        hits = db.search(query="消える", include_deleted=True)
        assert len(hits) == 1
        assert hits[0].message.message_id == 1
        assert db.mark_deleted(999) is False
    finally:
        db.close()


def test_search_japanese_and_filters(tmp_path: Path) -> None:
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        db.upsert_message(_message(1, "みはりちゃんのごはんは猫まんまだ", channel_id=111))
        db.upsert_message(_message(2, "宿題を終えたよ", channel_id=222, channel_name="study"))
        db.upsert_message(_message(3, "犬も好きだけど猫も好き", channel_id=111))

        hits = db.search(query="みはり")
        assert [h.message.message_id for h in hits] == [1]

        hits = db.search(query="猫", channel_ids=[111])
        ids = {h.message.message_id for h in hits}
        assert ids == {1, 3}

        hits = db.search(query="宿題", channel_names=["study"])
        assert [h.message.message_id for h in hits] == [2]

        after = dt.datetime(2024, 1, 2, 3, 4, 5, tzinfo=dt.UTC)
        hits = db.search(query="猫", from_dt=after)
        # 3 は同じ created_at だが後から upsert（LIKE は created_at 降順で同刻は id 順）
        ids = {h.message.message_id for h in hits}
        assert 1 in ids and 3 in ids

        hits = db.search(query="猫", to_dt=after + dt.timedelta(seconds=1))
        assert len(hits) == 2
    finally:
        db.close()


def test_search_short_japanese_falls_back_to_like(tmp_path: Path) -> None:
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        db.upsert_message(_message(1, "猫が好き。犬はまあまあ"))
        db.upsert_message(_message(2, "虎の話"))
        # 「猫」は 1 文字 → trigram に載らない → LIKE 側で引く。
        hits = db.search(query="猫")
        assert [h.message.message_id for h in hits] == [1]
        assert "猫" in hits[0].snippet
    finally:
        db.close()


def test_search_fts_unavailable_falls_back(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from mihari_room.archive import db as dbmodule

    monkeypatch.setattr(dbmodule.ArchiveDatabase, "_probe_fts", lambda self: False)
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert db.fts_available is False
        tables = {
            row[0]
            for row in db._conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        assert "messages_fts" not in tables
        db.upsert_message(_message(1, "みはりちゃんの長い本文です"))
        # FTS が無くても長いクエリは LIKE で引ける。
        hits = db.search(query="みはりちゃん")
        assert [h.message.message_id for h in hits] == [1]
    finally:
        db.close()


def test_search_fts_syntax_error_falls_back(tmp_path: Path) -> None:
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        db.upsert_message(_message(1, "普通の本文"))
        # FTS 構文として壊れていても例外にせず LIKE に落とす。
        hits = db.search(query='"')
        assert hits == []
        hits = db.search(query="みはり")
        assert hits == []
    finally:
        db.close()


def test_context_anchor_before_after(tmp_path: Path) -> None:
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        for i in range(1, 6):
            db.upsert_message(
                _message(
                    i, f"メッセージ {i}", created_at=dt.datetime(2024, 1, 2, 3, 4, i, tzinfo=dt.UTC)
                )
            )
        db.upsert_message(
            _message(
                99,
                "別チャンネル",
                channel_id=999,
                created_at=dt.datetime(2024, 1, 2, 3, 4, 3, tzinfo=dt.UTC),
            )
        )

        anchor, before, after = db.fetch_context(3, before=2, after=1)
        assert anchor.message_id == 3
        assert [m.message_id for m in before] == [1, 2]
        assert [m.message_id for m in after] == [4]
        # 別チャンネルは文脈に入らない。
        assert all(m.channel_id == 111 for m in before + after)

        with pytest.raises(MessageNotFound):
            db.fetch_context(9999)
    finally:
        db.close()


def test_context_thread_scope(tmp_path: Path) -> None:
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        for i in (10, 11, 12):
            db.upsert_message(_message(i, f"スレ {i}", thread_id=500))
        db.upsert_message(_message(13, "スレ外の近くの投稿"))
        anchor, before, after = db.fetch_context(11, before=2, after=2)
        assert [m.message_id for m in before] == [10]
        assert [m.message_id for m in after] == [12]
    finally:
        db.close()


def test_search_attachments_and_urls(tmp_path: Path) -> None:
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        db.upsert_message(
            _message(1, "添付あり https://example.com/note へどうぞ"),
            attachments=[_attachment(1, 100, "研修資料.pdf")],
            urls=[_url(1, 0, "https://example.com/note")],
        )
        attachment_hits = db.search_attachments(query="研修")
        assert len(attachment_hits) == 1
        attachment, message, _snippet = attachment_hits[0]
        assert attachment.filename == "研修資料.pdf"
        assert message.message_id == 1

        url_hits = db.search_urls(query="example.com/note")
        assert len(url_hits) == 1
        url, message = url_hits[0]
        assert url.title == "Example"
    finally:
        db.close()


def test_fts_populates_on_reopen_when_missing(tmp_path: Path) -> None:
    """外部コンテンツ FTS を壊して再オープンすると rebuild される。"""
    path = tmp_path / "messages.db"
    db = ArchiveDatabase(path)
    db.upsert_message(_message(1, "再構築テスト本文"))
    db.close()

    # FTS の中身だけ空にして、再オープン時の rebuild を確かめる。
    import sqlite3

    conn = sqlite3.connect(path)
    conn.execute("INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
    conn.execute("DELETE FROM messages_fts")
    conn.close()

    reopened = ArchiveDatabase(path)
    try:
        hits = reopened.search(query="再構築")
        assert [h.message.message_id for h in hits] == [1]
    finally:
        reopened.close()


def test_parameterized_query_no_injection(tmp_path: Path) -> None:
    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        db.upsert_message(_message(1, "安全な本文"))
        # 悪意あるクエリで全件出したり壊したりしない。
        hits = db.search(query="' OR 1=1 --")
        assert hits == []
        assert db.search(query="安全")[0].message.message_id == 1
    finally:
        db.close()
