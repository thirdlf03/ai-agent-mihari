"""Voice Realtime の HTTP/WS ルート。"""

from __future__ import annotations

import base64
import logging
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, WebSocket, status
from pydantic import BaseModel

from mihari_room.auth import verify_token, verify_ws_token
from mihari_room.voice.live_upstream import OpenAILiveUpstream, live_responses_delegation
from mihari_room.voice.protocol import PROTOCOL_VERSION
from mihari_room.voice.sessions import (
    SESSION_ID_PATTERN,
    ConcurrentVoiceSessionError,
    VoiceSessionManager,
)
from mihari_room.voice.stream import UpstreamFactory, handle_voice_stream
from mihari_room.voice.tools import VoiceToolExecutor
from mihari_room.voice.upstream import OpenAIRealtimeUpstream, RealtimeUpstream

logger = logging.getLogger("mihari_room.voice")

#: HTTP 委譲（voice gateway）向けに保持する session executor 数の上限。
#: 超えた分は古い順に close して畳む（DELETE が来ないまま増え続ける漏れ対策）。
_MAX_TOOL_EXECUTORS = 16


class VoiceToolExecuteBody(BaseModel):
    """``POST /voice/tools/execute`` の body。``arguments`` は JSON 文字列。"""

    session_id: str
    name: str
    arguments: str = ""


def _tool_executors(request: Request) -> dict[str, Any]:
    """app.state 上の session_id → executor 表。無ければ作る。"""
    executors = getattr(request.app.state, "voice_tool_executors", None)
    if executors is None:
        executors = {}
        request.app.state.voice_tool_executors = executors
    return executors


async def _close_tool_executor(executor: Any) -> None:
    """executor の close() を安全に呼ぶ（無い・失敗しても握りつぶす）。"""
    close = getattr(executor, "close", None)
    if not callable(close):
        return
    try:
        await close()
    except Exception:
        logger.debug("voice tool executor close failed", exc_info=True)


def _voice_unavailable() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail="OpenAI Realtime が未設定（room の OPENAI_API_KEY / MIHARI_OPENAI_API_KEY）",
    )


def build_voice_router(
    *,
    upstream_factory: UpstreamFactory | None = None,
) -> APIRouter:
    router = APIRouter(prefix="/voice", tags=["voice"])

    @router.post("/sessions", dependencies=[Depends(verify_token)])
    def create_voice_session(request: Request) -> dict[str, Any]:
        manager: VoiceSessionManager = request.app.state.voice
        if not manager.voice_enabled():
            raise _voice_unavailable()
        try:
            session = manager.create_session()
        except ConcurrentVoiceSessionError as error:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=str(error),
            ) from error
        return {
            "session_id": session.id,
            "model": session.model,
            "status": session.status.value,
            "protocol_version": PROTOCOL_VERSION,
            "stream_path": f"/voice/sessions/{session.id}/stream",
        }

    @router.get("/sessions/{session_id}", dependencies=[Depends(verify_token)])
    def get_voice_session(request: Request, session_id: str) -> dict[str, Any]:
        manager: VoiceSessionManager = request.app.state.voice
        session = manager.get(session_id)
        if session is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="session not found")
        return session.to_dict()

    @router.get("/sessions/{session_id}/history", dependencies=[Depends(verify_token)])
    def get_voice_session_history(request: Request, session_id: str) -> dict[str, Any]:
        manager: VoiceSessionManager = request.app.state.voice
        session = manager.get(session_id)
        if session is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="session not found")
        return {
            "session_id": session_id,
            "messages": manager.history_to_dicts(session_id),
        }

    @router.post("/sessions/{session_id}/close", dependencies=[Depends(verify_token)])
    def close_voice_session(request: Request, session_id: str) -> dict[str, Any]:
        manager: VoiceSessionManager = request.app.state.voice
        session = manager.get(session_id)
        if session is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="session not found")
        manager.close_session(session_id)
        return {"session_id": session_id, "status": "closed"}

    @router.post("/tools/execute", dependencies=[Depends(verify_token)])
    async def execute_voice_tool(
        request: Request, body: VoiceToolExecuteBody
    ) -> dict[str, Any]:
        """voice gateway から委譲されたツール 1 件を session 単位の executor で実行。

        Mac run の begin/end を整合させるため executor は session_id ごとに
        使い回し、``DELETE /tools/execute/{session_id}`` で畳む。
        """
        session_id = body.session_id.strip()
        if not SESSION_ID_PATTERN.match(session_id):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="session_id が不正"
            )
        name = body.name.strip()
        if not name:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="name が空"
            )
        executors = _tool_executors(request)
        executor = executors.get(session_id)
        if executor is None:
            executor = VoiceToolExecutor(
                session_id=session_id,
                manager=request.app.state.voice,
                orchestrator=getattr(request.app.state, "orchestrator", None),
                mac_hub=getattr(request.app.state, "mac_control", None),
                interactions=getattr(request.app.state, "job_interactions", None),
                config=request.app.state.config,
            )
            executors[session_id] = executor
            while len(executors) > _MAX_TOOL_EXECUTORS:
                stale_id = next(iter(executors))
                await _close_tool_executor(executors.pop(stale_id))
        outcome = await executor.execute(name, body.arguments)
        return {
            "output": outcome.output,
            "ok": outcome.ok,
            "client_side": outcome.client_side,
            "image_base64": (
                base64.b64encode(outcome.image_png).decode()
                if outcome.image_png
                else None
            ),
        }

    @router.delete("/tools/execute/{session_id}", dependencies=[Depends(verify_token)])
    async def close_voice_tool_executor(
        request: Request, session_id: str
    ) -> dict[str, Any]:
        """session の executor を畳む。既に無くても冪等に closed を返す。"""
        executor = _tool_executors(request).pop(session_id, None)
        if executor is not None:
            await _close_tool_executor(executor)
        return {"session_id": session_id, "status": "closed"}

    @router.websocket("/sessions/{session_id}/stream")
    async def voice_stream(websocket: WebSocket, session_id: str) -> None:
        config = websocket.app.state.config
        if not verify_ws_token(websocket, config.token):
            await websocket.close(code=4401)
            return
        manager: VoiceSessionManager = websocket.app.state.voice
        if not manager.voice_enabled():
            await websocket.close(code=4503)
            return
        await websocket.accept()
        factory: UpstreamFactory = (
            upstream_factory
            or getattr(websocket.app.state, "voice_upstream_factory", None)
            or _default_upstream_factory_from_app(websocket)
        )
        await handle_voice_stream(
            websocket,
            session_id=session_id,
            manager=manager,
            upstream_factory=factory,
            orchestrator=getattr(websocket.app.state, "orchestrator", None),
            mac_hub=getattr(websocket.app.state, "mac_control", None),
            interactions=getattr(websocket.app.state, "job_interactions", None),
            tool_executor_factory=getattr(
                websocket.app.state, "voice_tool_executor_factory", None
            ),
        )

    return router


def _default_upstream_factory_from_app(websocket: WebSocket) -> UpstreamFactory:
    manager: VoiceSessionManager = websocket.app.state.voice
    config = manager.config

    def factory() -> RealtimeUpstream:
        if config.voice_output_mode == "live_audio":
            delegation = None
            if getattr(config, "live_delegation", False):
                delegation = live_responses_delegation(
                    model=config.live_delegation_model
                )
            return OpenAILiveUpstream(
                api_key=config.openai_api_key,
                model=config.live_model,
                voice=config.live_voice,
                delegation=delegation,
            )
        return OpenAIRealtimeUpstream(
            api_key=config.openai_api_key,
            model=config.voice_realtime_model,
        )

    return factory


def register_voice_routes(
    app: Any,
    *,
    upstream_factory: UpstreamFactory | None = None,
) -> VoiceSessionManager:
    """``create_app`` から voice を載せる。"""
    config = app.state.config
    manager = VoiceSessionManager(config)
    app.state.voice = manager
    if upstream_factory is not None:
        app.state.voice_upstream_factory = upstream_factory
    app.include_router(build_voice_router(upstream_factory=upstream_factory))
    return manager
