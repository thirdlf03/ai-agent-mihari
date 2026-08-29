"""``/iphone/screenshot*`` エンドポイントのステータスコードとエラー内容を確かめる。

実機には依存しない。``LiveScreenshotSource`` は必ずフェイクに差し替え、実際の
usbmuxd/lockdown/tunneld 通信が起きないようにする。
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from device_bridge.commands.screenshot import PreflightFacts
from device_bridge.daemon.routers import screenshot as screenshot_router

READY_FACTS = PreflightFacts(
    ios_version="17.5.1",
    developer_mode_enabled=True,
    ddi_mounted=True,
    tunneld_reachable=True,
)

NOT_READY_FACTS = PreflightFacts(
    ios_version="17.5.1",
    developer_mode_enabled=False,
    ddi_mounted=False,
    tunneld_reachable=False,
)


class FakeSource:
    """``ScreenshotSource`` のフェイク。テストごとに挙動を差し替える。"""

    def __init__(
        self,
        *,
        udid: str | None = "UDID-1",
        facts: PreflightFacts | None = READY_FACTS,
        png: bytes = b"\x89PNG\r\n\x1a\nfake-png-bytes",
        capture_error: Exception | None = None,
    ) -> None:
        self._udid = udid
        self._facts = facts
        self._png = png
        self._capture_error = capture_error

    async def find_device(self) -> str | None:
        return self._udid

    async def gather_preflight_facts(self, udid: str) -> PreflightFacts:
        assert self._facts is not None
        return self._facts

    async def capture_png(self, udid: str) -> bytes:
        if self._capture_error is not None:
            raise self._capture_error
        return self._png


def _patch_source(monkeypatch: pytest.MonkeyPatch, source: FakeSource) -> None:
    monkeypatch.setattr(screenshot_router.screenshot_source, "LiveScreenshotSource", lambda: source)


# --- GET /iphone/screenshot/preflight ------------------------------------------------


def test_get_preflight_requires_token(client: TestClient) -> None:
    response = client.get("/iphone/screenshot/preflight")
    assert response.status_code == 401


def test_get_preflight_returns_200_even_when_not_ready(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    _patch_source(monkeypatch, FakeSource(facts=NOT_READY_FACTS))

    response = client.get("/iphone/screenshot/preflight", headers=auth)

    assert response.status_code == 200
    body = response.json()
    assert body["ready"] is False
    ids = {check["id"] for check in body["checks"] if not check["ok"]}
    assert ids == {"developer_mode", "ddi_mounted", "tunneld_reachable"}
    for check in body["checks"]:
        if not check["ok"]:
            assert check["remediation"]  # 直し方が必ず入っている


def test_get_preflight_reports_device_not_found(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    _patch_source(monkeypatch, FakeSource(udid=None, facts=None))

    response = client.get("/iphone/screenshot/preflight", headers=auth)

    assert response.status_code == 200
    body = response.json()
    assert body["ready"] is False
    assert body["udid"] is None
    device_check = next(c for c in body["checks"] if c["id"] == "device_connected")
    assert device_check["ok"] is False


def test_get_preflight_ready(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    _patch_source(monkeypatch, FakeSource(facts=READY_FACTS))

    response = client.get("/iphone/screenshot/preflight", headers=auth)

    assert response.status_code == 200
    assert response.json()["ready"] is True


# --- POST /iphone/screenshot ---------------------------------------------------------


def test_post_screenshot_requires_token(client: TestClient) -> None:
    response = client.post("/iphone/screenshot")
    assert response.status_code == 401


def test_post_screenshot_returns_png_on_success(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    png_bytes = b"\x89PNG\r\n\x1a\nsuccess"
    _patch_source(monkeypatch, FakeSource(facts=READY_FACTS, png=png_bytes))

    response = client.post("/iphone/screenshot", headers=auth)

    assert response.status_code == 200
    assert response.headers["content-type"] == "image/png"
    assert response.content == png_bytes


def test_post_screenshot_deletes_temp_file_after_response(
    client: TestClient,
    auth: dict[str, str],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(screenshot_router.screenshot, "DEFAULT_TEMP_DIR", tmp_path)
    _patch_source(monkeypatch, FakeSource(facts=READY_FACTS))

    response = client.post("/iphone/screenshot", headers=auth)

    assert response.status_code == 200
    # BackgroundTask がレスポンス送信後に一時ファイルを消しているはず。
    assert list(tmp_path.glob("*.png")) == []


def test_post_screenshot_returns_409_when_preflight_not_ready(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    _patch_source(monkeypatch, FakeSource(facts=NOT_READY_FACTS))

    response = client.post("/iphone/screenshot", headers=auth)

    assert response.status_code == 409
    detail = response.json()["detail"]
    assert detail["preflight"]["ready"] is False
    missing_ids = {c["id"] for c in detail["preflight"]["checks"] if not c["ok"]}
    assert "developer_mode" in missing_ids


def test_post_screenshot_returns_409_when_device_not_found(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    _patch_source(monkeypatch, FakeSource(udid=None, facts=None))

    response = client.post("/iphone/screenshot", headers=auth)

    assert response.status_code == 409


def test_post_screenshot_returns_502_when_capture_fails(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    _patch_source(
        monkeypatch,
        FakeSource(facts=READY_FACTS, capture_error=RuntimeError("device disconnected")),
    )

    response = client.post("/iphone/screenshot", headers=auth)

    assert response.status_code == 502
    assert "device disconnected" in response.json()["detail"]
