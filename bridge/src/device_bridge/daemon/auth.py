"""トークンによる認証。

ループバックに縛っていても、同じ Mac 上の別プロセスからは叩けてしまう。
起動のたびに macOS アプリが生成したトークンを共有し、一致しない要求は弾く。
"""

from __future__ import annotations

import hmac

from fastapi import Header, HTTPException, Request, status

from device_bridge.daemon.config import TOKEN_HEADER


def verify_token(request: Request, x_mihari_token: str | None = Header(default=None)) -> None:
    """リクエストヘッダのトークンを検証する。

    :raises HTTPException: トークンが無い、または一致しないとき 401。
    """
    expected: str = request.app.state.config.token
    if x_mihari_token is None or not hmac.compare_digest(x_mihari_token, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"{TOKEN_HEADER} が正しくない",
        )
