"""FastAPI アプリの組み立て。"""

from __future__ import annotations

from fastapi import FastAPI

from device_bridge.daemon.config import DaemonConfig
from device_bridge.daemon.events import EventBus
from device_bridge.daemon.routers import devices, events, health, voice
from device_bridge.voice.generator import LineGenerator
from device_bridge.voice.voicevox import VoicevoxClient


def create_app(config: DaemonConfig) -> FastAPI:
    """設定からアプリを作る。テストからも同じ経路で組み立てる。"""
    app = FastAPI(
        title="Mihari device-bridge daemon",
        version="0.1.0",
        # ローカル専用のプロセスなので、対話ドキュメントは出さない。
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.config = config
    app.state.events = EventBus()
    app.state.line_generator = LineGenerator()
    app.state.voicevox = VoicevoxClient()

    app.include_router(health.router)
    app.include_router(devices.router)
    app.include_router(events.router)
    app.include_router(voice.router)
    return app
