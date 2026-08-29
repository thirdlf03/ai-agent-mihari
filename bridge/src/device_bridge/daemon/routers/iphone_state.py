"""iPhone の現在状態を返す REST と、変化を SSE へ流す配線。

実際の監視(notification_proxy の購読 + diagnostics のポーリング)は、このルーターへ
最初にアクセスがあったタイミングで遅延起動するバックグラウンドタスクが担う。
デーモン起動直後、まだ誰も iPhone の状態を見ていない間は接続を試みない。

``app.py`` には本ルーターの登録行しか足していないため、タスクの生成・停止は
``request.app.state`` を使って自前で管理している。
"""

from __future__ import annotations

import asyncio
from typing import Any

from fastapi import APIRouter, Depends, Request

from device_bridge.commands import iphone_state, iphone_state_source
from device_bridge.daemon.auth import verify_token
from device_bridge.daemon.events import Event, EventBus

router = APIRouter(prefix="/iphone", tags=["iphone"], dependencies=[Depends(verify_token)])

_STORE_ATTR = "iphone_state_store"
_TASK_ATTR = "iphone_state_task"
_STOP_ATTR = "iphone_state_stop"


@router.get("/state")
async def get_state(request: Request) -> dict[str, Any]:
    """現在の iPhone 状態を返す。呼ばれた時点で監視が始まっていなければここで始める。"""
    store = _ensure_monitor_started(request)
    return store.snapshot.to_payload()


def _ensure_monitor_started(request: Request) -> iphone_state.IphoneStateStore:
    """アプリの状態に監視タスクが無ければ作る。あれば既存のものを返す(冪等)。"""
    app_state = request.app.state
    store: iphone_state.IphoneStateStore | None = getattr(app_state, _STORE_ATTR, None)
    if store is not None:
        return store

    bus: EventBus = app_state.events
    store = iphone_state.IphoneStateStore(on_change=lambda snapshot: _publish(bus, snapshot))
    stop_event = asyncio.Event()
    task = asyncio.create_task(
        iphone_state.run_monitor(
            store, iphone_state_source.LiveDeviceStateSource(), stop_event=stop_event
        ),
        name="iphone-state-monitor",
    )

    setattr(app_state, _STORE_ATTR, store)
    setattr(app_state, _TASK_ATTR, task)
    setattr(app_state, _STOP_ATTR, stop_event)
    return store


def _publish(bus: EventBus, snapshot: iphone_state.IphoneStateSnapshot) -> None:
    """状態変化を ``iphone.state`` という名前空間の SSE イベントとして流す。"""
    bus.publish(Event(name="iphone.state", payload=snapshot.to_payload()))
