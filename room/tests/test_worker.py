"""HermesWorker のテスト。command= を渡した subprocess 経路。"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from mihari_room.contracts import (
    CreateJobRequest,
    Job,
    JobSource,
    JobStatus,
    ProgressEvent,
    ProgressKind,
)
from mihari_room.fakes import InMemoryJobStore
from mihari_room.worker import HermesWorker

FIXTURES = Path(__file__).parent / "fixtures"
FAKE_OK = str(FIXTURES / "fake_hermes_ok.py")
FAKE_FAIL = str(FIXTURES / "fake_hermes_fail.py")
FAKE_SLOW = str(FIXTURES / "fake_hermes_slow.py")


def _make_job(tmp_path: Path, title: str = "まとめ", body: str = "今日の分") -> Job:
    """tmp_path 上に input/output 付きの Job を作る。"""
    store = InMemoryJobStore(tmp_path)
    job = store.create(CreateJobRequest(title=title, body=body, source=JobSource.PET))
    (job.directory / "input" / "memo.txt").write_text("入力メモ", encoding="utf-8")
    return job


async def test_success_emits_speech_summary_and_file(tmp_path: Path) -> None:
    """成功時は DONE・SPEECH/SUMMARY・FILE を返す。"""
    job = _make_job(tmp_path)
    cwd_file = tmp_path / "cwd.txt"
    prompt_file = tmp_path / "prompt.txt"
    os.environ["FAKE_HERMES_CWD_FILE"] = str(cwd_file)
    os.environ["FAKE_HERMES_PROMPT_FILE"] = str(prompt_file)
    try:
        worker = HermesWorker(command=[sys.executable, FAKE_OK], timeout=30)
        events: list[ProgressEvent] = []

        async def on_progress(ev: ProgressEvent) -> None:
            events.append(ev)

        status = await worker.run(job, on_progress)
    finally:
        os.environ.pop("FAKE_HERMES_CWD_FILE", None)
        os.environ.pop("FAKE_HERMES_PROMPT_FILE", None)

    assert status is JobStatus.DONE
    kinds = [e.kind for e in events]
    # ツール風ログは LOG、最終返答は SPEECH 1 通。同じ文面の SUMMARY は出さない。
    assert ProgressKind.LOG in kinds
    assert ProgressKind.SPEECH in kinds
    assert ProgressKind.SUMMARY not in kinds
    # output/hello.txt の FILE イベントがある。
    file_events = [e for e in events if e.kind is ProgressKind.FILE]
    assert any(e.path is not None and e.path.name == "hello.txt" for e in file_events)
    assert (job.directory / "output" / "hello.txt").is_file()
    # cwd はジョブフォルダ、プロンプトはタイトル・本文・入出力指示を含む。
    assert cwd_file.read_text(encoding="utf-8") == str(job.directory)
    prompt_text = prompt_file.read_text(encoding="utf-8")
    assert "まとめ" in prompt_text
    assert "今日の分" in prompt_text
    assert "input" in prompt_text
    assert "output" in prompt_text


async def test_failure_returns_failed(tmp_path: Path) -> None:
    """exit 1 の偽 CLI は FAILED を返す。"""
    job = _make_job(tmp_path)
    worker = HermesWorker(command=[sys.executable, FAKE_FAIL], timeout=30)
    events: list[ProgressEvent] = []

    async def on_progress(ev: ProgressEvent) -> None:
        events.append(ev)

    status = await worker.run(job, on_progress)
    assert status is JobStatus.FAILED
    # 失敗時は FILE / SUMMARY を流さない。
    assert all(e.kind is not ProgressKind.FILE for e in events)
    assert all(e.kind is not ProgressKind.SUMMARY for e in events)


async def test_timeout_returns_failed(tmp_path: Path) -> None:
    """制限時間を超えたら FAILED を返す。"""
    job = _make_job(tmp_path)
    worker = HermesWorker(command=[sys.executable, FAKE_SLOW], timeout=1)
    events: list[ProgressEvent] = []

    async def on_progress(ev: ProgressEvent) -> None:
        events.append(ev)

    status = await worker.run(job, on_progress)
    assert status is JobStatus.FAILED


async def test_missing_command_returns_failed(tmp_path: Path) -> None:
    """存在しないコマンドは FAILED を返す。"""
    job = _make_job(tmp_path)
    worker = HermesWorker(command=["__no-such-hermes-binary__"], timeout=10)

    async def on_progress(_ev: ProgressEvent) -> None:
        pass

    assert await worker.run(job, on_progress) is JobStatus.FAILED


async def test_tokens_are_not_written_into_job_dir(tmp_path: Path, monkeypatch) -> None:
    """トークン類はジョブフォルダに書き込まない。"""
    secret = "sk-test-secret-do-not-leak-12345"
    monkeypatch.setenv("DISCORD_TOKEN", secret)
    monkeypatch.setenv("CODEX_API_KEY", secret)
    job = _make_job(tmp_path)
    worker = HermesWorker(command=[sys.executable, FAKE_OK], timeout=30)

    async def on_progress(_ev: ProgressEvent) -> None:
        pass

    assert await worker.run(job, on_progress) is JobStatus.DONE
    # ジョブフォルダ配下に秘密文字列が残っていないこと。
    for path in job.directory.rglob("*"):
        if path.is_file():
            assert secret not in path.read_text(encoding="utf-8", errors="replace")
