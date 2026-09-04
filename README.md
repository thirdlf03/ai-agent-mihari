# Mihari

**Mihari** — サボりを検知して声で絡み、証拠を Discord に晒す macOS 常駐アプリ。
全体像と設計の決定事項は [Issue #2 (Epic)](https://github.com/thirdlf03/ai-agent-mihari/issues/2) にまとめてある。

## 構成

| ディレクトリ | 内容 |
| --- | --- |
| `desktop/` | 検知・撮影・説教・Discord・ペットを担うアプリ本体 `Mihari`。詳細は [desktop/README.md](desktop/README.md) |
| `bridge/` | Python 側。`device-bridge` CLI と、アプリが常駐させる HTTP デーモン(uv 管理) |
| `scripts/` | 補助スクリプト。同封音声の生成(`generate_voice_lines.py`) |

アプリは起動時に `bridge/` のデーモンを子プロセスとして立ち上げる。
Swift → Python は `127.0.0.1` の REST、Python → Swift は SSE。

```
desktop/Sources/MihariCore/
├── App/                # 起動の取りまとめ・メニュー・補助ウィンドウ
├── Detection/          # サボり判定の状態機械(疑い 3 段階 → 晒し → メンヘラ)
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
├── Resources/pets/mauve/         # 同梱ペットの素材
└── Resources/voice/              # セリフの原本 lines.json と同封音声 <区分>/<NN>.m4a

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

声は冥鳴ひまり(VOICEVOX の speaker 14)で固定。**音声モードが 2 つある。**

| モード | セリフ | 音声 | VOICEVOX |
| --- | --- | --- | --- |
| `bundled`(既定) | `desktop/Sources/MihariCore/Resources/voice/lines.json` から抽選 | アプリに同封した `.m4a` をそのまま鳴らす | 要らない |
| `live` | bridge が LLM で作る(ペットのひとりごとは同じ `lines.json`) | その場で合成 | 起動している必要がある |

既定は同封なので、**何も用意しなくても声は出る。** live を使うときだけ VOICEVOX を起動する
(起動していなければ音声は出ず、吹き出しだけになる。30 秒ごとに接続を試み直す)。

切り替えは 3 通り。

- ペットの右クリック →「デバッグ」→「音声」。再起動なしで効き、次の起動にも引き継ぐ
- `MIHARI_DEBUG_UI=1` で開く検証画面の「セリフと声」タブ。同封音声の試聴もできる
- 起動時に `MIHARI_VOICE_MODE=live`(または `bundled`)。**環境変数が最優先**で、付けている間はメニューで切り替えても次の起動でまた環境変数に戻る

メニュー「ペット > 声を出す」(ペットの右クリックメニューにもある)で読み上げを切ると、再生中の音声もその場で止まる。この設定は次の起動にも引き継ぐ。

### 同封音声を作り直す

セリフ(`lines.json`)を直したら、VOICEVOX を起動してから作り直す。

```sh
python3 scripts/generate_voice_lines.py              # 全 108 本
python3 scripts/generate_voice_lines.py --only idle   # 区分を絞る
python3 scripts/generate_voice_lines.py --url http://127.0.0.1:50021
```

`desktop/Sources/MihariCore/Resources/voice/<区分>/<NN>.m4a` に書き出す(`NN` は `lines.json` の
配列インデックス)。Python 3 の標準ライブラリと `/usr/bin/afconvert` だけで動くので `uv` は要らない。
声の調整値(速さ・抑揚・間)は live 側と同じものを使うので、どちらで喋っても印象は揃う。

## Discord

証拠は Discord に投稿する。投稿先のチャンネルは「Discord 設定…」(ペットの右クリックメニュー)から選ぶ。

### 呼びつける相手(メンション)

同じ画面の「メンション先」に Discord のユーザー ID を入れて「保存」を押すと、投稿の先頭に
`<@ID>` が付く。空にして保存すると外れる。「テスト投稿」で 1 通だけ試せる。

ID の調べ方:

1. Discord の 設定 → 詳細設定 → **開発者モード** を ON にする
2. 自分のアイコンを右クリック →「ユーザー ID をコピー」

数字だけの文字列(例 `123456789012345678`)になる。メンションを本文に足すのは bridge 側なので、
アプリが組み立てる文面には入っていない。

### 投稿の文面

1 行目で「何をしていたか」を言い、2 行目(Discord の小文字表示)に事実を並べる。
iPhone の画面を撮れたときは、そこに映っていたアプリと大まかな内容に触れる。
全パターンは [docs/pet.md](docs/pet.md) の「Discord の文面」にある。

## bridge

CLI を単体で叩く場合:

```sh
cd bridge
uv run device-bridge list
uv run device-bridge list --no-wifi   # tunneld のトンネル(Wi-Fi)経由のデバイスを一覧に含めない
uv run device-bridge info --udid <UDID>
```

stdout には常に JSON を 1 つだけ出力する。失敗時は stderr に `{"error": "<message>"}` を出力し、終了コード 1 で終了する。

### Wi-Fi 経由の接続

macOS の usbmuxd は Wi-Fi 上の iPhone を返さない。bonjour(`_apple-mobdev2._tcp`)で自前に探して lockdown する方式は**廃止した**(実測で使えなかった。理由は [bridge/README.md](bridge/README.md) の「bonjour 経由の Wi-Fi lockdown はやめた」)。代わりに **tunneld が張っている RemoteXPC トンネル**(iOS 17+)を Wi-Fi 経路として使う。

1. 一度 USB でつないでペアリングし、RemotePairing レコードを作る(これが無いと tunneld はトンネルを張れない)
2. tunneld を root で常駐させる(`sudo bridge/scripts/install_tunneld_daemon.sh`)。Wi-Fi 側の監視は既定で ON なので追加の指定は要らない
3. 以降は USB を抜いても、同じ Wi-Fi にいる限り `list` に `{"connection_type": "Tunnel", "host": null}` として出る。USB で見えているデバイスは従来どおり `{"connection_type": "USB", "host": null}` で、こちらが優先される
4. `info` も USB で見えなければ自動的にトンネル経由で取得する

**iPhone がロックされて眠っている間はトンネルごと消えるため、`list` からも消えて「応答なし」になる。** 画面が点けば tunneld が数秒〜30 秒で張り直す。

`~/.device-bridge/known_devices.json`(`DEVICE_BRIDGE_CACHE_DIR` で変更可)への UDID の記録は続けているが、探索には使わなくなった。

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

`MIHARI_DEBUG_UI=1` を付けて起動すると、従来の 10 タブ検証画面が開く(`MIHARI_SELFTEST=1` の自己診断、`MIHARI_FAST_THRESHOLDS=1` の閾値短縮は従来どおり)。閾値短縮は起動後でもペットの右クリック →「デバッグ」→「検知の閾値」から切り替えられる(次回起動には引き継がない)。

### メニュー

メニューバーの「ペット」と、ペットの右クリックメニューは同じ中身。

| 項目 | 内容 |
| --- | --- |
| 監視を止める / 監視を再開する | 見張りの開始と停止。「再開する」は休憩中ならその休憩も打ち切る。「止める」は休憩に触れない |
| 在席スタンプを押す | Touch ID で在席を証明する。直後は撮りに行かない。**5 分の猶予が付くのはこのメニューから押したときだけ**(疑い 1 の Touch ID では付かない) |
| 休憩する(15 分) / 休憩を終える | 休憩に入る / 切り上げる |
| Discord 設定… | 投稿先のチャンネルとメンション先を決める画面を開く |
| 権限の確認… | 権限の一覧を開く |
| サイズ | 小 / 中 / 大 |
| 声を出す | ひとりごとを読み上げるか |
| 状態パネルを表示 | 無操作時間・視線・iPhone・デーモンの様子をデスクトップの小さなパネルに出す(デバッグ用) |
| デバッグ | 検知の状態やアニメーションを手で起こして見た目を確かめる(開発用) |

「デバッグ」は検知を待たずに状態・9 種のアニメーション・セリフを試すためのサブメニュー。中身は [docs/pet.md](docs/pet.md) を参照。

### 監視の流れ

Mac を触らない時間が伸びるほど、絡み方が段階的に強くなる。数値は既定値で、括弧の中は
`MIHARI_FAST_THRESHOLDS=1` を付けたときの値。この短縮は「デバッグ」→「検知の閾値」からも切り替えられる。

| 段階 | 入る条件 | やること |
| --- | --- | --- |
| 疑い 1 | 無操作 60 秒(15 秒) | Touch ID で在席を確かめる。10 秒待って指が来なければ次へ |
| 疑い 2 | 疑い 1 から無操作が 30 秒(10 秒)続く | AirPods の首振り(はい / いいえ)で問いかける。20 秒(8 秒)無反応なら次へ |
| 疑い 3 | 疑い 2 から 30 秒(10 秒) | 最終警告を 1 回喋るだけ。確認はしない |
| 晒し | 疑い 3 から 30 秒(10 秒) | 証拠を撮って Discord に送る。音楽が鳴っていれば説教のオーバーレイも出す |
| メンヘラ | 晒し終わった直後 | 戻ってくるまで 60 秒(15 秒)ごとに Discord へ送り続ける。300 秒(60 秒)ごとに証拠を撮り直して添える |

- どの段階でも Mac を触った瞬間に正常へ戻る。疑いの途中なら黙って戻り、メンヘラ中なら「戻ってきた」を **1 通だけ(メンションなし)** 送って終わる
- 疑い 1 の Touch ID に成功しても猶予は付かない。5 分の猶予が付くのはメニューの「在席スタンプを押す」だけ
- 「監視を止める」「休憩する」「在席スタンプを押す」は、どの段階でも即座に畳む。Discord には何も送らない
- 証拠は iPhone を触っていれば iPhone のスクショ、それ以外は Mac のカメラ

### 検知の状態とペットの動き

| 検知の状態 | ペット |
| --- | --- |
| 正常 | 自律行動(待機・歩行・確認)。正常に戻った瞬間だけ `waving` を 1 回 |
| 疑い 1 / 2 / 3 | `waiting` で固定。段階が上がった瞬間だけ `jumping` を 1 回挟む |
| 晒し / メンヘラ | `failed` で固定。晒しに入った瞬間だけ `jumping` を 1 回挟む |
| 問いかけ中 | `waiting` で固定。吹き出しに はい / いいえ のボタンが出る |
| 監視停止中 / 休憩中 | 静止する |

### 疑い 2 の問いかけ

疑い 2 に入ると、ペットが「私のこと、好き?」のような質問を吹き出しに出す。

- **はい**(吹き出しのボタン、または AirPods でうなずく)… 「縦に振った」とセリフで言い返して正常に戻る
- **いいえ**(ボタン、または AirPods で横に振る)… 「横に振った」と言い返し、疑い 2 のまま待つ
- 20 秒無反応 … 問いかけを閉じて、疑い 2 のまま待つ

**縦横どちらに振ったと認識したかを必ずセリフで言う**ので、取り違えたときはその場で分かる。
休憩に入りたいときはメニューの「休憩する(15 分)」を使う。

### 声

冥鳴ひまり(VOICEVOX の話者 14)で固定。既定の同封モードでは、検知のセリフもひとりごとも説教も、
あらかじめ作っておいた `.m4a` をそのまま鳴らす(詳しくは上の「音声」)。

`live` にすると `bridge/` が作る。検知のセリフは Claude API で生成 → VOICEVOX で合成し、iPhone を
触っているサボりでは撮った証拠のスクショを Gemini に見せて「何のアプリで何をしているか」に触れた
セリフにする(読めなければ Claude → 固定文言に落ちる)。ひとりごとは macOS 側から直接 VOICEVOX を叩く。

音を出す口は 1 つしかないので、**検知のセリフを優先する。** ひとりごとを鳴らしている最中に検知のセリフが来たらひとりごとを止め、検知のセリフを鳴らしている最中のひとりごとは鳴らさず吹き出しだけ出す。メニューの「声を出す」はひとりごとにだけ効く。

### 集中継続

サボりを見つけたときだけでなく、正常が 15 分続くたびにペットが褒める。疑い以上の判定・休憩・監視の
停止で数え直す。間隔は右クリック →「デバッグ」→「集中継続の間隔」で 1 分に落とせる。

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
| `greeting` | クリックされたとき |
| `idle` | 待機中のひとりごと |
| `dragging` | ドラッグを始めたとき |
| `wake` | 起こされたとき |
| `watchStart` | 監視が始まったとき |
| `breakEnd` | 休憩が明けたとき |
| `focusStreak` | 集中が続いているとき(褒める) |

既定のセリフは `desktop/Sources/MihariCore/Resources/voice/lines.json` にある。差し替えたセリフには
同封音声が無いので、同封モードでは吹き出しだけになる。

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
| `MIHARI_VOICE_MODE` | 音声モード。`bundled`(既定)か `live`。付けると保存した設定より優先される |

## 注意

iOS 17+ の developer 系機能を使う場合は、別途 tunneld(root 権限が必要)の起動が必要になる。
