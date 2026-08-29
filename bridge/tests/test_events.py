"""イベントの配信。"""

from __future__ import annotations

import asyncio
import json

import pytest
from fastapi.testclient import TestClient

from device_bridge.daemon.events import Event, EventBus


def test_event_serializes_as_sse_frame() -> None:
    frame = Event(name="watch.start", payload={"at": "19:00"}).to_sse()
    assert frame.startswith("event: watch.start\n")
    assert frame.endswith("\n\n")

    data_line = next(line for line in frame.splitlines() if line.startswith("data: "))
    body = json.loads(data_line.removeprefix("data: "))
    assert body["name"] == "watch.start"
    assert body["payload"] == {"at": "19:00"}
    assert body["created_at"]


async def test_publish_reaches_every_subscriber() -> None:
    bus = EventBus()
    first = bus.subscribe()
    second = bus.subscribe()

    bus.publish(Event(name="ping"))

    assert (await first.get()).name == "ping"
    assert (await second.get()).name == "ping"


async def test_unsubscribed_queue_stops_receiving() -> None:
    bus = EventBus()
    queue = bus.subscribe()
    bus.unsubscribe(queue)

    bus.publish(Event(name="ping"))

    assert bus.subscriber_count == 0
    with pytest.raises(asyncio.QueueEmpty):
        queue.get_nowait()


async def test_full_queue_drops_the_oldest_event() -> None:
    # 読まない購読者がいても publish 側を止めない。取りこぼしてでも進む方を選んでいる。
    bus = EventBus(queue_max_size=2)
    queue = bus.subscribe()

    for index in range(3):
        bus.publish(Event(name=f"e{index}"))

    assert [queue.get_nowait().name for _ in range(2)] == ["e1", "e2"]


def test_publish_endpoint_reports_subscriber_count(
    client: TestClient, auth: dict[str, str]
) -> None:
    response = client.post(
        "/events/publish", json={"name": "test", "payload": {"a": 1}}, headers=auth
    )
    assert response.status_code == 200
    assert response.json() == {"published": True, "name": "test", "subscribers": 0}


def test_publish_endpoint_tolerates_a_missing_payload(
    client: TestClient, auth: dict[str, str]
) -> None:
    response = client.post("/events/publish", json={}, headers=auth)
    assert response.status_code == 200
    assert response.json()["name"] == "message"
