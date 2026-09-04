"""Hermes を部屋の venv の外から見つける。"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from mihari_room.worker import bootstrap as bootstrap_mod
from mihari_room.worker.bootstrap import (
    _can_import,
    _prepend_interpreter_path,
    _shebang_python,
    bootstrap_hermes,
)


def test_shebang_python_reads_absolute_interpreter(tmp_path: Path) -> None:
    script = tmp_path / "hermes"
    script.write_text(f"#!{sys.executable}\nprint('ok')\n", encoding="utf-8")
    assert _shebang_python(script) == sys.executable


def test_bootstrap_from_agent_root(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path / "hermes-agent"
    root.mkdir()
    (root / "run_agent.py").write_text("class AIAgent:\n    pass\n", encoding="utf-8")
    cli = root / "hermes_cli"
    cli.mkdir()
    (cli / "__init__.py").write_text("", encoding="utf-8")
    monkeypatch.setenv("HERMES_AGENT_ROOT", str(root))
    monkeypatch.delenv("HERMES_PYTHON", raising=False)
    monkeypatch.setattr(bootstrap_mod, "_BOOTSTRAPPED", False)
    monkeypatch.setattr(bootstrap_mod, "_hermes_pythons", lambda: [])
    monkeypatch.setattr(bootstrap_mod.shutil, "which", lambda _name: None)
    saved = list(sys.path)
    saved_modules = {name: sys.modules.get(name) for name in ("run_agent", "hermes_cli")}
    try:
        for name in ("run_agent", "hermes_cli"):
            sys.modules.pop(name, None)
        bootstrap_hermes()
        assert _can_import()
    finally:
        sys.path[:] = saved
        bootstrap_mod._BOOTSTRAPPED = False
        for name, module in saved_modules.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module


def test_prepend_interpreter_path_adds_entries(tmp_path: Path, monkeypatch) -> None:
    extra = tmp_path / "site"
    extra.mkdir()
    wrapper = tmp_path / "fake-python"
    payload = json.dumps([str(extra), ""])
    wrapper.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        f"if sys.argv[1:3] == ['-c', 'import json, sys; print(json.dumps(sys.path))']:\n"
        f"    print({payload!r})\n"
        "    raise SystemExit(0)\n"
        "raise SystemExit(1)\n",
        encoding="utf-8",
    )
    wrapper.chmod(0o755)
    saved = list(sys.path)
    try:
        _prepend_interpreter_path(str(wrapper))
        assert str(extra) in sys.path
        assert sys.path.index(str(extra)) == 0
    finally:
        sys.path[:] = saved
