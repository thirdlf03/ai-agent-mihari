"""セリフの生成と読み上げ。"""

from __future__ import annotations

import asyncio
import base64
import logging
import time
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, status

from device_bridge.daemon.auth import verify_token
from device_bridge.voice.context import Escalation, IPhoneState, SpeechContext, VisionLabel
from device_bridge.voice.fallback import fallback_line
from device_bridge.voice.generator import GeneratedLine
from device_bridge.voice.screen_reader import ScreenReadError, ScreenReading
from device_bridge.voice.voicevox import VoicevoxUnavailableError

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/voice", tags=["voice"], dependencies=[Depends(verify_token)])

#: PNG のマジックナンバー。別形式を Gemini に投げても読めないので入口で弾く。
_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

#: 画面読み取り・セリフ生成・音声合成をすべて含めた 1 リクエストの上限(秒)。
#: 呼び出し元の macOS アプリは 60 秒で諦めるので、それより十分手前で必ず返す。
#: 内訳のどれが遅くても、待たせ続けるより固定文言で返した方がペットは黙らずに済む。
SPEAK_DEADLINE_SECONDS = 20.0

#: 上限を超えたときに返す理由。テキストは固定文言に落ちる。
_TIMED_OUT_REASON = f"{SPEAK_DEADLINE_SECONDS:.0f} 秒以内に用意できなかった"

#: 画面読み取りだけを行うときの上限(秒)。セリフ生成も音声合成も挟まないので短く切る。
#: 同封済みの音声を鳴らすモードでは、これが Discord の文面を待たせる時間そのものになる。
SCREEN_DEADLINE_SECONDS = 8.0

#: 読み取りの上限を超えたときに返す理由。
_SCREEN_TIMED_OUT_REASON = f"{SCREEN_DEADLINE_SECONDS:.0f} 秒以内に読めなかった"

#: スクショが添えられていなかったときに返す理由。
_NO_SCREENSHOT_REASON = "スクリーンショットが無い"


@router.get("/status")
async def voice_status(request: Request) -> dict[str, Any]:
    """セリフ生成と読み上げが使える状態かを返す。

    どちらも落ちていて構わない。落ちている場合に「何をすれば喋るか」を出すために使う。
    """
    generator = request.app.state.line_generator
    screen_reader = request.app.state.screen_reader
    voicevox = request.app.state.voicevox
    return {
        "llm_configured": generator.is_configured,
        "llm_model": generator.model,
        "screen_llm_configured": screen_reader.is_configured,
        "screen_llm_model": screen_reader.model,
        "voicevox_url": voicevox.base_url,
        "voicevox_speaker": voicevox.speaker,
        "voicevox_tuning": voicevox.tuning.as_dict(),
        "voicevox_reachable": await voicevox.is_reachable(),
        "cached_audio": voicevox.cached_count,
    }


@router.post("/line")
async def make_line(request: Request, body: dict[str, Any]) -> dict[str, Any]:
    """状況からセリフを 1 本作る。読み上げはしない。"""
    context = _parse_context(body)
    screenshot = _parse_screenshot(body)
    try:
        async with asyncio.timeout(SPEAK_DEADLINE_SECONDS):
            line, reading, screen_error = await _generate(request.app.state, context, screenshot)
    except TimeoutError:
        return _timed_out_payload(context)

    return {
        "text": line.text,
        "from_llm": line.from_llm,
        "fallback_reason": line.fallback_reason,
        "screen": _screen_payload(reading),
        "screen_error": screen_error,
    }


@router.post("/screen")
async def read_screen(request: Request, body: dict[str, Any]) -> dict[str, Any]:
    """スクショから画面の読み取りだけを行う。セリフも音声も作らない。

    同封済みの音声を鳴らすモード用。Discord の文面を組み立てる材料としてだけ使う。
    読めなかったことは送るのをやめる理由にならないので、失敗も 200 で理由だけ返す。
    """
    context = _parse_context(body)
    screenshot = _parse_screenshot(body)
    if screenshot is None:
        return _screen_only_payload(None, _NO_SCREENSHOT_REASON)

    reader = request.app.state.screen_reader
    if not reader.is_configured:
        return _screen_only_payload(None, "GEMINI_API_KEY が未設定")

    try:
        async with asyncio.timeout(SCREEN_DEADLINE_SECONDS):
            # セリフは使わないので、それが壊れていても見立てだけは受け取る。
            reading = await reader.read(screenshot, context, require_line=False)
    except ScreenReadError as error:
        return _screen_only_payload(None, str(error))
    except TimeoutError:
        return _screen_only_payload(None, _SCREEN_TIMED_OUT_REASON)

    return _screen_only_payload(reading, None)


@router.post("/speak")
async def speak(request: Request, body: dict[str, Any]) -> dict[str, Any]:
    """状況からセリフを作り、WAV まで用意する。

    音声は base64 で返し、再生は macOS 側で行う。
    VOICEVOX が起動していない場合も 200 を返し、``audio`` を ``None`` にする。
    喋れないことは検知や送信を止める理由にならない。
    上限を超えた場合も同じ理由で 200 を返し、固定文言だけを渡す。
    """
    context = _parse_context(body)
    screenshot = _parse_screenshot(body)
    started = time.monotonic()

    try:
        async with asyncio.timeout(SPEAK_DEADLINE_SECONDS):
            line, reading, screen_error = await _generate(request.app.state, context, screenshot)
            audio, audio_error = await _synthesize(request.app.state, line.text)
    except TimeoutError:
        payload = _timed_out_payload(context) | {"audio": None, "audio_error": _TIMED_OUT_REASON}
    else:
        payload = {
            "text": line.text,
            "from_llm": line.from_llm,
            "fallback_reason": line.fallback_reason,
            "screen": _screen_payload(reading),
            "screen_error": screen_error,
            "audio": audio,
            "audio_error": audio_error,
        }

    # 実運用で遅いのがどこかを追えるように、1 リクエスト 1 行だけ残す。
    logger.info(
        "/voice/speak %.1fs from_llm=%s screen_error=%s audio_error=%s",
        time.monotonic() - started,
        payload["from_llm"],
        payload["screen_error"],
        payload["audio_error"],
    )
    return payload


async def _synthesize(state: Any, text: str) -> tuple[str | None, str | None]:
    """セリフを WAV にして base64 で返す。合成できなければ理由だけを返す。"""
    try:
        wav = await state.voicevox.synthesize(text)
    except VoicevoxUnavailableError as unavailable:
        return None, str(unavailable)
    return base64.b64encode(wav).decode("ascii"), None


def _timed_out_payload(context: SpeechContext) -> dict[str, Any]:
    """上限を超えたときの応答。固定文言だけを返す。

    間に合わなかったことは検知や送信を止める理由にならないので、エラーにはしない。
    """
    return {
        "text": fallback_line(context),
        "from_llm": False,
        "fallback_reason": _TIMED_OUT_REASON,
        "screen": None,
        "screen_error": _TIMED_OUT_REASON,
    }


async def _generate(
    state: Any, context: SpeechContext, screenshot: bytes | None
) -> tuple[GeneratedLine, ScreenReading | None, str | None]:
    """セリフを 1 本作る。スクショがあれば Gemini を先に試す。

    Gemini が使えない・失敗したときは従来の Claude 経路(さらに固定文言)に落とし、
    理由だけを ``screen_error`` として返す。画面が読めないことは喋らない理由にならない。
    """
    if screenshot is None:
        return await state.line_generator.generate(context), None, None

    reader = state.screen_reader
    if not reader.is_configured:
        return await state.line_generator.generate(context), None, "GEMINI_API_KEY が未設定"

    try:
        reading = await reader.read(screenshot, context)
    except ScreenReadError as error:
        return await state.line_generator.generate(context), None, str(error)

    return GeneratedLine(text=reading.line, from_llm=True), reading, None


def _screen_only_payload(reading: ScreenReading | None, error: str | None) -> dict[str, Any]:
    """``/voice/screen`` の応答。セリフを含まないぶん ``/voice/line`` の一部と同じ形にする。"""
    return {"screen": _screen_payload(reading), "screen_error": error}


def _screen_payload(reading: ScreenReading | None) -> dict[str, Any] | None:
    if reading is None:
        return None
    return {
        "app": reading.app,
        "activity": reading.activity,
        "category": str(reading.category),
    }


def _parse_screenshot(body: dict[str, Any]) -> bytes | None:
    """任意の ``screenshot_png`` を取り出す。無ければ ``None``。

    壊れた画像を Gemini まで運んでも失敗するだけなので、入口で 422 にする。
    """
    raw = body.get("screenshot_png")
    if raw is None:
        return None
    encoded = str(raw).strip()
    if not encoded:
        return None

    try:
        png = base64.b64decode(encoded, validate=True)
    except ValueError as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="screenshot_png を base64 として解釈できない",
        ) from error

    if not png.startswith(_PNG_SIGNATURE):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="screenshot_png が PNG ではない",
        )
    return png


def _parse_context(body: dict[str, Any]) -> SpeechContext:
    """要求の JSON を ``SpeechContext`` にする。未知の値は既定に倒す。"""
    try:
        return SpeechContext(
            idle_seconds=int(body.get("idle_seconds", 0)),
            escalation=_enum(Escalation, body.get("escalation"), Escalation.NUDGE),
            frontmost_app=_optional_str(body.get("frontmost_app")),
            iphone=_enum(IPhoneState, body.get("iphone"), IPhoneState.UNREACHABLE),
            iphone_app=_optional_str(body.get("iphone_app")),
            vision=_enum(VisionLabel, body.get("vision"), VisionLabel.UNKNOWN),
        )
    except (TypeError, ValueError) as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"状況を解釈できない: {error}",
        ) from error


def _enum[T](enum_type: type[T], raw: Any, default: T) -> T:
    """知らない値が来ても落とさず既定に倒す。送り手と受け手の版がずれても喋り続けるため。"""
    if raw is None:
        return default
    try:
        return enum_type(raw)
    except ValueError:
        return default


def _optional_str(raw: Any) -> str | None:
    if raw is None:
        return None
    text = str(raw).strip()
    return text or None
