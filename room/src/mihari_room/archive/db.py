"""作業部屋のアーカイブ DB。WAL + FTS5 trigram の ``messages.db``。

- ``messages`` / ``attachments`` / ``urls`` を正本に、FTS5 は外部コンテンツ表。
- 全文検索は ``messages_fts`` ``attachments_fts`` ``urls_fts``（trigram）。
- 3 文字未満の日本語クエリや FTS5 が無い環境は LIKE フォールバック。
- クエリは全部パラメータ化。チャンネル・日付・削除済みの絞り込み付き。
"""

from __future__ import annotations

import datetime as dt
import logging
import re
import sqlite3
import threading
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from mihari_room.archive.models import (
    SearchHit,
    StoredAttachment,
    StoredMessage,
    StoredUrl,
    from_iso,
    to_iso,
)
from mihari_room.archive.pathutil import ensure_contained

logger = logging.getLogger(__name__)

#: trigram tokenizer は 3 文字未満のトークンを索引できない。短い時は LIKE に落とす。
MIN_FTS_TERM_LEN = 3

#: FTS の snippet マーカー。出力を壊しにくい記号にしておく。
_SNIPPET_OPEN = "⟪"
_SNIPPET_CLOSE = "⟫"
_SNIPPET_ELLIPSIS = "…"
_SNIPPET_TOKENS = 18


class MessageNotFound(KeyError):
    """指定のメッセージがアーカイブに無い。"""

    def __init__(self, message_id: int) -> None:
        super().__init__(message_id)
        self.message_id = message_id


_SCHEMA = """
CREATE TABLE IF NOT EXISTS messages (
    message_id   INTEGER PRIMARY KEY,
    guild_id     INTEGER NOT NULL,
    channel_id   INTEGER NOT NULL,
    channel_name TEXT    NOT NULL,
    thread_id    INTEGER,
    thread_name  TEXT,
    author_id    INTEGER NOT NULL,
    author_name  TEXT    NOT NULL,
    content      TEXT    NOT NULL DEFAULT '',
    created_at   TEXT    NOT NULL,
    edited_at    TEXT,
    deleted_at   TEXT,
    jump_url     TEXT    NOT NULL DEFAULT '',
    fetched_at   TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);
CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages(channel_id);
CREATE INDEX IF NOT EXISTS idx_messages_deleted ON messages(deleted_at);

CREATE TABLE IF NOT EXISTS attachments (
    message_id      INTEGER NOT NULL,
    attachment_id   INTEGER NOT NULL,
    filename        TEXT    NOT NULL,
    content_type    TEXT,
    size            INTEGER NOT NULL,
    url             TEXT    NOT NULL,
    local_path      TEXT,
    status          TEXT    NOT NULL,
    extract_status  TEXT,
    extracted_text  TEXT,
    error           TEXT,
    fetched_at      TEXT,
    PRIMARY KEY (message_id, attachment_id)
);
CREATE INDEX IF NOT EXISTS idx_attachments_message ON attachments(message_id);

CREATE TABLE IF NOT EXISTS urls (
    message_id      INTEGER NOT NULL,
    url_index       INTEGER NOT NULL,
    url             TEXT    NOT NULL,
    normalized_url  TEXT    NOT NULL DEFAULT '',
    fetch_status    TEXT    NOT NULL,
    title           TEXT,
    description     TEXT,
    error           TEXT,
    fetched_at      TEXT,
    PRIMARY KEY (message_id, url_index)
);
CREATE INDEX IF NOT EXISTS idx_urls_message ON urls(message_id);
CREATE INDEX IF NOT EXISTS idx_urls_normalized ON urls(normalized_url);
"""

#: FTS5 が使える時だけ実行する。外部コンテンツ表で本文の二重持ちを避ける。
_FTS_SCHEMA = """
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    content, channel_name, thread_name, author_name,
    content='messages',
    content_rowid='message_id',
    tokenize='trigram'
);

CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, content, channel_name, thread_name, author_name)
    VALUES (new.message_id, new.content, new.channel_name, new.thread_name,
            new.author_name);
END;
CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content, channel_name,
                             thread_name, author_name)
    VALUES ('delete', old.message_id, old.content, old.channel_name,
            old.thread_name, old.author_name);
END;
CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content, channel_name,
                             thread_name, author_name)
    VALUES ('delete', old.message_id, old.content, old.channel_name,
            old.thread_name, old.author_name);
    INSERT INTO messages_fts(rowid, content, channel_name, thread_name, author_name)
    VALUES (new.message_id, new.content, new.channel_name, new.thread_name,
            new.author_name);
END;

CREATE VIRTUAL TABLE IF NOT EXISTS attachments_fts USING fts5(
    filename, extracted_text,
    content='attachments',
    tokenize='trigram'
);

CREATE TRIGGER IF NOT EXISTS attachments_ai AFTER INSERT ON attachments BEGIN
    INSERT INTO attachments_fts(rowid, filename, extracted_text)
    VALUES (new.rowid, new.filename, new.extracted_text);
END;
CREATE TRIGGER IF NOT EXISTS attachments_ad AFTER DELETE ON attachments BEGIN
    INSERT INTO attachments_fts(attachments_fts, rowid, filename, extracted_text)
    VALUES ('delete', old.rowid, old.filename, old.extracted_text);
END;
CREATE TRIGGER IF NOT EXISTS attachments_au AFTER UPDATE ON attachments BEGIN
    INSERT INTO attachments_fts(attachments_fts, rowid, filename, extracted_text)
    VALUES ('delete', old.rowid, old.filename, old.extracted_text);
    INSERT INTO attachments_fts(rowid, filename, extracted_text)
    VALUES (new.rowid, new.filename, new.extracted_text);
END;

CREATE VIRTUAL TABLE IF NOT EXISTS urls_fts USING fts5(
    url, title, description,
    content='urls',
    tokenize='trigram'
);

CREATE TRIGGER IF NOT EXISTS urls_ai AFTER INSERT ON urls BEGIN
    INSERT INTO urls_fts(rowid, url, title, description)
    VALUES (new.rowid, new.url, new.title, new.description);
END;
CREATE TRIGGER IF NOT EXISTS urls_ad AFTER DELETE ON urls BEGIN
    INSERT INTO urls_fts(urls_fts, rowid, url, title, description)
    VALUES ('delete', old.rowid, old.url, old.title, old.description);
END;
CREATE TRIGGER IF NOT EXISTS urls_au AFTER UPDATE ON urls BEGIN
    INSERT INTO urls_fts(urls_fts, rowid, url, title, description)
    VALUES ('delete', old.rowid, old.url, old.title, old.description);
    INSERT INTO urls_fts(rowid, url, title, description)
    VALUES (new.rowid, new.url, new.title, new.description);
END;
"""


def _placeholders(items: Sequence[object]) -> str:
    return ", ".join("?" for _ in items)


def _escape_like(term: str) -> str:
    """LIKE パターン用に % _ \\ をエスケープする。"""
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _split_terms(query: str) -> list[str]:
    """クエリを空白区切りの語に。FTS の引用符は除いて長さ判定する。"""
    return re.findall(r"\S+", query.replace('"', ""))


class ArchiveDatabase:
    """WAL の SQLite。書き込みはロックで直列化し、読みは WAL で並行させる。"""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(self.path, isolation_level=None, check_same_thread=False)
        self._lock = threading.Lock()
        with self._lock:
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA busy_timeout=5000")
            self._conn.execute("PRAGMA foreign_keys=ON")
            self._conn.executescript(_SCHEMA)
            self._fts = self._probe_fts()
            if self._fts:
                self._conn.executescript(_FTS_SCHEMA)
                self._ensure_fts_populated()
            else:
                logger.warning("FTS5 が使えない SQLite。全文検索は LIKE になる: %s", path)

    @property
    def root(self) -> Path:
        return self.path.parent

    @property
    def fts_available(self) -> bool:
        return self._fts

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def __enter__(self) -> ArchiveDatabase:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _probe_fts(self) -> bool:
        """FTS5 が組み込まれているか。トリグラムは FTS5 の機能なので同時に見る。"""
        try:
            self._conn.execute("CREATE VIRTUAL TABLE _arch_probe USING fts5(x, tokenize='trigram')")
            self._conn.execute("DROP TABLE _arch_probe")
        except sqlite3.OperationalError:
            return False
        return True

    def _ensure_fts_populated(self) -> None:
        """既存 DB を初めて開いた時など、FTS が未構築なら再構築する。

        外部コンテンツ FTS5 では fts 表の count(*) がソース行数を返すため、
        内側の ``<fts>_docsize`` 行数で未索引を判定する。
        """
        for fts_table, source_table in (
            ("messages_fts", "messages"),
            ("attachments_fts", "attachments"),
            ("urls_fts", "urls"),
        ):
            indexed = self._conn.execute(f"SELECT count(*) FROM {fts_table}_docsize").fetchone()[0]
            total = self._conn.execute(f"SELECT count(*) FROM {source_table}").fetchone()[0]
            if indexed == 0 and total > 0:
                self._conn.execute(f"INSERT INTO {fts_table}({fts_table}) VALUES('rebuild')")

    # ---------- resolve ----------

    def resolve_local(self, local_path: str | None) -> Path | None:
        """DB 内の相対パスを root 基準に戻す。root の外へ逃げるものは無効に。"""
        if not local_path:
            return None
        candidate = Path(local_path)
        if candidate.is_absolute():
            try:
                return ensure_contained(candidate, self.root)
            except ValueError:
                return None
        return self.root / candidate

    # ---------- write ----------

    def upsert_message(
        self,
        stored: StoredMessage,
        *,
        attachments: Sequence[StoredAttachment] | None = None,
        urls: Sequence[StoredUrl] | None = None,
    ) -> None:
        """メッセージを上書きする。

        attachments / urls が None なら既存行を残す（raw 部分更新の欠落対策）。
        空シーケンスは明示的な空として行を消す。deleted_at は粘着:
        新規行が None でも既存の削除を消さない（遅延ダウンロードの蘇生防止）。
        """
        row = (
            stored.message_id,
            stored.guild_id,
            stored.channel_id,
            stored.channel_name,
            stored.thread_id,
            stored.thread_name,
            stored.author_id,
            stored.author_name,
            stored.content,
            to_iso(stored.created_at),
            to_iso(stored.edited_at),
            to_iso(stored.deleted_at),
            stored.jump_url,
            to_iso(stored.fetched_at),
        )
        att_rows = (
            [
                (
                    a.message_id,
                    a.attachment_id,
                    a.filename,
                    a.content_type,
                    a.size,
                    a.url,
                    a.local_path,
                    a.status,
                    a.extract_status,
                    a.extracted_text,
                    a.error,
                    to_iso(a.fetched_at),
                )
                for a in attachments
            ]
            if attachments is not None
            else None
        )
        url_rows = (
            [
                (
                    u.message_id,
                    u.url_index,
                    u.url,
                    u.normalized_url,
                    u.fetch_status,
                    u.title,
                    u.description,
                    u.error,
                    to_iso(u.fetched_at),
                )
                for u in urls
            ]
            if urls is not None
            else None
        )
        with self._lock:
            # deleted_at は粘着: 新規が None で既存に削除があれば残す。
            if stored.deleted_at is None:
                prior = self._conn.execute(
                    "SELECT deleted_at FROM messages WHERE message_id = ?",
                    (stored.message_id,),
                ).fetchone()
                if prior is not None and prior[0] is not None:
                    row = row[:11] + (prior[0],) + row[12:]
            self._conn.execute(
                """
                INSERT INTO messages
                    (message_id, guild_id, channel_id, channel_name, thread_id,
                     thread_name, author_id, author_name, content, created_at,
                     edited_at, deleted_at, jump_url, fetched_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(message_id) DO UPDATE SET
                    guild_id = excluded.guild_id,
                    channel_id = excluded.channel_id,
                    channel_name = excluded.channel_name,
                    thread_id = excluded.thread_id,
                    thread_name = excluded.thread_name,
                    author_id = excluded.author_id,
                    author_name = excluded.author_name,
                    content = excluded.content,
                    created_at = excluded.created_at,
                    edited_at = excluded.edited_at,
                    deleted_at = excluded.deleted_at,
                    jump_url = excluded.jump_url,
                    fetched_at = excluded.fetched_at
                """,
                row,
            )
            if att_rows is not None:
                self._conn.execute(
                    "DELETE FROM attachments WHERE message_id = ?", (stored.message_id,)
                )
            if att_rows:
                self._conn.executemany(
                    """
                    INSERT INTO attachments
                        (message_id, attachment_id, filename, content_type, size,
                         url, local_path, status, extract_status, extracted_text,
                         error, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    att_rows,
                )
            if url_rows is not None:
                self._conn.execute("DELETE FROM urls WHERE message_id = ?", (stored.message_id,))
            if url_rows:
                self._conn.executemany(
                    """
                    INSERT INTO urls
                        (message_id, url_index, url, normalized_url, fetch_status,
                         title, description, error, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    url_rows,
                )

    def mark_deleted(self, message_id: int, when: dt.datetime | None = None) -> bool:
        """削除済みにする。既に無ければ False。"""
        when = when or dt.datetime.now(dt.UTC)
        with self._lock:
            cursor = self._conn.execute(
                "UPDATE messages SET deleted_at = ? WHERE message_id = ?",
                (to_iso(when), message_id),
            )
        return cursor.rowcount > 0

    # ---------- read ----------

    _MESSAGE_COLUMNS = (
        "message_id, guild_id, channel_id, channel_name, thread_id, thread_name, "
        "author_id, author_name, content, created_at, edited_at, deleted_at, "
        "jump_url, fetched_at"
    )

    def _row_to_message(self, row: tuple[Any, ...]) -> StoredMessage:
        return StoredMessage(
            message_id=int(row[0]),
            guild_id=int(row[1]),
            channel_id=int(row[2]),
            channel_name=str(row[3]),
            thread_id=int(row[4]) if row[4] is not None else None,
            thread_name=str(row[5]) if row[5] is not None else None,
            author_id=int(row[6]),
            author_name=str(row[7]),
            content=str(row[8]),
            created_at=dt.datetime.fromisoformat(row[9]),
            edited_at=from_iso(row[10]),
            deleted_at=from_iso(row[11]),
            jump_url=str(row[12]),
            fetched_at=from_iso(row[13]) or dt.datetime.now(dt.UTC),
        )

    def get_message(self, message_id: int) -> StoredMessage | None:
        with self._lock:
            row = self._conn.execute(
                f"SELECT {self._MESSAGE_COLUMNS} FROM messages WHERE message_id = ?",
                (message_id,),
            ).fetchone()
        if row is None:
            return None
        return self._row_to_message(row)

    def latest_created_at_for_scope(
        self,
        *,
        channel_id: int | None = None,
        thread_id: int | None = None,
    ) -> dt.datetime | None:
        """チャンネルまたはスレッドごとの最新 created_at。catchup の after に使う。"""
        if thread_id is not None:
            where_sql = "thread_id = ?"
            params: tuple[object, ...] = (thread_id,)
        elif channel_id is not None:
            where_sql = "channel_id = ? AND thread_id IS NULL"
            params = (channel_id,)
        else:
            with self._lock:
                row = self._conn.execute("SELECT MAX(created_at) FROM messages").fetchone()
            if not row or not row[0]:
                return None
            return dt.datetime.fromisoformat(str(row[0]))
        with self._lock:
            row = self._conn.execute(
                f"SELECT MAX(created_at) FROM messages WHERE {where_sql}",
                params,
            ).fetchone()
        if not row or not row[0]:
            return None
        return dt.datetime.fromisoformat(str(row[0]))

    def list_channels(self, *, limit: int = 200) -> list[dict[str, Any]]:
        """収録済みチャンネルの件数と最終発言。"""
        cap = max(1, min(500, int(limit)))
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT channel_id, channel_name, COUNT(*) AS n, MAX(created_at)
                FROM messages
                WHERE deleted_at IS NULL
                GROUP BY channel_id, channel_name
                ORDER BY MAX(created_at) DESC
                LIMIT ?
                """,
                (cap,),
            ).fetchall()
        return [
            {
                "channel_id": int(row[0]),
                "channel_name": str(row[1]),
                "message_count": int(row[2]),
                "last_message_at": str(row[3]) if row[3] is not None else None,
            }
            for row in rows
        ]

    def list_messages(
        self,
        *,
        channel_id: int | None = None,
        thread_id: int | None = None,
        author_id: int | None = None,
        from_dt: dt.datetime | None = None,
        to_dt: dt.datetime | None = None,
        include_deleted: bool = False,
        limit: int = 50,
    ) -> list[StoredMessage]:
        """新しい順の一覧。キーワード無しの最近の発言用。"""
        clauses: list[str] = []
        params: list[object] = []
        if channel_id is not None:
            clauses.append("channel_id = ?")
            params.append(channel_id)
        if thread_id is not None:
            clauses.append("thread_id = ?")
            params.append(thread_id)
        if author_id is not None:
            clauses.append("author_id = ?")
            params.append(author_id)
        if from_dt is not None:
            clauses.append("created_at >= ?")
            params.append(to_iso(from_dt))
        if to_dt is not None:
            clauses.append("created_at < ?")
            params.append(to_iso(to_dt))
        if not include_deleted:
            clauses.append("deleted_at IS NULL")
        where = " AND ".join(clauses) if clauses else "1=1"
        cap = max(1, min(200, int(limit)))
        with self._lock:
            rows = self._conn.execute(
                f"""
                SELECT {self._MESSAGE_COLUMNS} FROM messages
                WHERE {where}
                ORDER BY created_at DESC, message_id DESC
                LIMIT ?
                """,
                (*params, cap),
            ).fetchall()
        return [self._row_to_message(row) for row in rows]

    def require_message(self, message_id: int) -> StoredMessage:
        message = self.get_message(message_id)
        if message is None:
            raise MessageNotFound(message_id)
        return message

    def fetch_attachments_for_message(self, message_id: int) -> list[StoredAttachment]:
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT message_id, attachment_id, filename, content_type, size, url,
                       local_path, status, extract_status, extracted_text, error,
                       fetched_at
                FROM attachments WHERE message_id = ? ORDER BY attachment_id
                """,
                (message_id,),
            ).fetchall()
        return [self._row_to_attachment(r) for r in rows]

    def fetch_urls_for_message(self, message_id: int) -> list[StoredUrl]:
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT message_id, url_index, url, normalized_url, fetch_status,
                       title, description, error, fetched_at
                FROM urls WHERE message_id = ? ORDER BY url_index
                """,
                (message_id,),
            ).fetchall()
        return [self._row_to_url(r) for r in rows]

    @staticmethod
    def _row_to_attachment(row: tuple[Any, ...]) -> StoredAttachment:
        return StoredAttachment(
            message_id=int(row[0]),
            attachment_id=int(row[1]),
            filename=str(row[2]),
            content_type=str(row[3]) if row[3] is not None else None,
            size=int(row[4]),
            url=str(row[5]),
            local_path=str(row[6]) if row[6] is not None else None,
            status=str(row[7]),
            extract_status=str(row[8]) if row[8] is not None else None,
            extracted_text=str(row[9]) if row[9] is not None else None,
            error=str(row[10]) if row[10] is not None else None,
            fetched_at=from_iso(row[11]),
        )

    @staticmethod
    def _row_to_url(row: tuple[Any, ...]) -> StoredUrl:
        return StoredUrl(
            message_id=int(row[0]),
            url_index=int(row[1]),
            url=str(row[2]),
            normalized_url=str(row[3]),
            fetch_status=str(row[4]),
            title=str(row[5]) if row[5] is not None else None,
            description=str(row[6]) if row[6] is not None else None,
            error=str(row[7]) if row[7] is not None else None,
            fetched_at=from_iso(row[8]),
        )

    def fetch_context(
        self,
        message_id: int,
        *,
        before: int = 5,
        after: int = 5,
        include_deleted: bool = False,
    ) -> tuple[StoredMessage, list[StoredMessage], list[StoredMessage]]:
        """anchor と、同じスレッド／チャンネル内の前後文脈を返す。"""
        anchor = self.require_message(message_id)
        if anchor.thread_id is not None:
            scope_sql = "m.thread_id = ?"
            scope_params: tuple[object, ...] = (anchor.thread_id,)
        else:
            scope_sql = "m.channel_id = ? AND m.thread_id IS NULL"
            scope_params = (anchor.channel_id,)
        deleted_sql = "" if include_deleted else " AND m.deleted_at IS NULL"
        anchor_iso = to_iso(anchor.created_at)

        with self._lock:
            before_rows = self._conn.execute(
                f"""
                SELECT {self._MESSAGE_COLUMNS} FROM messages m
                WHERE {scope_sql}
                  AND (m.created_at < ? OR (m.created_at = ? AND m.message_id < ?))
                  {deleted_sql}
                ORDER BY m.created_at DESC, m.message_id DESC
                LIMIT ?
                """,
                (*scope_params, anchor_iso, anchor_iso, message_id, before),
            ).fetchall()
            after_rows = self._conn.execute(
                f"""
                SELECT {self._MESSAGE_COLUMNS} FROM messages m
                WHERE {scope_sql}
                  AND (m.created_at > ? OR (m.created_at = ? AND m.message_id > ?))
                  {deleted_sql}
                ORDER BY m.created_at ASC, m.message_id ASC
                LIMIT ?
                """,
                (*scope_params, anchor_iso, anchor_iso, message_id, after),
            ).fetchall()
        before_messages = [self._row_to_message(r) for r in reversed(before_rows)]
        after_messages = [self._row_to_message(r) for r in after_rows]
        return anchor, before_messages, after_messages

    def search(
        self,
        *,
        query: str,
        channel_ids: Sequence[int] | None = None,
        channel_names: Sequence[str] | None = None,
        from_dt: dt.datetime | None = None,
        to_dt: dt.datetime | None = None,
        include_deleted: bool = False,
        limit: int = 20,
        offset: int = 0,
        author_ids: Sequence[int] | None = None,
        author_names: Sequence[str] | None = None,
    ) -> list[SearchHit]:
        """キーワード全文検索。長い語は FTS、短い語は LIKE フォールバック。"""
        filters, filter_params = self._search_filters(
            channel_ids=channel_ids,
            channel_names=channel_names,
            from_dt=from_dt,
            to_dt=to_dt,
            include_deleted=include_deleted,
            author_ids=author_ids,
            author_names=author_names,
        )
        terms = _split_terms(query)
        if terms and self._fts and all(len(term) >= MIN_FTS_TERM_LEN for term in terms):
            try:
                return self._search_fts(query, filters, filter_params, limit=limit, offset=offset)
            except sqlite3.OperationalError as exc:
                # FTS 構文エラーは LIKE に落とす（`"` や `*` など）。
                logger.info("FTS クエリを LIKE に落とした: %s", exc)
        return self._search_like(
            terms or [query], filters, filter_params, limit=limit, offset=offset
        )

    def _search_filters(
        self,
        *,
        channel_ids: Sequence[int] | None,
        channel_names: Sequence[str] | None,
        from_dt: dt.datetime | None,
        to_dt: dt.datetime | None,
        include_deleted: bool,
        author_ids: Sequence[int] | None = None,
        author_names: Sequence[str] | None = None,
    ) -> tuple[str, list[object]]:
        clauses: list[str] = []
        params: list[object] = []
        if channel_ids:
            clauses.append(f"m.channel_id IN ({_placeholders(channel_ids)})")
            params.extend(channel_ids)
        if channel_names:
            clauses.append(f"m.channel_name IN ({_placeholders(channel_names)})")
            params.extend(channel_names)
        if author_ids:
            clauses.append(f"m.author_id IN ({_placeholders(author_ids)})")
            params.extend(author_ids)
        if author_names:
            clauses.append(f"m.author_name IN ({_placeholders(author_names)})")
            params.extend(author_names)
        if from_dt is not None:
            clauses.append("m.created_at >= ?")
            params.append(to_iso(from_dt))
        if to_dt is not None:
            clauses.append("m.created_at < ?")
            params.append(to_iso(to_dt))
        if not include_deleted:
            clauses.append("m.deleted_at IS NULL")
        if not clauses:
            return "1=1", params
        return " AND ".join(clauses), params

    def _search_fts(
        self,
        query: str,
        filters: str,
        filter_params: list[object],
        *,
        limit: int,
        offset: int,
    ) -> list[SearchHit]:
        sql = f"""
            SELECT {",".join("m." + c for c in self._MESSAGE_COLUMNS.split(", "))},
                   rank,
                   snippet(messages_fts, 0, '{_SNIPPET_OPEN}', '{_SNIPPET_CLOSE}',
                           '{_SNIPPET_ELLIPSIS}', {_SNIPPET_TOKENS}) AS snip
            FROM messages_fts
            JOIN messages m ON m.message_id = messages_fts.rowid
            WHERE messages_fts MATCH ? AND {filters}
            ORDER BY rank
            LIMIT ? OFFSET ?
        """
        with self._lock:
            rows = self._conn.execute(
                sql,
                (query, *filter_params, limit, offset),
            ).fetchall()
        hits: list[SearchHit] = []
        for row in rows:
            message = self._row_to_message(row[: len(self._MESSAGE_COLUMNS.split(", "))])
            hits.append(SearchHit(message=message, snippet=str(row[-1]), rank=float(row[-2])))
        return hits

    def _search_like(
        self,
        terms: Sequence[str],
        filters: str,
        filter_params: list[object],
        *,
        limit: int,
        offset: int,
    ) -> list[SearchHit]:
        like_clauses: list[str] = []
        like_params: list[object] = []
        for term in terms:
            like_clauses.append("m.content LIKE ? ESCAPE '\\'")
            like_params.append("%" + _escape_like(term) + "%")
        sql = f"""
            SELECT {self._MESSAGE_COLUMNS} FROM messages m
            WHERE ({") AND (".join(like_clauses)}) AND {filters}
            ORDER BY m.created_at DESC, m.message_id DESC
            LIMIT ? OFFSET ?
        """
        with self._lock:
            rows = self._conn.execute(sql, (*like_params, *filter_params, limit, offset)).fetchall()
        hits: list[SearchHit] = []
        for row in rows:
            message = self._row_to_message(row)
            hits.append(SearchHit(message=message, snippet=_make_snippet(message.content, terms)))
        return hits

    def search_attachments(
        self,
        *,
        query: str,
        channel_ids: Sequence[int] | None = None,
        channel_names: Sequence[str] | None = None,
        from_dt: dt.datetime | None = None,
        to_dt: dt.datetime | None = None,
        include_deleted: bool = False,
        limit: int = 20,
        offset: int = 0,
    ) -> list[tuple[StoredAttachment, StoredMessage, str]]:
        """添付のファイル名・抽出本文の検索。全語 AND、filename/extracted_text 横断。"""
        clauses = ["a.status = 'ok'"]
        params: list[object] = []
        if channel_ids:
            clauses.append(f"m.channel_id IN ({_placeholders(channel_ids)})")
            params.extend(channel_ids)
        if channel_names:
            clauses.append(f"m.channel_name IN ({_placeholders(channel_names)})")
            params.extend(channel_names)
        if from_dt is not None:
            clauses.append("m.created_at >= ?")
            params.append(to_iso(from_dt))
        if to_dt is not None:
            clauses.append("m.created_at < ?")
            params.append(to_iso(to_dt))
        if not include_deleted:
            clauses.append("m.deleted_at IS NULL")
        where = " AND ".join(clauses)

        terms = _split_terms(query)
        rows: list[Any] | None = None
        if terms and self._fts and all(len(t) >= MIN_FTS_TERM_LEN for t in terms):
            sql = f"""
                SELECT a.message_id, a.attachment_id, a.filename, a.content_type,
                       a.size, a.url, a.local_path, a.status, a.extract_status,
                       a.extracted_text, a.error, a.fetched_at,
                       {",".join("m." + c for c in self._MESSAGE_COLUMNS.split(", "))},
                       rank,
                       snippet(attachments_fts, 0, '{_SNIPPET_OPEN}', '{_SNIPPET_CLOSE}',
                               '{_SNIPPET_ELLIPSIS}', 12) AS snip
                FROM attachments_fts
                JOIN attachments a ON a.rowid = attachments_fts.rowid
                JOIN messages m ON m.message_id = a.message_id
                WHERE attachments_fts MATCH ? AND {where}
                ORDER BY rank
                LIMIT ? OFFSET ?
            """
            try:
                with self._lock:
                    rows = self._conn.execute(
                        sql,
                        (query, *params, limit, offset),
                    ).fetchall()
            except sqlite3.OperationalError as exc:
                logger.info("添付 FTS クエリを LIKE に落とした: %s", exc)
                rows = None
        if rows is None:
            like_clauses: list[str] = []
            like_params = []
            for term in terms or [query]:
                like_clauses.append(
                    "(a.filename LIKE ? ESCAPE '\\' OR a.extracted_text LIKE ? ESCAPE '\\')"
                )
                pattern = "%" + _escape_like(term) + "%"
                like_params.extend([pattern, pattern])
            sql = f"""
                SELECT a.message_id, a.attachment_id, a.filename, a.content_type,
                       a.size, a.url, a.local_path, a.status, a.extract_status,
                       a.extracted_text, a.error, a.fetched_at,
                       {",".join("m." + c for c in self._MESSAGE_COLUMNS.split(", "))}
                FROM attachments a JOIN messages m ON m.message_id = a.message_id
                WHERE ({" AND ".join(like_clauses)}) AND {where}
                ORDER BY m.created_at DESC
                LIMIT ? OFFSET ?
            """
            with self._lock:
                rows = self._conn.execute(sql, (*like_params, *params, limit, offset)).fetchall()

        col_count = 12
        out: list[tuple[StoredAttachment, StoredMessage, str]] = []
        for row in rows:
            attachment = self._row_to_attachment(row[:col_count])
            message = self._row_to_message(
                row[col_count : col_count + len(self._MESSAGE_COLUMNS.split(", "))]
            )
            snippet = (
                str(row[-1])
                if len(row) > col_count + len(self._MESSAGE_COLUMNS.split(", "))
                else ""
            )
            out.append((attachment, message, snippet))
        return out

    def search_urls(
        self,
        *,
        query: str,
        channel_ids: Sequence[int] | None = None,
        channel_names: Sequence[str] | None = None,
        from_dt: dt.datetime | None = None,
        to_dt: dt.datetime | None = None,
        include_deleted: bool = False,
        limit: int = 20,
        offset: int = 0,
    ) -> list[tuple[StoredUrl, StoredMessage]]:
        """URL・タイトル・説明の検索。全語 AND、url/title/description 横断。"""
        clauses: list[str] = []
        params: list[object] = []
        if channel_ids:
            clauses.append(f"m.channel_id IN ({_placeholders(channel_ids)})")
            params.extend(channel_ids)
        if channel_names:
            clauses.append(f"m.channel_name IN ({_placeholders(channel_names)})")
            params.extend(channel_names)
        if from_dt is not None:
            clauses.append("m.created_at >= ?")
            params.append(to_iso(from_dt))
        if to_dt is not None:
            clauses.append("m.created_at < ?")
            params.append(to_iso(to_dt))
        if not include_deleted:
            clauses.append("m.deleted_at IS NULL")
        where = (" AND " + " AND ".join(clauses)) if clauses else ""

        terms = _split_terms(query)
        if terms and self._fts and all(len(t) >= MIN_FTS_TERM_LEN for t in terms):
            try:
                return self._search_urls_fts(query, where, params, limit=limit, offset=offset)
            except sqlite3.OperationalError:
                pass  # FTS 構文エラー（'.' など）は LIKE に落とす
        return self._search_urls_like(query, where, params, limit=limit, offset=offset)

    def _search_urls_fts(
        self, query: str, where: str, params: list[object], *, limit: int, offset: int
    ) -> list[tuple[StoredUrl, StoredMessage]]:
        sql = f"""
            SELECT u.message_id, u.url_index, u.url, u.normalized_url,
                   u.fetch_status, u.title, u.description, u.error, u.fetched_at,
                   {",".join("m." + c for c in self._MESSAGE_COLUMNS.split(", "))},
                   rank
            FROM urls_fts
            JOIN urls u ON u.rowid = urls_fts.rowid
            JOIN messages m ON m.message_id = u.message_id
            WHERE urls_fts MATCH ?{where}
            ORDER BY rank
            LIMIT ? OFFSET ?
        """
        with self._lock:
            rows = self._conn.execute(sql, (query, *params, limit, offset)).fetchall()
        return [(self._row_to_url(row[:9]), self._row_to_message(row[9:])) for row in rows]

    def _search_urls_like(
        self, query: str, where: str, params: list[object], *, limit: int, offset: int
    ) -> list[tuple[StoredUrl, StoredMessage]]:
        terms = _split_terms(query) or [query]
        per_term = (
            "(u.url LIKE ? ESCAPE '\\' OR u.normalized_url LIKE ? ESCAPE '\\'"
            " OR u.title LIKE ? ESCAPE '\\' OR u.description LIKE ? ESCAPE '\\')"
        )
        like_clauses = " AND ".join([per_term] * len(terms))
        like_params: list[object] = []
        for term in terms:
            pattern = "%" + _escape_like(term) + "%"
            like_params.extend([pattern, pattern, pattern, pattern])
        sql = f"""
            SELECT u.message_id, u.url_index, u.url, u.normalized_url,
                   u.fetch_status, u.title, u.description, u.error, u.fetched_at,
                   {",".join("m." + c for c in self._MESSAGE_COLUMNS.split(", "))}
            FROM urls u JOIN messages m ON m.message_id = u.message_id
            WHERE ({like_clauses}){where}
            ORDER BY m.created_at DESC
            LIMIT ? OFFSET ?
        """
        with self._lock:
            rows = self._conn.execute(sql, (*like_params, *params, limit, offset)).fetchall()
        return [(self._row_to_url(row[:9]), self._row_to_message(row[9:])) for row in rows]


def _make_snippet(content: str, terms: Sequence[str]) -> str:
    """LIKE フォールバック用の簡易 snippet。最初のヒット周辺を返す。"""
    haystack = content.replace("\n", " ")
    best = -1
    best_term = "前後の前後"
    lower = haystack.casefold()
    for term in terms:
        idx = lower.find(term.casefold())
        if idx >= 0 and (best < 0 or idx < best):
            best = idx
            best_term = term
    if best < 0:
        return haystack[:80] + (_SNIPPET_ELLIPSIS if len(haystack) > 80 else "")
    start = max(0, best - 40)
    end = min(len(haystack), best + len(best_term) + 40)
    prefix = _SNIPPET_ELLIPSIS if start > 0 else ""
    suffix = _SNIPPET_ELLIPSIS if end < len(haystack) else ""
    return f"{prefix}{haystack[start:end]}{suffix}"
