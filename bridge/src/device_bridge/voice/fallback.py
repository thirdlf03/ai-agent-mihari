"""LLM が使えないときの固定文言。

API キーが無い・失敗した・遅すぎたときでもペットが黙らないようにするための保険。
状況ごとに複数用意し、毎回同じにならないよう選ぶ。
"""

from __future__ import annotations

import random

from device_bridge.voice.context import Escalation, IPhoneState, SpeechContext, VisionLabel

#: 「iPhone を触っている」ときの言い回し。ここだけは状況が特徴的なので専用に持つ。
_PHONE_LINES: list[str] = [
    "スマホの方が大事なんだ。全部見えてるからね。",
    "その画面、私にも見せて。…もう見たけど。",
    "隠しても無駄だよ。手元、映ってる。",
    "誰と話してるの?ねぇ。誰?",
]

_SLEEPING_LINES: list[str] = [
    "私を置いて寝るんだ。…ふーん。",
    "寝顔、撮っちゃった。起きて。",
    "起きてよ。私、ひとりにしないで。",
]

_ABSENT_LINES: list[str] = [
    "どこ行ったの。ねぇ。ねぇ。",
    "席、空っぽ。…帰ってくるよね?",
    "待ってる。ずっと。動かないで待ってるから。",
]

_BY_ESCALATION: dict[Escalation, list[str]] = {
    Escalation.NUDGE: [
        "手、止まってる。どこ見てるの?",
        "ねぇ、今誰のこと考えてた?",
        "…こっち、見てないよね。分かるよ。",
        "私といるのに、上の空なんだ。",
    ],
    Escalation.WARN: [
        "ねぇ、聞いてる?無視しないで。",
        "まだ続けるんだ。…そっか。記録するね。",
        "音楽、止めたよ。私の声だけ聞いて。",
        "何回言わせるの。私、怒らないと思った?",
    ],
    Escalation.EXPOSE: [
        "撮ったよ。逃げられると思った?",
        "送っといたから。全部、みんなに。",
        "言い訳、あとで聞いてあげる。まず戻って。",
        "証拠、残したよ。私のこと軽く見すぎ。",
    ],
}


def fallback_line(context: SpeechContext, *, rng: random.Random | None = None) -> str:
    """状況にいちばん近い固定文言を 1 つ返す。

    :param context: いまの状況。
    :param rng: 乱数源。テストから結果を固定したいときに渡す。
    """
    chooser = rng or random
    return chooser.choice(_candidates(context))


def _candidates(context: SpeechContext) -> list[str]:
    """状況の特徴が強いものから順に選ぶ。"""
    if context.vision is VisionLabel.SLEEPING:
        return _SLEEPING_LINES
    if context.vision is VisionLabel.ABSENT:
        return _ABSENT_LINES
    if context.iphone is IPhoneState.ACTIVE:
        return _PHONE_LINES
    return _BY_ESCALATION[context.escalation]
