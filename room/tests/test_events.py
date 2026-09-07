"""events.ndjson の日誌と、オーケストレータの日誌連携。"""

from __future__ import annotations

import asyncio
from pathlib import Path

from mihari_room.contracts import (
    CreateJobRequest,
    Job,
    JobSource,
    JobStatus,
    ProgressEvent,
    ProgressKind,
)
from mihari_room.events import (
    EVENTS_FILENAME,
    EventJournal,
    EventPhase,
    JournalKind,
    sanitize_text,
)
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from tests.recording import RecordingBoard, ScriptedWorker


def _make_room(
    tmp_path: Path,
    worker: ScriptedWorker | None = None,
) -> tuple[RoomOrchestrator, FileJobStore, RecordingBoard, ScriptedWorker]:
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    scripted = worker or ScriptedWorker(
        [
            ProgressEvent(kind=ProgressKind.LOG, text="[tool] 読む"),
            ProgressEvent(kind=ProgressKind.SPEECH, text="片付けたよ"),
            ProgressEvent(kind=ProgressKind.SUMMARY, text="片付けたよ"),
        ]
    )
    orch = RoomOrchestrator(store, FileJobQueue(store), board, scripted)
    return orch, store, board, scripted


def test_journal_appends_monotonic_records(tmp_path: Path) -> None:
    journal = EventJournal.for_job(tmp_path / "j1")
    first = journal.append(
        job_id="j1", phase=EventPhase.QUEUED, kind=JournalKind.LOG, text="並んだ"
    )
    second = journal.append(
        job_id="j1", phase=EventPhase.DONE, kind=JournalKind.SUMMARY, text="終わった"
    )
    assert first["id"] == 1
    assert second["id"] == 2

    assert (tmp_path / "j1" / EVENTS_FILENAME).is_file()
    events = journal.events()
    assert [e["id"] for e in events] == [1, 2]
    for event in events:
        assert set(event) == {"id", "job_id", "phase", "kind", "text", "progress", "created_at"}
        assert event["job_id"] == "j1"
        assert event["progress"] is None
        # UTC の ISO 8601
        assert "T" in event["created_at"]
        assert event["created_at"].endswith("+00:00")
    assert journal.latest()["id"] == 2
    assert journal.after(1)[0]["id"] == 2


def test_restart_keeps_monotonic_ids(tmp_path: Path) -> None:
    journal = EventJournal.for_job(tmp_path / "j1")
    journal.append(job_id="j1", phase=EventPhase.QUEUED, kind=JournalKind.LOG, text="a")
    journal.append(job_id="j1", phase=EventPhase.QUEUED, kind=JournalKind.LOG, text="b")
    # 再起動を模す：新しいインスタンスで続きを付ける。
    restarted = EventJournal.for_job(tmp_path / "j1")
    third = restarted.append(job_id="j1", phase=EventPhase.DONE, kind=JournalKind.SUMMARY, text="c")
    assert third["id"] == 3


def test_sanitize_secrets_and_claim_url() -> None:
    text = 'claim_url = "https://user:pass@host/path?key=1"'
    cleaned = sanitize_text(text)
    assert "***" in cleaned
    assert "user:pass" not in cleaned

    preview = "see https://dash.cloudflare.com/claim-preview?claimToken=SECRETCLAIM now"
    cleaned_preview = sanitize_text(preview)
    assert "SECRETCLAIM" not in cleaned_preview
    assert "claimToken" not in cleaned_preview

    assert "hunter2" not in sanitize_text("MIHARI_ROOM_TOKEN=hunter2")
    assert "sk-abc123xyz" not in sanitize_text("key is sk-abc123xyz")
    assert "Bearer abcd1234" not in sanitize_text("Authorization: Bearer abcd1234")


def test_progress_event_backwards_compatible() -> None:
    plain = ProgressEvent(kind=ProgressKind.LOG, text="x")
    assert plain.phase is None
    assert plain.tool_name is None
    enriched = ProgressEvent(
        kind=ProgressKind.LOG,
        text="x",
        phase=EventPhase.BUILDING.value,
        tool_name="write_file",
    )
    assert enriched.phase == "building"
    assert enriched.tool_name == "write_file"


async def test_submit_run_journal_phases(tmp_path: Path) -> None:
    orch, store, _board, _ = _make_room(tmp_path)
    orch.start_pump()
    job = await orch.submit(
        CreateJobRequest(title="掃除", body="部屋を片付けて", source=JobSource.PET)
    )
    await _settle()
    await orch.aclose()

    journal = EventJournal.for_job(store.job_dir(job.id))
    events = journal.events()
    phases = [e["phase"] for e in events]
    kinds = [e["kind"] for e in events]
    # 待ち → はじめ（調査中）→ ログ → 完了
    assert phases[0] == "queued"
    assert "researching" in phases
    assert phases[-1] == "done"
    assert kinds[-1] == "summary"
    assert events[-1]["text"] == "片付けたよ"


async def test_cancel_journal_uses_waiting_cancelled(tmp_path: Path) -> None:
    orch, store, _board, _ = _make_room(tmp_path)
    job = await orch.submit(
        CreateJobRequest(title="やめる", body="x", source=JobSource.PET, requested_by="hana")
    )
    await orch.cancel(job.id, by="hana")
    await orch.aclose()

    events = EventJournal.for_job(store.job_dir(job.id)).events()
    last = events[-1]
    assert last["phase"] == "waiting"
    assert last["kind"] == "cancelled"


async def test_failed_worker_is_terminal_failed(tmp_path: Path) -> None:
    worker = ScriptedWorker(
        [ProgressEvent(kind=ProgressKind.SUMMARY, text="途中")],
        result=JobStatus.FAILED,
    )
    orch, store, _board, _ = _make_room(tmp_path, worker)
    orch.start_pump()
    job = await orch.submit(CreateJobRequest(title="失敗", body="x", source=JobSource.PET))
    await _settle()
    await orch.aclose()

    assert store.get(job.id).status is JobStatus.FAILED
    events = EventJournal.for_job(store.job_dir(job.id)).events()
    assert events[-1]["phase"] == "failed"


async def test_worker_error_is_terminal_failed_not_requeued(tmp_path: Path) -> None:
    class BoomWorker:
        async def run(self, job: Job, on_progress) -> JobStatus:
            raise RuntimeError("爆発した")

    orch, store, _board, _ = _make_room(tmp_path, BoomWorker())
    orch.start_pump()
    job = await orch.submit(CreateJobRequest(title="転ぶ", body="x", source=JobSource.PET))
    await _settle()
    await orch.aclose()

    assert store.get(job.id).status is JobStatus.FAILED
    events = EventJournal.for_job(store.job_dir(job.id)).events()
    assert events[-1]["phase"] == "failed"
    assert "爆発した" in events[-1]["text"]


async def test_queued_jobs_resume_on_startup_without_running(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    job = store.create(
        CreateJobRequest(title="待ってた", body="x", source=JobSource.PET, thread_id=7)
    )
    orch, *_ = _make_room(tmp_path)
    orch.start_pump()
    orch.restore()  # running は無いが、待ちの仕事があれば回す。
    await _settle()
    await orch.aclose()
    assert store.get(job.id).status is JobStatus.DONE


async def test_restore_journals_queued_note(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    job = store.create(CreateJobRequest(title="途中", body="x", source=JobSource.PET, thread_id=9))
    store.set_status(job.id, JobStatus.RUNNING)
    orch, *_ = _make_room(tmp_path)
    orch.restore()
    events = EventJournal.for_job(store.job_dir(job.id)).events()
    assert events[-1]["phase"] == "queued"
    assert store.get(job.id).status is JobStatus.QUEUED


async def test_failed_publish_keeps_job_done(tmp_path: Path) -> None:
    class BoomPublisher:
        enabled = True

        def publish(self, job, session_id=None):
            raise RuntimeError("ディスクが一杯")

    worker = ScriptedWorker(
        [ProgressEvent(kind=ProgressKind.SUMMARY, text="ok")], result=JobStatus.DONE
    )
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    orch = RoomOrchestrator(store, FileJobQueue(store), board, worker, publisher=BoomPublisher())
    orch.start_pump()
    job = await orch.submit(CreateJobRequest(title="公開失敗", body="x", source=JobSource.PET))
    await _settle()
    await orch.aclose()

    # 公開に失敗しても仕事は完了のまま（job を失敗にしない）。
    assert store.get(job.id).status is JobStatus.DONE
    events = EventJournal.for_job(store.job_dir(job.id)).events()
    assert any("公開に失敗" in e["text"] for e in events)


async def _settle() -> None:
    for _ in range(30):
        await asyncio.sleep(0)
        await asyncio.sleep(0.01)
