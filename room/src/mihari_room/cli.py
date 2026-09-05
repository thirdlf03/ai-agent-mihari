"""VPS 上のエントリ。HTTP と Discord を同じループで持つ。

サブコマンド ``search`` / ``context`` / ``export`` はアーカイブ CLI に流す
（トークン不要）。それ以外は従来どおりデーモンを起動する。
"""

from __future__ import annotations

import asyncio
import logging
import sys

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

#: アーカイブ CLI のサブコマンド。デーモン起動と見分ける。
_ARCHIVE_COMMANDS = frozenset({"search", "context", "export"})

logger = logging.getLogger("mihari_room")


def build_orchestrator(config: RoomConfig, board: BoundForumBoard) -> RoomOrchestrator:
    store = FileJobStore(config.root)
    owner_id = config.owner_id or None
    return RoomOrchestrator(store, FileJobQueue(store, owner_id=owner_id), board, HermesWorker())


def _build_archive_ingester(config: RoomConfig):
    """環境変数からアーカイブを作る。設定ミスは起動を止める。"""
    from mihari_room.archive.config import ArchiveConfig
    from mihari_room.archive.ingest import ArchiveIngester

    try:
        archive_config = ArchiveConfig.from_environment(config.root)
        archive_config.validate()
    except ValueError as error:
        raise SystemExit(str(error)) from error
    return ArchiveIngester(archive_config)


async def _run_with_discord(config: RoomConfig) -> None:
    import discord

    intents = discord.Intents.default()
    intents.message_content = True
    intents.guilds = True
    client = discord.Client(intents=intents)
    board = BoundForumBoard()
    orchestrator = build_orchestrator(config, board)
    app = create_app(config, orchestrator)
    archive = _build_archive_ingester(config)

    @client.event
    async def on_ready() -> None:
        archive.start()
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
        # アーカイブは Forum の絞り込みより先に見る（チャンネル許可リストで弾く）。
        try:
            await archive.handle_message(message)
        except Exception:
            logger.exception("アーカイブ受付に失敗 message=%s", getattr(message, "id", "?"))
        incoming = await incoming_from_discord(message, client.user.id if client.user else None)
        if incoming is None or config.forum_channel_id is None:
            return
        await handle_incoming(
            orchestrator,
            incoming,
            forum_channel_id=config.forum_channel_id,
            owner_id=config.owner_id or None,
        )

    @client.event
    async def on_message_edit(before: discord.Message, after: discord.Message) -> None:
        """編集は全文で上書き。キャッシュ済みメッセージだけ届く。"""
        try:
            await archive.handle_message_edit(before, after)
        except Exception:
            logger.exception("アーカイブ編集受付に失敗 message=%s", getattr(after, "id", "?"))

    @client.event
    async def on_raw_message_edit(payload: discord.RawMessageUpdateEvent) -> None:
        try:
            await archive.handle_raw_edit(payload)
        except Exception:
            logger.exception("アーカイブ raw edit 受付に失敗")

    @client.event
    async def on_raw_message_delete(payload: discord.RawMessageDeleteEvent) -> None:
        try:
            await archive.handle_raw_delete(payload)
        except Exception:
            logger.exception("アーカイブ raw delete 受付に失敗")

    @client.event
    async def on_raw_bulk_message_delete(payload: discord.RawBulkMessageDeleteEvent) -> None:
        try:
            await archive.handle_raw_bulk_delete(payload)
        except Exception:
            logger.exception("アーカイブ bulk delete 受付に失敗")

    uv_config = uvicorn.Config(
        app,
        host=config.host,
        port=config.port,
        log_level="info",
        lifespan="on",
    )
    server = uvicorn.Server(uv_config)
    try:
        await asyncio.gather(client.start(config.discord_token), server.serve())
    finally:
        await archive.aclose()


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    if len(sys.argv) > 1 and sys.argv[1] in _ARCHIVE_COMMANDS:
        # デーモンを上げずにアーカイブ CLI へ。トークンは要らない。
        from mihari_room.archive.cli import main as archive_main

        raise SystemExit(archive_main(sys.argv[1:]))
    try:
        config = RoomConfig.from_environment()
    except ValueError as error:
        raise SystemExit(str(error)) from error
    config.root.mkdir(parents=True, exist_ok=True)
    if not config.discord_token or config.forum_channel_id is None:
        raise SystemExit("DISCORD_BOT_TOKEN と MIHARI_FORUM_CHANNEL_ID が要る")
    asyncio.run(_run_with_discord(config))
