# room

みはりちゃんの VPS 作業部屋。Discord の口（自前 Bot）と Hermes の作業エンジンを持つ。
Hermes の Discord Gateway は起動しない。Forum・タグ・ペット HTTP はみはりの Bot のまま。

契約は `src/mihari_room/contracts.py`、HTTP の取り決めは `docs/room-mvp.md`、
デプロイは `deploy/README.md`。デーモンは `uv run mihari-room`。

作業の中身は本家 Hermes の `AIAgent` をプロセス内で回す（`hermes -z` ではない）。
ツール進捗は Forum の 1 通を書き換え続ける（本家 Gateway の accumulate）。
同じジョブの続きは Hermes セッションを resume する。

## 仕事の進め方（全部 YOLO は撤回）

無人環境なので基本は自律で進めるが、**無条件の YOLO はやめた。**

- Clarify は自動で「最善の仮定で進めて」に丸める（一人作業）
- 作業の取り消しは `POST /jobs/{id}/cancel`（頼んだ人か `MIHARI_OWNER_ID` だけ）
- Hermes の memory 候補は `GET /jobs/{id}/memory` に出して、owner の明示承認
  （`approve` / `reject`）を待つ（この契約は実装中）
- 同時実行は 1 件。タイムアウト 15 分で failed 扱い

**検証状況（正直なところ）:** ローカルは偽 Hermes でのテストのみ。実 Hermes の E2E は
未実施。2026-09-05 の SSH 疎通がタイムアウトしたため実機デプロイは行っていない。
受け入れは `docs/room-mvp.md` のチェックリストで。

## 必要な環境変数

| 変数 | 用途 |
| --- | --- |
| `MIHARI_ROOM_TOKEN` | HTTP の合言葉（ペットの `X-Mihari-Token` と同じ） |
| `MIHARI_ROOM_ROOT` | 部屋のディスク（省略時は `~/mihari-room`） |
| `DISCORD_BOT_TOKEN` | Discord Bot トークン |
| `MIHARI_FORUM_CHANNEL_ID` | 仕事を流す Forum チャンネル |
| `MIHARI_OWNER_ID` | 誰の仕事でも止められる人 |
| `MIHARI_ROOM_HOST` / `MIHARI_ROOM_PORT` | 聞き口。既定 `127.0.0.1:8787`（ローカルバインド） |
| `HERMES_PYTHON` | 本家を入れた Python（`hermes` CLI の shebang）。省略時は `which hermes` |
| `HERMES_AGENT_ROOT` | 本家ソースのルート（`run_agent.py` がある場所）。通常は不要 |
| `HERMES_HOME` | Hermes 専用プロファイル（`state.db`、config、sessions、skills）。VPS では `/var/lib/mihari/hermes` |
| `MIHARI_ROOM_PYTHON` | mihari-room を動かす Python（systemd の ExecStart 用） |
| `MIHARI_PREVIEW_BASE_URL` | 静的プレビューの公開ホスト名。API ホストとは別にする（推奨） |
| `MIHARI_ARCHIVE_CHANNEL_IDS` | アーカイブ投稿を許すチャンネルの明示リスト。空なら archive は投稿しない |

## デプロイ

`deploy/` に systemd unit・Caddy 例・env 例・backup スクリプトがある。
流れは `deploy/README.md`（Hermes の pin、Python 3.11、uv sync --locked、
HTTPS / Tailscale、バックアップ復元の旧 URL 継続など）。

Forum にタグ `待ち` `作業中` `完了` `失敗` `中断` を先に作っておく。Hermes の Discord Gateway は使わない。