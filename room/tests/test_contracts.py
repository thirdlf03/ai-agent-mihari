"""契約のタグ対応と、仮の JobStore が Protocol を満たすこと。"""

from __future__ import annotations

from pathlib import Path

from mihari_room.contracts import CreateJobRequest, JobSource, JobStatus
from mihari_room.fakes import InMemoryJobStore


def test_status_tags_match_the_spec() -> None:
    assert JobStatus.QUEUED.discord_tag() == "待ち"
    assert JobStatus.RUNNING.discord_tag() == "作業中"
    assert JobStatus.DONE.discord_tag() == "完了"
    assert JobStatus.FAILED.discord_tag() == "失敗"
    assert JobStatus.CANCELLED.discord_tag() == "中断"


def test_in_memory_store_creates_job_dirs(tmp_path: Path) -> None:
    store = InMemoryJobStore(tmp_path)
    job = store.create(
        CreateJobRequest(title="ログをまとめて", body="今日の分", source=JobSource.PET)
    )
    assert job.status is JobStatus.QUEUED
    assert store.input_dir(job.id).is_dir()
    assert store.output_dir(job.id).is_dir()
    assert store.get(job.id).id == job.id


def test_restore_moves_running_back_to_queued(tmp_path: Path) -> None:
    store = InMemoryJobStore(tmp_path)
    job = store.create(CreateJobRequest(title="途中", body="", source=JobSource.FORUM))
    store.set_status(job.id, JobStatus.RUNNING)
    restored = store.restore_running_to_queued()
    assert len(restored) == 1
    assert store.get(job.id).status is JobStatus.QUEUED
    assert store.list_queued()[0].id == job.id


def test_in_memory_store_finds_by_thread_and_running(tmp_path: Path) -> None:
    store = InMemoryJobStore(tmp_path)
    job = store.create(
        CreateJobRequest(title="スレ", body="", source=JobSource.FORUM, thread_id=42)
    )
    assert store.find_by_thread_id(42) is not None
    assert store.find_by_thread_id(42).id == job.id
    assert store.find_by_thread_id(99) is None
    store.set_status(job.id, JobStatus.RUNNING)
    running = store.list_running()
    assert len(running) == 1
    assert running[0].id == job.id
