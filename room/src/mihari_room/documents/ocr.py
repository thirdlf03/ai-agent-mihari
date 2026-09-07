"""Tesseract によるページ画像の OCR（日本語・英語）。

固定引数（``tesseract <img> stdout -l jpn+eng --psm 3``）で呼ぶ。genuine の
結果にファイル名・ページ番号を保持する。ページ番号はファイル名の
``page-<NNNN>`` から拾い、無ければ ``None`` と明示する。
"""

from __future__ import annotations

import logging
import os
import re
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import Any

from mihari_room.documents.pdf_reader import MAX_PROCESS_SECONDS, PdfError

logger = logging.getLogger("mihari_room")

#: OCR 言語。日本語＋英語。
OCR_LANG = "jpn+eng"
#: ページ番号の目印。レンダラーは page-<NNNN>.png を出す。
_PAGE_RE = re.compile(r"(?:^|[^\d])(\d+)(?:$|[^\d])")
#: 認識結果を返す最大文字数。
MAX_OCR_CHARS = 20_000

TESSERACT_BIN_ENV = "MIHARI_TESSERACT_BIN"
_TESSERACT_CANDIDATES = ("tesseract", "/opt/homebrew/bin/tesseract", "/usr/bin/tesseract")


def tesseract_bin() -> str | None:
    explicit = (os.environ.get(TESSERACT_BIN_ENV) or "").strip()
    if explicit:
        return explicit
    for candidate in _TESSERACT_CANDIDATES:
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


Runner = Callable[[list[str]], subprocess.CompletedProcess[str]]


def _default_runner(argv: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603 - 固定引数・固定バイナリ。shell は使わない
        argv,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def page_number_from_name(name: str) -> int | None:
    """``page-0003.png`` から 3 を返す。読めなければ None。"""
    stem = Path(name).stem
    match = _PAGE_RE.search(stem)
    if not match:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def ocr_image(
    image_path: Path,
    *,
    lang: str = OCR_LANG,
    timeout: float = MAX_PROCESS_SECONDS,
    runner: Runner | None = None,
) -> dict[str, Any]:
    """1 枚のページ画像を OCR する。ファイル名・ページ番号を保持する。"""
    if not Path(image_path).is_file():
        raise PdfError("missing_file", f"画像が無い: {image_path}")
    if runner is None:
        tesseract = tesseract_bin()
        if tesseract is None:
            raise PdfError(
                "missing_tesseract",
                "Tesseract が無いので OCR できない。"
                "日本語・英語の言語データ込みで導入してください（room/deploy/README.md）",
            )
    else:
        tesseract = "tesseract"  # 注入 runner ではバイナリ探索を要求しない
    argv = [tesseract, str(image_path), "stdout", "-l", lang, "--psm", "3"]
    try:
        done = (runner or _default_runner)(argv, timeout)
    except subprocess.TimeoutExpired as exc:
        from mihari_room.documents.pdf_reader import timeout_error

        raise timeout_error() from exc
    except OSError as exc:
        raise PdfError("missing_tesseract", f"tesseract を実行できなかった: {exc}") from exc
    if done.returncode != 0:
        detail = (done.stderr or done.stdout or "").strip()[:500]
        raise PdfError("ocr_failed", f"tesseract が失敗した: {detail or 'unknown'}")
    text = (done.stdout or "").strip()
    return {
        "filename": Path(image_path).name,
        "page": page_number_from_name(Path(image_path).name),
        "text": text[:MAX_OCR_CHARS],
        "truncated": len(text) > MAX_OCR_CHARS,
        "lang": lang,
    }
