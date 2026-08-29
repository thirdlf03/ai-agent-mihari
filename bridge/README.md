# bridge

`device-bridge` CLI と、macOS アプリが子プロセスとして常駐させる HTTP デーモン(FastAPI + uv 管理)。

ルートの `README.md` と `Makefile` からの使い方は [ルート README](../README.md) を参照。ここでは
`bridge/` 単体の詳細と、iPhone のスクリーンショット機能([Issue #13](https://github.com/thirdlf03/progate-online-hackathon0829/issues/13))
のセットアップ手順を書く。

## iPhone のスクリーンショットを撮る

`POST /iphone/screenshot` は `pymobiledevice3 developer screenshot` 相当の処理を行い、PNG を返す。
この機能は次の 3 つが揃って初めて動く。**当日のセットアップで一番つまずきやすい箇所なので、
順番どおりに 1 つずつ確認すること。**

1. Developer Mode が有効になっている
2. DeveloperDiskImage(DDI)がマウントされている
3. iOS 17 以降の場合、developer 系サービス(スクリーンショット含む)は RemoteXPC トンネル越しにしか
   届かないため、**tunneld を root で常駐**させてトンネルを張っておく必要がある

`GET /iphone/screenshot/preflight` を叩けば、上記のどれが欠けているかと直し方が JSON で返る。
迷ったらまずこれを叩く。

### 0. 前提

- iPhone を USB で Mac に接続し、初回は「このコンピュータを信頼しますか」のダイアログで信頼する
- `cd bridge && uv sync` 済みであること(ルートの `make setup` でも可)
- `uv run device-bridge list` で対象の iPhone の UDID が見えること

### 1. Developer Mode を有効にする

iOS 16 以降、Developer Mode は既定で無効になっている。CLI から有効化リクエストを送る。

```sh
cd bridge
uv run pymobiledevice3 amfi enable-developer-mode
```

- iPhone が自動的に再起動する
- 再起動後、画面の指示に従って「オンにする」を選ぶと確認プロンプトが出る。このコマンドは
  再起動後の確認プロンプトへの応答まで自動で行う(内部で `enable_developer_mode_post_restart`
  を呼ぶ)
- 端末にパスコードが設定されていないと失敗する(`DeviceHasPasscodeSetError`)。先にパスコードを
  設定しておくこと
- 有効になっているかどうかは以下で確認できる

```sh
uv run pymobiledevice3 amfi developer-mode-status
```

### 2. DeveloperDiskImage(DDI)をマウントする

```sh
cd bridge
uv run pymobiledevice3 mounter auto-mount
```

- iOS のバージョンに応じて、pre-17 なら `Developer` イメージ、17+ なら `Personalized` イメージを
  自動判別してダウンロード・マウントする
- 初回はイメージのダウンロードが走るのでネットワークが必要
- すでにマウント済みの場合は `AlreadyMountedError` になるが、これは失敗ではない
- iOS のバージョンが上がると DDI の再マウントが必要になることがある(既知のリスク)。撮影が
  急にできなくなったら、まずここをやり直す

マウント済みかどうかは以下で確認できる。

```sh
uv run pymobiledevice3 mounter list
```

### 3. (iOS 17+ のみ)tunneld を root で常駐させる

iOS 17 以降は、DDI をマウントしていても developer 系サービスに直接は繋げない。Apple が
developer サービスを RemoteXPC ベースのトンネル越しでしか公開しなくなったため、
このトンネルを維持する **tunneld** を root 権限で常駐させておく必要がある。
**ここが当日のセットアップで一番の障害になりやすい。**

ヘルパースクリプトを使う場合:

```sh
bridge/scripts/start_tunneld.sh
```

- root でなければ自動的に `sudo` で再実行する(パスワードを聞かれる)
- `uv` が `PATH` に無い環境では `UV_PATH=/path/to/uv bridge/scripts/start_tunneld.sh` のように
  明示する(探索順はルート README の環境変数の節と同じ)
- Ctrl-C で終了するまでフォアグラウンドで動き続ける常駐プロセスなので、専用のターミナルタブ
  (または `tmux`)を 1 つ割り当てておく。デーモン化したい場合は自前で `nohup` 等を使うこと

直接コマンドを叩く場合:

```sh
cd bridge
sudo uv run pymobiledevice3 remote tunneld
```

起動後、`GET /iphone/screenshot/preflight` の `tunneld_reachable` が `true` になれば準備完了。
iOS 16 以前ではこの手順は不要(`preflight` も自動でスキップしたと表示する)。

### 4. 動作確認

デーモンを起動した状態で(`make run` でアプリごと起動するか、`uv run device-bridge serve --token <token>`
を直接起動する)、以下を叩く。

```sh
# 前提が揃っているか
curl -s -H "X-Mihari-Token: <token>" http://127.0.0.1:<port>/iphone/screenshot/preflight | python3 -m json.tool

# 実際に撮る(PNG を保存)
curl -s -X POST -H "X-Mihari-Token: <token>" http://127.0.0.1:<port>/iphone/screenshot -o screenshot.png
```

`preflight` の `ready` が `false` の場合、`checks` の中の `ok: false` な項目の `remediation` を
上から順に実行すればよい。

## REST エンドポイント一覧(iPhone スクリーンショット関連)

すべて `X-Mihari-Token` ヘッダによる認証が要る(トークンはアプリ起動時に生成される)。

### `GET /iphone/screenshot/preflight`

前提が揃っているかのセルフチェック。撮影を試みず、常に `200` を返す。

```json
{
  "ready": false,
  "udid": "00008030-XXXXXXXXXXXXXXXX",
  "ios_version": "17.5.1",
  "checks": [
    { "id": "device_connected", "ok": true, "label": "iPhone に接続できる", "remediation": null },
    { "id": "developer_mode", "ok": true, "label": "Developer Mode が有効", "remediation": null },
    { "id": "ddi_mounted", "ok": false, "label": "DeveloperDiskImage がマウント済み", "remediation": "`uv run pymobiledevice3 mounter auto-mount` で DeveloperDiskImage をマウントする(初回はイメージのダウンロードが走る)" },
    { "id": "tunneld_reachable", "ok": false, "label": "tunneld に到達できる", "remediation": "root で tunneld を常駐させる: `sudo bridge/scripts/start_tunneld.sh`(内部で `pymobiledevice3 remote tunneld` を実行する)。起動直後は端末側のトンネル確立に数秒かかる" }
  ]
}
```

`udid` はデバイスが見つからないときは `null`、`ios_version` は取得できなかったときも `null` になる。

### `POST /iphone/screenshot`

スクリーンショットを撮る。成功すると `image/png` の PNG バイナリを返す。

| ステータス | 意味 |
| --- | --- |
| `200` | 撮影成功。`Content-Type: image/png` で PNG を返す |
| `409` | 前提が 1 つ以上欠けている。`detail.preflight` に `preflight` と同じ形の内訳が入る |
| `502` | 前提は揃っているが撮影処理自体が失敗した(端末との通信断など)。`detail` にメッセージが入る |
| `401` | `X-Mihari-Token` が無い・一致しない |

撮影した PNG はサーバ側の一時ディレクトリ(既定は `$TMPDIR/device-bridge/screenshots/`)へ一度
保存してからレスポンスとして送り、送信完了後にバックグラウンドタスクで削除する。長期保存はしない
(Epic の非目標「撮影した画像の長期保存をしない」に合わせている)。

## 既知の制約

- Darwin 通知や developer サービスの内部仕様は非公開であり、iOS のバージョンによって挙動が
  変わる可能性がある(`get_developer_mode_status` / DDI マウント確認 / tunneld の到達確認は
  いずれも pymobiledevice3 の実装に依存する)
- iOS のバージョンが上がると DDI が外れ、再マウントが必要になることがある
- tunneld は root 常駐が前提のプロセスであり、アプリからは制御できない。ユーザーが手動で
  起動しておく運用になる
- `com.apple.mobile.screenshotr` は PNG ではなく TIFF を返すことがあるため、本実装は Pillow で
  PNG へ変換して常に PNG を保証している

## テスト

```sh
cd bridge
uv run pytest -q
```

実機が無い環境でも全件パスする。`commands/screenshot_source.py`(実機通信)は
`commands/screenshot.py` が定義する `ScreenshotSource` プロトコルの背後に隔離してあり、
テストはフェイクの `ScreenshotSource` に差し替えて検証する(`commands/iphone_state.py` /
`iphone_state_source.py` と同じ方針)。
