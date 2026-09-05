"""添付・URL の安全な取得。SSRF 対策つき。

- 添付は Discord CDN のホストだけ。それ以外は取りに行かない。
- ホスト検証・DNS 検証（private / loopback / link-local を踏まない）・
  リダイレクト毎の再検証・サイズ上限・タイムアウトを全部通す。
- URL メタは公開 HTTP(S) だけ。HTML の title / description を stdlib で抽出する。
- テストでは ``httpx.MockTransport`` のクライアントと偽 resolver を渡す。
"""

from __future__ import annotations

import asyncio
import ipaddress
import logging
import re
import socket
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit

import httpx

logger = logging.getLogger("mihari_room.archive.fetch")

#: 添付ダウンロードを許す Discord CDN のホスト。
DISCORD_CDN_HOSTS = frozenset({"cdn.discordapp.com", "media.discordapp.net"})
_DISCORD_SUFFIXES = (".discordapp.com",)

#: 手で追うリダイレクトのステータス。
_REDIRECT_STATUSES = {301, 302, 303, 307, 308}

#: URL 抽出の正規表現。<> や引用符は弾く。
_URL_PATTERN = re.compile(r"https?://[^\s<>\"]+")
#: URL 末尾に残りがちな句読点。
_TRAILING_PUNCTUATION = ".,!?;:、。！？）)」』\"'"
#: 索引から落とすトラッキング用クエリ。
_TRACKING_PARAMS = frozenset(
    {
        "utm_source",
        "utm_medium",
        "utm_campaign",
        "utm_term",
        "utm_content",
        "fbclid",
        "gclid",
        "mc_cid",
        "mc_eid",
    }
)

#: HTML 本文から FTS に載せる文字数上限。
_MAX_HTML_TEXT_CHARS = 4000
#: 説明に使う文字数上限。
_MAX_DESCRIPTION_CHARS = 280

Resolver = Callable[[str], Awaitable[Sequence[str]]]


class FetchError(RuntimeError):
    """安全に取得できなかった。理由を message に持つ。"""


@dataclass(frozen=True, slots=True)
class FetchResult:
    """取得の成功結果。body は max_bytes 以内に切り詰め済み。"""

    final_url: str
    status_code: int
    content_type: str
    body: bytes
    hops: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class UrlMetadata:
    """URL メタ取得の結果。失敗しても status に理由を入れて返す。"""

    fetch_status: str
    title: str | None = None
    description: str | None = None
    error: str | None = None


def is_discord_cdn_url(url: str) -> bool:
    """添付として許すホストか。テスト・検証用に公開している。"""
    parsed = urlsplit(url)
    if parsed.scheme != "https":
        return False
    host = (parsed.hostname or "").lower()
    return host in DISCORD_CDN_HOSTS or any(host.endswith(s) for s in _DISCORD_SUFFIXES)


def extract_urls(content: str) -> list[str]:
    """本文から http(s) URL を抜いて、末尾の句読点を落とす。"""
    found: list[str] = []
    for match in _URL_PATTERN.finditer(content):
        candidate = match.group(0).rstrip(_TRAILING_PUNCTUATION)
        # 閉じ括弧が余っているなら、対応する開き括弧まで戻す。
        while candidate.endswith(")") and candidate.count("(") < candidate.count(")"):
            candidate = candidate[:-1]
        if candidate:
            found.append(candidate)
    return found


def normalize_url(url: str) -> str:
    """索引用の正規化。www を落とし、トラッキングは削る。非 HTTP(S) は ValueError。"""
    parsed = urlsplit(url)
    scheme = parsed.scheme.lower()
    if scheme not in {"http", "https"}:
        raise ValueError("unsupported scheme")
    host = (parsed.hostname or "").lower()
    if not host:
        raise ValueError("missing host")
    if host.startswith("www."):
        host = host[4:]
    filtered = [
        (key, value)
        for key, value in parse_qsl(parsed.query, keep_blank_values=True)
        if key.lower() not in _TRACKING_PARAMS
    ]
    query = urlencode(filtered) if filtered else ""
    return urlunsplit((scheme, host, parsed.path.rstrip("/") or "/", query, ""))


async def _default_resolve(host: str) -> list[str]:
    """A/AAAA を引いて IP の文字列リストを返す。失敗は空。"""
    try:
        infos = await asyncio.to_thread(socket.getaddrinfo, host, None, type=socket.SOCK_STREAM)
    except socket.gaierror:
        return []
    addresses: list[str] = []
    for family, _, _, _, sockaddr in infos:
        if family in (socket.AF_INET, socket.AF_INET6) and sockaddr:
            addresses.append(str(sockaddr[0]))
    return addresses


def _is_private_ip(raw: str) -> bool:
    """private / loopback / link-local / 予約 / マルチキャスト / 未定義は全部弾く。"""
    try:
        address = ipaddress.ip_address(raw)
    except ValueError:
        # IP として解釈できないものは踏まない。
        return True
    return bool(
        address.is_private
        or address.is_loopback
        or address.is_link_local
        or address.is_reserved
        or address.is_multicast
        or address.is_unspecified
    )


class SafeFetcher:
    """検証付きの HTTP クライアント。``aclose()`` で閉じる。"""

    def __init__(
        self,
        *,
        client: httpx.AsyncClient | None = None,
        resolver: Resolver | None = None,
        max_redirects: int = 5,
        user_agent: str = "mihari-room-archive/0.1",
    ) -> None:
        self._client = client or httpx.AsyncClient(
            follow_redirects=False, timeout=httpx.Timeout(30.0)
        )
        self._owns_client = client is None
        self._resolver = resolver or _default_resolve
        self._max_redirects = max_redirects
        self._user_agent = user_agent

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    async def download_attachment(self, url: str, *, max_bytes: int, timeout: float) -> FetchResult:
        """Discord CDN の添付だけ取得する。それ以外のホストは FetchError。"""
        if not is_discord_cdn_url(url):
            raise FetchError(f"添付 URL が Discord CDN ではない: {url}")
        return await self._get(url, max_bytes=max_bytes, timeout=timeout, require_cdn=True)

    async def fetch_url_metadata(self, url: str, *, max_bytes: int, timeout: float) -> UrlMetadata:
        """公開 HTTP(S) のメタを取得する。失敗してもエラー付きで返す。"""
        parsed = urlsplit(url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            return UrlMetadata(fetch_status="skipped", error="unsupported scheme")
        if parsed.username or parsed.password:
            return UrlMetadata(fetch_status="skipped", error="credential in url")
        try:
            result = await self._get(url, max_bytes=max_bytes, timeout=timeout)
        except FetchError as exc:
            return UrlMetadata(fetch_status="error", error=str(exc))
        return _parse_url_metadata(result)

    async def _get(
        self, url: str, *, max_bytes: int, timeout: float, require_cdn: bool = False
    ) -> FetchResult:
        """全体を timeout で縛る。リダイレクトは手で追い、毎ホップ検証する。"""
        try:
            return await asyncio.wait_for(
                self._get_unbounded(url, max_bytes=max_bytes, require_cdn=require_cdn),
                timeout=timeout,
            )
        except TimeoutError as exc:
            raise FetchError(f"タイムアウト: {url}") from exc

    async def _get_unbounded(
        self, url: str, *, max_bytes: int, require_cdn: bool = False
    ) -> FetchResult:
        current = url
        hops: list[str] = []
        for _ in range(self._max_redirects + 1):
            if require_cdn and not is_discord_cdn_url(current):
                raise FetchError(f"添付のリダイレクト先が CDN 外: {current}")
            validated = await self._validate(current)
            # 送信直前に再解決し、私的 IP と総入れ替え（リバインド疑い）を弾く。
            # 完全な TOCTOU 除去には検証済み IP への固定接続 + Host/SNI 保持が
            # 必要だが、既定 httpx では再解決ホストを独立に引くため、ここでは
            # 二重検証 + CDN 固定 + 既定無効で事故面を絞る。
            await self._recheck_connection(current, validated)
            hops.append(current)
            request = self._client.build_request(
                "GET",
                current,
                headers={"User-Agent": self._user_agent, "Accept": "*/*"},
            )
            try:
                response = await self._client.send(request, stream=True)
            except httpx.HTTPError as exc:
                raise FetchError(f"取得失敗: {exc}") from exc

            if response.status_code in _REDIRECT_STATUSES:
                location = response.headers.get("location")
                await response.aclose()
                if not location:
                    raise FetchError(f"リダイレクト先が無い: {current}")
                current = urljoin(current, location)
                continue
            if response.status_code >= 400:
                await response.aclose()
                raise FetchError(f"HTTP {response.status_code}")

            declared = response.headers.get("content-length")
            if declared:
                try:
                    if int(declared) > max_bytes:
                        await response.aclose()
                        raise FetchError("サイズ上限超過")
                except ValueError:
                    pass
            chunks: list[bytes] = []
            total = 0
            try:
                async for chunk in response.aiter_bytes():
                    total += len(chunk)
                    if total > max_bytes:
                        raise FetchError("サイズ上限超過")
                    chunks.append(chunk)
            finally:
                await response.aclose()
            return FetchResult(
                final_url=str(response.url),
                status_code=response.status_code,
                content_type=response.headers.get("content-type") or "",
                body=b"".join(chunks),
                hops=tuple(hops),
            )
        raise FetchError("リダイレクトが多すぎる")

    async def _validate(self, url: str) -> list[str]:
        """スキーム・ホスト・DNS 解決先を検証する。検証済み IP 一覧を返す。"""
        parsed = urlsplit(url)
        if parsed.scheme not in {"http", "https"}:
            raise FetchError(f"スキーム不許可: {parsed.scheme}")
        host = parsed.hostname
        if not host:
            raise FetchError("ホストが無い")
        if parsed.username or parsed.password:
            raise FetchError("URL に秘密情報が含まれる")
        addresses = list(await self._resolver(host))
        if not addresses:
            raise FetchError(f"名前解決できなかった: {host}")
        if any(_is_private_ip(raw) for raw in addresses):
            raise FetchError(f"プライベート IP を踏まない: {host} {addresses}")
        return addresses

    async def _recheck_connection(self, url: str, validated: Sequence[str]) -> None:
        """送信直前の再解決。私的 IP・総入れ替えはリバインド疑いで弾く。"""
        host = urlsplit(url).hostname or ""
        try:
            fresh = list(await self._resolver(host))
        except Exception as exc:
            raise FetchError(f"再解決に失敗: {host}") from exc
        if not fresh:
            raise FetchError(f"名前解決できなかった: {host}")
        if any(_is_private_ip(raw) for raw in fresh):
            raise FetchError(f"プライベート IP を踏まない: {host} {fresh}")
        if not set(fresh) & set(validated):
            raise FetchError(f"DNS リバインド疑い: {host} {validated} -> {fresh}")


def _parse_url_metadata(result: FetchResult) -> UrlMetadata:
    """HTML なら title / description、テキストなら先頭を説明にする。"""
    body = result.body
    ctype = result.content_type.split(";")[0].strip().lower()
    head = body[:512].lstrip().lower()
    is_html = ctype in {"text/html", "application/xhtml+xml"} or head.startswith(
        (b"<!doctype html", b"<html")
    )
    if is_html:
        title, description, _text = _extract_html_meta(body.decode("utf-8", errors="replace"))
        return UrlMetadata(fetch_status="ok", title=title, description=description)
    if ctype.startswith("text/") or ctype in {
        "application/json",
        "application/xml",
        "text/xml",
    }:
        text = _collapse_whitespace(body.decode("utf-8", errors="replace"))
        description = text[:_MAX_DESCRIPTION_CHARS] or None
        return UrlMetadata(fetch_status="ok", title=None, description=description)
    return UrlMetadata(fetch_status="ok")


class _MetaParser(HTMLParser):
    """title と meta description と本文テキストだけ拾う軽いパーサ。"""

    _IGNORED_TAGS = frozenset({"script", "style", "noscript", "iframe", "svg", "canvas"})
    _META_NAMES = frozenset(
        {"og:title", "twitter:title", "description", "og:description", "twitter:description"}
    )

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title_parts: list[str] = []
        self.meta: dict[str, str] = {}
        self.text_parts: list[str] = []
        self._skip_depth = 0
        self._in_title = 0
        self._text_len = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in self._IGNORED_TAGS:
            self._skip_depth += 1
        if tag == "title":
            self._in_title += 1
        if tag == "meta":
            attr_map = {key.lower(): (value or "") for key, value in attrs}
            name = (attr_map.get("property") or attr_map.get("name") or "").lower()
            content = attr_map.get("content")
            if name in self._META_NAMES and content:
                self.meta.setdefault(name, content.strip())

    def handle_endtag(self, tag: str) -> None:
        if tag in self._IGNORED_TAGS and self._skip_depth > 0:
            self._skip_depth -= 1
        if tag == "title" and self._in_title > 0:
            self._in_title -= 1

    def handle_data(self, data: str) -> None:
        if self._skip_depth:
            return
        if self._in_title:
            self.title_parts.append(data)
            return
        if self._text_len >= _MAX_HTML_TEXT_CHARS:
            return
        text = _collapse_whitespace(data)
        if not text:
            return
        room = _MAX_HTML_TEXT_CHARS - self._text_len
        if len(text) > room:
            text = text[:room]
        self.text_parts.append(text)
        self._text_len += len(text)


def _extract_html_meta(html: str) -> tuple[str | None, str | None, str]:
    parser = _MetaParser()
    try:
        parser.feed(html)
        parser.close()
    except Exception:
        # 壊れた HTML でも title までは諦めない。空のまま返す。
        logger.info("HTML メタ抽出が途中で止まった", exc_info=True)
    title = _collapse_whitespace(" ".join(parser.title_parts)) or None
    description = (
        parser.meta.get("og:description")
        or parser.meta.get("description")
        or parser.meta.get("twitter:description")
    )
    if description:
        description = _collapse_whitespace(description)[:_MAX_DESCRIPTION_CHARS]
    text = _collapse_whitespace(" ".join(parser.text_parts))
    return title, description, text


def _collapse_whitespace(text: str | None) -> str:
    if not text:
        return ""
    return re.sub(r"\s+", " ", text).strip()
