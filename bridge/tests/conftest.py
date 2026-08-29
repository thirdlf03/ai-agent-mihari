"""テスト共通のフィクスチャ。"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from device_bridge.daemon.app import create_app
from device_bridge.daemon.config import DaemonConfig

TOKEN = "test-token"


@pytest.fixture
def client() -> TestClient:
    """認証トークンを固定したテストクライアント。"""
    app = create_app(DaemonConfig(token=TOKEN))
    return TestClient(app)


@pytest.fixture
def auth() -> dict[str, str]:
    return {"X-Mihari-Token": TOKEN}
