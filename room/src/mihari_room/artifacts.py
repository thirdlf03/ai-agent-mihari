"""成果物を root/previews/<ランダム token>/ に不変バージョンで置く。

- 公開するのは ``output/artifact/`` の中身だけ（``index.html`` があるとき）。
- 各バージョンは別 token のフォルダに丸ごと写し、後から変えない。
- マニフェスト（id / version / 公開状態 / sha256 / source_ids など）は
  ``root/registry/`` に置いて HTTP では出さない。
- シンボリックリンク・パストラバーサル・秘密（claim_url 等）は写さない。
- ``MIHARI_PREVIEW_BASE_URL`` が無い間は公開を無効（何もしない）。

公開状態はバージョンごとに持つ（新規は非公開）。

- 新しくできたバージョンは ``非公開``。認証付きの ``view_url`` 経路
  （API ホスト上の ``/jobs/<id>/artifacts/<n>/files/...``）だけで見られる。
- 公開にすると共有 URL（``preview_url``）を発行する。共有 token は発行のたびに
  新しく、非公開に戻すと当該バージョンの発行済み URL はすべて無効になる
  （再公開は別 token の新 URL）。
- 既存（アップグレード前）のバージョンは公開状態として移行し、後から止められる。
  新しいバージョンへ公開状態は引き継がない。
- 公開 token → (job, version, content token) の対応は ``registry/publications.json``
  に置く。公開配信経路はここを引いてから内容フォルダを読むので、
  ``previews/`` 直下の非公開フォルダには直接辿り着けない。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import tempfile
import threading
from pathlib import Path
from typing import Any

from mihari_room.contracts import INPUT_DIRNAME, OUTPUT_DIRNAME, REQUEST_FILENAME, Job

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

#: 公開 token の対応表（token -> {job_id, version, content_token}）。
PUBLICATIONS_FILENAME = "publications.json"

#: レジストリ内で永続化する公開状態。
VISIBILITY_PRIVATE = "private"
VISIBILITY_PUBLIC = "public"


def _version_id(artifact_id: str, version: int) -> str:
    return f"{artifact_id}-v{version}"


def _token_from_preview_url(url: str) -> str | None:
    token = url.strip().rstrip("/").rsplit("/", 1)[-1]
    if re.fullmatch(r"[A-Za-z0-9_-]+", token or ""):
        return token
    return None


def _is_secret_name(name: str) -> bool:
    lower = name.lower()
    if lower in _SECRET_EXACT:
        return True
    if lower.startswith(".env") or lower.endswith(".pem") or lower.endswith(".key"):
        return True
    stem = Path(lower).stem
    return any(marker in stem for marker in _SECRET_MARKERS)


def _view_url(job_id: str, version: int) -> str:
    """認証付きプレビュー経路（相対パス）。トークンは載せない。"""
    return f"/jobs/{job_id}/artifacts/{version}/files/"


def read_publication(root: Path, token: str) -> dict[str, Any] | None:
    """公開 token が指す (job, version, content token)。無ければ None。

    配信経路（``/previews/<token>/...``）がここを引く。非公開へ戻すと
    この表から消えるので、古い URL はどのファイルも 404 になる。
    """
    if not re.fullmatch(r"[A-Za-z0-9_-]+", token or ""):
        return None
    path = Path(root) / REGISTRY_DIRNAME / PUBLICATIONS_FILENAME
    if path.is_symlink() or not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return None
    publications = data.get("publications") if isinstance(data, dict) else None
    if not isinstance(publications, dict):
        return None
    entry = publications.get(token)
    if not isinstance(entry, dict):
        return None
    job_id = entry.get("job_id")
    version = entry.get("version")
    content_token = entry.get("content_token")
    if not (
        isinstance(job_id, str) and isinstance(version, int) and isinstance(content_token, str)
    ):
        return None
    if not re.fullmatch(r"[A-Za-z0-9_-]+", content_token):
        return None
    return {"job_id": job_id, "version": version, "content_token": content_token}


class ArtifactPublisher:
    """ディスクへ不変バージョンを置く。公開 URL が無ければ何もしない。"""

    def __init__(self, root: Path, preview_base_url: str = "") -> None:
        self._root = Path(root)
        self._base = preview_base_url.strip().rstrip("/")
        self._previews_root = self._root / PREVIEWS_DIRNAME
        self._registry_root = self._root / REGISTRY_DIRNAME
        # 1 プロセスの publisher で registry の読み書きを直列化する。
        self._lock = threading.Lock()

    @property
    def enabled(self) -> bool:
        return bool(self._base)

    @property
    def base_url(self) -> str:
        return self._base

    def publish(self, job: Job, session_id: str | None = None) -> dict[str, Any] | None:
        """成功した仕事の成果物を 1 バージョン登録する。無効なら None。

        新しくできたバージョンはつねに非公開。共有 URL は出さない。
        """
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

        with self._lock:
            artifact_id, versions = self._load_registry(job.id)
            version = len(versions) + 1
            record = self._record(
                artifact_id=artifact_id,
                job_id=job.id,
                session_id=session_id,
                version=version,
                token=token,
                visibility=VISIBILITY_PRIVATE,
                share_token=None,
                sha=sha,
                source_ids=self._source_ids(job),
            )
            versions.append(record)
            self._save_registry(job.id, artifact_id, versions)
        return self._view(artifact_id, record)

    def manifests_for(self, job_id: str) -> list[dict[str, Any]]:
        """仕事ごとの公開済みマニフェスト（バージョン順）。id は version ごとに一意。

        古い registry（公開状態の無い項目）は「公開済み」として読み出し時に
        正規化する。共有 token が無い項目は従来どおり preview_url の token を
        内容フォルダとして扱う。
        """
        artifact_id, versions = self._load_registry(job_id)
        out: list[dict[str, Any]] = []
        for item in versions:
            record, _ = self._normalize(artifact_id, item)
            out.append(self._view(artifact_id, record))
        return out

    def rollback(self, job: Job, version: int, session_id: str | None = None) -> dict[str, Any]:
        """旧バージョンのファイルを新しい不変バージョンとして再公開する。

        「この版を再公開」に相当。過去のバージョン内容を丸ごと写して最新の
        バージョン番号に載せる。新しいバージョンは非公開で始まり、公開状態は
        引き継がない（公開したければ明示的に公開操作を行う）。
        """
        if not self.enabled:
            raise ValueError("preview が無効")
        if not isinstance(version, int) or version < 1:
            raise LookupError(f"unknown version: {version}")
        with self._lock:
            artifact_id, versions = self._load_registry(job.id)
            source = next((item for item in versions if item.get("version") == version), None)
            if source is None:
                raise LookupError(f"unknown version: {version}")
            source_rec, _ = self._normalize(artifact_id, source)
            token = source_rec.get("token")
            if not token:
                raise LookupError(f"unknown version: {version}")
            src_root = self._previews_root / token
            if src_root.is_symlink() or not src_root.is_dir():
                raise LookupError(f"unknown version: {version}")
            files = self._collect(src_root)
            if not any(parts[-1].lower() == "index.html" for parts in files):
                raise LookupError(f"unknown version: {version}")

            new_token = secrets.token_hex(16)
            dest_root = self._previews_root / new_token
            for parts in files:
                self._copy_file(src_root, parts, dest_root)
            sha = self._digest(src_root, files)
            new_version = len(versions) + 1
            new_rec = self._record(
                artifact_id=artifact_id,
                job_id=job.id,
                session_id=session_id,
                version=new_version,
                token=new_token,
                visibility=VISIBILITY_PRIVATE,
                share_token=None,
                sha=sha,
                source_ids=list(source_rec.get("source_ids") or []),
            )
            versions.append(new_rec)
            self._save_registry(job.id, artifact_id, versions)
            return self._view(artifact_id, new_rec)

    def publish_version(self, job_id: str, version: int) -> dict[str, Any]:
        """バージョンを公開状態にし、共有 URL（新 token）を発行する。

        非公開へ戻してから再公開すると、前回とは別 token の新しい URL になる。
        """
        if not self.enabled:
            raise ValueError("preview が無効")
        with self._lock:
            artifact_id, versions = self._load_registry(job_id)
            idx = self._index_of(versions, version)
            record, _ = self._normalize(artifact_id, versions[idx])
            versions[idx] = record
            if record.get("visibility") == VISIBILITY_PUBLIC:
                raise ValueError(f"バージョン {version} は既に公開している")
            share_token = secrets.token_hex(16)
            record["visibility"] = VISIBILITY_PUBLIC
            record["share_token"] = share_token
            record["preview_url"] = f"{self._base}/{share_token}/"
            versions[idx] = record
            self._save_registry(job_id, artifact_id, versions)
            self._set_publication(share_token, job_id, version, record, active=True)
            # 公開状態を日誌に残すのは呼び出し側（HTTP）の責務。
            return self._view(artifact_id, self._normalize(artifact_id, record)[0])

    def unpublish_version(self, job_id: str, version: int) -> dict[str, Any]:
        """バージョンを非公開に戻す。発行済みの共有 URL（全 token）を無効化する。"""
        if not self.enabled:
            raise ValueError("preview が無効")
        with self._lock:
            artifact_id, versions = self._load_registry(job_id)
            idx = self._index_of(versions, version)
            record, _ = self._normalize(artifact_id, versions[idx])
            versions[idx] = record
            old_token = record.get("share_token")
            record["visibility"] = VISIBILITY_PRIVATE
            record["share_token"] = None
            record["preview_url"] = None
            versions[idx] = record
            self._save_registry(job_id, artifact_id, versions)
            if isinstance(old_token, str) and old_token:
                self._set_publication(old_token, job_id, version, record, active=False)
            return self._view(artifact_id, self._normalize(artifact_id, record)[0])

    def content_token_for(self, job_id: str, version: int) -> str:
        """認証付きプレビュー用。バージョンの内容フォルダ token を返す。"""
        with self._lock:
            artifact_id, versions = self._load_registry(job_id)
            idx = self._index_of(versions, version)
            record, _ = self._normalize(artifact_id, versions[idx])
            token = record.get("token")
            if not isinstance(token, str) or not token:
                raise LookupError(f"unknown version: {version}")
            return token

    def restore(self, job: Job, version: int) -> int:
        """旧バージョンの作業ファイルを output/artifact/ へ復元する。

        「この版から修正」の土台。実行中（RUNNING）の仕事に対しては呼ばないこと
        （呼び出し側・HTTP が弾く）。復元したファイルは次の実行がそのまま使う。
        """
        if not self.enabled:
            raise ValueError("preview が無効")
        with self._lock:
            artifact_id, versions = self._load_registry(job.id)
            record = next((item for item in versions if item.get("version") == version), None)
            if record is None:
                raise LookupError(f"unknown version: {version}")
            source, _ = self._normalize(artifact_id, record)
            token = source.get("token")
            if not token:
                raise LookupError(f"unknown version: {version}")
            src_root = self._previews_root / token
            if src_root.is_symlink() or not src_root.is_dir():
                raise LookupError(f"unknown version: {version}")
            files = self._collect(src_root)
            if not any(parts[-1].lower() == "index.html" for parts in files):
                raise LookupError(f"unknown version: {version}")

        dest_root = job.directory / OUTPUT_DIRNAME / ARTIFACT_DIRNAME
        if dest_root.is_symlink():
            raise ValueError("output/artifact の symlink を拒否")
        self._clear_dir(dest_root)
        dest_root.mkdir(parents=True, exist_ok=True)
        for parts in files:
            self._copy_file(src_root, parts, dest_root)
        return len(files)

    def migrate(self) -> int:
        """旧形式（公開状態なし・共有 token なし）を公開状態として移行する。

        起動時と呼ぶ。preview_url の token を内容フォルダとして保ち、そのまま
        公開済み URL として動き続けるように publications 表へも登録する。
        """
        migrated = 0
        if not self._registry_root.is_dir():
            return 0
        for path in sorted(self._registry_root.glob("*.json")):
            if path.name == PUBLICATIONS_FILENAME:
                continue
            if path.is_symlink():
                continue
            job_id = path.stem
            try:
                artifact_id, versions = self._load_registry(job_id)
            except ValueError:
                continue
            normalized: list[dict[str, Any]] = []
            changed = False
            for item in versions:
                record, record_changed = self._normalize(artifact_id, item)
                normalized.append(record)
                changed = changed or record_changed
            with self._lock:
                if changed:
                    self._save_registry(job_id, artifact_id, normalized)
                    migrated += 1
                # 公開中の共有 token を publications 表へ確実に載せる。
                self._sync_publications(job_id, artifact_id, normalized)
        return migrated

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

    @staticmethod
    def _clear_dir(directory: Path) -> None:
        """中身を空にする（symlink は辿らず、リンク自体を消す）。"""
        if not directory.exists():
            return
        for child in directory.iterdir():
            if child.is_symlink():
                child.unlink()
            elif child.is_dir():
                for sub in sorted(child.rglob("*"), reverse=True):
                    if sub.is_symlink():
                        sub.unlink()
                    elif sub.is_dir():
                        sub.rmdir()
                    else:
                        sub.unlink()
                child.rmdir()
            else:
                child.unlink()

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

    def _record(
        self,
        *,
        artifact_id: str,
        job_id: str,
        session_id: str | None,
        version: int,
        token: str,
        visibility: str,
        share_token: str | None,
        sha: str,
        source_ids: list[str],
    ) -> dict[str, Any]:
        return {
            "id": _version_id(artifact_id, version),
            "job_id": job_id,
            "session_id": session_id,
            "version": version,
            "kind": "web",
            "token": token,
            "visibility": visibility,
            "share_token": share_token,
            "preview_url": f"{self._base}/{share_token}/" if share_token else None,
            "view_url": _view_url(job_id, version),
            "expires_at": None,
            "sha256": sha,
            "source_ids": source_ids,
        }

    def _normalize(self, artifact_id: str, item: dict[str, Any]) -> tuple[dict[str, Any], bool]:
        """旧レコード（公開状態なし）を現行形へ正規化する。``changed`` は永続化必要か。"""
        record = dict(item)
        changed = False
        version = record.get("version")
        if not isinstance(version, int) or version < 1:
            version = 1
            record["version"] = version
            changed = True
        record["id"] = _version_id(artifact_id, version)

        token = record.get("token")
        if not isinstance(token, str) or not token:
            token = _token_from_preview_url(str(record.get("preview_url") or ""))
            if not token:
                token = secrets.token_hex(16)
            record["token"] = token
            changed = True
        view_url = record.get("view_url")
        if not isinstance(view_url, str) or not view_url.startswith("/jobs/"):
            record["view_url"] = _view_url(_record_job_id(record, artifact_id), version)
            changed = True
        visibility = record.get("visibility")
        if visibility not in (VISIBILITY_PRIVATE, VISIBILITY_PUBLIC):
            # 旧レコードは公開済み URL として動いていた。公開状態として移行する。
            record["visibility"] = VISIBILITY_PUBLIC
            changed = True
        if record["visibility"] == VISIBILITY_PUBLIC:
            share_token = record.get("share_token")
            if not isinstance(share_token, str) or not share_token:
                record["share_token"] = token
                changed = True
            preview_url = record.get("preview_url")
            if not isinstance(preview_url, str) or not preview_url.strip():
                record["preview_url"] = f"{self._base}/{token}/"
                changed = True
        else:
            if record.get("share_token") is not None:
                record["share_token"] = None
                changed = True
            if record.get("preview_url") is not None:
                record["preview_url"] = None
                changed = True
        return record, changed

    def _view(self, artifact_id: str, record: dict[str, Any]) -> dict[str, Any]:
        """HTTP へ出す形。内容フォルダと共有 token は出さない。"""
        version = record.get("version") if isinstance(record.get("version"), int) else 1
        view_job_id = str(record.get("job_id") or artifact_id)
        return {
            "id": _version_id(artifact_id, version),
            "job_id": record.get("job_id"),
            "session_id": record.get("session_id"),
            "version": version,
            "kind": record.get("kind") or "web",
            "preview_url": record.get("preview_url"),
            "visibility": record.get("visibility") or VISIBILITY_PUBLIC,
            "view_url": record.get("view_url") or _view_url(view_job_id, version),
            "expires_at": record.get("expires_at"),
            "sha256": record.get("sha256"),
            "source_ids": list(record.get("source_ids") or []),
        }

    @staticmethod
    def _index_of(versions: list[dict[str, Any]], version: int) -> int:
        if not isinstance(version, int) or version < 1:
            raise LookupError(f"unknown version: {version}")
        for idx, item in enumerate(versions):
            if item.get("version") == version:
                return idx
        raise LookupError(f"unknown version: {version}")

    def _source_ids(self, job: Job) -> list[str]:
        inp = job.directory / INPUT_DIRNAME
        if not inp.is_dir():
            return []
        return sorted(p.name for p in inp.iterdir() if p.is_file() and p.name != REQUEST_FILENAME)

    def _registry_path(self, job_id: str) -> Path:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", job_id or ""):
            raise ValueError(f"preview registry の job id が不正: {job_id!r}")
        path = self._registry_root / f"{job_id}.json"
        if path.is_symlink():
            raise ValueError(f"preview registry の symlink を拒否: {job_id}")
        return path

    def _publications_path(self) -> Path:
        path = self._registry_root / PUBLICATIONS_FILENAME
        if path.is_symlink():
            raise ValueError("publications の symlink を拒否")
        return path

    def _load_registry(self, job_id: str) -> tuple[str, list[dict[str, Any]]]:
        try:
            path = self._registry_path(job_id)
        except ValueError as error:
            raise LookupError(f"unknown job: {job_id}") from error
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
        payload = (
            json.dumps(
                {"artifact_id": artifact_id, "schema": 2, "versions": versions},
                ensure_ascii=False,
                indent=2,
            )
            + "\n"
        )
        # atomic: 同じ dir の tmp + os.replace。manifest の半端書きを残さない。
        fd, tmp_name = tempfile.mkstemp(
            dir=str(self._registry_root), prefix=".registry.", suffix=".tmp"
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
            os.replace(tmp_name, self._registry_path(job_id))
        finally:
            try:
                if os.path.exists(tmp_name):
                    os.unlink(tmp_name)
            except OSError:
                pass

    def _sync_publications(
        self, job_id: str, artifact_id: str, versions: list[dict[str, Any]]
    ) -> None:
        """その仕事の公開中 token を publications 表へ載せる。"""
        pending: list[tuple[str, str, int, str]] = []
        for item in versions:
            record, _ = self._normalize(artifact_id, item)
            if record.get("visibility") == VISIBILITY_PUBLIC:
                share_token = record.get("share_token")
                token = record.get("token")
                version = record.get("version")
                if (
                    isinstance(share_token, str)
                    and share_token
                    and isinstance(token, str)
                    and token
                    and isinstance(version, int)
                ):
                    pending.append((share_token, job_id, version, token))
        self._set_publications(job_id, pending)

    def _set_publication(
        self, share_token: str, job_id: str, version: int, record: dict[str, Any], *, active: bool
    ) -> None:
        publications = self._load_publications()
        entry = {
            "job_id": job_id,
            "version": version,
            "content_token": str(record.get("token") or ""),
        }
        if active:
            publications[share_token] = entry
        else:
            publications.pop(share_token, None)
        self._save_publications(publications)

    def _load_publications(self) -> dict[str, Any]:
        path = self._publications_path()
        if path.is_file():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                pubs = data.get("publications")
                if isinstance(pubs, dict):
                    return dict(pubs)
            except (ValueError, OSError):
                pass
        return {}

    def _save_publications(self, publications: dict[str, Any]) -> None:
        self._registry_root.mkdir(parents=True, exist_ok=True)
        payload = json.dumps({"publications": publications}, ensure_ascii=False, indent=2) + "\n"
        fd, tmp_name = tempfile.mkstemp(
            dir=str(self._registry_root), prefix=".publications.", suffix=".tmp"
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
            os.replace(tmp_name, self._publications_path())
        finally:
            try:
                if os.path.exists(tmp_name):
                    os.unlink(tmp_name)
            except OSError:
                pass

    def _set_publications(self, job_id: str, entries: list[tuple[str, str, int, str]]) -> None:
        publications = self._load_publications()
        # この仕事の対応だけを引き直す（止めた token を残さない）。
        for token, entry in list(publications.items()):
            if isinstance(entry, dict) and entry.get("job_id") == job_id:
                publications.pop(token, None)
        for share_token, _job_id, version, content_token in entries:
            publications[share_token] = {
                "job_id": _job_id,
                "version": version,
                "content_token": content_token,
            }
        self._save_publications(publications)


def _record_job_id(record: dict[str, Any], artifact_id: str) -> str:
    job_id = record.get("job_id")
    return str(job_id) if isinstance(job_id, str) and job_id else artifact_id
