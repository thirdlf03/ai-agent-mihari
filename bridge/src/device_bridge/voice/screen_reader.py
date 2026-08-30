"""iPhone のスクショを Gemini に見せて、何をしているかとセリフを同時に作る。

Claude 側と違って固定文言には落とさない。ここで失敗したら ``ScreenReadError`` を投げ、
呼び出し側が従来の ``LineGenerator``(Claude → 固定文言)に落とす。
つまり「画面を読む」だけを担い、ペットが黙らない保証は呼び出し側が持つ。
"""

from __future__ import annotations

import asyncio
import logging
import os
from dataclasses import dataclass
from enum import StrEnum
from typing import Any, Literal

import httpx
from google import genai
from google.genai import errors, types
from pydantic import BaseModel, ValidationError

from device_bridge.voice.context import SpeechContext
from device_bridge.voice.persona import PERSONA_RULES

logger = logging.getLogger(__name__)

#: 既定のモデル。画像 1 枚をその場で読むので、速さと安さを優先する。
#: `MIHARI_SCREEN_MODEL` で上書きできる。
DEFAULT_MODEL = "gemini-3.1-flash-lite"

#: 読み取りを待つ上限。画像を送るぶん Claude より少し長く取る。
DEFAULT_TIMEOUT_SECONDS = 6.0

#: SDK に渡せるタイムアウトの下限。
#: Gemini API はサーバー側 deadline が 10 秒未満だと 400 を返すため、
#: SDK に渡す値はこれ以上にする。体感を決める打ち切りは `asyncio.wait_for` 側で行う。
SDK_MIN_TIMEOUT_SECONDS = 10.0

#: 画像の解像度。アプリ名が読めれば十分なので中間を既定にする。
#: `MIHARI_SCREEN_MEDIA_RESOLUTION` に low / medium / high で指定する。
DEFAULT_MEDIA_RESOLUTION = "medium"

#: 出力は短い JSON 1 個。thinking を切っているので余裕を持たせてこの程度。
MAX_OUTPUT_TOKENS = 300

#: これを超えるセリフは読み上げに向かないので不正扱いにする。
#: 30 文字を頼んでいるので、この倍を超えたら壊れている。
MAX_LINE_LENGTH = 60


class ScreenCategory(StrEnum):
    """画面から見立てた、いまやっていることの種類。"""

    #: 仕事・学習・作業に見える。
    WORK = "work"
    #: SNS・動画・ゲーム・漫画など明らかな息抜き。
    SLACKING = "slacking"
    #: 連絡・地図・設定など、どちらとも言えない。
    NEUTRAL = "neutral"
    #: 判断できない(ロック画面・真っ暗など)。
    UNKNOWN = "unknown"


@dataclass(frozen=True, slots=True)
class ScreenReading:
    """画面の読み取り結果と、それを踏まえたセリフ。"""

    #: 推定したアプリ名(例 "YouTube")。分からなければ ``None``。
    app: str | None
    #: 何をしているかの短い名詞句(例 "猫の動画")。Swift 側が文面に埋め込む。
    activity: str
    category: ScreenCategory
    #: ペットのセリフ。1 文。``require_line=False`` で読んだときは空のことがある。
    line: str


class ScreenReadError(Exception):
    """画面を読めなかった。理由をそのまま ``screen_error`` として返す。"""


class _ScreenReadingSchema(BaseModel):
    """Gemini に返させる形。

    構造化出力は Optional の扱いが不安定なので、``app`` は ``str`` にして
    「不明なら空文字」とプロンプトで指示し、こちら側で ``None`` に変換する。
    """

    app: str
    activity: str
    category: Literal["work", "slacking", "neutral", "unknown"]
    line: str


SYSTEM_PROMPT = f"""\
あなたは macOS 常駐アプリ「Mihari」のデスクトップペット「みはり」です。
Mac を放っておいてスマホを触っているユーザーに、その画面を見た上で話しかけます。

渡されるのはユーザーの iPhone のスクリーンショットです。
何のアプリで何をしているかを見立て、次の項目を持つ JSON だけを返してください。

- app: 推定したアプリ名(例 "YouTube")。分からなければ空文字。
- activity: 何をしているかを短い名詞句で(12 文字以内。例 "猫の動画" "友達とのチャット")。
  文にしない。「〜している」「〜中」のような述語は付けず、見ているものだけを書く。
- category: 次のどれか。
  - work: 仕事・学習・作業に見える。Slack・メール・カレンダーなど仕事の連絡もここ。
  - slacking: SNS・動画・ゲーム・漫画など、明らかな息抜き。
  - neutral: 連絡・地図・設定など、どちらとも言えない。迷ったらこれ。
  - unknown: ロック画面や真っ暗など、判断できない。
- line: ペットのセリフ。

line を書くときに守ること:
{PERSONA_RULES}

さらに line では:
- アプリ名か見ているものを 1 語入れる(例: "YouTubeの動画、そんなに楽しい?")。
- work なら「スマホで仕事しているのは分かるけど Mac に戻ってきて」の線でいく。
- slacking なら軽くいじる。
- neutral なら「用事が済んだら戻ってきて」の線でいく。
- unknown なら画面の内容には触れず、iPhone を触っていること自体をいじる。
- 状況説明の「当たりの強さ」に合わせて当たりの強弱を変える。
- 画面に写っている個人名・メッセージ本文・金額は引用しない。
  プライバシーに関わるので、アプリ名と大まかな内容までにとどめる。

応答は JSON のみ。前置き・説明・コードブロックは付けない。
"""


class ScreenReader:
    """スクショ 1 枚から、画面の読み取りとセリフを 1 回の呼び出しで作る。

    キーが無い / 失敗した / 遅すぎた / 応答が壊れていた、のどれでも
    ``ScreenReadError`` に変換して返す。例外を素通しにすると呼び出し側が
    Claude に落とせず、ペットが黙ってしまう。
    """

    def __init__(
        self,
        client: genai.Client | None = None,
        *,
        model: str | None = None,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        media_resolution: str | None = None,
    ) -> None:
        self._model = model or os.environ.get("MIHARI_SCREEN_MODEL") or DEFAULT_MODEL
        self._timeout = timeout_seconds
        self._media_resolution = _resolve_media_resolution(media_resolution)
        self._client = client if client is not None else _build_client(timeout_seconds)

    @property
    def model(self) -> str:
        return self._model

    @property
    def is_configured(self) -> bool:
        """画面を読める状態か。キー未設定なら ``False``。"""
        return self._client is not None

    async def read(
        self, png: bytes, context: SpeechContext, *, require_line: bool = True
    ) -> ScreenReading:
        """スクショを 1 枚読む。

        :param require_line: セリフも要るなら ``True``。画面の見立てだけが欲しい場合は
            ``False`` にする。セリフが空・長すぎるだけで見立てまで捨てるのを避けるため。
        """
        try:
            reading = await self._read(png, context, require_line=require_line)
        except ScreenReadError as error:
            logger.warning("スクショを読めなかった: %s", error)
            raise
        logger.info(
            "画面を読んだ: app=%s category=%s activity=%s",
            reading.app,
            reading.category,
            reading.activity,
        )
        return reading

    async def _read(
        self, png: bytes, context: SpeechContext, *, require_line: bool
    ) -> ScreenReading:
        if self._client is None:
            raise ScreenReadError("GEMINI_API_KEY が未設定")

        try:
            # SDK 側の deadline は 10 秒以上なので、体感の上限はここで締める。
            response = await asyncio.wait_for(self._request(png, context), timeout=self._timeout)
            parsed = _ScreenReadingSchema.model_validate_json(response.text or "")
        except (TimeoutError, httpx.TimeoutException) as error:
            raise ScreenReadError(f"{self._timeout} 秒で応答がなかった") from error
        except errors.ClientError as error:
            if error.code == 429:
                raise ScreenReadError("レート制限に当たった") from error
            raise ScreenReadError(f"API エラー (HTTP {error.code})") from error
        except errors.APIError as error:
            raise ScreenReadError(f"API エラー (HTTP {error.code})") from error
        except (ValidationError, ValueError) as error:
            raise ScreenReadError("応答を解釈できなかった") from error
        except Exception as error:  # noqa: BLE001 - 何が来ても呼び出し側を落とさない
            raise ScreenReadError(f"予期しない失敗: {type(error).__name__}") from error

        line = parsed.line.strip()
        if not line or len(line) > MAX_LINE_LENGTH:
            # 読み上げに耐えないセリフは捨てる。セリフが要らない呼び出しなら、
            # そのために画面の見立てまで失わないよう空のまま返す。
            if require_line:
                raise ScreenReadError("セリフが不正")
            line = ""

        return ScreenReading(
            app=parsed.app.strip() or None,
            activity=parsed.activity.strip(),
            category=ScreenCategory(parsed.category),
            line=line,
        )

    async def _request(self, png: bytes, context: SpeechContext) -> Any:
        assert self._client is not None
        return await self._client.aio.models.generate_content(
            model=self._model,
            contents=[
                types.Part.from_bytes(
                    data=png,
                    mime_type="image/png",
                    media_resolution=self._media_resolution,
                ),
                _user_prompt(context),
            ],
            config=types.GenerateContentConfig(
                system_instruction=SYSTEM_PROMPT,
                response_mime_type="application/json",
                response_schema=_ScreenReadingSchema,
                # ツールは使わない。SDK が毎回 AFC の警告を出すので明示的に切る。
                automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
                # 喋り出しの速さが体験を決めるので、考え込ませない。
                thinking_config=types.ThinkingConfig(thinking_level="minimal"),
                temperature=0.8,
                max_output_tokens=MAX_OUTPUT_TOKENS,
            ),
        )


def _user_prompt(context: SpeechContext) -> str:
    """画像に添える 1 通ぶんの指示。Mac 側の状況もここで渡す。"""
    return (
        "これはユーザーの iPhone のスクリーンショットです。\n"
        f"Mac 側の状況: {context.describe()}\n"
        "画面を見て JSON を返してください。"
    )


_MEDIA_RESOLUTIONS: dict[str, types.MediaResolution] = {
    "low": types.MediaResolution.MEDIA_RESOLUTION_LOW,
    "medium": types.MediaResolution.MEDIA_RESOLUTION_MEDIUM,
    "high": types.MediaResolution.MEDIA_RESOLUTION_HIGH,
}


def _resolve_media_resolution(raw: str | None) -> types.MediaResolution:
    """low / medium / high を enum に直す。知らない値なら既定に倒す。"""
    name = (
        (raw or os.environ.get("MIHARI_SCREEN_MEDIA_RESOLUTION") or DEFAULT_MEDIA_RESOLUTION)
        .strip()
        .lower()
    )
    resolution = _MEDIA_RESOLUTIONS.get(name)
    if resolution is None:
        logger.warning("解像度の指定が不正なので %s に倒す: %s", DEFAULT_MEDIA_RESOLUTION, name)
        return _MEDIA_RESOLUTIONS[DEFAULT_MEDIA_RESOLUTION]
    return resolution


def _build_client(timeout_seconds: float) -> genai.Client | None:
    """キーがあるときだけクライアントを作る。無ければ ``None``。"""
    if not (os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")):
        logger.warning("GEMINI_API_KEY が未設定のため、スクショからのセリフは作らない")
        return None
    # SDK のタイムアウトはミリ秒指定。下限を割るとサーバーに 400 で弾かれる。
    sdk_timeout = max(timeout_seconds, SDK_MIN_TIMEOUT_SECONDS)
    return genai.Client(http_options=types.HttpOptions(timeout=int(sdk_timeout * 1000)))
