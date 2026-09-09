"""Voice 会話のテキスト履歴（ディスク永続化）。マイク音声は保存しない。"""

from __future__ import annotations

import json
import os
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Literal

VoiceRole = Literal["user", "assistant"]
HistoryKind = Literal["text", "image_prompt", "tool_call"]


@dataclass(frozen=True, slots=True)
class HistoryMessage:
    """1 発話分。audio バイナリは含めない。"""

    role: VoiceRole
    text: str
    ts: float
    kind: HistoryKind = "text"
    tool_name: str = ""
    tool_arguments: str = ""

    def to_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        if not payload["tool_name"]:
            payload.pop("tool_name")
        if not payload["tool_arguments"]:
            payload.pop("tool_arguments")
        return payload

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> HistoryMessage:
        return cls(
            role=str(raw.get("role") or "user"),  # type: ignore[arg-type]
            text=str(raw.get("text") or ""),
            ts=float(raw.get("ts") or 0.0),
            kind=str(raw.get("kind") or "text"),  # type: ignore[arg-type]
            tool_name=str(raw.get("tool_name") or ""),
            tool_arguments=str(raw.get("tool_arguments") or ""),
        )


class VoiceHistoryStore:
    """``{root}/voice/sessions/<id>/history.jsonl`` に追記する。"""

    def __init__(self, root: Path) -> None:
        self._root = Path(root).expanduser().resolve()

    def _session_dir(self, session_id: str) -> Path:
        return self._root / "voice" / "sessions" / session_id

    def _history_path(self, session_id: str) -> Path:
        return self._session_dir(session_id) / "history.jsonl"

    def append(self, session_id: str, message: HistoryMessage) -> None:
        path = self._history_path(session_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps(message.to_dict(), ensure_ascii=False, separators=(",", ":")) + "\n"
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line)

    def list_messages(self, session_id: str) -> list[HistoryMessage]:
        path = self._history_path(session_id)
        if not path.is_file():
            return []
        messages: list[HistoryMessage] = []
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                raw = json.loads(line)
            except ValueError:
                continue
            if isinstance(raw, dict):
                messages.append(HistoryMessage.from_dict(raw))
        return messages

    def record_user_text(
        self,
        session_id: str,
        text: str,
        *,
        kind: HistoryKind = "text",
    ) -> None:
        if not text.strip():
            return
        self.append(
            session_id,
            HistoryMessage(role="user", text=text.strip(), ts=time.time(), kind=kind),
        )

    def record_assistant_text(self, session_id: str, text: str) -> None:
        if not text.strip():
            return
        self.append(
            session_id,
            HistoryMessage(role="assistant", text=text.strip(), ts=time.time(), kind="text"),
        )

    def record_tool_call(self, session_id: str, *, name: str, arguments: str) -> None:
        self.append(
            session_id,
            HistoryMessage(
                role="assistant",
                text="",
                ts=time.time(),
                kind="tool_call",
                tool_name=name,
                tool_arguments=arguments,
            ),
        )

    def write_meta(self, session_id: str, meta: dict[str, Any]) -> None:
        """セッション meta.json を原子的に書く。"""
        path = self._session_dir(session_id) / "meta.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".meta.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
            os.replace(tmp_name, path)
        finally:
            try:
                if os.path.exists(tmp_name):
                    os.unlink(tmp_name)
            except OSError:
                pass

    def read_meta(self, session_id: str) -> dict[str, Any] | None:
        path = self._session_dir(session_id) / "meta.json"
        if not path.is_file():
            return None
        try:
            raw = path.read_text(encoding="utf-8")
            data = json.loads(raw)
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    def list_session_ids(self) -> list[str]:
        base = self._root / "voice" / "sessions"
        if not base.is_dir():
            return []
        return sorted(
            entry.name
            for entry in base.iterdir()
            if entry.is_dir() and (entry / "meta.json").is_file()
        )
