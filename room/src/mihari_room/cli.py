"""VPS 上のエントリ。HTTP と Discord を同じループで持つ。"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

import uvicorn
from dotenv import load_dotenv

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


async def resolve_discord_channel(client: Any, channel_id: int) -> Any | None:
    """キャッシュを見て、無ければ API から取る。再起動後のスレッド用。"""
    found = client.get_channel(channel_id)
    if found is not None:
        return found
    try:
        return await client.fetch_channel(channel_id)
    except Exception:
        logger.exception("Discord チャンネル %s を取れない", channel_id)
        return None


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
        forum = await resolve_discord_channel(client, config.forum_channel_id)
        if forum is None:
            logger.error("Forum チャンネル %s が見つからない", config.forum_channel_id)
            return
        async def lookup(channel_id: int) -> Any | None:
            return await resolve_discord_channel(client, channel_id)

        board.bind(DiscordForumBoard(forum, lookup))
        logger.info("Forum に繋いだ: %s", config.forum_channel_id)

    @client.event
    async def on_message(message: discord.Message) -> None:
        try:
            incoming = await incoming_from_discord(
                message, client.user.id if client.user else None
            )
            if incoming is None or config.forum_channel_id is None:
                return
            await handle_incoming(
                orchestrator,
                incoming,
                forum_channel_id=config.forum_channel_id,
                owner_id=config.owner_id or None,
            )
        except Exception:
            logger.exception("Forum のメッセージ処理に失敗した")

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
    load_dotenv()
    try:
        config = RoomConfig.from_environment()
    except ValueError as error:
        raise SystemExit(str(error)) from error
    config.root.mkdir(parents=True, exist_ok=True)
    if not config.discord_token or config.forum_channel_id is None:
        raise SystemExit("DISCORD_BOT_TOKEN と MIHARI_FORUM_CHANNEL_ID が要る")
    asyncio.run(_run_with_discord(config))
