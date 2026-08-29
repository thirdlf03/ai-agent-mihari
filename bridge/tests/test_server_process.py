"""デーモンをプロセスとして起動したときの振る舞い。

macOS アプリは子プロセスとして起動し、stdout の 1 行でポートを知り、
自分が死んだら子も死ぬことを前提にしている。その前提をここで固定する。
"""

from __future__ import annotations

import json
import socket
import subprocess
import sys
import time
from collections.abc import Iterator

import httpx
import pytest

TOKEN = "process-test-token"
STARTUP_TIMEOUT = 20.0
SHUTDOWN_TIMEOUT = 10.0


class Daemon:
    def __init__(self, process: subprocess.Popen[str], port: int) -> None:
        self.process = process
        self.port = port

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    @property
    def auth(self) -> dict[str, str]:
        return {"X-Mihari-Token": TOKEN}


@pytest.fixture
def daemon() -> Iterator[Daemon]:
    process = subprocess.Popen(
        [sys.executable, "-m", "device_bridge.cli", "serve", "--token", TOKEN],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert process.stdout is not None

    line = process.stdout.readline()
    if not line:
        stderr = process.stderr.read() if process.stderr else ""
        process.kill()
        pytest.fail(f"デーモンがポートを通知しなかった: {stderr}")

    announcement = json.loads(line)
    started = Daemon(process, announcement["port"])
    try:
        yield started
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=SHUTDOWN_TIMEOUT)
            except subprocess.TimeoutExpired:  # pragma: no cover - 保険
                process.kill()


def test_announces_port_and_pid_on_stdout(daemon: Daemon) -> None:
    assert daemon.port > 0
    assert daemon.process.pid > 0


def test_health_responds(daemon: Daemon) -> None:
    response = httpx.get(f"{daemon.base_url}/health", timeout=STARTUP_TIMEOUT)
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_listens_on_loopback_only(daemon: Daemon) -> None:
    # ループバック以外のアドレスからは繋がらないこと。LAN 側のアドレスへ直接繋いで確かめる。
    lan_ip = _primary_lan_ip()
    if lan_ip is None:
        pytest.skip("LAN アドレスが取れないため確認できない")

    with pytest.raises((httpx.ConnectError, httpx.ConnectTimeout)):
        httpx.get(f"http://{lan_ip}:{daemon.port}/health", timeout=2.0)


def test_published_event_reaches_the_sse_stream(daemon: Daemon) -> None:
    with httpx.Client(timeout=STARTUP_TIMEOUT) as client:
        with client.stream("GET", f"{daemon.base_url}/events", headers=daemon.auth) as stream:
            lines = stream.iter_lines()

            # 接続直後に connected が届く。ここまでで経路が通っている。
            assert _read_event(lines)["name"] == "connected"

            published = httpx.post(
                f"{daemon.base_url}/events/publish",
                json={"name": "watch.start", "payload": {"at": "19:00"}},
                headers=daemon.auth,
                timeout=STARTUP_TIMEOUT,
            )
            assert published.json()["subscribers"] == 1

            event = _read_event(lines)
            assert event["name"] == "watch.start"
            assert event["payload"] == {"at": "19:00"}


def test_exits_when_stdin_closes(daemon: Daemon) -> None:
    # 親(macOS アプリ)が異常終了してパイプが閉じたら、孤児として残らずに自分から終わる。
    assert daemon.process.stdin is not None
    daemon.process.stdin.close()

    deadline = time.monotonic() + SHUTDOWN_TIMEOUT
    while time.monotonic() < deadline:
        if daemon.process.poll() is not None:
            return
        time.sleep(0.05)

    pytest.fail("stdin を閉じてもデーモンが終了しなかった")


def _read_event(lines: Iterator[str]) -> dict[str, object]:
    """SSE のストリームから data 行を 1 件読む。keepalive のコメント行は読み飛ばす。"""
    for line in lines:
        if line.startswith("data: "):
            return json.loads(line.removeprefix("data: "))
    raise AssertionError("イベントが届かなかった")


def _primary_lan_ip() -> str | None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # 実際には送信しない。経路表からこのホストの外向きアドレスを引くための接続。
        sock.connect(("192.0.2.1", 9))
        ip: str = sock.getsockname()[0]
    except OSError:
        return None
    finally:
        sock.close()
    return None if ip.startswith("127.") else ip
