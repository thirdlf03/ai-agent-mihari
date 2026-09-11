# 音声会話のローカル試行手順（desktop + room）

Epic #35 / Issue #42 用。Mac 実機での手動確認と、CI では代替できない項目のチェックリスト。

契約の詳細: [`voice-realtime-contract.md`](voice-realtime-contract.md)

## 前提

| コンポーネント | 必要環境 |
| --- | --- |
| desktop（ペット + 会話 UI） | macOS 14+、Xcode / Swift 6 |
| room（Realtime 中継） | Python 3.12+、`room/` で `uv sync` |
| VOICEVOX | ローカルエンジン `http://127.0.0.1:50021`、話者 **14（冥鳴ひまり）** |

### PR マージ順（参考・本 Issue ではマージしない）

| レーン | 順序 |
| --- | --- |
| desktop | #43 → #45 → #48（本ブランチは #48 上） |
| room | #44 → #46 → #47 |

room の voice / steer / questions が入る PR が desktop より先にマージされていないと、通話開始〜ジョブ連携の E2E は room 側の不足で止まることがある。

---

## 1. 環境変数

### room（必須）

```bash
export MIHARI_ROOM_TOKEN='your-shared-token'
export MIHARI_OPENAI_API_KEY='sk-…'   # room のみ。desktop には置かない
export MIHARI_ROOM_HOST=127.0.0.1
export MIHARI_ROOM_PORT=8787
# 任意: MIHARI_ROOM_ROOT=~/mihari-room
```

room を起動:

```bash
cd room
uv sync
uv run mihari-room   # または deploy/README の systemd 手順
```

### desktop（必須）

```bash
export MIHARI_ROOM_URL='http://127.0.0.1:8787'
export MIHARI_ROOM_TOKEN='your-shared-token'   # room と同じ値
```

`MIHARI_OPENAI_API_KEY` は **desktop では不要**（room が OpenAI に接続する）。

Xcode から起動する場合は Scheme → Run → Arguments → Environment Variables に上記を追加する。

---

## 2. VOICEVOX

1. [VOICEVOX](https://voicevox.hiroshiba.jp/) を起動する。
2. エンジンが `http://127.0.0.1:50021` で待ち受けていることを確認する。

```bash
curl -s 'http://127.0.0.1:50021/speakers' | head
```

3. desktop は話者 **14（冥鳴ひまり）** 固定（`VoicevoxConfiguration.standard`）。

---

## 3. 会話の開始・終了

1. Mihari desktop アプリ（ペット）を起動する。
2. ペットを **右クリック**（または Ctrl+クリック）→ **「会話を開始…」**。
   - メニューバー「ペット」からも同じ項目がある。
3. 通話ウィンドウが開き、接続状態が「話しかけてください」等になるまで待つ。
4. マイク許可を求められたら許可する。
5. 話しかける → テキスト返答 → **VOICEVOX の声**で読み上げられることを確認する。
6. 終了: メニュー **「会話を終了」** または通話ウィンドウの終了操作。

---

## 4. 割り込み（barge-in）

1. みはりが喋っている最中にマイクへ話しかける。
2. 再生が止まり、新しい発話として扱われること（`VoiceConversationController` の echo guard / barge-in）。

---

## 5. 履歴

1. 数往復会話する。
2. 通話ウィンドウに **テキスト履歴**が残ること。
3. マイク音声ファイルがローカルに保存されていないこと（テキスト + 画面サムネのみ）。

再接続後は room から `history.sync` が届き、履歴が揃う（`VoiceConversationControllerTests.historySyncReplacesLocalMessages`）。

---

## 6. 「画面見て」

1. 画面収録権限を **許可**（システム設定 → プライバシーとセキュリティ → 画面収録）。
2. マウスを載せたディスプレイ上で「画面見て」と言う、または UI の画面送信を使う。
3. **確認ダイアログなし**で 1 枚送信され、履歴に **サムネイル**が付くこと。
4. モデルが画面内容に触れて返答すること。

---

## 7. 作業依頼・steer・質問回答

（room #47 + desktop #48 が揃っている前提）

| 操作 | 期待 |
| --- | --- |
| 「〇〇を調べて」等で依頼 | Hermes ジョブが作成され、会話は継続 |
| 「進捗は？」 | `get_job_status` 相当の要約が system 履歴に出る |
| 「左側を優先して」等 | `POST /jobs/{id}/steer` に **`text`** が送られる |
| ジョブが `waiting_for_input` | 通話 UI に質問が載り、回答を送れる |

HTTP 契約: [`voice-realtime-contract.md`](voice-realtime-contract.md) の steer / answer 節。

---

## 8. 切断・再接続

1. room を一時停止する、またはネットワークを切る。
2. 復旧後、自動再接続または手動「再接続」で **新規セッション**または `streaming` セッションへ張り直す。
3. `session.closed` 後は同一 ID への張り直しを避け、新規 `POST /voice/sessions` へ落ちること（swift test: `autoReconnectUsesNewSessionAfterClosed`）。

---

## 9. OpenAI 課金確認（音声出力ゼロ）

方針: Realtime は **テキスト OUT のみ**。音声合成はローカル VOICEVOX。

1. 試行前後で [OpenAI Usage](https://platform.openai.com/usage) を開く。
2. Realtime / `gpt-realtime-2.1-mini` の利用を確認する。
3. **音声出力（audio output）に課金が乗っていない**こと。
   - room ログやメトリクスの `upstream_audio_output_events` が 0 であることも併せて確認（room レーン）。

---

## 10. 自動テスト（Mac）

> **Linux CI では `swift test` を実行できない**（AppKit / 画面キャプチャ依存）。voice 関連は **macOS + Xcode** で実行する。

```bash
cd desktop
swift test
```

voice だけ絞る例:

```bash
# Swift Testing のスイート名でフィルタ
swift test --filter 'voice'

# 個別
swift test --filter VoiceRealtimeProtocolTests
swift test --filter VoiceConversationControllerTests
swift test --filter VoiceJobCollaborationTests
swift test --filter VoiceScreenCaptureTests
swift test --filter VoiceSessionClientTests
swift test --filter VoiceStreamConnectorTests
swift test --filter VoicevoxClientTests
swift test --filter PetMenuEntriesTests
```

VOICEVOX / room / OpenAI 実機は **不要**（URLProtocol / スタブソケットで通信を差し替え）。

room 側 pytest は **room レーン**（本 Issue の desktop スコープ外）:

```bash
cd room && uv run pytest tests/ -k voice   # room PR で整備
```

---

## トラブルシュート

| 症状 | 確認 |
| --- | --- |
| 会話メニューが出ない | `MIHARI_ROOM_URL` / `MIHARI_ROOM_TOKEN`、room 起動、#45 voice UI がビルドに入っているか |
| 401 / 合言葉 | desktop と room の `MIHARI_ROOM_TOKEN` が一致しているか |
| 無音 | VOICEVOX 起動、話者 14、`http://127.0.0.1:50021` |
| 画面が送れない | 画面収録権限、マウスが載っているディスプレイ |
| Realtime エラー | room の `MIHARI_OPENAI_API_KEY`、room ログ |
