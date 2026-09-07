"""incoming_from_discord の切り分け。

修正依頼の目印（Bot へのメンション・Bot の投稿への返信）が、Discord の
生メッセージから正しく IncomingMessage に落ちることを確かめる。
"""

from __future__ import annotations

from mihari_room.discord.adapt import incoming_from_discord


class FakeAuthor:
    def __init__(self, author_id: int, bot: bool = False) -> None:
        self.id = author_id
        self.bot = bot


class FakeAttachment:
    def __init__(self, filename: str, data: bytes) -> None:
        self.filename = filename
        self._data = data

    async def read(self) -> bytes:
        return self._data


class FakeReference:
    def __init__(self, message_id: int, resolved: object | None = None) -> None:
        self.message_id = message_id
        self.resolved = resolved


class FakeChannel:
    def __init__(
        self,
        channel_id: int,
        *,
        parent_id: int | None = None,
        name: str = "",
        fetched: object | None = None,
        error: Exception | None = None,
    ) -> None:
        self.id = channel_id
        self.parent_id = parent_id
        self.name = name
        self._fetched = fetched
        self._error = error

    async def fetch_message(self, message_id: int) -> object:
        if self._error is not None:
            raise self._error
        return self._fetched


class FakeMessage:
    def __init__(
        self,
        message_id: int,
        author: FakeAuthor,
        *,
        channel: FakeChannel | None = None,
        content: str = "",
        attachments: tuple[FakeAttachment, ...] = (),
        reference: FakeReference | None = None,
        mentions: tuple[FakeAuthor, ...] = (),
    ) -> None:
        self.id = message_id
        self.author = author
        self.channel = channel
        self.content = content
        self.attachments = attachments
        self.reference = reference
        self.mentions = mentions


BOT = 9001


def _thread_message(channel: FakeChannel | None = None, **kwargs: object) -> FakeMessage:
    return FakeMessage(
        100,
        FakeAuthor(42),
        channel=channel or FakeChannel(505, parent_id=77, name="掃除して"),
        **kwargs,
    )


async def test_bot_own_message_is_dropped() -> None:
    incoming = await incoming_from_discord(FakeMessage(1, FakeAuthor(BOT, bot=True)), BOT)
    assert incoming is None


async def test_mention_to_bot_is_detected() -> None:
    incoming = await incoming_from_discord(
        _thread_message(mentions=(FakeAuthor(42), FakeAuthor(BOT))),
        BOT,
    )
    assert incoming is not None
    assert incoming.mentions_bot is True
    assert incoming.replies_to_bot is False


async def test_plain_message_has_no_addressing() -> None:
    incoming = await incoming_from_discord(_thread_message(), BOT)
    assert incoming is not None
    assert incoming.mentions_bot is False
    assert incoming.replies_to_bot is False


async def test_reply_to_bot_message_is_detected() -> None:
    incoming = await incoming_from_discord(
        _thread_message(
            reference=FakeReference(77),
            channel=FakeChannel(
                505,
                parent_id=77,
                name="掃除して",
                fetched=FakeMessage(77, FakeAuthor(BOT, bot=True)),
            ),
        ),
        BOT,
    )
    assert incoming is not None
    assert incoming.replies_to_bot is True


async def test_reply_to_other_user_is_not_addressed() -> None:
    incoming = await incoming_from_discord(
        _thread_message(
            reference=FakeReference(78),
            channel=FakeChannel(
                505,
                parent_id=77,
                name="掃除して",
                fetched=FakeMessage(78, FakeAuthor(43)),
            ),
        ),
        BOT,
    )
    assert incoming is not None
    assert incoming.replies_to_bot is False


async def test_resolved_reference_needs_no_fetch() -> None:
    resolved = FakeMessage(79, FakeAuthor(BOT, bot=True))
    incoming = await incoming_from_discord(
        _thread_message(reference=FakeReference(79, resolved=resolved)),
        BOT,
    )
    assert incoming is not None
    assert incoming.replies_to_bot is True


async def test_unresolvable_reply_is_not_addressed() -> None:
    incoming = await incoming_from_discord(
        _thread_message(
            reference=FakeReference(80),
            channel=FakeChannel(505, parent_id=77, name="掃除して", error=RuntimeError("gone")),
        ),
        BOT,
    )
    assert incoming is not None
    assert incoming.replies_to_bot is False


async def test_attachments_are_read_for_new_thread_starter() -> None:
    incoming = await incoming_from_discord(
        FakeMessage(
            505,
            FakeAuthor(42),
            channel=FakeChannel(505, parent_id=77, name="掃除して"),
            attachments=(FakeAttachment("design.png", b"png-bytes"),),
        ),
        BOT,
    )
    assert incoming is not None
    assert incoming.is_thread_starter is True
    assert incoming.attachments == (("design.png", b"png-bytes"),)


async def test_non_thread_message_has_no_thread_id() -> None:
    incoming = await incoming_from_discord(
        FakeMessage(1, FakeAuthor(42), channel=FakeChannel(9)),
        BOT,
    )
    assert incoming is not None
    assert incoming.thread_id is None
