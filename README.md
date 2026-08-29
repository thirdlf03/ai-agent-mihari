# progate-online-hackathon0829

macOS アプリ(Swift)が Python 側の CLI をサブプロセス起動し、stdout の JSON を受け取って iOS デバイス情報を表示する。

## 構成

| ディレクトリ | 内容 |
| --- | --- |
| `app/` | SwiftUI 製 macOS アプリ(SwiftPM executable パッケージ、ターゲット `MacApp`)。デスクトップペットもここに含む |
| `app/Sources/MacApp/Resources/pets/` | ペットの素材(`pet.json` とスプライトシート) |
| `bridge/` | pymobiledevice3 を使う CLI `device-bridge`(uv 管理) |

```
app/Sources/MacApp/
├── App/MacApp.swift          # @main・ペットメニュー
├── Views/ContentView.swift   # 一覧 + 詳細
├── Models/Device.swift       # JSON に対応する Codable 型
├── Bridge/DeviceBridge.swift # Process で device-bridge を起動
├── Pet/
│   ├── PetManifest.swift         # pet.json に対応する型
│   ├── PetLibrary.swift          # 同梱ペットと ~/.codex/pets の列挙
│   ├── PetAtlas.swift            # スプライトシートのコマ切り出し
│   ├── PetStatus.swift           # 外部向けステータスとアニメーションの対応
│   ├── PetSpeech.swift           # セリフ集と speech.json の読み込み
│   ├── PetVoice.swift            # VOICEVOX でセリフを読み上げる
│   ├── PetController.swift       # 表示状態とふるまいの管理
│   ├── PetWindow.swift           # 浮遊表示する NSPanel
│   ├── PetView.swift             # コマ表示・ドラッグ・メニュー
│   ├── PetSpeechWindow.swift     # 吹き出しを出すペットの子ウィンドウ
│   └── PetSpeechBubbleView.swift # 吹き出しの見た目
└── Resources/pets/mauve/     # 同梱ペットの素材

bridge/src/device_bridge/
├── cli.py                    # argparse・JSON 出力
└── commands/devices.py       # pymobiledevice3 呼び出し
```

## 使い方

ルートの `Makefile` からまとめて実行する。`make` だけで各ターゲットの一覧が出る。

```sh
make setup   # bridge/ の Python 依存を同期する(初回のみ)
make run     # macOS アプリを起動する
make fmt     # Swift / Python を整形する
make lint    # フォーマットと lint を検査する
```

| ターゲット | 内容 |
| --- | --- |
| `setup` | `cd bridge && uv sync` |
| `fmt` | `swift format --in-place` と `ruff format` / `ruff check --fix` |
| `lint` | `swift format lint --strict` と `ruff check` / `ruff format --check` |
| `build` | `cd app && swift build` |
| `run` | `cd app && swift run` |
| `clean` | `rm -rf app/.build` |

Swift の整形設定は `app/.swift-format`、Python の設定は `bridge/pyproject.toml` の `[tool.ruff]` にある。

## 音声

ローカルで VOICEVOX(`http://127.0.0.1:50021`)が起動していれば、ペットのセリフを冥鳴ひまり(speaker 14)の声で読み上げる。

起動していないときは音声を出さず、吹き出しだけを表示する(30 秒ごとに接続を試み直す)。

メニュー「ペット > 声を出す」(ペットの右クリックメニューにもある)で読み上げを切ると、再生中の音声もその場で止まる。この設定は次の起動にも引き継ぐ。

## bridge

CLI を単体で叩く場合:

```sh
cd bridge
uv run device-bridge list
uv run device-bridge list --no-wifi   # Wi-Fi 探索を省略する
uv run device-bridge info --udid <UDID>
```

stdout には常に JSON を 1 つだけ出力する。失敗時は stderr に `{"error": "<message>"}` を出力し、終了コード 1 で終了する。

### Wi-Fi 経由の接続

macOS の usbmuxd は Wi-Fi 上の iPhone を返さないため、bonjour で自前に探す。

1. 一度 USB でつないでペアリングし、その状態で `list` を実行する。見えた UDID は `~/.device-bridge/known_devices.json` にキャッシュされる(`DEVICE_BRIDGE_CACHE_DIR` で変更可)
2. 以降は USB を抜いても、同じ Wi-Fi にいる限り `list` に `{"connection_type": "WiFi", "host": "<IP>"}` として出る。bonjour で見つけたホストへ usbmuxd のペアレコードを使って lockdown 接続し、UDID の一致で突き合わせている
3. `info` も USB で見えなければ自動的に Wi-Fi 経由で取得する

キャッシュが空のときは bonjour 探索をしない。探索する場合 `list` は 2 秒ほど余分にかかる。

## app

Xcode で開く場合:

```sh
open app/Package.swift
```

## ペット

デスクトップの最前面に小さなペットが浮かび、アプリの状態に合わせて動く。

- 他のウィンドウの上に浮かび、全 Space に出る。ドラッグで好きな位置へ動かせて、位置・サイズ・表示状態は次回の起動でも復元される
- ドラッグ中は動かした方向へ走り、手を止めると待機に戻る
- 一覧の取得中は「作業中」(`review` の動き)、失敗すると「失敗」(5 秒で解除)、デバイスが増えたときは「完了」を表示する
- 指示が無いときは自律的に待機・左右への歩行・確認動作を繰り返す
- クリックで手を振り、ダブルクリックで跳ねる
- 頭上の吹き出しでひとこと喋る。しゃべるのは次のとき。セリフは文字数に応じて 2〜6 秒で消え、画面の上に収まらないときは吹き出しがペットの下に出る
  - クリックしたとき(挨拶)、起こしたとき
  - ステータスが変わったとき(作業中 / 入力待ち / 完了 / 失敗)。同じステータスが続いたときは言い直さない
  - ドラッグを始めたとき(たまに)、待機に入ったとき(たまにひとりごと)
  - 右クリックとメニューバーの「しゃべる」を選んだとき
- 右クリックで「しゃべる」「しまう」「ペット」「サイズ(小 / 中 / 大)」「アプリを表示」のメニューが出る
- メニューバーの「ペット」からも同じ操作ができる。表示の切り替えは ⌘⇧P
- 一覧ヘッダーの「ペットを起こす / ペットをしまう」ボタンでも切り替えられる
- システム設定の「視差効果を減らす」が有効なときは、待機の 1 コマ目を静止表示して自律歩行もしない。吹き出しは出るが、フェードは省く

### 素材

素材は `app/Sources/MacApp/Resources/pets/<id>/` に `pet.json` とスプライトシートを置く。

```json
{
  "id": "mauve",
  "displayName": "Mauve",
  "description": "...",
  "spritesheetPath": "spritesheet.webp"
}
```

`${CODEX_HOME:-~/.codex}/pets/<id>/` にある Codex Desktop 用のカスタムペットも自動で一覧に出る。id が同梱ペットと重なる場合は同梱側を優先し、壊れた `pet.json` は読み飛ばす。

### セリフ

同じディレクトリに `speech.json` を置くと、そのペットのセリフを差し替えられる。書いたキーだけが上書きされ、書かなかったキーは既定のセリフのままになる。ファイルが無い場合や壊れている場合も既定のセリフを使う。

```json
{
  "greeting": ["こんにちは。", "呼びました?"],
  "running": ["デバイスを探しています…"],
  "needsInput": ["確認をお願いします。"],
  "ready": ["終わりました。"],
  "blocked": ["うまくいきませんでした…"],
  "idle": ["…。", "退屈です。"],
  "dragging": ["わっ。"],
  "wake": ["おはようございます。"]
}
```

| キー | しゃべる場面 |
| --- | --- |
| `greeting` | クリックされたとき、メニューの「しゃべる」 |
| `running` | 作業中(一覧の取得中) |
| `needsInput` | 入力・確認を待っているとき |
| `ready` | 完了したとき |
| `blocked` | 失敗して止まっているとき |
| `idle` | 待機中のひとりごと |
| `dragging` | ドラッグを始めたとき |
| `wake` | 起こされたとき |

### スプライトシート

8 列 × 9 行、1 セル 192 × 208 px(全体 1536 × 1872 px)の透明背景の画像。未使用のセルは完全に透明にする。各行が 1 つのアニメーションで、末尾まで進んだら先頭へ戻ってループする。

| 行 | アニメーション | 使う列 | 各コマの表示時間 |
| ---: | --- | ---: | --- |
| 0 | idle | 0-5 | 280, 110, 110, 140, 140, 320 ms |
| 1 | running-right | 0-7 | 120 ms ずつ、最後だけ 220 ms |
| 2 | running-left | 0-7 | 120 ms ずつ、最後だけ 220 ms |
| 3 | waving | 0-3 | 140 ms ずつ、最後だけ 280 ms |
| 4 | jumping | 0-4 | 140 ms ずつ、最後だけ 280 ms |
| 5 | failed | 0-7 | 140 ms ずつ、最後だけ 240 ms |
| 6 | waiting | 0-5 | 150 ms ずつ、最後だけ 260 ms |
| 7 | running | 0-5 | 120 ms ずつ、最後だけ 220 ms |
| 8 | review | 0-5 | 150 ms ずつ、最後だけ 280 ms |

`running`(行 7)は足で走る意味ではなく、作業に集中している状態を表す。左向きは専用の行があるので鏡映は使わない。

## 環境変数

| 変数 | 用途 |
| --- | --- |
| `UV_PATH` | `uv` の実行ファイルパス。未設定なら `~/.local/bin/uv`, `/opt/homebrew/bin/uv`, `/usr/local/bin/uv` の順に探索する |
| `DEVICE_BRIDGE_DIR` | `bridge/` のパス。未設定ならソース位置からリポジトリルートを逆算して `<root>/bridge` を使う |
| `DEVICE_BRIDGE_CACHE_DIR` | 既知デバイスキャッシュの置き場。未設定なら `~/.device-bridge` |
| `CODEX_HOME` | カスタムペットを探す Codex のホーム。未設定なら `~/.codex` |

## 注意

iOS 17+ の developer 系機能を使う場合は、別途 tunneld(root 権限が必要)の起動が必要になる。
