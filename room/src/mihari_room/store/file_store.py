"""ディスクに置く JobStore。$root/jobs/<id>/ が仕事の置き場。"""

from __future__ import annotations

import json
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any
from uuid import uuid4

from mihari_room.contracts import (
    INPUT_DIRNAME,
    JOBS_DIRNAME,
    META_FILENAME,
    OUTPUT_DIRNAME,
    CreateJobRequest,
    Job,
    JobSource,
    JobStatus,
)


class JobNotFound(KeyError):
    """指定の仕事がディスクにない。"""


class FileJobStore:
    """meta.json を正本にする JobStore。毎回ディスクから読み直す。"""

    def __init__(self, root: Path) -> None:
        # 手元に状態を持たない。再起動後も同じ root なら続きが見える。
        self._root = root

    @property
    def _jobs_root(self) -> Path:
        return self._root / JOBS_DIRNAME

    def create(self, request: CreateJobRequest) -> Job:
        """仕事部屋を掘って meta.json を書く。生まれたては queued。"""
        self._jobs_root.mkdir(parents=True, exist_ok=True)
        # 被らない id を引くまで振り直す
        while True:
            job_id = uuid4().hex[:12]
            directory = self._jobs_root / job_id
            if not directory.exists():
                break
        directory.mkdir(parents=True)
        (directory / INPUT_DIRNAME).mkdir(parents=True, exist_ok=True)
        (directory / OUTPUT_DIRNAME).mkdir(parents=True, exist_ok=True)
        meta: dict[str, Any] = {
            "id": job_id,
            "title": request.title,
            "body": request.body,
            "status": JobStatus.QUEUED.value,
            "source": request.source.value,
            "thread_id": request.thread_id,
            "requested_by": request.requested_by,
            "parent_id": request.parent_id,
            # Job にはないが、机の順番を覚えるための出生時刻
            "created_at": self._next_created_at(),
        }
        self._write_meta(job_id, meta)
        return self._job_from_meta(meta)

    def get(self, job_id: str) -> Job:
        meta = self._read_meta(job_id)
        return self._job_from_meta(meta)

    def list_queued(self) -> Sequence[Job]:
        """待ち行列。古い順 (FIFO) に並べる。"""
        return tuple(job for _, job in self._iter_jobs_sorted() if job.status is JobStatus.QUEUED)

    def list_running(self) -> Sequence[Job]:
        """作業中の机。ふつうは 0 か 1 件。古い順。"""
        return tuple(job for _, job in self._iter_jobs_sorted() if job.status is JobStatus.RUNNING)

    def set_status(self, job_id: str, status: JobStatus) -> Job:
        meta = self._read_meta(job_id)
        meta["status"] = status.value
        self._write_meta(job_id, meta)
        return self._job_from_meta(meta)

    def set_thread_id(self, job_id: str, thread_id: int) -> Job:
        meta = self._read_meta(job_id)
        meta["thread_id"] = thread_id
        self._write_meta(job_id, meta)
        return self._job_from_meta(meta)

    def restore_running_to_queued(self) -> Sequence[Job]:
        """落ちていた机を片づける。running は全部 queued に戻す。"""
        restored: list[Job] = []
        for _, job in self._iter_jobs_sorted():
            if job.status is JobStatus.RUNNING:
                restored.append(self.set_status(job.id, JobStatus.QUEUED))
        return tuple(restored)

    def job_dir(self, job_id: str) -> Path:
        # meta がない置き場は仕事ではない
        self._read_meta(job_id)
        return self._jobs_root / job_id

    def input_dir(self, job_id: str) -> Path:
        return self.job_dir(job_id) / INPUT_DIRNAME

    def output_dir(self, job_id: str) -> Path:
        return self.job_dir(job_id) / OUTPUT_DIRNAME

    def _iter_jobs_sorted(self) -> list[tuple[float, Job]]:
        """(出生時刻, 仕事) を古い順に。読めない置き場は飛ばす。"""
        found: list[tuple[float, Job]] = []
        if not self._jobs_root.is_dir():
            return found
        for directory in sorted(self._jobs_root.iterdir(), key=lambda p: p.name):
            if not directory.is_dir():
                continue
            try:
                meta = self._read_meta(directory.name)
            except JobNotFound:
                continue
            created_at = meta.get("created_at", 0.0)
            try:
                order = float(created_at)
            except (TypeError, ValueError):
                order = 0.0
            found.append((order, self._job_from_meta(meta)))
        # 同時刻に生まれた双子は id 順で決着
        found.sort(key=lambda item: (item[0], item[1].id))
        return found

    def _next_created_at(self) -> float:
        """今より少し未来の出生時刻。時計が粗くても順番が崩れない。"""
        now = time.time()
        latest: float | None = None
        if self._jobs_root.is_dir():
            for directory in self._jobs_root.iterdir():
                meta_path = directory / META_FILENAME
                if not meta_path.is_file():
                    continue
                try:
                    raw = json.loads(meta_path.read_text(encoding="utf-8"))
                    created = float(raw.get("created_at", 0.0))
                except (ValueError, TypeError, AttributeError):
                    continue
                if latest is None or created > latest:
                    latest = created
        if latest is not None and latest >= now:
            return latest + 0.001
        return now

    def _meta_path(self, job_id: str) -> Path:
        return self._jobs_root / job_id / META_FILENAME

    def _read_meta(self, job_id: str) -> dict[str, Any]:
        path = self._meta_path(job_id)
        if not path.is_file():
            raise JobNotFound(job_id)
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise JobNotFound(job_id)
        return data

    def _write_meta(self, job_id: str, meta: dict[str, Any]) -> None:
        path = self._meta_path(job_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def _job_from_meta(self, meta: dict[str, Any]) -> Job:
        job_id = str(meta["id"])
        return Job(
            id=job_id,
            title=str(meta["title"]),
            body=str(meta["body"]),
            status=JobStatus(str(meta["status"])),
            source=JobSource(str(meta["source"])),
            directory=self._jobs_root / job_id,
            thread_id=meta.get("thread_id"),
            requested_by=meta.get("requested_by"),
            parent_id=meta.get("parent_id"),
        )
