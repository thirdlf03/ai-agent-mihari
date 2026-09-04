"""インストール済み Hermes を import できるようにする。

部屋の venv には ``hermes_cli`` が無い。``hermes`` CLI の Python
（同じマイナーバージョンのもの）から site-packages と本家ソースだけを載せる。
標準ライブラリは載せない。3.11 の sqlite3 を 3.14 に混ぜると死ぬ。
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

#: shebang がシェルラッパ（uv / setuptools の ``#!/bin/sh`` + exec）のとき。
_SHELL_NAMES = frozenset({"sh", "bash", "dash", "zsh", "fish"})


def bootstrap_hermes() -> None:
    """``run_agent`` と ``hermes_cli`` が import できる状態にする。何度呼んでもよい。"""
    global _BOOTSTRAPPED
    if _BOOTSTRAPPED:
        return
    if _can_import():
        _BOOTSTRAPPED = True
        return
    skipped_versions: list[str] = []
    for python in _hermes_pythons():
        theirs = _python_version(python)
        if theirs is not None and theirs != sys.version_info[:2]:
            skipped_versions.append(
                f"{python} ({theirs[0]}.{theirs[1]})"
            )
            logger.warning(
                "Hermes の Python が部屋と違うので飛ばす: %s は %s.%s、部屋は %s.%s",
                python,
                theirs[0],
                theirs[1],
                sys.version_info[0],
                sys.version_info[1],
            )
            continue
        _prepend_interpreter_path(python)
        _prepend_agent_roots()
        if _can_import():
            _BOOTSTRAPPED = True
            logger.info("Hermes を CLI の Python から読んだ: %s", python)
            return
    for root in _candidate_roots():
        if not (root / "run_agent.py").is_file():
            continue
        entry = str(root)
        if entry not in sys.path:
            sys.path.insert(0, entry)
        if _can_import():
            _BOOTSTRAPPED = True
            logger.info("Hermes をソースから読んだ: %s", root)
            return
    ours = f"{sys.version_info[0]}.{sys.version_info[1]}"
    mismatch = ""
    if skipped_versions:
        mismatch = f" Hermes 側は {', '.join(skipped_versions)} だった。"
    raise ImportError(
        "Hermes Agent が見つからない。"
        f" 部屋は Python {ours}。"
        f"{mismatch}"
        " 同じマイナーバージョンで部屋を動かすか、HERMES_PYTHON / HERMES_AGENT_ROOT を設定して。"
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
    except Exception:
        return False


def _shebang_python(binary: Path) -> str | None:
    """CLI スクリプト先頭の ``#!`` から Python を取る。シェルラッパは無視する。"""
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
    if Path(program).name in _SHELL_NAMES:
        return None
    return str(path) if path.is_file() else None


def _cli_python(binary: Path) -> str | None:
    """``hermes`` スクリプトの隣の interpreter。uv は ``python3`` という名前。"""
    resolved_dir = binary.resolve().parent
    for name in ("python3", "python"):
        candidate = resolved_dir / name
        if candidate.is_file():
            return str(candidate)
    return _shebang_python(binary)


def _hermes_pythons() -> list[str]:
    found: list[str] = []
    env = (os.environ.get("HERMES_PYTHON") or "").strip()
    if env:
        found.append(str(Path(env).expanduser()))
    binary = shutil.which("hermes")
    if binary:
        nearby = _cli_python(Path(binary))
        if nearby:
            found.append(nearby)
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


def _python_version(python: str) -> tuple[int, int] | None:
    try:
        result = subprocess.run(
            [python, "-c", "import sys; print(sys.version_info[0], sys.version_info[1])"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    parts = result.stdout.split()
    if len(parts) < 2:
        return None
    try:
        return int(parts[0]), int(parts[1])
    except ValueError:
        return None


def _is_usable_import_path(raw: str) -> bool:
    """本家コードと third-party だけ。別 interpreter の stdlib は混ぜない。"""
    if not raw or raw == ".":
        return False
    path = Path(raw)
    text = str(path).replace("\\", "/")
    if "site-packages" in text.split("/"):
        return True
    try:
        if path.is_dir() and (
            (path / "run_agent.py").is_file() or (path / "hermes_cli").is_dir()
        ):
            return True
    except OSError:
        return False
    return False


def _prepend_interpreter_path(python: str) -> None:
    """その Python の site-packages と本家ソースだけを、今のプロセスの先頭に足す。"""
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
    if not isinstance(paths, list):
        return
    existing = set(sys.path)
    for entry in reversed(paths):
        if not isinstance(entry, str) or not _is_usable_import_path(entry):
            continue
        if entry not in existing:
            sys.path.insert(0, entry)
            existing.add(entry)


def _prepend_agent_roots() -> None:
    existing = set(sys.path)
    for root in _candidate_roots():
        if not (root / "run_agent.py").is_file():
            continue
        entry = str(root)
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
