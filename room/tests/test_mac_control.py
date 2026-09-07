"""依頼単位の Mac 操作（#23）の受け入れテスト。

hub の判定（許可・端末・画面構成・操作 ID・失効）を擬似 Mac で検証する。
実機専用のふるまい（クリック座標の物理実行など）はここでは扱わない。
"""

from __future__ import annotations

import asyncio
import base64
import json
import sys
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from mihari_room.artifacts import ArtifactPublisher
from mihari_room.config import TOKEN_HEADER, RoomConfig
from mihari_room.contracts import JobSource, JobStatus
from mihari_room.mac_control import history as history_mod
from mihari_room.mac_control.errors import MacControlError, MacControlErrorCode
from mihari_room.mac_control.hub import MacControlHub
from tests.mac_fakes import (
    TINY_PNG,
    FakeLink,
    FakeMac,
    default_displays,
    hello_frame,
    make_mac,
    make_run,
    run_capture,
)

TOKEN = "room-secret"


def make_hub(
    *,
    permission_timeout: float = 0.3,
    op_timeout: float = 0.3,
    deadline: float = 1.2,
) -> MacControlHub:
    hub = MacControlHub(
        permission_timeout=permission_timeout,
        op_timeout=op_timeout,
        deadline=deadline,
    )
    hub.attach_loop(asyncio.get_running_loop())
    return hub


async def wait_until(predicate: Any, timeout: float = 2.0) -> bool:
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        if predicate():
            return True
        await asyncio.sleep(0.02)
    return False


async def op_error(
    hub: MacControlHub,
    job_id: str,
    run_id: str,
    kind: str = "click",
    params: dict[str, Any] | None = None,
    device_id: str | None = None,
) -> str:
    with pytest.raises(MacControlError) as excinfo:
        await hub._run_operation(
            job_id=job_id,
            run_id=run_id,
            kind=kind,
            params=params or {},
            device_id=device_id,
        )
    return excinfo.value.code


# ---------------------------------------------------------------- hello / 端末


async def test_hello_registers_device_and_capabilities(tmp_path) -> None:
    hub = make_hub()
    assert hub.device_states() == []
    link = FakeLink()
    await hello_frame(link, hub)
    states = hub.device_states()
    assert len(states) == 1
    assert states[0]["device_id"] == "mac-1"
    assert states[0]["displays"][0]["width_px"] == 2880
    # ping に pong を返す。
    await hub.handle_frame(link, {"type": "ping"})
    pong = await link.next_frame()
    assert pong["type"] == "pong"


async def test_duplicate_hello_replaces_older_link(tmp_path) -> None:
    hub = make_hub()
    link1 = FakeLink(name="old")
    link2 = FakeLink(name="new")
    await hello_frame(link1, hub)
    await hello_frame(link2, hub)
    # 古いリンクは閉じられ、一覧は 1 台。
    assert len(hub.device_states()) == 1
    assert hub.device_states()[0]["device_id"] == "mac-1"
    assert link1.closed, "古い接続は閉じられる"
    await asyncio.sleep(0.05)
    assert len(hub.device_states()) == 1


async def test_op_without_device_fails(tmp_path) -> None:
    hub = make_hub()
    run_id = await make_run(hub, tmp_path)
    code = await op_error(hub, "job-1", run_id, kind="capture")
    assert code == MacControlErrorCode.NO_DEVICE


async def test_multiple_devices_require_device_id(tmp_path) -> None:
    hub = make_hub()
    link1, link2 = FakeLink(), FakeLink()
    await hello_frame(link1, hub, device_id="mac-a")
    await hello_frame(link2, hub, device_id="mac-b")
    run_id = await make_run(hub, tmp_path)
    code = await op_error(hub, "job-1", run_id, kind="capture")
    assert code == MacControlErrorCode.WRONG_DEVICE


async def test_wrong_device_refused_after_grant(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink())
    mac.start()
    await hello_frame(mac.link, hub, device_id="mac-a")
    run_id = await make_run(hub, tmp_path)
    result = await hub._run_operation(
        job_id="job-1", run_id=run_id, kind="capture", params={}, device_id="mac-a"
    )
    assert result["success"] is True
    # 別端末を指定した操作は拒否。
    code = await op_error(hub, "job-1", run_id, kind="capture", device_id="mac-b")
    assert code == MacControlErrorCode.WRONG_DEVICE
    await mac.stop()


# ------------------------------------------------------------------ 許可


async def test_permission_denied_refuses_before_sending_op(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink(), decision="deny")
    await hello_frame(mac.link, hub)
    mac.start()
    run_id = await make_run(hub, tmp_path)
    code = await op_error(hub, "job-1", run_id, kind="capture")
    assert code == MacControlErrorCode.DENIED
    # 操作フレームは端末に届いていない（許可を求めただけ）。
    assert mac.received_ops == []
    assert history_mod.read_history(tmp_path / "jobs" / "job-1") == []
    await mac.stop()


async def test_permission_timeout_defaults_to_deny(tmp_path) -> None:
    hub = make_hub(permission_timeout=0.15, deadline=0.8)
    link = FakeLink()
    await hello_frame(link, hub)
    run_id = await make_run(hub, tmp_path)
    code = await op_error(hub, "job-1", run_id, kind="capture")
    assert code == MacControlErrorCode.PERMISSION_TIMEOUT
    # 同じ run の次の操作は、ダイアログを出さずに即拒否（既定は無効）。
    code2 = await op_error(hub, "job-1", run_id, kind="capture")
    assert code2 == MacControlErrorCode.DENIED


async def test_allow_then_capture_stores_private_file(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink())
    await hello_frame(mac.link, hub)
    mac.start()
    run_id = await make_run(hub, tmp_path, title="画面を見て")
    result = await hub._run_operation(
        job_id="job-1", run_id=run_id, kind="capture", params={}, device_id=None
    )
    assert result["success"] is True
    payload = result["result"]
    assert payload["display_id"] == "1001"
    assert payload["width_px"] == 2880
    assert payload["path"].startswith(".mac/screens/")
    job_dir = tmp_path / "jobs" / "job-1"
    assert (job_dir / payload["path"]).is_file()
    # 履歴は private 領域にあり、撮影結果の要約だけ。
    records = history_mod.read_history(job_dir)
    assert len(records) == 1
    assert records[0]["kind"] == "capture"
    assert records[0]["status"] == "ok"
    assert "image_base64" not in json.dumps(records[0])
    # run に画面構成が残る。
    state = hub._runs[run_id]
    assert state.layouts["1001"]["width_px"] == 2880
    assert state.device_id == "mac-1"
    await mac.stop()


async def test_capture_followed_by_click_executes(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink())
    await hello_frame(mac.link, hub)
    mac.start()
    run_id = await make_run(hub, tmp_path)
    await hub._run_operation(job_id="job-1", run_id=run_id, kind="capture", params={})
    result = await hub._run_operation(
        job_id="job-1",
        run_id=run_id,
        kind="click",
        params={"display_id": "1001", "x": 100, "y": 100},
    )
    assert result["success"] is True
    sent = mac.received_ops[-1]
    assert sent["kind"] == "click"
    assert sent["expected"]["width_px"] == 2880
    await mac.stop()


async def test_click_without_capture_refused(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink())
    await hello_frame(mac.link, hub)
    mac.start()
    run_id = await make_run(hub, tmp_path)
    code = await op_error(
        hub,
        "job-1",
        run_id,
        kind="click",
        params={"display_id": "1001", "x": 10, "y": 10},
    )
    assert code == MacControlErrorCode.NO_CAPTURE
    assert mac.received_ops == []
    await mac.stop()


async def test_click_out_of_bounds_refused(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink())
    await hello_frame(mac.link, hub)
    mac.start()
    run_id = await make_run(hub, tmp_path)
    await hub._run_operation(job_id="job-1", run_id=run_id, kind="capture", params={})
    code = await op_error(
        hub,
        "job-1",
        run_id,
        kind="click",
        params={"display_id": "1001", "x": 99999, "y": 10},
    )
    assert code == MacControlErrorCode.STALE_LAYOUT
    await mac.stop()


async def test_stale_layout_after_display_change_refused(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink())
    await hello_frame(mac.link, hub)
    mac.start()
    run_id = await make_run(hub, tmp_path)
    await hub._run_operation(job_id="job-1", run_id=run_id, kind="capture", params={})
    # 撮影後に解像度が変わった（外部ディスプレイが抜けた）。
    changed = [
        {
            "display_id": "1001",
            "width_px": 1440,
            "height_px": 900,
            "scale": 1.0,
            "bounds": {"x": 0, "y": 0, "width": 1440, "height": 900},
        }
    ]
    await hub.handle_frame(
        mac.link,
        {"type": "displays", "displays": changed},
    )
    code = await op_error(
        hub,
        "job-1",
        run_id,
        kind="click",
        params={"display_id": "1001", "x": 100, "y": 100},
    )
    assert code == MacControlErrorCode.STALE_LAYOUT
    # 撮り直せばまた操作できる。
    result = await hub._run_operation(job_id="job-1", run_id=run_id, kind="capture", params={})
    assert result["success"] is True
    await mac.stop()


async def test_missing_display_after_change_refused(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink())
    await hello_frame(mac.link, hub)
    mac.start()
    run_id = await make_run(hub, tmp_path)
    # 撮影して画面構成を覚えさせる。
    assert (await hub._run_operation(job_id="job-1", run_id=run_id, kind="capture", params={}))[
        "success"
    ]
    # 表示器が消えた。
    await hub.handle_frame(mac.link, {"type": "displays", "displays": []})
    code = await op_error(
        hub,
        "job-1",
        run_id,
        kind="click",
        params={"display_id": "1001", "x": 5, "y": 5},
    )
    assert code == MacControlErrorCode.STALE_LAYOUT
    await mac.stop()


# ----------------------------------------------------------- 操作 ID・同時実行


async def _silent(_hub: Any, _link: Any, _frame: dict[str, Any]) -> None:
    """FakeMac に応答させない（結果不明を作る）ための on_op。"""
    return None


async def test_result_unknown_op_is_never_auto_resent(tmp_path) -> None:
    hub = make_hub(deadline=0.6)
    mac = await make_mac(hub)
    run_id = await make_run(hub, tmp_path)
    assert (await run_capture(mac, hub, run_id))["success"]
    mac.on_op = _silent  # クリックは応答しない → 結果不明
    task = asyncio.create_task(
        hub._run_operation(
            job_id="job-1",
            run_id=run_id,
            kind="click",
            params={"display_id": "1001", "x": 10, "y": 10},
        )
    )
    await wait_until(lambda: hub._link_by_device("mac-1").inflight is not None)
    with pytest.raises(MacControlError) as excinfo:
        await task
    assert excinfo.value.code == MacControlErrorCode.UNKNOWN_OUTCOME
    # 同じ操作をもう一度送ろうとしたら拒否（自動再送しない）。
    code = await op_error(
        hub,
        "job-1",
        run_id,
        kind="click",
        params={"display_id": "1001", "x": 10, "y": 10},
    )
    assert code == MacControlErrorCode.DUPLICATE_OP
    # 違う操作は、応答待ちが残っている間は 1 操作制限で拒否。
    code2 = await op_error(
        hub,
        "job-1",
        run_id,
        kind="click",
        params={"display_id": "1001", "x": 10, "y": 11},
    )
    assert code2 == MacControlErrorCode.BUSY
    await mac.stop()


async def test_one_operation_at_a_time_busy(tmp_path) -> None:
    hub = make_hub(deadline=3.0)
    mac = await make_mac(hub)
    run_id = await make_run(hub, tmp_path)
    mac.on_op = _silent  # 撮影を応答しないまま inflight を作る
    task = asyncio.create_task(
        hub._run_operation(job_id="job-1", run_id=run_id, kind="capture", params={})
    )
    await wait_until(lambda: hub._link_by_device("mac-1").inflight is not None)
    code = await op_error(hub, "job-1", run_id, kind="key", params={"key": "return"})
    assert code == MacControlErrorCode.BUSY
    # 応答を返すと 1 本目が完了する。
    inflight = hub._link_by_device("mac-1").inflight
    assert inflight is not None
    display = default_displays()[0]
    await hub.handle_frame(
        mac.link,
        {
            "type": "op.result",
            "op_id": inflight.op_id,
            "run_id": run_id,
            "kind": "capture",
            "ok": True,
            "result": {
                "display_id": display["display_id"],
                "width_px": display["width_px"],
                "height_px": display["height_px"],
                "scale": display["scale"],
                "bounds": display["bounds"],
                "layout_token": "tok-abc",
                "image_base64": TINY_PNG,
            },
        },
    )
    result = await task
    assert result["success"] is True
    await mac.stop()


async def test_dispatched_ops_have_unique_ids(tmp_path) -> None:
    """操作ごとに一意な op_id が振られ、線上の二重実行を防ぐ。"""
    hub = make_hub()
    mac = await make_mac(hub)
    run_id = await make_run(hub, tmp_path)
    assert (await run_capture(mac, hub, run_id))["success"]
    result = await hub._run_operation(
        job_id="job-1",
        run_id=run_id,
        kind="click",
        params={"display_id": "1001", "x": 5, "y": 5},
    )
    op_ids = [f["op_id"] for f in mac.received_ops]
    assert len(op_ids) == 2
    assert len(set(op_ids)) == 2  # capture と click は別の op_id
    assert result["op_id"] == op_ids[-1]
    await mac.stop()


# ------------------------------------------------------- 失効（lock/quit/cancel）


async def test_lock_revokes_and_blocks_further_ops(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink())
    await hello_frame(mac.link, hub)
    mac.start()
    run_id = await make_run(hub, tmp_path)
    await hub._run_operation(job_id="job-1", run_id=run_id, kind="capture", params={})
    sent_before = len(mac.received_ops)
    # ロックが届く。
    await hub.handle_frame(mac.link, {"type": "state", "event": "lock"})
    code = await op_error(
        hub,
        "job-1",
        run_id,
        kind="click",
        params={"display_id": "1001", "x": 10, "y": 10},
    )
    assert code == MacControlErrorCode.PERMISSION_LOST
    assert len(mac.received_ops) == sent_before  # 追加操作は走らない
    # アンロックすると再許可を求め、FakeMac が allow するので操作できる。
    await hub.handle_frame(mac.link, {"type": "state", "event": "unlock"})
    result = await hub._run_operation(
        job_id="job-1",
        run_id=run_id,
        kind="click",
        params={"display_id": "1001", "x": 10, "y": 10},
    )
    assert result["success"] is True
    await mac.stop()


async def test_disconnect_revokes_and_reconnect_does_not_resend(tmp_path) -> None:
    hub = make_hub(deadline=0.6)
    mac = await make_mac(hub)
    run_id = await make_run(hub, tmp_path)
    assert (await run_capture(mac, hub, run_id))["success"]
    mac.on_op = _silent  # クリックは応答しない → 結果不明
    task = asyncio.create_task(
        hub._run_operation(
            job_id="job-1",
            run_id=run_id,
            kind="click",
            params={"display_id": "1001", "x": 10, "y": 10},
        )
    )
    await wait_until(lambda: hub._link_by_device("mac-1").inflight is not None)
    # 実行中に切断 → 応答は来ないので結果不明。
    await hub.close_link(mac.link, "wifi lost")
    with pytest.raises(MacControlError) as excinfo:
        await task
    assert excinfo.value.code == MacControlErrorCode.UNKNOWN_OUTCOME
    await mac.stop()
    job_dir = tmp_path / "jobs" / "job-1"
    records = history_mod.read_history(job_dir)
    assert records[-1]["status"] == "unknown"
    assert records[-1]["error_code"] == MacControlErrorCode.UNKNOWN_OUTCOME

    # 同じ Mac が張り直しても、不明操作は再送されない。
    mac2 = FakeMac(hub, FakeLink())
    await hello_frame(mac2.link, hub, device_id="mac-1")
    code = await op_error(
        hub,
        "job-1",
        run_id,
        kind="click",
        params={"display_id": "1001", "x": 10, "y": 10},
    )
    assert code == MacControlErrorCode.DUPLICATE_OP
    assert mac2.received_ops == []
    # 別の操作は再許可（フォローアップの再許可）を経て実行できる。
    mac2.start()
    result2 = await hub._run_operation(
        job_id="job-1",
        run_id=run_id,
        kind="click",
        params={"display_id": "1001", "x": 10, "y": 11},
    )
    assert result2["success"] is True
    await mac2.stop()


async def test_cancel_discards_waiting_op_and_revokes(tmp_path) -> None:
    hub = make_hub(permission_timeout=5.0, deadline=5.0)
    link = FakeLink()
    await hello_frame(link, hub)
    run_id = await make_run(hub, tmp_path)
    # 許可待ちのまま止める。
    task = asyncio.create_task(
        hub._run_operation(job_id="job-1", run_id=run_id, kind="capture", params={})
    )
    await wait_until(lambda: hub._permission_waits.get(("mac-1", run_id)) is not None)
    hub.cancel_job("job-1")
    with pytest.raises(MacControlError) as excinfo:
        await task
    assert excinfo.value.code == MacControlErrorCode.CANCELLED
    # 中断後は追加操作が走らない。
    code = await op_error(hub, "job-1", run_id, kind="capture")
    assert code == MacControlErrorCode.CANCELLED
    assert hub._link_by_device("mac-1").inflight is None
    # 端末には操作フレームは 1 本も送られていない。
    outbox: list[dict[str, Any]] = []
    while not link.outbox.empty():
        outbox.append(link.outbox.get_nowait())
    assert all(f.get("type") != "op" for f in outbox)


async def test_cancel_marks_inflight_unknown_and_notifies_device(tmp_path) -> None:
    hub = make_hub(deadline=5.0)
    link = FakeLink()
    await hello_frame(link, hub)
    run_id = await make_run(hub, tmp_path)
    link_state = hub._link_by_device("mac-1")
    from mihari_room.mac_control.hub import PermissionGrant

    link_state.permissions[run_id] = PermissionGrant(decision="allow", decided_at="now")
    task = asyncio.create_task(
        hub._run_operation(job_id="job-1", run_id=run_id, kind="key", params={"key": "return"})
    )
    await wait_until(lambda: link_state.inflight is not None)
    hub.cancel_job("job-1")
    with pytest.raises(MacControlError) as excinfo:
        await task
    assert excinfo.value.code == MacControlErrorCode.CANCELLED
    # 端末に cancel_run が届き、履歴は canceled。
    frames = []
    while not link.outbox.empty():
        frames.append(link.outbox.get_nowait())
    assert any(f.get("type") == "cancel_run" for f in frames)
    records = history_mod.read_history(tmp_path / "jobs" / "job-1")
    assert records[-1]["status"] == "canceled"


async def test_followup_new_run_requires_new_permission(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink())
    await hello_frame(mac.link, hub)
    mac.start()
    run1 = await make_run(hub, tmp_path)
    assert (await hub._run_operation(job_id="job-1", run_id=run1, kind="capture", params={}))[
        "success"
    ]
    # run が終わった（許可は失効）。
    await hub._end_run(job_id="job-1", run_id=run1, reason="完了")
    # followup = 新しい run。もう一度許可を求めて（FakeMac が自動 allow）実行できる。
    run2 = await make_run(hub, tmp_path)
    capture = await hub._run_operation(job_id="job-1", run_id=run2, kind="capture", params={})
    assert capture["success"] is True
    await mac.stop()


# ------------------------------------------------------------- run / job 照合


async def test_wrong_job_refused(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink())
    await hello_frame(mac.link, hub)
    mac.start()
    run_id = await make_run(hub, tmp_path, job_id="job-1")
    # run は job-1 のもの。job-2 を名乗る操作は拒否。
    code = await op_error(hub, "job-2", run_id, kind="capture")
    assert code == MacControlErrorCode.UNKNOWN_RUN
    await mac.stop()


async def test_end_run_revokes_grant(tmp_path) -> None:
    hub = make_hub()
    mac = FakeMac(hub, FakeLink())
    await hello_frame(mac.link, hub)
    mac.start()
    run_id = await make_run(hub, tmp_path)
    await hub._run_operation(job_id="job-1", run_id=run_id, kind="capture", params={})
    assert hub._link_by_device("mac-1").permissions.get(run_id) is not None
    await hub._end_run(job_id="job-1", run_id=run_id, reason="完了")
    await asyncio.sleep(0.05)
    link = hub._link_by_device("mac-1")
    assert link is not None
    assert run_id not in link.permissions
    assert run_id not in hub._runs
    await mac.stop()


# ------------------------------------------------------------------- 公開されない


def test_capture_and_history_never_auto_published(tmp_path: Path) -> None:
    """撮影・履歴は jobs/<id>/.mac に置かれ、プレビュー公開に載らない。"""
    from mihari_room.contracts import Job

    job_dir = tmp_path / "jobs" / "job-x"
    output = job_dir / "output" / "artifact"
    output.mkdir(parents=True)
    (output / "index.html").write_text("<h1>成果物</h1>", encoding="utf-8")
    (job_dir / ".mac" / "screens" / "run-1").mkdir(parents=True)
    (job_dir / ".mac" / "screens" / "run-1" / "op.png").write_bytes(base64.b64decode(TINY_PNG))
    history_mod.append_history(
        job_dir,
        {
            "op_id": "op-1",
            "run_id": "run-1",
            "job_id": "job-x",
            "kind": "click",
            "params": {},
            "status": "ok",
            "result": {},
        },
    )
    job = Job(
        id="job-x",
        title="t",
        body="b",
        status=JobStatus.DONE,
        source=JobSource.FORUM,
        directory=job_dir,
        thread_id=1,
    )
    publisher = ArtifactPublisher(root=tmp_path, preview_base_url="https://p.example.test")
    manifest = publisher.publish(job)
    assert manifest is not None
    token = manifest["preview_url"].rstrip("/").rsplit("/", 1)[-1]
    published = sorted(
        p.relative_to(tmp_path / "previews" / token).as_posix()
        for p in (tmp_path / "previews" / token).rglob("*")
        if p.is_file()
    )
    assert published == ["index.html"]
    assert not (tmp_path / "previews" / token / ".mac").exists()


# --------------------------------------------------------------------- tools


def test_mac_tools_schema_and_names(monkeypatch: pytest.MonkeyPatch) -> None:
    from mihari_room.mac_control import tools

    assert tools.TOOL_NAMES == (
        "mac_capture",
        "mac_click",
        "mac_double_click",
        "mac_drag",
        "mac_scroll",
        "mac_type_text",
        "mac_key",
        "mac_activate_app",
    )
    for name in tools.TOOL_NAMES:
        schema = tools._SCHEMAS[name]
        assert schema["type"] == "function"
        assert schema["function"]["name"] == name
        assert "parameters" in schema["function"]
    # registry が無い環境（テスト）では何も登録しない。
    monkeypatch.setitem(sys.modules, "tools", None)
    monkeypatch.setitem(sys.modules, "tools.registry", None)
    assert tools.register_mac_tools(object(), None, "run-1") is None


def test_describe_op_redacts_typed_text() -> None:
    from mihari_room.mac_control.protocol import describe_op, sanitize_op_params

    safe = sanitize_op_params("type_text", {"text": "内緒のパスワード123"})
    assert safe.get("text_len") == 11
    assert "text" not in safe
    description = describe_op("type_text", {"text": "あいうえお"})
    assert "文字入力" in description
    assert "あいうえお" in description  # 先頭 40 字までのプレビューは可


def test_describe_op_click() -> None:
    from mihari_room.mac_control.protocol import describe_op

    text = describe_op("click", {"display_id": "1001", "x": 12, "y": 34})
    assert "クリック" in text and "1001" in text


# ---------------------------------------------------------------- app エンドポイント


def test_capabilities_endpoint(tmp_path: Path) -> None:
    from mihari_room.app import create_app
    from mihari_room.orchestrator import RoomOrchestrator
    from mihari_room.queue.file_queue import FileJobQueue
    from mihari_room.store.file_store import FileJobStore
    from tests.recording import RecordingBoard, ScriptedWorker

    board = RecordingBoard()
    store = FileJobStore(tmp_path)
    worker = ScriptedWorker([])
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id="owner"), board, worker)
    app = create_app(
        RoomConfig(token=TOKEN, root=tmp_path, owner_id="owner"), orch, start_pump=False
    )
    client = TestClient(app)
    assert client.get("/capabilities").status_code == 401
    body = client.get("/capabilities", headers={TOKEN_HEADER: TOKEN}).json()
    assert body["mac_control"] is True
    assert "mac_capture" in body["tools"]
    assert client.get("/mac/devices", headers={TOKEN_HEADER: TOKEN}).json() == {"devices": []}


def test_websocket_endpoint_requires_token_and_registers_device(tmp_path: Path) -> None:
    from mihari_room.app import create_app
    from mihari_room.orchestrator import RoomOrchestrator
    from mihari_room.queue.file_queue import FileJobQueue
    from mihari_room.store.file_store import FileJobStore
    from tests.recording import RecordingBoard, ScriptedWorker

    board = RecordingBoard()
    store = FileJobStore(tmp_path)
    orch = RoomOrchestrator(store, FileJobQueue(store, owner_id="owner"), board, ScriptedWorker([]))
    app = create_app(
        RoomConfig(token=TOKEN, root=tmp_path, owner_id="owner"), orch, start_pump=False
    )
    hub = app.state.mac_control
    with TestClient(app) as client:
        # トークン無しは拒否。
        with pytest.raises((RuntimeError, WebSocketDisconnect)):
            with client.websocket_connect("/ws/mac-control"):
                pass
        # トークン付きで hello → ack。
        with client.websocket_connect(
            "/ws/mac-control", headers={TOKEN_HEADER: TOKEN}
        ) as websocket:
            websocket.send_json(
                {
                    "type": "hello",
                    "device_id": "mac-ws-1",
                    "hostname": "ws-mac",
                    "app_version": "1.0",
                    "os_version": "15",
                    "displays": default_displays(),
                }
            )
            ack = websocket.receive_json()
            assert ack["type"] == "hello_ack"
            assert ack["device_id"] == "mac-ws-1"
            devices = client.get("/mac/devices", headers={TOKEN_HEADER: TOKEN}).json()
            assert [d["device_id"] for d in devices["devices"]] == ["mac-ws-1"]
            # 切断で hub から消える。
        import time

        deadline = time.monotonic() + 3
        while hub.device_states() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert hub.device_states() == []
