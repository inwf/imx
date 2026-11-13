import json
import shlex
import sys

import pytest

from conftest import ROOT
from test_pane_resize import origin
from test_panes import PaneTerminal


OPPOSITE = dict(left="right", right="left", up="down", down="up")


def resize_key(direction, mode="legacy", *, shrink=False):
    modifiers = 7 if shrink else 4
    if mode == "kitty":
        return f"\x1b[{dict(left=57350, right=57351, up=57352, down=57353)[direction]};{modifiers}u"
    return f"\x1b[1;{modifiers}{dict(left='D', right='C', up='A', down='B')[direction]}"


@pytest.mark.parametrize("direction", ["right", "down"])
@pytest.mark.parametrize("number", [0, 1])
@pytest.mark.parametrize("gap", [0, 3])
def test_keyboard_resize_updates_dimensions_and_preserves_proportions(sessions, direction, number, gap):
    config = sessions.home / ".config/imx/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text(f"[panes]\nhorizontal_gap = {gap}\nvertical_gap = {gap}\n")
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.visible("1: shell")
    terminal.focus(number)
    horizontal = direction == "right"
    total = (100 if horizontal else 30) - gap
    first = total // 2
    original = first if number == 0 else total - first
    grow = direction if number == 0 else OPPOSITE[direction]
    shrink = OPPOSITE[grow]
    for index, (key, shrinking, change) in enumerate([(shrink, True, -1), (grow, False, 0), (grow, False, 1)]):
        terminal.child.send(resize_key(key, shrink=shrinking))
        expected = original + change - 2
        dimensions = f"28 {expected}\n" if horizontal else f"{expected} 98\n"
        terminal.command("stty size", f"size-{index}", dimensions)
        terminal.focused(number)
    first += 1 if number == 0 else -1
    assert origin(terminal, 1) == ((first + gap, 0) if horizontal else (0, first + gap))

    terminal.screen.resize(lines=6, columns=15)
    terminal.child.setwinsize(6, 15)
    minimum = "4 10\n" if horizontal else "3 13\n"
    terminal.command("stty size", "minimum", minimum)
    terminal.child.send(resize_key(shrink, shrink=True) + resize_key(grow))
    terminal.command("stty size", "minimum-preserved", minimum)
    terminal.screen.resize(lines=60, columns=200)
    terminal.child.setwinsize(60, 200)
    expanded_total = (200 if horizontal else 60) - gap
    expanded_first = expanded_total * first // total
    expected = (expanded_first if number == 0 else expanded_total - expanded_first) - 2
    dimensions = f"58 {expected}\n" if horizontal else f"{expected} 198\n"
    terminal.command("stty size", "expanded", dimensions)


@pytest.mark.parametrize("direction", ["right", "down"])
@pytest.mark.parametrize("number", [1, 2])
def test_keyboard_resize_clamps_nearest_nested_separator(sessions, direction, number):
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.visible("1: shell")
    terminal.split(direction)
    terminal.visible("2: shell")
    terminal.focus(number)
    horizontal = direction == "right"
    grow = direction if number == 1 else OPPOSITE[direction]
    shrink = OPPOSITE[grow]
    outer = origin(terminal, 1)
    terminal.child.send(resize_key(shrink, shrink=True) * 100)
    terminal.command("stty size", "smallest", "28 10\n" if horizontal else "3 98\n")
    assert origin(terminal, 1) == outer
    terminal.child.send(resize_key(grow) * 100)
    terminal.command("stty size", "largest", "28 36\n" if horizontal else "8 98\n")
    assert origin(terminal, 1) == outer
    terminal.focus(0)
    terminal.command("stty size", "outer-preserved", "28 48\n" if horizontal else "13 98\n")


@pytest.mark.parametrize("number", [0, 1, 2, 3])
@pytest.mark.parametrize("shrink", [False, True])
def test_keyboard_resize_quadrants_and_outer_edges(sessions, number, shrink):
    terminal = PaneTerminal(sessions)
    terminal.split("right")
    terminal.visible("1: shell")
    terminal.split("down")
    terminal.visible("2: shell")
    terminal.focus(0)
    terminal.split("down")
    terminal.visible("3: shell")
    terminal.focus(number)
    initial = {0: (0, 0), 1: (50, 0), 2: (50, 15), 3: (0, 15)}
    neighbors = {
        0: {"right", "down"},
        1: {"left", "down"},
        2: {"left", "up"},
        3: {"right", "up"},
    }
    for direction in OPPOSITE:
        edge = OPPOSITE[direction] if shrink else direction
        movable = edge in neighbors[number]
        horizontal = direction in ("left", "right")
        change = (-1 if shrink else 1) if movable else 0
        width = 50 + (change if horizontal else 0)
        height = 15 + (0 if horizontal else change)
        step = (-1 if direction in ("left", "up") else 1) if movable else 0
        divider_x = 50 + (step if horizontal else 0)
        left_y = 15 + (step if not horizontal and number in (0, 3) else 0)
        right_y = 15 + (step if not horizontal and number in (1, 2) else 0)
        expected = {0: (0, 0), 1: (divider_x, 0), 2: (divider_x, right_y), 3: (0, left_y)}
        terminal.child.send(resize_key(direction, shrink=shrink))
        terminal.command("stty size", f"quadrant-{direction}", f"{height - 2} {width - 2}\n")
        terminal.wait(lambda: {pane: origin(terminal, pane) for pane in initial} == expected)
        terminal.focused(number)
        terminal.child.send(resize_key(OPPOSITE[direction], shrink=not shrink))
        terminal.command("stty size", f"restored-{direction}", "13 48\n")
        terminal.wait(lambda: {pane: origin(terminal, pane) for pane in initial} == initial)


@pytest.mark.parametrize("primary", ["right", "down"])
@pytest.mark.parametrize("shrink", [False, True])
def test_keyboard_resize_all_four_central_edges(sessions, primary, shrink):
    terminal = PaneTerminal(sessions)
    terminal.screen.resize(lines=60, columns=180)
    terminal.child.setwinsize(60, 180)
    terminal.command("stty size", "canvas-size", "58 178\n")
    for number in (1, 2):
        terminal.split(primary)
        terminal.visible(f"{number}: shell")
    secondary = "down" if primary == "right" else "right"
    for number in (0, 1, 2):
        terminal.focus(number)
        for child in (number * 2 + 3, number * 2 + 4):
            terminal.split(secondary)
            terminal.visible(f"{child}: shell")
    terminal.focus(5)
    terminal.command("stty size", "central-size", "13 43\n")
    initial = (
        {0: (0, 0), 1: (90, 0), 2: (135, 0), 3: (0, 30), 4: (0, 45),
         5: (90, 30), 6: (90, 45), 7: (135, 30), 8: (135, 45)}
        if primary == "right" else
        {0: (0, 0), 1: (0, 30), 2: (0, 45), 3: (90, 0), 4: (135, 0),
         5: (90, 30), 6: (135, 30), 7: (90, 45), 8: (135, 45)}
    )
    terminal.wait(lambda: {pane: origin(terminal, pane) for pane in initial} == initial)
    expected = (
        {"left": (90, 30, 41, 15), "right": (94, 30, 43, 15),
         "up": (90, 30, 45, 11), "down": (90, 34, 45, 13)}
        if shrink else
        {"left": (86, 30, 47, 15), "right": (90, 30, 49, 15),
         "up": (90, 26, 45, 17), "down": (90, 30, 45, 19)}
    )
    for direction, (x, y, width, height) in expected.items():
        terminal.child.send(resize_key(direction, shrink=shrink) * 4)
        terminal.command("stty size", f"central-{direction}", f"{height - 2} {width - 2}\n")
        terminal.wait(lambda: origin(terminal, 5) == (x, y))
        terminal.focused(5)
        terminal.child.send(resize_key(OPPOSITE[direction], shrink=not shrink) * 4)
        terminal.command("stty size", f"restored-{direction}", "13 43\n")
        terminal.wait(lambda: {pane: origin(terminal, pane) for pane in initial} == initial)


def test_keyboard_resize_nested_shared_boundary(sessions):
    terminal = PaneTerminal(sessions)
    for direction, number in [("right", 1), ("down", 2), ("right", 3)]:
        terminal.split(direction)
        terminal.visible(f"{number}: shell")
    terminal.child.send(resize_key("left"))
    terminal.command("stty size", "inner-width", "13 24\n")
    assert origin(terminal, 1) == (50, 0)
    assert origin(terminal, 2) == (50, 15)
    assert origin(terminal, 3) == (74, 15)
    terminal.child.send(resize_key("up"))
    terminal.command("stty size", "inner-height", "14 24\n")
    terminal.focus(2)
    terminal.command("stty size", "shared-height", "14 22\n")
    terminal.focus(1)
    terminal.command("stty size", "neighbor-height", "12 48\n")
    terminal.focus(0)
    terminal.command("stty size", "unchanged", "28 48\n")


@pytest.mark.parametrize("mode", ["legacy", "kitty", "modify"])
@pytest.mark.parametrize("number", [0, 1])
@pytest.mark.parametrize("mouse", [False, True])
def test_keyboard_resize_application_encodings_and_input(sessions, mode, number, mouse):
    config = sessions.home / ".config/imx/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text(f"[panes]\nmouse = {str(mouse).lower()}\n")
    terminal = PaneTerminal(sessions)
    if number == 1:
        terminal.split()
        terminal.visible("1: shell")
    destination = sessions.path / "resize-input.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), mode]))
    terminal.wait(lambda: destination.exists() and destination.with_suffix(".json").exists())
    terminal.visible("PANE_APPLICATION")
    if number == 0:
        terminal.child.send("".join(
            resize_key(direction, mode, shrink=shrink)
            for shrink in (False, True) for direction in OPPOSITE
        ))
        terminal.child.send("a")
        first_key = b"\x1b[97;;97u" if mode == "kitty" else b"a"
        terminal.wait(lambda: destination.read_bytes() == first_key)
        assert json.loads(destination.with_suffix(".json").read_text())["cols"] == 98
        terminal.split()
        terminal.visible("1: shell")
        terminal.focus(0)
    grow = "right" if number == 0 else "left"
    terminal.child.send(resize_key(grow, mode))
    terminal.wait(lambda: json.loads(destination.with_suffix(".json").read_text())["cols"] == 49)
    terminal.child.send("".join(
        resize_key(direction, mode, shrink=shrink)
        for shrink in (False, True) for direction in ("up", "down")
    ))
    terminal.child.send(resize_key(OPPOSITE[grow], mode) + resize_key(grow, mode, shrink=True))
    terminal.child.send(resize_key(OPPOSITE[grow], mode, shrink=True))
    terminal.wait(lambda: json.loads(destination.with_suffix(".json").read_text())["cols"] == 48)
    terminal.child.send("b")
    encoded = b"\x1b[98;;98u" if mode == "kitty" else b"b"
    terminal.wait(lambda: destination.read_bytes() == (first_key if number == 0 else b"") + encoded)
    terminal.focused(number)


@pytest.mark.parametrize("direction,number,grow,shrink", [
    ("right", 0, "\x1b[17~", "\x1b[20~"),
    ("right", 1, "\x1b[15~", "\x1b[21~"),
    ("down", 0, "\x1b[19~", "\x1b[23~"),
    ("down", 1, "\x1b[18~", "\x1b[24~"),
])
def test_configured_keyboard_resize_shortcuts(sessions, direction, number, grow, shrink):
    config = sessions.home / ".config/imx/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text(
        "[keybindings]\n"
        "resize_left = { key = 'F5' }\nresize_right = { key = 'F6' }\n"
        "resize_up = { key = 'F7' }\nresize_down = { key = 'F8' }\n"
        "shrink_left = { key = 'F9' }\nshrink_right = { key = 'F10' }\n"
        "shrink_up = { key = 'F11' }\nshrink_down = { key = 'F12' }\n"
    )
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.visible("1: shell")
    terminal.focus(number)
    terminal.child.send(grow)
    terminal.command("stty size", "larger", "28 49\n" if direction == "right" else "14 98\n")
    terminal.child.send(shrink)
    terminal.command("stty size", "smaller", "28 48\n" if direction == "right" else "13 98\n")
    terminal.focused(number)


@pytest.mark.usefixtures("mouse_mode")
@pytest.mark.parametrize("shrink", [False, True])
def test_keyboard_resize_cancels_separator_drag(sessions, shrink):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.child.send("\x1b[<0;50;8M" + resize_key("right" if shrink else "left", shrink=shrink))
    dimensions = "28 47\n" if shrink else "28 49\n"
    terminal.command("stty size", "resized", dimensions)
    terminal.child.send("\x1b[<32;80;8M\x1b[<0;80;8m")
    terminal.command("stty size", "after-release", dimensions)
    assert origin(terminal, 1) == (51 if shrink else 49, 0)
