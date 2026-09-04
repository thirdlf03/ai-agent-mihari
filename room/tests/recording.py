"""テスト用の Forum 口と Worker。本番コードには置かない。"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from pathlib import Path

from mihari_room.contracts import Job, JobStatus, ProgressEvent


class RecordingBoard:
    def __init__(self) -> None:
        self.thread_seq = 1000
        self.created: list[Job] = []
        self.tags: list[tuple[int, str]] = []
        self.speech: list[tuple[int, str]] = []
        self.logs: list[tuple[int, str]] = []
        self.files: list[tuple[int, Path]] = []
        self.summaries: list[tuple[int, str]] = []

    async def create_thread(self, job: Job) -> int:
        self.thread_seq += 1
        self.created.append(job)
        return self.thread_seq

    async def set_tag(self, thread_id: int, status: JobStatus) -> None:
        self.tags.append((thread_id, status.discord_tag()))

    async def post_speech(self, thread_id: int, text: str) -> None:
        self.speech.append((thread_id, text))

    async def post_log(self, thread_id: int, text: str) -> None:
        self.logs.append((thread_id, text))

    async def post_file(self, thread_id: int, path: Path) -> None:
        self.files.append((thread_id, path))

    async def post_summary(self, thread_id: int, text: str) -> None:
        self.summaries.append((thread_id, text))


class ScriptedWorker:
    def __init__(
        self,
        events: list[ProgressEvent],
        result: JobStatus = JobStatus.DONE,
        on_start: Callable[[Job], Awaitable[None]] | None = None,
        results: list[JobStatus] | None = None,
    ) -> None:
        self.events = events
        self.result = result
        self.jobs: list[Job] = []
        self._on_start = on_start
        self._results = list(results) if results is not None else None

    async def run(
        self,
        job: Job,
        on_progress: Callable[[ProgressEvent], Awaitable[None]],
    ) -> JobStatus:
        self.jobs.append(job)
        if self._on_start is not None:
            await self._on_start(job)
        for event in self.events:
            await on_progress(event)
        if self._results:
            return self._results.pop(0)
        return self.result
