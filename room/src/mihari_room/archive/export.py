"""ジョブへの出典コピー。``export --job-id ... --message-id ...`` の本体。

- ジョブの実在を確かめ、``jobs/<id>/research`` の内側だけを触る。
  PDF 実体は ``research/downloads``、目録は ``research/sources.json``、
  概要は ``research/summary.md``。シンボリックリンクで root の外へ逃げる
  パス（ディレクトリもファイルも）はそもそも弾く。
- 添付は既に落ちていればコピー、無ければ安全な取得器で取る（無効設定ならスキップ）。
- ``sources.json`` は追記マージ（安定 ID で重複排除）。既存の model 記述の
  ``summary.md`` は黙って上書きせず追記する。
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
MANIFEST_SCHEMA_VERSION = 1
SUMMARY_MARKER = "# 出典メモ"


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
    source_ids: list[str] = field(default_factory=list)


async def export_message(
    config: ArchiveConfig,
    *,
    job_id: str,
    message_id: int,
    fetcher: SafeFetcher | None = None,
    db: ArchiveDatabase | None = None,
) -> ExportResult:
    """指定メッセージの添付をジョブへコピーし、出典 JSON と概要を追記マージする。"""
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
        # ディレクトリも最終ファイルも解決して検証する。
        try:
            job_dir = ensure_contained(store.job_dir(job_id), config.root)
            research_dir = ensure_contained(job_dir / RESEARCH_DIRNAME, job_dir)
            downloads_dir = ensure_contained(research_dir / DOWNLOAD_DIRNAME, job_dir)
            sources_path = ensure_contained(research_dir / SOURCES_FILENAME, job_dir)
            summary_path = ensure_contained(research_dir / SUMMARY_FILENAME, job_dir)
        except ValueError as exc:
            raise ExportError(f"ジョブ置き場の検証に失敗: {exc}") from exc
        research_dir.mkdir(parents=True, exist_ok=True)
        downloads_dir.mkdir(parents=True, exist_ok=True)
        # mkdir 後の実体を再検証（途中の symlink 差し替え対策）。
        try:
            ensure_contained(downloads_dir, job_dir)
            ensure_contained(research_dir, job_dir)
        except ValueError as exc:
            raise ExportError(f"ジョブ置き場の検証に失敗: {exc}") from exc

        new_sources = _message_sources(database, message)
        downloaded: list[dict[str, Any]] = []
        skipped: list[dict[str, Any]] = []

        await _copy_attachments(
            database,
            config,
            fetcher,
            message,
            downloads_dir,
            job_dir,
            new_sources,
            downloaded,
            skipped,
        )

        merged_sources, source_ids = _merge_manifest(sources_path, new_sources)
        # 生ログの塊はメモリに溜めない: 1 件分だけ扱い、既存目録は ID で合流する。

        meta = _read_meta(store.job_dir(job_id))
        job_payload = {
            "id": job.id,
            "title": job.title,
            "source": job.source.value,
            "status": job.status.value,
            "body": job.body,
            "meta": meta,
        }
        message_payload = _message_slim(database, message)
        sources_json = {
            "schema_version": MANIFEST_SCHEMA_VERSION,
            "job": job_payload,
            "message": message_payload,
            "downloaded": downloaded,
            "skipped": skipped,
            "sources": merged_sources,
            "source_ids": source_ids,
            "note": "生ログは長期記憶に入れない。jump_url と要約だけを引用すること。",
        }
        _write_json_validated(sources_path, job_dir, sources_json)
        _merge_summary(summary_path, job_dir, job_payload, message, downloaded, skipped)
        return ExportResult(
            job_id=job_id,
            message_id=message_id,
            downloads_dir=downloads_dir,
            sources_path=sources_path,
            summary_path=summary_path,
            downloaded=downloaded,
            skipped=skipped,
            sources=merged_sources,
            job=job_payload,
            message_payload=message_payload,
            source_ids=source_ids,
        )
    finally:
        if owned_db:
            database.close()


def _message_sources(database: ArchiveDatabase, message: StoredMessage) -> list[dict[str, Any]]:
    sources: list[dict[str, Any]] = [
        {
            "id": f"discord-message-{message.message_id}",
            "type": "discord-message",
            "message_id": message.message_id,
            "jump_url": message.jump_url,
            "author_id": message.author_id,
            "author_name": message.author_name,
            "created_at": message.created_at.astimezone().isoformat(),
            "content": message.content,
        }
    ]
    for attachment in database.fetch_attachments_for_message(message.message_id):
        sources.append(
            {
                "id": f"attachment-{message.message_id}-{attachment.attachment_id}",
                "type": "attachment",
                "message_id": message.message_id,
                "attachment_id": attachment.attachment_id,
                "filename": attachment.filename,
                "url": attachment.url,
                "content_type": attachment.content_type,
                "status": attachment.status,
            }
        )
    for url in database.fetch_urls_for_message(message.message_id):
        sources.append(
            {
                "id": f"url-{message.message_id}-{url.url_index}",
                "type": "url",
                "message_id": message.message_id,
                "url": url.url,
                "normalized_url": url.normalized_url,
                "title": url.title,
                "description": url.description,
                "fetch_status": url.fetch_status,
            }
        )
    return sources


def _merge_manifest(
    sources_path: Path, new_sources: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], list[str]]:
    """既存目録と合流し、安定 ID で重複排除する。同 ID は新しい方で置換。"""
    merged: list[dict[str, Any]] = []
    if sources_path.is_file() and not sources_path.is_symlink():
        try:
            raw = json.loads(sources_path.read_text(encoding="utf-8"))
            prior = raw.get("sources") if isinstance(raw, dict) else None
            if isinstance(prior, list):
                for item in prior:
                    if isinstance(item, dict) and item.get("id"):
                        merged.append(item)
        except (json.JSONDecodeError, OSError):
            merged = []
    by_id: dict[str, int] = {str(s.get("id")): i for i, s in enumerate(merged)}
    for source in new_sources:
        sid = str(source.get("id"))
        if sid in by_id:
            merged[by_id[sid]] = source
        else:
            by_id[sid] = len(merged)
            merged.append(source)
    # 旧形式（id 無し）の混在に備え、id 無しは内容で重複排除して残す。
    return merged, [str(s.get("id")) for s in merged if s.get("id")]


def _write_json_validated(job_path: Path, job_dir: Path, payload: dict[str, Any]) -> None:
    try:
        validated = ensure_contained(job_path, job_dir)
    except ValueError as exc:
        raise ExportError(f"出力先の検証に失敗: {exc}") from exc
    if validated.is_symlink():
        raise ExportError(f"出力先が symlink: {job_path}")
    validated.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def _read_meta(job_dir: Path) -> dict[str, Any]:
    meta_path = job_dir / "meta.json"
    if not meta_path.is_file():
        return {}
    try:
        raw = json.loads(meta_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return raw if isinstance(raw, dict) else {}


def _message_slim(database: ArchiveDatabase, message: StoredMessage) -> dict[str, Any]:
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
    job_dir: Path,
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
        # メッセージ ID を含めて一意化し、衝突時は連番を足す。既存 PDF は残す。
        base = f"{message.message_id}-{attachment.attachment_id}-{safe_name}"
        try:
            target = ensure_contained(downloads_dir / base, job_dir)
        except ValueError as exc:
            skipped.append({**entry, "reason": f"出力先が置き場の外: {exc}"})
            continue
        target = _unique_target(target, job_dir, downloads_dir)
        existing_file = database.resolve_local(attachment.local_path)
        copied = False
        if existing_file is not None and existing_file.is_file() and not existing_file.is_symlink():
            try:
                validated_src = ensure_contained(existing_file, database.root)
                if validated_src.is_symlink():
                    raise ValueError("添付実体が symlink")
                shutil.copy2(validated_src, target)
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
            try:
                validated_target = ensure_contained(target, job_dir)
            except ValueError as exc:
                skipped.append({**entry, "reason": f"出力先の検証に失敗: {exc}"})
                continue
            relative = f"{RESEARCH_DIRNAME}/{DOWNLOAD_DIRNAME}/{validated_target.name}"
            downloaded.append(
                {
                    **entry,
                    "path": relative,
                    "bytes": validated_target.stat().st_size,
                }
            )
            for source in sources:
                if source.get("id") == (
                    f"attachment-{message.message_id}-{attachment.attachment_id}"
                ):
                    source["local_path"] = str(validated_target)
                    source["download_path"] = relative


def _unique_target(target: Path, job_dir: Path, downloads_dir: Path) -> Path:
    """同名が既にあれば連番でずらす。既存ファイルは消さない。"""
    if not target.exists() and not target.is_symlink():
        return target
    stem, suffix = target.stem, target.suffix
    for counter in range(2, 1000):
        candidate = downloads_dir / f"{stem}-{counter}{suffix}"
        try:
            ensure_contained(candidate, job_dir)
        except ValueError:
            continue
        if not candidate.exists() and not candidate.is_symlink():
            return candidate
    return target


def _skip_reason(status: str) -> str:
    if status == AttachmentStatus.SKIPPED_SIZE:
        return "サイズ上限で元々スキップ"
    if status == AttachmentStatus.SKIPPED_TYPE:
        return "種類不許可で元々スキップ"
    if status == AttachmentStatus.INDEXED:
        return "添付取得が無効設定"
    return "取得済みファイルが無い"


def _merge_summary(
    summary_path: Path,
    job_dir: Path,
    job: dict[str, Any],
    message: StoredMessage,
    downloaded: list[dict[str, Any]],
    skipped: list[dict[str, Any]],
) -> None:
    """既存 summary.md を黙って上書きしない。model 記述は残して追記する。"""
    block = _summary_block(job, message, downloaded, skipped)
    existing = ""
    if summary_path.is_file() and not summary_path.is_symlink():
        try:
            existing = summary_path.read_text(encoding="utf-8")
        except OSError:
            existing = ""
    if not existing:
        _write_text_validated(
            summary_path, job_dir, _render_summary(job, message, downloaded, skipped, [])
        )
        return
    marker = f"<!-- archive:message:{message.message_id} -->"
    if marker in existing:
        return  # 同一メッセージの再出力では model 記述を触らない
    if existing.startswith(SUMMARY_MARKER):
        # 自分が書いた目録なら追記で合流する。
        _write_text_validated(summary_path, job_dir, existing.rstrip("\n") + "\n\n" + block + "\n")
        return
    # model が書いた総合は先頭に残し、出典追記だけ足す。
    _write_text_validated(summary_path, job_dir, existing.rstrip("\n") + "\n\n" + block + "\n")


def _write_text_validated(path: Path, job_dir: Path, text: str) -> None:
    try:
        validated = ensure_contained(path, job_dir)
    except ValueError as exc:
        raise ExportError(f"出力先の検証に失敗: {exc}") from exc
    if validated.is_symlink():
        raise ExportError(f"出力先が symlink: {path}")
    validated.write_text(text, encoding="utf-8")


def _summary_block(
    job: dict[str, Any],
    message: StoredMessage,
    downloaded: list[dict[str, Any]],
    skipped: list[dict[str, Any]],
) -> str:
    lines = [
        f"<!-- archive:message:{message.message_id} -->",
        f"## 出典追記: {message.message_id}",
        "",
        f"- 投稿: {message.author_name} さん @ {_iso_local(message.created_at)}",
        f"- ジャンプ URL: <{message.jump_url}>",
        "",
        message.content or "（本文なし）",
        "",
    ]
    for item in downloaded:
        lines.append(f"- {item['filename']} → `{item['path']}`（{item['bytes']} bytes）")
    for item in skipped:
        lines.append(f"- {item['filename']}（スキップ: {item['reason']}）")
    return "\n".join(lines)


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
            f"<!-- archive:message:{message.message_id} -->",
            "（このメモは長期記憶に入れてよい。生ログの丸ごと保存はしないこと）",
        ]
    )
    return "\n".join(lines) + "\n"


def _iso_local(value: Any) -> str:
    return value.astimezone().isoformat()
