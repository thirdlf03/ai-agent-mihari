"""HTTP の合言葉。ペットと同じ `X-Mihari-Token`。"""

from __future__ import annotations

import hmac

from fastapi import Header, HTTPException, Request, WebSocket, status

from mihari_room.config import TOKEN_HEADER


def ws_token_candidate(websocket: WebSocket) -> str:
    """WebSocket の合言葉。ヘッダ優先、無ければ query ``token``。"""
    raw_header = websocket.headers.get(TOKEN_HEADER.lower()) or ""
    raw_query = websocket.query_params.get("token") or ""
    return raw_header or raw_query


def verify_ws_token(websocket: WebSocket, expected: str) -> bool:
    """WebSocket 接続前の合言葉検証。Mac 操作 WS と同じ 4401 で拒否する。"""
    candidate = ws_token_candidate(websocket)
    return bool(candidate) and hmac.compare_digest(candidate, expected)


def verify_token(request: Request, x_mihari_token: str | None = Header(default=None)) -> None:
    expected: str = request.app.state.config.token
    if x_mihari_token is None or not hmac.compare_digest(x_mihari_token, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"{TOKEN_HEADER} が正しくない",
        )
