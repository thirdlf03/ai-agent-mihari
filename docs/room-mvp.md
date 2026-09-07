# Mihari Room MVP — 契約と受け入れ

みはりちゃんの VPS 作業部屋（Room）の MVP 契約と検証状況。
デプロイ手順は `room/deploy/README.md`、型は `room/src/mihari_room/contracts.py`。
desktop 側の対応は別 owner（`desktop/`）が持つ。ここでは backend 契約だけを約束する。

## 現状の正直なまとめ

- **ローカル**: 偽 Hermes（`room/tests/fixtures/fake_hermes_*.py`＋注入 fake agent）で
  ストア・キュー・Forum・orchestrator・HTTP・memory 承認・プレビュー・
  終端 E2E（`room/tests/test_room_e2e.py`）を通した。`uv run pytest -q` 230 件、
  `ruff check` / `ruff format` clean
- **実機**: ConoHa で systemd 常駐。Tailscale Serve が API と `/previews` を
  tailnet 内 HTTPS に出している。`MIHARI_PREVIEW_BASE_URL` は Tailscale 原点。
  社外に渡せる公開 HTTPS はまだ無い（Cloudflare Tunnel が次。API は Tailscale のまま）
- Phase 6 の棚・Temporary Accounts・記憶ワンクリック・指摘 followup は実装済み
  （Temporary Accounts の VPS 実機 wrangler は未接続）
- 本番 Python は **3.11 に固定**する。Hermes は
  `requires-python = ">=3.11,<3.14"` で、room も同じ interpreter で回す
  （`room/.python-version` と `room/deploy/README.md` の
  `uv sync --python 3.11`）。3.14 の stdlib を混ぜると落ちる

## 構成

単一の Room デーモン 1 プロセス（`python -m mihari_room.cli`）：

```
HTTP (127.0.0.1:8787) ──> orchestrator ──> queue（同時実行 1 件）
                         └──> worker（Hermes AIAgent を in-process で回す）
Discord (Mihari Bot) ────> forum 入出力（本家 Gateway は使わない）
```

- ジョブは `$MIHARI_ROOM_ROOT/jobs/<id>/`（meta.json / input/ / output/ /
  followup-*.txt / hermes_session_id / memory_candidates.json / events.ndjson）
- Hermes の作業エンジンは `run_agent.AIAgent` をプロセス内で借りる
  （`hermes -z` も Discord Gateway も起動しない）。
  参照ソースは読み取り専用 `/Users/thirdlf03/.hermes/hermes-agent`（pin 先）。
  本番では `HERMES_PYTHON` / `HERMES_AGENT_ROOT` で同じ版を指定する
- 同時に RUNNING は 1 件（`agent_serial`）。落ちた机は起動直後に queued へ戻る
- デーモンは `room.lock`＋`hermes_home.lock` を掴み、専用 `HERMES_HOME`
  （既定 `<root>/.hermes-room`、対話 `~/.hermes` には触れない）を Hermes import
  より前に pin する。lease は worker thread 全終了まで離さない

## HTTP 契約

ベース: `http://127.0.0.1:8787`。認証はヘッダ **`X-Mihari-Token`**（ペットと同じ合言葉）。
`GET /health` と `GET /previews/*` だけ認証なし。

| Method / Path | 状態 | 説明 |
| --- | --- | --- |
| `GET /health` | 実装済み | `{"status":"ok"}` |
| `POST /jobs` | 実装済み | 仕事を投入。body: `{title?, body, source, requested_by?}` → `{job_id, thread_id, status}`。Forum 作成失敗時は `503`（phantom queued を残さない） |
| `POST /jobs/{id}/cancel` | 実装済み | body: `{by?}`。by 無しなら owner。頼んだ人か `MIHARI_OWNER_ID` だけ。`404` / `403`。実行中は worker thread に interrupt を届け、終了を待ってから次へ |
| `POST /jobs/{id}/followup` | 実装済み | 同じジョブの続き（input/ に追記、空いたら再実行、実行中は終了後に再回し）。cancel 後の中断 thread 生存中は終了後に再開（生存中の再開はしない） |
| `GET /jobs/running` | 実装済み | `{"jobs": [...]}`。今動いている 1 件 |
| `GET /jobs/{id}` | 実装済み | 単体。`artifacts`（version ごとの一意 `id`）と `temp_deploys`（claim URL 含む。認証済み）。`404` は無い仕事 |
| `GET /jobs/{id}/events` | 実装済み | SSE。`Last-Event-ID` で再開。イベント `id` は整数連番（desktop は整数 OR 文字列どちらも decode すること）。未知・壊れた cursor は先頭から全件（取りこぼさない）。完了後 5 秒で閉じるので desktop は張り直して cursor から再開すること |
| `GET /jobs/{id}/memory` | 実装済み | `{"candidates": [{id, target, content, status, created_at}]}`。`target` は `MEMORY.md` / `USER.md` |
| `POST /jobs/{id}/memory/{candidate_id}/approve` | 実装済み | 候補を確定（owner 明示承認）。承認者は**サーバ設定の owner**（body の身分は使わない）。`MIHARI_OWNER_ID` 未設定は `403`。冪等（2 回目は同値 200）。済み逆遷移は `409`、未知候補は `404` |
| `POST /jobs/{id}/memory/{candidate_id}/reject` | 実装済み | 候補を捨てる（home に書かない）。冪等・状態遷移は approve と対称 |
| `POST /jobs/{id}/artifacts/{version}/rollback` | 実装済み | 旧 version の静的プレビューを新しい token として再公開（owner のみ）。過去 token は残す。`404` は無い仕事・無い version |
| `GET /previews/{token}/...` | 実装済み | 未認証・安全ヘッダ付きの成果物配信（allowlist 拡張子のみ、symlink/隠しファイル/メタデータ経路は 404） |

ステータスは `queued / running / done / failed / cancelled`
（Forum タグ: 待ち / 作業中 / 完了 / 失敗 / 中断）。

イベント `kind` には `speech / log / file / summary / cancelled` に加え
`memory_candidate`（`phase: waiting`）がある。候補提案は queue を塞がず、
desktop は詳細 refresh 時に `GET .../memory` を引き直すこと。

## 承認ポリシー（YOLO は撤回）

- 無人環境なので基本は自律。Clarify は自動で「最善の仮定で進めて」に丸める
- **memory の書き込みは owner の明示承認が要る**
  （`GET /jobs/{id}/memory` → `approve` / `reject`）。
  組み込み `memory` ツールの `add` は候補として預かり、直書きしない。
  `replace` / `remove` は MVP 未対応として明示拒否する
  （差分指示文を memory に追記する誤記憶だけはしない）。
  外部 provider・終了時抽出の裏書きも抑止する。読みは承認済み memory を返す
- 取り消しは `POST /jobs/{id}/cancel`（頼んだ人 / owner）。Forum からも owner は止められる
- 1 ジョブ 15 分タイムアウト。超えたら failed 扱いで途中まで残す

## ツール境界（shell 無しで回る）

- `terminal / computer_use / code_execution / cronjob / kanban / delegation` は既定 OFF
  （`MIHARI_ROOM_ALLOW_SHELL=1` の明示 opt-in でのみ shell 系を許可）。
  `discord / discord_admin` 送信系は常に OFF。MCP 動的 toolset（`mcp-*`）も有効化しない
- 残すのは読み・生成系：`file`（write_file/patch 含む）・`search`・`web`・
  `session_search`・`memory`（承認制）・`mihari_room`（discord_search / recent /
  channels / message / context / export / cloudflare_temp_deploy）
- Discord 横断検索・PDF 取り込みは shell 不要の in-process bounded ツールで提供する
  （実 Hermes registry に `mihari_room` toolset として登録・検証済み）：
  `discord_search` / `discord_recent` / `discord_channels` / `discord_message` /
  `discord_context` / `discord_export` /
  `cloudflare_temp_deploy`（`wrangler deploy --temporary`。ジョブ dir と
  `XDG_CONFIG_HOME=<job>/.wrangler-tmp` に閉じる。claim URL は GET /jobs の
  `temp_deploys` だけ。Forum には workers.dev のみ）
- 危険ツール名の最終扉として `delegate_task / skill_manage / cronjob_manage / terminal`
  等を agent 表面から名指し除去する（`skills_list / skill_view` の参照は残す）
- **制限の正直な範囲**: `bash` 完全無制限化（opt-in 時）の書き込み先までは塞げない。
  ファイルガードは `HERMES_WRITE_SAFE_ROOT=<job_dir>`（Hermes file tools 用）。
  PII の完全な非含有は証明できない（公開前の目視確認を推奨）。詳細は
  `room/src/mihari_room/worker/agent.py` の `SAFETY_LIMITATIONS` を参照

## プレビューとアーカイブ

- **プレビュー**: `$MIHARI_ROOM_ROOT/previews/<random-token>/...` を
  **API とは別ホスト**（`MIHARI_PREVIEW_BASE_URL`）から静的配信する想定だが、
  MVP の配信実装自体は同一プロセスの `GET /previews/*`（未認証・CSP 付き）
  - 公開するのは `output/artifact/` の allowlist 拡張子のみ
    （`index.html` 必須、manifest・秘密名・research・非 web は写さない）。
    Forum へ通知するのも安全な成果物だけ
  - manifest（id/version/preview_url/sha256/source_ids/session_id）は
    `root/registry/` に置き、HTTP では出さない。sha256 は決定的
    （相対パス昇順）。version は単調増加、各 version の `id` は
    `art-<job>-v<n>` で一意（古い registry も読み出し時に付け直す）
  - CSP は `sandbox allow-scripts`（`allow-same-origin` なしの opaque origin）。
    相対 CSS/画像/フォント＋同一フォルダの `.js` のみ。HTML インライン script と
    CDN は `script-src 'self'` で拒否する。`connect-src 'none'` で
    API origin への権限は渡さない
  - preview ホストは `/previews/*` 以外を 404（API に触れない）
  - webroot に memory / research / manifests は置かない
  - 本番は Tailscale 原点が入っている。社外公開は Cloudflare Tunnel で
    **プレビュー専用ホスト**だけを出す（`room/deploy/README.md`）
- **アーカイブ**: 既定で Bot が見えるテキスト / スレッド / Forum を全部収録する。
  `MIHARI_ARCHIVE_CHANNEL_IDS` は任意の絞り込み（空なら全チャンネル）。
  起動時に各チャンネルの最終収録以降を history で埋め直す。
  検索・文脈・export は `python -m mihari_room.archive`（CLI）でも叩ける

## 環境変数

`room/README.md` と `room/deploy/env.example` を参照。
必須: `MIHARI_ROOM_TOKEN` / `DISCORD_BOT_TOKEN` / `MIHARI_FORUM_CHANNEL_ID` /
`MIHARI_OWNER_ID`。ディスク: `MIHARI_ROOM_ROOT` / `HERMES_HOME`
（未設定なら `<root>/.hermes-room`） / `HERMES_PYTHON`（省略可・本番は明示） /
`MIHARI_ROOM_PYTHON`。任意: `MIHARI_PREVIEW_BASE_URL` /
`MIHARI_ARCHIVE_CHANNEL_IDS` / `MIHARI_ROOM_ALLOW_SHELL`（既定空＝shell 無効）。
ローカルバインド `127.0.0.1:8787`。
Python は **3.11**（room と Hermes を同じ interpreter で回す。3.14 の stdlib を混ぜない）。

## 受け入れチェックリスト

### ローカル（偽 Hermes）— 済み

- [x] `uv run pytest -q`（230 件：store / queue / forum / discord / worker /
  orchestrator / app / memory 承認 HTTP / guard hook / bounded discord tools /
  hardening / cancel-interrupt / preview security / 終端 E2E）
- [x] HTTP: `POST /jobs` → queue → 実行 → Forum タグ更新（RecordingBoard で確認）
- [x] cancel（頼んだ人 / owner / それ以外 403）＋実行中 interrupt・thread 終了待ち
- [x] followup v2（同 job・同 session resume、実行中は終了後再回し、cursor 消費）
- [x] SSE（replay・unknown cursor 全件・heartbeat・完了後 close と再開）
- [x] memory 承認フロー（list → approve/reject、冪等、`409`/`404`、owner のみ、
  承認文の home 永続化と次 session 読み込み、replace/remove 明示拒否）
- [x] bounded Discord 検索ツール（search / recent / channels / message / context /
  export。seeded メッセージ＋PDF、sources.json/summary.md、実 registry 登録検証）
- [x] 成果物公開（allowlist・sha 決定性・version 増加・session 連続・CSP・symlink 拒否）
- [x] 起動直後の running → queued 復元＋再起動後の memory/candidates 永続
- [x] ruff lint / format clean
- [x] 本番 Python pin の文書化（3.11、`room/deploy/README.md`）

### ライブ（実 Hermes、実 Forum）

- [x] 実 `AIAgent` でジョブ 1 件が通って Forum に進捗が流れる
- [x] followup で同じセッションが resume される（実機で session_id 一致を確認）
- [x] 実機 systemd 起動 → `/health` OK、`POST /jobs` 認証 OK
- [x] Tailscale HTTPS で API が動く。preview は tailnet 内 URL で見える
- [ ] 社外向けの公開 HTTPS（Cloudflare Tunnel のプレビュー専用ホスト）
- [x] バックアップ（`--live-consistent`）→ temp 展開で state.db / messages.db
  の integrity ok、previews の sha 一致。本番ディレクトリへの上書き復元は未実施
- [x] 実 Hermes の memory 候補 → approve（200）→ 済みを reject すると 409
- [x] 実機で `discord_search` 等の `mihari_room` ツールがジョブから使えた

### 未着手 / 延期（対象外と明記）

- [ ] 定期ダイジェスト
- [ ] プレビュー CSP を緩めてモック内からコメントを送ること
- [ ] 本番 Cloudflare アカウントへの login 済み `wrangler deploy`
