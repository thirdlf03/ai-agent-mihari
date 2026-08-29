"""デーモン設定のバリデーション。"""

from __future__ import annotations

import pytest

from device_bridge.daemon.config import DaemonConfig


def test_token_is_required() -> None:
    with pytest.raises(ValueError, match="token"):
        DaemonConfig(token="")


def test_port_must_be_in_range() -> None:
    with pytest.raises(ValueError, match="port"):
        DaemonConfig(token="t", port=70000)


def test_non_loopback_host_is_rejected() -> None:
    # カメラ画像や画面を扱うため、外から届く経路を設定ミスで作れないようにしている。
    with pytest.raises(ValueError, match="ループバック"):
        DaemonConfig(token="t", host="0.0.0.0")


def test_defaults_to_loopback_and_ephemeral_port() -> None:
    config = DaemonConfig(token="t")
    assert config.host == "127.0.0.1"
    assert config.port == 0
