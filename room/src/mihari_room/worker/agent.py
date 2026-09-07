"""本家 ``AIAgent`` をジョブフォルダで回す。Gateway は起動しない。

起動の骨格は Hermes Agent（MIT, Copyright (c) 2025 Nous Research）の
``hermes_cli/oneshot.py`` と ``gateway/run_turn_runner.py`` と同じ。
oneshot と違う点:

- stdout を捨てない。``tool_progress_callback`` で進捗を取る
- セッションをジョブに紐づけて、続きは履歴ごと resume する
- ``declare_stateless_channel()`` は呼ばない

Safety (Phase 0/5):

- memory 書き込みは承認制。組み込み ``memory`` ツールを横取りして
  ``MemoryCandidateStore.propose`` に回し、ディスクへの直書きをしない。
  ``shutdown_memory_provider`` / 外部 provider の抽出書き込みも抑止する。
  プロンプトの注意書きは強制ではない。強制は hook / store 側である。
- ファイル書き込みは ``HERMES_WRITE_SAFE_ROOT=<job_dir>`` で job 内に縛る
  （本家 ``agent/file_safety.py`` が見る既存 hook）。
  ただし bash/terminal は無制限なので素通りできる。既定では terminal 系
  toolset を渡さない（``MIHARI_ROOM_ALLOW_SHELL=1`` で明示 opt-in）。
  制限は ``SAFETY_LIMITATIONS`` に明示する。
- Discord 送信 toolset は渡さない。出版は Room が持つ。
  session_search・search/browser 読取・file 生成は残す。
- 同プロセスで同時に回る agent は 1 つ（``agent_serial``）。
  timeout/中断時は ``interrupt`` して thread 終了を待ってから
  lease（cwd/HERMES_HOME）を離し、次の job を許す。
"""

from __future__ import annotations

import asyncio
import base64
import logging
import os
import queue
import re
import threading
from collections.abc import Awaitable, Callable, Mapping
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from mihari_room.contracts import (
    INPUT_DIRNAME,
    OUTPUT_DIRNAME,
    SCREENSHOTS_DIRNAME,
    Job,
    JobStatus,
    ProgressEvent,
    ProgressKind,
)
from mihari_room.persona import (
    confirm_alone_line,
    ensure_room_soul,
    memory_candidate_line,
    temp_deploy_posted_line,
)
from mihari_room.worker.progress import format_tool_progress

logger = logging.getLogger("mihari_room")

#: ジョブフォルダに残すセッション ID。秘密ではない。
SESSION_FILENAME = "hermes_session_id"

#: followup の消費カーソル。実行した prompt 分だけ進める。
FOLLOWUP_CURSOR_FILENAME = "followup_cursor"

#: 失敗理由を残すファイル。FAILED の一言に理由と次の操作を載せるために
#: orchestrator が読む。成功時は消す（古い理由を拾わないため）。
FAILURE_REASON_FILENAME = "failure_reason.txt"

#: interrupt 後に thread 終了を待つ猶予。超えても次の job は許さない
#: （gate を離さず待ち続ける。fail-closed）。
INTERRUPT_GRACE_SEC = 30.0

#: 安全上の制限。bash 無制限では防げないことを明示する。
SAFETY_LIMITATIONS = (
    "bash/terminal is unrestricted: HERMES_WRITE_SAFE_ROOT bounds Hermes file tools "
    "(write_file/patch) to the job dir, but shell commands can write anywhere. "
    "Terminal-class toolsets are therefore OFF by default "
    "(MIHARI_ROOM_ALLOW_SHELL=1 to opt in). "
    "The Hermes prompt directs safe placement but is NOT enforcement; "
    "enforcement lives in the memory hook + file-safety env + toolset filter."
)

#: 進捗に載せない鍵名（小文字で部分一致）。
_SENSITIVE_KEYS = ("api_key", "apikey", "token", "secret", "password", "authorization")

#: 進捗から削る秘密パターン。
_SECRET_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9_-]{8,}"),
    re.compile(r"xox[bap]-[A-Za-z0-9-]+"),
    re.compile(r"discord[_-]?token\s*[:=]\s*\S+", re.IGNORECASE),
    re.compile(r"api[_-]?key\s*[:=]\s*\S+", re.IGNORECASE),
)

#: 進捗に載せない URL 主張（リンクの既成事実化を避ける）。
_URL_PATTERN = re.compile(r"https?://\S+")


def _is_truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def sanitize_preview(text: str | None) -> str | None:
    """進捗プレビューから秘密・URL を削る。"""
    if not text:
        return text
    redacted = text
    for pattern in _SECRET_PATTERNS:
        redacted = pattern.sub("[redacted]", redacted)
    redacted = _URL_PATTERN.sub("[url]", redacted)
    return redacted


def sanitize_args(args: dict[str, Any] | None) -> dict[str, Any] | None:
    """秘密鍵を含む args は落とす。値は出さない。"""
    if not args:
        return None
    lowered = {str(key).lower(): key for key in args}
    for sensitive in _SENSITIVE_KEYS:
        if any(sensitive in name for name in lowered):
            return None
    return None  # 値は出さない。preview だけ使う。


def make_log_event(
    text: str,
    *,
    tool_name: str | None = None,
    phase: str | None = None,
) -> ProgressEvent:
    """contracts 拡張後も壊れない ProgressEvent 構築。

    contracts が ``tool_name`` / ``phase`` を持つ拡張版なら載せ、
    持たない現行版なら落として返す。standalone テストでは拡張版の
    dataclass（getattr で読める）で検証できる。
    """
    try:
        kwargs: dict[str, Any] = {"tool_name": tool_name, "phase": phase}
        return ProgressEvent(kind=ProgressKind.LOG, text=text, **kwargs)  # type: ignore[call-arg]
    except TypeError:
        return ProgressEvent(kind=ProgressKind.LOG, text=text)


#: ``os.chdir`` はプロセス全体。タイムアウト後の残りスレッドと次ジョブがぶつからないようにする。
_CWD_LOCK = threading.Lock()


def session_path(job: Job) -> Path:
    return job.directory / SESSION_FILENAME


def read_session_id(job: Job) -> str | None:
    path = session_path(job)
    if not path.is_file():
        return None
    value = path.read_text(encoding="utf-8").strip()
    return value or None


def write_session_id(job: Job, session_id: str) -> None:
    session_path(job).write_text(session_id.strip() + "\n", encoding="utf-8")


def _persist_session_best_effort(job: Job, session_id: Any) -> None:
    try:
        value = str(session_id or "").strip()
    except Exception:
        return
    if not value:
        return
    try:
        write_session_id(job, value)
    except Exception:
        logger.debug("session id persist failed", exc_info=True)


def clear_failure_reason(job: Job) -> None:
    """前回の失敗理由を消す。仕事の開始時に呼ぶ。"""
    try:
        (job.directory / FAILURE_REASON_FILENAME).unlink(missing_ok=True)
    except OSError:
        logger.debug("failure reason clear failed", exc_info=True)


def record_failure_reason(job: Job, reason: str | None) -> None:
    """失敗理由を 1 行で残す（best effort）。空なら何もしない。"""
    text = (reason or "").strip()
    if not text:
        return
    try:
        (job.directory / FAILURE_REASON_FILENAME).write_text(text, encoding="utf-8")
    except OSError:
        logger.debug("failure reason write failed", exc_info=True)


# -- followup cursor ----------------------------------------------------


def _followup_files(job: Job) -> list[Path]:
    folder = job.directory / INPUT_DIRNAME
    try:
        return sorted(folder.glob("followup-*.txt"))
    except OSError:
        return []


def _read_cursor(job: Job) -> str | None:
    path = job.directory / FOLLOWUP_CURSOR_FILENAME
    if not path.is_file():
        return None
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return value or None


def pending_followups(job: Job) -> list[Path]:
    """未実行の followup 一覧。カーソルより後のものだけ。"""
    cursor = _read_cursor(job)
    files = _followup_files(job)
    if cursor is None:
        return files
    return [path for path in files if path.name > cursor]


def advance_followup_cursor(job: Job, executed: list[Path] | None = None) -> None:
    """実行した prompt 分だけカーソルを進める。失敗時は呼ばない。"""
    files = executed if executed is not None else _followup_files(job)
    if not files:
        return
    latest = max(path.name for path in files)
    try:
        (job.directory / FOLLOWUP_CURSOR_FILENAME).write_text(latest + "\n", encoding="utf-8")
    except OSError:
        logger.debug("followup cursor write failed", exc_info=True)


# -- Mac スクショ（#22） ------------------------------------------------------

#: 1 ターンに Hermes へ渡すスクショの上限。文脈を過剰に広げない。
MAX_SCREENSHOTS_PER_TURN = 6

#: スクショ配信のカーソル。何枚目まで Hermes へ渡し済みかを覚える。
SCREENSHOT_CURSOR_FILENAME = "screenshot_cursor"

#: 画像拡張子→data URI の media type。
_SCREENSHOT_MEDIA_TYPES = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".gif": "image/gif",
}


def _screenshot_folder(job: Job) -> Path:
    return job.directory / INPUT_DIRNAME / SCREENSHOTS_DIRNAME


def list_screenshot_files(job: Job) -> list[Path]:
    """input/screenshots/ の画像一覧をファイル名順で返す（0001.png, 0002.png…）。"""
    folder = _screenshot_folder(job)
    if not folder.is_dir():
        return []
    return sorted(
        (
            path
            for path in folder.iterdir()
            if path.is_file() and path.suffix.lower() in _SCREENSHOT_MEDIA_TYPES
        ),
        key=lambda path: path.name,
    )


def _read_screenshot_delivered(job: Job) -> int:
    path = job.directory / SCREENSHOT_CURSOR_FILENAME
    if not path.is_file():
        return 0
    try:
        value = path.read_text(encoding="utf-8").strip()
        return max(0, int(value))
    except (OSError, ValueError):
        return 0


def _write_screenshot_delivered(job: Job, count: int) -> None:
    try:
        (job.directory / SCREENSHOT_CURSOR_FILENAME).write_text(
            f"{max(0, count)}\n", encoding="utf-8"
        )
    except OSError:
        logger.debug("screenshot cursor write failed", exc_info=True)


def undelivered_screenshots(job: Job) -> list[Path]:
    """まだ Hermes へ渡していないスクショ一覧。配信済みカーソルより後ろだけ。"""
    files = list_screenshot_files(job)
    delivered = _read_screenshot_delivered(job)
    return files[delivered:]


def advance_screenshot_cursor(job: Job, delivered: list[Path] | None = None) -> None:
    """実行で実際に渡したスクショ分だけ配信カーソルを進める。失敗時は呼ばない。

    `delivered` 未指定なら全ファイル（上限なしで全部渡したときと同じ）。
    """
    if delivered is None:
        files = list_screenshot_files(job)
        count = len(files)
    else:
        count = _read_screenshot_delivered(job) + len(delivered)
    if count > 0:
        _write_screenshot_delivered(job, count)


def _media_type_for(path: Path) -> str:
    return _SCREENSHOT_MEDIA_TYPES.get(path.suffix.lower(), "image/png")


def data_uri_for(path: Path) -> str:
    """スクショを data URI にする。本文へパスを書くだけで済ませないための実体。"""
    try:
        raw = path.read_bytes()
    except OSError:
        raise
    encoded = base64.b64encode(raw).decode("ascii")
    return f"data:{_media_type_for(path)};base64,{encoded}"


def build_multimodal_message(text: str, screenshots: list[Path]) -> list[dict[str, Any]]:
    """テキスト＋画像のマルチモーダル user message を作る。

    OpenAI 互換の content リスト（Hermes が各 provider へ変換する）。
    ``[{"type": "text", ...}, {"type": "image_url", "image_url": {"url": data-uri}}, ...]``。
    画像は必ずバイト列（data URI）で載せる。
    """
    hint_lines = [f"[Image attached at: {path.name}]".replace("\\", "/") for path in screenshots]
    combined = (text or "").rstrip()
    if combined and hint_lines:
        combined += "\n\n" + "\n".join(hint_lines)
    elif hint_lines:
        combined = "What do you see in this screenshot?\n" + "\n".join(hint_lines)
    parts: list[dict[str, Any]] = [{"type": "text", "text": combined}]
    for path in screenshots:
        parts.append({"type": "image_url", "image_url": {"url": data_uri_for(path)}})
    return parts


class _ImageInputUnsupported(Exception):
    """現在のモデルが画像をネイティブに読めないときに投げる。"""


def resolve_image_native_mode() -> tuple[bool, str]:
    """Hermes の設定から、現在のモデルが画像をネイティブに読めるかを決める。

    Room は in-process で ``run_conversation`` を回すため、gateway が行う
    補助 vision による画像→テキスト化は使えない。画像はネイティブに読める
    モデルへだけバイト列で渡し、それ以外は明示的に失敗する（#22 受け入れ）。
    判定できないときも失敗扱い（推測で画像を黙って捨てない）。

    Returns (True, "") なら渡してよい。(False, reason) なら理由を返す。
    """
    try:
        from agent.image_routing import decide_image_input_mode  # type: ignore[import-not-found]
        from hermes_cli.config import load_config  # type: ignore[import-not-found]
    except Exception as exc:
        return False, f"Hermes の画像能力を判定できないため添付をやめた: {exc}"
    try:
        model, resolved = _resolve_runtime()
        runtime = resolved.get("runtime") or {}
        provider = str(runtime.get("provider") or "").strip().lower()
        requested = str(runtime.get("requested_provider") or "").strip()
        cfg = load_config() or {}
    except Exception as exc:
        return False, f"モデル設定を読めないため添付をやめた: {exc}"
    if not provider or not model:
        return False, "モデルが未設定のため画像を添付できない"
    try:
        mode = decide_image_input_mode(provider, model, cfg, requested_provider=requested)
    except Exception as exc:
        return False, f"画像入力モードを判定できないため添付をやめた: {exc}"
    if mode == "native":
        return True, ""
    return False, (
        "今のモデルは画像を読めない設定です（Hermes の判定: "
        f"{mode}）。画像対応モデルを設定するか、Hermes プロファイルの config.yaml で "
        "`model.supports_vision: true` を明示してください。"
    )


#: 画像を送る前に確かめる判定関数。テストでは monkeypatch して差し替える。
image_native_check = resolve_image_native_mode


def build_turn_prompt(job: Job) -> str:
    """初回は題と本文＋待機中 followup があれば末尾に追記。

    続きは未実行の followup 全部を同じセッションの次ターンとして渡す。
    """
    from mihari_room.worker.hermes import build_prompt

    pending = pending_followups(job)
    if read_session_id(job) and pending:
        notes = "\n---\n".join(path.read_text(encoding="utf-8") for path in pending)
        return (
            f"続きの依頼:\n{notes}\n\n"
            "作業内容は上の続きです。"
            f"`{INPUT_DIRNAME}/followup-*.txt` にも同じ追記があります。"
            f"`{INPUT_DIRNAME}/` に他の添付が無くても正常です。無いファイルを探さないでください。"
            f"結果は `{OUTPUT_DIRNAME}/` に書き出してください。"
            "プレビュー CSP は `script-src 'self'`。"
            "JS は同一フォルダの `.js` に分け、インライン script と CDN は使わないでください。"
            "必要な説明は標準出力の最後に 1〜数行で書いてください。"
        )
    base = build_prompt(job)
    if pending:
        notes = "\n---\n".join(path.read_text(encoding="utf-8") for path in pending)
        return f"{base}\n\n追記:\n{notes}"
    return base


@contextmanager
def _job_cwd(directory: Path):
    """ツールと AGENTS.md がジョブフォルダを見るようにする。必ず戻す。"""
    previous = Path.cwd()
    previous_terminal = os.environ.get("TERMINAL_CWD")
    token = None
    os.chdir(directory)
    os.environ["TERMINAL_CWD"] = str(directory)
    try:
        from agent.runtime_cwd import set_session_cwd

        token = set_session_cwd(str(directory))
    except Exception:
        token = None
    try:
        yield
    finally:
        try:
            os.chdir(previous)
        except Exception:
            pass
        if previous_terminal is None:
            os.environ.pop("TERMINAL_CWD", None)
        else:
            os.environ["TERMINAL_CWD"] = previous_terminal
        if token is not None:
            try:
                from agent.runtime_cwd import _SESSION_CWD

                _SESSION_CWD.reset(token)
            except Exception:
                pass


@contextmanager
def _unattended_env():
    """人が端末にいないので承認は自動。プロセス全体の YOLO を汚したら戻す。"""
    keys = ("HERMES_YOLO_MODE", "HERMES_ACCEPT_HOOKS")
    previous = {key: os.environ.get(key) for key in keys}
    os.environ["HERMES_YOLO_MODE"] = "1"
    os.environ["HERMES_ACCEPT_HOOKS"] = "1"
    try:
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


@contextmanager
def _bounded_env(job_dir: Path):
    """Hermes file tools を job 内に縛る。bash は縛れない（制限として明示）。"""
    key = "HERMES_WRITE_SAFE_ROOT"
    previous = os.environ.get(key)
    os.environ[key] = str(job_dir)
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = previous


def _create_session_db() -> Any:
    try:
        from hermes_state import SessionDB

        return SessionDB()
    except Exception:
        logger.debug("SessionDB を開けない。履歴なしで進む", exc_info=True)
        return None


def _load_history(session_db: Any, session_id: str | None) -> list[dict[str, Any]] | None:
    if session_db is None or not session_id:
        return None
    try:
        reopen = getattr(session_db, "reopen_session", None)
        if callable(reopen):
            reopen(session_id)
        restored = session_db.get_messages_as_conversation(session_id, repair_alternation=True)
    except Exception:
        logger.debug("セッション履歴を読めない: %s", session_id, exc_info=True)
        return None
    if not restored:
        return None
    return [message for message in restored if message.get("role") != "session_meta"]


def _close_agent(agent: Any, session_db: Any) -> None:
    # Memory guard が入っていれば shutdown は no-op 化済み。
    # ここでは二重に抽出書き込みを起こさないよう、空メッセージで閉じる。
    if agent is not None:
        try:
            agent._end_session_on_close = False
        except Exception:
            pass
        try:
            shutdown = getattr(agent, "shutdown_memory_provider", None)
            if callable(shutdown):
                try:
                    shutdown([])
                except TypeError:
                    shutdown()
        except Exception:
            logger.debug("memory cleanup failed", exc_info=True)
        try:
            agent.close()
        except Exception:
            logger.debug("agent close failed", exc_info=True)
    if session_db is not None:
        try:
            session_db.close()
        except Exception:
            logger.debug("session db close failed", exc_info=True)


# -- memory + filesystem guards ------------------------------------------


def _room_root_for(job: Job) -> Path:
    # jobs/<id> の 2 つ上が room root。
    return job.directory.parent.parent


def _memory_store_for(job: Job):
    from mihari_room.worker.memory import MemoryCandidateStore
    from mihari_room.worker.runtime_lock import resolve_hermes_home

    room_root = _room_root_for(job)
    hermes_home = resolve_hermes_home(room_root)
    return MemoryCandidateStore(room_root, hermes_home)


def prune_agent_tools(agent: Any) -> int:
    """Dangerous toolsを agent 表面から落とす。discord_search skill は残す。

    Toolset レベルでは ``filter_toolsets`` が弾くが、toolset 経由で
    すり抜けた危険ツール名もここで名指しで落とす（defense in depth）:

    - ``delegate_task``: nested agents（再帰委任の無制限増殖を塞ぐ）
    - ``skill_manage``: skills の自己改変（list/view は残す）
    - ``cronjob_manage`` / kanban_*: 背後の永続実行系
    - ``computer_use`` / ``execute_code`` / ``terminal`` / ``process_manage``:
      無制限実行系（shell opt-in 時のみ残すのは呼び出し側の責任）
    - ``discord`` / ``discord_admin`` / ``mcp-*``: 外部送信・動的 MCP
    """
    removed = 0
    blocked_names = {
        "discord",
        "discord_admin",
        "delegate_task",
        "subagent",
        "skill_manage",
        "cronjob_manage",
        "computer_use",
        "execute_code",
        "terminal",
        "process_manage",
    }
    for attr in ("tools",):
        tools = getattr(agent, attr, None)
        if isinstance(tools, list):
            kept: list[Any] = []
            for tool in tools:
                name = ""
                if isinstance(tool, dict):
                    try:
                        name = str(tool.get("function", {}).get("name") or "")
                    except Exception:
                        name = ""
                else:
                    name = str(getattr(tool, "__name__", "") or "")
                if name in blocked_names or name.startswith("mcp-") or name.startswith("mcp_"):
                    removed += 1
                    continue
                kept.append(tool)
            if removed:
                try:
                    agent.tools = kept
                except Exception:
                    pass
    valid = getattr(agent, "valid_tool_names", None)
    if isinstance(valid, set):
        for name in blocked_names:
            if name in valid:
                valid.discard(name)
                removed += 1
        for name in [n for n in valid if n.startswith("mcp-") or n.startswith("mcp_")]:
            valid.discard(name)
            removed += 1
    return removed


def _emit_candidate_event(job: Job, candidate: Any) -> None:
    """memory 候補が出たら日誌に残す（desktop の refresh 用、queue は塞がない）。"""
    try:
        from mihari_room.events import EventJournal, EventPhase, JournalKind

        journal = EventJournal.for_job(job.directory)
        journal.append(
            job_id=job.id,
            phase=EventPhase.WAITING,
            kind=JournalKind.MEMORY_CANDIDATE,
            text=memory_candidate_line(candidate.target),
        )
    except Exception:
        logger.debug("memory candidate journal append failed", exc_info=True)


def _emit_candidate_event_for_id(job_id: str, candidate_store: Any, candidate: Any) -> None:
    """job オブジェクトが無い経路（store wrapper）用の候補通知。"""
    try:
        from mihari_room.events import EventJournal, EventPhase, JournalKind

        root = Path(candidate_store.root) if hasattr(candidate_store, "root") else None
        if root is None:
            return
        from mihari_room.contracts import JOBS_DIRNAME

        journal = EventJournal.for_job(root / JOBS_DIRNAME / job_id)
        journal.append(
            job_id=job_id,
            phase=EventPhase.WAITING,
            kind=JournalKind.MEMORY_CANDIDATE,
            text=memory_candidate_line(candidate.target),
        )
    except Exception:
        logger.debug("memory candidate journal append failed", exc_info=True)


def install_memory_guard(agent: Any, job: Job) -> Callable[[], None]:
    """組み込み memory 書き込みを候補提案に横取りする。

    本家 ``tools.memory_tool.memory_tool``（``agent_runtime_helpers`` が
    毎回 import して呼ぶ実体）と ``agent._memory_store`` / ``_memory_manager``
    を抑止し、承認なしの永続化を止める。読みは承認済み memory を返す。
    戻り値は元に戻す restore 関数。
    """
    store = _memory_store_for(job)
    originals: dict[str, Any] = {}
    candidate_store = store  # closure: 承認候補の正本。引数の shadow に惑わされない。

    # -- agent._memory_store を guard に差し替え --
    try:
        originals["memory_store"] = getattr(agent, "_memory_store", None)
        guard = _ApprovalMemoryStore(store, job.id)
        # 元 store の snapshot があれば引き継ぐ（表示用）。
        original_store = originals["memory_store"]
        if original_store is not None:
            for attr in ("memory_entries", "user_entries"):
                try:
                    setattr(guard, attr, list(getattr(original_store, attr, None) or []))
                except Exception:
                    pass
        agent._memory_store = guard
    except Exception:
        logger.debug("memory store guard install failed", exc_info=True)

    # -- 外部 provider の永続化を抑止 --
    try:
        originals["memory_manager"] = getattr(agent, "_memory_manager", None)
        agent._memory_manager = _NullMemoryManager()
    except Exception:
        logger.debug("memory manager guard install failed", exc_info=True)

    # -- cleanup 時の抽出書き込みを抑止 --
    try:
        original_shutdown = getattr(agent, "shutdown_memory_provider", None)
        originals["shutdown"] = original_shutdown

        def _guarded_shutdown(messages: Any = None) -> None:
            try:
                agent._memory_provider_shutdown = True
            except Exception:
                pass
            # わざと manager を呼ばない。抽出書き込みをしない。

        try:
            agent.shutdown_memory_provider = _guarded_shutdown  # type: ignore[method-assign]
        except Exception:
            pass
    except Exception:
        logger.debug("shutdown guard install failed", exc_info=True)

    # -- 本家 memory_tool 関数を横取り --
    try:
        import tools.memory_tool as memory_tool_module  # type: ignore[import-not-found]

        originals["memory_tool_fn"] = memory_tool_module.memory_tool

        def _guarded_memory_tool(
            action: str | None = None,
            target: str = "memory",
            content: str | None = None,
            old_text: str | None = None,
            new_text: str | None = None,
            operations: Any | None = None,
            store: Any | None = None,  # noqa: A002 -- 本家シグネチャ互換。無視する。
        ) -> str:
            import json as _json

            from tools.registry import tool_error as _tool_error

            _ = store  # agent 側の store は使わない。正本は closure の candidate_store。
            norm_target = (target or "memory").strip().lower()
            if norm_target not in ("memory", "user"):
                norm_target = "memory"
            filename = "USER.md" if norm_target == "user" else "MEMORY.md"
            # Batch は add のみ候補化する。replace/remove は MVP では未対応と明示する
            # （差分指示文を memory として追記すると誤った記憶になるため）。
            if operations:
                if not isinstance(operations, list):
                    return _tool_error(
                        "operations must be a list of {action, content?, old_text?} objects.",
                        success=False,
                    )
                for op in operations:
                    if isinstance(op, dict) and (op.get("action") or "add") != "add":
                        return _tool_error(
                            f"Room MVP: batch op '{op.get('action')}' is not supported. "
                            "Only action='add' is staged as a candidate. "
                            "For corrections, propose the full corrected entry with add.",
                            success=False,
                        )
                staged = 0
                for op in operations:
                    if not isinstance(op, dict):
                        continue
                    text = op.get("content", op.get("new_text", ""))
                    try:
                        candidate = candidate_store.propose(
                            job.id, norm_target, (text or "").strip()
                        )
                        _emit_candidate_event(job, candidate)
                        staged += 1
                    except ValueError as exc:
                        return _tool_error(str(exc), success=False)
                return _json.dumps(
                    {
                        "success": True,
                        "staged": True,
                        "proposed": staged,
                        "message": (
                            f"{staged} 件を memory 候補として預かりました "
                            f"({filename})。承認後に保存されます。直書きはしません。"
                        ),
                    },
                    ensure_ascii=False,
                )
            if action not in {"add", "replace", "remove"}:
                # 読み・一覧系は承認済み memory を返す。
                try:
                    entries = candidate_store.approved_entries(norm_target)
                except Exception:
                    entries = []
                return _json.dumps(
                    {
                        "success": True,
                        "target": filename,
                        "entries": entries,
                        "staged_only": True,
                        "message": "承認済み memory の読み取りです。新規書き込みは候補として預かります。",  # noqa: E501,
                    },
                    ensure_ascii=False,
                )
            text = content if content is not None else new_text
            # MVP では add のみ対応。replace/remove は差分適用器を持たないので
            # 明示的に断る（"[replace ...] >> ..." のような指示文を memory として
            # 追記すると誤った記憶になる。それだけはしない）。
            if action in {"replace", "remove"}:
                return _tool_error(
                    f"Room MVP: action='{action}' is not supported. "
                    "Only action='add' is staged as a candidate for owner approval. "
                    "For corrections, propose the full corrected entry with "
                    "action='add', content='<corrected entry>'.",
                    success=False,
                )
            if not (text or "").strip():
                return _tool_error("Content is required for 'add' action.", success=False)
            try:
                candidate = candidate_store.propose(job.id, norm_target, (text or "").strip())
                _emit_candidate_event(job, candidate)
            except ValueError as exc:
                return _tool_error(str(exc), success=False)
            return _json.dumps(
                {
                    "success": True,
                    "staged": True,
                    "candidate_id": candidate.id,
                    "target": filename,
                    "message": (
                        f"memory 候補として預かりました ({filename}, id={candidate.id})。"
                        "承認後に保存されます。直書きはしません。"
                    ),
                },
                ensure_ascii=False,
            )

        memory_tool_module.memory_tool = _guarded_memory_tool  # type: ignore[method-assign]
    except ImportError:
        pass
    except Exception:
        logger.debug("memory tool guard install failed", exc_info=True)

    def restore() -> None:
        try:
            import tools.memory_tool as memory_tool_module  # type: ignore[import-not-found]

            if "memory_tool_fn" in originals:
                memory_tool_module.memory_tool = originals["memory_tool_fn"]
        except Exception:
            pass
        for key, attr in (("memory_store", "_memory_store"), ("memory_manager", "_memory_manager")):
            if key in originals:
                try:
                    setattr(agent, attr, originals[key])
                except Exception:
                    pass
        if "shutdown" in originals and originals["shutdown"] is not None:
            try:
                agent.shutdown_memory_provider = originals["shutdown"]  # type: ignore[method-assign]  # noqa: E501
            except Exception:
                pass

    return restore


class _ApprovalMemoryStore:
    """本家 MemoryStore の口だけ持つ承認制 wrapper。直書きしない。"""

    def __init__(self, candidates, job_id: str = "") -> None:
        self._candidates = candidates
        self._job_id = job_id
        self.memory_entries: list[str] = []
        self.user_entries: list[str] = []
        self.memory_enabled = True
        self.user_profile_enabled = True
        self._system_prompt_snapshot = {"memory": "", "user": ""}

    def target_enabled(self, target: str) -> bool:
        return self.user_profile_enabled if target == "user" else self.memory_enabled

    def load_from_disk(self) -> None:
        try:
            self.memory_entries = self._candidates.approved_entries("memory")
            self.user_entries = self._candidates.approved_entries("user")
        except Exception:
            self.memory_entries = []
            self.user_entries = []
        self._system_prompt_snapshot = {"memory": "", "user": ""}

    def save_to_disk(self, target: str) -> None:
        # 直書きしない。承認フローだけが書く。
        return None

    def _entries_for(self, target: str) -> list[str]:
        return self.user_entries if target == "user" else self.memory_entries

    def format_for_system_prompt(self, target: str) -> str | None:
        entries = self._entries_for(target)
        if not entries:
            return None
        return "\n".join(f"- {entry}" for entry in entries)

    def _stage(self, target: str, content: str) -> dict[str, Any]:
        norm = "user" if target == "user" else "memory"
        candidate = self._candidates.propose(self._job_id, norm, content)
        _emit_candidate_event_for_id(self._job_id, self._candidates, candidate)
        return {"success": True, "staged": True, "candidate_id": candidate.id}

    def add(self, target: str, content: str) -> dict[str, Any]:
        try:
            norm = "user" if target == "user" else "memory"
            candidate = self._candidates.propose(self._job_id, norm, content)
            _emit_candidate_event_for_id(self._job_id, self._candidates, candidate)
            return {"success": True, "staged": True, "candidate_id": candidate.id}
        except ValueError as exc:
            return {"success": False, "error": str(exc)}

    def replace(self, target: str, old_text: str, new_content: str) -> dict[str, Any]:
        # MVP では未対応と明示する。指示文の追記は誤記憶になるのでしない。
        return {
            "success": False,
            "error": (
                "Room MVP: replace is not supported. Propose the full corrected "
                "entry with add instead. Nothing was staged."
            ),
        }

    def remove(self, target: str, old_text: str) -> dict[str, Any]:
        # MVP では未対応と明示する。削除依頼の文面化もしない。
        return {
            "success": False,
            "error": (
                "Room MVP: remove is not supported. "
                "Ask the owner to edit MEMORY.md/USER.md directly. Nothing was staged."
            ),
        }

    def apply_batch(self, target: str, operations: list[dict[str, Any]]) -> dict[str, Any]:
        for op in operations or []:
            if isinstance(op, dict) and (op.get("action") or "add") != "add":
                return {
                    "success": False,
                    "error": (
                        f"Room MVP: batch op '{op.get('action')}' is not supported. "
                        "Only action='add' is staged. Nothing was staged."
                    ),
                }
        staged = 0
        for op in operations or []:
            if not isinstance(op, dict):
                continue
            text = str(op.get("content", op.get("new_text", "")) or "")
            if not text.strip():
                continue
            result = self.add(target, text)
            if result.get("success"):
                staged += 1
            else:
                return result
        return {"success": True, "staged": True, "proposed": staged}


class _NullMemoryManager:
    """外部 provider 書き込みの抑止。読みの session_search とは無関係。"""

    def has_tool(self, _name: str) -> bool:
        return False

    def handle_tool_call(self, tool_name: str, _args: Any = None) -> Any:
        return {"success": False, "error": f"No memory provider handles tool '{tool_name}'"}

    def notify_memory_tool_write(self, *args: Any, **kwargs: Any) -> None:
        return None

    def on_session_end(self, messages: Any = None) -> None:
        return None

    def shutdown_all(self) -> None:
        return None


def _resolve_runtime() -> tuple[str, dict[str, Any]]:
    """oneshot と同じ model / provider / toolsets（Discord・危険系を濾過）。"""
    from mihari_room.worker.bootstrap import bootstrap_hermes

    bootstrap_hermes()
    from hermes_cli.config import load_config
    from hermes_cli.fallback_config import get_fallback_chain
    from hermes_cli.runtime_provider import resolve_runtime_provider
    from hermes_cli.tools_config import _get_platform_tools

    cfg = load_config()
    model_cfg = cfg.get("model") or {}
    if isinstance(model_cfg, str):
        cfg_model = model_cfg
    elif isinstance(model_cfg, dict):
        raw = model_cfg.get("default") or model_cfg.get("model") or ""
        if isinstance(raw, dict):
            from hermes_cli.config import split_model_config_default

            cfg_model, _ = split_model_config_default(raw)
        else:
            cfg_model = str(raw or "")
    else:
        cfg_model = ""
    env_model = os.getenv("HERMES_INFERENCE_MODEL", "").strip()
    effective_model = env_model or str(cfg_model or "")
    runtime = resolve_runtime_provider(
        requested=None,
        target_model=effective_model or None,
    )
    toolsets = sorted(_get_platform_tools(cfg, "cli"))
    try:
        from mihari_room.worker.hermes import ensure_baseline_toolsets, filter_toolsets

        toolsets = ensure_baseline_toolsets(filter_toolsets(toolsets))
    except Exception:
        logger.debug("toolset filter failed; using raw toolsets", exc_info=True)
    fallback = get_fallback_chain(cfg) or None
    return effective_model, {
        "runtime": runtime,
        "toolsets": toolsets,
        "fallback": fallback,
    }


def default_agent_factory(**kwargs: Any) -> Any:
    from mihari_room.worker.bootstrap import bootstrap_hermes, import_ai_agent

    bootstrap_hermes()
    from hermes_cli.mcp_startup import ensure_mcp_discovery_before_agent_build

    ensure_mcp_discovery_before_agent_build(logger=logger, single_query=True)
    # toolsets の最終濾過（factory 直注入テストでは素通り）。
    try:
        from mihari_room.worker.hermes import ensure_baseline_toolsets, filter_toolsets

        enabled = kwargs.get("enabled_toolsets")
        if isinstance(enabled, list):
            kwargs["enabled_toolsets"] = ensure_baseline_toolsets(filter_toolsets(enabled))
    except Exception:
        pass
    agent_cls = import_ai_agent()
    return agent_cls(**kwargs)


#: 注入用。本家 ``AIAgent`` と同じキーワードを受けてインスタンスを返す。
AgentFactory = Callable[..., Any]


class InProcessHermes:
    """ジョブフォルダを cwd に本家 AIAgent を 1 ターン回す。"""

    def __init__(
        self,
        timeout: float,
        agent_factory: AgentFactory | None = None,
    ) -> None:
        self._timeout = timeout
        self._injected = agent_factory is not None
        self._agent_factory = agent_factory or default_agent_factory
        self._live: dict[str, Any] = {}
        self._live_lock = threading.Lock()

    def request_cancel(self, job_id: str) -> bool:
        """実行中の agent に interrupt を届ける。届けば True。"""
        agent = self._live.get(job_id)
        if agent is None:
            return False
        interrupt = getattr(agent, "interrupt", None)
        if not callable(interrupt):
            return False
        try:
            try:
                interrupt("cancelled by owner")
            except TypeError:
                interrupt()
        except Exception:
            logger.debug("request_cancel interrupt failed", exc_info=True)
            return False
        return True

    def is_running(self, job_id: str) -> bool:
        return job_id in self._live

    async def run(
        self,
        job: Job,
        prompt: str,
        on_progress: Callable[[ProgressEvent], Awaitable[None]],
    ) -> JobStatus:
        events: queue.Queue[ProgressEvent | None] = queue.Queue()
        holder: list[Any] = []

        def emit(event: ProgressEvent) -> None:
            events.put(event)

        def progress_callback(
            event_type: str,
            tool_name: str | None = None,
            preview: str | None = None,
            args: dict[str, Any] | None = None,
            **kwargs: Any,
        ) -> None:
            line = format_tool_progress(
                event_type, tool_name, sanitize_preview(preview), sanitize_args(args), **kwargs
            )
            if line:
                emit(
                    make_log_event(
                        line,
                        tool_name=tool_name,
                        phase=kwargs.get("phase") or kwargs.get("tool_phase"),
                    )
                )

        def clarify_callback(question: str, choices: Any = None, multi_select: bool = False) -> str:
            emit(
                ProgressEvent(
                    kind=ProgressKind.LOG,
                    text=confirm_alone_line(sanitize_preview(question)),
                )
            )
            if choices:
                what = "subset" if multi_select else "option"
                return (
                    f"[unattended room: pick the best {what} from "
                    f"{choices} using your own judgment and continue.]"
                )
            return "[unattended room: make the most reasonable assumption and continue.]"

        pending = pending_followups(job) if read_session_id(job) else []
        # 未配信のスクショ（1 ターンの上限まで）。配信成功でカーソルが進む。
        screenshots = undelivered_screenshots(job)[:MAX_SCREENSHOTS_PER_TURN]
        # 古い失敗理由は次の仕事に持ち越さない。
        clear_failure_reason(job)

        def run_sync() -> tuple[Mapping[str, Any], str | None]:
            from mihari_room.worker.runtime_lock import scoped_hermes_home

            room_root = _room_root_for(job)
            hermes_home = _memory_store_for(job).hermes_home
            with (
                _CWD_LOCK,
                _job_cwd(job.directory),
                _unattended_env(),
                _bounded_env(job.directory),
                scoped_hermes_home(hermes_home),
            ):
                # Room 専用の人格（SOUL.md）を自分の HERMES_HOME に用意する。
                # 個人用 ~/.hermes には触れない。既存の SOUL.md は上書きしない。
                try:
                    ensure_room_soul(hermes_home)
                except Exception:
                    logger.debug("room soul seed failed", exc_info=True)
                if not self._injected:
                    from mihari_room.worker.bootstrap import bootstrap_hermes

                    bootstrap_hermes()
                session_id = read_session_id(job)
                session_db = None if self._injected else _create_session_db()
                history = _load_history(session_db, session_id)
                if self._injected:
                    model, resolved = "", {"runtime": {}, "toolsets": None, "fallback": None}
                else:
                    model, resolved = _resolve_runtime()
                runtime = resolved["runtime"]
                agent = None
                restore_memory_guard: Callable[[], None] | None = None
                restore_discord_tools: Callable[[], None] | None = None
                restore_temp_deploy: Callable[[], None] | None = None
                try:
                    # Bounded discord_* を registry に先に載せる（agent build が読む）。
                    try:
                        from mihari_room.worker.discord_tools import register_discord_tools

                        restore_discord_tools = register_discord_tools(job)
                    except Exception:
                        logger.debug("discord tools register failed", exc_info=True)
                    try:
                        from mihari_room.worker.wrangler_temp import register_temp_deploy_tool

                        # Temporary Deploy は外部公開。依頼時の明示許可
                        # （allow_external_publish）がある仕事にだけ道具を渡す。
                        if getattr(job, "allow_external_publish", False):
                            restore_temp_deploy = register_temp_deploy_tool(job)
                    except Exception:
                        logger.debug("temp deploy tool register failed", exc_info=True)
                    try:
                        from mihari_room.worker.hermes import DISABLED_TOOLSETS

                        disabled = list(DISABLED_TOOLSETS)
                    except Exception:
                        disabled = ["discord", "discord_admin", "terminal"]
                    agent = self._agent_factory(
                        api_key=runtime.get("api_key"),
                        base_url=runtime.get("base_url"),
                        provider=runtime.get("provider"),
                        requested_provider=runtime.get("requested_provider"),
                        api_mode=runtime.get("api_mode"),
                        model=model,
                        enabled_toolsets=resolved["toolsets"],
                        disabled_toolsets=disabled,
                        quiet_mode=True,
                        platform="cli",
                        session_id=session_id,
                        session_db=session_db,
                        credential_pool=runtime.get("credential_pool"),
                        fallback_model=resolved["fallback"],
                        tool_progress_callback=progress_callback,
                        clarify_callback=clarify_callback,
                        load_soul_identity=True,
                    )
                    holder.append(agent)
                    self._live[job.id] = agent
                    # セッション ID は早めに残す（中断時も拾えるように）。
                    _persist_session_best_effort(job, getattr(agent, "session_id", None))
                    try:
                        prune_agent_tools(agent)
                    except Exception:
                        logger.debug("prune agent tools failed", exc_info=True)
                    try:
                        restore_memory_guard = install_memory_guard(agent, job)
                    except Exception:
                        logger.debug("memory guard install failed", exc_info=True)
                    # 承認済み memory をこのセッションの snapshot に載せる。
                    # （本家 MemoryStore.load_from_disk と同じ口。次回起動も同様。）
                    try:
                        guard_store = getattr(agent, "_memory_store", None)
                        loader = getattr(guard_store, "load_from_disk", None)
                        if callable(loader):
                            loader()
                    except Exception:
                        logger.debug("approved memory load failed", exc_info=True)
                    agent.suppress_status_output = True
                    agent._end_session_on_close = False
                    user_message: Any = prompt
                    if screenshots:
                        native, reason = image_native_check()
                        if not native:
                            emit(
                                ProgressEvent(
                                    kind=ProgressKind.LOG,
                                    text=f"スクショを添付できない: {reason}",
                                )
                            )
                            raise _ImageInputUnsupported(reason)
                        user_message = build_multimodal_message(prompt, screenshots)
                    result = agent.run_conversation(
                        user_message,
                        conversation_history=history,
                    )
                    # 中断後に拾えるよう、完了時の ID も残す。
                    _persist_session_best_effort(job, getattr(agent, "session_id", None))
                    return result or {}, getattr(agent, "session_id", None)
                finally:
                    if restore_memory_guard is not None:
                        try:
                            restore_memory_guard()
                        except Exception:
                            pass
                    if restore_discord_tools is not None:
                        try:
                            restore_discord_tools()
                        except Exception:
                            pass
                    if restore_temp_deploy is not None:
                        try:
                            restore_temp_deploy()
                        except Exception:
                            pass
                    self._live.pop(job.id, None)
                    # 中断時も ID があれば残す。
                    try:
                        if holder:
                            _persist_session_best_effort(
                                job, getattr(holder[0], "session_id", None)
                            )
                    except Exception:
                        pass
                    _close_agent(agent, session_db)
                    _ = room_root  # lease marker (cwd/HERMES_HOME は with を抜けて離す)

        # 同プロセスで 1 agent ずつ。event loop を塞がないよう
        # polling で取る。gate を離すのは worker thread 終了後。
        from mihari_room.worker.runtime_lock import _AGENT_SERIAL

        while not _AGENT_SERIAL.acquire(blocking=False):
            await asyncio.sleep(0.01)
        try:
            drain_task = asyncio.create_task(_drain_progress(events, on_progress))
            loop = asyncio.get_running_loop()
            executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mihari-agent")
            try:
                future = loop.run_in_executor(executor, run_sync)
                try:
                    result, session_id = await asyncio.wait_for(
                        asyncio.shield(future), timeout=self._timeout
                    )
                except TimeoutError:
                    _interrupt(holder)
                    # 中断時点の ID も残す。
                    try:
                        if holder:
                            _persist_session_best_effort(
                                job, getattr(holder[0], "session_id", None)
                            )
                    except Exception:
                        pass
                    try:
                        result, session_id = await asyncio.wait_for(
                            future, timeout=INTERRUPT_GRACE_SEC
                        )
                    except TimeoutError:
                        logger.error(
                            "agent thread did not exit in %ss; holding the gate (fail-closed)",
                            INTERRUPT_GRACE_SEC,
                        )
                        # lease と gate は離さない。thread 終了を待つ。
                        result, session_id = await future
                    except Exception:
                        logger.exception("Hermes AIAgent が転んだ（中断後）")
                        try:
                            await future
                        except Exception:
                            pass
                        return JobStatus.FAILED
                    # 中断後に返ってきても失敗扱い。ID は残す。
                    try:
                        if session_id:
                            _persist_session_best_effort(job, session_id)
                    except Exception:
                        pass
                    # 時間切れだったことを理由に残す（次の操作は orchestrator の文言に載る）。
                    record_failure_reason(job, "時間切れ")
                    return JobStatus.FAILED
                except _ImageInputUnsupported:
                    # モデルが画像を読めない（理由は LOG イベントで流し済み）。
                    # thread は終了済みか終了に向かっている。回収して失敗扱いにする。
                    try:
                        await future
                    except Exception:
                        pass
                    return JobStatus.FAILED
                except Exception:
                    logger.exception("Hermes AIAgent が転んだ")
                    # thread は終了済みか終了に向かっている。lease 解放前に回収する。
                    try:
                        await future
                    except Exception:
                        pass
                    return JobStatus.FAILED
                finally:
                    events.put(None)
                    await drain_task
                    executor.shutdown(wait=False)
            finally:
                pass
        finally:
            _AGENT_SERIAL.release()

        if session_id:
            _persist_session_best_effort(job, session_id)

        # カーソルは実行した prompt 分だけ進める。失敗時は進めない（pending を残す）。
        try:
            if pending:
                advance_followup_cursor(job, pending)
        except Exception:
            logger.debug("followup cursor advance failed", exc_info=True)
        # 配信したスクショも同様にカーソルを進める。
        try:
            if screenshots:
                advance_screenshot_cursor(job, screenshots)
        except Exception:
            logger.debug("screenshot cursor advance failed", exc_info=True)

        response = str((result or {}).get("final_response") or "").strip()
        if (result or {}).get("failed"):
            # モデル自身が失敗を返した。理由を残して Forum/SSE の一言に載せる。
            record_failure_reason(job, response or None)
            return JobStatus.FAILED
        if not response:
            from mihari_room.worker.wrangler_temp import temp_deploys_for

            deploys = temp_deploys_for(Path(job.directory))
            preview = str(deploys[-1].get("preview_url") or "").strip() if deploys else ""
            if not preview:
                return JobStatus.FAILED
            response = temp_deploy_posted_line(preview)
        clear_failure_reason(job)
        # 返答は「発話（短い読み上げ）」と「説明（長い方）」を空行で分けられる。
        # 分かれていたら、読み上げ用の短い文と説明用の長い文を別イベントで流す。
        speech, _separator, explanation = response.partition("\n\n")
        if not speech.strip():
            # 空行から始まる変な返しは、まとめて発話として扱う。
            speech, explanation = response, ""
        await on_progress(ProgressEvent(kind=ProgressKind.SPEECH, text=speech.strip()))
        if explanation.strip():
            await on_progress(ProgressEvent(kind=ProgressKind.SUMMARY, text=explanation.strip()))
        return JobStatus.DONE


async def _drain_progress(
    events: queue.Queue[ProgressEvent | None],
    on_progress: Callable[[ProgressEvent], Awaitable[None]],
) -> None:
    while True:
        item = await asyncio.to_thread(events.get)
        if item is None:
            return
        await on_progress(item)


def _interrupt(holder: list[Any]) -> None:
    if not holder:
        return
    interrupt = getattr(holder[0], "interrupt", None)
    if callable(interrupt):
        try:
            interrupt("timeout")
        except TypeError:
            try:
                interrupt()
            except Exception:
                logger.debug("interrupt failed", exc_info=True)
        except Exception:
            logger.debug("interrupt failed", exc_info=True)
