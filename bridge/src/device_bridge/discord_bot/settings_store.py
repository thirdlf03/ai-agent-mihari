"""投稿先チャンネルとメンション先の保存。

Bot トークンと違って秘密ではないので、素直にファイルに置く。
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

DEFAULT_DIRECTORY = "~/.mihari"
SETTINGS_FILE = "discord.json"

#: メンション先のユーザー ID を入れるキー。
#: Discord の snowflake は 64bit あり JSON の数値では丸められかねないので、文字列で持つ。
MENTION_KEY = "mention_user_id"

#: 「起動してから何時間は終了できないか」を入れるキー。
LOCK_HOURS_KEY = "lock_hours"

#: 未設定のときに使う既定値。1 回の作業セッションとして妥当な長さ。
DEFAULT_LOCK_HOURS = 4.0


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
    """選んだチャンネルとメンション先を読み書きする。

    どちらも同じ ``discord.json`` に別のキーで入れる。片方だけを書き換えても
    もう片方が消えないよう、書くときは必ず読んでから差分を重ねる。
    """

    def __init__(self, directory: str | Path | None = None) -> None:
        raw = directory or os.environ.get("MIHARI_SETTINGS_DIR") or DEFAULT_DIRECTORY
        self._path = Path(raw).expanduser() / SETTINGS_FILE

    @property
    def path(self) -> Path:
        return self._path

    def load(self) -> ChannelSelection | None:
        payload = self._read()
        if payload is None:
            return None
        return ChannelSelection.from_dict(payload)

    def save(self, selection: ChannelSelection) -> None:
        self._write((self._read() or {}) | selection.to_dict())

    def load_mention_user_id(self) -> str | None:
        """通知するユーザーの ID。決めていなければ ``None``。"""
        payload = self._read() or {}
        text = str(payload.get(MENTION_KEY) or "").strip()
        return text or None

    def save_mention_user_id(self, user_id: str | None) -> None:
        """通知先を決める。``None`` や空文字ならキーごと消して解除する。"""
        payload = self._read() or {}
        if user_id:
            payload[MENTION_KEY] = user_id
        else:
            payload.pop(MENTION_KEY, None)
        self._write(payload)

    def load_lock_hours(self) -> float:
        """起動してから終了できるようになるまでの時間(時間単位)。決めていなければ既定値。"""
        payload = self._read() or {}
        raw = payload.get(LOCK_HOURS_KEY)
        try:
            hours = float(raw)  # type: ignore[arg-type]
        except (TypeError, ValueError):
            return DEFAULT_LOCK_HOURS
        return hours if hours >= 0 else DEFAULT_LOCK_HOURS

    def save_lock_hours(self, hours: float) -> None:
        payload = self._read() or {}
        payload[LOCK_HOURS_KEY] = hours
        self._write(payload)

    def clear(self) -> None:
        self._path.unlink(missing_ok=True)

    def _read(self) -> dict[str, Any] | None:
        try:
            payload = json.loads(self._path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except (OSError, ValueError):
            logger.warning("Discord の設定を読めなかった: %s", self._path)
            return None
        if not isinstance(payload, dict):
            return None
        return payload

    def _write(self, payload: dict[str, Any]) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
