# 並列実装の所有

契約は `src/mihari_room/contracts.py`。変えない。変えたくなったらこのブランチに戻す。

| ブランチ | 触ってよい | 触ってはいけない |
|---|---|---|
| feat/room-queue | `room/src/mihari_room/store/` `room/src/mihari_room/queue/` `room/tests/test_store*.py` `room/tests/test_queue*.py` | discord / worker / desktop / bridge / contracts.py |
| feat/room-discord | `room/src/mihari_room/discord/` `room/tests/test_forum*.py` `room/tests/test_discord*.py` | store / queue / worker / desktop / bridge / contracts.py |
| feat/room-hermes | `room/src/mihari_room/worker/` `room/tests/test_hermes*.py` `room/tests/test_worker*.py` | discord / store 本番 / desktop / bridge / contracts.py |
| feat/room-pet | `desktop/Sources/MihariCore/Pet/JobRequest*` 新規、`PetMenuActions.swift` にメソッド追加だけ、対応する Tests | room/ の中身、bridge/ |

Hermes の Discord Gateway は起動しない。設定もしない。
