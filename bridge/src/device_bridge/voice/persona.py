"""ペットの人格。定義はリポジトリ直下の共通リソース ``persona/mihari_persona.py``。

セリフを作る経路が増えても口調がぶれないよう、人格（名前・一人称・呼び方・口調）は
共通リソースの 1 箇所に置き、ここはそれを読み出すだけにする。Claude / Gemini
どちらのプロンプトにも同じ ``PERSONA_RULES`` を埋め込む。ここを直しても
性格は変わらない。変えるときは共通リソースを直す。
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

#: bridge と room は別パッケージで独立に配備されるが、どちらもリポジトリ一式
#: （editable install / リポジトリ内の実行）から動く。共通リソースを import する。
_SHARED_RELPATH = ("persona", "mihari_persona.py")


def load_shared_persona() -> ModuleType:
    """共通リソース（``<repo>/persona/mihari_persona.py``）を読み込む。"""
    here = Path(__file__).resolve()
    for directory in (here.parent, *here.parents):
        candidate = directory.joinpath(*_SHARED_RELPATH)
        if candidate.is_file():
            spec = importlib.util.spec_from_file_location("mihari_persona_shared", candidate)
            assert spec is not None and spec.loader is not None
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    raise ImportError(
        "共通リソース persona/mihari_persona.py が見つからない。"
        "リポジトリ一式（bridge/ と room/ と persona/ が並ぶ形）から動かしてください。"
    )


_shared = load_shared_persona()

#: セリフを書くときに必ず守るルール。Claude / Gemini どちらのプロンプトにも埋め込む。
#: 中身は共通リソースの正本。
PERSONA_RULES = _shared.PERSONA_RULES

#: 人格属性（テスト・共通参照用）。
NAME = _shared.NAME
FIRST_PERSON = _shared.FIRST_PERSON
ADDRESS = _shared.ADDRESS
IDENTITY_RULES = _shared.IDENTITY_RULES
SPEECH_RULES = _shared.SPEECH_RULES
TONE_EXAMPLES = _shared.TONE_EXAMPLES
UTTERANCE_CHAR_LIMIT = _shared.UTTERANCE_CHAR_LIMIT
