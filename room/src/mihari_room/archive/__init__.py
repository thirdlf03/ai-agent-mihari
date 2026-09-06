"""Discord アーカイブ。作業部屋の履歴を SQLite に溜めて CLI から引けるようにする。

- ``messages.db``（WAL）＋ FTS5 trigram で全文検索。
- 本文・添付・URL を出典として保存し、``python -m mihari_room.archive`` で検索できる。
- 収録は Gateway の ``on_message`` から bounded キュー経由。Gateway は塞がない。
"""

from mihari_room.archive.config import (
    ALLOWED_ATTACHMENT_EXTENSIONS,
    ArchiveConfig,
    allowed_attachment,
    load_archive_config,
)
from mihari_room.archive.db import ArchiveDatabase
from mihari_room.archive.ingest import ArchiveIngester

__all__ = [
    "ALLOWED_ATTACHMENT_EXTENSIONS",
    "ArchiveConfig",
    "ArchiveDatabase",
    "ArchiveIngester",
    "allowed_attachment",
    "load_archive_config",
]
