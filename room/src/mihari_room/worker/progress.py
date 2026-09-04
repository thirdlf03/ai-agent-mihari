"""ツール進捗を人間向け 1 行にする。

整形の考え方は Hermes Agent（MIT, Copyright (c) 2025 Nous Research）の
``gateway/run_turn_runner.py`` / ``agent/display.py`` と同じ。本家が import
できるときはそちらの動詞・絵文字を使い、できないときは短いフォールバック。
"""

from __future__ import annotations

from typing import Any

#: 1 行プレビューの上限。本家 Discord 既定の tool_preview_length に合わせる。
_PREVIEW_CAP = 40


def format_tool_progress(
    event_type: str,
    tool_name: str | None = None,
    preview: str | None = None,
    args: dict[str, Any] | None = None,
    **kwargs: Any,
) -> str | None:
    """Gateway と同じく、chat に出すのは主に ``tool.started``。"""
    if event_type == "subagent.complete":
        status = kwargs.get("status")
        if status in {"failed", "error", "cancelled", "timeout"}:
            goal = kwargs.get("goal") or preview or ""
            return f"⚠️ 委任が止まった: {status}" + (f" — {goal}" if goal else "")
        return None
    if event_type != "tool.started" or not tool_name or tool_name == "_thinking":
        return None
    if tool_name == "clarify":
        return None
    return _format_started(tool_name, preview, args)


def _format_started(tool_name: str, preview: str | None, args: dict[str, Any] | None) -> str:
    try:
        from agent.display import (
            get_tool_emoji,
            get_tool_verb,
            prepare_tool_preview,
            tool_verb_connector,
            verb_drops_preview,
        )
    except ImportError:
        return _fallback_line(tool_name, preview)

    emoji = get_tool_emoji(tool_name, default="⚙️")
    verb = get_tool_verb(tool_name)
    prepared = prepare_tool_preview(
        tool_name, args, fallback=preview or "", max_len=_PREVIEW_CAP
    )
    text = prepared.text if prepared.text else (preview or "")
    if not verb:
        return f'{emoji} {tool_name}: "{text}"' if text else f"{emoji} {tool_name}..."
    if verb_drops_preview(tool_name) or not text:
        return f"{emoji} {verb}"
    return f"{emoji} {verb}{tool_verb_connector(tool_name)}{text}"


def _fallback_line(tool_name: str, preview: str | None) -> str:
    if preview:
        clipped = preview if len(preview) <= _PREVIEW_CAP else preview[: _PREVIEW_CAP - 3] + "..."
        return f'⚙️ {tool_name}: "{clipped}"'
    return f"⚙️ {tool_name}..."
