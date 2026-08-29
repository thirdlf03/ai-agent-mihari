"""VOICEVOX クライアント。

**実際のエンジンは呼ばない。** httpx のトランスポートを差し替えて応答を作る。
"""

from __future__ import annotations

import json
from typing import Any

import httpx
import pytest

from device_bridge.voice import voicevox as voicevox_module
from device_bridge.voice.voicevox import (
    DEFAULT_SPEAKER,
    VoiceTuning,
    VoicevoxClient,
    VoicevoxUnavailableError,
)

WAV = b"RIFF....WAVE"

#: `/audio_query` が返す JSON。調整で消えては困るキーを混ぜてある。
QUERY = {"accent_phrases": [{"moras": []}], "outputSamplingRate": 24000}


class _Recorder:
    """呼ばれたパスと送られたボディを記録しつつ、決めた応答を返す。"""

    def __init__(self, *, status: int = 200, fail: Exception | None = None) -> None:
        self.paths: list[str] = []
        self.bodies: dict[str, Any] = {}
        self._status = status
        self._fail = fail

    def handler(self, request: httpx.Request) -> httpx.Response:
        if self._fail is not None:
            raise self._fail
        self.paths.append(request.url.path)
        if request.content:
            self.bodies[request.url.path] = json.loads(request.content)
        if self._status != 200:
            return httpx.Response(self._status)
        if request.url.path == "/audio_query":
            return httpx.Response(200, json=QUERY)
        if request.url.path == "/version":
            return httpx.Response(200, json="0.0.0")
        return httpx.Response(200, content=WAV)


@pytest.fixture
def install(monkeypatch: pytest.MonkeyPatch):
    """`httpx.AsyncClient` を差し替えるフィクスチャ。"""

    def _install(recorder: _Recorder) -> None:
        transport = httpx.MockTransport(recorder.handler)
        original = httpx.AsyncClient

        def factory(**kwargs: object) -> httpx.AsyncClient:
            kwargs.pop("transport", None)
            return original(transport=transport, **kwargs)  # type: ignore[arg-type]

        monkeypatch.setattr(voicevox_module.httpx, "AsyncClient", factory)

    return _install


async def test_synthesize_calls_audio_query_then_synthesis(install) -> None:
    recorder = _Recorder()
    install(recorder)

    audio = await VoicevoxClient("http://engine").synthesize("こんにちは")

    assert audio == WAV
    assert recorder.paths == ["/audio_query", "/synthesis"]


async def test_second_call_with_the_same_line_is_served_from_cache(install) -> None:
    recorder = _Recorder()
    install(recorder)
    client = VoicevoxClient("http://engine")

    await client.synthesize("同じセリフ")
    await client.synthesize("同じセリフ")

    # 2 回目はエンジンを叩かない。待たされずに鳴らすため。
    assert recorder.paths == ["/audio_query", "/synthesis"]
    assert client.cached_count == 1


async def test_different_speakers_are_cached_separately(install) -> None:
    recorder = _Recorder()
    install(recorder)
    client = VoicevoxClient("http://engine")

    await client.synthesize("やあ", speaker=1)
    await client.synthesize("やあ", speaker=2)

    assert client.cached_count == 2
    assert len(recorder.paths) == 4


async def test_cache_drops_the_oldest_entry(install) -> None:
    install(_Recorder())
    client = VoicevoxClient("http://engine", cache_capacity=2)

    for text in ["1つめ", "2つめ", "3つめ"]:
        await client.synthesize(text)

    assert client.cached_count == 2


async def test_engine_down_raises_a_readable_error(install) -> None:
    install(_Recorder(fail=httpx.ConnectError("refused")))

    with pytest.raises(VoicevoxUnavailableError, match="繋がらない"):
        await VoicevoxClient("http://engine").synthesize("やあ")


async def test_engine_error_status_raises(install) -> None:
    install(_Recorder(status=500))

    with pytest.raises(VoicevoxUnavailableError, match="500"):
        await VoicevoxClient("http://engine").synthesize("やあ")


async def test_blank_text_is_rejected_without_calling_the_engine(install) -> None:
    recorder = _Recorder()
    install(recorder)

    with pytest.raises(VoicevoxUnavailableError):
        await VoicevoxClient("http://engine").synthesize("   ")
    assert recorder.paths == []


async def test_is_reachable_reports_false_when_the_engine_is_down(install) -> None:
    install(_Recorder(fail=httpx.ConnectError("refused")))
    assert await VoicevoxClient("http://engine").is_reachable() is False


async def test_is_reachable_reports_true_when_the_engine_answers(install) -> None:
    install(_Recorder())
    assert await VoicevoxClient("http://engine").is_reachable() is True


def test_speaker_comes_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MIHARI_VOICEVOX_SPEAKER", "13")
    assert VoicevoxClient("http://engine").speaker == 13


def test_bad_speaker_env_falls_back_to_the_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MIHARI_VOICEVOX_SPEAKER", "ずんだもん")
    assert VoicevoxClient("http://engine").speaker == DEFAULT_SPEAKER


async def test_synthesis_receives_the_tuned_query(install) -> None:
    recorder = _Recorder()
    install(recorder)

    await VoicevoxClient("http://engine").synthesize("やあ")

    tuning = VoiceTuning()
    body = recorder.bodies["/synthesis"]
    assert body["speedScale"] == tuning.speed
    assert body["intonationScale"] == tuning.intonation
    assert body["pitchScale"] == tuning.pitch
    assert body["prePhonemeLength"] == tuning.pre_phoneme
    assert body["postPhonemeLength"] == tuning.post_phoneme
    assert body["pauseLengthScale"] == tuning.pause_length


async def test_tuned_query_keeps_the_other_keys(install) -> None:
    recorder = _Recorder()
    install(recorder)

    await VoicevoxClient("http://engine").synthesize("やあ")

    body = recorder.bodies["/synthesis"]
    assert body["accent_phrases"] == QUERY["accent_phrases"]
    assert body["outputSamplingRate"] == QUERY["outputSamplingRate"]


def test_apply_does_not_touch_the_original_query() -> None:
    query = {"accent_phrases": [], "speedScale": 1.0}

    tuned = VoiceTuning().apply(query)

    assert query["speedScale"] == 1.0
    assert tuned["speedScale"] == VoiceTuning().speed


def test_tuning_comes_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MIHARI_VOICEVOX_SPEED", "1.4")
    monkeypatch.setenv("MIHARI_VOICEVOX_INTONATION", "0.8")
    monkeypatch.setenv("MIHARI_VOICEVOX_PITCH", "0.02")
    monkeypatch.setenv("MIHARI_VOICEVOX_PRE_PHONEME", "0.2")
    monkeypatch.setenv("MIHARI_VOICEVOX_POST_PHONEME", "0.3")
    monkeypatch.setenv("MIHARI_VOICEVOX_PAUSE_LENGTH", "1.2")

    tuning = VoicevoxClient("http://engine").tuning

    assert tuning == VoiceTuning(
        speed=1.4,
        intonation=0.8,
        pitch=0.02,
        pre_phoneme=0.2,
        post_phoneme=0.3,
        pause_length=1.2,
    )


def test_bad_tuning_env_falls_back_to_the_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MIHARI_VOICEVOX_SPEED", "はやく")
    monkeypatch.setenv("MIHARI_VOICEVOX_PAUSE_LENGTH", "")

    assert VoicevoxClient("http://engine").tuning == VoiceTuning()


def test_tuning_given_to_the_constructor_wins(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MIHARI_VOICEVOX_SPEED", "1.4")

    tuning = VoiceTuning(speed=0.5)

    assert VoicevoxClient("http://engine", tuning=tuning).tuning == tuning
