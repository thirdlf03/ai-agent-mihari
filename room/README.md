# room

みはりちゃんの VPS 作業部屋。Discord の口（自前 Bot）と Hermes の作業エンジンを持つ。
Hermes の Discord Gateway は起動しない。Forum・タグ・ペット HTTP はみはりの Bot のまま。

契約は `src/mihari_room/contracts.py`。デーモンは `uv run mihari-room`。

作業の中身は本家 Hermes の `AIAgent` をプロセス内で回す（`hermes -z` ではない）。
ツール進捗は Forum の 1 通を書き換え続ける（本家 Gateway の accumulate）。
同じジョブの続きは Hermes セッションを resume する。承認は出さず、全部 YOLO。

必要な環境変数:

- `MIHARI_ROOM_TOKEN` — ペットの `X-Mihari-Token` と同じ合言葉
- `MIHARI_ROOM_ROOT` — 部屋のディスク（省略時は `~/mihari-room`）
- `DISCORD_BOT_TOKEN`
- `MIHARI_FORUM_CHANNEL_ID`
- `MIHARI_OWNER_ID` — 誰の仕事でも止められる人
- `MIHARI_ROOM_HOST` / `MIHARI_ROOM_PORT` — 既定 `127.0.0.1:8787`
- `HERMES_PYTHON` — 本家を入れた Python（`hermes` CLI の shebang）。省略時は `which hermes` から探す
- `HERMES_AGENT_ROOT` — 本家ソースのルート（`run_agent.py` がある場所）。通常は不要

Forum にタグ `待ち` `作業中` `完了` `失敗` `中断` を先に作っておく。Hermes の Discord Gateway は使わない。
