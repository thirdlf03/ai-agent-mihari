"""LLM が使えないときの固定文言。

API キーが無い・失敗した・遅すぎたときでもペットが黙らないようにするための保険。
状況ごとに複数用意し、毎回同じにならないよう選ぶ。
"""

from __future__ import annotations

import random

from device_bridge.voice.context import Escalation, IPhoneState, SpeechContext, VisionLabel

#: 「iPhone を触っている」ときの言い回し。ここだけは状況が特徴的なので専用に持つ。
_PHONE_LINES: list[str] = [
    "パソコンほったらかしでスマホですか。手元、見えてますよ。",
    "その画面、あとで共有されても大丈夫なやつですか？",
    "スマホの方が楽しいのは分かりますけど、こっちも見てますからね。",
]

_SLEEPING_LINES: list[str] = [
    "寝てますね。今、はっきり寝顔でしたよ。",
    "おやすみのところ失礼します。まだ作業中のはずですが。",
    "まぶた、完全に閉じてました。記録しておきますね。",
]

_ABSENT_LINES: list[str] = [
    "誰もいませんね。どこ行きました？",
    "席、空っぽですよ。戻ってくる気ありますか？",
    "無人の椅子を見つめています。",
]

_BY_ESCALATION: dict[Escalation, list[str]] = {
    Escalation.NUDGE: [
        "手が止まってますよ。ちょっと休憩しました？",
        "そろそろ戻ってきませんか。待ってますよ。",
        "静かですね。まだ起きてます？",
    ],
    Escalation.WARN: [
        "さすがに止まりすぎです。いったん話を聞いてください。",
        "だいぶ放置されてますね。このままだと記録に残りますよ。",
        "はい注目。手が完全に止まってます。",
    ],
    Escalation.EXPOSE: [
        "はい、証拠いただきました。共有しておきますね。",
        "ここまでくると黙っていられません。みんなに見てもらいましょう。",
        "記録しました。あとで言い訳を考えておいてください。",
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
