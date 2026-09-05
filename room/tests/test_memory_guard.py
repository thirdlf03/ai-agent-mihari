"""Memory guard hooks: replace/remove rejected explicitly, candidates journaled."""

from __future__ import annotations

import json
import sys
import types
from pathlib import Path
from typing import Any

from mihari_room.contracts import CreateJobRequest, Job, JobSource
from mihari_room.events import EventJournal, JournalKind
from mihari_room.fakes import InMemoryJobStore
from mihari_room.worker.agent import install_memory_guard
from mihari_room.worker.memory import MemoryCandidateStore


def _make_job(tmp_path: Path) -> Job:
    store = InMemoryJobStore(tmp_path)
    return store.create(CreateJobRequest(title="t", body="b", source=JobSource.PET))


def _install_fake_tool(monkeypatch) -> None:
    module = types.ModuleType("tools.memory_tool")

    def memory_tool(*args: Any, **kwargs: Any) -> str:  # pragma: no cover - replaced by guard
        return json.dumps({"success": True})

    module.memory_tool = memory_tool  # type: ignore[attr-defined]
    tools_pkg = types.ModuleType("tools")
    tools_pkg.__path__ = []  # type: ignore[attr-defined]
    registry = types.ModuleType("tools.registry")
    registry.tool_error = lambda message, success=False: json.dumps(  # type: ignore[attr-defined]
        {"success": success, "error": message}
    )
    monkeypatch.setitem(sys.modules, "tools", tools_pkg)
    monkeypatch.setitem(sys.modules, "tools.memory_tool", module)
    monkeypatch.setitem(sys.modules, "tools.registry", registry)


class _Agent:
    def __init__(self) -> None:
        self._memory_store = None
        self._memory_manager = None

    def shutdown_memory_provider(self, messages=None) -> None:
        return None


def test_replace_and_remove_are_rejected_not_staged(tmp_path: Path, monkeypatch) -> None:
    _install_fake_tool(monkeypatch)
    monkeypatch.setenv("MIHARI_HERMES_HOME", str(tmp_path / "hermes-home"))
    job = _make_job(tmp_path)
    agent = _Agent()
    restore = install_memory_guard(agent, job)
    try:
        import tools.memory_tool as mt

        replace = json.loads(
            mt.memory_tool(action="replace", target="memory", content="new", old_text="old")
        )
        assert replace["success"] is False
        assert "not supported" in replace["error"]
        remove = json.loads(mt.memory_tool(action="remove", target="memory", old_text="old"))
        assert remove["success"] is False
        assert "not supported" in remove["error"]
        batch = json.loads(
            mt.memory_tool(
                target="memory",
                operations=[
                    {"action": "add", "content": "ok one"},
                    {"action": "remove", "old_text": "x"},
                ],
            )
        )
        assert batch["success"] is False
    finally:
        restore()
    # Nothing misleadingly appended as memory.
    store = MemoryCandidateStore(tmp_path, tmp_path / "hermes-home")
    assert store.list(job.id) == []
    assert not (tmp_path / "hermes-home" / "memories" / "MEMORY.md").exists()


def test_add_proposal_emits_memory_candidate_journal(tmp_path: Path, monkeypatch) -> None:
    _install_fake_tool(monkeypatch)
    monkeypatch.setenv("MIHARI_HERMES_HOME", str(tmp_path / "hermes-home"))
    job = _make_job(tmp_path)
    agent = _Agent()
    restore = install_memory_guard(agent, job)
    try:
        import tools.memory_tool as mt

        result = json.loads(mt.memory_tool(action="add", target="memory", content="oven fact"))
        assert result["success"] is True
        assert result["staged"] is True
    finally:
        restore()
    journal = EventJournal.for_job(job.directory)
    kinds = [event["kind"] for event in journal.events()]
    assert JournalKind.MEMORY_CANDIDATE.value in kinds
    waiting = [e for e in journal.events() if e["kind"] == JournalKind.MEMORY_CANDIDATE.value]
    assert all(e["phase"] == "waiting" for e in waiting)


def test_wrapper_replace_remove_do_not_stage_text(tmp_path: Path, monkeypatch) -> None:
    _install_fake_tool(monkeypatch)
    monkeypatch.setenv("MIHARI_HERMES_HOME", str(tmp_path / "hermes-home"))
    job = _make_job(tmp_path)
    agent = _Agent()
    restore = install_memory_guard(agent, job)
    try:
        guard = agent._memory_store
        assert guard.replace("memory", "old", "new")["success"] is False
        assert guard.remove("memory", "old")["success"] is False
        batch = guard.apply_batch("memory", [{"action": "remove", "old_text": "x"}])
        assert batch["success"] is False
        ok = guard.apply_batch("memory", [{"action": "add", "content": "real fact"}])
        assert ok["success"] is True
    finally:
        restore()
    store = MemoryCandidateStore(tmp_path, tmp_path / "hermes-home")
    candidates = store.list(job.id)
    assert len(candidates) == 1
    assert "replace" not in candidates[0].content and "remove" not in candidates[0].content


def test_approved_memory_loads_next_session(tmp_path: Path, monkeypatch) -> None:
    _install_fake_tool(monkeypatch)
    monkeypatch.setenv("MIHARI_HERMES_HOME", str(tmp_path / "hermes-home"))
    job = _make_job(tmp_path)
    store = MemoryCandidateStore(tmp_path, tmp_path / "hermes-home")
    candidate = store.propose(job.id, "memory", "approved oven fact")
    store.approve(job.id, candidate.id)
    # Next session: fresh guard loads approved entries into the snapshot path.
    agent = _Agent()
    restore = install_memory_guard(agent, job)
    try:
        guard = agent._memory_store
        guard.load_from_disk()
        assert "approved oven fact" in guard.memory_entries
        assert guard.format_for_system_prompt("memory") is not None
        assert "approved oven fact" in (guard.format_for_system_prompt("memory") or "")
        # save_to_disk stays a no-op (approval flow is the only writer).
        assert guard.save_to_disk("memory") is None
        raw = (tmp_path / "hermes-home" / "memories" / "MEMORY.md").read_text(encoding="utf-8")
        assert "approved oven fact" in raw
    finally:
        restore()
