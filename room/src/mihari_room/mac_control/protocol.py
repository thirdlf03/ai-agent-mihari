"""Room ↔ Mac の線上の約束（JSON テキストフレーム）。

- Mac が認証付き WebSocket ``/ws/mac-control`` を Room へ張る（発信は Mac 側）。
- フレームは ``{"type": ...}`` の JSON。未知の type は無視してよい。
- 操作（op）は 1 本ずつ。op_id で一意に識別し、同じ op_id は二度送らない。
- 座標は「その撮影画像のピクセル」。Mac が表示器の座標へ変換する。
  撮影結果に表示器 ID・画像サイズ・座標変換情報を載せ、操作時は撮影時の
  画面構成（expected）と突き合わせて古い画面構成による操作を拒否する。
"""

from __future__ import annotations

from enum import StrEnum
from typing import Any

#: 線上のプロトコル版。互換のない変更で上げる。
PROTOCOL_VERSION = 1

#: Mac 側の許可の取りうる値。
DECISION_ALLOW = "allow"
DECISION_DENY = "deny"

#: Mac が Room へ上げる状態変化。
STATE_LOCK = "lock"
STATE_UNLOCK = "unlock"
STATE_QUIT = "quit"
STATE_STOP = "stop"
STATE_REVOKE = "revoke"


class MacOpKind(StrEnum):
    """Room 専用ツールの操作種別。汎用 Computer Use ではない。"""

    CAPTURE = "capture"
    CLICK = "click"
    DOUBLE_CLICK = "double_click"
    DRAG = "drag"
    SCROLL = "scroll"
    TYPE_TEXT = "type_text"
    KEY = "key"
    ACTIVATE_APP = "activate_app"


#: Room → Mac のフレーム種別。
FRAME_PING = "ping"
FRAME_HELLO_ACK = "hello_ack"
FRAME_CONTROL_REQUEST = "control.request"
FRAME_OP = "op"
FRAME_CANCEL_RUN = "cancel_run"

#: Mac → Room のフレーム種別。
FRAME_HELLO = "hello"
FRAME_PONG = "pong"
FRAME_CONTROL_DECISION = "control.decision"
FRAME_OP_RESULT = "op.result"
FRAME_STATE = "state"
FRAME_DISPLAYS = "displays"

#: テキスト入力の上限。誤爆・巨大ペーストを防ぐ。
MAX_TEXT_CHARS = 4000
#: 座標の上限（px）。現実の Retina 複数画面より十分大きい。
MAX_COORD = 100_000
#: スクロール量の上限。
MAX_SCROLL_DELTA = 10_000
#: ボタン名。CGEvent の mouse ボタンに写す。
BUTTON_LEFT = "left"
BUTTON_RIGHT = "right"
BUTTON_MIDDLE = "middle"

#: キー名の allowlist。keycode は任意（Mac が仮想キーコードで解釈）。
ALLOWED_KEYS = frozenset(
    {
        "return",
        "escape",
        "tab",
        "space",
        "delete",
        "forward_delete",
        "up",
        "down",
        "left",
        "right",
        "home",
        "end",
        "page_up",
        "page_down",
        "command",
        "shift",
        "control",
        "option",
        "caps_lock",
        "fn",
    }
)

#: モディファイア名。
ALLOWED_MODIFIERS = frozenset({"command", "shift", "control", "option", "caps_lock", "fn"})


def validate_device_id(raw: Any) -> str:
    """端末 ID（Mac が永続化して持つ値）の形を検証する。"""
    token = str(raw or "").strip()
    if not token or len(token) > 128 or any(ord(ch) < 33 or ord(ch) > 126 for ch in token):
        raise ValueError("device_id が不正")
    return token


def validate_display_id(raw: Any) -> str:
    """表示器 ID。数値でも文字列でも受け、正規化して返す。"""
    if isinstance(raw, int):
        token = str(raw)
    else:
        token = str(raw or "").strip()
    if not token or len(token) > 64 or not token.isdigit():
        raise ValueError("display_id が不正")
    return token


def _require_number(value: Any, name: str, *, minimum: float, maximum: float) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{name} が不正")
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"{name} が不正") from None
    if number < minimum or number > maximum:
        raise ValueError(f"{name} が範囲外")
    return number


def validate_coord(value: Any, name: str = "座標") -> int:
    """画像ピクセル座標。非負の整数に丸めて返す。"""
    if isinstance(value, bool):
        raise ValueError(f"{name} が不正")
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"{name} が不正") from None
    if number < 0 or number > MAX_COORD:
        raise ValueError(f"{name} が範囲外")
    return int(round(number))


def validate_modifiers(raw: Any) -> list[str]:
    if raw in (None, "", []):
        return []
    if not isinstance(raw, list):
        raise ValueError("modifiers が不正")
    out: list[str] = []
    for item in raw:
        token = str(item or "").strip().lower()
        if token not in ALLOWED_MODIFIERS:
            raise ValueError(f"modifier が不正: {token}")
        if token not in out:
            out.append(token)
    return out


def sanitize_op_params(kind: str, params: dict[str, Any]) -> dict[str, Any]:
    """履歴・ログに残す操作パラメータ。秘密（入力文そのまま）は載せない。"""
    kind_name = str(kind or "")
    safe: dict[str, Any] = {}
    if kind_name in (MacOpKind.CLICK, MacOpKind.DOUBLE_CLICK):
        for key in ("display_id", "x", "y", "button"):
            if params.get(key) is not None:
                safe[key] = params.get(key)
    elif kind_name == MacOpKind.DRAG:
        for key in ("display_id", "from_x", "from_y", "to_x", "to_y", "button"):
            if params.get(key) is not None:
                safe[key] = params.get(key)
    elif kind_name == MacOpKind.SCROLL:
        for key in ("display_id", "x", "y", "delta_x", "delta_y"):
            if params.get(key) is not None:
                safe[key] = params.get(key)
    elif kind_name == MacOpKind.TYPE_TEXT:
        text = str(params.get("text") or "")
        safe["text_len"] = len(text)
        safe["preview"] = text[:40] + ("..." if len(text) > 40 else "")
    elif kind_name == MacOpKind.KEY:
        if params.get("key") is not None:
            safe["key"] = params["key"]
        if params.get("keycode") is not None:
            safe["keycode"] = params["keycode"]
        if params.get("modifiers") is not None:
            safe["modifiers"] = params["modifiers"]
    elif kind_name == MacOpKind.ACTIVATE_APP:
        if params.get("bundle_id") is not None:
            safe["bundle_id"] = params["bundle_id"]
        if params.get("app_name") is not None:
            safe["app_name"] = params["app_name"]
    elif kind_name == MacOpKind.CAPTURE:
        if params.get("display_id") is not None:
            safe["display_id"] = params["display_id"]
    return safe


def describe_op(kind: str, params: dict[str, Any]) -> str:
    """進捗ログ用の短い説明。秘密は載せない。"""
    safe = sanitize_op_params(kind, params)
    kind_label = {
        MacOpKind.CAPTURE: "撮影",
        MacOpKind.CLICK: "クリック",
        MacOpKind.DOUBLE_CLICK: "ダブルクリック",
        MacOpKind.DRAG: "ドラッグ",
        MacOpKind.SCROLL: "スクロール",
        MacOpKind.TYPE_TEXT: "文字入力",
        MacOpKind.KEY: "キー操作",
        MacOpKind.ACTIVATE_APP: "アプリ切り替え",
    }.get(str(kind), str(kind))
    if kind_label == "文字入力":
        length = safe.get("text_len", 0)
        preview = safe.get("preview") or ""
        return f"文字入力（{length} 文字{('、先頭: ' + preview) if preview else ''}）"
    pieces: list[str] = []
    for key, label in (
        ("display_id", "表示器"),
        ("x", "x"),
        ("y", "y"),
        ("from_x", "from_x"),
        ("from_y", "from_y"),
        ("to_x", "to_x"),
        ("to_y", "to_y"),
        ("key", "キー"),
        ("keycode", "keycode"),
        ("bundle_id", "アプリ"),
        ("app_name", "アプリ名"),
        ("button", "ボタン"),
    ):
        if safe.get(key) is not None:
            pieces.append(f"{label}={safe[key]}")
    if safe.get("delta_y") is not None:
        pieces.append(f"dy={safe['delta_y']}")
    if safe.get("delta_x") is not None:
        pieces.append(f"dx={safe['delta_x']}")
    if safe.get("modifiers"):
        pieces.append(f"mod={','.join(safe['modifiers'])}")
    suffix = f"（{', '.join(pieces)}）" if pieces else ""
    return kind_label + suffix
