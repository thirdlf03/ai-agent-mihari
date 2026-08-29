"""iPhone のスクリーンショット取得と、そのための前提診断(セルフチェック)。

``pymobiledevice3 developer screenshot`` 相当の機能は、次の 3 つが揃って初めて動く。

1. Developer Mode が有効になっている
2. DeveloperDiskImage(DDI)がマウントされている(iOS 17+ では ``Personalized`` イメージ)
3. iOS 17+ の場合、developer 系サービスは tunneld 経由の RemoteXPC トンネルでしか
   届かないため、tunneld がそのデバイス向けのトンネルを張っていること

当日のセットアップでどれか 1 つでも欠けると撮影は失敗する。このモジュールは
「どれが欠けているか」を個別に判定し、直すための具体的なコマンドまで返す。

実機との通信(lockdown 接続・developer mode 照会・DDI マウント確認・tunneld への
到達確認・実際のキャプチャ)は ``ScreenshotSource`` プロトコルの背後に隔離してあり、
このモジュールはそれ以外の一切の実機依存を持たない。実機が無い環境でも import・実行
でき、テストではフェイクの ``ScreenshotSource`` に差し替えて検証する。
"""

from __future__ import annotations

import contextlib
import re
import tempfile
import uuid
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Any, Protocol

#: 一時ファイルの既定の置き場。macOS アプリと同じ Mac 上の一時領域を使う。
DEFAULT_TEMP_DIR = Path(tempfile.gettempdir()) / "device-bridge" / "screenshots"

#: このバージョン以降、developer 系サービスに tunneld(RemoteXPC トンネル)が要る。
TUNNELD_REQUIRED_MAJOR_VERSION = 17


class PreflightCheckId(StrEnum):
    """セルフチェックの各項目を識別する ID。Swift 側もこの値で分岐してよい。"""

    DEVICE_CONNECTED = "device_connected"
    DEVELOPER_MODE = "developer_mode"
    DDI_MOUNTED = "ddi_mounted"
    TUNNELD_REACHABLE = "tunneld_reachable"


@dataclass(frozen=True, slots=True)
class PreflightCheck:
    """セルフチェック 1 項目の結果。"""

    id: PreflightCheckId
    ok: bool
    label: str
    #: 直すための具体的なコマンド・手順。``ok`` なら ``None``。
    remediation: str | None = None

    def to_payload(self) -> dict[str, Any]:
        return {
            "id": self.id.value,
            "ok": self.ok,
            "label": self.label,
            "remediation": self.remediation,
        }


@dataclass(frozen=True, slots=True)
class PreflightResult:
    """セルフチェック全体の結果。"""

    ready: bool
    udid: str | None
    ios_version: str | None
    checks: tuple[PreflightCheck, ...]

    def to_payload(self) -> dict[str, Any]:
        return {
            "ready": self.ready,
            "udid": self.udid,
            "ios_version": self.ios_version,
            "checks": [check.to_payload() for check in self.checks],
        }

    def missing_labels(self) -> list[str]:
        """欠けている項目のラベルだけを並べる。エラーメッセージの組み立てに使う。"""
        return [check.label for check in self.checks if not check.ok]


@dataclass(frozen=True, slots=True)
class PreflightFacts:
    """実機から集めた生の事実。``ScreenshotSource.gather_preflight_facts`` が作る。

    いずれのフィールドも、取得できなかった(接続失敗・タイムアウトなど)場合は
    ``None`` になる。``None`` は「無効/未マウント」とは区別して扱う。
    """

    ios_version: str | None
    developer_mode_enabled: bool | None
    ddi_mounted: bool | None
    #: iOS 17 未満では判定不要なので常に ``None``。17+ では到達できたかどうか。
    tunneld_reachable: bool | None


def parse_ios_major_version(ios_version: str | None) -> int | None:
    """``"17.5.1"`` のようなバージョン文字列からメジャーバージョンを取り出す。"""
    if not ios_version:
        return None
    match = re.match(r"\d+", ios_version.strip())
    return int(match.group()) if match else None


def requires_tunneld(ios_version: str | None) -> bool:
    """このバージョンで tunneld 経由の到達確認が必要かどうか。"""
    major = parse_ios_major_version(ios_version)
    return major is not None and major >= TUNNELD_REQUIRED_MAJOR_VERSION


def _device_connected_check(udid: str | None) -> PreflightCheck:
    if udid is not None:
        return PreflightCheck(PreflightCheckId.DEVICE_CONNECTED, True, "iPhone に接続できる")
    return PreflightCheck(
        PreflightCheckId.DEVICE_CONNECTED,
        False,
        "iPhone に接続できる",
        remediation=(
            "iPhone を USB で接続するか、同じ Wi-Fi 上にあることを確認したうえで "
            "`uv run device-bridge list` に UDID が出るか確認する"
        ),
    )


def _developer_mode_check(enabled: bool | None) -> PreflightCheck:
    if enabled is True:
        return PreflightCheck(PreflightCheckId.DEVELOPER_MODE, True, "Developer Mode が有効")
    remediation = (
        "iPhone で 設定 > プライバシーとセキュリティ > Developer Mode をオンにして再起動する。"
        "CLI からなら `uv run pymobiledevice3 amfi enable-developer-mode`"
        "(端末再起動後の確認プロンプトまで自動応答する)"
    )
    if enabled is None:
        remediation = "状態を確認できなかった(接続を確認してから再試行する)。" + remediation
    return PreflightCheck(
        PreflightCheckId.DEVELOPER_MODE, False, "Developer Mode が有効", remediation=remediation
    )


def _ddi_mounted_check(mounted: bool | None) -> PreflightCheck:
    if mounted is True:
        return PreflightCheck(
            PreflightCheckId.DDI_MOUNTED, True, "DeveloperDiskImage がマウント済み"
        )
    remediation = (
        "`uv run pymobiledevice3 mounter auto-mount` で DeveloperDiskImage をマウントする"
        "(初回はイメージのダウンロードが走る)"
    )
    if mounted is None:
        remediation = (
            "状態を確認できなかった(Developer Mode が先に必要な場合がある)。" + remediation
        )
    return PreflightCheck(
        PreflightCheckId.DDI_MOUNTED,
        False,
        "DeveloperDiskImage がマウント済み",
        remediation=remediation,
    )


def _tunneld_check(ios_version: str | None, reachable: bool | None) -> PreflightCheck:
    if not requires_tunneld(ios_version):
        return PreflightCheck(
            PreflightCheckId.TUNNELD_REACHABLE,
            True,
            "tunneld に到達できる(iOS 17 未満のため不要)",
        )
    if reachable is True:
        return PreflightCheck(PreflightCheckId.TUNNELD_REACHABLE, True, "tunneld に到達できる")
    remediation = (
        "root で tunneld を常駐させる: `sudo bridge/scripts/start_tunneld.sh`"
        "(内部で `pymobiledevice3 remote tunneld` を実行する)。"
        "起動直後は端末側のトンネル確立に数秒かかる"
    )
    return PreflightCheck(
        PreflightCheckId.TUNNELD_REACHABLE, False, "tunneld に到達できる", remediation=remediation
    )


def evaluate_preflight(udid: str | None, facts: PreflightFacts | None) -> PreflightResult:
    """収集した事実からセルフチェック結果を組み立てる。

    :param udid: 見つかったデバイスの UDID。見つからなければ ``None``。
    :param facts: ``udid`` が ``None`` のときは無視してよい(集めていないため)。
    """
    ios_version = facts.ios_version if facts is not None else None
    developer_mode_enabled = facts.developer_mode_enabled if facts is not None else None
    ddi_mounted = facts.ddi_mounted if facts is not None else None
    tunneld_reachable = facts.tunneld_reachable if facts is not None else None

    checks = (
        _device_connected_check(udid),
        _developer_mode_check(developer_mode_enabled),
        _ddi_mounted_check(ddi_mounted),
        _tunneld_check(ios_version, tunneld_reachable),
    )
    return PreflightResult(
        ready=all(check.ok for check in checks),
        udid=udid,
        ios_version=ios_version,
        checks=checks,
    )


class ScreenshotSource(Protocol):
    """実機とやり取りする薄い層のインターフェース。テストではフェイクに差し替える。"""

    async def find_device(self) -> str | None:
        """接続中(USB または Wi-Fi)の既知デバイスの UDID を 1 つ探す。"""
        ...

    async def gather_preflight_facts(self, udid: str) -> PreflightFacts:
        """セルフチェックに必要な事実を集める。個々の取得失敗は ``None`` に丸めてよい。"""
        ...

    async def capture_png(self, udid: str) -> bytes:
        """スクリーンショットを撮り、PNG バイト列を返す。

        前提(Developer Mode / DDI / tunneld)が揃っていない場合は例外を送出してよい。
        呼び出し側(``capture_screenshot``)は事前に ``run_preflight`` を通すため、
        通常はここに来た時点で前提は揃っている想定。
        """
        ...


class ScreenshotPreflightError(Exception):
    """前提(Developer Mode / DDI / tunneld のいずれか)が欠けているときに送出する。"""

    def __init__(self, result: PreflightResult) -> None:
        self.result = result
        missing = "、".join(result.missing_labels()) or "不明な項目"
        super().__init__(f"スクリーンショットの前提が揃っていない: {missing}")


class ScreenshotCaptureError(Exception):
    """前提は揃っているが、撮影そのものが失敗したときに送出する。"""


async def run_preflight(source: ScreenshotSource) -> PreflightResult:
    """デバイスを探し、見つかれば事実を集めてセルフチェック結果を返す。"""
    udid = await source.find_device()
    if udid is None:
        return evaluate_preflight(udid=None, facts=None)
    facts = await source.gather_preflight_facts(udid)
    return evaluate_preflight(udid=udid, facts=facts)


async def capture_screenshot(source: ScreenshotSource) -> tuple[bytes, PreflightResult]:
    """前提を確認したうえでスクリーンショットを撮る。

    :raises ScreenshotPreflightError: 前提が 1 つでも欠けているとき。
    :raises ScreenshotCaptureError: 前提は揃っているが撮影自体が失敗したとき。
    :returns: ``(PNG バイト列, 撮影時点のセルフチェック結果)``。
    """
    result = await run_preflight(source)
    if not result.ready:
        raise ScreenshotPreflightError(result)

    assert result.udid is not None  # ready なら device_connected も ok のはず
    try:
        png = await source.capture_png(result.udid)
    except Exception as error:  # noqa: BLE001 - 下層の例外を種類問わず捕捉して意味づけする
        raise ScreenshotCaptureError(f"スクリーンショットの取得に失敗した: {error}") from error
    return png, result


def save_temp_png(data: bytes, *, directory: Path | None = None) -> Path:
    """PNG バイト列を一時ファイルへ保存し、そのパスを返す。

    送信後は ``delete_temp_png`` で必ず消す想定(ルーターが ``BackgroundTask`` で行う)。

    :param directory: 保存先ディレクトリ。省略時は ``DEFAULT_TEMP_DIR``(呼び出し時点の値。
        デフォルト引数として束縛しないことで、テストからのモジュール属性差し替えを効かせる)。
    """
    target = directory if directory is not None else DEFAULT_TEMP_DIR
    target.mkdir(parents=True, exist_ok=True)
    path = target / f"{uuid.uuid4().hex}.png"
    path.write_bytes(data)
    return path


def delete_temp_png(path: Path) -> None:
    """一時ファイルを削除する。すでに無くてもエラーにしない。"""
    with contextlib.suppress(FileNotFoundError):
        path.unlink()


async def capture_and_save(
    source: ScreenshotSource, *, directory: Path | None = None
) -> tuple[Path, PreflightResult]:
    """撮影して一時ファイルへ保存する。ルーターから呼ぶ想定の組み立て関数。

    :param directory: 保存先ディレクトリ。省略時は呼び出し時点の ``DEFAULT_TEMP_DIR``。
    """
    png, result = await capture_screenshot(source)
    path = save_temp_png(png, directory=directory)
    return path, result
