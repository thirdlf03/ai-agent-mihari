"""``python -m mihari_room.archive`` の CLI。JSON を stdout に出す。

- ``search --query ...`` … 全文検索（キーワード・日付・チャンネルで絞れる）
- ``context --message-id ...`` … メッセージと前後の文脈
- ``export --job-id ... --message-id ...`` … 添付を jobs/<id>/research/downloads へ

トークンやチャンネル許可リストは要らない。root だけあれば読める。
"""

from __future__ import annotations

import argparse
import asyncio
import dataclasses
import datetime as dt
import json
from pathlib import Path
from typing import Any

from mihari_room.archive.config import ArchiveConfig, load_archive_config
from mihari_room.archive.db import ArchiveDatabase, MessageNotFound
from mihari_room.archive.export import ExportError, export_message
from mihari_room.archive.fetch import SafeFetcher
from mihari_room.archive.models import StoredMessage


class CliError(RuntimeError):
    """CLI から出る確実なエラー。JSON にして exit 1。"""


def _iso(value: dt.datetime | None) -> str | None:
    return value.astimezone(dt.UTC).isoformat() if value is not None else None


def _parse_datetime(text: str, flag: str) -> dt.datetime:
    """--after/--before の解釈。日付だけはローカルの 0 時境界。"""
    token = (text or "").strip()
    if not token:
        raise CliError(f"{flag} が空")
    if "T" in token:
        try:
            parsed = dt.datetime.fromisoformat(token.replace("Z", "+00:00"))
        except ValueError as exc:
            raise CliError(f"{flag} を解釈できない: {token!r}") from exc
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.UTC)
        return parsed
    try:
        day = dt.date.fromisoformat(token)
    except ValueError as exc:
        raise CliError(f"{flag} を解釈できない: {token!r}") from exc
    naive = dt.datetime.combine(day, dt.time.min)
    tzinfo = dt.datetime.now().astimezone().tzinfo
    return naive.replace(tzinfo=tzinfo)


def _open_db(root: Path) -> ArchiveDatabase:
    path = root / "messages.db"
    if not path.is_file():
        raise CliError(f"アーカイブが無い: {path}")
    return ArchiveDatabase(path)


def _message_payload(db: ArchiveDatabase, message: StoredMessage) -> dict[str, Any]:
    return {
        "message_id": message.message_id,
        "guild_id": message.guild_id,
        "channel_id": message.channel_id,
        "channel_name": message.channel_name,
        "thread_id": message.thread_id,
        "thread_name": message.thread_name,
        "author_id": message.author_id,
        "author_name": message.author_name,
        "content": message.content,
        "created_at": _iso(message.created_at),
        "edited_at": _iso(message.edited_at),
        "deleted_at": _iso(message.deleted_at),
        "jump_url": message.jump_url,
        "attachments": [
            {
                "attachment_id": attachment.attachment_id,
                "filename": attachment.filename,
                "size": attachment.size,
                "url": attachment.url,
                "status": attachment.status,
                "local_path": attachment.local_path,
                "extract_status": attachment.extract_status,
            }
            for attachment in db.fetch_attachments_for_message(message.message_id)
        ],
        "urls": [
            {
                "url": url.url,
                "normalized_url": url.normalized_url,
                "title": url.title,
                "description": url.description,
                "fetch_status": url.fetch_status,
            }
            for url in db.fetch_urls_for_message(message.message_id)
        ],
    }


def _emit(payload: dict[str, Any], compact: bool) -> None:
    if compact:
        print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    else:
        print(json.dumps(payload, ensure_ascii=False, indent=2))


def _split_channels(raw: str) -> tuple[list[int], list[str]]:
    """--channel は ID でも名前でも。カンマ区切りで複数。"""
    ids: list[int] = []
    names: list[str] = []
    for token in (part.strip() for part in raw.split(",")):
        if not token:
            continue
        if token.isdigit():
            ids.append(int(token))
        else:
            names.append(token)
    return ids or None, names or None  # type: ignore[return-value]


# ---------- 各コマンド ----------


def cmd_search(args: argparse.Namespace, db: ArchiveDatabase) -> dict[str, Any]:
    channel_ids, channel_names = None, None
    if args.channel:
        channel_ids, channel_names = _split_channels(args.channel)
        if not channel_ids and not channel_names:
            raise CliError(f"--channel を解釈できない: {args.channel!r}")
    hits = db.search(
        query=args.query,
        channel_ids=channel_ids,
        channel_names=channel_names,
        from_dt=_parse_datetime(args.after, "--after") if args.after else None,
        to_dt=_parse_datetime(args.before, "--before") if args.before else None,
        include_deleted=args.include_deleted,
        limit=args.limit,
        offset=args.offset,
    )
    return {
        "command": "search",
        "query": args.query,
        "count": len(hits),
        "hits": [
            {"rank": hit.rank, "snippet": hit.snippet, "message": _message_payload(db, hit.message)}
            for hit in hits
        ],
    }


def cmd_context(args: argparse.Namespace, db: ArchiveDatabase) -> dict[str, Any]:
    anchor, before_messages, after_messages = db.fetch_context(
        args.message_id,
        before=args.before,
        after=args.after,
        include_deleted=args.include_deleted,
    )
    scope = (
        {"kind": "thread", "id": anchor.thread_id}
        if anchor.thread_id is not None
        else {"kind": "channel", "id": anchor.channel_id}
    )
    return {
        "command": "context",
        "message_id": args.message_id,
        "scope": scope,
        "anchor": _message_payload(db, anchor),
        "before": [_message_payload(db, m) for m in before_messages],
        "after": [_message_payload(db, m) for m in after_messages],
    }


async def cmd_export(args: argparse.Namespace, config: ArchiveConfig) -> dict[str, Any]:
    fetcher = SafeFetcher(max_redirects=config.max_redirects)
    if args.no_fetch:
        config = dataclasses.replace(config, fetch_attachments=False)
    result = await export_message(
        config,
        job_id=args.job_id,
        message_id=args.message_id,
        fetcher=fetcher,
    )
    return {
        "command": "export",
        "job_id": result.job_id,
        "message_id": result.message_id,
        "downloads_dir": str(result.downloads_dir),
        "sources_path": str(result.sources_path),
        "summary_path": str(result.summary_path),
        "job": result.job,
        "message": result.message_payload,
        "downloaded": result.downloaded,
        "skipped": result.skipped,
    }


# ---------- 組み立て ----------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mihari_room.archive",
        description="作業部屋の Discord アーカイブを引く CLI。JSON を出す。",
    )
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--root",
        help="部屋の root（既定は $MIHARI_ARCHIVE_ROOT / $MIHARI_ROOM_ROOT / ~/mihari-room）",
    )
    common.add_argument("--compact", action="store_true", help="1 行 JSON で出す")

    sub = parser.add_subparsers(dest="command", required=True)

    def _add(name: str, help_text: str):
        return sub.add_parser(name, parents=[common], help=help_text)

    search = _add("search", "メッセージの全文検索")
    search.add_argument("--query", required=True, help="検索キーワード（3 文字未満は LIKE 検索）")
    search.add_argument("--after", help="この日時以降（YYYY-MM-DD や ISO 8601）")
    search.add_argument("--before", help="この日時より前")
    search.add_argument("--channel", help="チャンネル ID か名前（カンマ区切りで複数）")
    search.add_argument("--include-deleted", action="store_true")
    search.add_argument("--limit", type=int, default=20)
    search.add_argument("--offset", type=int, default=0)
    search.set_defaults(handler=lambda args, db: cmd_search(args, db))

    context = _add("context", "メッセージと前後の文脈")
    context.add_argument("--message-id", type=int, required=True)
    context.add_argument("--before", type=int, default=5, help="前の件数")
    context.add_argument("--after", type=int, default=5, help="後の件数")
    context.add_argument("--include-deleted", action="store_true")
    context.set_defaults(handler=lambda args, db: cmd_context(args, db))

    export = _add("export", "出典を jobs/<id>/research/downloads へコピー")
    export.add_argument("--job-id", required=True)
    export.add_argument("--message-id", type=int, required=True)
    export.add_argument(
        "--no-fetch",
        action="store_true",
        help="まだ落ちていない添付の取得をしない（取得済みをコピーするだけ）",
    )
    export.set_defaults(handler=None)  # async なので別経路

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        config = load_archive_config(Path(args.root).expanduser() if args.root else None)
    except ValueError as exc:
        return _fatal({"error": str(exc)})
    try:
        if args.command == "export":
            payload = asyncio.run(cmd_export(args, config))
        else:
            with _open_db(config.root) as db:
                payload = args.handler(args, db)
        _emit(payload, args.compact)
        return 0
    except (CliError, ExportError) as exc:
        return _fatal({"error": str(exc)})
    except MessageNotFound as exc:
        return _fatal({"error": f"メッセージが無い: {exc}"})


def _fatal(payload: dict[str, Any]) -> int:
    print(json.dumps(payload, ensure_ascii=False))
    return 1
