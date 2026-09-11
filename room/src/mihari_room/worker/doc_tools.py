"""Room 専用の文書ツール（in-process、汎用 shell 権限なし）。

Hermes に PDF・Markdown の読み書きを渡す。連携は discord_* と同じく
``mihari_room`` toolset の実 registry 登録で行う。

- PDF: ページ単位テキスト抽出（pypdf）・ページ画像化（Poppler）・OCR（Tesseract 日本語+英語）
- Markdown: プレビューと同じ HTML を Chromium 印刷して PDF にする（無ければ fpdf2）
- 初期上限: 最大 100 ページ・処理 120 秒。超過・破損・暗号化は明示エラー
- すべて固定引数の呼び出し。shell（``-c`` 等）は一切使わない
"""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Callable
from pathlib import Path
from typing import Any

from mihari_room.documents import ocr as ocr_mod
from mihari_room.documents.pdf_gen import RenderError, convert_markdown_file
from mihari_room.documents.pdf_reader import (
    MAX_PAGES,
    MAX_PROCESS_SECONDS,
    PdfError,
    extract_pdf_text,
    pdf_info,
)
from mihari_room.documents.pdf_render import DEFAULT_DPI, render_pages

logger = logging.getLogger("mihari_room")

TOOLSET_NAME = "mihari_room"

TOOL_NAMES = (
    "pdf_info",
    "pdf_text",
    "pdf_pages",
    "pdf_ocr",
    "markdown_pdf",
)

#: OCR 言語として許す文字（固定文字列の範囲に縛る）。
_LANG_RE = re.compile(r"^[a-zA-Z+_-]{1,40}$")


class ToolError(Exception):
    """ツール呼び出しの明示エラー（コード付き）。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _resolve_under(root: Path, raw: str) -> Path:
    """ジョブ内のパスだけ解決する。外へは出さない。

    相対パスは root 起点、絶対パスも root の内側だけ受け付ける
    （ツールが返した絶対パスをそのまま渡せるようにする）。
    """
    if not raw or not raw.strip():
        raise ToolError("invalid_path", "ファイルパスが空")
    candidate = Path(raw)
    if candidate.is_absolute():
        resolved_path = candidate.resolve()
        if not _inside(resolved_path, root):
            raise ToolError("invalid_path", "ジョブの外のファイルは扱えません")
        return resolved_path
    if any(part in ("", ".", "..") for part in candidate.parts):
        raise ToolError("invalid_path", "パスが不正です")
    resolved_path = (root / candidate).resolve()
    if not _inside(resolved_path, root):
        raise ToolError("invalid_path", "ジョブの外のファイルは扱えません")
    return resolved_path


def _inside(path: Path, root: Path) -> bool:
    resolved_root = root.resolve()
    try:
        return path.is_relative_to(resolved_root)
    except AttributeError:  # pragma: no cover - 3.11 未満のフォールバック
        return str(path).startswith(str(resolved_root) + "/")


def _rel(root: Path, path: Path) -> str:
    """応答に載せるジョブ相対パス（絶対パスを外に出さない）。"""
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)


def _ok(payload: dict[str, Any]) -> str:
    payload = dict(payload)
    payload["success"] = True
    return json.dumps(payload, ensure_ascii=False)


def _err(error: Exception) -> str:
    code = getattr(error, "code", "failed")
    message = str(error) or "失敗"
    return json.dumps({"success": False, "code": code, "error": message}, ensure_ascii=False)


def _run(fn: Callable[[], dict[str, Any]]) -> str:
    try:
        return _ok(fn())
    except (PdfError, RenderError, ToolError, FileNotFoundError, OSError, ValueError) as exc:
        return _err(exc)
    except Exception as exc:  # noqa: BLE001 - ツールは常に JSON を返す
        logger.debug("document tool failed", exc_info=True)
        return _err(exc)


# -- 実装 ---------------------------------------------------------------


def pdf_info_impl(job: Any, path: str) -> str:
    """PDF のページ数などの基本情報。"""
    root = Path(job.directory)

    def _go() -> dict[str, Any]:
        info = pdf_info(_resolve_under(root, path))
        info["path"] = _rel(root, Path(info["path"]))
        return info

    return _run(_go)


def pdf_text_impl(job: Any, path: str, first_page: Any = None, last_page: Any = None) -> str:
    """PDF のページ単位テキスト抽出。結果にファイル名・ページ番号を保持する。"""
    root = Path(job.directory)

    def _go() -> dict[str, Any]:
        first = _optional_int(first_page)
        last = _optional_int(last_page)
        result = extract_pdf_text(
            _resolve_under(root, path),
            first_page=first,
            last_page=last,
            max_pages=MAX_PAGES,
            max_process_seconds=MAX_PROCESS_SECONDS,
        )
        result["path"] = _rel(root, Path(result["path"]))
        return result

    return _run(_go)


def pdf_pages_impl(
    job: Any,
    path: str,
    first_page: Any = None,
    last_page: Any = None,
    dpi: Any = None,
) -> str:
    """PDF のページ画像化（Poppler）。結果にファイル名・ページ番号を保持する。"""
    root = Path(job.directory)
    out_dir = root / "research" / "pdf_pages"

    def _go() -> dict[str, Any]:
        dpi_value = _optional_int(dpi) or DEFAULT_DPI
        if not 72 <= dpi_value <= 300:
            raise ToolError("invalid_dpi", "dpi は 72〜300 の範囲で指定してください")
        result = render_pages(
            _resolve_under(root, path),
            out_dir,
            first_page=_optional_int(first_page),
            last_page=_optional_int(last_page),
            dpi=dpi_value,
            max_pages=MAX_PAGES,
            timeout=MAX_PROCESS_SECONDS,
        )
        result["path"] = _rel(root, Path(result["path"]))
        for image in result["images"]:
            # ページ画像はジョブ相対で返す（次に pdf_ocr へ渡しやすい）。
            image["path"] = _rel(root, Path(image["path"]))
        return result

    return _run(_go)


def pdf_ocr_impl(job: Any, image_path: str, lang: str | None = None) -> str:
    """ページ画像の OCR（日本語+英語）。結果にファイル名・ページ番号を保持する。"""
    root = Path(job.directory)

    def _go() -> dict[str, Any]:
        resolved = _resolve_under(root, image_path)
        language = (lang or ocr_mod.OCR_LANG).strip()
        if not _LANG_RE.fullmatch(language):
            raise ToolError("invalid_lang", "lang は jpn+eng のような固定文字列だけです")
        return ocr_mod.ocr_image(resolved, lang=language, timeout=MAX_PROCESS_SECONDS)

    return _run(_go)


def markdown_pdf_impl(job: Any, md_path: str, out_path: str | None = None) -> str:
    """Markdown をプレビュー HTML の印刷、または控えの fpdf2 で PDF にする。"""
    root = Path(job.directory)

    def _go() -> dict[str, Any]:
        resolved = _resolve_under(root, md_path)
        if resolved.suffix.lower() not in (".md", ".markdown"):
            raise ToolError("not_markdown", "入力は .md / .markdown だけです")
        if out_path and out_path.strip():
            target = _resolve_under(root, out_path)
        else:
            target = resolved.with_suffix(".pdf")
        result = convert_markdown_file(resolved, target)
        result["path"] = _rel(root, Path(result["path"]))
        result["source"] = _rel(root, resolved)
        return result

    return _run(_go)


def _optional_int(raw: Any) -> int | None:
    if raw is None or raw == "":
        return None
    try:
        return int(raw)
    except (TypeError, ValueError) as exc:
        raise ToolError("invalid_page", f"ページ番号が数字ではない: {raw}") from exc


def _tool_args(args: Any, kwargs: dict[str, Any]) -> dict[str, Any]:
    """Hermes は ``handler(args_dict, **kwargs)``。kwargs 専用だと TypeError になる。"""
    merged: dict[str, Any] = {}
    if isinstance(args, dict):
        merged.update(args)
    merged.update(kwargs)
    return merged


def _make_handlers(job: Any) -> dict[str, Any]:
    def info(args: Any = None, **kwargs: Any) -> str:
        opts = _tool_args(args, kwargs)
        return pdf_info_impl(job, opts.get("path", ""))

    def text(args: Any = None, **kwargs: Any) -> str:
        opts = _tool_args(args, kwargs)
        return pdf_text_impl(
            job,
            opts.get("path", ""),
            opts.get("first_page"),
            opts.get("last_page"),
        )

    def pages(args: Any = None, **kwargs: Any) -> str:
        opts = _tool_args(args, kwargs)
        return pdf_pages_impl(
            job,
            opts.get("path", ""),
            opts.get("first_page"),
            opts.get("last_page"),
            opts.get("dpi"),
        )

    def ocr(args: Any = None, **kwargs: Any) -> str:
        opts = _tool_args(args, kwargs)
        return pdf_ocr_impl(job, opts.get("image_path", ""), opts.get("lang"))

    def markdown(args: Any = None, **kwargs: Any) -> str:
        opts = _tool_args(args, kwargs)
        return markdown_pdf_impl(job, opts.get("md_path", ""), opts.get("out_path"))

    return {
        "pdf_info": info,
        "pdf_text": text,
        "pdf_pages": pages,
        "pdf_ocr": ocr,
        "markdown_pdf": markdown,
    }


_SCHEMAS: dict[str, dict[str, Any]] = {
    "pdf_info": {
        "type": "function",
        "function": {
            "name": "pdf_info",
            "description": (
                "PDF のページ数・暗号化の有無を返す。"
                "暗号化・破損は success=false と code で明示する。"
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "ジョブ内の PDF の相対パス",
                    },
                },
                "required": ["path"],
            },
        },
    },
    "pdf_text": {
        "type": "function",
        "function": {
            "name": "pdf_text",
            "description": (
                "PDF からページ単位でテキストを抽出する。"
                "結果はファイル名・ページ番号付き。100 ページ上限・120 秒上限。"
                "超える PDF は first_page / last_page で範囲を分けて読む。"
                "暗号化・破損・上限超過は code 付きで明示される。"
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "ジョブ内の PDF の相対パス"},
                    "first_page": {
                        "type": "integer",
                        "description": "最初のページ（1 始まり・省略可）",
                    },
                    "last_page": {
                        "type": "integer",
                        "description": "最後のページ（1 始まり・省略可）",
                    },
                },
                "required": ["path"],
            },
        },
    },
    "pdf_pages": {
        "type": "function",
        "function": {
            "name": "pdf_pages",
            "description": (
                "PDF のページを PNG 画像化して research/pdf_pages に置く。"
                "結果はファイル名・ページ番号・寸法付き（Poppler 使用）。"
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "ジョブ内の PDF の相対パス"},
                    "first_page": {"type": "integer"},
                    "last_page": {"type": "integer"},
                    "dpi": {"type": "integer", "default": 144, "minimum": 72, "maximum": 300},
                },
                "required": ["path"],
            },
        },
    },
    "pdf_ocr": {
        "type": "function",
        "function": {
            "name": "pdf_ocr",
            "description": (
                "ページ画像（pdf_pages の出力）を OCR する。日本語+英語。"
                "結果はファイル名・ページ番号付き。画像化してから呼ぶこと。"
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "image_path": {
                        "type": "string",
                        "description": (
                            "PDF ページ画像の相対パス"
                            "（例: research/pdf_pages/report_144dpi/page-0001.png）"
                        ),
                    },
                    "lang": {"type": "string", "default": "jpn+eng"},
                },
                "required": ["image_path"],
            },
        },
    },
    "markdown_pdf": {
        "type": "function",
        "function": {
            "name": "markdown_pdf",
            "description": (
                "Markdown をプレビューと同じ HTML から PDF に変換して書き出す。"
                "表・リスト・コード・画像・リンクの見た目を保つ。生 HTML は無効。"
                "入力は output/ の .md、出力は同じ場所の .pdf（既定）。"
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "md_path": {"type": "string", "description": "ジョブ内の .md の相対パス"},
                    "out_path": {
                        "type": "string",
                        "description": "出力 .pdf の相対パス（省略時は md と同じ場所）",
                    },
                },
                "required": ["md_path"],
            },
        },
    },
}


def register_doc_tools(job: Any) -> Callable[[], None] | None:
    """``mihari_room`` toolset に文書ツールを登録する。restore 関数を返す。

    実 Hermes registry が import できない（fake agent テスト）ときは None。
    登録済みの名前は黙ってスキップし、途中失敗時は登録済み分を戻す。
    """
    try:
        from tools.registry import registry
    except ImportError:
        return None
    handlers = _make_handlers(job)
    registered: list[str] = []
    for name in TOOL_NAMES:
        schema = _SCHEMAS[name]
        try:
            registry.register(
                name,
                TOOLSET_NAME,
                schema,
                handlers[name],
                description=schema["function"]["description"],
                emoji="📄",
            )
        except TypeError as exc:
            logger.error("document tool register failed for %s: %s", name, exc)
            for done in registered:
                try:
                    registry.deregister(done)
                except Exception:
                    pass
            raise
        except Exception:
            logger.debug("document tool %s already registered", name, exc_info=True)
            continue
        registered.append(name)

    def restore() -> None:
        try:
            from tools.registry import registry as live
        except ImportError:
            return
        for name in registered:
            try:
                live.deregister(name)
            except Exception:
                pass

    return restore
