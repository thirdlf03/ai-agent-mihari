# progate-online-hackathon0829

**Mihari** — サボりを検知して声で絡み、証拠を Discord に晒す macOS 常駐アプリ。
全体像と設計の決定事項は [Issue #2 (Epic)](https://github.com/thirdlf03/progate-online-hackathon0829/issues/2) にまとめてある。

## 構成

| ディレクトリ | 内容 |
| --- | --- |
| `desktop/` | 検知・撮影・説教・Discord・ペットを担うアプリ本体 `Mihari`。詳細は [desktop/README.md](desktop/README.md) |
| `bridge/` | Python 側。`device-bridge` CLI と、アプリが常駐させる HTTP デーモン(uv 管理) |

アプリは起動時に `bridge/` のデーモンを子プロセスとして立ち上げる。
Swift → Python は `127.0.0.1` の REST、Python → Swift は SSE。

```
desktop/Sources/MihariCore/
├── App/                # 起動の取りまとめ・メニュー・補助ウィンドウ
├── Detection/          # サボり判定の状態機械と「休憩中?」の問いかけ
├── Capture/            # カメラ / 画面のスクショ
├── Vision/             # 撮った写真のラベル付け(寝てる / よそ見 / 不在)
├── Overlay/            # 説教の全画面オーバーレイ
├── Voice/              # セリフの取得と再生(アプリで唯一の音の出口)
├── Daemon/             # bridge のデーモンの起動・REST・SSE
├── Discord/            # 証拠の投稿とチャンネル選択
├── Attendance/         # 在席スタンプ(Touch ID)
├── HeadGesture/        # AirPods の首振り(はい / いいえ)
├── Permissions/        # TCC 権限の照会と要求
├── Views/              # 権限画面と検証用の 10 タブ画面
├── Pet/
│   ├── LivePetPresenter.swift    # 検知イベントをペットの動きに落とす
│   ├── PetPresenting.swift       # 検知側が知る唯一のインターフェース
│   ├── PetEvent.swift            # 検知側から渡すイベント
│   ├── PetController.swift       # 表示状態とふるまいの管理
│   ├── PetWindow.swift           # 浮遊表示する NSPanel
│   ├── PetSpriteView.swift       # コマ表示・ドラッグ・右クリック
│   ├── PetMenuContent.swift      # メニューバーと右クリックで共有する中身
│   ├── PetManifest.swift         # pet.json に対応する型
│   ├── PetLibrary.swift          # 同梱ペットと ~/.codex/pets の列挙
│   ├── PetAtlas.swift            # スプライトシートのコマ切り出し
│   ├── PetSpeech.swift           # セリフ集と speech.json の読み込み
│   ├── PetVoice.swift            # ひとりごとを VOICEVOX で読み上げる
│   ├── PetSpeechWindow.swift     # 吹き出しを出すペットの子ウィンドウ
│   └── PetSpeechBubbleView.swift # 吹き出しの見た目
└── Resources/pets/mauve/         # 同梱ペットの素材

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
| `build` | `cd desktop && ./build.sh`(`Mihari.app` を組み立てて ad-hoc 署名する) |
| `run` | `cd desktop && ./run.sh`(ビルドして `Mihari.app` を起動する) |
| `test` | `cd desktop && swift test` と `cd bridge && uv run pytest` |
| `clean` | `rm -rf desktop/.build desktop/Mihari.app` |

Swift の整形設定は `desktop/.swift-format`、Python の設定は `bridge/pyproject.toml` の `[tool.ruff]` にある。

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

## ペット

デスクトップの最前面に小さなペットが浮かび、検知の状態に合わせて動く。Mihari の操作はすべてこのペットから行い、ふだんはウィンドウを出さない。ソースは `desktop/Sources/MihariCore/Pet/`。細かい挙動と全セリフは [docs/pet.md](docs/pet.md)。

- 他のウィンドウの上に浮かび、全 Space に出る。ドラッグで好きな位置へ動かせて、位置・サイズ・表示状態・選んだペット・「声を出す」の設定は次回の起動でも復元される
- ドラッグ中は動かした方向へ走り、手を止めると待機に戻る
- 指示が無いときは自律的に待機・左右への歩行・確認動作を繰り返す
- クリックで手を振り、ダブルクリックで跳ねる
- 頭上の吹き出しでひとこと喋る。セリフは文字数に応じて 2〜6 秒で消え、画面の上に収まらないときは吹き出しがペットの下に出る
- システム設定の「視差効果を減らす」が有効なときは、待機の 1 コマ目を静止表示して自律歩行もしない。吹き出しは出るが、フェードは省く

### 起動フロー

初回、または必須権限(カメラ / マイク / 画面収録 / 入力監視)のどれかが欠けているときだけ、「権限の確認」ウィンドウが出る。必須が揃うと「始める」が押せるようになり、押すとウィンドウが閉じてペットが出て、デーモンが起動し、監視が始まる。2 回目以降は必須が揃っていればウィンドウを出さず、起動と同時に監視を始める。

オートメーション(説教中に音楽を止める)とモーション(AirPods の首振り)は任意で、欠けていても「始める」は押せる。画面収録だけは、システム設定で許可したあとにアプリを再起動しないと反映されない。

Dock のアイコンは残る。クリックすると、しまわれているペットが出る(ウィンドウは開かない)。

`MIHARI_DEBUG_UI=1` を付けて起動すると、従来の 10 タブ検証画面が開く(`MIHARI_SELFTEST=1` の自己診断、`MIHARI_FAST_THRESHOLDS=1` の閾値短縮は従来どおり)。

### メニュー

メニューバーの「ペット」と、ペットの右クリックメニューは同じ中身。

| 項目 | 内容 |
| --- | --- |
| 監視を止める / 監視を再開する | 見張りの開始と停止。「再開する」は休憩中ならその休憩も打ち切る。「止める」は休憩に触れない |
| 在席スタンプを押す | Touch ID で在席を証明する。直後は撮りに行かない |
| 休憩する(15 分) / 休憩を終える | 休憩に入る / 切り上げる |
| Discord 設定… | 投稿先のチャンネルを選ぶ画面を開く |
| 権限の確認… | 権限の一覧を開く |
| サイズ | 小 / 中 / 大 |
| 声を出す | ひとりごとを読み上げるか |
| 状態パネルを表示 | 無操作時間・視線・iPhone・デーモンの様子をデスクトップの小さなパネルに出す(デバッグ用) |

### 検知の状態とペットの動き

| 検知の状態 | ペット |
| --- | --- |
| 正常 | 自律行動(待機・歩行・確認)。正常に戻った瞬間だけ `waving` を 1 回 |
| 疑い | `waiting` で固定 |
| サボり確定 | `failed` で固定。エスカレーション段階が上がったときだけ `jumping` を 1 回挟む |
| 問いかけ中 | `waiting` で固定。吹き出しに はい / いいえ のボタンが出る |
| 監視停止中 / 休憩中 | 静止する |

### 「休憩中?」の問いかけ

疑いに入ったときに 1 回だけ聞く。

- **はい**(吹き出しのボタン、または AirPods でうなずく)… 15 分の休憩に入る。そのあいだは撮影・送信・説教・声かけをすべて止め、時間が来たら自動で監視に戻る
- **いいえ**、または 20 秒無反応 … 問いかけを閉じて監視を続ける

### 声

冥鳴ひまり(VOICEVOX の話者 14)で固定。声の経路は 2 本ある。

- 検知のセリフ … `bridge/` が作る(Claude API でセリフ生成 → VOICEVOX で合成)
- ペットのひとりごと(クリック・待機・ドラッグ)… macOS 側から直接 VOICEVOX を叩く

音を出す口は 1 つしかないので、**検知のセリフを優先する。** ひとりごとを鳴らしている最中に検知のセリフが来たらひとりごとを止め、検知のセリフを鳴らしている最中のひとりごとは鳴らさず吹き出しだけ出す。メニューの「声を出す」はひとりごとにだけ効く。

### 素材

素材は `desktop/Sources/MihariCore/Resources/pets/<id>/` に `pet.json` とスプライトシートを置く。

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
  "idle": ["…。", "退屈です。"],
  "dragging": ["わっ。"],
  "wake": ["おはようございます。"]
}
```

| キー | しゃべる場面 |
| --- | --- |
| `greeting` | クリックされたとき、メニューの「しゃべる」 |
| `idle` | 待機中のひとりごと |
| `dragging` | ドラッグを始めたとき |
| `wake` | 起こされたとき |

`running` / `needsInput` / `ready` / `blocked` は旧デスクトップペット由来のキーで、いまは使っていない。書いてあっても読み飛ばさずに読み込むだけで、どこでも喋らない。

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
