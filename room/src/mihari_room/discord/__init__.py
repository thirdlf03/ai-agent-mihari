"""Discord Forum の口（orchestration only・LLM なし）。

- 送信は :class:`DiscordForumBoard`（``ForumBoard`` Protocol の実装）。
- 受信は ``inbound`` の小さなヘルパー（Forum 新規投稿→``CreateJobRequest`` など）。
- 既存 Mac ``bridge`` 側の bot は触らない。Hermes Gateway も使わない。

必要な Intent:
    discord.py の Bot 側で ``message_content=True`` と ``guilds=True`` を有効にすること。
    Forum のスレッド名・本文を読むのに Message Content Intent が要るよ。
"""

from mihari_room.discord.board import BoundForumBoard, DiscordForumBoard, format_log_message
from mihari_room.discord.inbound import (
    CANCEL_COMMANDS,
    ForumPostEvent,
    ThreadReplyEvent,
    can_cancel,
    is_cancel_command,
    is_cancel_request,
    load_owner_id,
    parse_followup,
    parse_forum_post,
)

__all__ = [
    "BoundForumBoard",
    "CANCEL_COMMANDS",
    "DiscordForumBoard",
    "ForumPostEvent",
    "ThreadReplyEvent",
    "can_cancel",
    "format_log_message",
    "is_cancel_command",
    "is_cancel_request",
    "load_owner_id",
    "parse_followup",
    "parse_forum_post",
]
