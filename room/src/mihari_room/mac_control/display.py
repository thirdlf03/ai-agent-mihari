"""画面構成（display layout）の扱い。

撮影結果は表示器 ID・画像サイズ（px）・スケール・座標変換情報を持つ。
操作はその撮影画像の座標を使うため、操作時点の Mac の画面構成と撮影時の
画面構成が同じであることを要求する（古い画面構成による操作の拒否）。
"""

from __future__ import annotations

from typing import Any

#: 点（point）で見た座標変換情報の形。
#: - width_px / height_px: 撮影画像のピクセルサイズ
#: - scale: px を点に割る倍率（Retina は 2.0）
#: - bounds: CGDisplayBounds 相当（点）。原点はメインディスプレイ左上
#: - layout_token: 撮影時点の画面構成の印。操作時の突き合わせに使う
DISPLAY_FIELDS = ("display_id", "width_px", "height_px", "scale", "bounds", "layout_token")


class DisplayGeometryError(ValueError):
    """画面構成が撮影時と違う、または不正。再撮影が必要。"""


def display_layout_token(displays: list[dict[str, Any]]) -> str:
    """表示器の並び（id・解像度・bounds）から画面構成の印を作る。"""
    import hashlib

    rows = []
    for display in sorted(displays, key=lambda item: str(item.get("display_id") or "")):
        bounds = display.get("bounds") or {}
        rows.append(
            ":".join(
                str(
                    (
                        display.get("display_id"),
                        display.get("width_px"),
                        display.get("height_px"),
                        display.get("scale"),
                        bounds.get("x"),
                        bounds.get("y"),
                        bounds.get("width"),
                        bounds.get("height"),
                    )
                )
            )
        )
    digest = hashlib.sha256("\n".join(rows).encode("utf-8")).hexdigest()
    return digest[:16]


def normalize_display(dict: dict[str, Any]) -> dict[str, Any]:
    """Mac が送ってきた表示器 1 台分を正規化する。壊れていれば ValueError。"""
    from mihari_room.mac_control.protocol import validate_display_id

    display_id = validate_display_id(dict.get("display_id"))
    try:
        width_px = int(dict["width_px"])
        height_px = int(dict["height_px"])
        scale = float(dict.get("scale") or 1.0)
    except (TypeError, ValueError, KeyError):
        raise ValueError(f"表示器 {display_id} のサイズが不正") from None
    if width_px <= 0 or height_px <= 0 or scale <= 0 or scale > 16:
        raise ValueError(f"表示器 {display_id} のサイズが不正")
    bounds_raw = dict.get("bounds") or {}
    try:
        bounds = {
            "x": float(bounds_raw.get("x") or 0),
            "y": float(bounds_raw.get("y") or 0),
            "width": float(bounds_raw.get("width") or 0),
            "height": float(bounds_raw.get("height") or 0),
        }
    except (TypeError, ValueError):
        raise ValueError(f"表示器 {display_id} の bounds が不正") from None
    if bounds["width"] <= 0 or bounds["height"] <= 0:
        raise ValueError(f"表示器 {display_id} の bounds が不正")
    return {
        "display_id": display_id,
        "width_px": width_px,
        "height_px": height_px,
        "scale": scale,
        "bounds": bounds,
        "layout_token": dict.get("layout_token") or "",
        "name": str(dict.get("name") or "")[:200],
    }


def normalize_displays(raw: Any) -> list[dict[str, Any]]:
    """Mac の hello / displays フレームの表示器一覧を正規化する。"""
    if raw is None:
        return []
    if not isinstance(raw, list) or not raw:
        return []
    out: list[dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        try:
            out.append(normalize_display(item))
        except ValueError:
            continue
    if not out:
        raise ValueError("表示器が読めない")
    return out


def resolve_display(displays: list[dict[str, Any]], display_id: str | None) -> dict[str, Any]:
    """表示器を選ぶ。display_id 省略時はメインディスプレイ（bounds 原点 0,0）優先。"""
    if not displays:
        raise DisplayGeometryError("表示器が無い")
    if display_id is not None:
        for display in displays:
            if display["display_id"] == str(display_id):
                return display
        raise DisplayGeometryError(f"表示器 {display_id} が見つからない（再撮影が必要）")
    for display in displays:
        bounds = display["bounds"]
        if bounds.get("x") == 0 and bounds.get("y") == 0:
            return display
    return displays[0]


def check_layout_matches(expected: dict[str, Any], current: dict[str, Any]) -> None:
    """操作に載せた撮影時点の画面構成と、いまの画面構成を突き合わせる。"""
    if expected.get("display_id") != current.get("display_id"):
        raise DisplayGeometryError("表示器の構成が変わった（再撮影が必要）")
    if expected.get("width_px") != current.get("width_px") or expected.get(
        "height_px"
    ) != current.get("height_px"):
        raise DisplayGeometryError("解像度が変わった（再撮影が必要）")
    expected_token = str(expected.get("layout_token") or "")
    current_token = str(current.get("layout_token") or "")
    if expected_token and current_token and expected_token != current_token:
        raise DisplayGeometryError("画面構成が変わった（再撮影が必要）")
    # scale と bounds は座標変換に使う。欠けていたら古い実装とみなさず弾く。
    if expected.get("scale") != current.get("scale"):
        raise DisplayGeometryError("スケールが変わった（再撮影が必要）")
    expected_bounds = expected.get("bounds") or {}
    current_bounds = current.get("bounds") or {}
    for key in ("x", "y", "width", "height"):
        if expected_bounds.get(key) != current_bounds.get(key):
            raise DisplayGeometryError("表示器の位置が変わった（再撮影が必要）")


def clamp_point(display: dict[str, Any], x_px: int, y_px: int) -> tuple[int, int]:
    """画像ピクセル座標を表示器の画像内へ丸める。"""
    width_px = int(display["width_px"])
    height_px = int(display["height_px"])
    x = max(0, min(int(x_px), width_px - 1)) if width_px > 0 else 0
    y = max(0, min(int(y_px), height_px - 1)) if height_px > 0 else 0
    return x, y


def px_to_point(display: dict[str, Any], x_px: int, y_px: int) -> tuple[float, float]:
    """撮影画像のピクセルを Mac の点（CGEvent 座標）へ変換する。"""
    scale = float(display["scale"] or 1.0)
    bounds = display["bounds"]
    x, y = clamp_point(display, x_px, y_px)
    return float(bounds["x"]) + x / scale, float(bounds["y"]) + y / scale
