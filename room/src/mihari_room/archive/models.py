"""アーカイブの永続化モデル。DB の行と 1:1 の dataclass。"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field


class AttachmentStatus:
    """添付の取得状態。DB の status 列に入る文字列定数。"""

    OK = "ok"
    #: 取得無効時、メタ情報だけ記録。
    INDEXED = "indexed"
    SKIPPED_SIZE = "skipped_size"
    SKIPPED_TYPE = "skipped_type"
    ERROR = "error"


class UrlStatus:
    """URL の取得状態。"""

    INDEXED = "indexed"
    OK = "ok"
    ERROR = "error"
    DISABLED = "disabled"
    SKIPPED = "skipped"


def utc_now() -> dt.datetime:
    """UTC の現在時刻。DB の文字列も全部これ。"""
    return dt.datetime.now(dt.UTC)


def to_iso(value: dt.datetime | None) -> str | None:
    """UTC ISO 文字列へ。naive は UTC とみなす。"""
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=dt.UTC)
    return value.astimezone(dt.UTC).isoformat()


def from_iso(value: str | None) -> dt.datetime | None:
    """ISO 文字列から時刻へ。naive は UTC 扱い。"""
    if value is None:
        return None
    parsed = dt.datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.UTC)
    return parsed


@dataclass(frozen=True, slots=True)
class StoredMessage:
    """messages テーブルの 1 行。"""

    message_id: int
    guild_id: int
    channel_id: int
    channel_name: str
    author_id: int
    author_name: str
    content: str
    created_at: dt.datetime
    jump_url: str
    thread_id: int | None = None
    thread_name: str | None = None
    edited_at: dt.datetime | None = None
    deleted_at: dt.datetime | None = None
    fetched_at: dt.datetime = field(default_factory=utc_now)


@dataclass(frozen=True, slots=True)
class StoredAttachment:
    """attachments テーブルの 1 行。local_path は root からの相対。"""

    message_id: int
    attachment_id: int
    filename: str
    size: int
    url: str
    content_type: str | None = None
    local_path: str | None = None
    status: str = AttachmentStatus.OK
    extract_status: str | None = None
    extracted_text: str | None = None
    error: str | None = None
    fetched_at: dt.datetime | None = None


@dataclass(frozen=True, slots=True)
class StoredUrl:
    """urls テーブルの 1 行。メタ情報と取得状態を持つ。"""

    message_id: int
    url_index: int
    url: str
    normalized_url: str
    fetch_status: str = UrlStatus.INDEXED
    title: str | None = None
    description: str | None = None
    error: str | None = None
    fetched_at: dt.datetime | None = None


@dataclass(frozen=True, slots=True)
class SearchHit:
    """search の 1 件。FTS なら rank、LIKE フォールバックなら 0。"""

    message: StoredMessage
    snippet: str
    rank: float = 0.0
