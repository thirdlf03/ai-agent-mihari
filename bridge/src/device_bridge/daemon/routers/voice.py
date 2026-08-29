"""セリフの生成と読み上げ。"""

from __future__ import annotations

import base64
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, status

from device_bridge.daemon.auth import verify_token
from device_bridge.voice.context import Escalation, IPhoneState, SpeechContext, VisionLabel
from device_bridge.voice.voicevox import VoicevoxUnavailableError

router = APIRouter(prefix="/voice", tags=["voice"], dependencies=[Depends(verify_token)])


@router.get("/status")
async def voice_status(request: Request) -> dict[str, Any]:
    """セリフ生成と読み上げが使える状態かを返す。

    どちらも落ちていて構わない。落ちている場合に「何をすれば喋るか」を出すために使う。
    """
    generator = request.app.state.line_generator
    voicevox = request.app.state.voicevox
    return {
        "llm_configured": generator.is_configured,
        "llm_model": generator.model,
        "voicevox_url": voicevox.base_url,
        "voicevox_speaker": voicevox.speaker,
        "voicevox_reachable": await voicevox.is_reachable(),
        "cached_audio": voicevox.cached_count,
    }


@router.post("/line")
async def make_line(request: Request, body: dict[str, Any]) -> dict[str, Any]:
    """状況からセリフを 1 本作る。読み上げはしない。"""
    context = _parse_context(body)
    line = await request.app.state.line_generator.generate(context)
    return {
        "text": line.text,
        "from_llm": line.from_llm,
        "fallback_reason": line.fallback_reason,
    }


@router.post("/speak")
async def speak(request: Request, body: dict[str, Any]) -> dict[str, Any]:
    """状況からセリフを作り、WAV まで用意する。

    音声は base64 で返し、再生は macOS 側で行う。
    VOICEVOX が起動していない場合も 200 を返し、``audio`` を ``None`` にする。
    喋れないことは検知や送信を止める理由にならない。
    """
    context = _parse_context(body)
    line = await request.app.state.line_generator.generate(context)

    audio: str | None = None
    error: str | None = None
    try:
        wav = await request.app.state.voicevox.synthesize(line.text)
        audio = base64.b64encode(wav).decode("ascii")
    except VoicevoxUnavailableError as unavailable:
        error = str(unavailable)

    return {
        "text": line.text,
        "from_llm": line.from_llm,
        "fallback_reason": line.fallback_reason,
        "audio": audio,
        "audio_error": error,
    }


def _parse_context(body: dict[str, Any]) -> SpeechContext:
    """要求の JSON を ``SpeechContext`` にする。未知の値は既定に倒す。"""
    try:
        return SpeechContext(
            idle_seconds=int(body.get("idle_seconds", 0)),
            escalation=_enum(Escalation, body.get("escalation"), Escalation.NUDGE),
            frontmost_app=_optional_str(body.get("frontmost_app")),
            iphone=_enum(IPhoneState, body.get("iphone"), IPhoneState.UNREACHABLE),
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
