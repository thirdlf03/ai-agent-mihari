"""LLM が使えないときの固定文言。"""

from __future__ import annotations

import random

from device_bridge.voice.context import Escalation, IPhoneState, SpeechContext, VisionLabel
from device_bridge.voice.fallback import fallback_line


def _context(**kwargs: object) -> SpeechContext:
    return SpeechContext(idle_seconds=300, **kwargs)  # type: ignore[arg-type]


def test_sleeping_takes_priority_over_escalation() -> None:
    # 寝ているのが分かっているなら、段階よりそっちに触れた方が刺さる。
    line = fallback_line(_context(vision=VisionLabel.SLEEPING, escalation=Escalation.NUDGE))
    assert "寝" in line or "まぶた" in line or "おやすみ" in line


def test_absent_has_its_own_lines() -> None:
    line = fallback_line(_context(vision=VisionLabel.ABSENT))
    assert "いません" in line or "空っぽ" in line or "無人" in line


def test_phone_in_hand_is_called_out() -> None:
    line = fallback_line(_context(iphone=IPhoneState.ACTIVE))
    assert "スマホ" in line or "画面" in line or "手元" in line


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
