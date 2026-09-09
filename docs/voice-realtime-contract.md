# voice Realtime 契約（room ↔ desktop）

Epic #35 / §5 の共有契約。実装の正本は `desktop/Sources/MihariCore/Voice/VoiceRealtimeProtocol.swift` と room 側の voice ハンドラ。

## 経路

```
desktop (Swift) ──HTTP/WS──► room (Python) ──WS──► OpenAI Realtime
                              │
                              └── MIHARI_OPENAI_API_KEY（room のみ）
```

- desktop は `MIHARI_ROOM_URL` / `MIHARI_ROOM_TOKEN` で room に接続する。
- OpenAI API キーは **room 環境変数のみ**。desktop には置かない。
- 会話モデル: `gpt-realtime-2.1-mini`（音声・画像 IN、**テキスト OUT**）
- 返答テキストの読み上げは desktop 側 VOICEVOX（話者 14 冥鳴ひまり）

## HTTP

| メソッド | パス | 用途 |
| --- | --- | --- |
| `POST` | `/voice/sessions` | セッション作成 |
| `GET` | `/voice/sessions/{id}` | 状態取得（再接続判定） |

共通ヘッダ: `X-Mihari-Token: <MIHARI_ROOM_TOKEN>`

### POST /voice/sessions 応答

```json
{
  "session_id": "…",
  "model": "gpt-realtime-2.1-mini",
  "status": "created",
  "protocol_version": 1,
  "stream_path": "/voice/sessions/{id}/stream"
}
```

### GET /voice/sessions/{id} 応答

```json
{
  "session_id": "…",
  "model": "gpt-realtime-2.1-mini",
  "status": "created | streaming | closed | …",
  "error": null
}
```

`status` が `created` または `streaming` のとき desktop は同一 ID へ WebSocket を張り直せる。

## WebSocket

`WS {MIHARI_ROOM_URL}/voice/sessions/{id}/stream`（`stream_path` を ws/wss に変換）

### room → desktop（受信）

| type | 主なフィールド | 意味 |
| --- | --- | --- |
| `session.ready` | `session_id`, `model` | ストリーム準備完了 |
| `history.sync` | `messages[]` | テキスト履歴の同期（マイク音声は含めない） |
| `assistant.text` | `delta`, `text`, `done` | 返答テキスト（delta または text） |
| `assistant.tool_call` | `name`, `call_id`, `arguments` | ツール呼び出し（JSON 文字列） |
| `error` | `code`, `message` | エラー |
| `session.closed` | `reason` | セッション終了 |

#### history.sync の messages[]

| フィールド | 型 | 備考 |
| --- | --- | --- |
| `role` | string | `user` / `assistant` |
| `text` | string | 表示テキスト |
| `ts` | number | Unix 秒 |
| `kind` | string | `text` / `image_prompt` / `tool_call` 等 |
| `tool_name` | string | `kind=tool_call` のとき |
| `tool_arguments` | string | JSON 文字列 |

### desktop → room（送信）

| type | 主なフィールド | 意味 |
| --- | --- | --- |
| `input.audio` | `audio_base64`, `commit`, `create_response` | PCM16 チャンク。`commit:true` で発話確定 |
| `input.image` | `image_base64`, `media_type`, `prompt`, `create_response` | 画面 1 枚（マウスがあるディスプレイ） |

## ツール名（assistant.tool_call）

desktop が解釈する名前（別名あり）:

| 正名 | 別名例 | 用途 |
| --- | --- | --- |
| `capture_screen` | `screen_capture`, `request_screen` | 画面送信 |
| `submit_job` | `create_job`, `request_job` | Hermes ジョブ依頼 |
| `steer_job` | `steer`, `job_steer` | `POST /jobs/{id}/steer`（body は **`text`**） |
| `get_job_status` | `job_status`, `check_job_progress` | 進捗確認 |
| `show_job_question` | `waiting_for_input`, `job_question` | 質問 UI 表示 |

## 関連 room API（会話外 HTTP）

| メソッド | パス | body |
| --- | --- | --- |
| `POST` | `/jobs/{id}/steer` | `{"text": "…"}`（`instruction` ではない） |
| `POST` | `/jobs/{id}/questions/{qid}/answer` | `{"answer": "…"}` |

## 課金方針（テキスト OUT）

OpenAI Realtime へは **音声出力を要求しない**（テキスト OUT のみ）。ローカル試行後、OpenAI Usage で音声出力課金が乗っていないことを確認する手順は `docs/voice-local-try.md` を参照。

room 側では `upstream_audio_output_events` 等のメトリクスで監視する想定（room PR レーン）。

## protocol_version

現在 `1`。破壊的変更時は room / desktop を同時に上げる。
