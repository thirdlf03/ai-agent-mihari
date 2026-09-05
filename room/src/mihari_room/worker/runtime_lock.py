"""Process + in-process locks for the Room.

- :class:`FileProcessLock` — an ``flock``-based lock file (Linux/macOS).
  Usable from a future CLI (``mihari-room lock ...``) to serialize the
  Room root and the stable ``HERMES_HOME`` across processes.
- :func:`agent_serial` — an in-process serial gate so the same process
  never runs two agents at once. The agent relies on process-global
  state (``os.chdir``, ``os.environ``); the gate plus always-restore
  avoids global ``chdir`` concurrency leaks.
- :func:`scoped_hermes_home` — thread-safe per-task ``HERMES_HOME``
  scoping via the Hermes ``set_hermes_home_override`` contextvar when
  available, falling back to no-op when Hermes is not installed.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

try:
    import fcntl  # Unix only
except ImportError:  # pragma: no cover - Windows
    fcntl = None  # type: ignore[assignment]

_AGENT_SERIAL = threading.Lock()


@contextmanager
def agent_serial(blocking: bool = True) -> Iterator[bool]:
    """Hold the one-agent-at-a-time gate. Yields True when acquired."""
    acquired = _AGENT_SERIAL.acquire(blocking=blocking)
    try:
        yield acquired
    finally:
        if acquired:
            _AGENT_SERIAL.release()


def agent_serial_locked() -> bool:
    return _AGENT_SERIAL.locked()


class FileProcessLock:
    """Lock-file mutex with ``flock`` on Unix.

    The lock file itself (``<name>.lock`` under the given directory) is
    created on demand. ``acquire`` blocks up to ``timeout`` seconds when
    ``timeout`` is not None, otherwise blocks forever (matching ``flock``).
    Non-blocking try via :meth:`try_acquire`.
    """

    def __init__(self, directory: Path, name: str = "room") -> None:
        self._directory = Path(directory)
        self._name = name
        self._handle: object | None = None

    @property
    def path(self) -> Path:
        return self._directory / f"{self._name}.lock"

    def try_acquire(self) -> bool:
        return self.acquire(timeout=0.0)

    def acquire(self, timeout: float | None = None) -> bool:
        import time

        self._directory.mkdir(parents=True, exist_ok=True)
        handle = open(self.path, "a+b")  # noqa: PTH123 - lock file by design
        if fcntl is None:  # pragma: no cover - non-Unix fallback
            self._handle = handle
            return True
        deadline = None if timeout is None else (time.monotonic() + timeout)
        while True:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                self._handle = handle
                return True
            except OSError:
                if deadline is not None and time.monotonic() >= deadline:
                    handle.close()
                    return False
                time.sleep(0.05)

    def release(self) -> None:
        handle = self._handle
        self._handle = None
        if handle is None:
            return
        try:
            if fcntl is not None:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)  # type: ignore[union-attr]
        finally:
            try:
                handle.close()  # type: ignore[union-attr]
            except OSError:
                pass

    def __enter__(self) -> FileProcessLock:
        self.acquire()
        return self

    def __exit__(self, *exc: object) -> None:
        self.release()


@contextmanager
def room_lock(root: Path, timeout: float | None = None) -> Iterator[FileProcessLock]:
    """Process lock for the Room root (``<root>/room.lock``)."""
    lock = FileProcessLock(Path(root), "room")
    if not lock.acquire(timeout=timeout):
        raise TimeoutError(f"could not acquire room lock: {root}")
    try:
        yield lock
    finally:
        lock.release()


@contextmanager
def hermes_home_lock(hermes_home: Path, timeout: float | None = None) -> Iterator[FileProcessLock]:
    """Process lock for the stable ``HERMES_HOME``."""
    lock = FileProcessLock(Path(hermes_home), "hermes_home")
    if not lock.acquire(timeout=timeout):
        raise TimeoutError(f"could not acquire hermes home lock: {hermes_home}")
    try:
        yield lock
    finally:
        lock.release()


@contextmanager
def scoped_hermes_home(hermes_home: Path | str) -> Iterator[Path]:
    """Pin the Hermes home for the current context (thread-safe).

    Uses the Hermes ``set_hermes_home_override`` contextvar when importable
    so concurrent threads never fight over ``os.environ``. Falls back to a
    plain no-op yield when Hermes is not installed (tests with fakes).
    """
    target = Path(hermes_home)
    try:
        from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    except ImportError:
        yield target
        return
    token = set_hermes_home_override(str(target))
    try:
        yield target
    finally:
        try:
            reset_hermes_home_override(token)
        except Exception:
            pass


def resolve_hermes_home(room_root: Path) -> Path:
    """Stable home profile for Room-driven agents.

    Explicit ``MIHARI_HERMES_HOME`` (or ``HERMES_HOME``) wins; otherwise a
    Room-scoped profile under ``<root>/.hermes-room`` keeps Room memory
    separate from the interactive user profile and stable across restarts.
    """
    for key in ("MIHARI_HERMES_HOME", "HERMES_HOME"):
        value = (os.environ.get(key) or "").strip()
        if value:
            return Path(value).expanduser()
    return Path(room_root) / ".hermes-room"
