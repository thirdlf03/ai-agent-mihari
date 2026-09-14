"""バックフィルのテスト。全チャンネル全履歴を再開可能に遡るやつ。偽 Discord で完結する。"""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

from mihari_room.archive.cli import main as archive_main
from mihari_room.archive.config import ArchiveConfig
from mihari_room.archive.db import ArchiveDatabase
from mihari_room.archive.fetch import SafeFetcher
from mihari_room.archive.ingest import ArchiveIngester

from .archive_helpers import fake_message, fake_resolver, make_client


class Forbidden(Exception):
    """discord.Forbidden 風。``_is_forbidden`` はクラス名で判定する。"""


def _async_iter(items: list[Any]):
    """``archived_threads`` 系が返す async iterator の代役。"""

    async def _gen():
        for item in items:
            yield item

    return _gen


class FakeChannel:
    """``history()`` が Discord と同じ before ページングをする偽チャンネル。

    parent を持てばスレッド扱いになる。``error`` は反復開始時、``fail_after`` は
    N 件 yield した後に投げる（どちらも実際の history と同じく反復中の例外）。
    """

    def __init__(
        self,
        channel_id: int,
        *,
        name: str = "main",
        parent: Any = None,
        messages: tuple[Any, ...] | list[Any] = (),
        threads: tuple[Any, ...] | list[Any] = (),
        archived: tuple[Any, ...] | list[Any] = (),
        private_archived: tuple[Any, ...] | list[Any] = (),
        supports_private: bool = True,
        error: BaseException | None = None,
        fail_after: int | None = None,
    ) -> None:
        self.id = channel_id
        self.name = name
        self.parent = parent
        self.threads = list(threads)
        self._messages = list(messages)
        self._archived = list(archived)
        self._private_archived = list(private_archived)
        self._supports_private = supports_private
        self._error = error
        self._fail_after = fail_after
        self.history_calls: list[dict[str, Any]] = []
        self.archived_calls: list[dict[str, Any]] = []

    def history(self, *, limit=None, before=None, oldest_first=False, after=None):
        self.history_calls.append(
            {
                "limit": limit,
                "before": getattr(before, "id", before),
                "oldest_first": oldest_first,
            }
        )
        error = self._error
        fail_after = self._fail_after
        items = list(self._messages)
        before_id = getattr(before, "id", before)
        if before_id is not None:
            items = [m for m in items if m.id < before_id]
        items.sort(key=lambda m: m.id, reverse=not oldest_first)
        if limit is not None:
            items = items[:limit]

        async def _gen():
            if error is not None:
                raise error
            for index, message in enumerate(items):
                if fail_after is not None and index >= fail_after:
                    raise RuntimeError("history が途中で死んだ")
                yield message

        return _gen()

    def archived_threads(self, *, limit=None, before=None, private=False, joined=False):
        if (private or joined) and not self._supports_private:
            raise TypeError("archived_threads() got an unexpected keyword argument 'private'")
        self.archived_calls.append({"limit": limit, "private": private, "joined": joined})
        threads = list(self._private_archived if private else self._archived)
        if limit is not None:
            threads = threads[:limit]
        return _async_iter(threads)()


def _config(root: Path, **overrides: object) -> ArchiveConfig:
    values: dict[str, object] = {
        "root": root,
        "channel_ids": (),
        "queue_size": 16,
        "backfill_page_size": 1000,
        "backfill_page_interval": 0.0,
        "fetch_attachments": False,
    }
    values.update(overrides)
    return ArchiveConfig(**values)  # type: ignore[arg-type]


def _ingester(config: ArchiveConfig, db: ArchiveDatabase | None = None) -> ArchiveIngester:
    client = make_client()
    return ArchiveIngester(
        config, db, fetcher=SafeFetcher(client=client, resolver=fake_resolver)
    )


def _messages(channel: Any, ids: range | list[int]) -> list[Any]:
    return [fake_message(i, f"本文 {i}", channel=channel) for i in ids]


def _count_messages(db: ArchiveDatabase) -> int:
    return db._conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]


async def test_backfill_paginates_to_oldest(tmp_path: Path) -> None:
    """2500 件を page_size=1000 で 3 ページ遡り、最古まで全部入る。"""
    config = _config(tmp_path, backfill_page_size=1000)
    ing = _ingester(config)
    channel = FakeChannel(111)
    channel._messages = _messages(channel, list(range(1, 2501)))
    guild = SimpleNamespace(id=777, text_channels=[channel], forums=[])

    inserted = await ing.backfill_guilds([guild])
    await ing.aclose()

    assert inserted == 2500
    calls = channel.history_calls
    assert len(calls) == 3
    assert calls[0]["before"] is None and calls[0]["oldest_first"] is False
    assert calls[1]["before"] == 1501
    assert calls[2]["before"] == 501

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert _count_messages(db) == 2500
        state = db.backfill_state("channel:111")
        assert state is not None
        assert state["backfill_done"] is True
        assert state["oldest_message_id"] == 1
        assert state["channel_id"] == 111
        assert state["thread_id"] is None
    finally:
        db.close()


async def test_backfill_resumes_from_progress(tmp_path: Path) -> None:
    """progress の oldest_message_id から続きを取る。done=1 は skip。"""
    db = ArchiveDatabase(tmp_path / "messages.db")
    db.update_backfill(
        "channel:111",
        guild_id=777,
        channel_id=111,
        thread_id=None,
        name="main",
        oldest_message_id=1500,
        done=False,
    )
    db.update_backfill(
        "channel:222",
        guild_id=777,
        channel_id=222,
        thread_id=None,
        name="done-ch",
        oldest_message_id=1,
        done=True,
    )
    ing = _ingester(_config(tmp_path), db)
    ch_main = FakeChannel(111, name="main")
    ch_main._messages = _messages(ch_main, list(range(1000, 2001)))
    ch_done = FakeChannel(222, name="done-ch")
    ch_done._messages = _messages(ch_done, [5, 6, 7])
    guild = SimpleNamespace(id=777, text_channels=[ch_main, ch_done], forums=[])

    await ing.backfill_guilds([guild])

    # channel:111 は before=1500 から再開。1500 以上は取りに行かない。
    assert ch_main.history_calls[0]["before"] == 1500
    # done=1 の channel:222 は history を呼ばない。
    assert ch_done.history_calls == []
    assert _count_messages(db) == 500  # id 1000..1499
    assert db.get_message(1600) is None
    state = db.backfill_state("channel:111")
    assert state is not None and state["backfill_done"] is True
    assert state["oldest_message_id"] == 1000
    await ing.aclose()


async def test_backfill_resume_point_from_existing_messages(tmp_path: Path) -> None:
    """progress 未登録でも messages.db の最古 ID から再開する。"""
    db = ArchiveDatabase(tmp_path / "messages.db")
    channel = FakeChannel(111, name="main")
    # 既に収録済みの最古が 500 である想定。
    db.upsert_message(_stored(channel, 500))
    db.upsert_message(_stored(channel, 800))
    ing = _ingester(_config(tmp_path), db)
    channel._messages = _messages(channel, list(range(100, 901)))
    guild = SimpleNamespace(id=777, text_channels=[channel], forums=[])

    await ing.backfill_guilds([guild])

    assert channel.history_calls[0]["before"] == 500
    assert db.get_message(700) is None  # 500 より新しい未収録分は対象外（catchup の領分）
    assert _count_messages(db) == 402  # 既存 2 件 + id 100..499 の 400 件
    await ing.aclose()


def _stored(channel: Any, message_id: int) -> Any:
    """fake_message を db.upsert_message へ通す形に変換する。"""
    from mihari_room.archive.ingest import to_stored_message

    return to_stored_message(fake_message(message_id, f"既存 {message_id}", channel=channel))


async def test_backfill_enumerates_channels_threads_and_forums(tmp_path: Path) -> None:
    """text + アクティブ/アーカイブ済み/非公開スレッド + forum スレが対象になる。"""
    ing = _ingester(_config(tmp_path))
    parent = FakeChannel(111, name="本家")
    parent._messages = _messages(parent, [10])
    active_thread = FakeChannel(910, name="活スレ", parent=parent)
    active_thread._messages = _messages(active_thread, [20])
    archived_thread = FakeChannel(911, name="蔵スレ", parent=parent)
    archived_thread._messages = _messages(archived_thread, [30])
    private_thread = FakeChannel(912, name="秘スレ", parent=parent)
    private_thread._messages = _messages(private_thread, [40])
    parent.threads = [active_thread]
    parent._archived = [archived_thread]
    parent._private_archived = [private_thread]

    forum = FakeChannel(220, name="掲示板", supports_private=False)
    forum_thread = FakeChannel(920, name="forumスレ", parent=forum)
    forum_thread._messages = _messages(forum_thread, [50])
    forum_archived = FakeChannel(921, name="forum蔵スレ", parent=forum)
    forum_archived._messages = _messages(forum_archived, [60])
    forum.threads = [forum_thread]
    forum._archived = [forum_archived]

    guild = SimpleNamespace(id=777, text_channels=[parent], forums=[forum])

    await ing.backfill_guilds([guild])
    await ing.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        states = {row["scope_key"]: row for row in db.list_backfill_status()}
        expected = {
            "channel:111",
            "thread:910",
            "thread:911",
            "thread:912",
            "thread:920",
            "thread:921",
        }
        assert expected <= set(states)
        assert all(states[key]["backfill_done"] for key in expected)
        # アーカイブ列挙は limit=None で呼ばれている。
        assert parent.archived_calls[0]["limit"] is None
        # スレッドのメッセージは thread_id 付きで入る。
        assert db.get_message(30).thread_id == 911
        assert db.get_message(50).thread_id == 920
        assert db.get_message(50).channel_id == 220
        # 非公開アーカイブも private 経路で拾えている。
        assert any(call["private"] for call in parent.archived_calls)
    finally:
        db.close()


async def test_backfill_is_idempotent(tmp_path: Path) -> None:
    """進捗を戻して同じ範囲を2回流しても messages は増えない。"""
    db = ArchiveDatabase(tmp_path / "messages.db")
    config = _config(tmp_path)
    ing = _ingester(config, db)
    channel = FakeChannel(111)
    channel._messages = _messages(channel, list(range(1, 101)))
    guild = SimpleNamespace(id=777, text_channels=[channel], forums=[])

    await ing.backfill_guilds([guild])
    assert _count_messages(db) == 100

    # 未完了に戻して全範囲をもう一度流す。
    db.update_backfill(
        "channel:111",
        guild_id=777,
        channel_id=111,
        thread_id=None,
        name="main",
        oldest_message_id=None,
        done=False,
    )
    await ing.backfill_guilds([guild])
    assert _count_messages(db) == 100
    await ing.aclose()


async def test_backfill_forbidden_marks_done_and_continues(tmp_path: Path) -> None:
    """Forbidden のスコープは done 記録で skip し、他スコープは続行する。"""
    db = ArchiveDatabase(tmp_path / "messages.db")
    ing = _ingester(_config(tmp_path), db)
    forbidden = FakeChannel(111, name="閉鎖", error=Forbidden("no"))
    ok_channel = FakeChannel(222, name="開放")
    ok_channel._messages = _messages(ok_channel, [1, 2, 3])
    guild = SimpleNamespace(id=777, text_channels=[forbidden, ok_channel], forums=[])

    await ing.backfill_guilds([guild])

    state = db.backfill_state("channel:111")
    assert state is not None and state["backfill_done"] is True
    assert "forbidden" in state["name"]
    ok_state = db.backfill_state("channel:222")
    assert ok_state is not None and ok_state["backfill_done"] is True
    assert _count_messages(db) == 3
    await ing.aclose()


async def test_backfill_failure_keeps_progress_for_resume(tmp_path: Path) -> None:
    """history が途中で失敗しても進捗が残り、次回はそこから再開する。"""
    db = ArchiveDatabase(tmp_path / "messages.db")
    config = _config(tmp_path, backfill_page_size=1000)
    ing = _ingester(config, db)
    channel = FakeChannel(111, fail_after=400)
    channel._messages = _messages(channel, list(range(1, 2001)))
    guild = SimpleNamespace(id=777, text_channels=[channel], forums=[])

    await ing.backfill_guilds([guild])
    state = db.backfill_state("channel:111")
    assert state is not None and state["backfill_done"] is False
    assert state["oldest_message_id"] == 1601  # 400 件取れた時点の最小 ID
    first_count = _count_messages(db)
    assert first_count == 400

    # 回復したチャンネルで再実行 → 1601 より前から再開して完走する。
    channel._fail_after = None
    channel.history_calls.clear()
    await ing.backfill_guilds([guild])

    assert channel.history_calls[0]["before"] == 1601
    assert _count_messages(db) == 2000
    state = db.backfill_state("channel:111")
    assert state is not None and state["backfill_done"] is True
    assert state["oldest_message_id"] == 1
    await ing.aclose()


async def test_backfill_client_iterates_all_guilds(tmp_path: Path) -> None:
    """backfill_client は client.guilds の全ギルドを回る。"""
    ing = _ingester(_config(tmp_path))
    ch_a = FakeChannel(111)
    ch_a._messages = _messages(ch_a, [1])
    ch_b = FakeChannel(222)
    ch_b._messages = _messages(ch_b, [2])
    guild_a = SimpleNamespace(id=777, text_channels=[ch_a], forums=[])
    guild_b = SimpleNamespace(id=888, text_channels=[ch_b], forums=[])
    client = SimpleNamespace(guilds=[guild_a, guild_b])

    inserted = await ing.backfill_client(client)
    await ing.aclose()
    assert inserted == 2

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        states = {row["scope_key"] for row in db.list_backfill_status()}
        assert {"channel:111", "channel:222"} <= states
        by_scope = {row["scope_key"]: row for row in db.list_backfill_status()}
        assert by_scope["channel:111"]["guild_id"] == 777
        assert by_scope["channel:222"]["guild_id"] == 888
    finally:
        db.close()


async def test_backfill_progress_callback(tmp_path: Path) -> None:
    """progress コールバックはスコープごとの結果を受け取る。"""
    ing = _ingester(_config(tmp_path))
    channel = FakeChannel(111)
    channel._messages = _messages(channel, [1, 2])
    guild = SimpleNamespace(id=777, text_channels=[channel], forums=[])
    seen: list[dict[str, Any]] = []

    await ing.backfill_guilds([guild], progress=seen.append)
    await ing.aclose()

    assert len(seen) == 1
    assert seen[0]["scope_key"] == "channel:111"
    assert seen[0]["done"] is True
    assert seen[0]["inserted"] == 2


async def test_backfill_private_archived_attribute(tmp_path: Path) -> None:
    """private_archived_threads 属性を持つチャンネルはそこからも列挙する。"""
    ing = _ingester(_config(tmp_path))
    channel = FakeChannel(111)
    channel._messages = _messages(channel, [1])
    private_thread = FakeChannel(930, name="属性スレ", parent=channel)
    private_thread._messages = _messages(private_thread, [70])
    channel.private_archived_threads = lambda *, limit=None: _async_iter([private_thread])()
    guild = SimpleNamespace(id=777, text_channels=[channel], forums=[])

    await ing.backfill_guilds([guild])
    await ing.aclose()

    db = ArchiveDatabase(tmp_path / "messages.db")
    try:
        assert db.get_message(70) is not None
        assert db.backfill_state("thread:930")["backfill_done"] is True
    finally:
        db.close()


def test_archive_commands_include_backfill_and_status() -> None:
    from mihari_room import cli as room_cli

    assert {"backfill", "status"} <= room_cli._ARCHIVE_COMMANDS


def test_cli_status_outputs_progress(
    tmp_path: Path, capsys: pytest.CaptureFixture
) -> None:
    root = tmp_path / "room"
    root.mkdir(parents=True)
    db = ArchiveDatabase(root / "messages.db")
    db.update_backfill(
        "channel:111",
        guild_id=777,
        channel_id=111,
        thread_id=None,
        name="main",
        oldest_message_id=4321,
        done=False,
    )
    db.update_backfill(
        "thread:910",
        guild_id=777,
        channel_id=111,
        thread_id=910,
        name="スレ",
        oldest_message_id=1,
        done=True,
    )
    db.close()

    code = archive_main(["status", "--root", str(root)])
    assert code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "status"
    assert payload["total_scopes"] == 2
    assert payload["done_scopes"] == 1
    by_key = {row["scope_key"]: row for row in payload["scopes"]}
    assert by_key["channel:111"]["oldest_message_id"] == 4321
    assert by_key["channel:111"]["backfill_done"] is False
    assert by_key["thread:910"]["backfill_done"] is True


def test_cli_backfill_requires_token(
    tmp_path: Path, capsys: pytest.CaptureFixture, monkeypatch: pytest.MonkeyPatch
) -> None:
    """DISCORD_BOT_TOKEN が無い backfill は JSON エラーで落ちる。"""
    monkeypatch.delenv("DISCORD_BOT_TOKEN", raising=False)
    root = tmp_path / "room"
    root.mkdir(parents=True)
    code = archive_main(["backfill", "--root", str(root)])
    assert code == 1
    payload = json.loads(capsys.readouterr().out)
    assert "DISCORD_BOT_TOKEN" in payload["error"]
