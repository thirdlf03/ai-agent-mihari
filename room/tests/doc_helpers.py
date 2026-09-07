"""文書ツールのテスト用ヘルパー。外部ファイル・実ネットワークは使わない。

- ASCII の素の PDF（pypdf が書ける Type1 Helvetica）
- ページ数を指定できる複数ページ PDF
- 暗号化・破損・ページ数超過の PDF
- 日本語 PDF は同梱レンダラー（markdown_pdf）で作れば確実に本文が読める
"""

from __future__ import annotations

import io
from pathlib import Path
from typing import Any

from pypdf import PdfWriter
from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject

PAGE_W = 612
PAGE_H = 792


def _new_page(writer: PdfWriter) -> Any:
    page = writer.add_blank_page(width=PAGE_W, height=PAGE_H)
    fonts = DictionaryObject()
    font = DictionaryObject(
        {
            NameObject("/Type"): NameObject("/Font"),
            NameObject("/Subtype"): NameObject("/Type1"),
            NameObject("/BaseFont"): NameObject("/Helvetica"),
        }
    )
    fonts[NameObject("/F1")] = font
    page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): fonts})
    return page


def pdf_bytes(page_texts: list[str]) -> bytes:
    """1 ページ 1 テキストの本物の PDF。ASCII だけで書くこと。"""
    writer = PdfWriter()
    for text in page_texts:
        page = _new_page(writer)
        stream = DecodedStreamObject()
        stream.set_data(f"BT /F1 12 Tf 72 720 Td ({text}) Tj ET".encode("latin-1"))
        page[NameObject("/Contents")] = writer._add_object(stream)
    buffer = io.BytesIO()
    writer.write(buffer)
    return buffer.getvalue()


def write_pdf(path: Path, page_texts: list[str]) -> Path:
    path.write_bytes(pdf_bytes(page_texts))
    return path


def many_page_pdf_bytes(page_count: int) -> bytes:
    """テキスト無しの指定ページ数の PDF。上限超過の検証用。"""
    writer = PdfWriter()
    for _ in range(page_count):
        writer.add_blank_page(width=PAGE_W, height=PAGE_H)
    buffer = io.BytesIO()
    writer.write(buffer)
    return buffer.getvalue()


def encrypted_pdf_bytes(page_text: str = "secret contents") -> bytes:
    """パスワード付きで暗号化した PDF。"""
    writer = PdfWriter()
    page = _new_page(writer)
    stream = DecodedStreamObject()
    stream.set_data(f"BT /F1 12 Tf 72 720 Td ({page_text}) Tj ET".encode("latin-1"))
    page[NameObject("/Contents")] = writer._add_object(stream)
    writer.encrypt(user_password="hunter2")
    buffer = io.BytesIO()
    writer.write(buffer)
    return buffer.getvalue()


def corrupt_pdf_bytes() -> bytes:
    """破損した PDF 風バイト列。"""
    return b"%PDF-1.4\n1 0 obj\n<< broken garbage <<<"
