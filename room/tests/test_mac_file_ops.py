"""ローカルファイル検索 / 取り込み / 手渡し（find_files / fetch_file / hand_off_file）のテスト。

hub 側のパラメータ検証（``_normalize_op``）と、ツール実装（``mac_find_files`` 系）の
結果の整え方を確かめる。実機の Spotlight / Finder には触れない（Mac 側はスタブ）。
"""

from __future__ import annotations

import base64
import json
from pathlib import Path
from typing import Any

import pytest

from mihari_room.mac_control import tools
from mihari_room.mac_control.errors import MacControlError, MacControlErrorCode
from mihari_room.mac_control.hub import MacControlHub, _normalize_op
from mihari_room.mac_control.protocol import describe_op, sanitize_op_params
from tests.mac_fakes import make_mac, make_run


def norm(kind: str, params: dict[str, Any]) -> dict[str, Any]:
    normalized, _ = _normalize_op(kind, params)
    return normalized


def norm_error(kind: str, params: dict[str, Any]) -> str:
    with pytest.raises(ValueError) as excinfo:
        _normalize_op(kind, params)
    return str(excinfo.value)


# --------------------------------------------------------------- _normalize_op


def test_find_files_defaults() -> None:
    normalized = norm("find_files", {"query": "  報告書  "})
    assert normalized["query"] == "報告書"
    assert normalized["scope"] == "name"
    assert normalized["limit"] == 10
    assert "dirs" not in normalized


def test_find_files_full_params() -> None:
    normalized = norm(
        "find_files",
        {
            "query": "invoice",
            "scope": "CONTENT",
            "limit": "25",
            "dirs": ["~/Documents", "/tmp/work"],
        },
    )
    assert normalized["scope"] == "content"
    assert normalized["limit"] == 25
    assert normalized["dirs"] == ["~/Documents", "/tmp/work"]


def test_find_files_limit_bounds() -> None:
    assert norm("find_files", {"query": "x", "limit": 1})["limit"] == 1
    assert norm("find_files", {"query": "x", "limit": 50})["limit"] == 50
    assert "limit" in norm_error("find_files", {"query": "x", "limit": 0})
    assert "limit" in norm_error("find_files", {"query": "x", "limit": 51})
    assert "limit" in norm_error("find_files", {"query": "x", "limit": True})
    assert "limit" in norm_error("find_files", {"query": "x", "limit": "abc"})


def test_find_files_query_and_scope_required() -> None:
    assert "query" in norm_error("find_files", {})
    assert "query" in norm_error("find_files", {"query": "   "})
    assert "query" in norm_error("find_files", {"query": "x" * 201})
    # 文字列以外は潰さず拒否する。
    assert "query" in norm_error("find_files", {"query": 123})
    assert "query" in norm_error("find_files", {"query": ["/a"]})
    assert "scope" in norm_error("find_files", {"query": "x", "scope": "everything"})


def test_find_files_dirs_validation() -> None:
    assert "dirs" in norm_error("find_files", {"query": "x", "dirs": "not-a-list"})
    assert "dirs" in norm_error("find_files", {"query": "x", "dirs": ["/a"] * 9})
    assert "dirs" in norm_error("find_files", {"query": "x", "dirs": [""]})
    assert "dirs" in norm_error("find_files", {"query": "x", "dirs": ["a" * 513]})
    # 文字列でない要素は拒否する。
    assert "dirs" in norm_error("find_files", {"query": "x", "dirs": [None]})
    assert "dirs" in norm_error("find_files", {"query": "x", "dirs": [123]})
    # 空リストは「全部探す」と同じ意味で受け付ける。
    assert norm("find_files", {"query": "x", "dirs": []})["dirs"] == []


def test_fetch_file_validation() -> None:
    normalized = norm("fetch_file", {"path": "~/Documents/a.pdf"})
    assert normalized["path"] == "~/Documents/a.pdf"
    assert normalized["max_bytes"] == 8_388_608
    assert norm("fetch_file", {"path": "/a", "max_bytes": 1})["max_bytes"] == 1
    assert norm("fetch_file", {"path": "/a", "max_bytes": 16_777_216})["max_bytes"] == 16_777_216
    assert "path" in norm_error("fetch_file", {})
    assert "path" in norm_error("fetch_file", {"path": " "})
    assert "path" in norm_error("fetch_file", {"path": "a" * 1025})
    # 文字列以外は str() で潰さず拒否する。
    assert "path" in norm_error("fetch_file", {"path": 123})
    assert "path" in norm_error("fetch_file", {"path": ["/a"]})
    assert "max_bytes" in norm_error("fetch_file", {"path": "/a", "max_bytes": 0})
    assert "max_bytes" in norm_error("fetch_file", {"path": "/a", "max_bytes": 16_777_217})
    assert "max_bytes" in norm_error("fetch_file", {"path": "/a", "max_bytes": True})


def test_hand_off_file_validation() -> None:
    normalized = norm("hand_off_file", {"path": "/tmp/a.txt"})
    assert normalized["path"] == "/tmp/a.txt"
    assert "label" not in normalized
    normalized = norm("hand_off_file", {"path": "/tmp/a.txt", "label": "  見つけたやつ  "})
    assert normalized["label"] == "見つけたやつ"
    # 空 label は落とす（Mac 側でファイル名に戻す）。
    assert norm("hand_off_file", {"path": "/tmp/a.txt", "label": "  "})["label"] is None
    assert "label" in norm_error("hand_off_file", {"path": "/tmp/a.txt", "label": "x" * 201})
    assert "label" in norm_error("hand_off_file", {"path": "/tmp/a.txt", "label": 42})
    assert "path" in norm_error("hand_off_file", {"label": "x"})
    assert "path" in norm_error("hand_off_file", {"path": 7})


# ----------------------------------------------------------- describe / sanitize


def test_describe_op_file_ops() -> None:
    assert "ファイルを探す" in describe_op("find_files", {"query": "請求書"})
    assert "請求書" in describe_op("find_files", {"query": "請求書"})
    assert "ファイルを取り込む" in describe_op("fetch_file", {"path": "/a/b.pdf"})
    assert "ファイルを手渡す" in describe_op("hand_off_file", {"path": "/a/b.pdf"})


def test_sanitize_op_params_file_ops() -> None:
    safe = sanitize_op_params(
        "find_files",
        {"query": "q", "scope": "name", "limit": 5, "dirs": ["/a"], "secret": "x"},
    )
    assert safe == {"query": "q", "scope": "name", "limit": 5, "dirs": ["/a"]}
    safe = sanitize_op_params("fetch_file", {"path": "/a", "max_bytes": 100, "x": 1})
    assert safe == {"path": "/a", "max_bytes": 100}
    safe = sanitize_op_params("hand_off_file", {"path": "/a", "label": "l", "x": 1})
    assert safe == {"path": "/a", "label": "l"}


# ------------------------------------------------------------- hub 経由の op


async def test_find_files_needs_no_capture_layout(tmp_path: Path) -> None:
    """ファイル系の op は撮影なしで実行できる（画面構成の突き合わせをしない）。"""
    hub = MacControlHub(permission_timeout=0.3, op_timeout=0.3, deadline=1.2)
    import asyncio

    hub.attach_loop(asyncio.get_running_loop())
    mac = await make_mac(hub)
    run_id = await make_run(hub, tmp_path)
    # capture していない状態でも find_files は走る。
    result = await hub._run_operation(
        job_id="job-1",
        run_id=run_id,
        kind="find_files",
        params={"query": "report"},
    )
    assert result["success"] is True
    sent = mac.received_ops[-1]
    assert sent["kind"] == "find_files"
    assert sent["params"]["query"] == "report"
    assert sent["params"]["scope"] == "name"
    assert sent["params"]["limit"] == 10
    assert sent["expected"] is None
    await mac.stop()


async def test_find_files_invalid_params_refused_before_send(tmp_path: Path) -> None:
    hub = MacControlHub(permission_timeout=0.3, op_timeout=0.3, deadline=1.2)
    import asyncio

    hub.attach_loop(asyncio.get_running_loop())
    mac = await make_mac(hub)
    run_id = await make_run(hub, tmp_path)
    with pytest.raises(MacControlError) as excinfo:
        await hub._run_operation(
            job_id="job-1",
            run_id=run_id,
            kind="find_files",
            params={"query": "x" * 300},
        )
    assert excinfo.value.code == MacControlErrorCode.INVALID_PARAMS
    assert mac.received_ops == []
    await mac.stop()


async def test_hand_off_file_result_summary(tmp_path: Path) -> None:
    """hand_off_file の結果は revealed / presented だけ履歴に残る。"""
    from mihari_room.mac_control import history as history_mod

    hub = MacControlHub(permission_timeout=0.3, op_timeout=0.3, deadline=1.2)
    import asyncio

    hub.attach_loop(asyncio.get_running_loop())

    mac = await make_mac(hub)

    async def _reply(h: Any, link: Any, frame: dict[str, Any]) -> None:
        await h.handle_frame(
            link,
            {
                "type": "op.result",
                "op_id": frame.get("op_id"),
                "run_id": frame.get("run_id"),
                "kind": frame.get("kind"),
                "ok": True,
                "result": {"revealed": True, "presented": True},
            },
        )

    mac.on_op = _reply
    run_id = await make_run(hub, tmp_path)
    result = await hub._run_operation(
        job_id="job-1",
        run_id=run_id,
        kind="hand_off_file",
        params={"path": "~/Documents/a.pdf", "label": "書類"},
    )
    assert result["success"] is True
    assert result["result"] == {"revealed": True, "presented": True}
    records = history_mod.read_history(tmp_path / "jobs" / "job-1")
    assert records[-1]["kind"] == "hand_off_file"
    assert records[-1]["result"] == {"revealed": True, "presented": True}
    assert records[-1]["params"] == {"path": "~/Documents/a.pdf", "label": "書類"}
    await mac.stop()


async def test_fetch_file_history_drops_data_base64(tmp_path: Path) -> None:
    """fetch_file の履歴にはファイル本体（data_base64）を残さない。"""
    from mihari_room.mac_control import history as history_mod

    hub = MacControlHub(permission_timeout=0.3, op_timeout=0.3, deadline=1.2)
    import asyncio

    hub.attach_loop(asyncio.get_running_loop())
    mac = await make_mac(hub)

    payload = base64.b64encode(b"hello").decode()

    async def _reply(h: Any, link: Any, frame: dict[str, Any]) -> None:
        await h.handle_frame(
            link,
            {
                "type": "op.result",
                "op_id": frame.get("op_id"),
                "run_id": frame.get("run_id"),
                "kind": frame.get("kind"),
                "ok": True,
                "result": {
                    "name": "a.txt",
                    "path": "/tmp/a.txt",
                    "size": 5,
                    "data_base64": payload,
                    "truncated": False,
                },
            },
        )

    mac.on_op = _reply
    run_id = await make_run(hub, tmp_path)
    result = await hub._run_operation(
        job_id="job-1",
        run_id=run_id,
        kind="fetch_file",
        params={"path": "/tmp/a.txt"},
    )
    assert result["success"] is True
    # 呼び出し側には本体が届く。
    assert result["result"]["data_base64"] == payload
    records = history_mod.read_history(tmp_path / "jobs" / "job-1")
    blob = json.dumps(records[-1])
    assert "data_base64" not in blob
    assert payload not in blob
    assert records[-1]["result"] == {
        "name": "a.txt",
        "path": "/tmp/a.txt",
        "size": 5,
        "truncated": False,
    }
    await mac.stop()


# ----------------------------------------------------------------- tools


class RecordingHub:
    """``run_operation`` を記録して決まった応答を返すスタブ（実 hub には触れない）。"""

    def __init__(
        self,
        result: dict[str, Any] | None = None,
        error: MacControlError | None = None,
    ) -> None:
        self.calls: list[dict[str, Any]] = []
        self.result = result or {"success": True, "op_id": "op-x", "kind": "", "result": {}}
        self.error = error

    def run_operation(
        self,
        *,
        job_id: str,
        run_id: str,
        kind: str,
        params: dict[str, Any],
        device_id: str | None = None,
    ) -> dict[str, Any]:
        self.calls.append(
            {
                "job_id": job_id,
                "run_id": run_id,
                "kind": kind,
                "params": params,
                "device_id": device_id,
            }
        )
        if self.error is not None:
            raise self.error
        return self.result


class FakeJob:
    def __init__(self, directory: Path, job_id: str = "job-1", run_id: str = "run-1") -> None:
        self.id = job_id
        self.directory = directory
        self._mac_run_id = run_id


def test_find_files_tool_formats_lines(tmp_path: Path) -> None:
    hub = RecordingHub(
        result={
            "success": True,
            "op_id": "op-1",
            "kind": "find_files",
            "result": {
                "count": 2,
                "files": [
                    {
                        "name": "report.pdf",
                        "path": "/Users/u/Documents/report.pdf",
                        "kind": "PDF",
                        "size": 2048,
                    },
                    {"name": "memo.txt", "path": "/Users/u/Desktop/memo.txt"},
                ],
            },
        }
    )
    job = FakeJob(tmp_path)
    out = json.loads(tools.mac_find_files_impl(hub, job, query="report", limit=5))
    assert hub.calls[0]["kind"] == "find_files"
    assert hub.calls[0]["params"] == {"query": "report", "limit": 5}
    assert out["success"] is True
    assert out["count"] == 2
    assert len(out["files"]) == 2
    lines = out["lines"].splitlines()
    assert lines[0] == "report.pdf — /Users/u/Documents/report.pdf（PDF, 2.0 KB）"
    assert lines[1] == "memo.txt — /Users/u/Desktop/memo.txt"


def test_find_files_tool_without_run_fails(tmp_path: Path) -> None:
    hub = RecordingHub()
    job = FakeJob(tmp_path, run_id="")
    out = json.loads(tools.mac_find_files_impl(hub, job, query="x"))
    assert out["success"] is False
    assert hub.calls == []


def test_fetch_file_tool_saves_to_downloads(tmp_path: Path) -> None:
    data = b"PDF%fake-body"
    hub = RecordingHub(
        result={
            "success": True,
            "op_id": "op-2",
            "kind": "fetch_file",
            "result": {
                "name": "../evil/../../etc/report final.pdf",
                "path": "/Users/u/Documents/report.pdf",
                "size": len(data),
                "data_base64": base64.b64encode(data).decode(),
                "truncated": False,
            },
        }
    )
    job_dir = tmp_path / "job-1"
    job_dir.mkdir()
    job = FakeJob(job_dir)
    out = json.loads(tools.mac_fetch_file_impl(hub, job, path="/Users/u/Documents/report.pdf"))
    assert hub.calls[0]["kind"] == "fetch_file"
    assert out["success"] is True
    saved = Path(out["saved_as"])
    assert saved.parts[0] == "research"
    # sanitize_filename でパス成分が潰されている。
    assert ".." not in out["saved_as"]
    written = job_dir / saved
    assert written.read_bytes() == data
    assert out["name"] == "report_final.pdf"
    assert out["truncated"] is False


def test_fetch_file_tool_same_name_gets_counter(tmp_path: Path) -> None:
    data = b"x"
    hub = RecordingHub(
        result={
            "success": True,
            "op_id": "op-3",
            "kind": "fetch_file",
            "result": {
                "name": "a.txt",
                "path": "/tmp/a.txt",
                "size": 1,
                "data_base64": base64.b64encode(data).decode(),
                "truncated": False,
            },
        }
    )
    job_dir = tmp_path / "job-1"
    (job_dir / "research" / "downloads").mkdir(parents=True)
    (job_dir / "research" / "downloads" / "a.txt").write_bytes(b"old")
    job = FakeJob(job_dir)
    out = json.loads(tools.mac_fetch_file_impl(hub, job, path="/tmp/a.txt"))
    assert out["success"] is True
    assert out["saved_as"] == "research/downloads/a-2.txt"
    # 既存ファイルは上書きしない。
    assert (job_dir / "research" / "downloads" / "a.txt").read_bytes() == b"old"


def test_fetch_file_tool_missing_body_fails(tmp_path: Path) -> None:
    hub = RecordingHub(
        result={
            "success": True,
            "op_id": "op-4",
            "kind": "fetch_file",
            "result": {"name": "a.txt", "path": "/a.txt", "size": 1},
        }
    )
    out = json.loads(tools.mac_fetch_file_impl(hub, FakeJob(tmp_path), path="/a.txt"))
    assert out["success"] is False
    assert out["code"] == "execution_failed"


def test_hand_off_file_tool_returns_flags(tmp_path: Path) -> None:
    hub = RecordingHub(
        result={
            "success": True,
            "op_id": "op-5",
            "kind": "hand_off_file",
            "result": {"revealed": True, "presented": True},
        }
    )
    out = json.loads(
        tools.mac_hand_off_file_impl(hub, FakeJob(tmp_path), path="/tmp/a.txt", label="書類")
    )
    assert hub.calls[0]["kind"] == "hand_off_file"
    assert hub.calls[0]["params"] == {"path": "/tmp/a.txt", "label": "書類"}
    assert out == {"success": True, "op_id": "op-5", "revealed": True, "presented": True}


def test_tools_propagate_mac_error(tmp_path: Path) -> None:
    hub = RecordingHub(error=MacControlError(MacControlErrorCode.DENIED, "拒否された"))
    for impl, kwargs in (
        (tools.mac_find_files_impl, {"query": "x"}),
        (tools.mac_fetch_file_impl, {"path": "/a"}),
        (tools.mac_hand_off_file_impl, {"path": "/a"}),
    ):
        out = json.loads(impl(hub, FakeJob(tmp_path), **kwargs))
        assert out["success"] is False
        assert out["code"] == MacControlErrorCode.DENIED
