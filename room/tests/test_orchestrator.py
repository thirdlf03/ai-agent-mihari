"""結線。ペットの POST と Forum の続きが、同じ机に並ぶこと。"""

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
from mihari_room.discord.board import BoundForumBoard
from mihari_room.listener import IncomingMessage, handle_incoming
from mihari_room.orchestrator import REQUEUE_FILENAME, RoomOrchestrator
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


async def test_pet_submit_creates_thread_and_runs(tmp_path: Path) -> None:
    orch, store, board, worker = _make_room(tmp_path)
    orch.start_pump()
    job = await orch.submit(
        CreateJobRequest(title="掃除", body="部屋を片付けて", source=JobSource.PET)
    )
    await asyncio_settle()
    await orch.aclose()

    latest = store.get(job.id)
    assert latest.status is JobStatus.DONE
    assert latest.thread_id == 1001
    assert [tag for _, tag in board.tags] == ["待ち", "作業中", "完了"]
    assert board.speech[-1][1] == "片付けたよ"
    assert board.summaries == []
    assert board.logs[0][1] == "[tool] 読む"
    assert worker.jobs[0].id == job.id


async def test_distinct_summary_is_still_posted(tmp_path: Path) -> None:
    worker = ScriptedWorker(
        [
            ProgressEvent(kind=ProgressKind.SPEECH, text="できたよ"),
            ProgressEvent(kind=ProgressKind.SUMMARY, text="要点: 掃除した"),
        ]
    )
    orch, _store, board, _ = _make_room(tmp_path, worker)
    orch.start_pump()
    await orch.submit(CreateJobRequest(title="掃除", body="頼む", source=JobSource.PET))
    await asyncio_settle()
    await orch.aclose()
    assert board.speech[-1][1] == "できたよ"
    assert board.summaries[-1][1] == "要点: 掃除した"


async def test_second_job_waits_until_desk_is_free(tmp_path: Path) -> None:
    released = asyncio.Event()

    async def block(_job: Job) -> None:
        await released.wait()

    worker = ScriptedWorker(
        [ProgressEvent(kind=ProgressKind.SUMMARY, text="1件目")],
        on_start=block,
    )
    orch, store, _board, _ = _make_room(tmp_path, worker)
    orch.start_pump()
    first = await orch.submit(CreateJobRequest(title="1", body="a", source=JobSource.PET))
    second = await orch.submit(CreateJobRequest(title="2", body="b", source=JobSource.PET))
    await asyncio_settle()
    assert store.get(first.id).status is JobStatus.RUNNING
    assert store.get(second.id).status is JobStatus.QUEUED
    released.set()
    await asyncio_settle()
    await orch.aclose()
    assert store.get(first.id).status is JobStatus.DONE
    assert store.get(second.id).status is JobStatus.DONE


async def test_follow_up_requeues_same_folder(tmp_path: Path) -> None:
    orch, store, board, worker = _make_room(tmp_path)
    orch.start_pump()
    job = await orch.submit(
        CreateJobRequest(title="掃除", body="一度", source=JobSource.PET, requested_by="hana")
    )
    await asyncio_settle()
    assert store.get(job.id).status is JobStatus.DONE

    await orch.follow_up(job.thread_id or 0, "もう一度", requested_by="hana")
    await asyncio_settle()
    await orch.aclose()

    latest = store.get(job.id)
    assert latest.status is JobStatus.DONE
    assert len(worker.jobs) == 2
    follow = store.input_dir(job.id) / "followup-01.txt"
    assert follow.read_text(encoding="utf-8") == "もう一度"
    assert "待ち" in [tag for _, tag in board.tags]


async def test_forum_starter_becomes_a_job(tmp_path: Path) -> None:
    orch, store, _board, _ = _make_room(tmp_path)
    orch.start_pump()
    await handle_incoming(
        orch,
        IncomingMessage(
            author_id="hana",
            content="Forum から頼む",
            is_bot=False,
            thread_id=555,
            thread_name="Forum の題",
            parent_channel_id=42,
            is_thread_starter=True,
            attachments=(("memo.txt", b"hello"),),
        ),
        forum_channel_id=42,
        owner_id="owner",
    )
    await asyncio_settle()
    await orch.aclose()
    job = store.find_by_thread_id(555)
    assert job is not None
    assert job.title == "Forum の題"
    assert job.source is JobSource.FORUM
    assert (store.input_dir(job.id) / "memo.txt").read_bytes() == b"hello"
    assert job.status is JobStatus.DONE


async def test_restore_puts_running_back_on_the_desk(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    job = store.create(CreateJobRequest(title="途中", body="x", source=JobSource.PET, thread_id=9))
    store.set_status(job.id, JobStatus.RUNNING)
    orch, *_ = _make_room(tmp_path)
    restored = orch.restore()
    assert len(restored) == 1
    assert store.get(job.id).status is JobStatus.QUEUED


async def test_restore_wakes_already_queued_jobs(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    bound = BoundForumBoard()
    worker = ScriptedWorker([ProgressEvent(kind=ProgressKind.SUMMARY, text="起きた")])
    orch = RoomOrchestrator(store, FileJobQueue(store), bound, worker)
    job = store.create(CreateJobRequest(title="待ち", body="x", source=JobSource.PET, thread_id=7))
    orch.restore()
    orch.start_pump()
    bound.bind(RecordingBoard())
    await asyncio_settle()
    await orch.aclose()
    assert store.get(job.id).status is JobStatus.DONE
    assert worker.jobs[0].id == job.id


async def test_pump_waits_until_forum_is_bound(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    bound = BoundForumBoard()
    worker = ScriptedWorker([ProgressEvent(kind=ProgressKind.SUMMARY, text="起きた")])
    orch = RoomOrchestrator(store, FileJobQueue(store), bound, worker)
    job = store.create(CreateJobRequest(title="待ち", body="x", source=JobSource.PET, thread_id=7))
    store.set_status(job.id, JobStatus.RUNNING)
    orch.restore()
    orch.start_pump()
    await asyncio.sleep(0.15)
    assert store.get(job.id).status is JobStatus.QUEUED
    assert worker.jobs == []
    assert orch._pump_task is not None
    assert not orch._pump_task.done()

    bound.bind(RecordingBoard())
    await asyncio_settle()
    await orch.aclose()
    assert store.get(job.id).status is JobStatus.DONE
    assert worker.jobs[0].id == job.id


async def test_pump_survives_board_error_and_retries(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    board = BoomOnceBoard()
    worker = ScriptedWorker([ProgressEvent(kind=ProgressKind.SUMMARY, text="やり直し")])
    orch = RoomOrchestrator(store, FileJobQueue(store), board, worker)
    orch.start_pump()
    job = await orch.submit(CreateJobRequest(title="転ぶ", body="x", source=JobSource.PET))
    # ポンプの一息 (0.5s) を待つ
    await asyncio.sleep(0.8)
    await asyncio_settle()
    task = orch._pump_task
    assert task is not None
    assert not task.done()
    await orch.aclose()
    assert store.get(job.id).status is JobStatus.DONE


async def test_follow_up_requeues_even_when_run_failed(tmp_path: Path) -> None:
    released = asyncio.Event()

    async def block(_job: Job) -> None:
        await released.wait()

    worker = ScriptedWorker(
        [ProgressEvent(kind=ProgressKind.SUMMARY, text="途中")],
        on_start=block,
        results=[JobStatus.FAILED, JobStatus.DONE],
    )
    orch, store, _board, _ = _make_room(tmp_path, worker)
    orch.start_pump()
    job = await orch.submit(
        CreateJobRequest(title="続き", body="一度", source=JobSource.PET, requested_by="hana")
    )
    await asyncio_settle()
    assert store.get(job.id).status is JobStatus.RUNNING

    await orch.follow_up(job.thread_id or 0, "もう一度", requested_by="hana")
    assert (store.job_dir(job.id) / REQUEUE_FILENAME).is_file()
    released.set()
    await asyncio_settle()
    await orch.aclose()

    latest = store.get(job.id)
    assert latest.status is JobStatus.DONE
    assert len(worker.jobs) == 2
    assert not (store.job_dir(job.id) / REQUEUE_FILENAME).is_file()


async def test_forum_cancel_denied_speaks(tmp_path: Path) -> None:
    orch, store, board, _ = _make_room(tmp_path)
    job = await orch.submit(
        CreateJobRequest(title="他人", body="x", source=JobSource.PET, requested_by="hana")
    )
    thread_id = job.thread_id or 0
    await handle_incoming(
        orch,
        IncomingMessage(
            author_id="owner",
            content="やめて",
            is_bot=False,
            thread_id=thread_id,
            thread_name="他人",
            parent_channel_id=42,
            is_thread_starter=False,
        ),
        forum_channel_id=42,
        owner_id="owner",
    )
    await orch.aclose()
    assert store.get(job.id).status is JobStatus.QUEUED
    assert board.speech[-1][1] == "あなたには止められないよ"


async def test_cancel_by_requester(tmp_path: Path) -> None:
    orch, store, board, _ = _make_room(tmp_path)
    job = await orch.submit(
        CreateJobRequest(title="やめる", body="x", source=JobSource.PET, requested_by="hana")
    )
    cancelled = await orch.cancel(job.id, by="hana")
    assert cancelled.status is JobStatus.CANCELLED
    assert board.tags[-1][1] == "中断"
    assert store.get(job.id).status is JobStatus.CANCELLED


class BoomOnceBoard(RecordingBoard):
    def __init__(self) -> None:
        super().__init__()
        self._booms = 1

    async def set_tag(self, thread_id: int, status: JobStatus) -> None:
        if status is JobStatus.RUNNING and self._booms > 0:
            self._booms -= 1
            raise RuntimeError("Discord がまだ起きていない")
        await super().set_tag(thread_id, status)


async def asyncio_settle() -> None:
    for _ in range(30):
        await asyncio.sleep(0)
        await asyncio.sleep(0.01)
