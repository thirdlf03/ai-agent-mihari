"""#22: Mac スクショを Hermes の画像コンテキストへ渡す。

- 認証付き JSON 依頼の `screenshots` が input/screenshots/ に保存され、
  詳細 API がメタデータ（Retina scale・座標）を返す（パスは出さない）。
- 成果物の公開対象（output/artifact）には入らない。
- worker は画像バイトを data URI（multimodal content part）で載せる。
  本文へファイルパスを書くだけでは済ませない。
- 追記・セッション再開後も画像を参照できる（カーソル管理）。
- 画像非対応モデルでは明示的に失敗する。
"""

from __future__ import annotations

import base64
from pathlib import Path
from typing import Any

import pytest
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
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from mihari_room.worker.hermes import HermesWorker
from tests.recording import RecordingBoard, ScriptedWorker

TOKEN = "room-secret"

#: 最小の PNG っぽいバイト列。実体は不要（base64 で運ばれることを検証する）。
PNG_BYTES = b"\x89PNG\r\n\x1a\n" + bytes(range(16))
PNG_B64 = base64.b64encode(PNG_BYTES).decode("ascii")


def _auth() -> dict[str, str]:
    return {TOKEN_HEADER: TOKEN}


def _make_app(tmp_path: Path) -> TestClient:
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    worker = ScriptedWorker([ProgressEvent(kind=ProgressKind.SUMMARY, text="やった")])
    orch = RoomOrchestrator(store, FileJobQueue(store), board, worker)
    config = RoomConfig(token=TOKEN, root=tmp_path)
    return TestClient(create_app(config, orch, start_pump=False))


def _screenshot_payload(
    *,
    filename: str = "display.png",
    data: bytes = PNG_BYTES,
    scale: float = 2.0,
    pixel_width: int = 3024,
    pixel_height: int = 1964,
    display_id: int = 1,
) -> dict[str, Any]:
    return {
        "filename": filename,
        "media_type": "image/png",
        "content_base64": base64.b64encode(data).decode("ascii"),
        "source": "display",
        "source_title": "Built-in Retina Display",
        "display_id": display_id,
        "pixel_width": pixel_width,
        "pixel_height": pixel_height,
        "backing_scale": scale,
        "point_width": 1512.0,
        "point_height": 982.0,
        "frame_x": 0.0,
        "frame_y": 0.0,
    }


# --- 保存と認証 --------------------------------------------------------------


def test_screenshot_saved_with_metadata_and_not_published(tmp_path: Path) -> None:
    client = _make_app(tmp_path)
    created = client.post(
        "/jobs",
        json={
            "title": "画面を見て",
            "body": "このエラーを読んで",
            "source": "pet",
            "screenshots": [_screenshot_payload()],
        },
        headers=_auth(),
    )
    assert created.status_code == 200
    job_id = created.json()["job_id"]

    shot_dir = tmp_path / "jobs" / job_id / "input" / "screenshots"
    assert shot_dir.is_dir()
    stored = sorted(p for p in shot_dir.iterdir() if p.suffix == ".png")
    assert len(stored) == 1
    assert stored[0].read_bytes() == PNG_BYTES
    meta_file = shot_dir / "0001.json"
    assert meta_file.is_file()
    assert "backing_scale" in meta_file.read_text(encoding="utf-8")

    # 詳細 API はパスを出さず、メタデータを返す。
    detail = client.get(f"/jobs/{job_id}", headers=_auth()).json()
    shots = detail["screenshots"]
    assert len(shots) == 1
    assert shots[0]["backing_scale"] == 2.0
    assert shots[0]["pixel_width"] == 3024
    assert shots[0]["display_id"] == 1
    assert "screenshots" not in str(detail.get("artifacts"))
    assert "directory" not in detail

    # 成果物の公開対象（output/artifact）にスクショは入らない。
    assert not (tmp_path / "jobs" / job_id / "output" / "artifact").exists()

    # 未認証は 401。
    assert client.get(f"/jobs/{job_id}").status_code == 401


def test_screenshot_without_auth_is_rejected(tmp_path: Path) -> None:
    client = _make_app(tmp_path)
    response = client.post(
        "/jobs",
        json={"title": "t", "body": "b", "screenshots": [_screenshot_payload()]},
    )
    assert response.status_code == 401


def test_followup_screenshot_saved(tmp_path: Path) -> None:
    client = _make_app(tmp_path)
    job_id = client.post(
        "/jobs", json={"title": "t", "body": "b", "source": "pet"}, headers=_auth()
    ).json()["job_id"]

    response = client.post(
        f"/jobs/{job_id}/followup",
        json={"body": "もっと詳しく", "screenshots": [_screenshot_payload()]},
        headers=_auth(),
    )
    assert response.status_code == 200
    shot_dir = tmp_path / "jobs" / job_id / "input" / "screenshots"
    assert any(p.suffix == ".png" for p in shot_dir.iterdir())


@pytest.mark.parametrize(
    "bad",
    [
        {"filename": "../evil.png"},
        {"content_base64": "not-base64!"},
        {"media_type": "application/pdf"},
        {"source": "gpu"},
        {"backing_scale": -1},
    ],
)
def test_screenshot_validation_rejects(tmp_path: Path, bad: dict[str, Any]) -> None:
    client = _make_app(tmp_path)
    payload = _screenshot_payload()
    payload.update(bad)
    response = client.post(
        "/jobs",
        json={"title": "t", "body": "b", "screenshots": [payload]},
        headers=_auth(),
    )
    assert response.status_code in (400, 422)


def test_screenshot_count_and_size_limits(tmp_path: Path) -> None:
    client = _make_app(tmp_path)
    too_many = client.post(
        "/jobs",
        json={
            "title": "t",
            "body": "b",
            "screenshots": [_screenshot_payload() for _ in range(7)],
        },
        headers=_auth(),
    )
    assert too_many.status_code == 400
    assert "枚まで" in too_many.json()["detail"]

    from mihari_room.app import MAX_SCREENSHOT_BYTES

    oversized = _screenshot_payload(data=b"\x00" * (MAX_SCREENSHOT_BYTES + 1))
    response = client.post(
        "/jobs",
        json={"title": "t", "body": "b", "screenshots": [oversized]},
        headers=_auth(),
    )
    assert response.status_code == 400
    assert "大きすぎる" in response.json()["detail"]


# --- worker: マルチモーダル入力 ----------------------------------------------


class FakeAgent:
    """本家 AIAgent の最小の口。prompt を記録する。"""

    last: FakeAgent | None = None

    def __init__(self, **kwargs: Any) -> None:
        self.session_id = kwargs.get("session_id") or "sess-shot"
        self.prompts: list[Any] = []
        self.received_history = None
        FakeAgent.last = self

    def run_conversation(
        self, prompt: Any, conversation_history: list | None = None, **_kwargs: Any
    ) -> dict:
        self.prompts.append(prompt)
        self.received_history = conversation_history
        return {"final_response": "見えたよ"}

    def close(self) -> None:
        return None

    def shutdown_memory_provider(self, *_args: Any) -> None:
        return None


def _factory(**kwargs: Any) -> FakeAgent:
    return FakeAgent(**kwargs)


def _job_with_screenshot(tmp_path: Path, filename: str = "0001.png") -> Job:
    store = FileJobStore(tmp_path)
    job = store.create(CreateJobRequest(title="画面", body="見て", source=JobSource.PET))
    shot_dir = job.directory / "input" / "screenshots"
    shot_dir.mkdir(parents=True)
    (shot_dir / filename).write_bytes(PNG_BYTES)
    return job


async def test_screenshot_goes_as_data_uri_not_path(tmp_path: Path, monkeypatch: Any) -> None:
    monkeypatch.setattr("mihari_room.worker.agent.image_native_check", lambda: (True, ""))
    job = _job_with_screenshot(tmp_path)
    worker = HermesWorker(agent_factory=_factory, timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    assert await worker.run(job, on_progress) is JobStatus.DONE

    message = FakeAgent.last.prompts[0]
    assert isinstance(message, list)
    assert message[0]["type"] == "text"
    image_parts = [p for p in message if p.get("type") == "image_url"]
    assert len(image_parts) == 1
    url = image_parts[0]["image_url"]["url"]
    expected = "data:image/png;base64," + base64.b64encode(PNG_BYTES).decode("ascii")
    # バイト列が multimodal に載る（パス文字列だけではない）。
    assert url == expected
    assert "input/screenshots" not in url
    # 配信済みカーソルが進み、次は画像を再送しない。
    assert (job.directory / "screenshot_cursor").read_text(encoding="utf-8").strip() == "1"

    FakeAgent.last = None
    assert await worker.run(job, on_progress) is JobStatus.DONE
    second = FakeAgent.last.prompts[0]
    assert isinstance(second, str)  # 未配信スクショが無いのでテキストだけ


async def test_more_than_turn_limit_delivers_in_batches(tmp_path: Path, monkeypatch: Any) -> None:
    monkeypatch.setattr("mihari_room.worker.agent.image_native_check", lambda: (True, ""))
    job = _job_with_screenshot(tmp_path)
    shot_dir = job.directory / "input" / "screenshots"
    for i in range(2, 9):  # 計 8 枚
        (shot_dir / f"{i:04d}.png").write_bytes(PNG_BYTES)
    worker = HermesWorker(agent_factory=_factory, timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    assert await worker.run(job, on_progress) is JobStatus.DONE
    message = FakeAgent.last.prompts[0]
    assert isinstance(message, list)
    first_batch = [p for p in message if p.get("type") == "image_url"]
    from mihari_room.worker.agent import MAX_SCREENSHOTS_PER_TURN

    assert len(first_batch) == MAX_SCREENSHOTS_PER_TURN
    assert (job.directory / "screenshot_cursor").read_text(encoding="utf-8").strip() == str(
        MAX_SCREENSHOTS_PER_TURN
    )

    FakeAgent.last = None
    assert await worker.run(job, on_progress) is JobStatus.DONE
    second = FakeAgent.last.prompts[0]
    assert isinstance(second, list)
    rest = [p for p in second if p.get("type") == "image_url"]
    assert len(rest) == 2  # 残りは 2 枚だけ。重複配信しない。
    assert (job.directory / "screenshot_cursor").read_text(encoding="utf-8").strip() == "8"


async def test_followup_screenshot_is_attached_on_next_turn(
    tmp_path: Path, monkeypatch: Any
) -> None:
    monkeypatch.setattr("mihari_room.worker.agent.image_native_check", lambda: (True, ""))
    store = FileJobStore(tmp_path)
    job = store.create(CreateJobRequest(title="画面", body="見て", source=JobSource.PET))
    worker = HermesWorker(agent_factory=_factory, timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        return None

    assert await worker.run(job, on_progress) is JobStatus.DONE

    # 追記でスクショが来る。
    shot_dir = job.directory / "input" / "screenshots"
    shot_dir.mkdir(parents=True, exist_ok=True)
    (shot_dir / "0001.png").write_bytes(PNG_BYTES)
    (job.directory / "input" / "followup-01.txt").write_text("もっと詳しく", encoding="utf-8")

    FakeAgent.last = None
    assert await worker.run(job, on_progress) is JobStatus.DONE
    message = FakeAgent.last.prompts[0]
    assert isinstance(message, list)
    text = " ".join(p.get("text", "") for p in message if isinstance(p, dict))
    assert "もっと詳しく" in text
    image_parts = [p for p in message if p.get("type") == "image_url"]
    assert len(image_parts) == 1
    assert image_parts[0]["image_url"]["url"].startswith("data:image/png;base64,")
    # 前ターンは画像が無かったので、今回の image は 1 枚だけ（重複しない）。
    assert (job.directory / "screenshot_cursor").read_text(encoding="utf-8").strip() == "1"


async def test_unsupported_model_fails_explicitly(tmp_path: Path, monkeypatch: Any) -> None:
    monkeypatch.setattr(
        "mihari_room.worker.agent.image_native_check",
        lambda: (False, "モデルが画像を読めない（テスト）"),
    )
    job = _job_with_screenshot(tmp_path)
    worker = HermesWorker(agent_factory=_factory, timeout=30)
    events: list[ProgressEvent] = []

    async def on_progress(ev: ProgressEvent) -> None:
        events.append(ev)

    assert await worker.run(job, on_progress) is JobStatus.FAILED
    texts = " ".join(e.text for e in events)
    assert "スクショを添付できない" in texts
    assert "モデルが画像を読めない" in texts
    # 失敗時は配信カーソルを進めない（次の再実行で再添付できる）。
    assert not (job.directory / "screenshot_cursor").exists()
