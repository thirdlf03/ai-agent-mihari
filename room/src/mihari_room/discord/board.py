"""Discord Forum への投稿口。``ForumBoard`` Protocol の実装だよ。

- みはり口調の本文はそのまま送る（LLM 変換なし）。
- ログは壁打ちにならないよう subtext（``-# ``）に丸める。
- 進捗は本家 Gateway の accumulate と同じく、1 通を edit し続ける。
- Hermes Gateway は使わない。``discord.py`` の ForumChannel / Thread だけ触る。
"""

from __future__ import annotations

import asyncio
import inspect
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from mihari_room.contracts import Job, JobStatus

#: スレッド名の上限（Discord Forum の名前に合わせる）。
MAX_TITLE_LEN = 100
#: Discord 1 メッセージの上限。余裕を見て切り詰める。
MESSAGE_LIMIT = 2000
MESSAGE_HEADROOM = 100
#: typing 表示は約 10 秒しか持たないので、本家 Gateway と同じく打ち直す。
TYPING_INTERVAL_SEC = 8.0


def cap_title(title: str, limit: int = MAX_TITLE_LEN) -> str:
    """スレッド名を指定文字数で丸める。前後空白は落とす。"""
    return title.strip()[:limit]


def _raw_log_len(text: str) -> int:
    """省略前の subtext 長。溢れ判定用。"""
    lines = text.splitlines() or [""]
    return len("\n".join(f"-# {line}" if line.strip() else "-#" for line in lines))


def _log_budget() -> int:
    return MESSAGE_LIMIT - MESSAGE_HEADROOM


def format_log_message(text: str) -> str:
    """ログ用に subtext（``-# ``）へ丸める。巨大な壁打ちにしない。"""
    lines = text.splitlines() or [""]
    # 空行も subtext に寄せる（Discord の subtext 崩れ防止）。
    formatted = "\n".join(f"-# {line}" if line.strip() else "-#" for line in lines)
    budget = _log_budget()
    if len(formatted) > budget:
        formatted = formatted[:budget] + "\n-# …（長いから省略したよ）"
    return formatted


@dataclass
class _ProgressBubble:
    """スレッドごとの進捗バブル。本家の accumulate 1 通。"""

    message: Any = None
    lines: list[str] = field(default_factory=list)
    last: str | None = None
    repeat: int = 0


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
        self._typing_tasks: dict[int, asyncio.Task[None]] = {}
        self._progress: dict[int, _ProgressBubble] = {}

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

    def _seal_progress(self, thread_id: int) -> None:
        """最終返答が乗ったらバブルを閉じる。消さず、次のログは下に新規投稿。"""
        self._progress.pop(thread_id, None)

    async def _publish_progress(self, thread_id: int, bubble: _ProgressBubble) -> None:
        content = format_log_message("\n".join(bubble.lines))
        if bubble.message is None:
            thread = await self._thread(thread_id)
            bubble.message = await thread.send(content=content)
            return
        try:
            await bubble.message.edit(content=content)
        except Exception:
            thread = await self._thread(thread_id)
            bubble.message = await thread.send(content=content)

    def _absorb_log(self, bubble: _ProgressBubble, text: str) -> None:
        """同じ行の連打は ×N。本家 Gateway の dedup と同じ。"""
        if text == bubble.last:
            bubble.repeat += 1
            label = f"{text} (×{bubble.repeat + 1})"
            if bubble.lines:
                bubble.lines[-1] = label
            else:
                bubble.lines.append(label)
            return
        bubble.last = text
        bubble.repeat = 0
        bubble.lines.append(text)

    async def post_speech(self, thread_id: int, text: str) -> None:
        """みはり口調の本文をそのまま投げる。"""
        self._seal_progress(thread_id)
        thread = await self._thread(thread_id)
        await thread.send(content=text)

    async def post_log(self, thread_id: int, text: str) -> None:
        """進捗バブルを 1 通 edit する。溢れたら次の通を立てる。"""
        bubble = self._progress.get(thread_id)
        if bubble is None:
            bubble = _ProgressBubble()
            self._progress[thread_id] = bubble
        self._absorb_log(bubble, text)
        if len(bubble.lines) > 1 and _raw_log_len("\n".join(bubble.lines)) > _log_budget():
            overflow = bubble.lines.pop()
            self._seal_progress(thread_id)
            bubble = _ProgressBubble()
            self._progress[thread_id] = bubble
            self._absorb_log(bubble, overflow)
        await self._publish_progress(thread_id, bubble)

    async def post_file(self, thread_id: int, path: Path) -> None:
        """ファイルを添付して投げる。"""
        self._seal_progress(thread_id)
        thread = await self._thread(thread_id)
        try:
            import discord  # type: ignore[import-not-found]

            attached = discord.File(str(path))
        except ImportError:  # pragma: no cover - テスト時は discord 有り
            attached = str(path)  # type: ignore[assignment]
        await thread.send(file=attached)

    async def post_summary(self, thread_id: int, text: str) -> None:
        """最後に 1 通だけまとめて投げる。"""
        self._seal_progress(thread_id)
        thread = await self._thread(thread_id)
        await thread.send(content=text)

    async def start_typing(self, thread_id: int) -> None:
        """作業中の typing を回す。契約の必須メソッドではない。"""
        if thread_id in self._typing_tasks:
            return

        async def _loop() -> None:
            try:
                while True:
                    thread = await self._thread(thread_id)
                    trigger = getattr(thread, "trigger_typing", None)
                    if callable(trigger):
                        maybe = trigger()
                        if inspect.isawaitable(maybe):
                            await maybe
                    await asyncio.sleep(TYPING_INTERVAL_SEC)
            except asyncio.CancelledError:
                raise
            except Exception:
                return

        self._typing_tasks[thread_id] = asyncio.create_task(_loop())

    async def stop_typing(self, thread_id: int) -> None:
        task = self._typing_tasks.pop(thread_id, None)
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass


class BoundForumBoard:
    """Discord が起きるまで Forum 口を待たせる。"""

    def __init__(self) -> None:
        self._inner: DiscordForumBoard | None = None

    def bind(self, board: DiscordForumBoard) -> None:
        self._inner = board

    @property
    def is_ready(self) -> bool:
        return self._inner is not None

    def _get(self) -> DiscordForumBoard:
        if self._inner is None:
            raise RuntimeError("Discord がまだ起きていない")
        return self._inner

    async def create_thread(self, job: Job) -> int:
        return await self._get().create_thread(job)

    async def set_tag(self, thread_id: int, status: JobStatus) -> None:
        await self._get().set_tag(thread_id, status)

    async def post_speech(self, thread_id: int, text: str) -> None:
        await self._get().post_speech(thread_id, text)

    async def post_log(self, thread_id: int, text: str) -> None:
        await self._get().post_log(thread_id, text)

    async def post_file(self, thread_id: int, path: Path) -> None:
        await self._get().post_file(thread_id, path)

    async def post_summary(self, thread_id: int, text: str) -> None:
        await self._get().post_summary(thread_id, text)

    async def start_typing(self, thread_id: int) -> None:
        method = getattr(self._get(), "start_typing", None)
        if callable(method):
            await method(thread_id)

    async def stop_typing(self, thread_id: int) -> None:
        method = getattr(self._get(), "stop_typing", None)
        if callable(method):
            await method(thread_id)
