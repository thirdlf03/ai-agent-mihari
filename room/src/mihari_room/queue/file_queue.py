"""一人机のキュー。店 (JobStore) の上に座る。同時に RUNNING は 1 件。"""

from __future__ import annotations

from mihari_room.contracts import Job, JobStatus, JobStore

#: 持ち主の合言葉が入っている環境変数。読むのは config。ここには注入する。
OWNER_ENV_VAR = "MIHARI_OWNER_ID"


class CancelNotAllowed(PermissionError):
    """頼んだ人でも持ち主でもないので取り消せない。"""


class FileJobQueue:
    """机番。順番と作業中はディスク (店) に書くので再起動しても忘れない。"""

    def __init__(self, store: JobStore, *, owner_id: str | None = None) -> None:
        self._store = store
        self._owner_id = owner_id or None

    def enqueue(self, job: Job) -> None:
        """机に載せる。もう queued なら何もしない。"""
        current = self._store.get(job.id)
        if current.status is not JobStatus.QUEUED:
            self._store.set_status(job.id, JobStatus.QUEUED)

    def dequeue(self) -> Job | None:
        """一番古い待ちを作業中に。机が埋まっているか空なら None。"""
        if self.running() is not None:
            return None
        queued = self._store.list_queued()
        if not queued:
            return None
        return self._store.set_status(queued[0].id, JobStatus.RUNNING)

    def running(self) -> Job | None:
        """今作業中の仕事。なければ None。"""
        found = self._store.list_running()
        return found[0] if found else None

    def cancel(self, job_id: str, *, by: str) -> Job:
        """頼んだ人か持ち主だけ取り消せる。作業中なら机が空く。"""
        job = self._store.get(job_id)
        if by != job.requested_by and by != self._owner_id:
            raise CancelNotAllowed(f"job {job_id} は {by} には取り消せない")
        return self._store.set_status(job_id, JobStatus.CANCELLED)
