"""クライアント WS と Realtime upstream の双方向リレー。"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
import os
from collections.abc import Callable
from typing import Any

from fastapi import WebSocket, WebSocketDisconnect

from mihari_room.voice.history import HistoryMessage
from mihari_room.voice.live_upstream import LIVE_AUDIO_OUTPUT_EVENTS
from mihari_room.voice.protocol import (
    EVENT_INPUT_AUDIO,
    EVENT_INPUT_IMAGE,
    SessionStatus,
    assistant_audio_event,
    assistant_text_event,
    assistant_tool_activity_event,
    assistant_tool_call_event,
    error_event,
    history_sync_event,
    session_closed_event,
    session_ready_event,
    user_text_event,
    user_transcript_none_event,
)
from mihari_room.voice.sessions import VoiceSessionManager, VoiceStreamBusyError
from mihari_room.voice.tools import VoiceToolExecutor, VoiceToolOutcome
from mihari_room.voice.upstream import (
    UPSTREAM_AUDIO_OUTPUT_EVENTS,
    RealtimeUpstream,
    response_create_event,
)
from mihari_room.voice.vc import (
    VoiceConverter,
    f32_to_pcm16,
    pcm16_to_f32,
    voice_converter_from_config,
)

logger = logging.getLogger("mihari_room.voice")

#: Live API の既知だが中継しないイベント（ACK 類）。これ以外は 1 度だけログに出す。
_LIVE_QUIET_EVENTS = frozenset(
    {
        "session.started",
        "session.updated",
        "session.instructions.appended",
        "session.thinking.appended",
        "session.commentary.appended",
        "session.input_audio.muted",
        "session.input_audio.unmuted",
    }
)

#: ``response.event`` 内側の既知だが処理不要なライフサイクル中間イベント。
#: delegation の委譲応答は Responses API のイベント名で届く（公式
#: live-delegation ガイド。function_call の収集は output_item.done で行う）。
_LIVE_DELEGATION_QUIET_EVENTS = frozenset(
    {
        "response.in_progress",
        "response.output_item.added",
        "response.function_call_arguments.delta",
        "response.function_call_arguments.done",
        "response.content_part.added",
    }
)

#: submit_job で投げたジョブの終端を監視するポーリング間隔（秒）。
_JOB_WATCH_INTERVAL_SEC = 1.5

#: live 受信ループの tick（秒）。receive() をこの周期で区切り、イベントの
#: 途切れを検査するウォッチドッグを回す（200-300ms 程度が公式推奨の粒度）。
_LIVE_WATCH_TICK_SEC = 0.25

#: 出力区切りの無音判定（秒）。Live API の出力ストリームには発話終端
#: イベントが無い（session.output_audio.done/stopped は公式イベント一覧に
#: 存在しない）ため、最後の出力活動からこの gap が経ったら 1 発話の終端と
#: 自前判定する。再生キュー追跡 + gap 判定が公式推奨のやり方。
_LIVE_OUTPUT_GAP_SEC = (
    float(os.environ.get("MIHARI_LIVE_OUTPUT_GAP_MS", "1100")) / 1000.0
)

#: 入力（ユーザー発話）区切り（秒）。session.input_transcript.delta がこの
#: 時間途切れたらその発話を確定する。transcript が一度も来ない発話は
#: 最後の非無音クライアント音声からの gap で確定し transcript_none を出す。
_LIVE_INPUT_GAP_SEC = (
    float(os.environ.get("MIHARI_LIVE_INPUT_GAP_MS", "1800")) / 1000.0
)

#: live_audio モードで upstream の入力ストリームを維持する無音ペーサーの周期（秒）。
_LIVE_INPUT_PACER_INTERVAL = 0.1

#: ペーサーが補填する無音 1 枚分。PCM16 mono 24kHz の 100ms = 2400 サンプル = 4800 バイト。
_LIVE_SILENCE_FRAME_B64 = base64.b64encode(b"\x00" * 4800).decode()

#: Live delegation（Responses バックエンド）の入力履歴はセッション累積で
#: 128 items / 32,768 UTF-8 bytes まで。安全マージン込みの目安。
LIVE_DELEGATION_INPUT_LIMIT = 30_000

#: live で upstream へ積む画像 item の base64 文字列の上限。data URL 化と
#: JSON 枠のオーバーヘッドを見て、item 全体が 32KB 未満に収まるよう半分にする。
_LIVE_IMAGE_B64_LIMIT = LIVE_DELEGATION_INPUT_LIMIT // 2

#: live の fco output の最大文字数。超過分は切り詰めて末尾に印を付ける。
_LIVE_FCO_OUTPUT_LIMIT = 4_000

#: 画像を backend へ送らなかったとき fco output に添える説明。
_LIVE_IMAGE_DROPPED_NOTE = (
    "画像は backend の入力上限を超えるため送信しなかった（ユーザー側には表示済み）"
)

UpstreamFactory = Callable[[], RealtimeUpstream]

#: 音声セッション 1 本ぶんのツール実行器を組み立てる factory（session_id を取る）。
#: voice gateway が ``RemoteVoiceToolExecutor`` を差し込むために使う。
ToolExecutorFactory = Callable[[str], Any]


class _ClientAudioClock:
    """クライアント音声の最終到着時刻とターン内の発話量を共有するホルダ。"""

    def __init__(self) -> None:
        self.last_at = asyncio.get_running_loop().time()
        #: 最後に非無音（発話とみなせる）input.audio が届いた時刻。
        #: transcript が一度も来ない発話の区切り検出はこの時刻を起点にする。
        self.last_speech_at: float | None = None
        #: 直前のターン区切り以降に届いた非無音 input.audio の累積バイト数。
        #: live_audio では非押下中も無音チャンクが流れ続ける（room 側の無音
        #: ペーサーもある）ため、全ゼロ PCM はユーザー発話として数えない。
        self.speech_bytes = 0

    def note(self, pcm: bytes) -> None:
        now = asyncio.get_running_loop().time()
        self.last_at = now
        if any(pcm):
            self.speech_bytes += len(pcm)
            self.last_speech_at = now


async def handle_voice_stream(
    websocket: WebSocket,
    *,
    session_id: str,
    manager: VoiceSessionManager,
    upstream_factory: UpstreamFactory,
    orchestrator: Any = None,
    mac_hub: Any = None,
    interactions: Any = None,
    tool_executor: Any = None,
    tool_executor_factory: ToolExecutorFactory | None = None,
) -> None:
    """``/voice/sessions/{id}/stream`` の本体。

    ``orchestrator`` / ``mac_hub`` / ``interactions`` は room のツール実行器へ
    渡す依存（app.state 由来）。``tool_executor`` があればそれを使う（test 用）。
    ``tool_executor_factory`` は orchestrator が無い環境（voice gateway）でのみ
    使い、session_id から executor を組み立てる。orchestrator が居る room 本体
    では常にローカルの ``VoiceToolExecutor`` を優先する。
    """
    session = manager.get(session_id)
    if session is None:
        await websocket.close(code=4404)
        return
    if session.status in {SessionStatus.CLOSED, SessionStatus.ERROR}:
        await websocket.close(code=4409)
        return

    try:
        await manager.acquire_stream(session_id)
    except VoiceStreamBusyError:
        await websocket.close(code=4409)
        return
    except KeyError:
        await websocket.close(code=4404)
        return

    upstream = upstream_factory()
    output_mode = getattr(manager.config, "voice_output_mode", "text")
    #: live_audio モードではセッション（= このストリーム）中 1 インスタンスの VC を保持する。
    converter: VoiceConverter | None = (
        voice_converter_from_config(manager.config) if output_mode == "live_audio" else None
    )
    manager.mark_streaming(session_id)
    end_reason = "idle"
    close_sent = False
    history = manager.get_history(session_id)
    resumed = bool(history)
    if tool_executor is not None:
        executor = tool_executor
    elif tool_executor_factory is not None and orchestrator is None:
        # orchestrator の無い gateway だけ factory（例: remote executor）を使う。
        # room 本体では app.state.orchestrator が居るので常にローカル実行器。
        executor = tool_executor_factory(session_id)
    else:
        executor = VoiceToolExecutor(
            session_id=session_id,
            manager=manager,
            orchestrator=orchestrator,
            mac_hub=mac_hub,
            interactions=interactions,
        )
    #: client 実行ツール（capture_screen）の未解決 call。call_id → ツール名。
    pending_client_calls: dict[str, str] = {}

    async def send_client(frame: dict[str, Any]) -> None:
        await websocket.send_text(json.dumps(frame, ensure_ascii=False))

    try:
        await upstream.connect()
        if history:
            await _replay_history_to_upstream(upstream, history)
        if converter is not None:
            await converter.reset()
        await send_client(
            session_ready_event(
                session_id=session_id,
                model=session.model,
                resumed=resumed,
                output_modalities=session.output_modalities,
            )
        )
        if history:
            await send_client(history_sync_event(messages=manager.history_to_dicts(session_id)))

        # Live API は入力音声ストリームでセッションの時間が進むため、live_audio
        # ではクライアント音声の最終到着時刻を共有し、途切れた区間を無音で補填する。
        client_audio_clock = _ClientAudioClock() if converter is not None else None
        client_task = asyncio.create_task(
            _client_to_upstream(
                websocket,
                upstream,
                send_client,
                session_id=session_id,
                manager=manager,
                pending_client_calls=pending_client_calls,
                live=converter is not None,
                on_client_audio=(
                    client_audio_clock.note if client_audio_clock is not None else None
                ),
            )
        )
        if converter is not None:
            upstream_task = asyncio.create_task(
                _live_upstream_to_client(
                    upstream,
                    converter,
                    send_client,
                    session_id=session_id,
                    manager=manager,
                    executor=executor,
                    pending_client_calls=pending_client_calls,
                    audio_clock=client_audio_clock,
                )
            )
        else:
            upstream_task = asyncio.create_task(
                _upstream_to_client(
                    upstream,
                    send_client,
                    session_id=session_id,
                    manager=manager,
                    executor=executor,
                    pending_client_calls=pending_client_calls,
                )
            )
        close_task = asyncio.create_task(_watch_session_close(manager, session_id))
        stream_tasks = {client_task, upstream_task, close_task}
        if client_audio_clock is not None:
            stream_tasks.add(asyncio.create_task(_live_input_pacer(upstream, client_audio_clock)))
        if callable(getattr(executor, "finished_jobs", None)):
            # submit_job で投げたジョブの終端を会話へ戻す監視（live / text 共通）。
            stream_tasks.add(
                asyncio.create_task(
                    _job_result_watcher(
                        upstream,
                        send_client,
                        session_id=session_id,
                        manager=manager,
                        executor=executor,
                        live=converter is not None,
                    )
                )
            )
        try:
            done, pending = await asyncio.wait(
                stream_tasks,
                return_when=asyncio.FIRST_COMPLETED,
            )
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            for task in done:
                exc = task.exception()
                if isinstance(exc, WebSocketDisconnect):
                    end_reason = "client_disconnect"
                elif exc and not isinstance(exc, asyncio.CancelledError):
                    logger.debug("voice stream task ended: %s", exc)
                    end_reason = "error"
            if close_task in done and close_task.exception() is None:
                # POST /close 等で外部から CLOSED/ERROR にされた。
                end_reason = "closed"
        finally:
            # ルートタスクが cancel されても子タスクを残さず、例外を回収する。
            for task in stream_tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*stream_tasks, return_exceptions=True)
    except WebSocketDisconnect:
        end_reason = "client_disconnect"
    except Exception as error:
        logger.exception("voice stream failed for %s", session_id)
        end_reason = "error"
        manager.mark_closed(session_id, reason=str(error))
        try:
            await send_client(error_event(str(error)))
            await send_client(session_closed_event(reason=str(error)))
            close_sent = True
        except Exception:
            pass
    finally:
        if converter is not None:
            try:
                await converter.close()
            except Exception:
                pass
        # begin 済みの Mac run があれば畳む（executor 未生成パスもあるので getattr）。
        close_executor = getattr(executor, "close", None)
        if callable(close_executor):
            try:
                await close_executor()
            except Exception:
                pass
        await upstream.close()
        await manager.release_stream(session_id)
        current = manager.get(session_id)
        if current is not None:
            if end_reason in {"client_disconnect", "idle"}:
                # 外部 close で CLOSED になったセッションを CREATED に巻き戻さない。
                if current.status is SessionStatus.STREAMING:
                    manager.mark_idle(session_id)
            elif end_reason == "error" and current.status is SessionStatus.STREAMING:
                # タスク側の例外で wait が返り except パスを通っていない場合、
                # streaming 固着を防ぐため idle に戻して再接続可能にする。
                logger.warning(
                    "voice stream %s ended by task error; resetting to idle",
                    session_id,
                )
                manager.mark_idle(session_id)
        if not close_sent:
            try:
                await send_client(session_closed_event())
                close_sent = True
            except Exception:
                pass


async def _replay_history_to_upstream(
    upstream: RealtimeUpstream,
    messages: list[HistoryMessage],
) -> None:
    """切断復旧時、テキスト履歴だけ upstream コンテキストへ再注入する。"""
    for message in messages:
        if message.kind == "tool_call":
            continue
        text = message.text.strip()
        if not text:
            continue
        content_type = "input_text" if message.role == "user" else "output_text"
        await upstream.send(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": message.role,
                    "content": [{"type": content_type, "text": text}],
                },
            }
        )


async def _watch_session_close(manager: VoiceSessionManager, session_id: str) -> None:
    """POST /close など外部操作で CLOSED/ERROR にされたら戻る。"""
    while True:
        await asyncio.sleep(0.2)
        current = manager.get(session_id)
        if current is None or current.status in {
            SessionStatus.CLOSED,
            SessionStatus.ERROR,
        }:
            return


async def _live_input_pacer(upstream: RealtimeUpstream, clock: _ClientAudioClock) -> None:
    """live_audio 専用。クライアント音声が無い区間を無音フレームで補填する。

    gpt-live-1（Live API）はフルデュプレックスで、入力音声ストリームが
    セッションの時計を進める。クライアントの input.audio が止まると
    応答生成も途中で停まるため、最後のクライアント音声から 100ms 以上
    経っていれば 100ms 分の無音（PCM16 mono 24kHz）を送り続ける。
    upstream が切れていれば静かに終わり、ストリーム全体は落とさない。
    """
    loop = asyncio.get_running_loop()
    try:
        while True:
            await asyncio.sleep(_LIVE_INPUT_PACER_INTERVAL)
            if loop.time() - clock.last_at < _LIVE_INPUT_PACER_INTERVAL:
                continue
            await upstream.send(
                {
                    "type": "input_audio_buffer.append",
                    "audio": _LIVE_SILENCE_FRAME_B64,
                }
            )
    except Exception:
        return


async def _client_to_upstream(
    websocket: WebSocket,
    upstream: RealtimeUpstream,
    send_client: Any,
    *,
    session_id: str,
    manager: VoiceSessionManager,
    pending_client_calls: dict[str, str],
    live: bool = False,
    on_client_audio: Callable[[bytes], None] | None = None,
) -> None:
    while True:
        message = await websocket.receive()
        if message.get("type") == "websocket.disconnect":
            raise WebSocketDisconnect()
        raw = message.get("text")
        if raw is None:
            continue
        try:
            frame = json.loads(raw)
        except (ValueError, TypeError):
            continue
        if not isinstance(frame, dict):
            continue
        frame_type = frame.get("type")
        try:
            if frame_type == EVENT_INPUT_AUDIO:
                await _forward_audio(
                    frame, upstream, live=live, on_client_audio=on_client_audio
                )
            elif frame_type == EVENT_INPUT_IMAGE:
                await _forward_image(
                    frame,
                    upstream,
                    session_id=session_id,
                    manager=manager,
                    pending_client_calls=pending_client_calls,
                    live=live,
                )
            else:
                await send_client(error_event(f"未知のイベント: {frame_type}", code="bad_event"))
        except (ValueError, binascii.Error) as error:
            await send_client(error_event(str(error), code="bad_payload"))


async def _forward_audio(
    frame: dict[str, Any],
    upstream: RealtimeUpstream,
    *,
    live: bool = False,
    on_client_audio: Callable[[bytes], None] | None = None,
) -> None:
    audio_b64 = frame.get("audio_base64") or frame.get("audio") or ""
    if not isinstance(audio_b64, str) or not audio_b64:
        raise ValueError("input.audio には audio_base64 が必要")
    # 形式チェックのみ。中身は OpenAI へそのまま渡し、ディスクには書かない。
    pcm = base64.b64decode(audio_b64, validate=True)
    await upstream.send({"type": "input_audio_buffer.append", "audio": audio_b64})
    if on_client_audio is not None:
        # live_audio の無音ペーサーが使う最終到着時刻と、ターン内の発話量
        # （無転写ターン検出用。全ゼロ PCM のキープアライブは数えない）を更新する。
        on_client_audio(pcm)
    if live:
        # Live は commit / response.create を持たない。delegation 有効時に
        # response.create が upstream へ通ってしまうと、クライアントの
        # ターン確定ごとに委譲応答を起こしてしまうのでここでは送らない。
        return
    if frame.get("commit", True):
        await upstream.send({"type": "input_audio_buffer.commit"})
    if frame.get("create_response", True):
        await upstream.send(response_create_event())


async def _forward_image(
    frame: dict[str, Any],
    upstream: RealtimeUpstream,
    *,
    session_id: str,
    manager: VoiceSessionManager,
    pending_client_calls: dict[str, str],
    live: bool = False,
) -> None:
    image_b64 = frame.get("image_base64") or frame.get("image") or ""
    media_type = frame.get("media_type") or "image/png"
    prompt = frame.get("prompt") or frame.get("text") or "Describe this image."
    if not isinstance(image_b64, str) or not image_b64:
        raise ValueError("input.image には image_base64 が必要")
    base64.b64decode(image_b64, validate=True)
    if not isinstance(media_type, str) or not media_type.startswith("image/"):
        raise ValueError("input.image の media_type が不正")
    manager.record_user_text(session_id, str(prompt), kind="image_prompt")
    image_item: dict[str, Any] = {
        "type": "message",
        "role": "user",
        "content": [
            {
                "type": "input_image",
                "image_url": f"data:{media_type};base64,{image_b64}",
            },
            {"type": "input_text", "text": str(prompt)},
        ],
    }
    # client 側で実行した capture_screen の結果として届いた画像は、
    # pending の function_call を解決する（fco + 画像メッセージ + response.create）。
    capture_call_id = next(
        (cid for cid, name in pending_client_calls.items() if name == "capture_screen"),
        None,
    )
    if capture_call_id is not None:
        pending_client_calls.pop(capture_call_id, None)
        # live の delegation 入力履歴はセッション累積で上限が小さい（32KB）。
        # 上限を超える画像は backend へ送らず、fco の note で欠落を伝える。
        image_dropped = live and len(image_b64) > _LIVE_IMAGE_B64_LIMIT
        function_output: dict[str, Any] = {
            "type": "function_call_output",
            "call_id": capture_call_id,
            "output": json.dumps(
                {
                    "success": True,
                    "note": (
                        _LIVE_IMAGE_DROPPED_NOTE
                        if image_dropped
                        else "画像は直前のメッセージ"
                    ),
                },
                ensure_ascii=False,
            ),
        }
        if live:
            if not image_dropped:
                await upstream.send({"type": "response.item.create", "item": image_item})
            await upstream.send({"type": "response.item.create", "item": function_output})
            await upstream.send({"type": "response.create"})
        else:
            await upstream.send(
                {"type": "conversation.item.create", "item": image_item}
            )
            await upstream.send(
                {"type": "conversation.item.create", "item": function_output}
            )
            await upstream.send(response_create_event())
        return
    # ユーザー能動の画像（pending 無し）は従来どおりメッセージとして積む。
    # live では conversation.item.create が thinking.append へ変換される
    # （画像は落ちてテキストのみ）。response.create は live では意味を持たない。
    await upstream.send({"type": "conversation.item.create", "item": image_item})
    if not live and frame.get("create_response", True):
        await upstream.send(response_create_event())


async def _upstream_to_client(
    upstream: RealtimeUpstream,
    send_client: Any,
    *,
    session_id: str,
    manager: VoiceSessionManager,
    executor: Any,
    pending_client_calls: dict[str, str],
) -> None:
    while True:
        event = await upstream.receive()
        event_type = event.get("type", "")
        if event_type in UPSTREAM_AUDIO_OUTPUT_EVENTS:
            manager.note_upstream_audio_output(session_id)
        if event_type == "response.output_text.delta":
            delta = event.get("delta") or ""
            if delta:
                await send_client(assistant_text_event(delta=delta, done=False))
        elif event_type == "response.output_text.done":
            text = event.get("text") or ""
            if text:
                manager.record_assistant_text(session_id, str(text))
            await send_client(assistant_text_event(text=text, done=True))
        elif event_type == "response.done":
            response = event.get("response") or {}
            output = response.get("output") or []
            if isinstance(output, list):
                await _run_function_calls(
                    output,
                    upstream=upstream,
                    send_client=send_client,
                    session_id=session_id,
                    manager=manager,
                    executor=executor,
                    pending_client_calls=pending_client_calls,
                )
        elif event_type == "conversation.item.input_audio_transcription.completed":
            transcript = str(event.get("transcript") or "").strip()
            if transcript:
                # ユーザーターンを履歴に残し、history.sync / GET /history で復元できるようにする。
                manager.record_user_text(session_id, transcript)
                await send_client(user_text_event(text=transcript))
        elif event_type == "error":
            message = _extract_error_message(event)
            await send_client(error_event(message, code="upstream_error"))
        elif event_type in {"session.updated", "session.created", "session.closed"}:
            if event_type == "session.closed":
                return
            continue


def _call_arguments_str(raw: Any) -> str:
    """function_call の arguments を executor/client 両対応の JSON 文字列へ。"""
    if isinstance(raw, str):
        return raw or "{}"
    return json.dumps(raw or {}, ensure_ascii=False)


def _live_fco_output(output: str, *, image_dropped: bool) -> str:
    """live 用の fco output を整える（長文の切り詰め + 画像欠落 note）。

    切り詰めは JSON を壊しうるので先に行い、image_dropped の note は
    その結果を包む形で必ず末尾へ残す。
    """
    if len(output) > _LIVE_FCO_OUTPUT_LIMIT:
        output = output[:_LIVE_FCO_OUTPUT_LIMIT] + "…(truncated)"
    if not image_dropped:
        return output
    try:
        payload = json.loads(output)
    except ValueError:
        payload = None
    if isinstance(payload, dict):
        payload["note"] = _LIVE_IMAGE_DROPPED_NOTE
        return json.dumps(payload, ensure_ascii=False)
    return json.dumps(
        {"success": True, "note": _LIVE_IMAGE_DROPPED_NOTE, "output": output},
        ensure_ascii=False,
    )


async def _send_tool_result(
    upstream: RealtimeUpstream,
    *,
    call_id: str,
    outcome: VoiceToolOutcome,
    live: bool,
) -> None:
    """function_call_output（+ あれば画像メッセージ）を upstream へ積む。"""
    item_create = "response.item.create" if live else "conversation.item.create"
    image_dropped = False
    if outcome.image_png:
        image_b64 = base64.b64encode(outcome.image_png).decode()
        if live and len(image_b64) > _LIVE_IMAGE_B64_LIMIT:
            # delegation の入力履歴はセッション累積で上限 32KB と小さい。
            # 大きい画像は積まず、fco の note で欠落だけ伝える。
            image_dropped = True
        else:
            image_item: dict[str, Any] = {
                "type": "message",
                "role": "user",
                "content": [
                    {
                        "type": "input_image",
                        "image_url": "data:image/png;base64," + image_b64,
                    },
                    {"type": "input_text", "text": "ツール実行結果の画像"},
                ],
            }
            await upstream.send({"type": item_create, "item": image_item})
    output = outcome.output
    if live:
        output = _live_fco_output(output, image_dropped=image_dropped)
    await upstream.send(
        {
            "type": item_create,
            "item": {
                "type": "function_call_output",
                "call_id": call_id,
                "output": output,
            },
        }
    )


async def _run_function_calls(
    output: list[Any],
    *,
    upstream: RealtimeUpstream,
    send_client: Any,
    session_id: str,
    manager: VoiceSessionManager,
    executor: Any,
    pending_client_calls: dict[str, str],
    live: bool = False,
) -> None:
    """response.done / delegation の response.completed で溜めた function_call を処理。

    - room 実行ツール: ``assistant.tool_activity`` を client へ通知し、
      fco（+ 画像があればメッセージ）を upstream へ返す。
    - client 実行ツール（capture_screen）: ``assistant.tool_call`` を送り、
      pending へ登録。結果は input.image で届く。
    - 全 room 側の結果を積み終え、かつ pending client call が無いときだけ
      ``response.create`` を 1 回送る。
    """
    submitted = False
    for item in output:
        if not isinstance(item, dict) or item.get("type") != "function_call":
            continue
        name = str(item.get("name") or "")
        call_id = str(item.get("call_id") or "")
        arguments = _call_arguments_str(item.get("arguments"))
        manager.record_tool_call(session_id, name=name, arguments=arguments)
        outcome = await executor.execute(name, arguments)
        if outcome.client_side:
            await send_client(
                assistant_tool_call_event(name=name, call_id=call_id, arguments=arguments)
            )
            if call_id:
                pending_client_calls[call_id] = name
            continue
        # room 実行ツールは旧 client が二重実行しないよう tool_call は送らず、
        # 活動通知だけを送る。submit_job は受理された job_id・title を載せて、
        # desktop の RoomJobMonitor がそのまま購読を始められるようにする。
        activity_job_id = ""
        activity_title = ""
        if name == "submit_job" and outcome.ok:
            try:
                payload = json.loads(outcome.output)
                if isinstance(payload, dict):
                    activity_job_id = str(payload.get("job_id") or "")
                    activity_title = str(payload.get("title") or "")
            except (ValueError, TypeError):
                pass
        await send_client(
            assistant_tool_activity_event(
                name=name,
                call_id=call_id,
                status="done" if outcome.ok else "failed",
                title=activity_title,
                job_id=activity_job_id,
            )
        )
        await _send_tool_result(upstream, call_id=call_id, outcome=outcome, live=live)
        submitted = True
    if submitted and not pending_client_calls:
        await upstream.send({"type": "response.create"} if live else response_create_event())


def _extract_error_message(event: dict[str, Any]) -> str:
    error = event.get("error")
    if not isinstance(error, dict):
        # response.failed 系は error を response オブジェクトの内側に持つ。
        nested = event.get("response")
        if isinstance(nested, dict):
            error = nested.get("error") or error
    if isinstance(error, dict):
        return str(error.get("message") or error.get("code") or "upstream error")
    return str(error or "upstream error")


def _accumulate_transcript(accumulated: str, delta: str) -> tuple[str, str]:
    """文字起こし delta の累積。重複送出・累積全文形式を潰す。

    upstream は通常増分だけを送るが、実機では同一文の重複送出や
    「それまでの累積全文」を delta として送るケースが観測されている。
    ``delta`` が累積済み文字列で始まるときは累積全文形式（または完全な
    重複送出）とみなして置き換え、そうでなければ通常の delta として連結する。
    戻り値は ``(新しい累積, client へ流す新規部分)``。
    """
    if not accumulated:
        return delta, delta
    if delta.startswith(accumulated):
        return delta, delta[len(accumulated) :]
    return accumulated + delta, delta


async def _job_result_watcher(
    upstream: RealtimeUpstream,
    send_client: Any,
    *,
    session_id: str,
    manager: VoiceSessionManager,
    executor: Any,
    live: bool,
) -> None:
    """executor が追跡する submit_job 済みジョブの終端を会話へ注入する。

    ジョブ状態の購読は executor 側に委ねる。room 本体の ``VoiceToolExecutor``
    は同プロセスの job store を、voice gateway の ``RemoteVoiceToolExecutor``
    は room の ``GET /jobs/{id}`` をそれぞれポーリングする。
    """
    poll = getattr(executor, "finished_jobs", None)
    if not callable(poll):
        return
    while True:
        await asyncio.sleep(_JOB_WATCH_INTERVAL_SEC)
        session = manager.get(session_id)
        if session is None or session.status in {
            SessionStatus.CLOSED,
            SessionStatus.ERROR,
        }:
            return
        try:
            results = await poll()
        except Exception:
            logger.debug("voice job watcher poll failed", exc_info=True)
            continue
        for result in results:
            try:
                await _inject_job_result(
                    upstream,
                    send_client,
                    result=result,
                    live=live,
                )
            except Exception:
                logger.debug("voice job result inject failed", exc_info=True)


async def _inject_job_result(
    upstream: RealtimeUpstream,
    send_client: Any,
    *,
    result: dict[str, Any],
    live: bool,
) -> None:
    """終端に達したジョブ 1 件を client 通知 + upstream 注入で会話へ戻す。

    upstream 注入はモードで分岐する:
    - live + delegation 有効: ``response.item.create``（user メッセージ）+
      ``response.create`` で委譲バックエンドへ知らせ、続きを生成させる
      （公式 live-delegation ガイドの typed input と同じ手順）。
    - live + delegation 無効: 上記コマンドは upstream に落とされるため、
      ``session.commentary.append``（delegation_id=null、発話向け文脈）で
      表の音声モデルへ直接伝える。
    - text（Realtime）: ``conversation.item.create`` + ``response.create``。
    """
    job_id = str(result.get("job_id") or "")
    title = str(result.get("title") or job_id)
    status = str(result.get("status") or "")
    summary = str(result.get("summary") or "").strip()
    if len(summary) > _LIVE_FCO_OUTPUT_LIMIT:
        summary = summary[:_LIVE_FCO_OUTPUT_LIMIT] + "…(truncated)"
    terminal_word = {
        "done": "完了",
        "failed": "失敗",
        "cancelled": "中断",
    }.get(status, status or "不明")
    # client へ活動通知。desktop は submit_job の完了行を出す。job_id は
    # call_id と専用フィールドの両方へ載せる（RoomJobMonitor.attach 用）。
    await send_client(
        assistant_tool_activity_event(
            name="submit_job",
            call_id=job_id,
            status="done" if status == "done" else "failed",
            title=title,
            job_id=job_id,
        )
    )
    if live and not getattr(upstream, "delegation_enabled", False):
        # commentary.append は 1 回 500 トークン上限の発話向け文脈注入。
        # 結果そのものを話させる形で短く収める。
        content = f"部屋の仕事「{title}」が{terminal_word}しました。"
        if summary:
            content += f"結果: {summary[:400]}"
        await upstream.send(
            {
                "type": "session.commentary.append",
                "event_id": f"job_result_{job_id}",
                "delegation_id": None,
                "content": content,
            }
        )
        return
    message_text = (
        f"システム通知: 部屋の仕事「{title}」が{terminal_word}しました"
        f"（job_id={job_id}）。"
    )
    if summary:
        message_text += f"\n結果: {summary}"
    message_text += "\nこの結果をユーザーへ短く報告してください。"
    item_create = "response.item.create" if live else "conversation.item.create"
    await upstream.send(
        {
            "type": item_create,
            "item": {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": message_text}],
            },
        }
    )
    await upstream.send(
        {"type": "response.create"} if live else response_create_event()
    )


async def _live_upstream_to_client(
    upstream: RealtimeUpstream,
    converter: VoiceConverter,
    send_client: Any,
    *,
    session_id: str,
    manager: VoiceSessionManager,
    executor: Any,
    pending_client_calls: dict[str, str],
    audio_clock: _ClientAudioClock,
) -> None:
    """live_audio モードの upstream → クライアント中継。

    gpt-live-1 の ``session.output_audio.delta``（base64 PCM16 24kHz）を
    f32 に変換して VC へ通し、PCM16 に戻して ``assistant.audio`` で送る。

    Live の文字起こしは断片（delta）しか無く、出力にも「1 発話の終端」
    イベントが無い（``session.output_audio.done``/``stopped`` は公式
    イベント一覧に存在しない）。そのためターン区切りは自前判定する:

    - ユーザー発話: ``session.input_transcript.delta`` の gap
      （``_LIVE_INPUT_GAP_SEC``）、または delta が持つ ``start_ms``/``end_ms``
      の発話区間の飛びで確定。音声だけ届いて transcript が一度も来ない
      ターンは ``user.transcript_none`` で client へ知らせ、desktop の発話
      プレースホルダが残り続けるのを防ぐ。
    - assistant 出力: ``session.output_audio.delta`` /
      ``session.output_transcript.delta`` の gap（``_LIVE_OUTPUT_GAP_SEC``）
      で 1 発話の終端と判定し、converter の残りを吐いて done を送る。

    receive() は ``_LIVE_WATCH_TICK_SEC`` で区切り、途切れ検査
    （``check_watchdogs``）を回す。未知のイベント type は 1 度だけ警告
    ログへ出して無視する。
    """
    user_transcript = ""
    #: 区切り間で受けた ``session.input_transcript.delta`` の回数（診断ログ用）。
    transcript_deltas = 0
    assistant_transcript = ""
    output_active = False
    logged_types: set[str] = set()
    #: ターン統計。flush_user が呼ばれるたびに累積し、assistant 出力区切り
    #: （ウォッチドッグの発話終端判定）で 1 行ログへ出してリセットする。
    turn_input_bytes = 0
    turn_transcript_deltas = 0
    turn_transcript_len = 0
    #: session.delegation.created で記録する委譲 ID（responses バックエンドの 1 委譲）。
    delegation_id: str | None = None
    #: 内側 response.event の ``response.created`` で記録する委譲応答 ID。
    delegated_response_id: str | None = None
    #: response.completed までに output_item.done で集めた function_call。
    delegated_calls: list[dict[str, Any]] = []
    #: 委譲バックエンドの応答テキスト（``response.output_text.delta`` の累積）。
    #: 発話内容を担う ``session.output_transcript`` とは別ストリームなので、
    #: assistant.text へは流さず履歴 + delegate 活動行へ畳む。
    delegated_text = ""
    #: ``flush_delegated`` で確定済みの最新委譲テキスト。``output_text.done``
    #: で先に畳まれたあと、``response.completed`` の delegate 活動行 title
    #: へ載せるために保持する（委譲ごとにクリア）。
    delegated_last_text = ""
    #: ウォッチドッグ用の最終活動時刻。出力は音声・文字起こし両方を見る。
    last_output_activity_at: float | None = None
    last_input_transcript_at: float | None = None
    #: 発話区間グルーピング用。前 delta の ``end_ms`` を覚えておき、次 delta の
    #: ``start_ms`` が閾値以上離れていたら別発話として先に確定する。
    last_input_end_ms: float | None = None

    async def flush_user(*, send: bool = True) -> None:
        nonlocal user_transcript, transcript_deltas
        nonlocal turn_input_bytes, turn_transcript_deltas, turn_transcript_len
        #: 直前の区切り以降に届いた非無音のユーザー音声（無音キープアライブは除く）。
        speech = audio_clock.speech_bytes
        audio_clock.speech_bytes = 0
        turn_input_bytes += speech
        turn_transcript_deltas += transcript_deltas
        transcript_deltas = 0
        turn_transcript_len += len(user_transcript)
        if user_transcript:
            manager.record_user_text(session_id, user_transcript)
            if send:
                await send_client(user_text_event(text=user_transcript, done=True))
            user_transcript = ""
        elif speech and send:
            # 音声は届いたが文字起こしが一度も来なかったターン。
            # desktop の「（音声を送信）」を未転写の明示表示へ解放する。
            await send_client(user_transcript_none_event())

    async def flush_assistant(*, send: bool = True) -> None:
        nonlocal assistant_transcript
        if not assistant_transcript:
            return
        manager.record_assistant_text(session_id, assistant_transcript)
        if send:
            await send_client(assistant_text_event(text=assistant_transcript, done=True))
        assistant_transcript = ""

    async def flush_delegated() -> str:
        """委譲バックエンドの応答テキストを確定する。戻り値は確定した全文。

        発話レーン（assistant.text）とは別扱い: 履歴へ記録してログへ出すだけで、
        client への表示は response.completed 時の delegate 活動行に任せる。
        確定した全文は ``delegated_last_text`` にも残す（completed の title 用）。
        """
        nonlocal delegated_text, delegated_last_text
        text = delegated_text.strip()
        delegated_text = ""
        if text:
            delegated_last_text = text
            manager.record_assistant_text(session_id, text)
            logger.info("live delegated backend text: %s", text[:200])
        return text

    async def finish_output_turn() -> None:
        """assistant 出力 1 発話分の区切り処理。

        Live API に発話終端イベントは無いため、ウォッチドッグ（出力活動の
        gap 検出）と、万一届いた ``session.output_audio.done``/``stopped``
        の両方から呼ばれる。
        """
        nonlocal output_active
        nonlocal turn_input_bytes, turn_transcript_deltas, turn_transcript_len
        output_active = False
        await flush_user()
        await flush_assistant()
        flushed = await converter.flush()
        if flushed:
            await send_client(
                assistant_audio_event(
                    audio_b64=base64.b64encode(f32_to_pcm16(flushed)).decode()
                )
            )
        await send_client(assistant_audio_event(done=True))
        # ターン診断。input_bytes が非ゼロで transcript_len=0 なら
        # 無転写ターン（user.transcript_none を送った区切り）。
        logger.info(
            "live turn: input_bytes=%d transcript_deltas=%d transcript_len=%d",
            turn_input_bytes,
            turn_transcript_deltas,
            turn_transcript_len,
        )
        turn_input_bytes = 0
        turn_transcript_deltas = 0
        turn_transcript_len = 0

    async def check_watchdogs() -> None:
        """イベント途切れを検査し、出力・入力の区切りを自前判定する。

        - 出力: ``session.output_audio.delta``/``session.output_transcript.delta``
          の最終到着から ``_LIVE_OUTPUT_GAP_SEC`` 経過 → 発話終端扱い。
        - 入力: ``session.input_transcript.delta``（未転写なら最後の非無音
          クライアント音声）の最終到着から ``_LIVE_INPUT_GAP_SEC`` 経過 →
          ``flush_user``。音声だけ届いたターンは transcript_none が出る。
        """
        now = asyncio.get_running_loop().time()
        if (
            output_active
            and last_output_activity_at is not None
            and now - last_output_activity_at >= _LIVE_OUTPUT_GAP_SEC
        ):
            await finish_output_turn()
        if user_transcript or audio_clock.speech_bytes:
            anchors = [
                t
                for t in (last_input_transcript_at, audio_clock.last_speech_at)
                if t is not None
            ]
            if anchors and now - max(anchors) >= _LIVE_INPUT_GAP_SEC:
                await flush_user()

    try:
        while True:
            try:
                async with asyncio.timeout(_LIVE_WATCH_TICK_SEC):
                    event = await upstream.receive()
            except TimeoutError:
                await check_watchdogs()
                continue
            event_type = event.get("type", "")
            if event_type in LIVE_AUDIO_OUTPUT_EVENTS:
                manager.note_upstream_audio_output(session_id)
            if event_type == "session.output_audio.delta":
                last_output_activity_at = asyncio.get_running_loop().time()
                if not output_active:
                    output_active = True
                    await flush_user()
                try:
                    pcm = base64.b64decode(event.get("delta") or "")
                except (ValueError, binascii.Error):
                    continue
                converted = await converter.convert(pcm16_to_f32(pcm))
                await send_client(
                    assistant_audio_event(
                        audio_b64=base64.b64encode(f32_to_pcm16(converted)).decode()
                    )
                )
            elif event_type in {
                "session.output_audio.done",
                "session.output_audio.stopped",
            }:
                # 公式イベント一覧には存在しない（発話終端はウォッチドッグが
                # gap で判定する）。万一 upstream から届いた場合の保険として残置。
                await finish_output_turn()
            elif event_type == "session.output_transcript.delta":
                last_output_activity_at = asyncio.get_running_loop().time()
                if not output_active:
                    output_active = True
                    await flush_user()
                delta = str(event.get("delta") or "")
                if delta:
                    assistant_transcript, piece = _accumulate_transcript(
                        assistant_transcript, delta
                    )
                    if piece:
                        await send_client(assistant_text_event(delta=piece, done=False))
            elif event_type == "session.input_transcript.delta":
                last_input_transcript_at = asyncio.get_running_loop().time()
                # 発話区間が取れるなら時刻で別発話を切る（公式推奨の grouping）。
                # 前 delta の end_ms と次の start_ms が大きく離れていたら、
                # ここまでの分を先に確定してから新しい発話として累積する。
                start_ms = event.get("start_ms")
                end_ms = event.get("end_ms")
                if (
                    user_transcript
                    and isinstance(start_ms, (int, float))
                    and last_input_end_ms is not None
                    and start_ms - last_input_end_ms > _LIVE_INPUT_GAP_SEC * 1000
                ):
                    await flush_user()
                transcript_deltas += 1
                if isinstance(end_ms, (int, float)):
                    last_input_end_ms = float(end_ms)
                delta = str(event.get("delta") or "")
                if delta:
                    user_transcript, piece = _accumulate_transcript(
                        user_transcript, delta
                    )
                    if piece:
                        await send_client(
                            user_text_event(text=user_transcript, delta=piece, done=False)
                        )
            elif event_type == "session.delegation.created":
                delegation = event.get("delegation") or {}
                delegation_id = str(delegation.get("id") or "")
                delegated_response_id = str(event.get("response_id") or "") or None
                # 前の委譲で集めた function_call・確定テキストを引きずらない。
                # 連続委譲で古い呼び出しが次の response.completed に混入したり、
                # 前委譲のテキストが次の活動行 title に出るのを防ぐ。
                delegated_calls.clear()
                delegated_last_text = ""
                # ユーザーの発話を履歴へ確定させてから委譲の記録を残す。
                await flush_user()
                # 委譲前の発話断片も確定する。ここで閉じないと desktop 側で
                # ツール行の上のバブルへ続き発話が追記され続ける。
                await flush_assistant()
                await send_client(
                    assistant_tool_activity_event(
                        name="delegate",
                        call_id=delegation_id,
                        status="running",
                    )
                )
            elif event_type == "response.event":
                # delegation（Responses バックエンド）の内側イベント。
                # 委譲応答の進行・完了・テキストはこの内側で届く。
                inner = event.get("event") or {}
                inner_type = inner.get("type", "")
                if inner_type == "response.created":
                    delegated_response_id = str(
                        (inner.get("response") or {}).get("id") or ""
                    ) or delegated_response_id
                elif inner_type == "response.output_item.done":
                    item = inner.get("item") or {}
                    # function_call の回収は completed 状態の item のみ
                    # （Twilio 公式サンプル準拠。in_progress 等は拾わない）。
                    if (
                        item.get("type") == "function_call"
                        and item.get("status") == "completed"
                    ):
                        delegated_calls.append(item)
                    elif item.get("type") == "function_call":
                        logger.debug(
                            "live delegation: skip function_call status=%s",
                            item.get("status"),
                        )
                elif inner_type == "response.output_text.delta":
                    # 委譲バックエンドの応答テキスト。発話内容は表の
                    # session.output_transcript が担うため、こちらは別レーン
                    # （delegated_text）に累積し、assistant.text へは流さない
                    # （喋った内容≠表示の二重コンテンツ防止）。
                    delta = str(inner.get("delta") or "")
                    if delta:
                        delegated_text, _ = _accumulate_transcript(
                            delegated_text, delta
                        )
                elif inner_type in {
                    "response.output_text.done",
                    "response.content_part.done",
                }:
                    # 委譲テキストの区切り。履歴へ確定するだけで表示は
                    # response.completed の delegate 活動行に任せる。
                    await flush_delegated()
                elif inner_type == "response.completed":
                    # 委譲ターンの確定区切り。function_call の有無に関わらず
                    # ユーザー・assistant 両方をここで確定する。
                    await flush_user()
                    await flush_assistant()
                    snippet = await flush_delegated()
                    # 「裏で考えた」活動行を閉じる。確定テキストは title で
                    # 抜粋表示（subdued、発話バブルと混ざらないレーン）。
                    # output_text.done で先に畳まれた分は delegated_last_text
                    # に残っているので、それを拾って表示に使う。
                    title = (snippet or delegated_last_text)[:120]
                    delegated_last_text = ""
                    await send_client(
                        assistant_tool_activity_event(
                            name="delegate",
                            call_id=delegation_id or delegated_response_id or "",
                            status="done",
                            title=title,
                        )
                    )
                    # completed の output は意図的に空 — 集めた呼び出しで処理する。
                    calls, delegated_calls = delegated_calls, []
                    if calls:
                        await _run_function_calls(
                            calls,
                            upstream=upstream,
                            send_client=send_client,
                            session_id=session_id,
                            manager=manager,
                            executor=executor,
                            pending_client_calls=pending_client_calls,
                            live=True,
                        )
                elif inner_type in {
                    "response.failed",
                    "response.incomplete",
                    "error",
                }:
                    # 委譲失敗を沈黙させない。確定できる断片は畳んでから
                    # delegate 活動行を failed で閉じ、エラーを通知する。
                    await flush_user()
                    await flush_assistant()
                    await flush_delegated()
                    delegated_calls.clear()
                    delegated_last_text = ""
                    await send_client(
                        assistant_tool_activity_event(
                            name="delegate",
                            call_id=delegation_id or delegated_response_id or "",
                            status="failed",
                        )
                    )
                    await send_client(
                        error_event(
                            _extract_error_message(inner),
                            code="delegation_error",
                        )
                    )
                elif inner_type in _LIVE_DELEGATION_QUIET_EVENTS:
                    continue
                else:
                    # 内側の音声イベント（response.output_audio.* / response.audio.*
                    # 等）は live-delegation ドキュメントに記載なし。万一届いても
                    # 中継せず type 名だけログへ出す（委譲バックエンドはテキスト
                    # 応答で、音声は表の Live モデルが session.output_audio.* で
                    # 出す想定）。
                    key = f"response.event:{inner_type}"
                    if key not in logged_types:
                        logged_types.add(key)
                        logger.warning(
                            "live delegation event (unhandled): %s", inner_type
                        )
            elif event_type == "session.usage.updated":
                # 既知イベント。中継はしないが usage だけログへ残す。
                logger.debug("live session usage: %s", event.get("usage") or event)
            elif event_type == "session.closed":
                return
            elif event_type == "error":
                message = _extract_error_message(event)
                await send_client(error_event(message, code="upstream_error"))
            elif event_type in _LIVE_QUIET_EVENTS:
                continue
            else:
                if event_type not in logged_types:
                    logged_types.add(event_type)
                    logger.warning("live upstream event (unhandled): %s", event_type)
            # イベントが TICK 未満の間隔で流れ続けても gap 判定を取りこぼさない
            # よう、処理後にもウォッチドッグを回す。
            await check_watchdogs()
    finally:
        # クライアントへ送り切れなかった未確定の断片も履歴には残す。
        try:
            await flush_user(send=False)
            await flush_assistant(send=False)
            await flush_delegated()
        except Exception:
            pass
