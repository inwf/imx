import json
import shlex
import sys

import pytest

from conftest import ROOT
from test_pane_resize import origin
from test_panes import PaneTerminal


def resize_key(direction, mode="legacy"):
    if mode == "kitty":
        return f"\x1b[{dict(left=57350, right=57351, up=57352, down=57353)[direction]};4u"
    return f"\x1b[1;4{dict(left='D', right='C', up='A', down='B')[direction]}"


@pytest.mark.parametrize("direction", ["right", "down"])
@pytest.mark.parametrize("number", [1, 2])
@pytest.mark.parametrize("gap", [0, 3])
def test_keyboard_resize_updates_dimensions_and_preserves_proportions(sessions, direction, number, gap):
    config = sessions.home / ".config/imx/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text(f"[panes]\nhorizontal_gap = {gap}\nvertical_gap = {gap}\n")
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.visible("2: shell")
    terminal.focus(number)
    horizontal = direction == "right"
    total = (100 if horizontal else 30) - gap
    first = total // 2
    original = first if number == 1 else total - first
    shrink = "left" if horizontal else "up"
    for index, (key, change) in enumerate([(shrink, -1), (direction, 0), (direction, 1)]):
        terminal.child.send(resize_key(key))
        expected = original + change - 2
        dimensions = f"28 {expected}\n" if horizontal else f"{expected} 98\n"
        terminal.command("stty size", f"size-{index}", dimensions)
        terminal.focused(number)
    first += 1 if number == 1 else -1
    assert origin(terminal, 2) == ((first + gap, 0) if horizontal else (0, first + gap))

    terminal.screen.resize(lines=6, columns=15)
    terminal.child.setwinsize(6, 15)
    minimum = "4 10\n" if horizontal else "3 13\n"
    terminal.command("stty size", "minimum", minimum)
    terminal.child.send(resize_key(shrink) + resize_key(direction))
    terminal.command("stty size", "minimum-preserved", minimum)
    terminal.screen.resize(lines=60, columns=200)
    terminal.child.setwinsize(60, 200)
    expanded_total = (200 if horizontal else 60) - gap
    expanded_first = expanded_total * first // total
    expected = (expanded_first if number == 1 else expanded_total - expanded_first) - 2
    dimensions = f"58 {expected}\n" if horizontal else f"{expected} 198\n"
    terminal.command("stty size", "expanded", dimensions)


@pytest.mark.parametrize("direction", ["right", "down"])
@pytest.mark.parametrize("number", [2, 3])
def test_keyboard_resize_clamps_nearest_nested_separator(sessions, direction, number):
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.visible("2: shell")
    terminal.split(direction)
    terminal.visible("3: shell")
    terminal.focus(number)
    horizontal = direction == "right"
    shrink = "left" if horizontal else "up"
    outer = origin(terminal, 2)
    terminal.child.send(resize_key(shrink) * 100)
    terminal.command("stty size", "smallest", "28 10\n" if horizontal else "3 98\n")
    assert origin(terminal, 2) == outer
    terminal.child.send(resize_key(direction) * 100)
    terminal.command("stty size", "largest", "28 36\n" if horizontal else "8 98\n")
    assert origin(terminal, 2) == outer
    terminal.focus(1)
    terminal.command("stty size", "outer-preserved", "28 48\n" if horizontal else "13 98\n")


def test_keyboard_resize_nested_shared_boundary(sessions):
    terminal = PaneTerminal(sessions)
    for direction, number in [("right", 2), ("down", 3), ("right", 4)]:
        terminal.split(direction)
        terminal.visible(f"{number}: shell")
    terminal.child.send(resize_key("right"))
    terminal.command("stty size", "inner-width", "13 24\n")
    assert origin(terminal, 2) == (50, 0)
    assert origin(terminal, 3) == (50, 15)
    assert origin(terminal, 4) == (74, 15)
    terminal.child.send(resize_key("down"))
    terminal.command("stty size", "inner-height", "14 24\n")
    terminal.focus(3)
    terminal.command("stty size", "shared-height", "14 22\n")
    terminal.focus(2)
    terminal.command("stty size", "neighbor-height", "12 48\n")
    terminal.focus(1)
    terminal.command("stty size", "unchanged", "28 48\n")


@pytest.mark.parametrize("mode", ["legacy", "kitty", "modify"])
@pytest.mark.parametrize("number", [1, 2])
@pytest.mark.parametrize("mouse", [False, True])
def test_keyboard_resize_application_encodings_and_input(sessions, mode, number, mouse):
    config = sessions.home / ".config/imx/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text(f"[panes]\nmouse = {str(mouse).lower()}\n")
    terminal = PaneTerminal(sessions)
    if number == 2:
        terminal.split()
        terminal.visible("2: shell")
    destination = sessions.path / "resize-input.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), mode]))
    terminal.wait(lambda: destination.exists() and destination.with_suffix(".json").exists())
    terminal.visible("PANE_APPLICATION")
    if number == 1:
        terminal.child.send("".join(resize_key(direction, mode) for direction in ("left", "right", "up", "down")))
        terminal.child.send("a")
        terminal.wait(lambda: destination.read_bytes() == b"a")
        assert json.loads(destination.with_suffix(".json").read_text())["cols"] == 100
        terminal.split()
        terminal.visible("2: shell")
        terminal.focus(1)
    terminal.child.send(resize_key("right", mode))
    terminal.wait(lambda: json.loads(destination.with_suffix(".json").read_text())["cols"] == 49)
    terminal.child.send(resize_key("up", mode) + resize_key("down", mode) + resize_key("left", mode))
    terminal.wait(lambda: json.loads(destination.with_suffix(".json").read_text())["cols"] == 48)
    terminal.child.send("b")
    encoded = b"\x1b[98;;98u" if mode == "kitty" else b"b"
    terminal.wait(lambda: destination.read_bytes() == (b"a" if number == 1 else b"") + encoded)
    terminal.focused(number)


def test_configured_keyboard_resize_shortcuts(sessions):
    config = sessions.home / ".config/imx/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text(
        "[keybindings]\n"
        "resize_left = { key = 'F5' }\nresize_right = { key = 'F6' }\n"
        "resize_up = { key = 'F7' }\nresize_down = { key = 'F8' }\n"
    )
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.send("\x1b[17~")
    terminal.command("stty size", "wider", "28 49\n")
    terminal.child.send("\x1b[15~")
    terminal.command("stty size", "narrower", "28 48\n")
    terminal.split("down")
    terminal.visible("3: shell")
    terminal.child.send("\x1b[19~")
    terminal.command("stty size", "taller", "14 48\n")
    terminal.child.send("\x1b[18~")
    terminal.command("stty size", "shorter", "13 48\n")


@pytest.mark.usefixtures("mouse_mode")
def test_keyboard_resize_cancels_separator_drag(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.send("\x1b[<0;50;8M" + resize_key("right"))
    terminal.command("stty size", "resized", "28 49\n")
    terminal.child.send("\x1b[<32;80;8M\x1b[<0;80;8m")
    terminal.command("stty size", "after-release", "28 49\n")
    assert origin(terminal, 2) == (49, 0)
