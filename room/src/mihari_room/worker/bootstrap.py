"""インストール済み Hermes を import できるようにする。

部屋の venv には ``hermes_cli`` が無い。``hermes`` CLI の Python
（uv tool の venv）の ``sys.path`` を先に載せる。
Hermes の Discord Gateway は起動しない。``run_agent.AIAgent`` だけ借りる。
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import sys
from pathlib import Path

logger = logging.getLogger("mihari_room")

_BOOTSTRAPPED = False


def bootstrap_hermes() -> None:
    """``run_agent`` と ``hermes_cli`` が import できる状態にする。何度呼んでもよい。"""
    global _BOOTSTRAPPED
    if _BOOTSTRAPPED:
        return
    if _can_import():
        _BOOTSTRAPPED = True
        return
    for python in _hermes_pythons():
        _prepend_interpreter_path(python)
        if _can_import():
            _BOOTSTRAPPED = True
            logger.info("Hermes を CLI の Python から読んだ: %s", python)
            return
    for root in _candidate_roots():
        if (root / "run_agent.py").is_file():
            sys.path.insert(0, str(root))
            if _can_import():
                _BOOTSTRAPPED = True
                logger.info("Hermes をソースから読んだ: %s", root)
                return
    raise ImportError(
        "Hermes Agent が見つからない。"
        " PATH に hermes があるか、HERMES_PYTHON / HERMES_AGENT_ROOT を設定して。"
    )


def import_ai_agent() -> type:
    """本家の ``AIAgent``。見つからなければ ImportError。"""
    bootstrap_hermes()
    from run_agent import AIAgent

    return AIAgent


def _can_import() -> bool:
    try:
        import hermes_cli  # noqa: F401
        import run_agent  # noqa: F401

        return True
    except ImportError:
        return False


def _shebang_python(binary: Path) -> str | None:
    """CLI スクリプト先頭の ``#!`` から Python を取る。"""
    try:
        first = binary.read_bytes().splitlines()[0]
    except OSError:
        return None
    if not first.startswith(b"#!"):
        return None
    line = first[2:].decode("utf-8", errors="replace").strip()
    parts = line.split()
    if not parts:
        return None
    program = parts[0]
    if Path(program).name in {"env", "env.exe"} and len(parts) >= 2:
        found = shutil.which(parts[1])
        return found
    path = Path(program)
    return str(path) if path.is_file() else None


def _hermes_pythons() -> list[str]:
    found: list[str] = []
    env = (os.environ.get("HERMES_PYTHON") or "").strip()
    if env:
        found.append(str(Path(env).expanduser()))
    binary = shutil.which("hermes")
    if binary:
        shebang = _shebang_python(Path(binary))
        if shebang:
            found.append(shebang)
        sibling = Path(binary).resolve().parent / "python"
        if sibling.is_file():
            found.append(str(sibling))
    home_tools = Path.home() / ".local/share/uv/tools"
    for name in ("hermes-agent", "hermes", "hermes_agent"):
        candidate = home_tools / name / "bin" / "python"
        if candidate.is_file():
            found.append(str(candidate))
    unique: list[str] = []
    seen: set[str] = set()
    for item in found:
        if item not in seen:
            seen.add(item)
            unique.append(item)
    return unique


def _prepend_interpreter_path(python: str) -> None:
    """その Python が見ている sys.path を、今のプロセスの先頭に足す。"""
    try:
        result = subprocess.run(
            [python, "-c", "import json, sys; print(json.dumps(sys.path))"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return
    if result.returncode != 0:
        return
    try:
        paths = json.loads(result.stdout)
    except json.JSONDecodeError:
        return
    existing = set(sys.path)
    for entry in reversed(paths):
        if not entry or entry == ".":
            continue
        if entry not in existing:
            sys.path.insert(0, entry)
            existing.add(entry)


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
