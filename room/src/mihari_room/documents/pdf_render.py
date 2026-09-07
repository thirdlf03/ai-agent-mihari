"""Poppler (``pdftoppm``) による PDF のページ画像化。

汎用 shell は使わない。バイナリは固定の引数構成（``-png -r <dpi> -f <f> -l <l>``）で
``subprocess`` のリスト引数として呼ぶ。テストでは runner を差し替えられる。
"""

from __future__ import annotations

import logging
import os
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import Any

from mihari_room.documents.pdf_reader import (
    MAX_PAGES,
    MAX_PROCESS_SECONDS,
    PdfError,
    too_many_pages_error,
)

logger = logging.getLogger("mihari_room")

#: 既定の DPI。文書表示・OCR の両方で読める解像度。
DEFAULT_DPI = 144

#: バイナリの探索順。環境変数で明示もできる（テスト・特殊パス向け）。
POPPLER_BIN_ENV = "MIHARI_POPPLER_BIN"
_POPPLER_CANDIDATES = ("pdftoppm", "/opt/homebrew/bin/pdftoppm", "/usr/bin/pdftoppm")


def poppler_bin() -> str | None:
    """pdftoppm の場所。見つからなければ None（明示エラーになる）。"""
    explicit = (os.environ.get(POPPLER_BIN_ENV) or "").strip()
    if explicit:
        return explicit
    for candidate in _POPPLER_CANDIDATES:
        if _which(candidate):
            return candidate
    return None


def _which(name: str) -> bool:
    if "/" in name:
        try:
            return os.path.isfile(name) and os.access(name, os.X_OK)
        except OSError:
            return False
    from shutil import which

    return which(name) is not None


#: subprocess.run 相当。テストで差し替える。
Runner = Callable[[list[str]], subprocess.CompletedProcess[str]]


def _default_runner(argv: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603 - 固定引数・固定バイナリ。shell は使わない
        argv,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def _page_number_from_name(name: str) -> int:
    """``page-0003.png`` / ``page-3.png`` から 3 を返す。読めなければ大きい値。"""
    stem = Path(name).stem
    digits = stem.rsplit("-", 1)[-1]
    try:
        return int(digits)
    except ValueError:
        return 10**9


def _page_size(reader: Any, number: int, dpi: int) -> tuple[int, int]:
    """ページの PDF 座標からピクセル寸法を返す（回転は考慮しない）。"""
    try:
        page = reader.pages[number - 1]
        box = getattr(page, "mediabox", None)
        if box is None:
            return dpi, dpi
        width = float(getattr(box, "width", dpi))
        height = float(getattr(box, "height", dpi))
        scale = dpi / 72.0
        return max(1, int(round(width * scale))), max(1, int(round(height * scale)))
    except Exception:
        return dpi, dpi


def render_pages(
    pdf_path: Path,
    out_dir: Path,
    *,
    first_page: int | None = None,
    last_page: int | None = None,
    dpi: int = DEFAULT_DPI,
    max_pages: int = MAX_PAGES,
    timeout: float = MAX_PROCESS_SECONDS,
    runner: Runner | None = None,
) -> dict[str, Any]:
    """ページを PNG 画像に描画する。結果にファイル名・ページ番号を保持する。

    - 出力は ``out_dir/<stem>_<dpi>/page-<NNNN>.png``
    - ページ数上限・時間上限を超えたら明示エラー
    - Poppler が見つからないときは ``missing_poppler``
    """
    from mihari_room.documents.pdf_reader import _open_reader

    if not Path(pdf_path).is_file():
        raise PdfError("missing_file", f"PDF が無い: {pdf_path}")
    reader = _open_reader(pdf_path)
    try:
        page_count = len(reader.pages)
        inner_first = 1 if first_page is None else max(1, int(first_page))
        inner_last = page_count if last_page is None else min(page_count, int(last_page))
    except Exception as exc:
        raise PdfError("corrupt", f"PDF が破損しているか読めません: {exc}") from exc

    requested = inner_last - inner_first + 1
    if requested < 1 or inner_first > inner_last:
        return {
            "filename": Path(pdf_path).name,
            "path": str(pdf_path),
            "page_count": page_count,
            "images": [],
            "partial": True,
            "truncated": False,
            "notes": ["ページ範囲が空です"],
        }
    if requested > max_pages:
        raise too_many_pages_error(page_count)

    pdftoppm = poppler_bin()
    if pdftoppm is None:
        raise PdfError(
            "missing_poppler",
            "Poppler (pdftoppm) が無いのでページ画像を作れない。"
            "VPS への導入は room/deploy/README.md を参照",
        )

    stem = Path(pdf_path).stem
    dest = Path(out_dir) / f"{stem}_{dpi}dpi"
    dest.mkdir(parents=True, exist_ok=True)
    prefix = dest / "page"
    argv = [
        pdftoppm,
        "-png",
        "-r",
        str(dpi),
        "-f",
        str(inner_first),
        "-l",
        str(inner_last),
        str(pdf_path),
        str(prefix),
    ]
    try:
        done = (runner or _default_runner)(argv, timeout)
    except subprocess.TimeoutExpired as exc:
        from mihari_room.documents.pdf_reader import timeout_error

        raise timeout_error() from exc
    except OSError as exc:
        raise PdfError("missing_poppler", f"pdftoppm を実行できなかった: {exc}") from exc
    if done.returncode != 0:
        detail = (done.stderr or done.stdout or "").strip()[:500]
        if "password" in detail.lower():
            raise PdfError("encrypted", "暗号化された PDF です。パスワード付きは対象外")
        raise PdfError("corrupt", f"pdftoppm が失敗した: {detail or 'unknown'}")

    images: list[dict[str, Any]] = []
    rendered = sorted(
        dest.glob("page-*.png"),
        key=lambda p: _page_number_from_name(p.name),
    )
    expected = list(range(inner_first, inner_last + 1))
    if len(rendered) != len(expected):
        raise PdfError("corrupt", "ページ画像の枚数が合わない")
    for number, image_path in zip(expected, rendered, strict=True):
        width, height = _page_size(reader, number, dpi)
        images.append(
            {
                "page": number,
                "filename": image_path.name,
                "path": str(image_path),
                "width": width,
                "height": height,
            }
        )
    return {
        "filename": Path(pdf_path).name,
        "path": str(pdf_path),
        "page_count": page_count,
        "images": images,
        "partial": requested < page_count,
        "truncated": False,
        "notes": [f"DPI {dpi} で描画した"] if requested < page_count else [],
    }
