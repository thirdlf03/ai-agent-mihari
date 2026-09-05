# Mihari Room MVP — 契約と受け入れ

みはりちゃんの VPS 作業部屋（Room）の MVP 契約と検証状況。
デプロイ手順は `room/deploy/README.md`、型は `room/src/mihari_room/contracts.py`。

## 現状の正直なまとめ

- **ローカル**: 偽 Hermes（`room/tests/fixtures/fake_hermes_*.py`）でストア・キュー・
  Forum・orchestrator・HTTP をテスト済み
- **実 Hermes の E2E は未実施**。実機（ConoHa）へのデプロイも未実施
- 2026-09-05、SSH で実機へつなぎに行ったが**タイムアウト**。この日以降の実操作は無い
- **「出荷済み E2E 検証済み」とは書かない**。下のチェックリストを埋めたときだけ言える
- Phase 6（後回しに決めた任意フェーズ）は**未着手**（後述）

## 構成

単一の Room デーモン 1 プロセス:

```
HTTP (127.0.0.1:8787) ──> orchestrator ──> queue（同時実行 1 件）
                         └──> worker（Hermes AIAgent を in-process で回す）
Discord (Mihari Bot) ────> forum 入出力（本家 Gateway は使わない）
```

- ジョブは `$MIHARI_ROOM_ROOT/jobs/<id>/`（meta.json / input/ / output/ /
  followup-*.txt / hermes_session_id）
- Hermes の作業エンジンは `run_agent.AIAgent` をプロセス内で借りる
  （`hermes -z` も Discord Gateway も起動しない）
- 同時に RUNNING は 1 件。落ちた机は起動直後に queued へ戻る

## HTTP 契約

ベース: `http://127.0.0.1:8787`。認証はヘッダ **`X-Mihari-Token`**（ペットと同じ合言葉）。
`GET /health` だけ認証なし。

| Method / Path | 状態 | 説明 |
| --- | --- | --- |
| `GET /health` | 実装済み | `{"status":"ok"}` |
| `POST /jobs` | 実装済み | 仕事を投入。body: `{title?, body, source, requested_by?}` → `{job_id, thread_id, status}`。失敗時 `503` |
| `POST /jobs/{id}/cancel` | 実装済み | body: `{by?}`。by 無しなら owner。頼んだ人か `MIHARI_OWNER_ID` だけ。`404` / `403` |
| `POST /jobs/{id}/followup` | **後で実装** | 同じジョブの続き（input/ に追記、空いたら再実行、実行中は終了後に再回し） |
| `GET /jobs/running` | **後で実装** | `{"jobs": [...]}`。今動いている 1 件 |
| `GET /jobs/{id}` | **後で実装** | 単体。`404` は無い仕事 |
| `GET /jobs/{id}/events` | **後で実装** | SSE。`Last-Event-ID` で再開。Caddy はバッファしない設定 |
| `GET /jobs/{id}/memory` | **後で実装** | `{"candidates": [...]}`。Hermes が出した memory 候補 |
| `POST /jobs/{id}/memory/{candidate_id}/approve` | **後で実装** | 候補を確定（owner 明示承認） |
| `POST /jobs/{id}/memory/{candidate_id}/reject` | **後で実装** | 候補を捨てる |

ステータスは `queued / running / done / failed / cancelled`
（Forum タグ: 待ち / 作業中 / 完了 / 失敗 / 中断）。

## 承認ポリシー（YOLO は撤回）

- 無人環境なので基本は自律。Clarify は自動で「最善の仮定で進めて」に丸める
- ただし **memory の書き込みは owner の明示承認が要る**
  （`GET /jobs/{id}/memory` → `approve` / `reject`。この契約は実装中。実装が
  済むまでは Hermes の memory 書き込みは YOLO モードのままにしない——設定で塞ぐ）
- 取り消しは `POST /jobs/{id}/cancel`（頼んだ人 / owner）。Forum からも owner は止められる
- 1 ジョブ 15 分タイムアウト。超えたら failed 扱いで途中まで残す

## プレビューとアーカイブ

- **プレビュー**: `$MIHARI_ROOM_ROOT/previews/<job_id>/...` を
  **API とは別ホスト**（`MIHARI_PREVIEW_BASE_URL`）から静的配信する
  - preview ホストは `/previews/*` 以外を 404（API に触れない）
  - webroot に memory / research / manifests は置かない
  - 未実装の間は `MIHARI_PREVIEW_BASE_URL` は空のまま
- **アーカイブ**: `MIHARI_ARCHIVE_CHANNEL_IDS` の**明示的な許可リスト**だけに投稿。
  空なら archive は一切投稿しない（opt-in）

## 環境変数

`room/README.md` と `room/deploy/env.example` を参照。
必須: `MIHARI_ROOM_TOKEN` / `DISCORD_BOT_TOKEN` / `MIHARI_FORUM_CHANNEL_ID` /
`MIHARI_OWNER_ID`。ディスク: `MIHARI_ROOM_ROOT` / `HERMES_HOME` /
`HERMES_PYTHON`（省略可） / `MIHARI_ROOM_PYTHON`。任意: `MIHARI_PREVIEW_BASE_URL` /
`MIHARI_ARCHIVE_CHANNEL_IDS`。ローカルバインド `127.0.0.1:8787`。
Python は **3.11**（room と Hermes を同じ interpreter で回す。3.14 の stdlib を混ぜない）。

## 受け入れチェックリスト

### ローカル（偽 Hermes）— 済み

- [x] `uv run pytest -q`（store / queue / forum / discord / worker / orchestrator / app のユニット）
- [x] HTTP: `POST /jobs` → queue → 実行 → Forum タグ更新（RecordingBoard で確認）
- [x] cancel（頼んだ人 / owner / それ以外 403）
- [x] 起動直後の running → queued 復元
- [x] ruff lint / format

### ライブ（実 Hermes、実 Forum）— 未実施

- [ ] 実 `AIAgent` でジョブ 1 件が通って Forum に進捗が流れる
- [ ] followup で同じセッションが resume され、実行中の仕事に続きが載る
- [ ] 実機 systemd 起動 → `/health` OK、`POST /jobs` 認証 OK
- [ ] Caddy 経由（HTTPS / Tailscale）で API が動く、preview が public URL で見える
- [ ] バックアップ → 停止復元で state.db / jobs / previews が旧 URL のまま戻る
- [ ] 実 Hermes の memory 候補 → approve / reject のフロー（Phase 後半の契約）

### 未着手 / 延期

- [ ] Phase 6（任意フェーズ）: 後回しに決定、未着手
- [ ] memory 承認エンドポイント（`/jobs/{id}/memory/{candidate_id}/approve|reject`）
- [ ] SSE イベント配信（`/jobs/{id}/events`、Last-Event-ID 再開）
- [ ] messages.db / archive 実装
- [ ] Cloudflare / 他 CDN（実装しないと決めた場合は「対象外」と明記）