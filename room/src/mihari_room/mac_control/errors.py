"""Mac 操作の失敗。Room 側ツールが Hermes へ返す JSON の ``code`` と本文の正本。"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


#: 失敗の分類。ツールの戻り値は常に JSON 文字列で
#: ``{"success": false, "code": ..., "error": ...}``。
#: code は Hermes が機械的に扱える安定した識別子（変えない）。
class MacControlErrorCode:
    #: Room の Mac 操作が無効 / 準備できていない（loop 未接続など）。
    UNAVAILABLE = "unavailable"
    #: その依頼（ジョブ）の実行ラベル（run）が分からない / もう終わっている。
    UNKNOWN_RUN = "unknown_run"
    #: その run ではまだ Mac に許可をもらっていない（または既定で拒否）。
    NO_PERMISSION = "no_permission"
    #: Mac 側でユーザーが拒否した。
    DENIED = "denied"
    #: 許可待ちが時間切れ（既定は拒否扱い）。
    PERMISSION_TIMEOUT = "permission_timeout"
    #: 操作を要求された端末が違う（この run を許可した Mac ではない）。
    WRONG_DEVICE = "wrong_device"
    #: 要求されたジョブが、この run のジョブと違う。
    WRONG_JOB = "wrong_job"
    #: 操作 ID の重複（同じ run で同じ op_id を二度使った / 結果不明の再送）。
    DUPLICATE_OP = "duplicate_op"
    #: 別の操作が実行中のため受け付けられない（一度に 1 操作）。
    BUSY = "busy"
    #: Mac がまだ撮影されていない。先に mac_capture で撮る必要がある。
    NO_CAPTURE = "no_capture"
    #: 撮影後の画面構成と違う座標（古い画面構成による操作）。再撮影が必要。
    STALE_LAYOUT = "stale_layout"
    #: 端末から古い画面構成を理由に拒否された。
    LAYOUT_CHANGED = "layout_changed"
    #: Mac が繋がっていない（認証付き WebSocket が無い）。
    NO_DEVICE = "no_device"
    #: Mac が切断・ロック・アプリ終了などで許可を失効させた。
    PERMISSION_LOST = "permission_lost"
    #: 実行結果が不明（切断・停止の直後）。自動再送はしない。
    UNKNOWN_OUTCOME = "unknown_outcome"
    #: 依頼が中断された（キャンセル）。実行前の操作は破棄。
    CANCELLED = "cancelled"
    #: 操作パラメータが不正。
    INVALID_PARAMS = "invalid_params"
    #: Mac 側の権限（画面収録・アクセシビリティ）が足りない。
    MAC_PERMISSION_MISSING = "mac_permission_missing"
    #: Mac で実行に失敗した（code は端末から）。
    EXECUTION_FAILED = "execution_failed"
    #: 予期しない内部エラー。
    INTERNAL = "internal"


@dataclass(frozen=True, slots=True)
class MacControlError(Exception):
    """Room 側で完結する拒否。Hermes へ JSON のまま返す。"""

    code: str
    message: str
    detail: dict[str, Any] | None = None

    def __str__(self) -> str:
        return f"{self.code}: {self.message}"

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {"success": False, "code": self.code, "error": self.message}
        if self.detail:
            payload["detail"] = self.detail
        return payload
