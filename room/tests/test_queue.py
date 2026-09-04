"""一人机のキューの順番・取り消し・再起動のテスト。"""

from __future__ import annotations

from pathlib import Path

import pytest

from mihari_room.contracts import CreateJobRequest, JobSource, JobStatus
from mihari_room.queue import CancelNotAllowed, FileJobQueue
from mihari_room.store import FileJobStore


def _request(title: str, by: str = "hana") -> CreateJobRequest:
    # テスト用の小さな依頼状
    return CreateJobRequest(title=title, body="本文", source=JobSource.FORUM, requested_by=by)


def _store_and_queue(
    root: Path, *, owner_id: str | None = None
) -> tuple[FileJobStore, FileJobQueue]:
    store = FileJobStore(root)
    return store, FileJobQueue(store, owner_id=owner_id)


def test_fifo_dequeue(tmp_path: Path) -> None:
    store, queue = _store_and_queue(tmp_path)
    first = store.create(_request("ひとつめ"))
    second = store.create(_request("ふたつめ"))

    taken = queue.dequeue()
    assert taken is not None
    assert taken.id == first.id
    assert taken.status is JobStatus.RUNNING
    assert queue.running() is not None
    assert queue.running().id == first.id

    # 机が埋まっている間は次の子は取れない
    assert queue.dequeue() is None

    # 片づけたら次の子が取れる
    store.set_status(first.id, JobStatus.DONE)
    taken = queue.dequeue()
    assert taken is not None
    assert taken.id == second.id
    assert taken.status is JobStatus.RUNNING
    assert store.get(second.id).id == second.id


def test_cannot_dequeue_while_running_after_restart(tmp_path: Path) -> None:
    store, queue = _store_and_queue(tmp_path)
    job = store.create(_request("作業中"))
    assert queue.dequeue() is not None

    # 再起動のふり: 同じ root で新しい店と机を開く
    fresh_store = FileJobStore(tmp_path)
    fresh_queue = FileJobQueue(fresh_store)
    assert fresh_queue.running() is not None
    assert fresh_queue.running().id == job.id
    assert fresh_queue.dequeue() is None


def test_queue_order_survives_restart(tmp_path: Path) -> None:
    store, _ = _store_and_queue(tmp_path)
    first = store.create(_request("ひとつめ"))
    second = store.create(_request("ふたつめ"))

    # 再起動後に机を開いても順番はそのまま
    fresh_queue = FileJobQueue(FileJobStore(tmp_path))
    assert fresh_queue.dequeue() is not None
    assert fresh_queue.dequeue() is None  # 机が埋まっている
    assert fresh_queue.running().id == first.id
    assert second.id != first.id


def test_dequeue_empty_returns_none(tmp_path: Path) -> None:
    _, queue = _store_and_queue(tmp_path)
    assert queue.dequeue() is None
    assert queue.running() is None


def test_enqueue_sets_queued(tmp_path: Path) -> None:
    store, queue = _store_and_queue(tmp_path)
    job = store.create(_request("やり直し"))
    store.set_status(job.id, JobStatus.FAILED)

    # もう queued ではない子は列に戻す
    queue.enqueue(store.get(job.id))
    assert store.get(job.id).status is JobStatus.QUEUED

    # すでに queued なら触らない (壊さない)
    queue.enqueue(store.get(job.id))
    assert store.get(job.id).status is JobStatus.QUEUED
    assert [j.id for j in store.list_queued()] == [job.id]


def test_cancel_by_requester(tmp_path: Path) -> None:
    store, queue = _store_and_queue(tmp_path)
    job = store.create(_request("やめた", by="hana"))

    cancelled = queue.cancel(job.id, by="hana")
    assert cancelled.status is JobStatus.CANCELLED
    assert store.get(job.id).status is JobStatus.CANCELLED
    assert store.list_queued() == ()


def test_cancel_by_owner(tmp_path: Path) -> None:
    store, queue = _store_and_queue(tmp_path, owner_id="owner-sama")
    job = store.create(_request("持ち主が止める", by="hana"))

    cancelled = queue.cancel(job.id, by="owner-sama")
    assert cancelled.status is JobStatus.CANCELLED


def test_cancel_by_stranger_rejected(tmp_path: Path) -> None:
    store, queue = _store_and_queue(tmp_path, owner_id="owner-sama")
    job = store.create(_request("他人の仕事", by="hana"))

    with pytest.raises(CancelNotAllowed):
        queue.cancel(job.id, by="taro")
    # 列に残ったまま
    assert store.get(job.id).status is JobStatus.QUEUED


def test_cancel_owner_does_not_read_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MIHARI_OWNER_ID", "env-owner")
    store, queue = _store_and_queue(tmp_path)
    job = store.create(_request("env では止められない", by="hana"))

    with pytest.raises(CancelNotAllowed):
        queue.cancel(job.id, by="env-owner")
    assert store.get(job.id).status is JobStatus.QUEUED


def test_cancel_running_frees_the_desk(tmp_path: Path) -> None:
    store, queue = _store_and_queue(tmp_path)
    first = store.create(_request("作業中の中断"))
    second = store.create(_request("次"))
    assert queue.dequeue() is not None

    queue.cancel(first.id, by="hana")
    assert queue.running() is None

    # 机が空いたので次の子が取れる
    taken = queue.dequeue()
    assert taken is not None
    assert taken.id == second.id
