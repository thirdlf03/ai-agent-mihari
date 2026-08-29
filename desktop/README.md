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

## ペット連携インターフェース

サボり検知の状態機械（#9）とペット本体（担当は別メンバー）の間は、`Pet/` の型と
protocol だけでつながる。**ペット本体を差し替えても、検知側のコードは一切触らずに済む**
ことがこの節のゴール。現時点で `Pet/` に入っているのは、暫定の画像1枚実装
（`PlaceholderPetPresenter`）と、これから本実装が差し込まれるための箱だけ。

### 渡すイベント: `PetEvent`

`desktop/Sources/MihariCore/Pet/PetEvent.swift` で定義。検知側はこの値を組み立てて
`PetPresenting.present(_:)` に渡す。

```swift
public struct PetEvent: Sendable {
    public let state: SaboriState        // 正常 / 疑い / サボり確定
    public let escalationStage: Int      // エスカレーション段階（0 始まり、負値は 0 に丸める）
    public let line: String              // 吹き出しに出すセリフ。空文字なら吹き出しを出さない
    public let visionLabel: VisionLabel  // 寝てる / よそ見 / 不在 / なし（デフォルト .none）
    public let prompt: PetYesNoPrompt?   // はい/いいえ の問いかけ。無ければ nil
}
```

- `SaboriState`（`normal` / `suspected` / `confirmed`）と `VisionLabel`
  （`asleep` / `lookingAway` / `absent` / `none`）はどちらも `String` の `RawRepresentable`
  な enum。`.label` で日本語の表示用文字列が取れる。
- `PetYesNoPrompt(question:onAnswer:)` は はい/いいえ の問いかけ。`onAnswer` は
  `@Sendable (Bool) -> Void` で、回答が決まった瞬間に一度だけ呼ぶ。ボタンのタップからも、
  AirPods の首振り判定（#18）からも、同じコールバックを呼べば分岐できる。

### 受け取る protocol: `PetPresenting`

`desktop/Sources/MihariCore/Pet/PetPresenting.swift` で定義。

```swift
@MainActor
public protocol PetPresenting: AnyObject {
    func present(_ event: PetEvent)  // イベントを反映する
    func show()                       // 常駐ウィンドウを表示する
    func hide()                       // 常駐ウィンドウを隠す
}
```

検知側はこの protocol の型（`any PetPresenting` や、具体型を渡すなら
`PlaceholderPetPresenter`）だけを知っていればよく、ペットの中身を一切知らなくてよい。

### 差し替え手順

1. `PetPresenting` に適合する新しい型（例: `LivePetPresenter`）を `Pet/` 以下に作る。
   `present(_:)` / `show()` / `hide()` を実装すればよく、シグネチャは変えない。
2. 検知エンジン（#9）やアプリ起動処理が `PlaceholderPetPresenter` を生成している箇所を、
   新しい型の生成に差し替える（この配線は本 Issue の範囲外で、統合時に行う）。
3. `PlaceholderPetPresenter` や `Pet/` 配下の他ファイルは削除してよい。`PetEvent` /
   `PetPresenting` はそのまま使い続けられるはずなので、変更が要る場合は検知側に影響が
   出ないか確認すること。

### 暫定実装（`PlaceholderPetPresenter`）の中身

- 画像は `PetConfiguration.imagePath` で差し替え可能。未設定、または指定パスにファイルが
  無ければ SF Symbols のプレースホルダ（既定 `cat.fill`）を描く
  （判定ロジックは `PetImageResolver`）。
- ウィンドウは `NSPanel`（`.borderless, .nonactivatingPanel`、背景透過、`level = .floating`、
  `isMovableByWindowBackground = true`）。キーウィンドウにならないため、クリックやドラッグで
  他アプリからフォーカスを奪わない。`collectionBehavior` は既定のまま
  （全 Space には追随させない）にしてあり、全画面アプリの Space まで追いかけて
  鬱陶しく出続けることを避けている。
- セリフは `PetSpeechQueue` に積んで順番に吹き出しへ出す。直前と全く同じセリフの連投は
  積まない。表示時間は `PetBubbleDurationPolicy`（文字数に応じて 2.5〜8 秒）が決める。
- `PetView`（`desktop/Sources/MihariCore/Views/PetView.swift`）は表示/非表示の切り替えと
  画像パスの設定、サンプルイベントでの動作確認ができる画面。`RootView` には未統合。

### テストから NSWindow は作らない

`PlaceholderPetPresenter` は `show()` を呼ぶまで `NSPanel` を生成しない。テストは
`present(_:)` / `answerPrompt(_:)` / `configuration` の更新だけを呼び、`show()` は
呼ばないことで、CI 上でもウィンドウを一切開かずに検証できる
（`Tests/MihariCoreTests/PlaceholderPetPresenterTests.swift` ほか）。

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
│       ├── Pet/              # ペット連携イベント・protocol・暫定の画像1枚実装
│       └── Views/            # PetView.swift はペットの設定・動作確認画面
└── Tests/MihariCoreTests/
```

実行可能ターゲットはテストから import できないため、ロジックと View はすべてライブラリターゲット
`MihariCore` に置き、`Mihari` は `@main` だけを持つ薄い層にしている。

## 署名について

`codesign --sign -` による ad-hoc 署名で、ローカル実機検証専用。
Developer ID による署名・公証はしておらず、配布は想定していない。

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

## Vision でのラベル付け(寝てる / よそ見 / 不在)

撮った写真そのものではサボり判定をしない。撮った 1 枚に「寝てる / よそ見 / 不在」の
ラベルを付けて、Discord の文面とセリフ生成(`SpeechRequest.vision`)に渡すためだけに使う(#11)。
`Sources/MihariCore/Vision/` にまとまっている。

- `FaceVisionAnalyzer`: `VNDetectFaceLandmarksRequest` を実行する唯一の入口。複数人写っていても
  最も信頼度の高い 1 件だけを見る。例外は内部で吸収し、失敗しても外へは投げない。
- `FaceLandmarkGeometry` / `FaceLandmarkMetrics`: 目の輪郭点群から開き具合(縦幅/横幅)を計算する
  純粋関数と、判定に使う指標(左右の目の開き具合・yaw)をまとめた型。Vision フレームワークの型を
  知らないので、実カメラなしにテストできる。
- `FaceDetectionOutcome`: 検出結果を `detectionFailed` / `noFaceFound` / `faceFound(metrics)` の
  3 通りに分けたもの。「顔が 0 件」と「検出処理自体が失敗した」を区別する。
- `VisionLabelClassifier`: 上記から `SpeechRequest.VisionLabel` を決める純粋なロジック。
  閾値は引数で注入できる。

判定の優先順位と閾値(いずれも `../macos-app-verification` の SaboriLab モジュール 11 での
検証値を引き継いだ仮の値。個人差・カメラ位置・照明でキャリブレーションが必要):

| 条件 | ラベル |
| --- | --- |
| 顔が 1 件も検出できない | `absent`(不在) |
| 目の開き具合(左右平均、縦幅/横幅)が `0.18` 未満 | `sleeping`(寝てる) |
| `yaw` の絶対値が `0.35` rad(約 20 度)超 | `lookingAway`(よそ見) |
| 上記のどれでもない / 検出処理自体が失敗した | `unknown`(不明) |

「検出処理自体が失敗した」場合は「顔が写っていない」と断定できないため `absent` ではなく
`unknown` に倒す。ラベル付けは付加価値であり、これが原因で撮影や送信を止めないことを優先している。

「Vision でラベル付け」タブ(`VisionView`)で「撮ってラベルを付ける」を押すと、その場で
1 枚撮ってプレビュー・判定結果・算出した指標の生の値(左右の目の開き具合・yaw の角度)を表示する。
生の値を見ながら閾値を調整する用途を想定していて、他タブへの組み込みは行っていない。

既知の誤判定要因: メガネ・暗所・逆光。
## 説教オーバーレイ

サボりが確定したときに、音楽を止めて全画面オーバーレイを出し、説教を最後まで聞かせる機能。
`Sources/MihariCore/Overlay/` と `Views/OverlayView.swift` に実装している。

**最優先の要件は「解除されないと Mac が操作不能になる」を絶対に起こさないこと。**
そのため `OverlayModel.show()` は、音楽停止やセリフ取得より先に上限秒数のタイマーを仕込む。
以降の処理がどれだけ失敗・停滞しても、このタイマーだけは動き続けて必ず解除する。

| 解除の経路 | 条件 |
| --- | --- |
| 読み上げ完了(推定) | セリフの文字数から見積もった時間が経過 |
| 上限秒数 | `maxDurationSeconds`(既定 90 秒)が経過。最後の安全策 |
| 緊急解除 | Esc キー |
| 手動 | 画面の「いますぐ解除」ボタン |

```
OverlayModel.show()
  ├─ 1. 上限秒数タイマーを仕込む(他の何より先)
  ├─ 2. 音楽を止める(AppleScript → 失敗したらメディアキーにフォールバック。例外は投げない)
  ├─ 3. セリフを取得する(VoiceController.speak。失敗・例外は固定文言に倒す)
  ├─ 4. 全画面オーバーレイを表示し、読み上げ完了推定タイマーを仕込む
  └─ dismiss(reason:) はどの経路からも呼べて、2 回目以降は何もしない(冪等)
```

`VoiceController.isSpeaking` は再生開始時に `true` になったきり、自然終了では `false` に戻らない
(`stopSpeaking()` を呼んだときだけ戻る)ため、実際の読み上げ完了をそこから検知することはできない。
代わりにセリフの文字数から所要時間を見積もり、それを「読み上げ完了」とみなしている。
見積もりが外れて長引いても、上限秒数のタイマーが必ず先に効く。

`NSWindow` の生成と `NSApplication.presentationOptions` の変更は `OverlayWindowPresenting`
プロトコルの裏に隠してあり、テストではスタブに差し替えて実際の全画面表示を発生させない。
`presentationOptions` は無効な組み合わせを代入すると Swift では catch できない ObjC 例外で
アプリごと落ちるため、選択式 UI は持たず `OverlayPresentationPolicy.sermonOptions`
(`hideDock` + `hideMenuBar` + `disableProcessSwitching`)という検証済みの固定値だけを使う。
`disableForceQuit` はあえて含めていない。自動解除も Esc もすべて壊れた最悪のケースでも、
Cmd+Option+Esc の強制終了でユーザーが自力で抜け出せる経路を残すため。

音楽の停止は Music / Spotify に `player state` を聞いて再生中のものを探し、`pause` を送る。
`pause` コマンド自体が失敗した(オートメーション権限が無いなど)場合に限り、メディアキー
(`NX_KEYTYPE_PLAY` の `CGEvent`)にフォールバックする。メディアキーは再生/一時停止のトグルなので、
「何も再生していない」または「状態そのものが分からない」ときには送らない。誤って再生を
始めてしまうリスクを避けるため。
## AirPods 首振り（はい/いいえ）

ペットの問いかけに、AirPods のヘッドトラッキングで「はい/いいえ」を返す（#18）。カメラのフォールバックは持たない方針。

`CMHeadphoneMotionManager` は macOS 14.0+ の API で、SaboriLab の21モジュールでは唯一未検証だった。
実装前に、署名済み `.app` バンドルから小さな検証コードで疎通確認をした。分かったこと:

- `CMHeadphoneMotionManager.authorizationStatus()` は `notDetermined` から始まり、
  `startDeviceMotionUpdates` を呼んだ瞬間にプロンプトが出て `authorized` に変わった。
  これは既存の `PermissionRequester.requestMotion` に書かれている挙動と一致する
- `isDeviceMotionAvailable` は、AirPods が Bluetooth 未接続の状態でも `true` を返した。
  対応機種かどうかだけを見ており、接続状態そのものは見ていないらしい
- **検証環境の AirPods Pro は Bluetooth 接続されていなかったため、実際に `CMDeviceMotion` が
  流れてくるかは未確認。** 15 秒間購読を続けても、サンプルは 0 件だった

つまり「API を呼べる」ことと「権限を得られる」ことは確認できたが、「実際に値が流れる」ことは
実機で AirPods を接続してから確認する必要がある。判定ロジックはこの不確実性を踏まえて、
CoreMotion に依存しない形にしてテストで担保してある。

### 構成

```
Sources/MihariCore/HeadGesture/
├── HeadOrientationSample.swift        # pitch/yaw の1サンプル。CoreMotion に依存しない
├── HeadGestureThresholds.swift        # 振幅・往復回数・時間窓などの閾値（注入可能）
├── HeadGestureRecognizer.swift        # 判定ロジック本体。角度の時系列を渡すと答えが出る
├── HeadGestureAvailability.swift      # 利用可否（使える/使えない＋理由）
├── HeadOrientationSource.swift        # サンプル供給側の契約（プロトコル）
├── AirPodsHeadOrientationSource.swift # CMHeadphoneMotionManager を使う本物の実装
├── HeadGestureResponse.swift          # 質問の結果（はい/いいえ/時間切れ/利用不可）
├── HeadGestureQuestioner.swift        # 「質問 → 待つ → 結果」を1つにまとめた async API
└── HeadGestureController.swift        # HeadGestureView 用の ObservableObject
```

`HeadGestureRecognizer` は CoreMotion を一切知らない純粋なロジックで、
`Tests/MihariCoreTests/HeadGestureRecognizerTests.swift` で疑似的な角度の時系列を流してテストしている。

### 他モジュールとの接続（#16 向け）

ペットの問いかけ UI（#16）は `HeadGestureQuestioner` だけに依存すればよい。内部実装や
`HeadGestureView` の型は一切知らなくてよい設計にしてある。

```swift
let questioner = HeadGestureQuestioner()
let response = await questioner.ask(prompt: "休憩する？")
switch response {
case .yes: // うなずいた
case .no: // 首を振った
case .timedOut: // 反応がなかった
case .unavailable(let reason): // AirPods未接続などで質問自体をスキップした
}
```

### 判定の閾値と根拠

首振りの判定は、振れ幅・往復回数・時間窓の3つの条件がすべて揃ったときだけ「はい/いいえ」を返す。
AirPods の実データでは未検証のため、`HeadGestureThresholds.default` は日常の首の動きで
誤反応しない方向に倒した見積もり値。

| 定数 | 既定値 | 根拠 |
| --- | --- | --- |
| `minAmplitudeDegrees` | 12° | 画面を見る程度の視線移動（10°未満のことが多い）より確実に大きく、明確なうなずき/首振り（15〜30°）より確実に小さい値 |
| `minReversalCount` | 2 | 1往復（2回反転）未満は「一度だけ下を見て戻す」動作と区別できないため |
| `timeWindowSeconds` | 1.6秒 | 意図したうなずき/首振りの1往復はおよそ0.3〜0.6秒。2往復分の余裕を持たせた |
| `noiseFloorDegrees` | 1.5° | センサーノイズ・首の微振動を反転として誤カウントしないための下限 |
| `maxCrossAxisRatio` | 0.6 | 首を斜めに振ったときに、うなずきと首振りを取り違えないための、主軸に対する副軸の許容比率 |

`HeadGestureView`（「AirPods 首振り」タブ相当。ルートへの組み込みは親が行う）で生の pitch/yaw を
出しているのは、これらの値を実機の AirPods で調整するため。

### 既知の制約

- AirPods が Bluetooth 接続されていないと、`availability()` は `.unavailable` を返して質問を
  スキップする。カメラなどへのフォールバックは持たない（#2 の Epic で明示的にそう決まっている）
- `CMHeadphoneMotionManager` は同時に1つの購読しか持てない。`HeadGestureController` は
  プレビュー中に質問が来たら一旦プレビューを止め、終わったら再開する形で衝突を避けている
- 閾値は実機の AirPods で未検証。誤反応しやすい/しにくいが判明したら
  `HeadGestureThresholds.default` を調整する

## 検知（中核）

Mac の無操作時間と iPhone の様子から、声をかけるか・証拠を取るかを決める。

### 段階と分岐

| Mac 無操作 | iPhone | 状態 | やること |
| --- | --- | --- | --- |
| 〜2 分 | — | 正常 | 何もしない |
| 2〜5 分 | — | 疑い | 声をかける（撮らない・送らない） |
| 5 分〜 | 応答なし / 置かれたまま | サボり確定 | **Mac のカメラで顔を撮る** → Vision でラベル → 音楽を止めて説教 → Discord |
| 5 分〜 | 操作中 | サボり確定 | **iPhone のスクショを撮る** → 音楽を止めて説教 → Discord |

「iPhone からも反応が無い＝寝ているか席にいない」ので顔を撮り、
「Mac は放置して iPhone を触っている＝何を見ているか」を晒す、という切り分け。

### 撮りに行かないケース

- **在席スタンプの直後**（既定 5 分）… 本人が指紋で「席にいる」と示した直後に撮ると、ただの嫌がらせになる
- **クールダウン中**（既定 3 分）… これが無いと 5 秒ごとに撮って送り続けることになる

どちらも声はかける。撮って送るところだけを抑える。

### 閾値

すべて `DetectionThresholds` にあり、**全部要調整**。デモしながら詰める前提。
「検知」タブに現在値と、いま何を根拠に判断したかが出る。

| 名前 | 既定 | 意味 |
| --- | --- | --- |
| `suspectSeconds` | 120 | ここを超えたら疑い |
| `confirmSeconds` | 300 | ここを超えたら確定 |
| `stampGraceSeconds` | 300 | 在席スタンプ直後の猶予 |
| `cooldownSeconds` | 180 | 次に撮るまで空ける |

### 判断の記録

「なぜ撮られたのか」が後から分からないと、閾値を詰めようがないし撮られた本人も納得できない。
発火のたびに **根拠**（無操作時間 / iPhone の様子 / 直前のアプリ）と **結果**（撮れた・送れた・失敗した理由）を残す。

### 壊れ方

**どのアクションが失敗しても評価ループは止めない。** カメラが使えない・VOICEVOX が起動していない・
Discord のトークンが無い、はどれも起こりうる。1 つ転んだせいで見張り自体が死ぬのが一番まずい。
失敗はすべて記録に残して次のループへ進む。
