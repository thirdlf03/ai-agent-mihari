# Mihari

サボり監視ペットの macOS アプリ本体。SwiftUI / Swift 6 / Swift Package Manager 製。macOS 14+ が必要。

現時点で入っているのは、`.app` バンドルの組み立てと権限オンボーディング画面（#3）、および Python 常駐デーモンの起動と接続（#4）まで。

## なぜ `swift run` ではなく `.app` を作るのか

TCC（カメラ / マイク / 画面収録 / 入力監視 / モーション）のプロンプトを正しく出すには、
用途文字列を持つ `Info.plist` 入りの**署名済み `.app` バンドル**である必要がある。
`swift build` の生成物をそのまま実行してもプロンプトは出ず、権限は黙って失敗する。
`build.sh` はビルド生成物を `Mihari.app` に組み立て、`Resources/Mihari.entitlements` を付けて ad-hoc 署名する。

## ビルド / 実行

リポジトリルートから:

```sh
make build   # Mihari.app をビルドして ad-hoc 署名する
make run     # ビルドして Mihari.app を起動する
make test    # テストを実行する
```

`desktop/` で直接叩く場合:

```sh
./build.sh   # swift build -c release → .app 組み立て → ad-hoc 署名 → 署名の検証
./run.sh     # build.sh を実行してから open ./Mihari.app
swift test
```

アプリの標準出力やログをターミナルで見たい場合は、`open` の代わりに
`./Mihari.app/Contents/MacOS/Mihari` を直接実行する。バンドル内の実行ファイルを直接叩いても
バンドル ID と署名は変わらないため、TCC のプロンプトは同じように出る。

## 権限

| 権限 | 用途 | 照会 API |
| --- | --- | --- |
| カメラ | サボり検知時に証拠写真を1枚撮る | `AVCaptureDevice.authorizationStatus(for: .video)` |
| マイク | 在席状況の判定に使う（音声は保存しない） | `AVCaptureDevice.authorizationStatus(for: .audio)` |
| 画面収録 | サボり検知時に画面のスクショを撮る | `CGPreflightScreenCaptureAccess()` |
| 入力監視 | キーやマウスの操作有無からアイドルを判定する | `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` |
| オートメーション | 説教中に再生中の音楽を止める | `AEDeterminePermissionToAutomateTarget(com.apple.Music)` |
| モーション | AirPods の首振りを はい/いいえ として受け取る | `CMHeadphoneMotionManager.authorizationStatus()` |

初回起動時だけ、要求できる権限（カメラ / マイク / 画面収録 / 入力監視）をまとめてプロンプトする。
2 回目以降は勝手に出さず、「まとめて許可を求める」ボタンを押したときだけ要求する。

### 開発中にハマりやすい点

- **ad-hoc 署名は再ビルドのたびに署名が変わりうるため、一度許可した権限が再ビルド後に忘れられる。**
  画面の「まとめて許可を求める」を押し直すか、システム設定から一度削除して登録し直す。
- **画面収録**は事前照会の API が `CGPreflightScreenCaptureAccess` しかなく、未決定と拒否済みを区別できない。
  false のときは赤ではなく灰色（未決定）で出る。また `CGRequestScreenCaptureAccess` のプロンプトは初回だけで、
  2 回目以降はシステム設定から許可してアプリを再起動する必要がある。
- **オートメーション**は対象アプリ（Music）が起動していないと `procNotFound` になり判定できない。
  プロンプトは実際に命令を送った瞬間にしか出ないので、この画面からは要求できない。
- **モーション**は AirPods が接続されていないとプロンプトが出ないため、初回のまとめ要求からは外してある。

## デーモン

Discord Bot・セリフ生成・iPhone の取得は `bridge/` の Python プロセスが受け持つ。
アプリは起動時にこれを子プロセスとして立ち上げ、終了時に落とす。

- Swift → Python: `127.0.0.1` へ REST
- Python → Swift: SSE（`/events`）でイベントを push
- 認証: 起動のたびにアプリが生成したトークンを `X-Mihari-Token` ヘッダで送る
- ポート: `0` で起動して OS に空きを選ばせ、子プロセスが stdout に出す 1 行
  `{"port": ..., "pid": ...}` でアプリが接続先を知る

「デーモン」タブから起動 / 停止 / 再起動と、iPhone の探索、テストイベントの往復ができる。

### ハマりどころ

- **`URLSession.AsyncBytes.lines` は空行を捨てる。** SSE はフレームの区切りが空行なので、
  これを使うと「接続は成功しているのにイベントが 1 件も届かない」という症状になる。
  `LineAccumulator` で自前に行を切っている。
- **SSE は専用の `URLSession` を使う。** 既定のセッションはキャッシュを挟むため、終わらない応答だと
  バイトが手元まで降りてこない。また `timeoutInterval` に `.infinity` を入れると期限の計算が
  壊れるので、長い有限値にする。
- アプリが異常終了しても孤児のデーモンが残らないよう、Python 側は stdin の EOF を監視して
  自分から終了する。

## 構成

```
desktop/
├── Package.swift
├── build.sh / run.sh
├── Resources/
│   ├── Info.plist            # 用途文字列（TCC のプロンプト本文）
│   └── Mihari.entitlements   # apple-events
├── Sources/
│   ├── Mihari/               # @main だけ。中身は MihariCore に置く
│   └── MihariCore/
│       ├── Daemon/           # Python 常駐プロセスの起動・REST・SSE
│       ├── Permissions/
│       └── Views/
└── Tests/MihariCoreTests/
```

実行可能ターゲットはテストから import できないため、ロジックと View はすべてライブラリターゲット
`MihariCore` に置き、`Mihari` は `@main` だけを持つ薄い層にしている。

## 署名について

`codesign --sign -` による ad-hoc 署名で、ローカル実機検証専用。
Developer ID による署名・公証はしておらず、配布は想定していない。

## セリフと声

ペットの発話は `bridge/` 側で作る。macOS 側は「状況を渡す」「返ってきた WAV を鳴らす」だけ。

```
Swift ──POST /voice/speak（状況）──▶ Python
                                    ├ Claude API でセリフ生成
                                    └ VOICEVOX で WAV 合成
      ◀── {text, audio(base64), ...} ─┘
```

**片方が欠けても止まらないことを最優先にしている。** サボりを検知したのに、喋れないせいで
撮影も送信も起きない、という壊れ方をさせない。

| 欠けているもの | どうなるか |
| --- | --- |
| `ANTHROPIC_API_KEY` 未設定 | 状況別の固定文言で喋る（`from_llm: false`） |
| Claude API が遅い / 失敗 | 待たずに固定文言へ切り替える（既定 4 秒で打ち切り） |
| VOICEVOX が未起動 | 音声は `null`。セリフは返るので吹き出しには出る |

### セットアップ

1. [VOICEVOX](https://voicevox.hiroshiba.jp/) をインストールして起動する（既定 `http://127.0.0.1:50021`）
2. `cp bridge/.env.example bridge/.env` して `ANTHROPIC_API_KEY` を入れる

どちらも任意。入れなくてもアプリは動く。「セリフと声」タブに、いま何が足りないかが出る。

### 設定（`bridge/.env`）

| 変数 | 既定 | 用途 |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | なし | セリフ生成。未設定なら固定文言 |
| `MIHARI_LLM_MODEL` | `claude-haiku-4-5` | 喋り出しの速さを優先した既定。品質重視なら `claude-opus-5` |
| `MIHARI_VOICEVOX_URL` | `http://127.0.0.1:50021` | エンジンの場所 |
| `MIHARI_VOICEVOX_SPEAKER` | `1` | 話者 ID。`/speakers` で一覧を引ける。**どのキャラにするかは未定** |

`bridge/.env` は `.gitignore` 済み。**API キーは絶対にコミットしない。**

同じセリフの音声は合成結果を覚えておくので、2 回目以降は待たされずに鳴る。

### キャラの口調を変える

`bridge/src/device_bridge/voice/generator.py` の `SYSTEM_PROMPT` を書き換える。
固定文言は `bridge/src/device_bridge/voice/fallback.py`。

## Discord

証拠の投稿も、監視の指示も Discord Bot 経由で行う。Webhook は使わない。
**Bot は Mac の上でローカル常駐する**ので、Mac が落ちている間はスラッシュコマンドが効かない。

### セットアップ

1. [Discord Developer Portal](https://discord.com/developers/applications) で **New Application**
2. 「General Information」の **APPLICATION ID** を `bridge/.env` の `DISCORD_CLIENT_ID` に
3. 「Bot」タブで **Reset Token** して `bridge/.env` の `DISCORD_BOT_TOKEN` に
4. アプリの「Discord」タブで **招待 URL を開く** → 自分のサーバに Bot を入れる
5. 「チャンネルを探す」→ 投稿先を選ぶ

`bridge/.env` は `.gitignore` 済み。**Bot トークンは認証情報なので絶対にコミットしない。**

未設定でもアプリは起動する。「Discord」タブに、いま何段目で止まっているかが出る。

### スラッシュコマンド

| コマンド | 内容 |
| --- | --- |
| `/watch start` | いますぐ監視を始める |
| `/watch at HH:MM` | 指定時刻に監視を始める（過ぎていれば翌日） |
| `/watch stop` | 監視を止める |
| `/watch status` | いまの監視状態を見る |

予約が発火すると Python 側が SSE に `watch.start` を流し、macOS アプリが監視モードに入る。

### 招待 URL が要求する権限

「チャンネルを見る」「メッセージを送る」「ファイルを添付する」だけ。
過剰な権限を要求すると招待をためらわれるので最小限にしている。
## 在席スタンプ(Touch ID)

`Sources/MihariCore/Attendance/` に、Touch ID(または非搭載機ではパスワード)で在席を
証明する「スタンプ」の仕組みが入っている(#19)。UI は `Views/AttendanceView.swift` に単体で
動く `View` として用意してあり、`RootView` への組み込みは別途行う。

- `TouchIDAuthenticating`: `LocalAuthentication` を抽象化するプロトコル。本番実装は
  `LocalAuthenticationTouchIDAuthenticator`(SaboriLab の `TouchIDModule` を踏襲)。
  テストではこれをスタブに差し替え、実行だけで Touch ID のダイアログが出ないようにしている。
- `AttendanceModel`: `canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` が
  使えなければ `.deviceOwnerAuthentication`(パスワード)へ自動でフォールバックする。
  認証のキャンセル・失敗は例外を投げず、`lastMessage` に文言を残すだけ。
- `AttendanceStore`: スタンプ履歴を `UserDefaults` に JSON で永続化する。保存先は
  `PermissionsModel` と同じく注入可能で、上限件数(`historyLimit`)を超えた分は古いものから捨てる。
- `AttendanceGrace`: 「直近のスタンプから何秒経ったか」「いま猶予期間中か」を返す純粋なロジック。
  猶予秒数は `defaultGracePeriod`(既定 5 分)で、呼び出し側から上書きできる。
  サボり検知の状態機械(#9)はここを参照して、スタンプ直後の誤検知を避ける想定。
## 撮影(カメラ / スクリーンショット)

検知が発火した瞬間の証拠取得(#10)は `Sources/MihariCore/Capture/` にまとまっている。

- `CameraCaptureService`: `AVCaptureSession` + `AVCapturePhotoOutput` で 1 枚だけ撮る。
  呼び出しのたびにセッションを新しく組み立てて開始し、撮影が終わったら必ず `stopRunning()` する。
  常時プレビューは行わないため、緑ランプは撮影の瞬間だけ点く。
- `ScreenshotCaptureService`: ScreenCaptureKit の `SCScreenshotManager.captureImage` でメイン
  ディスプレイを 1 枚キャプチャする。
- `CaptureService`: 上記 2 つの窓口。撮った画像を PNG にそろえて一時ディレクトリへ保存し、
  `CaptureArtifact`(保存先パス + `delete()`)として返す。送信後の削除はこの型 1 つで完結する。
- どちらも撮影前に `PermissionChecker` で権限を確認し、未許可なら実際の AV API には触れずに
  理由(`PermissionState.detail`)付きの `CaptureError` を返す。権限拒否・未決定でアプリが
  落ちないことは単体テストで固定してある。
- `Views/CaptureView.swift` は上記を単体で試すための最小限の画面(撮る / プレビュー / 保存先 /
  エラー表示)。他タブへの組み込みは行っていない。
