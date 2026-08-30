"""LLM が使えないときの固定文言。"""

from __future__ import annotations

import random

from device_bridge.voice.context import Escalation, IPhoneState, SpeechContext, VisionLabel
from device_bridge.voice.fallback import (
    _ABSENT_LINES,
    _BY_ESCALATION,
    _PHONE_LINES,
    _SLEEPING_LINES,
    fallback_line,
)


def _context(**kwargs: object) -> SpeechContext:
    return SpeechContext(idle_seconds=300, **kwargs)  # type: ignore[arg-type]


def test_sleeping_takes_priority_over_escalation() -> None:
    # 寝ているのが分かっているなら、段階よりそっちに触れた方が刺さる。
    line = fallback_line(_context(vision=VisionLabel.SLEEPING, escalation=Escalation.NUDGE))
    assert line in _SLEEPING_LINES


def test_absent_has_its_own_lines() -> None:
    assert fallback_line(_context(vision=VisionLabel.ABSENT)) in _ABSENT_LINES


def test_phone_in_hand_is_called_out() -> None:
    assert fallback_line(_context(iphone=IPhoneState.ACTIVE)) in _PHONE_LINES


def test_escalation_changes_the_line() -> None:
    nudge = {fallback_line(_context(escalation=Escalation.NUDGE)) for _ in range(30)}
    expose = {fallback_line(_context(escalation=Escalation.EXPOSE)) for _ in range(30)}
    assert not (nudge & expose)


def test_repeated_calls_do_not_always_return_the_same_line() -> None:
    lines = {fallback_line(_context()) for _ in range(50)}
    assert len(lines) > 1


def test_rng_can_be_fixed_for_reproducibility() -> None:
    first = fallback_line(_context(), rng=random.Random(0))
    second = fallback_line(_context(), rng=random.Random(0))
    assert first == second


def test_every_escalation_has_a_line() -> None:
    for escalation in Escalation:
        assert fallback_line(_context(escalation=escalation))


def test_the_lines_are_short_enough_to_read_aloud() -> None:
    # 読み上げ用なので、人格ルールと同じく 30 文字以内に収める。
    for lines in (_SLEEPING_LINES, _ABSENT_LINES, _PHONE_LINES, *_BY_ESCALATION.values()):
        for line in lines:
            assert len(line) <= 30, line
