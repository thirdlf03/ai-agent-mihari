# deploy — Mihari Room（VPS 版）運用

みはりちゃんの作業部屋を ConoHa 1 台で回すための運用資料。
デーモンは **1 プロセス**（HTTP + Discord + in-process Hermes `AIAgent`）。
Hermes の Discord Gateway は起動しない。

このディレクトリのファイル:

| ファイル | 役割 |
| --- | --- |
| `env.example` | 環境変数の雛形。実値は書かない |
| `mihari-room.service` | systemd unit（foreground uvicorn、restart、umask、サンドボックス） |
| `Caddyfile.example` | Caddy 例（API ホスト + プレビュー ホスト） |
| `backup.sh` | バックアップ（停止 or `--live-consistent`、WAL 対応、mode 600） |

## 構成

```
/var/lib/mihari/
├── room/                  MIHARI_ROOM_ROOT
│   ├── jobs/<id>/         meta.json / input/ / output/ / followup-*.txt / hermes_session_id
│   ├── messages.db        部屋のメッセージログ（Phase 後半。未実装なら無い）
│   ├── archive/           アーカイブ（Phase 後半）
│   └── previews/          公開してよい静的成果物（プレビュー ホストの webroot）
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
- **プレビュー ホスト**: `/previews/*` だけ静的に出し、他は 404（API に触れない）
- SSE は `flush_interval -1` でバッファしない
- `/previews/*` 以外の静的パス（memory / research / manifests 等）を webroot に
  置かない。`/var/lib/mihari/room/previews` には公開してよい成果物だけ、
  HERMES_HOME / jobs へのシンボリックリンクは張らない
- アクセスログは discard（パス＝ジョブ ID やトークン類を記録しない）

### HTTPS か Tailscale か

- **API**: クライアントが自動ログインして来る通常のユースなら、Caddy の自動
  HTTPS（Let's Encrypt）で公開 DNS に出す。
  開発者だけで叩くなら Tailscale serve で tailnet 内に閉じてもよい
  （`tailscale serve --bg 8787`）。どちらでも **平文 HTTP で外に晒さない**
- **プレビュー**: Unlisted 前提（誰でも URL を知っていれば見られる）を要求するなら、
  **静的プレビューは必ず一般公開の HTTPS に出す**。Tailscale だけでは tailnet 外から
  見えず、「公開 URL を渡して見てもらう」用途を満たさない
  - 例: `preview.room.example.com` を Caddy / CDN で公開 HTTPS に
  - 完全に非公開でよいなら tailnet 内だけで終わらせられるが、その場合は「Unlisted で
    公開」ではないと認識すること

Cloudflare は**まだ実装していない**。cloudflared の設定は入れない。
将来入れる場合も、API・プレビューの 2 ホスト構成はそのまま Caddy の内側に保つ。

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
- **旧 URL の継続性**: プレビュー URL は `<preview>/previews/<job_id>/...` で、
  ジョブ ID（uuid の先頭 12 文字）と `previews/` のディレクトリ構造で決まる。
  復元は **同じ絶対パス**（`/var/lib/mihari/room/previews`）に戻すこと。
  別のディレクトリに付け替えると Caddy の root がずれて旧 URL が切れる
- messages.db / state.db の owner は mihari:mihari、mode は 600 を保つ
- WAL の三つ組で戻すときは db / -wal / -shm を**全部同時に**置く
  （`--live-consistent` のスナップショットなら 1 ファイルでよい）

## 7. 検証状況（正直なところ）

- ローカルでは**偽 Hermes（test fixtures）でのテストのみ**。実 Hermes の E2E は未実施
- 2026-09-05 に SSH で実機（ConoHa）へつなぎに行ったが**タイムアウト**。
  実デプロイ・本番起動は**行っていない**
- 受け入れは `docs/room-mvp.md` のチェックリストで。
  「ローカル済み（偽 Hermes）」と「ライブ未確認」を分けて記録する

## 8. やらないこと

- 既存の Gateway（本家 Hermes / Mihari の Bot）をローカルや VPS で
  勝手に start / cancel しない。gateway の運用は担当者が行う
- 実値の秘密をこのリポジトリに入れない
- Cloudflare / 他 CDN の設定を入れない（未実装）