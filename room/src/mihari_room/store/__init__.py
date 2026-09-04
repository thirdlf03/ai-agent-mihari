"""ディスクに仕事を置く JobStore。meta.json が正本。"""

from mihari_room.store.file_store import FileJobStore, JobNotFound

__all__ = ["FileJobStore", "JobNotFound"]
