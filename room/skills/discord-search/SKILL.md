# discord-search（Room アーカイブ検索）

みはりちゃんの作業部屋（Room）に溜まった Discord 履歴から、過去の発言・添付・URL を
探して仕事に使うスキル。検索だけでなく、出典を `jobs/<id>/research/downloads` に
コピーして `sources.json` / `summary.md` を作るところまで面倒を見る。

## 実行環境

Room のジョブ内では **in-process ツール**を使う（shell は既定で無効のため、
サブプロセスの CLI はジョブ内からは呼ばない）。Hermes の tool として登録済み：

- `discord_search` — 本文・添付・URL の全文検索（`query`, `limit`, `channel`,
  `after`, `before`, `author`）
- `discord_recent` — キーワード無しの最近の発言
- `discord_channels` — 収録チャンネル一覧
- `discord_message` — 1 件の詳細（添付・URL 付き）
- `discord_context` — `message_id` の前後を読む（`before`/`after` 0〜10）
- `discord_export` — 添付を `jobs/<id>/research/downloads/` にコピーし、
  `sources.json` / `summary.md` を作る（`message_id`, `no_fetch` 省略可）

いずれも Room のアーカイブ DB を読み取り専用で引き、export だけ
`research/downloads/` の内側に書く。結果は最大 10 件・本文 2000 字で頭打ち。
引用には必ず `jump_url` を添える。

手元（Room 外）で直接叩きたいときだけ CLI を使う。トークン不要：

- 環境変数 `MIHARI_ROOM_PYTHON` が設定されていれば、それを使う（`uv run` 不要）。
  ```bash
  "$MIHARI_ROOM_PYTHON" -m mihari_room.archive search --query "みはり" --root "$MIHARI_ROOM_ROOT"
  ```
- 無ければ room の uv 環境から動かす。
  ```bash
  cd "$ROOM_DIR" && uv run python -m mihari_room.archive search --query "みはり"
  ```
- `--root` は部屋のディスク。省略時は `$MIHARI_ARCHIVE_ROOT` / `$MIHARI_ROOM_ROOT` /
  `~/mihari-room` の順で探す。デーモンと同じ root を指定すること。

## コマンド

### search — 発言の全文検索

```bash
python -m mihari_room.archive search \
  --query "キーワード" \
  [--after 2024-01-01] [--before 2024-01-31] \
  [--channel 123456789012345678] [--limit 20] [--include-deleted]
```

- `--query` は日本語・英語どちらでも。3 文字未満の語は自動で LIKE 検索に落ちる。
- `--after` / `--before` は `YYYY-MM-DD`（ローカル 0 時境界）か ISO 8601 文字列。
- `--channel` は ID でもチャンネル名でもよい（カンマ区切りで複数）。
- 出力は JSON。各ヒットに `jump_url`・`author_name`・`created_at`・本文・
  添付一覧・URL 一覧が入っている。

### context — メッセージの前後

```bash
python -m mihari_room.archive context \
  --message-id 123456789012345678 [--before 5] [--after 5]
```

同じスレッド／チャンネル内の前後の発言を `anchor` / `before` / `after` で返す。
文脈が要るときは search で見つけた `message_id` をここに渡す。

### export — 出典をジョブへコピー

```bash
python -m mihari_room.archive export \
  --job-id <job_id> --message-id 123456789012345678 [--no-fetch]
```

- 作業中のジョブ `jobs/<id>/research/downloads/` に添付をコピーする。
- `sources.json`（出典一覧：`jump_url`・ファイル名・URL メタ）と
  `summary.md`（要約用メモ）を同じ場所に書く。
- `--no-fetch` は、まだダウンロードされていない添付の取得を止めてスキップ扱いにする。
- パスは全部検証済み。ジョブの外へ逃げる symlink は弾く。

## 出力の読み方

```json
{
  "command": "search",
  "hits": [{
    "rank": -0.0008,
    "snippet": "⟪みはり⟫ちゃんのごはん https://…",
    "message": {
      "message_id": 12345,
      "jump_url": "https://discord.com/channels/777/111/12345",
      "author_name": "たろー",
      "created_at": "2024-01-02T03:04:05+00:00",
      "content": "みはりちゃんのごはん https://example.com/page を確認",
      "attachments": [{"filename": "report.pdf", "status": "ok"}],
      "urls": []
    }
  }]
}
```

## 引用ルール（大事）

- 引用するときは必ず `jump_url` を添える。発言の ID だけや本文の丸写しでは足りない。
  jump_url が無い・見つからないメッセージは「未収録」として引用しない。
- 引用は lenny に切って短く。前後は `context` で確かめてから。
- 添付は `export` してできた `downloads/` のコピーを使う。CDN の URL をそのまま
  書き残す必要はない（`sources.json` に既に入っている）。

## 長期記憶のルール

- 生ログ・全文・連呼のやり取りを丸ごと長期記憶に入れない。
- 記憶に残すのは「要約 + 根拠の jump_url 一覧」だけ。
  `export` が作る `summary.md` をそのまま流用してもよい。
- 検索結果の本文は作業中の一時メモ（ジョブフォルダ）に書き、記憶には残さない。

## やってはいけないこと

- Discord トークンなど秘密情報をコマンドに渡さない・出力に含めない。
- アーカイブはローカル検索ツール。Discord への投稿や外部 API への転送はしない。
- `messages.db` を直接編集しない・壊さない。CLI だけ使う。
- 取得は全部安全側：添付は Discord CDN、URL は公開 HTTP のみ、サイズ上限つき。

## トラブルシューティング

- `アーカイブが無い: …/messages.db` → まだ収録が始まっていない。デーモンを再起動すると
  見えるチャンネルの履歴キャッチアップが走る。
  特定チャンネルだけにしたいときだけ `MIHARI_ARCHIVE_CHANNEL_IDS` を書く。
- 検索結果が 0 件 → 3 文字未満の語でも LIKE で引けるはず。`--channel` が
  間違っていないか確認する。
- `MIHARI_ROOM_PYTHON` が無く module が見つからない → `cd room && uv sync` を実行。