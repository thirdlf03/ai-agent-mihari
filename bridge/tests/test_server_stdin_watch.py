"""親プロセスの死を stdin で検知する仕組み。

パイプ以外を監視対象にすると、`&` でのバックグラウンド起動や nohup 下で
stdin が /dev/null になり、起動直後に EOF を親の死と誤認して自殺してしまう。
"""

from __future__ import annotations

import os
import subprocess
import sys
import time

import pytest

from device_bridge.daemon.server import stdin_is_parent_pipe


def test_pipe_is_watched(monkeypatch: pytest.MonkeyPatch) -> None:
    read_fd, write_fd = os.pipe()
    try:
        monkeypatch.setattr(sys, "stdin", os.fdopen(read_fd))
        assert stdin_is_parent_pipe() is True
    finally:
        os.close(write_fd)


def test_devnull_is_not_watched(monkeypatch: pytest.MonkeyPatch) -> None:
    with open(os.devnull) as devnull:
        monkeypatch.setattr(sys, "stdin", devnull)
        assert stdin_is_parent_pipe() is False


def test_regular_file_is_not_watched(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    path = tmp_path / "stdin.txt"
    path.write_text("", encoding="utf-8")
    with path.open() as handle:
        monkeypatch.setattr(sys, "stdin", handle)
        assert stdin_is_parent_pipe() is False


def test_daemon_started_with_devnull_stdin_keeps_running() -> None:
    """`&` でのバックグラウンド起動を模した状態でも生き残ること。"""
    with open(os.devnull) as devnull:
        process = subprocess.Popen(
            [sys.executable, "-m", "device_bridge.cli", "serve", "--token", "t"],
            stdin=devnull,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    try:
        assert process.stdout is not None
        assert process.stdout.readline(), "ポートを通知しなかった"
        time.sleep(1.0)
        assert process.poll() is None, "stdin が /dev/null なだけで終了してしまった"
    finally:
        process.terminate()
        process.wait(timeout=10)
