"""Discord Bot 本体。

Mac 上でローカル常駐する。Mac が落ちている間はスラッシュコマンドが効かないので、
コマンドの応答にもその旨を出す。
"""

from __future__ import annotations

import asyncio
import io
import logging
from dataclasses import dataclass

import discord
from discord import app_commands

from device_bridge.discord_bot.config import DiscordConfig
from device_bridge.discord_bot.schedule import InvalidTimeError, parse_time_of_day
from device_bridge.discord_bot.scheduler import WatchScheduler
from device_bridge.discord_bot.settings_store import ChannelSelection, SettingsStore

logger = logging.getLogger(__name__)

#: Bot の起動を待つ上限。
READY_TIMEOUT_SECONDS = 30.0


class DiscordUnavailableError(RuntimeError):
    """Bot が使えない。トークン未設定、未起動、チャンネル未選択など。"""


@dataclass(frozen=True, slots=True)
class ChannelInfo:
    """投稿先の候補。"""

    guild_id: int
    guild_name: str
    channel_id: int
    channel_name: str

    def to_dict(self) -> dict[str, object]:
        return {
            "guild_id": self.guild_id,
            "guild_name": self.guild_name,
            "channel_id": self.channel_id,
            "channel_name": self.channel_name,
        }


class MihariBot(discord.Client):
    """スラッシュコマンドを持つ最小の Bot。"""

    def __init__(self, scheduler: WatchScheduler) -> None:
        # メッセージ内容は読まない。投稿と、参加サーバの一覧が取れれば足りる。
        super().__init__(intents=discord.Intents.default())
        self.tree = app_commands.CommandTree(self)
        self._scheduler = scheduler
        self._register_commands()

    async def setup_hook(self) -> None:
        await self.tree.sync()

    def _register_commands(self) -> None:
        group = app_commands.Group(name="watch", description="Mihari の監視を操作する")

        @group.command(name="start", description="いますぐ監視を始める")
        async def start(interaction: discord.Interaction) -> None:
            self._scheduler.start_now(requested_by=str(interaction.user))
            await interaction.response.send_message("監視を始めました。見てますよ。")

        @group.command(name="at", description="指定した時刻に監視を始める")
        @app_commands.describe(time="HH:MM(例: 19:00)。過ぎていれば翌日になります")
        async def at(interaction: discord.Interaction, time: str) -> None:
            try:
                hour, minute = parse_time_of_day(time)
            except InvalidTimeError as error:
                await interaction.response.send_message(str(error), ephemeral=True)
                return
            scheduled = self._scheduler.schedule_at(
                hour, minute, requested_by=str(interaction.user)
            )
            await interaction.response.send_message(
                f"{scheduled.at:%m/%d %H:%M} から監視します。"
                "\n※ Bot は Mac 上で動いているので、その時刻に Mac が起きている必要があります。"
            )

        @group.command(name="stop", description="監視を止める")
        async def stop(interaction: discord.Interaction) -> None:
            self._scheduler.stop(requested_by=str(interaction.user))
            await interaction.response.send_message("監視を止めました。")

        @group.command(name="status", description="いまの監視状態を見る")
        async def status(interaction: discord.Interaction) -> None:
            state = self._scheduler.status()
            lines = ["監視中です。" if state["watching"] else "監視していません。"]
            scheduled = state["scheduled"]
            if isinstance(scheduled, dict):
                lines.append(f"予約: {scheduled['at']}")
            await interaction.response.send_message("\n".join(lines), ephemeral=True)

        self.tree.add_command(group)


class DiscordService:
    """デーモンから Bot を扱うための窓口。

    トークンが無い / Bot が起動していない、のどちらでも例外を投げるだけで、
    デーモン自体は動き続ける。晒せないことは検知を止める理由にならない。
    """

    def __init__(
        self,
        config: DiscordConfig | None = None,
        *,
        scheduler: WatchScheduler,
        store: SettingsStore | None = None,
    ) -> None:
        self._config = config or DiscordConfig.from_environment()
        self._scheduler = scheduler
        self._store = store or SettingsStore()
        self._bot: MihariBot | None = None
        self._task: asyncio.Task[None] | None = None
        self._last_error: str | None = None

    @property
    def config(self) -> DiscordConfig:
        return self._config

    @property
    def is_ready(self) -> bool:
        return self._bot is not None and self._bot.is_ready()

    @property
    def last_error(self) -> str | None:
        return self._last_error

    @property
    def selection(self) -> ChannelSelection | None:
        return self._store.load()

    def select_channel(self, selection: ChannelSelection) -> None:
        self._store.save(selection)

    @property
    def mention_user_id(self) -> str | None:
        """投稿の先頭でメンションするユーザーの ID。決めていなければ ``None``。"""
        return self._store.load_mention_user_id()

    def set_mention_user_id(self, user_id: str | None) -> None:
        self._store.save_mention_user_id(user_id)

    async def start(self) -> None:
        """Bot を起動する。トークンが無ければ何もしない。"""
        if not self._config.has_token or self._task is not None:
            return
        self._bot = MihariBot(self._scheduler)
        self._task = asyncio.create_task(self._run())

    async def close(self) -> None:
        if self._bot is not None:
            await self._bot.close()
        if self._task is not None:
            self._task.cancel()
        self._bot = None
        self._task = None

    async def _run(self) -> None:
        assert self._bot is not None
        try:
            await self._bot.start(self._config.token)
        except discord.LoginFailure:
            self._last_error = "DISCORD_BOT_TOKEN が正しくない"
            logger.error(self._last_error)
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001 - Bot が落ちてもデーモンは続ける
            self._last_error = f"Bot が落ちた: {error}"
            logger.error(self._last_error)

    def channels(self) -> list[ChannelInfo]:
        """投稿できるチャンネルの一覧。

        :raises DiscordUnavailableError: Bot が起動していない。
        """
        bot = self._require_bot()
        found: list[ChannelInfo] = []
        for guild in bot.guilds:
            for channel in guild.text_channels:
                if channel.permissions_for(guild.me).send_messages:
                    found.append(
                        ChannelInfo(
                            guild_id=guild.id,
                            guild_name=guild.name,
                            channel_id=channel.id,
                            channel_name=channel.name,
                        )
                    )
        return found

    async def post(
        self, text: str, *, image: bytes | None = None, filename: str = "evidence.png"
    ) -> int:
        """選んだチャンネルに投稿する。投稿したメッセージ ID を返す。

        :raises DiscordUnavailableError: Bot 未起動、またはチャンネル未選択。
        """
        bot = self._require_bot()
        selection = self.selection
        if selection is None:
            raise DiscordUnavailableError("投稿先のチャンネルが選ばれていない")

        channel = bot.get_channel(selection.channel_id)
        if not isinstance(channel, discord.TextChannel):
            raise DiscordUnavailableError(
                f"チャンネルが見つからない(id={selection.channel_id})。Bot が抜けた可能性がある"
            )

        content = self._with_mention(text)
        file = discord.File(io.BytesIO(image), filename=filename) if image else None
        try:
            message = await channel.send(
                content=content or None,
                file=file,
                # メンションを書いても既定では通知が飛ばないことがあるので、明示的に許す。
                # 許すのはユーザー宛てだけ。@everyone やロールを誤爆させない。
                allowed_mentions=discord.AllowedMentions(
                    everyone=False, roles=False, users=True, replied_user=False
                ),
            )
        except discord.HTTPException as error:
            raise DiscordUnavailableError(f"投稿に失敗した: {error}") from error
        return message.id

    def _with_mention(self, text: str) -> str:
        """メンション先が決まっていれば本文の先頭に付ける。決まっていなければそのまま。"""
        user_id = self.mention_user_id
        if not user_id:
            return text
        return f"<@{user_id}> {text}" if text else f"<@{user_id}>"

    def _require_bot(self) -> MihariBot:
        if not self._config.has_token:
            raise DiscordUnavailableError("DISCORD_BOT_TOKEN が未設定")
        if self._bot is None or not self._bot.is_ready():
            raise DiscordUnavailableError(self._last_error or "Bot がまだ起動していない")
        return self._bot
