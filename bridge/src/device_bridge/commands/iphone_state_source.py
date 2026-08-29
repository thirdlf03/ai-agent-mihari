"""``DeviceStateSource`` の実機実装。

notification_proxy の Darwin 通知購読と、diagnostics の IORegistry(画面の点灯状態)/
バッテリー取得を、実際に pymobiledevice3 で行う薄い層。``iphone_state.py`` 側は
本モジュールの具象クラスを知らなくても動くようにしてあり、実機が無い環境でも
テストは本モジュールを差し替えて成立させる。

notification_proxy(``com.apple.mobile.notification_proxy``)と diagnostics_relay
(``com.apple.mobile.diagnostics_relay``)はいずれも DeveloperDiskImage のマウントを
必要としない lockdown サービスであり、``is_developer_service`` は既定の ``False``。

Wi-Fi 経由では tunneld のトンネル(``commands/devices.py`` の ``connect_tunnel``)を使う。
bonjour で見つけたホストへ TCP:62078 で直接繋ぐ classic な Wi-Fi lockdown は使わない。
実測(iOS 26.6 / iPhone 14)では lockdownd 本体には繋がるものの、そこから開く
diagnostics_relay / notification_proxy のサービス接続が SSL 直後に端末側から必ず切断され、
本モジュールの用途には使えなかった。トンネル経由で得られる ``RemoteServiceDiscoveryService``
なら、``DiagnosticsService`` / ``NotificationProxyService`` がどちらも ``.shim.remote`` の
サービス名に自動で切り替わり、そのまま動く(同構成で動作を確認済み)。
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.lockdown_service_provider import LockdownServiceProvider
from pymobiledevice3.services.diagnostics import DiagnosticsService
from pymobiledevice3.services.notification_proxy import NotificationProxyService

from device_bridge.commands import devices as devices_module
from device_bridge.commands.iphone_state import (
    BATTERY_POLL_INTERVAL,
    DISPLAY_POLL_INTERVAL,
    DISPLAY_SETTLE_SECONDS,
    OBSERVED_NOTIFICATIONS,
    IphoneActivity,
    IphoneStateSnapshot,
    build_snapshot,
    classify_display,
    resolve_activity,
)


class LiveDeviceStateSource:
    """実機に接続して iPhone の状態を観測する。"""

    async def find_device(self) -> str | None:
        """接続中(USB、無ければ tunneld のトンネル)の UDID を 1 つ返す。

        USB を抜いても、tunneld が同じ Wi-Fi 上の端末にトンネルを張り直していれば見つかる。
        端末がロックされて眠るとトンネルごと消えるので、そのときは ``None`` になる。
        """
        udids = await devices_module.list_connected_udids()
        return udids[0] if udids else None

    async def observe(self, udid: str) -> AsyncIterator[IphoneStateSnapshot]:
        """画面の点灯状態とバッテリーからスナップショットを yield し続ける。

        Darwin 通知は「画面状態を読み直す合図」としてだけ使い、通知が来なくても
        ``DISPLAY_POLL_INTERVAL`` ごとに読み直す。状態が変わらない間は yield を抑え、
        少なくとも ``BATTERY_POLL_INTERVAL`` ごとには 1 件流す。
        """
        lockdown = await _connect_lockdown(udid)
        try:
            async with (
                NotificationProxyService(lockdown) as proxy,
                DiagnosticsService(lockdown) as diagnostics,
            ):
                for name in OBSERVED_NOTIFICATIONS:
                    await proxy.notify_register_dispatch(name)

                # 画面状態は IORegistry から絶対値で読めるので、観測開始時点から正しい値を
                # 出せる。読めない機種でだけ未操作始まりになる(iphone_state docstring 参照)。
                normal_mode_active, brightness = await _read_display(diagnostics)
                activity = resolve_activity(
                    IphoneActivity.IDLE, None, classify_display(normal_mode_active, brightness)
                )
                battery_level, battery_charging = await _read_battery(diagnostics)

                loop = asyncio.get_running_loop()
                battery_read_at = loop.time()
                yielded = (activity, battery_level, battery_charging)
                yielded_at = battery_read_at
                yield build_snapshot(
                    udid, activity, battery_level=battery_level, battery_charging=battery_charging
                )

                while True:
                    try:
                        message = await asyncio.wait_for(
                            proxy.service.recv_plist(), timeout=DISPLAY_POLL_INTERVAL
                        )
                    except TimeoutError:
                        notification = None
                    else:
                        notification = message.get("Name")
                        # 通知の直後はまだ IORegistry に反映されていないので少し待つ。
                        await asyncio.sleep(DISPLAY_SETTLE_SECONDS)

                    normal_mode_active, brightness = await _read_display(diagnostics)
                    activity = resolve_activity(
                        activity, notification, classify_display(normal_mode_active, brightness)
                    )

                    now = loop.time()
                    if now - battery_read_at >= BATTERY_POLL_INTERVAL:
                        battery_level, battery_charging = await _read_battery(diagnostics)
                        battery_read_at = now

                    current = (activity, battery_level, battery_charging)
                    if current == yielded and now - yielded_at < BATTERY_POLL_INTERVAL:
                        continue
                    yielded = current
                    yielded_at = now
                    yield build_snapshot(
                        udid,
                        activity,
                        battery_level=battery_level,
                        battery_charging=battery_charging,
                    )
        finally:
            await _close_quietly(lockdown)


async def _connect_lockdown(udid: str) -> LockdownServiceProvider:
    """USB で見えていれば usbmuxd 経由、無ければ tunneld のトンネル経由で繋ぐ。

    トンネル経由で返るのは ``RemoteServiceDiscoveryService`` だが、この先で使う
    ``NotificationProxyService`` / ``DiagnosticsService`` はどちらも RSD を受け取れる。
    """
    transport = devices_module.select_transport(
        udid, await devices_module.list_usb_udids(), await devices_module.list_tunnel_udids()
    )
    if transport == "usbmux":
        return await create_using_usbmux(serial=udid)
    if transport == "tunnel":
        rsd = await devices_module.connect_tunnel(udid)
        if rsd is not None:
            return rsd
    raise RuntimeError(f"device not found: {udid}")


async def _read_display(diagnostics: DiagnosticsService) -> tuple[bool | None, int | None]:
    """画面が点灯しているかを IORegistry から読む。

    主指標は ``AppleCLCD2`` の ``NormalModeActive``(点灯 ``True`` / 消灯 ``False``)。
    その属性が無い機種のために ``AppleARMBacklight`` の輝度(点灯 16384 / 消灯 0)も
    併せて読む。``IOMFBBrightnessLevel`` は消灯中でも 0 以外を返すことがあり使わない。

    :returns: ``(NormalModeActive, バックライト輝度)``。読めなかった側は ``None``。
    """
    normal_mode_active: bool | None = None
    try:
        clcd = await diagnostics.ioregistry(ioclass="AppleCLCD2")
    except Exception:  # noqa: BLE001 - 読めない機種・一時的な失敗は None に倒す
        clcd = None
    if isinstance(clcd, dict):
        value = clcd.get("NormalModeActive")
        if isinstance(value, bool):
            normal_mode_active = value

    brightness: int | None = None
    try:
        backlight = await diagnostics.ioregistry(ioclass="AppleARMBacklight")
    except Exception:  # noqa: BLE001 - 同上
        backlight = None
    if isinstance(backlight, dict):
        parameters = backlight.get("IODisplayParameters")
        entry = parameters.get("brightness") if isinstance(parameters, dict) else None
        value = entry.get("value") if isinstance(entry, dict) else None
        if isinstance(value, int) and not isinstance(value, bool):
            brightness = value

    return normal_mode_active, brightness


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
