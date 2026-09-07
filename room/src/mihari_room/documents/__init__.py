"""資料（PDF・Markdown）の読み取り・変換ライブラリ。

Hermes の in-process ツール（``mihari_room.worker.doc_tools``）から使う。
入力は既存 ``pypdf``、ページ画像化は Poppler（``pdftoppm``）、OCR は
Tesseract（日本語・英語）、Markdown 表示は同梱の markdown-it-py、
Markdown→PDF は同梱フォントを使う専用レンダラーで行う。
"""
