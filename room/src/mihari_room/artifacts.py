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
    ".md",
    ".markdown",
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

#: 文書（Markdown・PDF）として成果物一覧に載せる拡張子。
DOCUMENT_EXTS = frozenset({".md", ".markdown", ".pdf"})
#: Markdown のプレビュー HTML の接尾辞。``report.md`` → ``report.md.html``。
_MD_PREVIEW_SUFFIX = ".html"


def _doc_kind(name: str) -> str:
    """文書ファイルの種別（markdown / pdf）。"""
    if name.lower().endswith((".md", ".markdown")):
        return "markdown"
    return "pdf"


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
        """成功した仕事の成果物を 1 バージョン公開する。無効なら None。

        - HTML モックは従来どおり ``output/artifact/`` の index.html を起点に写す
        - Markdown / PDF の文書は ``output/`` 配下（research/ を除く）から写す。
          Markdown はプレビュー用 HTML（マークダウン表示）を同梱する
        - index.html が無くても文書だけあれば公開する（文書のみの版）
        """
        if not self.enabled:
            return None
        artifact = self._artifact_dir(job)
        web_files: list[list[str]] = []
        if (artifact / "index.html").is_file():
            web_files = [
                parts
                for parts in self._collect(artifact)
                if not parts[-1].lower().endswith(tuple(DOCUMENT_EXTS))
            ]
        output_dir = job.directory / OUTPUT_DIRNAME
        doc_files = self._collect_documents(output_dir)
        if not any(parts[-1].lower() == "index.html" for parts in web_files) and not doc_files:
            return None

        token = secrets.token_hex(16)
        dest_root = self._previews_root / token
        for parts in web_files:
            self._copy_file(artifact, parts, dest_root)
        for parts in doc_files:
            self._copy_document(output_dir, parts, dest_root)
        rendered_docs = self._render_markdown_previews(output_dir, doc_files, dest_root)
        related_images = self._markdown_related_images(output_dir, doc_files, dest_root)
        published = web_files + doc_files + rendered_docs + related_images
        if not any(parts[-1].lower() == "index.html" for parts in web_files):
            self._write_docs_index(doc_files, dest_root)
            published = published + [["index.html"]]
        sha = self._digest(dest_root, published)

        artifact_id, versions = self._load_registry(job.id)
        version = len(versions) + 1
        manifest = self._manifest(
            artifact_id=artifact_id,
            job_id=job.id,
            session_id=session_id,
            version=version,
            token=token,
            sha=sha,
            source_ids=self._source_ids(job),
        )
        manifest["documents"] = self._documents_manifest(token, doc_files)
        versions.append(manifest)
        self._save_registry(job.id, artifact_id, versions)
        return manifest

    def manifests_for(self, job_id: str) -> list[dict[str, Any]]:
        """仕事ごとの公開済みマニフェスト（バージョン順）。id は version ごとに一意。"""
        artifact_id, versions = self._load_registry(job_id)
        return [self._with_unique_id(artifact_id, item) for item in versions]

    def rollback(self, job: Job, version: int, session_id: str | None = None) -> dict[str, Any]:
        """旧バージョンのファイルを新しい token として再公開する。過去 token は残す。"""
        if not self.enabled:
            raise ValueError("preview が無効")
        if not isinstance(version, int) or version < 1:
            raise LookupError(f"unknown version: {version}")
        artifact_id, versions = self._load_registry(job.id)
        source = next((item for item in versions if item.get("version") == version), None)
        if source is None:
            raise LookupError(f"unknown version: {version}")
        token = _token_from_preview_url(str(source.get("preview_url") or ""))
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
        doc_files = [parts for parts in files if self._is_document(parts[-1])]
        manifest = self._manifest(
            artifact_id=artifact_id,
            job_id=job.id,
            session_id=session_id,
            version=new_version,
            token=new_token,
            sha=sha,
            source_ids=list(source.get("source_ids") or []),
        )
        manifest["documents"] = self._documents_manifest(new_token, doc_files)
        versions.append(manifest)
        self._save_registry(job.id, artifact_id, versions)
        return manifest

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

    def _collect_documents(self, output: Path) -> list[list[str]]:
        """``output/`` 配下の文書（Markdown / PDF）の相対パス一覧。

        ``research/``（調べもの・生データ）と秘密名・隠し・symlink は弾く。
        ``artifact/`` 内の文書も含める（同じくプレビュー・ダウンロード対象）。
        """
        if not output.is_dir():
            return []
        files: list[list[str]] = []
        for dirpath, dirnames, filenames in os.walk(output):
            dirnames[:] = [
                d
                for d in dirnames
                if d not in (".", "..", "research")
                and not d.startswith(".")
                and not _is_secret_name(d)
                and not os.path.islink(os.path.join(dirpath, d))
            ]
            rel_dir = Path(dirpath).relative_to(output)
            for name in filenames:
                full = Path(dirpath) / name
                if os.path.islink(full):
                    continue
                if name.startswith(".") or _is_secret_name(name):
                    continue
                if any(_is_secret_name(p) for p in rel_dir.parts):
                    continue
                if full.suffix.lower() not in DOCUMENT_EXTS:
                    continue
                files.append([*rel_dir.parts, name])
        return files

    @staticmethod
    def _is_document(name: str) -> bool:
        return Path(name).suffix.lower() in DOCUMENT_EXTS

    def _copy_document(self, output: Path, parts: list[str], dest_root: Path) -> None:
        """文書ファイル（Markdown / PDF）を版ディレクトリへ写す。"""
        if not self._is_document(parts[-1]):
            raise ValueError(f"文書ではない: {parts[-1]}")
        self._copy_file(output, parts, dest_root)

    def _render_markdown_previews(
        self, output: Path, doc_files: list[list[str]], dest_root: Path
    ) -> list[list[str]]:
        """Markdown 文書のプレビュー HTML（同梱 markdown-it 表示）を作る。

        ``report.md`` に ``report.md.html`` を隣に置く。生 HTML は無効・CDN なし。
        """
        from mihari_room.documents.markdown_render import render_to_page

        rendered: list[list[str]] = []
        for parts in doc_files:
            name = parts[-1]
            if not name.lower().endswith((".md", ".markdown")):
                continue
            source = output.joinpath(*parts)
            if source.is_symlink() or not source.is_file():
                raise ValueError(f"文書の実体が不正: {parts!r}")
            try:
                text = source.read_text(encoding="utf-8")
            except UnicodeDecodeError as exc:
                raise ValueError(f"Markdown を UTF-8 で読めない: {parts!r}") from exc
            page = render_to_page(text, title=name)
            preview_parts = [*parts[:-1], f"{name}.html"]
            self._write_bytes(preview_parts, page.encode("utf-8"), dest_root)
            rendered.append(preview_parts)
        return rendered

    def _markdown_related_images(
        self, output: Path, doc_files: list[list[str]], dest_root: Path
    ) -> list[list[str]]:
        """Markdown が相対参照する画像を同じ版に写す（関連画像にも公開制御を適用）。

        ``output/`` 直下（artifact/ を除く）の文書が ``![図](fig.png)`` のように
        参照するファイルを、文書と同じ相対位置に写してプレビューを成立させる。
        research/・秘密名・隠し・symlink は弾く。
        """
        import re

        image_re = re.compile(r"!\[[^\]]*\]\(([^)\s]+)")
        copied: dict[tuple[str, ...], list[str]] = {}
        for parts in doc_files:
            source = output.joinpath(*parts)
            if source.is_symlink() or not source.is_file():
                continue
            if len(parts) > 0 and parts[0] == ARTIFACT_DIRNAME:
                continue  # artifact/ 内の画像は web collect が写す
            try:
                text = source.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            md_parent = output.joinpath(*parts[:-1]) if len(parts) > 1 else output
            for ref in image_re.findall(text):
                if not ref or ref.startswith(("http://", "https://", "data:", "/")):
                    continue
                rel_image = Path(ref)
                if rel_image.is_absolute():
                    continue
                if any(part in ("", ".", "..") for part in rel_image.parts):
                    continue
                try:
                    image_parts = list(
                        (md_parent / rel_image).resolve().relative_to(output.resolve()).parts
                    )
                except ValueError:
                    continue
                if not image_parts or image_parts[0] == "research":
                    continue
                if any(_is_secret_name(p) or p.startswith(".") for p in image_parts):
                    continue
                key = tuple(image_parts)
                if key in copied:
                    continue
                image_path = output.joinpath(*image_parts)
                if image_path.is_symlink() or not image_path.is_file():
                    continue
                self._copy_file(output, image_parts, dest_root)
                copied[key] = image_parts
        return list(copied.values())

    def _write_docs_index(self, doc_files: list[list[str]], dest_root: Path) -> None:
        """文書だけの版向けの一覧ページ。相対リンクのみ・script なし。"""
        rows: list[str] = []
        for parts in sorted(doc_files):
            rel = "/".join(parts)
            href = f"./{rel}"
            name_esc = rel.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            if parts[-1].lower().endswith((".md", ".markdown")):
                preview_href = href + ".html"
                rows.append(
                    f'<li><a href="{preview_href}">プレビュー</a> · '
                    f'<a href="{href}" download>ダウンロード</a> — {name_esc}</li>'
                )
            else:
                rows.append(f'<li><a href="{href}" download>ダウンロード</a> — {name_esc}</li>')
        rows_text = "\n".join(rows)
        body = (
            '<!doctype html>\n<html lang="ja">\n<head>\n'
            '<meta charset="utf-8">\n<title>成果物</title>\n'
            "<style>body{font-family:-apple-system,'Hiragino Sans',sans-serif;"
            "line-height:1.7;margin:2em auto;max-width:40em;padding:0 1em}"
            "a{color:#065fb8}</style>\n</head>\n<body>\n"
            f"<h1>成果物</h1>\n<ul>\n{rows_text}\n</ul>\n</body>\n</html>\n"
        )
        self._write_bytes(["index.html"], body.encode("utf-8"), dest_root)

    def _write_bytes(self, parts: list[str], content: bytes, dest_root: Path) -> None:
        """検証（トラバーサル・隠し・symlink）を通る書き込み。"""
        if any(part in ("", ".", "..") for part in parts):
            raise ValueError(f"preview の経路が不正: {parts!r}")
        if any(part.startswith(".") for part in parts):
            raise ValueError(f"preview の隠し経路は出さない: {parts!r}")
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
        resolved.write_bytes(content)

    def _documents_manifest(self, token: str, doc_files: list[list[str]]) -> list[dict[str, Any]]:
        """版の ``documents`` 一覧。プレビュー・ダウンロードは同じ preview 権限に乗せる。"""
        documents: list[dict[str, Any]] = []
        for parts in sorted(doc_files):
            rel = "/".join(parts)
            name = parts[-1]
            kind = _doc_kind(name)
            if kind == "markdown":
                preview_rel = f"{rel}.html"
            else:
                preview_rel = rel
            documents.append(
                {
                    "name": rel,
                    "kind": kind,
                    "preview_url": f"{self._base}/{token}/{preview_rel}",
                    "download_url": f"{self._base}/{token}/{rel}",
                }
            )
        return documents

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

    def _manifest(
        self,
        *,
        artifact_id: str,
        job_id: str,
        session_id: str | None,
        version: int,
        token: str,
        sha: str,
        source_ids: list[str],
    ) -> dict[str, Any]:
        return {
            "id": _version_id(artifact_id, version),
            "job_id": job_id,
            "session_id": session_id,
            "version": version,
            "kind": "web",
            "preview_url": f"{self._base}/{token}/",
            "expires_at": None,
            "sha256": sha,
            "source_ids": source_ids,
        }

    def _with_unique_id(self, artifact_id: str, item: dict[str, Any]) -> dict[str, Any]:
        """古い registry（全 version が同じ id）も HTTP では一意にする。"""
        out = dict(item)
        version = out.get("version")
        if isinstance(version, int) and version >= 1:
            out["id"] = _version_id(artifact_id, version)
        # 文書一覧が無い古い版は空で返す（desktop の表示は壊さない）。
        out.setdefault("documents", [])
        return out

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
