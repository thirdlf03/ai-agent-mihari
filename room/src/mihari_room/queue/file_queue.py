"""一人机のキュー。店 (JobStore) の上に座る。同時に RUNNING は 1 件。"""

from __future__ import annotations

import os
from collections.abc import Callable, Sequence
from typing import Any

from mihari_room.contracts import Job, JobStatus, JobStore

#: 持ち主の合言葉が入っている環境変数
OWNER_ENV_VAR = "MIHARI_OWNER_ID"


class CancelNotAllowed(PermissionError):
    """頼んだ人でも持ち主でもないので取り消せない。"""


class FileJobQueue:
    """机番。順番と作業中はディスク (店) に書くので再起動しても忘れない。"""

    def __init__(self, store: JobStore) -> None:
        self._store = store
        # 契約だけの店 (list_running がない) 用のメモ
        self._running_id: str | None = None

    def enqueue(self, job: Job) -> None:
        """机に載せる。もう queued なら何もしない。"""
        current = self._store.get(job.id)
        if current.status is not JobStatus.QUEUED:
            self._store.set_status(job.id, JobStatus.QUEUED)
        if self._running_id == job.id:
            self._running_id = None

    def dequeue(self) -> Job | None:
        """一番古い待ちを作業中に。机が埋まっているか空なら None。"""
        if self.running() is not None:
            return None
        queued = self._store.list_queued()
        if not queued:
            return None
        job = self._store.set_status(queued[0].id, JobStatus.RUNNING)
        self._running_id = job.id
        return job

    def running(self) -> Job | None:
        """今作業中の仕事。なければ None。"""
        list_running: Callable[[], Sequence[Job]] | Any = getattr(self._store, "list_running", None)
        if callable(list_running):
            found = list_running()
            return found[0] if found else None
        # 古い店では手元のメモと現物を突き合わせる
        if self._running_id is None:
            return None
        try:
            job = self._store.get(self._running_id)
        except LookupError:
            self._running_id = None
            return None
        if job.status is not JobStatus.RUNNING:
            self._running_id = None
            return None
        return job

    def cancel(self, job_id: str, *, by: str) -> Job:
        """頼んだ人か持ち主だけ取り消せる。作業中なら机が空く。"""
        job = self._store.get(job_id)
        owner = os.environ.get(OWNER_ENV_VAR)
        if by != job.requested_by and by != owner:
            raise CancelNotAllowed(f"job {job_id} は {by} には取り消せない")
        cancelled = self._store.set_status(job_id, JobStatus.CANCELLED)
        if self._running_id == job_id:
            self._running_id = None
        return cancelled
