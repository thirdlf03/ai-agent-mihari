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
