"""Forum 直のメッセージをオーケストレータへ渡す。discord.py の型には依存しない。"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

from mihari_room.discord.inbound import (
    ForumPostEvent,
    is_cancel_request,
    parse_forum_post,
)
from mihari_room.orchestrator import RoomOrchestrator


@dataclass(frozen=True, slots=True)
class IncomingMessage:
    """Bot が見るメッセージの、テストしやすい切り出し。"""

    author_id: str
    content: str
    is_bot: bool
    thread_id: int | None
    thread_name: str
    parent_channel_id: int | None
    is_thread_starter: bool
    attachments: Sequence[tuple[str, bytes]] = ()


async def handle_incoming(
    orchestrator: RoomOrchestrator,
    message: IncomingMessage,
    *,
    forum_channel_id: int,
    owner_id: str | None,
) -> None:
    """Forum のスレッドだけ扱う。自分の投稿は呼ぶ側で捨てる。"""
    if message.is_bot:
        return
    if message.thread_id is None or message.parent_channel_id != forum_channel_id:
        return

    thread_id = message.thread_id
    finder = getattr(orchestrator.store, "find_by_thread_id", None)
    existing = finder(thread_id) if callable(finder) else None

    if existing is not None:
        starter_id = existing.requested_by or ""
        if is_cancel_request(
            message.content,
            message.author_id,
            thread_starter_id=starter_id,
            owner_id=owner_id,
        ):
            try:
                await orchestrator.cancel_thread(thread_id, by=message.author_id)
            except Exception:
                return
            return
        await orchestrator.follow_up(thread_id, message.content, requested_by=message.author_id)
        return

    if not message.is_thread_starter:
        return

    request = parse_forum_post(
        ForumPostEvent(
            thread_id=thread_id,
            thread_name=message.thread_name,
            content=message.content,
            author_id=message.author_id,
        )
    )
    await orchestrator.submit(request, attachments=message.attachments)
