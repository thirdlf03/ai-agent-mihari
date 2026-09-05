"""パス安全。生成パスの正規化と、jobs / archive の外へ逃げない containment 検証。

シンボリックリンクを辿って ``Path.resolve()`` した実体が root の内側にあることだけを信じる。
"""

from __future__ import annotations

import re
from pathlib import Path

#: ファイル名に残して良い文字。パス区切り・制御文字・空白は全部 '_' に落とす。
_FILENAME_UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")


def sanitize_filename(name: str) -> str:
    """添付ファイル名からパスを剥がし、安全な文字だけ残す。``..`` も無効化。"""
    base = Path(name).name.strip()
    if not base or base in {".", ".."}:
        return "attachment"
    cleaned = _FILENAME_UNSAFE.sub("_", base).strip("._")
    return cleaned or "attachment"


def ensure_contained(target: Path, root: Path) -> Path:
    """``target`` の実体（symlink 解決後）が ``root`` の内側なら解決済みパスを返す。

    外に出る／root 自身を指す場合は ``ValueError``。
    """
    root_resolved = root.resolve()
    target_resolved = target.resolve()
    if target_resolved == root_resolved or not target_resolved.is_relative_to(root_resolved):
        raise ValueError(f"パスが置き場の外: {target} -> {target_resolved} (root={root_resolved})")
    return target_resolved
