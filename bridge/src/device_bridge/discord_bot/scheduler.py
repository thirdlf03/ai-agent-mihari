"""指定時刻に監視を開始させる。

発火すると `EventBus` にイベントを流す。それを SSE で受けた macOS アプリが監視モードに入る。
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from datetime import UTC, datetime

from device_bridge.daemon.events import Event, EventBus
from device_bridge.discord_bot.schedule import next_occurrence, seconds_until

logger = logging.getLogger(__name__)

#: 監視を始めさせるイベント名。
WATCH_START_EVENT = "watch.start"
#: 監視を止めさせるイベント名。
WATCH_STOP_EVENT = "watch.stop"


@dataclass(frozen=True, slots=True)
class ScheduledWatch:
    """予約済みの監視開始。"""

    at: datetime
    requested_by: str

    def to_dict(self) -> dict[str, object]:
        return {"at": self.at.isoformat(), "requested_by": self.requested_by}


class WatchScheduler:
    """監視開始の予約を 1 件だけ持つ。

    予約を複数持てるようにしても使い道がなく、「いま何時に予約されているか」が
    分からなくなる方が困る。新しい予約は古い予約を置き換える。
    """

    def __init__(self, events: EventBus) -> None:
        self._events = events
        self._task: asyncio.Task[None] | None = None
        self._scheduled: ScheduledWatch | None = None
        self._watching = False

    @property
    def scheduled(self) -> ScheduledWatch | None:
        return self._scheduled

    @property
    def is_watching(self) -> bool:
        return self._watching

    def status(self) -> dict[str, object]:
        return {
            "watching": self._watching,
            "scheduled": self._scheduled.to_dict() if self._scheduled else None,
        }

    def start_now(self, *, requested_by: str) -> None:
        """すぐに監視を始めさせる。予約が残っていれば取り消す。"""
        self.cancel()
        self._fire(requested_by=requested_by, scheduled=False)

    def schedule_at(self, hour: int, minute: int, *, requested_by: str) -> ScheduledWatch:
        """指定時刻に監視を始めさせる。すでに過ぎていれば翌日。"""
        self.cancel()
        now = datetime.now().astimezone()
        target = next_occurrence(hour, minute, now=now)
        self._scheduled = ScheduledWatch(at=target, requested_by=requested_by)
        self._task = asyncio.create_task(self._wait_and_fire(target, requested_by))
        logger.info("監視を予約した: %s", target.isoformat())
        return self._scheduled

    def stop(self, *, requested_by: str) -> None:
        """監視を止めさせる。予約も取り消す。"""
        self.cancel()
        self._watching = False
        self._events.publish(Event(name=WATCH_STOP_EVENT, payload={"requested_by": requested_by}))

    def cancel(self) -> None:
        """予約だけ取り消す。すでに始まっている監視は止めない。"""
        if self._task is not None and not self._task.done():
            self._task.cancel()
        self._task = None
        self._scheduled = None

    async def _wait_and_fire(self, target: datetime, requested_by: str) -> None:
        try:
            await asyncio.sleep(seconds_until(target, now=datetime.now().astimezone()))
        except asyncio.CancelledError:
            return
        self._scheduled = None
        self._fire(requested_by=requested_by, scheduled=True)

    def _fire(self, *, requested_by: str, scheduled: bool) -> None:
        self._watching = True
        self._events.publish(
            Event(
                name=WATCH_START_EVENT,
                payload={
                    "requested_by": requested_by,
                    "scheduled": scheduled,
                    "fired_at": datetime.now(UTC).isoformat(),
                },
            )
        )
