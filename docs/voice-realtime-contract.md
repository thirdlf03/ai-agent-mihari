# Voice Realtime 契約（room ↔ desktop 共有）

Epic: [#35](https://github.com/thirdlf03/ai-agent-mihari/issues/35) / room 実装: [#36](https://github.com/thirdlf03/ai-agent-mihari/issues/36) / セッション完成: [#38](https://github.com/thirdlf03/ai-agent-mihari/issues/38) / ジョブ接続: [#40](https://github.com/thirdlf03/ai-agent-mihari/issues/40) / desktop 実装: [#41](https://github.com/thirdlf03/ai-agent-mihari/issues/41)

OpenAI Realtime（`gpt-realtime-2.1-mini`）への接続は **room のみ** が行う。API キーは room 環境変数（`MIHARI_OPENAI_API_KEY` または `OPENAI_API_KEY`）に置き、desktop へは渡さない。

```
desktop (Swift) ──HTTP/WS──► room (Python) ──WS──► OpenAI Realtime
                              │
                              └── MIHARI_OPENAI_API_KEY（room のみ）
```

- desktop は `MIHARI_ROOM_URL` / `MIHARI_ROOM_TOKEN` で room に接続する
- 会話モデル: `gpt-realtime-2.1-mini`（音声・画像 IN、**テキスト OUT**）
- 返答テキストの読み上げは desktop 側 VOICEVOX（話者 14 冥鳴ひまり）

room 側のローカル試行・pytest・課金確認手順: [`voice-realtime-room-trial.md`](./voice-realtime-room-trial.md)。desktop 側の手動試行: [`voice-local-try.md`](./voice-local-try.md)。

## 認証

既存の `X-Mihari-Token`（`mihari_room.auth.verify_token` / `TOKEN_HEADER`）。

- HTTP: ヘッダ `X-Mihari-Token`
- WebSocket: ヘッダ `X-Mihari-Token` または query `?token=`

Mac 操作の `/ws/mac-control` とは別経路。voice は `/voice/*` のみ。

## HTTP

### `POST /voice/sessions`

セッションを作成し ID を返す。

**Response 200**

```json
{
  "session_id": "<id>",
  "model": "gpt-realtime-2.1-mini",
  "status": "created",
  "protocol_version": 1,
  "stream_path": "/voice/sessions/<id>/stream"
}
```

OpenAI キー未設定時は **503**。

同時に 1 会話だけ許可。未終了セッションがある状態で新規作成すると **409**。

### `GET /voice/sessions/{id}/history`

テキスト履歴を再取得する。マイク音声（`input.audio`）は保存しない。

**Response 200**

```json
{
  "session_id": "<id>",
  "messages": [
    {
      "role": "user",
      "text": "Describe this image.",
      "ts": 0.0,
      "kind": "image_prompt"
    },
    {
      "role": "assistant",
      "text": "saw-image",
      "ts": 0.1,
      "kind": "text"
    }
  ]
}
```

### `POST /voice/sessions/{id}/close`

会話セッションを明示終了する。終了後のみ新規 `POST /voice/sessions` が可能。

生存中のストリームがある場合は `session.closed` フレームがクライアントへ送られ、WS と upstream 接続が切断される（反映まで最大 ~0.2 秒）。

**Response 200**

```json
{
  "session_id": "<id>",
  "status": "closed"
}
```

### `GET /voice/sessions/{id}`

セッション状態。

```json
{
  "session_id": "<id>",
  "model": "gpt-realtime-2.1-mini",
  "status": "created|streaming|closed|error",
  "created_at": 0.0,
  "closed_at": null,
  "error": null,
  "upstream_audio_output_events": 0,
  "output_modalities": ["text"]
}
```

## WebSocket

### `WS /voice/sessions/{id}/stream`

JSON テキストフレーム。方向ごとの最小イベント:

| 方向 | type | 用途 |
|------|------|------|
| room → client | `session.ready` | upstream 接続・`output_modalities: ["text"]` 設定完了（`resumed: true` は切断復旧） |
| room → client | `history.sync` | 再接続時にテキスト履歴を一括送信 |
| client → room | `input.audio` | PCM16 等の base64 音声チャンク |
| client → room | `input.image` | base64 画像 + `media_type` |
| room → client | `assistant.text` | テキスト応答（`delta` / `text` + `done`） |
| room → client | `assistant.tool_call` | ツール呼び出し（`name`, `call_id`, `arguments`） |
| room → client | `user.text` | 入力音声の文字起こし（`text`） |
| room → client | `error` | エラー |
| room → client | `session.closed` | ストリーム終了 |

未知の `type` はクライアント側で無視してよい（後方互換の追加イベント）。

`assistant.text` は `delta`（差分）フレーム列のあと `done: true` フレームで**全文 `text`** を送る。クライアントは `done` の `text` で累積分を置き換えること（加算すると二重表示になる）。

#### `history.sync` の `messages[]`

| フィールド | 型 | 備考 |
| --- | --- | --- |
| `role` | string | `user` / `assistant` |
| `text` | string | 表示テキスト |
| `ts` | number | Unix 秒 |
| `kind` | string | `text` / `image_prompt` / `tool_call` 等 |
| `tool_name` | string | `kind=tool_call` のとき |
| `tool_arguments` | string | JSON 文字列 |

ユーザーの音声ターンは `role=user, kind=text`（文字起こし結果）として保存・同期される。

### `input.audio`

```json
{
  "type": "input.audio",
  "audio_base64": "<base64>",
  "commit": true,
  "create_response": true
}
```

PCM16 モノラル 24 kHz を想定。`commit: false` でチャンクを流し、発話確定時に `commit: true`（+ `create_response: true`）を送る。発話中は無音に近いチャンクも欠落させずに送ること。

### `input.image`

```json
{
  "type": "input.image",
  "image_base64": "<base64>",
  "media_type": "image/png",
  "prompt": "Describe this image.",
  "create_response": true
}
```

### ツール名（`assistant.tool_call`）

desktop が解釈するツール名（別名あり）:

| 正名 | 別名例 | 用途 |
| --- | --- | --- |
| `capture_screen` | `screen_capture`, `request_screen` | 画面 1 枚を `input.image` で送信（マウスがあるディスプレイ） |
| `submit_job` | `create_job`, `request_job` | Hermes ジョブ依頼 |
| `steer_job` | `steer`, `job_steer` | `POST /jobs/{id}/steer`（body は **`text`**） |
| `get_job_status` | `job_status`, `check_job_progress` | 進捗確認 |
| `show_job_question` | `waiting_for_input`, `job_question` | 質問 UI 表示 |

現状 room が `session.update` で登録するツールは接続検証用の `echo_phrase` のみ。上記の job/画面ツールをモデルが実際に呼べるようにするには、room 側でのツール定義登録と結果返却（`function_call_output` 相当）経路の追加が今後必要。

## 音声 OUT 課金なし方針

room は upstream 接続直後に `session.update` で `output_modalities: ["text"]` を設定し、各 `response.create` でも同設定を送る。モデル音声（`response.output_audio.*`）は relay しない。

`session.update` の `session` は GA 形（`type: "realtime"`）で、音声入力は `session.audio.input` 配下に設定する:

- `format: {"type": "audio/pcm", "rate": 24000}` — クライアント送信は PCM16 24 kHz モノラル
- `turn_detection: null` — server VAD を切り、クライアントの `commit` でターン確定（トップレベルの `turn_detection` は beta 形で無視されうるため置かない）
- `transcription: {"model": "gpt-4o-mini-transcribe"}` — 入力音声の文字起こしを有効化。`conversation.item.input_audio_transcription.completed` を room が `user.text` として中継し履歴にも残す

検証:

1. セッション後 `GET /voice/sessions/{id}` の `upstream_audio_output_events` が **0** であること
2. room ログに `upstream audio output observed` が出ないこと
3. （本番キー利用時）OpenAI Usage で当該セッション時間帯に Realtime **audio output** 課金が無いこと

## 切断復旧

1. クライアント WS が切れても HTTP セッションは `created` のまま残る（明示 `POST .../close` で `closed`、ハンドラ内部エラーで `error`）。
2. 同一 `session_id` で `WS .../stream` に再接続する（`closed`/`error` セッションは 4409 で拒否されるため新規 `POST /voice/sessions` からやり直す）。
3. room はディスク上のテキスト履歴を upstream へ `conversation.item.create` で再注入し、続けて `history.sync` を送る。
4. 会話を続行する（新しい `input.audio` / `input.image` を送る）。

同時ストリームは 1 本のみ。別セッションまたは二重接続は WS close code **4409**。upstream 側の障害でストリームが落ちた場合もセッションは `created` に戻るため再接続できる。

## 永続化

- 保存先: `{MIHARI_ROOM_ROOT}/voice/sessions/<id>/meta.json` と `history.jsonl`
- 保存対象: テキスト（画像プロンプト、音声ターンの文字起こし、assistant 応答、tool_call メタ）
- 非保存: マイク PCM / 音声ファイル
- `closed` / `error` セッションには履歴を追記しない

## ジョブ接続（voice 会話 ↔ Hermes ジョブ）

voice **session_id** と Hermes **job_id** は別 ID。会話セッションのストレージは `voice/sessions/`、ジョブは `jobs/`。会話からジョブを参照するときは既存のジョブ API を使う（セッション ID を job ID にしない）。

### ジョブ状態 `waiting_for_input`

Hermes が clarify 等でユーザー入力待ちになったとき、ジョブ status は `waiting_for_input`（机占有・`/jobs/running` に含む）。回答後は `running` に戻る。

### `POST /jobs/{id}/steer`

実行中（`running` / `waiting_for_input`）ジョブへ途中指示を足す。

**Request**

```json
{ "text": "左側を優先して" }
```

**Response 200**

```json
{
  "job_id": "<id>",
  "seq": 1,
  "filename": "001.txt",
  "text": "左側を優先して",
  "created_at": 0.0,
  "delivered": true
}
```

未実行・終端ジョブは **409**。指示は `jobs/<id>/input/steer/` に永続化される。`delivered: true` は稼働中の worker へ即時注入できたこと、`false` は永続化のみ（次ターン開始時に `input/steer/*.txt` から読み込まれる）を意味する。クライアントは `false` を「送った」ではなく「保存した」と表示すべき。

### `GET /jobs/{id}/questions`

質問一覧（pending / answered / cancelled）。

### `POST /jobs/{id}/questions/{qid}/answer`

`waiting_for_input` 中の pending 質問に答える。

**Request**

```json
{ "answer": "blue" }
```

**Response 200**

```json
{
  "job_id": "<id>",
  "question": {
    "id": "<qid>",
    "question": "色は？",
    "choices": ["red", "blue"],
    "multi_select": false,
    "status": "answered",
    "answer": "blue",
    "created_at": 0.0,
    "answered_at": 0.1
  }
}
```

`GET /jobs/{id}` の `pending_questions` に未回答分が載る。不明な `qid` は **404**、存在するが回答済み・取消済みは **409**。

## protocol_version

現在 `1`。破壊的変更時は room / desktop を同時に上げる。
