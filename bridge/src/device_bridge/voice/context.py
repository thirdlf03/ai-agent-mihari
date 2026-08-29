"""セリフを作るために必要な「いまの状況」。"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class Escalation(StrEnum):
    """サボりに対する当たりの強さ。段階が上がるほど言うことがきつくなる。"""

    #: まだ疑っているだけ。軽く声をかける。
    NUDGE = "nudge"
    #: サボり確定。音楽を止めて話を聞かせる段階。
    WARN = "warn"
    #: 証拠を Discord に晒す段階。
    EXPOSE = "expose"


class IPhoneState(StrEnum):
    """iPhone の様子。#12 が返す値に合わせる。"""

    #: 画面が点いていて触っている。
    ACTIVE = "active"
    #: 画面が消えている。
    IDLE = "idle"
    #: 圏外・スリープ・未ペアリングなどで問い合わせに答えない。
    UNREACHABLE = "unreachable"


class VisionLabel(StrEnum):
    """撮った写真に対する見立て。#11 が返す値に合わせる。"""

    SLEEPING = "sleeping"
    LOOKING_AWAY = "looking_away"
    ABSENT = "absent"
    #: 判定していない、または判定できなかった。
    UNKNOWN = "unknown"


@dataclass(frozen=True, slots=True)
class SpeechContext:
    """1 回の発話ぶんの状況。

    :param idle_seconds: Mac が無操作だった秒数。
    :param escalation: 当たりの強さ。
    :param frontmost_app: 直前まで前面にあったアプリ名。分からなければ ``None``。
    :param iphone: iPhone の様子。
    :param vision: 写真から付けたラベル。
    """

    idle_seconds: int
    escalation: Escalation = Escalation.NUDGE
    frontmost_app: str | None = None
    iphone: IPhoneState = IPhoneState.UNREACHABLE
    vision: VisionLabel = VisionLabel.UNKNOWN

    def __post_init__(self) -> None:
        if self.idle_seconds < 0:
            raise ValueError(f"idle_seconds が負: {self.idle_seconds}")

    @property
    def idle_phrase(self) -> str:
        """無操作時間を日本語で読みやすくする。"""
        if self.idle_seconds < 60:
            return f"{self.idle_seconds}秒"
        minutes = self.idle_seconds // 60
        return f"{minutes}分"

    def describe(self) -> str:
        """LLM に渡す 1 行の状況説明。"""
        parts = [
            f"Mac が {self.idle_phrase} 無操作",
            f"iPhone は{_IPHONE_TEXT[self.iphone]}",
            f"様子は{_VISION_TEXT[self.vision]}",
            f"当たりの強さは{_ESCALATION_TEXT[self.escalation]}",
        ]
        if self.frontmost_app:
            parts.insert(1, f"直前に開いていたのは {self.frontmost_app}")
        return "、".join(parts)


_IPHONE_TEXT: dict[IPhoneState, str] = {
    IPhoneState.ACTIVE: "触っている",
    IPhoneState.IDLE: "置かれたまま",
    IPhoneState.UNREACHABLE: "応答なし",
}

_VISION_TEXT: dict[VisionLabel, str] = {
    VisionLabel.SLEEPING: "寝ている",
    VisionLabel.LOOKING_AWAY: "よそ見",
    VisionLabel.ABSENT: "席にいない",
    VisionLabel.UNKNOWN: "不明",
}

_ESCALATION_TEXT: dict[Escalation, str] = {
    Escalation.NUDGE: "軽め",
    Escalation.WARN: "強め",
    Escalation.EXPOSE: "最大",
}
