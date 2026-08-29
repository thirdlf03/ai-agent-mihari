"""VOICEVOX のローカルエンジンで音声を合成する。

エンジンは別プロセス(既定 http://127.0.0.1:50021)で起動している前提。
起動していなくても例外を外に出さず、「合成できなかった」として扱う。
喋れないだけで、サボり検知と Discord への送信は止めない。
"""

from __future__ import annotations

import logging
import os
from collections import OrderedDict
from dataclasses import asdict, dataclass
from typing import Any

import httpx

logger = logging.getLogger(__name__)

DEFAULT_BASE_URL = "http://127.0.0.1:50021"

#: 話者 ID。VOICEVOX の話者一覧は /speakers で引ける。14 は冥鳴ひまり。
DEFAULT_SPEAKER = 14

#: 合成を待つ上限。エンジンが固まっていても発話待ちで詰まらせない。
DEFAULT_TIMEOUT_SECONDS = 10.0

#: 疎通確認だけの短いタイムアウト。
PING_TIMEOUT_SECONDS = 1.5

#: 音声を覚えておく件数。同じセリフを 2 回目以降すぐ鳴らすため。
CACHE_CAPACITY = 64


class VoicevoxUnavailableError(RuntimeError):
    """エンジンに繋がらない、または合成に失敗した。"""


@dataclass(frozen=True)
class VoiceTuning:
    """``audio_query`` の結果を書き換えて、棒読みを和らげる。

    既定のままだと抑揚が乏しく機械的に聞こえるので、少し速く・抑揚を強めにして、
    前後の無音と句読点の間を詰める。desktop 側(``VoicevoxQueryTuning``)と同じ値。
    """

    #: 話す速さ。1.0 が既定。
    speed: float = 1.1
    #: 抑揚の強さ。大きいほど高低の差がつく。
    intonation: float = 1.3
    #: 声の高さ。話者の印象を変えたくないので既定のまま。
    pitch: float = 0.0
    #: 発話前の無音(秒)。
    pre_phoneme: float = 0.05
    #: 発話後の無音(秒)。
    post_phoneme: float = 0.05
    #: 句読点などの間の倍率。1.0 未満で間が詰まる。
    pause_length: float = 0.9

    def apply(self, query: dict[str, Any]) -> dict[str, Any]:
        """``audio_query`` の JSON に調整値を載せた新しい dict を返す。

        ``accent_phrases`` などその他のキーはそのまま残す。
        ``pauseLengthScale`` を知らない古いエンジンもあるが、VOICEVOX ENGINE は
        知らないキーを無視するので付けたままで構わない。
        """
        tuned = dict(query)
        tuned["speedScale"] = self.speed
        tuned["intonationScale"] = self.intonation
        tuned["pitchScale"] = self.pitch
        tuned["prePhonemeLength"] = self.pre_phoneme
        tuned["postPhonemeLength"] = self.post_phoneme
        tuned["pauseLengthScale"] = self.pause_length
        return tuned

    def as_dict(self) -> dict[str, float]:
        """状態表示に載せるための dict。"""
        return asdict(self)


class VoicevoxClient:
    """音声合成のクライアント。合成結果は (セリフ, 話者) で覚えておく。"""

    def __init__(
        self,
        base_url: str | None = None,
        *,
        speaker: int | None = None,
        tuning: VoiceTuning | None = None,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        cache_capacity: int = CACHE_CAPACITY,
    ) -> None:
        self._base_url = (
            base_url or os.environ.get("MIHARI_VOICEVOX_URL") or DEFAULT_BASE_URL
        ).rstrip("/")
        self._speaker = speaker if speaker is not None else _speaker_from_env()
        self._tuning = tuning if tuning is not None else _tuning_from_env()
        self._timeout = timeout_seconds
        self._cache: OrderedDict[tuple[str, int], bytes] = OrderedDict()
        self._cache_capacity = cache_capacity

    @property
    def base_url(self) -> str:
        return self._base_url

    @property
    def speaker(self) -> int:
        return self._speaker

    @property
    def tuning(self) -> VoiceTuning:
        return self._tuning

    @property
    def cached_count(self) -> int:
        return len(self._cache)

    async def is_reachable(self) -> bool:
        """エンジンが起動しているか。起動手順を案内するために使う。"""
        try:
            async with httpx.AsyncClient(timeout=PING_TIMEOUT_SECONDS) as client:
                response = await client.get(f"{self._base_url}/version")
            return response.status_code == httpx.codes.OK
        except httpx.HTTPError:
            return False

    async def synthesize(self, text: str, *, speaker: int | None = None) -> bytes:
        """セリフを WAV にする。

        :raises VoicevoxUnavailableError: エンジンに繋がらない・合成に失敗した。
        """
        if not text.strip():
            raise VoicevoxUnavailableError("空のセリフは合成できない")

        speaker_id = speaker if speaker is not None else self._speaker
        key = (text, speaker_id)
        cached = self._cache.get(key)
        if cached is not None:
            # 直近で使ったものとして並べ直す。
            self._cache.move_to_end(key)
            return cached

        audio = await self._request_audio(text, speaker_id)
        self._remember(key, audio)
        return audio

    async def _request_audio(self, text: str, speaker_id: int) -> bytes:
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                query = await client.post(
                    f"{self._base_url}/audio_query",
                    params={"text": text, "speaker": speaker_id},
                )
                query.raise_for_status()

                synthesis = await client.post(
                    f"{self._base_url}/synthesis",
                    params={"speaker": speaker_id},
                    json=self._tuning.apply(query.json()),
                )
                synthesis.raise_for_status()
        except httpx.HTTPStatusError as error:
            raise VoicevoxUnavailableError(
                f"VOICEVOX が {error.response.status_code} を返した"
            ) from error
        except httpx.HTTPError as error:
            raise VoicevoxUnavailableError(
                f"VOICEVOX に繋がらない({self._base_url}): {error}"
            ) from error

        return synthesis.content

    def _remember(self, key: tuple[str, int], audio: bytes) -> None:
        self._cache[key] = audio
        self._cache.move_to_end(key)
        while len(self._cache) > self._cache_capacity:
            self._cache.popitem(last=False)


def _speaker_from_env() -> int:
    raw = os.environ.get("MIHARI_VOICEVOX_SPEAKER")
    if not raw:
        return DEFAULT_SPEAKER
    try:
        return int(raw)
    except ValueError:
        logger.warning("MIHARI_VOICEVOX_SPEAKER が数値でないため既定値を使う: %s", raw)
        return DEFAULT_SPEAKER


def _tuning_from_env() -> VoiceTuning:
    """環境変数で調整値を上書きする。未設定・数値でないものは既定のまま。"""
    default = VoiceTuning()
    return VoiceTuning(
        speed=_float_from_env("MIHARI_VOICEVOX_SPEED", default.speed),
        intonation=_float_from_env("MIHARI_VOICEVOX_INTONATION", default.intonation),
        pitch=_float_from_env("MIHARI_VOICEVOX_PITCH", default.pitch),
        pre_phoneme=_float_from_env("MIHARI_VOICEVOX_PRE_PHONEME", default.pre_phoneme),
        post_phoneme=_float_from_env("MIHARI_VOICEVOX_POST_PHONEME", default.post_phoneme),
        pause_length=_float_from_env("MIHARI_VOICEVOX_PAUSE_LENGTH", default.pause_length),
    )


def _float_from_env(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        logger.warning("%s が数値でないため既定値を使う: %s", name, raw)
        return default
