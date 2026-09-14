"""ローカル voice ゲートウェイ。

room の voice 契約（``/voice/sessions`` 系）だけを切り出して手元の Mac で動かす
エントリポイント。本体 room は VPS で jobs/hermes を担い続け、音声会話の往復は
``desktop → 本プロセス → gpt-live-1 → ローカル VC → desktop`` に閉じる。

desktop 側は ``MIHARI_VOICE_GATEWAY_URL`` があればそこへ voice を向け、
無ければ従来どおり ``MIHARI_ROOM_URL``（= VPS room）を使う。

音声ツール（submit_job / mac_* / discord_*）の実行は、``MIHARI_ROOM_URL``
が設定されていれば room 本体の ``POST /voice/tools/execute`` へ HTTP で委譲する
（``RemoteVoiceToolExecutor``）。未設定なら従来どおり orchestrator 無しの
失敗 JSON を返す。

認証は room と同じ ``X-Mihari-Token``（``MIHARI_ROOM_TOKEN`` と照合）。
セッション履歴は ``MIHARI_VOICE_GATEWAY_ROOT``（既定
``~/.local/share/mihari-voice-gateway``）に置く。

起動例:

    MIHARI_ROOM_URL=https://room.example.ts.net \\
    MIHARI_ROOM_TOKEN=... \\
    MIHARI_OPENAI_API_KEY=... \\
    MIHARI_VC_URL=http://127.0.0.1:18995 \\
    uv run python -m mihari_room.voice_gateway --port 8790
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI

from mihari_room.config import RoomConfig
from mihari_room.voice.remote_tools import remote_tool_executor_factory
from mihari_room.voice.routes import register_voice_routes

#: セッション履歴・ロックの置き場所。本体 room の root（~/mihari-room）とは分ける。
DEFAULT_GATEWAY_ROOT = Path.home() / ".local/share/mihari-voice-gateway"


def build_config() -> RoomConfig:
    """環境変数から RoomConfig を組み立てる。

    既定との差分は voice 用途のものだけ: 出力モードは ``live_audio`` が既定
    （``MIHARI_VOICE_OUTPUT_MODE`` で上書き可）、root は gateway 専用の場所。
    """
    base = RoomConfig.from_environment()
    root_raw = os.environ.get("MIHARI_VOICE_GATEWAY_ROOT")
    root = Path(root_raw).expanduser().resolve() if root_raw else DEFAULT_GATEWAY_ROOT
    root.mkdir(parents=True, exist_ok=True)
    return RoomConfig(
        token=base.token,
        root=root,
        host=base.host,
        port=base.port,
        forum_channel_id=base.forum_channel_id,
        discord_token=base.discord_token,
        owner_id=base.owner_id,
        preview_base_url=base.preview_base_url,
        openai_api_key=base.openai_api_key,
        voice_realtime_model=base.voice_realtime_model,
        voice_output_mode=os.environ.get("MIHARI_VOICE_OUTPUT_MODE", "live_audio").strip()
        or "live_audio",
        live_model=base.live_model,
        live_voice=base.live_voice,
        vc_url=base.vc_url,
        vc_timeout=base.vc_timeout,
    )


def create_gateway_app(config: RoomConfig, *, room_url: str | None = None) -> FastAPI:
    app = FastAPI(title="mihari-voice-gateway")
    app.state.config = config
    register_voice_routes(app)

    # room 本体の URL が分かればツール実行は HTTP 委譲（remote executor）にする。
    # 無ければ executor は従来どおり orchestrator 無しで失敗 JSON を返す。
    resolved_room_url = (
        room_url if room_url is not None else os.environ.get("MIHARI_ROOM_URL", "")
    ).strip()
    if resolved_room_url:
        app.state.voice_tool_executor_factory = remote_tool_executor_factory(
            room_url=resolved_room_url, token=config.token
        )

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "output_mode": config.voice_output_mode}

    return app


def main() -> None:
    parser = argparse.ArgumentParser(description="mihari local voice gateway")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8790)
    args = parser.parse_args()

    load_dotenv()
    try:
        config = build_config()
    except ValueError as error:
        raise SystemExit(str(error)) from error
    uvicorn.run(
        create_gateway_app(config),
        host=args.host,
        port=args.port,
        log_level="info",
    )


if __name__ == "__main__":
    main()
