"""ツール進捗の整形。本家 display が無くてもフォールバックする。"""

from mihari_room.worker.progress import format_tool_progress


def test_started_line_contains_tool_name() -> None:
    line = format_tool_progress("tool.started", "read_file", "memo.txt", {"path": "input/memo.txt"})
    assert line is not None
    assert "read_file" in line or "Reading" in line
    assert "memo.txt" in line


def test_thinking_is_hidden() -> None:
    assert format_tool_progress("tool.started", "_thinking", "pondering") is None
    assert format_tool_progress("_thinking", "scratch") is None


def test_clarify_is_hidden() -> None:
    line = format_tool_progress(
        "tool.started",
        "clarify",
        "which one?",
        {"question": "which?"},
    )
    assert line is None


def test_completed_is_silent() -> None:
    assert format_tool_progress("tool.completed", "read_file") is None


def test_failed_subagent_is_reported() -> None:
    line = format_tool_progress(
        "subagent.complete",
        preview="調べる",
        status="failed",
        goal="調べる",
    )
    assert line is not None
    assert "止まった" in line
