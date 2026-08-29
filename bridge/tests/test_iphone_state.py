"""iPhone 状態モデルの正規化・変化検出・エラー時のフォールバックを確かめる。

実機には依存しない。``DeviceStateSource`` はすべてフェイクに差し替える。
"""

from __future__ import annotations

from collections.abc import AsyncIterator

import pytest

from device_bridge.commands.iphone_state import (
    IphoneActivity,
    IphoneStateSnapshot,
    IphoneStateStore,
    build_snapshot,
    classify_display,
    classify_notification,
    resolve_activity,
    run_monitor_cycle,
    unresponsive_snapshot,
)

UDID = "known-udid"


class FakeSource:
    """``DeviceStateSource`` のフェイク実装。

    :param udid: ``find_device`` が返す UDID。``None`` なら未接続を模す。
    :param snapshots: ``observe`` が順に yield するスナップショット。
    :param raise_after: 指定した件数だけ yield した後に例外を送出する(接続断を模す)。
    """

    def __init__(
        self,
        udid: str | None,
        snapshots: list[IphoneStateSnapshot] | None = None,
        raise_after: int | None = None,
    ) -> None:
        self._udid = udid
        self._snapshots = snapshots or []
        self._raise_after = raise_after

    async def find_device(self) -> str | None:
        return self._udid

    async def observe(self, udid: str) -> AsyncIterator[IphoneStateSnapshot]:
        for index, snapshot in enumerate(self._snapshots):
            if self._raise_after is not None and index == self._raise_after:
                raise ConnectionError("device went away")
            yield snapshot


class RaisingFindSource:
    """``find_device`` 自体が例外を投げるフェイク(usbmuxd に繋がらない等)。"""

    async def find_device(self) -> str | None:
        raise OSError("usbmuxd に繋がらない")

    async def observe(self, udid: str) -> AsyncIterator[IphoneStateSnapshot]:
        return
        yield  # pragma: no cover - ジェネレータにするためのダミー


def test_classify_notification_maps_wake_to_active() -> None:
    assert classify_notification("com.apple.springboard.hasWokenUp") == IphoneActivity.ACTIVE


def test_classify_notification_maps_blank_and_lockcomplete_to_idle() -> None:
    assert classify_notification("com.apple.springboard.hasBlankedScreen") == IphoneActivity.IDLE
    assert classify_notification("com.apple.springboard.lockcomplete") == IphoneActivity.IDLE


def test_classify_notification_ignores_ambiguous_lockstate() -> None:
    assert classify_notification("com.apple.springboard.lockstate") is None


def test_classify_notification_ignores_unknown_names() -> None:
    assert classify_notification("com.example.something.else") is None
    assert classify_notification(None) is None


def test_classify_display_prefers_normal_mode_active() -> None:
    # 主指標が読めていれば、副指標が矛盾していても主指標に従う。
    assert classify_display(True, 0) == IphoneActivity.ACTIVE
    assert classify_display(False, 16384) == IphoneActivity.IDLE


def test_classify_display_falls_back_to_backlight_brightness() -> None:
    # AppleCLCD2 が無い機種向けの保険。
    assert classify_display(None, 16384) == IphoneActivity.ACTIVE
    assert classify_display(None, 0) == IphoneActivity.IDLE


def test_classify_display_returns_none_when_nothing_readable() -> None:
    assert classify_display(None, None) is None


def test_resolve_activity_prefers_display_over_notification() -> None:
    # 画面状態が読めているときは通知名より優先する。
    assert (
        resolve_activity(
            IphoneActivity.IDLE,
            "com.apple.springboard.hasBlankedScreen",
            IphoneActivity.ACTIVE,
        )
        == IphoneActivity.ACTIVE
    )
    assert (
        resolve_activity(
            IphoneActivity.ACTIVE,
            "com.apple.springboard.hasWokenUp",
            IphoneActivity.IDLE,
        )
        == IphoneActivity.IDLE
    )


def test_resolve_activity_uses_notification_when_display_unreadable() -> None:
    assert (
        resolve_activity(IphoneActivity.IDLE, "com.apple.springboard.hasWokenUp", None)
        == IphoneActivity.ACTIVE
    )
    assert (
        resolve_activity(IphoneActivity.ACTIVE, "com.apple.springboard.hasBlankedScreen", None)
        == IphoneActivity.IDLE
    )


def test_resolve_activity_keeps_previous_without_display_or_notification() -> None:
    assert resolve_activity(IphoneActivity.ACTIVE, None, None) == IphoneActivity.ACTIVE
    assert resolve_activity(IphoneActivity.IDLE, None, None) == IphoneActivity.IDLE


def test_resolve_activity_keeps_previous_for_ambiguous_lockstate() -> None:
    # lockstate は向きが分からないので、画面状態が無ければ直前の状態を保つ。
    assert (
        resolve_activity(IphoneActivity.ACTIVE, "com.apple.springboard.lockstate", None)
        == IphoneActivity.ACTIVE
    )


def test_snapshot_to_payload_is_json_friendly() -> None:
    snapshot = build_snapshot(
        UDID, IphoneActivity.ACTIVE, battery_level=87.0, battery_charging=True
    )
    payload = snapshot.to_payload()

    assert payload["activity"] == "active"
    assert payload["udid"] == UDID
    assert payload["battery_level"] == 87.0
    assert payload["battery_charging"] is True
    assert payload["updated_at"]


def test_store_starts_unresponsive() -> None:
    store = IphoneStateStore()
    assert store.snapshot.activity == IphoneActivity.UNRESPONSIVE


def test_store_fires_on_change_only_when_activity_changes() -> None:
    changes: list[IphoneActivity] = []
    store = IphoneStateStore(on_change=lambda snapshot: changes.append(snapshot.activity))

    store.update(build_snapshot(UDID, IphoneActivity.ACTIVE))
    store.update(build_snapshot(UDID, IphoneActivity.ACTIVE, battery_level=50.0))
    store.update(build_snapshot(UDID, IphoneActivity.ACTIVE, battery_level=49.0))
    store.update(build_snapshot(UDID, IphoneActivity.IDLE))

    # 同じ activity が続く間(バッテリー値だけの更新含む)はイベントを流さない。
    assert changes == [IphoneActivity.ACTIVE, IphoneActivity.IDLE]
    assert store.snapshot.activity == IphoneActivity.IDLE


def test_store_update_returns_whether_it_changed() -> None:
    store = IphoneStateStore()
    assert store.update(build_snapshot(UDID, IphoneActivity.ACTIVE)) is True
    assert store.update(build_snapshot(UDID, IphoneActivity.ACTIVE)) is False


async def test_monitor_cycle_falls_back_to_unresponsive_when_device_not_found() -> None:
    store = IphoneStateStore()
    store.update(build_snapshot(UDID, IphoneActivity.ACTIVE))

    await run_monitor_cycle(store, FakeSource(udid=None))

    assert store.snapshot.activity == IphoneActivity.UNRESPONSIVE


async def test_monitor_cycle_falls_back_to_unresponsive_when_find_device_raises() -> None:
    store = IphoneStateStore()

    await run_monitor_cycle(store, RaisingFindSource())

    assert store.snapshot.activity == IphoneActivity.UNRESPONSIVE


async def test_monitor_cycle_applies_observed_snapshots_in_order() -> None:
    store = IphoneStateStore()
    seen: list[IphoneActivity] = []
    store = IphoneStateStore(on_change=lambda snapshot: seen.append(snapshot.activity))
    snapshots = [
        build_snapshot(UDID, IphoneActivity.ACTIVE),
        build_snapshot(UDID, IphoneActivity.IDLE),
    ]

    await run_monitor_cycle(store, FakeSource(udid=UDID, snapshots=snapshots))

    # observe が(切断などで)終わった後は最終的に「応答なし」へ倒す。
    assert seen == [IphoneActivity.ACTIVE, IphoneActivity.IDLE, IphoneActivity.UNRESPONSIVE]


async def test_monitor_cycle_falls_back_to_unresponsive_when_observe_raises_midway() -> None:
    store = IphoneStateStore()
    snapshots = [build_snapshot(UDID, IphoneActivity.ACTIVE)]

    await run_monitor_cycle(store, FakeSource(udid=UDID, snapshots=snapshots, raise_after=1))

    assert store.snapshot.activity == IphoneActivity.UNRESPONSIVE


def test_unresponsive_snapshot_carries_udid_when_known() -> None:
    snapshot = unresponsive_snapshot(UDID)
    assert snapshot.activity == IphoneActivity.UNRESPONSIVE
    assert snapshot.udid == UDID


@pytest.mark.parametrize("value", list(IphoneActivity))
def test_activity_enum_values_are_stable_strings(value: IphoneActivity) -> None:
    # Swift 側と共有する契約なので、値の綴りが変わっていないことを固定しておく。
    assert value.value in {"active", "idle", "unresponsive"}
