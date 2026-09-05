"""安全な取得（SafeFetcher）とパス生成のテスト。実ネットワークは使わない。"""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest

from mihari_room.archive.config import ALLOWED_ATTACHMENT_EXTENSIONS, allowed_attachment
from mihari_room.archive.fetch import (
    FetchError,
    SafeFetcher,
    extract_urls,
    is_discord_cdn_url,
    normalize_url,
)
from mihari_room.archive.pathutil import ensure_contained, sanitize_filename

from .archive_helpers import PUBLIC_IP, make_client


@pytest.fixture
def calls() -> dict[str, int]:
    return {}


async def _fetcher(*, resolver=None, responses=None, max_redirects=3, calls=None):
    client = make_client(responses=responses, calls=calls)

    async def public_resolver(host: str) -> list[str]:
        return [PUBLIC_IP]

    return SafeFetcher(
        client=client, resolver=resolver or public_resolver, max_redirects=max_redirects
    )


# ---------- ホスト検証 ----------


async def test_attachment_requires_discord_cdn(calls) -> None:
    fetcher = await _fetcher(calls=calls)
    with pytest.raises(FetchError):
        await fetcher.download_attachment(
            "http://evil.example/attachments/x.png", max_bytes=1000, timeout=2
        )
    with pytest.raises(FetchError):
        await fetcher.download_attachment("https://example.com/x.png", max_bytes=1000, timeout=2)
    assert calls == {}  # 1 回も送っていない


async def test_attachment_allows_only_https_cdn(calls) -> None:
    fetcher = await _fetcher(calls=calls)
    with pytest.raises(FetchError):
        await fetcher.download_attachment(
            "http://cdn.discordapp.com/attachments/1/2/a.png", max_bytes=1000, timeout=2
        )
    assert is_discord_cdn_url("https://cdn.discordapp.com/attachments/1/2/a.png")
    assert is_discord_cdn_url("https://media.discordapp.net/attachments/1/2/a.png")
    assert not is_discord_cdn_url("https://discord.com/channels/1/2/3")
    assert calls == {}


# ---------- SSRF（DNS・リダイレクト・URL 検証） ----------


async def test_ssrf_private_ip_resolution_blocked(calls) -> None:
    async def private_resolver(host: str) -> list[str]:
        return ["127.0.0.1"]

    fetcher = await _fetcher(resolver=private_resolver, calls=calls)
    meta = await fetcher.fetch_url_metadata("https://example.com/secret", max_bytes=1000, timeout=2)
    assert meta.fetch_status == "error"
    assert "プライベート IP" in (meta.error or "")
    assert calls == {}  # 送信前に弾いた


async def test_ssrf_direct_private_ip_host(calls) -> None:
    import ipaddress

    async def ip_aware_resolver(host: str) -> list[str]:
        try:
            ipaddress.ip_address(host)
            return [host]
        except ValueError:
            return [PUBLIC_IP]

    fetcher = await _fetcher(resolver=ip_aware_resolver, calls=calls)
    meta = await fetcher.fetch_url_metadata("http://127.0.0.1/admin", max_bytes=1000, timeout=2)
    assert meta.fetch_status == "error"
    meta = await fetcher.fetch_url_metadata("https://[::1]/x", max_bytes=1000, timeout=2)
    assert meta.fetch_status == "error"
    assert calls == {}


async def test_ssrf_link_local_and_reserved(calls) -> None:
    async def link_local_resolver(host: str) -> list[str]:
        return ["169.254.169.254"]

    fetcher = await _fetcher(resolver=link_local_resolver, calls=calls)
    meta = await fetcher.fetch_url_metadata("https://metadata.example/", max_bytes=1000, timeout=2)
    assert meta.fetch_status == "error"
    assert calls == {}


async def test_ssrf_link_local_and_reserved_download(calls) -> None:
    async def private_resolver(host: str) -> list[str]:
        return ["10.0.0.5"]

    fetcher = await _fetcher(resolver=private_resolver, calls=calls)
    with pytest.raises(FetchError):
        await fetcher.download_attachment(
            "https://cdn.discordapp.com/attachments/1/2/a.png",
            max_bytes=1000,
            timeout=2,
        )
    assert calls == {}


async def test_ssrf_redirect_to_private_host_blocked(calls) -> None:
    responses = {
        "safe.example": httpx.Response(302, headers={"location": "http://127.0.0.1/steal"}),
    }

    async def map_resolver(host: str) -> list[str]:
        if host == "safe.example":
            return [PUBLIC_IP]
        return [host]  # 127.0.0.1 は自分自身を返す

    fetcher = await _fetcher(
        responses=responses, resolver=map_resolver, max_redirects=3, calls=calls
    )
    meta = await fetcher.fetch_url_metadata("https://safe.example/start", max_bytes=1000, timeout=2)
    assert meta.fetch_status == "error"
    # 1 回目のリクエストは行くが、2 回目（プライベート先）は飛ばない。
    assert list(calls.keys()) == ["safe.example/start"]


async def test_redirect_chain_resolves_if_public(calls) -> None:
    responses = {
        "a.example": httpx.Response(302, headers={"location": "https://b.example/final"}),
        "b.example": httpx.Response(
            200,
            content="<html><head><title>着地</title></head></html>".encode(),
            headers={"content-type": "text/html"},
        ),
    }
    fetcher = await _fetcher(responses=responses, calls=calls)
    meta = await fetcher.fetch_url_metadata("https://a.example/start", max_bytes=1000, timeout=2)
    assert meta.fetch_status == "ok"
    assert meta.title == "着地"


async def test_redirect_loop_rejected(calls) -> None:
    loop = httpx.Response(302, headers={"location": "https://loop.example/again"})
    fetcher = await _fetcher(responses={"loop.example": loop}, max_redirects=2, calls=calls)
    meta = await fetcher.fetch_url_metadata("https://loop.example/again", max_bytes=1000, timeout=2)
    assert meta.fetch_status == "error"
    assert "多すぎる" in (meta.error or "")


async def test_url_with_credentials_rejected(calls) -> None:
    fetcher = await _fetcher(calls=calls)
    meta = await fetcher.fetch_url_metadata(
        "https://user:pass@example.com/x", max_bytes=100, timeout=2
    )
    assert meta.fetch_status == "skipped"
    assert calls == {}


async def test_non_http_scheme_skipped(calls) -> None:
    fetcher = await _fetcher(calls=calls)
    meta = await fetcher.fetch_url_metadata("ftp://example.com/x", max_bytes=100, timeout=2)
    assert meta.fetch_status == "skipped"
    assert calls == {}


async def test_error_status_is_reported_not_raised(calls) -> None:
    fetcher = await _fetcher(
        responses={"gone.example": httpx.Response(410, content=b"")}, calls=calls
    )
    meta = await fetcher.fetch_url_metadata("https://gone.example/x", max_bytes=100, timeout=2)
    assert meta.fetch_status == "error"
    assert meta.error is not None


# ---------- サイズ上限 ----------


async def test_oversize_body_rejected(calls) -> None:
    fetcher = await _fetcher(
        responses={"big.example": httpx.Response(200, content=b"x" * 5000)}, calls=calls
    )
    meta = await fetcher.fetch_url_metadata("https://big.example/x", max_bytes=100, timeout=2)
    assert meta.fetch_status == "error"
    assert "サイズ上限" in (meta.error or "")


async def test_oversize_content_length_rejected_without_body_read(calls) -> None:
    fetcher = await _fetcher(
        responses={
            "declared.example": httpx.Response(
                200, content=b"", headers={"content-length": "999999999"}
            )
        },
        calls=calls,
    )
    meta = await fetcher.fetch_url_metadata("https://declared.example/x", max_bytes=100, timeout=2)
    assert meta.fetch_status == "error"
    assert "サイズ上限" in (meta.error or "")


# ---------- MIME / 拡張子 ----------


def test_extension_allowlist() -> None:
    assert ".pdf" in ALLOWED_ATTACHMENT_EXTENSIONS
    assert ".exe" not in ALLOWED_ATTACHMENT_EXTENSIONS
    assert allowed_attachment("application/pdf", "a.pdf")
    assert allowed_attachment("image/png", "a.png")
    assert allowed_attachment("text/plain", "a.txt")
    assert not allowed_attachment("application/x-msdownload", "a.exe")
    assert not allowed_attachment("application/pdf", "a.exe")
    assert not allowed_attachment("text/html", "a.sh")
    # Discord は octet-stream を返すことが多い。拡張子が通っていれば許す。
    assert allowed_attachment("application/octet-stream", "a.png")


# ---------- パス生成と containment ----------


def test_sanitize_filename_removes_paths() -> None:
    assert sanitize_filename("../../etc/passwd") == "passwd"
    assert sanitize_filename("/abs/path/file.pdf") == "file.pdf"
    assert sanitize_filename("..") == "attachment"
    assert sanitize_filename("") == "attachment"
    assert sanitize_filename("正常な名前.txt") == "txt"  # 非 ASCII は落ちる
    assert sanitize_filename("a b.txt") == "a_b.txt"


def test_ensure_contained_rejects_outside(tmp_path: Path) -> None:
    root = tmp_path / "root"
    root.mkdir()
    inside = root / "a" / "b.txt"
    inside.parent.mkdir()
    inside.write_text("x")
    outside = tmp_path / "outside.txt"
    outside.write_text("secret")

    assert ensure_contained(inside, root) == inside.resolve()

    with pytest.raises(ValueError):
        ensure_contained(outside, root)
    with pytest.raises(ValueError):
        ensure_contained(root, root)


def test_ensure_contained_follows_symlink(tmp_path: Path) -> None:
    root = tmp_path / "root"
    root.mkdir()
    secret = tmp_path / "secret.txt"
    secret.write_text("secret")
    link = root / "escape"
    link.symlink_to(secret)

    with pytest.raises(ValueError):
        ensure_contained(link, root)


# ---------- URL 抽出・正規化 ----------


def test_extract_urls_trims_punctuation() -> None:
    found = extract_urls("見て: https://example.com/a.html。 あと https://example.com/b.md だよ")
    assert found == ["https://example.com/a.html", "https://example.com/b.md"]


def test_extract_urls_balances_parens() -> None:
    found = extract_urls("リンク (https://example.com/b.md) だよ")
    assert found == ["https://example.com/b.md"]


def test_normalize_url_strips_tracking() -> None:
    assert (
        normalize_url("https://www.example.com/path/?utm_source=x&id=5")
        == "https://example.com/path?id=5"
    )
    with pytest.raises(ValueError):
        normalize_url("ftp://example.com/x")
