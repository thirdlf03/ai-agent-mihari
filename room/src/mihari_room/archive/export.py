"""ジョブへの出典コピー。``export --job-id ... --message-id ...`` の本体。

- ジョブの実在を確かめ、``jobs/<id>/research/downloads`` の内側だけを触る。
  シンボリックリンクで root の外へ逃げるパスはそもそも弾く。
- 添付は既に落ちていればコピー、無ければ安全な取得器で取る（無効設定ならスキップ）。
- ``sources.json``（jump_url とファイル名を出典として）と ``summary.md`` を書く。
"""

from __future__ import annotations

import json
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from mihari_room.archive.config import ArchiveConfig
from mihari_room.archive.db import ArchiveDatabase, MessageNotFound
from mihari_room.archive.fetch import SafeFetcher
from mihari_room.archive.models import AttachmentStatus, StoredMessage
from mihari_room.archive.pathutil import ensure_contained, sanitize_filename
from mihari_room.store.file_store import FileJobStore, JobNotFound

RESEARCH_DIRNAME = "research"
DOWNLOAD_DIRNAME = "downloads"
SOURCES_FILENAME = "sources.json"
SUMMARY_FILENAME = "summary.md"


class ExportError(RuntimeError):
    """export が続けられない。理由を message に持つ。"""


@dataclass(slots=True)
class ExportResult:
    job_id: str
    message_id: int
    downloads_dir: Path
    sources_path: Path
    summary_path: Path
    downloaded: list[dict[str, Any]]
    skipped: list[dict[str, Any]]
    sources: list[dict[str, Any]]
    job: dict[str, Any]
    message_payload: dict[str, Any] = field(default_factory=dict)


async def export_message(
    config: ArchiveConfig,
    *,
    job_id: str,
    message_id: int,
    fetcher: SafeFetcher | None = None,
    db: ArchiveDatabase | None = None,
) -> ExportResult:
    """指定メッセージの添付をジョブへコピーし、出典 JSON と概要を書く。"""
    owned_db = db is None
    database = db or ArchiveDatabase(config.db_path)
    try:
        try:
            message = database.require_message(message_id)
        except MessageNotFound as exc:
            raise ExportError(f"メッセージが archive に無い: {message_id}") from exc

        store = FileJobStore(config.root)
        try:
            job = store.get(job_id)
        except JobNotFound as exc:
            raise ExportError(f"ジョブが無い: {job_id}") from exc

        # ジョブ置き場自体が root の外を指す symlink だったら弾く。
        try:
            ensure_contained(store.job_dir(job_id), config.root)
            downloads_dir = ensure_contained(
                store.job_dir(job_id) / RESEARCH_DIRNAME / DOWNLOAD_DIRNAME,
                store.job_dir(job_id),
            )
        except ValueError as exc:
            raise ExportError(f"ジョブ置き場の検証に失敗: {exc}") from exc
        downloads_dir.mkdir(parents=True, exist_ok=True)

        sources: list[dict[str, Any]] = [
            {
                "type": "discord-message",
                "message_id": message.message_id,
                "jump_url": message.jump_url,
                "author_id": message.author_id,
                "author_name": message.author_name,
                "created_at": message.created_at.astimezone().isoformat(),
                "content": message.content,
            }
        ]
        downloaded: list[dict[str, Any]] = []
        skipped: list[dict[str, Any]] = []

        await _copy_attachments(
            database,
            config,
            fetcher,
            message,
            downloads_dir,
            sources,
            downloaded,
            skipped,
        )

        for url in database.fetch_urls_for_message(message.message_id):
            source = {
                "type": "url",
                "url": url.url,
                "normalized_url": url.normalized_url,
                "title": url.title,
                "description": url.description,
                "fetch_status": url.fetch_status,
            }
            sources.append(source)

        meta = _read_meta(store.job_dir(job_id))
        job_payload = {
            "id": job.id,
            "title": job.title,
            "source": job.source.value,
            "status": job.status.value,
            "body": job.body,
            "meta": meta,
        }
        message_payload = _message_slim(database, message, downloads_dir)
        sources_path = downloads_dir / SOURCES_FILENAME
        summary_path = downloads_dir / SUMMARY_FILENAME
        sources_json = {
            "schema_version": 1,
            "job": job_payload,
            "message": message_payload,
            "downloaded": downloaded,
            "skipped": skipped,
            "sources": sources,
            "note": "生ログは長期記憶に入れない。jump_url と要約だけを引用すること。",
        }
        sources_path.write_text(
            json.dumps(sources_json, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        summary_path.write_text(
            _render_summary(job_payload, message, downloaded, skipped, sources),
            encoding="utf-8",
        )
        return ExportResult(
            job_id=job_id,
            message_id=message_id,
            downloads_dir=downloads_dir,
            sources_path=sources_path,
            summary_path=summary_path,
            downloaded=downloaded,
            skipped=skipped,
            sources=sources,
            job=job_payload,
            message_payload=message_payload,
        )
    finally:
        if owned_db:
            database.close()


def _read_meta(job_dir: Path) -> dict[str, Any]:
    meta_path = job_dir / "meta.json"
    if not meta_path.is_file():
        return {}
    try:
        raw = json.loads(meta_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return raw if isinstance(raw, dict) else {}


def _message_slim(
    database: ArchiveDatabase, message: StoredMessage, downloads_dir: Path
) -> dict[str, Any]:
    return {
        "message_id": message.message_id,
        "channel_id": message.channel_id,
        "channel_name": message.channel_name,
        "thread_id": message.thread_id,
        "thread_name": message.thread_name,
        "author_id": message.author_id,
        "author_name": message.author_name,
        "content": message.content,
        "created_at": message.created_at.astimezone().isoformat(),
        "jump_url": message.jump_url,
        "attachments": [
            {
                "attachment_id": attachment.attachment_id,
                "filename": attachment.filename,
                "size": attachment.size,
                "url": attachment.url,
                "content_type": attachment.content_type,
                "status": attachment.status,
                "local_path": attachment.local_path,
                "extract_status": attachment.extract_status,
            }
            for attachment in database.fetch_attachments_for_message(message.message_id)
        ],
        "urls": [
            {
                "url": url.url,
                "normalized_url": url.normalized_url,
                "title": url.title,
                "description": url.description,
                "fetch_status": url.fetch_status,
            }
            for url in database.fetch_urls_for_message(message.message_id)
        ],
    }


async def _copy_attachments(
    database: ArchiveDatabase,
    config: ArchiveConfig,
    fetcher: SafeFetcher | None,
    message: StoredMessage,
    downloads_dir: Path,
    sources: list[dict[str, Any]],
    downloaded: list[dict[str, Any]],
    skipped: list[dict[str, Any]],
) -> None:
    for attachment in database.fetch_attachments_for_message(message.message_id):
        entry: dict[str, Any] = {
            "attachment_id": attachment.attachment_id,
            "filename": attachment.filename,
            "size": attachment.size,
            "url": attachment.url,
            "status": attachment.status,
        }
        safe_name = sanitize_filename(attachment.filename)
        target = ensure_contained(
            downloads_dir / f"{attachment.attachment_id}-{safe_name}",
            downloads_dir,
        )
        existing_file = database.resolve_local(attachment.local_path)
        copied = False
        if existing_file is not None and existing_file.is_file():
            try:
                ensure_contained(existing_file, database.root)
                shutil.copy2(existing_file, target)
                copied = True
            except (OSError, ValueError) as exc:
                skipped.append({**entry, "reason": f"コピー失敗: {exc}"})
        elif config.fetch_attachments and fetcher is not None:
            if attachment.status not in {
                AttachmentStatus.SKIPPED_SIZE,
                AttachmentStatus.SKIPPED_TYPE,
            }:
                try:
                    result = await fetcher.download_attachment(
                        attachment.url,
                        max_bytes=config.max_attachment_bytes,
                        timeout=config.download_timeout,
                    )
                    target.write_bytes(result.body)
                    copied = True
                except Exception as exc:
                    skipped.append({**entry, "reason": f"取得失敗: {exc}"})
            else:
                skipped.append({**entry, "reason": _skip_reason(attachment.status)})
        else:
            skipped.append({**entry, "reason": _skip_reason(attachment.status)})

        if copied:
            relative = f"{RESEARCH_DIRNAME}/{DOWNLOAD_DIRNAME}/{target.name}"
            downloaded.append(
                {
                    **entry,
                    "path": relative,
                    "bytes": target.stat().st_size,
                }
            )
            sources.append(
                {
                    "type": "attachment",
                    "filename": attachment.filename,
                    "url": attachment.url,
                    "local_path": str(target),
                }
            )


def _skip_reason(status: str) -> str:
    if status == AttachmentStatus.SKIPPED_SIZE:
        return "サイズ上限で元々スキップ"
    if status == AttachmentStatus.SKIPPED_TYPE:
        return "種類不許可で元々スキップ"
    if status == AttachmentStatus.INDEXED:
        return "添付取得が無効設定"
    return "取得済みファイルが無い"


def _render_summary(
    job: dict[str, Any],
    message: StoredMessage,
    downloaded: list[dict[str, Any]],
    skipped: list[dict[str, Any]],
    sources: list[dict[str, Any]],
) -> str:
    lines = [
        "# 出典メモ",
        "",
        f"- ジョブ: {job.get('title', '')}（{job.get('id', '')}）",
        f"- 投稿: {message.author_name} さん @ {_iso_local(message.created_at)}",
        f"- ジャンプ URL: <{message.jump_url}>",
        "",
        "## 本文",
        "",
        message.content or "（本文なし）",
        "",
        "## 添付",
        "",
    ]
    if not downloaded and not skipped:
        lines.append("（添付なし）")
    for item in downloaded:
        lines.append(f"- {item['filename']} → `{item['path']}`（{item['bytes']} bytes）")
    for item in skipped:
        lines.append(f"- {item['filename']}（スキップ: {item['reason']}）")
    url_sources = [s for s in sources if s["type"] == "url"]
    if url_sources:
        lines.append("")
        lines.append("## URL")
        lines.append("")
        for source in url_sources:
            title = source.get("title")
            label = f"{source['url']}" + (f"（{title}）" if title else "")
            lines.append(f"- {label}")
    lines.extend(
        [
            "",
            "（このメモは長期記憶に入れてよい。生ログの丸ごと保存はしないこと）",
        ]
    )
    return "\n".join(lines) + "\n"


def _iso_local(value: Any) -> str:
    return value.astimezone().isoformat()
