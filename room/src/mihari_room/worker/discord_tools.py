"""Room-bound Discord archive tools (in-process, no shell).

Hermes は Discord を直接見ない。``messages.db`` を読むだけ。
参照実装（discord-daily-summary-bot の Search API）に合わせて、
検索・最近・チャンネル一覧・1件取得・前後・出典コピーを分ける。

- read-only: ``messages.db`` は読み取り専用。書き込みは export だけ
- export は ``jobs/<id>/research/downloads`` の内側
- 件数・字数は頭打ち
"""

from __future__ import annotations

import asyncio
import datetime as dt
import json
import logging
from collections.abc import Callable
from pathlib import Path
from typing import Any

logger = logging.getLogger("mihari_room")

TOOLSET_NAME = "mihari_room"

TOOL_NAMES = (
    "discord_search",
    "discord_recent",
    "discord_channels",
    "discord_message",
    "discord_context",
    "discord_export",
)

#: Hard caps so a tool call cannot dump the whole archive into context.
MAX_HITS = 10
MAX_LIST = 20
MAX_SNIPPET_CHARS = 500
MAX_CONTENT_CHARS = 2000


def _room_root_for_job(job: Any) -> Path:
    return Path(job.directory).parent.parent


def _open_ro_db(room_root: Path) -> Any:
    from mihari_room.archive.db import ArchiveDatabase

    path = Path(room_root) / "messages.db"
    if not path.is_file():
        raise FileNotFoundError(f"アーカイブが無い: {path}")
    return ArchiveDatabase(path)


def _clip(text: Any, limit: int = MAX_SNIPPET_CHARS) -> str:
    s = str(text or "")
    return s if len(s) <= limit else s[: limit - 3] + "..."


def _parse_dt(raw: str | None) -> dt.datetime | None:
    token = (raw or "").strip()
    if not token:
        return None
    if "T" in token:
        parsed = dt.datetime.fromisoformat(token.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.UTC)
        return parsed
    day = dt.date.fromisoformat(token)
    return dt.datetime.combine(day, dt.time.min, tzinfo=dt.datetime.now().astimezone().tzinfo)


def _split_tokens(raw: str | None) -> tuple[list[int] | None, list[str] | None]:
    if not raw:
        return None, None
    ids: list[int] = []
    names: list[str] = []
    for token in str(raw).split(","):
        token = token.strip()
        if not token:
            continue
        if token.isdigit():
            ids.append(int(token))
        else:
            names.append(token)
    return (ids or None), (names or None)


def _cap_limit(raw: Any, default: int, ceiling: int) -> int:
    try:
        n = int(raw)
    except (TypeError, ValueError):
        n = default
    return max(1, min(ceiling, n))


def _msg_payload(msg: Any) -> dict[str, Any]:
    return {
        "message_id": getattr(msg, "message_id", None),
        "channel_id": getattr(msg, "channel_id", None),
        "channel_name": getattr(msg, "channel_name", None),
        "thread_id": getattr(msg, "thread_id", None),
        "thread_name": getattr(msg, "thread_name", None),
        "author_id": getattr(msg, "author_id", None),
        "author_name": getattr(msg, "author_name", None),
        "created_at": str(getattr(msg, "created_at", "") or ""),
        "content": _clip(getattr(msg, "content", ""), MAX_CONTENT_CHARS),
        "jump_url": getattr(msg, "jump_url", None) or "",
    }


def _hit_payload(hit: Any, _db: Any) -> dict[str, Any]:
    msg = hit.message
    payload = _msg_payload(msg)
    payload["rank"] = getattr(hit, "rank", None)
    payload["snippet"] = _clip(getattr(hit, "snippet", ""))
    return payload


def _with_db(job: Any, fn: Callable[[Any], dict[str, Any]]) -> str:
    try:
        db = _open_ro_db(_room_root_for_job(job))
    except FileNotFoundError as exc:
        return json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False)
    try:
        return json.dumps(fn(db), ensure_ascii=False)
    except Exception as exc:
        logger.debug("discord tool failed", exc_info=True)
        return json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False)
    finally:
        try:
            db.close()
        except Exception:
            pass


def discord_search_impl(
    job: Any,
    query: str,
    limit: int = 5,
    channel: str | None = None,
    after: str | None = None,
    before: str | None = None,
    author: str | None = None,
) -> str:
    """本文・添付・URL を横断検索する。"""
    q = (query or "").strip()
    if not q:
        return json.dumps({"success": False, "error": "query が空"}, ensure_ascii=False)
    try:
        from_dt = _parse_dt(after)
        to_dt = _parse_dt(before)
    except ValueError as exc:
        return json.dumps({"success": False, "error": f"日時が読めない: {exc}"}, ensure_ascii=False)
    n = _cap_limit(limit, 5, MAX_HITS)
    channel_ids, channel_names = _split_tokens(channel)
    author_ids, author_names = _split_tokens(author)

    def _run(db: Any) -> dict[str, Any]:
        hits = db.search(
            query=q,
            channel_ids=channel_ids,
            channel_names=channel_names,
            from_dt=from_dt,
            to_dt=to_dt,
            author_ids=author_ids,
            author_names=author_names,
            limit=n,
        )
        attachments = db.search_attachments(
            query=q,
            channel_ids=channel_ids,
            channel_names=channel_names,
            from_dt=from_dt,
            to_dt=to_dt,
            limit=n,
        )
        urls = db.search_urls(
            query=q,
            channel_ids=channel_ids,
            channel_names=channel_names,
            from_dt=from_dt,
            to_dt=to_dt,
            limit=n,
        )
        return {
            "success": True,
            "query": q,
            "count": len(hits),
            "hits": [_hit_payload(h, db) for h in hits],
            "attachment_hits": [
                {
                    "filename": att.filename,
                    "snippet": _clip(snippet),
                    "message_id": msg.message_id,
                    "jump_url": msg.jump_url,
                    "channel_name": msg.channel_name,
                }
                for att, msg, snippet in attachments
            ],
            "url_hits": [
                {
                    "url": url.url,
                    "title": url.title,
                    "description": _clip(url.description or ""),
                    "message_id": msg.message_id,
                    "jump_url": msg.jump_url,
                }
                for url, msg in urls
            ],
        }

    return _with_db(job, _run)


def discord_recent_impl(
    job: Any,
    limit: int = 10,
    channel: str | None = None,
    after: str | None = None,
    before: str | None = None,
    author: str | None = None,
) -> str:
    """キーワード無しの最近の発言。"""
    try:
        from_dt = _parse_dt(after)
        to_dt = _parse_dt(before)
    except ValueError as exc:
        return json.dumps({"success": False, "error": f"日時が読めない: {exc}"}, ensure_ascii=False)
    n = _cap_limit(limit, 10, MAX_LIST)
    channel_ids, _names = _split_tokens(channel)
    author_ids, _author_names = _split_tokens(author)
    channel_id = channel_ids[0] if channel_ids else None
    author_id = author_ids[0] if author_ids else None

    def _run(db: Any) -> dict[str, Any]:
        rows = db.list_messages(
            channel_id=channel_id,
            author_id=author_id,
            from_dt=from_dt,
            to_dt=to_dt,
            limit=n,
        )
        return {
            "success": True,
            "count": len(rows),
            "items": [_msg_payload(m) for m in rows],
        }

    return _with_db(job, _run)


def discord_channels_impl(job: Any, limit: int = 50) -> str:
    n = _cap_limit(limit, 50, 200)

    def _run(db: Any) -> dict[str, Any]:
        rows = db.list_channels(limit=n)
        return {"success": True, "count": len(rows), "channels": rows}

    return _with_db(job, _run)


def discord_message_impl(job: Any, message_id: int) -> str:
    try:
        mid = int(message_id)
    except (TypeError, ValueError):
        return json.dumps(
            {"success": False, "error": "message_id が数字ではない"}, ensure_ascii=False
        )

    def _run(db: Any) -> dict[str, Any]:
        msg = db.get_message(mid)
        if msg is None:
            return {"success": False, "error": f"メッセージが archive に無い: {mid}"}
        payload = _msg_payload(msg)
        payload["attachments"] = [
            {
                "attachment_id": a.attachment_id,
                "filename": a.filename,
                "status": a.status,
                "size": a.size,
            }
            for a in db.fetch_attachments_for_message(mid)
        ]
        payload["urls"] = [
            {"url": u.url, "title": u.title, "description": _clip(u.description or "")}
            for u in db.fetch_urls_for_message(mid)
        ]
        payload["success"] = True
        return payload

    return _with_db(job, _run)


def discord_context_impl(job: Any, message_id: int, before: int = 3, after: int = 3) -> str:
    """Bounded in-process context fetch. Returns JSON string."""
    try:
        mid = int(message_id)
    except (TypeError, ValueError):
        return json.dumps(
            {"success": False, "error": "message_id が数字ではない"}, ensure_ascii=False
        )
    try:
        nb = max(0, min(10, int(before)))
        na = max(0, min(10, int(after)))
    except (TypeError, ValueError):
        nb, na = 3, 3

    def _run(db: Any) -> dict[str, Any]:
        try:
            anchor, before_msgs, after_msgs = db.fetch_context(mid, before=nb, after=na)
        except KeyError:
            return {"success": False, "error": f"メッセージが archive に無い: {mid}"}
        return {
            "success": True,
            "anchor": _msg_payload(anchor),
            "before": [_msg_payload(m) for m in before_msgs],
            "after": [_msg_payload(m) for m in after_msgs],
        }

    return _with_db(job, _run)


def discord_export_impl(job: Any, message_id: int, no_fetch: bool = False) -> str:
    """Bounded in-process export into this job's research/downloads. Returns JSON."""
    from mihari_room.archive.config import ArchiveConfig
    from mihari_room.archive.export import ExportError, export_message
    from mihari_room.archive.fetch import SafeFetcher

    room_root = _room_root_for_job(job)
    try:
        mid = int(message_id)
    except (TypeError, ValueError):
        return json.dumps(
            {"success": False, "error": "message_id が数字ではない"}, ensure_ascii=False
        )
    config = ArchiveConfig(root=room_root)
    if no_fetch:
        import dataclasses

        config = dataclasses.replace(config, fetch_attachments=False)
    try:

        async def _go() -> Any:
            fetcher = SafeFetcher(max_redirects=config.max_redirects)
            try:
                return await export_message(config, job_id=job.id, message_id=mid, fetcher=fetcher)
            finally:
                try:
                    await fetcher.aclose()
                except Exception:
                    pass

        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None
        if loop is not None:
            import concurrent.futures

            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                result = pool.submit(asyncio.run, _go()).result(timeout=120)
        else:
            result = asyncio.run(_go())
    except ExportError as exc:
        return json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False)
    except Exception as exc:
        logger.debug("discord_export failed", exc_info=True)
        return json.dumps({"success": False, "error": f"export failed: {exc}"}, ensure_ascii=False)
    return json.dumps(
        {
            "success": True,
            "job_id": result.job_id,
            "message_id": result.message_id,
            "sources_path": str(result.sources_path),
            "summary_path": str(result.summary_path),
            "downloaded": result.downloaded,
            "skipped": result.skipped,
        },
        ensure_ascii=False,
    )


def _make_handlers(job: Any) -> dict[str, Any]:
    def search(**kwargs: Any) -> str:
        return discord_search_impl(
            job,
            kwargs.get("query", ""),
            kwargs.get("limit", 5),
            kwargs.get("channel"),
            kwargs.get("after"),
            kwargs.get("before"),
            kwargs.get("author"),
        )

    def recent(**kwargs: Any) -> str:
        return discord_recent_impl(
            job,
            kwargs.get("limit", 10),
            kwargs.get("channel"),
            kwargs.get("after"),
            kwargs.get("before"),
            kwargs.get("author"),
        )

    def channels(**kwargs: Any) -> str:
        return discord_channels_impl(job, kwargs.get("limit", 50))

    def message(**kwargs: Any) -> str:
        return discord_message_impl(job, kwargs.get("message_id", 0))

    def context(**kwargs: Any) -> str:
        return discord_context_impl(
            job,
            kwargs.get("message_id", 0),
            kwargs.get("before", 3),
            kwargs.get("after", 3),
        )

    def export(**kwargs: Any) -> str:
        no_fetch = kwargs.get("no_fetch", False)
        return discord_export_impl(
            job,
            kwargs.get("message_id", 0),
            bool(no_fetch) if isinstance(no_fetch, (bool, int)) else False,
        )

    return {
        "discord_search": search,
        "discord_recent": recent,
        "discord_channels": channels,
        "discord_message": message,
        "discord_context": context,
        "discord_export": export,
    }


_SCHEMAS: dict[str, dict[str, Any]] = {
    "discord_search": {
        "type": "function",
        "function": {
            "name": "discord_search",
            "description": (
                "アーカイブから Discord 履歴を全文検索する。"
                "本文に加え添付ファイル名・PDF 抽出文・共有 URL も返す。"
                "日時 (after/before)・チャンネル・作者で絞れる。引用には jump_url を添える。"
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "検索キーワード"},
                    "limit": {"type": "integer", "default": 5, "minimum": 1, "maximum": 10},
                    "channel": {
                        "type": "string",
                        "description": "チャンネル ID/名のカンマ区切り（省略可）",
                    },
                    "after": {
                        "type": "string",
                        "description": "これ以降（YYYY-MM-DD または ISO 8601）",
                    },
                    "before": {
                        "type": "string",
                        "description": "これより前（YYYY-MM-DD または ISO 8601）",
                    },
                    "author": {
                        "type": "string",
                        "description": "作者 ID または表示名",
                    },
                },
                "required": ["query"],
            },
        },
    },
    "discord_recent": {
        "type": "function",
        "function": {
            "name": "discord_recent",
            "description": (
                "キーワード無しで最近の発言を新しい順に返す。『最近何があった』を見るときに使う。"
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "limit": {"type": "integer", "default": 10, "minimum": 1, "maximum": 20},
                    "channel": {"type": "string"},
                    "after": {"type": "string"},
                    "before": {"type": "string"},
                    "author": {"type": "string"},
                },
            },
        },
    },
    "discord_channels": {
        "type": "function",
        "function": {
            "name": "discord_channels",
            "description": "アーカイブに入っているチャンネル一覧（件数・最終発言）。",
            "parameters": {
                "type": "object",
                "properties": {
                    "limit": {"type": "integer", "default": 50, "minimum": 1, "maximum": 200},
                },
            },
        },
    },
    "discord_message": {
        "type": "function",
        "function": {
            "name": "discord_message",
            "description": "1 件のアーカイブメッセージと添付・URL を返す。",
            "parameters": {
                "type": "object",
                "properties": {
                    "message_id": {"type": "integer"},
                },
                "required": ["message_id"],
            },
        },
    },
    "discord_context": {
        "type": "function",
        "function": {
            "name": "discord_context",
            "description": "アーカイブ済みメッセージの前後を読む。search の message_id を渡す。",
            "parameters": {
                "type": "object",
                "properties": {
                    "message_id": {"type": "integer", "description": "基準メッセージ ID"},
                    "before": {"type": "integer", "default": 3, "minimum": 0, "maximum": 10},
                    "after": {"type": "integer", "default": 3, "minimum": 0, "maximum": 10},
                },
                "required": ["message_id"],
            },
        },
    },
    "discord_export": {
        "type": "function",
        "function": {
            "name": "discord_export",
            "description": (
                "出典メッセージの添付をこのジョブの research/downloads にコピーし、"
                "sources.json/summary.md を作る。ジョブ外への書き込みはしない。"
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "message_id": {"type": "integer", "description": "出典メッセージ ID"},
                    "no_fetch": {"type": "boolean", "default": False},
                },
                "required": ["message_id"],
            },
        },
    },
}


def register_discord_tools(job: Any) -> Callable[[], None] | None:
    """Register job-bound ``discord_*`` tools on the real Hermes registry.

    Returns a restore callable (deregisters our tools) or ``None`` when the
    Hermes registry is not importable (fake-agent tests). Schemas are verified
    against the registry's ``register()`` signature; unknown names fail fast.
    """
    try:
        from tools.registry import registry
    except ImportError:
        return None
    handlers = _make_handlers(job)
    registered: list[str] = []
    for name in TOOL_NAMES:
        schema = _SCHEMAS[name]
        try:
            registry.register(
                name,
                TOOLSET_NAME,
                schema,
                handlers[name],
                description=schema["function"]["description"],
                emoji="🔍",
            )
        except TypeError as exc:
            logger.error("discord tool register failed for %s: %s", name, exc)
            for done in registered:
                try:
                    registry.deregister(done)
                except Exception:
                    pass
            raise
        except Exception:
            logger.debug("discord tool %s already registered", name, exc_info=True)
            continue
        registered.append(name)

    def restore() -> None:
        try:
            from tools.registry import registry as live
        except ImportError:
            return
        for name in registered:
            try:
                live.deregister(name)
            except Exception:
                pass

    return restore
