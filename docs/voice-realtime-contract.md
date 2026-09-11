# Voice Realtime 契約（room ↔ desktop 共有）

Epic: [#35](https://github.com/thirdlf03/ai-agent-mihari/issues/35) / room 実装: [#36](https://github.com/thirdlf03/ai-agent-mihari/issues/36) / セッション完成: [#38](https://github.com/thirdlf03/ai-agent-mihari/issues/38)

OpenAI Realtime（`gpt-realtime-2.1-mini`）への接続は **room のみ** が行う。API キーは room 環境変数（`MIHARI_OPENAI_API_KEY` または `OPENAI_API_KEY`）に置き、desktop へは渡さない。

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

### `input.audio`

```json
{
  "type": "input.audio",
  "audio_base64": "<base64>",
  "commit": true,
  "create_response": true
}
```

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

## 音声 OUT 課金なし方針

room は upstream 接続直後に `session.update` で `output_modalities: ["text"]` を設定し、各 `response.create` でも同設定を送る。モデル音声（`response.output_audio.*`）は relay しない。

`session.update` の `session` は GA 形（`type: "realtime"`）で、音声入力は `session.audio.input` 配下に設定する:

- `format: {"type": "audio/pcm", "rate": 24000}` — クライアント送信は PCM16 24 kHz モノラル
- `turn_detection: null` — server VAD を切り、クライアントの `commit` でターン確定
- `transcription: {"model": "gpt-4o-mini-transcribe"}` — 入力音声の文字起こしを有効化。`conversation.item.input_audio_transcription.completed` を room が `user.text` として中継する

検証:

1. セッション後 `GET /voice/sessions/{id}` の `upstream_audio_output_events` が **0** であること
2. room ログに `upstream audio output observed` が出ないこと
3. （本番キー利用時）OpenAI Usage で当該セッション時間帯に Realtime **audio output** 課金が無いこと

## 切断復旧

1. クライアント WS が切れても HTTP セッションは `created` のまま残る（明示 `POST .../close` または server error で `closed`/`error`）。
2. 同一 `session_id` で `WS .../stream` に再接続する。
3. room はディスク上のテキスト履歴を upstream へ `conversation.item.create` で再注入し、続けて `history.sync` を送る。
4. 会話を続行する（新しい `input.audio` / `input.image` を送る）。

同時ストリームは 1 本のみ。別セッションまたは二重接続は WS close code **4409**。

## 永続化

- 保存先: `{MIHARI_ROOM_ROOT}/voice/sessions/<id>/meta.json` と `history.jsonl`
- 保存対象: テキスト（画像プロンプト、assistant 応答、tool_call メタ）
- 非保存: マイク PCM / 音声ファイル
