"""監視開始の予約と発火。"""

from __future__ import annotations

import asyncio

from device_bridge.daemon.events import EventBus
from device_bridge.discord_bot.scheduler import (
    WATCH_START_EVENT,
    WATCH_STOP_EVENT,
    WatchScheduler,
)


async def test_start_now_fires_immediately() -> None:
    bus = EventBus()
    queue = bus.subscribe()
    scheduler = WatchScheduler(bus)

    scheduler.start_now(requested_by="tester")

    event = await queue.get()
    assert event.name == WATCH_START_EVENT
    assert event.payload["requested_by"] == "tester"
    assert event.payload["scheduled"] is False
    assert scheduler.is_watching is True


async def test_stop_publishes_and_clears() -> None:
    bus = EventBus()
    queue = bus.subscribe()
    scheduler = WatchScheduler(bus)
    scheduler.start_now(requested_by="tester")
    await queue.get()

    scheduler.stop(requested_by="tester")

    assert (await queue.get()).name == WATCH_STOP_EVENT
    assert scheduler.is_watching is False
    assert scheduler.scheduled is None


async def test_scheduling_records_the_time_without_firing() -> None:
    bus = EventBus()
    queue = bus.subscribe()
    scheduler = WatchScheduler(bus)

    scheduled = scheduler.schedule_at(23, 59, requested_by="tester")

    assert scheduler.scheduled == scheduled
    assert scheduler.is_watching is False
    # 予約しただけでは何も流れない。
    await asyncio.sleep(0)
    assert queue.empty()


async def test_a_new_schedule_replaces_the_old_one() -> None:
    # 予約を複数持てても使い道がなく、「いま何時に予約されているか」が分からなくなる方が困る。
    scheduler = WatchScheduler(EventBus())
    scheduler.schedule_at(23, 58, requested_by="tester")
    second = scheduler.schedule_at(23, 59, requested_by="tester")

    assert scheduler.scheduled == second


async def test_cancel_clears_the_reservation() -> None:
    scheduler = WatchScheduler(EventBus())
    scheduler.schedule_at(23, 59, requested_by="tester")

    scheduler.cancel()

    assert scheduler.scheduled is None


async def test_status_reports_both_watching_and_reservation() -> None:
    scheduler = WatchScheduler(EventBus())
    assert scheduler.status() == {"watching": False, "scheduled": None}

    scheduler.schedule_at(23, 59, requested_by="tester")
    status = scheduler.status()
    assert status["watching"] is False
    assert isinstance(status["scheduled"], dict)
