"""Discord のエンドポイント。

**実際の Discord には繋がない。** サービス層をスタブに差し替える。
"""

from __future__ import annotations

import base64
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import discord
import pytest
from fastapi.testclient import TestClient

from device_bridge.daemon.events import EventBus
from device_bridge.daemon.routers.discord import TEST_MESSAGE
from device_bridge.discord_bot.bot import ChannelInfo, DiscordService, DiscordUnavailableError
from device_bridge.discord_bot.config import DiscordConfig
from device_bridge.discord_bot.scheduler import WatchScheduler
from device_bridge.discord_bot.settings_store import ChannelSelection, SettingsStore

PNG = b"\x89PNG\r\n\x1a\n"


class _StubService:
    def __init__(
        self,
        *,
        config: DiscordConfig | None = None,
        ready: bool = True,
        selection: ChannelSelection | None = None,
        error: str | None = None,
    ) -> None:
        self.config = config or DiscordConfig(token="t", client_id="12345")
        self.is_ready = ready
        self.selection = selection
        self.last_error = error
        self.mention_user_id: str | None = None
        self.lock_hours: float = 4.0
        self.posted: list[tuple[str, bytes | None, str]] = []
        self.selected: list[ChannelSelection] = []

    def channels(self) -> list[ChannelInfo]:
        if not self.is_ready:
            raise DiscordUnavailableError("Bot がまだ起動していない")
        return [ChannelInfo(guild_id=1, guild_name="サーバ", channel_id=2, channel_name="general")]

    def select_channel(self, selection: ChannelSelection) -> None:
        self.selected.append(selection)
        self.selection = selection

    def set_mention_user_id(self, user_id: str | None) -> None:
        self.mention_user_id = user_id

    async def post(
        self, text: str, *, image: bytes | None = None, filename: str = "evidence.png"
    ) -> int:
        if not self.is_ready:
            raise DiscordUnavailableError("Bot がまだ起動していない")
        if self.selection is None:
            raise DiscordUnavailableError("投稿先のチャンネルが選ばれていない")
        self.posted.append((text, image, filename))
        return 999


@pytest.fixture
def service(client: TestClient) -> _StubService:
    stub = _StubService()
    client.app.state.discord = stub
    return stub


def test_status_reports_the_invite_url(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    body = client.get("/discord/status", headers=auth).json()

    assert body["token_configured"] is True
    assert body["missing"] == []
    assert "client_id=12345" in body["invite_url"]


def test_status_says_what_is_missing(client: TestClient, auth: dict[str, str]) -> None:
    client.app.state.discord = _StubService(config=DiscordConfig(), ready=False)

    body = client.get("/discord/status", headers=auth).json()

    assert body["missing"] == ["DISCORD_BOT_TOKEN", "DISCORD_CLIENT_ID"]
    assert body["invite_url"] is None
    assert body["bot_ready"] is False


def test_channels_are_listed(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    body = client.get("/discord/channels", headers=auth).json()
    assert body["channels"][0]["channel_name"] == "general"


def test_channels_without_a_running_bot_is_409(client: TestClient, auth: dict[str, str]) -> None:
    client.app.state.discord = _StubService(ready=False)
    response = client.get("/discord/channels", headers=auth)
    assert response.status_code == 409
    assert "起動していない" in response.json()["detail"]


def test_selecting_a_channel_persists_it(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    response = client.post(
        "/discord/channel",
        json={"guild_id": 1, "channel_id": 2, "guild_name": "サーバ", "channel_name": "general"},
        headers=auth,
    )

    assert response.status_code == 200
    assert service.selected[0].channel_id == 2


def test_bad_channel_payload_is_422(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    assert client.post("/discord/channel", json={"guild_id": 1}, headers=auth).status_code == 422


def test_posting_text_and_image(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    service.selection = ChannelSelection(guild_id=1, channel_id=2)

    response = client.post(
        "/discord/post",
        json={"text": "寝てますね", "image": base64.b64encode(PNG).decode("ascii")},
        headers=auth,
    )

    assert response.status_code == 200
    assert response.json()["message_id"] == 999
    assert service.posted[0][0] == "寝てますね"
    assert service.posted[0][1] == PNG


def test_posting_nothing_is_422(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    assert client.post("/discord/post", json={}, headers=auth).status_code == 422


def test_broken_base64_is_422(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    response = client.post("/discord/post", json={"image": "@@@"}, headers=auth)
    assert response.status_code == 422
    assert "base64" in response.json()["detail"]


def test_posting_without_a_channel_is_409(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    # 晒せないことは検知を止める理由にならないので、原因を返して呼び出し元に判断させる。
    service.selection = None
    response = client.post("/discord/post", json={"text": "やあ"}, headers=auth)
    assert response.status_code == 409
    assert "チャンネル" in response.json()["detail"]


def test_schedule_can_be_set_and_cleared(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    body = client.post("/discord/schedule", json={"at": "23:59"}, headers=auth).json()
    assert body["scheduled"] is not None

    cleared = client.delete("/discord/schedule", headers=auth).json()
    assert cleared["scheduled"] is None
    assert cleared["watching"] is False


def test_schedule_without_a_time_starts_now(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    body = client.post("/discord/schedule", json={}, headers=auth).json()
    assert body["watching"] is True


def test_bad_schedule_time_is_422(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    assert client.post("/discord/schedule", json={"at": "とけい"}, headers=auth).status_code == 422


def test_status_reports_the_mention_target(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    assert client.get("/discord/status", headers=auth).json()["mention_user_id"] is None

    service.mention_user_id = "123456789012345678"

    body = client.get("/discord/status", headers=auth).json()
    assert body["mention_user_id"] == "123456789012345678"


def test_lock_hours_are_reported(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    service.lock_hours = 6.5

    response = client.get("/discord/lock-hours", headers=auth)

    assert response.status_code == 200
    assert response.json() == {"lock_hours": 6.5}


def test_setting_a_mention_target(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    response = client.post("/discord/mention", json={"user_id": "123456789012345678"}, headers=auth)

    assert response.status_code == 200
    assert response.json() == {"mention_user_id": "123456789012345678"}
    assert service.mention_user_id == "123456789012345678"


@pytest.mark.parametrize("raw", [None, ""])
def test_clearing_the_mention_target(
    client: TestClient, auth: dict[str, str], service: _StubService, raw: str | None
) -> None:
    service.mention_user_id = "123456789012345678"

    response = client.post("/discord/mention", json={"user_id": raw}, headers=auth)

    assert response.status_code == 200
    assert response.json() == {"mention_user_id": None}
    assert service.mention_user_id is None


@pytest.mark.parametrize("raw", ["<@123>", "abc", "12 34", "1" * 26, "-1"])
def test_a_bad_mention_target_is_400(
    client: TestClient, auth: dict[str, str], service: _StubService, raw: str
) -> None:
    response = client.post("/discord/mention", json={"user_id": raw}, headers=auth)

    assert response.status_code == 400
    assert "数字" in response.json()["detail"]
    assert service.mention_user_id is None


def test_test_post_sends_the_fixed_message(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    service.selection = ChannelSelection(guild_id=1, channel_id=2)

    response = client.post("/discord/test", json={}, headers=auth)

    assert response.status_code == 200
    assert response.json() == {"posted": True, "message_id": 999}
    assert service.posted[0][0] == TEST_MESSAGE


def test_test_post_without_a_channel_is_409(
    client: TestClient, auth: dict[str, str], service: _StubService
) -> None:
    service.selection = None
    response = client.post("/discord/test", json={}, headers=auth)
    assert response.status_code == 409
    assert "チャンネル" in response.json()["detail"]


def test_test_post_without_a_running_bot_is_409(client: TestClient, auth: dict[str, str]) -> None:
    client.app.state.discord = _StubService(ready=False)
    response = client.post("/discord/test", json={}, headers=auth)
    assert response.status_code == 409
    assert "起動していない" in response.json()["detail"]


def test_discord_endpoints_need_a_token(client: TestClient) -> None:
    assert client.get("/discord/status").status_code == 401
    assert client.get("/discord/channels").status_code == 401
    assert client.post("/discord/post", json={"text": "x"}).status_code == 401
    assert client.post("/discord/mention", json={"user_id": None}).status_code == 401
    assert client.post("/discord/test", json={}).status_code == 401


# ---- ここから下は `DiscordService.post` そのもの。Bot とチャンネルだけをモックにする。


class _FakeBot:
    """`DiscordService` が使う分だけの Bot。"""

    def __init__(self, channel: Any) -> None:
        self._channel = channel

    def is_ready(self) -> bool:
        return True

    def get_channel(self, channel_id: int) -> Any:
        return self._channel


def _service(tmp_path: Path) -> tuple[DiscordService, Any]:
    # `isinstance(channel, discord.TextChannel)` を通したいので spec 付きで作る。
    channel = MagicMock(spec=discord.TextChannel)
    channel.send.return_value = MagicMock(id=999)
    service = DiscordService(
        DiscordConfig(token="t", client_id="12345"),
        scheduler=WatchScheduler(EventBus()),
        store=SettingsStore(tmp_path),
    )
    service._bot = _FakeBot(channel)
    service.select_channel(ChannelSelection(guild_id=1, channel_id=2))
    return service, channel


async def test_post_prefixes_the_mention(tmp_path: Path) -> None:
    service, channel = _service(tmp_path)
    service.set_mention_user_id("123456789012345678")

    assert await service.post("寝てますね") == 999

    sent = channel.send.call_args.kwargs
    assert sent["content"] == "<@123456789012345678> 寝てますね"
    # 書いただけでは通知が飛ばないことがあるので、明示的に許している。
    # ただし許すのはユーザー宛てだけ。@everyone やロールは誤爆させない。
    allowed = sent["allowed_mentions"]
    assert allowed.users is True
    assert allowed.everyone is False
    assert allowed.roles is False
    assert allowed.replied_user is False


async def test_post_without_a_mention_target_is_left_alone(tmp_path: Path) -> None:
    service, channel = _service(tmp_path)

    await service.post("寝てますね")

    assert channel.send.call_args.kwargs["content"] == "寝てますね"


async def test_post_with_only_an_image_still_mentions(tmp_path: Path) -> None:
    # 本文が空でも通知は飛ばしたい。末尾に空白だけ残さないようにする。
    service, channel = _service(tmp_path)
    service.set_mention_user_id("1")

    await service.post("", image=PNG)

    assert channel.send.call_args.kwargs["content"] == "<@1>"
