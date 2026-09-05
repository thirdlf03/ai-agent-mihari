"""FileJobStore hardening: validation, containment, atomicity, graceful recovery."""

from __future__ import annotations

from pathlib import Path

import pytest

from mihari_room.contracts import CreateJobRequest, JobSource, JobStatus
from mihari_room.store.file_store import FileJobStore, JobNotFound


def _req() -> CreateJobRequest:
    return CreateJobRequest(title="t", body="b", source=JobSource.PET)


def test_invalid_job_ids_rejected(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    for evil in ("../escape", "..", "a/b", "", "x" * 65, ".", "has space!", "/abs"):
        with pytest.raises(JobNotFound):
            store.get(evil)
        with pytest.raises(JobNotFound):
            store.set_status(evil, JobStatus.DONE)
        with pytest.raises(JobNotFound):
            store.job_dir(evil)


def test_symlink_job_dir_rejected(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    job = store.create(_req())
    link = tmp_path / "jobs" / "linkjob12"
    try:
        link.symlink_to(job.directory, target_is_directory=True)
    except OSError:
        pytest.skip("symlink not permitted")
    with pytest.raises(JobNotFound):
        store.job_dir("linkjob12")


def test_malformed_meta_does_not_crash_listing(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    good = store.create(_req())
    bad_dir = tmp_path / "jobs" / "badjob000001"
    bad_dir.mkdir(parents=True)
    (bad_dir / "meta.json").write_text("{not json", encoding="utf-8")
    non_dict = tmp_path / "jobs" / "nondict00001"
    non_dict.mkdir(parents=True)
    (non_dict / "meta.json").write_text("[1,2]", encoding="utf-8")
    assert [job.id for job in store.list_queued()] == [good.id]
    with pytest.raises(JobNotFound):
        store.get("badjob000001")
    # Recovery: a fresh store over the same root behaves the same (no crash loop).
    again = FileJobStore(tmp_path)
    assert [job.id for job in again.list_queued()] == [good.id]


def test_meta_writes_are_atomic_without_leftovers(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    job = store.create(_req())
    store.set_status(job.id, JobStatus.RUNNING)
    leftovers = [p for p in (tmp_path / "jobs" / job.id).iterdir() if p.suffix == ".tmp"]
    assert leftovers == []
    assert store.get(job.id).status is JobStatus.RUNNING


def test_root_is_resolved_to_absolute(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    assert store._root.is_absolute()
