"""作業部屋デーモンの起動設定。VPS でも手元でも同じ。"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from mihari_room.contracts import AUTH_HEADER

#: ペットと同じヘッダ名。
TOKEN_HEADER = AUTH_HEADER

#: ペットの既定と揃える。
DEFAULT_PORT = 8787


@dataclass(frozen=True, slots=True)
class RoomConfig:
    """部屋 1 プロセス分。トークンが空なら HTTP は立てられない。"""

    token: str
    root: Path
    host: str = "127.0.0.1"
    port: int = DEFAULT_PORT
    forum_channel_id: int | None = None
    discord_token: str = ""
    owner_id: str = ""
    #: プレビューの公開 URL の土台。空の間は成果物の公開を無効にする。
    preview_base_url: str = ""

    @classmethod
    def from_environment(cls) -> RoomConfig:
        token = (os.environ.get("MIHARI_ROOM_TOKEN") or "").strip()
        raw_root = os.environ.get("MIHARI_ROOM_ROOT") or (Path.home() / "mihari-room")
        # 相対 root はデーモン全体の chdir（job cwd 運用）に弱いので絶対化する。
        root = Path(raw_root).expanduser().resolve()
        host = (os.environ.get("MIHARI_ROOM_HOST") or "127.0.0.1").strip()
        port_raw = (os.environ.get("MIHARI_ROOM_PORT") or str(DEFAULT_PORT)).strip()
        forum_raw = (os.environ.get("MIHARI_FORUM_CHANNEL_ID") or "").strip()
        discord_token = (os.environ.get("DISCORD_BOT_TOKEN") or "").strip()
        owner_id = (os.environ.get("MIHARI_OWNER_ID") or "").strip()
        preview_base_url = (os.environ.get("MIHARI_PREVIEW_BASE_URL") or "").strip()
        try:
            port = int(port_raw)
        except ValueError as error:
            raise ValueError(f"MIHARI_ROOM_PORT が数字ではない: {port_raw}") from error
        forum_channel_id = int(forum_raw) if forum_raw else None
        return cls(
            token=token,
            root=root,
            host=host,
            port=port,
            forum_channel_id=forum_channel_id,
            discord_token=discord_token,
            owner_id=owner_id,
            preview_base_url=preview_base_url,
        )

    def __post_init__(self) -> None:
        if not self.token:
            raise ValueError("MIHARI_ROOM_TOKEN は空にできない")
        if not 0 <= self.port <= 65535:
            raise ValueError(f"port が範囲外: {self.port}")
        base = self.preview_base_url
        if base and not (base.startswith("http://") or base.startswith("https://")):
            raise ValueError("MIHARI_PREVIEW_BASE_URL は http(s):// で始めて")
