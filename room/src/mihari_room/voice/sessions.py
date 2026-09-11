"""Realtime セッションのメタデータ。upstream 接続は WS ハンドラが担う。"""

from __future__ import annotations

import secrets
import time
from dataclasses import dataclass, field
from typing import Any

from mihari_room.config import RoomConfig
from mihari_room.voice.protocol import SessionStatus


@dataclass
class VoiceSession:
    """1 クライアント接続分の状態。"""

    id: str
    model: str
    status: SessionStatus = SessionStatus.CREATED
    created_at: float = field(default_factory=time.time)
    closed_at: float | None = None
    error: str = ""
    #: upstream から観測したモデル音声出力イベント数（課金確認用）。
    upstream_audio_output_events: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "session_id": self.id,
            "model": self.model,
            "status": self.status.value,
            "created_at": self.created_at,
            "closed_at": self.closed_at,
            "error": self.error or None,
            "upstream_audio_output_events": self.upstream_audio_output_events,
            "output_modalities": ["text"],
        }


class VoiceSessionManager:
    """プロセス内の voice セッション台帳。"""

    def __init__(self, config: RoomConfig) -> None:
        self._config = config
        self._sessions: dict[str, VoiceSession] = {}

    @property
    def config(self) -> RoomConfig:
        return self._config

    def voice_enabled(self) -> bool:
        return bool(self._config.openai_api_key)

    def create_session(self) -> VoiceSession:
        session_id = secrets.token_urlsafe(16)
        session = VoiceSession(id=session_id, model=self._config.voice_realtime_model)
        self._sessions[session_id] = session
        return session

    def get(self, session_id: str) -> VoiceSession | None:
        return self._sessions.get(session_id)

    def mark_streaming(self, session_id: str) -> None:
        session = self._require(session_id)
        session.status = SessionStatus.STREAMING

    def mark_closed(self, session_id: str, *, reason: str = "") -> None:
        session = self._require(session_id)
        session.status = SessionStatus.ERROR if reason else SessionStatus.CLOSED
        session.error = reason
        session.closed_at = time.time()

    def note_upstream_audio_output(self, session_id: str) -> None:
        session = self._require(session_id)
        session.upstream_audio_output_events += 1

    def _require(self, session_id: str) -> VoiceSession:
        session = self._sessions.get(session_id)
        if session is None:
            raise KeyError(session_id)
        return session
