import shlex
import sys
import time
import unicodedata

import pytest

from conftest import ROOT
from test_panes import PaneTerminal


pytestmark = pytest.mark.usefixtures("mouse_mode")


def selected_text(terminal):
    lines = []
    for row in range(terminal.screen.lines):
        cells = [terminal.screen.buffer[row][column] for column in range(terminal.screen.columns)]
        if any(cell.reverse for cell in cells):
            lines.append("".join(cell.data for cell in cells if cell.reverse).rstrip())
    return "\n".join(lines)


def selected(terminal, text):
    terminal.wait(lambda: selected_text(terminal) == unicodedata.normalize("NFC", text))


def finish_selection(terminal):
    terminal.child.sendline("printf '\\nSELECTION_FINISHED\\n'")
    terminal.wait(lambda: any(row[1:49].strip() == "SELECTION_FINISHED" for row in terminal.screen.display))
    assert "\x1b]52;" not in terminal.capture.getvalue()


def select(terminal, start, end, modifiers=0, release=True):
    terminal.child.send(f"\x1b[<{modifiers};{start[0]};{start[1]}M\x1b[<{32 + modifiers};{end[0]};{end[1]}M")
    if release:
        terminal.child.send(f"\x1b[<{modifiers};{end[0]};{end[1]}m")


def text_terminal(sessions, text="alpha 中文 beta\nsecond line"):
    terminal = PaneTerminal(sessions)
    sessions.command(terminal.child, "printf '\\033[2J\\033[H%s\\n' " + shlex.quote(text))
    terminal.split()
    terminal.visible("2: shell")
    return terminal


@pytest.mark.parametrize("start,end,expected", [
    ((2, 2), (7, 2), "alpha"),
    ((7, 2), (2, 2), "alpha"),
    ((9, 2), (12, 2), "中文"),
    ((2, 2), (8, 3), "alpha 中文 beta\nsecond"),
    ((2, 2), (80, 2), "alpha 中文 beta"),
])
def test_drag_selects_pane_text_and_preserves_clipboard(sessions, start, end, expected):
    terminal = text_terminal(sessions)
    select(terminal, start, end)
    selected(terminal, expected)
    terminal.focused(1)
    assert any(cell.reverse for row in terminal.screen.buffer.values() for cell in row.values())
    terminal.command("printf ready", "selection-input", "ready")
    terminal.wait(lambda: not any(cell.reverse for row in terminal.screen.buffer.values() for cell in row.values()))
    finish_selection(terminal)


@pytest.mark.parametrize("release_column,expected", [(7, "alpha"), (12, "alpha 中文")])
def test_selection_remains_highlighted_after_release(sessions, release_column, expected):
    terminal = text_terminal(sessions)
    select(terminal, (2, 2), (7, 2), release=False)
    terminal.wait(lambda: all(terminal.screen.buffer[1][column].reverse for column in range(1, 6)))
    assert "\x1b]52;c;" not in terminal.capture.getvalue()
    terminal.child.send(f"\x1b[<0;{release_column};2m")
    selected(terminal, expected)
    finish_selection(terminal)


def test_double_and_triple_click_select_word_and_line(sessions):
    terminal = text_terminal(sessions)
    terminal.click(3, 2)
    terminal.click(3, 2)
    selected(terminal, "alpha")
    terminal.click(3, 2)
    selected(terminal, "alpha 中文 beta")
    finish_selection(terminal)


def test_selection_spans_soft_wrapped_lines(sessions):
    text = "0123456789" * 7
    terminal = text_terminal(sessions, text)
    select(terminal, (2, 2), (24, 3))
    selected(terminal, text[:48] + "\n" + text[48:])
    finish_selection(terminal)


def test_selection_preserves_combining_characters(sessions):
    text = "e\u0301lan"
    terminal = text_terminal(sessions, text)
    offset = len(terminal.capture.getvalue())
    select(terminal, (2, 2), (6, 2))
    selected(terminal, text)
    assert text in terminal.capture.getvalue()[offset:]
    finish_selection(terminal)


def test_drag_selection_scrolls_history_and_stops_on_release(sessions):
    text = "\n".join(f"history-{number:03}" for number in range(100))
    terminal = text_terminal(sessions, text)
    before = terminal.screen.display[1][:50]
    select(terminal, (3, 4), (3, 1), release=False)
    terminal.wait(lambda: terminal.screen.display[1][:50] != before)
    terminal.child.send("\x1b[<0;3;1m")
    time.sleep(0.1)
    terminal.pump()
    stopped = terminal.screen.display[1][:50]
    time.sleep(0.15)
    terminal.pump()
    assert terminal.screen.display[1][:50] == stopped
    finish_selection(terminal)


def test_shift_drag_selects_text_in_mouse_application(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    destination = sessions.path / "selection-app.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), "legacy"]))
    terminal.wait(destination.exists)
    terminal.visible("PANE_APPLICATION")
    select(terminal, (52, 2), (68, 2), modifiers=4)
    selected(terminal, "PANE_APPLICATION")
    assert destination.read_bytes() == b""
    terminal.child.send("\x1b[57441;2:3u")
    terminal.pump()
    assert terminal.screen.buffer[1][51].reverse
    terminal.click(55, 3)
    terminal.wait(lambda: destination.read_bytes() == b"\x1b[<0;4;2M\x1b[<0;4;2m")
    assert "\x1b]52;" not in terminal.capture.getvalue()


@pytest.mark.parametrize("action", ["resize", "split", "close"])
def test_layout_changes_cancel_selection_and_preserve_clipboard(sessions, action):
    terminal = text_terminal(sessions)
    select(terminal, (2, 2), (7, 2), release=False)
    terminal.wait(lambda: terminal.screen.buffer[1][1].reverse)
    offset = len(terminal.capture.getvalue())
    if action == "resize":
        terminal.screen.resize(lines=30, columns=120)
        terminal.child.setwinsize(30, 120)
        terminal.wait(lambda: " 2: " in terminal.screen.display[0][60:])
    elif action == "split":
        terminal.split("down")
        terminal.visible("3: shell")
    else:
        terminal.child.send("\x1bw")
        terminal.wait(lambda: all(" 1: " not in row for row in terminal.screen.display))
    terminal.child.send("\x1b[<32;10;2M\x1b[<0;10;2m")
    terminal.command("printf ready", "after-selection-cancel", "ready")
    assert "\x1b]52;c;" not in terminal.capture.getvalue()[offset:]
