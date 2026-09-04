"""並列実装用のメモリ実装。本番のディスク実装ではない。"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import replace
from pathlib import Path
from uuid import uuid4

from mihari_room.contracts import (
    INPUT_DIRNAME,
    JOBS_DIRNAME,
    OUTPUT_DIRNAME,
    CreateJobRequest,
    Job,
    JobStatus,
)


class InMemoryJobStore:
    """JobStore の契約を満たすだけの仮実装。"""

    def __init__(self, root: Path) -> None:
        self._root = root
        self._jobs: dict[str, Job] = {}

    def create(self, request: CreateJobRequest) -> Job:
        job_id = uuid4().hex[:12]
        directory = self._root / JOBS_DIRNAME / job_id
        directory.mkdir(parents=True)
        (directory / INPUT_DIRNAME).mkdir()
        (directory / OUTPUT_DIRNAME).mkdir()
        job = Job(
            id=job_id,
            title=request.title,
            body=request.body,
            status=JobStatus.QUEUED,
            source=request.source,
            directory=directory,
            thread_id=request.thread_id,
            requested_by=request.requested_by,
            parent_id=request.parent_id,
        )
        self._jobs[job_id] = job
        return job

    def get(self, job_id: str) -> Job:
        return self._jobs[job_id]

    def list_queued(self) -> Sequence[Job]:
        return tuple(job for job in self._jobs.values() if job.status is JobStatus.QUEUED)

    def list_running(self) -> Sequence[Job]:
        return tuple(job for job in self._jobs.values() if job.status is JobStatus.RUNNING)

    def find_by_thread_id(self, thread_id: int) -> Job | None:
        for job in self._jobs.values():
            if job.thread_id == thread_id:
                return job
        return None

    def set_status(self, job_id: str, status: JobStatus) -> Job:
        updated = replace(self._jobs[job_id], status=status)
        self._jobs[job_id] = updated
        return updated

    def set_thread_id(self, job_id: str, thread_id: int) -> Job:
        updated = replace(self._jobs[job_id], thread_id=thread_id)
        self._jobs[job_id] = updated
        return updated

    def restore_running_to_queued(self) -> Sequence[Job]:
        restored: list[Job] = []
        for job_id, job in list(self._jobs.items()):
            if job.status is JobStatus.RUNNING:
                restored.append(self.set_status(job_id, JobStatus.QUEUED))
        return tuple(restored)

    def job_dir(self, job_id: str) -> Path:
        return self.get(job_id).directory

    def input_dir(self, job_id: str) -> Path:
        return self.job_dir(job_id) / INPUT_DIRNAME

    def output_dir(self, job_id: str) -> Path:
        return self.job_dir(job_id) / OUTPUT_DIRNAME
