import json
import shlex
import sys

import pytest

from conftest import ROOT
from test_panes import PaneTerminal


pytestmark = pytest.mark.usefixtures("mouse_mode")


def origin(terminal, number):
    for line, row in enumerate(terminal.screen.display):
        column = row.find(f" {number}: ")
        if column >= 0:
            return column - 2, line
    return None


def drag(terminal, start, end, release=True):
    terminal.child.send(f"\x1b[<0;{start[0]};{start[1]}M\x1b[<32;{end[0]};{end[1]}M")
    if release:
        terminal.child.send(f"\x1b[<0;{end[0]};{end[1]}m")


@pytest.mark.parametrize("direction", ["right", "down"])
@pytest.mark.parametrize("edge", [0, 1])
def test_drag_resizes_live_and_preserves_proportions(sessions, direction, edge):
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.visible("2: shell")
    horizontal = direction == "right"
    start = (50 + edge, 8) if horizontal else (25, 15 + edge)
    end = (65 + edge, 8) if horizontal else (25, 20 + edge)
    drag(terminal, start, end, release=False)
    terminal.wait(lambda: origin(terminal, 2) == ((65, 0) if horizontal else (0, 20)))
    terminal.focused(2)
    terminal.command("stty size", "live-size", "28 33\n" if horizontal else "8 98\n")
    terminal.child.send(f"\x1b[<0;{end[0]};{end[1]}m")
    terminal.focus(1)
    terminal.command("stty size", "first-size", "28 63\n" if horizontal else "18 98\n")
    terminal.focus(2)

    terminal.screen.resize(lines=6, columns=15)
    terminal.child.setwinsize(6, 15)
    terminal.command("stty size", "minimum-size", "4 10\n" if horizontal else "3 13\n")
    terminal.screen.resize(lines=60, columns=200)
    terminal.child.setwinsize(60, 200)
    terminal.wait(lambda: origin(terminal, 2) == ((130, 0) if horizontal else (0, 40)))
    terminal.command("stty size", "expanded-size", "58 68\n" if horizontal else "18 198\n")
    terminal.focus(1)
    terminal.command("stty size", "expanded-first-size", "58 128\n" if horizontal else "38 198\n")


@pytest.mark.parametrize("direction", ["right", "down"])
def test_drag_clamps_to_nested_pane_minimums(sessions, direction):
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.visible("2: shell")
    terminal.split(direction)
    terminal.visible("3: shell")
    horizontal = direction == "right"
    start = (50, 8) if horizontal else (25, 15)
    end = (100, 8) if horizontal else (25, 30)
    drag(terminal, start, end)
    terminal.wait(lambda: origin(terminal, 2) == ((76, 0) if horizontal else (0, 20)))
    terminal.command("stty size", "third-minimum", "28 10\n" if horizontal else "3 98\n")
    terminal.focus(2)
    terminal.command("stty size", "second-minimum", "28 10\n" if horizontal else "3 98\n")

    start = (76, 8) if horizontal else (25, 20)
    end = (1, 8) if horizontal else (25, 1)
    drag(terminal, start, end)
    terminal.wait(lambda: origin(terminal, 2) == ((12, 0) if horizontal else (0, 5)))
    terminal.command("stty size", "second-expanded", "28 42\n" if horizontal else "10 98\n")
    terminal.focus(3)
    terminal.command("stty size", "third-expanded", "28 42\n" if horizontal else "11 98\n")
    terminal.focus(1)
    terminal.command("stty size", "first-minimum", "28 10\n" if horizontal else "3 98\n")


def test_drag_nested_separator_and_intersection(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.split("down")
    terminal.visible("3: shell")
    terminal.focus(1)
    terminal.split("down")
    terminal.visible("4: shell")

    drag(terminal, (50, 15), (65, 20))
    terminal.wait(lambda: origin(terminal, 3) == (65, 15))
    assert origin(terminal, 4) == (0, 15)
    drag(terminal, (80, 16), (80, 21))
    terminal.wait(lambda: origin(terminal, 3) == (65, 20))
    assert origin(terminal, 4) == (0, 15)
    terminal.focused(4)
    terminal.command("stty size", "unchanged-left", "13 63\n")
    terminal.focus(3)
    terminal.command("stty size", "nested-bottom", "8 33\n")
    terminal.focus(2)
    terminal.command("stty size", "nested-top", "18 33\n")


def test_drag_uses_final_release_position_and_preserves_click_size(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.send("\x1b[<0;50;8M\x1b[<0;61;8m")
    terminal.wait(lambda: origin(terminal, 2) == (61, 0))
    terminal.click(62, 8)
    terminal.command("stty size", "clicked-size", "28 37\n")
    terminal.focused(2)


def test_drag_with_scrolled_small_terminal(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.split("down")
    terminal.visible("3: shell")
    terminal.screen.resize(lines=30, columns=15)
    terminal.child.setwinsize(30, 15)
    terminal.wait(lambda: origin(terminal, 3) == (3, 15))
    drag(terminal, (8, 15), (8, 20))
    terminal.wait(lambda: origin(terminal, 3) == (3, 20))
    terminal.command("stty size", "small-drag-size", "8 10\n")
    terminal.screen.resize(lines=30, columns=100)
    terminal.child.setwinsize(30, 100)
    terminal.wait(lambda: origin(terminal, 3) == (50, 20))
    terminal.command("stty size", "restored-drag-size", "8 48\n")


def test_closing_pane_during_drag_cancels_capture(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.split("down")
    terminal.visible("3: shell")
    drag(terminal, (80, 15), (80, 20))
    terminal.wait(lambda: origin(terminal, 3) == (50, 20))
    terminal.focus(1)
    terminal.child.send("\x1b[<0;80;20M\x1bw")
    terminal.wait(lambda: origin(terminal, 1) is None and origin(terminal, 3) == (0, 20))
    terminal.child.send("\x1b[<32;80;24M\x1b[<0;80;24m")
    terminal.command("stty size", "after-close", "18 98\n")
    assert origin(terminal, 3) == (0, 20)
    drag(terminal, (80, 20), (80, 24))
    terminal.wait(lambda: origin(terminal, 3) == (0, 24))


@pytest.mark.parametrize("action", ["resize", "split", "focus"])
def test_layout_changes_during_drag_cancel_capture(sessions, action):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.send("\x1b[<0;50;8M")
    if action == "resize":
        terminal.command("printf ready", "drag-started", "ready")
        terminal.screen.resize(lines=30, columns=120)
        terminal.child.setwinsize(30, 120)
        terminal.wait(lambda: origin(terminal, 2) == (60, 0))
        expected = "28 58\n"
    elif action == "split":
        terminal.split("down")
        terminal.visible("3: shell")
        expected = "13 48\n"
    else:
        terminal.focus(1)
        expected = "28 48\n"
    terminal.child.send("\x1b[<32;80;8M\x1b[<0;80;8m")
    terminal.command("stty size", "after-change", expected)
    assert origin(terminal, 2) == ((60, 0) if action == "resize" else (50, 0))


def test_separator_drag_resizes_application_without_forwarding_mouse_events(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach test")
    terminal.visible("2: test")
    destination = sessions.path / "resize-application.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), "legacy"]))
    terminal.wait(lambda: destination.with_suffix(".json").exists() and destination.exists())
    terminal.visible("PANE_APPLICATION")
    drag(terminal, (50, 8), (65, 8), release=False)
    terminal.wait(lambda: json.loads(destination.with_suffix(".json").read_text())["cols"] == 33)
    terminal.child.send("\x1b[<0;65;8m")
    terminal.click(70, 3)
    terminal.wait(lambda: destination.read_bytes() == b"\x1b[<0;4;2M\x1b[<0;4;2m")
    drag(terminal, (70, 3), (20, 3))
    terminal.wait(lambda: destination.read_bytes().endswith(b"\x1b[<0;4;2M\x1b[<0;1;2m"))
    assert origin(terminal, 2) == (65, 0)
    assert json.loads(destination.with_suffix(".json").read_text())["cols"] == 33
