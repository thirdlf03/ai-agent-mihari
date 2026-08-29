"""接続中の iOS デバイスに関する情報を取得する。

USB(usbmuxd)経由に加えて、一度 USB でペアリング済みのデバイスを Wi-Fi 経由でも探す。
Wi-Fi 探索は bonjour(``_apple-mobdev2._tcp``)で見つけたホストに対して、usbmuxd が持つ
ペアレコードを使って lockdown へ TCP 接続し、UDID の一致で突き合わせる。
"""

import asyncio
import ipaddress
import json
import os
from pathlib import Path
from typing import Any

from pymobiledevice3.bonjour import ServiceInstance, browse_mobdev2
from pymobiledevice3.lockdown import TcpLockdownClient, create_using_tcp, create_using_usbmux
from pymobiledevice3.pair_records import get_usbmux_pairing_record
from pymobiledevice3.usbmux import list_devices as usbmux_list_devices

#: 既知デバイスキャッシュの既定ディレクトリ。``DEVICE_BRIDGE_CACHE_DIR`` で上書きできる。
DEFAULT_CACHE_DIR = "~/.device-bridge"
KNOWN_DEVICES_FILE = "known_devices.json"

#: bonjour で応答を待つ秒数。
BONJOUR_TIMEOUT = 2.0
#: 1 ホスト 1 UDID あたりの lockdown 接続を打ち切る秒数。
CONNECT_TIMEOUT = 3.0


def list_devices(*, wifi: bool = True) -> dict[str, Any]:
    """接続中のデバイスの一覧を返す。

    :param wifi: ``False`` なら Wi-Fi 経由の探索を省略する。
    :returns: ``{"devices": [{"udid": str, "connection_type": str, "host": str | None}]}``。
    """
    return asyncio.run(_list_devices(wifi=wifi))


def device_info(udid: str) -> dict[str, Any]:
    """指定した UDID のデバイスの基本情報を返す。

    USB で見えていれば usbmuxd 経由、見えていなければ Wi-Fi 経由で取得する。

    :param udid: 対象デバイスの UDID。
    :returns: ``udid`` / ``device_name`` / ``product_type`` / ``product_version`` /
        ``build_version`` / ``connection_type`` / ``host``。
    """
    return asyncio.run(_device_info(udid))


async def discover_wifi(
    known_udids: list[str], exclude_udids: list[str]
) -> dict[str, dict[str, str]]:
    """Wi-Fi 上にいる既知デバイスを探す。

    :param known_udids: 一度 USB でペアリングしたことのある UDID の一覧。
    :param exclude_udids: 探索対象から外す UDID(すでに USB で見えているものなど)。
    :returns: ``{udid: {"host": ip}}``。
    """
    excluded = set(exclude_udids)
    remaining = [udid for udid in known_udids if udid not in excluded]
    if not remaining:
        return {}

    found: dict[str, dict[str, str]] = {}
    for host in _collect_hosts(await browse_mobdev2(timeout=BONJOUR_TIMEOUT)):
        if not remaining:
            break
        for udid in remaining:
            if await _matches(host, udid):
                found[udid] = {"host": host}
                remaining.remove(udid)
                # このホストの持ち主は確定したので、残りの UDID は試さない。
                break

    return found


async def _list_devices(*, wifi: bool) -> dict[str, Any]:
    usb_devices = await usbmux_list_devices()
    entries = [
        {"udid": device.serial, "connection_type": device.connection_type, "host": None}
        for device in usb_devices
    ]

    usb_udids = [device.serial for device in usb_devices]
    known_udids = _remember_udids(usb_udids)
    if wifi:
        discovered = await discover_wifi(known_udids, usb_udids)
        entries.extend(
            {"udid": udid, "connection_type": "WiFi", "host": location["host"]}
            for udid, location in discovered.items()
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

    location = (await discover_wifi([udid], [])).get(udid)
    if location is None:
        raise RuntimeError(f"device not found: {udid}")

    host = location["host"]
    async with await _connect_tcp(host, udid) as lockdown:
        info = lockdown.short_info
    return _info_payload(info, "WiFi", host)


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


def _collect_hosts(services: list[ServiceInstance]) -> list[str]:
    """bonjour の結果から接続先ホストを重複なく取り出す。

    同じデバイスが複数エントリで返るため、IP 文字列で重複排除する。link-local
    (IPv4 の ``169.254.*`` / IPv6 の ``fe80::``)は接続先にならないので除く。
    IPv4 が 1 つも無い場合に限り IPv6 を使う。
    """
    ipv4: list[str] = []
    ipv6: list[str] = []
    for service in services:
        for address in service.addresses:
            try:
                parsed = ipaddress.ip_address(address.ip)
            except ValueError:
                continue
            if parsed.is_link_local:
                continue
            bucket = ipv4 if parsed.version == 4 else ipv6
            if address.ip not in bucket:
                bucket.append(address.ip)
    return ipv4 or ipv6


async def _matches(host: str, udid: str) -> bool:
    """``host`` が ``udid`` のデバイスかどうかを lockdown で確認する。"""
    try:
        return await asyncio.wait_for(_check_udid(host, udid), timeout=CONNECT_TIMEOUT)
    except Exception:  # noqa: BLE001 - 到達不能・未ペアリングなどは単に不一致として扱う
        return False


async def _check_udid(host: str, udid: str) -> bool:
    async with await _connect_tcp(host, udid) as lockdown:
        return lockdown.short_info.get("UniqueDeviceID") == udid


async def _connect_tcp(host: str, udid: str) -> TcpLockdownClient:
    """usbmuxd のペアレコードを使って lockdown に TCP 接続する。

    ペアレコードを渡さないと未認証となり ``UniqueDeviceID`` が取れないため、
    ``autopair=False`` と合わせて必ず渡す。
    """
    pair_record = await get_usbmux_pairing_record(udid)
    return await create_using_tcp(
        hostname=host, identifier=udid, autopair=False, pair_record=pair_record
    )


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
