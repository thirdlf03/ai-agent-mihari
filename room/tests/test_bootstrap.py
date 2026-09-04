"""Hermes を部屋の venv の外から見つける。"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from mihari_room.worker import bootstrap as bootstrap_mod
from mihari_room.worker.bootstrap import (
    _can_import,
    _cli_python,
    _is_usable_import_path,
    _prepend_interpreter_path,
    _shebang_python,
    bootstrap_hermes,
)


def test_shebang_python_reads_absolute_interpreter(tmp_path: Path) -> None:
    script = tmp_path / "hermes"
    script.write_text(f"#!{sys.executable}\nprint('ok')\n", encoding="utf-8")
    assert _shebang_python(script) == sys.executable


def test_shebang_python_ignores_shell_wrapper(tmp_path: Path) -> None:
    script = tmp_path / "hermes"
    script.write_text("#!/bin/sh\n'''exec' python3 \"$0\" \"$@\"\n", encoding="utf-8")
    assert _shebang_python(script) is None


def test_cli_python_prefers_python3_sibling(tmp_path: Path) -> None:
    bindir = tmp_path / "bin"
    bindir.mkdir()
    script = bindir / "hermes"
    neighbor = bindir / "python3"
    script.write_text("#!/bin/sh\n", encoding="utf-8")
    neighbor.write_text("#!/bin/sh\n", encoding="utf-8")
    script.chmod(0o755)
    neighbor.chmod(0o755)
    assert _cli_python(script) == str(neighbor.resolve())


def test_stdlib_is_not_a_usable_import_path(tmp_path: Path) -> None:
    stdlib = tmp_path / "lib" / "python3.11"
    stdlib.mkdir(parents=True)
    (stdlib / "sqlite3").mkdir()
    site = tmp_path / "lib" / "python3.11" / "site-packages"
    site.mkdir()
    root = tmp_path / "hermes-agent"
    root.mkdir()
    (root / "run_agent.py").write_text("", encoding="utf-8")
    assert _is_usable_import_path(str(stdlib)) is False
    assert _is_usable_import_path(str(site)) is True
    assert _is_usable_import_path(str(root)) is True
    assert _is_usable_import_path("") is False


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


def test_prepend_interpreter_path_adds_site_packages_only(tmp_path: Path) -> None:
    extra = tmp_path / "lib" / "python3.11" / "site-packages"
    extra.mkdir(parents=True)
    stdlib = tmp_path / "lib" / "python3.11"
    wrapper = tmp_path / "fake-python"
    payload = json.dumps([str(extra), str(stdlib), ""])
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
        assert str(stdlib) not in sys.path
    finally:
        sys.path[:] = saved
