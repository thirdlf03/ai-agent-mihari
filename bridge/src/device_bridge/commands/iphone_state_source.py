"""``DeviceStateSource`` の実機実装。

notification_proxy の Darwin 通知購読と diagnostics のバッテリー取得を、実際に
pymobiledevice3 で行う薄い層。``iphone_state.py`` 側は本モジュールの具象クラスを
知らなくても動くようにしてあり、実機が無い環境でもテストは本モジュールを
差し替えて成立させる。

Wi-Fi 経由の接続は ``commands/devices.py`` の bonjour + lockdown 実装を踏襲する。
notification_proxy(``com.apple.mobile.notification_proxy``)と diagnostics_relay
(``com.apple.mobile.diagnostics_relay``)はいずれも DeveloperDiskImage のマウントを
必要としない lockdown サービスであり、``is_developer_service`` は既定の ``False``。
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator

from pymobiledevice3.lockdown import create_using_tcp, create_using_usbmux
from pymobiledevice3.lockdown_service_provider import LockdownServiceProvider
from pymobiledevice3.pair_records import get_usbmux_pairing_record
from pymobiledevice3.services.diagnostics import DiagnosticsService
from pymobiledevice3.services.notification_proxy import NotificationProxyService
from pymobiledevice3.usbmux import list_devices as usbmux_list_devices

from device_bridge.commands import devices as devices_module
from device_bridge.commands.iphone_state import (
    BATTERY_POLL_INTERVAL,
    OBSERVED_NOTIFICATIONS,
    IphoneActivity,
    IphoneStateSnapshot,
    build_snapshot,
    classify_notification,
)


class LiveDeviceStateSource:
    """実機に接続して iPhone の状態を観測する。"""

    async def find_device(self) -> str | None:
        """接続中(USB または、既知デバイスの Wi-Fi)の UDID を 1 つ返す。

        USB を抜いても、一度でも USB でペアリングした UDID なら
        ``commands.devices`` のキャッシュ経由で Wi-Fi 上を探しに行く。
        """
        result = await asyncio.to_thread(devices_module.list_devices, wifi=True)
        entries = result.get("devices", [])
        if not entries:
            return None
        udid = entries[0].get("udid")
        return udid if isinstance(udid, str) else None

    async def observe(self, udid: str) -> AsyncIterator[IphoneStateSnapshot]:
        """通知とバッテリーからスナップショットを yield し続ける。"""
        lockdown = await _connect_lockdown(udid)
        try:
            async with (
                NotificationProxyService(lockdown) as proxy,
                DiagnosticsService(lockdown) as diagnostics,
            ):
                for name in OBSERVED_NOTIFICATIONS:
                    await proxy.notify_register_dispatch(name)

                # 購読開始時点の絶対的な画面状態は分からないため、いったん未操作として
                # 始める(iphone_state モジュール docstring 参照)。以後は通知で更新する。
                activity = IphoneActivity.IDLE
                battery_level, battery_charging = await _read_battery(diagnostics)
                yield build_snapshot(
                    udid, activity, battery_level=battery_level, battery_charging=battery_charging
                )

                while True:
                    try:
                        message = await asyncio.wait_for(
                            proxy.service.recv_plist(), timeout=BATTERY_POLL_INTERVAL
                        )
                    except TimeoutError:
                        battery_level, battery_charging = await _read_battery(diagnostics)
                        yield build_snapshot(
                            udid,
                            activity,
                            battery_level=battery_level,
                            battery_charging=battery_charging,
                        )
                        continue

                    new_activity = classify_notification(message.get("Name"))
                    if new_activity is None:
                        continue
                    activity = new_activity
                    yield build_snapshot(
                        udid,
                        activity,
                        battery_level=battery_level,
                        battery_charging=battery_charging,
                    )
        finally:
            await _close_quietly(lockdown)


async def _connect_lockdown(udid: str) -> LockdownServiceProvider:
    """USB で見えていれば usbmuxd 経由、無ければ Wi-Fi 経由で lockdown に繋ぐ。

    ``commands/devices.py`` の ``_connect_tcp`` と同じ考え方(ペアレコードを使った
    ``autopair=False`` の TCP 接続)を踏襲している。
    """
    usb_devices = await usbmux_list_devices()
    if any(device.serial == udid for device in usb_devices):
        return await create_using_usbmux(serial=udid)

    location = (await devices_module.discover_wifi([udid], [])).get(udid)
    if location is None:
        raise RuntimeError(f"device not found: {udid}")

    pair_record = await get_usbmux_pairing_record(udid)
    return await create_using_tcp(
        hostname=location["host"], identifier=udid, autopair=False, pair_record=pair_record
    )


async def _read_battery(diagnostics: DiagnosticsService) -> tuple[float | None, bool | None]:
    """バッテリー情報を取る。失敗しても補助情報なので None を返すだけに留める。"""
    try:
        info = await diagnostics.get_battery()
    except Exception:  # noqa: BLE001 - 補助情報の取得失敗で本体機能を止めない
        return None, None
    if not info:
        return None, None
    level = info.get("CurrentCapacity")
    charging = info.get("IsCharging")
    return (
        float(level) if isinstance(level, (int, float)) else None,
        bool(charging) if isinstance(charging, bool) else None,
    )


async def _close_quietly(lockdown: LockdownServiceProvider) -> None:
    close = getattr(lockdown, "close", None)
    if close is None:
        return
    try:
        result = close()
        if asyncio.iscoroutine(result):
            await result
    except Exception:  # noqa: BLE001 - 後始末の失敗は無視してよい
        pass
