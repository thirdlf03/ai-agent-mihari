"""Discord の生メッセージを IncomingMessage に落とす。"""

from __future__ import annotations

from typing import Any

from mihari_room.listener import IncomingMessage


async def incoming_from_discord(message: Any, bot_user_id: int | None) -> IncomingMessage | None:
    """自分の投稿は捨てる。Forum のスレッド以外は thread_id を空にする。"""
    author = getattr(message, "author", None)
    author_id = str(getattr(author, "id", "") or "")
    is_bot = bool(getattr(author, "bot", False))
    if bot_user_id is not None and str(getattr(author, "id", None)) == str(bot_user_id):
        return None

    channel = getattr(message, "channel", None)
    thread_id = None
    thread_name = ""
    parent_channel_id = None
    is_thread_starter = False
    parent = getattr(channel, "parent", None)
    parent_id = getattr(channel, "parent_id", None)
    if parent is not None or parent_id is not None:
        thread_id = int(channel.id)
        thread_name = str(getattr(channel, "name", "") or "")
        parent_channel_id = int(getattr(parent, "id", parent_id))
        is_thread_starter = int(message.id) == thread_id

    blobs: list[tuple[str, bytes]] = []
    for attachment in getattr(message, "attachments", ()) or ():
        name = str(getattr(attachment, "filename", "attachment") or "attachment")
        reader = getattr(attachment, "read", None)
        data = await reader() if callable(reader) else b""
        blobs.append((name, data))

    return IncomingMessage(
        author_id=author_id,
        content=str(getattr(message, "content", "") or ""),
        is_bot=is_bot,
        thread_id=thread_id,
        thread_name=thread_name,
        parent_channel_id=parent_channel_id,
        is_thread_starter=is_thread_starter,
        attachments=tuple(blobs),
    )
