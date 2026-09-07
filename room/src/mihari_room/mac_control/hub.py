"""Mac 操作の取りまとめ役（Room 側の正本）。

- ジョブ（job）・実行（run）・端末（device）・許可（permission）・操作 ID（op_id）
  を紐付け、一度に 1 操作だけを Mac へ送る。
- 操作は Room 専用ツール（``mac_*``）経由でしか来ない。汎用 Computer Use や
  shell の一括有効化はしない。
- 許可は run 単位（依頼ごと）。既定は無効。切断・キャンセル・ロック・アプリ終了で
  失効し、再接続・followup では再許可する。
- 結果不明の操作は自動再送しない（同じ操作の再送は hub が拒否する）。
- スクリーンショットと操作履歴は ``jobs/<id>/.mac`` に置き、自動公開しない。
"""

from __future__ import annotations

import asyncio
import base64
import concurrent.futures
import logging
import threading
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from uuid import uuid4

from mihari_room.mac_control import history as history_mod
from mihari_room.mac_control.display import (
    DisplayGeometryError,
    check_layout_matches,
    normalize_displays,
)
from mihari_room.mac_control.errors import MacControlError, MacControlErrorCode
from mihari_room.mac_control.protocol import (
    DECISION_ALLOW,
    DECISION_DENY,
    FRAME_CANCEL_RUN,
    FRAME_CONTROL_DECISION,
    FRAME_CONTROL_REQUEST,
    FRAME_DISPLAYS,
    FRAME_HELLO,
    FRAME_HELLO_ACK,
    FRAME_OP,
    FRAME_OP_RESULT,
    FRAME_PING,
    FRAME_PONG,
    FRAME_STATE,
    MacOpKind,
    describe_op,
    sanitize_op_params,
    validate_display_id,
)

logger = logging.getLogger("mihari_room")

#: 既定の待ち時間。
DEFAULT_PERMISSION_TIMEOUT_SEC = 120.0
DEFAULT_OP_TIMEOUT_SEC = 120.0
DEFAULT_DEADLINE_SEC = 300.0


class DeviceLink:
    """Mac 側 WebSocket 1 本の抽象。実体は hub に差し込まれる。"""

    async def send(self, frame: dict[str, Any]) -> None:  # pragma: no cover - interface
        raise NotImplementedError

    async def close(self, code: int = 1000, reason: str = "") -> None:  # pragma: no cover
        raise NotImplementedError


@dataclass(slots=True)
class PermissionGrant:
    """端末が run に与えた許可の決定。既定は無効（許可なし）。"""

    decision: str | None = None  # allow / deny / None(未決定)
    request_id: str | None = None
    decided_at: str | None = None
    reason: str | None = None


@dataclass(slots=True)
class InflightOp:
    op_id: str
    run_id: str
    job_id: str
    kind: str
    params_safe: dict[str, Any]
    future: asyncio.Future[dict[str, Any]]
    sent_at: str
    expected: dict[str, Any] | None = None
    #: 応答待ちが時間切れになった（後から届いた結果は履歴にだけ残す）。
    timed_out: bool = False


@dataclass(slots=True)
class LinkState:
    link: DeviceLink
    device_id: str | None = None
    hostname: str = ""
    app_version: str = ""
    os_version: str = ""
    displays: list[dict[str, Any]] = field(default_factory=list)
    connected_at: str = ""
    permissions: dict[str, PermissionGrant] = field(default_factory=dict)
    inflight: InflightOp | None = None
    seen_op_ids: set[str] = field(default_factory=set)
    #: ロック・終了などで操作を止めた理由。アンロック / 再接続で消える。
    revoked_reason: str | None = None


@dataclass(slots=True)
class RunState:
    """Hermes の 1 実行（run）に紐づく操作状態。"""

    job_id: str
    run_id: str
    job_dir: Path
    job_title: str
    device_id: str | None = None
    #: display_id → 直近の撮影結果の画面構成。
    layouts: dict[str, dict[str, Any]] = field(default_factory=dict)
    canceled: bool = False
    started_at: str = ""


class _PermissionWait:
    __slots__ = ("request_id", "future", "started_at")

    def __init__(self, request_id: str, future: asyncio.Future[str]) -> None:
        self.request_id = request_id
        self.future = future
        self.started_at = datetime.now(UTC).isoformat(timespec="seconds")


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


class MacControlHub:
    """部屋 1 プロセスに 1 つ。HTTP / WebSocket / Hermes から操作される。"""

    def __init__(
        self,
        *,
        permission_timeout: float = DEFAULT_PERMISSION_TIMEOUT_SEC,
        op_timeout: float = DEFAULT_OP_TIMEOUT_SEC,
        deadline: float = DEFAULT_DEADLINE_SEC,
    ) -> None:
        self._permission_timeout = permission_timeout
        self._op_timeout = op_timeout
        self._deadline = deadline
        self._links: list[LinkState] = []
        self._runs: dict[str, RunState] = {}
        self._permission_waits: dict[tuple[str, str], _PermissionWait] = {}
        self._loop: asyncio.AbstractEventLoop | None = None
        self._lock = threading.Lock()

    # -------------------------------------------------------------- loop / 分岐

    @property
    def loop(self) -> asyncio.AbstractEventLoop | None:
        return self._loop

    def attach_loop(self, loop: asyncio.AbstractEventLoop | None) -> None:
        """実行ループを覚える。初回だけ。uvicorn 起動時にも呼ばれる。"""
        if self._loop is None and loop is not None:
            self._loop = loop

    def _in_hub_loop(self) -> bool:
        if self._loop is None:
            return False
        try:
            return asyncio.get_running_loop() is self._loop
        except RuntimeError:
            return False

    def _wait_for(self, coro: Any, timeout: float = 30.0) -> Any:
        """hub のループで coro を回し、完了を待つ（ループ外のスレッド用）。"""
        if self._loop is None:
            raise MacControlError(MacControlErrorCode.UNAVAILABLE, "Mac 操作の準備ができていない")
        if self._in_hub_loop():
            raise RuntimeError("hub API をループ内から同期呼び出しできない")
        return asyncio.run_coroutine_threadsafe(coro, self._loop).result(timeout=timeout)

    # ------------------------------------------------------------------ run

    def begin_run(
        self,
        *,
        job_id: str,
        run_id: str,
        job_dir: Path,
        job_title: str = "",
    ) -> None:
        """Hermes が 1 実行を始めるときに呼ぶ（Hermes のワーカースレッドから）。"""
        self._wait_for(
            self._begin_run(job_id=job_id, run_id=run_id, job_dir=job_dir, job_title=job_title),
            timeout=10,
        )

    def end_run(self, *, job_id: str, run_id: str, reason: str = "run 終了") -> None:
        """Hermes の 1 実行が終わるときに呼ぶ。許可を失効させて状態を捨てる。"""
        self._wait_for(self._end_run(job_id=job_id, run_id=run_id, reason=reason), timeout=10)

    def cancel_job(self, job_id: str) -> None:
        """依頼の中断。実行前の操作を破棄し、許可を失効させる。

        ループ内（orchestrator の cancel など）からは fire-and-forget で予約する。
        """
        if self._in_hub_loop():
            asyncio.create_task(self._cancel_job(job_id))
            return
        if self._loop is None or not self._loop.is_running():
            # hub のループが動いていない（起動前・停止後）ときは失効状態を作らない。
            return
        self._wait_for(self._cancel_job(job_id), timeout=10)

    async def _begin_run(self, *, job_id: str, run_id: str, job_dir: Path, job_title: str) -> None:
        self._runs.pop(run_id, None)
        state = RunState(
            job_id=job_id,
            run_id=run_id,
            job_dir=Path(job_dir),
            job_title=job_title[:200],
            started_at=_now(),
        )
        self._runs[run_id] = state

    async def _end_run(self, *, job_id: str, run_id: str, reason: str) -> None:
        state = self._runs.pop(run_id, None)
        if state is None:
            return
        if state.device_id:
            link = self._link_by_device(state.device_id)
            if link is not None:
                link.permissions.pop(run_id, None)
                self._permission_waits.pop((state.device_id, run_id), None)
                inflight = link.inflight
                if inflight is not None and inflight.run_id == run_id:
                    link.inflight = None
                    self._record_unknown(state, inflight, reason)
                await self._send_safely(link.link, _cancel_run_frame(run_id, job_id, reason))

    async def _cancel_job(self, job_id: str) -> None:
        targets = [state for state in self._runs.values() if state.job_id == job_id]
        for state in targets:
            state.canceled = True
            device_id = state.device_id
            if device_id is not None:
                link = self._link_by_device(device_id)
                if link is not None:
                    link.permissions.pop(state.run_id, None)
                    self._resolve_permission_wait(device_id, state.run_id, canceled=True)
                    inflight = link.inflight
                    if inflight is not None and inflight.run_id == state.run_id:
                        link.inflight = None
                        self._record(
                            state,
                            inflight,
                            status="canceled",
                            error_code=MacControlErrorCode.CANCELLED,
                            error_message="中断された（実行結果は不明。自動再送はしない）",
                        )
                        self._resolve_inflight(inflight, canceled=True)
                        await self._send_safely(
                            link.link, _cancel_run_frame(state.run_id, job_id, "job cancelled")
                        )
            for (dev_id, run_id), _wait in list(self._permission_waits.items()):
                if run_id == state.run_id:
                    self._resolve_permission_wait(dev_id, run_id, canceled=True)
            self._emit_journal(state, "Mac 操作をやめた")

    # ------------------------------------------------------------- device link

    def register_link(self, link: DeviceLink) -> LinkState:
        """Mac の WebSocket が繋がった（hello まで pending）。非同期処理は不要。"""
        state = LinkState(link=link, connected_at=_now())
        with self._lock:
            self._links.append(state)
        return state

    async def handle_frame(self, link: DeviceLink, frame: dict[str, Any]) -> None:
        """Mac から届いたフレームを処理する。未知の type は無視。"""
        state = self._link_state(link)
        if state is None:
            return
        frame_type = frame.get("type")
        try:
            if frame_type == FRAME_HELLO:
                await self._on_hello(state, frame)
            elif frame_type == FRAME_CONTROL_DECISION:
                self._on_decision(state, frame)
            elif frame_type == FRAME_OP_RESULT:
                await self._on_op_result(state, frame)
            elif frame_type == FRAME_STATE:
                await self._on_state(state, frame)
            elif frame_type == FRAME_DISPLAYS:
                self._on_displays(state, frame)
            elif frame_type == FRAME_PING:
                await self._send_safely(state.link, {"type": FRAME_PONG, "ts": _now()})
            elif frame_type == FRAME_PONG:
                pass
        except Exception:
            logger.exception("mac control frame failed type=%s", frame_type)

    async def close_link(self, link: DeviceLink, reason: str) -> None:
        """Mac の WebSocket が切れた。許可を失効させ、実行中は結果不明にする。"""
        await self._link_closed(link, reason)

    def link_state(self, link: DeviceLink) -> LinkState | None:
        return self._link_state(link)

    def _link_state(self, link: DeviceLink) -> LinkState | None:
        for state in self._links:
            if state.link is link:
                return state
        return None

    def _link_by_device(self, device_id: str) -> LinkState | None:
        for state in self._links:
            if state.device_id == device_id:
                return state
        return None

    def device_states(self) -> list[dict[str, Any]]:
        """認証済みで今繋がっている Mac の一覧（デバッグ・テスト用）。"""
        return [
            {
                "device_id": state.device_id,
                "hostname": state.hostname,
                "app_version": state.app_version,
                "os_version": state.os_version,
                "connected_at": state.connected_at,
                "displays": state.displays,
                "granted_run_ids": sorted(state.permissions.keys()),
                "inflight_op_id": state.inflight.op_id if state.inflight else None,
            }
            for state in self._links
            if state.device_id
        ]

    async def _on_hello(self, state: LinkState, frame: dict[str, Any]) -> None:
        from mihari_room.mac_control.protocol import validate_device_id

        device_id = validate_device_id(frame.get("device_id"))
        previous = self._link_by_device(device_id)
        if previous is not None and previous is not state:
            # 同じ Mac からの張り直し。古い方を閉じて新しい方を正本にする。
            await previous.link.close(code=4000, reason="replaced by a newer connection")
            with self._lock:
                if previous in self._links:
                    self._links.remove(previous)
            await self._link_closed(previous, "replaced")
        state.device_id = device_id
        state.hostname = str(frame.get("hostname") or "")[:200]
        state.app_version = str(frame.get("app_version") or "")[:100]
        state.os_version = str(frame.get("os_version") or "")[:100]
        state.revoked_reason = None
        try:
            state.displays = normalize_displays(frame.get("displays"))
        except ValueError:
            state.displays = []
        await self._send_safely(
            state.link,
            {"type": FRAME_HELLO_ACK, "device_id": device_id, "protocol": 1},
        )

    def _on_displays(self, state: LinkState, frame: dict[str, Any]) -> None:
        """画面構成の変化（アンロック・表示器の抜き差し）を反映する。"""
        try:
            state.displays = normalize_displays(frame.get("displays"))
        except ValueError:
            return
        state.revoked_reason = None
        # 古い撮影に基づく操作は Mac 側と突き合わせて弾く（_expected_layout）。

    async def _on_state(self, state: LinkState, frame: dict[str, Any]) -> None:
        event = str(frame.get("event") or "")
        run_id = str(frame.get("run_id") or "")
        message = str(frame.get("message") or "")[:300]
        if event == "unlock":
            state.revoked_reason = None
            return
        if event in ("lock", "quit", "stop", "revoke"):
            await self._revoke_all(state, event=event, run_id=run_id, message=message)

    async def _revoke_all(
        self,
        state: LinkState,
        *,
        event: str,
        run_id: str = "",
        message: str = "",
    ) -> None:
        """端末側の状態変化で、その端末に紐づく許可を失効させる。"""
        label = {
            "lock": "Mac がロックされた",
            "quit": "Mac アプリが終了した",
            "stop": "ユーザーが停止した",
            "revoke": "許可が取り消された",
        }.get(event, "許可が失効した")
        if event in ("lock", "quit", "stop"):
            state.revoked_reason = label
        device_id = state.device_id or ""
        run_ids = [run_id] if run_id else [rid for rid in list(state.permissions)]
        for rid in run_ids:
            state.permissions.pop(rid, None)
            self._resolve_permission_wait(device_id, rid, canceled=False, label=label)
        inflight = state.inflight
        if inflight is not None and (not run_id or run_id == inflight.run_id):
            state.inflight = None
            run_state = self._runs.get(inflight.run_id)
            if run_state is not None:
                self._record(
                    run_state,
                    inflight,
                    status="unknown",
                    error_code=MacControlErrorCode.UNKNOWN_OUTCOME,
                    error_message=f"{label}（実行結果は不明。自動再送はしない）",
                )
            self._resolve_inflight(inflight, canceled=False, label=label)
        if message:
            logger.info("mac control revoked device=%s event=%s (%s)", device_id, event, message)
        else:
            logger.info("mac control revoked device=%s event=%s", device_id, event)

    async def _link_closed(self, link: DeviceLink, reason: str) -> None:
        state = self._link_state(link)
        if state is None:
            return
        with self._lock:
            if state in self._links:
                self._links.remove(state)
        await self._revoke_all(state, event="quit", message=f"切断: {reason[:300]}")

    # --------------------------------------------------------------- decision

    def _on_decision(self, state: LinkState, frame: dict[str, Any]) -> None:
        device_id = state.device_id
        if device_id is None:
            return
        run_id = str(frame.get("run_id") or "")
        decision = str(frame.get("decision") or "")
        if not run_id or decision not in (DECISION_ALLOW, DECISION_DENY):
            return
        grant = state.permissions.setdefault(run_id, PermissionGrant())
        grant.decision = decision
        grant.decided_at = _now()
        grant.request_id = str(frame.get("request_id") or grant.request_id or "")
        grant.reason = str(frame.get("reason") or "")[:300]
        wait = self._permission_waits.pop((device_id, run_id), None)
        if wait is not None and not wait.future.done():
            wait.future.set_result(decision)

    # ----------------------------------------------------------------- op result

    async def _on_op_result(self, state: LinkState, frame: dict[str, Any]) -> None:
        op_id = str(frame.get("op_id") or "")
        if not op_id:
            return
        inflight = state.inflight
        if inflight is None or inflight.op_id != op_id or inflight.timed_out:
            # タイムアウト・キャンセル後に届いた結果。Hermes には返さず履歴に残す。
            if inflight is not None and inflight.op_id == op_id and inflight.timed_out:
                state.inflight = None
            run_state = self._runs.get(str(frame.get("run_id") or ""))
            if run_state is not None:
                self._append_late(run_state, op_id, frame)
            return
        state.inflight = None
        run_state = self._runs.get(inflight.run_id)
        ok = bool(frame.get("ok"))
        try:
            if ok:
                result = frame.get("result") or {}
                if run_state is not None and inflight.kind == MacOpKind.CAPTURE:
                    result = await self._absorb_capture(run_state, inflight, result)
                if run_state is not None:
                    self._record(
                        run_state,
                        inflight,
                        status="ok",
                        result=_result_summary(inflight.kind, result),
                    )
                if not inflight.future.done():
                    inflight.future.set_result(result or {})
            else:
                error = frame.get("error") or {}
                code = str(error.get("code") or MacControlErrorCode.EXECUTION_FAILED)
                message = str(error.get("message") or "実行に失敗した")
                if run_state is not None:
                    self._record(
                        run_state,
                        inflight,
                        status="error",
                        error_code=code,
                        error_message=message,
                    )
                if not inflight.future.done():
                    inflight.future.set_exception(MacControlError(code, message))
        except MacControlError as exc:
            # 撮影結果の保存失敗など。操作自体は失敗として扱う。
            if run_state is not None:
                self._record(
                    run_state,
                    inflight,
                    status="error",
                    error_code=exc.code,
                    error_message=exc.message,
                )
            if not inflight.future.done():
                inflight.future.set_exception(exc)

    async def _absorb_capture(
        self, run_state: RunState, inflight: InflightOp, result: dict[str, Any]
    ) -> dict[str, Any]:
        """撮影結果を private 領域へ保存し、画面構成を覚える。"""
        raw = result.get("image_base64") or ""
        display_id = validate_display_id(result.get("display_id"))
        if not raw:
            raise MacControlError(MacControlErrorCode.EXECUTION_FAILED, "撮影結果に画像が無い")
        try:
            png = base64.b64decode(raw, validate=True)
        except ValueError as exc:
            raise MacControlError(
                MacControlErrorCode.EXECUTION_FAILED, "撮影画像が壊れている"
            ) from exc
        rel = history_mod.write_capture_image(
            run_state.job_dir, run_state.run_id, inflight.op_id, png
        )
        layout = {
            "display_id": display_id,
            "width_px": int(result.get("width_px") or 0),
            "height_px": int(result.get("height_px") or 0),
            "scale": float(result.get("scale") or 1.0),
            "bounds": result.get("bounds") or {},
            "layout_token": str(result.get("layout_token") or ""),
        }
        if layout["width_px"] > 0 and layout["height_px"] > 0:
            run_state.layouts[display_id] = layout
        return {
            "display_id": display_id,
            "width_px": layout["width_px"],
            "height_px": layout["height_px"],
            "scale": layout["scale"],
            "bounds": layout["bounds"],
            "layout_token": layout["layout_token"],
            "path": str(rel),
            "bytes": len(png),
        }

    # ------------------------------------------------------------------ ops

    def run_operation(
        self,
        *,
        job_id: str,
        run_id: str,
        kind: str,
        params: dict[str, Any],
        device_id: str | None = None,
    ) -> dict[str, Any]:
        """Hermes ツールからの同期待ち入り口。結果か MacControlError を返す。"""
        try:
            return self._wait_for(
                self._run_operation(
                    job_id=job_id,
                    run_id=run_id,
                    kind=kind,
                    params=params,
                    device_id=device_id,
                ),
                timeout=self._deadline + 15,
            )
        except concurrent.futures.TimeoutError:
            raise MacControlError(
                MacControlErrorCode.UNKNOWN_OUTCOME,
                f"操作が {self._deadline:.0f} 秒以内に終わらなかった（結果不明。自動再送はしない）",
            ) from None

    async def _run_operation(
        self,
        *,
        job_id: str,
        run_id: str,
        kind: str,
        params: dict[str, Any],
        device_id: str | None = None,
    ) -> dict[str, Any]:
        run_state = self._runs.get(run_id)
        if run_state is None or run_state.job_id != job_id:
            raise MacControlError(
                MacControlErrorCode.UNKNOWN_RUN,
                "この実行（run）はもう終わっているか、見つからない",
            )
        if run_state.canceled:
            raise MacControlError(
                MacControlErrorCode.CANCELLED,
                "依頼が中断されているので、これ以上の操作はしない",
            )
        op_id = uuid4().hex
        deadline = time.monotonic() + self._deadline

        try:
            normalized, display_ref = _normalize_op(kind, params)
        except ValueError as exc:
            raise MacControlError(MacControlErrorCode.INVALID_PARAMS, str(exc)) from exc
        params_safe = sanitize_op_params(str(kind), normalized)

        device_id = await self._resolve_device(run_state, device_id)
        if device_id is None:
            raise MacControlError(
                MacControlErrorCode.NO_DEVICE,
                "Mac がまだ部屋に繋がっていない。Mac でみはりちゃんアプリを起動して"
                "部屋との接続を確認してから、もう一度呼んで。",
            )
        link = self._link_by_device(device_id)
        if link is None:
            raise MacControlError(
                MacControlErrorCode.NO_DEVICE, "Mac が切断されている（接続を確認して）"
            )

        # 同一 run で結果不明のまま同じ操作を再送しない。
        self._check_duplicate_of_unknown(run_state, str(kind), params_safe)

        # 実行前に許可を確認する（既定は無効）。
        await self._ensure_permission(run_state, link, deadline)

        # 画面構成の突き合わせ。撮影してからでないと座標操作はできない。
        expected = self._expected_layout(run_state, str(kind), normalized, display_ref)
        if expected is not None:
            current = _find_current_display(link, expected["display_id"])
            if current is None:
                raise MacControlError(
                    MacControlErrorCode.STALE_LAYOUT,
                    f"表示器 {expected['display_id']} が今は無い。mac_capture で撮り直して",
                )
            try:
                check_layout_matches(expected, current)
            except DisplayGeometryError as exc:
                raise MacControlError(
                    MacControlErrorCode.STALE_LAYOUT,
                    f"{exc} いまの画面を mac_capture で撮り直して",
                ) from exc

        # 一度に 1 操作。
        if link.inflight is not None:
            raise MacControlError(
                MacControlErrorCode.BUSY,
                "別の操作が実行中。終わってからもう一度呼んで",
            )

        loop = asyncio.get_running_loop()
        inflight = InflightOp(
            op_id=op_id,
            run_id=run_id,
            job_id=job_id,
            kind=str(kind),
            params_safe=params_safe,
            future=loop.create_future(),
            sent_at=_now(),
            expected=expected,
        )
        link.seen_op_ids.add(op_id)
        link.inflight = inflight
        frame = {
            "type": FRAME_OP,
            "op_id": op_id,
            "run_id": run_id,
            "job_id": job_id,
            "kind": str(kind),
            "params": normalized,
            "expected": expected,
            "sent_at": inflight.sent_at,
        }
        try:
            await self._send_safely(link.link, frame)
        except Exception as exc:
            link.inflight = None
            self._record(
                run_state,
                inflight,
                status="error",
                error_code=MacControlErrorCode.EXECUTION_FAILED,
                error_message=f"送信に失敗した: {exc}",
            )
            raise MacControlError(
                MacControlErrorCode.EXECUTION_FAILED, f"Mac への送信に失敗した: {exc}"
            ) from exc
        self._emit_journal(run_state, f"{describe_op(str(kind), normalized)}を送った")
        try:
            remaining = deadline - time.monotonic()
            result = await asyncio.wait_for(
                asyncio.shield(inflight.future), timeout=max(1.0, remaining)
            )
        except TimeoutError:
            inflight.timed_out = True
            self._record(
                run_state,
                inflight,
                status="unknown",
                error_code=MacControlErrorCode.UNKNOWN_OUTCOME,
                error_message="端末からの応答が無かった（結果不明。自動再送はしない）",
            )
            raise MacControlError(
                MacControlErrorCode.UNKNOWN_OUTCOME,
                "Mac からの応答が無い（結果不明。自動再送はしない）",
            ) from None
        except asyncio.CancelledError:
            raise
        self._emit_journal(run_state, f"{describe_op(str(kind), normalized)}を終えた")
        return {"success": True, "op_id": op_id, "kind": str(kind), "result": result}

    async def _resolve_device(self, run_state: RunState, device_id: str | None) -> str | None:
        """操作対象の端末を決める。この run を許可した端末だけを使う。"""
        if run_state.device_id is not None:
            if device_id is not None and device_id != run_state.device_id:
                raise MacControlError(
                    MacControlErrorCode.WRONG_DEVICE,
                    f"この依頼は端末 {run_state.device_id} が許可している。"
                    f"別端末 {device_id} では操作できない",
                )
            return run_state.device_id
        if device_id is not None:
            if self._link_by_device(device_id) is None:
                raise MacControlError(
                    MacControlErrorCode.WRONG_DEVICE, f"端末 {device_id} は繋がっていない"
                )
            return device_id
        candidates = [s.device_id for s in self._links if s.device_id and s.inflight is None]
        if not candidates:
            candidates = [s.device_id for s in self._links if s.device_id]
        if not candidates:
            return None
        if len(candidates) == 1:
            return candidates[0]
        raise MacControlError(
            MacControlErrorCode.WRONG_DEVICE,
            "複数の Mac が繋がっているため device_id を指定してね",
        )

    async def _ensure_permission(
        self, run_state: RunState, link: LinkState, deadline: float
    ) -> None:
        device_id = link.device_id
        assert device_id is not None
        grant = link.permissions.get(run_state.run_id)
        if grant is not None and grant.decision == DECISION_ALLOW:
            run_state.device_id = device_id
            return
        if grant is not None and grant.decision == DECISION_DENY:
            raise MacControlError(
                MacControlErrorCode.DENIED,
                "Mac 側でこの依頼の操作が拒否された。新しい追記・再接続で再許可を求められる",
            )
        if link.revoked_reason is not None:
            raise MacControlError(
                MacControlErrorCode.PERMISSION_LOST,
                f"{link.revoked_reason}。アンロック / 再接続を待ってから、"
                "新しい追記などで再許可を求めて",
            )
        key = (device_id, run_state.run_id)
        wait = self._permission_waits.get(key)
        if wait is None:
            request_id = uuid4().hex
            future: asyncio.Future[str] = asyncio.get_running_loop().create_future()
            wait = _PermissionWait(request_id, future)
            self._permission_waits[key] = wait
            await self._send_safely(
                link.link,
                {
                    "type": FRAME_CONTROL_REQUEST,
                    "request_id": request_id,
                    "job_id": run_state.job_id,
                    "run_id": run_state.run_id,
                    "job_title": run_state.job_title,
                    "scope": "whole_mac",
                    "note": (
                        "この依頼の間、この Mac 全体の撮影・クリック・入力などの操作を"
                        "許可しますか？ 既定は拒否です。キャンセル・ロック・終了で失効します。"
                    ),
                },
            )
            self._emit_journal(run_state, "Mac 側に操作の許可を求めた")
        remaining = deadline - time.monotonic()
        try:
            decision = await asyncio.wait_for(
                asyncio.shield(wait.future),
                timeout=max(0.5, min(remaining, self._permission_timeout)),
            )
        except TimeoutError:
            grant = link.permissions.setdefault(run_state.run_id, PermissionGrant())
            grant.decision = DECISION_DENY
            grant.decided_at = _now()
            grant.reason = "timeout"
            self._permission_waits.pop(key, None)
            raise MacControlError(
                MacControlErrorCode.PERMISSION_TIMEOUT,
                "Mac 側で許可されなかった（既定は拒否）。ユーザーが許可してからもう一度呼んで",
            ) from None
        except MacControlError:
            # キャンセル・失効など。request は消す。
            if self._permission_waits.get(key) is wait:
                self._permission_waits.pop(key, None)
            raise
        if decision != DECISION_ALLOW:
            raise MacControlError(
                MacControlErrorCode.DENIED,
                "Mac 側でこの依頼の操作が拒否された",
            )
        run_state.device_id = device_id
        self._emit_journal(run_state, "Mac 側から操作の許可をもらった")

    def _resolve_permission_wait(
        self, device_id: str, run_id: str, *, canceled: bool, label: str = ""
    ) -> None:
        wait = self._permission_waits.pop((device_id, run_id), None)
        if wait is None or wait.future.done():
            return
        if canceled:
            wait.future.set_exception(
                MacControlError(
                    MacControlErrorCode.CANCELLED,
                    "依頼が中断されたので、Mac への許可待ちをやめた",
                )
            )
        else:
            wait.future.set_exception(
                MacControlError(
                    MacControlErrorCode.PERMISSION_LOST,
                    label or "許可が失効した",
                )
            )

    def _resolve_inflight(self, inflight: InflightOp, *, canceled: bool, label: str = "") -> None:
        if inflight.future.done():
            return
        if canceled:
            inflight.future.set_exception(
                MacControlError(
                    MacControlErrorCode.CANCELLED,
                    "依頼が中断された。実行結果は不明で、自動再送はしない",
                )
            )
        else:
            inflight.future.set_exception(
                MacControlError(
                    MacControlErrorCode.UNKNOWN_OUTCOME,
                    f"{label or '切断'}（実行結果は不明。自動再送はしない）",
                )
            )

    def _record_unknown(self, run_state: RunState, inflight: InflightOp, reason: str) -> None:
        self._record(
            run_state,
            inflight,
            status="unknown",
            error_code=MacControlErrorCode.UNKNOWN_OUTCOME,
            error_message=f"{reason}（実行結果は不明。自動再送はしない）",
        )
        self._resolve_inflight(inflight, canceled=False, label=reason)

    def _check_duplicate_of_unknown(
        self, run_state: RunState, kind: str, params: dict[str, Any]
    ) -> None:
        """結果不明の操作と同一内容をもう一度送ろうとしていないか。"""
        last = self._last_op(run_state)
        if last is None or last["kind"] != kind:
            return
        if last["params_key"] != _params_key(params):
            return
        if last["status"] != "unknown":
            return
        raise MacControlError(
            MacControlErrorCode.DUPLICATE_OP,
            "直前の同じ操作は結果不明のまま（実行されたか分からない）。"
            "自動再送はしない。画面を mac_capture で撮り直して状態を確認してから判断して",
        )

    def _last_op(self, run_state: RunState) -> dict[str, Any] | None:
        records = history_mod.read_history(run_state.job_dir)
        for record in reversed(records):
            if record.get("run_id") != run_state.run_id:
                continue
            # 時間切れ後に届いた遅延結果は「未知」の判断を上書きしない。
            if str(record.get("status") or "").endswith("_late"):
                continue
            params = record.get("params") or {}
            return {
                "kind": record.get("kind"),
                "params_key": _params_key(params),
                "status": record.get("status"),
            }
        return None

    def _expected_layout(
        self,
        run_state: RunState,
        kind: str,
        params: dict[str, Any],
        display_ref: str | None,
    ) -> dict[str, Any] | None:
        if kind == MacOpKind.CAPTURE or kind == MacOpKind.ACTIVATE_APP or kind == MacOpKind.KEY:
            return None
        if kind == MacOpKind.SCROLL:
            # 座標なしスクロールは現在のカーソル位置で行われる。突き合わせ不要。
            if display_ref is None and params.get("x") is None and params.get("y") is None:
                return None
        display_id = display_ref or str(params.get("display_id") or "")
        if not display_id:
            raise MacControlError(
                MacControlErrorCode.NO_CAPTURE,
                "先に mac_capture で画面を撮って、その display_id を渡して",
            )
        layout = run_state.layouts.get(display_id)
        if layout is None:
            raise MacControlError(
                MacControlErrorCode.NO_CAPTURE,
                f"表示器 {display_id} はまだ撮影していない。mac_capture で撮ってから操作して",
            )
        width = int(layout["width_px"])
        height = int(layout["height_px"])
        if kind != MacOpKind.SCROLL:
            self._check_coords_in_layout(params, width, height)
        return {
            "display_id": display_id,
            "width_px": width,
            "height_px": height,
            "scale": layout.get("scale"),
            "bounds": layout.get("bounds"),
            "layout_token": layout.get("layout_token"),
        }

    @staticmethod
    def _check_coords_in_layout(params: dict[str, Any], width: int, height: int) -> None:
        for name in ("x", "y", "from_x", "from_y", "to_x", "to_y"):
            value = params.get(name)
            if value is None:
                continue
            try:
                number = float(value)
            except (TypeError, ValueError):
                continue
            limit = width if name.endswith("x") else height
            if number < 0 or number >= limit:
                raise MacControlError(
                    MacControlErrorCode.STALE_LAYOUT,
                    f"{name}={value} が撮影画像の外（{width}x{height}）。再撮影して",
                )

    # ------------------------------------------------------------------ misc

    def _record(
        self,
        run_state: RunState,
        inflight: InflightOp,
        *,
        status: str,
        error_code: str | None = None,
        error_message: str | None = None,
        result: dict[str, Any] | None = None,
    ) -> None:
        record = history_mod.operation_record(
            op_id=inflight.op_id,
            run_id=run_state.run_id,
            job_id=run_state.job_id,
            kind=inflight.kind,
            params_safe=inflight.params_safe,
            status=status,
            error_code=error_code,
            error_message=error_message,
            result=result,
            sent_at=inflight.sent_at,
        )
        history_mod.append_history(run_state.job_dir, record)

    def _append_late(self, run_state: RunState, op_id: str, frame: dict[str, Any]) -> None:
        """タイムアウト・キャンセル後に届いた結果。履歴へ「遅延」として残す。"""
        try:
            ok = bool(frame.get("ok"))
            error = frame.get("error") or {}
            history_mod.append_history(
                run_state.job_dir,
                {
                    "op_id": op_id,
                    "run_id": run_state.run_id,
                    "job_id": run_state.job_id,
                    "kind": str(frame.get("kind") or ""),
                    "params": {},
                    "status": "done_late" if ok else "error_late",
                    "error_code": None if ok else str(error.get("code") or ""),
                    "error_message": None if ok else str(error.get("message") or ""),
                    "result": frame.get("result") if ok else None,
                    "sent_at": None,
                    "resolved_at": _now(),
                },
            )
        except Exception:
            logger.debug("late result record failed", exc_info=True)

    async def _send_safely(self, channel: DeviceLink, frame: dict[str, Any]) -> None:
        await channel.send(frame)

    def _emit_journal(self, run_state: RunState, text: str) -> None:
        try:
            from mihari_room.events import EventJournal, EventPhase, JournalKind

            journal = EventJournal.for_job(run_state.job_dir)
            journal.append(
                job_id=run_state.job_id,
                phase=EventPhase.RESEARCHING,
                kind=JournalKind.LOG,
                text=text,
            )
        except Exception:
            logger.debug("mac journal append failed", exc_info=True)


def _find_current_display(link: LinkState, display_id: str) -> dict[str, Any] | None:
    for display in link.displays:
        if display.get("display_id") == display_id:
            return display
    return None


def _cancel_run_frame(run_id: str, job_id: str, reason: str) -> dict[str, Any]:
    return {"type": FRAME_CANCEL_RUN, "run_id": run_id, "job_id": job_id, "reason": reason}


def _params_key(params: dict[str, Any]) -> tuple[tuple[str, str], ...]:
    return tuple(sorted((str(k), repr(v)) for k, v in (params or {}).items()))


def _result_summary(kind: str, result: dict[str, Any]) -> dict[str, Any]:
    """履歴に残す結果。capture は画像本体を載せず要約だけ。"""
    if kind == MacOpKind.CAPTURE:
        return {
            "display_id": result.get("display_id"),
            "width_px": result.get("width_px"),
            "height_px": result.get("height_px"),
            "path": result.get("path"),
            "bytes": result.get("bytes"),
        }
    out: dict[str, Any] = {}
    for key in (
        "activated",
        "bundle_id",
        "app_name",
        "moved_to",
        "clicked",
        "typed_chars",
        "scrolled",
    ):
        if result.get(key) is not None:
            out[key] = result.get(key)
    return out


def _normalize_op(kind: str, params: dict[str, Any]) -> tuple[dict[str, Any], str | None]:
    """操作パラメータを検証して返す。``(params, display_ref)``。

    座標は撮影画像のピクセル。display_id は表示器の参照。
    """
    from mihari_room.mac_control.protocol import (
        MAX_SCROLL_DELTA,
        MAX_TEXT_CHARS,
        validate_coord,
        validate_modifiers,
    )

    raw = dict(params or {})
    display_ref = raw.get("display_id")
    if display_ref is not None:
        raw["display_id"] = validate_display_id(display_ref)
        display_ref = raw["display_id"]

    kind_name = MacOpKind(str(kind))
    if kind_name == MacOpKind.CAPTURE:
        pass
    elif kind_name in (MacOpKind.CLICK, MacOpKind.DOUBLE_CLICK):
        raw["x"] = validate_coord(raw.get("x"), "x")
        raw["y"] = validate_coord(raw.get("y"), "y")
        button = str(raw.get("button") or "left").lower()
        if button not in ("left", "right", "middle"):
            raise ValueError("button は left/right/middle のどれか")
        raw["button"] = button
        raw["modifiers"] = validate_modifiers(raw.get("modifiers"))
    elif kind_name == MacOpKind.DRAG:
        if raw.get("display_id") is None:
            raise ValueError("display_id が要る（ドラッグは同じ表示器の中だけ）")
        for name in ("from_x", "from_y", "to_x", "to_y"):
            raw[name] = validate_coord(raw.get(name), name)
        if raw["from_x"] == raw["to_x"] and raw["from_y"] == raw["to_y"]:
            raise ValueError("ドラッグの開始と終了が同じ")
        button = str(raw.get("button") or "left").lower()
        if button not in ("left", "right", "middle"):
            raise ValueError("button は left/right/middle のどれか")
        raw["button"] = button
        raw["modifiers"] = validate_modifiers(raw.get("modifiers"))
    elif kind_name == MacOpKind.SCROLL:
        if raw.get("delta_x") is None and raw.get("delta_y") is None:
            raise ValueError("delta_x / delta_y のどちらかは要る")
        for name in ("delta_x", "delta_y"):
            if raw.get(name) is not None:
                try:
                    value = float(raw[name])
                except (TypeError, ValueError):
                    raise ValueError(f"{name} が不正") from None
                if abs(value) > MAX_SCROLL_DELTA:
                    raise ValueError(f"{name} が大きすぎる")
                raw[name] = value
        for name in ("x", "y"):
            if raw.get(name) is not None:
                raw[name] = validate_coord(raw[name], name)
    elif kind_name == MacOpKind.TYPE_TEXT:
        text = str(raw.get("text") or "")
        if not text:
            raise ValueError("text が空")
        if len(text) > MAX_TEXT_CHARS:
            raise ValueError(f"text が長すぎる（上限 {MAX_TEXT_CHARS} 文字）")
        raw["text"] = text
    elif kind_name == MacOpKind.KEY:
        from mihari_room.mac_control.protocol import ALLOWED_KEYS

        key = raw.get("key")
        keycode = raw.get("keycode")
        if key is None and keycode is None:
            raise ValueError("key または keycode のどちらかは要る")
        if key is not None:
            normalized = str(key).strip().lower()
            if normalized not in ALLOWED_KEYS:
                raise ValueError(f"key が未対応: {key}（対応: {', '.join(sorted(ALLOWED_KEYS))}）")
            raw["key"] = normalized
        if keycode is not None:
            try:
                code = int(keycode)
            except (TypeError, ValueError):
                raise ValueError("keycode が数字ではない") from None
            if code < 0 or code > 0x7FFF:
                raise ValueError("keycode が範囲外")
            raw["keycode"] = code
        raw["modifiers"] = validate_modifiers(raw.get("modifiers"))
    elif kind_name == MacOpKind.ACTIVATE_APP:
        bundle_id = str(raw.get("bundle_id") or "").strip()
        app_name = str(raw.get("app_name") or "").strip()
        if not bundle_id and not app_name:
            raise ValueError("bundle_id か app_name のどちらかは要る")
        raw["bundle_id"] = bundle_id or None
        raw["app_name"] = app_name or None
    else:
        raise ValueError(f"未対応の操作: {kind}")
    return raw, display_ref
