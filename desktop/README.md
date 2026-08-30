# Mihari

サボり監視ペットの macOS アプリ本体。SwiftUI / Swift 6 / Swift Package Manager 製。macOS 14+ が必要。

検知・撮影・Vision・説教・Discord・在席スタンプ・AirPods 首振り・デスクトップペットまでを 1 つのアプリに統合してある。
起動すると（必須権限が揃っていれば）ウィンドウを出さず、ペットが出て見張り始める。

## なぜ `swift run` ではなく `.app` を作るのか

TCC（カメラ / マイク / 画面収録 / 入力監視 / モーション）のプロンプトを正しく出すには、
用途文字列を持つ `Info.plist` 入りの**署名済み `.app` バンドル**である必要がある。
`swift build` の生成物をそのまま実行してもプロンプトは出ず、権限は黙って失敗する。
`build.sh` はビルド生成物を `Mihari.app` に組み立て、`Resources/Mihari.entitlements` を付けて署名する
（証明書があればそれを使い、無ければ ad-hoc。「[署名について](#署名について)」を参照）。

## ビルド / 実行

リポジトリルートから:

```sh
make build   # Mihari.app をビルドして署名する
make run     # Mihari.app をビルドして起動する
make test    # Swift / Python のテストを実行する
make lint    # Swift / Python のフォーマットと lint を検査する
```

`desktop/` で直接叩く場合:

```sh
./build.sh   # swift build -c release → .app 組み立て → 署名 → 署名の検証
./run.sh     # build.sh を実行してから open ./Mihari.app
swift test
```

`build.sh` は一時ディレクトリ（`.build/staging.XXXXXX`）で組み立て・署名・検証まで済ませてから `Mihari.app` を差し替える。
**アプリを起動したまま `make build` すると、古いバンドルは `.build/Mihari.app.previous` へ退避され、新しいものは次回起動から有効になる**
（起動中のアプリには反映されないので、一度終了して起動し直す）。起動中は警告を 1 行出すだけでビルドは止めない。
止めたい場合は `MIHARI_BUILD_REQUIRE_QUIT=1 make build` にすると、差し替える前に非 0 で終了する。

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

カメラ / マイク / 画面収録 / 入力監視の 4 つは**必須**で、揃うまで見張り始めない。
撮れも送れもしない状態で常駐しても、黙って失敗し続けるだけになるため。
オートメーションとモーションは任意で、欠けていても始められる。

初回、または必須のどれかが欠けているときだけ「権限の確認」ウィンドウが出る。初回起動時は
要求できる権限（カメラ / マイク / 画面収録 / 入力監視）をまとめてプロンプトし、2 回目以降は
勝手に出さず「まとめて許可を求める」ボタンを押したときだけ要求する。必須が揃うと「始める」が
押せるようになり、押すとウィンドウが閉じてペットが出て、デーモンが起動し、見張りが始まる。
2 回目以降で必須が揃っていれば、ウィンドウを出さずに起動と同時に見張り始める。
画面収録だけは、システム設定で許可したあとにアプリを再起動しないと反映されない。

### 開発中にハマりやすい点

- **ad-hoc 署名は再ビルドのたびに署名が変わりうるため、一度許可した権限が再ビルド後に忘れられる。**
  画面の「まとめて許可を求める」を押し直すか、システム設定から一度削除して登録し直す。
  **Apple Development 証明書で署名していればこれは起きない**（TCC の照合が cdhash ではなく
  Team ID を含む要件になるため）。作り方は「[署名について](#署名について)」を参照。
- **起動中のアプリの足元でバンドルを作り直すと、TCC が `Info.plist` の用途文字列を読めず `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__` で落ちる**ことがあったため、`build.sh` は一時ディレクトリで組み立ててから差し替えている。
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

サボり検知の状態機械（#9）とペット本体の間は、`Pet/` の型と protocol だけでつながる。
**ペット本体を差し替えても、検知側のコードは一切触らずに済む**ことがこの節のゴール。
本実装は `LivePetPresenter` で、`PetPresenting` に適合している。検知側が知っているのは
`PetEvent` を組み立てて `PetPresenting` に渡すことだけで、スプライトも吹き出しもメニューも知らない。

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
    func present(_ event: PetEvent)               // イベントを反映する
    func show()                                   // 常駐ウィンドウを表示する
    func hide()                                   // 常駐ウィンドウを隠す
    func dismissPrompt()                          // 出している問いかけを捨てる
    func setMonitoring(_ mode: PetMonitoringMode)  // 監視の状態を伝える
}
```

- `dismissPrompt()` は、AirPods の首振りや無反応で検知側が問いかけを終えたときに呼ぶ。
  吹き出しの はい/いいえ を閉じるだけで、回答は起こさない。
- `setMonitoring(_:)` は `watching` / `paused` / `onBreak` の 3 値。監視停止中と休憩中は
  ペットを静止させる。

### `PetEvent` からペットの動きへ

`LivePetPresenter` がイベントを `PetDirective`（固定するアニメーション / 1 回だけ挟む
アニメーション / 吹き出しのセリフ）に落とし、`PetController` に渡す。

| イベント | 固定 | 1 回だけ挟む | 吹き出し |
| --- | --- | --- | --- |
| `normal` | 解除（自律行動に戻る） | 直前が `normal` でなければ `waving` | 出さない |
| `suspected` | `waiting` | — | `line` |
| `confirmed` | `failed` | 段階が上がったときだけ `jumping` | `line` |
| `prompt` 付き | `waiting` | — | 問いかけ + はい/いいえ のボタン |

- 跳ねるのは**段階が上がったときだけ**。同じエピソード内で 3→2→3 と往復しても跳ねない。
  正常に戻ったところで段階を忘れる。
- 問いかけを出しているあいだに届いたセリフは溜めておき、問いかけが閉じてから出す。
- 問いかけを出している最中に新しい問いかけが来たら**新しい方を捨てる**。先に出している方の
  回答経路を生かして、答えたのに何も起きない状態を作らない。
- 音声は検知側（`Voice/VoiceController`）が鳴らすので、ここでは吹き出しだけを出す。

### テストから NSWindow は作らない

`LivePetPresenter` は `show()` を呼ぶまでウィンドウを生成しない。テストは `present(_:)` /
`answerPrompt(_:)` だけを呼び、結果を `lastDirective` で確かめることで、CI 上でもウィンドウを
一切開かずに検証できる（`Tests/MihariCoreTests/LivePetPresenterTests.swift`）。

## 構成

```
desktop/
├── Package.swift
├── build.sh / run.sh
├── Resources/
│   ├── Info.plist            # 用途文字列（TCC のプロンプト本文）
│   └── Mihari.entitlements   # apple-events
├── Sources/
│   ├── Mihari/               # @main とメニューバーの「ペット」メニューだけ
│   └── MihariCore/
│       ├── App/              # AppCoordinator（全機能の取りまとめ）/ MihariAppDelegate / AuxiliaryWindows
│       ├── Detection/        # 判定の状態機械・閾値・BreakPromptSession（「休憩中?」の問いかけ）
│       ├── Capture/          # カメラ / 画面のスクショ
│       ├── Vision/           # 撮った写真のラベル付け
│       ├── Overlay/          # 説教の全画面オーバーレイと音楽の停止
│       ├── Voice/            # SpeechPlayer（唯一の音の出口）と VoiceController
│       ├── Daemon/           # Python 常駐プロセスの起動・REST・SSE
│       ├── Discord/          # 証拠の投稿とチャンネル選択
│       ├── Attendance/       # 在席スタンプ（Touch ID）
│       ├── HeadGesture/      # AirPods の首振り
│       ├── Permissions/
│       ├── Pet/              # 連携イベント・protocol と、スプライトのペット本体
│       ├── Resources/pets/   # 同梱ペットの素材（pet.json + スプライトシート）
│       └── Views/            # 権限画面と、MIHARI_DEBUG_UI=1 で開く検証用の 10 タブ画面
└── Tests/MihariCoreTests/
```

実行可能ターゲットはテストから import できないため、ロジックと View はすべてライブラリターゲット
`MihariCore` に置き、`Mihari` は `@main` だけを持つ薄い層にしている。

## 署名について

ローカル実機検証専用。Developer ID による署名・公証はしておらず、配布は想定していない。
`build.sh` は次の順で署名に使う identity を決め、どれを使ったかを必ず 1 行出力する。

1. 環境変数 `CODESIGN_IDENTITY` が設定されていればそれを使う（`security find-identity -v -p codesigning`
   に出る 40 桁のハッシュでも `Apple Development: ...` の名前でもよい）。
   その identity が見つからない場合は **ad-hoc に落ちずに codesign のエラーで止まる**
2. 未設定なら、キーチェーンにある最初の **Apple Development 証明書**を自動検出して使う
   （同名の証明書が複数あっても一意に決まるよう、名前ではなく SHA-1 ハッシュを渡している）
3. どちらも無ければ従来どおり **ad-hoc**（`codesign --sign -`）で署名し、stderr に警告を 1 行出す

Hardened Runtime（`--options runtime`）は付けていない。付けるとカメラ / マイクに
`com.apple.security.device.*` の entitlements が別途必要になるため。

### なぜ証明書で署名したいのか

TCC はアプリの同一性を、証明書署名なら **Team ID を含む designated requirement** で、
ad-hoc なら **cdhash** で照合する。cdhash はコードが変われば変わるので、**ad-hoc だと再ビルドの
たびに別のアプリと見なされ、一度許可したカメラ / マイク / 入力監視が無効になる。**
システム設定の一覧では ON のままなのに実際のチェックだけが拒否される、という分かりにくい壊れ方をする。
`build.sh` の最後に出る `designated => ...` の行が、いまどちらで照合されているかを示している。

### Apple Development 証明書の作り方（無料の Apple ID でよい）

有料の Developer Program は要らない。

1. Xcode > Settings… > Accounts で Apple ID を追加する
2. 追加した Apple ID を選んで **Manage Certificates…**
3. 左下の **＋** > **Apple Development**
4. `security find-identity -v -p codesigning` に出れば準備完了。
   以降は `make build` するだけで自動的にこの証明書が使われる

### ad-hoc から証明書署名に切り替えた直後

**TCC から見ると別のアプリになるので、ad-hoc 時代の許可の記録が残っていると噛み合わない。**
一度リセットしてから取り直す。

```sh
tccutil reset All com.thirdlf03.mihari
make build
make run   # 「権限の確認」ウィンドウが出るので、まとめて許可し直す
```

画面収録だけは、システム設定で許可したあとにアプリを再起動しないと反映されない。

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
Swift ──POST /voice/speak（状況・iPhone 操作中ならスクショ）──▶ Python
                                    ├ スクショあり → Gemini が画面を読んでセリフ
                                    ├ それ以外・読めなかった → Claude API でセリフ生成
                                    └ VOICEVOX で WAV 合成
      ◀── {text, screen, audio(base64), ...} ─┘
```

スクショを添えるのは、**iPhone 操作中（`iphone == active`）のサボりで証拠のスクショを撮れたとき**だけ。
Mac のカメラ写真は顔しか写らないので送らない。手で試すときは「撮影」タブで iPhone のスクショを
撮ってから「この画面を読ませて喋らせる」を押すと、同じ経路を 1 回だけ通せる（読み取れた内容と、
読めなかった理由がその場に出る）。

**片方が欠けても止まらないことを最優先にしている。** サボりを検知したのに、喋れないせいで
撮影も送信も起きない、という壊れ方をさせない。

| 欠けているもの | どうなるか |
| --- | --- |
| `ANTHROPIC_API_KEY` 未設定 | 状況別の固定文言で喋る（`from_llm: false`） |
| Claude API が遅い / 失敗 | 待たずに固定文言へ切り替える（既定 4 秒で打ち切り） |
| `GEMINI_API_KEY` 未設定 | 画面は読まず、従来どおり Claude のセリフになる |
| Gemini が遅い / 失敗 | Claude → 固定文言の順に落ちる（既定 6 秒で打ち切り） |
| VOICEVOX が未起動 | 音声は `null`。セリフは返るので吹き出しには出る |

### セットアップ

1. [VOICEVOX](https://voicevox.hiroshiba.jp/) をインストールして起動する（既定 `http://127.0.0.1:50021`）
2. `cp bridge/.env.example bridge/.env` して `ANTHROPIC_API_KEY` を入れる
3. iPhone の画面まで読ませるなら、同じ `.env` に `GEMINI_API_KEY` を入れる

どれも任意。入れなくてもアプリは動く（`GEMINI_API_KEY` が無ければ画面は読まず、従来どおり
Claude / 固定文言になる）。「セリフと声」タブに、いま何が足りないかが出る。

画面を読ませると 1 回およそ $0.0003（画像は medium で 560 トークン固定 + 短い JSON。
[料金](https://ai.google.dev/gemini-api/docs/pricing)）。スクショは Gemini API に送られる。

### 設定（`bridge/.env`）

| 変数 | 既定 | 用途 |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | なし | セリフ生成。未設定なら固定文言 |
| `MIHARI_LLM_MODEL` | `claude-haiku-4-5` | 喋り出しの速さを優先した既定。品質重視なら `claude-opus-5` |
| `GEMINI_API_KEY` | なし | iPhone のスクショを読む。`GOOGLE_API_KEY` でも可。未設定なら画面を読まない |
| `MIHARI_SCREEN_MODEL` | `gemini-3.1-flash-lite` | 画面を読むモデル。ここも喋り出しの速さ優先 |
| `MIHARI_SCREEN_MEDIA_RESOLUTION` | `medium` | スクショを送る解像度（`low` / `medium` / `high`）。上げるのは読み違いが多いときだけ |
| `MIHARI_VOICEVOX_URL` | `http://127.0.0.1:50021` | エンジンの場所 |
| `MIHARI_VOICEVOX_SPEAKER` | `14` | 話者 ID。`/speakers` で一覧を引ける。既定の 14 は冥鳴ひまり |
| `MIHARI_VOICEVOX_SPEED` | `1.1` | 話す速さ（`speedScale`）。1.0 がエンジンの既定 |
| `MIHARI_VOICEVOX_INTONATION` | `1.3` | 抑揚の強さ（`intonationScale`）。大きいほど高低の差がつく |
| `MIHARI_VOICEVOX_PITCH` | `0.0` | 声の高さ（`pitchScale`）。話者の印象を変えたくないので既定のまま |
| `MIHARI_VOICEVOX_PRE_PHONEME` | `0.05` | 発話前の無音（秒、`prePhonemeLength`） |
| `MIHARI_VOICEVOX_POST_PHONEME` | `0.05` | 発話後の無音（秒、`postPhonemeLength`） |
| `MIHARI_VOICEVOX_PAUSE_LENGTH` | `0.9` | 句読点などの間の倍率（`pauseLengthScale`）。1.0 未満で間が詰まる |

`bridge/.env` は `.gitignore` 済み。**API キーは絶対にコミットしない。**

同じセリフの音声は合成結果を覚えておくので、2 回目以降は待たされずに鳴る。

`audio_query` の既定値のままだと棒読みに聞こえるので、`synthesis` に渡す前に上表の調整値を
載せている。**検知のセリフ（bridge）とペットのひとりごと（`Pet/PetVoice`）で同じ値を使う**ので、
どちらの経路で喋っても声の印象は揃う。bridge 側は上の環境変数で変えられるが、
ひとりごと側は定数（`Voice/VoicevoxQueryTuning.swift` の `standard`）なのでコードを直す。

音を出す口はアプリで 1 つ（`Voice/SpeechPlayer`）だけで、検知のセリフとペットのひとりごと
（クリック・待機・ドラッグ。bridge を通さず `Pet/PetVoice` が直接 VOICEVOX を叩く）が
これを共有する。どちらを鳴らすかは優先度で決まり（`SpeechPriority` / `SpeechPlaybackArbiter`）、
**検知のセリフは鳴っているものを止めてでも必ず鳴る。** 逆にひとりごとは検知のセリフにかぶせず、
鳴らせないときは溜めずに捨てる（吹き出しは出る）。メニューの「声を出す」はひとりごとにだけ効く。

### キャラの口調を変える

Claude と Gemini に共通の「守ること」は `bridge/src/device_bridge/voice/persona.py` の `PERSONA_RULES`。
Claude 向けの前置きは `voice/generator.py` の `SYSTEM_PROMPT`、スクショを見るときの指示は
`voice/screen_reader.py` の `SYSTEM_PROMPT`。固定文言は `voice/fallback.py`。

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

`VoiceController.isSpeaking` は `SpeechPlayer` の再生完了通知を受けているので、自然に喋り終わっても
`false` に戻る。ただしオーバーレイの解除判定は従来どおりで、セリフの文字数から所要時間を見積もり、
それを「読み上げ完了」とみなしている。見積もりが外れて長引いても、上限秒数のタイマーが必ず先に効く。

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

### 検知への接続

「休憩中?」の問いかけ（`DetectionEngine.Actions.askHeadGesture`）に配線済み。
`AppCoordinator` が `HeadGestureQuestioner` を差し込んでいるだけなので、検知エンジンは
`HeadGestureQuestioner` の存在も `HeadGestureView` の型も知らない。

```swift
askHeadGesture: { [questioner] question, answerWindow in
    await questioner.ask(prompt: question, answerWindow: answerWindow)
}
```

うなずけば はい、首を振れば いいえ として休憩の返事になる。`.timedOut` / `.unavailable` は
回答として扱わない——AirPods が無いことを「いいえ」と読み替える理由がないし、時間切れは
検知側の無反応タイマー（`promptTimeoutSeconds`）が面倒を見る。

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

| Mac 無操作 | 視線 | iPhone | 状態 | やること |
| --- | --- | --- | --- | --- |
| 〜1.5 分 | — | — | 正常 | 何もしない |
| **1 分〜** | **見ていない状態が 15 秒継続** | 応答なし / 置かれたまま | **サボり確定** | **Mac のカメラで顔を撮る** → Discord（音楽が鳴っていれば説教も） |
| **1 分〜** | **見ていない状態が 15 秒継続** | 操作中 | **サボり確定** | **iPhone のスクショを撮る** → Discord（音楽が鳴っていれば説教も） |
| 2〜5 分 | 見ている / 不明 | — | 疑い | 声をかける（撮らない・送らない） |
| 5 分〜 | 見ている / 不明 | 応答なし / 置かれたまま | サボり確定 | Mac のカメラで顔を撮る → 説教 → Discord |
| 5 分〜 | 見ている / 不明 | 操作中 | サボり確定 | iPhone のスクショを撮る → 説教 → Discord |

iPhone の「操作中 / 置かれたまま」は、`bridge/` が画面の点灯状態(IORegistry の
`NormalModeActive`)を読んで返す `active` / `idle` をそのまま使う。判定の詳細と
実機で測った制約は `bridge/README.md` の「既知の制約」にある。

**「画面を見ていない」が 15 秒続いたら、無操作 5 分を待たずに確定する。** 見ていないことが
分かっているなら待つ理由がない。逆に**視線が取れていないときは早期確定しない** ——
カメラが使えないだけで撮られては困る。

### 視線をどう取るか

**手を動かしている間はカメラを一切起動しない。** 緑ランプが点きっぱなしになると、
ただの監視カメラになってしまう。

- 無操作が **1 分**を超えたらカメラを**開けっぱなし**にして見張る
- 触り始めたら閉じて、覚えていた視線も捨てる（席に戻ったのに、さっきの「見ていない」で撮られないように）
- 解析は **4 fps** 程度に間引く。全フレーム解析しても判定は良くならず CPU だけ食う
- 開けた直後 **1.2 秒**は結果を採用しない（露出が落ち着く前は暗くて顔が取れない）

#### なぜ単発フレームをやめたか

最初は「間隔を空けて 1 枚ずつ撮る」方式だったが、実機で 2 つ問題が出た。

1. **1 フレームだと判定が飛ぶ。** 目の開きは同じ姿勢でも 0.066〜0.416 と大きく振れ、
   20 フレーム中 9 回が「見ていない」に振れる回もあった。単発で決めると作業中の人を撮る
2. **撮るたびに自動露出がやり直しになる。** 開始 0.5 秒で撮ると平均輝度 0.017（ほぼ真っ黒）で、
   顔が写っていても検出できなかった（実測: 0.1s→0.016 / 0.5s→0.017 / 1.0s→0.599）

開けっぱなしにして「見ていない状態が続いた秒数」で判断すると、両方とも構造的に消える。
瞬き（0.1〜0.4 秒）は 15 秒の窓に埋もれ、露出はセッションが開いている間ずっと落ち着いている。
- 顔が取れない / 目が閉じている → 見ていない
- 顔が写っていて目が開いている → 見ている
- **検出に失敗した → 不明**（「見ていない」と決めつけない）

### よそ見（yaw）判定は行わない

**この Vision のリビジョンでは `VNFaceObservation.yaw` が使い物にならない。** 実機で測ると
`0.000` か `0.785`（ちょうど π/4 = 45°）の 2 値しか返さず、実際の角度ではなく量子化された値だった。

決定的だったのは、**画面を真っ直ぐ見ている状態で 20 フレーム中の中央値が 0.785 になった**こと。
しきい値 0.35 でよそ見を判定していたら、その回は 20/20 が「よそ見」と判定され、
**作業中の人を撮って Discord に晒していた。**

そのため yaw は判定に一切使わない。「顔の有無」と「目の開き具合」だけで見る。
自己診断では yaw の分布を出し続けているので、将来まともな値が返るようになったら気づける。

外した結果、実機で 20 フレーム中 17〜20 が安定して「見ている」になった。

「iPhone からも反応が無い＝寝ているか席にいない」ので顔を撮り、
「Mac は放置して iPhone を触っている＝何を見ているか」を晒す、という切り分け。

### 説教（全画面オーバーレイ）は音楽が鳴っているときだけ

**止める音楽が無いのに画面を覆っても、「音楽を止めて聞かせる」が空振りするだけ。**
サボり確定でも、Spotify / Music が実際に再生中でなければ画面は奪わない。声はかけるし、
証拠は撮って送る。

| 再生状況 | 説教 | 声かけ | 証拠 |
| --- | --- | --- | --- |
| Spotify / Music が再生中 | **出る** | 出る | 撮って送る |
| 何も鳴っていない | 出ない | 出る | 撮って送る |
| 確認できない（オートメーション権限が無い） | 出ない | 出る | 撮って送る |

**「鳴っていない」と「確認できない」は区別する。** オートメーション権限が無いと再生状況
そのものが取れないので、それを「鳴っていない」と混ぜると原因が分からなくなる。
どちらの場合も、確信が無いまま画面を奪うことはしない。

**止めた音楽は再開しない（既定）。** サボって音楽を聴いていた相手に、説教のあと音楽を
返してやる理由がない。聴き直したければ本人が再生すればよい。
「説教」タブの設定で再開させることもできる。

再生状況の問い合わせは AppleScript なので、**手が動いている間は投げない**。
何も起きない場面で他アプリに毎秒話しかける理由がない。

### 撮りに行かないケース

- **在席スタンプの直後**（既定 5 分）… 本人が指紋で「席にいる」と示した直後に撮ると、ただの嫌がらせになる
- **クールダウン中**（既定 3 分）… これが無いと 5 秒ごとに撮って送り続けることになる

どちらも声はかける。撮って送るところだけを抑える。

### 休憩

疑いに入ったとき、ペットの吹き出しで「休憩中?」と**1 回だけ**聞く。返事は 3 か所から来る
（吹き出しのボタン・AirPods の首振り・無反応タイマー）が、**採用するのは先に来た 1 つだけ**で、
残りは捨てて待っているタスクも畳む（`Detection/BreakPromptSession`）。閉じたあとに届いた
古い返事はセッション ID が違うので通らない。二重に休憩へ入らないための番人。

- **はい** … `breakDurationSeconds`（既定 15 分）休憩に入る。**休憩中は材料を集める前に評価を
  打ち切るので、カメラも開かない。**撮らない・送らない・説教しない・声もかけない。
  時間が明ければ何もしなくても見張りに戻る
- **いいえ / `promptTimeoutSeconds`（既定 20 秒）無反応** … 問いかけを閉じて見張りを続ける

メニューの「休憩する(15 分)」からも同じ休憩に入る。「監視を止める」は休憩に触れず、
「監視を再開する」は休憩中ならその休憩も打ち切る。

### 閾値

すべて `DetectionThresholds` にあり、**全部要調整**。デモしながら詰める前提。
`MIHARI_DEBUG_UI=1` で開く「検知」タブに現在値と、いま何を根拠に判断したかが出る。

| 名前 | 既定 | 意味 |
| --- | --- | --- |
| `suspectSeconds` | 120 | ここを超えたら疑い |
| `confirmSeconds` | 300 | ここを超えたら確定 |
| `gazeWatchSeconds` | 60 | ここまではカメラを起動しない |
| `notLookingDurationSeconds` | 15 | 「見ていない」がこの秒数続いたら確定 |
| `gazeFreshnessSeconds` | 10 | 視線の見立てを信じる期間（カメラ停止直後の古い値で判定しない） |
| `stampGraceSeconds` | 300 | 在席スタンプ直後の猶予 |
| `cooldownSeconds` | 180 | 次に撮るまで空ける |
| `breakDurationSeconds` | 900 | 「休憩中?」に はい と答えたときの休憩の長さ |
| `promptTimeoutSeconds` | 20 | 「休憩中?」の返事を待つ時間 |

### いつ見張り始めるか

**アプリを起動したら自動で見張り始める。** 常駐して見張るアプリなので、ボタンを押すまで
何も起きないのでは監視にならない。メニューバーの「ペット」かペットの右クリックメニューの
「監視を止める / 監視を再開する」から手で止め / 再開もできる。

Discord の `/watch start` `/watch at HH:MM` `/watch stop` からも操作できる。
Python 側のスケジューラが SSE に `watch.start` / `watch.stop` を流し、アプリがそれを受ける。

### 動作確認（しきい値を縮めて通しで見る）

5 分待たずに一連の流れを確かめたいとき:

```sh
make build
MIHARI_FAST_THRESHOLDS=1 ./desktop/Mihari.app/Contents/MacOS/Mihari
```

疑い 10 秒 / 確定 25 秒 / 視線 5 秒から 8 秒継続、休憩 60 秒 / 返事待ち 8 秒、まで縮まる。
判断の様子は次のログで見られる。`MIHARI_DEBUG_UI=1` も付けて起動すると検証用の 10 タブ画面が
開き、「検知」タブの記録でも追える。

```sh
log stream --info --predicate 'subsystem == "com.thirdlf03.mihari"' --style compact
```

実際にこうなる（Discord のトークンが無い状態）:

```
視線の監視を開始する(緑ランプ点灯)
AVCaptureSession を開始する(撮影のみ・緑ランプ点灯)
AVCaptureSession を停止した(緑ランプ消灯)
Discord へ投稿できなかった: HTTP 409 DISCORD_BOT_TOKEN が未設定
confirmed: Mac が 4分 無操作 / iPhone は応答なし / 直前は GatherV2
           → 証拠を取った / Discord に送れなかった
confirmed: 7秒 前に証拠を取ったばかり → 声をかけた
```

**Discord が失敗しても検知が止まらない**ことと、**クールダウンが効いて撮り直さない**ことが
この 1 回で確かめられる。

メニューバーの「ペット > 状態パネルを表示」(ペットの右クリックメニューにもある)で、いま何を見て
どう判断しているかをデスクトップの小さなパネルに出せる。`MIHARI_DEBUG_UI=1` を付けて起動したときは
保存値によらず最初から出る。行は上から順に、状態と段階(丸の色は 正常 = 緑 / 疑い = 橙 / 確定 = 赤 /
停止・休憩 = 灰)と 監視中 / 休憩中(残り) / 停止中、Mac の無操作秒数と確定までのバー(右は実際の閾値で、
`MIHARI_FAST_THRESHOLDS=1` なら縮んだ値がそのまま出る)、視線と目の開き(カメラを開ける秒数に届いて
いなければ「不明(カメラ閉)」)、iPhone、音楽、前面アプリ、在席スタンプからの経過(猶予中かどうか)と
次に撮れるまでのクールダウン、最後の判断の根拠 → 結果とその時刻、デーモンの接続状態とポート。
まだ一度も評価していない行は「—」になる。パネルはドラッグで動かせて、置いた場所と表示の有無は
次の起動にも引き継ぐ。

### 判断の記録

「なぜ撮られたのか」が後から分からないと、閾値を詰めようがないし撮られた本人も納得できない。
発火のたびに **根拠**（無操作時間 / iPhone の様子 / 直前のアプリ）と **結果**（撮れた・送れた・失敗した理由）を残す。

### 壊れ方

**どのアクションが失敗しても評価ループは止めない。** カメラが使えない・VOICEVOX が起動していない・
Discord のトークンが無い、はどれも起こりうる。1 つ転んだせいで見張り自体が死ぬのが一番まずい。
失敗はすべて記録に残して次のループへ進む。

## 自己診断

単体テストは「自分で書いたスタブ相手に、自分で書いたロジックが仕様どおりか」しか見ていない。
カメラが本当に写るか、ScreenCaptureKit が本当に撮れるか、Vision が本当に顔を見つけるかは、
**署名済みの `.app` の中で実際に呼んでみないと分からない。**

```sh
make build
MIHARI_SELFTEST=1 ./desktop/Mihari.app/Contents/MacOS/Mihari
```

画面を出さずに次を通して結果を並べ、終了コードで成否を返す。

| 項目 | 何を確かめるか |
| --- | --- |
| 画面のスクショ | ScreenCaptureKit で実際に PNG が取れるか |
| カメラで 1 枚撮る | AVCaptureSession で実際に PNG が取れるか |
| 写真の見立て | Vision が実際に走り、ラベルが付くか |
| 視線の判定 | 静止画 1 枚での見立てと、目の開き・yaw の生の値 |
| 視線の連続監視 | 6 秒ぶん見張って、見ている/見ていないの内訳と目の開きの分布 |
| 音楽の再生状況 | いま鳴っているか、説教が出る条件を満たすか |
| **全画面オーバーレイの自動解除** | **覆ったあと本当に自力で消えるか** |

最後の 1 つが一番重要。解除されないと Mac が操作不能になるので、
上限秒数を 2 秒に縮めて毎回確かめる。消えなかった場合は手で消したうえで失敗として報告する。

## iPhone のスクリーンショット（実機で確認済み）

iOS 17+ では **DVT 経由**でしか撮れない。`com.apple.mobile.screenshotr` は RSD の
サービス一覧に載っておらず `No such service` になる（iOS 26.4.1 の実機で確認）。
pymobiledevice3 の CLI でも `developer screenshot`（非推奨）は失敗し、
`developer dvt screenshot` だけが成功する。

### 撮れる状態にするまで

**USB が要るのは DDI のマウント時だけ。** マウントが済めばケーブルを抜いてよく、
以降は Wi-Fi で完結する（実機で確認済み）。

1. iPhone を **USB ケーブル**で繋ぐ（「信頼」を許可）
2. 設定 > プライバシーとセキュリティ > デベロッパモード を オン
3. `cd bridge && uv run pymobiledevice3 mounter auto-mount`
   （root 不要。初回はイメージのダウンロードが走る。**Wi-Fi 経由では
   `Connection was terminated abruptly` で落ちるので、ここだけ USB が必須**）
4. `sudo bridge/scripts/start_tunneld.sh`（**root 必須**。常駐し続ける）
5. **ここで USB を抜いてよい。** tunneld は `_remotepairing._tcp` を bonjour で見つけて
   Wi-Fi 側にトンネルを張り直す

`GET /iphone/screenshot/preflight` が 4 項目すべて OK になれば撮れる。
足りない項目には直すためのコマンドが付く。

**USB を抜いても撮れる。** tunneld が Wi-Fi 側にトンネルを張り直すので、`preflight` の
「iPhone に接続できる」もトンネルがあれば OK になる（USB があればそちらを優先する）。
ただし **iPhone がロックされて眠っている間は撮れない** —— トンネルごと消えるため。
画面が点けば tunneld が数秒〜30 秒で張り直し、また撮れるようになる。

### 再セットアップが要るとき

| 何が起きたか | やり直すこと |
| --- | --- |
| Mac を再起動した | 4 だけ（tunneld）。DDI は端末側に残っている |
| **iPhone を再起動した** | **1〜4 全部。** DDI が消えるので USB を挿し直す |
| Wi-Fi が変わった / 圏外になった | tunneld が張り直すまで待つ |

デモ前に一度通して、`preflight` が `ready: true` になることを確認しておくこと。
