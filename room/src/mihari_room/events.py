"""ジョブの出来事を events.ndjson に残す。SSE の実体。

1 仕事 1 ファイル ``<job>/events.ndjson``。行ごとに 1 件の JSON
``{id, job_id, phase, kind, text, progress, created_at}``。

- ``id`` は仕事ごとの単調増加。再起動してもファイルから続きを引く。
- ``phase`` はクライアント側の状態表示（調査中・ビルド中…）。
- ``kind`` はどう見せるか（speech / log / file / summary / cancelled）。
- ``text`` は秘密（API キー、claim_url など）を伏せてから書く。
- ``created_at`` は UTC の ISO 8601。
"""

from __future__ import annotations

import json
import os
import re
import threading
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import Any

from mihari_room.contracts import ProgressKind

#: 仕事フォルダに残す出来事のファイル名。
EVENTS_FILENAME = "events.ndjson"

#: 伏せ字。
_REDACT = "***"


class EventPhase(StrEnum):
    """ジョブの状態表示。SSE の ``phase`` フィールド。"""

    QUEUED = "queued"
    RESEARCHING = "researching"
    DOWNLOADING = "downloading"
    BUILDING = "building"
    DEPLOYING = "deploying"
    VERIFYING = "verifying"
    WAITING = "waiting"
    DONE = "done"
    FAILED = "failed"


class JournalKind(StrEnum):
    """出来事の種別。ProgressKind に cancelled を足したもの。"""

    SPEECH = "speech"
    LOG = "log"
    FILE = "file"
    SUMMARY = "summary"
    CANCELLED = "cancelled"
    #: memory candidate proposed; phase is WAITING. Desktop refreshes the
    #: memory list on detail refresh; the job queue never blocks on it.
    MEMORY_CANDIDATE = "memory_candidate"


def kind_from_progress(kind: ProgressKind) -> JournalKind:
    return JournalKind(kind.value)


# --- 秘密の伏せ字 -----------------------------------------------------------

#: claim_url = "https://user:pass@host/..." のような形。値ごと伏せる。
_CLAIM_URL = re.compile(r"(?i)(claim_url\s*[:=]\s*)(['\"]?)[^'\"\s,}]+")
#: URL の userinfo (user:pass@)。
_URL_USERINFO = re.compile(r"(?i)(https?://)[^/\s:@]+@")
#: 名前=値 / 名前:値 の割り当て。値だけ伏せる。
_ASSIGN = re.compile(
    r"(?i)(\b[A-Za-z0-9_]*(?:api[_-]?key|access[_-]?token|secret|password|passwd|token|private[_-]?key|claim_url)[A-Za-z0-9_]*\b"
    r"\s*[:=]\s*)(['\"]?)[^'\"\s,}]+"
)
#: よくある API キー / トークンの形。
_APIKEYS = re.compile(
    r"(?i)(\b(?:sk-[A-Za-z0-9_-]+|sk-ant-[A-Za-z0-9_-]+|xox[baprs]-[A-Za-z0-9_-]+"
    r"|ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}"
    r"|Bearer\s+[A-Za-z0-9._~+/=-]+)\b)"
)


def sanitize_text(text: str | None) -> str | None:
    """秘密になりうる値（claim_url・キー類）を伏せて返す。"""
    if not text:
        return text
    out = _CLAIM_URL.sub(lambda m: m.group(1) + m.group(2) + _REDACT, text)
    out = _URL_USERINFO.sub(r"\1" + _REDACT + "@", out)
    out = _ASSIGN.sub(lambda m: m.group(1) + m.group(2) + _REDACT, out)
    out = _APIKEYS.sub(_REDACT, out)
    return out


# --- ディスク上の日誌 ---------------------------------------------------------

#: 1 プロセスで append を直列化する鍵。id の読み取り→書き込みを守る。
_WRITE_LOCK = threading.Lock()
#: path → 最後に付けた id の覚え書き。再起動後は空なので最初に読み直す。
_LAST_ID: dict[str, int] = {}


class EventJournal:
    """append-only の出来事帳。書き込みと読み出しはいつでも（SSE と共有）。"""

    def __init__(self, path: Path) -> None:
        self._path = Path(path)

    @classmethod
    def for_job(cls, job_dir: Path) -> EventJournal:
        return cls(job_dir / EVENTS_FILENAME)

    @property
    def path(self) -> Path:
        return self._path

    def events(self) -> list[dict[str, Any]]:
        """今ある出来事を id 順に全部返す。"""
        if not self._path.is_file():
            return []
        records: list[dict[str, Any]] = []
        for line in self._path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except (ValueError, TypeError):
                # 途中で壊れた 1 行は無視して続ける。
                continue
        return records

    def after(self, after_id: int) -> list[dict[str, Any]]:
        """``after_id`` より大きい id の出来事だけ返す。"""
        return [event for event in self.events() if event["id"] > after_id]

    def latest(self) -> dict[str, Any] | None:
        events = self.events()
        return events[-1] if events else None

    def append(
        self,
        *,
        job_id: str,
        phase: EventPhase,
        kind: JournalKind,
        text: str | None,
        progress: float | None = None,
    ) -> dict[str, Any]:
        """1 件追記する。id は直近 + 1（再起動後もファイルから続きを引く）。"""
        record: dict[str, Any]
        with _WRITE_LOCK:
            next_id = self._next_id()
            record = {
                "id": next_id,
                "job_id": job_id,
                "phase": phase.value,
                "kind": kind.value,
                "text": sanitize_text(text),
                "progress": progress,
                "created_at": datetime.now(UTC).isoformat(timespec="seconds"),
            }
            line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
            self._path.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(self._path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
            try:
                os.write(fd, line.encode("utf-8"))
            finally:
                os.close(fd)
            _LAST_ID[str(self._path)] = next_id
        return record

    def _next_id(self) -> int:
        key = str(self._path)
        cached = _LAST_ID.get(key)
        if cached is not None:
            return cached + 1
        events = self.events()
        last = events[-1]["id"] if events else 0
        _LAST_ID[key] = last
        return last + 1
