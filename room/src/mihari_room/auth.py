"""HTTP の合言葉。ペットと同じ `X-Mihari-Token`。"""

from __future__ import annotations

import hmac

from fastapi import Header, HTTPException, Request, status

from mihari_room.config import TOKEN_HEADER


def verify_token(request: Request, x_mihari_token: str | None = Header(default=None)) -> None:
    expected: str = request.app.state.config.token
    if x_mihari_token is None or not hmac.compare_digest(x_mihari_token, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"{TOKEN_HEADER} が正しくない",
        )
