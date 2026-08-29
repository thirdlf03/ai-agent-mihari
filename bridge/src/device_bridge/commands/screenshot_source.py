"""``ScreenshotSource`` の実機実装。

セルフチェック(Developer Mode / DDI マウント / tunneld 到達性)と実際のキャプチャを、
pymobiledevice3 で行う薄い層。``screenshot.py`` 側は本モジュールの具象クラスを知らな
くても動くようにしてあり、実機が無い環境でもテストは本モジュールを差し替えて成立させる。

lockdown への接続方針(USB を優先し、無ければ tunneld のトンネル経由)は
``commands/iphone_state_source.py`` の ``_connect_lockdown`` と同じ考え方を踏襲する。
bonjour で見つけたホストへ TCP:62078 で直接繋ぐ classic な Wi-Fi lockdown は使わない
(理由は ``commands/devices.py`` の docstring を参照)。

前提が揃っているかの判定は、いずれも DDI 不要な軽い問い合わせで完結する。USB でもトンネル
でも同じ呼び出しで済む(``MobileImageMounterService`` は RSD を渡すと ``.shim.remote`` の
サービス名に切り替わり、``get_developer_mode_status`` は RSD のリモート lockdown が受ける)。

- Developer Mode: ``lockdown.get_developer_mode_status()``(lockdown の値照会)
- DDI マウント: ``com.apple.mobile.mobile_image_mounter``(is_developer_service ではない
  ため lockdown だけで問い合わせできる)。DDI 自体のマウントも同じ経路で行う。
- tunneld 到達性: iOS 17+ の developer サービス(スクリーンショット含む)は
  RemoteXPC トンネル越しにしか届かないため、tunneld の HTTP API にこのデバイスの
  トンネルが登録されているかを見る

実際のキャプチャは iOS バージョンで経路を変える。

- iOS 17 未満: classic lockdown 上の ``com.apple.mobile.screenshotr``
- iOS 17+: tunneld から得た ``RemoteServiceDiscoveryService`` 上で **DVT** の
  ``com.apple.instruments.server.services.screenshot`` を使う

iOS 17+ で ``screenshotr`` を使わないのは、RSD のサービス一覧に載っておらず
``No such service: com.apple.mobile.screenshotr`` になるため(iOS 26.4.1 で確認)。
pymobiledevice3 の CLI も ``developer screenshot``(非推奨・screenshotr)は失敗し、
``developer dvt screenshot``(DVT)だけが成功する。
"""

from __future__ import annotations

import asyncio
import io
from collections.abc import Coroutine
from typing import Any

from packaging.version import Version
from PIL import Image
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.lockdown_service_provider import LockdownServiceProvider
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot
from pymobiledevice3.services.mobile_image_mounter import (
    DeveloperDiskImageMounter,
    MobileImageMounterService,
    PersonalizedImageMounter,
)
from pymobiledevice3.services.screenshot import ScreenshotService
from pymobiledevice3.tunneld.api import get_tunneld_device_by_udid

from device_bridge.commands import devices as devices_module
from device_bridge.commands.screenshot import PreflightFacts, requires_tunneld

#: DDI 関連の問い合わせ 1 回あたりのタイムアウト(秒)。応答が無い端末で待たされ続けない。
FACTS_TIMEOUT = 5.0


class LiveScreenshotSource:
    """実機に接続してセルフチェックとスクリーンショット撮影を行う。"""

    async def find_device(self) -> str | None:
        """接続中(USB、無ければ tunneld のトンネル)の UDID を 1 つ返す。

        USB を抜いても、tunneld がトンネルを張っていれば「接続できる」と判定する。
        """
        udids = await devices_module.list_connected_udids()
        return udids[0] if udids else None

    async def gather_preflight_facts(self, udid: str) -> PreflightFacts:
        """セルフチェックに必要な事実を集める。個々の失敗は ``None`` に丸める。"""
        try:
            lockdown = await _connect_lockdown(udid)
        except Exception:  # noqa: BLE001 - 接続自体の失敗はすべて「不明」として扱う
            return PreflightFacts(
                ios_version=None,
                developer_mode_enabled=None,
                ddi_mounted=None,
                tunneld_reachable=None,
            )

        try:
            ios_version = lockdown.product_version
            developer_mode_enabled = await _safe(lockdown.get_developer_mode_status())
            ddi_mounted = await _safe(_is_ddi_mounted(lockdown, ios_version))
            tunneld_reachable = (
                await _safe(_is_tunneld_reachable(udid)) if requires_tunneld(ios_version) else None
            )
            return PreflightFacts(
                ios_version=ios_version,
                developer_mode_enabled=developer_mode_enabled,
                ddi_mounted=ddi_mounted,
                tunneld_reachable=tunneld_reachable,
            )
        finally:
            await _close_quietly(lockdown)

    async def capture_png(self, udid: str) -> bytes:
        """スクリーンショットを撮り、PNG バイト列を返す。

        どちらの経路も PNG または TIFF を返しうるため、TIFF だった場合は
        Pillow で PNG に変換して常に PNG を保証する。
        """
        lockdown = await _connect_lockdown(udid)
        try:
            if requires_tunneld(lockdown.product_version):
                raw = await _capture_via_dvt(udid)
            else:
                async with ScreenshotService(lockdown=lockdown) as service:
                    raw = await service.take_screenshot()
            return _ensure_png(raw)
        finally:
            await _close_quietly(lockdown)


async def _capture_via_dvt(udid: str) -> bytes:
    """iOS 17+ 向け。tunneld のトンネル越しに DVT のスクリーンショットを撮る。

    RSD には ``com.apple.mobile.screenshotr`` が載っていないため、
    Instruments 側の ``...services.screenshot`` チャンネルを使う。
    """
    rsd = await get_tunneld_device_by_udid(udid)
    if rsd is None:
        raise RuntimeError(f"tunneld にこのデバイスのトンネルが無い: {udid}")
    async with DvtProvider(rsd) as dvt, Screenshot(dvt) as screenshot:
        return await screenshot.get_screenshot()


def _ensure_png(raw: bytes) -> bytes:
    """PNG シグネチャで無ければ Pillow で PNG へ変換する。"""
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return raw
    with Image.open(io.BytesIO(raw)) as image:
        buffer = io.BytesIO()
        image.save(buffer, format="PNG")
        return buffer.getvalue()


async def _safe(coroutine: Coroutine[Any, Any, bool]) -> bool | None:
    """個々の事実収集を ``asyncio.wait_for`` でくくり、失敗を ``None`` に丸める。"""
    try:
        return await asyncio.wait_for(coroutine, timeout=FACTS_TIMEOUT)
    except Exception:  # noqa: BLE001 - 補助情報の取得失敗でセルフチェック全体を止めない
        return None


async def _is_ddi_mounted(lockdown: LockdownServiceProvider, ios_version: str) -> bool:
    """iOS バージョンに応じたイメージ種別で、DDI がマウント済みかを見る。"""
    mounter = _mounter_for(lockdown, ios_version)
    async with mounter:
        return await mounter.is_image_mounted(mounter.IMAGE_TYPE)


def _mounter_for(lockdown: LockdownServiceProvider, ios_version: str) -> MobileImageMounterService:
    if Version(ios_version).major >= 17:
        return PersonalizedImageMounter(lockdown=lockdown)
    return DeveloperDiskImageMounter(lockdown=lockdown)


async def _is_tunneld_reachable(udid: str) -> bool:
    """tunneld がこのデバイス向けのトンネルを張っているかを見る。

    HTTP API の一覧に UDID が載っているかだけを見る。実際にトンネルへ繋いで確かめないのは、
    ここが軽い前提チェックであり、繋いだ RSD の後始末まで面倒を見たくないため。
    """
    return udid in await devices_module.list_tunnel_udids()


async def _connect_lockdown(udid: str) -> LockdownServiceProvider:
    """USB で見えていれば usbmuxd 経由、無ければ tunneld のトンネル経由で繋ぐ。

    ``iphone_state_source._connect_lockdown`` と同じ考え方を踏襲している。
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
