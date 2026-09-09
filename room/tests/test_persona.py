"""みはりちゃんの人格の適用と固定文言のスナップショット。

- 共通リソース（persona/mihari_persona.py）から Room が参照している
- 固定文言（受付・進捗・完了・失敗）が 1 箇所に揃っていて、みはりの口調（タメ口）で、
  失敗には理由と次の操作が載る
- 発話向け「30 文字以内」と Room の説明・完了報告の長さ制約が分かれている
- Room 専用 SOUL.md の種まきが個人用 Hermes（~/.hermes）に触れない
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from mihari_room.contracts import (
    CreateJobRequest,
    Job,
    JobSource,
    JobStatus,
)
from mihari_room.events import EventJournal
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.persona import (
    ROOM_SOUL_MD,
    SOUL_FILENAME,
    accepted_line,
    artifact_placed_private_line,
    cancel_accepted_line,
    cancel_denied_line,
    cancel_failed_line,
    cancelled_line,
    done_line,
    ensure_room_soul,
    failure_line,
    followup_again_line,
    followup_queued_line,
    memory_candidate_line,
    preview_posted_line,
    publish_failed_line,
    restart_line,
    screenshot_followup_posted_line,
    screenshot_posted_line,
    start_line,
    temp_deploy_posted_line,
    thread_create_failed_line,
)
from mihari_room.queue.file_queue import FileJobQueue
from mihari_room.store.file_store import FileJobStore
from tests.recording import RecordingBoard, ScriptedWorker

#: 人格属性（共通リソースから Room が引き写す値）。
EXPECTED_NAME = "みはり"
EXPECTED_FIRST_PERSON = "私"
EXPECTED_ADDRESS = "あなた"
EXPECTED_UTTERANCE_LIMIT = 30

#: 固定文言一式。ここを足すときはテストの一覧も足す。
FIXED_LINES: dict[str, str] = {
    "accepted": accepted_line("仕様まとめ"),
    "screenshot_posted": screenshot_posted_line(1),
    "screenshot_posted_many": screenshot_posted_line(2),
    "start": start_line("仕様まとめ"),
    "restart": restart_line("仕様まとめ"),
    "followup_queued": followup_queued_line("仕様まとめ"),
    "screenshot_followup_posted": screenshot_followup_posted_line(1),
    "followup_again": followup_again_line(),
    "cancelled_journal": cancelled_line(),
    "cancel_accepted": cancel_accepted_line(),
    "cancel_denied": cancel_denied_line(),
    "cancel_failed": cancel_failed_line(),
    "done": done_line(),
    "thread_create_failed": thread_create_failed_line(),
    "publish_failed": publish_failed_line(),
    "artifact_placed_private": artifact_placed_private_line(1),
    "preview_posted": preview_posted_line("https://preview.example.test/x"),
    "temp_deploy_posted": temp_deploy_posted_line("https://demo.example.workers.dev"),
    "memory_candidate": memory_candidate_line("MEMORY.md"),
}


def test_fixed_phrase_snapshot_matches_persona_voice() -> None:
    """固定文言がみはりの口調（タメ口・よ/ね）で、敬語を含まない。"""
    assert FIXED_LINES["accepted"].startswith("受け付けたよ。")
    assert FIXED_LINES["start"].startswith("はじめるね。")
    assert FIXED_LINES["restart"].startswith("再起動したよ。")
    assert FIXED_LINES["done"] == "やりきったよ。"
    for name, line in FIXED_LINES.items():
        assert line.strip(), name
        # タメ口。です/ます 調は使わない。
        assert "です" not in line, name
        assert "ます" not in line, name
        # 人格否定・侮辱・暴力・自傷は固定文言にも出さない。
        for banned in ("殺す", "死ね", "バカ", "馬鹿"):
            assert banned not in line, name


def test_failure_line_carries_reason_and_next_action() -> None:
    """失敗時は理由（分かれば）と次の操作を伝える。無い理由はでっち上げない。"""
    with_reason = failure_line("API キーが切れてた")
    assert with_reason.startswith("うまくいかなかったよ。")
    assert "API キーが切れてた" in with_reason
    assert "また頼んでみてね" in with_reason

    without_reason = failure_line()
    assert without_reason == "うまくいかなかったよ。また頼んでみてね。"
    # 分からない理由を書かない。
    assert "理由" not in without_reason


def test_identity_comes_from_shared_resource() -> None:
    """名前・一人称・呼び方・発話上限は共通リソースの値。"""
    from mihari_room import persona as room_persona

    assert room_persona.NAME == EXPECTED_NAME
    assert room_persona.FIRST_PERSON == EXPECTED_FIRST_PERSON
    assert room_persona.ADDRESS == EXPECTED_ADDRESS
    assert room_persona.UTTERANCE_CHAR_LIMIT == EXPECTED_UTTERANCE_LIMIT
    assert "みはり" in room_persona.IDENTITY_RULES
    assert "私" in room_persona.IDENTITY_RULES
    assert "あなた" in room_persona.IDENTITY_RULES


def test_shared_resource_is_single_source_of_persona() -> None:
    """Room の参照先（共通リソース）がリポジトリ直下にある。"""
    from mihari_room.persona import _load_shared_persona

    shared = _load_shared_persona()
    # PERSONA_RULES は IDENTITY + SPEECH + トーン例の合成（発話側のみ）。
    composed = (
        shared.IDENTITY_RULES + "\n" + shared.SPEECH_RULES + "\n" + shared.TONE_EXAMPLES + "\n"
    )
    assert shared.PERSONA_RULES == composed
    # Room が参照する共通リソースはリポジトリ直下の persona/ に置いてある。
    import mihari_room.persona as room_persona

    assert room_persona.NAME == shared.NAME
    assert room_persona.FIRST_PERSON == shared.FIRST_PERSON
    assert room_persona.ADDRESS == shared.ADDRESS
    assert room_persona.UTTERANCE_CHAR_LIMIT == shared.UTTERANCE_CHAR_LIMIT


def test_speech_limit_is_split_from_explanation_rules() -> None:
    """「30 文字以内」は発話側だけ。Room の説明・完了報告には掛けない。"""
    from mihari_room.persona import ROOM_EXPLANATION_RULES, SPEECH_RULES, _load_shared_persona

    shared = _load_shared_persona()
    assert "30 文字以内" in SPEECH_RULES
    assert "30 文字以内" in shared.PERSONA_RULES
    # 説明・完了報告の制約は別建て。30 文字制約は「適用しない」と明示する。
    assert "適用しない" in ROOM_EXPLANATION_RULES
    assert ROOM_EXPLANATION_RULES.strip()


def test_room_soul_md_keeps_voice_and_reports_separate() -> None:
    """SOUL.md は人格・発話と、説明/完了報告・成果物の文体を分けて書く。"""
    soul = ROOM_SOUL_MD
    assert "# 部屋のみはり" in soul
    assert EXPECTED_NAME in soul
    assert EXPECTED_FIRST_PERSON in soul
    assert EXPECTED_ADDRESS in soul
    # 発話は 30 文字以内。
    assert "30 文字以内" in soul
    # 説明・完了報告は 30 文字制約を掛けない（別の長さ制約）。
    assert "説明・完了報告" in soul
    # 成果物は依頼された文体を優先し、キャラクターの口調を押し付けない。
    assert "依頼された文体・形式を優先" in soul
    # できていないことをできたと述べない。
    assert "できていないこと" in soul
    assert "完了した" in soul


def test_ensure_room_soul_seeds_once_and_never_overwrites(tmp_path: Path) -> None:
    """SOUL.md は無いときだけ作る。既存（空でも）は触らない。"""
    home = tmp_path / "hermes-home"
    assert not (home / SOUL_FILENAME).exists()

    first = ensure_room_soul(home)
    assert first.name == SOUL_FILENAME
    assert first.read_text(encoding="utf-8") == ROOM_SOUL_MD

    # 2 回目は何もしない（中身は同じまま）。
    again = ensure_room_soul(home)
    assert again == first
    assert again.read_text(encoding="utf-8") == ROOM_SOUL_MD

    # カスタム SOUL.md は上書きしない。
    first.write_text("カスタム人格", encoding="utf-8")
    ensure_room_soul(home)
    assert first.read_text(encoding="utf-8") == "カスタム人格"

    # 空ファイル（無効化の印）も上書きしない。
    empty_home = tmp_path / "empty-home"
    empty_soul = empty_home / SOUL_FILENAME
    empty_soul.parent.mkdir(parents=True)
    empty_soul.write_text("", encoding="utf-8")
    ensure_room_soul(empty_home)
    assert empty_soul.read_text(encoding="utf-8") == ""


def test_ensure_room_soul_only_touches_the_given_home(tmp_path: Path, monkeypatch) -> None:
    """個人用 Hermes（~/.hermes）には触れない。渡した HERMES_HOME だけを作る。"""
    fake_home = tmp_path / "home" / ".hermes"
    monkeypatch.setenv("HOME", str(fake_home))
    target = tmp_path / "room-profile"
    ensure_room_soul(target)
    assert (target / SOUL_FILENAME).is_file()
    assert not fake_home.exists()


# --- オーケストレータの失敗・完了の文面 --------------------------------------


def _make_room(
    tmp_path: Path,
    worker: ScriptedWorker,
) -> tuple[RoomOrchestrator, FileJobStore, RecordingBoard]:
    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    orch = RoomOrchestrator(store, FileJobQueue(store), board, worker)
    return orch, store, board


async def test_orchestrator_failed_posts_reason_and_next_action(tmp_path: Path) -> None:
    """失敗時は Forum に理由＋次の操作の一言を出す（無い理由は書かない）。"""
    worker = ScriptedWorker([], result=JobStatus.FAILED)
    orch, store, board = _make_room(tmp_path, worker)
    orch.start_pump()
    job = await orch.submit(CreateJobRequest(title="失敗", body="x", source=JobSource.PET))
    for _ in range(30):
        await asyncio.sleep(0)
        await asyncio.sleep(0.01)
    await orch.aclose()

    assert store.get(job.id).status is JobStatus.FAILED
    assert board.speech, "失敗の一言が Forum に出ていない"
    line = board.speech[-1][1]
    assert line.startswith("うまくいかなかったよ。")
    assert "また頼んでみてね" in line
    events = EventJournal.for_job(store.job_dir(job.id)).events()
    failed = [e for e in events if e["phase"] == "failed"]
    assert failed and failed[-1]["text"] == line


async def test_orchestrator_failed_uses_worker_error_as_reason(tmp_path: Path) -> None:
    """worker が投げた例外の文面は理由として一言に載る。"""

    class BoomWorker:
        async def run(self, job: Job, on_progress) -> JobStatus:
            raise RuntimeError("ディスクが壊れた")

    store = FileJobStore(tmp_path)
    board = RecordingBoard()
    orch = RoomOrchestrator(store, FileJobQueue(store), board, BoomWorker())
    orch.start_pump()
    await orch.submit(CreateJobRequest(title="転ぶ", body="x", source=JobSource.PET))
    for _ in range(30):
        await asyncio.sleep(0)
        await asyncio.sleep(0.01)
    await orch.aclose()

    line = board.speech[-1][1]
    assert "ディスクが壊れた" in line
    assert "また頼んでみてね" in line


async def test_orchestrator_done_falls_back_to_persona_line(tmp_path: Path) -> None:
    """Hermes の返答が無くても完了の固定文言（やりきったよ。）を残す。"""
    worker = ScriptedWorker([], result=JobStatus.DONE)
    orch, store, board = _make_room(tmp_path, worker)
    orch.start_pump()
    job = await orch.submit(CreateJobRequest(title="空", body="x", source=JobSource.PET))
    for _ in range(30):
        await asyncio.sleep(0)
        await asyncio.sleep(0.01)
    await orch.aclose()

    assert store.get(job.id).status is JobStatus.DONE
    assert board.summaries == []
    events = EventJournal.for_job(store.job_dir(job.id)).events()
    done_events = [e for e in events if e["phase"] == "done"]
    assert done_events and done_events[-1]["text"] == done_line()
