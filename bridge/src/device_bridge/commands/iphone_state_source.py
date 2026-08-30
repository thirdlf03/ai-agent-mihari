"""``DeviceStateSource`` の実機実装。

notification_proxy の Darwin 通知購読と、diagnostics の IORegistry(画面の点灯状態)/
バッテリー取得を、実際に pymobiledevice3 で行う薄い層。``iphone_state.py`` 側は
本モジュールの具象クラスを知らなくても動くようにしてあり、実機が無い環境でも
テストは本モジュールを差し替えて成立させる。

notification_proxy(``com.apple.mobile.notification_proxy``)と diagnostics_relay
(``com.apple.mobile.diagnostics_relay``)はいずれも DeveloperDiskImage のマウントを
必要としない lockdown サービスであり、``is_developer_service`` は既定の ``False``。

前面にあるアプリは os_trace_relay(``com.apple.os_trace_relay``)で SpringBoard の syslog を
流して拾い、その表示名は installation_proxy(``com.apple.mobile.installation_proxy``)で引く。
どちらも DeveloperDiskImage の要らない lockdown サービスで、トンネル経由の RSD でも動く
(実機で確認済み)。ただし **os_trace_relay は 1 接続で 1 リクエストしか受け付けない**ので、
pid 一覧の取得と syslog の購読は別々の ``OsTraceService`` で開く。同じインスタンスで続けて
呼ぶと端末側から接続を切られる。

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
import contextlib
import logging
from collections.abc import AsyncIterator
from typing import Any

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.lockdown_service_provider import LockdownServiceProvider
from pymobiledevice3.services.diagnostics import DiagnosticsService
from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.services.lockdown_service import LockdownService
from pymobiledevice3.services.notification_proxy import NotificationProxyService
from pymobiledevice3.services.os_trace import OsTraceService

from device_bridge.commands import devices as devices_module
from device_bridge.commands.iphone_state import (
    BATTERY_POLL_INTERVAL,
    DISPLAY_POLL_INTERVAL,
    DISPLAY_SETTLE_SECONDS,
    OBSERVED_NOTIFICATIONS,
    RECONNECT_INTERVAL,
    IphoneActivity,
    IphoneStateSnapshot,
    build_snapshot,
    classify_display,
    parse_foreground_apps,
    resolve_activity,
)

logger = logging.getLogger(__name__)

# ``observe`` のメインループを起こす合図の種別。
#: Darwin 通知が届いた(``value`` は通知名)。
_EVENT_NOTIFICATION = "notification"
#: 前面のアプリが変わった(``value`` は新しい bundle ID)。
_EVENT_FOREGROUND = "foreground"
#: 通知の受信が失敗した(``value`` は例外)。メインループで送出し直す。
_EVENT_ERROR = "error"


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
        """画面の点灯状態・前面アプリ・バッテリーからスナップショットを yield し続ける。

        Darwin 通知の受信と前面アプリの変化は、どちらも「読み直す合図」として 1 本のキューに
        集める。メインループはそのキューを ``DISPLAY_POLL_INTERVAL`` で待ち、合図が来なくても
        その間隔で画面状態を読み直す。通知由来のときだけ ``DISPLAY_SETTLE_SECONDS`` 待ってから
        読む(前面アプリの変化は syslog に出た時点で確定しているので待たない)。
        状態が変わらない間は yield を抑え、少なくとも ``BATTERY_POLL_INTERVAL`` ごとには 1 件流す。
        """
        lockdown = await _connect_lockdown(udid)
        tasks: list[asyncio.Task[None]] = []
        try:
            async with (
                NotificationProxyService(lockdown) as proxy,
                DiagnosticsService(lockdown) as diagnostics,
            ):
                for name in OBSERVED_NOTIFICATIONS:
                    await proxy.notify_register_dispatch(name)

                events: asyncio.Queue[tuple[str, Any]] = asyncio.Queue()
                start_lock = asyncio.Lock()
                app_names: dict[str, str | None] = {}
                foreground = _ForegroundTracker(lockdown, events, start_lock)
                tasks.append(asyncio.create_task(foreground.run(), name="iphone-foreground-watch"))
                tasks.append(
                    asyncio.create_task(
                        _pump_notifications(proxy, events), name="iphone-notification-pump"
                    )
                )

                # 画面状態は IORegistry から絶対値で読めるので、観測開始時点から正しい値を
                # 出せる。読めない機種でだけ未操作始まりになる(iphone_state docstring 参照)。
                normal_mode_active, brightness = await _read_display(diagnostics)
                activity = resolve_activity(
                    IphoneActivity.IDLE, None, classify_display(normal_mode_active, brightness)
                )
                battery_level, battery_charging = await _read_battery(diagnostics)

                loop = asyncio.get_running_loop()
                battery_read_at = loop.time()
                bundle_id = foreground.bundle_id
                yielded = (activity, bundle_id, battery_level, battery_charging)
                yielded_at = battery_read_at
                yield build_snapshot(
                    udid,
                    activity,
                    battery_level=battery_level,
                    battery_charging=battery_charging,
                    foreground_bundle_id=bundle_id,
                    foreground_app_name=await _resolve_app_name(
                        lockdown, bundle_id, app_names, start_lock
                    ),
                )

                while True:
                    notification: str | None = None
                    try:
                        kind, value = await asyncio.wait_for(
                            events.get(), timeout=DISPLAY_POLL_INTERVAL
                        )
                    except TimeoutError:
                        pass
                    else:
                        if kind == _EVENT_ERROR:
                            raise value
                        if kind == _EVENT_NOTIFICATION:
                            notification = value
                            # 通知の直後はまだ IORegistry に反映されていないので少し待つ。
                            await asyncio.sleep(DISPLAY_SETTLE_SECONDS)

                    normal_mode_active, brightness = await _read_display(diagnostics)
                    activity = resolve_activity(
                        activity, notification, classify_display(normal_mode_active, brightness)
                    )
                    bundle_id = foreground.bundle_id

                    now = loop.time()
                    if now - battery_read_at >= BATTERY_POLL_INTERVAL:
                        battery_level, battery_charging = await _read_battery(diagnostics)
                        battery_read_at = now

                    current = (activity, bundle_id, battery_level, battery_charging)
                    if current == yielded and now - yielded_at < BATTERY_POLL_INTERVAL:
                        continue
                    yielded = current
                    yielded_at = now
                    yield build_snapshot(
                        udid,
                        activity,
                        battery_level=battery_level,
                        battery_charging=battery_charging,
                        foreground_bundle_id=bundle_id,
                        foreground_app_name=await _resolve_app_name(
                            lockdown, bundle_id, app_names, start_lock
                        ),
                    )
        finally:
            for task in tasks:
                task.cancel()
            for task in tasks:
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    await task
            await _close_quietly(lockdown)


class _ForegroundTracker:
    """SpringBoard の syslog を流し続け、いま前面にあるアプリの bundle ID を持つ。

    pid で絞っても毎秒 900 行ほど流れてくるので、目印(``FOREGROUND_LOG_MARKER``)を含まない
    行は正規表現に渡す前に捨てる。前面が変わったときだけ ``events`` に合図を入れ、
    ``observe`` のメインループを 5 秒ポーリングを待たずに起こす。

    SpringBoard はこの行を切り替えのときにしか出さないので、購読を始めた直後は次に
    アプリが切り替わるまで「不明」(``None``)のまま。

    ストリームが切れたら前面を「不明」(``None``)に戻し、``RECONNECT_INTERVAL`` 待って
    pid の取得からやり直す。前面アプリが取れないことは観測そのものを止める理由にならないので、
    例外はここで飲み込む。
    """

    def __init__(
        self,
        lockdown: LockdownServiceProvider,
        events: asyncio.Queue[tuple[str, Any]],
        start_lock: asyncio.Lock,
    ) -> None:
        self._lockdown = lockdown
        self._events = events
        self._start_lock = start_lock
        #: いま前面にあるアプリ。ホーム画面・ロック中・未取得は ``None``。
        self.bundle_id: str | None = None

    async def run(self) -> None:
        """``observe`` が生きている間、監視と再接続を繰り返す。"""
        while True:
            try:
                await self._stream()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - 前面が取れなくても観測そのものは続ける
                logger.debug("前面アプリの監視が切れた", exc_info=True)
            self._set(None)
            await asyncio.sleep(RECONNECT_INTERVAL)

    async def _stream(self) -> None:
        """SpringBoard の pid を取り直し、その syslog を流して前面アプリを追う。"""
        pid = await self._springboard_pid()
        if pid is None:
            return
        async with _open_service(OsTraceService(self._lockdown), self._start_lock) as trace:
            async for entry in trace.syslog(pid=pid):
                apps = parse_foreground_apps(entry.message)
                if apps is None:
                    continue
                self._set(apps[0] if apps else None)

    async def _springboard_pid(self) -> int | None:
        """SpringBoard の pid を探す。見つからなければ ``None``。

        ここで使う ``OsTraceService`` は ``_stream`` のものと別インスタンスにする。
        os_trace_relay は 1 接続 1 リクエストで、使い回すと端末側から切られる。
        """
        async with _open_service(OsTraceService(self._lockdown), self._start_lock) as trace:
            payload = (await trace.get_pid_list()).get("Payload")
        if not isinstance(payload, dict):
            return None
        for pid, info in payload.items():
            if isinstance(info, dict) and info.get("ProcessName") == "SpringBoard":
                with contextlib.suppress(TypeError, ValueError):
                    return int(pid)
        return None

    def _set(self, bundle_id: str | None) -> None:
        """前面アプリを更新し、変わったときだけメインループを起こす。"""
        if bundle_id == self.bundle_id:
            return
        self.bundle_id = bundle_id
        self._events.put_nowait((_EVENT_FOREGROUND, bundle_id))


async def _pump_notifications(
    proxy: NotificationProxyService, events: asyncio.Queue[tuple[str, Any]]
) -> None:
    """Darwin 通知を受け取り続け、``observe`` のメインループへ渡す。

    受信が失敗したら例外をそのままキューに載せる。通知の受信は観測の生命線なので、
    メインループ側で送出し直し、``run_monitor_cycle`` の「応答なし」に倒してもらう。
    """
    try:
        while True:
            message = await proxy.service.recv_plist()
            events.put_nowait((_EVENT_NOTIFICATION, message.get("Name")))
    except asyncio.CancelledError:
        raise
    except Exception as error:  # noqa: BLE001 - 扱いをメインループ 1 箇所に寄せる
        events.put_nowait((_EVENT_ERROR, error))


@contextlib.asynccontextmanager
async def _open_service[ServiceT: LockdownService](
    service: ServiceT, start_lock: asyncio.Lock
) -> AsyncIterator[ServiceT]:
    """サービスを開き、使い終わったら閉じる。開く操作だけ ``start_lock`` で直列化する。

    lockdown 本体の接続は 1 本しかなく、``StartService`` のやり取りが割り込まれると応答が
    混ざる。開いた後のやり取りはサービスごとの別接続なので、排他が要るのは開くときだけ。
    """
    async with start_lock:
        await service.connect()
    try:
        yield service
    finally:
        await service.close()


async def _resolve_app_name(
    lockdown: LockdownServiceProvider,
    bundle_id: str | None,
    cache: dict[str, str | None],
    start_lock: asyncio.Lock,
) -> str | None:
    """bundle ID から表示名を引く。結果は ``observe`` の 1 セッション内で使い回す。

    引けなかったことも ``None`` として憶えるので、同じアプリに何度も問い合わせない。
    ホーム画面・ロック中(``bundle_id`` が ``None``)は問い合わせそのものをしない。
    """
    if bundle_id is None:
        return None
    if bundle_id not in cache:
        cache[bundle_id] = await _lookup_display_name(lockdown, bundle_id, start_lock)
    return cache[bundle_id]


async def _lookup_display_name(
    lockdown: LockdownServiceProvider, bundle_id: str, start_lock: asyncio.Lock
) -> str | None:
    """installation_proxy でローカライズ済みの表示名を 1 件だけ引く。

    ``com.apple.Preferences`` なら「設定」のように端末の言語で返る。常時つないでおく理由は
    無いので、知らない bundle ID が出てきたときだけ開いて閉じる。
    """
    try:
        async with _open_service(InstallationProxyService(lockdown), start_lock) as service:
            result = await service.lookup(
                {
                    "BundleIDs": [bundle_id],
                    "ReturnAttributes": ["CFBundleIdentifier", "CFBundleDisplayName"],
                }
            )
    except Exception:  # noqa: BLE001 - 表示名は補助情報。引けなくても bundle ID だけで足りる
        logger.debug("表示名を引けなかった: %s", bundle_id, exc_info=True)
        return None

    entry = result.get(bundle_id) if isinstance(result, dict) else None
    name = entry.get("CFBundleDisplayName") if isinstance(entry, dict) else None
    return name if isinstance(name, str) and name else None


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
