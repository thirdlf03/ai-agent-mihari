# room

みはりちゃんの VPS 作業部屋。Discord の口（自前 Bot）と Hermes の呼び出しを持つ。
Hermes の Discord Gateway は使わない。

契約は `src/mihari_room/contracts.py`。デーモンは `uv run mihari-room`。

必要な環境変数:

- `MIHARI_ROOM_TOKEN` — ペットの `X-Mihari-Token` と同じ合言葉
- `MIHARI_ROOM_ROOT` — 部屋のディスク（省略時は `~/mihari-room`）
- `DISCORD_BOT_TOKEN`
- `MIHARI_FORUM_CHANNEL_ID`
- `MIHARI_OWNER_ID` — 誰の仕事でも止められる人
- `MIHARI_ROOM_HOST` / `MIHARI_ROOM_PORT` — 既定 `127.0.0.1:8787`

Forum にタグ `待ち` `作業中` `完了` `失敗` `中断` を先に作っておく。Hermes の Discord Gateway は使わない。
