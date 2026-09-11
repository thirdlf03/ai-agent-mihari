"""In-process AIAgent 経路。本家 Hermes は使わず、偽エージェントを注入する。"""

from __future__ import annotations

import threading
from pathlib import Path
from typing import Any

from mihari_room.contracts import (
    CreateJobRequest,
    Job,
    JobSource,
    JobStatus,
    ProgressEvent,
    ProgressKind,
)
from mihari_room.fakes import InMemoryJobStore
from mihari_room.job_interactions import append_steer, pending_steers
from mihari_room.worker.agent import read_session_id
from mihari_room.worker.hermes import HermesWorker


def _make_job(tmp_path: Path, title: str = "まとめ", body: str = "今日の分") -> Job:
    store = InMemoryJobStore(tmp_path)
    job = store.create(CreateJobRequest(title=title, body=body, source=JobSource.PET))
    (job.directory / "input" / "memo.txt").write_text("入力メモ", encoding="utf-8")
    return job


class FakeAgent:
    """本家 AIAgent の最小の口。cwd で output を書き、コールバックを飛ばす。"""

    last: FakeAgent | None = None

    def __init__(self, **kwargs: Any) -> None:
        self.session_id = kwargs.get("session_id") or "sess-test"
        self.tool_progress_callback = kwargs.get("tool_progress_callback")
        self.prompts: list[str] = []
        self.history = kwargs
        self._fail = False
        self._sleep = 0.0
        self._stop = threading.Event()
        FakeAgent.last = self

    def interrupt(self, *_args: Any) -> None:
        self._stop.set()

    def run_conversation(
        self,
        prompt: str,
        conversation_history: list | None = None,
        **_kwargs: Any,
    ) -> dict:
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

    def shutdown_memory_provider(self, *_args: Any) -> None:
        return None


def _factory(**kwargs: Any) -> FakeAgent:
    return FakeAgent(**kwargs)


async def test_inprocess_emits_tool_log_speech_and_file(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    worker = HermesWorker(agent_factory=_factory, timeout=30)
    events: list[ProgressEvent] = []

    async def on_progress(ev: ProgressEvent) -> None:
        events.append(ev)

    status = await worker.run(job, on_progress)
    assert status is JobStatus.DONE
    kinds = [e.kind for e in events]
    assert ProgressKind.LOG in kinds
    assert ProgressKind.SPEECH in kinds
    assert ProgressKind.SUMMARY not in kinds
    file_events = [e for e in events if e.kind is ProgressKind.FILE]
    assert any(e.path is not None and e.path.name == "hello.txt" for e in file_events)
    assert (job.directory / "output" / "hello.txt").is_file()
    assert read_session_id(job) == "sess-test"
    log_text = " ".join(e.text for e in events if e.kind is ProgressKind.LOG)
    assert "read_file" in log_text or "Reading" in log_text
    assert FakeAgent.last is not None
    assert "まとめ" in FakeAgent.last.prompts[0]
    assert "今日の分" in FakeAgent.last.prompts[0]


async def test_followup_reuses_session_and_sends_latest_note(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    worker = HermesWorker(agent_factory=_factory, timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    await worker.run(job, on_progress)
    (job.directory / "input" / "followup-01.txt").write_text("もっと短くして", encoding="utf-8")
    await worker.run(job, on_progress)
    assert FakeAgent.last is not None
    assert FakeAgent.last.prompts[-1].startswith("続きの依頼:")
    assert "もっと短くして" in FakeAgent.last.prompts[-1]
    assert FakeAgent.last.history.get("session_id") == "sess-test"


async def test_queued_followup_is_appended_before_first_run(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    (job.directory / "input" / "followup-01.txt").write_text("窓もお願い", encoding="utf-8")
    worker = HermesWorker(agent_factory=_factory, timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    await worker.run(job, on_progress)
    assert FakeAgent.last is not None
    assert "窓もお願い" in FakeAgent.last.prompts[0]
    assert "追記:" in FakeAgent.last.prompts[0]


async def test_pending_steer_reaches_turn_prompt_once(tmp_path: Path) -> None:
    """live 未配信の steer はターンのプロンプトに載り、消費後は再送しない。"""
    job = _make_job(tmp_path)
    append_steer(job.directory, "左側を優先して")
    worker = HermesWorker(agent_factory=_factory, timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    await worker.run(job, on_progress)
    assert FakeAgent.last is not None
    assert "左側を優先して" in FakeAgent.last.prompts[0]
    assert "追記:" in FakeAgent.last.prompts[0]
    assert pending_steers(job) == []
    # 消費済みなので次ターンでは再送しない。
    await worker.run(job, on_progress)
    assert "左側を優先して" not in FakeAgent.last.prompts[-1]


async def test_inprocess_failure_returns_failed(tmp_path: Path) -> None:
    job = _make_job(tmp_path)

    def factory(**kwargs: Any) -> FakeAgent:
        agent = FakeAgent(**kwargs)
        agent._fail = True
        return agent

    worker = HermesWorker(agent_factory=factory, timeout=30)
    events: list[ProgressEvent] = []

    async def on_progress(ev: ProgressEvent) -> None:
        events.append(ev)

    assert await worker.run(job, on_progress) is JobStatus.FAILED
    assert all(e.kind is not ProgressKind.SUMMARY for e in events)
    assert all(e.kind is not ProgressKind.FILE for e in events)


async def test_inprocess_timeout_returns_failed(tmp_path: Path) -> None:
    job = _make_job(tmp_path)

    def factory(**kwargs: Any) -> FakeAgent:
        agent = FakeAgent(**kwargs)
        agent._sleep = 5
        return agent

    worker = HermesWorker(agent_factory=factory, timeout=0.2)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    assert await worker.run(job, on_progress) is JobStatus.FAILED


async def test_inprocess_does_not_write_tokens(tmp_path: Path, monkeypatch) -> None:
    secret = "sk-test-secret-do-not-leak-12345"
    monkeypatch.setenv("DISCORD_TOKEN", secret)
    monkeypatch.setenv("CODEX_API_KEY", secret)
    job = _make_job(tmp_path)
    worker = HermesWorker(agent_factory=_factory, timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    assert await worker.run(job, on_progress) is JobStatus.DONE
    for path in job.directory.rglob("*"):
        if path.is_file():
            assert secret not in path.read_text(encoding="utf-8", errors="replace")


class _ReasonFailingAgent(FakeAgent):
    """失敗を返し、理由を final_response に残す偽エージェント。"""

    def run_conversation(
        self, prompt: str, conversation_history: list | None = None, **_kwargs: Any
    ) -> dict:
        return {"failed": True, "final_response": "API キーが切れてた"}


async def test_failure_reason_is_recorded_when_model_reports_failure(tmp_path: Path) -> None:
    """モデルが失敗理由を返したら failure_reason.txt に残す。"""
    job = _make_job(tmp_path)
    worker = HermesWorker(agent_factory=lambda **kw: _ReasonFailingAgent(**kw), timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    assert await worker.run(job, on_progress) is JobStatus.FAILED
    reason = (job.directory / "failure_reason.txt").read_text(encoding="utf-8")
    assert reason == "API キーが切れてた"


async def test_timeout_records_timeout_reason(tmp_path: Path) -> None:
    """時間切れは failure_reason.txt に「時間切れ」を残す。"""
    job = _make_job(tmp_path)

    def factory(**kwargs: Any) -> FakeAgent:
        agent = FakeAgent(**kwargs)
        agent._sleep = 5
        return agent

    worker = HermesWorker(agent_factory=factory, timeout=0.2)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    assert await worker.run(job, on_progress) is JobStatus.FAILED
    reason = (job.directory / "failure_reason.txt").read_text(encoding="utf-8")
    assert reason == "時間切れ"


async def test_success_clears_old_failure_reason(tmp_path: Path) -> None:
    """成功したら古い失敗理由は消す（次の失敗に引きずらない）。"""
    job = _make_job(tmp_path)
    (job.directory / "failure_reason.txt").write_text("前回の理由", encoding="utf-8")
    worker = HermesWorker(agent_factory=_factory, timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    assert await worker.run(job, on_progress) is JobStatus.DONE
    assert not (job.directory / "failure_reason.txt").exists()


class _SplitResponseAgent(FakeAgent):
    """発話と説明を空行で分けて返す偽エージェント。"""

    def run_conversation(
        self, prompt: str, conversation_history: list | None = None, **_kwargs: Any
    ) -> dict:
        return {"final_response": "まとめたよ。\n\n長い説明はこれ。\n二行目も説明。"}


async def test_speech_and_explanation_are_split_into_separate_events(tmp_path: Path) -> None:
    """短い読み上げ（SPEECH）と長い説明（SUMMARY）を別イベントで流す。"""
    job = _make_job(tmp_path)
    worker = HermesWorker(agent_factory=lambda **kw: _SplitResponseAgent(**kw), timeout=30)
    events: list[ProgressEvent] = []

    async def on_progress(ev: ProgressEvent) -> None:
        events.append(ev)

    assert await worker.run(job, on_progress) is JobStatus.DONE
    kinds = [e.kind for e in events]
    assert kinds[0] is ProgressKind.SPEECH
    assert ProgressKind.SUMMARY in kinds
    speeches = [e.text for e in events if e.kind is ProgressKind.SPEECH]
    summaries = [e.text for e in events if e.kind is ProgressKind.SUMMARY]
    assert speeches == ["まとめたよ。"]
    assert summaries == ["長い説明はこれ。\n二行目も説明。"]
