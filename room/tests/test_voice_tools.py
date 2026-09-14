"""音声セッションのツール実行器（VoiceToolExecutor）の単体検証。"""

from __future__ import annotations

import base64
import json
from pathlib import Path
from typing import Any

from mihari_room.config import RoomConfig
from mihari_room.contracts import CreateJobRequest, Job, JobSource, JobStatus
from mihari_room.fakes import InMemoryJobStore
from mihari_room.mac_control.errors import MacControlError, MacControlErrorCode
from mihari_room.voice.sessions import VoiceSessionManager
from mihari_room.voice.tools import (
    CLIENT_SIDE_TOOLS,
    VOICE_TOOL_SCHEMAS,
    VoiceToolExecutor,
    VoiceToolOutcome,
)

TOKEN = "room-secret"


class FakeOrchestrator:
    """submit / steer / answer / cancel / store だけを持つ orchestrator スタブ。"""

    def __init__(self, root: Path) -> None:
        self.store = InMemoryJobStore(root)
        self.submissions: list[tuple[CreateJobRequest, list[tuple[str, bytes]]]] = []
        self.steers: list[tuple[str, str]] = []
        self.answers: list[tuple[str, str, str]] = []
        self.cancels: list[tuple[str, str]] = []

    async def submit(
        self,
        request: CreateJobRequest,
        *,
        attachments: Any = (),
        screenshots: Any = (),
    ) -> Job:
        job = self.store.create(request)
        self.submissions.append((request, list(attachments)))
        return job

    async def steer_job(self, job_id: str, text: str) -> dict[str, Any]:
        job = self.store.get(job_id)
        self.steers.append((job.id, text))
        return {"id": "s1", "text": text, "status": "queued"}

    async def answer_question(
        self, job_id: str, qid: str, answer: str
    ) -> dict[str, Any]:
        job = self.store.get(job_id)
        self.answers.append((job.id, qid, answer))
        return {"id": qid, "answer": answer, "status": "answered"}

    async def cancel(self, job_id: str, *, by: str) -> Job:
        self.cancels.append((job_id, by))
        return self.store.set_status(job_id, JobStatus.CANCELLED)


class FakeMacHub:
    """begin_run / run_operation / end_run を記録する MacControlHub スタブ。"""

    def __init__(self) -> None:
        self.begun: list[dict[str, Any]] = []
        self.ops: list[tuple[str, dict[str, Any]]] = []
        self.ended: list[dict[str, Any]] = []
        self.results: dict[str, dict[str, Any]] = {}
        self.begin_error: Exception | None = None

    def begin_run(
        self, *, job_id: str, run_id: str, job_dir: Path, job_title: str = ""
    ) -> None:
        if self.begin_error is not None:
            raise self.begin_error
        self.begun.append(
            {
                "job_id": job_id,
                "run_id": run_id,
                "job_dir": job_dir,
                "job_title": job_title,
            }
        )

    def run_operation(
        self,
        *,
        job_id: str,
        run_id: str,
        kind: Any,
        params: dict[str, Any],
        device_id: str | None = None,
    ) -> dict[str, Any]:
        key = str(kind)
        self.ops.append((key, dict(params)))
        return self.results.get(
            key,
            {"success": True, "op_id": "op-1", "kind": key, "result": {}},
        )

    def end_run(self, *, job_id: str, run_id: str, reason: str = "") -> None:
        self.ended.append({"job_id": job_id, "run_id": run_id, "reason": reason})


def _make_executor(
    tmp_path: Path,
    *,
    orchestrator: FakeOrchestrator | None = None,
    hub: FakeMacHub | None = None,
) -> VoiceToolExecutor:
    config = RoomConfig(token=TOKEN, root=tmp_path, owner_id="owner")
    manager = VoiceSessionManager(config)
    return VoiceToolExecutor(
        session_id="sess-1",
        manager=manager,
        orchestrator=orchestrator,
        mac_hub=hub,
        interactions=None,
        config=config,
    )


def _payload(outcome: VoiceToolOutcome) -> dict[str, Any]:
    return json.loads(outcome.output)


async def _run(executor: VoiceToolExecutor, name: str, args: dict[str, Any] | str):
    raw = args if isinstance(args, str) else json.dumps(args, ensure_ascii=False)
    return await executor.execute(name, raw)


def test_tool_schemas_cover_all_voice_tools() -> None:
    names = {tool["name"] for tool in VOICE_TOOL_SCHEMAS}
    assert {
        "submit_job",
        "steer_job",
        "get_job_status",
        "list_running_jobs",
        "answer_job_question",
        "cancel_job",
        "capture_screen",
        "discord_search",
        "discord_recent",
        "discord_channels",
        "discord_message",
        "discord_context",
        "mac_find_files",
        "mac_fetch_file",
        "mac_hand_off_file",
    } <= names
    for tool in VOICE_TOOL_SCHEMAS:
        assert tool["type"] == "function"
        assert tool["parameters"]["type"] == "object"


async def test_submit_job_creates_job(tmp_path: Path) -> None:
    orch = FakeOrchestrator(tmp_path)
    executor = _make_executor(tmp_path, orchestrator=orch)
    outcome = await _run(
        executor, "submit_job", {"prompt": "レポートを直して", "title": ""}
    )
    payload = _payload(outcome)
    assert payload["success"] is True
    assert payload["job_id"]
    assert payload["title"] == "レポートを直して"
    request, attachments = orch.submissions[0]
    assert request.source is JobSource.PET
    assert request.requested_by == "owner"
    assert request.body == "レポートを直して"
    assert attachments == []


async def test_submit_job_requires_prompt(tmp_path: Path) -> None:
    orch = FakeOrchestrator(tmp_path)
    executor = _make_executor(tmp_path, orchestrator=orch)
    outcome = await _run(executor, "submit_job", {"prompt": "  "})
    assert _payload(outcome)["success"] is False
    assert orch.submissions == []


async def test_submit_job_attachments_from_downloads_only(tmp_path: Path) -> None:
    orch = FakeOrchestrator(tmp_path)
    executor = _make_executor(tmp_path, orchestrator=orch)
    executor.downloads_dir.mkdir(parents=True)
    (executor.downloads_dir / "note.txt").write_bytes(b"hello")
    outcome = await _run(
        executor,
        "submit_job",
        {"prompt": "添付つき", "attachments": ["note.txt"]},
    )
    assert _payload(outcome)["success"] is True
    _request, attachments = orch.submissions[0]
    assert attachments == [("note.txt", b"hello")]


async def test_submit_job_rejects_path_traversal(tmp_path: Path) -> None:
    orch = FakeOrchestrator(tmp_path)
    executor = _make_executor(tmp_path, orchestrator=orch)
    # downloads/ の外に同名ファイルがあっても拾えない
    # （sanitize で basename 化 + ensure_contained で二重に弾く）。
    (tmp_path / "voice" / "sess-1").mkdir(parents=True, exist_ok=True)
    (tmp_path / "voice" / "sess-1" / "secret.txt").write_bytes(b"secret")
    outcome = await _run(
        executor,
        "submit_job",
        {"prompt": "x", "attachments": ["../secret.txt"]},
    )
    assert _payload(outcome)["success"] is False
    assert orch.submissions == []


async def test_submit_job_rejects_unfetched_attachment(tmp_path: Path) -> None:
    orch = FakeOrchestrator(tmp_path)
    executor = _make_executor(tmp_path, orchestrator=orch)
    outcome = await _run(
        executor,
        "submit_job",
        {"prompt": "x", "attachments": ["missing.png"]},
    )
    payload = _payload(outcome)
    assert payload["success"] is False
    assert "mac_fetch_file" in payload["error"]


async def test_steer_job_uses_last_submitted(tmp_path: Path) -> None:
    orch = FakeOrchestrator(tmp_path)
    executor = _make_executor(tmp_path, orchestrator=orch)
    submitted = _payload(await _run(executor, "submit_job", {"prompt": "p"}))
    outcome = await _run(executor, "steer_job", {"instruction": "急いで"})
    payload = _payload(outcome)
    assert payload["success"] is True
    assert orch.steers == [(submitted["job_id"], "急いで")]


async def test_steer_job_without_target_fails(tmp_path: Path) -> None:
    orch = FakeOrchestrator(tmp_path)
    executor = _make_executor(tmp_path, orchestrator=orch)
    outcome = await _run(executor, "steer_job", {"instruction": "x"})
    assert _payload(outcome)["success"] is False


async def test_get_job_status_specific_and_running(tmp_path: Path) -> None:
    orch = FakeOrchestrator(tmp_path)
    executor = _make_executor(tmp_path, orchestrator=orch)
    submitted = _payload(await _run(executor, "submit_job", {"prompt": "p"}))
    # 直近 job を引く（job_id 省略）。
    outcome = await _run(executor, "get_job_status", {})
    payload = _payload(outcome)
    assert payload["success"] is True
    assert payload["job_id"] == submitted["job_id"]
    assert payload["status"] == "queued"
    assert payload["pending_questions"] == []
    # 存在しない job。
    missing = _payload(await _run(executor, "get_job_status", {"job_id": "nope"}))
    assert missing["success"] is False
    # 実行中一覧。
    running = _payload(await _run(executor, "list_running_jobs", {}))
    assert running["success"] is True
    assert running["jobs"] == []


async def test_answer_and_cancel_job(tmp_path: Path) -> None:
    orch = FakeOrchestrator(tmp_path)
    executor = _make_executor(tmp_path, orchestrator=orch)
    submitted = _payload(await _run(executor, "submit_job", {"prompt": "p"}))
    answer = _payload(
        await _run(
            executor,
            "answer_job_question",
            {
                "job_id": submitted["job_id"],
                "question_id": "q1",
                "answer": "はい",
            },
        )
    )
    assert answer["success"] is True
    assert orch.answers == [(submitted["job_id"], "q1", "はい")]
    cancelled = _payload(
        await _run(executor, "cancel_job", {"job_id": submitted["job_id"]})
    )
    assert cancelled["success"] is True
    assert cancelled["status"] == "cancelled"
    assert orch.cancels == [(submitted["job_id"], "voice")]


async def test_capture_screen_is_client_side(tmp_path: Path) -> None:
    assert "capture_screen" in CLIENT_SIDE_TOOLS
    executor = _make_executor(tmp_path)
    outcome = await _run(executor, "capture_screen", {"prompt": "見て"})
    assert outcome.client_side is True


async def test_unknown_tool_and_bad_json(tmp_path: Path) -> None:
    executor = _make_executor(tmp_path)
    unknown = await _run(executor, "nope", {})
    assert _payload(unknown)["success"] is False
    bad = await executor.execute("submit_job", "{broken")
    assert _payload(bad)["success"] is False
    non_dict = await executor.execute("submit_job", '"str"')
    assert _payload(non_dict)["success"] is False


async def test_discord_tools_fail_cleanly_without_archive(tmp_path: Path) -> None:
    executor = _make_executor(tmp_path)
    for name, args in (
        ("discord_search", {"query": "ごはん"}),
        ("discord_recent", {}),
        ("discord_channels", {}),
        ("discord_message", {"message_id": 1}),
        ("discord_context", {"message_id": 1}),
    ):
        outcome = await _run(executor, name, args)
        payload = _payload(outcome)
        assert payload["success"] is False, name


async def test_discord_search_uses_room_root(tmp_path: Path) -> None:
    """archive db（<root>/messages.db）が shim の parent.parent 経由で見つかる。"""
    import datetime as dt

    from mihari_room.archive.db import ArchiveDatabase
    from mihari_room.archive.models import StoredMessage

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        db.upsert_message(
            StoredMessage(
                message_id=1,
                guild_id=7,
                channel_id=11,
                channel_name="main",
                thread_id=None,
                thread_name=None,
                author_id=42,
                author_name="たろー",
                content="みはりちゃんのごはんを確認",
                created_at=dt.datetime(2024, 1, 2, tzinfo=dt.UTC),
                jump_url="https://discord.com/channels/7/11/1",
            )
        )
    finally:
        db.close()
    executor = _make_executor(tmp_path)
    outcome = await _run(executor, "discord_search", {"query": "ごはん"})
    payload = _payload(outcome)
    assert payload["success"] is True
    assert payload["count"] >= 1


async def test_mac_tools_begin_run_lazily_and_close(tmp_path: Path) -> None:
    hub = FakeMacHub()
    executor = _make_executor(tmp_path, hub=hub)
    # mac 系を呼ぶまでは run を張らない。
    await _run(executor, "list_running_jobs", {})
    assert hub.begun == []
    outcome = await _run(
        executor, "mac_find_files", {"query": "請求書", "limit": 5}
    )
    payload = _payload(outcome)
    assert payload["success"] is True
    assert len(hub.begun) == 1
    assert hub.begun[0]["job_id"] == "voice-sess-1"
    assert hub.ops[0][0] == "find_files"
    assert hub.ops[0][1]["query"] == "請求書"
    assert hub.ops[0][1]["limit"] == 5
    # 2 回目以降は begin しない。
    await _run(executor, "mac_hand_off_file", {"path": "/tmp/a.pdf"})
    assert len(hub.begun) == 1
    assert hub.ops[1][0] == "hand_off_file"
    await executor.close()
    assert len(hub.ended) == 1
    assert hub.ended[0]["run_id"] == hub.begun[0]["run_id"]
    # close は冪等。
    await executor.close()
    assert len(hub.ended) == 1


async def test_mac_fetch_file_saves_to_downloads(tmp_path: Path) -> None:
    hub = FakeMacHub()
    orch = FakeOrchestrator(tmp_path)
    data = b"PNGDATA"
    hub.results["fetch_file"] = {
        "success": True,
        "op_id": "op-1",
        "kind": "fetch_file",
        "result": {
            "name": "画面 1.png",
            "data_base64": base64.b64encode(data).decode(),
        },
    }
    executor = _make_executor(tmp_path, orchestrator=orch, hub=hub)
    outcome = await _run(
        executor, "mac_fetch_file", {"path": "/Users/me/画面 1.png"}
    )
    payload = _payload(outcome)
    assert payload["success"] is True
    saved = payload["saved_as"]
    assert saved.endswith(".png")
    saved_path = executor.downloads_dir / saved
    assert saved_path.read_bytes() == data
    # PNG は結果画像として upstream へ添付される。
    assert outcome.image_png == data
    # 保存したファイルは submit_job の attachments から参照できる。
    attached = _payload(
        await _run(
            executor,
            "submit_job",
            {"prompt": "これを使って", "attachments": [saved]},
        )
    )
    assert attached["success"] is True
    assert orch.submissions[0][1] == [(saved, data)]


async def test_mac_tools_fail_cleanly_without_device(tmp_path: Path) -> None:
    hub = FakeMacHub()
    hub.begin_error = MacControlError(
        MacControlErrorCode.NO_DEVICE, "Mac が繋がっていない"
    )
    executor = _make_executor(tmp_path, hub=hub)
    outcome = await _run(executor, "mac_find_files", {"query": "x"})
    payload = _payload(outcome)
    assert payload["success"] is False
    assert payload["code"] == "no_device"
    assert outcome.ok is False
    await executor.close()
    # begin が失敗しているので end_run は呼ばれない。
    assert hub.ended == []


async def test_mac_tools_without_hub(tmp_path: Path) -> None:
    executor = _make_executor(tmp_path, hub=None)
    outcome = await _run(executor, "mac_find_files", {"query": "x"})
    payload = _payload(outcome)
    assert payload["success"] is False
    assert payload["code"] == "unavailable"


async def test_executor_tolerates_orchestrator_errors(tmp_path: Path) -> None:
    class BrokenOrchestrator(FakeOrchestrator):
        async def submit(self, request, *, attachments=(), screenshots=()):
            raise RuntimeError("forum down")

    executor = _make_executor(tmp_path, orchestrator=BrokenOrchestrator(tmp_path))
    outcome = await _run(executor, "submit_job", {"prompt": "p"})
    payload = _payload(outcome)
    assert payload["success"] is False
    assert "forum down" in payload["error"]
    assert outcome.ok is False


async def test_tools_do_not_raise_without_orchestrator(tmp_path: Path) -> None:
    executor = _make_executor(tmp_path, orchestrator=None)
    for name, args in (
        ("submit_job", {"prompt": "p"}),
        ("steer_job", {"instruction": "x"}),
        ("answer_job_question", {"job_id": "j", "question_id": "q", "answer": "a"}),
        ("cancel_job", {"job_id": "j"}),
    ):
        outcome = await _run(executor, name, args)
        assert _payload(outcome)["success"] is False, name
    # get/list は store 無しでも空一覧を返す。
    listing = _payload(await _run(executor, "list_running_jobs", {}))
    assert listing["success"] is True
    assert listing["jobs"] == []
