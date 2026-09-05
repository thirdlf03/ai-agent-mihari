"""アーカイブの起動設定。RoomConfig（トークン要り）には依存しない。

- ``MIHARI_ARCHIVE_CHANNEL_IDS`` … 収録チャンネル（カンマ区切り）。未設定なら収録 OFF。
- ``MIHARI_ARCHIVE_ROOT`` … 省略時は ``MIHARI_ROOM_ROOT``、さらに無ければ ``~/mihari-room``。
- 添付・URL の上限とタイムアウトも全部ここで読む。
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

#: Discord 側の制限に合わせた既定値（25 MiB）。
DEFAULT_MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024
#: URL メタ取得のボディ上限。
DEFAULT_MAX_URL_BYTES = 512 * 1024
DEFAULT_DOWNLOAD_TIMEOUT_SEC = 15.0
DEFAULT_URL_TIMEOUT_SEC = 8.0
DEFAULT_MAX_REDIRECTS = 5
DEFAULT_PDF_MAX_CHARS = 20_000
DEFAULT_QUEUE_SIZE = 256

#: 添付を落として良い拡張子。実行ファイルや秘密系は最初から除外。
ALLOWED_ATTACHMENT_EXTENSIONS = frozenset(
    {
        ".png",
        ".jpg",
        ".jpeg",
        ".gif",
        ".webp",
        ".bmp",
        ".pdf",
        ".txt",
        ".md",
        ".csv",
        ".json",
        ".xml",
        ".yaml",
        ".yml",
        ".log",
        ".html",
        ".htm",
    }
)

#: Content-Type 側で無条件に通す型。
_ALLOWED_CONTENT_TYPES = frozenset(
    {
        "application/pdf",
        "text/plain",
        "text/markdown",
        "text/csv",
        "application/json",
        "application/xml",
        "text/xml",
        "text/html",
        "text/yaml",
        "application/x-yaml",
    }
)


def allowed_attachment(content_type: str | None, filename: str) -> bool:
    """拡張子と Content-Type の両方で添付を弾く。片方不合格なら取り込まない。"""
    ext = Path(filename).suffix.lower()
    if ext not in ALLOWED_ATTACHMENT_EXTENSIONS:
        return False
    if not content_type:
        return True
    lowered = content_type.split(";")[0].strip().lower()
    if lowered in _ALLOWED_CONTENT_TYPES:
        return True
    if lowered.startswith("image/"):
        return True
    # Discord はよく application/octet-stream で返す。拡張子検査を通っていれば許す。
    if lowered == "application/octet-stream":
        return True
    return False


def default_root() -> Path:
    """CLI・デーモン共通のルート決定。環境変数 → ホーム。"""
    for key in ("MIHARI_ARCHIVE_ROOT", "MIHARI_ROOM_ROOT"):
        raw = (os.environ.get(key) or "").strip()
        if raw:
            return Path(raw).expanduser()
    return Path.home() / "mihari-room"


def _env_int(name: str, default: int) -> int:
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError as error:
        raise ValueError(f"{name} が数字ではない: {raw!r}") from error


def _env_float(name: str, default: float) -> float:
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError as error:
        raise ValueError(f"{name} が数字ではない: {raw!r}") from error


def _env_bool(name: str, default: bool) -> bool:
    raw = (os.environ.get(name) or "").strip().lower()
    if not raw:
        return default
    return raw not in {"0", "false", "no", "off"}


@dataclass(frozen=True, slots=True)
class ArchiveConfig:
    root: Path
    channel_ids: tuple[int, ...] = ()
    max_attachment_bytes: int = DEFAULT_MAX_ATTACHMENT_BYTES
    max_url_bytes: int = DEFAULT_MAX_URL_BYTES
    download_timeout: float = DEFAULT_DOWNLOAD_TIMEOUT_SEC
    url_timeout: float = DEFAULT_URL_TIMEOUT_SEC
    max_redirects: int = DEFAULT_MAX_REDIRECTS
    pdf_max_chars: int = DEFAULT_PDF_MAX_CHARS
    queue_size: int = DEFAULT_QUEUE_SIZE
    fetch_urls: bool = True
    fetch_attachments: bool = True

    @property
    def enabled(self) -> bool:
        """収録チャンネルが一つも無ければ、アーカイブ全体を無効にする。"""
        return bool(self.channel_ids)

    @property
    def db_path(self) -> Path:
        return self.root / "messages.db"

    @property
    def attachments_dir(self) -> Path:
        return self.root / "archive" / "attachments"

    @classmethod
    def from_environment(cls, root: Path | None = None) -> ArchiveConfig:
        """環境変数から作る。``MIHARI_ARCHIVE_CHANNEL_IDS`` が無ければ無効。"""
        raw = (os.environ.get("MIHARI_ARCHIVE_CHANNEL_IDS") or "").strip()
        channel_ids: tuple[int, ...] = ()
        if raw:
            parts: list[int] = []
            for item in raw.split(","):
                token = item.strip()
                if not token:
                    continue
                try:
                    parts.append(int(token))
                except ValueError as error:
                    raise ValueError(
                        f"MIHARI_ARCHIVE_CHANNEL_IDS に数字以外がある: {token!r}"
                    ) from error
            channel_ids = tuple(dict.fromkeys(parts))
        resolved_root = root if root is not None else default_root()
        return cls(
            root=resolved_root,
            channel_ids=channel_ids,
            max_attachment_bytes=_env_int(
                "MIHARI_ARCHIVE_MAX_ATTACHMENT_BYTES", DEFAULT_MAX_ATTACHMENT_BYTES
            ),
            max_url_bytes=_env_int("MIHARI_ARCHIVE_MAX_URL_BYTES", DEFAULT_MAX_URL_BYTES),
            download_timeout=_env_float(
                "MIHARI_ARCHIVE_DOWNLOAD_TIMEOUT", DEFAULT_DOWNLOAD_TIMEOUT_SEC
            ),
            url_timeout=_env_float("MIHARI_ARCHIVE_URL_TIMEOUT", DEFAULT_URL_TIMEOUT_SEC),
            max_redirects=_env_int("MIHARI_ARCHIVE_MAX_REDIRECTS", DEFAULT_MAX_REDIRECTS),
            pdf_max_chars=_env_int("MIHARI_ARCHIVE_PDF_MAX_CHARS", DEFAULT_PDF_MAX_CHARS),
            queue_size=_env_int("MIHARI_ARCHIVE_QUEUE_SIZE", DEFAULT_QUEUE_SIZE),
            fetch_urls=_env_bool("MIHARI_ARCHIVE_FETCH_URLS", True),
            fetch_attachments=_env_bool("MIHARI_ARCHIVE_FETCH_ATTACHMENTS", True),
        )

    def validate(self) -> None:
        """不正な上限値を弾く。0 以下の上限は事故のもと。"""
        if self.max_attachment_bytes <= 0 or self.max_url_bytes <= 0:
            raise ValueError("アーカイブの上限値は正の数にして")
        if self.queue_size <= 0:
            raise ValueError("MIHARI_ARCHIVE_QUEUE_SIZE は正の数にして")
        if self.max_redirects < 0:
            raise ValueError("MIHARI_ARCHIVE_MAX_REDIRECTS は 0 以上にして")


def load_archive_config(root: Path | None = None) -> ArchiveConfig:
    """環境変数から作って検証まで済ませる。デーモンと CLI が使う。"""
    config = ArchiveConfig.from_environment(root)
    config.validate()
    return config
