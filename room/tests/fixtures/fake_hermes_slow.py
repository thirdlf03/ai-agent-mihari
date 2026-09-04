"""テスト用の偽 hermes（低速版）。タイムアウト検証用に眠る。"""

from __future__ import annotations

import time


def main() -> int:
    print("[tool] fake-tool: ゆっくり作業中")
    time.sleep(30)
    print("終わりました")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
