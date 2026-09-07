"""handle_incoming の切り分け。

修正依頼（追記）は Bot への返信またはメンションだけ受け付け、通常会話
（相づち・お礼・他人同士の会話）では再実行しない。中止命令は先に判定し、
権限が無ければ断って「追記」にはしない。添付資料は次の実行に渡す。
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from mihari_room.contracts import (
    Job,
    JobSource,
    JobStatus,
    ProgressEvent,
    ProgressKind,
)
from mihari_room.listener import IncomingMessage, handle_incoming, is_thanks_only
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from tests.recording import RecordingBoard, ScriptedWorker

FORUM = 42
THREAD = 555


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


async def _starter(
    orch: RoomOrchestrator,
    content: str = "掃除して",
    *,
    author: str = "hana",
) -> None:
    await handle_incoming(
        orch,
        IncomingMessage(
            author_id=author,
            content=content,
            is_bot=False,
            thread_id=THREAD,
            thread_name="掃除して",
            parent_channel_id=FORUM,
            is_thread_starter=True,
        ),
        forum_channel_id=FORUM,
        owner_id="owner",
    )


async def _speak(
    orch: RoomOrchestrator,
    content: str,
    *,
    author: str = "hana",
    replies_to_bot: bool = False,
    mentions_bot: bool = False,
    attachments: tuple[tuple[str, bytes], ...] = (),
) -> None:
    await handle_incoming(
        orch,
        IncomingMessage(
            author_id=author,
            content=content,
            is_bot=False,
            thread_id=THREAD,
            thread_name="掃除して",
            parent_channel_id=FORUM,
            is_thread_starter=False,
            attachments=attachments,
            replies_to_bot=replies_to_bot,
            mentions_bot=mentions_bot,
        ),
        forum_channel_id=FORUM,
        owner_id="owner",
    )


async def _settle() -> None:
    for _ in range(30):
        await asyncio.sleep(0)
        await asyncio.sleep(0.01)


def _job_from_thread(store: FileJobStore) -> Job:
    job = store.find_by_thread_id(THREAD)
    assert job is not None
    return job


async def _done_job(
    tmp_path: Path,
) -> tuple[RoomOrchestrator, FileJobStore, RecordingBoard, ScriptedWorker]:
    orch, store, board, worker = _make_room(tmp_path)
    orch.start_pump()
    await _starter(orch)
    await _settle()
    assert store.find_by_thread_id(THREAD) is not None
    return orch, store, board, worker


def test_thanks_only_phrases() -> None:
    assert is_thanks_only("ありがとう")
    assert is_thanks_only("ありがとう！")
    assert is_thanks_only("ありがとうございます。")
    assert is_thanks_only("Thank you")
    assert not is_thanks_only("画像を差し替えて")
    assert not is_thanks_only("ありがとう、でも色を直して")


async def test_plain_message_after_done_does_not_rerun(tmp_path: Path) -> None:
    orch, store, _board, worker = await _done_job(tmp_path)
    await _speak(orch, "ありがとう", author="hana")
    await _settle()
    await orch.aclose()

    job = _job_from_thread(store)
    assert job.status is JobStatus.DONE
    # 追記も再実行もされない。
    assert len(worker.jobs) == 1
    followups = list(store.input_dir(job.id).glob("followup-*.txt"))
    assert followups == []


async def test_plain_conversation_does_not_rerun(tmp_path: Path) -> None:
    orch, store, _board, worker = await _done_job(tmp_path)
    # Bot に宛てていない「直して」も通常会話として無視する。
    await _speak(orch, "ここ直して", author="hana")
    await _settle()
    await orch.aclose()

    job = _job_from_thread(store)
    assert job.status is JobStatus.DONE
    assert len(worker.jobs) == 1
    assert list(store.input_dir(job.id).glob("followup-*.txt")) == []


async def test_thanks_reply_to_bot_does_not_rerun(tmp_path: Path) -> None:
    orch, store, _board, worker = await _done_job(tmp_path)
    # Bot への返信でも、お礼だけなら再実行しない。
    await _speak(orch, "ありがとう！", author="hana", replies_to_bot=True)
    await _settle()
    await orch.aclose()

    job = _job_from_thread(store)
    assert job.status is JobStatus.DONE
    assert len(worker.jobs) == 1
    assert list(store.input_dir(job.id).glob("followup-*.txt")) == []


async def test_reply_to_bot_correction_requeues(tmp_path: Path) -> None:
    orch, store, _board, worker = await _done_job(tmp_path)
    await _speak(orch, "色を直して", author="hana", replies_to_bot=True)
    await _settle()
    await orch.aclose()

    job = _job_from_thread(store)
    assert job.status is JobStatus.DONE
    assert len(worker.jobs) == 2
    followup = store.input_dir(job.id) / "followup-01.txt"
    assert followup.read_text(encoding="utf-8") == "色を直して"


async def test_mention_correction_requeues(tmp_path: Path) -> None:
    orch, store, _board, worker = await _done_job(tmp_path)
    await _speak(orch, "@mihari 続きの調査をして", author="hana", mentions_bot=True)
    await _settle()
    await orch.aclose()

    job = _job_from_thread(store)
    assert job.status is JobStatus.DONE
    assert len(worker.jobs) == 2
    followup = store.input_dir(job.id) / "followup-01.txt"
    assert followup.read_text(encoding="utf-8") == "@mihari 続きの調査をして"


async def test_reply_attachments_are_saved_and_acknowledged(tmp_path: Path) -> None:
    orch, store, board, worker = await _done_job(tmp_path)
    await _speak(
        orch,
        "この画像で差し替えて",
        author="hana",
        replies_to_bot=True,
        attachments=(("new.png", b"png-bytes"), ("memo.txt", b"memo")),
    )
    await _settle()
    await orch.aclose()

    job = _job_from_thread(store)
    assert job.status is JobStatus.DONE
    assert len(worker.jobs) == 2
    # 添付は次の実行の資料として input/ に残る。
    assert (store.input_dir(job.id) / "new.png").read_bytes() == b"png-bytes"
    assert (store.input_dir(job.id) / "memo.txt").read_bytes() == b"memo"
    # 受領した資料を返答する。
    ack = [text for _, text in board.speech if text.startswith("資料を受け取ったよ")]
    assert ack and "new.png" in ack[-1] and "memo.txt" in ack[-1]


async def test_unauthorized_cancel_is_refused_not_followed_up(tmp_path: Path) -> None:
    orch, store, board, worker = await _done_job(tmp_path)
    # スレ立て人でも持ち主でもない人の「やめて」は断る。追記扱いにしない。
    await _speak(orch, "やめて", author="taro")
    await _settle()
    await orch.aclose()

    job = _job_from_thread(store)
    assert job.status is JobStatus.DONE
    assert board.speech[-1][1] == "あなたには止められないよ"
    assert len(worker.jobs) == 1
    assert list(store.input_dir(job.id).glob("followup-*.txt")) == []


async def test_new_forum_thread_still_becomes_job(tmp_path: Path) -> None:
    orch, store, _board, worker = await _done_job(tmp_path)
    job = _job_from_thread(store)
    assert job.source is JobSource.FORUM
    assert len(worker.jobs) == 1
    await orch.aclose()
