"""キュー・Forum・Hermes を一本に繋ぐ。Discord の口調変換はしない。"""

from __future__ import annotations

import asyncio
from collections.abc import Sequence
from pathlib import Path

from mihari_room.contracts import (
    CreateJobRequest,
    ForumBoard,
    Job,
    JobQueue,
    JobStatus,
    JobStore,
    JobWorker,
    ProgressEvent,
    ProgressKind,
)
from mihari_room.store.file_store import JobNotFound

#: 実行中に続きが来たとき、終わったらもう一回回す印。
REQUEUE_FILENAME = "requeue"


class RoomOrchestrator:
    """机番。HTTP と Forum の両方から仕事を受けて、空いたら Hermes に渡す。"""

    def __init__(
        self,
        store: JobStore,
        queue: JobQueue,
        board: ForumBoard,
        worker: JobWorker,
    ) -> None:
        self._store = store
        self._queue = queue
        self._board = board
        self._worker = worker
        self._wake = asyncio.Event()
        self._pump_task: asyncio.Task[None] | None = None

    @property
    def store(self) -> JobStore:
        return self._store

    def restore(self) -> Sequence[Job]:
        """起動直後。作業中だった机を待ちに戻す。"""
        restored = self._store.restore_running_to_queued()
        if restored:
            self.wake()
        return restored

    def wake(self) -> None:
        self._wake.set()

    def start_pump(self) -> None:
        """待ち行列を回すループを立てる。テストでも本番でも同じ。"""
        if self._pump_task is None or self._pump_task.done():
            self._pump_task = asyncio.create_task(self._pump(), name="mihari-room-pump")

    async def aclose(self) -> None:
        task = self._pump_task
        self._pump_task = None
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    async def submit(
        self,
        request: CreateJobRequest,
        *,
        attachments: Sequence[tuple[str, bytes]] = (),
    ) -> Job:
        """新しい仕事。ペット経由ならスレッドを切る。Forum 直なら thread_id 済み。"""
        job = self._store.create(request)
        self._save_attachments(job.id, attachments)
        if job.thread_id is None:
            thread_id = await self._board.create_thread(job)
            job = self._store.set_thread_id(job.id, thread_id)
        await self._board.set_tag(self._require_thread(job), JobStatus.QUEUED)
        self._queue.enqueue(job)
        self.wake()
        return self._store.get(job.id)

    async def follow_up(self, thread_id: int, body: str, *, requested_by: str) -> Job:
        """同じスレッドの続き。同じフォルダに追記して、空いたらもう一度回す。"""
        job = self._require_by_thread(thread_id)
        self._write_followup(job.id, body)
        current = self._store.get(job.id)
        if current.status is JobStatus.RUNNING:
            (self._store.job_dir(job.id) / REQUEUE_FILENAME).write_text("1", encoding="utf-8")
            return current
        if current.status is not JobStatus.QUEUED:
            current = self._store.set_status(job.id, JobStatus.QUEUED)
            await self._board.set_tag(self._require_thread(current), JobStatus.QUEUED)
            self._queue.enqueue(current)
            self.wake()
        return self._store.get(job.id)

    async def cancel(self, job_id: str, *, by: str) -> Job:
        job = self._queue.cancel(job_id, by=by)
        thread_id = job.thread_id
        if thread_id is not None:
            await self._board.set_tag(thread_id, JobStatus.CANCELLED)
            await self._board.post_speech(thread_id, "わかった。途中まで残しておくね。")
        self.wake()
        return self._store.get(job.id)

    async def cancel_thread(self, thread_id: int, *, by: str) -> Job:
        job = self._require_by_thread(thread_id)
        return await self.cancel(job.id, by=by)

    async def _pump(self) -> None:
        try:
            while True:
                await self._wake.wait()
                self._wake.clear()
                await self._run_available()
        except asyncio.CancelledError:
            raise

    async def _run_available(self) -> None:
        while True:
            job = self._queue.dequeue()
            if job is None:
                return
            await self._run_job(job)

    async def _run_job(self, job: Job) -> None:
        thread_id = self._require_thread(job)
        await self._board.set_tag(thread_id, JobStatus.RUNNING)

        async def on_progress(event: ProgressEvent) -> None:
            latest = self._store.get(job.id)
            if latest.status is JobStatus.CANCELLED:
                return
            if event.kind is ProgressKind.SPEECH:
                await self._board.post_speech(thread_id, event.text)
            elif event.kind is ProgressKind.LOG:
                await self._board.post_log(thread_id, event.text)
            elif event.kind is ProgressKind.FILE:
                if event.path is not None:
                    await self._board.post_file(thread_id, event.path)
            elif event.kind is ProgressKind.SUMMARY:
                await self._board.post_summary(thread_id, event.text)

        status = await self._worker.run(job, on_progress)
        latest = self._store.get(job.id)
        if latest.status is JobStatus.CANCELLED:
            self.wake()
            return
        latest = self._store.set_status(job.id, status)
        await self._board.set_tag(thread_id, status)
        if status is JobStatus.DONE and self._consume_requeue(job.id):
            latest = self._store.set_status(job.id, JobStatus.QUEUED)
            await self._board.set_tag(thread_id, JobStatus.QUEUED)
            self._queue.enqueue(latest)
        self.wake()

    def _consume_requeue(self, job_id: str) -> bool:
        path = self._store.job_dir(job_id) / REQUEUE_FILENAME
        if not path.is_file():
            return False
        path.unlink()
        return True

    def _write_followup(self, job_id: str, body: str) -> None:
        folder = self._store.input_dir(job_id)
        existing = list(folder.glob("followup-*.txt"))
        path = folder / f"followup-{len(existing) + 1:02d}.txt"
        path.write_text(body, encoding="utf-8")

    def _save_attachments(self, job_id: str, attachments: Sequence[tuple[str, bytes]]) -> None:
        folder = self._store.input_dir(job_id)
        for name, data in attachments:
            safe = Path(name).name or "attachment"
            (folder / safe).write_bytes(data)

    def _require_thread(self, job: Job) -> int:
        if job.thread_id is None:
            raise RuntimeError(f"job {job.id} にスレッドがない")
        return job.thread_id

    def _require_by_thread(self, thread_id: int) -> Job:
        finder = getattr(self._store, "find_by_thread_id", None)
        if callable(finder):
            job = finder(thread_id)
            if job is not None:
                return job
        raise JobNotFound(f"thread {thread_id}")
