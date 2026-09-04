"""作業部屋の HTTP。ペットの `POST /jobs` を受ける。"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Request, status
from pydantic import BaseModel

from mihari_room.auth import verify_token
from mihari_room.config import RoomConfig
from mihari_room.contracts import CreateJobRequest, JobSource
from mihari_room.discord.board import MAX_TITLE_LEN
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import CancelNotAllowed
from mihari_room.store.file_store import JobNotFound


class JobCreateBody(BaseModel):
    title: str = ""
    body: str = ""
    source: JobSource = JobSource.PET
    requested_by: str | None = None


class JobCreateResponse(BaseModel):
    job_id: str
    thread_id: int | None
    status: str


class CancelBody(BaseModel):
    by: str | None = None


def derive_title(title: str, body: str) -> str:
    """ペット側と同じ。空なら本文の先頭行、最大 100 文字。"""
    trimmed = title.strip()
    if trimmed:
        return trimmed[:MAX_TITLE_LEN]
    first = ""
    for line in body.splitlines():
        first = line.strip()
        break
    return first[:MAX_TITLE_LEN]


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

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

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

    return app
