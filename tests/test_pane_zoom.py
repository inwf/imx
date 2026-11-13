import json
import os
import shlex
import signal
import sys

import psutil
import pytest

from conftest import ROOT
from test_pane_keyboard_resize import resize_key
from test_pane_resize import drag, origin
from test_panes import PaneTerminal


ZOOM = "\x1bz"


def quadrants(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.split("down")
    terminal.visible("2: shell")
    terminal.focus(0)
    terminal.split("down")
    terminal.visible("3: shell")
    return terminal


def zoomed(terminal, number):
    terminal.wait(lambda: "[zoom]" in terminal.screen.display[0] and origin(terminal, number) == (0, 0))
    terminal.focused(number)
    terminal.wait(lambda:
        terminal.screen.display[0].startswith("╔═")
        and terminal.screen.display[0].endswith("╗")
        and terminal.screen.display[-1] == "╚" + "═" * (terminal.screen.columns - 2) + "╝"
        and all(row.startswith("║") and row.endswith("║") for row in terminal.screen.display[1:-1])
    )


@pytest.mark.parametrize("number", [0, 1, 2, 3])
@pytest.mark.parametrize("gap", [0, 3])
def test_zoom_quadrants_restores_resized_layout_and_focus(sessions, number, gap):
    config = sessions.home / ".config/imx/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text(f"[panes]\nhorizontal_gap = {gap}\nvertical_gap = {gap}\n")
    terminal = quadrants(sessions)
    terminal.focus(0)
    terminal.child.send(resize_key("right") * 7 + resize_key("down") * 3)
    left = (100 - gap) // 2 + 7
    top = (30 - gap) // 2
    terminal.command("stty size", "adjusted", f"{top + 1} {left - 2}\n")
    initial = {0: (0, 0), 1: (left + gap, 0), 2: (left + gap, top + gap), 3: (0, top + 3 + gap)}
    terminal.wait(lambda: {pane: origin(terminal, pane) for pane in initial} == initial)
    terminal.focus(number)
    width = left if number in (0, 3) else 100 - gap - left
    heights = {0: top + 3, 1: top, 2: 30 - gap - top, 3: 30 - gap - top - 3}
    for iteration in range(2):
        terminal.child.send(ZOOM)
        zoomed(terminal, number)
        assert all(origin(terminal, pane) is None for pane in initial if pane != number)
        terminal.command("stty size", f"zoom-{iteration}", "28 98\n")
        terminal.child.send(ZOOM)
        terminal.wait(lambda: {pane: origin(terminal, pane) for pane in initial} == initial)
        terminal.focused(number)
        terminal.command("stty size", f"restored-{iteration}", f"{heights[number] - 2} {width - 2}\n")
        for pane, (x, y) in initial.items():
            pane_width = left if pane in (0, 3) else 100 - gap - left
            assert terminal.screen.display[y][x] == "┌"
            assert terminal.screen.display[y][x + pane_width - 1] == "┐"
            assert terminal.screen.display[y + heights[pane] - 1][x] == "└"
            assert terminal.screen.display[y + heights[pane] - 1][x + pane_width - 1] == "┘"


def test_zoom_tracks_terminal_size_and_restores_proportions(sessions):
    terminal = quadrants(sessions)
    terminal.focus(0)
    terminal.child.send(resize_key("right") * 7)
    terminal.command("stty size", "resized", "13 55\n")
    terminal.focus(2)
    terminal.child.send(ZOOM)
    zoomed(terminal, 2)
    terminal.screen.resize(lines=3, columns=8)
    terminal.child.setwinsize(3, 8)
    terminal.command("stty size", "small-zoom", "3 10\n")
    terminal.screen.resize(lines=60, columns=200)
    terminal.child.setwinsize(60, 200)
    terminal.command("stty size", "large-zoom", "58 198\n")
    zoomed(terminal, 2)
    terminal.child.send(ZOOM)
    expected = {0: (0, 0), 1: (114, 0), 2: (114, 30), 3: (0, 30)}
    terminal.wait(lambda: {pane: origin(terminal, pane) for pane in expected} == expected)
    terminal.command("stty size", "large-restored", "28 84\n")


@pytest.mark.parametrize("mode, key", [
    ("legacy", ZOOM),
    ("kitty", "\x1b[122;3u"),
    ("modify", "\x1b[27;3;122~"),
])
@pytest.mark.parametrize("mouse", [False, True])
def test_zoom_application_resize_mouse_keyboard_and_hidden_dimensions(sessions, mode, key, mouse):
    config = sessions.home / ".config/imx/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text(f"[panes]\nmouse = {str(mouse).lower()}\n")
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    inputs = {}
    identities = {}
    for number in (0, 1):
        terminal.focus(number)
        destination = sessions.path / f"application-{number}.bin"
        inputs[number] = destination
        terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), mode]))
        terminal.wait(lambda: destination.exists() and destination.with_suffix(".json").exists())
        identities[number] = json.loads(destination.with_suffix(".json").read_text())["pid"]
    terminal.child.send(key)
    zoomed(terminal, 1)
    state = inputs[1].with_suffix(".json")
    terminal.wait(lambda: json.loads(state.read_text()) == {"pid": identities[1], "rows": 28, "cols": 98})
    terminal.click(50, 3)
    mouse_bytes = b"\x1b[<0;49;2M\x1b[<0;49;2m"
    terminal.wait(lambda: inputs[1].read_bytes() == mouse_bytes)
    terminal.child.send("x")
    encoded = b"\x1b[120;;120u" if mode == "kitty" else b"x"
    paste = "\x1b[200~中文" + key + "\x1b[201~"
    terminal.child.send(paste)
    terminal.wait(lambda: inputs[1].read_bytes() == mouse_bytes + encoded + paste.encode())
    zoomed(terminal, 1)
    assert inputs[0].read_bytes() == b""
    terminal.screen.resize(lines=60, columns=160)
    terminal.child.setwinsize(60, 160)
    terminal.wait(lambda: json.loads(state.read_text()) == {"pid": identities[1], "rows": 58, "cols": 158})
    assert json.loads(inputs[0].with_suffix(".json").read_text()) == {"pid": identities[0], "rows": 28, "cols": 48}
    terminal.child.send(key)
    terminal.wait(lambda: "[zoom]" not in terminal.screen.display[0])
    for number in (0, 1):
        terminal.wait(lambda: json.loads(inputs[number].with_suffix(".json").read_text()) == {"pid": identities[number], "rows": 58, "cols": 78})
    terminal.visible("PANE_APPLICATION")
    assert inputs[0].read_bytes() == b""


def test_zoom_hidden_output_continues_and_is_visible_after_restore(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    gate = sessions.path / "output.gate"
    ready = sessions.path / "output.ready"
    done = sessions.path / "output.done"
    os.mkfifo(gate)
    terminal.child.sendline(
        f"printf ready > {shlex.quote(str(ready))}; read -r value < {shlex.quote(str(gate))}; "
        f"seq 1 200000; printf '\\nHIDDEN_COMPLETE\\n'; printf done > {shlex.quote(str(done))}"
    )
    terminal.wait(ready.exists)
    terminal.focus(0)
    terminal.child.send(ZOOM)
    zoomed(terminal, 0)
    gate.write_text("run\n")
    terminal.wait(done.exists)
    zoomed(terminal, 0)
    assert all("HIDDEN_COMPLETE" not in row for row in terminal.screen.display)
    terminal.child.send(ZOOM)
    terminal.visible("HIDDEN_COMPLETE")
    terminal.focused(0)
    terminal.focus(1)
    terminal.command("stty size", "hidden-size", "28 48\n")


def test_zoom_vim_preserves_unsaved_text_and_insert_position(sessions):
    document = sessions.path / "zoom-document.txt"
    document.write_text("VIM_ZOOM\n")
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.child.sendline("vim -u NONE -i NONE -n zoom-document.txt")
    terminal.visible("VIM_ZOOM")
    terminal.child.send("A before")
    terminal.visible("VIM_ZOOM before")
    terminal.child.send(ZOOM)
    zoomed(terminal, 1)
    terminal.child.send("中文")
    terminal.visible("VIM_ZOOM before中文")
    terminal.child.send(ZOOM)
    terminal.wait(lambda: origin(terminal, 1) == (50, 0))
    terminal.child.send(" after\x1b:wq\r")
    terminal.wait(lambda: document.read_text() == "VIM_ZOOM before中文 after\n")
    terminal.command("stty size", "after-vim", "28 48\n")


def test_zoom_cancels_separator_drag(sessions, mouse_mode):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    drag(terminal, (50, 8), (55, 8), release=False)
    terminal.wait(lambda: origin(terminal, 1) == (55, 0))
    terminal.child.send(ZOOM)
    zoomed(terminal, 1)
    terminal.child.send("\x1b[<32;75;8M\x1b[<0;75;8m")
    terminal.command("stty size", "drag-cancelled", "28 98\n")
    terminal.child.send(ZOOM)
    terminal.command("stty size", "drag-restored", "28 43\n")
    assert origin(terminal, 1) == (55, 0)


def test_zoom_focus_uses_original_geometry_and_ignores_missing_targets(sessions):
    terminal = quadrants(sessions)
    terminal.focus(2)
    terminal.child.send(ZOOM)
    zoomed(terminal, 2)
    terminal.child.send("\x1b2\x1b9\x1b[1;3B")
    terminal.command("stty size", "same-focus", "28 98\n")
    zoomed(terminal, 2)
    terminal.child.send("\x1b[1;3A")
    terminal.focused(1)
    assert "[zoom]" not in terminal.screen.display[0]
    terminal.command("stty size", "direction-focus", "13 48\n")
    terminal.child.send(ZOOM)
    zoomed(terminal, 1)
    terminal.focus(3)
    terminal.command("stty size", "number-focus", "13 48\n")
    assert origin(terminal, 3) == (0, 15)


@pytest.mark.parametrize("axis, size", [("right", "28 23\n"), ("down", "13 48\n")])
def test_split_restores_zoom_before_dividing_the_original_pane(sessions, axis, size):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.child.send(ZOOM)
    zoomed(terminal, 1)
    terminal.split(axis)
    terminal.visible("2: shell")
    terminal.command("stty size", "new-pane-size", size)
    assert "[zoom]" not in terminal.screen.display[0]
    assert origin(terminal, 1) == (50, 0)


@pytest.mark.parametrize("key, width", [(resize_key("left"), 49), (resize_key("right", shrink=True), 47)])
def test_resize_shortcuts_restore_zoom_and_resize_original_separator(sessions, key, width):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.child.send(ZOOM)
    zoomed(terminal, 1)
    terminal.child.send(key)
    terminal.command("stty size", "resized", f"28 {width}\n")
    assert "[zoom]" not in terminal.screen.display[0]
    assert origin(terminal, 1) == (100 - width - 2, 0)


@pytest.mark.parametrize("close", ["\x1bw", "exit\r"])
def test_closing_zoomed_pane_restores_remaining_panes(sessions, close):
    terminal = PaneTerminal(sessions)
    terminal.child.send(ZOOM)
    terminal.command("stty size", "single-pane", "28 98\n")
    terminal.split()
    terminal.visible("1: shell")
    terminal.child.send(ZOOM)
    zoomed(terminal, 1)
    terminal.child.send(close)
    terminal.wait(lambda: origin(terminal, 1) is None and origin(terminal, 0) == (0, 0) and "[zoom]" not in terminal.screen.display[0])
    terminal.focused(0)
    terminal.child.send(ZOOM)
    terminal.command("stty size", "remaining-pane", "28 98\n")
    assert "[zoom]" not in terminal.screen.display[0]
    assert terminal.screen.display[0][0] == "┌"
    assert terminal.screen.display[-1][-1] == "┘"
    assert sessions.sessions()[0]["CLIENTS"] == "1"


def test_hidden_pane_exit_preserves_zoom_until_one_pane_remains(sessions):
    terminal = PaneTerminal(sessions)
    identities = {}
    for number in (1, 2):
        terminal.split("down")
        terminal.visible(f"{number}: shell")
        destination = sessions.path / f"shell-{number}.pid"
        terminal.child.sendline(f"printf '%s' \"$$\" > {shlex.quote(str(destination))}")
        terminal.wait(lambda: destination.exists() and destination.read_text() != "")
        identities[number] = int(destination.read_text())
    terminal.focus(0)
    terminal.child.send(ZOOM)
    zoomed(terminal, 0)
    os.kill(identities[2], signal.SIGKILL)
    terminal.wait(lambda: not psutil.pid_exists(identities[2]))
    terminal.command("stty size", "after-first-exit", "28 98\n")
    zoomed(terminal, 0)
    os.kill(identities[1], signal.SIGKILL)
    terminal.wait(lambda: "[zoom]" not in terminal.screen.display[0])
    terminal.command("stty size", "after-second-exit", "28 98\n")
    terminal.focused(0)
    assert terminal.screen.display[0][0] == "┌"
    assert terminal.screen.display[-1][-1] == "┘"


def test_detach_keeps_zoom_on_the_same_pane(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.focus(0)
    terminal.child.send(ZOOM)
    zoomed(terminal, 0)
    terminal.child.send("\x1b\\")
    terminal.visible("0: shell [zoom]")
    terminal.command("stty size", "detached-zoom", "28 98\n")
    assert sessions.sessions()[0]["CLIENTS"] == "0"
    terminal.child.send(ZOOM)
    terminal.command("stty size", "detached-restored", "28 48\n")


def test_zoom_pending_pane_uses_full_size_when_shell_starts(sessions):
    terminal = PaneTerminal(sessions)
    backend = psutil.Process(psutil.Process(int(sessions.sessions()[0]["PID"])).ppid())
    backend.suspend()
    try:
        terminal.split()
        terminal.visible("1: starting")
        terminal.child.send(ZOOM)
        zoomed(terminal, 1)
    finally:
        backend.resume()
    terminal.visible("1: shell [zoom]")
    terminal.command("stty size", "started-zoom", "28 98\n")
    terminal.child.send(ZOOM)
    terminal.command("stty size", "started-restored", "28 48\n")


def test_configured_zoom_shortcut(sessions):
    config = sessions.home / ".config/imx/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text("[keybindings]\nzoom_pane = { key = 'F6' }\n")
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.child.send("\x1b[17~")
    zoomed(terminal, 1)
    terminal.command("stty size", "custom-zoom", "28 98\n")
    terminal.child.send("\x1b[17~")
    terminal.command("stty size", "custom-restored", "28 48\n")


def test_zoom_shortcut_conflict_is_rejected(sessions):
    config = sessions.home / ".config/imx/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text("[keybindings]\nzoom_pane = { key = 'd', alt = true }\n")
    result = sessions.run("list", check=False)
    assert result.returncode != 0
    assert "keybindings.zoom_pane" in result.stderr
    assert "DuplicateKeybinding" in result.stderr
    assert not sessions.runtime.exists()
    config.unlink()
