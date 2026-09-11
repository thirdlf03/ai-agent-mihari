"""資料（PDF・Markdown）の読み取り・変換ライブラリ。

Hermes の in-process ツール（``mihari_room.worker.doc_tools``）から使う。
入力は既存 ``pypdf``、ページ画像化は Poppler（``pdftoppm``）、OCR は
Tesseract（日本語・英語）、Markdown 表示は同梱の markdown-it-py、
Markdown→PDF はプレビュー HTML の Chromium 印刷（無ければ同梱フォントの fpdf2）で行う。
"""
