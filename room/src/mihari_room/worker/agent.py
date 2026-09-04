"""本家 ``AIAgent`` をジョブフォルダで回す。Gateway は起動しない。

起動の骨格は Hermes Agent（MIT, Copyright (c) 2025 Nous Research）の
``hermes_cli/oneshot.py`` と ``gateway/run_turn_runner.py`` と同じ。
oneshot と違う点:

- stdout を捨てない。``tool_progress_callback`` で進捗を取る
- セッションをジョブに紐づけて、続きは履歴ごと resume する
- ``declare_stateless_channel()`` は呼ばない
"""

from __future__ import annotations

import asyncio
import logging
import os
import queue
from collections.abc import Awaitable, Callable, Mapping
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from mihari_room.contracts import (
    INPUT_DIRNAME,
    OUTPUT_DIRNAME,
    Job,
    JobStatus,
    ProgressEvent,
    ProgressKind,
)
from mihari_room.worker.progress import format_tool_progress

logger = logging.getLogger("mihari_room")

#: ジョブフォルダに残すセッション ID。秘密ではない。
SESSION_FILENAME = "hermes_session_id"

#: 注入用。本家 ``AIAgent`` と同じキーワードを受けてインスタンスを返す。
AgentFactory = Callable[..., Any]


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


def build_turn_prompt(job: Job) -> str:
    """初回は題と本文。続きは最新の followup を、同じセッションへの次ターンとして渡す。"""
    from mihari_room.worker.hermes import build_prompt

    followups = sorted((job.directory / INPUT_DIRNAME).glob("followup-*.txt"))
    if read_session_id(job) and followups:
        latest = followups[-1].read_text(encoding="utf-8")
        return (
            f"続きの依頼:\n{latest}\n\n"
            f"`{INPUT_DIRNAME}/` にある入力ファイルを読んで作業し、"
            f"結果は `{OUTPUT_DIRNAME}/` に書き出してください。"
            "必要な説明は標準出力の最後に 1〜数行で書いてください。"
        )
    return build_prompt(job)


@contextmanager
def _job_cwd(directory: Path):
    """ツールと AGENTS.md がジョブフォルダを見るようにする。"""
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
        os.chdir(previous)
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
    if agent is not None:
        try:
            agent._end_session_on_close = False
        except Exception:
            pass
        try:
            messages = getattr(agent, "_session_messages", None)
            if isinstance(messages, list):
                agent.shutdown_memory_provider(messages)
            else:
                agent.shutdown_memory_provider()
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


def _resolve_runtime() -> tuple[str, dict[str, Any]]:
    """oneshot と同じ model / provider / toolsets。"""
    from mihari_room.worker.bootstrap import bootstrap_hermes

    bootstrap_hermes()
    from hermes_cli.config import load_config
    from hermes_cli.fallback_config import get_fallback_chain
    from hermes_cli.oneshot import _resolve_model_and_provider
    from hermes_cli.runtime_provider import resolve_runtime_provider
    from hermes_cli.tools_config import _get_platform_tools

    cfg = load_config()
    choice = _resolve_model_and_provider(cfg, None, None)
    runtime = resolve_runtime_provider(
        requested=choice.provider,
        target_model=choice.model or None,
        explicit_base_url=choice.base_url,
        explicit_api_key=choice.api_key,
    )
    toolsets = sorted(_get_platform_tools(cfg, "cli"))
    fallback = get_fallback_chain(cfg) or None
    return choice.model, {
        "runtime": runtime,
        "toolsets": toolsets,
        "fallback": fallback,
    }


def default_agent_factory(**kwargs: Any) -> Any:
    from mihari_room.worker.bootstrap import bootstrap_hermes, import_ai_agent

    bootstrap_hermes()
    from hermes_cli.mcp_startup import ensure_mcp_discovery_before_agent_build

    ensure_mcp_discovery_before_agent_build(logger=logger, single_query=False)
    agent_cls = import_ai_agent()
    return agent_cls(**kwargs)


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
            line = format_tool_progress(event_type, tool_name, preview, args, **kwargs)
            if line:
                emit(ProgressEvent(kind=ProgressKind.LOG, text=line))

        def clarify_callback(question: str, choices: Any = None, multi_select: bool = False) -> str:
            emit(
                ProgressEvent(
                    kind=ProgressKind.LOG,
                    text=f"確認したいけど、一人で進める: {question}",
                )
            )
            if choices:
                what = "subset" if multi_select else "option"
                return (
                    f"[unattended room: pick the best {what} from "
                    f"{choices} using your own judgment and continue.]"
                )
            return "[unattended room: make the most reasonable assumption and continue.]"

        def run_sync() -> tuple[Mapping[str, Any], str | None]:
            with _job_cwd(job.directory), _unattended_env():
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
                try:
                    agent = self._agent_factory(
                        api_key=runtime.get("api_key"),
                        base_url=runtime.get("base_url"),
                        provider=runtime.get("provider"),
                        requested_provider=runtime.get("requested_provider"),
                        api_mode=runtime.get("api_mode"),
                        model=model,
                        enabled_toolsets=resolved["toolsets"],
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
                    agent.suppress_status_output = True
                    agent._end_session_on_close = False
                    result = agent.run_conversation(
                        prompt,
                        conversation_history=history,
                    )
                    return result or {}, getattr(agent, "session_id", None)
                finally:
                    _close_agent(agent, session_db)

        drain_task = asyncio.create_task(_drain_progress(events, on_progress))
        work = asyncio.create_task(asyncio.to_thread(run_sync))
        try:
            result, session_id = await asyncio.wait_for(asyncio.shield(work), timeout=self._timeout)
        except TimeoutError:
            _interrupt(holder)
            try:
                await asyncio.wait_for(work, timeout=5)
            except (TimeoutError, Exception):
                pass
            return JobStatus.FAILED
        except Exception:
            logger.exception("Hermes AIAgent が転んだ")
            return JobStatus.FAILED
        finally:
            events.put(None)
            await drain_task

        if session_id:
            write_session_id(job, str(session_id))

        response = str((result or {}).get("final_response") or "").strip()
        if (result or {}).get("failed") or not response:
            return JobStatus.FAILED
        await on_progress(ProgressEvent(kind=ProgressKind.SPEECH, text=response))
        await on_progress(ProgressEvent(kind=ProgressKind.SUMMARY, text=response))
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
            interrupt()
        except Exception:
            logger.debug("interrupt failed", exc_info=True)
