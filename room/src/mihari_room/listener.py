"""Forum 直のメッセージをオーケストレータへ渡す。discord.py の型には依存しない。"""

from __future__ import annotations

import logging
from collections.abc import Sequence
from dataclasses import dataclass

from mihari_room.discord.inbound import (
    ForumPostEvent,
    is_cancel_command,
    parse_forum_post,
)
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import CancelNotAllowed
from mihari_room.store.file_store import JobNotFound

logger = logging.getLogger("mihari_room")

#: お礼・労いだけの文面。Bot への返信・メンションでも修正依頼にはしない。
_THANKS_ONLY = frozenset(
    {
        "ありがとう",
        "ありがとうございます",
        "ありがとうございました",
        "有難う",
        "有難うございます",
        "thank you",
        "thanks",
        "thx",
        "感謝",
        "感謝します",
        "助かった",
        "助かりました",
        "お疲れ様",
        "お疲れさま",
        "おつかれさま",
        "おつかれ様",
    }
)

#: 文末の勢い（感嘆符・疑問符・句点）は落として比べる。
_TRAILING_NOISE = " \t\n　!！?？。．.、,､～〜…"


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
    #: 返信先が Bot の投稿か。修正依頼（追記）を受け付ける目印。
    replies_to_bot: bool = False
    #: 本文に Bot へのメンションを含むか。同じく修正依頼の目印。
    mentions_bot: bool = False


def is_thanks_only(text: str) -> bool:
    """お礼・労いだけで、修正依頼ではない文面か。"""
    normalized = text.strip().casefold().rstrip(_TRAILING_NOISE).strip()
    return normalized in _THANKS_ONLY


def is_addressed_to_bot(message: IncomingMessage) -> bool:
    """Bot への返信かメンションで、Bot に宛てた発言か。"""
    return message.replies_to_bot or message.mentions_bot


async def handle_incoming(
    orchestrator: RoomOrchestrator,
    message: IncomingMessage,
    *,
    forum_channel_id: int,
    owner_id: str | None,
) -> None:
    """Forum のスレッドだけ扱う。自分の投稿は呼ぶ側で捨てる。

    既存の仕事のスレッドでは中止命令を先に判定する。修正依頼（追記）は
    Bot への返信またはメンションが付いた発言だけ受け付け、通常会話では
    再実行しない。
    """
    if message.is_bot:
        return
    if message.thread_id is None or message.parent_channel_id != forum_channel_id:
        return

    thread_id = message.thread_id
    existing = orchestrator.store.find_by_thread_id(thread_id)

    if existing is not None:
        # 中止命令は先に見る。権限が無くても「追記」扱いにはしない。
        if is_cancel_command(message.content):
            await _cancel_or_explain(orchestrator, thread_id, by=message.author_id)
            return
        if not is_addressed_to_bot(message):
            # 誰に宛てたわけでもない発言（相づち・世間話）では再実行しない。
            logger.info("通常会話なので再実行しない thread=%s", thread_id)
            return
        if is_thanks_only(message.content):
            # Bot への「ありがとう」もお礼であり修正依頼ではない。
            logger.info("お礼だけなので再実行しない thread=%s", thread_id)
            return
        await orchestrator.follow_up(
            thread_id,
            message.content,
            requested_by=message.author_id,
            attachments=message.attachments,
        )
        if message.attachments:
            names = "、".join(name for name, _ in message.attachments)
            await _say_or_log(orchestrator, thread_id, f"資料を受け取ったよ: {names}")
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


async def _cancel_or_explain(orchestrator: RoomOrchestrator, thread_id: int, *, by: str) -> None:
    try:
        await orchestrator.cancel_thread(thread_id, by=by)
    except CancelNotAllowed:
        logger.info("Forum のキャンセルを断った thread=%s by=%s", thread_id, by)
        await _say_or_log(orchestrator, thread_id, "あなたには止められないよ")
    except JobNotFound:
        logger.info("止める仕事がない thread=%s", thread_id)
    except Exception:
        logger.exception("Forum のキャンセルに失敗した thread=%s", thread_id)
        await _say_or_log(orchestrator, thread_id, "止められなかった。あとで見て。")


async def _say_or_log(orchestrator: RoomOrchestrator, thread_id: int, text: str) -> None:
    try:
        await orchestrator.say(thread_id, text)
    except Exception:
        logger.exception("Forum に返事を書けなかった thread=%s", thread_id)
