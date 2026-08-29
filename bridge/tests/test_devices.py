"""``device_bridge.commands.devices`` のうち、実機を必要としない部分を検証する。

接続経路の選択(``select_transport``)と、tunneld の HTTP API の読み取りが対象。
tunneld への HTTP は ``httpx.MockTransport`` で差し替えるので、実際の通信は起きない。
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

import httpx
import pytest

from device_bridge.commands import devices as devices_module


def _transport(handler: Callable[[httpx.Request], httpx.Response]) -> httpx.MockTransport:
    return httpx.MockTransport(handler)


# --- select_transport ---------------------------------------------------------------


def test_select_transport_prefers_usb() -> None:
    # USB とトンネルの両方にいるときは、tunneld に依存しない USB を選ぶ。
    assert devices_module.select_transport("UDID-1", ["UDID-1"], ["UDID-1"]) == "usbmux"


def test_select_transport_uses_usb_when_no_tunnel() -> None:
    assert devices_module.select_transport("UDID-1", ["UDID-1"], []) == "usbmux"


def test_select_transport_falls_back_to_tunnel() -> None:
    assert devices_module.select_transport("UDID-1", [], ["UDID-1"]) == "tunnel"


def test_select_transport_returns_none_when_nowhere() -> None:
    assert devices_module.select_transport("UDID-1", ["UDID-2"], ["UDID-3"]) is None


# --- list_tunnel_udids --------------------------------------------------------------


async def test_list_tunnel_udids_returns_keys() -> None:
    payload = {
        "UDID-1": [
            {"tunnel-address": "fdf4::1", "tunnel-port": 54839, "interface": "192.168.0.28"}
        ],
        "UDID-2": [],
    }

    udids = await devices_module.list_tunnel_udids(
        transport=_transport(lambda request: httpx.Response(200, json=payload))
    )

    assert udids == ["UDID-1", "UDID-2"]


async def test_list_tunnel_udids_empty_when_no_tunnels() -> None:
    udids = await devices_module.list_tunnel_udids(
        transport=_transport(lambda request: httpx.Response(200, json={}))
    )

    assert udids == []


async def test_list_tunnel_udids_empty_on_invalid_json() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, content=b"<html>not json</html>", headers={"content-type": "application/json"}
        )

    assert await devices_module.list_tunnel_udids(transport=_transport(handler)) == []


async def test_list_tunnel_udids_empty_when_payload_is_not_a_mapping() -> None:
    udids = await devices_module.list_tunnel_udids(
        transport=_transport(lambda request: httpx.Response(200, json=["UDID-1"]))
    )

    assert udids == []


async def test_list_tunnel_udids_empty_when_tunneld_is_not_running() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    assert await devices_module.list_tunnel_udids(transport=_transport(handler)) == []


async def test_list_tunnel_udids_empty_on_error_status() -> None:
    udids = await devices_module.list_tunnel_udids(
        transport=_transport(lambda request: httpx.Response(500))
    )

    assert udids == []


# --- list_connected_udids -----------------------------------------------------------


def _patch_udids(monkeypatch: pytest.MonkeyPatch, *, usb: list[str], tunnel: list[str]) -> None:
    async def fake_usb() -> list[str]:
        return usb

    async def fake_tunnel(**kwargs: Any) -> list[str]:
        return tunnel

    monkeypatch.setattr(devices_module, "list_usb_udids", fake_usb)
    monkeypatch.setattr(devices_module, "list_tunnel_udids", fake_tunnel)


async def test_list_connected_udids_puts_usb_first_and_deduplicates(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_udids(monkeypatch, usb=["UDID-USB"], tunnel=["UDID-USB", "UDID-TUNNEL"])

    assert await devices_module.list_connected_udids() == ["UDID-USB", "UDID-TUNNEL"]


async def test_list_connected_udids_finds_tunnel_only_device(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_udids(monkeypatch, usb=[], tunnel=["UDID-TUNNEL"])

    assert await devices_module.list_connected_udids() == ["UDID-TUNNEL"]


# --- list_devices -------------------------------------------------------------------


class _FakeMuxDevice:
    def __init__(self, serial: str) -> None:
        self.serial = serial
        self.connection_type = "USB"


async def test_list_devices_reports_tunnels_as_tunnel_entries(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Any
) -> None:
    monkeypatch.setenv("DEVICE_BRIDGE_CACHE_DIR", str(tmp_path))

    async def fake_usbmux() -> list[_FakeMuxDevice]:
        return [_FakeMuxDevice("UDID-USB")]

    async def fake_tunnel(**kwargs: Any) -> list[str]:
        return ["UDID-USB", "UDID-TUNNEL"]

    monkeypatch.setattr(devices_module, "usbmux_list_devices", fake_usbmux)
    monkeypatch.setattr(devices_module, "list_tunnel_udids", fake_tunnel)

    result = await devices_module._list_devices(wifi=True)

    assert result["devices"] == [
        {"udid": "UDID-USB", "connection_type": "USB", "host": None},
        {"udid": "UDID-TUNNEL", "connection_type": "Tunnel", "host": None},
    ]


async def test_list_devices_skips_tunnels_when_wifi_is_off(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Any
) -> None:
    monkeypatch.setenv("DEVICE_BRIDGE_CACHE_DIR", str(tmp_path))

    async def fake_usbmux() -> list[_FakeMuxDevice]:
        return []

    async def fake_tunnel(**kwargs: Any) -> list[str]:
        raise AssertionError("wifi=False では tunneld に問い合わせない")

    monkeypatch.setattr(devices_module, "usbmux_list_devices", fake_usbmux)
    monkeypatch.setattr(devices_module, "list_tunnel_udids", fake_tunnel)

    assert await devices_module._list_devices(wifi=False) == {"devices": []}
