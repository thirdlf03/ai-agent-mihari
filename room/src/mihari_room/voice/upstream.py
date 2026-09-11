"""OpenAI Realtime upstream とテスト用フェイク。"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
from abc import ABC, abstractmethod
from collections.abc import AsyncIterator
from typing import Any

from mihari_room.voice.protocol import DEMO_TOOL

logger = logging.getLogger("mihari_room.voice")

REALTIME_WS_BASE = "wss://api.openai.com/v1/realtime"

#: モデル音声出力イベント。観測数 0 が「音声 OUT 課金なし」の目安。
UPSTREAM_AUDIO_OUTPUT_EVENTS = frozenset(
    {
        "response.output_audio.delta",
        "response.output_audio.done",
        "response.audio.delta",
        "response.audio.done",
    }
)


class RealtimeUpstream(ABC):
    """room が張る OpenAI Realtime 相当の 1 本。"""

    @abstractmethod
    async def connect(self) -> None:
        raise NotImplementedError

    @abstractmethod
    async def send(self, event: dict[str, Any]) -> None:
        raise NotImplementedError

    @abstractmethod
    async def receive(self) -> dict[str, Any]:
        raise NotImplementedError

    @abstractmethod
    async def close(self) -> None:
        raise NotImplementedError

    @abstractmethod
    def audio_output_events_seen(self) -> int:
        raise NotImplementedError


def session_update_event(*, model: str) -> dict[str, Any]:
    """テキスト出力のみ・手動ターン制御・入力音声の文字起こし有効。"""
    return {
        "type": "session.update",
        "session": {
            "type": "realtime",
            "model": model,
            "output_modalities": ["text"],
            "tools": [DEMO_TOOL],
            # GA の RealtimeSessionCreateRequest では音声入力の設定は audio.input 配下。
            # トップレベルの turn_detection は beta 時代の形で、置いても無視されうる。
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": 24000},
                    # server VAD を切り、クライアントの commit でターンを確定する。
                    "turn_detection": None,
                    # ユーザー発話の文字起こし。user.text 中継と履歴に使う。
                    "transcription": {"model": "gpt-4o-mini-transcribe"},
                },
            },
        },
    }


def response_create_event() -> dict[str, Any]:
    return {
        "type": "response.create",
        "response": {"output_modalities": ["text"]},
    }


class OpenAIRealtimeUpstream(RealtimeUpstream):
    """本物の OpenAI Realtime WebSocket。"""

    def __init__(self, *, api_key: str, model: str) -> None:
        self._api_key = api_key
        self._model = model
        self._ws: Any = None
        self._audio_output_events = 0

    async def connect(self) -> None:
        import websockets

        url = f"{REALTIME_WS_BASE}?model={self._model}"
        self._ws = await websockets.connect(
            url,
            additional_headers={"Authorization": f"Bearer {self._api_key}"},
            open_timeout=30,
        )
        await self.send(session_update_event(model=self._model))

    async def send(self, event: dict[str, Any]) -> None:
        if self._ws is None:
            raise RuntimeError("upstream not connected")
        await self._ws.send(json.dumps(event))

    async def receive(self) -> dict[str, Any]:
        if self._ws is None:
            raise RuntimeError("upstream not connected")
        raw = await self._ws.recv()
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", errors="replace")
        event = json.loads(raw)
        if not isinstance(event, dict):
            return {"type": "error", "error": {"message": "invalid upstream frame"}}
        event_type = event.get("type", "")
        if event_type in UPSTREAM_AUDIO_OUTPUT_EVENTS:
            self._audio_output_events += 1
            logger.warning("upstream audio output observed: %s", event_type)
        return event

    async def close(self) -> None:
        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None

    def audio_output_events_seen(self) -> int:
        return self._audio_output_events


class FakeRealtimeUpstream(RealtimeUpstream):
    """pytest 用。受信イベントに応じて決定的に応答する。"""

    def __init__(self) -> None:
        self._sent: list[dict[str, Any]] = []
        self._queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self._closed = False
        self._audio_output_events = 0
        self._connected = False

    async def connect(self) -> None:
        self._connected = True
        self._closed = False
        self._queue = asyncio.Queue()
        await self.send(session_update_event(model="gpt-realtime-2.1-mini"))
        await self._queue.put({"type": "session.created", "session": {"model": "fake"}})

    async def send(self, event: dict[str, Any]) -> None:
        if self._closed:
            return
        self._sent.append(event)
        event_type = event.get("type", "")
        if event_type == "session.update":
            return
        if event_type == "input_audio_buffer.append":
            audio = event.get("audio") or ""
            try:
                raw = base64.b64decode(audio, validate=True)
            except Exception:
                raw = b""
            if raw == b"tool":
                await self._emit_tool_call("audio-tool")
            elif raw == b"audio-out-probe":
                await self._emit_upstream_audio_output_probe()
                await self._emit_text("text-only")
            else:
                await self._emit_text("heard-audio")
            return
        if event_type == "input_audio_buffer.commit":
            await self._queue.put(
                {
                    "type": "conversation.item.input_audio_transcription.completed",
                    "transcript": "こんにちは",
                }
            )
            return
        if event_type == "conversation.item.create":
            item = event.get("item") or {}
            content = item.get("content") or []
            if any(part.get("type") == "input_image" for part in content):
                prompt = ""
                for part in content:
                    if part.get("type") == "input_text":
                        prompt = str(part.get("text") or "")
                if "__tool__" in prompt:
                    await self._emit_tool_call("image-tool")
                else:
                    await self._emit_text("saw-image")
            return

    async def receive(self) -> dict[str, Any]:
        if self._closed:
            raise RuntimeError("upstream closed")
        if not self._connected:
            raise RuntimeError("upstream not connected")
        return await self._queue.get()

    async def close(self) -> None:
        self._closed = True
        try:
            self._queue.put_nowait({"type": "session.closed"})
        except asyncio.QueueFull:
            pass

    def audio_output_events_seen(self) -> int:
        return self._audio_output_events

    def sent_events(self) -> list[dict[str, Any]]:
        return list(self._sent)

    async def _emit_text(self, text: str) -> None:
        await self._queue.put({"type": "response.output_text.delta", "delta": text})
        await self._queue.put({"type": "response.output_text.done", "text": text})
        await self._queue.put(
            {
                "type": "response.done",
                "response": {
                    "status": "completed",
                    "output": [
                        {
                            "type": "message",
                            "content": [{"type": "output_text", "text": text}],
                        }
                    ],
                },
            }
        )

    async def _emit_upstream_audio_output_probe(self) -> None:
        """pytest 用。upstream が音声 OUT を返した場合の観測・非 relay を検証する。"""
        for event_type in ("response.output_audio.delta", "response.output_audio.done"):
            await self._queue.put({"type": event_type, "delta": "probe"})

    async def _emit_tool_call(self, phrase: str) -> None:
        arguments = json.dumps({"phrase": phrase}, ensure_ascii=False)
        await self._queue.put(
            {
                "type": "response.done",
                "response": {
                    "status": "completed",
                    "output": [
                        {
                            "type": "function_call",
                            "name": "echo_phrase",
                            "call_id": "call_test_1",
                            "arguments": arguments,
                        }
                    ],
                },
            }
        )


async def iter_upstream_events(upstream: RealtimeUpstream) -> AsyncIterator[dict[str, Any]]:
    """upstream 受信を async for 向けにラップ。"""
    while True:
        yield await upstream.receive()
