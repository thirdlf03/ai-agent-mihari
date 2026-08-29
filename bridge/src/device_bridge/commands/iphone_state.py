"""iPhone の「操作中 / 未操作 / 応答なし」を判定するための状態モデル。

Darwin 通知は変化した瞬間だけを伝える差分通知であり、購読開始時点の絶対状態は分からない。
そのため観測を始めた直後は ``IDLE``(未操作)として扱い、以後の通知で更新していく。
この前提は既知の制約として PR に明記している。

実機との通信(notification_proxy の購読・diagnostics のバッテリー取得)は
``iphone_state_source.LiveDeviceStateSource`` に隔離してあり、このモジュールは
それを差し替え可能にする ``DeviceStateSource`` プロトコルにしか依存しない。
実機が無い環境でも本モジュールは import・実行でき、テストでは
``DeviceStateSource`` をフェイクに差し替えて検証する。
"""

from __future__ import annotations

import asyncio
import contextlib
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any, Protocol

# 画面が消灯した(ブランクした)ことを示す。iOS のバージョンにより変わりうる非公開の通知名。
NOTIFICATION_SCREEN_BLANKED = "com.apple.springboard.hasBlankedScreen"
# スリープから復帰し、画面が点灯したことを示す。
NOTIFICATION_SCREEN_WOKEN = "com.apple.springboard.hasWokenUp"
# ロック状態が変化した(遷移の向きまでは分からない)。参考情報として購読はするが、
# 単体では活動状態を確定させる根拠にしない。
NOTIFICATION_LOCK_STATE = "com.apple.springboard.lockstate"
# ロック処理が完了した(画面が消灯しロックされた状態になった)。
NOTIFICATION_LOCK_COMPLETE = "com.apple.springboard.lockcomplete"

#: 購読する Darwin 通知の一覧。
OBSERVED_NOTIFICATIONS: tuple[str, ...] = (
    NOTIFICATION_SCREEN_BLANKED,
    NOTIFICATION_SCREEN_WOKEN,
    NOTIFICATION_LOCK_STATE,
    NOTIFICATION_LOCK_COMPLETE,
)

#: 通知が来ない間、バッテリー情報を取り直す間隔(秒)。
BATTERY_POLL_INTERVAL = 30.0
#: デバイスが見つからない・観測が切れたときの再接続間隔(秒)。
RECONNECT_INTERVAL = 5.0


class IphoneActivity(StrEnum):
    """Swift 側がサボり判定の分岐に使う 3 値の正規化状態。"""

    ACTIVE = "active"  # 操作中
    IDLE = "idle"  # 未操作
    UNRESPONSIVE = "unresponsive"  # 応答なし(未接続・未ペアリング・機内モードなど)


@dataclass(frozen=True, slots=True)
class IphoneStateSnapshot:
    """ある時点の iPhone 状態。"""

    activity: IphoneActivity
    udid: str | None = None
    battery_level: float | None = None
    battery_charging: bool | None = None
    updated_at: datetime = field(default_factory=lambda: datetime.now(UTC))

    def to_payload(self) -> dict[str, Any]:
        """REST / SSE で送る JSON 互換の辞書に変換する。"""
        return {
            "activity": self.activity.value,
            "udid": self.udid,
            "battery_level": self.battery_level,
            "battery_charging": self.battery_charging,
            "updated_at": self.updated_at.isoformat(),
        }


#: 監視を始める前の初期値。実機が見つかるまでは「応答なし」として扱う。
UNKNOWN_SNAPSHOT = IphoneStateSnapshot(activity=IphoneActivity.UNRESPONSIVE)


def classify_notification(name: str | None) -> IphoneActivity | None:
    """Darwin 通知名から活動状態を推定する。

    対象外の通知(``lockstate`` など方向が分からないもの)は ``None`` を返し、
    呼び出し側は直前の状態を維持する。

    :param name: 受信した通知の ``Name``。
    :returns: 推定できた活動状態、推定できなければ ``None``。
    """
    if name == NOTIFICATION_SCREEN_WOKEN:
        return IphoneActivity.ACTIVE
    if name in (NOTIFICATION_SCREEN_BLANKED, NOTIFICATION_LOCK_COMPLETE):
        return IphoneActivity.IDLE
    return None


def build_snapshot(
    udid: str | None,
    activity: IphoneActivity,
    *,
    battery_level: float | None = None,
    battery_charging: bool | None = None,
) -> IphoneStateSnapshot:
    """現在時刻を刻んだスナップショットを作る。"""
    return IphoneStateSnapshot(
        activity=activity,
        udid=udid,
        battery_level=battery_level,
        battery_charging=battery_charging,
    )


def unresponsive_snapshot(udid: str | None = None) -> IphoneStateSnapshot:
    """「応答なし」のスナップショットを作る。"""
    return build_snapshot(udid, IphoneActivity.UNRESPONSIVE)


class IphoneStateStore:
    """現在のスナップショットを保持し、``activity`` が変わったときだけ通知する。

    「状態が変化したときだけ SSE でイベントを流す」を成立させる核。
    """

    def __init__(self, on_change: Callable[[IphoneStateSnapshot], None] | None = None) -> None:
        self._snapshot = UNKNOWN_SNAPSHOT
        self._on_change = on_change

    @property
    def snapshot(self) -> IphoneStateSnapshot:
        """現在のスナップショット。"""
        return self._snapshot

    def update(self, snapshot: IphoneStateSnapshot) -> bool:
        """新しいスナップショットを反映する。

        :param snapshot: 新しく観測されたスナップショット。
        :returns: ``activity`` が直前と変わっていれば ``True``。バッテリー値だけの
            更新など、``activity`` が同じときは ``False`` で ``on_change`` も呼ばない。
        """
        changed = snapshot.activity != self._snapshot.activity
        self._snapshot = snapshot
        if changed and self._on_change is not None:
            self._on_change(snapshot)
        return changed


class DeviceStateSource(Protocol):
    """実機とやり取りする薄い層のインターフェース。テストではフェイクに差し替える。"""

    async def find_device(self) -> str | None:
        """接続中(USB または Wi-Fi)の既知デバイスの UDID を 1 つ探す。

        :returns: 見つかった UDID。1 台も見つからなければ ``None``。
        """
        ...

    def observe(self, udid: str) -> AsyncIterator[IphoneStateSnapshot]:
        """指定デバイスを観測し、状態が分かるたびにスナップショットを yield し続ける。

        接続が切れた・観測できなくなった場合は例外を送出するか、単に終了してよい。
        呼び出し側(``run_monitor_cycle``)がどちらのケースも「応答なし」に倒す。
        """
        ...


async def run_monitor_cycle(store: IphoneStateStore, source: DeviceStateSource) -> None:
    """観測を 1 サイクル行う。

    デバイスが見つからない・観測中に例外が起きた・観測が終わった、のいずれの場合も
    最終的に「応答なし」へ倒して戻る。例外はここで飲み込み、外へは伝播させない。
    """
    try:
        udid = await source.find_device()
    except Exception:  # noqa: BLE001 - 探索の失敗も応答なし扱いにする
        udid = None

    if udid is None:
        store.update(unresponsive_snapshot())
        return

    try:
        async for snapshot in source.observe(udid):
            store.update(snapshot)
    except Exception:  # noqa: BLE001 - 接続断・未ペアリング・機内モードなどをすべて吸収する
        pass

    store.update(unresponsive_snapshot(udid))


async def run_monitor(
    store: IphoneStateStore,
    source: DeviceStateSource,
    *,
    stop_event: asyncio.Event,
    reconnect_interval: float = RECONNECT_INTERVAL,
) -> None:
    """``stop_event`` が立つまで、観測と再接続待ちを繰り返す。

    デーモンの背景タスクとして常駐させる想定のループ本体。
    """
    while not stop_event.is_set():
        await run_monitor_cycle(store, source)
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(stop_event.wait(), timeout=reconnect_interval)
