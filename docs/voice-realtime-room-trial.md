# Voice Realtime — room 側ローカル試行手順

Epic: [#35](https://github.com/thirdlf03/ai-agent-mihari/issues/35) / 統合検証: [#42](https://github.com/thirdlf03/ai-agent-mihari/issues/42)

API・WS イベントの正本は [`voice-realtime-contract.md`](./voice-realtime-contract.md)。本書は **room プロセスだけ** で Realtime を試す手順（キー設定・pytest・課金確認）に絞る。VOICEVOX・通話 UI・実機マイクは desktop レーン（[#41](https://github.com/thirdlf03/ai-agent-mihari/issues/41) 等）のドキュメントを参照。

## 前提

- Python 3.11+、`uv`（[`room/README.md`](../room/README.md) 参照）
- OpenAI API キー（Realtime `gpt-realtime-2.1-mini` が使えるアカウント）
- ペットと同じ `MIHARI_ROOM_TOKEN`

## 1. API キー設定（room のみ）

OpenAI キーは **room 環境変数だけ** に置く。desktop やクライアントへは渡さない（契約どおり）。

| 変数 | 優先 | 説明 |
|------|------|------|
| `MIHARI_OPENAI_API_KEY` | 1 | room 専用（推奨） |
| `OPENAI_API_KEY` | 2 | 上が未設定のときのみ読む |

その他、voice セッションに最低限必要な room 変数:

```bash
export MIHARI_ROOM_TOKEN="<ペットと同じ合言葉>"
export MIHARI_ROOM_ROOT="${MIHARI_ROOM_ROOT:-$HOME/mihari-room}"
export MIHARI_OPENAI_API_KEY="sk-..."   # または OPENAI_API_KEY
# 省略時: gpt-realtime-2.1-mini
# export MIHARI_VOICE_REALTIME_MODEL=gpt-realtime-2.1-mini
```

本番 VPS では `room/deploy/env.example` を `/etc/mihari-room/env` にコピーして同項目を埋める。

**未設定時の挙動:** `POST /voice/sessions` は **503**。`GET /capabilities` の `voice_realtime` は `false`。

## 2. room の起動

```bash
cd room
uv sync --locked
uv run mihari-room
```

既定は `127.0.0.1:8787`。別ホスト/ポートは `MIHARI_ROOM_HOST` / `MIHARI_ROOM_PORT`。

## 3. HTTP でセッション作成（手動スモーク）

```bash
TOKEN="$MIHARI_ROOM_TOKEN"
BASE="http://127.0.0.1:8787"

# 作成
curl -sS -X POST "$BASE/voice/sessions" -H "X-Mihari-Token: $TOKEN" | jq .

# 状態確認（upstream_audio_output_events を後で見る）
SESSION_ID="<上で返った session_id>"
curl -sS "$BASE/voice/sessions/$SESSION_ID" -H "X-Mihari-Token: $TOKEN" | jq .

# 終了（同時 1 会話制限のため、次の試行前に close 推奨）
curl -sS -X POST "$BASE/voice/sessions/$SESSION_ID/close" -H "X-Mihari-Token: $TOKEN" | jq .
```

WebSocket `WS /voice/sessions/{id}/stream` は JSON テキストフレーム。認証はヘッダ `X-Mihari-Token` または query `?token=`（契約参照）。desktop クライアントが接続するまでの **room 単体 WS 試行** は、wscat 等で `session.ready` → `input.image` / `input.audio` → `assistant.text` を確認すればよい。

## 4. pytest（偽 upstream・オフライン）

OpenAI キー不要。Fake upstream で Realtime 経路・履歴・再接続・音声 OUT 非 relay・steer / waiting_for_input を検証する。

```bash
cd room

# voice + ジョブ接続まわり
uv run pytest tests/test_voice_realtime.py tests/test_job_interactions.py -q

# room 全体（既知の無関係な失敗が base にある場合は voice 系だけで可）
uv run pytest -q
```

主なカバレッジ（room 側）:

| 領域 | テストファイル | 内容 |
|------|----------------|------|
| Realtime フェイク | `test_voice_realtime.py` | 画像/音声 IN → テキスト OUT、ツール、`output_modalities: ["text"]` |
| 音声 OUT なし | 同上 | upstream が `response.output_audio.*` を返してもクライアントへ relay せず、`upstream_audio_output_events` でカウント |
| 履歴・再接続 | 同上 | テキスト永続化、マイク PCM 非保存、`history.sync`、manager 再起動 |
| 同時制限 | 同上 | セッション 409、ストリーム 4409 |
| steer / 質問 | `test_job_interactions.py` | `waiting_for_input`、`/jobs/running`、session_id ≠ job_id |

## 5. 音声 OUT 課金なしの確認（契約 § 音声 OUT 課金なし方針）

room は upstream 接続直後および各 `response.create` で `output_modalities: ["text"]` を送る。モデル音声は relay しない。

### A. 自動（pytest / セッション API）

1. `uv run pytest tests/test_voice_realtime.py -q` が通る（偽 upstream で音声 OUT 非 relay を含む）。
2. 本物キーで短いセッション後:

```bash
curl -sS "$BASE/voice/sessions/$SESSION_ID" -H "X-Mihari-Token: $TOKEN" \
  | jq '.upstream_audio_output_events, .output_modalities'
```

期待: `upstream_audio_output_events` が **0**、`output_modalities` が `["text"]`。

### B. room ログ

セッション中に **`upstream audio output observed`** が **出ない** こと（出た場合は upstream が音声 OUT を返しているが relay はしていない — 設定見直しの信号）。

### C. OpenAI Usage（本番キー・手動）

1. [OpenAI Usage](https://platform.openai.com/usage) を開く。
2. 試行した時刻帯の Realtime を確認する。
3. **audio output**（モデル音声生成）の課金行が **無い** こと。テキスト入力・テキスト出力のみが載る想定。

※ Usage ダッシュボードは pytest では検証できない。Epic 受け入れの「本番キー確認」は手動項目。

## 6. ジョブ API の room 側確認（voice 会話とは ID 分離）

voice `session_id` と Hermes `job_id` は別。会話中にジョブを触る場合:

```bash
# 実行中 / 入力待ちジョブ一覧
curl -sS "$BASE/jobs/running" -H "X-Mihari-Token: $TOKEN" | jq .

# steer（running または waiting_for_input のみ）
curl -sS -X POST "$BASE/jobs/$JOB_ID/steer" \
  -H "X-Mihari-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"text":"左側を優先して"}' | jq .

# 質問回答
curl -sS -X POST "$BASE/jobs/$JOB_ID/questions/$QID/answer" \
  -H "X-Mihari-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"answer":"blue"}' | jq .
```

詳細は [`voice-realtime-contract.md` のジョブ接続](./voice-realtime-contract.md#ジョブ接続voice-会話--hermes-ジョブ) を参照。

## 関連

- 契約正本: [`voice-realtime-contract.md`](./voice-realtime-contract.md)
- room デプロイ env 例: [`room/deploy/env.example`](../room/deploy/env.example)
- Epic #35 受け入れの desktop 項目（VOICEVOX 往復・通話 UI・画面見て）は別 PR / 手動
