"""Discord Forum への投稿口。``ForumBoard`` Protocol の実装だよ。

- みはり口調の本文はそのまま送る（LLM 変換なし）。
- ログは壁打ちにならないよう subtext（``-# ``）に丸める。
- Hermes Gateway は使わない。``discord.py`` の ForumChannel / Thread だけ触る。
"""

from __future__ import annotations

import inspect
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from mihari_room.contracts import Job, JobStatus

#: スレッド名の上限（Discord Forum の名前に合わせる）。
MAX_TITLE_LEN = 100
#: Discord 1 メッセージの上限。余裕を見て切り詰める。
MESSAGE_LIMIT = 2000
MESSAGE_HEADROOM = 100


def cap_title(title: str, limit: int = MAX_TITLE_LEN) -> str:
    """スレッド名を指定文字数で丸める。前後空白は落とす。"""
    return title.strip()[:limit]


def format_log_message(text: str) -> str:
    """ログ用に subtext（``-# ``）へ丸める。巨大な壁打ちにしない。"""
    lines = text.splitlines() or [""]
    # 空行も subtext に寄せる（Discord の subtext 崩れ防止）。
    formatted = "\n".join(f"-# {line}" if line.strip() else "-#" for line in lines)
    budget = MESSAGE_LIMIT - MESSAGE_HEADROOM
    if len(formatted) > budget:
        formatted = formatted[:budget] + "\n-# …（長いから省略したよ）"
    return formatted


class DiscordForumBoard:
    """ForumChannel からスレッドを作って進捗を投げる口。"""

    def __init__(
        self,
        forum: Any,
        get_thread: Callable[[int], Awaitable[Any] | Any],
    ) -> None:
        # forum: discord.ForumChannel 想定（create_thread / available_tags）。
        # get_thread: thread_id -> discord.Thread（send / edit できるもの）。
        self._forum = forum
        self._get_thread = get_thread

    @classmethod
    def from_client(cls, client: Any, forum_channel_id: int) -> DiscordForumBoard:
        """discord.Client から作る素朴な組み立て。本番用。"""
        forum = client.get_channel(forum_channel_id)
        return cls(forum, client.get_channel)

    async def _thread(self, thread_id: int) -> Any:
        thread = self._get_thread(thread_id)
        if inspect.isawaitable(thread):
            thread = await thread
        return thread

    async def create_thread(self, job: Job) -> int:
        """Forum 投稿を作る。タイトルは job.title（100 字丸め）。"""
        title = cap_title(job.title)
        body = job.body
        # discord.py: ForumChannel.create_thread(name=..., content=...) -> Thread
        created = await self._forum.create_thread(name=title, content=body)
        # バージョン差で tuple (Thread, Message) が返ることがある。
        thread = created[0] if isinstance(created, tuple) else created
        return thread.id

    async def set_tag(self, thread_id: int, status: JobStatus) -> None:
        """Forum タグを状態に合わせる。タグ名は ``status.discord_tag()``。"""
        wanted = status.discord_tag()
        tags = getattr(self._forum, "available_tags", []) or []
        tag = next((t for t in tags if getattr(t, "name", None) == wanted), None)
        if tag is None:
            # タグが無いと黙ってズレるので怒っておく。
            raise ValueError(f"Forum タグ {wanted!r} がないよ")
        thread = await self._thread(thread_id)
        await thread.edit(applied_tags=[tag])

    async def post_speech(self, thread_id: int, text: str) -> None:
        """みはり口調の本文をそのまま投げる。"""
        thread = await self._thread(thread_id)
        await thread.send(content=text)

    async def post_log(self, thread_id: int, text: str) -> None:
        """ログは subtext に丸めて小さく投げる。"""
        thread = await self._thread(thread_id)
        await thread.send(content=format_log_message(text))

    async def post_file(self, thread_id: int, path: Path) -> None:
        """ファイルを添付して投げる。"""
        thread = await self._thread(thread_id)
        try:
            import discord  # type: ignore[import-not-found]

            attached = discord.File(str(path))
        except ImportError:  # pragma: no cover - テスト時は discord 有り
            attached = str(path)  # type: ignore[assignment]
        await thread.send(file=attached)

    async def post_summary(self, thread_id: int, text: str) -> None:
        """最後に 1 通だけまとめて投げる。"""
        thread = await self._thread(thread_id)
        await thread.send(content=text)
