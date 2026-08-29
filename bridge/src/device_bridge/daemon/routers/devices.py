"""iOS デバイスの情報を返す。

pymobiledevice3 の呼び出しは同期かつ数秒かかることがあるため、
FastAPI の `def`（スレッドプール実行）で定義してイベントループを止めない。
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, status

from device_bridge.commands import devices
from device_bridge.daemon.auth import verify_token

router = APIRouter(prefix="/devices", tags=["devices"], dependencies=[Depends(verify_token)])


@router.get("")
def list_devices(
    wifi: bool = Query(default=True, description="Wi-Fi 経由の探索を行うか"),
) -> dict[str, Any]:
    """接続中のデバイスを一覧する。"""
    try:
        return devices.list_devices(wifi=wifi)
    except Exception as error:  # noqa: BLE001 - 下層の例外は 502 として返す
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"デバイス一覧の取得に失敗した: {error}",
        ) from error


@router.get("/{udid}")
def device_info(udid: str) -> dict[str, Any]:
    """指定した UDID のデバイスの基本情報を返す。"""
    try:
        return devices.device_info(udid)
    except RuntimeError as error:
        # devices.device_info は見つからないとき RuntimeError を投げる。
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except Exception as error:  # noqa: BLE001
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"デバイス情報の取得に失敗した: {error}",
        ) from error
