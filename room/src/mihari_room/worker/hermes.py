"""Hermes をジョブフォルダで動かす JobWorker。

既定は本家 ``AIAgent`` をプロセス内で回す（Gateway は起動しない）。
``command=`` を渡したときだけ従来の subprocess（テスト用の偽 CLI 含む）。
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import Awaitable, Callable, Sequence
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
from mihari_room.worker.agent import AgentFactory

# タイムアウトの既定値（15 分）。
DEFAULT_TIMEOUT = 15 * 60

# subprocess 経路の雛形。末尾にプロンプトを 1 引数として足す。
DEFAULT_COMMAND: tuple[str, ...] = ("hermes", "-z")

# ツール/デバッグ出力とみなす行頭（小文字で比較するもの）。
_LOG_PREFIXES = (
    "tool",
    "debug",
    "log",
    "trace",
    "exec",
    "running",
    "calling",
    "invoke",
    "command",
    "thinking",
    "working",
)

#: Discord 送信系。Room が Forum への出版を持つので agent には渡さない。
DISCORD_TOOLSETS = frozenset({"discord", "discord_admin"})

#: 既定で落とす危険ツールセット。bash/terminal は無制限なので、
#: ファイルガード（HERMES_WRITE_SAFE_ROOT）を素通りできる。
#: 明示の opt-in (MIHARI_ROOM_ALLOW_SHELL=1) がない限り外す。
#: file 生成 (write_file/patch)・session_search・search/browser 読取は残す。
#: delegation（nested agents の無制限増殖）・cronjob/kanban（背後の永続実行系）も
#: 既定では外す。Room の discord_* は in-process の bounded tool（別 toolset）で残す。
UNSAFE_TOOLSETS_DEFAULT_OFF = frozenset(
    {"terminal", "computer_use", "code_execution", "cronjob", "kanban", "delegation"}
)

#: agent 構築時に二重に渡す denylist（toolset 濾過のすり抜け対策）。
#: enabled 側の allowlist と併用し、MCP 動的 toolset（``mcp-*``）と送信系も塞ぐ。
#: name レベルの最終扉は ``prune_agent_tools``（委任・skill_manage・実行系を名指し除去）。
DISABLED_TOOLSETS = sorted(
    DISCORD_TOOLSETS | UNSAFE_TOOLSETS_DEFAULT_OFF | {"mcp", "hermes-discord", "hermes-gateway"}
)


def shell_allowed() -> bool:
    from mihari_room.worker.agent import _is_truthy

    return _is_truthy(os.environ.get("MIHARI_ROOM_ALLOW_SHELL", ""))


def filter_toolsets(toolsets: Sequence[str] | None) -> list[str] | None:
    """Discord 送信を落とし、既定では unsafe な実行系も落とす。

    None は None のまま（本家の既定解決に任せる前の段階では使わない。
    実際に agent へ渡す直前はリスト化されたものが来る）。
    Room の bounded ``mihari_room`` toolset（discord_* 検索群）は残す。
    """
    if toolsets is None:
        return None
    allow_shell = shell_allowed()
    out: list[str] = []
    for name in toolsets:
        if name in DISCORD_TOOLSETS or "discord" in name:
            # ただし Room の bounded toolset だけは残す（送信ではなく archive 読取）。
            if name == "mihari_room":
                out.append(name)
            continue
        if name.startswith("mcp-") or name.startswith("mcp_") or name == "mcp":
            continue
        if not allow_shell and name in UNSAFE_TOOLSETS_DEFAULT_OFF:
            continue
        out.append(name)
    # session_search / search / browser 読取 / file 生成は落とさない。
    # 万が一全部落ちたら None にせず空のまま（agent 側で最小集合を足す）。
    return out


def ensure_baseline_toolsets(toolsets: Sequence[str] | None) -> list[str]:
    """読み・生成に要る最小集合を保証する。"""
    base = list(toolsets) if toolsets else []
    for required in ("session_search", "search", "file", "mihari_room", "memory"):
        if required not in base:
            base.append(required)
    return base


def build_prompt(job: Job) -> str:
    """Hermes に渡すプロンプトを作る。タイトル・本文・入出力の約束を含む。

    プロンプトは強制ではない（enforcement は tool hook / store 側）。
    配置・公開・秘密の約束だけを書く。
    """
    return (
        f"タイトル: {job.title}\n"
        f"内容:\n{job.body}\n\n"
        "作業内容は上のタイトルと内容です。"
        f"同じ文面は `{INPUT_DIRNAME}/request.md` にもあります。\n"
        f"ペットからの依頼では `{INPUT_DIRNAME}/` に添付ファイルが無いのが普通です。"
        "無いファイルを探したり、無いことを失敗としないでください。"
        f"追記があるときだけ `{INPUT_DIRNAME}/followup-*.txt` を読んでください。\n"
        "調べものは `research/` に置き、要点は `research/summary.md`、"
        "出典は `research/sources.json`、生データは `research/downloads/` に置いてください。\n"
        f"成果物は `{OUTPUT_DIRNAME}/artifact/index.html` を起点に "
        f"`{OUTPUT_DIRNAME}/` に書き出してください。\n"
        "プレビュー CSP は `script-src 'self'` です。"
        "JS は同一フォルダの `.js` に分け、相対パスの `<script src>` だけ使ってください。"
        "HTML 内の `<script>`・onclick 等のインライン、CDN、外部スクリプトは動きません。\n"
        "公開物に API キー・トークン・個人情報（住所・電話・メール等）を入れないでください。\n"
        "静的な HTML/CSS/JS のモックは Room が管理します。"
        "新しくできた版は非公開で、共有 URL は owner が公開操作してから出ます。"
        "直接デプロイや外部投稿はしないでください。\n"
        "Worker や D1/KV/DO などバックエンド付きの動作確認が必要なときだけ "
        "`cloudflare_temp_deploy` を使ってください（一時アカウント、約 60 分、外部公開）。"
        "これは依頼時に外部公開を許可（allow_external_publish）された仕事でだけ使えます。"
        "許されていない仕事ではこの道具は存在しません。"
        "その仕事では `output/artifact` にページを置かないでください。"
        "置くと恒久プレビューになり、CSP で Worker API に繋がりません。"
        "UI は Worker プロジェクト側に含めてください。"
        "`cloudflare_temp_deploy` の subdir はこのジョブのフォルダだけを見ます。"
        "他ジョブの worker/ や temp_deploy.json は使えません。"
        "このジョブに wrangler.toml が無ければ先に書いてから呼んでください。"
        "本番 Cloudflare アカウントへの wrangler deploy はしないでください。"
        "claim URL は Room が owner に渡します。Forum や成果物に書かないでください。\n"
        "過去の会話は組み込みの session_search を先に使ってください。\n"
        "Discord 横断検索が必要なときは組み込みツールを使う:"
        " `discord_search`（本文・添付・URL、日時/チャンネル/作者で絞れる）、"
        " `discord_recent`（最近の発言）、`discord_channels`（収録チャンネル一覧）、"
        " `discord_message`（1件の詳細）、`discord_context`（前後）、"
        " 添付の取り込みは `discord_export`。"
        "いずれも in-process で messages.db を読むだけ。shell は要らない。"
        "引用には必ず `jump_url` を添えてください。\n"
        "記憶に残したいことは memory ツールの action='add' に書いてください"
        "（承認後に保存されます。replace/remove は未対応です）。"
        "MEMORY.md や USER.md を file ツールで書かないでください。\n"
        "必要な説明は標準出力の最後に 1〜数行で書いてください。"
    )


def is_log_line(line: str) -> bool:
    """ツール/デバッグ系の行かどうかを判定する。"""
    s = line.strip()
    if not s:
        return False
    # `[tool] ...` や `{...}` のような構造化ログは LOG 扱い。
    if s[0] in "[{":
        return True
    # `> ...` や `$ ...` などの接頭辞は LOG 扱い。
    if s[0] in ">$•-▸":
        return True
    lowered = s.lower()
    return lowered.startswith(_LOG_PREFIXES)


def _snapshot_files(output_dir: Path) -> set[Path]:
    """実行前の output/ 配下ファイル一覧を取る（新規検出用）。"""
    if not output_dir.is_dir():
        return set()
    return {p.resolve() for p in output_dir.rglob("*") if p.is_file()}


def _new_files(output_dir: Path, before: set[Path]) -> list[Path]:
    """実行後に増えた output/ 配下ファイルをソートして返す。"""
    if not output_dir.is_dir():
        return []
    after = [p.resolve() for p in output_dir.rglob("*") if p.is_file()]
    return sorted(p for p in after if p not in before)


def _safe_new_files(job: Job, output_dir: Path, before: set[Path]) -> list[Path]:
    """Forum へ post してよい新規ファイルだけ返す。

    公開・通知するのは明示的に安全な成果物だけ。manifest・秘密・research・
    生ログはここで落とす（claim_url 等が外へ出ないように）。
    """
    from mihari_room.artifacts import _ALLOWED_WEB_EXT, _is_secret_name

    safe: list[Path] = []
    for path in _new_files(output_dir, before):
        try:
            rel = path.relative_to(output_dir.resolve())
        except ValueError:
            continue
        if any(part in ("", ".", "..") for part in rel.parts):
            continue
        if any(_is_secret_name(part) for part in rel.parts):
            continue
        # 恒久プレビューで出すので Forum にソースを添付しない。
        if rel.parts and rel.parts[0] == "artifact":
            continue
        if path.suffix.lower() not in _ALLOWED_WEB_EXT:
            continue
        if path.is_symlink():
            continue
        # manifest / registry 由来は通知しない。
        if path.name.endswith(".json") and "manifest" in path.name.lower():
            continue
        safe.append(path)
    _ = job  # 将来の job 単位 allowlist 用に引数だけ残す。
    return safe


class HermesWorker:
    """ジョブフォルダで Hermes を回す。Discord には出ない。"""

    def __init__(
        self,
        command: Sequence[str] | None = None,
        timeout: float = DEFAULT_TIMEOUT,
        *,
        agent_factory: AgentFactory | None = None,
    ) -> None:
        # command を渡すと subprocess。渡さなければ本家 AIAgent。
        self._command = tuple(command) if command is not None else None
        self._timeout = timeout
        self._agent_factory = agent_factory

    @property
    def command(self) -> tuple[str, ...] | None:
        """subprocess 経路のコマンド雛形。in-process のときは None。"""
        return self._command

    @property
    def timeout(self) -> float:
        """タイムアウト秒数。"""
        return self._timeout

    async def run(
        self,
        job: Job,
        on_progress: Callable[[ProgressEvent], Awaitable[None]],
    ) -> JobStatus:
        """ジョブフォルダを cwd に Hermes を実行し、進捗を流す。"""
        if self._command is not None:
            return await self._run_subprocess(job, on_progress)
        return await self._run_inprocess(job, on_progress)

    def request_cancel(self, job_id: str) -> bool:
        """実行中の worker thread に中断を頼む。届けば True。"""
        runner = getattr(self, "_runner", None)
        if runner is not None and hasattr(runner, "request_cancel"):
            try:
                return bool(runner.request_cancel(job_id))
            except Exception:
                return False
        return False

    def is_running(self, job_id: str) -> bool:
        runner = getattr(self, "_runner", None)
        if runner is not None and hasattr(runner, "is_running"):
            try:
                return bool(runner.is_running(job_id))
            except Exception:
                return False
        return False

    async def _run_inprocess(
        self,
        job: Job,
        on_progress: Callable[[ProgressEvent], Awaitable[None]],
    ) -> JobStatus:
        from mihari_room.worker.agent import InProcessHermes, build_turn_prompt

        output_dir = job.directory / OUTPUT_DIRNAME
        before = _snapshot_files(output_dir)
        runner = InProcessHermes(timeout=self._timeout, agent_factory=self._agent_factory)
        self._runner: Any = runner
        try:
            status = await runner.run(job, build_turn_prompt(job), on_progress)
        finally:
            self._runner = None
        if status is not JobStatus.DONE:
            return status
        for path in _safe_new_files(job, output_dir, before):
            await on_progress(ProgressEvent(kind=ProgressKind.FILE, text=path.name, path=path))
        return JobStatus.DONE

    async def _run_subprocess(
        self,
        job: Job,
        on_progress: Callable[[ProgressEvent], Awaitable[None]],
    ) -> JobStatus:
        assert self._command is not None
        prompt = build_prompt(job)
        cmd = [*self._command, prompt]
        output_dir = job.directory / OUTPUT_DIRNAME
        before = _snapshot_files(output_dir)

        # 現在の環境を引き継ぐ。トークン類はファイルに書かない（ここでは何も書かない）。
        env = dict(os.environ)

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=job.directory,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=env,
            )
        except (FileNotFoundError, OSError):
            return JobStatus.FAILED

        assert proc.stdout is not None
        speech_candidate: str | None = None

        async def _drain() -> int:
            nonlocal speech_candidate
            while True:
                raw = await proc.stdout.readline()
                if not raw:
                    break
                try:
                    line = raw.decode("utf-8", errors="replace")
                except Exception:
                    continue
                text = line.strip()
                if not text:
                    continue
                if is_log_line(text):
                    await on_progress(ProgressEvent(kind=ProgressKind.LOG, text=text))
                else:
                    speech_candidate = text
            return await proc.wait()

        try:
            returncode = await asyncio.wait_for(_drain(), timeout=self._timeout)
        except TimeoutError:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(proc.wait(), timeout=10)
            except TimeoutError:
                pass
            return JobStatus.FAILED

        if returncode != 0:
            return JobStatus.FAILED

        if speech_candidate:
            await on_progress(ProgressEvent(kind=ProgressKind.SPEECH, text=speech_candidate))

        for path in _safe_new_files(job, output_dir, before):
            await on_progress(ProgressEvent(kind=ProgressKind.FILE, text=path.name, path=path))
        return JobStatus.DONE
