"""Mac 操作テストの二重。本番コードには置かない。

``FakeLink`` は hub が送るフレームを asyncio.Queue へ積む。``FakeMac`` は
そのキューを読んで、制御フレームのとおりに decision / op.result を返す
（実機の Mac アプリのふるまいを模す）。デフォルトは撮影なら 1x1 PNG を返す。
"""

from __future__ import annotations

import asyncio
from typing import Any

from mihari_room.mac_control.hub import DeviceLink

#: 1x1 の透明 PNG。base64 で返す。
TINY_PNG = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
    "+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)


class FakeLink(DeviceLink):
    """hub が送るフレームを積むリンク。close は記録する。"""

    def __init__(self, name: str = "link") -> None:
        self.name = name
        self.outbox: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.closed: list[tuple[int, str]] = []

    async def send(self, frame: dict[str, Any]) -> None:
        await self.outbox.put(frame)

    async def close(self, code: int = 1000, reason: str = "") -> None:
        self.closed.append((code, reason))

    async def next_frame(self, timeout: float = 2.0) -> dict[str, Any] | None:
        try:
            return await asyncio.wait_for(self.outbox.get(), timeout=timeout)
        except TimeoutError:
            return None


def default_displays() -> list[dict[str, Any]]:
    """Retina 1 台（1440x900 点、2x=2880x1800 px）。"""
    return [
        {
            "display_id": "1001",
            "name": "Color LCD",
            "width_px": 2880,
            "height_px": 1800,
            "scale": 2.0,
            "bounds": {"x": 0, "y": 0, "width": 1440, "height": 900},
        }
    ]


async def make_mac(hub: Any, device_id: str = "mac-1") -> FakeMac:
    """hello 済みで起動済みの擬似 Mac を作る。"""
    mac = FakeMac(hub, FakeLink())
    await hello_frame(mac.link, hub, device_id=device_id)
    mac.start()
    return mac


async def run_capture(mac: FakeMac, hub: Any, run_id: str) -> dict[str, Any]:
    """許可を経て capture を実行する（FakeMac が自動応答）。"""
    return await hub._run_operation(job_id="job-1", run_id=run_id, kind="capture", params={})


async def hello_frame(link: FakeLink, hub: Any, device_id: str = "mac-1") -> None:
    """リンクを hub に登録し、hello を送り hello_ack を消費する。"""
    hub.register_link(link)
    await hub.handle_frame(
        link,
        {
            "type": "hello",
            "device_id": device_id,
            "hostname": "test-mac",
            "app_version": "1.0",
            "os_version": "macOS 15",
            "displays": default_displays(),
        },
    )
    await link.next_frame()  # hello_ack


class FakeMac:
    """hub の送信フレームに自動応答する擬似 Mac。

    - control.request → decision（既定 allow）
    - op: capture は画像、それ以外は ok を返す
    - cancel_run / ping は無視・pong
    """

    def __init__(
        self,
        hub: Any,
        link: FakeLink,
        *,
        decision: str = "allow",
        capture_png: str | None = TINY_PNG,
        displays: list[dict[str, Any]] | None = None,
    ) -> None:
        self.hub = hub
        self.link = link
        self.decision = decision
        self.capture_png = capture_png
        self.displays = displays if displays is not None else default_displays()
        self.task: asyncio.Task[None] | None = None
        self.received_ops: list[dict[str, Any]] = []
        self.cancelled_runs: list[str] = []
        #: op にどう応えるかの上書き。
        self.on_op: Any = None

    def start(self) -> None:
        self.task = asyncio.create_task(self._run(), name="fake-mac")

    async def stop(self) -> None:
        if self.task is not None:
            self.task.cancel()
            try:
                await self.task
            except asyncio.CancelledError:
                pass
            self.task = None

    async def _run(self) -> None:
        while True:
            frame = await self.link.outbox.get()
            frame_type = frame.get("type")
            if frame_type == "hello_ack":
                continue
            if frame_type == "ping":
                await self.hub.handle_frame(self.link, {"type": "pong"})
                continue
            if frame_type == "cancel_run":
                self.cancelled_runs.append(str(frame.get("run_id") or ""))
                continue
            if frame_type == "control.request":
                await self.hub.handle_frame(
                    self.link,
                    {
                        "type": "control.decision",
                        "request_id": frame.get("request_id"),
                        "job_id": frame.get("job_id"),
                        "run_id": frame.get("run_id"),
                        "decision": self.decision,
                    },
                )
                continue
            if frame_type == "op":
                self.received_ops.append(frame)
                if self.on_op is not None:
                    await self.on_op(self.hub, self.link, frame)
                    continue
                await self._reply_op(frame)
                continue

    async def _reply_op(self, frame: dict[str, Any]) -> None:
        kind = frame.get("kind")
        if kind == "capture":
            if self.capture_png is None:
                await self.hub.handle_frame(
                    self.link,
                    {
                        "type": "op.result",
                        "op_id": frame.get("op_id"),
                        "run_id": frame.get("run_id"),
                        "ok": False,
                        "error": {"code": "execution_failed", "message": "撮影に失敗"},
                    },
                )
                return
            display = self.displays[0]
            await self.hub.handle_frame(
                self.link,
                {
                    "type": "op.result",
                    "op_id": frame.get("op_id"),
                    "run_id": frame.get("run_id"),
                    "kind": kind,
                    "ok": True,
                    "result": {
                        "display_id": display["display_id"],
                        "width_px": display["width_px"],
                        "height_px": display["height_px"],
                        "scale": display["scale"],
                        "bounds": display["bounds"],
                        "layout_token": "tok-abc",
                        "image_base64": self.capture_png or TINY_PNG,
                    },
                },
            )
            return
        await self.hub.handle_frame(
            self.link,
            {
                "type": "op.result",
                "op_id": frame.get("op_id"),
                "run_id": frame.get("run_id"),
                "kind": kind,
                "ok": True,
                "result": {"ok": True},
            },
        )


async def make_run(hub: Any, tmp_path, job_id: str = "job-1", title: str = "画面を触って") -> str:
    """run を張って run_id を返す。"""
    import uuid

    run_id = f"{job_id}-{uuid.uuid4().hex[:8]}"
    job_dir = tmp_path / "jobs" / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    await hub._begin_run(job_id=job_id, run_id=run_id, job_dir=job_dir, job_title=title)
    return run_id
