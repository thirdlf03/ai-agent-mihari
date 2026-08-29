"""セリフ生成と、失敗時のフォールバック。

**実際の Claude API は呼ばない。** 課金と外部依存をテストに持ち込まないため、
クライアントはすべてスタブに差し替える。
"""

from __future__ import annotations

from typing import Any

import anthropic
import httpx
import pytest

from device_bridge.voice.context import SpeechContext
from device_bridge.voice.generator import LineGenerator

CONTEXT = SpeechContext(idle_seconds=300)


class _TextBlock:
    type = "text"

    def __init__(self, text: str) -> None:
        self.text = text


class _Response:
    def __init__(self, blocks: list[Any]) -> None:
        self.content = blocks


class _StubMessages:
    def __init__(self, result: Any) -> None:
        self._result = result
        self.calls: list[dict[str, Any]] = []

    async def create(self, **kwargs: Any) -> Any:
        self.calls.append(kwargs)
        if isinstance(self._result, Exception):
            raise self._result
        return self._result


class _StubClient:
    """`with_options(...).messages.create(...)` だけを模した最小のスタブ。"""

    def __init__(self, result: Any) -> None:
        self.messages = _StubMessages(result)
        self.options: dict[str, Any] = {}

    def with_options(self, **kwargs: Any) -> _StubClient:
        self.options = kwargs
        return self


def _generator(result: Any) -> tuple[LineGenerator, _StubClient]:
    client = _StubClient(result)
    return LineGenerator(client, model="test-model", timeout_seconds=1.0), client  # type: ignore[arg-type]


async def test_uses_the_generated_text() -> None:
    generator, _ = _generator(_Response([_TextBlock("  手が止まってますよ  ")]))

    line = await generator.generate(CONTEXT)

    assert line.text == "手が止まってますよ"
    assert line.from_llm is True
    assert line.fallback_reason is None


async def test_sends_the_situation_and_a_short_timeout() -> None:
    generator, client = _generator(_Response([_TextBlock("はい")]))

    await generator.generate(CONTEXT)

    assert client.options["timeout"] == 1.0
    # 遅いときは待たずに固定文言へ落とす方針なので、SDK 側の再試行はさせない。
    assert client.options["max_retries"] == 0
    assert client.messages.calls[0]["messages"][0]["content"] == CONTEXT.describe()
    assert client.messages.calls[0]["model"] == "test-model"


async def test_without_a_key_it_falls_back_without_calling_the_api() -> None:
    generator = LineGenerator(None)

    line = await generator.generate(CONTEXT)

    assert generator.is_configured is False
    assert line.from_llm is False
    assert "ANTHROPIC_API_KEY" in (line.fallback_reason or "")
    assert line.text


async def test_timeout_falls_back() -> None:
    generator, _ = _generator(anthropic.APITimeoutError(request=httpx.Request("POST", "http://x")))

    line = await generator.generate(CONTEXT)

    assert line.from_llm is False
    assert "秒" in (line.fallback_reason or "")
    assert line.text


async def test_connection_error_falls_back() -> None:
    generator, _ = _generator(
        anthropic.APIConnectionError(request=httpx.Request("POST", "http://x"))
    )

    line = await generator.generate(CONTEXT)

    assert line.from_llm is False
    assert line.text


async def test_empty_response_falls_back() -> None:
    generator, _ = _generator(_Response([]))

    line = await generator.generate(CONTEXT)

    assert line.from_llm is False
    assert "空" in (line.fallback_reason or "")
    assert line.text


async def test_model_can_be_overridden_by_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MIHARI_LLM_MODEL", "claude-opus-5")
    assert LineGenerator(None).model == "claude-opus-5"


async def test_model_defaults_to_the_fast_one(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("MIHARI_LLM_MODEL", raising=False)
    # 喋り出しの速さが体験を決めるので、既定は軽いモデル。
    assert LineGenerator(None).model == "claude-haiku-4-5"
