"""投稿先チャンネルの保存。

Bot トークンと違って秘密ではないので、素直にファイルに置く。
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

DEFAULT_DIRECTORY = "~/.mihari"
SETTINGS_FILE = "discord.json"


@dataclass(frozen=True, slots=True)
class ChannelSelection:
    """投稿先として選んだチャンネル。"""

    guild_id: int
    channel_id: int
    guild_name: str = ""
    channel_name: str = ""

    def to_dict(self) -> dict[str, object]:
        return {
            "guild_id": self.guild_id,
            "channel_id": self.channel_id,
            "guild_name": self.guild_name,
            "channel_name": self.channel_name,
        }

    @classmethod
    def from_dict(cls, payload: dict[str, object]) -> ChannelSelection | None:
        """壊れた内容なら ``None``。読めないだけでデーモンを落とさない。"""
        try:
            return cls(
                guild_id=int(payload["guild_id"]),  # type: ignore[arg-type]
                channel_id=int(payload["channel_id"]),  # type: ignore[arg-type]
                guild_name=str(payload.get("guild_name") or ""),
                channel_name=str(payload.get("channel_name") or ""),
            )
        except (KeyError, TypeError, ValueError):
            return None


class SettingsStore:
    """選んだチャンネルを読み書きする。"""

    def __init__(self, directory: str | Path | None = None) -> None:
        raw = directory or os.environ.get("MIHARI_SETTINGS_DIR") or DEFAULT_DIRECTORY
        self._path = Path(raw).expanduser() / SETTINGS_FILE

    @property
    def path(self) -> Path:
        return self._path

    def load(self) -> ChannelSelection | None:
        try:
            payload = json.loads(self._path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except (OSError, ValueError):
            logger.warning("チャンネル設定を読めなかった: %s", self._path)
            return None
        if not isinstance(payload, dict):
            return None
        return ChannelSelection.from_dict(payload)

    def save(self, selection: ChannelSelection) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(
            json.dumps(selection.to_dict(), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    def clear(self) -> None:
        self._path.unlink(missing_ok=True)
