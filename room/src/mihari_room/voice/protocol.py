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
#: live_audio モードの音声出力。PCM16 24kHz mono の base64（input.audio と対称）。
EVENT_ASSISTANT_AUDIO = "assistant.audio"
EVENT_ASSISTANT_TOOL_CALL = "assistant.tool_call"
#: room 側で実行したツールの結果通知（status: "running" / "done" / "failed"）。
#: client 実行のツール（capture_screen）は従来どおり assistant.tool_call で届く。
EVENT_ASSISTANT_TOOL_ACTIVITY = "assistant.tool_activity"
EVENT_USER_TEXT = "user.text"
#: live_audio で入力音声は upstream へ届いたが文字起こしが一度も来なかった
#: ターンの通知。desktop は「（音声を送信）」プレースホルダを明示表示へ置き換える。
EVENT_USER_TRANSCRIPT_NONE = "user.transcript_none"
EVENT_ERROR = "error"
EVENT_SESSION_CLOSED = "session.closed"


def client_event(type_name: str, **fields: Any) -> dict[str, Any]:
    """room → クライアントの JSON フレーム。"""
    return {"type": type_name, **fields}


def error_event(message: str, *, code: str = "voice_error") -> dict[str, Any]:
    return client_event(EVENT_ERROR, code=code, message=message)


def session_ready_event(
    *,
    session_id: str,
    model: str,
    resumed: bool = False,
    output_modalities: list[str] | None = None,
) -> dict[str, Any]:
    return client_event(
        EVENT_SESSION_READY,
        session_id=session_id,
        model=model,
        protocol_version=PROTOCOL_VERSION,
        output_modalities=output_modalities or ["text"],
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


def assistant_tool_call_event(*, name: str, call_id: str, arguments: str) -> dict[str, Any]:
    return client_event(
        EVENT_ASSISTANT_TOOL_CALL,
        name=name,
        call_id=call_id,
        arguments=arguments,
    )


def assistant_tool_activity_event(
    *, name: str, call_id: str, status: str
) -> dict[str, Any]:
    """room 実行ツールの活動通知。tool_call と違い client は実行しない。"""
    return client_event(
        EVENT_ASSISTANT_TOOL_ACTIVITY,
        name=name,
        call_id=call_id,
        status=status,
    )


def assistant_audio_event(*, audio_b64: str = "", done: bool = False) -> dict[str, Any]:
    """live_audio モードの音声出力チャンク。done=True は 1 発話分の終端。"""
    payload: dict[str, Any] = {"done": done}
    if audio_b64:
        payload["audio_base64"] = audio_b64
    return client_event(EVENT_ASSISTANT_AUDIO, **payload)


def user_text_event(*, text: str, delta: str = "", done: bool | None = None) -> dict[str, Any]:
    """入力音声の文字起こし結果。クライアントはユーザーターンの表示に使う。

    live_audio モードでは断片（``delta`` + 累積 ``text``）を逐次送り、
    ターン確定時に ``done=True`` を付ける。text モードでは従来どおり
    ``text`` のみの完成形で 1 度だけ送る。
    """
    payload: dict[str, Any] = {"text": text}
    if delta:
        payload["delta"] = delta
    if done is not None:
        payload["done"] = done
    return client_event(EVENT_USER_TEXT, **payload)


def user_transcript_none_event() -> dict[str, Any]:
    """音声ターンがあったのに upstream が文字起こしを返さなかった通知。

    live_audio 専用。文字起こしが無いターンは履歴へも残せないため、
    履歴には記録せず desktop の表示解放だけに使う。
    """
    return client_event(EVENT_USER_TRANSCRIPT_NONE)


def session_closed_event(*, reason: str = "") -> dict[str, Any]:
    return client_event(EVENT_SESSION_CLOSED, reason=reason)
