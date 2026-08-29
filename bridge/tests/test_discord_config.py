"""Discord の設定と招待 URL。"""

from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import pytest

from device_bridge.discord_bot.config import REQUIRED_PERMISSIONS, DiscordConfig
from device_bridge.discord_bot.invite import invite_url


def test_reads_from_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DISCORD_BOT_TOKEN", "  token  ")
    monkeypatch.setenv("DISCORD_CLIENT_ID", "12345")

    config = DiscordConfig.from_environment()

    assert config.token == "token"
    assert config.client_id == "12345"
    assert config.missing == []


def test_reports_what_is_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    # 「なぜ使えないのか」が分からないと直しようがないので、名前で返す。
    monkeypatch.delenv("DISCORD_BOT_TOKEN", raising=False)
    monkeypatch.delenv("DISCORD_CLIENT_ID", raising=False)

    config = DiscordConfig.from_environment()

    assert config.has_token is False
    assert config.missing == ["DISCORD_BOT_TOKEN", "DISCORD_CLIENT_ID"]


def test_invite_url_carries_scopes_and_permissions() -> None:
    query = parse_qs(urlparse(invite_url("12345")).query)

    assert query["client_id"] == ["12345"]
    assert query["scope"] == ["bot applications.commands"]
    assert query["permissions"] == [str(REQUIRED_PERMISSIONS)]


def test_invite_url_requests_only_what_is_needed() -> None:
    # 過剰な権限を要求すると招待をためらわれる。送信・添付・閲覧だけに絞っている。
    assert REQUIRED_PERMISSIONS == (1 << 10) | (1 << 11) | (1 << 15)


def test_invite_url_without_client_id_is_rejected() -> None:
    with pytest.raises(ValueError, match="DISCORD_CLIENT_ID"):
        invite_url("")
