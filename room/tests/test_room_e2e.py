"""End-to-end local scenario with a fake AIAgent (no live VPS claims).

Seeded Discord messages + PDF -> bounded search/export tools -> source summary
+ mock generated artifact -> job/SSE/public URL/followup/restart/memory approval.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import json
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from mihari_room.app import create_app, parse_last_event_id
from mihari_room.archive.db import ArchiveDatabase
from mihari_room.archive.models import AttachmentStatus, StoredAttachment, StoredMessage
from mihari_room.artifacts import ArtifactPublisher
from mihari_room.config import TOKEN_HEADER, RoomConfig
from mihari_room.contracts import CreateJobRequest, Job, JobSource, JobStatus
from mihari_room.events import EventJournal
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from mihari_room.worker.hermes import HermesWorker
from mihari_room.worker.memory import MemoryCandidateStore
from tests.recording import RecordingBoard

TOKEN = "room-secret"


def _message(message_id: int, content: str) -> StoredMessage:
    return StoredMessage(
        message_id=message_id,
        guild_id=777,
        channel_id=111,
        channel_name="main",
        thread_id=None,
        thread_name=None,
        author_id=42,
        author_name="たろー",
        content=content,
        created_at=dt.datetime(2024, 1, 2, 3, 4, 5, tzinfo=dt.UTC),
        jump_url=f"https://discord.com/channels/777/111/{message_id}",
    )


def _seed_archive(root: Path) -> None:
    db = ArchiveDatabase(root / "messages.db")
    try:
        db.upsert_message(_message(1, "みはりちゃんのごはん設計メモ https://example.com/menu"))
        db.upsert_message(
            _message(2, "仕様 PDF を更新した"),
            attachments=[
                StoredAttachment(
                    message_id=2,
                    attachment_id=7,
                    filename="spec.pdf",
                    size=9,
                    url="https://cdn.discordapp.com/attachments/1/2/spec.pdf",
                    status=AttachmentStatus.OK,
                    local_path=None,
                )
            ],
        )
    finally:
        db.close()


class FakeAgent:
    """Seeded-tool user: searches, exports, summarizes, generates, proposes memory."""

    def __init__(self, **kwargs: Any) -> None:
        self.session_id = kwargs.get("session_id") or "sess-e2e-1"
        self.kwargs = kwargs

    def run_conversation(self, prompt: str, conversation_history: Any = None, **_: Any) -> dict:
        from mihari_room.worker.discord_tools import discord_export_impl, discord_search_impl

        # Room root + job dir are real (FileJobStore); cwd is the job dir.
        job_dir = Path.cwd()
        job_id = job_dir.name
        room_root = job_dir.parent.parent

        class _Job:
            id = job_id
            directory = job_dir

        search = json.loads(discord_search_impl(_Job(), "ごはん"))
        assert search["success"] is True and search["count"] >= 1
        export = json.loads(discord_export_impl(_Job(), 2, no_fetch=True))
        assert export["success"] is True, export

        # Source summary from the archive hit (jump_url cited).
        summary = (
            "# 調査まとめ\n\n"
            f"- {search['hits'][0]['content']}\n"
            f"- 出典: {search['hits'][0]['jump_url']}\n"
        )
        research = job_dir / "research"
        research.mkdir(parents=True, exist_ok=True)
        (research / "summary.md").write_text(summary, encoding="utf-8")

        # Mock generated artifact + files that must NEVER be posted.
        artifact = job_dir / "output" / "artifact"
        artifact.mkdir(parents=True, exist_ok=True)
        (artifact / "index.html").write_text(
            "<html><head><link rel='stylesheet' href='style.css'></head>"
            "<body><h1>ごはん</h1><script src='app.js'></script></body></html>",
            encoding="utf-8",
        )
        (artifact / "style.css").write_text("h1 { color: red; }", encoding="utf-8")
        (artifact / "app.js").write_text("console.log('mock');", encoding="utf-8")
        (job_dir / "output" / "secret-notes.txt").write_text("token=xxx", encoding="utf-8")
        (job_dir / "output" / "claim_url.txt").write_text(
            "claim_url=https://u:p@host/x", encoding="utf-8"
        )

        # Memory candidate for later owner approval.
        home = Path(__import__("os").environ["MIHARI_HERMES_HOME"])
        mem = MemoryCandidateStore(room_root, home)
        mem.propose(job_id, "memory", "e2e approved fact")

        (job_dir / "input" / "note.txt").write_text("input", encoding="utf-8")
        return {"final_response": "ごはん設計をまとめたよ。"}

    def close(self) -> None:
        return None

    def shutdown_memory_provider(self, messages: Any = None) -> None:
        return None

    def interrupt(self, *_args: Any) -> None:
        return None


def test_room_e2e_fake_agent(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("MIHARI_HERMES_HOME", str(tmp_path / "hermes-home"))
    _seed_archive(tmp_path)

    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    worker = HermesWorker(command=None, agent_factory=lambda **kw: FakeAgent(**kw))
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id="owner"), board, worker)
    config = RoomConfig(
        token=TOKEN,
        root=tmp_path,
        owner_id="owner",
        preview_base_url="https://preview.example.test",
    )
    orch.attach_publisher(
        ArtifactPublisher(root=tmp_path, preview_base_url=config.preview_base_url)
    )

    async def go() -> Job:
        job = await orch.submit(
            CreateJobRequest(title="ごはん", body="まとめて", source=JobSource.PET)
        )
        await orch._run_available()
        # Followup v2: same job, same session, resumed.
        await orch.follow_up_job(job.id, "分量も追記して", requested_by="owner")
        await orch._run_available()
        await orch.aclose()
        return store.get(job.id)

    job = asyncio.run(go())

    assert job.status is JobStatus.DONE
    # Session continuity: hermes_session_id persisted.
    session_id = (job.directory / "hermes_session_id").read_text(encoding="utf-8").strip()
    assert session_id == "sess-e2e-1"
    # Only explicitly safe output posted (no secrets/manifests/research).
    posted = sorted(p.name for _, p in board.files)
    assert "index.html" in posted
    assert "secret-notes.txt" not in posted and "claim_url.txt" not in posted
    # Research sources exist (export writes sources.json/summary.md under downloads/).
    assert (job.directory / "research" / "downloads" / "sources.json").is_file()
    assert (job.directory / "research" / "downloads" / "summary.md").is_file()
    # SSE replay: unknown cursor loses nothing; far cursor is empty.
    journal = EventJournal.for_job(job.directory)
    assert len(journal.after(0)) > 0
    assert journal.after(10**9) == []
    assert parse_last_event_id("not-a-number") == 0
    assert parse_last_event_id(str(journal.after(0)[0]["id"])) == journal.after(0)[0]["id"]

    # Public URL: followup rerun published v2 (stable id, versions increment).
    publisher = ArtifactPublisher(root=tmp_path, preview_base_url="https://preview.example.test")
    manifests = publisher.manifests_for(job.id)
    assert len(manifests) == 2
    assert [m["version"] for m in manifests] == [1, 2]
    assert manifests[0]["id"] == manifests[1]["id"]
    assert manifests[0]["sha256"] == manifests[1]["sha256"]  # identical content: deterministic
    manifest = manifests[-1]
    assert manifest["preview_url"].startswith("https://preview.example.test/")
    assert manifest["session_id"] == "sess-e2e-1"
    assert "note.txt" in manifest["source_ids"] or "followup-01.txt" in manifest["source_ids"]
    token = manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]

    client = TestClient(create_app(config, orch, start_pump=False))
    headers = {TOKEN_HEADER: TOKEN}
    page = client.get(f"/previews/{token}/")
    assert page.status_code == 200
    assert "ごはん" in page.text
    csp = page.headers["content-security-policy"]
    assert "sandbox allow-scripts" in csp and "allow-same-origin" not in csp
    css = client.get(f"/previews/{token}/style.css")
    assert css.status_code == 200
    # Tampered non-allowlist file is never served.
    (tmp_path / "previews" / token / "evil.php").write_text("<?php", encoding="utf-8")
    assert client.get(f"/previews/{token}/evil.php").status_code == 404

    # Memory approval contract over HTTP (shared with desktop agent).
    listing = client.get(f"/jobs/{job.id}/memory", headers=headers).json()
    assert len(listing["candidates"]) >= 1
    candidate_id = listing["candidates"][0]["id"]
    approved = client.post(f"/jobs/{job.id}/memory/{candidate_id}/approve", headers=headers)
    assert approved.status_code == 200
    assert approved.json()["status"] == "approved"
    home_mem = (tmp_path / "hermes-home" / "memories" / "MEMORY.md").read_text(encoding="utf-8")
    assert "e2e approved fact" in home_mem

    # Restart: a crashed RUNNING desk returns to queued, memory survives.
    store.set_status(job.id, JobStatus.RUNNING)
    orch2 = RoomOrchestrator(
        FileJobStore(tmp_path),
        FileJobQueue(FileJobStore(tmp_path), owner_id="owner"),
        board,
        worker,
    )
    restored = orch2.restore()
    assert [j.id for j in restored] == [job.id]
    mem2 = MemoryCandidateStore(tmp_path, tmp_path / "hermes-home")
    assert mem2.list(job.id)[0].status == "approved"
