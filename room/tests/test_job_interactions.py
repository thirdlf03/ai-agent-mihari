"""steer / questions / waiting_for_input と session/job ID 分離。"""

from __future__ import annotations

import asyncio
import threading
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from mihari_room.app import create_app
from mihari_room.config import TOKEN_HEADER, RoomConfig
from mihari_room.contracts import (
    CreateJobRequest,
    Job,
    JobSource,
    JobStatus,
    ProgressEvent,
    ProgressKind,
)
from mihari_room.job_interactions import JobInteractionHub, list_steers
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from mihari_room.voice.sessions import VoiceSessionManager
from tests.recording import RecordingBoard

TOKEN = "room-secret"


class InteractiveWorker:
    """質問待ちと steer 受信を再現する worker。"""

    def __init__(
        self,
        *,
        ask: str | None = None,
        choices: list[str] | None = None,
        result: JobStatus = JobStatus.DONE,
        on_start: Callable[[Job], Awaitable[None]] | None = None,
    ) -> None:
        self.ask = ask
        self.choices = choices
        self.result = result
        self._on_start = on_start
        self.jobs: list[Job] = []
        self.steers: list[str] = []
        self._hub: JobInteractionHub | None = None
        self._live: set[str] = set()

    def attach_interactions(self, hub: JobInteractionHub) -> None:
        self._hub = hub

    def deliver_steer(self, job_id: str, text: str) -> bool:
        if job_id not in self._live:
            return False
        self.steers.append(text)
        return True

    def is_running(self, job_id: str) -> bool:
        return job_id in self._live

    async def run(
        self,
        job: Job,
        on_progress: Callable[[ProgressEvent], Awaitable[None]],
    ) -> JobStatus:
        self.jobs.append(job)
        self._live.add(job.id)
        if self._hub is not None:
            self._hub.register_steer_deliverer(job.id, self.deliver_steer)
        try:
            if self._on_start is not None:
                await self._on_start(job)
            if self._hub is not None and self.ask:
                pending = self._hub.register_question(job, self.ask, self.choices)
                await on_progress(
                    ProgressEvent(kind=ProgressKind.LOG, text=f"Q:{self.ask}", phase="waiting")
                )

                async def answer_later() -> None:
                    await asyncio.sleep(0.05)
                    self._hub.answer(job, pending.id, "blue")

                asyncio.create_task(answer_later())
                answer = await asyncio.to_thread(
                    self._hub.wait_for_answer, job.id, pending.id, timeout=5.0
                )
                assert answer == "blue"
                self._hub.cleanup_question(pending.id)
                self._hub.resume_running(job.id)
        finally:
            self._live.discard(job.id)
            if self._hub is not None:
                self._hub.unregister_steer_deliverer(job.id)
        return self.result


def _make_app(
    tmp_path: Path,
    *,
    worker: InteractiveWorker | None = None,
    start_pump: bool = True,
) -> tuple[TestClient, RoomOrchestrator, FileJobStore, InteractiveWorker]:
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    w = worker or InteractiveWorker()
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id="owner"), board, w)
    config = RoomConfig(token=TOKEN, root=tmp_path, owner_id="owner")
    app = create_app(config, orch, start_pump=start_pump)
    return TestClient(app), orch, store, w


def _auth() -> dict[str, str]:
    return {TOKEN_HEADER: TOKEN}


def test_steer_adds_instruction_to_running_job(tmp_path: Path) -> None:
    released = threading.Event()

    async def block(_job: Job) -> None:
        while not released.is_set():
            await asyncio.sleep(0.01)

    worker = InteractiveWorker(on_start=block)
    client, _, store, w = _make_app(tmp_path, worker=worker)
    with client:
        created = client.post(
            "/jobs", json={"title": "走る", "body": "x", "source": "pet"}, headers=_auth()
        ).json()
        job_id = created["job_id"]
        for _ in range(50):
            if store.get(job_id).status is JobStatus.RUNNING:
                break
            import time

            time.sleep(0.01)
        resp = client.post(
            f"/jobs/{job_id}/steer",
            json={"text": "左側を優先して"},
            headers=_auth(),
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["text"] == "左側を優先して"
        assert body["delivered"] is True
        assert w.steers == ["左側を優先して"]
        assert list_steers(store.job_dir(job_id))
        released.set()


def test_steer_allowed_during_waiting_for_input(tmp_path: Path) -> None:
    gate = asyncio.Event()

    async def hold(_job: Job) -> None:
        await gate.wait()

    worker = InteractiveWorker(on_start=hold)
    client, _, store, w = _make_app(tmp_path, worker=worker)
    hub: JobInteractionHub = client.app.state.job_interactions  # type: ignore[attr-defined]
    with client:
        created = client.post(
            "/jobs", json={"title": "入力待ち", "body": "x", "source": "pet"}, headers=_auth()
        ).json()
        job_id = created["job_id"]
        for _ in range(50):
            if store.get(job_id).status is JobStatus.RUNNING:
                break
            import time

            time.sleep(0.01)
        job = store.get(job_id)
        hub.register_question(job, "色は？", ["red", "blue"])
        assert store.get(job_id).status is JobStatus.WAITING_FOR_INPUT
        resp = client.post(
            f"/jobs/{job_id}/steer",
            json={"text": "左側を優先して"},
            headers=_auth(),
        )
        assert resp.status_code == 200
        assert resp.json()["delivered"] is True
        assert w.steers == ["左側を優先して"]
        gate.set()


def test_jobs_running_includes_waiting_for_input(tmp_path: Path) -> None:
    gate = asyncio.Event()

    async def hold(_job: Job) -> None:
        await gate.wait()

    worker = InteractiveWorker(on_start=hold)
    client, _, store, _ = _make_app(tmp_path, worker=worker)
    hub: JobInteractionHub = client.app.state.job_interactions  # type: ignore[attr-defined]
    with client:
        created = client.post(
            "/jobs", json={"title": "机占有", "body": "x", "source": "pet"}, headers=_auth()
        ).json()
        job_id = created["job_id"]
        for _ in range(50):
            if store.get(job_id).status is JobStatus.RUNNING:
                break
            import time

            time.sleep(0.01)
        hub.register_question(store.get(job_id), "待て", None)
        assert store.get(job_id).status is JobStatus.WAITING_FOR_INPUT
        running = client.get("/jobs/running", headers=_auth()).json()["jobs"]
        assert [j["job_id"] for j in running] == [job_id]
        assert running[0]["status"] == "waiting_for_input"
        gate.set()


def test_steer_rejected_when_not_running(tmp_path: Path) -> None:
    client, _, store, _ = _make_app(tmp_path, start_pump=False)
    created = client.post(
        "/jobs", json={"title": "待ち", "body": "x", "source": "pet"}, headers=_auth()
    ).json()
    job_id = created["job_id"]
    assert store.get(job_id).status is JobStatus.QUEUED
    resp = client.post(
        f"/jobs/{job_id}/steer",
        json={"text": "早く"},
        headers=_auth(),
    )
    assert resp.status_code == 409


def test_question_answer_waiting_for_input_state_machine(tmp_path: Path) -> None:
    worker = InteractiveWorker(ask="色は？", choices=["red", "blue"])
    client, _, store, _ = _make_app(tmp_path, worker=worker)
    with client:
        created = client.post(
            "/jobs", json={"title": "質問", "body": "x", "source": "pet"}, headers=_auth()
        ).json()
        job_id = created["job_id"]
        seen_waiting = False
        for _ in range(100):
            status = store.get(job_id).status
            if status is JobStatus.WAITING_FOR_INPUT:
                seen_waiting = True
                detail = client.get(f"/jobs/{job_id}", headers=_auth()).json()
                assert detail["status"] == "waiting_for_input"
                assert len(detail["pending_questions"]) == 1
                assert detail["pending_questions"][0]["question"] == "色は？"
                break
            import time

            time.sleep(0.02)
        assert seen_waiting
        for _ in range(100):
            if store.get(job_id).status is JobStatus.DONE:
                break
            import time

            time.sleep(0.02)
        assert store.get(job_id).status is JobStatus.DONE
        questions = client.get(f"/jobs/{job_id}/questions", headers=_auth()).json()["questions"]
        assert questions[0]["status"] == "answered"
        assert questions[0]["answer"] == "blue"


def test_answer_endpoint_transitions_back_to_running(tmp_path: Path) -> None:
    gate = asyncio.Event()

    async def hold(_job: Job) -> None:
        await gate.wait()

    worker = InteractiveWorker(on_start=hold)
    client, _, store, _ = _make_app(tmp_path, worker=worker)
    hub: JobInteractionHub = client.app.state.job_interactions  # type: ignore[attr-defined]
    with client:
        created = client.post(
            "/jobs", json={"title": "手動", "body": "x", "source": "pet"}, headers=_auth()
        ).json()
        job_id = created["job_id"]
        for _ in range(50):
            if store.get(job_id).status is JobStatus.RUNNING:
                break
            import time

            time.sleep(0.01)
        job = store.get(job_id)
        pending = hub.register_question(job, "続ける？", None)
        assert store.get(job_id).status is JobStatus.WAITING_FOR_INPUT
        resp = client.post(
            f"/jobs/{job_id}/questions/{pending.id}/answer",
            json={"answer": "はい"},
            headers=_auth(),
        )
        assert resp.status_code == 200
        assert resp.json()["question"]["answer"] == "はい"
        assert store.get(job_id).status is JobStatus.RUNNING
        gate.set()


def test_voice_session_id_separate_from_job_id(tmp_path: Path) -> None:
    client, _, store, _ = _make_app(tmp_path, start_pump=False)
    config = RoomConfig(token=TOKEN, root=tmp_path, owner_id="owner", openai_api_key="sk-test")
    voice = VoiceSessionManager(config)
    session = voice.create_session()
    job = store.create(CreateJobRequest(title="別物", body="b", source=JobSource.PET))
    assert session.id != job.id
    detail = client.get(f"/jobs/{job.id}", headers=_auth()).json()
    assert detail["job_id"] == job.id
    assert detail.get("session_id") in (None, "")
    meta = voice.get(session.id)
    assert meta.id == session.id
    assert meta.id != job.id


def test_waiting_for_input_blocks_queue(tmp_path: Path) -> None:
    gate = asyncio.Event()

    async def hold(_job: Job) -> None:
        await gate.wait()

    worker = InteractiveWorker(on_start=hold)
    client, _, store, _ = _make_app(tmp_path, worker=worker)
    hub: JobInteractionHub = client.app.state.job_interactions  # type: ignore[attr-defined]
    with client:
        first = client.post(
            "/jobs", json={"title": "1", "body": "a", "source": "pet"}, headers=_auth()
        ).json()["job_id"]
        for _ in range(50):
            if store.get(first).status is JobStatus.RUNNING:
                break
            import time

            time.sleep(0.01)
        job = store.get(first)
        hub.register_question(job, "待て", None)
        assert store.get(first).status is JobStatus.WAITING_FOR_INPUT
        second = client.post(
            "/jobs", json={"title": "2", "body": "b", "source": "pet"}, headers=_auth()
        ).json()["job_id"]
        import time

        time.sleep(0.05)
        assert store.get(second).status is JobStatus.QUEUED
        gate.set()


def test_restore_moves_waiting_for_input_to_queued(tmp_path: Path) -> None:
    store = FileJobStore(tmp_path)
    job = store.create(CreateJobRequest(title="t", body="", source=JobSource.PET))
    store.set_status(job.id, JobStatus.WAITING_FOR_INPUT)
    restored = store.restore_running_to_queued()
    assert len(restored) == 1
    assert store.get(job.id).status is JobStatus.QUEUED
