"""VOICEVOX のローカルエンジンで音声を合成する。

エンジンは別プロセス(既定 http://127.0.0.1:50021)で起動している前提。
起動していなくても例外を外に出さず、「合成できなかった」として扱う。
喋れないだけで、サボり検知と Discord への送信は止めない。
"""

from __future__ import annotations

import logging
import os
from collections import OrderedDict

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


class VoicevoxClient:
    """音声合成のクライアント。合成結果は (セリフ, 話者) で覚えておく。"""

    def __init__(
        self,
        base_url: str | None = None,
        *,
        speaker: int | None = None,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        cache_capacity: int = CACHE_CAPACITY,
    ) -> None:
        self._base_url = (
            base_url or os.environ.get("MIHARI_VOICEVOX_URL") or DEFAULT_BASE_URL
        ).rstrip("/")
        self._speaker = speaker if speaker is not None else _speaker_from_env()
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
                    json=query.json(),
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
