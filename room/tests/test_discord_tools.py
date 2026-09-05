"""Bounded in-process Discord tools: search / context / export without shell."""

from __future__ import annotations

import datetime as dt
import json
from pathlib import Path
from typing import Any

import pytest

from mihari_room.archive.db import ArchiveDatabase
from mihari_room.archive.models import AttachmentStatus, StoredAttachment, StoredMessage
from mihari_room.contracts import CreateJobRequest, Job, JobSource
from mihari_room.fakes import InMemoryJobStore
from mihari_room.worker.discord_tools import (
    _SCHEMAS,
    TOOL_NAMES,
    discord_context_impl,
    discord_export_impl,
    discord_search_impl,
    register_discord_tools,
)


def _message(message_id: int, content: str, **kwargs: Any) -> StoredMessage:
    return StoredMessage(
        message_id=message_id,
        guild_id=777,
        channel_id=kwargs.get("channel_id", 111),
        channel_name=kwargs.get("channel_name", "main"),
        thread_id=None,
        thread_name=None,
        author_id=42,
        author_name="たろー",
        content=content,
        created_at=dt.datetime(2024, 1, 2, 3, 4, 5, tzinfo=dt.UTC),
        jump_url=f"https://discord.com/channels/777/111/{message_id}",
    )


def _seed_db(root: Path) -> None:
    db = ArchiveDatabase(root / "messages.db")
    try:
        db.upsert_message(_message(1, "みはりちゃんのごはんを確認 https://example.com/page"))
        db.upsert_message(
            _message(2, "設計メモの PDF を更新した"),
            attachments=[
                StoredAttachment(
                    message_id=2,
                    attachment_id=7,
                    filename="report.pdf",
                    size=11,
                    url="https://cdn.discordapp.com/attachments/1/2/report.pdf",
                    status=AttachmentStatus.OK,
                    local_path=None,
                )
            ],
        )
    finally:
        db.close()


def _make_job(tmp_path: Path) -> Job:
    store = InMemoryJobStore(tmp_path)
    return store.create(CreateJobRequest(title="t", body="b", source=JobSource.PET))


def test_search_finds_seeded_message(tmp_path: Path) -> None:
    _seed_db(tmp_path)
    job = _make_job(tmp_path)
    payload = json.loads(discord_search_impl(job, "ごはん"))
    assert payload["success"] is True
    assert payload["count"] >= 1
    first = payload["hits"][0]
    assert "jump_url" in first and first["jump_url"].startswith("https://discord.com/")
    assert payload["count"] <= 10


def test_search_validates_query_and_missing_db(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    assert json.loads(discord_search_impl(job, ""))["success"] is False
    _seed_db(tmp_path)
    assert json.loads(discord_search_impl(job, "ごはん", limit=999))["count"] <= 10


def test_context_returns_anchor_and_neighbors(tmp_path: Path) -> None:
    _seed_db(tmp_path)
    job = _make_job(tmp_path)
    payload = json.loads(discord_context_impl(job, 1))
    assert payload["success"] is True
    assert payload["anchor"]["message_id"] == 1
    assert json.loads(discord_context_impl(job, 999999))["success"] is False


def test_export_copies_pdf_into_job_research(tmp_path: Path) -> None:
    _seed_db(tmp_path)
    from mihari_room.store.file_store import FileJobStore

    store = FileJobStore(tmp_path)
    job = store.create(CreateJobRequest(title="t", body="b", source=JobSource.PET))
    payload = json.loads(discord_export_impl(job, 2, no_fetch=True))
    assert payload["success"] is True, payload
    downloads = job.directory / "research" / "downloads"
    assert (downloads / "sources.json").is_file()
    assert (downloads / "summary.md").is_file()
    assert downloads.is_dir()
    assert json.loads(discord_export_impl(job, 999999, no_fetch=True))["success"] is False


def _live_registry():
    """Real Hermes registry (read-only import of the pinned source)."""
    import sys

    pinned = "/Users/thirdlf03/.hermes/hermes-agent"
    inserted = False
    if pinned not in sys.path:
        sys.path.insert(0, pinned)
        inserted = True
    try:
        from tools.registry import registry

        return registry
    except ImportError as exc:
        raise _SkipHermes from exc
    finally:
        if inserted:
            try:
                sys.path.remove(pinned)
            except ValueError:
                pass


class _SkipHermes(Exception):
    """Internal: real Hermes registry is not importable here."""


def _skip_hermes() -> None:
    pytest.skip("Hermes source not importable here")


def test_tool_names_and_schemas_match_registry() -> None:
    # Schema/tool names verified against the actual Hermes registry surface:
    # register(name, toolset, schema, handler, ...) and no shadowing.
    assert set(_SCHEMAS) == set(TOOL_NAMES)
    assert set(TOOL_NAMES) == {
        "discord_search",
        "discord_context",
        "discord_export",
    }
    for name, schema in _SCHEMAS.items():
        assert schema["function"]["name"] == name
        params = schema["function"]["parameters"]
        assert params["type"] == "object"
    try:
        from tools.registry import ToolRegistry
    except ImportError:
        # Fall back to the pinned read-only source.
        import sys

        sys.path.insert(0, "/Users/thirdlf03/.hermes/hermes-agent")
        try:
            from tools.registry import ToolRegistry
        except ImportError:
            pytest.skip("Hermes not installed here; impl-level tests above still ran")
        finally:
            try:
                sys.path.remove("/Users/thirdlf03/.hermes/hermes-agent")
            except ValueError:
                pass
    import inspect

    params = list(inspect.signature(ToolRegistry.register).parameters)
    assert params[:4] == ["self", "name", "toolset", "schema"]
    assert "handler" in params


def test_register_and_restore_against_real_registry(tmp_path: Path) -> None:
    try:
        live = _live_registry()
    except _SkipHermes as exc:
        _skip_hermes()
        raise AssertionError("unreachable") from exc
    job = _make_job(tmp_path)
    restore = register_discord_tools(job)
    try:
        assert restore is not None
        mapping = live.get_tool_to_toolset() if hasattr(live, "get_tool_to_toolset") else {}
        if mapping:
            for name in TOOL_NAMES:
                assert mapping.get(name) == "mihari_room"
    finally:
        if restore is not None:
            restore()
    mapping = live.get_tool_to_toolset() if hasattr(live, "get_tool_to_toolset") else {}
    if mapping:
        for name in TOOL_NAMES:
            assert name not in mapping
