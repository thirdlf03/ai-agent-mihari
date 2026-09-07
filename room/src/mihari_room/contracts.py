"""作業部屋の契約。実装は store / discord / worker に分かれる。

ここにある型と Protocol を変えるときは、並列 worktree 全部に影響する。
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import Any, Literal, Protocol


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
    #: memory candidate proposed (approval-gated, job does not block).
    MEMORY_CANDIDATE = "memory_candidate"


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
    #: 依頼時の明示的な外部公開許可（Temporary Deploy の扉）。
    #: 認証なしで外向けに出す worker 等を動かすための合図。
    allow_external_publish: bool = False


@dataclass(frozen=True, slots=True)
class CreateJobRequest:
    title: str
    body: str
    source: JobSource
    requested_by: str | None = None
    parent_id: str | None = None
    thread_id: int | None = None
    #: 依頼ごとの明示的な外部公開許可（既定は拒否）。
    #: この合図がない限り Temporary Deploy の道具は渡さない。
    allow_external_publish: bool = False


@dataclass(frozen=True, slots=True)
class CreateJobResponse:
    job_id: str
    thread_id: int | None
    status: JobStatus


@dataclass(frozen=True, slots=True)
class ScreenshotAttachment:
    """Mac スクショ 1 枚。バイト列と、Retina/複数画面のためのメタデータを持つ。

    スクショは `input/screenshots/` に保存され、Hermes のマルチモーダル入力に
    バイト列で載る。本文へファイルパスを書くだけでは済ませない（#22）。
    """

    filename: str
    data: bytes
    #: 撮影元ディスプレイ/ウィンドウの情報（scale・座標など）。任意。
    metadata: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class ProgressEvent:
    kind: ProgressKind
    text: str
    path: Path | None = None
    #: 進捗がどの段階（調査中・ビルド中…）かを表す任意の値。
    #: 未指定なら既存どおり振る舞う（後方互換）。
    phase: str | None = None
    #: どのツールから来た進捗かを表す任意の値。未指定なら None。
    tool_name: str | None = None


class JobStore(Protocol):
    """ディスク上の部屋。仕事は jobs/<id>/ に置く。"""

    def create(self, request: CreateJobRequest) -> Job: ...
    def get(self, job_id: str) -> Job: ...
    def list_queued(self) -> Sequence[Job]: ...
    def list_running(self) -> Sequence[Job]: ...
    def find_by_thread_id(self, thread_id: int) -> Job | None: ...
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
#: Mac スクショ（#22）の置き場。input/ 配下に置き、成果物公開（output/）には入れない。
SCREENSHOTS_DIRNAME = "screenshots"
#: ペット依頼の本文。input/ が空に見えるのを防ぐ。
REQUEST_FILENAME = "request.md"
#: Discord Forum のスレッド名が空のときの題。
DEFAULT_JOB_TITLE = "依頼"


def write_request_markdown(input_dir: Path, title: str, body: str) -> None:
    """依頼本文を input/request.md に置く。添付が無くても読む先があるようにする。"""
    heading = title.strip() or DEFAULT_JOB_TITLE
    text = f"# {heading}\n\n{body.rstrip()}\n"
    input_dir.mkdir(parents=True, exist_ok=True)
    (input_dir / REQUEST_FILENAME).write_text(text, encoding="utf-8")


AuthHeader = Literal["X-Mihari-Token"]
AUTH_HEADER: AuthHeader = "X-Mihari-Token"
