"""投稿先チャンネルとメンション先の保存。"""

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


def test_mention_is_saved_and_cleared(tmp_path: Path) -> None:
    store = SettingsStore(tmp_path)
    assert store.load_mention_user_id() is None

    store.save_mention_user_id("123456789012345678")
    assert SettingsStore(tmp_path).load_mention_user_id() == "123456789012345678"

    store.save_mention_user_id(None)
    assert SettingsStore(tmp_path).load_mention_user_id() is None


def test_mention_and_channel_do_not_overwrite_each_other(tmp_path: Path) -> None:
    # 同じファイルに別のキーで入れているので、片方の書き換えでもう片方が消えないこと。
    store = SettingsStore(tmp_path)

    store.save(SELECTION)
    store.save_mention_user_id("123456789012345678")
    assert store.load() == SELECTION
    assert store.load_mention_user_id() == "123456789012345678"

    store.save(ChannelSelection(guild_id=3, channel_id=4))
    assert store.load_mention_user_id() == "123456789012345678"

    store.save_mention_user_id(None)
    assert store.load() == ChannelSelection(guild_id=3, channel_id=4)


def test_mention_survives_a_file_without_a_channel(tmp_path: Path) -> None:
    store = SettingsStore(tmp_path)
    store.save_mention_user_id("123456789012345678")

    assert store.load() is None
    assert store.load_mention_user_id() == "123456789012345678"


def test_broken_file_returns_no_mention(tmp_path: Path) -> None:
    store = SettingsStore(tmp_path)
    store.path.parent.mkdir(parents=True, exist_ok=True)
    store.path.write_text("これは JSON ではない", encoding="utf-8")
    assert store.load_mention_user_id() is None
