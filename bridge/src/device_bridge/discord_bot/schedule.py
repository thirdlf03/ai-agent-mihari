"""監視の開始時刻。

Discord のスラッシュコマンドで「19:00 から見張って」と指示できるようにするための、
時刻計算だけを切り出した部分。実際の発火は `scheduler.py` が行う。
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta

#: `HH:MM` の形。`9:05` のような 1 桁時も許す。
_TIME_PATTERN = re.compile(r"^(?P<hour>\d{1,2}):(?P<minute>\d{2})$")


class InvalidTimeError(ValueError):
    """指定された時刻を解釈できない。"""


def parse_time_of_day(text: str) -> tuple[int, int]:
    """`HH:MM` を時と分にする。

    :raises InvalidTimeError: 形式が違う、または範囲外。
    """
    match = _TIME_PATTERN.match(text.strip())
    if match is None:
        raise InvalidTimeError(f"HH:MM の形で指定する(例: 19:00): {text}")

    hour = int(match.group("hour"))
    minute = int(match.group("minute"))
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        raise InvalidTimeError(f"時刻が範囲外: {text}")
    return hour, minute


def next_occurrence(hour: int, minute: int, *, now: datetime) -> datetime:
    """次にその時刻が来る日時を返す。

    すでに過ぎていれば翌日にする。`/watch at 9:00` を 10 時に打ったら明日の 9 時、という挙動。
    「今日のもう過ぎた時刻」を指定されて即発火する方が驚きが大きい。
    """
    candidate = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if candidate <= now:
        candidate += timedelta(days=1)
    return candidate


def seconds_until(target: datetime, *, now: datetime) -> float:
    """発火までの秒数。すでに過ぎていれば 0。"""
    return max(0.0, (target - now).total_seconds())
