"""Markdown の表示用 HTML 化。同梱の markdown-it-py を使う。

- 表・コード・画像・出典リンクに対応する（gfm-like プリセット）
- 生 HTML は無効（``html=False``）。CDN や外部 CSS・JS は使わない
- 出力は 1 枚の自己完結 HTML。画像は相対パスのまま残す（プレビュー配信と同じ場所で読む）
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

#: 埋め込み CSS。外部ファイル・フォントは参照しない。
_STYLE = """
:root { color-scheme: light dark; }
body { font-family: -apple-system, "Hiragino Sans", "Hiragino Kaku Gothic ProN",
       "Noto Sans CJK JP", "Noto Sans JP", "IPAGothic", "IPAexGothic", sans-serif;
       line-height: 1.7; margin: 0 auto; max-width: 46em; padding: 2em 1.5em;
       color: #222; background: #fff; }
@media (prefers-color-scheme: dark) {
  body { color: #ddd; background: #121212; }
  pre, table { background: #1e1e1e; }
}
h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin-top: 1.6em; }
h1 { border-bottom: 1px solid #ccc; padding-bottom: .2em; }
a { color: #065fb8; }
pre { background: #f5f5f5; padding: .8em 1em; overflow-x: auto; border-radius: 6px; }
code { font-family: ui-monospace, "SF Mono", Menlo, "Noto Sans Mono CJK JP", monospace; }
pre code { background: transparent; padding: 0; }
table { border-collapse: collapse; margin: 1em 0; width: 100%; }
th, td { border: 1px solid #bbb; padding: .4em .7em; text-align: left; }
th { background: #f0f0f0; }
img { max-width: 100%; height: auto; }
blockquote { border-left: 4px solid #ccc; margin: 1em 0; padding: 0 1em; color: #555; }
hr { border: 0; border-top: 1px solid #ccc; margin: 2em 0; }
@media print {
  :root { color-scheme: light; }
  body {
    color: #222;
    background: #fff;
    max-width: none;
    margin: 0;
    padding: 0;
    font-family: "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Noto Sans CJK JP",
                 "Noto Sans JP", "IPAGothic", "IPAexGothic", sans-serif;
  }
  pre, table { background: #f5f5f5; }
  pre { white-space: pre-wrap; overflow: visible; }
  a { color: #065fb8; }
}
"""


def markdown_renderer(*, html: bool = False) -> Any:
    """生 HTML を無効にし、自動リンク化（linkify）を止めた markdown-it。"""
    from markdown_it import MarkdownIt

    return MarkdownIt("gfm-like", {"html": html}).disable("linkify")


def render_to_fragment(markdown_text: str, *, html: bool = False) -> str:
    """Markdown 本文を HTML 断片に変換する。生 HTML はエスケープされる。"""
    renderer = markdown_renderer(html=html)
    return renderer.render(markdown_text or "")


def render_to_page(
    markdown_text: str,
    *,
    title: str | None = None,
    html: bool = False,
) -> str:
    """Markdown を 1 枚の自己完結 HTML ページにする。"""
    body = render_to_fragment(markdown_text, html=html)
    heading = title or "Markdown"
    escaped_title = heading.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return f"""<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escaped_title}</title>
<style>{_STYLE}</style>
</head>
<body>
{body}
</body>
</html>
"""


def convert_file(md_path: Path, out_html_path: Path, *, html: bool = False) -> Path:
    """``.md`` ファイルを ``.html`` に書き出す。HTML が無効でも書ける。"""
    source = Path(md_path)
    if not source.is_file():
        raise FileNotFoundError(f"Markdown が無い: {source}")
    text = source.read_text(encoding="utf-8")
    page = render_to_page(text, title=source.stem, html=html)
    out = Path(out_html_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page, encoding="utf-8")
    return out
