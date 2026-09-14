"""room 本体へ HTTP で委譲する voice ツール実行器（voice gateway 用）。

voice gateway（``voice_gateway.py``、Mac ローカル）には orchestrator・
mac_control hub・job_interactions が無い。そこでツール実行は VPS の room
本体が出す ``POST /voice/tools/execute`` へ投げ、応答を ``VoiceToolOutcome``
へ復元して stream 層へ返す。

room が落ちていても音声会話は落とさない。接続失敗・タイムアウト・
認証 NG は ``{"success": false, "error": ...}`` の JSON output に畳む
（``VoiceToolExecutor`` の失敗形式と同じ）。
"""

from __future__ import annotations

import base64
import binascii
import json
import logging
from collections.abc import Callable

import httpx

from mihari_room.config import TOKEN_HEADER
from mihari_room.voice.tools import VoiceToolOutcome

logger = logging.getLogger("mihari_room.voice")

#: room 側のツール実行（forum 作成・mac 経由のファイル fetch 等）を待つ上限秒。
DEFAULT_REMOTE_TIMEOUT = 60.0


def _fail(message: str) -> str:
    """``tools._fail`` と同じ形の失敗 JSON 文字列。"""
    return json.dumps({"success": False, "error": message}, ensure_ascii=False)


class RemoteVoiceToolExecutor:
    """``VoiceToolExecutor`` と同じ口で、実行本体は room の HTTP エンドポイント。

    - ``execute``: ``POST {room}/voice/tools/execute`` に session_id・ツール名・
      引数 JSON を送り、応答を ``VoiceToolOutcome`` へ復元する。
    - ``close``: ``DELETE {room}/voice/tools/execute/{session_id}`` で room 側の
      session executor（begin 済みの Mac run を含む）を畳む。
    """

    def __init__(
        self,
        *,
        session_id: str,
        room_url: str,
        token: str,
        timeout: float = DEFAULT_REMOTE_TIMEOUT,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._session_id = session_id
        self._token = token
        if client is not None:
            # テスト用に注入されたクライアントは呼び出し側が畳む。
            self._client = client
            self._owns_client = False
        else:
            self._client = httpx.AsyncClient(
                base_url=room_url.rstrip("/"), timeout=timeout
            )
            self._owns_client = True
        self._closed = False

    async def execute(self, name: str, arguments_json: str) -> VoiceToolOutcome:
        """function_call 1 件を room へ委譲する。例外は failure JSON に畳む。"""
        try:
            response = await self._client.post(
                "/voice/tools/execute",
                json={
                    "session_id": self._session_id,
                    "name": name,
                    "arguments": arguments_json or "",
                },
                headers={TOKEN_HEADER: self._token},
            )
            response.raise_for_status()
            payload = response.json()
        except Exception as error:  # noqa: BLE001 -- ツール失敗で会話は落とさない
            logger.warning("remote voice tool %s failed: %s", name, error)
            return VoiceToolOutcome(
                output=_fail(f"{type(error).__name__}: {error}"), ok=False
            )
        if not isinstance(payload, dict):
            return VoiceToolOutcome(
                output=_fail("room の応答が JSON オブジェクトではない"), ok=False
            )
        image_png: bytes | None = None
        raw_image = payload.get("image_base64")
        if isinstance(raw_image, str) and raw_image:
            try:
                image_png = base64.b64decode(raw_image, validate=True)
            except (binascii.Error, ValueError):
                logger.warning(
                    "remote voice tool %s: image_base64 を読めない", name
                )
        return VoiceToolOutcome(
            output=str(payload.get("output") or ""),
            image_png=image_png,
            client_side=bool(payload.get("client_side")),
            ok=bool(payload.get("ok")),
        )

    async def close(self) -> None:
        """stream 終了時。room 側の session executor も畳む。失敗は握りつぶす。"""
        if self._closed:
            return
        self._closed = True
        try:
            await self._client.delete(
                f"/voice/tools/execute/{self._session_id}",
                headers={TOKEN_HEADER: self._token},
            )
        except Exception:  # noqa: BLE001 -- close 失敗で会話終了を妨げない
            logger.debug("remote tool session close failed", exc_info=True)
        if self._owns_client:
            await self._client.aclose()


def remote_tool_executor_factory(
    *,
    room_url: str,
    token: str,
    client: httpx.AsyncClient | None = None,
) -> Callable[[str], RemoteVoiceToolExecutor]:
    """``app.state.voice_tool_executor_factory`` へ差し込む factory を組み立てる。

    ``client`` を渡すと全セッションで共有する（テスト用。所有は呼び出し側）。
    """

    def factory(session_id: str) -> RemoteVoiceToolExecutor:
        return RemoteVoiceToolExecutor(
            session_id=session_id,
            room_url=room_url,
            token=token,
            client=client,
        )

    return factory
