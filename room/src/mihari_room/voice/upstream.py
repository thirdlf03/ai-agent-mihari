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
from mihari_room.voice.tools import VOICE_TOOL_SCHEMAS

logger = logging.getLogger("mihari_room.voice")

REALTIME_WS_BASE = "wss://api.openai.com/v1/realtime"

#: テキストモード（Realtime）のセッション指示。みはりペルソナ + ツール運用ルール。
REALTIME_INSTRUCTIONS = (
    "あなたはデスクトップペットの女の子「みはり」。"
    "部屋（作業デーモン）の受付として、依頼主と日本語で会話する。\n\n"
    "## 口調\n"
    "- 一人称は「私」、相手は「あなた」と呼ぶ。相手の名前は呼ばない。\n"
    "- 敬語ではなく短いタメ口。1〜2 文・30 文字程度の短いセリフで返す。\n"
    "- 出力はテキストのみ。読み上げは別系統（VOICEVOX）が行うので、"
    "読み方の指定や前置きは書かない。\n\n"
    "## ツール\n"
    "- 仕事を頼まれたら submit_job で部屋のキューへ登録し、"
    "結果（job_id 等）を踏まえて短く報告する。\n"
    "- 実行中の仕事への追加指示は steer_job、状態確認は "
    "get_job_status / list_running_jobs を使う。\n"
    "- 画面を見る必要があるときだけ capture_screen を使う。"
    "撮影は client 側で行われ、画像は別メッセージで届く。\n"
    "- Discord の過去ログを聞かれたら discord_*、"
    "ユーザーの Mac のファイルは mac_* を使う。\n"
    "- ツール結果が success:false なら失敗を隠さず、理由を短く伝える。"
)

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


def session_update_event(
    model: str,
    *,
    tools: list[dict[str, Any]] | None = None,
    instructions: str | None = None,
) -> dict[str, Any]:
    """テキスト出力のみ・手動ターン制御・入力音声の文字起こし有効。

    ``tools`` 指定時は ``tool_choice: "auto"`` を付ける（省略時は接続検証用の
    ``DEMO_TOOL`` のみ、tool_choice なし）。
    """
    session: dict[str, Any] = {
        "type": "realtime",
        "model": model,
        "output_modalities": ["text"],
        "tools": list(tools) if tools is not None else [DEMO_TOOL],
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
    }
    if tools:
        session["tool_choice"] = "auto"
    if instructions is not None:
        session["instructions"] = instructions
    return {"type": "session.update", "session": session}


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
        await self.send(
            session_update_event(
                self._model,
                tools=VOICE_TOOL_SCHEMAS,
                instructions=REALTIME_INSTRUCTIONS,
            )
        )

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
        await self.send(
            session_update_event(
                "gpt-realtime-2.1-mini",
                tools=VOICE_TOOL_SCHEMAS,
                instructions=REALTIME_INSTRUCTIONS,
            )
        )
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
            if raw == b"tool" or raw.startswith(b"tool:"):
                # b"tool" → list_running_jobs、b"tool:<name>" → 指定ツール。
                name = raw.partition(b":")[2].decode() or "list_running_jobs"
                await self._emit_tool_call(name, "{}", "call_test_1")
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
                    # "__tool__" → capture_screen、"__tool__:<name>" → 指定ツール。
                    name = "capture_screen"
                    if "__tool__:" in prompt:
                        name = prompt.split("__tool__:", 1)[1].strip() or "capture_screen"
                    arguments = (
                        json.dumps({"prompt": prompt}, ensure_ascii=False)
                        if name == "capture_screen"
                        else "{}"
                    )
                    await self._emit_tool_call(name, arguments, "call_test_2")
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

    async def _emit_tool_call(
        self, name: str, arguments: str, call_id: str
    ) -> None:
        await self._queue.put(
            {
                "type": "response.done",
                "response": {
                    "status": "completed",
                    "output": [
                        {
                            "type": "function_call",
                            "name": name,
                            "call_id": call_id,
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
