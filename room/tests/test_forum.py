"""Forum の口（DiscordForumBoard）と受信ヘルパーのテスト。

- discord.py は触らない。MagicMock で ForumChannel / Thread を偽装する。
- Job 作成は InMemoryJobStore を使う（仮実装の契約確認ついで）。
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

from mihari_room.contracts import CreateJobRequest, JobSource, JobStatus
from mihari_room.discord.board import DiscordForumBoard, format_log_message
from mihari_room.discord.inbound import (
    ForumPostEvent,
    ThreadReplyEvent,
    is_cancel_command,
    is_cancel_request,
    parse_followup,
    parse_forum_post,
)
from mihari_room.fakes import InMemoryJobStore


def _make_board() -> tuple[DiscordForumBoard, MagicMock, AsyncMock]:
    # ForumChannel 偽装＋スレッド解決の偽装。
    forum = MagicMock()
    thread = AsyncMock()
    created_thread = SimpleNamespace(id=12345)
    forum.create_thread = AsyncMock(return_value=created_thread)
    board = DiscordForumBoard(forum, lambda thread_id: thread)
    return board, forum, thread


def _make_job(tmp_path: Path, title: str = "ログまとめて", body: str = "今日の分"):
    # InMemoryJobStore で Job を作る（本番 store の代わり）。
    store = InMemoryJobStore(tmp_path)
    return store.create(CreateJobRequest(title=title, body=body, source=JobSource.FORUM))


async def test_create_thread_called_with_title_and_body(tmp_path: Path) -> None:
    board, forum, _ = _make_board()
    job = _make_job(tmp_path, title="お掃除して", body="部屋のログ整理")
    thread_id = await board.create_thread(job)
    assert thread_id == 12345
    forum.create_thread.assert_awaited_once()
    kwargs = forum.create_thread.await_args.kwargs
    assert kwargs["name"] == "お掃除して"
    assert kwargs["content"] == "部屋のログ整理"


async def test_create_thread_caps_title_at_100_chars(tmp_path: Path) -> None:
    board, forum, _ = _make_board()
    job = _make_job(tmp_path, title="あ" * 150, body="本文")
    await board.create_thread(job)
    kwargs = forum.create_thread.await_args.kwargs
    assert len(kwargs["name"]) == 100


async def test_set_tag_uses_status_tag_names() -> None:
    # 全ステータスのタグ名（待ち・作業中・完了・失敗・中断）を確認。
    expected = {
        JobStatus.QUEUED: "待ち",
        JobStatus.RUNNING: "作業中",
        JobStatus.DONE: "完了",
        JobStatus.FAILED: "失敗",
        JobStatus.CANCELLED: "中断",
    }
    for status, tag_name in expected.items():
        board, forum, thread = _make_board()
        tag = SimpleNamespace(name=tag_name)
        other = SimpleNamespace(name="関係ない")
        forum.available_tags = [other, tag]
        await board.set_tag(999, status)
        thread.edit.assert_awaited_once()
        applied = thread.edit.await_args.kwargs["applied_tags"]
        assert [t.name for t in applied] == [tag_name]


async def test_post_speech_sends_text_as_is() -> None:
    board, _, thread = _make_board()
    await board.post_speech(1, "了解だよ！すぐやるね")
    thread.send.assert_awaited_once_with(content="了解だよ！すぐやるね")


async def test_post_log_uses_subtext_not_wall() -> None:
    board, _, thread = _make_board()
    await board.post_log(1, "line1\nline2")
    (call,) = thread.send.await_args_list
    content = call.kwargs["content"]
    # subtext（-# ）で小さく出す。素の壁打ちはダメ。
    assert content == format_log_message("line1\nline2")
    assert "-# " in content
    assert content.splitlines()[0].startswith("-# ")


async def test_post_log_truncates_huge_text() -> None:
    board, _, thread = _make_board()
    await board.post_log(1, "あ" * 5000)
    (call,) = thread.send.await_args_list
    assert len(call.kwargs["content"]) <= 2000


async def test_post_file_attaches_file(tmp_path: Path) -> None:
    board, _, thread = _make_board()
    target = tmp_path / "result.txt"
    target.write_text("できたよ")
    await board.post_file(7, target)
    thread.send.assert_awaited_once()
    sent_file = thread.send.await_args.kwargs["file"]
    # discord.File は filename を持つ。添付なしはダメ。
    filename = getattr(sent_file, "filename", str(sent_file))
    assert "result.txt" in str(filename)


async def test_post_summary_sends_single_message() -> None:
    board, _, thread = _make_board()
    await board.post_summary(3, "まとめだよ")
    thread.send.assert_awaited_once_with(content="まとめだよ")


def test_inbound_forum_post_to_create_request() -> None:
    event = ForumPostEvent(thread_id=111, thread_name="掃除して", content="床もね", author_id=222)
    req = parse_forum_post(event)
    assert req.source is JobSource.FORUM
    assert req.requested_by == "222"
    assert req.title == "掃除して"
    assert req.body == "床もね"
    assert req.thread_id == 111


def test_inbound_reply_to_followup() -> None:
    event = ThreadReplyEvent(thread_id=111, content="あと窓もお願い", author_id=333)
    req = parse_followup(event, parent_job_id="abc123")
    assert req.source is JobSource.FOLLOWUP
    assert req.parent_id == "abc123"
    assert req.thread_id == 111
    assert req.requested_by == "333"
    assert req.body == "あと窓もお願い"


def test_cancel_command_variants() -> None:
    assert is_cancel_command("やめ")
    assert is_cancel_command("やめ！")
    assert is_cancel_command("/cancel")
    assert is_cancel_command("/cancel now")
    assert is_cancel_command("キャンセル")
    assert not is_cancel_command("続けて")
    assert not is_cancel_command("やめるほどでもない")


def test_cancel_allowed_for_starter_and_owner_denied_for_stranger() -> None:
    # スレ立て人は OK。
    assert is_cancel_request("やめ", 100, thread_starter_id=100, owner_id="999") is True
    # オーナーは OK。
    assert is_cancel_request("/cancel", 999, thread_starter_id=100, owner_id="999") is True
    # 知らない人はダメ。
    assert is_cancel_request("やめ", 555, thread_starter_id=100, owner_id="999") is False
    # 合言葉じゃないと権限があってもダメ。
    assert is_cancel_request("続けて", 100, thread_starter_id=100, owner_id="999") is False


async def test_typing_loop_triggers_and_stops(monkeypatch) -> None:
    import asyncio

    from mihari_room.discord import board as board_mod

    monkeypatch.setattr(board_mod, "TYPING_INTERVAL_SEC", 0.01)
    board, _, thread = _make_board()
    thread.trigger_typing = AsyncMock()
    await board.start_typing(42)
    await asyncio.sleep(0.05)
    await board.stop_typing(42)
    assert thread.trigger_typing.await_count >= 1
    assert 42 not in board._typing_tasks


async def test_progress_edits_one_message() -> None:
    board, _, thread = _make_board()
    msg = SimpleNamespace()
    msg.edit = AsyncMock()
    thread.send = AsyncMock(return_value=msg)
    await board.post_log(1, "📖 Reading memo.txt")
    await board.post_log(1, "✏️ Writing output/hello.txt")
    thread.send.assert_awaited_once()
    msg.edit.assert_awaited_once()
    content = msg.edit.await_args.kwargs["content"]
    assert "Reading memo.txt" in content
    assert "Writing output/hello.txt" in content
    assert content.startswith("-# ")


async def test_progress_dedups_repeated_line() -> None:
    board, _, thread = _make_board()
    msg = SimpleNamespace()
    msg.edit = AsyncMock()
    thread.send = AsyncMock(return_value=msg)
    await board.post_log(1, "⚙️ terminal: ls")
    await board.post_log(1, "⚙️ terminal: ls")
    content = msg.edit.await_args.kwargs["content"]
    assert "×2" in content
    thread.send.assert_awaited_once()


async def test_speech_seals_progress_so_next_log_is_new() -> None:
    board, _, thread = _make_board()
    first = SimpleNamespace(edit=AsyncMock())
    second = SimpleNamespace(edit=AsyncMock())
    thread.send = AsyncMock(side_effect=[first, SimpleNamespace(), second])
    await board.post_log(1, "📖 Reading")
    await board.post_speech(1, "できたよ")
    await board.post_log(1, "📖 Reading more")
    assert thread.send.await_count == 3
    assert first.edit.await_count == 0


async def test_progress_starts_new_bubble_when_full(monkeypatch) -> None:
    from mihari_room.discord import board as board_mod

    monkeypatch.setattr(board_mod, "MESSAGE_LIMIT", 80)
    monkeypatch.setattr(board_mod, "MESSAGE_HEADROOM", 10)
    board, _, thread = _make_board()
    first = SimpleNamespace(edit=AsyncMock())
    second = SimpleNamespace(edit=AsyncMock())
    thread.send = AsyncMock(side_effect=[first, second])
    await board.post_log(1, "a" * 40)
    await board.post_log(1, "b" * 40)
    assert thread.send.await_count == 2
    first.edit.assert_not_called()


