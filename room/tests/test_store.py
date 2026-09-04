"""ディスクの JobStore の置き場・meta・再起動のテスト。"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from mihari_room.contracts import CreateJobRequest, JobSource, JobStatus
from mihari_room.store import FileJobStore, JobNotFound


def _request(title: str = "おつかい") -> CreateJobRequest:
    # テスト用の小さな依頼状
    return CreateJobRequest(
        title=title,
        body="今日の分",
        source=JobSource.PET,
        requested_by="hana",
        thread_id=123,
    )


def test_create_makes_dirs_and_meta(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    job = store.create(_request())

    # 置き場の間取り
    assert job.directory == tmp_path / "jobs" / job.id
    assert job.directory.is_dir()
    assert store.job_dir(job.id).is_dir()
    assert store.input_dir(job.id).is_dir()
    assert store.output_dir(job.id).is_dir()

    # 正本の meta.json
    meta_path = job.directory / "meta.json"
    assert meta_path.is_file()
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    assert meta["id"] == job.id
    assert meta["title"] == "おつかい"
    assert meta["status"] == JobStatus.QUEUED.value
    assert "created_at" in meta


def test_meta_roundtrip(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    job = store.create(_request())

    fetched = store.get(job.id)
    assert fetched.id == job.id
    assert fetched.title == "おつかい"
    assert fetched.body == "今日の分"
    assert fetched.status is JobStatus.QUEUED
    assert fetched.source is JobSource.PET
    assert fetched.thread_id == 123
    assert fetched.requested_by == "hana"
    assert fetched.directory == job.directory

    # 書き換えもディスクに残る
    assert store.set_status(job.id, JobStatus.RUNNING).status is JobStatus.RUNNING
    assert store.set_thread_id(job.id, 999).thread_id == 999
    reread = store.get(job.id)
    assert reread.status is JobStatus.RUNNING
    assert reread.thread_id == 999


def test_restore_running_to_queued_after_restart(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    job = store.create(_request())
    store.set_status(job.id, JobStatus.RUNNING)

    # プロセスが落ちたふり: 同じ root で新しい店を開く
    fresh = FileJobStore(tmp_path)
    assert fresh.get(job.id).status is JobStatus.RUNNING

    restored = fresh.restore_running_to_queued()
    assert [j.id for j in restored] == [job.id]
    assert fresh.get(job.id).status is JobStatus.QUEUED

    # もう一度呼んでも何も戻らない
    assert fresh.restore_running_to_queued() == ()


def test_list_queued_is_fifo(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    first = store.create(_request("ひとつめ"))
    second = store.create(_request("ふたつめ"))
    third = store.create(_request("みっつめ"))

    assert [j.id for j in store.list_queued()] == [first.id, second.id, third.id]

    # 作業中は列から抜ける
    store.set_status(second.id, JobStatus.RUNNING)
    assert [j.id for j in store.list_queued()] == [first.id, third.id]


def test_missing_job_raises(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    with pytest.raises(JobNotFound):
        store.get("いない子")
    with pytest.raises(JobNotFound):
        store.set_status("いない子", JobStatus.DONE)
    with pytest.raises(JobNotFound):
        store.set_thread_id("いない子", 1)
    with pytest.raises(JobNotFound):
        store.job_dir("いない子")
    with pytest.raises(JobNotFound):
        store.input_dir("いない子")
    with pytest.raises(JobNotFound):
        store.output_dir("いない子")


def test_empty_root_lists_nothing(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    assert store.list_queued() == ()
    assert store.restore_running_to_queued() == ()


def test_find_by_thread_id(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    job = store.create(_request())
    assert store.find_by_thread_id(123) is not None
    assert store.find_by_thread_id(123).id == job.id
    assert store.find_by_thread_id(999) is None
