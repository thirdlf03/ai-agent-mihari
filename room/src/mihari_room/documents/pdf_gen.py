"""Markdown → PDF の専用レンダラー。

既定はプレビューと同じ HTML（markdown-it）を Chromium で印刷する（Playwright）。
Playwright / Chromium が無い環境では、同梱 IPAexGothic の fpdf2 レイアウトに倒す。

- 生 HTML は無効。外部フォント・CDN は読みに行かない（HTML 側の方針と同じ）
- Chromium は PDF 1 件ごとに起動し、常駐させない
- 開くのは生成した file:// の HTML だけ
"""

from __future__ import annotations

import logging
import os
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from mihari_room.documents.markdown_render import markdown_renderer, render_to_page

logger = logging.getLogger("mihari_room")

#: Chromium は systemd の NoNewPrivileges 下ではサンドボックスを落とせない。
_CHROMIUM_ARGS = ("--no-sandbox", "--disable-dev-shm-usage")
_PLAYWRIGHT_TIMEOUT_MS = 120_000
_playwright_available_cached: bool | None = None

#: ページ余白（mm）。A4。
MARGIN_LEFT = 18.0
MARGIN_RIGHT = 18.0
MARGIN_TOP = 16.0
MARGIN_BOTTOM = 16.0
#: 本文の基準サイズ。
BASE_SIZE = 9.5
#: 行の高さ係数（サイズ × 係数）。
LINE_HEIGHT = 1.7
#: コードの文字サイズ。
CODE_SIZE = 8.5
#: 見出しサイズ（h1〜h6）。
HEADING_SIZES = {1: 20, 2: 16, 3: 13, 4: 11.5, 5: 10.2, 6: 9.5}

_FONT_RESOURCE = "resources/fonts/IPAexGothic.ttf"


class RenderError(Exception):
    """Markdown → PDF の明示エラー。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class PlaywrightUnavailable(Exception):
    """Playwright / Chromium がこの環境に無い。fpdf2 へ倒す合図。"""


def bundled_font_path() -> Path:
    """同梱フォントのパス。無ければ RenderError。"""
    try:
        from importlib.resources import files

        resource = files("mihari_room") / _FONT_RESOURCE
        return Path(resource)  # 通常はリポジトリ配下。zip 配布時は as_file 側も試す
    except Exception as exc:
        raise RenderError("missing_font", f"同梱フォントを開けない: {_FONT_RESOURCE}") from exc


@dataclass(frozen=True, slots=True)
class _TextToken:
    """フォールバック表示用の 1 文字列 token。"""

    type: str = "text"
    content: str = ""


def _inline_plain(tokens: list[Any] | None) -> str:
    """インライン token 列からプレーンテキストを作る（表セル・見出し用）。"""
    parts: list[str] = []
    for token in tokens or []:
        if token.type == "text":
            parts.append(token.content)
        elif token.type == "code_inline":
            parts.append(token.content)
        elif token.type == "image":
            parts.append("[画像]")
        elif token.type in ("softbreak", "hardbreak"):
            parts.append(" ")
    return "".join(parts).strip()


class _Layout:
    """fpdf2 にカーソル管理と折り返しを足した専用レイアウト。"""

    def __init__(self, pdf: Any, font_path: Path) -> None:
        self.pdf = pdf
        pdf.set_margins(MARGIN_LEFT, MARGIN_TOP, MARGIN_RIGHT)
        pdf.set_auto_page_break(auto=False)
        pdf.add_font("IPAex", "", str(font_path))
        pdf.add_page()
        self.page_w = float(pdf.w)
        self.page_h = float(pdf.h)
        self.body_w = self.page_w - MARGIN_LEFT - MARGIN_RIGHT
        self.y = MARGIN_TOP

    @property
    def bottom(self) -> float:
        return self.page_h - MARGIN_BOTTOM

    def measure(self, text: str, size: float) -> float:
        self.pdf.set_font("IPAex", "", size)
        return float(self.pdf.get_string_width(text))

    def wrap(self, text: str, size: float, max_width: float) -> list[str]:
        """文字単位で折り返す（CJK はスペース無しでも分割できる）。"""
        text = (text or "").replace("\n", " ")
        if not text:
            return [""]
        lines: list[str] = []
        current = ""
        current_w = 0.0
        for char in text:
            width = self.measure(char, size)
            if current and current_w + width > max_width:
                lines.append(current)
                current = char
                current_w = width
            else:
                current += char
                current_w += width
        if current:
            lines.append(current)
        return lines

    @staticmethod
    def line_height(size: float) -> float:
        return size * LINE_HEIGHT

    def ensure(self, needed: float) -> None:
        if self.y + needed > self.bottom:
            self.pdf.add_page()
            self.y = MARGIN_TOP

    def newline(self, size: float, extra: float = 0.0) -> None:
        height = self.line_height(size) + extra
        self.ensure(height)
        self.y += height


def _text_runs(tokens: list[Any] | None) -> list[tuple[str, str | None]]:
    """インライン token を (text, link_url) の列にする。"""
    runs: list[tuple[str, str | None]] = []
    link: str | None = None
    for token in tokens or []:
        if token.type == "text":
            runs.append((token.content, link))
        elif token.type == "code_inline":
            runs.append((token.content, link))
        elif token.type == "softbreak":
            runs.append((" ", link))
        elif token.type == "hardbreak":
            runs.append(("\n", link))
        elif token.type == "link_open":
            link = token.attrGet("href")
        elif token.type == "link_close":
            link = None
        elif token.type == "image":
            alt = token.content or "画像"
            runs.append((f"[画像: {alt}]", link))
    return runs


class _Document:
    """ブロック token 列を 1 ページずつ PDF に落とす。"""

    def __init__(self, pdf: Any, layout: _Layout) -> None:
        self.pdf = pdf
        self.layout = layout
        self.list_stack: list[bool] = []
        self.list_numbers: list[int] = []

    # -- テキスト行 ------------------------------------------------------

    def draw_runs(self, runs: list[tuple[str, str | None]], size: float) -> None:
        """(text, link) の列を折り返して描く。リンクは行ごとに注釈を張る。"""
        layout = self.layout
        pdf = self.pdf
        line_h = layout.line_height(size)
        pending: list[tuple[str, str | None]] = []
        pending_w = 0.0

        def flush() -> None:
            nonlocal pending, pending_w
            if not pending:
                return
            layout.ensure(line_h)
            x = MARGIN_LEFT
            for content, url in pending:
                width = layout.measure(content, size)
                pdf.set_xy(x, layout.y)
                pdf.cell(width, line_h, content)
                if url:
                    pdf.link(x, layout.y, width, line_h, url)
                x += width
            pending = []
            pending_w = 0.0
            layout.newline(size)

        for content, url in runs:
            if content == "\n":
                flush()
                layout.ensure(line_h)
                continue
            if not content:
                continue
            # 断片が長いときは文字単位で切る（URL・長いコードなど）。
            for piece in _split_to_fit(content, size, layout):
                width = layout.measure(piece, size)
                if pending and pending_w + width > layout.body_w:
                    flush()
                    width = layout.measure(piece, size)
                pending.append((piece, url))
                pending_w += width
        flush()

    # -- 段落 ----------------------------------------------------------

    def paragraph(self, tokens: list[Any]) -> None:
        self.draw_runs(_text_runs(tokens), BASE_SIZE)
        self.layout.newline(BASE_SIZE, extra=1.5)

    def placeholder(self, text: str) -> None:
        self.paragraph([_TextToken(content=text)])

    # -- 見出し --------------------------------------------------------

    def heading(self, level: int, tokens: list[Any]) -> None:
        layout = self.layout
        size = HEADING_SIZES.get(level, BASE_SIZE)
        line_h = layout.line_height(size)
        layout.ensure(line_h + 2)
        text = _inline_plain(tokens)
        pdf = self.pdf
        pdf.set_font("IPAex", "", size)
        for line in layout.wrap(text, size, layout.body_w):
            layout.ensure(line_h)
            pdf.set_xy(MARGIN_LEFT, layout.y)
            pdf.cell(layout.body_w, line_h, line)
            layout.newline(size)
        layout.newline(size, extra=2)

    # -- リスト --------------------------------------------------------

    def list_open(self, ordered: bool) -> None:
        self.list_stack.append(ordered)
        self.list_numbers.append(0)

    def list_item(self, tokens: list[Any]) -> None:
        layout = self.layout
        ordered = self.list_stack[-1] if self.list_stack else False
        if self.list_stack:
            self.list_numbers[-1] += 1
        number = self.list_numbers[-1] if self.list_stack else 0
        indent = 5.0 * len(self.list_stack)
        marker = f"{number}." if ordered else "•"
        marker_w = layout.measure(marker + "  ", BASE_SIZE)
        body_w = layout.body_w - indent - marker_w
        if body_w <= 0:
            body_w = layout.body_w
        wrapped = layout.wrap(_inline_plain(tokens), BASE_SIZE, body_w) or [""]
        for index, line in enumerate(wrapped):
            x = MARGIN_LEFT + indent
            layout.ensure(layout.line_height(BASE_SIZE))
            if index == 0:
                self.pdf.set_xy(x, layout.y)
                self.pdf.cell(marker_w, layout.line_height(BASE_SIZE), marker)
            x += marker_w
            self.pdf.set_xy(x, layout.y)
            self.pdf.cell(body_w, layout.line_height(BASE_SIZE), line)
            layout.newline(BASE_SIZE)
        layout.newline(BASE_SIZE, extra=0.5)

    def list_close(self) -> None:
        self.list_stack.pop(-1) if self.list_stack else None
        self.list_numbers.pop(-1) if self.list_numbers else None
        self.layout.newline(BASE_SIZE, extra=1.0)

    # -- 引用 ----------------------------------------------------------

    def blockquote(self, tokens: list[Any]) -> None:
        layout = self.layout
        text = _inline_plain(tokens)
        line_h = layout.line_height(BASE_SIZE)
        indent = 6.0
        body_w = layout.body_w - indent
        pdf = self.pdf
        first = True
        for line in layout.wrap(text, BASE_SIZE, body_w):
            layout.ensure(line_h)
            x = MARGIN_LEFT + indent
            pdf.set_xy(x, layout.y)
            pdf.cell(body_w, line_h, line)
            if first:
                pdf.set_xy(MARGIN_LEFT, layout.y)
                pdf.cell(1.2, line_h, "")
                first = False
            layout.newline(BASE_SIZE)
        layout.newline(BASE_SIZE, extra=1.5)

    # -- コード --------------------------------------------------------

    def code_block(self, text: str) -> None:
        layout = self.layout
        pdf = self.pdf
        lines: list[str] = []
        for raw in (text or "").rstrip("\n").split("\n"):
            lines.extend(layout.wrap(raw, CODE_SIZE, layout.body_w - 8) or [""])
        pad = 3.0
        line_h = layout.line_height(CODE_SIZE)
        block_h = len(lines) * line_h + pad * 2
        layout.ensure(block_h)
        pdf.set_fill_color(245, 245, 245)
        pdf.rect(MARGIN_LEFT, layout.y, layout.body_w, block_h, style="F")
        cursor_y = layout.y + pad
        pdf.set_font("IPAex", "", CODE_SIZE)
        for line in lines:
            pdf.set_xy(MARGIN_LEFT + 3, cursor_y)
            if line:
                pdf.cell(layout.body_w - 8, line_h, line)
            cursor_y += line_h
        layout.y = cursor_y + pad
        layout.newline(BASE_SIZE, extra=1.5)

    # -- 区切り線 ------------------------------------------------------

    def rule(self) -> None:
        layout = self.layout
        layout.ensure(2)
        pdf = self.pdf
        pdf.line(MARGIN_LEFT, layout.y + 1, self.page_w - MARGIN_RIGHT, layout.y + 1)
        layout.y += 4

    # -- 画像 ----------------------------------------------------------

    def image(self, token: Any, base_dir: Path | None) -> None:
        layout = self.layout
        src = token.attrGet("src") or ""
        alt = token.content or Path(src).name or "画像"
        if not src:
            layout.newline(BASE_SIZE)
            return
        if base_dir is not None and not Path(src).is_absolute():
            image_path = base_dir / src
        else:
            image_path = Path(src)
        if not image_path.is_file():
            self.placeholder(f"[画像が見つからない: {alt} ({src})]")
            return
        try:
            from PIL import Image

            with Image.open(image_path) as img:
                width, height = img.size
        except Exception as exc:
            logger.debug("PDF に画像を埋め込めない: %s", exc)
            self.placeholder(f"[画像を埋め込めない: {alt}]")
            return
        max_w = layout.body_w
        max_h = 90.0
        scale = min(max_w / max(width, 1), max_h / max(height, 1), 1.0)
        draw_w = max(1.0, width * scale)
        draw_h = max(1.0, height * scale)
        layout.ensure(draw_h)
        self.pdf.image(str(image_path), MARGIN_LEFT, layout.y, w=draw_w)
        layout.y += draw_h + 3

    # -- 表 ------------------------------------------------------------

    def table(self, tokens: list[Any]) -> None:
        """GFM 表を描く。セル内は折り返し、行ごとに改ページできる。"""
        layout = self.layout
        rows: list[list[str]] = []
        current: list[str] | None = None
        for token in tokens:
            if token.type == "tr_open":
                current = []
            elif token.type in ("th_open", "td_open") and current is not None:
                current.append("")
            elif token.type == "inline" and current is not None and current:
                current[-1] = _inline_plain(token.children)
            elif token.type == "tr_close" and current is not None:
                rows.append(current)
                current = None
        if not rows:
            return
        cell_size = 8.2
        line_h = layout.line_height(cell_size)
        pad = 1.6
        ncols = max(len(row) for row in rows)
        col_w = layout.body_w / max(ncols, 1)
        wrapped: list[list[list[str]]] = []
        for row in rows:
            cells: list[list[str]] = []
            for index in range(ncols):
                text = row[index] if index < len(row) else ""
                cells.append(layout.wrap(text, cell_size, max(col_w - pad * 2, 1)))
            wrapped.append(cells)
        row_heights = [max(len(cell) for cell in row) * line_h + pad * 2 for row in wrapped]
        for row_index, (row, height) in enumerate(zip(wrapped, row_heights, strict=True)):
            layout.ensure(height)
            y0 = layout.y
            if row_index == 0:
                self.pdf.set_fill_color(240, 240, 240)
            max_lines = max(len(cell) for cell in row)
            for line_index in range(max_lines):
                x = MARGIN_LEFT
                for cell in row:
                    line = cell[line_index] if line_index < len(cell) else ""
                    self.pdf.set_xy(x, layout.y)
                    self.pdf.cell(col_w, line_h, line, border=1)
                    x += col_w
                layout.newline(cell_size)
            if row_index == 0:
                self.pdf.set_fill_color(255, 255, 255)
            layout.y = y0 + height
        layout.newline(BASE_SIZE, extra=2)


def _split_to_fit(content: str, size: float, layout: _Layout) -> list[str]:
    """1 断片を 1 行に収まる単位へ文字で分割する（URL・長いコード用）。"""
    if layout.measure(content, size) <= layout.body_w:
        return [content]
    pieces: list[str] = []
    current = ""
    current_w = 0.0
    for char in content:
        width = layout.measure(char, size)
        if current and current_w + width > layout.body_w:
            pieces.append(current)
            current = char
            current_w = width
        else:
            current += char
            current_w += width
    if current:
        pieces.append(current)
    return pieces or [""]


def playwright_pdf_available() -> bool:
    """Chromium 印刷ができるか。結果はプロセス内でキャッシュする。"""
    global _playwright_available_cached
    if _playwright_available_cached is not None:
        return _playwright_available_cached
    try:
        from playwright.sync_api import sync_playwright

        with sync_playwright() as playwright:
            executable = playwright.chromium.executable_path
        _playwright_available_cached = bool(executable) and Path(executable).is_file()
    except Exception:
        _playwright_available_cached = False
    return _playwright_available_cached


def _wanted_engine() -> str:
    raw = (os.environ.get("MIHARI_PDF_ENGINE") or "auto").strip().lower()
    if raw in ("playwright", "fpdf2", "auto"):
        return raw
    return "auto"


def _render_playwright_pdf(
    markdown_text: str,
    out_path: Path,
    *,
    title: str | None = None,
    base_dir: Path | None = None,
) -> dict[str, Any]:
    """プレビュー HTML を Chromium の印刷で A4 PDF にする。"""
    from pypdf import PdfReader

    try:
        from playwright.sync_api import sync_playwright
    except ImportError as exc:
        raise PlaywrightUnavailable("playwright が入っていない") from exc

    html = render_to_page(markdown_text, title=title)
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    html_dir = Path(base_dir) if base_dir is not None else out.parent
    html_dir.mkdir(parents=True, exist_ok=True)
    html_file = html_dir / f".mihari-print-{uuid.uuid4().hex}.html"
    try:
        html_file.write_text(html, encoding="utf-8")
        try:
            playwright = sync_playwright().start()
        except Exception as exc:
            raise PlaywrightUnavailable(f"playwright を起動できない: {exc}") from exc
        browser = None
        try:
            try:
                browser = playwright.chromium.launch(args=list(_CHROMIUM_ARGS))
            except Exception as exc:
                raise PlaywrightUnavailable(f"Chromium を起動できない: {exc}") from exc
            page = browser.new_page()
            page.set_default_timeout(_PLAYWRIGHT_TIMEOUT_MS)
            # 生成した file:// だけを開く。ユーザー指定の URL は辿らない。
            page.goto(html_file.resolve().as_uri(), wait_until="load")
            page.emulate_media(media="print")
            page.pdf(
                path=str(out),
                format="A4",
                print_background=True,
                margin={
                    "top": "16mm",
                    "bottom": "16mm",
                    "left": "16mm",
                    "right": "16mm",
                },
            )
        finally:
            try:
                if browser is not None:
                    browser.close()
            finally:
                playwright.stop()
    finally:
        html_file.unlink(missing_ok=True)

    if not out.is_file() or out.stat().st_size == 0:
        raise RenderError("pdf_failed", "Playwright が空の PDF を返した")
    pages = len(PdfReader(str(out)).pages)
    return {
        "pages": pages,
        "path": str(out),
        "size_bytes": out.stat().st_size,
        "engine": "playwright",
    }


def render_markdown_pdf(
    markdown_text: str,
    out_path: Path,
    *,
    title: str | None = None,
    base_dir: Path | None = None,
    font_path: Path | None = None,
) -> dict[str, Any]:
    """Markdown を PDF に変換する。戻り値はページ数と書き出し先。"""
    wanted = _wanted_engine()
    if wanted != "fpdf2":
        try:
            return _render_playwright_pdf(
                markdown_text,
                out_path,
                title=title,
                base_dir=base_dir,
            )
        except PlaywrightUnavailable as exc:
            if wanted == "playwright":
                raise RenderError("missing_playwright", str(exc)) from exc
            logger.info("Playwright PDF を使えないため fpdf2 に倒す: %s", exc)
        except Exception as exc:
            if wanted == "playwright":
                raise
            logger.warning("Playwright PDF が失敗したため fpdf2 に倒す: %s", exc)
    return _render_fpdf2(
        markdown_text,
        out_path,
        title=title,
        base_dir=base_dir,
        font_path=font_path,
    )


def _render_fpdf2(
    markdown_text: str,
    out_path: Path,
    *,
    title: str | None = None,
    base_dir: Path | None = None,
    font_path: Path | None = None,
) -> dict[str, Any]:
    """同梱フォントの fpdf2 レイアウト。Playwright が無いときの控え。"""
    from fpdf import FPDF

    font = Path(font_path) if font_path is not None else bundled_font_path()
    if not font.is_file():
        raise RenderError("missing_font", f"フォントが無い: {font}")
    pdf = FPDF(format="A4", unit="mm")
    pdf.set_title(title or "Markdown")
    layout = _Layout(pdf, font)
    document = _Document(pdf, layout)
    tokens = markdown_renderer().parse(markdown_text or "")
    base = Path(base_dir) if base_dir is not None else None

    index = 0
    while index < len(tokens):
        token = tokens[index]
        ttype = token.type
        if ttype == "inline":
            parent = tokens[index - 1].type if index > 0 else ""
            if parent == "paragraph_open":
                document.paragraph(token.children or [])
        elif ttype == "heading_open":
            level = int(token.tag[1]) if token.tag and token.tag[0] == "h" else 2
            body = tokens[index + 1] if index + 1 < len(tokens) else None
            document.heading(level, (body.children if body is not None else []) or [])
            index += 1
        elif ttype == "bullet_list_open":
            document.list_open(False)
        elif ttype == "ordered_list_open":
            document.list_open(True)
        elif ttype == "list_item_open":
            body = tokens[index + 1] if index + 1 < len(tokens) else None
            if body is not None and body.type == "inline":
                document.list_item(body.children or [])
                index += 1
        elif ttype in ("bullet_list_close", "ordered_list_close"):
            document.list_close()
        elif ttype in ("fence", "code_block"):
            document.code_block(token.content or "")
        elif ttype == "blockquote_open":
            body = tokens[index + 1] if index + 1 < len(tokens) else None
            if body is not None and body.type == "inline":
                document.blockquote(body.children or [])
                index += 1
        elif ttype == "table_open":
            end = index + 1
            while end < len(tokens) and tokens[end].type != "table_close":
                end += 1
            document.table(tokens[index : end + 1])
            index = end
        elif ttype == "hr":
            document.rule()
        elif ttype == "image":
            document.image(token, base)
        index += 1

    if not pdf.pages:
        pdf.add_page()
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    pdf.output(str(out))
    return {
        "pages": len(pdf.pages),
        "path": str(out),
        "size_bytes": out.stat().st_size,
        "engine": "fpdf2",
    }


def convert_markdown_file(
    md_path: Path,
    out_pdf_path: Path,
    *,
    title: str | None = None,
    font_path: Path | None = None,
) -> dict[str, Any]:
    """``.md`` ファイルを PDF にする。画像は md と同じフォルダ基準で探す。"""
    source = Path(md_path)
    if not source.is_file():
        raise RenderError("missing_file", f"Markdown が無い: {source}")
    text = source.read_text(encoding="utf-8")
    return render_markdown_pdf(
        text,
        out_pdf_path,
        title=title or source.stem,
        base_dir=source.parent,
        font_path=font_path,
    )
