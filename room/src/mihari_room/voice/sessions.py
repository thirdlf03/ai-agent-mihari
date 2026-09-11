"""Realtime セッションのメタデータ・同時通話ガード・永続化。"""

from __future__ import annotations

import asyncio
import re
import secrets
import time
from dataclasses import dataclass, field
from typing import Any

from mihari_room.config import RoomConfig
from mihari_room.voice.history import HistoryKind, HistoryMessage, VoiceHistoryStore
from mihari_room.voice.protocol import SessionStatus

#: session_id は ``secrets.token_urlsafe(16)``（22 文字）を想定。
#: 履歴ディレクトリのパス連結前に、この形に合わない id を入口で弾く。
SESSION_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")


class ConcurrentVoiceSessionError(RuntimeError):
    """同時に 1 セッションだけ許可。"""


class VoiceStreamBusyError(RuntimeError):
    """別セッションまたは同一セッションで既にストリーム中。"""


@dataclass
class VoiceSession:
    """1 会話セッション分の状態。"""

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

    def to_meta(self) -> dict[str, Any]:
        return {
            "session_id": self.id,
            "model": self.model,
            "status": self.status.value,
            "created_at": self.created_at,
            "closed_at": self.closed_at,
            "error": self.error,
            "upstream_audio_output_events": self.upstream_audio_output_events,
        }

    @classmethod
    def from_meta(cls, meta: dict[str, Any]) -> VoiceSession:
        status_raw = str(meta.get("status") or SessionStatus.CREATED.value)
        try:
            status = SessionStatus(status_raw)
        except ValueError:
            status = SessionStatus.CREATED
        if status is SessionStatus.STREAMING:
            status = SessionStatus.CREATED
        return cls(
            id=str(meta["session_id"]),
            model=str(meta.get("model") or ""),
            status=status,
            created_at=float(meta.get("created_at") or time.time()),
            closed_at=meta.get("closed_at"),
            error=str(meta.get("error") or ""),
            upstream_audio_output_events=int(meta.get("upstream_audio_output_events") or 0),
        )


class VoiceSessionManager:
    """プロセス内の voice セッション台帳 + ディスク永続化。"""

    def __init__(self, config: RoomConfig) -> None:
        self._config = config
        self._sessions: dict[str, VoiceSession] = {}
        self._store = VoiceHistoryStore(config.root)
        self._stream_session_id: str | None = None
        self._stream_lock = asyncio.Lock()
        self._load_persisted_sessions()

    @property
    def config(self) -> RoomConfig:
        return self._config

    @property
    def history_store(self) -> VoiceHistoryStore:
        return self._store

    def voice_enabled(self) -> bool:
        return bool(self._config.openai_api_key)

    def _load_persisted_sessions(self) -> None:
        for session_id in self._store.list_session_ids():
            meta = self._store.read_meta(session_id)
            if meta is None:
                continue
            session = VoiceSession.from_meta(meta)
            if session.status not in {SessionStatus.CLOSED, SessionStatus.ERROR}:
                self._sessions[session_id] = session

    def _persist(self, session: VoiceSession) -> None:
        self._store.write_meta(session.id, session.to_meta())

    def find_open_session(self) -> VoiceSession | None:
        for session in self._sessions.values():
            if session.status not in {SessionStatus.CLOSED, SessionStatus.ERROR}:
                return session
        return None

    def create_session(self) -> VoiceSession:
        if self.find_open_session() is not None:
            raise ConcurrentVoiceSessionError("voice session already active")
        session_id = secrets.token_urlsafe(16)
        session = VoiceSession(id=session_id, model=self._config.voice_realtime_model)
        self._sessions[session_id] = session
        self._persist(session)
        return session

    def get(self, session_id: str) -> VoiceSession | None:
        if not SESSION_ID_PATTERN.match(session_id):
            return None
        session = self._sessions.get(session_id)
        if session is not None:
            return session
        meta = self._store.read_meta(session_id)
        if meta is None:
            return None
        session = VoiceSession.from_meta(meta)
        self._sessions[session_id] = session
        return session

    def get_history(self, session_id: str) -> list[HistoryMessage]:
        return self._store.list_messages(session_id)

    def history_to_dicts(self, session_id: str) -> list[dict[str, Any]]:
        return [message.to_dict() for message in self.get_history(session_id)]

    def record_user_text(
        self, session_id: str, text: str, *, kind: HistoryKind = "text"
    ) -> None:
        if not self._accepts_history(session_id):
            return
        self._store.record_user_text(session_id, text, kind=kind)

    def record_assistant_text(self, session_id: str, text: str) -> None:
        if not self._accepts_history(session_id):
            return
        self._store.record_assistant_text(session_id, text)

    def record_tool_call(self, session_id: str, *, name: str, arguments: str) -> None:
        if not self._accepts_history(session_id):
            return
        self._store.record_tool_call(session_id, name=name, arguments=arguments)

    def _accepts_history(self, session_id: str) -> bool:
        """CLOSED/ERROR のセッションには履歴を追記しない。"""
        session = self.get(session_id)
        return session is not None and session.status not in {
            SessionStatus.CLOSED,
            SessionStatus.ERROR,
        }

    async def acquire_stream(self, session_id: str) -> None:
        async with self._stream_lock:
            if self._stream_session_id is not None:
                raise VoiceStreamBusyError("another voice stream is active")
            session = self.get(session_id)
            if session is None:
                raise KeyError(session_id)
            if session.status in {SessionStatus.CLOSED, SessionStatus.ERROR}:
                raise VoiceStreamBusyError("session is closed")
            self._stream_session_id = session_id

    async def release_stream(self, session_id: str) -> None:
        async with self._stream_lock:
            if self._stream_session_id == session_id:
                self._stream_session_id = None

    def mark_streaming(self, session_id: str) -> None:
        session = self._require(session_id)
        session.status = SessionStatus.STREAMING
        self._persist(session)

    def mark_idle(self, session_id: str) -> None:
        session = self._require(session_id)
        session.status = SessionStatus.CREATED
        self._persist(session)

    def close_session(self, session_id: str, *, reason: str = "") -> None:
        session = self._require(session_id)
        session.status = SessionStatus.ERROR if reason else SessionStatus.CLOSED
        session.error = reason
        session.closed_at = time.time()
        self._persist(session)

    def mark_closed(self, session_id: str, *, reason: str = "") -> None:
        self.close_session(session_id, reason=reason)

    def note_upstream_audio_output(self, session_id: str) -> None:
        session = self.get(session_id)
        if session is None or session.status in {
            SessionStatus.CLOSED,
            SessionStatus.ERROR,
        }:
            return
        session.upstream_audio_output_events += 1
        self._persist(session)

    def _require(self, session_id: str) -> VoiceSession:
        session = self.get(session_id)
        if session is None:
            raise KeyError(session_id)
        return session
