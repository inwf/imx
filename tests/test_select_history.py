import shlex
import sys
import time

import pyte
import pytest

from preview_client import PreviewClient
from conftest import ROOT
from test_pane_resize import drag, origin
from test_panes import PaneTerminal
from test_select import cancel, selector, shown


pytestmark = pytest.mark.usefixtures("mouse_mode")


def history(sessions, name="alpha"):
    writer = sessions.spawn(name, rows=30, cols=100)
    sessions.command(writer, "printf '\\033[3J\\033[2J\\033[H'; printf 'HISTORY-%03d\\n' {1..200}")
    return writer


def wheel(terminal, delta, col=5, row=8):
    terminal.child.send(f"\x1b[<{64 if delta < 0 else 65};{col};{row}M" * abs(delta))


def preview_rows(terminal):
    return [row.strip() for row in terminal.screen.display if "HISTORY-" in row]


def settle(terminal):
    deadline = time.monotonic() + 0.35
    while time.monotonic() < deadline:
        terminal.pump()


def test_preview_scroll_holds_history_and_returns_to_live(sessions):
    writer = history(sessions)
    terminal = selector(sessions)
    terminal.visible("HISTORY-200")
    settle(terminal)
    wheel(terminal, -12)
    terminal.visible("HISTORY-160")
    original = preview_rows(terminal)
    assert not shown(terminal, "HISTORY-200")
    sessions.command(writer, "printf 'NEW-%03d\\n' {1..50}")
    settle(terminal)
    assert preview_rows(terminal) == original
    assert shown(terminal, "> alpha")
    assert sessions.sessions()[0]["CLIENTS"] == "1"
    assert "28 98" in sessions.command(writer, "stty size")
    wheel(terminal, 100)
    terminal.visible("NEW-050")
    sessions.command(writer, "printf '\\033[2J\\033[HFOLLOW_TOP\\n'")
    terminal.visible("FOLLOW_TOP")
    cancel(terminal)


def test_preview_history_survives_resize_and_list_changes(sessions):
    writer = history(sessions)
    terminal = selector(sessions)
    terminal.visible("HISTORY-200")
    wheel(terminal, -12)
    terminal.visible("HISTORY-160")
    first = preview_rows(terminal)[0].strip("│ ")
    for rows, cols in ((20, 75), (2, 12), (30, 100)):
        terminal.child.setwinsize(rows, cols)
        terminal.screen.resize(rows, cols)
        if rows > 2:
            terminal.visible(first)
            settle(terminal)
            assert preview_rows(terminal)[0].strip("│ ") == first
        else:
            terminal.wait(lambda: terminal.screen.display[-1].startswith("Click/Wheel"))
    beta = sessions.spawn("beta")
    sessions.command(beta, "printf '\\033[2J\\033[HBETA_LIVE\\n'")
    terminal.visible("  beta")
    settle(terminal)
    assert preview_rows(terminal)[0].strip("│ ") == first
    wheel(terminal, 1, row=2)
    terminal.visible("> beta")
    terminal.visible("BETA_LIVE")
    terminal.child.send("k")
    terminal.visible("HISTORY-200")
    assert "28 98" in sessions.command(writer, "stty size")
    cancel(terminal)


def test_preview_history_is_independent_between_connections(sessions):
    writer = history(sessions)
    with PreviewClient(sessions, "alpha", 12, 70) as first, PreviewClient(sessions, "alpha", 12, 70) as second:
        first.frame()
        screen = pyte.Screen(70, 12)
        stream = pyte.Stream(screen)
        stream.feed(second.frame().decode())
        first.scroll(-40)
        initial = first.frame().decode()
        assert "HISTORY-160" in initial
        sessions.command(writer, "printf 'OTHER_LIVE\\n'")
        stream.feed(second.frame().decode())
        assert any("OTHER_LIVE" in row for row in screen.display)
        assert first.frame() == b""
        first.scroll(2**31 - 1)
        assert "OTHER_LIVE" in first.frame().decode()
    assert sessions.sessions()[0]["CLIENTS"] == "1"


def test_preview_history_retains_colors_unicode_and_hyperlinks(sessions):
    writer = sessions.spawn("alpha", rows=30, cols=100)
    sessions.command(writer, "printf '\\033[3J\\033[2J\\033[H\\033[31m\\033]8;;https://example.com/history\\007中文历史 e\\314\\201\\033]8;;\\007\\033[0m\\n'; printf 'ROW-%03d\\n' {1..200}")
    with PreviewClient(sessions, "alpha", 12, 70) as preview:
        preview.frame()
        preview.scroll(-(2**31))
        output = preview.frame().decode()
        assert "https://example.com/history" in output
        assert "中文历史 e\u0301" in output
        screen = pyte.Screen(70, 12)
        pyte.Stream(screen).feed(output)
        assert screen.buffer[0][0].fg == "cd0000"


def test_preview_history_survives_pruning_and_screen_switches(sessions):
    writer = history(sessions)
    with PreviewClient(sessions, "alpha", 12, 70) as preview:
        preview.frame()
        preview.scroll(-100)
        initial = preview.frame().decode()
        assert "HISTORY-100" in initial
        sessions.command(writer, "printf '\\033[?1049h\\033[2J\\033[HALTERNATE_VIEW\\n'")
        assert preview.frame() == b""
        preview.scroll(2**31 - 1)
        assert "ALTERNATE_VIEW" in preview.frame().decode()
        sessions.command(writer, "printf '\\033[?1049l'; printf 'RECENT-%05d\\n' {1..12000}")
        preview.frame()
        preview.scroll(-(2**31))
        oldest = preview.frame().decode()
        assert "HISTORY-" not in oldest
        assert "RECENT-" in oldest
        sessions.command(writer, "printf 'NEWER-%05d\\n' {1..12000}")
        assert "NEWER-" in preview.frame().decode()
        preview.scroll(2**31 - 1)
        assert "NEWER-12000" in preview.frame().decode()


def test_preview_history_inside_current_session(sessions):
    writer = history(sessions)
    writer.sendline("imx select")
    terminal = PaneTerminal(sessions, child=writer)
    terminal.visible("HISTORY-200")
    wheel(terminal, -12)
    terminal.visible("HISTORY-160")
    wheel(terminal, 100)
    terminal.visible("HISTORY-200")
    writer.send("q")
    writer.expect_prompt("IMX_PROMPT> ")
    assert "28 98" in sessions.command(writer, "stty size")


def test_preview_history_inside_resized_split_pane(sessions):
    writer = history(sessions, "target")
    terminal = PaneTerminal(sessions, name="workspace")
    terminal.split()
    terminal.visible("1: shell")
    terminal.child.sendline("imx select")
    terminal.visible("HISTORY-200")
    wheel(terminal, -12, col=60, row=10)
    terminal.visible("HISTORY-160")
    first = preview_rows(terminal)[0].split("│")[-2].strip()
    drag(terminal, (50, 8), (60, 8))
    terminal.wait(lambda: origin(terminal, 1) == (60, 0))
    terminal.visible(first)
    wheel(terminal, 100, col=70, row=10)
    terminal.visible("HISTORY-200")
    terminal.child.send("q")
    terminal.wait(lambda: not shown(terminal, "Click/Wheel"))
    terminal.command("printf done", "preview-finished", "done")
    assert "28 98" in sessions.command(writer, "stty size")


def test_preview_scrolling_preserves_large_frame_delivery(sessions):
    writer = sessions.spawn("alpha", rows=160, cols=320)
    sessions.command(writer, shlex.join([sys.executable, str(ROOT / "tests/select_output.py"), "--colors"]))
    with PreviewClient(sessions, "alpha", 150, 318) as preview:
        preview.request_frame()
        preview.scroll(-3)
        original = preview.receive_frame().decode()
        assert len(original) > 256 * 1024
        assert "COLOR_GRID" in original
        screen = pyte.Screen(318, 150)
        stream = pyte.Stream(screen)
        stream.feed(original)
        assert screen.buffer[100][200].fg == "c8642c"
        preview.frame()
        preview.scroll(2**31 - 1)
        stream.feed(preview.frame().decode())
        assert "COLOR_GRID" in screen.display[0]
        assert screen.buffer[100][200].fg == "c8642c"


def test_preview_history_session_exit_selects_live_session(sessions):
    history(sessions)
    beta = sessions.spawn("beta")
    sessions.command(beta, "printf '\\033[2J\\033[HBETA_LIVE\\n'")
    terminal = selector(sessions)
    terminal.visible("HISTORY-200")
    wheel(terminal, -12)
    terminal.visible("HISTORY-160")
    sessions.run("kill", "alpha")
    terminal.visible("> beta")
    terminal.visible("BETA_LIVE")
    cancel(terminal)


def test_preview_wheel_direction_changes_respect_history_boundaries(sessions):
    history(sessions)
    terminal = selector(sessions)
    terminal.visible("HISTORY-200")
    terminal.child.send("\x1b[<64;5;8M" * 100 + "\x1b[<65;5;8M" * 5)
    terminal.wait(lambda: "HISTORY-016" in preview_rows(terminal)[0])
    assert not shown(terminal, "HISTORY-001")
    cancel(terminal)
