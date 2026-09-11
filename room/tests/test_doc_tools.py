"""Room 専用文書ツール（PDF・Markdown）のテスト。

受け入れに対応する検証:

- 日本語 PDF（同梱レンダラーで作った実 PDF）・ページ単位テキスト・範囲指定
- スキャン PDF 相当（テキスト無しページ → ページ画像化 → OCR 呼び出し固定引数）
- 表・コード・リンクを含む Markdown の表示 HTML・PDF 出力（文字化け・欠けの自動検証）
- 暗号化・破損・100 ページ超過・120 秒上限の明示エラー
- 部分処理を全件処理と偽らない（partial / truncated を明示）

PDF の見た目（欠け・重なり）は自動では判定できないので、テストコメントに
目視確認の手順を残している（pdftoppm でページ画像を作って確認する）。
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

import pytest

from mihari_room.contracts import CreateJobRequest, JobSource
from mihari_room.documents import ocr as ocr_mod
from mihari_room.documents.markdown_render import render_to_fragment, render_to_page
from mihari_room.documents.pdf_gen import bundled_font_path, playwright_pdf_available
from mihari_room.documents.pdf_reader import extract_pdf_text
from mihari_room.documents.pdf_render import poppler_bin
from mihari_room.fakes import InMemoryJobStore
from mihari_room.worker.doc_tools import (
    _SCHEMAS,
    TOOL_NAMES,
    _make_handlers,
    markdown_pdf_impl,
    pdf_info_impl,
    pdf_ocr_impl,
    pdf_pages_impl,
    pdf_text_impl,
    register_doc_tools,
)
from tests import doc_helpers

MARKDOWN_SAMPLE = """# 資料タイトル

日本語の段落です。表・コード・リンクを含むサンプル。

- 箇条書きの甲
- 箇条書きの乙

| 項目 | 説明 |
|---|---|
| PDF 抽出 | pypdf ページ単位 |
| OCR | tesseract jpn+eng |

```python
print("hello")
```

[出典リンク](https://example.com/source)
"""


def _can_render_markdown_pdf() -> bool:
    """Playwright の Chromium か、同梱フォントの fpdf2 のどちらかがあれば PDF を書ける。"""
    if playwright_pdf_available():
        return True
    try:
        return bundled_font_path().is_file()
    except Exception:
        return False


def _make_job(tmp_path: Path) -> Any:
    store = InMemoryJobStore(tmp_path)
    return store.create(CreateJobRequest(title="t", body="b", source=JobSource.PET))


def _input_pdf(job: Any, name: str = "doc.pdf", page_texts: list[str] | None = None) -> Path:
    target = job.directory / "input" / name
    target.write_bytes(doc_helpers.pdf_bytes(page_texts or ["page one", "page two", "page three"]))
    return target


# -- pdf_info -------------------------------------------------------------


def test_pdf_info_reports_pages_and_filename(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    _input_pdf(job)
    payload = json.loads(pdf_info_impl(job, "input/doc.pdf"))
    assert payload["success"] is True
    assert payload["filename"] == "doc.pdf"
    assert payload["page_count"] == 3
    assert payload["is_encrypted"] is False
    assert payload["max_pages"] == 100


def test_pdf_info_encrypted_is_explicit(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    (job.directory / "input" / "secret.pdf").write_bytes(doc_helpers.encrypted_pdf_bytes())
    payload = json.loads(pdf_info_impl(job, "input/secret.pdf"))
    assert payload["success"] is False
    assert payload["code"] == "encrypted"


def test_pdf_info_corrupt_and_missing(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    (job.directory / "input" / "broken.pdf").write_bytes(doc_helpers.corrupt_pdf_bytes())
    assert json.loads(pdf_info_impl(job, "input/broken.pdf"))["code"] == "corrupt"
    assert json.loads(pdf_info_impl(job, "input/nope.pdf"))["code"] == "missing_file"


# -- pdf_text -------------------------------------------------------------


def test_pdf_text_page_numbers_and_filename(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    _input_pdf(job)
    payload = json.loads(pdf_text_impl(job, "input/doc.pdf"))
    assert payload["success"] is True
    assert payload["filename"] == "doc.pdf"
    assert [page["page"] for page in payload["pages"]] == [1, 2, 3]
    assert payload["pages"][0]["text"] == "page one"
    assert payload["partial"] is False
    assert payload["truncated"] is False


def test_pdf_text_range_is_explicitly_partial(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    _input_pdf(job)
    payload = json.loads(pdf_text_impl(job, "input/doc.pdf", 2, 2))
    assert payload["success"] is True
    assert payload["requested_pages"] == 1
    assert payload["pages"][0]["page"] == 2
    # 全体 3 ページのうち 1 ページだけ → partial を明示する（全件処理と偽らない）。
    assert payload["partial"] is True


def test_pdf_text_100_page_limit_is_explicit(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    (job.directory / "input" / "big.pdf").write_bytes(doc_helpers.many_page_pdf_bytes(101))
    payload = json.loads(pdf_text_impl(job, "input/big.pdf"))
    assert payload["success"] is False
    assert payload["code"] == "too_many_pages"
    assert "100" in payload["error"]
    # 範囲を指定すれば 100 ページ以内の分割読みはできる（partial を明示）。
    ok = json.loads(pdf_text_impl(job, "input/big.pdf", 1, 5))
    assert ok["success"] is True
    assert ok["requested_pages"] == 5
    assert ok["partial"] is True


def test_pdf_text_encrypted_corrupt_and_timeout(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    (job.directory / "input" / "secret.pdf").write_bytes(doc_helpers.encrypted_pdf_bytes())
    assert json.loads(pdf_text_impl(job, "input/secret.pdf"))["code"] == "encrypted"
    (job.directory / "input" / "broken.pdf").write_bytes(doc_helpers.corrupt_pdf_bytes())
    assert json.loads(pdf_text_impl(job, "input/broken.pdf"))["code"] == "corrupt"
    # 図書館側の上限は直接呼んで検証する（ツールは 120 秒固定）。
    pdf = _input_pdf(job)
    with pytest.raises(Exception) as exc:
        extract_pdf_text(pdf, max_process_seconds=0.0)
    assert getattr(exc.value, "code", "") == "processing_timeout"


def test_pdf_text_truncation_is_reported(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    pdf = _input_pdf(job, page_texts=["x" * 5000])
    result = extract_pdf_text(pdf, per_page_chars=100, total_chars=10_000)
    assert result["truncated"] is True
    assert any("切り詰め" in note for note in result["notes"])
    assert len(result["pages"][0]["text"]) == 100


def test_tool_rejects_paths_outside_job(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    _input_pdf(job)
    outside = tmp_path / "outside.pdf"
    outside.write_bytes(doc_helpers.pdf_bytes(["x"]))
    assert (
        json.loads(pdf_text_impl(job, str(outside)))["code"] == "invalid_path"
        or json.loads(pdf_text_impl(job, str(outside)))["code"] == "invalid_path"
    )
    payload = json.loads(pdf_text_impl(job, "/etc/passwd"))
    assert payload["code"] == "invalid_path"
    traversal = json.loads(pdf_text_impl(job, "input/../input/doc.pdf"))
    assert traversal["code"] == "invalid_path"


# -- pdf_pages（Poppler） -------------------------------------------------


@pytest.mark.skipif(poppler_bin() is None, reason="Poppler が無い環境ではスキップ")
def test_pdf_pages_renders_numbered_pngs(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    _input_pdf(job)
    payload = json.loads(pdf_pages_impl(job, "input/doc.pdf"))
    assert payload["success"] is True, payload
    assert payload["filename"] == "doc.pdf"
    assert [image["page"] for image in payload["images"]] == [1, 2, 3]
    for image in payload["images"]:
        path = Path(job.directory) / image["path"]
        assert path.is_file()
        assert path.suffix == ".png"
        assert image["width"] > 0 and image["height"] > 0
    assert payload["partial"] is False


@pytest.mark.skipif(poppler_bin() is None, reason="Poppler が無い環境ではスキップ")
def test_pdf_pages_range_and_dpi(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    _input_pdf(job)
    payload = json.loads(pdf_pages_impl(job, "input/doc.pdf", 2, 2, 72))
    assert payload["success"] is True
    assert [image["page"] for image in payload["images"]] == [2]
    assert payload["partial"] is True
    bad = json.loads(pdf_pages_impl(job, "input/doc.pdf", 1, 3, 999))
    assert bad["success"] is False
    assert bad["code"] == "invalid_dpi"


@pytest.mark.skipif(poppler_bin() is None, reason="Poppler が無い環境ではスキップ")
def test_pdf_pages_encrypted_is_explicit(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    (job.directory / "input" / "secret.pdf").write_bytes(doc_helpers.encrypted_pdf_bytes())
    payload = json.loads(pdf_pages_impl(job, "input/secret.pdf"))
    assert payload["success"] is False
    assert payload["code"] == "encrypted"


def test_pdf_pages_missing_poppler(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    import mihari_room.documents.pdf_render as pdf_render

    monkeypatch.setattr(pdf_render, "poppler_bin", lambda: None)
    job = _make_job(tmp_path)
    _input_pdf(job)
    payload = json.loads(pdf_pages_impl(job, "input/doc.pdf"))
    assert payload["success"] is False
    assert payload["code"] == "missing_poppler"


def test_pdf_pages_timeout_is_explicit(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    pdf = _input_pdf(job)

    def exploding(argv: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
        raise subprocess.TimeoutExpired(argv[0], timeout)

    from mihari_room.documents.pdf_render import render_pages

    with pytest.raises(Exception) as exc:
        render_pages(pdf, job.directory / "research", first_page=1, last_page=1, runner=exploding)
    assert getattr(exc.value, "code", "") == "processing_timeout"


# -- pdf_ocr（Tesseract） -------------------------------------------------


def test_pdf_ocr_missing_tesseract(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    import mihari_room.documents.ocr as ocr_mod2

    monkeypatch.setattr(ocr_mod2, "tesseract_bin", lambda: None)
    job = _make_job(tmp_path)
    image = job.directory / "research" / "page-0001.png"
    image.parent.mkdir(parents=True, exist_ok=True)
    image.write_bytes(b"x")
    payload = json.loads(pdf_ocr_impl(job, "research/page-0001.png"))
    assert payload["success"] is False
    assert payload["code"] == "missing_tesseract"


def test_pdf_ocr_missing_image_and_bad_lang(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    assert json.loads(pdf_ocr_impl(job, "research/nope.png"))["code"] == "missing_file"
    image = job.directory / "research" / "page-0001.png"
    image.parent.mkdir(parents=True, exist_ok=True)
    image.write_bytes(b"x")
    payload = json.loads(pdf_ocr_impl(job, "research/page-0001.png", "eng; rm -rf /"))
    assert payload["success"] is False
    assert payload["code"] == "invalid_lang"


def test_ocr_page_number_from_filename() -> None:
    assert ocr_mod.page_number_from_name("page-0003.png") == 3
    assert ocr_mod.page_number_from_name("slide-42.png") == 42
    assert ocr_mod.page_number_from_name("cover.png") is None
    assert ocr_mod.page_number_from_name("page-0003") == 3


def test_ocr_impl_runs_tesseract_with_fixed_args(tmp_path: Path) -> None:
    """固定引数（tesseract <img> stdout -l jpn+eng --psm 3）で呼ぶことの検証。"""
    captured: dict[str, Any] = {}

    def fake_tesseract(argv: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
        captured["argv"] = argv
        return subprocess.CompletedProcess(argv, 0, stdout="detected text", stderr="")

    import mihari_room.documents.ocr as ocr_mod2

    image = tmp_path / "page-7.png"
    image.write_bytes(b"x")
    result = ocr_mod2.ocr_image(image, runner=fake_tesseract)
    assert captured["argv"] == ["tesseract", str(image), "stdout", "-l", "jpn+eng", "--psm", "3"]
    assert result["page"] == 7
    assert result["text"] == "detected text"


def test_ocr_failure_is_explicit(tmp_path: Path) -> None:
    def failing(argv: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr="Failed opening file")

    import mihari_room.documents.ocr as ocr_mod2

    image = tmp_path / "page-1.png"
    image.write_bytes(b"x")
    with pytest.raises(Exception) as exc:
        ocr_mod2.ocr_image(image, runner=failing)
    assert getattr(exc.value, "code", "") == "ocr_failed"


def _tesseract_available_with_jpn() -> bool:
    """本物の Tesseract（jpn+eng 言語データ込み）があるか。"""
    binary = ocr_mod.tesseract_bin()
    if binary is None:
        return False
    try:
        done = subprocess.run(  # noqa: S603 - 固定バイナリの一覧取得のみ
            [binary, "--list-langs"], capture_output=True, text=True, timeout=30, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    langs = (done.stdout or "") + (done.stderr or "")
    return "jpn" in langs and "eng" in langs


@pytest.mark.skipif(
    not _tesseract_available_with_jpn(),
    reason="本物の Tesseract（jpn+eng）が無い環境ではスキップ（CI は fake runner で検証済み）",
)
def test_scanned_pdf_pages_to_ocr_end_to_end(tmp_path: Path) -> None:
    """スキャン PDF（テキスト層の無い画像 PDF）のページ化→OCR を実バイナリで通す。

    目視確認（自動ではできない）::

        スキャン PDF のページ画像（pdf_pages の出力）を開き、文字が読めることを確認する。
    """
    from PIL import Image, ImageDraw, ImageFont

    from mihari_room.documents.pdf_gen import bundled_font_path

    # 1. 日本語テキストを描いた「スキャン風」画像を作る。
    font_path = bundled_font_path()
    image = Image.new("RGB", (900, 300), "white")
    draw = ImageDraw.Draw(image)
    draw.text(
        (60, 100),
        "みはりちゃんのスキャン資料",
        font=ImageFont.truetype(str(font_path), 64),
        fill="black",
    )
    image_path = tmp_path / "scan_sheet.png"
    image.save(image_path)

    # 2. 画像だけの 1 ページ PDF（テキスト層なし = スキャン相当）を作る。
    from fpdf import FPDF

    pdf_file = tmp_path / "scanned.pdf"
    pdf = FPDF(unit="mm", format="A4")
    pdf.add_page()
    pdf.image(str(image_path), x=30, y=90, w=150)
    pdf.output(str(pdf_file))
    from pypdf import PdfReader

    assert (PdfReader(str(pdf_file)).pages[0].extract_text() or "").strip() == ""

    # 3. ページ画像化 → OCR。
    job = _make_job(tmp_path)
    (job.directory / "input").mkdir(parents=True, exist_ok=True)
    (job.directory / "input" / "scanned.pdf").write_bytes(pdf_file.read_bytes())
    pages = json.loads(pdf_pages_impl(job, "input/scanned.pdf"))
    assert pages["success"] is True
    image_result = pages["images"][0]
    assert image_result["page"] == 1
    ocr_result = json.loads(pdf_ocr_impl(job, image_result["path"]))
    assert ocr_result["success"] is True
    assert ocr_result["page"] == 1
    assert "みはり" in ocr_result["text"]


# -- markdown → PDF（プレビュー HTML の印刷、無ければ fpdf2） -------------


@pytest.mark.skipif(not _can_render_markdown_pdf(), reason="Playwright も同梱フォントも無い")
def test_markdown_pdf_roundtrip_japanese_without_mojibake(tmp_path: Path) -> None:
    """日本語 PDF 出力の文字化け・欠けを自動検証する。

    目視確認（自動ではできない）::

        pdftoppm -png -r 100 output/report.pdf /tmp/report-page
        # ページ画像を開き、見出し・表・コード・リンクの文字が欠けていないか見る。
        文字化け（豆腐・ひらがなが化ける）が無いこと。

    pypdf で全文を読み戻して、元の Markdown の本文がそのまま出ることを検査する。
    """
    job = _make_job(tmp_path)
    md = job.directory / "output" / "report.md"
    md.parent.mkdir(parents=True, exist_ok=True)
    md.write_text(MARKDOWN_SAMPLE, encoding="utf-8")
    payload = json.loads(markdown_pdf_impl(job, "output/report.md"))
    assert payload["success"] is True, payload
    assert payload["engine"] in ("playwright", "fpdf2")
    pdf_path = Path(job.directory) / payload["path"]
    assert pdf_path.name == "report.pdf"
    assert pdf_path.is_file()

    from pypdf import PdfReader

    reader = PdfReader(str(pdf_path))
    text = "\n".join((page.extract_text() or "") for page in reader.pages)
    for expect in (
        "資料タイトル",
        "日本語の段落です",
        "PDF 抽出",
        "pypdf ページ単位",
        "print",
        "出典リンク",
    ):
        assert expect in text, f"PDF に {expect!r} が欠けている:\n{text}"
    if payload["engine"] == "playwright":
        for expect in ("箇条書きの甲", "箇条書きの乙"):
            assert expect in text, f"Playwright PDF に {expect!r} が欠けている:\n{text}"
    # 置換文字・豆腐の目印（U+FFFD）が出ないこと。
    assert "\ufffd" not in text

    # 同じ PDF を pdf_text（ページ単位抽出）の入力にしても日本語が読める。
    (job.directory / "input").mkdir(parents=True, exist_ok=True)
    (job.directory / "input" / "資料.pdf").write_bytes(pdf_path.read_bytes())
    extracted = json.loads(pdf_text_impl(job, "input/資料.pdf"))
    assert extracted["success"] is True
    page_text = "\n".join(page["text"] for page in extracted["pages"])
    assert "資料タイトル" in page_text and "pypdf ページ単位" in page_text

    # ページ画像化して黒インクがあるか（描画欠けの自動プロキシ。目視は上のコメント）。
    if poppler_bin() is not None:
        rendered = json.loads(pdf_pages_impl(job, "input/資料.pdf", 1, 1, 100))
        assert rendered["success"] is True

        from PIL import Image

        page_image = Path(job.directory) / rendered["images"][0]["path"]
        with Image.open(page_image) as img:
            pixels = img.convert("L")
            dark = sum(
                1
                for y in range(0, pixels.height, 3)
                for x in range(0, pixels.width, 3)
                if pixels.getpixel((x, y)) < 128
            )
        assert dark > 100, "ページ画像に文字のインクがほぼ無い（描画欠けの可能性）"


@pytest.mark.skipif(not _can_render_markdown_pdf(), reason="Playwright も同梱フォントも無い")
def test_markdown_pdf_to_named_output_and_errors(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    md = job.directory / "output" / "report.md"
    md.parent.mkdir(parents=True, exist_ok=True)
    md.write_text("## 見出し\n\n本文\n", encoding="utf-8")
    payload = json.loads(markdown_pdf_impl(job, "output/report.md", "output/書類.pdf"))
    assert payload["success"] is True
    assert payload["path"].endswith("書類.pdf")
    assert (Path(job.directory) / payload["path"]).is_file()
    # 存在しない md
    missing = json.loads(markdown_pdf_impl(job, "output/nope.md"))
    assert missing["code"] == "missing_file"
    # md 以外は拒否
    txt = job.directory / "output" / "note.txt"
    txt.write_text("x", encoding="utf-8")
    wrong = json.loads(markdown_pdf_impl(job, "output/note.txt"))
    assert wrong["code"] == "not_markdown"
    # ジョブ外への書き込みは拒否
    outside = json.loads(markdown_pdf_impl(job, "output/report.md", "/tmp/evil.pdf"))
    assert outside["success"] is False


def test_markdown_pdf_outside_job_input_is_rejected(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    payload = json.loads(markdown_pdf_impl(job, "input/doc.pdf"))
    assert payload["code"] == "not_markdown"


# -- Markdown 表示（同梱 markdown-it、生 HTML 無効・CDN なし） --------------


def test_markdown_render_tables_code_links_images() -> None:
    fragment = render_to_fragment(MARKDOWN_SAMPLE)
    assert "<table>" in fragment and "項目" in fragment
    assert "<pre><code" in fragment
    assert '<a href="https://example.com/source">出典リンク</a>' in fragment
    assert "<img" not in fragment  # このサンプルには画像が無い
    assert "<ul>" in fragment and "箇条書きの甲" in fragment


def test_markdown_render_disables_raw_html_and_cdn() -> None:
    page = render_to_page(
        "# タイトル\n\n<script>alert(1)</script> と <b>太字</b> と [リンク](https://example.com/a)\n"
    )
    assert "<script>" not in page
    assert "&lt;script&gt;" in page
    assert "<b>太字</b>" not in page
    # 外部参照（CDN・フォント・JS）を出さない。リンク href は本文の出典だけ。
    assert "cdn" not in page.lower()
    assert "http://" not in page
    assert "https://fonts" not in page
    assert "example.com/a" in page
    assert "@media print" in page


def test_markdown_render_image_with_relative_src(tmp_path: Path) -> None:
    (tmp_path / "fig.png").write_bytes(b"fakepng")
    fragment = render_to_fragment("![図](fig.png)")
    assert '<img src="fig.png" alt="図"' in fragment


# -- handlers と registry --------------------------------------------------


def test_handlers_accept_hermes_positional_args_dict(tmp_path: Path) -> None:
    job = _make_job(tmp_path)
    _input_pdf(job)
    info = _make_handlers(job)["pdf_info"]
    payload = json.loads(info({"path": "input/doc.pdf"}))
    assert payload["success"] is True
    assert payload["page_count"] == 3
    text = _make_handlers(job)["pdf_text"]
    payload = json.loads(text({"path": "input/doc.pdf", "first_page": 1, "last_page": 2}))
    assert payload["requested_pages"] == 2
    # kwargs だけでも同じ。
    payload = json.loads(_make_handlers(job)["pdf_text"](path="input/doc.pdf"))
    assert payload["requested_pages"] == 3


def test_tool_names_and_schemas_match_registry() -> None:
    assert set(_SCHEMAS) == set(TOOL_NAMES)
    assert set(TOOL_NAMES) == {"pdf_info", "pdf_text", "pdf_pages", "pdf_ocr", "markdown_pdf"}
    for name, schema in _SCHEMAS.items():
        assert schema["function"]["name"] == name
        assert schema["function"]["parameters"]["type"] == "object"


def test_register_against_real_registry(tmp_path: Path) -> None:
    """実 Hermes registry への登録・取下げ（無ければスキップ）。"""
    import sys

    pinned = "/Users/thirdlf03/.hermes/hermes-agent"
    inserted = False
    if pinned not in sys.path:
        sys.path.insert(0, pinned)
        inserted = True
    try:
        from tools.registry import registry
    except ImportError:
        pytest.skip("Hermes source not importable here")
    finally:
        if inserted:
            try:
                sys.path.remove(pinned)
            except ValueError:
                pass
    job = _make_job(tmp_path)
    restore = register_doc_tools(job)
    assert restore is not None
    try:
        mapping = registry.get_tool_to_toolset() if hasattr(registry, "get_tool_to_toolset") else {}
        if mapping:
            for name in TOOL_NAMES:
                assert mapping.get(name) == "mihari_room", f"{name} が mihari_room に無い"
    finally:
        restore()
    mapping = registry.get_tool_to_toolset() if hasattr(registry, "get_tool_to_toolset") else {}
    if mapping:
        for name in TOOL_NAMES:
            assert name not in mapping
