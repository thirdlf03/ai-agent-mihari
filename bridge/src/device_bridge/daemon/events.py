"""Python から macOS アプリへ流すイベント。

Swift → Python は REST で足りるが、Discord Bot が受けたコマンドや iPhone の状態変化は
Python 側の都合で発生する。これを push するために SSE のチャンネルを 1 本持つ。
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

#: 購読者ごとのキューの上限。アプリが読み取りを止めても、ここで詰まって
#: メモリを食い続けないように古いイベントから捨てる。
QUEUE_MAX_SIZE = 256


@dataclass(frozen=True, slots=True)
class Event:
    """アプリに届ける 1 件のイベント。"""

    name: str
    payload: dict[str, Any] = field(default_factory=dict)
    created_at: datetime = field(default_factory=lambda: datetime.now(UTC))

    def to_sse(self) -> str:
        """SSE のフレーム 1 件分に整形する。"""
        body = json.dumps(
            {
                "name": self.name,
                "payload": self.payload,
                "created_at": self.created_at.isoformat(),
            },
            ensure_ascii=False,
        )
        return f"event: {self.name}\ndata: {body}\n\n"


class EventBus:
    """購読者へイベントを配る。購読者は SSE の接続 1 本につき 1 つ。"""

    def __init__(self, queue_max_size: int = QUEUE_MAX_SIZE) -> None:
        self._subscribers: set[asyncio.Queue[Event]] = set()
        self._queue_max_size = queue_max_size

    @property
    def subscriber_count(self) -> int:
        return len(self._subscribers)

    def subscribe(self) -> asyncio.Queue[Event]:
        queue: asyncio.Queue[Event] = asyncio.Queue(maxsize=self._queue_max_size)
        self._subscribers.add(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue[Event]) -> None:
        self._subscribers.discard(queue)

    def publish(self, event: Event) -> None:
        """全購読者へ配る。

        キューが満杯の購読者は、最も古い 1 件を捨ててから入れ直す。
        イベントを取りこぼしてでも、publish 側を待たせない方を選んでいる。
        """
        for queue in self._subscribers:
            try:
                queue.put_nowait(event)
            except asyncio.QueueFull:
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:  # pragma: no cover - 直前まで満杯だったので通常起きない
                    pass
                try:
                    queue.put_nowait(event)
                except asyncio.QueueFull:  # pragma: no cover - 同上
                    pass
