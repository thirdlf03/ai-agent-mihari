"""アーカイブテストの共有ヘルパー。実ネットワークは一切使わない。

- discord.Message 風の偽装物を作る
- httpx.MockTransport で添付・URL の応答を固定する
- 偽 resolver で DNS 検証を通す（実 DNS を引かない）
"""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

import httpx

#: テストで「公開」とみなす IP。実 DNS は引かない。
PUBLIC_IP = "93.184.216.34"


def fake_attachment(
    attachment_id: int,
    filename: str = "report.pdf",
    size: int = 100,
    content_type: str = "application/pdf",
    url: str | None = None,
) -> SimpleNamespace:
    if url is None:
        url = f"https://cdn.discordapp.com/attachments/1/2/{attachment_id}-{filename}"
    return SimpleNamespace(
        id=attachment_id,
        filename=filename,
        size=size,
        content_type=content_type,
        url=url,
    )


def fake_channel(channel_id: int, name: str = "main", parent: Any = None) -> SimpleNamespace:
    return SimpleNamespace(id=channel_id, name=name, parent=parent)


def fake_thread(thread_id: int, parent: SimpleNamespace, name: str = "スレ") -> SimpleNamespace:
    return SimpleNamespace(id=thread_id, name=name, parent=parent)


def fake_message(
    message_id: int,
    content: str,
    *,
    channel: Any | None = None,
    channel_id: int = 111,
    guild_id: int = 777,
    author_id: int = 42,
    author_name: str = "たろー",
    bot: bool = False,
    attachments: tuple[Any, ...] = (),
    created_at: str = "2024-01-02T03:04:05+00:00",
    edited_at: str | None = None,
    jump_url: str | None = None,
) -> SimpleNamespace:
    if channel is None:
        channel = fake_channel(channel_id)
    if jump_url is None:
        jump_url = f"https://discord.com/channels/{guild_id}/{channel.id}/{message_id}"
    return SimpleNamespace(
        id=message_id,
        content=content,
        created_at=created_at,
        edited_at=edited_at,
        jump_url=jump_url,
        guild=SimpleNamespace(id=guild_id),
        author=SimpleNamespace(id=author_id, name="taro", bot=bot, display_name=author_name),
        channel=channel,
        attachments=attachments,
    )


def fake_payload(message_id: int, data: dict[str, Any]) -> SimpleNamespace:
    """RawMessageUpdateEvent / RawMessageDeleteEvent 風。"""
    return SimpleNamespace(message_id=message_id, data=data)


def make_transport(
    *, responses: dict[str, httpx.Response] | None = None, calls: dict[str, int] | None = None
):
    """ホスト名で応答を切り替える MockTransport を作る。呼び出し回数も数える。"""

    def handler(request: httpx.Request) -> httpx.Response:
        if calls is not None:
            key = request.url.host + request.url.path
            calls[key] = calls.get(key, 0) + 1
        if responses is not None:
            for host in sorted(responses, key=len, reverse=True):
                if request.url.host.endswith(host):
                    return responses[host]
        return httpx.Response(404)

    return httpx.MockTransport(handler)


def make_client(
    responses: dict[str, Any] | None = None, calls: dict[str, int] | None = None
) -> httpx.AsyncClient:
    """テスト用 AsyncClient。応答辞書は host -> Response or bytes。"""
    if responses is None:
        responses = {}
    return httpx.AsyncClient(
        transport=make_transport(responses=responses, calls=calls),
        follow_redirects=False,
        timeout=httpx.Timeout(5.0),
    )


async def fake_resolver(host: str) -> list[str]:
    """全部「公開 IP」として返す。SSRF テストでは専用の resolver を使う。"""
    return [PUBLIC_IP]


def pdf_bytes(text: str = "Mihari PDF report body") -> bytes:
    """pypdf が読める本物の PDF を組み立てる。外部ファイル不要。

    Type1 Helvetica の文字列は ASCII で書くこと（日本語はフォントが無い）。
    """
    import io

    from pypdf import PdfWriter
    from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject

    writer = PdfWriter()
    page = writer.add_blank_page(width=612, height=792)
    fonts = DictionaryObject()
    font = DictionaryObject(
        {
            NameObject("/Type"): NameObject("/Font"),
            NameObject("/Subtype"): NameObject("/Type1"),
            NameObject("/BaseFont"): NameObject("/Helvetica"),
        }
    )
    fonts[NameObject("/F1")] = font
    page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): fonts})
    stream = DecodedStreamObject()
    stream.set_data(f"BT /F1 12 Tf 72 720 Td ({text}) Tj ET".encode("latin-1"))
    page[NameObject("/Contents")] = writer._add_object(stream)
    buffer = io.BytesIO()
    writer.write(buffer)
    return buffer.getvalue()
