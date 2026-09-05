"""Discord Gateway からメッセージをアーカイブへ流す。

- ``on_message`` は bounded キューに突っ込むだけ。Gateway を塞がない。
- チャンネル許可リスト（``MIHARI_ARCHIVE_CHANNEL_IDS``）が無ければ何もしない。
- Bot 投稿は収録しない。編集は上書き、削除は deleted_at。
- 添付は Discord CDN だけ。サイズ・MIME・拡張子の上限と PDF 本文抽出付き。
"""

from __future__ import annotations

import asyncio
import dataclasses
import datetime as dt
import logging
from collections.abc import Sequence
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from mihari_room.archive.config import ArchiveConfig, allowed_attachment
from mihari_room.archive.db import ArchiveDatabase
from mihari_room.archive.fetch import SafeFetcher, extract_urls, normalize_url
from mihari_room.archive.models import (
    AttachmentStatus,
    StoredAttachment,
    StoredMessage,
    StoredUrl,
    UrlStatus,
    utc_now,
)
from mihari_room.archive.pathutil import ensure_contained, sanitize_filename

logger = logging.getLogger("mihari_room.archive")


@dataclasses.dataclass(slots=True)
class _Task:
    """キューに入る仕事。kind で処理を分ける。"""

    kind: str
    data: Any


def _classify_channel(channel: Any) -> tuple[int, str, int | None, str | None]:
    """(channel_id, channel_name, thread_id, thread_name)。スレッドは親チャンネルへ寄せる。"""
    parent = getattr(channel, "parent", None)
    if parent is not None:
        parent_id = int(getattr(parent, "id", 0))
        parent_name = str(getattr(parent, "name", "") or "") or str(parent_id)
        thread_id = int(getattr(channel, "id", 0))
        thread_name = str(getattr(channel, "name", "") or "") or None
        return parent_id, parent_name, thread_id, thread_name
    channel_id = int(getattr(channel, "id", 0))
    channel_name = str(getattr(channel, "name", "") or "") or str(channel_id)
    return channel_id, channel_name, None, None


def _author_fields(author: Any) -> tuple[int, str]:
    author_id = int(getattr(author, "id", 0))
    name = getattr(author, "display_name", None) or getattr(author, "name", None) or str(author_id)
    return author_id, str(name)


def _jump_url_for(guild_id: int, channel_id: int, message_id: int) -> str:
    return f"https://discord.com/channels/{guild_id}/{channel_id}/{message_id}"


def to_stored_message(message: Any) -> StoredMessage:
    """discord.Message や偽装物から StoredMessage を作る。収録可否は呼び出し側で。"""
    channel_id, channel_name, thread_id, thread_name = _classify_channel(
        getattr(message, "channel", None)
    )
    author_id, author_name = _author_fields(getattr(message, "author", None))
    guild_id = int(getattr(getattr(message, "guild", None), "id", 0))
    message_id = int(getattr(message, "id", 0))
    jump_url = str(getattr(message, "jump_url", "") or "") or _jump_url_for(
        guild_id, channel_id, message_id
    )
    return StoredMessage(
        message_id=message_id,
        guild_id=guild_id,
        channel_id=channel_id,
        channel_name=channel_name,
        thread_id=thread_id,
        thread_name=thread_name,
        author_id=author_id,
        author_name=author_name,
        content=str(getattr(message, "content", "") or ""),
        created_at=_as_datetime(getattr(message, "created_at", utc_now())) or utc_now(),
        jump_url=jump_url,
        edited_at=_as_datetime(getattr(message, "edited_at", None)),
    )


def _as_datetime(value: Any) -> dt.datetime | None:
    """文字列や None を datetime に寄せる。既に datetime ならそのまま。"""
    if value is None:
        return None
    if isinstance(value, dt.datetime):
        return value
    if isinstance(value, str):
        try:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=dt.UTC)
            return parsed
        except ValueError:
            return None
    return None


def _channel_accepts(channel_id: int, config: ArchiveConfig) -> bool:
    return channel_id in config.channel_ids


class ArchiveIngester:
    """Gateway とアーカイブを繋ぐ口。``start()`` 後に ``handle_*`` を呼ぶ。"""

    def __init__(
        self,
        config: ArchiveConfig,
        db: ArchiveDatabase | None = None,
        *,
        fetcher: SafeFetcher | None = None,
    ) -> None:
        self._config = config
        self._fetcher = fetcher or SafeFetcher(
            max_redirects=config.max_redirects,
        )
        # DB とキューは start() まで作らない。
        # 無効設定で構築しても空ファイルを作らないし、ループ外で作っても安全。
        self._db = db
        self._queue: asyncio.Queue[_Task] | None = None
        self._worker: asyncio.Task[None] | None = None
        self._closed = False

    @property
    def config(self) -> ArchiveConfig:
        return self._config

    @property
    def db(self) -> ArchiveDatabase | None:
        return self._db

    @property
    def enabled(self) -> bool:
        return self._config.enabled

    def _ensure_started(self) -> None:
        """受付の入口から呼ぶ。有効ならワーカーを立てる。"""
        if self.enabled and (self._worker is None or self._worker.done()):
            self.start()

    def start(self) -> None:
        """ワーカーを立てる。有効でない設定なら何もしない。ループ内で呼ぶ。"""
        if not self.enabled:
            logger.info("アーカイブは無効（MIHARI_ARCHIVE_CHANNEL_IDS 未設定）")
            return
        if self._worker is None or self._worker.done():
            if self._db is None:
                self._db = ArchiveDatabase(self._config.db_path)
            self._queue = asyncio.Queue(maxsize=self._config.queue_size)
            self._worker = asyncio.create_task(self._run(), name="mihari-room-archive-worker")
            logger.info(
                "アーカイブ開始: db=%s channels=%s",
                self._config.db_path,
                ",".join(str(c) for c in self._config.channel_ids),
            )

    async def _submit(self, task: _Task) -> None:
        """bounded キューへ突っ込む。一杯なら落とす（Gateway は塞がない）。"""
        if self._closed or self._worker is None or self._queue is None:
            return
        try:
            self._queue.put_nowait(task)
        except asyncio.QueueFull:
            logger.warning("アーカイブのキューが一杯。1 件落とした: %s", task.kind)

    async def handle_message(self, message: Any) -> None:
        """``on_message`` から。Bot・ギルド外・未許可チャンネルは落とす。"""
        if not self.enabled or self._closed:
            return
        self._ensure_started()
        try:
            if not self._accepts(message):
                return
            await self._submit(_Task("message", message))
        except Exception:
            logger.exception("アーカイブ受付に失敗 message=%s", getattr(message, "id", "?"))

    def _accepts(self, message: Any) -> bool:
        guild = getattr(message, "guild", None)
        if guild is None:
            return False
        author = getattr(message, "author", None)
        if author is not None and bool(getattr(author, "bot", False)):
            return False
        channel_id, _channel_name, _thread_id, _thread_name = _classify_channel(
            getattr(message, "channel", None)
        )
        return _channel_accepts(channel_id, self._config)

    async def handle_message_edit(self, before: Any, after: Any) -> None:
        """``on_message_edit`` から。キャッシュ済みメッセージの全更新。"""
        if not self.enabled or self._closed:
            return
        self._ensure_started()
        try:
            if not self._accepts(after):
                return
            await self._submit(_Task("message", after))
        except Exception:
            logger.exception("アーカイブ編集受付に失敗 message=%s", getattr(after, "id", "?"))

    async def handle_raw_edit(self, payload: Any) -> None:
        """``on_raw_message_edit`` から。収録済みメッセージだけ部分更新する。"""
        if not self.enabled or self._closed:
            return
        self._ensure_started()
        try:
            data = getattr(payload, "data", None)
            if not isinstance(data, dict):
                return
            try:
                message_id = int(data.get("id") or 0)
            except (TypeError, ValueError):
                return
            if not message_id:
                return
            existing = self._db.get_message(message_id)
            if existing is None:
                return  # 収録していないメッセージの edit は無視
            await self._submit(_Task("raw_edit", (data, existing)))
        except Exception:
            logger.exception("アーカイブ raw edit 受付に失敗")

    async def handle_raw_delete(self, payload: Any) -> None:
        """``on_raw_message_delete`` から。収録済みなら deleted_at を立てる。"""
        if not self.enabled or self._closed:
            return
        self._ensure_started()
        try:
            message_id = int(getattr(payload, "message_id", 0) or 0)
            if message_id and self._db.get_message(message_id) is not None:
                await self._submit(_Task("delete", message_id))
        except Exception:
            logger.exception("アーカイブ raw delete 受付に失敗")

    async def handle_raw_bulk_delete(self, payload: Any) -> None:
        """``on_raw_bulk_message_delete`` から。複数件まとめて削除する。"""
        if not self.enabled or self._closed:
            return
        self._ensure_started()
        try:
            data = getattr(payload, "data", None)
            if not isinstance(data, dict):
                return
            ids = data.get("ids") or ()
            for raw in ids:
                try:
                    message_id = int(raw)
                except (TypeError, ValueError):
                    continue
                if message_id and self._db.get_message(message_id) is not None:
                    await self._submit(_Task("delete", message_id))
        except Exception:
            logger.exception("アーカイブ raw bulk delete 受付に失敗")

    async def aclose(self, drain_timeout: float = 5.0) -> None:
        """受け付けを止め、残りを流してからワーカーと DB を閉じる。"""
        if self._closed:
            return
        self._closed = True
        worker = self._worker
        if worker is not None and self._queue is not None:
            try:
                await asyncio.wait_for(self._queue.join(), timeout=drain_timeout)
            except TimeoutError:
                logger.warning("アーカイブの残り %d 件を捨てて閉じる", self._queue.qsize())
            worker.cancel()
            try:
                await worker
            except asyncio.CancelledError:
                pass
        await self._fetcher.aclose()
        if self._db is not None:
            self._db.close()

    async def _run(self) -> None:
        try:
            while True:
                task = await self._queue.get()
                try:
                    if task.kind == "message":
                        await self._ingest_message(task.data)
                    elif task.kind == "raw_edit":
                        await self._ingest_raw_edit(task.data)
                    elif task.kind == "delete":
                        self._db.mark_deleted(int(task.data))
                except asyncio.CancelledError:
                    raise
                except Exception:
                    logger.exception("アーカイブ処理に失敗 kind=%s", task.kind)
                finally:
                    self._queue.task_done()
        except asyncio.CancelledError:
            raise

    # ---------- capture ----------

    async def _ingest_message(self, message: Any) -> None:
        stored = to_stored_message(message)
        attachments = await self._capture_attachments(
            stored.message_id, getattr(message, "attachments", ()) or ()
        )
        urls = await self._capture_urls(stored.content, stored.message_id)
        await asyncio.to_thread(self._db.upsert_message, stored, attachments=attachments, urls=urls)

    async def _ingest_raw_edit(self, task_data: tuple[dict[str, Any], StoredMessage]) -> None:
        data, existing = task_data
        content = str(data.get("content") or "")
        attachments = await self._capture_attachments(
            existing.message_id, _raw_attachments(data.get("attachments") or ())
        )
        urls = await self._capture_urls(content, existing.message_id)
        updated = dataclasses.replace(
            existing,
            content=content,
            edited_at=_as_datetime(
                (data.get("edited_timestamp") or "").replace("Z", "+00:00") or None
            ),
            fetched_at=utc_now(),
        )
        await asyncio.to_thread(
            self._db.upsert_message, updated, attachments=attachments, urls=urls
        )

    async def _capture_attachments(
        self, message_id: int, attachments: Sequence[Any]
    ) -> list[StoredAttachment]:
        """添付の一覧を保存形へ。既に取得済みなら再ダウンロードしない。"""
        existing = {a.attachment_id: a for a in self._db.fetch_attachments_for_message(message_id)}
        out: list[StoredAttachment] = []
        for index, attachment in enumerate(attachments):
            attachment_id = int(getattr(attachment, "id", index))
            filename = str(getattr(attachment, "filename", "attachment") or "attachment")
            size = int(getattr(attachment, "size", 0) or 0)
            url = str(getattr(attachment, "url", "") or "")
            content_type = getattr(attachment, "content_type", None)
            prior = existing.get(attachment_id)
            if prior is not None and prior.status == AttachmentStatus.OK:
                local = self._db.resolve_local(prior.local_path)
                if local is not None and local.is_file():
                    out.append(prior)
                    continue
            out.append(
                await self._capture_attachment(
                    message_id, attachment_id, filename, size, url, content_type
                )
            )
        return out

    async def _capture_attachment(
        self,
        message_id: int,
        attachment_id: int,
        filename: str,
        size: int,
        url: str,
        content_type: str | None,
    ) -> StoredAttachment:
        if size > self._config.max_attachment_bytes:
            return StoredAttachment(
                message_id=message_id,
                attachment_id=attachment_id,
                filename=filename,
                size=size,
                url=url,
                content_type=content_type,
                status=AttachmentStatus.SKIPPED_SIZE,
                error=(f"size {size} over {self._config.max_attachment_bytes} bytes"),
            )
        if not allowed_attachment(content_type, filename):
            return StoredAttachment(
                message_id=message_id,
                attachment_id=attachment_id,
                filename=filename,
                size=size,
                url=url,
                content_type=content_type,
                status=AttachmentStatus.SKIPPED_TYPE,
                error=f"not allowed: {content_type or ''} {filename}",
            )
        if not self._config.fetch_attachments:
            return StoredAttachment(
                message_id=message_id,
                attachment_id=attachment_id,
                filename=filename,
                size=size,
                url=url,
                content_type=content_type,
                status=AttachmentStatus.INDEXED,
            )
        safe_name = sanitize_filename(filename)
        relative = (
            Path("archive") / "attachments" / str(message_id) / (f"{attachment_id}-{safe_name}")
        )
        storage = self._config.root / relative
        try:
            ensure_contained(storage, self._config.attachments_dir)
            storage.parent.mkdir(parents=True, exist_ok=True)
            result = await self._fetcher.download_attachment(
                url,
                max_bytes=self._config.max_attachment_bytes,
                timeout=self._config.download_timeout,
            )
            storage.write_bytes(result.body)
        except Exception as exc:
            return StoredAttachment(
                message_id=message_id,
                attachment_id=attachment_id,
                filename=filename,
                size=size,
                url=url,
                content_type=content_type,
                status=AttachmentStatus.ERROR,
                error=str(exc),
            )
        extract_status: str | None = None
        extracted_text: str | None = None
        error: str | None = None
        if filename.lower().endswith(".pdf"):
            extracted_text, error = await asyncio.to_thread(
                _extract_pdf_text, storage, self._config.pdf_max_chars
            )
            if extracted_text:
                extract_status = "pdf_text"
            elif error:
                extract_status = "error"
            else:
                extract_status = "none"
        return StoredAttachment(
            message_id=message_id,
            attachment_id=attachment_id,
            filename=filename,
            size=size,
            url=url,
            content_type=content_type,
            local_path=str(relative.as_posix()),
            status=AttachmentStatus.OK,
            extract_status=extract_status,
            extracted_text=extracted_text,
            error=error,
            fetched_at=utc_now(),
        )

    async def _capture_urls(self, content: str, message_id: int) -> list[StoredUrl]:
        """本文の URL を正規化して索引し、メタ取得を試みる（失敗しても URL は残す）。"""
        out: list[StoredUrl] = []
        seen: set[str] = set()
        for index, raw in enumerate(extract_urls(content)):
            try:
                normalized = normalize_url(raw)
            except ValueError:
                out.append(
                    StoredUrl(
                        message_id=message_id,
                        url_index=index,
                        url=raw,
                        normalized_url="",
                        fetch_status=UrlStatus.SKIPPED,
                        error="unsupported scheme",
                    )
                )
                continue
            if normalized in seen:
                continue
            seen.add(normalized)
            if not self._config.fetch_urls:
                out.append(
                    StoredUrl(
                        message_id=message_id,
                        url_index=index,
                        url=raw,
                        normalized_url=normalized,
                        fetch_status=UrlStatus.DISABLED,
                    )
                )
                continue
            metadata = await self._fetcher.fetch_url_metadata(
                normalized,
                max_bytes=self._config.max_url_bytes,
                timeout=self._config.url_timeout,
            )
            out.append(
                StoredUrl(
                    message_id=message_id,
                    url_index=index,
                    url=raw,
                    normalized_url=normalized,
                    fetch_status=metadata.fetch_status,
                    title=metadata.title,
                    description=metadata.description,
                    error=metadata.error,
                    fetched_at=utc_now(),
                )
            )
        return out


def _raw_attachments(raw: list[Any]) -> list[Any]:
    """raw edit ペイロードの attachments を添付風オブジェクトに寄せる。"""
    out: list[Any] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        out.append(
            SimpleNamespace(
                id=item.get("id"),
                filename=item.get("filename", "attachment"),
                size=item.get("size", 0),
                url=item.get("url", ""),
                content_type=item.get("content_type"),
            )
        )
    return out


def _extract_pdf_text(path: Path, max_chars: int) -> tuple[str | None, str | None]:
    """pypdf で PDF の本文を取る。イベントループの外（to_thread）で呼ぶこと。"""
    try:
        from pypdf import PdfReader
    except ImportError:
        return None, "pypdf が無いので PDF 本文は索引しない"
    try:
        reader = PdfReader(str(path))
        parts: list[str] = []
        total = 0
        for page in reader.pages:
            text = (page.extract_text() or "").strip()
            if not text:
                continue
            parts.append(text)
            total += len(text)
            if total >= max_chars:
                break
        content = " ".join(parts)[:max_chars]
        return (content or None), None
    except Exception as exc:
        return None, str(exc)
