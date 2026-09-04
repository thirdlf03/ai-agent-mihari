"""Forum からの受信イベントを ``CreateJobRequest`` に寄せる小さな助っ人。

- discord.py のオブジェクトには直接触らない（テストしやすい形）。
- 呼び出し側で discord の Thread / Message から Event を作って渡してね。
- キャンセルはスレ立て人 or オーナー（``MIHARI_OWNER_ID``）だけ通す。
"""

from __future__ import annotations

import os
from dataclasses import dataclass

from mihari_room.contracts import CreateJobRequest, JobSource
from mihari_room.discord.board import MAX_TITLE_LEN

#: 環境変数名。Discord ユーザー ID（文字列）を入れる。
OWNER_ENV_VAR = "MIHARI_OWNER_ID"

#: 中止コマンドとみなす文言（正規化後に比較する）。
CANCEL_COMMANDS = frozenset(
    {
        "やめ",
        "やめて",
        "とめて",
        "止めて",
        "中止",
        "中止して",
        "キャンセル",
        "/cancel",
        "cancel",
        "stop",
    }
)

#: 文末の勢い（感嘆符・疑問符・句点）は落として比べる。
_TRAILING_NOISE = " \t\n　!！?？。．.、,､～〜…"


@dataclass(frozen=True, slots=True)
class ForumPostEvent:
    """Forum の新規投稿。スレッド名＋初回メッセージ。"""

    thread_id: int
    thread_name: str
    content: str
    author_id: int | str


@dataclass(frozen=True, slots=True)
class ThreadReplyEvent:
    """既存ジョブスレへの返信。追従依頼として扱う。"""

    thread_id: int
    content: str
    author_id: int | str


def load_owner_id(env: dict[str, str] | os._Environ[str] | None = None) -> str | None:
    """``MIHARI_OWNER_ID`` を読む。空文字は None に丸める。"""
    values = env if env is not None else os.environ
    raw = values.get(OWNER_ENV_VAR, "")
    cleaned = raw.strip()
    return cleaned or None


def _normalize_cancel_text(text: str) -> str:
    # 小文字化＋前後空白＋文末の勢いを落とす（「やめ！」も拾う）。
    lowered = text.strip().casefold()
    return lowered.rstrip(_TRAILING_NOISE).strip()


def is_cancel_command(text: str) -> bool:
    """中止コマンドっぽい文言か。``/cancel あとで`` のような引数付きも許す。"""
    normalized = _normalize_cancel_text(text)
    if normalized in CANCEL_COMMANDS:
        return True
    # スラッシュコマンドの引数付き（"/cancel now"）だけ許す。
    for base in ("/cancel", "cancel"):
        if normalized == base:
            return True
        if normalized.startswith(base + " ") or normalized.startswith(base + "　"):
            return True
    return False


def can_cancel(
    author_id: int | str,
    *,
    thread_starter_id: int | str,
    owner_id: int | str | None,
) -> bool:
    """スレ立て人 or オーナーだけ中止できる。"""
    author = str(author_id)
    if author == str(thread_starter_id):
        return True
    if owner_id is not None and author == str(owner_id):
        return True
    return False


def is_cancel_request(
    content: str,
    author_id: int | str,
    *,
    thread_starter_id: int | str,
    owner_id: int | str | None = None,
) -> bool:
    """中止コマンドかつ権限ありか。両方そろって初めて True。"""
    if owner_id is None:
        owner_id = load_owner_id()
    return is_cancel_command(content) and can_cancel(
        author_id, thread_starter_id=thread_starter_id, owner_id=owner_id
    )


def parse_forum_post(event: ForumPostEvent) -> CreateJobRequest:
    """Forum 新規投稿 → ジョブ作成依頼。``source=forum`` 固定。"""
    return CreateJobRequest(
        title=event.thread_name.strip()[:MAX_TITLE_LEN],
        body=event.content,
        source=JobSource.FORUM,
        requested_by=str(event.author_id),
        thread_id=event.thread_id,
    )


def parse_followup(event: ThreadReplyEvent, parent_job_id: str) -> CreateJobRequest:
    """スレ内返信 → 追従依頼。``source=followup`` 固定。"""
    # タイトルは先頭行から作る（CreateJobRequest に title が要るため）。
    first_line = ""
    for line in event.content.splitlines():
        if line.strip():
            first_line = line.strip()
            break
    return CreateJobRequest(
        title=first_line[:MAX_TITLE_LEN],
        body=event.content,
        source=JobSource.FOLLOWUP,
        requested_by=str(event.author_id),
        parent_id=parent_job_id,
        thread_id=event.thread_id,
    )
