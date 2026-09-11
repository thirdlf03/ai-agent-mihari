"""Room ↔ クライアントの音声 Realtime 線上契約（desktop 共有）。

OpenAI Realtime そのものではなく、room が公開する HTTP/WS のイベント名。
"""

from __future__ import annotations

from enum import StrEnum
from typing import Any

#: 契約版。互換のない変更で上げる。
PROTOCOL_VERSION = 1

#: デモ用ツール。接続検証で function_call が返ることを確認する。
DEMO_TOOL_NAME = "echo_phrase"

DEMO_TOOL: dict[str, Any] = {
    "type": "function",
    "name": DEMO_TOOL_NAME,
    "description": "短いフレーズをそのまま返す（接続検証用）。",
    "parameters": {
        "type": "object",
        "properties": {
            "phrase": {"type": "string", "description": "返す短いフレーズ"},
        },
        "required": ["phrase"],
    },
}


class SessionStatus(StrEnum):
    """セッションの寿命。"""

    CREATED = "created"
    STREAMING = "streaming"
    CLOSED = "closed"
    ERROR = "error"


# --- クライアント → room ---------------------------------------------------

EVENT_INPUT_AUDIO = "input.audio"
EVENT_INPUT_IMAGE = "input.image"

# --- room → クライアント ---------------------------------------------------

EVENT_SESSION_READY = "session.ready"
EVENT_HISTORY_SYNC = "history.sync"
EVENT_ASSISTANT_TEXT = "assistant.text"
EVENT_ASSISTANT_TOOL_CALL = "assistant.tool_call"
EVENT_USER_TEXT = "user.text"
EVENT_ERROR = "error"
EVENT_SESSION_CLOSED = "session.closed"


def client_event(type_name: str, **fields: Any) -> dict[str, Any]:
    """room → クライアントの JSON フレーム。"""
    return {"type": type_name, **fields}


def error_event(message: str, *, code: str = "voice_error") -> dict[str, Any]:
    return client_event(EVENT_ERROR, code=code, message=message)


def session_ready_event(
    *, session_id: str, model: str, resumed: bool = False
) -> dict[str, Any]:
    return client_event(
        EVENT_SESSION_READY,
        session_id=session_id,
        model=model,
        protocol_version=PROTOCOL_VERSION,
        output_modalities=["text"],
        resumed=resumed,
    )


def history_sync_event(*, messages: list[dict[str, Any]]) -> dict[str, Any]:
    return client_event(EVENT_HISTORY_SYNC, messages=messages)


def assistant_text_event(*, text: str = "", delta: str = "", done: bool = False) -> dict[str, Any]:
    payload: dict[str, Any] = {"done": done}
    if delta:
        payload["delta"] = delta
    if text:
        payload["text"] = text
    return client_event(EVENT_ASSISTANT_TEXT, **payload)


def assistant_tool_call_event(
    *, name: str, call_id: str, arguments: str
) -> dict[str, Any]:
    return client_event(
        EVENT_ASSISTANT_TOOL_CALL,
        name=name,
        call_id=call_id,
        arguments=arguments,
    )


def user_text_event(*, text: str) -> dict[str, Any]:
    """入力音声の文字起こし結果。クライアントはユーザーターンの表示に使う。"""
    return client_event(EVENT_USER_TEXT, text=text)


def session_closed_event(*, reason: str = "") -> dict[str, Any]:
    return client_event(EVENT_SESSION_CLOSED, reason=reason)
