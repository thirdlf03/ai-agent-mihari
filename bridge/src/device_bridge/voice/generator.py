"""Claude API でセリフを作る。失敗したら必ず固定文言に落ちる。"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass

import anthropic

from device_bridge.voice.context import SpeechContext
from device_bridge.voice.fallback import fallback_line

logger = logging.getLogger(__name__)

#: 既定のモデル。喋り出しの速さが体験を決めるので軽いモデルを既定にする。
#: `MIHARI_LLM_MODEL` で上書きできる(例: claude-opus-5)。
DEFAULT_MODEL = "claude-haiku-4-5"

#: 生成を待つ上限。これを超えたら固定文言に切り替える。
#: ペットの返しが遅いと会話として成立しないため、短く切る。
DEFAULT_TIMEOUT_SECONDS = 4.0

#: セリフは 1〜2 文なので出力は短くてよい。
MAX_TOKENS = 200

#: キャラの口調。ここを変えるとペットの性格が変わる。
SYSTEM_PROMPT = """\
あなたは macOS 常駐アプリ「Mihari」のマスコットです。
ユーザーがサボっているのを見つけて話しかけます。

守ること:
- 出力はセリフ本文のみ。前置き・説明・鉤括弧・絵文字は付けない。
- 1〜2 文、合計 60 文字以内。読み上げるので短くする。
- 皮肉混じりだが、人格否定・侮辱・脅迫はしない。あくまで軽口。
- 与えられた状況に具体的に触れる。毎回違う言い回しにする。
- 日本語で書く。
"""


@dataclass(frozen=True, slots=True)
class GeneratedLine:
    """生成したセリフと、その出どころ。"""

    text: str
    #: LLM が生成したなら ``True``、固定文言に落ちたなら ``False``。
    from_llm: bool
    #: 固定文言に落ちた理由。LLM 成功時は ``None``。
    fallback_reason: str | None = None


class LineGenerator:
    """状況からセリフを 1 本作る。

    API キーが無い / 呼び出しが失敗した / 遅すぎた、のどれでも固定文言を返す。
    ここで例外を外に出すと、ペットが黙るだけでなく検知そのものが止まってしまう。
    """

    def __init__(
        self,
        client: anthropic.AsyncAnthropic | None = None,
        *,
        model: str | None = None,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    ) -> None:
        self._model = model or os.environ.get("MIHARI_LLM_MODEL") or DEFAULT_MODEL
        self._timeout = timeout_seconds
        self._client = client if client is not None else _build_client()

    @property
    def model(self) -> str:
        return self._model

    @property
    def is_configured(self) -> bool:
        """LLM を呼べる状態か。キー未設定なら ``False``。"""
        return self._client is not None

    async def generate(self, context: SpeechContext) -> GeneratedLine:
        if self._client is None:
            return GeneratedLine(
                text=fallback_line(context),
                from_llm=False,
                fallback_reason="ANTHROPIC_API_KEY が未設定",
            )

        try:
            response = await self._client.with_options(
                timeout=self._timeout, max_retries=0
            ).messages.create(
                model=self._model,
                max_tokens=MAX_TOKENS,
                system=SYSTEM_PROMPT,
                messages=[{"role": "user", "content": context.describe()}],
            )
        except anthropic.APITimeoutError:
            return self._fall_back(context, f"{self._timeout} 秒で応答がなかった")
        except anthropic.RateLimitError:
            return self._fall_back(context, "レート制限に当たった")
        except anthropic.APIStatusError as error:
            return self._fall_back(context, f"API エラー (HTTP {error.status_code})")
        except anthropic.APIConnectionError as error:
            return self._fall_back(context, f"接続できなかった: {error}")

        text = _extract_text(response)
        if not text:
            return self._fall_back(context, "空の応答が返った")
        return GeneratedLine(text=text, from_llm=True)

    def _fall_back(self, context: SpeechContext, reason: str) -> GeneratedLine:
        logger.warning("セリフ生成に失敗したので固定文言に落とす: %s", reason)
        return GeneratedLine(text=fallback_line(context), from_llm=False, fallback_reason=reason)


def _extract_text(response: anthropic.types.Message) -> str:
    """応答からテキストだけを取り出す。"""
    chunks = [block.text for block in response.content if block.type == "text"]
    return "".join(chunks).strip()


def _build_client() -> anthropic.AsyncAnthropic | None:
    """キーがあるときだけクライアントを作る。無ければ ``None``。"""
    if not os.environ.get("ANTHROPIC_API_KEY"):
        logger.warning("ANTHROPIC_API_KEY が未設定のため、セリフは固定文言になる")
        return None
    return anthropic.AsyncAnthropic()
