"""デーモンの起動。

macOS アプリは次の手順でこのプロセスを扱う。

1. トークンを生成して ``device-bridge serve --token <token>`` を子プロセスとして起動する
2. 子プロセスの stdout に 1 行だけ出る ``{"port": ..., "pid": ...}`` を読む
3. そのポートへ REST / SSE でつなぐ
4. アプリ終了時に子プロセスを終了させる

アプリが異常終了して 4 が実行されなかった場合に備え、stdin の EOF を監視して自分から終了する。
親が死ぬとパイプが閉じるため、孤児として残り続けることがない。
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import socket
import stat
import sys
import threading
from pathlib import Path

import uvicorn
from dotenv import load_dotenv

from device_bridge.daemon.app import create_app
from device_bridge.daemon.config import DaemonConfig

#: 出力が多くて肝心のログが埋もれるライブラリ。WARNING 以上だけ残す。
_NOISY_LOGGERS = ("httpx", "httpcore", "google_genai", "discord")


def _configure_logging() -> None:
    """自分たちのログを stderr に出す。

    アプリは子プロセスの stderr を拾って記録する。stdout はポート通知専用なので、
    ログを 1 行でも混ぜてはいけない。
    """
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    for name in _NOISY_LOGGERS:
        logging.getLogger(name).setLevel(logging.WARNING)


def _bind_socket(config: DaemonConfig) -> socket.socket:
    """待ち受けソケットを先に作る。

    ポート 0 を渡された場合、実際のポート番号を uvicorn の起動前に知る必要がある。
    先に bind しておけば、確定したポートを stdout に出してから serve に渡せる。
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((config.host, config.port))
    sock.listen(128)
    return sock


def _announce(port: int) -> None:
    """アプリが読む 1 行を stdout に出す。以降 stdout には何も出さない。"""
    print(json.dumps({"port": port, "pid": os.getpid()}, ensure_ascii=False), flush=True)


def stdin_is_parent_pipe() -> bool:
    """stdin が親プロセスとつながったパイプかどうか。

    パイプのときだけ EOF を「親が死んだ」と読んでよい。
    ``&`` でバックグラウンド起動した場合や nohup 下では stdin が /dev/null になり、
    read() が即座に EOF を返す。これを親の死と誤認すると、起動した直後に自殺してしまう。
    端末につながっている場合も、読むとユーザーの入力を横取りしてしまうので監視しない。
    """
    try:
        mode = os.fstat(sys.stdin.fileno()).st_mode
    except (OSError, ValueError, AttributeError):
        return False
    return stat.S_ISFIFO(mode)


def _exit_when_stdin_closes(server: uvicorn.Server) -> None:
    """親プロセスが死んで stdin が閉じたら、自分も終了する。"""
    if not stdin_is_parent_pipe():
        return

    def watch() -> None:
        try:
            # 親が生きている間はここでブロックし続ける。親が死ぬと EOF で抜ける。
            sys.stdin.read()
        except Exception:  # noqa: BLE001 - stdin が無い環境でも監視を諦めるだけ
            return
        server.should_exit = True

    thread = threading.Thread(target=watch, name="parent-watchdog", daemon=True)
    thread.start()


def serve(config: DaemonConfig, *, watch_stdin: bool = True) -> None:
    """デーモンを起動し、終了するまでブロックする。"""
    _configure_logging()
    # API キーなどは bridge/.env から読む。無くても起動する(セリフが固定文言になるだけ)。
    load_dotenv(Path(__file__).resolve().parents[3] / ".env")

    sock = _bind_socket(config)
    port = sock.getsockname()[1]

    app = create_app(config)
    server = uvicorn.Server(
        uvicorn.Config(
            app,
            # ログは stderr に出す。stdout はアプリとの受け渡し専用にする。
            log_config=None,
            log_level="warning",
            access_log=False,
            # SSE のような長い接続が残っていても 3 秒で切り上げる。
            # 上限が無いと、アプリ終了時に接続が閉じるまでプロセスが残り続ける。
            timeout_graceful_shutdown=3,
        )
    )

    if watch_stdin:
        _exit_when_stdin_closes(server)

    _announce(port)
    try:
        asyncio.run(server.serve(sockets=[sock]))
    finally:
        sock.close()
