"""bridge の人格参照が共通リソースを向いていて、発話の 30 文字制約と
Room の説明・完了報告の長さ制約が分離されていること（回帰なしの確認）。

bridge は「発話（読み上げる短いセリフ）」しか作らないので、プロンプトに埋めるのは
IDENTITY + SPEECH（30 文字以内）+ トーン例だけ。Room の説明・成果物の規則は
bridge には持ち込まない。
"""

from __future__ import annotations

from pathlib import Path

from device_bridge.voice.persona import (
    ADDRESS,
    FIRST_PERSON,
    IDENTITY_RULES,
    NAME,
    PERSONA_RULES,
    SPEECH_RULES,
    TONE_EXAMPLES,
    UTTERANCE_CHAR_LIMIT,
    load_shared_persona,
)


def test_persona_embedded_in_llm_prompts_keeps_the_voice() -> None:
    """generator.py / screen_reader.py が埋める PERSONA_RULES が人格を持っている。"""
    assert "みはり" in PERSONA_RULES
    assert "私" in PERSONA_RULES
    assert "あなた" in PERSONA_RULES
    assert "30 文字以内" in PERSONA_RULES
    assert "束縛" in PERSONA_RULES
    # トーン例
    assert "撮ったよ" in PERSONA_RULES


def test_bridge_references_the_shared_resource_single_source() -> None:
    """bridge の PERSONA_RULES は共通リソース（persona/mihari_persona.py）の正本。"""
    shared = load_shared_persona()
    assert PERSONA_RULES == shared.PERSONA_RULES
    assert NAME == shared.NAME == "みはり"
    assert FIRST_PERSON == shared.FIRST_PERSON == "私"
    assert ADDRESS == shared.ADDRESS == "あなた"
    assert UTTERANCE_CHAR_LIMIT == shared.UTTERANCE_CHAR_LIMIT == 30


def test_identity_and_speech_are_composed_into_persona_rules() -> None:
    """IDENTITY + SPEECH + トーン例 で PERSONA_RULES が合成されている。"""
    assert IDENTITY_RULES in PERSONA_RULES
    assert SPEECH_RULES in PERSONA_RULES
    assert TONE_EXAMPLES in PERSONA_RULES
    assert SPEECH_RULES.strip()
    assert IDENTITY_RULES.strip()


def test_room_explanation_rules_are_not_embedded_in_bridge_prompt() -> None:
    """Room の説明・完了報告の長さ制約は bridge のプロンプトに持ち込まない。"""
    # 発話向けの 30 文字制約は SPEECH_RULES（bridge 側）にある。
    assert "30 文字以内" in SPEECH_RULES
    # bridge は説明・成果物の規則を埋めない（人格がぶれないように分けておく）。
    assert "完了報告" not in PERSONA_RULES
    assert "成果物" not in PERSONA_RULES


def test_shared_persona_lives_at_repo_root_persona_dir() -> None:
    """共通リソースはリポジトリ直下の persona/ に置いてある。"""
    shared = load_shared_persona()
    source = Path(shared.__file__).resolve()
    assert source.name == "mihari_persona.py"
    assert source.parent.name == "persona"
    # bridge / room / persona が並ぶリポジトリ一式から動く前提。
    assert (source.parent.parent / "bridge").is_dir()
    assert (source.parent.parent / "room").is_dir()
