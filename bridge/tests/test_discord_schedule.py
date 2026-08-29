"""監視開始時刻の計算。"""

from __future__ import annotations

from datetime import datetime

import pytest

from device_bridge.discord_bot.schedule import (
    InvalidTimeError,
    next_occurrence,
    parse_time_of_day,
    seconds_until,
)

NOW = datetime(2026, 8, 29, 10, 0, 0)


@pytest.mark.parametrize(
    ("text", "expected"), [("19:00", (19, 0)), ("9:05", (9, 5)), ("00:00", (0, 0))]
)
def test_parses_time(text: str, expected: tuple[int, int]) -> None:
    assert parse_time_of_day(text) == expected


@pytest.mark.parametrize("text", ["1900", "19:0", "とけい", "", "19:60", "24:00", "-1:00"])
def test_rejects_bad_time(text: str) -> None:
    with pytest.raises(InvalidTimeError):
        parse_time_of_day(text)


def test_future_time_is_today() -> None:
    assert next_occurrence(19, 0, now=NOW) == datetime(2026, 8, 29, 19, 0)


def test_past_time_moves_to_tomorrow() -> None:
    # 過ぎた時刻を指定されて即発火する方が驚きが大きいので、翌日にする。
    assert next_occurrence(9, 0, now=NOW) == datetime(2026, 8, 30, 9, 0)


def test_the_current_minute_moves_to_tomorrow() -> None:
    assert next_occurrence(10, 0, now=NOW) == datetime(2026, 8, 30, 10, 0)


def test_seconds_until_counts_forward() -> None:
    assert seconds_until(datetime(2026, 8, 29, 10, 1), now=NOW) == 60.0


def test_seconds_until_never_goes_negative() -> None:
    assert seconds_until(datetime(2026, 8, 29, 9, 0), now=NOW) == 0.0
