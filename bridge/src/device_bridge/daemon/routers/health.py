"""デーモンの生死確認。"""

from __future__ import annotations

import os

from fastapi import APIRouter, Request

router = APIRouter(tags=["health"])


@router.get("/health")
def health(request: Request) -> dict[str, object]:
    """デーモンが応答できることと、いま何人が SSE を購読しているかを返す。

    macOS アプリはこれをポーリングして接続状態を出す。
    """
    return {
        "status": "ok",
        "pid": os.getpid(),
        "subscribers": request.app.state.events.subscriber_count,
    }
