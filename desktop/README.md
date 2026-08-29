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
