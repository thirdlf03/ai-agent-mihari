"""仕事一覧（履歴込み）と添付アップロードの HTTP。既存 JSON 依頼との互換を確かめる。"""

from __future__ import annotations

import base64
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from mihari_room.app import (
    MAX_ATTACHMENT_BYTES,
    MAX_ATTACHMENT_COUNT,
    create_app,
)
from mihari_room.config import TOKEN_HEADER, RoomConfig
from mihari_room.contracts import CreateJobRequest, JobSource, JobStatus
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
):
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    w = worker or ScriptedWorker([])
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id="owner"), board, w)
    config = RoomConfig(token=TOKEN, root=tmp_path, owner_id="owner")
    app = create_app(config, orch, start_pump=start_pump)
    return TestClient(app), orch, store, board


def _auth() -> dict[str, str]:
    return {TOKEN_HEADER: TOKEN}


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


# --- 既存 JSON 依頼との互換 ------------------------------------------------


def test_json_create_without_attachments_still_works(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    response = client.post(
        "/jobs", json={"title": "掃除", "body": "頼む", "source": "pet"}, headers=_auth()
    )
    assert response.status_code == 200
    body = response.json()
    assert body["job_id"]
    assert body["status"] == "queued"


# --- 添付のアップロード -----------------------------------------------------


def test_create_with_attachments_saves_into_input_dir(tmp_path: Path) -> None:
    client, _, store, _ = _make_app(tmp_path)
    response = client.post(
        "/jobs",
        json={
            "title": "図を見て",
            "body": "この図を参考にして",
            "source": "pet",
            "attachments": [
                {"name": "図.png", "content_base64": _b64(b"\x89PNG-fake")},
                {"name": "手順.md", "content_base64": _b64("# 手順".encode())},
            ],
        },
        headers=_auth(),
    )
    assert response.status_code == 200
    job_id = response.json()["job_id"]

    input_dir = store.input_dir(job_id)
    assert (input_dir / "図.png").read_bytes() == b"\x89PNG-fake"
    assert (input_dir / "手順.md").read_text(encoding="utf-8") == "# 手順"
    # request.md も置かれる。
    assert (input_dir / "request.md").is_file()


def test_attachment_named_request_md_does_not_overwrite_body(tmp_path: Path) -> None:
    client, _, store, _ = _make_app(tmp_path)
    response = client.post(
        "/jobs",
        json={
            "title": "掃除",
            "body": "本文は残して",
            "source": "pet",
            "attachments": [{"name": "request.md", "content_base64": _b64(b"# fake")}],
        },
        headers=_auth(),
    )
    assert response.status_code == 200
    job_id = response.json()["job_id"]
    input_dir = store.input_dir(job_id)
    assert "本文は残して" in input_dir.joinpath("request.md").read_text(encoding="utf-8")
    assert (input_dir / "attached-request.md").read_bytes() == b"# fake"


def test_attachment_rejects_unsupported_extension(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    response = client.post(
        "/jobs",
        json={
            "title": "x",
            "body": "x",
            "source": "pet",
            "attachments": [{"name": "悪意.exe", "content_base64": _b64(b"MZ")}],
        },
        headers=_auth(),
    )
    assert response.status_code == 400
    assert "形式" in response.json()["detail"]


def test_attachment_rejects_count_over_limit(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    attachments = [
        {"name": f"{i}.png", "content_base64": _b64(b"x")} for i in range(MAX_ATTACHMENT_COUNT + 1)
    ]
    response = client.post(
        "/jobs",
        json={"title": "x", "body": "x", "source": "pet", "attachments": attachments},
        headers=_auth(),
    )
    assert response.status_code == 400
    assert "個まで" in response.json()["detail"]


def test_attachment_rejects_oversized_single_file(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    response = client.post(
        "/jobs",
        json={
            "title": "x",
            "body": "x",
            "source": "pet",
            "attachments": [
                {"name": "big.png", "content_base64": _b64(b"\x00" * (MAX_ATTACHMENT_BYTES + 1))}
            ],
        },
        headers=_auth(),
    )
    assert response.status_code == 400
    assert "20MB" in response.json()["detail"]


def test_attachment_rejects_total_over_limit(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    # 各 6MB を 10 個（合計 60MB）で 20MB の 1 件上限は越えずに合計 50MB だけ超える。
    per = 6 * 1024 * 1024
    response = client.post(
        "/jobs",
        json={
            "title": "x",
            "body": "x",
            "source": "pet",
            "attachments": [
                {"name": f"a{i}.png", "content_base64": _b64(b"\x00" * per)} for i in range(10)
            ],
        },
        headers=_auth(),
    )
    assert response.status_code == 400
    assert "50MB" in response.json()["detail"]


def test_attachment_rejects_corrupt_base64(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    response = client.post(
        "/jobs",
        json={
            "title": "x",
            "body": "x",
            "source": "pet",
            "attachments": [{"name": "a.png", "content_base64": "!!!not-base64!!!"}],
        },
        headers=_auth(),
    )
    assert response.status_code == 400


def test_attachment_requires_auth(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    response = client.post(
        "/jobs",
        json={
            "title": "x",
            "body": "x",
            "source": "pet",
            "attachments": [{"name": "a.png", "content_base64": _b64(b"x")}],
        },
    )
    assert response.status_code == 401


# --- 履歴込みの仕事一覧 -----------------------------------------------------


def _create_discord_job(orch: RoomOrchestrator, title: str, body: str) -> str:
    request = CreateJobRequest(title=title, body=body, source=JobSource.FORUM, thread_id=999)
    job = orch.store.create(request)
    return job.id


def test_list_all_includes_all_sources_newest_first(tmp_path: Path) -> None:
    client, orch, store, _ = _make_app(tmp_path)
    pet = client.post(
        "/jobs", json={"title": "ペット", "body": "頼む", "source": "pet"}, headers=_auth()
    ).json()["job_id"]
    discord = _create_discord_job(orch, "Discordから", "これも見える")

    jobs = client.get("/jobs", headers=_auth()).json()["jobs"]
    assert [j["job_id"] for j in jobs] == [discord, pet]
    by_id = {j["job_id"]: j for j in jobs}
    assert by_id[discord]["source"] == "forum"
    assert by_id[discord]["body"] == "これも見える"
    assert by_id[pet]["source"] == "pet"
    # 絶対パスは出さない。
    assert "directory" not in by_id[pet]


def test_list_all_includes_terminal_jobs_after_restart(tmp_path: Path) -> None:
    async def on_start(_job) -> None:
        pass

    worker = ScriptedWorker([], result=JobStatus.DONE, on_start=on_start)
    client, orch, store, _ = _make_app(tmp_path, start_pump=True, worker=worker)
    with client:
        created = client.post(
            "/jobs", json={"title": "完了", "body": "x", "source": "pet"}, headers=_auth()
        ).json()
        job_id = created["job_id"]
        _wait_done(client, job_id, store)

        # 別の root ストア＝再起動のつもり。
        restarted_client, _, _, _ = _make_app(tmp_path)
        jobs = restarted_client.get("/jobs", headers=_auth()).json()["jobs"]
        assert [j["job_id"] for j in jobs] == [job_id]
        assert jobs[0]["status"] == "done"


def test_list_all_requires_auth(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    assert client.get("/jobs").status_code == 401


def test_list_route_does_not_capture_job_detail(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    assert client.get("/jobs", headers=_auth()).status_code == 200
    assert client.get("/jobs/running", headers=_auth()).status_code == 200
    assert client.get("/jobs/nope", headers=_auth()).status_code == 404


# --- capabilities -----------------------------------------------------------


def test_capabilities_reports_supported_features(tmp_path: Path) -> None:
    client, _, _, _ = _make_app(tmp_path)
    body = client.get("/capabilities", headers=_auth()).json()
    assert body["attachment_upload"] is True
    assert body["job_list"] is True
    assert body["job_history"] is True
    assert client.get("/capabilities").status_code == 401


# --- ヘルパー ---------------------------------------------------------------


def _wait_done(client: TestClient, job_id: str, store: FileJobStore) -> None:
    import time

    for _ in range(50):
        if store.get(job_id).status in (JobStatus.DONE, JobStatus.FAILED, JobStatus.CANCELLED):
            return
        time.sleep(0.01)
    raise AssertionError("仕事が終わらなかった")
