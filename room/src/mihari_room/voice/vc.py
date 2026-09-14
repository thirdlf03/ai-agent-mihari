"""Voice Conversion（VC）バックエンド抽象化。

live_audio モードで gpt-live-1 が返す音声（素の声）を、外部 HTTP の VC
サービス（Beatrice / Seed-VC 等）へ投げて冥鳴ひまり声に変換するための土台。

線上のフォーマット:

- room ↔ VC サービス: f32（-1.0〜1.0）モノラル 24 kHz の生バイト列
- room ↔ クライアント / Live upstream: PCM16 モノラル 24 kHz（base64）

room 側にリサンプリング等の DSP は入れない。PCM16 ↔ f32 の変換だけを
標準ライブラリ（struct）で行う。
"""

from __future__ import annotations

import logging
import struct
from abc import ABC, abstractmethod
from typing import TYPE_CHECKING

import httpx

if TYPE_CHECKING:
    from mihari_room.config import RoomConfig

logger = logging.getLogger("mihari_room.voice")


def pcm16_to_f32(pcm16: bytes) -> bytes:
    """PCM16LE モノラルの生バイト列を f32LE（±1.0）の生バイト列へ変換する。"""
    usable = len(pcm16) - (len(pcm16) % 2)
    count = usable // 2
    if count == 0:
        return b""
    ints = struct.unpack(f"<{count}h", pcm16[:usable])
    return struct.pack(f"<{count}f", *(sample / 32768.0 for sample in ints))


def f32_to_pcm16(data: bytes) -> bytes:
    """f32LE（±1.0）の生バイト列を PCM16LE モノラルへ戻す。範囲外はクリップ。"""
    usable = len(data) - (len(data) % 4)
    count = usable // 4
    if count == 0:
        return b""
    floats = struct.unpack(f"<{count}f", data[:usable])
    ints = (max(-32768, min(32767, int(round(sample * 32767.0)))) for sample in floats)
    return struct.pack(f"<{count}h", *ints)


class VoiceConverter(ABC):
    """音声変換バックエンド。f32 mono 24kHz を受けて同フォーマットを返す。"""

    @abstractmethod
    async def convert(self, pcm_f32_24k: bytes) -> bytes:
        """1 チャンク変換する。失敗しても会話を落とさない実装にすること。"""
        raise NotImplementedError

    @abstractmethod
    async def reset(self) -> None:
        """変換の内部状態（話者状態・バッファ）をリセットする。"""
        raise NotImplementedError

    async def flush(self) -> bytes:
        """発話終端。バッファに残っている変換済み音声を返す。

        チャンク変換型のバックエンド（入力を溜めてから変換するもの）向け。
        変換結果が無い場合は空バイト列を返す。デフォルトは何もしない。
        """
        return b""

    @abstractmethod
    async def close(self) -> None:
        raise NotImplementedError


class PassthroughConverter(VoiceConverter):
    """VC 無効時の素通し。"""

    async def convert(self, pcm_f32_24k: bytes) -> bytes:
        return pcm_f32_24k

    async def reset(self) -> None:
        return None

    async def close(self) -> None:
        return None


class HTTPVoiceConverter(VoiceConverter):
    """外部 VC サービスへ HTTP で投げるコンバータ。

    - ``POST {base}/convert``: body は f32 生バイト列
      （Content-Type: application/octet-stream）、応答 body は変換済み f32。
    - ``POST {base}/reset``: 内部状態のリセット。

    接続失敗・タイムアウト・5xx は warning を出して素通しにフォールバックする
    （VC が落ちても会話自体は継続させる）。
    """

    def __init__(
        self,
        *,
        base_url: str,
        timeout: float = 2.0,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        if client is not None:
            # テスト用に注入されたクライアントは呼び出し側が畳む。
            self._client = client
            self._owns_client = False
        else:
            self._client = httpx.AsyncClient(base_url=base_url.rstrip("/"), timeout=timeout)
            self._owns_client = True

    async def convert(self, pcm_f32_24k: bytes) -> bytes:
        if not pcm_f32_24k:
            return pcm_f32_24k
        try:
            response = await self._client.post(
                "/convert",
                content=pcm_f32_24k,
                headers={"Content-Type": "application/octet-stream"},
            )
            response.raise_for_status()
            return response.content
        except httpx.HTTPError as error:
            logger.warning("VC 変換に失敗したので素通しで継続: %s", error)
            return pcm_f32_24k

    async def reset(self) -> None:
        try:
            response = await self._client.post("/reset")
            response.raise_for_status()
        except httpx.HTTPError as error:
            logger.warning("VC reset に失敗（続行）: %s", error)

    async def flush(self) -> bytes:
        try:
            response = await self._client.post("/flush")
            response.raise_for_status()
            return response.content
        except httpx.HTTPError as error:
            # /flush 未実装のバックエンドでも会話は継続する。
            logger.warning("VC flush に失敗（続行）: %s", error)
            return b""

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()


def voice_converter_from_config(config: RoomConfig) -> VoiceConverter:
    """設定からコンバータを組み立てる。``vc_url`` 空ならパススルー。"""
    if not config.vc_url:
        return PassthroughConverter()
    return HTTPVoiceConverter(base_url=config.vc_url, timeout=config.vc_timeout)
