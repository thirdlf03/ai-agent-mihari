"""発話の状況。"""

from __future__ import annotations

import pytest

from device_bridge.voice.context import Escalation, IPhoneState, SpeechContext, VisionLabel


def test_negative_idle_is_rejected() -> None:
    with pytest.raises(ValueError, match="idle_seconds"):
        SpeechContext(idle_seconds=-1)


@pytest.mark.parametrize(
    ("seconds", "expected"),
    [(0, "0秒"), (59, "59秒"), (60, "1分"), (301, "5分")],
)
def test_idle_phrase_switches_to_minutes(seconds: int, expected: str) -> None:
    assert SpeechContext(idle_seconds=seconds).idle_phrase == expected


def test_describe_includes_every_signal() -> None:
    context = SpeechContext(
        idle_seconds=300,
        escalation=Escalation.EXPOSE,
        frontmost_app="Xcode",
        iphone=IPhoneState.ACTIVE,
        vision=VisionLabel.SLEEPING,
    )

    described = context.describe()

    assert "5分" in described
    assert "Xcode" in described
    assert "触っている" in described
    assert "寝ている" in described
    assert "最大" in described


def test_describe_names_the_iphone_app_while_the_phone_is_in_use() -> None:
    context = SpeechContext(idle_seconds=120, iphone=IPhoneState.ACTIVE, iphone_app="YouTube")

    assert "iPhone は触っている(開いているのは YouTube)" in context.describe()


def test_describe_omits_the_iphone_app_when_the_phone_is_not_in_use() -> None:
    # 置かれたままのときのアプリ名は「さっき何を見ていたか」でしかなく、根拠にならない。
    described = SpeechContext(
        idle_seconds=120, iphone=IPhoneState.IDLE, iphone_app="YouTube"
    ).describe()

    assert "YouTube" not in described
    assert "iPhone は置かれたまま" in described


def test_describe_omits_the_app_when_unknown() -> None:
    assert "直前に開いていたのは" not in SpeechContext(idle_seconds=10).describe()
