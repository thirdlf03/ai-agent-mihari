"""作業部屋の HTTP。ペットの `POST /jobs` を受ける。

Phase 2/3: 仕事の詳細・イベントの SSE・成果物プレビューの公開も担う。
"""

from __future__ import annotations

import asyncio
import json
import mimetypes
import re
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
from pydantic import BaseModel
from starlette.responses import Response, StreamingResponse

from mihari_room.artifacts import PREVIEWS_DIRNAME, ArtifactPublisher
from mihari_room.auth import verify_token
from mihari_room.config import RoomConfig
from mihari_room.contracts import (
    DEFAULT_JOB_TITLE,
    CreateJobRequest,
    Job,
    JobSource,
    JobStatus,
)
from mihari_room.discord.board import MAX_TITLE_LEN
from mihari_room.events import EventJournal
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import CancelNotAllowed
from mihari_room.store.file_store import JobNotFound
from mihari_room.worker.agent import read_session_id

#: SSE のポーリング間隔。ファイルを読むだけなので短くてよい。
POLL_INTERVAL_SEC = 0.25
#: プロキシに落ちないためのハートビート間隔。
HEARTBEAT_INTERVAL_SEC = 15.0
#: 完了してから stream を閉じるまでの余裕。この間に続きが来たら繋ぎ直す。
TERMINAL_HOLD_SEC = 5.0


class JobCreateBody(BaseModel):
    title: str = ""
    body: str = ""
    source: JobSource = JobSource.PET
    requested_by: str | None = None


class JobCreateResponse(BaseModel):
    job_id: str
    thread_id: int | None
    status: str


class FollowupBody(BaseModel):
    body: str
    requested_by: str | None = None


class CancelBody(BaseModel):
    by: str | None = None


def derive_title(title: str, body: str) -> str:
    """ペット側と同じ。空なら本文の先頭の中身がある行、最大 100 文字。

    どちらも空なら Discord が弾く空スレ名を避けるため「依頼」。
    """
    trimmed = title.strip()
    if trimmed:
        return trimmed[:MAX_TITLE_LEN]
    for line in body.splitlines():
        first = line.strip()
        if first:
            return first[:MAX_TITLE_LEN]
    return DEFAULT_JOB_TITLE


def parse_last_event_id(raw: str | None) -> int:
    """SSE の Last-Event-ID を整数に。未知・壊れていれば 0（最初から）。

    未知の id で黙って取りこぼさないために、解釈できないものは先頭に戻す。
    """
    if raw is None or not raw.strip():
        return 0
    try:
        value = int(raw.strip())
    except ValueError:
        return 0
    return value if value >= 0 else 0


def _sse(event: dict[str, Any]) -> str:
    return f"id: {event['id']}\nevent: job\ndata: {json.dumps(event, ensure_ascii=False)}\n\n"


async def _job_events_stream(
    orchestrator: RoomOrchestrator,
    job_id: str,
    replay_from: int,
    poll: float,
    heartbeat: float,
    hold: float,
) -> AsyncIterator[str]:
    """出来事を追いかける非同期ストリーム。閉じたら直すのは呼び出し側。"""
    journal = EventJournal.for_job(orchestrator.store.job_dir(job_id))
    last_id = replay_from
    last_activity = time.monotonic()
    terminal_since: float | None = None
    try:
        while True:
            new = journal.after(last_id)
            for event in new:
                yield _sse(event)
                last_id = event["id"]
                last_activity = time.monotonic()

            try:
                job = orchestrator.store.get(job_id)
            except JobNotFound:
                # 途中で消えたら静かに閉じる。
                return
            is_terminal = job.status in (
                JobStatus.DONE,
                JobStatus.FAILED,
                JobStatus.CANCELLED,
            )
            if is_terminal:
                if terminal_since is None:
                    terminal_since = time.monotonic()
                if (
                    terminal_since is not None
                    and time.monotonic() - terminal_since >= hold
                    and not new
                ):
                    return
            else:
                terminal_since = None

            if time.monotonic() - last_activity >= heartbeat:
                yield ": hb\n\n"
                last_activity = time.monotonic()
            await asyncio.sleep(poll)
    except asyncio.CancelledError:
        raise


@asynccontextmanager
async def _lifespan(app: FastAPI) -> AsyncIterator[None]:
    orchestrator: RoomOrchestrator = app.state.orchestrator
    orchestrator.restore()
    if app.state.start_pump:
        orchestrator.start_pump()
    starter = getattr(app.state, "discord_starter", None)
    stop = getattr(app.state, "discord_stopper", None)
    if callable(starter):
        await starter()
    try:
        yield
    finally:
        if callable(stop):
            await stop()
        await orchestrator.aclose()


def _job_detail(orchestrator: RoomOrchestrator, job: Job) -> dict[str, Any]:
    """詳細。絶対パスは出さない。session と成果物は置いてあれば。"""
    journal = EventJournal.for_job(job.directory)
    publisher = orchestrator.publisher
    artifacts = publisher.manifests_for(job.id) if publisher is not None else []
    return {
        "job_id": job.id,
        "title": job.title,
        "status": job.status.value,
        "thread_id": job.thread_id,
        "session_id": read_session_id(job),
        "artifacts": artifacts,
        "latest_event": journal.latest(),
    }


def _preview_headers() -> dict[str, str]:
    """未認証プレビューの安全ヘッダ。nosniff / no-referrer / sandbox CSP。

    opaque origin の sandbox（allow-same-origin なし）で動かす。
    相対 CSS/画像/フォントと同一フォルダの JS だけ許し、API origin への権限は渡さない
    （connect-src 'none'、form-action 'none'）。対話モック用の script は
    ``sandbox allow-scripts`` で許すが、allow-same-origin は付けないので
    親ページの DOM・storage には触れない。
    """
    return {
        "Content-Security-Policy": (
            "sandbox allow-scripts; default-src 'none'; base-uri 'none'; "
            "form-action 'none'; connect-src 'none'; worker-src 'none'; "
            "img-src 'self' data: https:; media-src 'self' data:; "
            "style-src 'self' 'unsafe-inline'; script-src 'self'; "
            "font-src 'self' data:;"
        ),
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        "X-Frame-Options": "DENY",
        "Cache-Control": "no-store",
    }


def _serve_preview(config: RoomConfig, token: str, rest: str) -> Response:
    """プレビューを未認証で返す。ルートやメタデータは晒さない。

    - token 自体・token 配下の symlink chain は拒否（FS 改ざん時の他 job 漏洩対策）
    - ``..`` / 絶対パス / 隠しファイル（``.*``）・メタデータ名は 404
    - 公開 allowlist（ArtifactPublisher と同じ拡張子）以外の実ファイルは出さない
    """
    from mihari_room.artifacts import _ALLOWED_WEB_EXT

    if not re.fullmatch(r"[A-Za-z0-9_-]+", token):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    previews_root = (config.root / PREVIEWS_DIRNAME).resolve()
    token_dir = config.root / PREVIEWS_DIRNAME / token
    # token 置き場自体の symlink は拒否。
    if token_dir.is_symlink() or not token_dir.is_dir():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    rel = Path(rest or "index.html")
    if rel.is_absolute() or ".." in rel.parts:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    if any(part.startswith(".") for part in rel.parts):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    candidate = token_dir / rel
    if candidate.is_symlink():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    try:
        resolved = candidate.resolve()
    except OSError as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error
    try:
        token_resolved = token_dir.resolve()
    except OSError as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error
    if token_resolved != previews_root / token or not resolved.is_relative_to(token_resolved):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    # 途中の symlink chain（他 token・root 外への差し替え）も拒否。
    node = candidate
    for _ in range(len(rel.parts) + 1):
        if node.is_symlink():
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
        if node == token_dir:
            break
        node = node.parent
    if not resolved.is_file() or resolved.is_symlink():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    if resolved.suffix.lower() not in _ALLOWED_WEB_EXT:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    media = mimetypes.guess_type(resolved.name)[0] or "application/octet-stream"
    return Response(content=resolved.read_bytes(), media_type=media, headers=_preview_headers())


#: candidate id は MemoryCandidateStore が振る hex（12 chars）。外からはこの形だけ。
_CANDIDATE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")


def _memory_store_for_config(config: RoomConfig):
    from mihari_room.worker.memory import MemoryCandidateStore
    from mihari_room.worker.runtime_lock import resolve_hermes_home

    return MemoryCandidateStore(config.root, resolve_hermes_home(config.root))


def _candidate_to_dict(candidate: Any) -> dict[str, Any]:
    return {
        "id": candidate.id,
        "target": candidate.target,
        "content": candidate.content,
        "status": candidate.status,
        "created_at": candidate.created_at,
    }


async def _memory_decide(
    request: Request, job_id: str, candidate_id: str, *, approve: bool
) -> dict[str, Any]:
    """memory 候補の approve/reject。承認者は token owner（config 側）のみ。

    body の身分表示は一切使わない。認証済み token の持ち主 = owner として扱い、
    記録上の approved_by も config.owner_id にする。owner 未設定なら 403。
    """
    orchestrator = request.app.state.orchestrator
    config: RoomConfig = request.app.state.config
    if not config.owner_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="owner が未設定（MIHARI_OWNER_ID）"
        )
    try:
        orchestrator.store.get(job_id)
    except JobNotFound as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない") from error
    if not _CANDIDATE_ID_RE.match(candidate_id or ""):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="候補がない")
    store = _memory_store_for_config(config)
    try:
        if approve:
            candidate = store.approve(job_id, candidate_id)
        else:
            candidate = store.reject(job_id, candidate_id)
    except ValueError as error:
        message = str(error)
        if "unknown candidate" in message or "unknown job" in message or "invalid job" in message:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="候補がない"
            ) from error
        if "already approved" in message or "already rejected" in message:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=message) from error
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=message) from error
    # 決定を日誌にも残す（SSE で desktop が拾える）。job は塞がない。
    try:
        journal = EventJournal.for_job(orchestrator.store.job_dir(job_id))
        from mihari_room.events import EventPhase, JournalKind

        journal.append(
            job_id=job_id,
            phase=EventPhase.WAITING,
            kind=JournalKind.LOG,
            text=("memory 候補を確定したよ。" if approve else "memory 候補を捨てたよ。"),
        )
    except Exception:
        pass
    return _candidate_to_dict(candidate)


def create_app(
    config: RoomConfig,
    orchestrator: RoomOrchestrator,
    *,
    discord_starter: Any = None,
    discord_stopper: Any = None,
    start_pump: bool = True,
) -> FastAPI:
    app = FastAPI(
        title="Mihari room",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=_lifespan,
    )
    app.state.config = config
    app.state.orchestrator = orchestrator
    app.state.discord_starter = discord_starter
    app.state.discord_stopper = discord_stopper
    app.state.start_pump = start_pump
    if orchestrator.publisher is None:
        orchestrator.attach_publisher(
            ArtifactPublisher(root=config.root, preview_base_url=config.preview_base_url)
        )

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    # --- ペットの依頼 ------------------------------------------------------

    @app.post("/jobs", dependencies=[Depends(verify_token)])
    async def create_job(request: Request, body: JobCreateBody) -> JobCreateResponse:
        title = derive_title(body.title, body.body)
        job_request = CreateJobRequest(
            title=title,
            body=body.body,
            source=body.source,
            requested_by=body.requested_by,
        )
        try:
            job = await request.app.state.orchestrator.submit(job_request)
        except RuntimeError as error:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(error)
            ) from error
        return JobCreateResponse(
            job_id=job.id,
            thread_id=job.thread_id,
            status=job.status.value,
        )

    # 可変ルート `/jobs/{job_id}` より先に定義する（/jobs/running が奪われないように）。
    @app.get("/jobs/running", dependencies=[Depends(verify_token)])
    def list_running(request: Request) -> dict[str, Any]:
        orchestrator = request.app.state.orchestrator
        return {
            "jobs": [_job_detail(orchestrator, job) for job in orchestrator.store.list_running()]
        }

    @app.get("/jobs/{job_id}", dependencies=[Depends(verify_token)])
    def job_detail(request: Request, job_id: str) -> dict[str, Any]:
        orchestrator = request.app.state.orchestrator
        try:
            job = orchestrator.store.get(job_id)
        except JobNotFound as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない"
            ) from error
        return _job_detail(orchestrator, job)

    @app.post("/jobs/{job_id}/followup", dependencies=[Depends(verify_token)])
    async def job_followup(request: Request, job_id: str, body: FollowupBody) -> JobCreateResponse:
        if not body.body.strip():
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="続きを書いて")
        orchestrator = request.app.state.orchestrator
        try:
            job = await orchestrator.follow_up_job(
                job_id, body.body, requested_by=body.requested_by
            )
        except JobNotFound as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない"
            ) from error
        return JobCreateResponse(
            job_id=job.id,
            thread_id=job.thread_id,
            status=job.status.value,
        )

    @app.post("/jobs/{job_id}/cancel", dependencies=[Depends(verify_token)])
    async def cancel_job(
        request: Request, job_id: str, body: CancelBody | None = None
    ) -> JobCreateResponse:
        payload = body or CancelBody()
        by = payload.by or request.app.state.config.owner_id
        if not by:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="誰が止めるかを書いて"
            )
        try:
            job = await request.app.state.orchestrator.cancel(job_id, by=by)
        except JobNotFound as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない"
            ) from error
        except CancelNotAllowed as error:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
        return JobCreateResponse(
            job_id=job.id,
            thread_id=job.thread_id,
            status=job.status.value,
        )

    # --- イベントの SSE ------------------------------------------------------

    @app.get("/jobs/{job_id}/events", dependencies=[Depends(verify_token)])
    async def job_events(
        request: Request,
        job_id: str,
        last_event_id: str | None = Header(default=None, alias="Last-Event-ID"),
    ) -> StreamingResponse:
        orchestrator = request.app.state.orchestrator
        try:
            orchestrator.store.get(job_id)
        except JobNotFound as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない"
            ) from error
        replay_from = parse_last_event_id(last_event_id)
        stream = _job_events_stream(
            orchestrator,
            job_id,
            replay_from,
            POLL_INTERVAL_SEC,
            HEARTBEAT_INTERVAL_SEC,
            TERMINAL_HOLD_SEC,
        )
        return StreamingResponse(
            stream,
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )

    # --- memory 承認（owner の明示承認。body の身分は使わない） ------------------

    @app.get("/jobs/{job_id}/memory", dependencies=[Depends(verify_token)])
    def job_memory(request: Request, job_id: str) -> dict[str, Any]:
        orchestrator = request.app.state.orchestrator
        config = request.app.state.config
        try:
            orchestrator.store.get(job_id)
        except JobNotFound as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない"
            ) from error
        store = _memory_store_for_config(config)
        try:
            candidates = store.list(job_id)
        except ValueError as error:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
        return {
            "candidates": [
                {
                    "id": c.id,
                    "target": c.target,
                    "content": c.content,
                    "status": c.status,
                    "created_at": c.created_at,
                }
                for c in candidates
            ]
        }

    @app.post("/jobs/{job_id}/memory/{candidate_id}/approve", dependencies=[Depends(verify_token)])
    async def job_memory_approve(
        request: Request, job_id: str, candidate_id: str
    ) -> dict[str, Any]:
        return await _memory_decide(request, job_id, candidate_id, approve=True)

    @app.post("/jobs/{job_id}/memory/{candidate_id}/reject", dependencies=[Depends(verify_token)])
    async def job_memory_reject(request: Request, job_id: str, candidate_id: str) -> dict[str, Any]:
        return await _memory_decide(request, job_id, candidate_id, approve=False)

    # --- プレビュー（未認証・安全ヘッダ付き） --------------------------------

    @app.get("/previews/{token}")
    def preview_index(token: str) -> Response:
        return _serve_preview(config, token, "index.html")

    @app.get("/previews/{token}/{rest:path}")
    def preview_file(token: str, rest: str) -> Response:
        return _serve_preview(config, token, rest)

    return app
