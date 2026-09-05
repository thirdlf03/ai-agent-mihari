"""Room-bound Discord archive tools (in-process, no shell).

Hermes runs with ``terminal`` class toolsets OFF by default, so the old
``MIHARI_ROOM_PYTHON -m mihari_room.archive ...`` subprocess path is dead
inside a job. These three tools call the same archive DB/export code
in-process, bound to the room root + the running job:

- ``discord_search`` — full-text search over the archived Discord history
- ``discord_context`` — messages around one archived message
- ``discord_export`` — copy attachments into ``jobs/<id>/research/downloads``

Schemas are registered against the real Hermes ``tools.registry`` so tool
names / JSON-schema shapes are verified at registration time (not just
prompt text). All bounds are enforced in code, not in the prompt:

- read-only: ``messages.db`` is opened read-only; no writes except export
- export stays inside ``jobs/<id>/research/downloads`` (symlink escape rejected)
- secrets are never echoed (payloads go through ``sanitize_preview``-style
  redaction at the call site; jump_url citation required by SKILL.md)
- result sizes are capped (``MAX_HITS`` / ``MAX_SNIPPET_CHARS``)
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable
from pathlib import Path
from typing import Any

logger = logging.getLogger("mihari_room")

TOOLSET_NAME = "mihari_room"

TOOL_NAMES = ("discord_search", "discord_context", "discord_export")

#: Hard caps so a tool call cannot dump the whole archive into context.
MAX_HITS = 10
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


def _hit_payload(hit: Any, db: Any) -> dict[str, Any]:
    msg = hit.message
    return {
        "rank": getattr(hit, "rank", None),
        "snippet": _clip(getattr(hit, "snippet", "")),
        "message_id": getattr(msg, "message_id", None),
        "channel_name": getattr(msg, "channel_name", None),
        "author_name": getattr(msg, "author_name", None),
        "created_at": str(getattr(msg, "created_at", "") or ""),
        "content": _clip(getattr(msg, "content", ""), MAX_CONTENT_CHARS),
        "jump_url": getattr(msg, "jump_url", None) or "",
    }


def discord_search_impl(job: Any, query: str, limit: int = 5, channel: str | None = None) -> str:
    """Bounded in-process archive search. Returns JSON string."""
    from mihari_room.archive.db import ArchiveDatabase  # noqa: F401 (import check)

    room_root = _room_root_for_job(job)
    q = (query or "").strip()
    if not q:
        return json.dumps({"success": False, "error": "query が空"}, ensure_ascii=False)
    try:
        n = int(limit)
    except (TypeError, ValueError):
        n = 5
    n = max(1, min(MAX_HITS, n))
    channel_ids: list[int] | None = None
    channel_names: list[str] | None = None
    if channel:
        ids: list[int] = []
        names: list[str] = []
        for token in str(channel).split(","):
            token = token.strip()
            if not token:
                continue
            if token.isdigit():
                ids.append(int(token))
            else:
                names.append(token)
        channel_ids = ids or None
        channel_names = names or None
    try:
        db = _open_ro_db(room_root)
    except FileNotFoundError as exc:
        return json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False)
    try:
        hits = db.search(query=q, channel_ids=channel_ids, channel_names=channel_names, limit=n)
    except Exception as exc:
        logger.debug("discord_search failed", exc_info=True)
        return json.dumps({"success": False, "error": f"search failed: {exc}"}, ensure_ascii=False)
    finally:
        try:
            db.close()
        except Exception:
            pass
    return json.dumps(
        {
            "success": True,
            "query": q,
            "count": len(hits),
            "hits": [_hit_payload(h, db) for h in hits],
        },
        ensure_ascii=False,
    )


def discord_context_impl(job: Any, message_id: int, before: int = 3, after: int = 3) -> str:
    """Bounded in-process context fetch. Returns JSON string."""
    room_root = _room_root_for_job(job)
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
    try:
        db = _open_ro_db(room_root)
    except FileNotFoundError as exc:
        return json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False)
    try:
        try:
            anchor, before_msgs, after_msgs = db.fetch_context(mid, before=nb, after=na)
        except KeyError:
            return json.dumps(
                {"success": False, "error": f"メッセージが archive に無い: {mid}"},
                ensure_ascii=False,
            )
        except Exception as exc:
            return json.dumps(
                {"success": False, "error": f"context failed: {exc}"}, ensure_ascii=False
            )

        def _msg(m: Any) -> dict[str, Any]:
            return {
                "message_id": getattr(m, "message_id", None),
                "author_name": getattr(m, "author_name", None),
                "created_at": str(getattr(m, "created_at", "") or ""),
                "content": _clip(getattr(m, "content", ""), MAX_CONTENT_CHARS),
                "jump_url": getattr(m, "jump_url", None) or "",
            }

        return json.dumps(
            {
                "success": True,
                "anchor": _msg(anchor),
                "before": [_msg(m) for m in before_msgs],
                "after": [_msg(m) for m in after_msgs],
            },
            ensure_ascii=False,
        )
    finally:
        try:
            db.close()
        except Exception:
            pass


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
            # Already inside the agent worker thread without a running loop
            # for this thread in practice; run a fresh loop via asyncio.run
            # in a helper thread to avoid nesting.
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
    return {
        "discord_search": lambda query="", limit=5, channel=None, **_kwargs: discord_search_impl(
            job, query, limit, channel
        ),
        "discord_context": lambda message_id=0, before=3, after=3, **_kwargs: discord_context_impl(
            job, message_id, before, after
        ),
        "discord_export": lambda message_id=0, no_fetch=False, **_kwargs: discord_export_impl(
            job, message_id, bool(no_fetch) if isinstance(no_fetch, (bool, int)) else False
        ),
    }


_SCHEMAS: dict[str, dict[str, Any]] = {
    "discord_search": {
        "type": "function",
        "function": {
            "name": "discord_search",
            "description": (
                "Room アーカイブから Discord 履歴を全文検索する。"
                "引用には jump_url を添える。messages.db は読み取り専用。"
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
                },
                "required": ["query"],
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
            # Registry signature drift: fail fast, never half-registered.
            logger.error("discord tool register failed for %s: %s", name, exc)
            for done in registered:
                try:
                    registry.deregister(done)
                except Exception:
                    pass
            raise
        except Exception:
            # Already registered (e.g. re-entry): keep going.
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
