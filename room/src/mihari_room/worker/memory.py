"""Approval-controlled memory candidates.

Blanket YOLO memory writes are replaced by a propose -> approve flow.
Candidates are durable under ``jobs/<id>/memory_candidates.json`` so a
later HTTP layer can list/approve/reject them.

Public API (for later HTTP wiring)::

    store = MemoryCandidateStore(root, hermes_home)
    store.list(job_id)
    store.propose(job_id, target, content)
    store.approve(job_id, candidate_id)
    store.reject(job_id, candidate_id)

``target`` is ``"memory"`` (MEMORY.md) or ``"user"`` (USER.md).
``approve`` appends the candidate content to the stable home profile
(``<hermes_home>/memories/MEMORY.md`` or ``USER.md``) atomically and
idempotently, then marks the candidate approved.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from uuid import uuid4

from mihari_room.contracts import JOBS_DIRNAME

CANDIDATES_FILENAME = "memory_candidates.json"

#: job ids are uuid hex from FileJobStore (12 chars) — be liberal but safe.
_JOB_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")

TARGET_TO_FILE = {"memory": "MEMORY.md", "user": "USER.md"}

#: Propose policy: hard cap for a single candidate entry.
MAX_CANDIDATE_CHARS = 2000

_PENDING = "pending"
_APPROVED = "approved"
_REJECTED = "rejected"


@dataclass
class MemoryCandidate:
    id: str
    target: str  # "MEMORY.md" | "USER.md"
    content: str
    status: str  # pending | approved | rejected
    created_at: float

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def policy_reject_reason(content: str) -> str | None:
    """Return a rejection reason when content must not become memory.

    Feasible heuristics only (not a security proof):

    - empty / too large
    - raw logs / traces / PDF dumps
    - inferred personal facts without an explicit user statement
    """
    text = (content or "").strip()
    if not text:
        return "empty content"
    if len(text) > MAX_CANDIDATE_CHARS:
        return f"too large ({len(text)} chars > {MAX_CANDIDATE_CHARS})"
    lowered = text.lower()
    # Raw logs / traces.
    if "traceback (most recent call last)" in lowered:
        return "raw log/traceback must not become memory"
    lines = text.splitlines()
    if len(lines) >= 20:
        return "raw log (too many lines) must not become memory"
    if "%pdf" in lowered or ("\x00" in text):
        return "PDF/binary dump must not become memory"
    if (
        len(lines) >= 1
        and sum(1 for ln in lines if re.search(r"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}", ln)) >= 5
    ):
        return "raw log (timestamps) must not become memory"
    # Inferred facts about the user without an explicit statement.
    # e.g. "user probably likes X" / "ユーザーはたぶん X".
    inferred_markers = ("probably", "likely", "seems to", "たぶん", "おそらく", "らしい")
    personal_markers = (
        "likes",
        "prefers",
        "hates",
        "lives",
        "works",
        "age",
        "好み",
        "好き",
        "嫌い",
        "住",
        "歳",
    )
    if any(m in lowered for m in inferred_markers) and any(p in lowered for p in personal_markers):
        return "inferred fact needs explicit user confirmation first"
    return None


class MemoryCandidateStore:
    """Durable per-job memory candidates + approved writes to a stable home."""

    def __init__(self, root: Path, hermes_home: Path) -> None:
        self._root = Path(root)
        self._hermes_home = Path(hermes_home)

    @property
    def root(self) -> Path:
        return self._root

    @property
    def hermes_home(self) -> Path:
        return self._hermes_home

    # -- public API -----------------------------------------------------

    def list(self, job_id: str) -> list[MemoryCandidate]:
        self._job_dir(job_id)
        return self._load(job_id)

    def propose(self, job_id: str, target: str, content: str) -> MemoryCandidate:
        self._job_dir(job_id)
        filename = self._normalize_target(target)
        text = (content or "").strip()
        reason = policy_reject_reason(text)
        if reason is not None:
            raise ValueError(f"memory candidate rejected: {reason}")
        if not text:
            raise ValueError("memory candidate rejected: empty content")
        candidates = self._load(job_id)
        # Idempotent propose: same target+content returns existing pending.
        for existing in candidates:
            if (
                existing.target == filename
                and existing.content == text
                and existing.status == _PENDING
            ):
                return existing
        candidate = MemoryCandidate(
            id=uuid4().hex[:12],
            target=filename,
            content=text,
            status=_PENDING,
            created_at=time.time(),
        )
        candidates.append(candidate)
        self._save(job_id, candidates)
        return candidate

    def approve(self, job_id: str, candidate_id: str) -> MemoryCandidate:
        """Mark approved and append to the stable home profile (idempotent)."""
        self._job_dir(job_id)
        candidates = self._load(job_id)
        candidate = self._find(candidates, candidate_id)
        if candidate.status == _APPROVED:
            # Idempotent: ensure the approved text is present, then return.
            self._append_approved(candidate)
            return candidate
        if candidate.status == _REJECTED:
            raise ValueError(f"candidate {candidate_id} already rejected")
        self._append_approved(candidate)
        candidate.status = _APPROVED
        self._save(job_id, candidates)
        # Re-load to return the stored instance.
        return self._find(self._load(job_id), candidate_id)

    def reject(self, job_id: str, candidate_id: str) -> MemoryCandidate:
        """Mark rejected (idempotent, never touches the home profile)."""
        self._job_dir(job_id)
        candidates = self._load(job_id)
        candidate = self._find(candidates, candidate_id)
        if candidate.status == _REJECTED:
            return candidate
        if candidate.status == _APPROVED:
            raise ValueError(f"candidate {candidate_id} already approved")
        candidate.status = _REJECTED
        self._save(job_id, candidates)
        return self._find(self._load(job_id), candidate_id)

    # -- approved-memory reads ------------------------------------------

    def approved_entries(self, target: str) -> list[str]:
        """Read approved on-disk entries for prompt injection (best effort)."""
        filename = self._normalize_target(target)
        path = self._hermes_home / "memories" / filename
        try:
            raw = path.read_text(encoding="utf-8")
        except OSError:
            return []
        return [entry for entry in (part.strip() for part in raw.split("\n§\n")) if entry]

    # -- internals --------------------------------------------------------

    def _normalize_target(self, target: str) -> str:
        normalized = (target or "").strip().lower()
        # Accept both short ("memory") and file ("MEMORY.md") forms.
        if normalized in ("memory.md", "memory"):
            return "MEMORY.md"
        if normalized in ("user.md", "user"):
            return "USER.md"
        raise ValueError("target must be MEMORY.md or USER.md")

    def _jobs_root(self) -> Path:
        return self._root / JOBS_DIRNAME

    def _job_dir(self, job_id: str) -> Path:
        if not _JOB_ID_RE.match(job_id or ""):
            raise ValueError(f"invalid job id: {job_id!r}")
        jobs_root = self._jobs_root().resolve()
        candidate = self._jobs_root() / job_id
        # Containment: resolve symlinks and require staying under jobs/.
        try:
            resolved = candidate.resolve()
        except OSError as exc:
            raise ValueError(f"unknown job: {job_id}") from exc
        try:
            resolved.relative_to(jobs_root)
        except ValueError as exc:
            raise ValueError(f"job escapes room root: {job_id}") from exc
        if resolved != (jobs_root / job_id):
            # A symlink pointing elsewhere still resolves outside; the
            # relative_to check above already rejects escapes, but a symlink
            # pointing inside another job would also land elsewhere.
            if not resolved.is_dir():
                raise ValueError(f"unknown job: {job_id}")
            raise ValueError(f"job path is not a real job dir: {job_id}")
        if (
            not candidate.is_dir() or resolved.is_symlink()
            if hasattr(resolved, "is_symlink")
            else False
        ):
            pass
        # The link itself must not be a symlink (symlink jobs are rejected).
        if candidate.is_symlink():
            raise ValueError(f"job path is a symlink: {job_id}")
        if not resolved.is_dir():
            raise ValueError(f"unknown job: {job_id}")
        return resolved

    def _candidates_path(self, job_id: str) -> Path:
        return self._job_dir(job_id) / CANDIDATES_FILENAME

    def _load(self, job_id: str) -> list[MemoryCandidate]:
        path = self._candidates_path(job_id)
        try:
            raw = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return []
        except OSError as exc:
            raise ValueError(f"cannot read candidates for {job_id}: {exc}") from exc
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return []
        if not isinstance(data, list):
            return []
        out: list[MemoryCandidate] = []
        for item in data:
            if not isinstance(item, dict):
                continue
            try:
                out.append(
                    MemoryCandidate(
                        id=str(item["id"]),
                        target=str(item["target"]),
                        content=str(item["content"]),
                        status=str(item["status"]),
                        created_at=float(item.get("created_at", 0.0)),
                    )
                )
            except (KeyError, TypeError, ValueError):
                continue
        return out

    def _save(self, job_id: str, candidates: list[MemoryCandidate]) -> None:
        path = self._candidates_path(job_id)
        payload = json.dumps([c.to_dict() for c in candidates], ensure_ascii=False, indent=2)
        # Atomic: tmp file in same dir + os.replace.
        fd, tmp_name = tempfile.mkstemp(
            dir=str(path.parent), prefix=".memory_candidates.", suffix=".tmp"
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
            os.replace(tmp_name, path)
        finally:
            try:
                if os.path.exists(tmp_name):
                    os.unlink(tmp_name)
            except OSError:
                pass

    @staticmethod
    def _find(candidates: list[MemoryCandidate], candidate_id: str) -> MemoryCandidate:
        for candidate in candidates:
            if candidate.id == candidate_id:
                return candidate
        raise ValueError(f"unknown candidate: {candidate_id}")

    def _append_approved(self, candidate: MemoryCandidate) -> None:
        mem_dir = self._hermes_home / "memories"
        mem_dir.mkdir(parents=True, exist_ok=True)
        path = mem_dir / candidate.target
        # Containment for the home profile (no symlink escapes).
        try:
            resolved = path.resolve()
            resolved.relative_to(self._hermes_home.resolve())
        except ValueError as exc:
            raise ValueError("hermes home escape") from exc
        if path.is_symlink():
            raise ValueError("memory file is a symlink; refusing write")
        try:
            raw = path.read_text(encoding="utf-8") if path.is_file() else ""
        except OSError:
            raw = ""
        entries = (
            [entry for entry in (part.strip() for part in raw.split("\n§\n")) if entry]
            if raw.strip()
            else []
        )
        if candidate.content.strip() in entries:
            return  # idempotent: already present
        entries.append(candidate.content.strip())
        payload = "\n§\n".join(entries) + ("\n" if entries else "")
        fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".mem.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
            os.replace(tmp_name, path)
        finally:
            try:
                if os.path.exists(tmp_name):
                    os.unlink(tmp_name)
            except OSError:
                pass
