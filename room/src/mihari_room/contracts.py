"""作業部屋の契約。実装は store / discord / worker に分かれる。

ここにある型と Protocol を変えるときは、並列 worktree 全部に影響する。
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Literal, Protocol


class JobStatus(StrEnum):
    """Forum タグと 1:1。"""

    QUEUED = "queued"
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"
    CANCELLED = "cancelled"

    def discord_tag(self) -> str:
        return {
            JobStatus.QUEUED: "待ち",
            JobStatus.RUNNING: "作業中",
            JobStatus.DONE: "完了",
            JobStatus.FAILED: "失敗",
            JobStatus.CANCELLED: "中断",
        }[self]


class JobSource(StrEnum):
    PET = "pet"
    FORUM = "forum"
    FOLLOWUP = "followup"


class ProgressKind(StrEnum):
    SPEECH = "speech"
    LOG = "log"
    FILE = "file"
    SUMMARY = "summary"


@dataclass(frozen=True, slots=True)
class Job:
    id: str
    title: str
    body: str
    status: JobStatus
    source: JobSource
    directory: Path
    thread_id: int | None = None
    requested_by: str | None = None
    parent_id: str | None = None


@dataclass(frozen=True, slots=True)
class CreateJobRequest:
    title: str
    body: str
    source: JobSource
    requested_by: str | None = None
    parent_id: str | None = None
    thread_id: int | None = None


@dataclass(frozen=True, slots=True)
class CreateJobResponse:
    job_id: str
    thread_id: int | None
    status: JobStatus


@dataclass(frozen=True, slots=True)
class ProgressEvent:
    kind: ProgressKind
    text: str
    path: Path | None = None


class JobStore(Protocol):
    """ディスク上の部屋。仕事は jobs/<id>/ に置く。"""

    def create(self, request: CreateJobRequest) -> Job: ...
    def get(self, job_id: str) -> Job: ...
    def list_queued(self) -> Sequence[Job]: ...
    def set_status(self, job_id: str, status: JobStatus) -> Job: ...
    def set_thread_id(self, job_id: str, thread_id: int) -> Job: ...
    def restore_running_to_queued(self) -> Sequence[Job]: ...
    def job_dir(self, job_id: str) -> Path: ...
    def input_dir(self, job_id: str) -> Path: ...
    def output_dir(self, job_id: str) -> Path: ...


class JobQueue(Protocol):
    """机は一つ。同時に RUNNING は 1 件。"""

    def enqueue(self, job: Job) -> None: ...
    def dequeue(self) -> Job | None: ...
    def running(self) -> Job | None: ...
    def cancel(self, job_id: str, *, by: str) -> Job: ...


class ForumBoard(Protocol):
    """Discord Forum の口。Hermes の Gateway は使わない。"""

    async def create_thread(self, job: Job) -> int: ...
    async def set_tag(self, thread_id: int, status: JobStatus) -> None: ...
    async def post_speech(self, thread_id: int, text: str) -> None: ...
    async def post_log(self, thread_id: int, text: str) -> None: ...
    async def post_file(self, thread_id: int, path: Path) -> None: ...
    async def post_summary(self, thread_id: int, text: str) -> None: ...


class JobWorker(Protocol):
    """Hermes を裏で叩く。Discord には出ない。"""

    async def run(
        self,
        job: Job,
        on_progress: Callable[[ProgressEvent], Awaitable[None]],
    ) -> JobStatus: ...


#: 部屋のルートからの相対。実体は $MIHARI_ROOM または引数の root。
JOBS_DIRNAME = "jobs"
INPUT_DIRNAME = "input"
OUTPUT_DIRNAME = "output"
META_FILENAME = "meta.json"

AuthHeader = Literal["X-Mihari-Token"]
AUTH_HEADER: AuthHeader = "X-Mihari-Token"
