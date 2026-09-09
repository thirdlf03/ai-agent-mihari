"""クライアント WS と Realtime upstream の双方向リレー。"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
from collections.abc import Callable
from typing import Any

from fastapi import WebSocket, WebSocketDisconnect

from mihari_room.voice.history import HistoryMessage
from mihari_room.voice.protocol import (
    EVENT_INPUT_AUDIO,
    EVENT_INPUT_IMAGE,
    SessionStatus,
    assistant_text_event,
    assistant_tool_call_event,
    error_event,
    history_sync_event,
    session_closed_event,
    session_ready_event,
)
from mihari_room.voice.sessions import VoiceSessionManager, VoiceStreamBusyError
from mihari_room.voice.upstream import (
    UPSTREAM_AUDIO_OUTPUT_EVENTS,
    RealtimeUpstream,
    response_create_event,
)

logger = logging.getLogger("mihari_room.voice")

UpstreamFactory = Callable[[], RealtimeUpstream]


async def handle_voice_stream(
    websocket: WebSocket,
    *,
    session_id: str,
    manager: VoiceSessionManager,
    upstream_factory: UpstreamFactory,
) -> None:
    """``/voice/sessions/{id}/stream`` の本体。"""
    session = manager.get(session_id)
    if session is None:
        await websocket.close(code=4404)
        return
    if session.status in {SessionStatus.CLOSED, SessionStatus.ERROR}:
        await websocket.close(code=4409)
        return

    try:
        await manager.acquire_stream(session_id)
    except VoiceStreamBusyError:
        await websocket.close(code=4409)
        return
    except KeyError:
        await websocket.close(code=4404)
        return

    upstream = upstream_factory()
    manager.mark_streaming(session_id)
    end_reason = "idle"
    history = manager.get_history(session_id)
    resumed = bool(history)

    async def send_client(frame: dict[str, Any]) -> None:
        await websocket.send_text(json.dumps(frame, ensure_ascii=False))

    try:
        await upstream.connect()
        if history:
            await _replay_history_to_upstream(upstream, history)
        await send_client(
            session_ready_event(session_id=session_id, model=session.model, resumed=resumed)
        )
        if history:
            await send_client(history_sync_event(messages=manager.history_to_dicts(session_id)))

        client_task = asyncio.create_task(
            _client_to_upstream(
                websocket,
                upstream,
                send_client,
                session_id=session_id,
                manager=manager,
            )
        )
        upstream_task = asyncio.create_task(
            _upstream_to_client(
                upstream,
                send_client,
                session_id=session_id,
                manager=manager,
            )
        )
        done, pending = await asyncio.wait(
            {client_task, upstream_task}, return_when=asyncio.FIRST_COMPLETED
        )
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        for task in done:
            exc = task.exception()
            if isinstance(exc, WebSocketDisconnect):
                end_reason = "client_disconnect"
            elif exc and not isinstance(exc, asyncio.CancelledError):
                logger.debug("voice stream task ended: %s", exc)
                end_reason = "error"
    except WebSocketDisconnect:
        end_reason = "client_disconnect"
    except Exception as error:
        logger.exception("voice stream failed for %s", session_id)
        end_reason = "error"
        manager.mark_closed(session_id, reason=str(error))
        try:
            await send_client(error_event(str(error)))
            await send_client(session_closed_event(reason=str(error)))
        except Exception:
            pass
    finally:
        await upstream.close()
        await manager.release_stream(session_id)
        current = manager.get(session_id)
        if current is None:
            return
        if end_reason in {"client_disconnect", "idle"}:
            manager.mark_idle(session_id)
        elif end_reason == "error":
            pass


async def _replay_history_to_upstream(
    upstream: RealtimeUpstream,
    messages: list[HistoryMessage],
) -> None:
    """切断復旧時、テキスト履歴だけ upstream コンテキストへ再注入する。"""
    for message in messages:
        if message.kind == "tool_call":
            continue
        text = message.text.strip()
        if not text:
            continue
        content_type = "input_text" if message.role == "user" else "output_text"
        await upstream.send(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": message.role,
                    "content": [{"type": content_type, "text": text}],
                },
            }
        )


async def _client_to_upstream(
    websocket: WebSocket,
    upstream: RealtimeUpstream,
    send_client: Any,
    *,
    session_id: str,
    manager: VoiceSessionManager,
) -> None:
    while True:
        message = await websocket.receive()
        if message.get("type") == "websocket.disconnect":
            raise WebSocketDisconnect()
        raw = message.get("text")
        if raw is None:
            continue
        try:
            frame = json.loads(raw)
        except (ValueError, TypeError):
            continue
        if not isinstance(frame, dict):
            continue
        frame_type = frame.get("type")
        try:
            if frame_type == EVENT_INPUT_AUDIO:
                await _forward_audio(frame, upstream)
            elif frame_type == EVENT_INPUT_IMAGE:
                await _forward_image(frame, upstream, session_id=session_id, manager=manager)
            else:
                await send_client(error_event(f"未知のイベント: {frame_type}", code="bad_event"))
        except (ValueError, binascii.Error) as error:
            await send_client(error_event(str(error), code="bad_payload"))


async def _forward_audio(frame: dict[str, Any], upstream: RealtimeUpstream) -> None:
    audio_b64 = frame.get("audio_base64") or frame.get("audio") or ""
    if not isinstance(audio_b64, str) or not audio_b64:
        raise ValueError("input.audio には audio_base64 が必要")
    # 形式チェックのみ。中身は OpenAI へそのまま渡し、ディスクには書かない。
    base64.b64decode(audio_b64, validate=True)
    await upstream.send({"type": "input_audio_buffer.append", "audio": audio_b64})
    if frame.get("commit", True):
        await upstream.send({"type": "input_audio_buffer.commit"})
    if frame.get("create_response", True):
        await upstream.send(response_create_event())


async def _forward_image(
    frame: dict[str, Any],
    upstream: RealtimeUpstream,
    *,
    session_id: str,
    manager: VoiceSessionManager,
) -> None:
    image_b64 = frame.get("image_base64") or frame.get("image") or ""
    media_type = frame.get("media_type") or "image/png"
    prompt = frame.get("prompt") or frame.get("text") or "Describe this image."
    if not isinstance(image_b64, str) or not image_b64:
        raise ValueError("input.image には image_base64 が必要")
    base64.b64decode(image_b64, validate=True)
    if not isinstance(media_type, str) or not media_type.startswith("image/"):
        raise ValueError("input.image の media_type が不正")
    manager.record_user_text(session_id, str(prompt), kind="image_prompt")
    content: list[dict[str, Any]] = [
        {
            "type": "input_image",
            "image_url": f"data:{media_type};base64,{image_b64}",
        },
        {"type": "input_text", "text": str(prompt)},
    ]
    await upstream.send(
        {
            "type": "conversation.item.create",
            "item": {"type": "message", "role": "user", "content": content},
        }
    )
    if frame.get("create_response", True):
        await upstream.send(response_create_event())


async def _upstream_to_client(
    upstream: RealtimeUpstream,
    send_client: Any,
    *,
    session_id: str,
    manager: VoiceSessionManager,
) -> None:
    while True:
        event = await upstream.receive()
        event_type = event.get("type", "")
        if event_type in UPSTREAM_AUDIO_OUTPUT_EVENTS:
            manager.note_upstream_audio_output(session_id)
        if event_type == "response.output_text.delta":
            delta = event.get("delta") or ""
            if delta:
                await send_client(assistant_text_event(delta=delta, done=False))
        elif event_type == "response.output_text.done":
            text = event.get("text") or ""
            if text:
                manager.record_assistant_text(session_id, str(text))
            await send_client(assistant_text_event(text=text, done=True))
        elif event_type == "response.done":
            await _emit_tool_calls(event, send_client, session_id=session_id, manager=manager)
        elif event_type == "error":
            message = _extract_error_message(event)
            await send_client(error_event(message, code="upstream_error"))
        elif event_type in {"session.updated", "session.created", "session.closed"}:
            if event_type == "session.closed":
                return
            continue


async def _emit_tool_calls(
    event: dict[str, Any],
    send_client: Any,
    *,
    session_id: str,
    manager: VoiceSessionManager,
) -> None:
    response = event.get("response") or {}
    output = response.get("output") or []
    if not isinstance(output, list):
        return
    for item in output:
        if not isinstance(item, dict):
            continue
        if item.get("type") != "function_call":
            continue
        name = str(item.get("name") or "")
        arguments = str(item.get("arguments") or "{}")
        manager.record_tool_call(session_id, name=name, arguments=arguments)
        await send_client(
            assistant_tool_call_event(
                name=name,
                call_id=str(item.get("call_id") or ""),
                arguments=arguments,
            )
        )


def _extract_error_message(event: dict[str, Any]) -> str:
    error = event.get("error")
    if isinstance(error, dict):
        return str(error.get("message") or error.get("code") or "upstream error")
    return str(error or "upstream error")
