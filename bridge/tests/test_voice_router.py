"""セリフのエンドポイント。"""

from __future__ import annotations

import base64
from typing import Any

from fastapi.testclient import TestClient

from device_bridge.voice.context import Escalation, IPhoneState, SpeechContext, VisionLabel
from device_bridge.voice.generator import GeneratedLine
from device_bridge.voice.voicevox import VoicevoxUnavailableError

WAV = b"RIFF....WAVE"


class _StubGenerator:
    def __init__(self, line: GeneratedLine) -> None:
        self._line = line
        self.seen: list[SpeechContext] = []
        self.is_configured = True
        self.model = "test-model"

    async def generate(self, context: SpeechContext) -> GeneratedLine:
        self.seen.append(context)
        return self._line


class _StubVoicevox:
    def __init__(self, *, audio: bytes | None = WAV) -> None:
        self._audio = audio
        self.base_url = "http://engine"
        self.speaker = 1
        self.cached_count = 0

    async def is_reachable(self) -> bool:
        return self._audio is not None

    async def synthesize(self, text: str, *, speaker: int | None = None) -> bytes:
        if self._audio is None:
            raise VoicevoxUnavailableError("VOICEVOX に繋がらない(http://engine)")
        return self._audio


def _install(client: TestClient, generator: Any, voicevox: Any) -> None:
    client.app.state.line_generator = generator
    client.app.state.voicevox = voicevox


def test_line_returns_the_generated_text(client: TestClient, auth: dict[str, str]) -> None:
    generator = _StubGenerator(GeneratedLine(text="手が止まってますよ", from_llm=True))
    _install(client, generator, _StubVoicevox())

    response = client.post("/voice/line", json={"idle_seconds": 300}, headers=auth)

    assert response.status_code == 200
    assert response.json() == {
        "text": "手が止まってますよ",
        "from_llm": True,
        "fallback_reason": None,
    }


def test_line_parses_every_signal(client: TestClient, auth: dict[str, str]) -> None:
    generator = _StubGenerator(GeneratedLine(text="はい", from_llm=True))
    _install(client, generator, _StubVoicevox())

    client.post(
        "/voice/line",
        json={
            "idle_seconds": 120,
            "escalation": "expose",
            "frontmost_app": "Safari",
            "iphone": "active",
            "vision": "sleeping",
        },
        headers=auth,
    )

    context = generator.seen[0]
    assert context.idle_seconds == 120
    assert context.escalation is Escalation.EXPOSE
    assert context.frontmost_app == "Safari"
    assert context.iphone is IPhoneState.ACTIVE
    assert context.vision is VisionLabel.SLEEPING


def test_unknown_enum_values_fall_back_to_defaults(
    client: TestClient, auth: dict[str, str]
) -> None:
    # 送り手と受け手の版がずれても喋り続ける方を選んでいる。
    generator = _StubGenerator(GeneratedLine(text="はい", from_llm=True))
    _install(client, generator, _StubVoicevox())

    response = client.post(
        "/voice/line",
        json={"idle_seconds": 1, "escalation": "未知", "vision": "未知"},
        headers=auth,
    )

    assert response.status_code == 200
    assert generator.seen[0].escalation is Escalation.NUDGE
    assert generator.seen[0].vision is VisionLabel.UNKNOWN


def test_invalid_idle_seconds_is_422(client: TestClient, auth: dict[str, str]) -> None:
    _install(client, _StubGenerator(GeneratedLine(text="x", from_llm=True)), _StubVoicevox())

    response = client.post("/voice/line", json={"idle_seconds": -5}, headers=auth)

    assert response.status_code == 422


def test_speak_returns_base64_audio(client: TestClient, auth: dict[str, str]) -> None:
    _install(client, _StubGenerator(GeneratedLine(text="やあ", from_llm=True)), _StubVoicevox())

    body = client.post("/voice/speak", json={"idle_seconds": 60}, headers=auth).json()

    assert base64.b64decode(body["audio"]) == WAV
    assert body["audio_error"] is None


def test_speak_still_returns_the_line_when_the_engine_is_down(
    client: TestClient, auth: dict[str, str]
) -> None:
    # 喋れないことは検知や送信を止める理由にならないので、200 で返してテキストは渡す。
    _install(
        client,
        _StubGenerator(GeneratedLine(text="やあ", from_llm=False, fallback_reason="キー未設定")),
        _StubVoicevox(audio=None),
    )

    response = client.post("/voice/speak", json={"idle_seconds": 60}, headers=auth)

    assert response.status_code == 200
    body = response.json()
    assert body["text"] == "やあ"
    assert body["audio"] is None
    assert "繋がらない" in body["audio_error"]


def test_status_reports_what_is_missing(client: TestClient, auth: dict[str, str]) -> None:
    _install(
        client, _StubGenerator(GeneratedLine(text="x", from_llm=True)), _StubVoicevox(audio=None)
    )

    body = client.get("/voice/status", headers=auth).json()

    assert body["llm_configured"] is True
    assert body["llm_model"] == "test-model"
    assert body["voicevox_reachable"] is False
    assert body["voicevox_url"] == "http://engine"


def test_voice_endpoints_need_a_token(client: TestClient) -> None:
    assert client.get("/voice/status").status_code == 401
    assert client.post("/voice/line", json={}).status_code == 401
    assert client.post("/voice/speak", json={}).status_code == 401
