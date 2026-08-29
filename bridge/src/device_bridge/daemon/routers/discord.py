"""Discord への投稿と、監視の予約。"""

from __future__ import annotations

import base64
import binascii
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, status

from device_bridge.daemon.auth import verify_token
from device_bridge.discord_bot.bot import DiscordUnavailableError
from device_bridge.discord_bot.invite import invite_url
from device_bridge.discord_bot.schedule import InvalidTimeError, parse_time_of_day
from device_bridge.discord_bot.settings_store import ChannelSelection

router = APIRouter(prefix="/discord", tags=["discord"], dependencies=[Depends(verify_token)])


@router.get("/status")
def discord_status(request: Request) -> dict[str, Any]:
    """Bot が使える状態かと、いま何が足りないかを返す。"""
    service = request.app.state.discord
    config = service.config
    selection = service.selection
    return {
        "token_configured": config.has_token,
        "client_id_configured": config.has_client_id,
        "missing": config.missing,
        "bot_ready": service.is_ready,
        "last_error": service.last_error,
        "invite_url": invite_url(config.client_id) if config.has_client_id else None,
        "selection": selection.to_dict() if selection else None,
        "schedule": request.app.state.watch_scheduler.status(),
    }


@router.get("/channels")
def list_channels(request: Request) -> dict[str, Any]:
    """投稿できるチャンネルの一覧。"""
    try:
        channels = request.app.state.discord.channels()
    except DiscordUnavailableError as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    return {"channels": [channel.to_dict() for channel in channels]}


@router.post("/channel")
def select_channel(request: Request, body: dict[str, Any]) -> dict[str, Any]:
    """投稿先のチャンネルを決める。"""
    try:
        selection = ChannelSelection(
            guild_id=int(body["guild_id"]),
            channel_id=int(body["channel_id"]),
            guild_name=str(body.get("guild_name") or ""),
            channel_name=str(body.get("channel_name") or ""),
        )
    except (KeyError, TypeError, ValueError) as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"チャンネルの指定が不正: {error}",
        ) from error

    request.app.state.discord.select_channel(selection)
    return {"selection": selection.to_dict()}


@router.post("/post")
async def post_evidence(request: Request, body: dict[str, Any]) -> dict[str, Any]:
    """証拠を投稿する。画像は base64 で受け取る。"""
    text = str(body.get("text") or "")
    image = _decode_image(body.get("image"))
    filename = str(body.get("filename") or "evidence.png")

    if not text and image is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="text か image のどちらかは必要",
        )

    try:
        message_id = await request.app.state.discord.post(text, image=image, filename=filename)
    except DiscordUnavailableError as error:
        # 晒せないことは検知を止める理由にならないので、原因を返して呼び出し元に判断させる。
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    return {"posted": True, "message_id": message_id}


@router.get("/schedule")
async def schedule_status(request: Request) -> dict[str, Any]:
    return request.app.state.watch_scheduler.status()


@router.post("/schedule")
async def set_schedule(request: Request, body: dict[str, Any]) -> dict[str, Any]:
    """監視の開始を予約する。`at` を省くとすぐ始める。

    予約は `asyncio.create_task` で作るのでイベントループ上で動く必要がある。
    同期エンドポイントにするとスレッドプールで動いてループが無く、登録に失敗する。
    """
    scheduler = request.app.state.watch_scheduler
    requested_by = str(body.get("requested_by") or "app")
    raw_time = body.get("at")

    if raw_time is None:
        scheduler.start_now(requested_by=requested_by)
        return scheduler.status()

    try:
        hour, minute = parse_time_of_day(str(raw_time))
    except InvalidTimeError as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(error)
        ) from error

    scheduler.schedule_at(hour, minute, requested_by=requested_by)
    return scheduler.status()


@router.delete("/schedule")
async def stop_schedule(request: Request) -> dict[str, Any]:
    scheduler = request.app.state.watch_scheduler
    scheduler.stop(requested_by="app")
    return scheduler.status()


def _decode_image(raw: Any) -> bytes | None:
    if raw is None:
        return None
    try:
        return base64.b64decode(str(raw), validate=True)
    except (binascii.Error, ValueError) as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"画像を base64 として読めない: {error}",
        ) from error
