"""Cancellation interrupts the real worker; followup waits for thread exit."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from pathlib import Path

from mihari_room.contracts import CreateJobRequest, Job, JobSource, JobStatus, ProgressEvent
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from tests.recording import RecordingBoard


class InterruptibleWorker:
    """Fake running worker with real interrupt semantics."""

    def __init__(self) -> None:
        self.cancelled: list[str] = []
        self.live: set[str] = set()
        self.runs: list[str] = []

    async def run(
        self, job: Job, on_progress: Callable[[ProgressEvent], Awaitable[None]]
    ) -> JobStatus:
        self.runs.append(job.id)
        self.live.add(job.id)
        try:
            for _ in range(200):
                await asyncio.sleep(0.01)
            return JobStatus.DONE
        except asyncio.CancelledError:
            raise
        finally:
            self.live.discard(job.id)

    def request_cancel(self, job_id: str) -> bool:
        self.cancelled.append(job_id)
        self.live.discard(job_id)
        return True

    def is_running(self, job_id: str) -> bool:
        return job_id in self.live


class FailingBoard(RecordingBoard):
    async def create_thread(self, job: Job) -> int:
        raise RuntimeError("forum down")


def _orch(tmp_path: Path, worker: InterruptibleWorker | None = None):
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    worker = worker or InterruptibleWorker()
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id="owner"), board, worker)
    return orch, store, board, worker


async def _submit(tmp_path: Path, orch: RoomOrchestrator, title: str = "t") -> Job:
    job = await orch.submit(CreateJobRequest(title=title, body="b", source=JobSource.PET))
    return job


def test_cancel_interrupts_running_worker(tmp_path: Path) -> None:
    async def go() -> None:
        orch, store, _, worker = _orch(tmp_path)
        job = await _submit(tmp_path, orch)
        orch.start_pump()
        for _ in range(200):
            if job.id in worker.live:
                break
            await asyncio.sleep(0.01)
        assert job.id in worker.live
        await orch.cancel(job.id, by="owner")
        assert job.id in worker.cancelled
        await orch.aclose()

    asyncio.run(go())


def test_followup_while_cancelled_thread_runs_does_not_requeue_early(tmp_path: Path) -> None:
    async def go() -> None:
        orch, store, _, worker = _orch(tmp_path)
        job = await _submit(tmp_path, orch)
        # Simulate: worker thread still alive but status already CANCELLED.
        worker.live.add(job.id)
        store.set_status(job.id, JobStatus.CANCELLED)
        returned = await orch.follow_up_job(job.id, "続き", requested_by="owner")
        assert returned.status is JobStatus.CANCELLED
        assert store.get(job.id).status is JobStatus.CANCELLED
        worker.live.discard(job.id)
        await orch.aclose()

    asyncio.run(go())


def test_submit_failure_leaves_no_phantom_queued_job(tmp_path: Path) -> None:
    async def go() -> None:
        store = FileJobStore(tmp_path)
        board = FailingBoard()
        worker = InterruptibleWorker()
        orch = RoomOrchestrator(store, FileJobQueue(store, owner_id="owner"), board, worker)
        try:
            await orch.submit(CreateJobRequest(title="t", body="b", source=JobSource.PET))
        except RuntimeError:
            pass
        else:
            raise AssertionError("expected RuntimeError")
        assert list(store.list_queued()) == []
        assert list(store.list_running()) == []
        await orch.aclose()

    asyncio.run(go())
