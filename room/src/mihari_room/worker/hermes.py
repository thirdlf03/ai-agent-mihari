"""Hermes 互換 CLI を subprocess で叩く JobWorker。"""

from __future__ import annotations

import asyncio
import os
from collections.abc import Awaitable, Callable, Sequence
from pathlib import Path

from mihari_room.contracts import (
    INPUT_DIRNAME,
    OUTPUT_DIRNAME,
    Job,
    JobStatus,
    ProgressEvent,
    ProgressKind,
)

# タイムアウトの既定値（15 分）。
DEFAULT_TIMEOUT = 15 * 60

# 既定コマンド。末尾にプロンプトを 1 引数として足す。
DEFAULT_COMMAND: tuple[str, ...] = ("hermes", "-z")

# ツール/デバッグ出力とみなす行頭（小文字で比較するもの）。
_LOG_PREFIXES = (
    "tool",
    "debug",
    "log",
    "trace",
    "exec",
    "running",
    "calling",
    "invoke",
    "command",
    "thinking",
    "working",
)


def build_prompt(job: Job) -> str:
    """Hermes に渡すプロンプトを作る。タイトル・本文・入出力の約束を含む。"""
    return (
        f"タイトル: {job.title}\n"
        f"内容:\n{job.body}\n\n"
        f"`{INPUT_DIRNAME}/` にある入力ファイルを読んで作業し、"
        f"結果は `{OUTPUT_DIRNAME}/` に書き出してください。"
        "必要な説明は標準出力の最後に 1〜数行で書いてください。"
    )


def is_log_line(line: str) -> bool:
    """ツール/デバッグ系の行かどうかを判定する。"""
    s = line.strip()
    if not s:
        return False
    # `[tool] ...` や `{...}` のような構造化ログは LOG 扱い。
    if s[0] in "[{":
        return True
    # `> ...` や `$ ...` などの接頭辞は LOG 扱い。
    if s[0] in ">$•-▸":
        return True
    lowered = s.lower()
    return lowered.startswith(_LOG_PREFIXES)


def _snapshot_files(output_dir: Path) -> set[Path]:
    """実行前の output/ 配下ファイル一覧を取る（新規検出用）。"""
    if not output_dir.is_dir():
        return set()
    return {p.resolve() for p in output_dir.rglob("*") if p.is_file()}


def _new_files(output_dir: Path, before: set[Path]) -> list[Path]:
    """実行後に増えた output/ 配下ファイルをソートして返す。"""
    if not output_dir.is_dir():
        return []
    after = [p.resolve() for p in output_dir.rglob("*") if p.is_file()]
    return sorted(p for p in after if p not in before)


class HermesWorker:
    """Hermes 互換 CLI を `job.directory` で実行する Worker。"""

    def __init__(
        self,
        command: Sequence[str] | None = None,
        timeout: float = DEFAULT_TIMEOUT,
    ) -> None:
        # 注入可能にするためのコマンド雛形（末尾にプロンプトを足す）。
        self._command = tuple(command) if command is not None else DEFAULT_COMMAND
        self._timeout = timeout

    @property
    def command(self) -> tuple[str, ...]:
        """コマンド雛形（プロンプトなし）。"""
        return self._command

    @property
    def timeout(self) -> float:
        """タイムアウト秒数。"""
        return self._timeout

    async def run(
        self,
        job: Job,
        on_progress: Callable[[ProgressEvent], Awaitable[None]],
    ) -> JobStatus:
        """ジョブフォルダを cwd に Hermes を実行し、進捗を流す。"""
        prompt = build_prompt(job)
        cmd = [*self._command, prompt]
        output_dir = job.directory / OUTPUT_DIRNAME
        before = _snapshot_files(output_dir)

        # 現在の環境を引き継ぐ。トークン類はファイルに書かない（ここでは何も書かない）。
        env = dict(os.environ)

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=job.directory,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=env,
            )
        except (FileNotFoundError, OSError):
            # コマンドが存在しない・起動できない場合は失敗扱い。
            return JobStatus.FAILED

        assert proc.stdout is not None
        speech_candidate: str | None = None

        async def _drain() -> int:
            """標準出力を 1 行ずつ読み、LOG を流しつつ最終発話候補を保持する。"""
            nonlocal speech_candidate
            while True:
                raw = await proc.stdout.readline()
                if not raw:
                    break
                try:
                    line = raw.decode("utf-8", errors="replace")
                except Exception:
                    continue
                text = line.strip()
                if not text:
                    continue
                if is_log_line(text):
                    # ツール/デバッグ系の行はそのまま LOG として流す。
                    await on_progress(ProgressEvent(kind=ProgressKind.LOG, text=text))
                else:
                    # 通常の行は最終返答の候補として保持する（SPEECH は最後に 1 回）。
                    speech_candidate = text
            return await proc.wait()

        try:
            returncode = await asyncio.wait_for(_drain(), timeout=self._timeout)
        except TimeoutError:
            # タイムアウト時はプロセスを止めて失敗扱いにする。
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(proc.wait(), timeout=10)
            except TimeoutError:
                pass
            return JobStatus.FAILED

        if returncode != 0:
            return JobStatus.FAILED

        # 成功時のみ最終返答を SPEECH + SUMMARY として流す。
        if speech_candidate:
            await on_progress(ProgressEvent(kind=ProgressKind.SPEECH, text=speech_candidate))
            await on_progress(ProgressEvent(kind=ProgressKind.SUMMARY, text=speech_candidate))

        # 成功時に output/ へ増えたファイルを FILE として流す。
        for path in _new_files(output_dir, before):
            await on_progress(
                ProgressEvent(
                    kind=ProgressKind.FILE,
                    text=path.name,
                    path=path,
                )
            )
        return JobStatus.DONE
