"""投稿先チャンネルの保存。"""

from __future__ import annotations

from pathlib import Path

from device_bridge.discord_bot.settings_store import ChannelSelection, SettingsStore

SELECTION = ChannelSelection(guild_id=1, channel_id=2, guild_name="サーバ", channel_name="general")


def test_saves_and_loads(tmp_path: Path) -> None:
    store = SettingsStore(tmp_path)
    store.save(SELECTION)
    assert store.load() == SELECTION


def test_missing_file_returns_none(tmp_path: Path) -> None:
    assert SettingsStore(tmp_path).load() is None


def test_broken_file_returns_none_without_raising(tmp_path: Path) -> None:
    # 壊れた設定でデーモンを落とさない。選び直せばよいだけ。
    store = SettingsStore(tmp_path)
    store.path.parent.mkdir(parents=True, exist_ok=True)
    store.path.write_text("これは JSON ではない", encoding="utf-8")
    assert store.load() is None


def test_missing_keys_return_none(tmp_path: Path) -> None:
    store = SettingsStore(tmp_path)
    store.path.parent.mkdir(parents=True, exist_ok=True)
    store.path.write_text('{"guild_id": 1}', encoding="utf-8")
    assert store.load() is None


def test_clear_removes_the_file(tmp_path: Path) -> None:
    store = SettingsStore(tmp_path)
    store.save(SELECTION)
    store.clear()
    assert store.load() is None


def test_clear_is_safe_when_nothing_is_saved(tmp_path: Path) -> None:
    SettingsStore(tmp_path).clear()
