"""接続中の iOS デバイスに関する情報を取得する。

USB(usbmuxd)経由に加えて、tunneld(``pymobiledevice3 remote tunneld``)が張っている
RemoteXPC トンネル越しのデバイスも「つながっている」ものとして扱う。USB を抜いても
tunneld は同じ Wi-Fi 上の端末にトンネルを張り直すため、これが Wi-Fi 経由の唯一の経路になる。

bonjour(``_apple-mobdev2._tcp``)で見つけたホストへ TCP:62078 で直接 lockdown する
classic な Wi-Fi 経路は使わない。実測(iOS 26.6 / iPhone 14)では lockdownd 本体には
繋がるものの、``StartService`` で開く 2 本目のサービス接続が SSL 直後に端末側から必ず
切断される(diagnostics_relay / notification_proxy / afc / installation_proxy のいずれも)。
また macOS の usbmuxd は Wi-Fi 上の端末を Network デバイスとして列挙しない。
"""

import asyncio
import json
import os
from collections.abc import Iterable
from pathlib import Path
from typing import Any, Literal

import httpx
from pymobiledevice3.exceptions import TunneldConnectionError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.tunneld.api import get_tunneld_device_by_udid
from pymobiledevice3.usbmux import list_devices as usbmux_list_devices

#: 既知デバイスキャッシュの既定ディレクトリ。``DEVICE_BRIDGE_CACHE_DIR`` で上書きできる。
DEFAULT_CACHE_DIR = "~/.device-bridge"
KNOWN_DEVICES_FILE = "known_devices.json"

#: root で常駐している tunneld の HTTP API。``{udid: [トンネル情報, ...]}`` を返す。
TUNNELD_URL = "http://127.0.0.1:49151/"
#: tunneld の HTTP API を待つ秒数。localhost 相手なので短くてよい。
TUNNELD_TIMEOUT = 2.0

#: 実機へ繋ぐ経路。
Transport = Literal["usbmux", "tunnel"]


def list_devices(*, wifi: bool = True) -> dict[str, Any]:
    """接続中のデバイスの一覧を返す。

    :param wifi: ``False`` なら tunneld のトンネル(Wi-Fi 経由)を一覧に含めない。
    :returns: ``{"devices": [{"udid": str, "connection_type": str, "host": str | None}]}``。
        ``connection_type`` は usbmuxd の値(``"USB"`` など)か、トンネル経由なら ``"Tunnel"``。
    """
    return asyncio.run(_list_devices(wifi=wifi))


def device_info(udid: str) -> dict[str, Any]:
    """指定した UDID のデバイスの基本情報を返す。

    USB で見えていれば usbmuxd 経由、見えていなければ tunneld のトンネル経由で取得する。

    :param udid: 対象デバイスの UDID。
    :returns: ``udid`` / ``device_name`` / ``product_type`` / ``product_version`` /
        ``build_version`` / ``connection_type`` / ``host``。
    """
    return asyncio.run(_device_info(udid))


def select_transport(
    udid: str, usb_udids: Iterable[str], tunnel_udids: Iterable[str]
) -> Transport | None:
    """``udid`` にどの経路で繋ぐかを決める。

    USB で見えていれば usbmux を選ぶ(従来どおりで、tunneld が動いていなくても使える)。
    USB に無ければ tunneld のトンネルを使う。どちらにも無ければ繋げない。

    :param udid: 対象デバイスの UDID。
    :param usb_udids: usbmuxd が見せている UDID の一覧。
    :param tunnel_udids: tunneld がトンネルを張っている UDID の一覧。
    :returns: ``"usbmux"`` / ``"tunnel"``、どちらでも繋げないなら ``None``。
    """
    if udid in set(usb_udids):
        return "usbmux"
    if udid in set(tunnel_udids):
        return "tunnel"
    return None


async def list_usb_udids() -> list[str]:
    """usbmuxd が見せている(= USB で繋がっている)UDID の一覧を返す。"""
    return [device.serial for device in await usbmux_list_devices()]


async def list_tunnel_udids(*, transport: httpx.AsyncBaseTransport | None = None) -> list[str]:
    """tunneld がトンネルを張っている UDID の一覧を返す。

    tunneld が常駐していない・応答が JSON でないといった場合は、例外にせず空リストを返す
    (「トンネルが 1 本も無い」と同じ扱いにする)。

    :param transport: テストから HTTP をモックするための差し込み口。実運用では ``None``。
    """
    try:
        async with httpx.AsyncClient(transport=transport, timeout=TUNNELD_TIMEOUT) as client:
            response = await client.get(TUNNELD_URL)
            response.raise_for_status()
            payload = response.json()
    except (httpx.HTTPError, ValueError):
        return []
    if not isinstance(payload, dict):
        return []
    return [udid for udid in payload if isinstance(udid, str)]


async def list_connected_udids() -> list[str]:
    """いま繋がっている UDID を、USB → トンネルの順で重複なく並べる。"""
    usb_udids = await list_usb_udids()
    tunnel_udids = [udid for udid in await list_tunnel_udids() if udid not in usb_udids]
    return usb_udids + tunnel_udids


async def connect_tunnel(udid: str) -> RemoteServiceDiscoveryService | None:
    """tunneld のトンネル越しに RSD へ繋ぐ。

    :returns: 接続済みの ``RemoteServiceDiscoveryService``。tunneld に到達できない、または
        このデバイスのトンネルが無い場合は ``None``。
    """
    try:
        return await get_tunneld_device_by_udid(udid)
    except TunneldConnectionError:
        return None


async def _list_devices(*, wifi: bool) -> dict[str, Any]:
    usb_devices = await usbmux_list_devices()
    entries = [
        {"udid": device.serial, "connection_type": device.connection_type, "host": None}
        for device in usb_devices
    ]

    usb_udids = [device.serial for device in usb_devices]
    _remember_udids(usb_udids)
    if wifi:
        entries.extend(
            {"udid": udid, "connection_type": "Tunnel", "host": None}
            for udid in await list_tunnel_udids()
            if udid not in usb_udids
        )

    return {"devices": entries}


async def _device_info(udid: str) -> dict[str, Any]:
    usb_device = next(
        (device for device in await usbmux_list_devices() if device.serial == udid), None
    )
    if usb_device is not None:
        async with await create_using_usbmux(serial=udid) as lockdown:
            info = lockdown.short_info
        return _info_payload(info, usb_device.connection_type, None)

    rsd = await connect_tunnel(udid)
    if rsd is None:
        raise RuntimeError(f"device not found: {udid}")
    try:
        # RSD は ``short_info`` を持たないため、リモート lockdown から取れた値で組み立てる。
        info = dict(rsd.all_values)
        info.setdefault("UniqueDeviceID", rsd.udid)
        info.setdefault("ProductType", rsd.product_type)
        info.setdefault("ProductVersion", rsd.product_version)
        return _info_payload(info, "Tunnel", None)
    finally:
        await rsd.close()


def _info_payload(info: dict[str, Any], connection_type: str, host: str | None) -> dict[str, Any]:
    return {
        "udid": info.get("UniqueDeviceID"),
        "device_name": info.get("DeviceName"),
        "product_type": info.get("ProductType"),
        "product_version": info.get("ProductVersion"),
        "build_version": info.get("BuildVersion"),
        "connection_type": connection_type,
        "host": host,
    }


def _cache_file() -> Path:
    directory = os.environ.get("DEVICE_BRIDGE_CACHE_DIR") or DEFAULT_CACHE_DIR
    return Path(directory).expanduser() / KNOWN_DEVICES_FILE


def _remember_udids(udids: list[str]) -> list[str]:
    """USB で見えた UDID をキャッシュに追記し、既知 UDID の全一覧を返す。"""
    known = _load_known_udids()
    added = [udid for udid in udids if udid not in known]
    if added:
        known.extend(added)
        _save_known_udids(known)
    return known


def _load_known_udids() -> list[str]:
    try:
        payload = json.loads(_cache_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(payload, dict):
        return []
    udids = payload.get("udids")
    if not isinstance(udids, list):
        return []
    return [udid for udid in udids if isinstance(udid, str)]


def _save_known_udids(udids: list[str]) -> None:
    path = _cache_file()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"udids": udids}, ensure_ascii=False), encoding="utf-8")
    except OSError:
        # キャッシュが書けなくても一覧の取得自体は成立させる。
        pass
