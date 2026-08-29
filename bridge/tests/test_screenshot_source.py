"""``device_bridge.commands.screenshot_source`` のうち、実機を必要としない部分を検証する。

``LiveScreenshotSource`` 本体(lockdown 接続・DDI 照会・tunneld 照会)は実機が無いと
検証できないため対象外とし、ここでは PNG 変換とマウンタ選択という純粋なロジックだけを見る。
"""

from __future__ import annotations

import io

from PIL import Image
from pymobiledevice3.services.mobile_image_mounter import (
    DeveloperDiskImageMounter,
    PersonalizedImageMounter,
)

from device_bridge.commands.screenshot_source import _ensure_png, _mounter_for


def _tiff_bytes() -> bytes:
    image = Image.new("RGB", (2, 2), color=(1, 2, 3))
    buffer = io.BytesIO()
    image.save(buffer, format="TIFF")
    return buffer.getvalue()


def _png_bytes() -> bytes:
    image = Image.new("RGB", (2, 2), color=(1, 2, 3))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def test_ensure_png_passes_through_existing_png() -> None:
    raw = _png_bytes()

    result = _ensure_png(raw)

    assert result == raw


def test_ensure_png_converts_tiff_to_png() -> None:
    raw = _tiff_bytes()

    result = _ensure_png(raw)

    assert result.startswith(b"\x89PNG\r\n\x1a\n")
    with Image.open(io.BytesIO(result)) as reopened:
        assert reopened.format == "PNG"
        assert reopened.size == (2, 2)


class _FakeLockdown:
    """``MobileImageMounterService`` 生成に必要な最低限だけ持つフェイク。

    ``LockdownClient`` のサブクラスではないため、RSD 経由の RSD_SERVICE_NAME 分岐を通る。
    接続は行わないので、これでマウンタの型選択だけを安全に検証できる。
    """


def test_mounter_for_selects_personalized_image_for_ios17_plus() -> None:
    mounter = _mounter_for(_FakeLockdown(), "17.5.1")

    assert isinstance(mounter, PersonalizedImageMounter)
    assert mounter.IMAGE_TYPE == "Personalized"


def test_mounter_for_selects_developer_image_below_ios17() -> None:
    mounter = _mounter_for(_FakeLockdown(), "16.7")

    assert isinstance(mounter, DeveloperDiskImageMounter)
    assert mounter.IMAGE_TYPE == "Developer"
