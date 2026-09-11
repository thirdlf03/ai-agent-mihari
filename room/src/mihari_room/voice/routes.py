"""Voice Realtime の HTTP/WS ルート。"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, WebSocket, status

from mihari_room.auth import verify_token, verify_ws_token
from mihari_room.voice.protocol import PROTOCOL_VERSION
from mihari_room.voice.sessions import ConcurrentVoiceSessionError, VoiceSessionManager
from mihari_room.voice.stream import UpstreamFactory, handle_voice_stream
from mihari_room.voice.upstream import OpenAIRealtimeUpstream, RealtimeUpstream


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
        )

    return router


def _default_upstream_factory_from_app(websocket: WebSocket) -> UpstreamFactory:
    manager: VoiceSessionManager = websocket.app.state.voice
    config = manager.config

    def factory() -> RealtimeUpstream:
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
