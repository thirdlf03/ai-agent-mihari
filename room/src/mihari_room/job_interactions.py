"""実行中ジョブへの steer と質問回答。voice session とは ID 分離。

- steer: ``input/steer/`` に追記し、live worker へ届けられるなら届ける
- questions: ``questions.json`` に pending を置き、回答まで worker thread を待つ
"""

from __future__ import annotations

import json
import secrets
import threading
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass
from enum import StrEnum
from pathlib import Path
from typing import Any, Literal

from mihari_room.contracts import INPUT_DIRNAME, Job, JobStatus

STEER_DIRNAME = "steer"
QUESTIONS_FILENAME = "questions.json"

#: 質問回答の既定待ち時間（秒）。Hermes timeout と揃える想定。
DEFAULT_QUESTION_TIMEOUT_SEC = 15 * 60


class QuestionStatus(StrEnum):
    PENDING = "pending"
    ANSWERED = "answered"
    CANCELLED = "cancelled"


@dataclass(frozen=True, slots=True)
class PendingQuestion:
    id: str
    question: str
    choices: list[str] | None
    multi_select: bool
    status: QuestionStatus
    answer: str | None = None
    created_at: float = 0.0
    answered_at: float | None = None

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["status"] = self.status.value
        return data

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> PendingQuestion:
        return cls(
            id=str(raw["id"]),
            question=str(raw["question"]),
            choices=list(raw["choices"]) if raw.get("choices") is not None else None,
            multi_select=bool(raw.get("multi_select", False)),
            status=QuestionStatus(str(raw.get("status") or QuestionStatus.PENDING.value)),
            answer=raw.get("answer"),
            created_at=float(raw.get("created_at") or 0.0),
            answered_at=raw.get("answered_at"),
        )


class QuestionNotFound(LookupError):
    """指定 qid の質問が無い、または別 job のもの。"""


class QuestionNotPending(ValueError):
    """既に回答済み・取消済み。"""


class SteerNotAllowed(PermissionError):
    """steer できない状態（queued / done など）。"""


class AnswerNotAllowed(PermissionError):
    """回答できない状態。"""


def _steer_dir(job_dir: Path) -> Path:
    return job_dir / INPUT_DIRNAME / STEER_DIRNAME


def _questions_path(job_dir: Path) -> Path:
    return job_dir / QUESTIONS_FILENAME


def _read_questions(job_dir: Path) -> list[PendingQuestion]:
    path = _questions_path(job_dir)
    if not path.is_file():
        return []
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return []
    items = raw.get("questions") if isinstance(raw, dict) else raw
    if not isinstance(items, list):
        return []
    out: list[PendingQuestion] = []
    for item in items:
        if isinstance(item, dict):
            try:
                out.append(PendingQuestion.from_dict(item))
            except (KeyError, TypeError, ValueError):
                continue
    return out


def _write_questions(job_dir: Path, questions: list[PendingQuestion]) -> None:
    path = _questions_path(job_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"questions": [q.to_dict() for q in questions]}
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def list_questions(job_dir: Path) -> list[PendingQuestion]:
    return _read_questions(job_dir)


def list_pending_questions(job_dir: Path) -> list[PendingQuestion]:
    return [q for q in _read_questions(job_dir) if q.status is QuestionStatus.PENDING]


def append_steer(job_dir: Path, text: str) -> dict[str, Any]:
    """steer 指示を input/steer/NNN.txt に追記する。"""
    trimmed = text.strip()
    if not trimmed:
        raise ValueError("steer text is empty")
    folder = _steer_dir(job_dir)
    folder.mkdir(parents=True, exist_ok=True)
    seq = 1
    for path in folder.glob("*.txt"):
        try:
            seq = max(seq, int(path.stem) + 1)
        except ValueError:
            continue
    filename = f"{seq:03d}.txt"
    created_at = time.time()
    (folder / filename).write_text(trimmed + "\n", encoding="utf-8")
    return {
        "seq": seq,
        "filename": filename,
        "text": trimmed,
        "created_at": created_at,
    }


def list_steers(job_dir: Path) -> list[dict[str, Any]]:
    folder = _steer_dir(job_dir)
    if not folder.is_dir():
        return []
    out: list[dict[str, Any]] = []
    for path in sorted(folder.glob("*.txt")):
        try:
            seq = int(path.stem)
        except ValueError:
            continue
        try:
            text = path.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        out.append({"seq": seq, "filename": path.name, "text": text})
    return out


#: steer の消費カーソル。live 配信済み・ターン消費済みの seq まで進める。
#: ``input/followup-*.txt`` の followup_cursor と同じ仕組み。
STEER_CURSOR_FILENAME = "steer_cursor"


def _steer_cursor_path(job_dir: Path) -> Path:
    return job_dir / INPUT_DIRNAME / STEER_CURSOR_FILENAME


def _read_steer_cursor(job_dir: Path) -> int:
    path = _steer_cursor_path(job_dir)
    if not path.is_file():
        return 0
    try:
        return max(0, int(path.read_text(encoding="utf-8").strip()))
    except (OSError, ValueError):
        return 0


def _write_steer_cursor(job_dir: Path, seq: int) -> None:
    try:
        _steer_cursor_path(job_dir).write_text(f"{max(0, seq)}\n", encoding="utf-8")
    except OSError:
        pass


def pending_steers(job: Job) -> list[dict[str, Any]]:
    """未消費の steer。カーソルより後の seq だけ（live 配信・ターン消費済みは除く）。"""
    delivered = _read_steer_cursor(job.directory)
    return [item for item in list_steers(job.directory) if int(item["seq"]) > delivered]


def advance_steer_cursor(job: Job, executed: list[dict[str, Any]] | None = None) -> None:
    """ターンで消費した steer 分だけカーソルを進める。失敗時は呼ばない。"""
    steers = executed if executed is not None else list_steers(job.directory)
    if not steers:
        return
    _write_steer_cursor(job.directory, max(int(item["seq"]) for item in steers))


def mark_steer_delivered(job_dir: Path, seq: int) -> None:
    """live worker へ届いた steer。次ターンで再送しないようカーソルを進める。"""
    if seq > _read_steer_cursor(job_dir):
        _write_steer_cursor(job_dir, seq)


StatusCallback = Callable[[str, JobStatus], None]


class JobInteractionHub:
    """steer 配信と質問待ちを thread-safe に束ねる。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._answer_events: dict[str, threading.Event] = {}
        self._answers: dict[str, str] = {}
        self._status_callbacks: list[StatusCallback] = []
        self._steer_deliverers: dict[str, Callable[[str, str], bool]] = {}

    def add_status_callback(self, callback: StatusCallback) -> None:
        self._status_callbacks.append(callback)

    def register_steer_deliverer(
        self, job_id: str, deliverer: Callable[[str, str], bool]
    ) -> None:
        with self._lock:
            self._steer_deliverers[job_id] = deliverer

    def unregister_steer_deliverer(self, job_id: str) -> None:
        with self._lock:
            self._steer_deliverers.pop(job_id, None)

    def _notify_status(self, job_id: str, status: JobStatus) -> None:
        for callback in list(self._status_callbacks):
            try:
                callback(job_id, status)
            except Exception:
                pass

    def steer(self, job: Job, text: str) -> dict[str, Any]:
        """steer を永続化し、live worker へ届ける。"""
        if job.status not in (JobStatus.RUNNING, JobStatus.WAITING_FOR_INPUT):
            raise SteerNotAllowed(f"job {job.id} is not steerable ({job.status.value})")
        record = append_steer(job.directory, text)
        delivered = False
        with self._lock:
            deliverer = self._steer_deliverers.get(job.id)
        if deliverer is not None:
            try:
                delivered = bool(deliverer(job.id, text))
            except Exception:
                delivered = False
        if delivered:
            # live 配信できた steer は次ターンの pending に出さない。
            mark_steer_delivered(job.directory, int(record["seq"]))
        record["delivered"] = delivered
        return record

    def register_question(
        self,
        job: Job,
        question: str,
        choices: list[str] | None,
        *,
        multi_select: bool = False,
    ) -> PendingQuestion:
        qid = secrets.token_hex(6)
        pending = PendingQuestion(
            id=qid,
            question=question.strip(),
            choices=list(choices) if choices else None,
            multi_select=multi_select,
            status=QuestionStatus.PENDING,
            created_at=time.time(),
        )
        with self._lock:
            questions = _read_questions(job.directory)
            questions.append(pending)
            _write_questions(job.directory, questions)
            event = threading.Event()
            self._answer_events[qid] = event
        self._notify_status(job.id, JobStatus.WAITING_FOR_INPUT)
        return pending

    def wait_for_answer(
        self,
        job_id: str,
        qid: str,
        *,
        timeout: float = DEFAULT_QUESTION_TIMEOUT_SEC,
    ) -> str:
        with self._lock:
            event = self._answer_events.get(qid)
        if event is None:
            raise QuestionNotFound(qid)
        if not event.wait(timeout=timeout):
            raise TimeoutError(f"question {qid} timed out")
        with self._lock:
            answer = self._answers.get(qid)
        if answer is None:
            raise QuestionNotFound(qid)
        return answer

    def answer(self, job: Job, qid: str, answer: str) -> PendingQuestion:
        trimmed = answer.strip()
        if not trimmed:
            raise ValueError("answer is empty")
        # qid の存在は回答済み・取消済みも含めた全件で見る。
        # 存在するが PENDING でない場合はロック内のチェックが 409 にする。
        if not any(q.id == qid for q in _read_questions(job.directory)):
            if job.status is not JobStatus.WAITING_FOR_INPUT:
                raise AnswerNotAllowed(f"job {job.id} is not waiting for input")
            raise QuestionNotFound(qid)
        with self._lock:
            questions = _read_questions(job.directory)
            found: PendingQuestion | None = None
            updated: list[PendingQuestion] = []
            for item in questions:
                if item.id != qid:
                    updated.append(item)
                    continue
                if item.status is not QuestionStatus.PENDING:
                    raise QuestionNotPending(f"question {qid} is {item.status.value}")
                found = PendingQuestion(
                    id=item.id,
                    question=item.question,
                    choices=item.choices,
                    multi_select=item.multi_select,
                    status=QuestionStatus.ANSWERED,
                    answer=trimmed,
                    created_at=item.created_at,
                    answered_at=time.time(),
                )
                updated.append(found)
            if found is None:
                raise QuestionNotFound(qid)
            _write_questions(job.directory, updated)
            self._answers[qid] = trimmed
            event = self._answer_events.get(qid)
            if event is not None:
                event.set()
        # 他に pending 質問が残る間は worker はまだ待ち中。running 表示に戻さない。
        if any(item.status is QuestionStatus.PENDING for item in updated):
            return found
        self._notify_status(job.id, JobStatus.RUNNING)
        return found

    def resume_running(self, job_id: str) -> None:
        self._notify_status(job_id, JobStatus.RUNNING)

    def cancel_questions(self, job_dir: Path) -> None:
        with self._lock:
            questions = _read_questions(job_dir)
            changed = False
            updated: list[PendingQuestion] = []
            for item in questions:
                if item.status is QuestionStatus.PENDING:
                    updated.append(
                        PendingQuestion(
                            id=item.id,
                            question=item.question,
                            choices=item.choices,
                            multi_select=item.multi_select,
                            status=QuestionStatus.CANCELLED,
                            answer=item.answer,
                            created_at=item.created_at,
                            answered_at=time.time(),
                        )
                    )
                    event = self._answer_events.get(item.id)
                    if event is not None:
                        event.set()
                    changed = True
                else:
                    updated.append(item)
            if changed:
                _write_questions(job_dir, updated)

    def cleanup_question(self, qid: str) -> None:
        with self._lock:
            self._answer_events.pop(qid, None)
            self._answers.pop(qid, None)
