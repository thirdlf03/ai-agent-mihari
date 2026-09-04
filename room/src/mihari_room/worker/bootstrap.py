"""インストール済み Hermes を import できるようにする。

Hermes の Discord Gateway は起動しない。``run_agent.AIAgent`` だけ借りる。
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

_BOOTSTRAPPED = False


def bootstrap_hermes() -> None:
    """``run_agent`` が import できる状態にする。何度呼んでもよい。"""
    global _BOOTSTRAPPED
    if _BOOTSTRAPPED:
        return
    if _can_import():
        _BOOTSTRAPPED = True
        return
    for root in _candidate_roots():
        if (root / "run_agent.py").is_file():
            sys.path.insert(0, str(root))
            if _can_import():
                _BOOTSTRAPPED = True
                return
    raise ImportError(
        "Hermes Agent が見つからない。"
        " hermes を入れるか、HERMES_AGENT_ROOT にソースのルートを指定して。"
    )


def import_ai_agent() -> type:
    """本家の ``AIAgent``。見つからなければ ImportError。"""
    bootstrap_hermes()
    from run_agent import AIAgent

    return AIAgent


def _can_import() -> bool:
    try:
        import run_agent  # noqa: F401

        return True
    except ImportError:
        return False


def _candidate_roots() -> list[Path]:
    roots: list[Path] = []
    env = (os.environ.get("HERMES_AGENT_ROOT") or "").strip()
    if env:
        roots.append(Path(env).expanduser())
    home = Path.home() / ".hermes"
    roots.extend(
        [
            home / "hermes-agent",
            home / "src" / "hermes-agent",
        ]
    )
    binary = shutil.which("hermes")
    if binary:
        resolved = Path(binary).resolve()
        for parent in resolved.parents:
            if (parent / "run_agent.py").is_file():
                roots.append(parent)
                break
    return roots
