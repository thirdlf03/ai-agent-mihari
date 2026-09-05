"""Phase 0/5 safety: hook adapter, lifecycle, session continuity.

Uses fakes matching the inspected Hermes API surface:

- ``AIAgent`` kwargs: api_key/base_url/provider/..., enabled_toolsets,
  session_id/session_db, tool_progress_callback, clarify_callback
- ``agent.run_conversation(prompt, conversation_history)``
- ``agent.interrupt(msg)``, ``agent.close()``,
  ``agent.shutdown_memory_provider(messages)``
- ``tools.memory_tool.memory_tool(action, target, content, ...)``
  returning a JSON string; ``agent._memory_store`` / ``_memory_manager``
"""

from __future__ import annotations

import asyncio
import json
import sys
import threading
import time
import types
from pathlib import Path
from typing import Any

from mihari_room.contracts import (
    CreateJobRequest,
    Job,
    JobSource,
    JobStatus,
    ProgressEvent,
)
from mihari_room.fakes import InMemoryJobStore
from mihari_room.worker import HermesWorker
from mihari_room.worker.agent import (
    InProcessHermes,
    install_memory_guard,
    make_log_event,
    pending_followups,
    read_session_id,
    sanitize_args,
    sanitize_preview,
)
from mihari_room.worker.hermes import ensure_baseline_toolsets, filter_toolsets
from mihari_room.worker.memory import MemoryCandidateStore
from mihari_room.worker.runtime_lock import (
    agent_serial,
    resolve_hermes_home,
    room_lock,
    scoped_hermes_home,
)


def _make_job(tmp_path: Path, title: str = "まとめ", body: str = "今日の分") -> Job:
    store = InMemoryJobStore(tmp_path)
    job = store.create(CreateJobRequest(title=title, body=body, source=JobSource.PET))
    (job.directory / "input" / "memo.txt").write_text("入力メモ", encoding="utf-8")
    return job


class FakeAgent:
    last: Any = None

    def __init__(self, **kwargs: Any) -> None:
        self.session_id = kwargs.get("session_id") or "sess-test"
        self.tool_progress_callback = kwargs.get("tool_progress_callback")
        self.kwargs = kwargs
        self.prompts: list[str] = []
        self._stop = threading.Event()
        self._sleep = 0.0
        self._fail = False
        self.shutdown_calls: list[Any] = []
        FakeAgent.last = self

    def interrupt(self, *_args: Any) -> None:
        self._stop.set()

    def run_conversation(self, prompt: str, conversation_history: Any = None, **_: Any) -> dict:
        self.prompts.append(prompt)
        self.received_history = conversation_history
        if self._sleep:
            self._stop.wait(self._sleep)
        callback = self.tool_progress_callback
        if callback:
            callback("tool.started", "read_file", "memo.txt", {"path": "input/memo.txt"})
        Path("output/hello.txt").write_text("hello\n", encoding="utf-8")
        if self._fail:
            return {"failed": True, "final_response": ""}
        return {"final_response": "作業が終わりました。"}

    def close(self) -> None:
        return None

    def shutdown_memory_provider(self, messages: Any = None) -> None:
        self.shutdown_calls.append(messages)
        return None


def _factory(**kwargs: Any) -> FakeAgent:
    return FakeAgent(**kwargs)


# -- memory hook adapter with a fake tools.memory_tool module --------------


def _install_fake_memory_tool(monkeypatch=None):
    """Fake the inspected ``tools.memory_tool`` module with a file-backed store."""
    written: list[tuple[str, str]] = []

    module = types.ModuleType("tools.memory_tool")

    class FakeStore:
        def __init__(self) -> None:
            self.entries: list[str] = []

    def memory_tool(action=None, target="memory", content=None, **kwargs):
        store = kwargs.get("store")
        if action in {"add", "replace", "remove"}:
            text = content or kwargs.get("new_text") or ""
            written.append((target, text))
            if store is not None and hasattr(store, "entries"):
                store.entries.append(text)
            return json.dumps({"success": True})
        return json.dumps({"success": True, "entries": []})

    module.memory_tool = memory_tool  # type: ignore[attr-defined]
    module.MemoryStore = FakeStore  # type: ignore[attr-defined]
    tools_pkg = types.ModuleType("tools")
    tools_pkg.__path__ = []  # type: ignore[attr-defined]
    if monkeypatch is not None:
        monkeypatch.setitem(sys.modules, "tools", tools_pkg)
        monkeypatch.setitem(sys.modules, "tools.memory_tool", module)
    else:
        sys.modules["tools"] = tools_pkg
        sys.modules["tools.memory_tool"] = module
    registry = types.ModuleType("tools.registry")

    def tool_error(message, success=False):
        return json.dumps({"success": success, "error": message})

    registry.tool_error = tool_error  # type: ignore[attr-defined]
    if monkeypatch is not None:
        monkeypatch.setitem(sys.modules, "tools.registry", registry)
    else:
        sys.modules["tools.registry"] = registry
    return written, module


def test_memory_tool_updates_become_candidates_not_writes(tmp_path: Path, monkeypatch) -> None:
    written, module = _install_fake_memory_tool(monkeypatch)
    monkeypatch.setenv("MIHARI_HERMES_HOME", str(tmp_path / "hermes-home"))

    class MemoryAgent(FakeAgent):
        def run_conversation(self, prompt, conversation_history=None, **kw):
            import tools.memory_tool as mt

            # Agent with a real store object (inspected API: store= kw).
            fake_store = mt.MemoryStore()
            self._memory_store = fake_store
            self._memory_manager = types.SimpleNamespace(
                has_tool=lambda name: False,
                notify_memory_tool_write=lambda *a, **k: None,
                on_session_end=lambda messages=None: written.append(("manager", "write")),
                shutdown_all=lambda: None,
            )
            restore = install_memory_guard(self, _make_job_holder(tmp_path))
            try:
                result = mt.memory_tool(
                    action="add",
                    target="memory",
                    content="remember the oven",
                    store=self._memory_store,
                )
            finally:
                restore()
            self.memory_result = json.loads(result)
            # Manager must not have written; guarded shutdown writes nothing.
            self.shutdown_memory_provider([])
            return {"final_response": "done"}

    holder: dict[str, Job] = {}

    def _make_job_holder(_tmp: Path) -> Job:
        if "job" not in holder:
            holder["job"] = _make_job(_tmp)
        return holder["job"]

    job = _make_job_holder(tmp_path)

    async def go() -> None:
        runner = InProcessHermes(timeout=30, agent_factory=lambda **kw: MemoryAgent(**kw))

        async def on_progress(_ev: ProgressEvent) -> None:
            return None

        status = await runner.run(job, "do it", on_progress)
        assert status is JobStatus.DONE

    asyncio.run(go())
    agent = FakeAgent.last
    assert agent.memory_result["success"] is True
    assert agent.memory_result.get("staged") is True
    # No direct permanent write happened through the built-in path.
    assert written == []
    # A pending candidate is durable for later HTTP approval.
    store = MemoryCandidateStore(tmp_path, tmp_path / "hermes-home")
    candidates = store.list(job.id)
    assert len(candidates) == 1 and candidates[0].status == "pending"
    store.approve(job.id, candidates[0].id)
    mem = (tmp_path / "hermes-home" / "memories" / "MEMORY.md").read_text(encoding="utf-8")
    assert "oven" in mem


def test_shutdown_and_manager_do_not_write(tmp_path: Path) -> None:
    job = _make_job(tmp_path)

    class Probe(FakeAgent):
        pass

    agent = Probe(session_id="s")
    agent._memory_manager = types.SimpleNamespace(
        on_session_end=lambda messages=None: (_ for _ in ()).throw(
            AssertionError("must not write")
        ),
    )
    restore = install_memory_guard(agent, job)
    try:
        agent.shutdown_memory_provider([{"role": "user"}])
        agent._memory_manager.on_session_end([])
    finally:
        restore()


def test_toolset_filter_drops_discord_and_shell_by_default(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.delenv("MIHARI_ROOM_ALLOW_SHELL", raising=False)
    filtered = filter_toolsets(
        ["discord", "discord_admin", "terminal", "session_search", "file", "memory"]
    )
    assert "discord" not in filtered and "discord_admin" not in filtered
    assert "terminal" not in filtered
    assert "session_search" in filtered and "file" in filtered
    monkeypatch.setenv("MIHARI_ROOM_ALLOW_SHELL", "1")
    assert "terminal" in filter_toolsets(["terminal", "file"])
    baseline = ensure_baseline_toolsets(["file"])
    assert "session_search" in baseline and "search" in baseline


def test_progress_never_echoes_secrets_or_urls() -> None:
    assert sanitize_args({"api_key": "sk-abc", "path": "x"}) is None
    assert sanitize_args({"path": "x"}) is None
    assert "sk-abc123456789" not in (sanitize_preview("key sk-abc123456789 here") or "")
    assert "https://example.com/secret" not in (
        sanitize_preview("see https://example.com/secret") or ""
    )
    event = make_log_event("hi", tool_name="read_file", phase="started")
    assert event.text == "hi"


def test_late_interruption_persists_session_and_joins_thread(tmp_path: Path) -> None:
    job = _make_job(tmp_path)

    started = threading.Event()
    entered_cwd: list[str] = []

    class SlowAgent(FakeAgent):
        def run_conversation(self, prompt, conversation_history=None, **kw):
            started.set()
            entered_cwd.append(str(Path.cwd()))
            # Ignore the first interrupt briefly, then honor it (late interruption).
            time.sleep(0.6)
            self._stop.wait(5)
            Path("output/late.txt").write_text("late\n", encoding="utf-8")
            return {"failed": True, "final_response": ""}

    async def go() -> JobStatus:
        runner = InProcessHermes(timeout=0.2, agent_factory=lambda **kw: SlowAgent(**kw))

        async def on_progress(_ev: ProgressEvent) -> None:
            return None

        return await runner.run(job, "slow", on_progress)

    status = asyncio.run(go())
    assert status is JobStatus.FAILED
    assert started.is_set()
    # Session ID persisted even on interrupted completion.
    assert read_session_id(job) == "sess-test"
    # cwd lease released (back to the test process cwd).
    assert Path.cwd() != job.directory
    # The worker thread wrote inside the job dir (lease held until exit).
    assert entered_cwd and entered_cwd[0] == str(job.directory)


def test_one_agent_at_a_time(tmp_path: Path) -> None:
    job_a = _make_job(tmp_path)
    job_b = _make_job(tmp_path)
    overlap: list[int] = []
    counter = {"n": 0}
    lock = threading.Lock()

    class OverlapProbe(FakeAgent):
        def run_conversation(self, prompt, conversation_history=None, **kw):
            with lock:
                counter["n"] += 1
                overlap.append(counter["n"])
            time.sleep(0.3)
            with lock:
                counter["n"] -= 1
                overlap.append(counter["n"])
            return {"final_response": "ok"}

    async def go() -> None:
        runner_a = InProcessHermes(timeout=30, agent_factory=lambda **kw: OverlapProbe(**kw))
        runner_b = InProcessHermes(timeout=30, agent_factory=lambda **kw: OverlapProbe(**kw))

        async def on_progress(_ev: ProgressEvent) -> None:
            return None

        await asyncio.gather(
            runner_a.run(job_a, "a", on_progress), runner_b.run(job_b, "b", on_progress)
        )

    asyncio.run(go())
    assert max(overlap) <= 1


def test_followups_all_delivered_and_cursor_advances_only_on_success(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    worker = HermesWorker(agent_factory=_factory, timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    asyncio.run(worker.run(job, on_progress))
    (job.directory / "input" / "followup-01.txt").write_text("first", encoding="utf-8")
    (job.directory / "input" / "followup-02.txt").write_text("second", encoding="utf-8")
    assert len(pending_followups(job)) == 2
    asyncio.run(worker.run(job, on_progress))
    # Both queued messages reached the executed prompt (none lost).
    assert "first" in FakeAgent.last.prompts[-1]
    assert "second" in FakeAgent.last.prompts[-1]
    assert pending_followups(job) == []

    # Failed runs keep pending (failed recovery).
    job2 = _make_job(tmp_path)
    (job2.directory / "input" / "followup-01.txt").write_text("keep me", encoding="utf-8")

    def fail_factory(**kwargs: Any) -> FakeAgent:
        agent = FakeAgent(**kwargs)
        agent._fail = True
        return agent

    failing = HermesWorker(agent_factory=fail_factory, timeout=30)
    assert asyncio.run(failing.run(job2, on_progress)) is JobStatus.FAILED
    assert len(pending_followups(job2)) == 1


def test_session_continuity_reuses_session_id(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    worker = HermesWorker(agent_factory=_factory, timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    asyncio.run(worker.run(job, on_progress))
    first_sid = read_session_id(job)
    (job.directory / "input" / "followup-01.txt").write_text("again", encoding="utf-8")
    asyncio.run(worker.run(job, on_progress))
    assert FakeAgent.last.kwargs.get("session_id") == first_sid


def test_process_locks_and_scoped_home(tmp_path: Path) -> None:
    with room_lock(tmp_path):
        assert (tmp_path / "room.lock").is_file()
    home = tmp_path / "scoped-home"
    with scoped_hermes_home(home):
        pass
    assert resolve_hermes_home(tmp_path).name == ".hermes-room"
    with agent_serial(blocking=False) as acquired:
        assert acquired is True
