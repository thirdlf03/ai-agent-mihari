"""FastAPI アプリの組み立て。"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from device_bridge.daemon.config import DaemonConfig
from device_bridge.daemon.events import EventBus
from device_bridge.daemon.routers import devices, discord, events, health, voice
from device_bridge.discord_bot.bot import DiscordService
from device_bridge.discord_bot.scheduler import WatchScheduler
from device_bridge.voice.generator import LineGenerator
from device_bridge.voice.voicevox import VoicevoxClient


@asynccontextmanager
async def _lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Bot の起動と後片付け。

    トークンが無ければ何も起きない。Bot が使えなくてもデーモンは動き続ける。
    """
    await app.state.discord.start()
    try:
        yield
    finally:
        await app.state.discord.close()


def create_app(config: DaemonConfig) -> FastAPI:
    """設定からアプリを作る。テストからも同じ経路で組み立てる。"""
    app = FastAPI(
        title="Mihari device-bridge daemon",
        version="0.1.0",
        # ローカル専用のプロセスなので、対話ドキュメントは出さない。
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=_lifespan,
    )
    app.state.config = config
    app.state.events = EventBus()
    app.state.line_generator = LineGenerator()
    app.state.voicevox = VoicevoxClient()
    app.state.watch_scheduler = WatchScheduler(app.state.events)
    app.state.discord = DiscordService(scheduler=app.state.watch_scheduler)

    app.include_router(health.router)
    app.include_router(devices.router)
    app.include_router(events.router)
    app.include_router(voice.router)
    app.include_router(discord.router)
    return app
