"""VPS 上のエントリ。HTTP と Discord を同じループで持つ。"""

from __future__ import annotations

import asyncio
import logging

import uvicorn

from mihari_room.app import create_app
from mihari_room.config import RoomConfig
from mihari_room.discord.adapt import incoming_from_discord
from mihari_room.discord.board import BoundForumBoard, DiscordForumBoard
from mihari_room.listener import handle_incoming
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from mihari_room.worker.hermes import HermesWorker

logger = logging.getLogger("mihari_room")


def build_orchestrator(config: RoomConfig, board: BoundForumBoard) -> RoomOrchestrator:
    store = FileJobStore(config.root)
    owner_id = config.owner_id or None
    return RoomOrchestrator(store, FileJobQueue(store, owner_id=owner_id), board, HermesWorker())


async def _run_with_discord(config: RoomConfig) -> None:
    import discord

    intents = discord.Intents.default()
    intents.message_content = True
    intents.guilds = True
    client = discord.Client(intents=intents)
    board = BoundForumBoard()
    orchestrator = build_orchestrator(config, board)
    app = create_app(config, orchestrator)

    @client.event
    async def on_ready() -> None:
        if config.forum_channel_id is None:
            logger.error("MIHARI_FORUM_CHANNEL_ID が無い")
            return
        forum = client.get_channel(config.forum_channel_id)
        if forum is None:
            logger.error("Forum チャンネル %s が見つからない", config.forum_channel_id)
            return
        board.bind(DiscordForumBoard(forum, client.get_channel))
        logger.info("Forum に繋いだ: %s", config.forum_channel_id)

    @client.event
    async def on_message(message: discord.Message) -> None:
        incoming = await incoming_from_discord(message, client.user.id if client.user else None)
        if incoming is None or config.forum_channel_id is None:
            return
        await handle_incoming(
            orchestrator,
            incoming,
            forum_channel_id=config.forum_channel_id,
            owner_id=config.owner_id or None,
        )

    uv_config = uvicorn.Config(
        app,
        host=config.host,
        port=config.port,
        log_level="info",
        lifespan="on",
    )
    server = uvicorn.Server(uv_config)
    await asyncio.gather(client.start(config.discord_token), server.serve())


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    try:
        config = RoomConfig.from_environment()
    except ValueError as error:
        raise SystemExit(str(error)) from error
    config.root.mkdir(parents=True, exist_ok=True)
    if not config.discord_token or config.forum_channel_id is None:
        raise SystemExit("DISCORD_BOT_TOKEN と MIHARI_FORUM_CHANNEL_ID が要る")
    asyncio.run(_run_with_discord(config))
