"""``device_bridge.commands.iphone_state_source`` のうち、実機を必要としない部分を検証する。

SpringBoard の syslog 購読(``_ForegroundTracker``)と installation_proxy の問い合わせ自体は
実機が無いと動かないため対象外とし、ここでは表示名のキャッシュ判断だけを見る。
ログ行の解釈は純粋関数なので ``test_iphone_state.py`` 側にある。
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest

from device_bridge.commands import iphone_state_source

BUNDLE_ID = "com.apple.Preferences"


@pytest.fixture
def looked_up(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """``_lookup_display_name`` を差し替え、問い合わせた bundle ID を記録する。"""
    seen: list[str] = []

    async def fake_lookup(lockdown: Any, bundle_id: str, start_lock: asyncio.Lock) -> str | None:
        seen.append(bundle_id)
        return "設定" if bundle_id == BUNDLE_ID else None

    monkeypatch.setattr(iphone_state_source, "_lookup_display_name", fake_lookup)
    return seen


async def test_resolve_app_name_asks_the_device_once_per_bundle_id(looked_up: list[str]) -> None:
    cache: dict[str, str | None] = {}
    lock = asyncio.Lock()

    first = await iphone_state_source._resolve_app_name(None, BUNDLE_ID, cache, lock)
    second = await iphone_state_source._resolve_app_name(None, BUNDLE_ID, cache, lock)

    assert (first, second) == ("設定", "設定")
    assert looked_up == [BUNDLE_ID]


async def test_resolve_app_name_remembers_that_it_could_not_be_looked_up(
    looked_up: list[str],
) -> None:
    # 引けなかったことも憶える。引けないアプリに毎回問い合わせても同じ結果しか返らない。
    cache: dict[str, str | None] = {}
    lock = asyncio.Lock()

    assert (
        await iphone_state_source._resolve_app_name(None, "com.example.gone", cache, lock) is None
    )
    assert (
        await iphone_state_source._resolve_app_name(None, "com.example.gone", cache, lock) is None
    )

    assert looked_up == ["com.example.gone"]
    assert cache == {"com.example.gone": None}


async def test_resolve_app_name_does_not_ask_on_the_home_or_lock_screen(
    looked_up: list[str],
) -> None:
    cache: dict[str, str | None] = {}

    assert await iphone_state_source._resolve_app_name(None, None, cache, asyncio.Lock()) is None

    assert looked_up == []
    assert cache == {}
