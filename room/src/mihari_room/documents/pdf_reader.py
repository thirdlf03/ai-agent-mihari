"""PDF のページ単位テキスト抽出（既存 ``pypdf``）。

- ページごとの本文を切り出して返す。結果はファイル名・ページ番号を保持する
- 暗号化・破損・空・ページ数超過は、部分処理を全件処理と偽らないコード付きエラーで明示する
- 処理時間の上限（既定 120 秒）を超えたら ``processing_timeout`` で止める
"""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

#: 初期上限。これを超える PDF は明示エラー（範囲指定の読み取りは別途許す）。
MAX_PAGES = 100
#: 1 ページあたりの本文上限（文字）。文脈を大きすぎないようにする。
PER_PAGE_CHARS = 4000
#: 1 回の呼び出しで返す本文の合計上限（文字）。
TOTAL_CHARS = 100_000
#: 1 回の処理時間の上限（秒）。
MAX_PROCESS_SECONDS = 120.0


class PdfError(Exception):
    """PDF 処理の明示エラー。``code`` はツール応答にも載せる。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def encrypted_error() -> PdfError:
    return PdfError("encrypted", "暗号化された PDF です。パスワード付きは対象外")


def corrupt_error(detail: str) -> PdfError:
    return PdfError("corrupt", f"PDF が破損しているか読めません: {detail}")


def too_many_pages_error(page_count: int) -> PdfError:
    return PdfError(
        "too_many_pages",
        f"{page_count} ページの PDF です。初期上限は {MAX_PAGES} ページまで。"
        "範囲（first_page / last_page）を指定して分割して読んでください",
    )


def timeout_error() -> PdfError:
    return PdfError(
        "processing_timeout",
        f"処理時間が上限（{MAX_PROCESS_SECONDS:.0f} 秒）を超えました",
    )


def _open_reader(path: Path) -> Any:
    """pypdf の PdfReader を開く。エラーは明示コードに寄せる。"""
    try:
        from pypdf import PdfReader
    except ImportError as exc:  # pragma: no cover - 依存は固定済み
        raise PdfError("missing_pypdf", "pypdf が使えない") from exc
    try:
        reader = PdfReader(str(path))
    except Exception as exc:
        raise corrupt_error(str(exc)) from exc
    if getattr(reader, "is_encrypted", False):
        raise encrypted_error()
    return reader


def pdf_info(path: Path) -> dict[str, Any]:
    """ページ数などの基本情報。処理上限とは独立に返す。"""
    if not Path(path).is_file():
        raise PdfError("missing_file", f"PDF が無い: {path}")
    reader = _open_reader(Path(path))
    try:
        page_count = len(reader.pages)
    except Exception as exc:
        raise corrupt_error(str(exc)) from exc
    return {
        "filename": Path(path).name,
        "path": str(path),
        "page_count": page_count,
        "is_encrypted": False,
        "max_pages": MAX_PAGES,
    }


def _clip(text: str | None, limit: int) -> str:
    value = (text or "").strip()
    return value[:limit]


def extract_pdf_text(
    path: Path,
    *,
    first_page: int | None = None,
    last_page: int | None = None,
    max_pages: int = MAX_PAGES,
    max_process_seconds: float = MAX_PROCESS_SECONDS,
    per_page_chars: int = PER_PAGE_CHARS,
    total_chars: int = TOTAL_CHARS,
) -> dict[str, Any]:
    """ページ単位のテキスト抽出。

    - ``max_pages``（既定 100）を超える PDF は明示エラー ``too_many_pages``
    - ``first_page`` / ``last_page``（1 始まり）を渡すとその範囲だけを読み、
      全体より短いときは ``partial: true`` と ``total_pages`` を明示する
    - 切り詰めたときは ``truncated: true`` と理由を ``notes`` に足す
    """
    if not Path(path).is_file():
        raise PdfError("missing_file", f"PDF が無い: {path}")
    reader = _open_reader(Path(path))
    try:
        page_count = len(reader.pages)
    except Exception as exc:
        raise corrupt_error(str(exc)) from exc

    first = 1 if first_page is None else int(first_page)
    last = page_count if last_page is None else int(last_page)
    if first < 1:
        first = 1
    if last > page_count:
        last = page_count
    if first > last:
        return {
            "filename": Path(path).name,
            "path": str(path),
            "page_count": page_count,
            "requested_pages": 0,
            "pages": [],
            "partial": True,
            "truncated": False,
            "notes": ["ページ範囲が空です"],
        }
    requested = last - first + 1
    if requested > max_pages:
        raise too_many_pages_error(page_count)

    pages: list[dict[str, Any]] = []
    notes: list[str] = []
    truncated = False
    started = time.monotonic()
    total_used = 0
    for number in range(first, last + 1):
        if time.monotonic() - started > max_process_seconds:
            raise timeout_error()
        try:
            raw = reader.pages[number - 1].extract_text() or ""
        except Exception as exc:
            raise corrupt_error(f"{number} ページ目が読めない: {exc}") from exc
        text = _clip(raw, per_page_chars)
        pages.append({"page": number, "text": text})
        total_used += len(text)
        if len(raw) > per_page_chars:
            if not truncated:
                notes.append(f"{per_page_chars} 文字で 1 ページを切り詰めた")
                truncated = True
        if total_used >= total_chars:
            notes.append(f"本文の合計が {total_chars} 文字に達した（残りは読んでいない）")
            truncated = True
            break

    return {
        "filename": Path(path).name,
        "path": str(path),
        "page_count": page_count,
        "requested_pages": len(pages),
        "pages": pages,
        "partial": requested < page_count,
        "truncated": truncated,
        "notes": notes,
    }
