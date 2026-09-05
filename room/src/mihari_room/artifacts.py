"""成果物を root/previews/<ランダム token>/ に不変バージョンで置く。

- 公開するのは ``output/artifact/`` の中身だけ（``index.html`` があるとき）。
- 各バージョンは別 token のフォルダに丸ごと写し、後から変えない。
- マニフェスト（id / version / preview_url / sha256 / source_ids など）は
  ``root/registry/`` に置いて HTTP では出さない。
- シンボリックリンク・パストラバーサル・秘密（claim_url 等）は写さない。
- ``MIHARI_PREVIEW_BASE_URL`` が無い間は公開を無効（何もしない）。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import tempfile
from pathlib import Path
from typing import Any

from mihari_room.contracts import INPUT_DIRNAME, OUTPUT_DIRNAME, Job

#: 公開してよい web アセットの拡張子。これ以外は写さない。
_ALLOWED_WEB_EXT = {
    ".html",
    ".htm",
    ".css",
    ".js",
    ".mjs",
    ".json",
    ".svg",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".avif",
    ".ico",
    ".txt",
    ".xml",
    ".pdf",
    ".woff",
    ".woff2",
    ".ttf",
    ".otf",
    ".map",
    ".webmanifest",
}

#: 名前を見て弾く秘密の目印（大文字小文字を区別しない）。
_SECRET_MARKERS = (
    "secret",
    "password",
    "passwd",
    "credential",
    "claim_url",
    "private_key",
    "api_key",
    "apikey",
    "access_token",
    "auth_token",
)
#: 完全一致で弾くファイル名 / ディレクトリ名。
_SECRET_EXACT = {".env", ".pem", ".key", ".p12", ".pfx", ".p8", "id_rsa", "id_ed25519", ".git"}

PREVIEWS_DIRNAME = "previews"
REGISTRY_DIRNAME = "registry"
ARTIFACT_DIRNAME = "artifact"


def _is_secret_name(name: str) -> bool:
    lower = name.lower()
    if lower in _SECRET_EXACT:
        return True
    if lower.startswith(".env") or lower.endswith(".pem") or lower.endswith(".key"):
        return True
    stem = Path(lower).stem
    return any(marker in stem for marker in _SECRET_MARKERS)


class ArtifactPublisher:
    """ディスクへ不変バージョンを置く。公開 URL が無ければ何もしない。"""

    def __init__(self, root: Path, preview_base_url: str = "") -> None:
        self._root = Path(root)
        self._base = preview_base_url.strip().rstrip("/")
        self._previews_root = self._root / PREVIEWS_DIRNAME
        self._registry_root = self._root / REGISTRY_DIRNAME

    @property
    def enabled(self) -> bool:
        return bool(self._base)

    @property
    def base_url(self) -> str:
        return self._base

    def publish(self, job: Job, session_id: str | None = None) -> dict[str, Any] | None:
        """成功した仕事の成果物を 1 バージョン公開する。無効なら None。"""
        if not self.enabled:
            return None
        artifact = self._artifact_dir(job)
        if not (artifact / "index.html").is_file():
            return None
        files = self._collect(artifact)
        if not any(parts[-1].lower() == "index.html" for parts in files):
            return None

        token = secrets.token_hex(16)
        dest_root = self._previews_root / token
        for parts in files:
            self._copy_file(artifact, parts, dest_root)
        sha = self._digest(artifact, files)

        artifact_id, versions = self._load_registry(job.id)
        version = len(versions) + 1
        manifest: dict[str, Any] = {
            "id": artifact_id,
            "job_id": job.id,
            "session_id": session_id,
            "version": version,
            "kind": "web",
            "preview_url": f"{self._base}/{token}/",
            "expires_at": None,
            "sha256": sha,
            "source_ids": self._source_ids(job),
        }
        versions.append(manifest)
        self._save_registry(job.id, artifact_id, versions)
        return manifest

    def manifests_for(self, job_id: str) -> list[dict[str, Any]]:
        """仕事ごとの公開済みマニフェスト（バージョン順）。"""
        _, versions = self._load_registry(job_id)
        return versions

    # --- 内部 ------------------------------------------------------------

    def _artifact_dir(self, job: Job) -> Path:
        return job.directory / OUTPUT_DIRNAME / ARTIFACT_DIRNAME

    def _collect(self, artifact: Path) -> list[list[str]]:
        """公開する相対パスのリスト（拡張子・秘密・シンボリックリンクを弾く）。"""
        files: list[list[str]] = []
        for dirpath, dirnames, filenames in os.walk(artifact):
            dirnames[:] = [
                d
                for d in dirnames
                if d not in (".", "..")
                and not _is_secret_name(d)
                and not os.path.islink(os.path.join(dirpath, d))
            ]
            rel_dir = Path(dirpath).relative_to(artifact)
            for name in filenames:
                full = Path(dirpath) / name
                if os.path.islink(full):
                    continue
                if _is_secret_name(name) or any(_is_secret_name(p) for p in rel_dir.parts):
                    continue
                if full.suffix.lower() not in _ALLOWED_WEB_EXT:
                    continue
                files.append([*rel_dir.parts, name])
        return files

    def _copy_file(self, artifact: Path, parts: list[str], dest_root: Path) -> None:
        if any(part in ("", ".", "..") for part in parts):
            raise ValueError(f"preview の経路が不正: {parts!r}")
        if any(part.startswith(".") for part in parts):
            raise ValueError(f"preview の隠し経路は出さない: {parts!r}")
        src = artifact.joinpath(*parts)
        if src.is_symlink() or not src.is_file():
            raise ValueError(f"preview の実体が不正: {parts!r}")
        dest = dest_root.joinpath(*parts)
        if dest.is_symlink():
            raise ValueError(f"preview の差し替え symlink を拒否: {parts!r}")
        resolved = dest.resolve()
        try:
            root_resolved = dest_root.resolve()
        except OSError:
            root_resolved = dest_root
        if not resolved.is_relative_to(root_resolved):
            raise ValueError(f"preview を外へ出そうとした: {parts!r}")
        resolved.parent.mkdir(parents=True, exist_ok=True)
        # 自分で検証した普通のファイルだけを写す（シンボリックリンクは _collect で弾いた）。
        resolved.write_bytes(src.read_bytes())

    def _digest(self, artifact: Path, parts_list: list[list[str]]) -> str:
        # 決定的ハッシュ: 相対パス昇順に "path\\0bytes\\n" を積む。
        # session 連続性は manifest の session_id / source_ids で追える。
        h = hashlib.sha256()
        for parts in sorted(parts_list):
            rel = "/".join(parts)
            data = (artifact.joinpath(*parts)).read_bytes()
            h.update(rel.encode("utf-8"))
            h.update(b"\x00")
            h.update(data)
            h.update(b"\n")
        return h.hexdigest()

    def _source_ids(self, job: Job) -> list[str]:
        inp = job.directory / INPUT_DIRNAME
        if not inp.is_dir():
            return []
        return sorted(p.name for p in inp.iterdir() if p.is_file())

    def _registry_path(self, job_id: str) -> Path:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", job_id or ""):
            raise ValueError(f"preview registry の job id が不正: {job_id!r}")
        path = self._registry_root / f"{job_id}.json"
        if path.is_symlink():
            raise ValueError(f"preview registry の symlink を拒否: {job_id}")
        return path

    def _load_registry(self, job_id: str) -> tuple[str, list[dict[str, Any]]]:
        try:
            path = self._registry_path(job_id)
        except ValueError:
            return f"art-{job_id}", []
        if path.is_file() and not path.is_symlink():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                versions = data.get("versions", [])
                if isinstance(data.get("artifact_id"), str) and isinstance(versions, list):
                    return str(data["artifact_id"]), list(versions)
            except (ValueError, KeyError, TypeError, OSError):
                pass
        return f"art-{job_id}", []

    def _save_registry(self, job_id: str, artifact_id: str, versions: list[dict[str, Any]]) -> None:
        self._registry_root.mkdir(parents=True, exist_ok=True)
        path = self._registry_path(job_id)
        payload = (
            json.dumps(
                {"artifact_id": artifact_id, "versions": versions}, ensure_ascii=False, indent=2
            )
            + "\n"
        )
        # atomic: 同じ dir の tmp + os.replace。manifest の半端書きを残さない。
        fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".registry.", suffix=".tmp")
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
