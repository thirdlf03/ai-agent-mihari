"""HTTP API（詳細・SSE・プレビュー）とイベント生成器。"""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from mihari_room.app import _job_events_stream, create_app, parse_last_event_id
from mihari_room.config import TOKEN_HEADER, RoomConfig
from mihari_room.contracts import Job, JobStatus, ProgressEvent, ProgressKind
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from tests.recording import RecordingBoard, ScriptedWorker

TOKEN = "room-secret"


def _make_app(
    tmp_path: Path,
    *,
    start_pump: bool = False,
    worker: Any = None,
    preview_base: str = "",
    owner_id: str = "owner",
):
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    w = worker or ScriptedWorker([ProgressEvent(kind=ProgressKind.SUMMARY, text="やった")])
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id=owner_id), board, w)
    config = RoomConfig(
        token=TOKEN, root=tmp_path, owner_id=owner_id, preview_base_url=preview_base
    )
    app = create_app(config, orch, start_pump=start_pump)
    return TestClient(app), orch, store, board


def _auth() -> dict[str, str]:
    return {TOKEN_HEADER: TOKEN}


# --- ルートの順序と認証 -----------------------------------------------------


def test_running_route_is_not_captured_by_job_detail(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    assert client.get("/jobs/running", headers=_auth()).status_code == 200
    body = client.get("/jobs/running", headers=_auth()).json()
    assert body == {"jobs": []}
    assert client.get("/jobs/running").status_code == 401
    assert client.get("/jobs/nope", headers=_auth()).status_code == 404


def test_running_lists_running_jobs(tmp_path: Path) -> None:
    released = asyncio.Event()

    async def block(_job: Job) -> None:
        await released.wait()

    worker = ScriptedWorker(
        [ProgressEvent(kind=ProgressKind.SUMMARY, text="やった")], on_start=block
    )
    client, orch, store, _ = _make_app(tmp_path, start_pump=True, worker=worker)
    with client:
        created = client.post(
            "/jobs", json={"title": "走る", "body": "x", "source": "pet"}, headers=_auth()
        ).json()
        job_id = created["job_id"]
        for _ in range(30):
            if store.get(job_id).status is JobStatus.RUNNING:
                break
            import time

            time.sleep(0.01)
        running = client.get("/jobs/running", headers=_auth()).json()["jobs"]
        assert [j["job_id"] for j in running] == [job_id]
        released.set()


# --- 仕事の詳細 --------------------------------------------------------------


def test_job_detail_shape_and_404(tmp_path: Path) -> None:
    client, orch, store, _ = _make_app(tmp_path)
    created = client.post(
        "/jobs", json={"title": "掃除", "body": "頼む", "source": "pet"}, headers=_auth()
    ).json()
    job_id = created["job_id"]

    detail = client.get(f"/jobs/{job_id}", headers=_auth()).json()
    assert detail["job_id"] == job_id
    assert detail["title"] == "掃除"
    assert detail["status"] == "queued"
    assert detail["session_id"] is None
    assert detail["artifacts"] == []
    assert detail["latest_event"] is not None
    assert detail["latest_event"]["job_id"] == job_id
    # 絶対パスは出さない。
    assert "directory" not in detail
    assert "root" not in detail

    assert client.get("/jobs/does-not-exist", headers=_auth()).status_code == 404
    assert client.get(f"/jobs/{job_id}").status_code == 401


# --- 続き（followup） --------------------------------------------------------


def test_followup_reuses_same_job(tmp_path: Path) -> None:
    client, orch, store, _ = _make_app(tmp_path)
    created = client.post(
        "/jobs", json={"title": "掃除", "body": "頼む", "source": "pet"}, headers=_auth()
    ).json()
    job_id = created["job_id"]

    response = client.post(
        f"/jobs/{job_id}/followup",
        json={"body": "もっと丁寧に", "requested_by": "hana"},
        headers=_auth(),
    )
    assert response.status_code == 200
    body = response.json()
    assert body["job_id"] == job_id
    assert body["thread_id"] == created["thread_id"]
    assert body["status"] == "queued"

    follow = store.input_dir(job_id) / "followup-01.txt"
    assert follow.read_text(encoding="utf-8") == "もっと丁寧に"

    assert (
        client.post(f"/jobs/{job_id}/followup", json={"body": "  "}, headers=_auth()).status_code
        == 400
    )
    assert (
        client.post(f"/jobs/{job_id}/followup", json={"body": "x"}, headers=_auth()).status_code
        == 200
    )
    nojob = client.post("/jobs/nope/followup", json={"body": "x"}, headers=_auth())
    assert nojob.status_code == 404


# --- イベントの SSE ----------------------------------------------------------


def test_sse_requires_token_and_404(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    assert client.get("/jobs/whatever/events").status_code == 401
    got = client.get("/jobs/whatever/events", headers=_auth())
    assert got.status_code == 404


def test_sse_replays_completed_job_and_closes(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr("mihari_room.app.POLL_INTERVAL_SEC", 0.001)
    monkeypatch.setattr("mihari_room.app.TERMINAL_HOLD_SEC", 0.001)
    monkeypatch.setattr("mihari_room.app.HEARTBEAT_INTERVAL_SEC", 60.0)
    client, orch, store, _ = _make_app(tmp_path, start_pump=True)
    with client:
        created = client.post(
            "/jobs", json={"title": "完了", "body": "x", "source": "pet"}, headers=_auth()
        ).json()
        job_id = created["job_id"]
        _wait_done(client, job_id, store)

        frames = _read_sse(client, f"/jobs/{job_id}/events", _auth())
        assert frames
        # 全イベントが流れる。
        phases = {f.get("phase") for f in frames}
        assert "queued" in phases
        assert "done" in phases
        # 完了した仕事は stream が閉じる（読めた = 吊り下がらない）。
        more = _read_sse(client, f"/jobs/{job_id}/events", _auth())
        assert more == frames


def test_sse_replays_from_last_event_id(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr("mihari_room.app.POLL_INTERVAL_SEC", 0.001)
    monkeypatch.setattr("mihari_room.app.TERMINAL_HOLD_SEC", 0.001)
    monkeypatch.setattr("mihari_room.app.HEARTBEAT_INTERVAL_SEC", 60.0)
    client, orch, store, _ = _make_app(tmp_path, start_pump=True)
    with client:
        created = client.post(
            "/jobs", json={"title": "完了", "body": "x", "source": "pet"}, headers=_auth()
        ).json()
        job_id = created["job_id"]
        _wait_done(client, job_id, store)

        all_frames = _read_sse(client, f"/jobs/{job_id}/events", _auth())
        last_id = all_frames[-1]["id"]
        replayed = _read_sse(
            client,
            f"/jobs/{job_id}/events",
            {**_auth(), "Last-Event-ID": str(last_id)},
        )
        # last_id より新しいイベントは無いので空。
        assert replayed == []

        # 途中からリプレイすると id の大きい側だけ来る。
        partial = _read_sse(
            client,
            f"/jobs/{job_id}/events",
            {**_auth(), "Last-Event-ID": str(all_frames[0]["id"])},
        )
        assert partial and partial[0]["id"] > all_frames[0]["id"]


def test_sse_unknown_last_event_id_replays_all(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr("mihari_room.app.POLL_INTERVAL_SEC", 0.001)
    monkeypatch.setattr("mihari_room.app.TERMINAL_HOLD_SEC", 0.001)
    monkeypatch.setattr("mihari_room.app.HEARTBEAT_INTERVAL_SEC", 60.0)
    client, orch, store, _ = _make_app(tmp_path, start_pump=True)
    with client:
        created = client.post(
            "/jobs", json={"title": "完了", "body": "x", "source": "pet"}, headers=_auth()
        ).json()
        job_id = created["job_id"]
        _wait_done(client, job_id, store)

        all_frames = _read_sse(client, f"/jobs/{job_id}/events", _auth())
        # 壊れた Last-Event-ID は最初から（取りこぼさない）。
        unknown = _read_sse(
            client,
            f"/jobs/{job_id}/events",
            {**_auth(), "Last-Event-ID": "garbage"},
        )
        assert [f["id"] for f in unknown] == [f["id"] for f in all_frames]


def test_derive_title_falls_back_and_skips_blank_lines() -> None:
    from mihari_room.app import derive_title

    assert derive_title("", "") == "依頼"
    assert derive_title("  ", "\n\n本文の本題\n続き") == "本文の本題"
    assert derive_title("", "あ" * 150) == "あ" * 100


def test_parse_last_event_id() -> None:
    assert parse_last_event_id(None) == 0
    assert parse_last_event_id("") == 0
    assert parse_last_event_id("5") == 5
    assert parse_last_event_id("garbage") == 0
    assert parse_last_event_id("-3") == 0


async def test_sse_generator_heartbeats_and_closes(tmp_path: Path) -> None:
    released = asyncio.Event()

    async def block(_job: Job) -> None:
        await released.wait()

    worker = ScriptedWorker(
        [ProgressEvent(kind=ProgressKind.SUMMARY, text="やった")], on_start=block
    )
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    orch = RoomOrchestrator(store, FileJobQueue(store), board, worker)
    orch.start_pump()
    job = await orch.submit(_req("調査"))
    for _ in range(30):
        if store.get(job.id).status is JobStatus.RUNNING:
            break
        await asyncio.sleep(0.01)

    gen = _job_events_stream(orch, job.id, 0, poll=0.001, heartbeat=0.01, hold=0.01)

    async def _next() -> str:
        return await asyncio.wait_for(anext(gen), timeout=1.0)

    seen_heartbeat = False
    try:
        for _ in range(200):
            frame = await _next()
            if frame == ": hb\n\n":
                seen_heartbeat = True
                break
    except (TimeoutError, StopAsyncIteration):
        pass
    assert seen_heartbeat

    released.set()
    frames: list[str] = []
    try:
        while True:
            frames.append(await _next())
    except (TimeoutError, StopAsyncIteration):
        pass
    assert any("done" in frame for frame in frames)
    await orch.aclose()


def _req(title: str):
    from mihari_room.contracts import CreateJobRequest, JobSource

    return CreateJobRequest(title=title, body="x", source=JobSource.PET)


# --- プレビュー --------------------------------------------------------------


def test_publish_and_serve_preview_end_to_end(tmp_path: Path) -> None:
    def make_artifact(job: Job) -> None:
        (job.directory / "output" / "artifact").mkdir(parents=True, exist_ok=True)
        (job.directory / "output" / "artifact" / "index.html").write_text(
            "<h1>できた</h1>", encoding="utf-8"
        )
        (job.directory / "output" / "artifact" / "secret.txt").write_text(
            "hunter2", encoding="utf-8"
        )

    async def on_start(job: Job) -> None:
        make_artifact(job)

    worker = ScriptedWorker(
        [ProgressEvent(kind=ProgressKind.SUMMARY, text="やった")], on_start=on_start
    )
    client, orch, store, _ = _make_app(
        tmp_path,
        start_pump=True,
        worker=worker,
        preview_base="https://preview.example.com/previews",
    )
    with client:
        created = client.post(
            "/jobs", json={"title": "プレビュー", "body": "x", "source": "pet"}, headers=_auth()
        ).json()
        job_id = created["job_id"]
        _wait_done(client, job_id, store)

        detail = client.get(f"/jobs/{job_id}", headers=_auth()).json()
        assert len(detail["artifacts"]) == 1
        manifest = detail["artifacts"][0]
        assert manifest["version"] == 1
        assert manifest["preview_url"].startswith("https://preview.example.com/previews/")

        token = manifest["preview_url"].rsplit("/", 2)[-2]
        # 未認証で index が見える。秘密は公開されない。
        resp = client.get(f"/previews/{token}/index.html")
        assert resp.status_code == 200
        assert "できた" in resp.text
        assert resp.headers["X-Content-Type-Options"] == "nosniff"
        assert resp.headers["Referrer-Policy"] == "no-referrer"
        assert "sandbox" in resp.headers["Content-Security-Policy"]
        assert client.get(f"/previews/{token}/secret.txt").status_code == 404
        assert client.get(f"/previews/{token}/").status_code == 200

        # トラバーサル・未知 token は 404。
        assert client.get(f"/previews/{token}/../jobs").status_code == 404
        assert client.get(f"/previews/{token}/..%2Fjobs").status_code == 404
        assert client.get("/previews/nope/index.html").status_code == 404

        # SSE に preview URL の summary が流れる。
        frames = _read_sse(client, f"/jobs/{job_id}/events", _auth())
        assert any("preview.example.com" in f["text"] for f in frames if f["kind"] == "summary")


# --- ヘルパー ----------------------------------------------------------------


def _wait_done(client: TestClient, job_id: str, store: FileJobStore) -> None:
    import time

    for _ in range(50):
        if store.get(job_id).status in (JobStatus.DONE, JobStatus.FAILED, JobStatus.CANCELLED):
            return
        time.sleep(0.01)
    raise AssertionError("仕事が終わらなかった")


def _read_sse(client: TestClient, url: str, headers: dict[str, str]) -> list[dict]:
    """SSE を最後まで読み、data 行を JSON に戻す。"""
    events: list[dict] = []
    with client.stream("GET", url, headers=headers) as response:
        assert response.status_code == 200
        for line in response.iter_lines():
            if line.startswith("data: "):
                import json

                events.append(json.loads(line[6:]))
    return events
