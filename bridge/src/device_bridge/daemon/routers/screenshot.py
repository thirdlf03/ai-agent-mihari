"""iPhone のスクリーンショットに関する REST。

``GET /iphone/screenshot/preflight`` はセルフチェックの結果を返す。
``POST /iphone/screenshot`` は実際に撮影し、PNG を返す。

撮影した PNG は ``device_bridge.commands.screenshot.save_temp_png`` で一時ファイルへ
保存してから返し、レスポンス送信後に ``BackgroundTask`` で削除する。前提が欠けている
場合は 409、前提は揃っているが撮影自体が失敗した場合は 502 とし、いずれも「何が足りない
か」が分かる detail を返す(曖昧な 500 にしない)。
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask

from device_bridge.commands import screenshot, screenshot_source
from device_bridge.daemon.auth import verify_token

router = APIRouter(prefix="/iphone", tags=["iphone"], dependencies=[Depends(verify_token)])


@router.get("/screenshot/preflight")
async def get_preflight() -> dict[str, Any]:
    """Developer Mode / DDI マウント / tunneld 到達性のセルフチェック結果を返す。

    前提が欠けていること自体はエラーではないため、常に 200 で ``ready`` と
    各チェックの内訳を返す。
    """
    result = await screenshot.run_preflight(screenshot_source.LiveScreenshotSource())
    return result.to_payload()


@router.post("/screenshot")
async def post_screenshot() -> FileResponse:
    """スクリーンショットを撮り、PNG を返す。"""
    source = screenshot_source.LiveScreenshotSource()
    try:
        path, _result = await screenshot.capture_and_save(source)
    except screenshot.ScreenshotPreflightError as error:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"message": str(error), "preflight": error.result.to_payload()},
        ) from error
    except screenshot.ScreenshotCaptureError as error:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=str(error)) from error

    return FileResponse(
        path,
        media_type="image/png",
        filename="iphone-screenshot.png",
        background=BackgroundTask(screenshot.delete_temp_png, path),
    )
