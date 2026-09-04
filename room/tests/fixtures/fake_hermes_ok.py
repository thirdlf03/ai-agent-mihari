"""テスト用の偽 hermes（成功版）。cwd で動き、output/hello.txt を作る。"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def main() -> int:
    # 呼び出し元 cwd とプロンプトを外の記録ファイルへ残す（検証用）。
    cwd_file = os.environ.get("FAKE_HERMES_CWD_FILE")
    if cwd_file:
        Path(cwd_file).write_text(os.getcwd(), encoding="utf-8")
    prompt_file = os.environ.get("FAKE_HERMES_PROMPT_FILE")
    if prompt_file:
        Path(prompt_file).write_text("\n".join(sys.argv[1:]), encoding="utf-8")

    # ジョブフォルダ直下の output/ に成果物を書く（cwd 依存）。
    Path("output/hello.txt").write_text("hello\n", encoding="utf-8")

    # ツール風ログと最終返答を標準出力へ流す。
    print("[tool] fake-tool: output/hello.txt を作成中")
    sys.stdout.flush()
    print("作業が終わりました。hello.txt を作りました。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
