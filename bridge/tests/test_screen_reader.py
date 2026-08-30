"""スクショの読み取りと、読めなかったときの理由。

**実際の Gemini API は呼ばない。** 課金と外部依存をテストに持ち込まないため、
クライアントはすべてスタブに差し替える。
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

import pytest
from google.genai import errors, types

from device_bridge.voice import screen_reader
from device_bridge.voice.context import SpeechContext
from device_bridge.voice.screen_reader import (
    ScreenCategory,
    ScreenReader,
    ScreenReadError,
)

CONTEXT = SpeechContext(idle_seconds=300)
PNG = b"\x89PNG\r\n\x1a\n" + b"body"

READING_JSON = json.dumps(
    {
        "app": "YouTube",
        "activity": "料理動画を見ている",
        "category": "slacking",
        "line": "その料理動画、あとで作るんですか？",
    },
    ensure_ascii=False,
)


class _Response:
    def __init__(self, text: str) -> None:
        self.text = text


class _StubModels:
    def __init__(self, result: Any, *, delay: float = 0.0) -> None:
        self._result = result
        self._delay = delay
        self.calls: list[dict[str, Any]] = []

    async def generate_content(self, **kwargs: Any) -> Any:
        self.calls.append(kwargs)
        if self._delay:
            await asyncio.sleep(self._delay)
        if isinstance(self._result, Exception):
            raise self._result
        return self._result


class _StubAio:
    def __init__(self, models: _StubModels) -> None:
        self.models = models


class _StubClient:
    """`client.aio.models.generate_content(...)` だけを模した最小のスタブ。"""

    def __init__(self, result: Any, *, delay: float = 0.0) -> None:
        self.aio = _StubAio(_StubModels(result, delay=delay))

    @property
    def calls(self) -> list[dict[str, Any]]:
        return self.aio.models.calls


def _reader(
    result: Any,
    *,
    delay: float = 0.0,
    timeout_seconds: float = 1.0,
    media_resolution: str | None = None,
) -> tuple[ScreenReader, _StubClient]:
    client = _StubClient(result, delay=delay)
    reader = ScreenReader(
        client,  # type: ignore[arg-type]
        model="test-model",
        timeout_seconds=timeout_seconds,
        media_resolution=media_resolution,
    )
    return reader, client


async def test_parses_a_valid_response() -> None:
    reader, _ = _reader(_Response(READING_JSON))

    reading = await reader.read(PNG, CONTEXT)

    assert reading.app == "YouTube"
    assert reading.activity == "料理動画を見ている"
    assert reading.category is ScreenCategory.SLACKING
    assert reading.line == "その料理動画、あとで作るんですか？"


async def test_an_empty_app_becomes_none() -> None:
    # 構造化出力は Optional が不安定なので空文字で受けて None に直している。
    payload = json.dumps(
        {
            "app": "",
            "activity": "何か見ている",
            "category": "unknown",
            "line": "スマホ触ってますね",
        },
        ensure_ascii=False,
    )
    reader, _ = _reader(_Response(payload))

    reading = await reader.read(PNG, CONTEXT)

    assert reading.app is None
    assert reading.category is ScreenCategory.UNKNOWN


async def test_sends_the_image_and_the_situation() -> None:
    reader, client = _reader(_Response(READING_JSON))

    await reader.read(PNG, CONTEXT)

    call = client.calls[0]
    assert call["model"] == "test-model"
    image, prompt = call["contents"]
    assert image.inline_data.data == PNG
    assert image.inline_data.mime_type == "image/png"
    assert image.media_resolution.level is types.PartMediaResolutionLevel.MEDIA_RESOLUTION_MEDIUM
    assert CONTEXT.describe() in prompt

    config = call["config"]
    assert config.response_mime_type == "application/json"
    assert config.thinking_config.thinking_level is types.ThinkingLevel.MINIMAL
    assert config.automatic_function_calling.disable is True


async def test_broken_json_is_reported() -> None:
    reader, _ = _reader(_Response("これは JSON ではない"))

    with pytest.raises(ScreenReadError, match="応答を解釈できなかった"):
        await reader.read(PNG, CONTEXT)


async def test_rate_limit_is_reported() -> None:
    reader, _ = _reader(errors.ClientError(429, {"error": {"message": "rate"}}))

    with pytest.raises(ScreenReadError, match="レート制限"):
        await reader.read(PNG, CONTEXT)


async def test_api_error_keeps_the_status_code() -> None:
    reader, _ = _reader(errors.APIError(503, {"error": {"message": "down"}}))

    with pytest.raises(ScreenReadError, match="HTTP 503"):
        await reader.read(PNG, CONTEXT)


async def test_a_slow_response_times_out() -> None:
    # ペットの返しが遅いと会話にならないので、待たずに切って呼び出し側に返す。
    reader, _ = _reader(_Response(READING_JSON), delay=5.0, timeout_seconds=0.05)

    with pytest.raises(ScreenReadError, match="秒で応答がなかった"):
        await reader.read(PNG, CONTEXT)


@pytest.mark.parametrize("line", ["", "   ", "あ" * 61])
async def test_an_unusable_line_is_rejected(line: str) -> None:
    payload = json.dumps(
        {"app": "Safari", "activity": "調べ物", "category": "neutral", "line": line},
        ensure_ascii=False,
    )
    reader, _ = _reader(_Response(payload))

    with pytest.raises(ScreenReadError, match="セリフが不正"):
        await reader.read(PNG, CONTEXT)


async def test_without_a_key_it_is_not_configured(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)

    assert ScreenReader().is_configured is False


async def test_the_sdk_timeout_never_goes_below_the_api_minimum(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Gemini API は deadline が 10 秒未満だと 400 を返すので、短く指定しても下限まで持ち上げる。
    monkeypatch.setenv("GEMINI_API_KEY", "x")
    captured: list[types.HttpOptions] = []

    def _fake_client(*, http_options: types.HttpOptions) -> object:
        captured.append(http_options)
        return object()

    monkeypatch.setattr(screen_reader.genai, "Client", _fake_client)

    ScreenReader(timeout_seconds=6.0)
    ScreenReader(timeout_seconds=30.0)

    assert [options.timeout for options in captured] == [10_000, 30_000]


async def test_model_can_be_overridden_by_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    monkeypatch.setenv("MIHARI_SCREEN_MODEL", "gemini-3.1-pro")

    assert ScreenReader().model == "gemini-3.1-pro"


async def test_model_defaults_to_the_fast_one(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    monkeypatch.delenv("MIHARI_SCREEN_MODEL", raising=False)

    assert ScreenReader().model == "gemini-3.1-flash-lite"


async def test_media_resolution_comes_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MIHARI_SCREEN_MEDIA_RESOLUTION", "high")
    reader, client = _reader(_Response(READING_JSON))

    await reader.read(PNG, CONTEXT)

    image, _ = client.calls[0]["contents"]
    assert image.media_resolution.level is types.PartMediaResolutionLevel.MEDIA_RESOLUTION_HIGH


async def test_an_unknown_media_resolution_falls_back_to_medium(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("MIHARI_SCREEN_MEDIA_RESOLUTION", "ultra")
    reader, client = _reader(_Response(READING_JSON))

    await reader.read(PNG, CONTEXT)

    image, _ = client.calls[0]["contents"]
    assert image.media_resolution.level is types.PartMediaResolutionLevel.MEDIA_RESOLUTION_MEDIUM
