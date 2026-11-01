import json
import shlex
import sys

import pytest

from conftest import ROOT
from test_panes import PaneTerminal


def reporting_modes(terminal):
    return {mode for mode in (9, 1000, 1002, 1003, 1006) if mode << 5 in terminal.screen.mode}


@pytest.mark.parametrize("contents", [None, "[panes]\n", "[panes]\nmouse = false\n"])
def test_disabled_mouse_leaves_shell_selection_to_terminal(sessions, contents):
    if contents is not None:
        path = sessions.home / ".config/imx/config.toml"
        path.parent.mkdir(parents=True)
        path.write_text(contents)
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    assert reporting_modes(terminal) == set()
    terminal.click(3)
    terminal.child.send("\x1b[<0;50;8M\x1b[<32;65;8M\x1b[<0;65;8m\x1b[<64;3;3M")
    terminal.command("stty size", "unchanged-size", "28 48\n")
    terminal.focused(2)
    assert "\x1b]52;" not in terminal.capture.getvalue()
    assert not any(cell.reverse for row in terminal.screen.buffer.values() for cell in row.values())
    terminal.focus(1)
    terminal.command("printf '%s' \"$IMX_SESSION\"", "keyboard-focus", "dev")
    terminal.split("down")
    terminal.visible("3: shell")
    assert reporting_modes(terminal) == set()


@pytest.mark.parametrize("enabled", [False, True])
@pytest.mark.parametrize("mode", [9, 1000, 1002, 1003])
def test_application_mouse_reporting_follows_focus_and_detach(sessions, enabled, mode):
    path = sessions.home / ".config/imx/config.toml"
    path.parent.mkdir(parents=True)
    path.write_text(f"[panes]\nmouse = {str(enabled).lower()}\n")
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    shell_modes = {1002, 1006} if enabled else set()
    assert reporting_modes(terminal) == shell_modes
    terminal.child.sendline("imx attach test")
    terminal.visible("2: test")
    destination = sessions.path / "mouse-application.bin"
    terminal.child.sendline(shlex.join([
        sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), "legacy", str(mode),
    ]))
    application_modes = {1003 if mode == 1003 else 1002 if enabled else mode, 1006}
    terminal.wait(lambda: destination.exists() and reporting_modes(terminal) == application_modes)
    terminal.visible("PANE_APPLICATION")
    if not enabled:
        terminal.click(3)
        terminal.child.send("\x1b[<0;50;8M\x1b[<32;65;8M\x1b[<0;65;8m")
    terminal.click(55, 3)
    expected = b"\x1b[<0;4;2M" + (b"" if mode == 9 else b"\x1b[<0;4;2m")
    terminal.wait(lambda: destination.read_bytes() == expected)
    terminal.focused(2)
    assert json.loads(destination.with_suffix(".json").read_text())["cols"] == 48
    terminal.focus(1)
    terminal.wait(lambda: reporting_modes(terminal) == shell_modes)
    terminal.command("printf ready", "shell-remains-usable", "ready")
    terminal.focus(2)
    terminal.wait(lambda: reporting_modes(terminal) == application_modes)
    terminal.child.send("\x1b\\")
    terminal.visible("2: shell")
    terminal.wait(lambda: reporting_modes(terminal) == shell_modes)
    assert {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == {"dev": "1", "test": "0"}


def test_full_template_disables_mouse_mode(sessions):
    path = sessions.home / ".config/imx/config.toml"
    path.parent.mkdir(parents=True)
    path.write_text((ROOT / "config.example.toml").read_text())
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    assert reporting_modes(terminal) == set()


@pytest.mark.parametrize("enabled", [False, True])
def test_split_and_close_restore_mouse_mode_from_initial_application(sessions, enabled):
    path = sessions.home / ".config/imx/config.toml"
    path.parent.mkdir(parents=True)
    path.write_text(f"[panes]\nmouse = {str(enabled).lower()}\n")
    terminal = PaneTerminal(sessions)
    destination = sessions.path / "initial-application.bin"
    terminal.child.sendline(shlex.join([
        sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), "legacy",
    ]))
    terminal.wait(lambda: destination.exists() and reporting_modes(terminal) == {1000, 1006})
    terminal.split()
    terminal.visible("2: shell")
    shell_modes = {1002, 1006} if enabled else set()
    assert reporting_modes(terminal) == shell_modes
    terminal.focus(1)
    terminal.wait(lambda: reporting_modes(terminal) == {1002 if enabled else 1000, 1006})
    terminal.child.send("\x1bw")
    terminal.wait(lambda: " 1: " not in terminal.screen.display[0])
    terminal.focused(2)
    assert reporting_modes(terminal) == shell_modes
    terminal.command("printf ready", "remaining-pane", "ready")
