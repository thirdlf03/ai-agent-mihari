"""``device_bridge.commands.screenshot`` の純粋ロジックを検証する。

実機には一切依存しない。``ScreenshotSource`` はすべてフェイクに差し替える。
"""

from __future__ import annotations

from pathlib import Path

import pytest

from device_bridge.commands.screenshot import (
    PreflightCheckId,
    PreflightFacts,
    ScreenshotCaptureError,
    ScreenshotPreflightError,
    capture_and_save,
    capture_screenshot,
    delete_temp_png,
    evaluate_preflight,
    parse_ios_major_version,
    requires_tunneld,
    run_preflight,
    save_temp_png,
)

READY_FACTS = PreflightFacts(
    ios_version="17.5.1",
    developer_mode_enabled=True,
    ddi_mounted=True,
    tunneld_reachable=True,
)


class FakeSource:
    """``ScreenshotSource`` のフェイク実装。"""

    def __init__(
        self,
        *,
        udid: str | None = "UDID-1",
        facts: PreflightFacts | None = READY_FACTS,
        png: bytes = b"\x89PNG\r\n\x1a\nfake",
        capture_error: Exception | None = None,
    ) -> None:
        self._udid = udid
        self._facts = facts
        self._png = png
        self._capture_error = capture_error
        self.capture_calls = 0

    async def find_device(self) -> str | None:
        return self._udid

    async def gather_preflight_facts(self, udid: str) -> PreflightFacts:
        assert self._facts is not None
        return self._facts

    async def capture_png(self, udid: str) -> bytes:
        self.capture_calls += 1
        if self._capture_error is not None:
            raise self._capture_error
        return self._png


# --- parse_ios_major_version / requires_tunneld -----------------------------------


@pytest.mark.parametrize(
    ("version", "expected"),
    [("17.5.1", 17), ("16.0", 16), ("9", 9), (None, None), ("", None), ("abc", None)],
)
def test_parse_ios_major_version(version: str | None, expected: int | None) -> None:
    assert parse_ios_major_version(version) == expected


@pytest.mark.parametrize(
    ("version", "expected"),
    [("17.0", True), ("18.1", True), ("16.7", False), (None, False), ("abc", False)],
)
def test_requires_tunneld(version: str | None, expected: bool) -> None:
    assert requires_tunneld(version) is expected


# --- evaluate_preflight: 各分岐 -----------------------------------------------------


def test_evaluate_preflight_all_ok_is_ready() -> None:
    result = evaluate_preflight(udid="UDID-1", facts=READY_FACTS)

    assert result.ready is True
    assert result.udid == "UDID-1"
    assert result.ios_version == "17.5.1"
    assert all(check.ok for check in result.checks)
    assert all(check.remediation is None for check in result.checks)


def test_evaluate_preflight_no_device_fails_device_check_and_downstream() -> None:
    result = evaluate_preflight(udid=None, facts=None)

    assert result.ready is False
    checks = {check.id: check for check in result.checks}
    assert checks[PreflightCheckId.DEVICE_CONNECTED].ok is False
    assert checks[PreflightCheckId.DEVICE_CONNECTED].remediation is not None
    # デバイス未接続時は developer mode 等の判定はできないため、その他のチェックも失敗させる。
    assert checks[PreflightCheckId.DEVELOPER_MODE].ok is False


def test_evaluate_preflight_developer_mode_disabled() -> None:
    facts = PreflightFacts(
        ios_version="17.0", developer_mode_enabled=False, ddi_mounted=True, tunneld_reachable=True
    )
    result = evaluate_preflight(udid="UDID-1", facts=facts)

    assert result.ready is False
    checks = {check.id: check for check in result.checks}
    assert checks[PreflightCheckId.DEVELOPER_MODE].ok is False
    assert "amfi enable-developer-mode" in checks[PreflightCheckId.DEVELOPER_MODE].remediation
    # 他のチェックには影響しない。
    assert checks[PreflightCheckId.DDI_MOUNTED].ok is True


def test_evaluate_preflight_developer_mode_unknown_mentions_uncertainty() -> None:
    facts = PreflightFacts(
        ios_version="17.0", developer_mode_enabled=None, ddi_mounted=True, tunneld_reachable=True
    )
    result = evaluate_preflight(udid="UDID-1", facts=facts)

    checks = {check.id: check for check in result.checks}
    assert checks[PreflightCheckId.DEVELOPER_MODE].ok is False
    assert "確認できなかった" in checks[PreflightCheckId.DEVELOPER_MODE].remediation


def test_evaluate_preflight_ddi_not_mounted() -> None:
    facts = PreflightFacts(
        ios_version="16.0", developer_mode_enabled=True, ddi_mounted=False, tunneld_reachable=None
    )
    result = evaluate_preflight(udid="UDID-1", facts=facts)

    assert result.ready is False
    checks = {check.id: check for check in result.checks}
    assert checks[PreflightCheckId.DDI_MOUNTED].ok is False
    assert "auto-mount" in checks[PreflightCheckId.DDI_MOUNTED].remediation
    # iOS 16 では tunneld は不要なので ok のまま。
    assert checks[PreflightCheckId.TUNNELD_REACHABLE].ok is True


def test_evaluate_preflight_ios16_skips_tunneld_check() -> None:
    facts = PreflightFacts(
        ios_version="16.7", developer_mode_enabled=True, ddi_mounted=True, tunneld_reachable=None
    )
    result = evaluate_preflight(udid="UDID-1", facts=facts)

    assert result.ready is True
    checks = {check.id: check for check in result.checks}
    assert checks[PreflightCheckId.TUNNELD_REACHABLE].ok is True
    assert "不要" in checks[PreflightCheckId.TUNNELD_REACHABLE].label


def test_evaluate_preflight_ios17_requires_tunneld() -> None:
    facts = PreflightFacts(
        ios_version="17.0", developer_mode_enabled=True, ddi_mounted=True, tunneld_reachable=False
    )
    result = evaluate_preflight(udid="UDID-1", facts=facts)

    assert result.ready is False
    checks = {check.id: check for check in result.checks}
    assert checks[PreflightCheckId.TUNNELD_REACHABLE].ok is False
    assert "start_tunneld.sh" in checks[PreflightCheckId.TUNNELD_REACHABLE].remediation


def test_missing_labels_lists_only_failed_checks() -> None:
    facts = PreflightFacts(
        ios_version="17.0", developer_mode_enabled=False, ddi_mounted=False, tunneld_reachable=False
    )
    result = evaluate_preflight(udid="UDID-1", facts=facts)

    labels = result.missing_labels()
    assert "Developer Mode が有効" in labels
    assert "DeveloperDiskImage がマウント済み" in labels
    assert "tunneld に到達できる" in labels
    assert "iPhone に接続できる" not in labels


# --- run_preflight / capture_screenshot ---------------------------------------------


async def test_run_preflight_no_device() -> None:
    source = FakeSource(udid=None, facts=None)

    result = await run_preflight(source)

    assert result.ready is False
    assert result.udid is None


async def test_run_preflight_ready() -> None:
    source = FakeSource()

    result = await run_preflight(source)

    assert result.ready is True


async def test_capture_screenshot_raises_preflight_error_when_not_ready() -> None:
    facts = PreflightFacts(
        ios_version="17.0", developer_mode_enabled=False, ddi_mounted=True, tunneld_reachable=True
    )
    source = FakeSource(facts=facts)

    with pytest.raises(ScreenshotPreflightError) as excinfo:
        await capture_screenshot(source)

    assert excinfo.value.result.ready is False
    assert source.capture_calls == 0  # 前提が揃わないうちは撮影を試みない


async def test_capture_screenshot_raises_capture_error_on_lower_layer_failure() -> None:
    source = FakeSource(capture_error=RuntimeError("device disconnected"))

    with pytest.raises(ScreenshotCaptureError, match="device disconnected"):
        await capture_screenshot(source)


async def test_capture_screenshot_returns_png_and_result_when_ready() -> None:
    source = FakeSource(png=b"\x89PNG\r\n\x1a\nabc")

    png, result = await capture_screenshot(source)

    assert png == b"\x89PNG\r\n\x1a\nabc"
    assert result.ready is True
    assert source.capture_calls == 1


# --- 一時ファイルの保存・削除 --------------------------------------------------------


def test_save_temp_png_writes_file_under_directory(tmp_path: Path) -> None:
    path = save_temp_png(b"binary-data", directory=tmp_path)

    assert path.parent == tmp_path
    assert path.suffix == ".png"
    assert path.read_bytes() == b"binary-data"


def test_save_temp_png_creates_missing_directory(tmp_path: Path) -> None:
    directory = tmp_path / "nested" / "dir"

    path = save_temp_png(b"data", directory=directory)

    assert path.exists()


def test_delete_temp_png_removes_file(tmp_path: Path) -> None:
    path = save_temp_png(b"data", directory=tmp_path)
    assert path.exists()

    delete_temp_png(path)

    assert not path.exists()


def test_delete_temp_png_is_idempotent(tmp_path: Path) -> None:
    path = tmp_path / "already-gone.png"

    delete_temp_png(path)  # 例外を投げないこと


async def test_capture_and_save_writes_then_returns_path(tmp_path: Path) -> None:
    source = FakeSource(png=b"\x89PNG\r\n\x1a\nxyz")

    path, result = await capture_and_save(source, directory=tmp_path)

    assert path.read_bytes() == b"\x89PNG\r\n\x1a\nxyz"
    assert result.ready is True

    delete_temp_png(path)
    assert not path.exists()
