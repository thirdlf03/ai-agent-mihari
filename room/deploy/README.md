# deploy — Mihari Room（VPS 版）運用

みはりちゃんの作業部屋を ConoHa 1 台で回すための運用資料。
デーモンは **1 プロセス**（HTTP + Discord + in-process Hermes `AIAgent`）。
Hermes の Discord Gateway は起動しない。

このディレクトリのファイル:

| ファイル | 役割 |
| --- | --- |
| `env.example` | 環境変数の雛形。実値は書かない |
| `mihari-room.service` | systemd unit（foreground uvicorn、restart、umask、サンドボックス） |
| `Caddyfile.example` | Caddy 例（API ホスト + プレビュー ホスト。プレビューは Room へ reverse_proxy） |
| `cloudflared-preview.yml.example` | Cloudflare Tunnel でプレビューだけ公開する例 |
| `backup.sh` | バックアップ（停止 or `--live-consistent`、WAL 対応、mode 600） |

## 構成

```
/var/lib/mihari/
├── room/                  MIHARI_ROOM_ROOT
│   ├── jobs/<id>/         meta.json / input/ / output/ / followup-*.txt / hermes_session_id
│   ├── messages.db        Discord アーカイブ（SQLite WAL + FTS5）
│   ├── archive/           添付の実体
│   └── previews/          公開してよい静的成果物（Room の GET /previews が配信）
├── hermes/                HERMES_HOME（Hermes 専用プロファイル。既定の ~/.hermes には触れない）
│   ├── state.db(-wal/-shm) セッション/メモリ（SQLite WAL）
│   ├── config.yaml / .env
│   ├── sessions/ memories/ skills/ hooks/ cron/ plugins/ pairing/
├── hermes-agent/          Hermes ソース（下のリビジョンに pin。.venv もここにできる）
├── room-venv/             mihari-room の venv（uv sync --locked）
└── backups/               バックアップ先（mode 700、中身 600）
/etc/mihari-room/env       EnvironmentFile（mode 600、root:mihari）
```

聞き口は **127.0.0.1:8787 のみ**。外には Caddy が出す（API ホスト / プレビュー ホスト）。

## 0. 前提（初回）

- ConoHa VPS（Ubuntu 24.04 想定）。`sudo` できるユーザーで作業する
- DNS: 下のドメイン例を実値に置き換える（`.example.com` のままだと動かない）
- 専用ユーザーを作る:

```sh
sudo useradd --system --home /var/lib/mihari --create-home --shell /usr/sbin/nologin mihari
sudo mkdir -p /var/lib/mihari/room /var/lib/mihari/hermes /var/lib/mihari/backups /etc/mihari-room
sudo chown -R mihari:mihari /var/lib/mihari
sudo chmod 700 /var/lib/mihari/backups
```

## 1. Hermes のインストール（pin 固定）

in-process で import するので、**リビジョンを固定**して、その venv の Python で動かす。

- 上流: `NousResearch/hermes-agent`
- **pin するリビジョン: `365e2835d490a053d076daa3b429371d6f35210f`**
  （2026-09-02 の commit。ローカル開発機 `~/.hermes/hermes-agent` の git HEAD を
  read-only で解決した実値。`git rev-parse HEAD` で同じ値が出ることを確認してからデプロイする）
- **Python は 3.11 に揃える**
  - 理由: Hermes は `requires-python = ">=3.11,<3.14"`。in-process で import
    するので、room も同じ 3.11 で動かす（`room/pyproject.toml` は `>=3.11`、
    `room/.python-version` は `3.11`）
  - 3.14 の標準ライブラリ（とくに sqlite3）を 3.11 の Hermes に混ぜると落ちる。
    room の venv と hermes の venv を両方 3.11 にし、開発機の 3.14 とは混ぜない

```sh
sudo -u mihari git clone https://github.com/NousResearch/hermes-agent.git /var/lib/mihari/hermes-agent
cd /var/lib/mihari/hermes-agent
git checkout 365e2835d490a053d076daa3b429371d6f35210f   # 必ず pin の値で
sudo -u mihari uv python install 3.11
sudo -u mihari env HERMES_HOME=/var/lib/mihari/hermes \
    uv sync --locked --python 3.11
```

- `uv sync --locked` が `pyproject.toml`＋`uv.lock` どおりに `.venv` を作り、
  hermes-agent 自体を editable で入れる。`--python 3.11` で venv の Python を固定
- このあと `HERMES_PYTHON=/var/lib/mihari/hermes-agent/.venv/bin/python` を
  `/etc/mihari-room/env` に入れる（省略時は PATH の hermes の shebang から探すが、
  専用ユーザーには PATH に hermes が居ないので必ず明示する）
- pin した日時点の依存は lock に閉じている。`uv sync` は `--locked` を必ず付ける
- Hermes は自分専用の uv を `$HERMES_HOME/bin/uv` に置くが、venv はここで自由に作ってよい

### skills（discord 検索だけ専用プロファイルへ）

**discord 検索スキルだけ**を専用プロファイル（`/var/lib/mihari/hermes`）へコピーする。
既定のプロファイル（`/root/.hermes` や開発機の `~/.hermes`）には**入れない**。

```sh
# pin したリビジョンに discord 検索スキルがあるか、先に確認する（無ければここは飛ばす）
ls /var/lib/mihari/hermes-agent/skills/social-media/            # 例: discord-search
sudo -u mihari mkdir -p /var/lib/mihari/hermes/skills/social-media
sudo -u mihari cp -r /var/lib/mihari/hermes-agent/skills/social-media/<discord-search> \
    /var/lib/mihari/hermes/skills/social-media/
# コピー先の owner を mihari:mihari に戻し、read だけにしておく
```

ツリー全体のコピーはしない。他スキルは専用プロファイルに置かない。

### Gateway は起動しない

Hermes の Discord Gateway を起動・設定しない。使うのは `run_agent.AIAgent` だけ。
Mihari の Bot（forum・タグ・pet HTTP）は room 自身の Discord 接続。

## 2. room 本体

```sh
git clone <このリポジトリ> /var/lib/mihari/room-src        # 場所は任意。
cd room-src/room
sudo -u mihari uv python install 3.11
sudo -u mihari env UV_PROJECT_ENVIRONMENT=/var/lib/mihari/room-venv \
    uv sync --locked --python 3.11
```

`uv sync --locked` が `pyproject.toml` の依存（fastapi / uvicorn / httpx /
python-dotenv / discord-py、dev は ruff / pytest）を lock どおり入れる。
`UV_PROJECT_ENVIRONMENT` で venv を `/var/lib/mihari/room-venv` に固定し、
`MIHARI_ROOM_PYTHON=/var/lib/mihari/room-venv/bin/python` を env に入れる。

## 3. 環境変数

```sh
sudo install -o root -g mihari -m 600 room/deploy/env.example /etc/mihari-room/env
sudoedit /etc/mihari-room/env
```

埋める値は `env.example` のコメント参照。**リポジトリには実値を入れない。**

## 4. systemd

```sh
sudo install -o root -g root -m 644 room/deploy/mihari-room.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mihari-room
systemctl status mihari-room
```

- foreground の uvicorn（`mihari_room.cli:main` が `server.serve()` で動く）
- `Restart=on-failure`。落ちた机（running）は起動直後に queued へ戻る
- `UMask=0077`。サンドボックスは「Hermes を in-process で回す」前提の緩め設定
  （`ProtectSystem=strict` / `MemoryDenyWriteExecute` / `SystemCallFilter` は付けない。
  理由は unit のコメントを参照）

確認:

```sh
curl -s http://127.0.0.1:8787/health        # {"status":"ok"}
curl -s -H "X-Mihari-Token: $MIHARI_ROOM_TOKEN" -X POST \
  http://127.0.0.1:8787/jobs -d '{"title":"テスト","body":"hello"}'   # 認証の確認
```

## 5. Caddy（DNS は必ず実値に）

```sh
sudo install -o root -g root -m 644 room/deploy/Caddyfile.example /etc/caddy/Caddyfile
sudoedit /etc/caddy/Caddyfile                # api./preview. のドメインを実値に置き換える
sudo systemctl reload caddy
```

- **API ホスト**: `127.0.0.1:8787` へ転送。認証は Room 自身（`X-Mihari-Token`）
- **プレビュー ホスト**: `/previews/*` だけ Room へ reverse_proxy。他は 404
  （ディスク直出しはしない。CSP と allowlist は Room 側）
- SSE は `flush_interval -1` でバッファしない
- `/previews/*` 以外の静的パス（memory / research / manifests 等）を webroot に
  置かない。`/var/lib/mihari/room/previews` には公開してよい成果物だけ、
  HERMES_HOME / jobs へのシンボリックリンクは張らない
- アクセスログは discard（パス＝ジョブ ID やトークン類を記録しない）

### HTTPS か Tailscale か

- **API**: ペットと運用者だけが叩く。いまは Tailscale Serve
  （`https://v133-117-76-14.tail0820c2.ts.net` → `127.0.0.1:8787`）。
  **合言葉付きの `/jobs` をインターネットに出さない。**
- **プレビュー**: Unlisted（URL を知っていれば誰でも見られる）にするなら、
  **プレビュー専用の公開ホスト**が要る。Tailscale だけでは tailnet 外から見えない。
  - **推奨: Cloudflare Tunnel**。ConoHa の 80/443 を開けなくてよい。ドメインが
    Cloudflare にあれば `preview.<domain>` → `http://127.0.0.1:8787` の
    `/previews` だけ。雛形は `cloudflared-preview.yml.example`。
    通ったら `MIHARI_PREVIEW_BASE_URL=https://preview.<domain>/previews`
  - VPS に穴を開ける（Caddy + Let's Encrypt + DNS A）も動くが、原点 IP が
    見え、ファイアウォールと証明書の運用が増える。Tunnel の方が早い
  - **オブジェクトストレージ（R2 / S3）は今はやらない。** 成果物はすでに
    Room が allowlist して `previews/` に置いている。コピー経路を増やすだけで、
    CSP と token 管理が二重になる
- Cloudflare **Temporary Deploy**（約 60 分 URL）は Phase 6。Tunnel とは別

## 6. バックアップと復元

### 撮る

```sh
# A) 停止して撮る（推奨。WAL の三つ組 state.db / -wal / -shm をそのまま入れる）
sudo systemctl stop mihari-room
sudo -u mihari env \
    MIHARI_ROOM_ROOT=/var/lib/mihari/room HERMES_HOME=/var/lib/mihari/hermes \
    /var/lib/mihari/room-src/room/deploy/backup.sh
sudo systemctl start mihari-room

# B) 動いたまま撮る（sqlite3 .backup で DB だけ整合化。sqlite3 インストール必須）
sudo -u mihari env \
    MIHARI_ROOM_ROOT=/var/lib/mihari/room HERMES_HOME=/var/lib/mihari/hermes \
    /var/lib/mihari/room-src/room/deploy/backup.sh --live-consistent
```

- 停止状態なら DB と `-wal` / `-shm` の三つが揃って tar に入る（WAL の必須条件）
- `--live-consistent` は各 DB を `sqlite3 .backup` でスナップショットにし、
  生の main DB と `-wal` / `-shm` は tar に入れない
- バックアップは `mode 600`、ディレクトリ `700`。.env は入るが**標準出力に出さない**
- スクリプトは `rm` を**動かさない**。古いバックアップの削除は手動で行う
- 自動化するなら `systemctl stop` → backup → `systemctl start` を 1 つの
  systemd timer にまとめる（サービス停止→起動の失敗に注意）

### 戻す（復元手順）

```sh
sudo systemctl stop mihari-room
# バックアップの manifest と中身を確認してから
sudo tar -xpf /var/lib/mihari/backups/mihari-room-<STAMP>.tar.gz -C /
# live モードの DB だけスナップショット（バックアップ配下の mihari-room-<STAMP>/）から戻す
sudo -u mihari cp /var/lib/mihari/backups/mihari-room-<STAMP>/state.db /var/lib/mihari/hermes/state.db
sudo chown -R mihari:mihari /var/lib/mihari/room /var/lib/mihari/hermes
sudo systemctl start mihari-room
```

注意:

- `tar -xpf` は owner / mode を保存する（root で）
- **旧 URL の継続性**: プレビュー URL は `<preview_base>/<token>/` で、token は
  公開時のランダム値。復元は **同じ絶対パス**（`/var/lib/mihari/room/previews`）
  に戻すこと。原点（`MIHARI_PREVIEW_BASE_URL`）を変えると新規仕事から URL が変わる
- messages.db / state.db の owner は mihari:mihari、mode は 600 を保つ
- WAL の三つ組で戻すときは db / -wal / -shm を**全部同時に**置く
  （`--live-consistent` のスナップショットなら 1 ファイルでよい）

## 7. 検証状況（正直なところ）

- ローカルは偽 Hermes のテスト（`cd room && uv run pytest -q`）
- 実機は ConoHa + systemd + Tailscale Serve。ジョブ・followup・Discord 検索・
  Tailscale プレビュー URL は通した
- `--live-consistent` バックアップを 2026-09-07 に撮り、temp 展開で
  DB integrity と preview の sha 一致を確認した。サービス停止しての本番上書き復元は未実施
- 社外向けプレビュー HTTPS と Cloudflare Temporary Deploy は未接続

## 8. やらないこと

- 既存の Gateway（本家 Hermes / Mihari の Bot）をローカルや VPS で
  勝手に start / cancel しない。gateway の運用は担当者が行う
- 実値の秘密をこのリポジトリに入れない
- API をインターネットに出さない
- Cloudflare Temporary Deploy / 他 CDN は Phase 6（Tunnel でのプレビュー公開とは別）