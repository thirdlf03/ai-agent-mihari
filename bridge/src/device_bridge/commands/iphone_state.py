"""iPhone の「操作中 / 未操作 / 応答なし」を判定するための状態モデル。

画面が点いているかどうかは IORegistry(``AppleCLCD2`` の ``NormalModeActive``)から
その時点の絶対値として読めるので、観測開始時点から正しい活動状態を出せる。Darwin 通知は
「何かが変わった」という合図としてだけ使い、通知を受けたら画面状態を読み直す。
IORegistry が読めない機種では従来どおり ``IDLE``(未操作)から始め、通知だけで更新していく。

通知名だけで向きを決めないのは、実測(iOS 26.6 / iPhone 14)で ``hasWokenUp`` が
一度も発火せず、消灯時も点灯時も同じ ``hasBlankedScreen`` が来たため。通知だけでは
遷移の向きが分からず ``ACTIVE`` になる経路が無い。

実機との通信(notification_proxy の購読・diagnostics の IORegistry / バッテリー取得)は
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
# スリープから復帰し、画面が点灯したことを示す。ただし iOS 26.6 / iPhone 14 では
# 一度も発火しなかった。発火する iOS のための保険として購読だけ続けている。
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

#: 通知を受けてから画面状態が IORegistry に反映されるまで待つ秒数(実測 0.5〜1.0 秒)。
DISPLAY_SETTLE_SECONDS = 1.0
#: 通知が来なくても画面状態を読み直す間隔(秒)。
DISPLAY_POLL_INTERVAL = 5.0
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

    画面状態が IORegistry から読めない機種のための保険。読める環境では
    ``resolve_activity`` が画面状態を優先するので、この結果は使われない。

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


def classify_display(
    normal_mode_active: bool | None, backlight_brightness: int | None
) -> IphoneActivity | None:
    """IORegistry から読んだ画面の点灯状態を活動状態に直す。

    ``NormalModeActive``(``AppleCLCD2``)を主指標にし、それが読めない機種のために
    バックライトの輝度(``AppleARMBacklight``、点灯 16384 / 消灯 0)を副指標として使う。

    :param normal_mode_active: 画面が点灯していれば ``True``、消灯していれば ``False``。
        読めなければ ``None``。
    :param backlight_brightness: バックライトの輝度。読めなければ ``None``。
    :returns: 判定できた活動状態。どちらも読めなければ ``None``。
    """
    if normal_mode_active is not None:
        return IphoneActivity.ACTIVE if normal_mode_active else IphoneActivity.IDLE
    if backlight_brightness is not None:
        return IphoneActivity.ACTIVE if backlight_brightness > 0 else IphoneActivity.IDLE
    return None


def resolve_activity(
    previous: IphoneActivity, notification: str | None, display: IphoneActivity | None
) -> IphoneActivity:
    """画面状態・通知・直前の状態から、いま採用すべき活動状態を決める。

    画面状態が読めていればそれが最優先。読めない機種でだけ通知名から推定し、
    それも決め手にならなければ直前の状態を維持する。

    :param previous: 直前の活動状態。
    :param notification: 直前に受け取った通知の ``Name``(無ければ ``None``)。
    :param display: ``classify_display`` の結果(読めなければ ``None``)。
    :returns: 採用する活動状態。
    """
    if display is not None:
        return display
    from_notification = classify_notification(notification)
    if from_notification is not None:
        return from_notification
    return previous


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
