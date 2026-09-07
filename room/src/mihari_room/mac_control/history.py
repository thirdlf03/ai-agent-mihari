"""ジョブ内の Mac 操作履歴。公開されない private 領域に書く。

置き場は ``jobs/<id>/.mac/operations.jsonl``。スクリーンショットは
``jobs/<id>/.mac/screens/<run_id>/<op_id>.png``。

- 成果物の自動公開（ArtifactPublisher）は ``output/artifact`` しか見ない
- Forum への自動投稿（``_safe_new_files``）は ``output/`` しか見ない
したがって画面・操作履歴は自動公開されない。
"""

from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path
from typing import Any

#: 仕事フォルダ直下の private 置き場。ドット始まりで公開経路から外す。
MAC_DIRNAME = ".mac"
SCREENS_DIRNAME = "screens"
HISTORY_FILENAME = "operations.jsonl"
#: いま走っている run（実行ラベル）の覚え書き。ツール実装の参照用。
CURRENT_RUN_FILENAME = "current_run"

#: 1 プロセスで append を直列化する鍵。
_WRITE_LOCK = threading.Lock()


def mac_dir(job_dir: Path) -> Path:
    return Path(job_dir) / MAC_DIRNAME


def screens_dir(job_dir: Path, run_id: str) -> Path:
    return mac_dir(job_dir) / SCREENS_DIRNAME / run_id


def history_path(job_dir: Path) -> Path:
    return mac_dir(job_dir) / HISTORY_FILENAME


def current_run_path(job_dir: Path) -> Path:
    return mac_dir(job_dir) / CURRENT_RUN_FILENAME


def write_current_run(job_dir: Path, run_id: str) -> None:
    """現在の run を覚える。ジョブフォルダ内のツール実装が参照できる。"""
    path = current_run_path(job_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, (run_id + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def read_current_run(job_dir: Path) -> str | None:
    """直近に走った run。無ければ None。"""
    path = current_run_path(job_dir)
    if path.is_file() and not path.is_symlink():
        try:
            value = path.read_text(encoding="utf-8").strip()
        except OSError:
            return None
        return value or None
    return None


def write_capture_image(job_dir: Path, run_id: str, op_id: str, png: bytes) -> Path:
    """撮影 PNG を private 領域へ置く。相対パスを返す。"""
    folder = screens_dir(job_dir, run_id)
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{op_id}.png"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, png)
    finally:
        os.close(fd)
    return path.relative_to(Path(job_dir).resolve())


def append_history(job_dir: Path, record: dict[str, Any]) -> None:
    """操作 1 件（終端状態）を追記する。既存行は変えない。"""
    path = history_path(job_dir)
    line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
    with _WRITE_LOCK:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)


def read_history(job_dir: Path) -> list[dict[str, Any]]:
    """履歴を追記順に返す。壊れた行は無視する。"""
    path = history_path(job_dir)
    if not path.is_file() or path.is_symlink():
        return []
    records: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    for raw in lines:
        try:
            records.append(json.loads(raw))
        except (ValueError, TypeError):
            continue
    return records


def last_unknown_signature(job_dir: Path, run_id: str) -> tuple[str, tuple] | None:
    """同じ run で最後に「結果不明」で終わった操作があれば返す。

    ``(kind, params_key)`` で返し、params_key は並べ替え済みの引数タプル。
    「結果不明のクリック・入力を自動再送しない」判定に使う。
    """
    for record in reversed(read_history(job_dir)):
        if record.get("run_id") != run_id:
            continue
        if record.get("status") != "unknown":
            continue
        kind = str(record.get("kind") or "")
        params = record.get("params") or {}
        if not kind:
            continue
        key = tuple(sorted((str(k), json.dumps(v, sort_keys=True)) for k, v in params.items()))
        return kind, key
    return None


def operation_record(
    *,
    op_id: str,
    run_id: str,
    job_id: str,
    kind: str,
    params_safe: dict[str, Any],
    status: str,
    error_code: str | None = None,
    error_message: str | None = None,
    result: dict[str, Any] | None = None,
    sent_at: str | None = None,
) -> dict[str, Any]:
    """履歴 1 行を作る。時刻は UTC 秒。"""
    return {
        "op_id": op_id,
        "run_id": run_id,
        "job_id": job_id,
        "kind": str(kind),
        "params": params_safe,
        "status": status,
        "error_code": error_code,
        "error_message": error_message,
        "result": result,
        "sent_at": sent_at,
        "resolved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
