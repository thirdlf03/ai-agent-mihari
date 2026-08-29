"""OAuth2 の招待 URL を組み立てる。

ユーザーはこの URL を開いて、自分のサーバに Bot を入れる。
"""

from __future__ import annotations

from urllib.parse import urlencode

from device_bridge.discord_bot.config import REQUIRED_PERMISSIONS, REQUIRED_SCOPES

OAUTH_AUTHORIZE_URL = "https://discord.com/oauth2/authorize"


def invite_url(
    client_id: str,
    *,
    permissions: int = REQUIRED_PERMISSIONS,
    scopes: tuple[str, ...] = REQUIRED_SCOPES,
) -> str:
    """招待 URL を返す。

    :raises ValueError: ``client_id`` が空のとき。
    """
    if not client_id:
        raise ValueError("DISCORD_CLIENT_ID が未設定のため招待 URL を作れない")
    query = urlencode(
        {
            "client_id": client_id,
            "permissions": str(permissions),
            "scope": " ".join(scopes),
        }
    )
    return f"{OAUTH_AUTHORIZE_URL}?{query}"
