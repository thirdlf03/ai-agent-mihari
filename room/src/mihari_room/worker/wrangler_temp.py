"""Bounded ``wrangler deploy --temporary`` for backend-backed previews.

静的 HTML の恒久共有は Room の ArtifactPublisher。こちらは Worker / D1 / KV /
DO などバックエンド付きの 60 分動作確認専用。フル shell は開けない。

- cwd はジョブフォルダの内側だけ
- 一時 credential は ``<job>/.wrangler-tmp``（XDG_CONFIG_HOME）に閉じる
- claim URL は bearer。ツール戻り値・Forum・日誌本文には出さない
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import subprocess
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

logger = logging.getLogger("mihari_room")

TOOLSET_NAME = "mihari_room"
TOOL_NAME = "cloudflare_temp_deploy"
TEMP_DEPLOY_FILENAME = "temp_deploy.json"
WRANGLER_TMP_DIRNAME = ".wrangler-tmp"
CLAIM_WINDOW_MINUTES = 60
DEPLOY_TIMEOUT_SEC = 180

_CF_ENV_UNSET = (
    "CLOUDFLARE_API_TOKEN",
    "CLOUDFLARE_API_KEY",
    "CLOUDFLARE_ACCOUNT_ID",
    "CF_API_TOKEN",
    "CF_API_KEY",
)

_WORKERS_DEV = re.compile(r"https://[A-Za-z0-9._-]+\.workers\.dev(?:/[^\s'\"<>]*)?", re.I)
_CLAIM_URL = re.compile(
    r"https://dash\.cloudflare\.com/claim-preview\?claimToken=[A-Za-z0-9._~+/-]+",
    re.I,
)

Runner = Callable[..., tuple[int, str, str]]


def _tool_args(args: Any, kwargs: dict[str, Any]) -> dict[str, Any]:
    """Hermes は ``handler(args_dict, **kwargs)``。kwargs 専用だと TypeError になる。"""
    merged: dict[str, Any] = {}
    if isinstance(args, dict):
        merged.update(args)
    merged.update(kwargs)
    return merged


class TempDeployError(RuntimeError):
    """wrangler 一時デプロイがジョブ内で完結しなかった。"""


def temp_deploys_for(job_dir: Path) -> list[dict[str, Any]]:
    """GET /jobs 向け。認証済みなので claim_url を含めて返す。"""
    path = Path(job_dir) / TEMP_DEPLOY_FILENAME
    if path.is_symlink() or not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return []
    deploys = data.get("deploys") if isinstance(data, dict) else None
    if not isinstance(deploys, list):
        return []
    out: list[dict[str, Any]] = []
    for item in deploys:
        if isinstance(item, dict) and item.get("preview_url"):
            out.append(item)
    return out


def save_temp_deploy(job_dir: Path, record: dict[str, Any]) -> None:
    path = Path(job_dir) / TEMP_DEPLOY_FILENAME
    if path.is_symlink():
        raise TempDeployError("temp_deploy.json の symlink を拒否")
    existing = temp_deploys_for(job_dir)
    existing.append(record)
    payload = json.dumps({"deploys": existing}, ensure_ascii=False, indent=2) + "\n"
    path.write_text(payload, encoding="utf-8")


def parse_wrangler_output(text: str) -> dict[str, str]:
    """stdout/stderr から workers.dev と claim URL を拾う。"""
    blob = text or ""
    workers = _WORKERS_DEV.findall(blob)
    claims = _CLAIM_URL.findall(blob)
    preview = workers[-1].rstrip(".,)") if workers else ""
    claim = claims[-1].rstrip(".,)") if claims else ""
    return {"preview_url": preview, "claim_url": claim}


def resolve_workdir(job_dir: Path, subdir: str = ".") -> Path:
    root = Path(job_dir).resolve()
    raw = (subdir or ".").strip() or "."
    if Path(raw).is_absolute():
        raise TempDeployError("subdir はジョブ内の相対パスだけ")
    dest = (root / raw).resolve()
    if not dest.is_relative_to(root):
        raise TempDeployError("ジョブの外へは出ない")
    node = dest
    for _ in range(len(dest.parts) + 1):
        if node.is_symlink():
            raise TempDeployError("symlink は使わない")
        if node == root:
            break
        node = node.parent
    if not dest.exists():
        try:
            listing = ", ".join(sorted(p.name for p in root.iterdir())[:20]) or "(empty)"
        except OSError:
            listing = "(unreadable)"
        raise TempDeployError(
            f"作業ディレクトリが無い: {raw}。"
            f"このジョブ直下: [{listing}]。"
            "他ジョブの worker/ は使えない。先にこのジョブへ wrangler.toml を書いてから呼ぶこと。"
        )
    if not dest.is_dir():
        raise TempDeployError("subdir はディレクトリ")
    return dest


def _latest_wrangler_log(job_dir: Path) -> str:
    """WRANGLER_LOG が静かでも、ログファイルに workers.dev が残ることがある。"""
    logs = (Path(job_dir) / WRANGLER_TMP_DIRNAME / ".wrangler" / "logs").resolve()
    root = Path(job_dir).resolve()
    if not logs.is_dir() or not logs.is_relative_to(root):
        return ""
    files = sorted(
        (path for path in logs.glob("wrangler-*.log") if path.is_file() and not path.is_symlink()),
        key=lambda path: path.stat().st_mtime,
    )
    if not files:
        return ""
    try:
        return files[-1].read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _isolated_env(job_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    for key in _CF_ENV_UNSET:
        env.pop(key, None)
    xdg = (Path(job_dir) / WRANGLER_TMP_DIRNAME).resolve()
    xdg.mkdir(parents=True, exist_ok=True)
    cache = xdg / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    env["XDG_CONFIG_HOME"] = str(xdg)
    env["XDG_STATE_HOME"] = str(xdg)
    env["XDG_CACHE_HOME"] = str(cache)
    env["HOME"] = str(xdg)
    # error にすると workers.dev / claim URL が stdout に出ず、失敗扱いにする。
    env.pop("WRANGLER_LOG", None)
    return env


def _wrangler_argv() -> list[str]:
    explicit = (os.environ.get("MIHARI_WRANGLER") or "").strip()
    if explicit:
        return [explicit, "deploy", "--temporary"]
    found = shutil.which("wrangler")
    if found:
        return [found, "deploy", "--temporary"]
    return ["npx", "--yes", "wrangler@4.102.0", "deploy", "--temporary"]


def _default_runner(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: float,
) -> tuple[int, str, str]:
    completed = subprocess.run(  # noqa: S603 — argv は固定。ユーザー入力は載せない
        argv,
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    return completed.returncode, completed.stdout or "", completed.stderr or ""


def run_temp_deploy(
    job_dir: Path,
    *,
    subdir: str = ".",
    runner: Runner | None = None,
    timeout: float = DEPLOY_TIMEOUT_SEC,
) -> dict[str, Any]:
    """ジョブ内で ``wrangler deploy --temporary`` を回し、パース結果を返す。"""
    workdir = resolve_workdir(job_dir, subdir)
    env = _isolated_env(job_dir)
    argv = _wrangler_argv()
    run = runner or _default_runner
    try:
        code, stdout, stderr = run(argv, cwd=workdir, env=env, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise TempDeployError("wrangler が時間切れ") from error
    parsed = parse_wrangler_output(f"{stdout}\n{stderr}\n{_latest_wrangler_log(job_dir)}")
    if code != 0 or not parsed["preview_url"]:
        detail = " ".join((stderr or stdout or "").split())
        detail = _CLAIM_URL.sub("[claim omitted]", detail)[:240]
        raise TempDeployError("一時デプロイに失敗した" + (f": {detail}" if detail else ""))
    expires = datetime.now(UTC) + timedelta(minutes=CLAIM_WINDOW_MINUTES)
    return {
        "preview_url": parsed["preview_url"],
        "claim_url": parsed["claim_url"],
        "expires_at": expires.isoformat(timespec="seconds"),
        "created_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "workdir": str(workdir.relative_to(Path(job_dir).resolve())),
    }


def _emit_temp_deploy_event(job: Any, preview_url: str) -> None:
    try:
        from mihari_room.events import EventJournal, EventPhase, JournalKind

        journal = EventJournal.for_job(Path(job.directory))
        journal.append(
            job_id=job.id,
            phase=EventPhase.DEPLOYING,
            kind=JournalKind.TEMP_DEPLOY,
            text=f"一時デプロイしたよ: {preview_url}（claim は詳細パネル）",
        )
    except Exception:
        logger.debug("temp deploy journal append failed", exc_info=True)


def cloudflare_temp_deploy_impl(job: Any, subdir: str = ".", runner: Runner | None = None) -> str:
    """Hermes 向け。成功時も claim URL は返さない。"""
    try:
        record = run_temp_deploy(Path(job.directory), subdir=subdir, runner=runner)
        save_temp_deploy(Path(job.directory), record)
        _emit_temp_deploy_event(job, record["preview_url"])
    except TempDeployError as error:
        return json.dumps({"success": False, "error": str(error)}, ensure_ascii=False)
    except Exception as error:
        logger.debug("temp deploy failed", exc_info=True)
        return json.dumps({"success": False, "error": str(error)}, ensure_ascii=False)
    return json.dumps(
        {
            "success": True,
            "preview_url": record["preview_url"],
            "expires_at": record["expires_at"],
            "claim": "owner のペット詳細に出した。Forum や成果物に書かないこと。",
        },
        ensure_ascii=False,
    )


_SCHEMA: dict[str, Any] = {
    "type": "function",
    "function": {
        "name": TOOL_NAME,
        "description": (
            "Worker や D1/KV/DO などバックエンド付きのものを一時アカウントへデプロイする。"
            "静的 HTML/CSS/JS のモックは output/artifact に書いて Room に公開させる。"
            "本番 Cloudflare アカウントへはデプロイしない。claim URL は Room が owner に渡す。"
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "subdir": {
                    "type": "string",
                    "description": "ジョブ内の Worker プロジェクト相対パス（省略時はジョブ直下）",
                    "default": ".",
                },
            },
        },
    },
}


def make_temp_deploy_handler(job: Any, *, runner: Runner | None = None):
    """Hermes ``handler(args_dict, **kwargs)`` 契約。"""

    def handler(args: Any = None, **kwargs: Any) -> str:
        merged = _tool_args(args, kwargs)
        return cloudflare_temp_deploy_impl(job, merged.get("subdir", "."), runner=runner)

    return handler


def register_temp_deploy_tool(
    job: Any, *, runner: Runner | None = None
) -> Callable[[], None] | None:
    """Register ``cloudflare_temp_deploy`` on the real Hermes registry."""
    try:
        from tools.registry import registry
    except ImportError:
        return None

    handler = make_temp_deploy_handler(job, runner=runner)
    try:
        registry.register(
            TOOL_NAME,
            TOOLSET_NAME,
            _SCHEMA,
            handler,
            description=_SCHEMA["function"]["description"],
            emoji="☁️",
        )
    except TypeError:
        raise
    except Exception:
        logger.debug("temp deploy tool already registered", exc_info=True)
        return None

    def restore() -> None:
        try:
            from tools.registry import registry as live
        except ImportError:
            return
        try:
            live.deregister(TOOL_NAME)
        except Exception:
            pass

    return restore
