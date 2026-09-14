"""クライアント WS と Realtime upstream の双方向リレー。"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
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
    """クライアント音声の最終到着時刻をモノトニック秒で共有するホルダ。"""

    def __init__(self) -> None:
        self.last_at = asyncio.get_running_loop().time()

    def note(self) -> None:
        self.last_at = asyncio.get_running_loop().time()


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
    on_client_audio: Callable[[], None] | None = None,
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
    on_client_audio: Callable[[], None] | None = None,
) -> None:
    audio_b64 = frame.get("audio_base64") or frame.get("audio") or ""
    if not isinstance(audio_b64, str) or not audio_b64:
        raise ValueError("input.audio には audio_base64 が必要")
    # 形式チェックのみ。中身は OpenAI へそのまま渡し、ディスクには書かない。
    base64.b64decode(audio_b64, validate=True)
    await upstream.send({"type": "input_audio_buffer.append", "audio": audio_b64})
    if on_client_audio is not None:
        # live_audio の無音ペーサーが使う最終到着時刻を更新する。
        on_client_audio()
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
        # 活動通知だけを送る。
        await send_client(
            assistant_tool_activity_event(
                name=name,
                call_id=call_id,
                status="done" if outcome.ok else "failed",
            )
        )
        await _send_tool_result(upstream, call_id=call_id, outcome=outcome, live=live)
        submitted = True
    if submitted and not pending_client_calls:
        await upstream.send({"type": "response.create"} if live else response_create_event())


def _extract_error_message(event: dict[str, Any]) -> str:
    error = event.get("error")
    if isinstance(error, dict):
        return str(error.get("message") or error.get("code") or "upstream error")
    return str(error or "upstream error")


async def _live_upstream_to_client(
    upstream: RealtimeUpstream,
    converter: VoiceConverter,
    send_client: Any,
    *,
    session_id: str,
    manager: VoiceSessionManager,
    executor: Any,
    pending_client_calls: dict[str, str],
) -> None:
    """live_audio モードの upstream → クライアント中継。

    gpt-live-1 の ``session.output_audio.delta``（base64 PCM16 24kHz）を
    f32 に変換して VC へ通し、PCM16 に戻して ``assistant.audio`` で送る。

    Live の文字起こしは断片（delta）しか無く「ターン完了」イベントが無い。
    そのためユーザー発話は累積しておき、アシスタントの出力区切り
    （出力セグメント開始 or done/stopped）で確定扱いにして履歴へ記録する。
    未知のイベント type は 1 度だけログへ出して無視する。
    """
    user_transcript = ""
    assistant_transcript = ""
    output_active = False
    logged_types: set[str] = set()
    #: session.delegation.created で記録する委譲 ID（responses バックエンドの 1 委譲）。
    delegation_id: str | None = None
    #: 内側 response.event の ``response.created`` で記録する委譲応答 ID。
    delegated_response_id: str | None = None
    #: response.completed までに output_item.done で集めた function_call。
    delegated_calls: list[dict[str, Any]] = []

    async def flush_user(*, send: bool = True) -> None:
        nonlocal user_transcript
        if not user_transcript:
            return
        manager.record_user_text(session_id, user_transcript)
        if send:
            await send_client(user_text_event(text=user_transcript, done=True))
        user_transcript = ""

    async def flush_assistant(*, send: bool = True) -> None:
        nonlocal assistant_transcript
        if not assistant_transcript:
            return
        manager.record_assistant_text(session_id, assistant_transcript)
        if send:
            await send_client(assistant_text_event(text=assistant_transcript, done=True))
        assistant_transcript = ""

    try:
        while True:
            event = await upstream.receive()
            event_type = event.get("type", "")
            if event_type in LIVE_AUDIO_OUTPUT_EVENTS:
                manager.note_upstream_audio_output(session_id)
            if event_type == "session.output_audio.delta":
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
            elif event_type == "session.output_transcript.delta":
                if not output_active:
                    output_active = True
                    await flush_user()
                delta = str(event.get("delta") or "")
                if delta:
                    assistant_transcript += delta
                    await send_client(assistant_text_event(delta=delta, done=False))
            elif event_type == "session.input_transcript.delta":
                delta = str(event.get("delta") or "")
                if delta:
                    user_transcript += delta
                    await send_client(
                        user_text_event(text=user_transcript, delta=delta, done=False)
                    )
            elif event_type == "session.delegation.created":
                delegation = event.get("delegation") or {}
                delegation_id = str(delegation.get("id") or "")
                delegated_response_id = str(event.get("response_id") or "") or None
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
                inner = event.get("event") or {}
                inner_type = inner.get("type", "")
                if inner_type == "response.created":
                    delegated_response_id = str(
                        (inner.get("response") or {}).get("id") or ""
                    ) or delegated_response_id
                elif inner_type == "response.output_item.done":
                    item = inner.get("item") or {}
                    if item.get("type") == "function_call":
                        delegated_calls.append(item)
                elif inner_type == "response.completed":
                    # completed の output は意図的に空 — 集めた呼び出しで処理する。
                    calls, delegated_calls = delegated_calls, []
                    if calls:
                        await flush_user()
                        # ツール実行前に発話中の断片を確定させ、tool_activity と
                        # 続き発話のバブルを分ける。
                        await flush_assistant()
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
                else:
                    key = f"response.event:{inner_type}"
                    if key not in logged_types:
                        logged_types.add(key)
                        logger.info("live delegation event (unhandled): %s", inner_type)
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
                    logger.info("live upstream event (unhandled): %s", event_type)
    finally:
        # クライアントへ送り切れなかった未確定の断片も履歴には残す。
        try:
            await flush_user(send=False)
            await flush_assistant(send=False)
        except Exception:
            pass
