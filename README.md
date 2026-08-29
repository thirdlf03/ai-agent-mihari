# progate-online-hackathon0829

**Mihari** — サボりを検知して声で絡み、証拠を Discord に晒す macOS 常駐アプリ。
全体像と設計の決定事項は [Issue #2 (Epic)](https://github.com/thirdlf03/progate-online-hackathon0829/issues/2) にまとめてある。

## 構成

| ディレクトリ | 内容 |
| --- | --- |
| `desktop/` | アプリ本体 `Mihari`(SwiftUI / SwiftPM)。詳細は [desktop/README.md](desktop/README.md) |
| `bridge/` | Python 側。`device-bridge` CLI と、アプリが常駐させる HTTP デーモン(uv 管理) |
| `app/` | **参照用に凍結。** 旧 macOS アプリ(`MacApp`)。Wi-Fi 経由の lockdown 接続の実装を読むために残している |

アプリは起動時に `bridge/` のデーモンを子プロセスとして立ち上げる。
Swift → Python は `127.0.0.1` の REST、Python → Swift は SSE。

```
app/Sources/MacApp/
├── App/MacApp.swift          # @main
├── Views/ContentView.swift   # 一覧 + 詳細
├── Models/Device.swift       # JSON に対応する Codable 型
└── Bridge/DeviceBridge.swift # Process で device-bridge を起動

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

## 環境変数

| 変数 | 用途 |
| --- | --- |
| `UV_PATH` | `uv` の実行ファイルパス。未設定なら `~/.local/bin/uv`, `/opt/homebrew/bin/uv`, `/usr/local/bin/uv` の順に探索する |
| `DEVICE_BRIDGE_DIR` | `bridge/` のパス。未設定ならソース位置からリポジトリルートを逆算して `<root>/bridge` を使う |
| `DEVICE_BRIDGE_CACHE_DIR` | 既知デバイスキャッシュの置き場。未設定なら `~/.device-bridge` |

## 注意

iOS 17+ の developer 系機能を使う場合は、別途 tunneld(root 権限が必要)の起動が必要になる。
