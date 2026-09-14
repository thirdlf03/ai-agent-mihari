"""音声セッションから呼べるツールのスキーマ定義と実行器。

- ``VOICE_TOOL_SCHEMAS``: Realtime ``session.update`` の ``session.tools`` と
  Live ``session.delegation.responses.tools`` に登録する function tool 定義。
- ``VoiceToolExecutor``: upstream の ``function_call`` を受けて実行し、
  JSON 文字列の結果を ``VoiceToolOutcome`` で返す。``capture_screen`` だけは
  room では実行せず ``client_side=True`` を返し、desktop（ScreenCaptureKit
  の許可を既に持つ側）へ委譲する。
- Mac へ届ける ``mac_*`` ツールは最初の呼び出しで ``MacControlHub`` の run を
  遅延開始し（音声セッション = 1 run）、``close()`` で畳む。Mac が未接続でも
  音声会話自体は落とさず、失敗は ``{"success": false, ...}`` の JSON で返す。
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from typing import TYPE_CHECKING, Any
from uuid import uuid4

from mihari_room.archive.pathutil import ensure_contained, sanitize_filename
from mihari_room.contracts import CreateJobRequest, Job, JobSource
from mihari_room.job_interactions import list_pending_questions
from mihari_room.mac_control.errors import MacControlError, MacControlErrorCode
from mihari_room.mac_control.protocol import MacOpKind
from mihari_room.worker.discord_tools import (
    discord_channels_impl,
    discord_context_impl,
    discord_message_impl,
    discord_recent_impl,
    discord_search_impl,
)

if TYPE_CHECKING:
    from mihari_room.config import RoomConfig
    from mihari_room.job_interactions import JobInteractionHub
    from mihari_room.mac_control.hub import MacControlHub
    from mihari_room.orchestrator import RoomOrchestrator
    from mihari_room.voice.sessions import VoiceSessionManager

logger = logging.getLogger("mihari_room.voice")

# --- 引数の上限 ---------------------------------------------------------------

_MAX_PROMPT_CHARS = 20_000
_MAX_TEXT_ARG_CHARS = 4_000
_MAX_QUERY_CHARS = 500
_MAX_PATH_CHARS = 1_024
_MAX_FETCH_BYTES = 50 * 1024 * 1024
_MAX_ATTACHMENT_COUNT = 10
_MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
_MAX_FIND_LIMIT = 50
_MAX_DISCORD_LIMIT = 50

#: submit_job の添付に使えるのは mac_fetch_file が同セッションで保存した
#: downloads/ 内のファイルだけ（パストラバーサル・任意パス読み出しを防ぐ）。
_DOWNLOADS_DIRNAME = "downloads"

#: room では実行せず desktop へ委譲するツール名。
CLIENT_SIDE_TOOLS = frozenset({"capture_screen"})


def _fn(
    name: str,
    description: str,
    properties: dict[str, Any],
    required: list[str] | None = None,
) -> dict[str, Any]:
    """function tool 定義（Realtime / Responses delegation 共通の形）。"""
    return {
        "type": "function",
        "name": name,
        "description": description,
        "parameters": {
            "type": "object",
            "properties": properties,
            "required": required or [],
            "additionalProperties": False,
        },
    }


#: upstream に登録するツール一式。capture_screen は登録するが実行は client。
VOICE_TOOL_SCHEMAS: list[dict[str, Any]] = [
    _fn(
        "submit_job",
        "依頼された仕事を部屋の作業キューへ登録する。「投げて」「やっておいて」等に使う。",
        {
            "prompt": {
                "type": "string",
                "description": "仕事の本文。何をしてほしいかを具体的に。",
            },
            "title": {
                "type": "string",
                "description": "短い件名。省略時は本文から自動で付く。",
            },
            "attachments": {
                "type": "array",
                "items": {"type": "string"},
                "description": (
                    "同セッションで mac_fetch_file 済みのファイル名だけ指定可。"
                ),
            },
        },
        ["prompt"],
    ),
    _fn(
        "steer_job",
        "実行中・待機中の仕事へ追加指示（steer）を送る。",
        {
            "instruction": {"type": "string", "description": "追加の指示文。"},
            "job_id": {
                "type": "string",
                "description": "対象 job。省略時はこのセッションで直近に依頼した job。",
            },
        },
        ["instruction"],
    ),
    _fn(
        "get_job_status",
        "仕事の状態を取得する。job_id 省略時は直近の依頼、それも無ければ実行中一覧。",
        {
            "job_id": {"type": "string", "description": "対象 job id。"},
        },
    ),
    _fn(
        "list_running_jobs",
        "机を占有している（実行中・入力待ちの）仕事の一覧を返す。",
        {},
    ),
    _fn(
        "answer_job_question",
        "仕事からの pending 質問へ依頼主の回答を登録する。",
        {
            "job_id": {"type": "string"},
            "question_id": {"type": "string"},
            "answer": {"type": "string", "description": "依頼主の回答文。"},
        },
        ["job_id", "question_id", "answer"],
    ),
    _fn(
        "cancel_job",
        "仕事をキャンセルする。job_id 省略時は直近の依頼。",
        {
            "job_id": {"type": "string"},
        },
    ),
    _fn(
        "capture_screen",
        "ユーザーの Mac の画面を撮影して内容を見る。client 側で実行される。",
        {
            "prompt": {
                "type": "string",
                "description": "画像と一緒に送る問いかけ（何を見たいか）。",
            },
        },
    ),
    _fn(
        "discord_search",
        "取り込み済み Discord アーカイブを本文・添付・URL 横断で検索する。",
        {
            "query": {"type": "string"},
            "limit": {"type": "integer"},
            "channel": {"type": "string", "description": "チャンネル名か ID。"},
            "after": {"type": "string", "description": "ISO 日時（以降）。"},
            "before": {"type": "string", "description": "ISO 日時（以前）。"},
        },
        ["query"],
    ),
    _fn(
        "discord_recent",
        "取り込み済み Discord アーカイブの最近の発言を返す。",
        {
            "limit": {"type": "integer"},
            "channel": {"type": "string"},
            "after": {"type": "string"},
            "before": {"type": "string"},
        },
    ),
    _fn(
        "discord_channels",
        "アーカイブ済みの Discord チャンネル一覧を返す。",
        {},
    ),
    _fn(
        "discord_message",
        "message_id の Discord メッセージ本文・添付・URL を返す。",
        {
            "message_id": {"type": "integer"},
        },
        ["message_id"],
    ),
    _fn(
        "discord_context",
        "message_id の前後の発言を返す。",
        {
            "message_id": {"type": "integer"},
            "before": {"type": "integer"},
            "after": {"type": "integer"},
        },
        ["message_id"],
    ),
    _fn(
        "mac_find_files",
        "ユーザーの Mac 上のファイルを検索する（候補リストのみ、中身は読まない）。",
        {
            "query": {"type": "string", "description": "ファイル名・内容の検索語。"},
            "scope": {"type": "string", "description": "検索範囲の種別（実装依存）。"},
            "dirs": {
                "type": "array",
                "items": {"type": "string"},
                "description": "検索対象ディレクトリ。",
            },
            "limit": {"type": "integer"},
        },
        ["query"],
    ),
    _fn(
        "mac_fetch_file",
        "ユーザーの Mac 上のファイルをこのセッションへ取り込む。"
        "保存名を返し、submit_job の attachments から参照できる。",
        {
            "path": {"type": "string", "description": "Mac 上のファイルパス。"},
            "max_bytes": {"type": "integer"},
        },
        ["path"],
    ),
    _fn(
        "mac_hand_off_file",
        "ユーザーの Mac 上のファイルを Finder 等へ引き渡す（共有・プレビュー用）。",
        {
            "path": {"type": "string"},
            "label": {"type": "string", "description": "引き渡し時の表示名。"},
        },
        ["path"],
    ),
]


def _json(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False)


def _ok(payload: dict[str, Any]) -> str:
    return _json({"success": True, **payload})


def _fail(message: str, **extra: Any) -> str:
    return _json({"success": False, "error": message, **extra})


def _str_arg(args: dict[str, Any], key: str, limit: int) -> str:
    value = args.get(key)
    if value is None:
        return ""
    return str(value).strip()[:limit]


def _int_arg(args: dict[str, Any], key: str, default: int, ceiling: int) -> int:
    try:
        value = int(args.get(key))
    except (TypeError, ValueError):
        value = default
    return max(1, min(ceiling, value))


@dataclass(frozen=True, slots=True)
class VoiceToolOutcome:
    """1 tool call の結果。

    ``output`` は function_call_output へそのまま入る JSON 文字列。
    ``image_png`` があれば結果と一緒に画像メッセージを upstream へ足す。
    ``client_side`` は desktop 実行（capture_screen）の印。
    """

    output: str
    image_png: bytes | None = None
    client_side: bool = False
    ok: bool = True


class VoiceToolExecutor:
    """音声セッション 1 本ぶんのツール実行器。

    - job 系は ``RoomOrchestrator`` 経由（Forum スレッド・queue・journal は内部）。
    - discord_* は ``worker/discord_tools`` の実装を流用。``job.directory`` の
      ``parent.parent`` が room root（messages.db の置き場）になるよう、
      ``<root>/voice/<session_id>`` を shim の job 置き場にする。
    - mac_* は ``MacControlHub`` の run を初回に begin してセッション中は
      同じ run を使い、``close()`` で end_run する。
    """

    def __init__(
        self,
        *,
        session_id: str,
        manager: VoiceSessionManager,
        orchestrator: RoomOrchestrator | None,
        mac_hub: MacControlHub | None,
        interactions: JobInteractionHub | None,
        config: RoomConfig | None = None,
    ) -> None:
        self._session_id = session_id
        self._manager = manager
        self._orchestrator = orchestrator
        self._hub = mac_hub
        self._interactions = interactions
        self._config = config if config is not None else getattr(manager, "config", None)
        root = Path(self._config.root) if self._config is not None else Path(".")
        # ``<root>/voice/<sid>`` は root の 2 段下なので
        # ``_room_root_for_job``（directory.parent.parent）が config.root を指す。
        self.voice_dir = root / "voice" / session_id
        self.downloads_dir = self.voice_dir / _DOWNLOADS_DIRNAME
        self._last_job_id: str | None = None
        self._mac_job_id = f"voice-{session_id}"
        self._mac_run_id = f"{self._mac_job_id}-{uuid4().hex[:8]}"
        self._mac_begun = False

    async def execute(self, name: str, arguments_json: str) -> VoiceToolOutcome:
        """function_call 1 件を実行する。例外は failure JSON に畳む。"""
        try:
            args = json.loads(arguments_json) if arguments_json else {}
        except (json.JSONDecodeError, TypeError):
            return self._outcome(_fail(f"引数 JSON が読めない: {name}"), ok=False)
        if not isinstance(args, dict):
            return self._outcome(_fail("引数は JSON オブジェクトで"), ok=False)
        handler = _TOOL_HANDLERS.get(name)
        if handler is None:
            return self._outcome(_fail(f"未対応のツール: {name}"), ok=False)
        try:
            return await handler(self, args)
        except MacControlError as error:
            return self._outcome(_json(error.to_dict()), ok=False)
        except Exception as error:  # noqa: BLE001 -- ツール失敗で会話は落とさない
            logger.warning("voice tool %s failed: %s", name, error, exc_info=True)
            return self._outcome(
                _fail(f"{type(error).__name__}: {error}"), ok=False
            )

    async def close(self) -> None:
        """stream 終了時。begin 済みの Mac run があれば畳む。"""
        if not self._mac_begun or self._hub is None:
            return
        self._mac_begun = False
        try:
            await asyncio.to_thread(
                self._hub.end_run,
                job_id=self._mac_job_id,
                run_id=self._mac_run_id,
                reason="voice stream end",
            )
        except Exception:
            logger.debug("voice mac run end failed", exc_info=True)

    # --- 共通ヘルパ -----------------------------------------------------------

    def _outcome(
        self,
        output: str,
        *,
        ok: bool | None = None,
        image_png: bytes | None = None,
        client_side: bool = False,
    ) -> VoiceToolOutcome:
        if ok is None:
            try:
                ok = bool(json.loads(output).get("success"))
            except (ValueError, AttributeError):
                ok = bool(output)
        return VoiceToolOutcome(
            output=output, image_png=image_png, client_side=client_side, ok=ok
        )

    def _resolve_job_id(self, raw: Any) -> str | None:
        job_id = str(raw).strip() if raw else ""
        return job_id or self._last_job_id

    def _store(self) -> Any:
        if self._orchestrator is None:
            return None
        return getattr(self._orchestrator, "store", None)

    def _job_summary(self, job: Job) -> dict[str, Any]:
        return {
            "job_id": job.id,
            "title": job.title,
            "status": job.status.value,
            "thread_id": job.thread_id,
        }

    def _active_jobs(self) -> list[Job]:
        store = self._store()
        if store is None:
            return []
        lister = getattr(store, "list_active", None) or getattr(store, "list_running", None)
        if not callable(lister):
            return []
        return list(lister())

    # --- job 系 ---------------------------------------------------------------

    async def _tool_submit_job(self, args: dict[str, Any]) -> VoiceToolOutcome:
        if self._orchestrator is None:
            return self._outcome(_fail("job の受付（orchestrator）が無い"), ok=False)
        prompt = _str_arg(args, "prompt", _MAX_PROMPT_CHARS)
        if not prompt:
            return self._outcome(_fail("prompt が空"), ok=False)
        from mihari_room.app import derive_title

        title = derive_title(_str_arg(args, "title", 200), prompt)
        attachments = self._resolve_attachments(args.get("attachments"))
        if isinstance(attachments, VoiceToolOutcome):
            return attachments
        owner = getattr(self._config, "owner_id", "") or "voice"
        job = await self._orchestrator.submit(
            CreateJobRequest(
                title=title,
                body=prompt,
                source=JobSource.PET,
                requested_by=owner,
            ),
            attachments=attachments,
        )
        self._last_job_id = job.id
        return self._outcome(
            _ok(
                {
                    **self._job_summary(job),
                    "note": "仕事をキューに入れた",
                }
            )
        )

    def _resolve_attachments(self, raw: Any) -> list[tuple[str, bytes]] | VoiceToolOutcome:
        if raw is None:
            return []
        if not isinstance(raw, list) or len(raw) > _MAX_ATTACHMENT_COUNT:
            return self._outcome(
                _fail(f"attachments は {_MAX_ATTACHMENT_COUNT} 個まで"), ok=False
            )
        resolved: list[tuple[str, bytes]] = []
        for item in raw:
            name = sanitize_filename(str(item))
            try:
                path = ensure_contained(self.downloads_dir / name, self.downloads_dir)
            except ValueError:
                return self._outcome(
                    _fail(f"attachments は downloads 内のファイル名だけ: {item}"),
                    ok=False,
                )
            if not path.is_file():
                return self._outcome(
                    _fail(f"{name} は未取得（先に mac_fetch_file で取り込む）"),
                    ok=False,
                )
            try:
                data = path.read_bytes()
            except OSError as error:
                return self._outcome(_fail(f"{name} が読めない: {error}"), ok=False)
            if len(data) > _MAX_ATTACHMENT_BYTES:
                return self._outcome(
                    _fail(f"{name} が大きすぎる（{_MAX_ATTACHMENT_BYTES} bytes まで）"),
                    ok=False,
                )
            resolved.append((name, data))
        return resolved

    async def _tool_steer_job(self, args: dict[str, Any]) -> VoiceToolOutcome:
        if self._orchestrator is None:
            return self._outcome(_fail("orchestrator が無い"), ok=False)
        instruction = _str_arg(args, "instruction", _MAX_TEXT_ARG_CHARS)
        if not instruction:
            return self._outcome(_fail("instruction が空"), ok=False)
        job_id = self._resolve_job_id(args.get("job_id"))
        if job_id is None:
            return self._outcome(
                _fail("対象 job が分からない（先に submit_job するか job_id を指定）"),
                ok=False,
            )
        record = await self._orchestrator.steer_job(job_id, instruction)
        return self._outcome(_ok({"job_id": job_id, "steer": record}))

    async def _tool_get_job_status(self, args: dict[str, Any]) -> VoiceToolOutcome:
        job_id = self._resolve_job_id(args.get("job_id"))
        store = self._store()
        if job_id is not None:
            if store is None:
                return self._outcome(_fail("job store が無い"), ok=False)
            try:
                job = store.get(job_id)
            except KeyError:
                return self._outcome(_fail(f"job が無い: {job_id}"), ok=False)
            pending = [
                {"id": q.id, "question": q.question, "choices": q.choices}
                for q in list_pending_questions(job.directory)
            ]
            return self._outcome(
                _ok({**self._job_summary(job), "pending_questions": pending})
            )
        jobs = self._active_jobs()
        return self._outcome(
            _ok({"jobs": [self._job_summary(job) for job in jobs], "count": len(jobs)})
        )

    async def _tool_list_running_jobs(self, args: dict[str, Any]) -> VoiceToolOutcome:
        del args
        jobs = self._active_jobs()
        return self._outcome(
            _ok({"jobs": [self._job_summary(job) for job in jobs], "count": len(jobs)})
        )

    async def _tool_answer_job_question(self, args: dict[str, Any]) -> VoiceToolOutcome:
        if self._orchestrator is None:
            return self._outcome(_fail("orchestrator が無い"), ok=False)
        job_id = self._resolve_job_id(args.get("job_id"))
        question_id = _str_arg(args, "question_id", 200)
        answer = _str_arg(args, "answer", _MAX_TEXT_ARG_CHARS)
        if not job_id or not question_id or not answer:
            return self._outcome(
                _fail("job_id / question_id / answer は全部必要"), ok=False
            )
        resolved = await self._orchestrator.answer_question(job_id, question_id, answer)
        return self._outcome(_ok({"job_id": job_id, "question": resolved}))

    async def _tool_cancel_job(self, args: dict[str, Any]) -> VoiceToolOutcome:
        if self._orchestrator is None:
            return self._outcome(_fail("orchestrator が無い"), ok=False)
        job_id = self._resolve_job_id(args.get("job_id"))
        if job_id is None:
            return self._outcome(_fail("対象 job が分からない"), ok=False)
        job = await self._orchestrator.cancel(job_id, by="voice")
        return self._outcome(_ok(self._job_summary(job)))

    async def _tool_capture_screen(self, args: dict[str, Any]) -> VoiceToolOutcome:
        # room では実行しない。stream 層が assistant.tool_call で desktop へ渡し、
        # 返ってきた input.image が function_call_output になる。
        del args
        return self._outcome("", ok=True, client_side=True)

    # --- discord archive 系 ---------------------------------------------------

    def _shim_job(self) -> Any:
        """discord_* 実装が要求する job 形（``id`` と ``directory`` だけ見る）。"""
        return SimpleNamespace(id=self._mac_job_id, directory=self.voice_dir)

    async def _tool_discord_search(self, args: dict[str, Any]) -> VoiceToolOutcome:
        query = _str_arg(args, "query", _MAX_QUERY_CHARS)
        if not query:
            return self._outcome(_fail("query が空"), ok=False)
        limit = _int_arg(args, "limit", 5, _MAX_DISCORD_LIMIT)
        channel = _str_arg(args, "channel", 200) or None
        after = _str_arg(args, "after", 64) or None
        before = _str_arg(args, "before", 64) or None
        out = await asyncio.to_thread(
            discord_search_impl, self._shim_job(), query, limit, channel, after, before
        )
        return self._outcome(out)

    async def _tool_discord_recent(self, args: dict[str, Any]) -> VoiceToolOutcome:
        limit = _int_arg(args, "limit", 10, _MAX_DISCORD_LIMIT)
        channel = _str_arg(args, "channel", 200) or None
        after = _str_arg(args, "after", 64) or None
        before = _str_arg(args, "before", 64) or None
        out = await asyncio.to_thread(
            discord_recent_impl, self._shim_job(), limit, channel, after, before
        )
        return self._outcome(out)

    async def _tool_discord_channels(self, args: dict[str, Any]) -> VoiceToolOutcome:
        del args
        out = await asyncio.to_thread(discord_channels_impl, self._shim_job(), 50)
        return self._outcome(out)

    async def _tool_discord_message(self, args: dict[str, Any]) -> VoiceToolOutcome:
        try:
            message_id = int(args.get("message_id"))
        except (TypeError, ValueError):
            return self._outcome(_fail("message_id が数字ではない"), ok=False)
        out = await asyncio.to_thread(discord_message_impl, self._shim_job(), message_id)
        return self._outcome(out)

    async def _tool_discord_context(self, args: dict[str, Any]) -> VoiceToolOutcome:
        try:
            message_id = int(args.get("message_id"))
        except (TypeError, ValueError):
            return self._outcome(_fail("message_id が数字ではない"), ok=False)
        before = _int_arg(args, "before", 3, 10)
        after = _int_arg(args, "after", 3, 10)
        out = await asyncio.to_thread(
            discord_context_impl, self._shim_job(), message_id, before, after
        )
        return self._outcome(out)

    # --- mac 系（遅延 run） ----------------------------------------------------

    async def _ensure_mac_run(self) -> None:
        if self._mac_begun:
            return
        if self._hub is None:
            raise MacControlError(
                MacControlErrorCode.UNAVAILABLE, "Mac 操作の hub が無い"
            )
        self.voice_dir.mkdir(parents=True, exist_ok=True)
        # hub の公開 API は同期呼び出し（内部で loop へ投げて待つ）なので
        # イベントループを塞がないようスレッドへ逃がす。
        await asyncio.to_thread(
            self._hub.begin_run,
            job_id=self._mac_job_id,
            run_id=self._mac_run_id,
            job_dir=self.voice_dir,
            job_title="音声会話",
        )
        self._mac_begun = True

    async def _run_mac_op(self, kind: MacOpKind, params: dict[str, Any]) -> dict[str, Any]:
        await self._ensure_mac_run()
        assert self._hub is not None  # _ensure_mac_run が通れば非 None
        outcome = await asyncio.to_thread(
            self._hub.run_operation,
            job_id=self._mac_job_id,
            run_id=self._mac_run_id,
            kind=kind,
            params=params,
        )
        return dict(outcome)

    async def _tool_mac_find_files(self, args: dict[str, Any]) -> VoiceToolOutcome:
        query = _str_arg(args, "query", _MAX_QUERY_CHARS)
        if not query:
            return self._outcome(_fail("query が空"), ok=False)
        params: dict[str, Any] = {"query": query}
        scope = _str_arg(args, "scope", 100)
        if scope:
            params["scope"] = scope
        dirs_raw = args.get("dirs")
        if isinstance(dirs_raw, list):
            params["dirs"] = [
                str(d)[:_MAX_PATH_CHARS] for d in dirs_raw[:10] if str(d).strip()
            ]
        params["limit"] = _int_arg(args, "limit", 10, _MAX_FIND_LIMIT)
        outcome = await self._run_mac_op(MacOpKind.FIND_FILES, params)
        return self._outcome(_json(outcome))

    async def _tool_mac_fetch_file(self, args: dict[str, Any]) -> VoiceToolOutcome:
        path = _str_arg(args, "path", _MAX_PATH_CHARS)
        if not path:
            return self._outcome(_fail("path が空"), ok=False)
        max_bytes = _int_arg(args, "max_bytes", _MAX_ATTACHMENT_BYTES, _MAX_FETCH_BYTES)
        outcome = await self._run_mac_op(
            MacOpKind.FETCH_FILE, {"path": path, "max_bytes": max_bytes}
        )
        if not outcome.get("success"):
            return self._outcome(_json(outcome), ok=False)
        result = outcome.get("result") or {}
        data_b64 = result.get("data_base64") or result.get("data")
        if not isinstance(data_b64, str) or not data_b64:
            # 本体が無い形で返る実装もありうる。そのまま結果を渡す。
            return self._outcome(_json(outcome))
        try:
            data = base64.b64decode(data_b64, validate=True)
        except (binascii.Error, ValueError):
            return self._outcome(
                _fail("fetch 結果の base64 が読めない"), ok=False
            )
        name = sanitize_filename(
            str(result.get("name") or result.get("filename") or Path(path).name)
        )
        self.downloads_dir.mkdir(parents=True, exist_ok=True)
        dest = ensure_contained(self.downloads_dir / name, self.downloads_dir)
        dest.write_bytes(data)
        image_png = data if name.lower().endswith(".png") else None
        return self._outcome(
            _ok(
                {
                    "path": path,
                    "saved_as": name,
                    "bytes": len(data),
                    "note": "submit_job の attachments に saved_as を指定できる",
                }
            ),
            image_png=image_png,
        )

    async def _tool_mac_hand_off_file(self, args: dict[str, Any]) -> VoiceToolOutcome:
        path = _str_arg(args, "path", _MAX_PATH_CHARS)
        if not path:
            return self._outcome(_fail("path が空"), ok=False)
        params: dict[str, Any] = {"path": path}
        label = _str_arg(args, "label", 200)
        if label:
            params["label"] = label
        outcome = await self._run_mac_op(MacOpKind.HAND_OFF_FILE, params)
        return self._outcome(_json(outcome))


#: ツール名 → 実行メソッドの dispatch 表。``CLIENT_SIDE_TOOLS`` はここにも
#: 載せ、client_side=True の outcome として stream 層へ委譲を伝える。
_TOOL_HANDLERS: dict[str, Any] = {
    "submit_job": VoiceToolExecutor._tool_submit_job,
    "steer_job": VoiceToolExecutor._tool_steer_job,
    "get_job_status": VoiceToolExecutor._tool_get_job_status,
    "list_running_jobs": VoiceToolExecutor._tool_list_running_jobs,
    "answer_job_question": VoiceToolExecutor._tool_answer_job_question,
    "cancel_job": VoiceToolExecutor._tool_cancel_job,
    "capture_screen": VoiceToolExecutor._tool_capture_screen,
    "discord_search": VoiceToolExecutor._tool_discord_search,
    "discord_recent": VoiceToolExecutor._tool_discord_recent,
    "discord_channels": VoiceToolExecutor._tool_discord_channels,
    "discord_message": VoiceToolExecutor._tool_discord_message,
    "discord_context": VoiceToolExecutor._tool_discord_context,
    "mac_find_files": VoiceToolExecutor._tool_mac_find_files,
    "mac_fetch_file": VoiceToolExecutor._tool_mac_fetch_file,
    "mac_hand_off_file": VoiceToolExecutor._tool_mac_hand_off_file,
}
