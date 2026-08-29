"""Discord のエンドポイント。

**実際の Discord には繋がない。** サービス層をスタブに差し替える。
"""

from __future__ import annotations

import base64

import pytest
from fastapi.testclient import TestClient

from device_bridge.discord_bot.bot import ChannelInfo, DiscordUnavailableError
from device_bridge.discord_bot.config import DiscordConfig
from device_bridge.discord_bot.settings_store import ChannelSelection

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
        self.posted: list[tuple[str, bytes | None, str]] = []
        self.selected: list[ChannelSelection] = []

    def channels(self) -> list[ChannelInfo]:
        if not self.is_ready:
            raise DiscordUnavailableError("Bot がまだ起動していない")
        return [ChannelInfo(guild_id=1, guild_name="サーバ", channel_id=2, channel_name="general")]

    def select_channel(self, selection: ChannelSelection) -> None:
        self.selected.append(selection)
        self.selection = selection

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


def test_discord_endpoints_need_a_token(client: TestClient) -> None:
    assert client.get("/discord/status").status_code == 401
    assert client.get("/discord/channels").status_code == 401
    assert client.post("/discord/post", json={"text": "x"}).status_code == 401
