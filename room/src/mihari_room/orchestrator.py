"""キュー・Forum・Hermes を一本に繋ぐ。Discord の口調変換はしない。"""

from __future__ import annotations

import asyncio
import json
import logging
import re
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from mihari_room.contracts import (
    SCREENSHOTS_DIRNAME,
    CreateJobRequest,
    ForumBoard,
    Job,
    JobQueue,
    JobStatus,
    JobStore,
    JobWorker,
    ProgressEvent,
    ProgressKind,
    ScreenshotAttachment,
)
from mihari_room.events import (
    EventJournal,
    EventPhase,
    JournalKind,
    kind_from_progress,
    sanitize_text,
)
from mihari_room.store.file_store import JobNotFound
from mihari_room.worker.agent import read_session_id
from mihari_room.worker.wrangler_temp import temp_deploys_for

logger = logging.getLogger("mihari_room")

#: 実行中に続きが来たとき、終わったらもう一回回す印。
REQUEUE_FILENAME = "requeue"

#: Forum が起きるのを待つ間隔。短すぎると空回り、長すぎると起動がもたつく。
_BOARD_READY_POLL_SEC = 0.05
#: ポンプが転んだあとの一息。同じ例外で忙しく死なないように。
_PUMP_BACKOFF_SEC = 0.5


class RoomOrchestrator:
    """机番。HTTP と Forum の両方から仕事を受けて、空いたら Hermes に渡す。"""

    def __init__(
        self,
        store: JobStore,
        queue: JobQueue,
        board: ForumBoard,
        worker: JobWorker,
        publisher: Any = None,
    ) -> None:
        self._store = store
        self._queue = queue
        self._board = board
        self._worker = worker
        self._publisher = publisher
        self._wake = asyncio.Event()
        self._pump_task: asyncio.Task[None] | None = None

    @property
    def publisher(self) -> Any:
        return self._publisher

    def attach_publisher(self, publisher: Any) -> None:
        """成果物の公開口を後付けする。cli は store を先に作るので。"""
        self._publisher = publisher

    @property
    def store(self) -> JobStore:
        return self._store

    def _journal(self, job_id: str) -> EventJournal:
        return EventJournal.for_job(self._store.job_dir(job_id))

    def restore(self) -> Sequence[Job]:
        """起動直後。作業中だった机を待ちに戻し、待ちの仕事はポンプで再開する。"""
        restored = self._store.restore_running_to_queued()
        for job in restored:
            self._journal(job.id).append(
                job_id=job.id,
                phase=EventPhase.QUEUED,
                kind=JournalKind.LOG,
                text=f"再起動したよ。{job.title} は待ちに戻した。",
            )
        # running が無くても、待ちの仕事があれば机は回り出す。
        if restored or self._store.list_queued():
            self.wake()
        return restored

    def wake(self) -> None:
        self._wake.set()

    def start_pump(self) -> None:
        """待ち行列を回すループを立てる。テストでも本番でも同じ。"""
        if self._pump_task is None or self._pump_task.done():
            self._pump_task = asyncio.create_task(self._pump(), name="mihari-room-pump")

    async def aclose(self) -> None:
        task = self._pump_task
        self._pump_task = None
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    async def submit(
        self,
        request: CreateJobRequest,
        *,
        attachments: Sequence[tuple[str, bytes]] = (),  # noqa: A002 -- Discord 等の添付
        screenshots: Sequence[ScreenshotAttachment] = (),
    ) -> Job:
        """新しい仕事。ペット経由ならスレッドを切る。Forum 直なら thread_id 済み。"""
        job = self._store.create(request)
        self._save_attachments(job.id, attachments)
        self._save_screenshots(job.id, screenshots)
        if job.thread_id is None:
            try:
                thread_id = await self._board.create_thread(job)
            except Exception as exc:
                # スレッド無しで queued のまま残すと、机が thread 無し job を
                # 拾って crash loop する（phantom running）。失敗で畳んで wake しない。
                logger.exception("Forum スレッド作成に失敗 job=%s", job.id)
                self._store.set_status(job.id, JobStatus.FAILED)
                self._journal(job.id).append(
                    job_id=job.id,
                    phase=EventPhase.FAILED,
                    kind=JournalKind.LOG,
                    text="スレッドが切れなかったよ。もう一度頼んで。",
                )
                raise RuntimeError(f"Forum スレッドが切れない: {exc}") from exc
            job = self._store.set_thread_id(job.id, thread_id)
        await self._board.set_tag(self._require_thread(job), JobStatus.QUEUED)
        self._queue.enqueue(job)
        self._journal(job.id).append(
            job_id=job.id,
            phase=EventPhase.QUEUED,
            kind=JournalKind.LOG,
            text=f"受け付けたよ。{job.title}",
        )
        self.wake()
        return self._store.get(job.id)

    async def follow_up(self, thread_id: int, body: str, *, requested_by: str) -> Job:
        """同じスレッドの続き。同じフォルダに追記して、空いたらもう一度回す。"""
        job = self._require_by_thread(thread_id)
        return await self.follow_up_job(job.id, body, requested_by=requested_by)

    async def follow_up_job(
        self,
        job_id: str,
        body: str,
        *,
        requested_by: str,
        screenshots: Sequence[ScreenshotAttachment] = (),
    ) -> Job:
        """同じ仕事の続き。同じセッションへ次のターンとして回す。"""
        job = self._store.get(job_id)
        self._write_followup(job.id, body)
        self._save_screenshots(job.id, screenshots)
        current = self._store.get(job.id)
        if current.status is JobStatus.RUNNING:
            (self._store.job_dir(job.id) / REQUEUE_FILENAME).write_text("1", encoding="utf-8")
            return current
        if current.status is JobStatus.CANCELLED and self._worker_running(job_id):
            # 中断した thread がまだ生きている間の追記は、thread 終了後の
            # requeue 印に載せる。先走って queued に戻すと二重実行になる。
            (self._store.job_dir(job.id) / REQUEUE_FILENAME).write_text("1", encoding="utf-8")
            return current
        if current.status is not JobStatus.QUEUED:
            current = self._store.set_status(job.id, JobStatus.QUEUED)
            self._journal(job.id).append(
                job_id=job.id,
                phase=EventPhase.QUEUED,
                kind=JournalKind.LOG,
                text=f"続きが来た。{job.title} はまた待ちに並んだ。",
            )
            await self._board.set_tag(self._require_thread(current), JobStatus.QUEUED)
            self._queue.enqueue(current)
            self.wake()
        return self._store.get(job.id)

    async def cancel(self, job_id: str, *, by: str) -> Job:
        job = self._queue.cancel(job_id, by=by)
        # 実行中の worker thread があれば実際に interrupt する（status flag だけにしない）。
        # thread 終了は _run_job 側が待つ。ここでは届けただけにする。
        try:
            requester = getattr(self._worker, "request_cancel", None)
            if callable(requester):
                requester(job_id)
        except Exception:
            logger.debug("worker request_cancel failed", exc_info=True)
        thread_id = job.thread_id
        self._journal(job_id).append(
            job_id=job_id,
            phase=EventPhase.WAITING,
            kind=JournalKind.CANCELLED,
            text="やめたよ。途中まで残しておくね。",
        )
        if thread_id is not None:
            await self._board.set_tag(thread_id, JobStatus.CANCELLED)
            await self._board.post_speech(thread_id, "わかった。途中まで残しておくね。")
        self.wake()
        return self._store.get(job.id)

    async def cancel_thread(self, thread_id: int, *, by: str) -> Job:
        job = self._require_by_thread(thread_id)
        return await self.cancel(job.id, by=by)

    def _worker_running(self, job_id: str) -> bool:
        checker = getattr(self._worker, "is_running", None)
        if not callable(checker):
            return False
        try:
            return bool(checker(job_id))
        except Exception:
            return False

    async def _wait_worker_exit(self, job_id: str, timeout: float = 30.0) -> None:
        """中断した thread の終了を待つ。次の job はその後にしか渡さない。"""
        import time as _time

        deadline = _time.monotonic() + timeout
        while self._worker_running(job_id):
            if _time.monotonic() >= deadline:
                break
            await asyncio.sleep(0.05)

    async def say(self, thread_id: int, text: str) -> None:
        """Forum に短い返事を書く。キャンセルを断ったときなど。"""
        await self._board.post_speech(thread_id, text)

    def _board_is_ready(self) -> bool:
        """BoundForumBoard は bind 前だけ待つ。RecordingBoard には印がないので起きている扱い。"""
        if not hasattr(self._board, "is_ready"):
            return True
        value = self._board.is_ready
        if callable(value):
            return bool(value())
        return bool(value)

    async def _wait_until_board_ready(self) -> None:
        while not self._board_is_ready():
            await asyncio.sleep(_BOARD_READY_POLL_SEC)

    async def _pump(self) -> None:
        try:
            while True:
                await self._wait_until_board_ready()
                await self._wake.wait()
                self._wake.clear()
                try:
                    await self._run_available()
                except asyncio.CancelledError:
                    raise
                except Exception:
                    logger.exception("ポンプが転んだ。机を待ちに戻して続ける")
                    restored = self._store.restore_running_to_queued()
                    if restored:
                        self.wake()
                    await asyncio.sleep(_PUMP_BACKOFF_SEC)
        except asyncio.CancelledError:
            raise

    async def _run_available(self) -> None:
        while True:
            job = self._queue.dequeue()
            if job is None:
                return
            await self._run_job(job)

    async def _run_job(self, job: Job) -> None:
        thread_id = self._require_thread(job)
        await self._board.set_tag(thread_id, JobStatus.RUNNING)
        start_typing = getattr(self._board, "start_typing", None)
        stop_typing = getattr(self._board, "stop_typing", None)
        if callable(start_typing):
            await start_typing(thread_id)

        journal = self._journal(job.id)
        # 段階の初期値。worker が phase を明示したらそちらへ進む。
        current_phase = EventPhase.RESEARCHING
        # 終端（done / failed）で使う最後の発話。
        terminal_text: str | None = None
        last_speech = ""

        async def on_progress(event: ProgressEvent) -> None:
            nonlocal current_phase, terminal_text, last_speech
            latest = self._store.get(job.id)
            if latest.status is JobStatus.CANCELLED:
                return
            if event.phase is not None:
                try:
                    current_phase = EventPhase(event.phase)
                except ValueError:
                    pass
            if event.kind is ProgressKind.MEMORY_CANDIDATE:
                # 承認待ち候補の通知。phase は WAITING。job は塞がない。
                journal.append(
                    job_id=job.id,
                    phase=EventPhase.WAITING,
                    kind=JournalKind.MEMORY_CANDIDATE,
                    text=event.text,
                )
                return
            if event.kind is ProgressKind.SPEECH or event.kind is ProgressKind.SUMMARY:
                # 発話は段階の変わり目だけ残す。段階を明示してないなら
                # 終端（done / failed）の発話として使う。
                terminal_text = event.text
                if event.phase is not None:
                    journal.append(
                        job_id=job.id,
                        phase=current_phase,
                        kind=kind_from_progress(event.kind),
                        text=event.text,
                    )
            elif event.kind is ProgressKind.FILE:
                journal.append(
                    job_id=job.id,
                    phase=current_phase,
                    kind=JournalKind.FILE,
                    text=event.path.name if event.path is not None else event.text,
                )
            else:  # LOG
                journal.append(
                    job_id=job.id,
                    phase=current_phase,
                    kind=JournalKind.LOG,
                    text=event.text,
                )
            # Forum への書き出しは従来どおり。claim URL は伏せる。
            safe_text = sanitize_text(event.text) or ""
            if event.kind is ProgressKind.SPEECH:
                last_speech = safe_text.strip()
                await self._board.post_speech(thread_id, safe_text)
            elif event.kind is ProgressKind.LOG:
                await self._board.post_log(thread_id, safe_text)
            elif event.kind is ProgressKind.FILE:
                if event.path is not None:
                    await self._board.post_file(thread_id, event.path)
            elif event.kind is ProgressKind.SUMMARY:
                # 最終返答を SPEECH と SUMMARY の両方で流す Worker がある。同じ文面は 1 通。
                if safe_text.strip() == last_speech:
                    return
                await self._board.post_summary(thread_id, safe_text)

        journal.append(
            job_id=job.id,
            phase=current_phase,
            kind=JournalKind.LOG,
            text=f"はじめるね。{job.title}",
        )

        error: str | None = None
        try:
            status = await self._worker.run(job, on_progress)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            # worker が転んでも机は失敗で畳む（再試行には回さない）。
            logger.exception("worker が転んだ job=%s", job.id)
            error = str(exc)
            status = JobStatus.FAILED
        finally:
            if callable(stop_typing):
                await stop_typing(thread_id)

        latest = self._store.get(job.id)
        # 続きの印は成否に関わらず消す。FAILED のまま残すと、次に成功した瞬間に余分に回る。
        wants_again = self._consume_requeue(job.id)
        if latest.status is JobStatus.CANCELLED:
            # 中断した thread がまだ生きていたら、終了を待ってから次へ。
            # 先走って次の job を渡すと同プロセスの agent が二重に回る。
            await self._wait_worker_exit(job.id)
            if wants_again:
                # cancel 後の追記は thread 終了後に改めて queued へ（終了前の再開はしない）。
                latest = self._store.set_status(job.id, JobStatus.QUEUED)
                journal.append(
                    job_id=job.id,
                    phase=EventPhase.QUEUED,
                    kind=JournalKind.LOG,
                    text="続きが来た。もう一度やるね。",
                )
                await self._board.set_tag(thread_id, JobStatus.QUEUED)
                self._queue.enqueue(latest)
            self.wake()
            return
        latest = self._store.set_status(job.id, status)
        await self._board.set_tag(thread_id, status)
        if status is JobStatus.DONE:
            journal.append(
                job_id=job.id,
                phase=EventPhase.DONE,
                kind=JournalKind.SUMMARY,
                text=terminal_text or "やりきったよ。",
            )
            await self._publish_if_any(job, thread_id)
        elif status is JobStatus.FAILED:
            journal.append(
                job_id=job.id,
                phase=EventPhase.FAILED,
                kind=JournalKind.LOG,
                text=error or terminal_text or "うまくいかなかったよ。",
            )
        if wants_again:
            latest = self._store.set_status(job.id, JobStatus.QUEUED)
            journal.append(
                job_id=job.id,
                phase=EventPhase.QUEUED,
                kind=JournalKind.LOG,
                text="続きが来た。もう一度やるね。",
            )
            await self._board.set_tag(thread_id, JobStatus.QUEUED)
            self._queue.enqueue(latest)
        self.wake()

    async def _publish_if_any(self, job: Job, thread_id: int) -> None:
        """成功した仕事の静的プレビューと一時デプロイを知らせる。"""
        await self._announce_temp_deploy(job, thread_id)
        publisher = self._publisher
        if publisher is None or not getattr(publisher, "enabled", False):
            return
        try:
            manifest = publisher.publish(job, read_session_id(job))
        except Exception:
            logger.exception("成果物の公開に失敗した job=%s", job.id)
            self._journal(job.id).append(
                job_id=job.id,
                phase=EventPhase.DONE,
                kind=JournalKind.LOG,
                text="プレビューの公開に失敗したよ（仕事は完了）。",
            )
            return
        if manifest is None or not manifest.get("preview_url"):
            return
        url = manifest["preview_url"]
        message = f"プレビューを置いたよ: {url}"
        self._journal(job.id).append(
            job_id=job.id,
            phase=EventPhase.DONE,
            kind=JournalKind.SUMMARY,
            text=message,
        )
        await self._board.post_summary(thread_id, message)

    async def _announce_temp_deploy(self, job: Job, thread_id: int) -> None:
        """workers.dev だけ Forum に出す。claim URL は載せない。"""
        deploys = temp_deploys_for(job.directory)
        if not deploys:
            return
        url = str(deploys[-1].get("preview_url") or "").strip()
        if not url:
            return
        message = f"一時デプロイしたよ: {url}"
        self._journal(job.id).append(
            job_id=job.id,
            phase=EventPhase.DONE,
            kind=JournalKind.SUMMARY,
            text=message,
        )
        await self._board.post_summary(thread_id, message)

    def _consume_requeue(self, job_id: str) -> bool:
        path = self._store.job_dir(job_id) / REQUEUE_FILENAME
        if not path.is_file():
            return False
        path.unlink()
        return True

    def _write_followup(self, job_id: str, body: str) -> None:
        folder = self._store.input_dir(job_id)
        existing = list(folder.glob("followup-*.txt"))
        path = folder / f"followup-{len(existing) + 1:02d}.txt"
        path.write_text(body, encoding="utf-8")

    def _save_attachments(self, job_id: str, attachments: Sequence[tuple[str, bytes]]) -> None:
        folder = self._store.input_dir(job_id)
        for name, data in attachments:
            safe = Path(name).name or "attachment"
            (folder / safe).write_bytes(data)

    # -- Mac スクショ（#22） --------------------------------------------------

    #: 認める拡張子。PNG/JPEG 系はそのまま画像として Hermes に載せられる。
    _SCREENSHOT_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".gif"}

    def _save_screenshots(self, job_id: str, screenshots: Sequence[ScreenshotAttachment]) -> None:
        """スクショを input/screenshots/<seq>.<ext> に保存する。

        撮影メタデータ（scale・座標など）は <seq>.json に置く。成果物公開の対象は
        output/ だけなので、ここに置いた限り自動で公開されない。
        """
        if not screenshots:
            return
        folder = self._store.input_dir(job_id) / SCREENSHOTS_DIRNAME
        folder.mkdir(parents=True, exist_ok=True)
        for upload in screenshots:
            if not upload.data:
                continue
            seq = self._next_screenshot_seq(folder)
            suffix = self._suffix_for(upload.filename)
            target = folder / f"{seq:04d}{suffix}"
            target.write_bytes(upload.data)
            meta = dict(upload.metadata or {})
            meta["original_filename"] = Path(upload.filename).name
            (folder / f"{seq:04d}.json").write_text(
                json.dumps(meta, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8"
            )

    def _next_screenshot_seq(self, folder: Path) -> int:
        """置き場にある画像の次の連番。並行で同じ番号を引かないよう冪等に数える。"""
        highest = 0
        try:
            for path in folder.iterdir():
                if not path.is_file():
                    continue
                match = re.match(r"^(\d{4,})\.(?:png|jpe?g|webp|gif)$", path.name, re.IGNORECASE)
                if match:
                    highest = max(highest, int(match.group(1)))
        except OSError:
            pass
        return highest + 1

    @staticmethod
    def _suffix_for(filename: str) -> str:
        suffix = Path(filename or "").suffix.lower()
        if suffix in RoomOrchestrator._SCREENSHOT_SUFFIXES:
            return suffix
        # 未知の拡張子は Hermes が読みやすい PNG として置く。
        return ".png"

    def _require_thread(self, job: Job) -> int:
        if job.thread_id is None:
            raise RuntimeError(f"job {job.id} にスレッドがない")
        return job.thread_id

    def _require_by_thread(self, thread_id: int) -> Job:
        job = self._store.find_by_thread_id(thread_id)
        if job is None:
            raise JobNotFound(f"thread {thread_id}")
        return job
