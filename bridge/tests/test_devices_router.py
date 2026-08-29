"""デバイス系エンドポイントのエラー翻訳。

pymobiledevice3 の実呼び出しは実機に依存するため、下層を差し替えて
HTTP のステータスコードへの翻訳だけを固定する。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from device_bridge.commands import devices as devices_module


def test_list_devices_passes_through(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        devices_module, "list_devices", lambda *, wifi: {"devices": [], "wifi": wifi}
    )

    response = client.get("/devices", headers=auth)

    assert response.status_code == 200
    assert response.json() == {"devices": [], "wifi": True}


def test_list_devices_can_skip_wifi(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        devices_module, "list_devices", lambda *, wifi: {"devices": [], "wifi": wifi}
    )

    response = client.get("/devices", params={"wifi": "false"}, headers=auth)

    assert response.json()["wifi"] is False


def test_list_devices_failure_becomes_502(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    def boom(*, wifi: bool) -> dict[str, object]:
        raise OSError("usbmuxd に繋がらない")

    monkeypatch.setattr(devices_module, "list_devices", boom)

    response = client.get("/devices", headers=auth)

    assert response.status_code == 502
    assert "usbmuxd" in response.json()["detail"]


def test_unknown_device_becomes_404(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    def missing(udid: str) -> dict[str, object]:
        raise RuntimeError(f"device not found: {udid}")

    monkeypatch.setattr(devices_module, "device_info", missing)

    response = client.get("/devices/UNKNOWN", headers=auth)

    assert response.status_code == 404
    assert "UNKNOWN" in response.json()["detail"]
