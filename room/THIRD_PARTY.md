# Third-party notices

`room/src/mihari_room/worker/` の in-process 起動と進捗整形は、
[Hermes Agent](https://github.com/NousResearch/hermes-agent) の実装を参考にしている。

Hermes Agent is licensed under the MIT License.

```
MIT License

Copyright (c) 2025 Nous Research

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

# Archive の設計参照（インスピレーション）

`room/src/mihari_room/archive/` の設計は、同じ著者による別リポジトリ
`discord-daily-summary-bot`（ローカル `/Users/thirdlf03/src/github.com/thirdlf03/discord-daily-summary-bot`
を読み取り専用で参照）を参考にしている。コードはそのままコピーしていない。

参考にした点:

- SQLite を WAL で開き、FTS5 trigram の外部コンテンツ表（`messages_fts` など）を
  trigger で保守する構成
- `messages` / 添付 / URL を別テーブルに分け、メッセージ行を upsert で置き換える更新
- 添付はローカルに保存し、編集は全置き換え・削除は `deleted_at` で履歴を残す流儀
- URL は本文から抽出して別テーブルに索引し、メタ取得は失敗しても索引を残す方針

アーカイブ実装は上記の「考え方」だけを借り、書き直している
（安全な取得・パス検証・CLI・テストは本リポジトリ独自の実装）。

# 文書ツールの依存

`room/src/mihari_room/documents/` の依存:

- **markdown-it-py** — Markdown の表示用 HTML 化（MarkdownIt の Python 移植）。
  MIT License。アップストリーム: https://github.com/executablebooks/markdown-it-py
  Hermes 等の Markdown 表示に同梱して使い、生 HTML は無効・CDN 不使用で描画する
- **fpdf2** — Markdown → PDF の専用レンダラーの PDF 出力基盤。
  MIT License（LGPL 時代の fpdf からフォークして再ライセンス）。アップストリーム:
  https://github.com/PyFPDF/fpdf2
- **Pillow** — PDF 内への画像埋め込み（fpdf2 の依存）。HPND ライセンス
- **fontTools** — フォントのサブセット化（fpdf2 の依存）。MIT License

# 同梱フォント

`room/src/mihari_room/resources/fonts/IPAexGothic.ttf` は
[IPAex フォント](https://moji.or.jp/ipafont/)（IPA Font License v1.0）です。
ライセンス全文は同じディレクトリの `IPA_Font_License_Agreement_v1.0.txt` に
同梱している。要素は自由に入手・使用でき、再配布はライセンス条項に従う。
