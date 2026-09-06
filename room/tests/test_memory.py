"""MemoryCandidateStore: approval / rejection / restart / path attacks."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from mihari_room.contracts import CreateJobRequest, Job, JobSource
from mihari_room.fakes import InMemoryJobStore
from mihari_room.worker.memory import MemoryCandidateStore


def _make_job(tmp_path: Path) -> Job:
    store = InMemoryJobStore(tmp_path)
    return store.create(CreateJobRequest(title="t", body="b", source=JobSource.PET))


def _store_for(tmp_path: Path, home: Path | None = None) -> MemoryCandidateStore:
    return MemoryCandidateStore(tmp_path, home or (tmp_path / "hermes-home"))


def test_propose_list_approve_persists(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    store = _store_for(tmp_path)
    candidate = store.propose(job.id, "memory", "project uses uv")
    assert candidate.status == "pending"
    assert candidate.target == "MEMORY.md"
    assert store.list(job.id)[0].id == candidate.id
    approved = store.approve(job.id, candidate.id)
    assert approved.status == "approved"
    # Approved text lands in the stable home profile.
    mem = (store.hermes_home / "memories" / "MEMORY.md").read_text(encoding="utf-8")
    assert "project uses uv" in mem
    # Idempotent second approve: no duplicate.
    store.approve(job.id, candidate.id)
    mem2 = (store.hermes_home / "memories" / "MEMORY.md").read_text(encoding="utf-8")
    assert mem2.count("project uses uv") == 1


def test_reject_never_writes_home(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    store = _store_for(tmp_path)
    candidate = store.propose(job.id, "user", "user likes short replies")
    rejected = store.reject(job.id, candidate.id)
    assert rejected.status == "rejected"
    assert not (store.hermes_home / "memories" / "USER.md").exists()
    # Idempotent second reject.
    assert store.reject(job.id, candidate.id).status == "rejected"


def test_approve_after_reject_fails_and_vice_versa(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    store = _store_for(tmp_path)
    candidate = store.propose(job.id, "memory", "durable fact")
    store.reject(job.id, candidate.id)
    with pytest.raises(ValueError):
        store.approve(job.id, candidate.id)
    candidate2 = store.propose(job.id, "memory", "another fact")
    store.approve(job.id, candidate2.id)
    with pytest.raises(ValueError):
        store.reject(job.id, candidate2.id)


def test_restart_keeps_candidates(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    store = _store_for(tmp_path)
    candidate = store.propose(job.id, "memory", "restart me")
    # New instance against the same root sees the same durable file.
    again = _store_for(tmp_path)
    assert [c.id for c in again.list(job.id)] == [candidate.id]
    again.approve(job.id, candidate.id)
    assert again.list(job.id)[0].status == "approved"


def test_unknown_job_rejected(tmp_path: Path) -> None:
    store = _store_for(tmp_path)
    with pytest.raises(ValueError):
        store.list("nope-not-a-job")
    with pytest.raises(ValueError):
        store.propose("nope-not-a-job", "memory", "x")


def test_job_id_path_traversal_rejected(tmp_path: Path) -> None:
    _make_job(tmp_path)
    store = _store_for(tmp_path)
    for evil in ("../escape", "..", "a/b", "", "x" * 65, "."):
        with pytest.raises(ValueError):
            store.list(evil)


def test_symlink_job_rejected(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    link = tmp_path / "jobs" / "linkjob"
    try:
        link.symlink_to(job.directory, target_is_directory=True)
    except OSError:
        pytest.skip("symlink not permitted")
    store = _store_for(tmp_path)
    with pytest.raises(ValueError):
        store.list("linkjob")


def test_policy_rejects_large_raw_pdf_inferred(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    store = _store_for(tmp_path)
    with pytest.raises(ValueError, match="too large"):
        store.propose(job.id, "memory", "x" * 2001)
    with pytest.raises(ValueError, match="raw log"):
        store.propose(job.id, "memory", "Traceback (most recent call last):\n boom")
    with pytest.raises(ValueError, match="raw log"):
        store.propose(job.id, "memory", "\n".join(f"line {i}" for i in range(25)))
    with pytest.raises(ValueError, match="PDF"):
        store.propose(job.id, "memory", "%PDF-1.4 binary dump here")
    with pytest.raises(ValueError, match="inferred fact"):
        store.propose(job.id, "user", "user probably likes late-night ramen")


def test_target_aliases_and_validation(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    store = _store_for(tmp_path)
    assert store.propose(job.id, "MEMORY.md", "aliased").target == "MEMORY.md"
    assert store.propose(job.id, "user", "u1").target == "USER.md"
    with pytest.raises(ValueError):
        store.propose(job.id, "soul", "nope")


def test_candidates_file_is_json_list(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    store = _store_for(tmp_path)
    store.propose(job.id, "memory", "json check")
    raw = json.loads((job.directory / "memory_candidates.json").read_text(encoding="utf-8"))
    assert isinstance(raw, list) and raw[0]["status"] == "pending"
