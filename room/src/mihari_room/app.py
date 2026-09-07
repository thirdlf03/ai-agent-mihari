"""作業部屋の HTTP。ペットの `POST /jobs` を受ける。

Phase 2/3: 仕事の詳細・イベントの SSE・成果物プレビューの公開も担う。
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
import mimetypes
import re
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
from pydantic import BaseModel, field_validator
from starlette.responses import Response, StreamingResponse

from mihari_room.artifacts import PREVIEWS_DIRNAME, ArtifactPublisher, read_publication
from mihari_room.auth import verify_token
from mihari_room.config import RoomConfig
from mihari_room.contracts import (
    DEFAULT_JOB_TITLE,
    INPUT_DIRNAME,
    SCREENSHOTS_DIRNAME,
    CreateJobRequest,
    Job,
    JobSource,
    JobStatus,
    ScreenshotAttachment,
)
from mihari_room.discord.board import MAX_TITLE_LEN
from mihari_room.events import EventJournal, EventPhase, JournalKind
from mihari_room.orchestrator import RoomOrchestrator
from mihari_room.queue.file_queue import CancelNotAllowed
from mihari_room.store.file_store import JobNotFound
from mihari_room.worker.agent import read_session_id
from mihari_room.worker.wrangler_temp import temp_deploys_for

logger = logging.getLogger("mihari_room")

#: SSE のポーリング間隔。ファイルを読むだけなので短くてよい。
POLL_INTERVAL_SEC = 0.25
#: プロキシに落ちないためのハートビート間隔。
HEARTBEAT_INTERVAL_SEC = 15.0
#: 完了してから stream を閉じるまでの余裕。この間に続きが来たら繋ぎ直す。
TERMINAL_HOLD_SEC = 5.0

#: 依頼に同封できる添付の上限。desktop 側と同じ数値に揃える。
MAX_ATTACHMENT_COUNT = 10
#: 1 ファイルの上限 (20MB)。
MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
#: 依頼全体の添付合計の上限 (50MB)。
MAX_ATTACHMENT_TOTAL_BYTES = 50 * 1024 * 1024
#: 受け付ける添付の拡張子。PNG・JPEG・PDF・Markdown・テキスト。
ALLOWED_ATTACHMENT_EXT = frozenset({".png", ".jpg", ".jpeg", ".pdf", ".md", ".markdown", ".txt"})


class JobAttachmentBody(BaseModel):
    """JSON で送る添付 1 件。本文は base64。既存 JSON 依頼との互換を保つ。"""

    name: str = ""
    content_base64: str = ""


#: Mac スクショ（#22）の上限。ペットからの依頼窓は 1 枚ずつなので控えめでよい。
MAX_SCREENSHOTS_PER_REQUEST = 6
#: 1 枚の画像バイト上限（base64 前）。スクショ PNG は数 MB に収まる想定。
MAX_SCREENSHOT_BYTES = 30 * 1024 * 1024

_ALLOWED_SCREENSHOT_MEDIA = {
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/gif",
}
_ALLOWED_SCREENSHOT_SOURCES = {"display", "window"}


class ScreenshotBody(BaseModel):
    """依頼 JSON に載るスクショ 1 枚。バイト列は base64 で運ぶ。"""

    filename: str
    media_type: str = "image/png"
    content_base64: str
    #: 撮影メタデータ。Hermes へはバイト列で渡すため、これらは記録と将来の操作(#23)用。
    source: str = "display"
    source_title: str = ""
    display_id: int | None = None
    window_id: int | None = None
    pixel_width: int | None = None
    pixel_height: int | None = None
    point_width: float | None = None
    point_height: float | None = None
    backing_scale: float = 1.0
    frame_x: float | None = None
    frame_y: float | None = None

    @field_validator("filename")
    @classmethod
    def _plain_filename(cls, value: str) -> str:
        name = Path(value or "").name
        if not name or name != value:
            raise ValueError("filename はファイル名だけ（パスは不可）")
        return name

    @field_validator("media_type")
    @classmethod
    def _image_media_type(cls, value: str) -> str:
        if value not in _ALLOWED_SCREENSHOT_MEDIA:
            raise ValueError(f"対応していない画像形式: {value}")
        return value

    @field_validator("source")
    @classmethod
    def _known_source(cls, value: str) -> str:
        if value not in _ALLOWED_SCREENSHOT_SOURCES:
            raise ValueError(f"未知の撮影元: {value}")
        return value

    @field_validator("backing_scale")
    @classmethod
    def _positive_scale(cls, value: float) -> float:
        if value is not None and value <= 0:
            raise ValueError("backing_scale は正の数")
        return value


class JobCreateBody(BaseModel):
    title: str = ""
    body: str = ""
    source: JobSource = JobSource.PET
    requested_by: str | None = None
    #: 依頼ごとの明示的な外部公開許可（Temporary Deploy の扉）。
    #: False なら agent に cloudflare_temp_deploy を渡さない。
    allow_external_publish: bool = False
    screenshots: list[ScreenshotBody] = []
    attachments: list[JobAttachmentBody] = []


class JobCreateResponse(BaseModel):
    job_id: str
    thread_id: int | None
    status: str


class FollowupBody(BaseModel):
    body: str
    requested_by: str | None = None
    screenshots: list[ScreenshotBody] = []


class CancelBody(BaseModel):
    by: str | None = None


def _decode_screenshots(screenshots: list[ScreenshotBody] | None) -> list[ScreenshotAttachment]:
    """base64 のスクショをバイト列に戻す。上限を超えたら 400。"""
    if not screenshots:
        return []
    if len(screenshots) > MAX_SCREENSHOTS_PER_REQUEST:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"スクショは {MAX_SCREENSHOTS_PER_REQUEST} 枚まで",
        )
    decoded: list[ScreenshotAttachment] = []
    for item in screenshots:
        try:
            data = base64.b64decode(item.content_base64, validate=True)
        except (ValueError, TypeError) as error:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"base64 を読めない: {item.filename}",
            ) from error
        if not data:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"スクショが空: {item.filename}",
            )
        if len(data) > MAX_SCREENSHOT_BYTES:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=(
                    f"スクショが大きすぎる: {item.filename} "
                    f"({len(data)} bytes > {MAX_SCREENSHOT_BYTES})"
                ),
            )
        decoded.append(
            ScreenshotAttachment(
                filename=item.filename,
                data=data,
                metadata={
                    "media_type": item.media_type,
                    "source": item.source,
                    "source_title": item.source_title,
                    "display_id": item.display_id,
                    "window_id": item.window_id,
                    "pixel_width": item.pixel_width,
                    "pixel_height": item.pixel_height,
                    "point_width": item.point_width,
                    "point_height": item.point_height,
                    "backing_scale": item.backing_scale,
                    "frame_x": item.frame_x,
                    "frame_y": item.frame_y,
                },
            )
        )
    return decoded


def _decode_attachments(attachments: list[JobAttachmentBody]) -> list[tuple[str, bytes]]:
    """base64 の添付を検証・復号する。上限・形式が違えば 400。"""
    if len(attachments) > MAX_ATTACHMENT_COUNT:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"添付は {MAX_ATTACHMENT_COUNT} 個までだよ",
        )
    decoded: list[tuple[str, bytes]] = []
    total = 0
    for item in attachments:
        name = Path(item.name).name.strip()
        if not name:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="添付の名前が空だよ"
            )
        ext = Path(name).suffix.lower()
        if ext not in ALLOWED_ATTACHMENT_EXT:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{name} は添付できない形式だよ（PNG・JPEG・PDF・Markdown・テキスト）",
            )
        try:
            data = base64.b64decode(item.content_base64, validate=True)
        except (binascii.Error, ValueError) as error:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{name} のデータが壊れているよ",
            ) from error
        if len(data) > MAX_ATTACHMENT_BYTES:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{name} が 20MB を超えているよ",
            )
        total += len(data)
        if total > MAX_ATTACHMENT_TOTAL_BYTES:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="添付の合計が 50MB を超えているよ",
            )
        decoded.append((name, data))
    return decoded


def derive_title(title: str, body: str) -> str:
    """ペット側と同じ。空なら本文の先頭の中身がある行、最大 100 文字。

    どちらも空なら Discord が弾く空スレ名を避けるため「依頼」。
    """
    trimmed = title.strip()
    if trimmed:
        return trimmed[:MAX_TITLE_LEN]
    for line in body.splitlines():
        first = line.strip()
        if first:
            return first[:MAX_TITLE_LEN]
    return DEFAULT_JOB_TITLE


def parse_last_event_id(raw: str | None) -> int:
    """SSE の Last-Event-ID を整数に。未知・壊れていれば 0（最初から）。

    未知の id で黙って取りこぼさないために、解釈できないものは先頭に戻す。
    """
    if raw is None or not raw.strip():
        return 0
    try:
        value = int(raw.strip())
    except ValueError:
        return 0
    return value if value >= 0 else 0


def _sse(event: dict[str, Any]) -> str:
    return f"id: {event['id']}\nevent: job\ndata: {json.dumps(event, ensure_ascii=False)}\n\n"


async def _job_events_stream(
    orchestrator: RoomOrchestrator,
    job_id: str,
    replay_from: int,
    poll: float,
    heartbeat: float,
    hold: float,
) -> AsyncIterator[str]:
    """出来事を追いかける非同期ストリーム。閉じたら直すのは呼び出し側。"""
    journal = EventJournal.for_job(orchestrator.store.job_dir(job_id))
    last_id = replay_from
    last_activity = time.monotonic()
    terminal_since: float | None = None
    try:
        while True:
            new = journal.after(last_id)
            for event in new:
                yield _sse(event)
                last_id = event["id"]
                last_activity = time.monotonic()

            try:
                job = orchestrator.store.get(job_id)
            except JobNotFound:
                # 途中で消えたら静かに閉じる。
                return
            is_terminal = job.status in (
                JobStatus.DONE,
                JobStatus.FAILED,
                JobStatus.CANCELLED,
            )
            if is_terminal:
                if terminal_since is None:
                    terminal_since = time.monotonic()
                if (
                    terminal_since is not None
                    and time.monotonic() - terminal_since >= hold
                    and not new
                ):
                    return
            else:
                terminal_since = None

            if time.monotonic() - last_activity >= heartbeat:
                yield ": hb\n\n"
                last_activity = time.monotonic()
            await asyncio.sleep(poll)
    except asyncio.CancelledError:
        raise


@asynccontextmanager
async def _lifespan(app: FastAPI) -> AsyncIterator[None]:
    orchestrator: RoomOrchestrator = app.state.orchestrator
    orchestrator.restore()
    if app.state.start_pump:
        orchestrator.start_pump()
    starter = getattr(app.state, "discord_starter", None)
    stop = getattr(app.state, "discord_stopper", None)
    if callable(starter):
        await starter()
    try:
        yield
    finally:
        if callable(stop):
            await stop()
        await orchestrator.aclose()


def _job_detail(orchestrator: RoomOrchestrator, job: Job) -> dict[str, Any]:
    """詳細。絶対パスは出さない。session・成果物・スクショは置いてあれば。"""
    journal = EventJournal.for_job(job.directory)
    publisher = orchestrator.publisher
    artifacts = publisher.manifests_for(job.id) if publisher is not None else []
    return {
        "job_id": job.id,
        "title": job.title,
        "status": job.status.value,
        "thread_id": job.thread_id,
        "session_id": read_session_id(job),
        "allow_external_publish": job.allow_external_publish,
        "artifacts": artifacts,
        "temp_deploys": temp_deploys_for(job.directory),
        "screenshots": _screenshot_details(job),
        "latest_event": journal.latest(),
    }


#: スクショの実体として認める拡張子（詳細一覧の表示用）。
_SCREENSHOT_WEB_SUFFIXES = frozenset({".png", ".jpg", ".jpeg", ".webp", ".gif"})


def _screenshot_details(job: Job) -> list[dict[str, Any]]:
    """保存済みスクショの一覧。パスは出さず、名前と撮影メタデータだけ。"""
    folder = job.directory / INPUT_DIRNAME / SCREENSHOTS_DIRNAME
    if not folder.is_dir():
        return []
    result: list[dict[str, Any]] = []
    for path in sorted(folder.glob("*.json")):
        try:
            meta = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(meta, dict):
            continue
        image = next(
            (
                p
                for p in folder.glob(path.stem + ".*")
                if p.is_file() and p.suffix.lower() in _SCREENSHOT_WEB_SUFFIXES
            ),
            None,
        )
        result.append(
            {
                "filename": meta.get("original_filename", path.stem),
                "stored_name": image.name if image is not None else path.stem + ".png",
                "media_type": meta.get("media_type"),
                "source": meta.get("source"),
                "source_title": meta.get("source_title"),
                "display_id": meta.get("display_id"),
                "window_id": meta.get("window_id"),
                "pixel_width": meta.get("pixel_width"),
                "pixel_height": meta.get("pixel_height"),
                "backing_scale": meta.get("backing_scale"),
                "frame_x": meta.get("frame_x"),
                "frame_y": meta.get("frame_y"),
            }
        )
    return result


def _job_list_item(orchestrator: RoomOrchestrator, job: Job) -> dict[str, Any]:
    """一覧 1 件。検索用に source・出生時刻・本文を足す。"""
    detail = _job_detail(orchestrator, job)
    detail["source"] = job.source.value
    detail["created_at"] = _created_at(orchestrator, job.id)
    detail["body"] = job.body
    return detail


def _created_at(orchestrator: RoomOrchestrator, job_id: str) -> float | None:
    """meta.json の出生時刻。読めなければ None。"""
    try:
        raw = (orchestrator.store.job_dir(job_id) / "meta.json").read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        value = float(json.loads(raw).get("created_at", 0.0))
    except (ValueError, TypeError, AttributeError):
        return None
    return value


def _preview_headers() -> dict[str, str]:
    """未認証プレビューの安全ヘッダ。nosniff / no-referrer / sandbox CSP。

    opaque origin の sandbox（allow-same-origin なし）で動かす。
    相対 CSS/画像/フォントと同一フォルダの JS だけ許し、API origin への権限は渡さない
    （connect-src 'none'、form-action 'none'）。対話モック用の script は
    ``sandbox allow-scripts`` で許すが、allow-same-origin は付けないので
    親ページの DOM・storage には触れない。
    """
    return {
        "Content-Security-Policy": (
            "sandbox allow-scripts; default-src 'none'; base-uri 'none'; "
            "form-action 'none'; connect-src 'none'; worker-src 'none'; "
            "img-src 'self' data: https:; media-src 'self' data:; "
            "style-src 'self' 'unsafe-inline'; script-src 'self'; "
            "font-src 'self' data:;"
        ),
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        "X-Frame-Options": "DENY",
        "Cache-Control": "no-store",
    }


def _serve_artifact_files(config: RoomConfig, token: str, rest: str) -> Response:
    """内容フォルダ token から 1 ファイルを返す。ルートやメタデータは晒さない。

    - token 自体・token 配下の symlink chain は拒否（FS 改ざん時の他 job 漏洩対策）
    - ``..`` / 絶対パス / 隠しファイル（``.*``）・メタデータ名は 404
    - 公開 allowlist（ArtifactPublisher と同じ拡張子）以外の実ファイルは出さない
    - 非公開も公開も同じ安全ヘッダ（no-store）で返す（キャッシュで停止を迂回させない）
    """
    from mihari_room.artifacts import _ALLOWED_WEB_EXT

    if not re.fullmatch(r"[A-Za-z0-9_-]+", token):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    previews_root = (config.root / PREVIEWS_DIRNAME).resolve()
    token_dir = config.root / PREVIEWS_DIRNAME / token
    # token 置き場自体の symlink は拒否。
    if token_dir.is_symlink() or not token_dir.is_dir():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    rel = Path(rest or "index.html")
    if rel.is_absolute() or ".." in rel.parts:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    if any(part.startswith(".") for part in rel.parts):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    candidate = token_dir / rel
    if candidate.is_symlink():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    try:
        resolved = candidate.resolve()
    except OSError as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error
    try:
        token_resolved = token_dir.resolve()
    except OSError as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error
    if token_resolved != previews_root / token or not resolved.is_relative_to(token_resolved):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    # 途中の symlink chain（他 token・root 外への差し替え）も拒否。
    node = candidate
    for _ in range(len(rel.parts) + 1):
        if node.is_symlink():
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
        if node == token_dir:
            break
        node = node.parent
    if not resolved.is_file() or resolved.is_symlink():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    if resolved.suffix.lower() not in _ALLOWED_WEB_EXT:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    media = mimetypes.guess_type(resolved.name)[0] or "application/octet-stream"
    return Response(content=resolved.read_bytes(), media_type=media, headers=_preview_headers())


def _serve_preview(config: RoomConfig, token: str, rest: str) -> Response:
    """公開 token → バージョンの内容フォルダを解決して 1 ファイル返す。

    公開 token は publications 表にあるものだけ。非公開へ戻すと表から消えるので、
    古い URL（HTML・画像・CSS・PDF のどのファイルでも）は 404 になる。
    """
    publication = read_publication(config.root, token)
    if publication is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    content_token = publication.get("content_token") or ""
    return _serve_artifact_files(config, content_token, rest)


#: candidate id は MemoryCandidateStore が振る hex（12 chars）。外からはこの形だけ。
_CANDIDATE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")


def _memory_store_for_config(config: RoomConfig):
    from mihari_room.worker.memory import MemoryCandidateStore
    from mihari_room.worker.runtime_lock import resolve_hermes_home

    return MemoryCandidateStore(config.root, resolve_hermes_home(config.root))


def _candidate_to_dict(candidate: Any) -> dict[str, Any]:
    return {
        "id": candidate.id,
        "target": candidate.target,
        "content": candidate.content,
        "status": candidate.status,
        "created_at": candidate.created_at,
    }


async def _memory_decide(
    request: Request, job_id: str, candidate_id: str, *, approve: bool
) -> dict[str, Any]:
    """memory 候補の approve/reject。承認者は token owner（config 側）のみ。

    body の身分表示は一切使わない。認証済み token の持ち主 = owner として扱い、
    記録上の approved_by も config.owner_id にする。owner 未設定なら 403。
    """
    orchestrator = request.app.state.orchestrator
    config: RoomConfig = request.app.state.config
    if not config.owner_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="owner が未設定（MIHARI_OWNER_ID）"
        )
    try:
        orchestrator.store.get(job_id)
    except JobNotFound as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない") from error
    if not _CANDIDATE_ID_RE.match(candidate_id or ""):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="候補がない")
    store = _memory_store_for_config(config)
    try:
        if approve:
            candidate = store.approve(job_id, candidate_id)
        else:
            candidate = store.reject(job_id, candidate_id)
    except ValueError as error:
        message = str(error)
        if "unknown candidate" in message or "unknown job" in message or "invalid job" in message:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="候補がない"
            ) from error
        if "already approved" in message or "already rejected" in message:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=message) from error
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=message) from error
    # 決定を日誌にも残す（SSE で desktop が拾える）。job は塞がない。
    try:
        journal = EventJournal.for_job(orchestrator.store.job_dir(job_id))
        from mihari_room.events import EventPhase, JournalKind

        journal.append(
            job_id=job_id,
            phase=EventPhase.WAITING,
            kind=JournalKind.LOG,
            text=("memory 候補を確定したよ。" if approve else "memory 候補を捨てたよ。"),
        )
    except Exception:
        pass
    return _candidate_to_dict(candidate)


def _artifact_target(request: Request, job_id: str) -> tuple[Any, Any]:
    """成果物操作の共通前処理。owner と仕事と publisher を確かめる。"""
    config: RoomConfig = request.app.state.config
    orchestrator = request.app.state.orchestrator
    if not config.owner_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="owner が未設定（MIHARI_OWNER_ID）"
        )
    try:
        job = orchestrator.store.get(job_id)
    except JobNotFound as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない") from error
    publisher = orchestrator.publisher
    if publisher is None or not getattr(publisher, "enabled", False):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="成果物がない")
    return job, publisher


def _journal_artifact(
    request: Request,
    job_id: str,
    phase: Any,
    kind: Any,
    *,
    text: str,
) -> None:
    """成果物操作の結果を日誌に残す（SSE と詳細が拾える）。失敗しても握りつぶす。"""
    try:
        orchestrator = request.app.state.orchestrator
        journal = EventJournal.for_job(orchestrator.store.job_dir(job_id))
        journal.append(job_id=job_id, phase=phase, kind=kind, text=text)
    except Exception:
        pass


def create_app(
    config: RoomConfig,
    orchestrator: RoomOrchestrator,
    *,
    discord_starter: Any = None,
    discord_stopper: Any = None,
    start_pump: bool = True,
) -> FastAPI:
    app = FastAPI(
        title="Mihari room",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=_lifespan,
    )
    app.state.config = config
    app.state.orchestrator = orchestrator
    app.state.discord_starter = discord_starter
    app.state.discord_stopper = discord_stopper
    app.state.start_pump = start_pump
    if orchestrator.publisher is None:
        orchestrator.attach_publisher(
            ArtifactPublisher(root=config.root, preview_base_url=config.preview_base_url)
        )
    # 旧形式の registry（公開状態なし）を公開状態として移行する。
    # 既存 URL が動き続け、UI から停止できるようにする。
    try:
        if orchestrator.publisher is not None:
            orchestrator.publisher.migrate()
    except Exception:
        logger.exception("成果物 registry の移行に失敗")

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    # --- ペットの依頼 ------------------------------------------------------

    @app.post("/jobs", dependencies=[Depends(verify_token)])
    async def create_job(request: Request, body: JobCreateBody) -> JobCreateResponse:
        title = derive_title(body.title, body.body)
        attachments = _decode_attachments(body.attachments)
        job_request = CreateJobRequest(
            title=title,
            body=body.body,
            source=body.source,
            requested_by=body.requested_by,
            allow_external_publish=body.allow_external_publish,
        )
        screenshots = _decode_screenshots(body.screenshots)
        try:
            job = await request.app.state.orchestrator.submit(
                job_request, attachments=attachments, screenshots=screenshots
            )
        except RuntimeError as error:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(error)
            ) from error
        return JobCreateResponse(
            job_id=job.id,
            thread_id=job.thread_id,
            status=job.status.value,
        )

    @app.get("/capabilities", dependencies=[Depends(verify_token)])
    def capabilities() -> dict[str, Any]:
        """この部屋が実装している機能を返す。旧バックエンドでは未対応操作を出さないため。"""
        return {
            "attachment_upload": True,
            "job_list": True,
            "job_history": True,
        }

    # 可変ルート `/jobs/{job_id}` より先に定義する（/jobs/running が奪われないように）。
    @app.get("/jobs/running", dependencies=[Depends(verify_token)])
    def list_running(request: Request) -> dict[str, Any]:
        orchestrator = request.app.state.orchestrator
        return {
            "jobs": [_job_detail(orchestrator, job) for job in orchestrator.store.list_running()]
        }

    # 履歴を含む一覧。待ち・実行中・完了・失敗・中断と Discord 作成を全部返す（新しい順）。
    @app.get("/jobs", dependencies=[Depends(verify_token)])
    def list_jobs(request: Request) -> dict[str, Any]:
        orchestrator = request.app.state.orchestrator
        return {
            "jobs": [_job_list_item(orchestrator, job) for job in orchestrator.store.list_all()]
        }

    @app.get("/jobs/{job_id}", dependencies=[Depends(verify_token)])
    def job_detail(request: Request, job_id: str) -> dict[str, Any]:
        orchestrator = request.app.state.orchestrator
        try:
            job = orchestrator.store.get(job_id)
        except JobNotFound as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない"
            ) from error
        return _job_detail(orchestrator, job)

    @app.post("/jobs/{job_id}/followup", dependencies=[Depends(verify_token)])
    async def job_followup(request: Request, job_id: str, body: FollowupBody) -> JobCreateResponse:
        if not body.body.strip():
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="続きを書いて")
        orchestrator = request.app.state.orchestrator
        screenshots = _decode_screenshots(body.screenshots)
        try:
            job = await orchestrator.follow_up_job(
                job_id, body.body, requested_by=body.requested_by, screenshots=screenshots
            )
        except JobNotFound as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない"
            ) from error
        return JobCreateResponse(
            job_id=job.id,
            thread_id=job.thread_id,
            status=job.status.value,
        )

    @app.post("/jobs/{job_id}/cancel", dependencies=[Depends(verify_token)])
    async def cancel_job(
        request: Request, job_id: str, body: CancelBody | None = None
    ) -> JobCreateResponse:
        payload = body or CancelBody()
        by = payload.by or request.app.state.config.owner_id
        if not by:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="誰が止めるかを書いて"
            )
        try:
            job = await request.app.state.orchestrator.cancel(job_id, by=by)
        except JobNotFound as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない"
            ) from error
        except CancelNotAllowed as error:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
        return JobCreateResponse(
            job_id=job.id,
            thread_id=job.thread_id,
            status=job.status.value,
        )

    # --- イベントの SSE ------------------------------------------------------

    @app.get("/jobs/{job_id}/events", dependencies=[Depends(verify_token)])
    async def job_events(
        request: Request,
        job_id: str,
        last_event_id: str | None = Header(default=None, alias="Last-Event-ID"),
    ) -> StreamingResponse:
        orchestrator = request.app.state.orchestrator
        try:
            orchestrator.store.get(job_id)
        except JobNotFound as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない"
            ) from error
        replay_from = parse_last_event_id(last_event_id)
        stream = _job_events_stream(
            orchestrator,
            job_id,
            replay_from,
            POLL_INTERVAL_SEC,
            HEARTBEAT_INTERVAL_SEC,
            TERMINAL_HOLD_SEC,
        )
        return StreamingResponse(
            stream,
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )

    # --- memory 承認（owner の明示承認。body の身分は使わない） ------------------

    @app.get("/jobs/{job_id}/memory", dependencies=[Depends(verify_token)])
    def job_memory(request: Request, job_id: str) -> dict[str, Any]:
        orchestrator = request.app.state.orchestrator
        config = request.app.state.config
        try:
            orchestrator.store.get(job_id)
        except JobNotFound as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない"
            ) from error
        store = _memory_store_for_config(config)
        try:
            candidates = store.list(job_id)
        except ValueError as error:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
        return {
            "candidates": [
                {
                    "id": c.id,
                    "target": c.target,
                    "content": c.content,
                    "status": c.status,
                    "created_at": c.created_at,
                }
                for c in candidates
            ]
        }

    @app.post("/jobs/{job_id}/memory/{candidate_id}/approve", dependencies=[Depends(verify_token)])
    async def job_memory_approve(
        request: Request, job_id: str, candidate_id: str
    ) -> dict[str, Any]:
        return await _memory_decide(request, job_id, candidate_id, approve=True)

    @app.post("/jobs/{job_id}/memory/{candidate_id}/reject", dependencies=[Depends(verify_token)])
    async def job_memory_reject(request: Request, job_id: str, candidate_id: str) -> dict[str, Any]:
        return await _memory_decide(request, job_id, candidate_id, approve=False)

    @app.post(
        "/jobs/{job_id}/artifacts/{version}/rollback",
        dependencies=[Depends(verify_token)],
    )
    def job_artifact_rollback(request: Request, job_id: str, version: int) -> dict[str, Any]:
        """「この版を再公開」。旧版の内容を新しい非公開バージョンとして載せる。"""
        job, publisher = _artifact_target(request, job_id)
        try:
            manifest = publisher.rollback(job, version, read_session_id(job))
        except LookupError as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="成果物がない"
            ) from error
        except ValueError as error:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=str(error)
            ) from error
        _journal_artifact(
            request,
            job_id,
            EventPhase.DONE,
            JournalKind.SUMMARY,
            text=(
                f"v{version} の内容を v{manifest['version']} として再公開したよ"
                "（非公開・部屋から開ける）。"
            ),
        )
        return manifest

    @app.post(
        "/jobs/{job_id}/artifacts/{version}/publish",
        dependencies=[Depends(verify_token)],
    )
    def job_artifact_publish(request: Request, job_id: str, version: int) -> dict[str, Any]:
        """版を公開し共有 URL を発行する。非公開へ戻してからの再公開は新 URL。"""
        job, publisher = _artifact_target(request, job_id)
        try:
            manifest = publisher.publish_version(job_id, version)
        except LookupError as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="成果物がない"
            ) from error
        except ValueError as error:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
        url = manifest.get("preview_url") or ""
        _journal_artifact(
            request,
            job_id,
            EventPhase.DONE,
            JournalKind.SUMMARY,
            text=f"v{version} を公開したよ: {url}" if url else f"v{version} を公開したよ。",
        )
        return manifest

    @app.post(
        "/jobs/{job_id}/artifacts/{version}/unpublish",
        dependencies=[Depends(verify_token)],
    )
    def job_artifact_unpublish(request: Request, job_id: str, version: int) -> dict[str, Any]:
        """版を非公開に戻す。その版の発行済み共有 URL をすべて無効化する。"""
        job, publisher = _artifact_target(request, job_id)
        try:
            manifest = publisher.unpublish_version(job_id, version)
        except LookupError as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="成果物がない"
            ) from error
        except ValueError as error:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=str(error)
            ) from error
        _journal_artifact(
            request,
            job_id,
            EventPhase.DONE,
            JournalKind.SUMMARY,
            text=f"v{version} の公開を止めたよ（古い URL は無効にした）。",
        )
        return manifest

    @app.post(
        "/jobs/{job_id}/artifacts/{version}/restore",
        dependencies=[Depends(verify_token)],
    )
    def job_artifact_restore(request: Request, job_id: str, version: int) -> dict[str, Any]:
        """「この版から修正」の土台。その版の作業ファイルを作業フォルダへ復元する。

        実行中の仕事には復元しない（走っているファイルを上書きしない）。
        復元したファイルは次の実行がそのまま使う。
        """
        job, publisher = _artifact_target(request, job_id)
        latest = request.app.state.orchestrator.store.get(job_id)
        if latest.status is JobStatus.RUNNING:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail="実行中の仕事は復元できない"
            )
        try:
            restored = publisher.restore(job, version)
        except LookupError as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="成果物がない"
            ) from error
        except ValueError as error:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=str(error)
            ) from error
        _journal_artifact(
            request,
            job_id,
            EventPhase.QUEUED,
            JournalKind.LOG,
            text=f"v{version} の作業ファイルを戻したよ（{restored} ファイル）。",
        )
        return {"job_id": job_id, "version": version, "restored_files": restored}

    @app.get(
        "/jobs/{job_id}/artifacts/{version}/files",
        dependencies=[Depends(verify_token)],
    )
    @app.get(
        "/jobs/{job_id}/artifacts/{version}/files/{rest:path}",
        dependencies=[Depends(verify_token)],
    )
    def job_artifact_files(
        request: Request, job_id: str, version: int, rest: str = "index.html"
    ) -> Response:
        """認証付きの成果物取得（非公開でも desktop 内プレビューで見られる）。

        URL に Room トークンは載せない。認証はヘッダだけ。
        """
        config: RoomConfig = request.app.state.config
        publisher = request.app.state.orchestrator.publisher
        if publisher is None or not getattr(publisher, "enabled", False):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="成果物がない")
        try:
            request.app.state.orchestrator.store.get(job_id)
        except JobNotFound as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="仕事がない"
            ) from error
        try:
            content_token = publisher.content_token_for(job_id, version)
        except LookupError as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="成果物がない"
            ) from error
        return _serve_artifact_files(config, content_token, rest)

    # --- プレビュー（未認証・安全ヘッダ付き） --------------------------------

    @app.get("/previews/{token}")
    def preview_index(token: str) -> Response:
        return _serve_preview(config, token, "index.html")

    @app.get("/previews/{token}/{rest:path}")
    def preview_file(token: str, rest: str) -> Response:
        return _serve_preview(config, token, rest)

    return app
