"""``GET /iphone/state`` のステータスコードと、監視タスクの遅延起動・冪等性を確かめる。

実機には依存しない。``LiveDeviceStateSource`` は必ずフェイクに差し替え、実際の
usbmuxd/bonjour 通信が起きないようにする。
"""

from __future__ import annotations

from collections.abc import AsyncIterator

import httpx
import pytest
from fastapi.testclient import TestClient

from device_bridge.commands.iphone_state import IphoneStateSnapshot
from device_bridge.daemon.app import create_app
from device_bridge.daemon.config import DaemonConfig
from device_bridge.daemon.routers import iphone_state as iphone_state_router


class NeverFoundSource:
    """デバイスが一切見つからないフェイク。実機なし環境の既定挙動を模す。"""

    async def find_device(self) -> str | None:
        return None

    async def observe(self, udid: str) -> AsyncIterator[IphoneStateSnapshot]:
        return
        yield  # pragma: no cover - ジェネレータにするためのダミー


@pytest.fixture(autouse=True)
def _no_real_device(monkeypatch: pytest.MonkeyPatch) -> None:
    """すべてのテストで実機探索をフェイクに差し替える。"""
    monkeypatch.setattr(
        iphone_state_router.iphone_state_source, "LiveDeviceStateSource", NeverFoundSource
    )


def test_get_state_requires_token(client: TestClient) -> None:
    response = client.get("/iphone/state")
    assert response.status_code == 401


def test_get_state_returns_unresponsive_snapshot_shape(
    client: TestClient, auth: dict[str, str]
) -> None:
    response = client.get("/iphone/state", headers=auth)

    assert response.status_code == 200
    body = response.json()
    assert body["activity"] == "unresponsive"
    assert "battery_level" in body
    assert "battery_charging" in body
    assert "updated_at" in body


def test_get_state_starts_monitor_at_most_once(client: TestClient, auth: dict[str, str]) -> None:
    client.get("/iphone/state", headers=auth)
    client.get("/iphone/state", headers=auth)

    app = client.app
    store_first = app.state.iphone_state_store
    task = app.state.iphone_state_task

    client.get("/iphone/state", headers=auth)

    # 2 回目以降のアクセスで新しいタスク/ストアが作られない(冪等)ことを確認する。
    assert app.state.iphone_state_store is store_first
    assert app.state.iphone_state_task is task

    app.state.iphone_state_stop.set()


async def test_lifespan_stops_the_monitor(auth: dict[str, str]) -> None:
    """デーモンの終了で監視タスクが片付くこと。残ると再接続待ちでプロセスが終わりきらない。

    ``TestClient`` はイベントループごと畳んでしまい、止め忘れても done になってしまうため、
    lifespan だけを同じループの中で開け閉めして確かめる。
    """
    app = create_app(DaemonConfig(token=auth["X-Mihari-Token"]))

    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://daemon"
        ) as http:
            await http.get("/iphone/state", headers=auth)
        task = app.state.iphone_state_task
        assert not task.done()

    assert task.done()
