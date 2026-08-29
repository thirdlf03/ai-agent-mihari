"""トークン認証。"""

from __future__ import annotations

from fastapi.testclient import TestClient


def test_health_needs_no_token(client: TestClient) -> None:
    # 生死確認だけはトークン無しで通す。アプリが起動直後に叩けるようにするため。
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_devices_without_token_is_rejected(client: TestClient) -> None:
    assert client.get("/devices").status_code == 401


def test_devices_with_wrong_token_is_rejected(client: TestClient) -> None:
    response = client.get("/devices", headers={"X-Mihari-Token": "wrong"})
    assert response.status_code == 401


def test_events_without_token_is_rejected(client: TestClient) -> None:
    assert client.get("/events").status_code == 401
    assert client.post("/events/publish", json={"name": "x"}).status_code == 401
