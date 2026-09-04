"""テスト用の偽 hermes（失敗版）。exit 1 を返す。"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def main() -> int:
    cwd_file = os.environ.get("FAKE_HERMES_CWD_FILE")
    if cwd_file:
        Path(cwd_file).write_text(os.getcwd(), encoding="utf-8")
    print("[tool] fake-tool: わざと失敗します")
    sys.stdout.flush()
    print("これは失敗時の出力です")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
