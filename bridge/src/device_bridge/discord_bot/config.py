"""Discord まわりの設定。

Bot トークンは認証情報なので `.env` からしか読まない。コードにも設定ファイルにも書かない。
Application ID(クライアント ID)は秘密ではないが、同じところで管理した方が迷わない。
"""

from __future__ import annotations

import os
from dataclasses import dataclass

#: Bot に必要な権限。招待 URL の permissions に載せる。
#: 「メッセージを送る」「ファイルを添付する」「チャンネルを見る」だけあればよい。
#: 過剰な権限を要求すると招待をためらわれるので、最小限にしている。
VIEW_CHANNEL = 1 << 10
SEND_MESSAGES = 1 << 11
ATTACH_FILES = 1 << 15
REQUIRED_PERMISSIONS = VIEW_CHANNEL | SEND_MESSAGES | ATTACH_FILES

#: 招待 URL に載せるスコープ。スラッシュコマンドを使うので applications.commands も要る。
REQUIRED_SCOPES = ("bot", "applications.commands")


@dataclass(frozen=True, slots=True)
class DiscordConfig:
    """`.env` から読んだ設定。

    :param token: Bot トークン。未設定なら空文字。
    :param client_id: Application ID。未設定なら空文字。
    """

    token: str = ""
    client_id: str = ""

    @classmethod
    def from_environment(cls) -> DiscordConfig:
        return cls(
            token=(os.environ.get("DISCORD_BOT_TOKEN") or "").strip(),
            client_id=(os.environ.get("DISCORD_CLIENT_ID") or "").strip(),
        )

    @property
    def has_token(self) -> bool:
        return bool(self.token)

    @property
    def has_client_id(self) -> bool:
        return bool(self.client_id)

    @property
    def missing(self) -> list[str]:
        """足りていない設定の名前。UI に「何をすればよいか」を出すために使う。"""
        names: list[str] = []
        if not self.has_token:
            names.append("DISCORD_BOT_TOKEN")
        if not self.has_client_id:
            names.append("DISCORD_CLIENT_ID")
        return names
