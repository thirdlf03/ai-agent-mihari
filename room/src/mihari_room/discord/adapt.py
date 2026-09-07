"""Discord の生メッセージを IncomingMessage に落とす。"""

from __future__ import annotations

from typing import Any

from mihari_room.listener import IncomingMessage


async def incoming_from_discord(message: Any, bot_user_id: int | None) -> IncomingMessage | None:
    """自分の投稿は捨てる。Forum のスレッド以外は thread_id を空にする。

    修正依頼かどうかの目印として、Bot へのメンションと「Bot の投稿への返信」を
    見ておく。返信先の解決は API を 1 回叩くので、返信が付いたスレッド内の発言
    だけ調べる。
    """
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

    mentions_bot = _mentions_bot(message, bot_user_id)
    replies_to_bot = await _replies_to_bot(message, bot_user_id, thread_id)

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
        replies_to_bot=replies_to_bot,
        mentions_bot=mentions_bot,
    )


def _mentions_bot(message: Any, bot_user_id: int | None) -> bool:
    """本文のメンションに Bot が含まれるか。"""
    if bot_user_id is None:
        return False
    for mention in getattr(message, "mentions", ()) or ():
        if str(getattr(mention, "id", "")) == str(bot_user_id):
            return True
    return False


async def _replies_to_bot(message: Any, bot_user_id: int | None, thread_id: int | None) -> bool:
    """返信先のメッセージが Bot の投稿か。

    スレッド内の返信だけ調べる（返信先の解決に API が要るため）。解決できない
    ときは ``reference.resolved``（キャッシュ済み）を信じ、それも無ければ False。
    """
    if bot_user_id is None or thread_id is None:
        return False
    reference = getattr(message, "reference", None)
    if reference is None:
        return False
    message_id = getattr(reference, "message_id", None)
    if message_id is None:
        return False
    resolved = getattr(reference, "resolved", None)
    if resolved is not None:
        return _author_is_bot(resolved, bot_user_id)
    channel = getattr(message, "channel", None)
    fetch = getattr(channel, "fetch_message", None)
    if not callable(fetch):
        return False
    try:
        target = await fetch(message_id)
    except Exception:
        return False
    return _author_is_bot(target, bot_user_id)


def _author_is_bot(target: Any, bot_user_id: int | None) -> bool:
    if bot_user_id is None:
        return False
    author_id = getattr(getattr(target, "author", None), "id", None)
    return author_id is not None and str(author_id) == str(bot_user_id)
