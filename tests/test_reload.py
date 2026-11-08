import shlex
import subprocess
import time
import uuid

import pexpect
import psutil
import pytest

from test_panes import PaneTerminal
from test_pane_resize import origin
from test_pane_selection import select, selected, text_terminal
from test_pane_copy import copy_text
from test_prompt import configuration
from test_readonly import observe


def reload_terminal(terminal, success=True):
    name = uuid.uuid4().hex
    output = terminal.sessions.path / f"reload-{name}.out"
    status = terminal.sessions.path / f"reload-{name}.status"
    terminal.child.sendline(f"imx reload > {shlex.quote(str(output))} 2>&1; printf '%s' \"$?\" > {shlex.quote(str(status))}")
    terminal.wait(lambda: status.exists() and status.stat().st_size > 0)
    assert status.read_text() == ("0" if success else "1"), output.read_text()
    result = output.read_text()
    if success:
        assert result == "Configuration reloaded.\n"
    return result


def pane_environment(terminal):
    name = f"workspace-{uuid.uuid4().hex}"
    target = terminal.sessions.path / name
    terminal.child.sendline(f"printf '%s' \"$IMX_WORKSPACE\" > {shlex.quote(str(target))}")
    terminal.wait(lambda: target.exists() and target.stat().st_size > 0)
    return dict(terminal.sessions.environment, IMX_WORKSPACE=target.read_text())


def test_reload_inside_session_updates_split_and_detach_without_restarting(sessions):
    terminal = PaneTerminal(sessions)
    pid = sessions.sessions()[0]["PID"]
    sessions.command(terminal.child, "export RELOAD_VALUE=preserved; printf 'RELOAD_HISTORY\\n'")
    terminal.command("printf '%s' \"$IMX_WORKSPACE\"", "session-workspace-variable", "")
    configuration(sessions).write_text("[keybindings]\nsplit_right = { key = 'F6' }\ndetach = { key = 'F12' }\n")
    reload_terminal(terminal)
    terminal.child.send("\x1b[17~")
    terminal.visible("1: shell")
    terminal.focus(0)
    terminal.command("printf '%s' \"$RELOAD_VALUE\"", "value-after-reload", "preserved")
    assert "RELOAD_HISTORY" in sessions.run("cat", "dev").stdout
    assert sessions.sessions()[0]["PID"] == pid
    terminal.child.send("\x1b[24~")
    terminal.visible("0: shell")
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")


def test_reload_from_plain_pane_updates_existing_and_new_connections(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    configuration(sessions).write_text("[panes]\nmouse = true\nfocused_border_color = '#123456'\n[keybindings]\ndetach = { key = 'F12' }\n")
    reload_terminal(terminal)
    terminal.wait(lambda: terminal.screen.buffer[0][50].fg == "123456")
    terminal.click(5, 3)
    terminal.focused(0)
    terminal.child.send("\x1b[24~")
    terminal.visible("0: shell")
    configuration(sessions).write_text("[keybindings]\ndetach = { key = 'F11' }\n")
    terminal.child.sendline("imx attach second")
    terminal.visible("0: second")
    terminal.command("printf ready", "second-ready", "ready")
    terminal.child.send("\x1b[24~")
    terminal.visible("0: shell")
    sessions.wait(lambda: all(row["CLIENTS"] == "0" for row in sessions.sessions()))


def test_reload_changes_only_the_invoking_interface_of_a_shared_session(sessions):
    first = PaneTerminal(sessions)
    second = PaneTerminal(sessions, initialize=False)
    configuration(sessions).write_text("[keybindings]\nsplit_right = { key = 'F6' }\n")
    reload_terminal(second)
    second.child.send("\x1b[17~")
    second.visible("1: shell")
    first.split()
    first.visible("1: shell")
    assert sessions.sessions()[0]["CLIENTS"] == "2"


def test_reload_preserves_zoom_and_applies_gaps_to_existing_layout(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.split("down")
    terminal.visible("2: shell")
    terminal.child.send("\x1bz")
    terminal.visible("[zoom]")
    configuration(sessions).write_text("[panes]\nhorizontal_gap = 4\nvertical_gap = 2\nfocused_border_color = '#abcdef'\n")
    reload_terminal(terminal)
    terminal.wait(lambda: terminal.screen.buffer[0][0].fg == "abcdef")
    assert "[zoom]" in terminal.screen.display[0]
    terminal.child.send("\x1bz")
    terminal.wait(lambda: origin(terminal, 1) == (52, 0) and origin(terminal, 2) == (52, 16))
    terminal.focused(2)
    terminal.command("stty size", "reloaded-size", "12 46\n")
    terminal.split()
    terminal.visible("3: shell")
    assert origin(terminal, 3) == (78, 16)


@pytest.mark.parametrize("contents, message", [
    ("[panes\n", "InvalidConfiguration"),
    ("[panes]\nmouse = 'true'\n", "panes.mouse"),
    ("[panes]\nfocused_border_color = '#abcdef'\n[keybindings]\ndetach = { key = 'd', alt = true }\n", "DuplicateKeybinding"),
    (None, "FileNotFound"),
])
def test_invalid_reload_reports_error_and_preserves_running_interface(sessions, contents, message):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    path = configuration(sessions)
    original = path.read_text()
    try:
        if contents is None:
            path.unlink()
        else:
            path.write_text(contents)
        result = reload_terminal(terminal, success=False)
        assert str(path) in result and message in result
        assert terminal.screen.buffer[0][50].fg == "969cd5"
        terminal.split("down")
        terminal.visible("2: shell")
        terminal.command("printf alive", "after-invalid-reload", "alive")
        if contents is None:
            assert not path.exists()
    finally:
        path.write_text(original)


def test_reload_rejects_gaps_exceeding_supported_layout(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split("down")
    terminal.visible("1: shell")
    configuration(sessions).write_text("[panes]\nvertical_gap = 255\nfocused_border_color = '#abcdef'\n")
    result = reload_terminal(terminal, success=False)
    assert "ReloadLayoutTooLarge" in result
    assert origin(terminal, 1) == (0, 15)
    assert terminal.screen.buffer[15][0].fg == "969cd5"
    terminal.command("stty size", "unchanged-size", "13 98\n")


def test_oversized_configuration_diagnostic_preserves_interface(sessions):
    terminal = PaneTerminal(sessions)
    path = configuration(sessions)
    original = path.read_text()
    try:
        path.write_text("x" * 10000 + " = true\n")
        result = reload_terminal(terminal, success=False)
        assert "Configuration error" in result and len(result) <= 8192
        terminal.command("printf alive", "large-error-alive", "alive")
    finally:
        path.write_text(original)


def test_reload_copy_binding_preserves_selection(sessions, mouse_mode):
    terminal = text_terminal(sessions)
    select(terminal, (2, 2), (7, 2))
    selected(terminal, "alpha")
    terminal.focus(1)
    configuration(sessions).write_text("[panes]\nmouse = true\n[keybindings]\ncopy_selection = { key = 'y', alt = true }\n")
    reload_terminal(terminal)
    terminal.focus(0)
    selected(terminal, "alpha")
    copy_text(terminal, "alpha", "\x1by")


def test_reload_uses_interface_configuration_path(sessions):
    terminal = PaneTerminal(sessions)
    configuration(sessions).write_text("[keybindings]\nsplit_right = { key = 'F6' }\n")
    alternative = sessions.path / "different-config"
    (alternative / "imx").mkdir(parents=True)
    (alternative / "imx/config.toml").write_text("[invalid\n")
    terminal.child.sendline(f"export XDG_CONFIG_HOME={shlex.quote(str(alternative))}")
    reload_terminal(terminal)
    terminal.child.send("\x1b[17~")
    terminal.visible("1: shell")


def test_reload_updates_readonly_mouse_and_detach_without_resizing_source(sessions):
    writer = sessions.spawn(rows=30, cols=100)
    sessions.command(writer, "printf '\\033[3J\\033[2J\\033[H'; printf 'HISTORY-%03d\\n' {1..100}")
    observer = observe(sessions, rows=30, cols=100)
    observer.split()
    observer.visible("1: shell")
    configuration(sessions).write_text("[panes]\nmouse = true\n[keybindings]\ndetach = { key = 'F12' }\n")
    reload_terminal(observer)
    observer.child.send("\x1b[<64;5;5M" * 100)
    observer.visible("HISTORY-001")
    assert "30 100" in sessions.command(writer, "stty size")
    observer.focus(0)
    observer.child.send("\x1b[24~")
    observer.visible("0: shell")
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "1")
    assert writer.isalive()


def test_reload_turns_mouse_off_and_restores_default_bindings(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    configuration(sessions).write_text("[panes]\nmouse = true\n[keybindings]\nsplit_down = { key = 'F6' }\n")
    reload_terminal(terminal)
    terminal.click(5, 3)
    terminal.focused(0)
    configuration(sessions).write_text("")
    reload_terminal(terminal)
    terminal.click(75, 3)
    terminal.command("printf '%s' \"$IMX_SESSION\"", "mouse-disabled-focus", "dev")
    terminal.split("down")
    terminal.visible("2: shell")


def test_reload_to_escape_detach_preserves_session(sessions):
    terminal = PaneTerminal(sessions)
    configuration(sessions).write_text("[keybindings]\ndetach = { key = 'Escape' }\n")
    reload_terminal(terminal)
    terminal.child.send("\x1b")
    terminal.child.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")


def test_reload_after_switch_and_rename_routes_to_current_interface(sessions):
    terminal = PaneTerminal(sessions)
    terminal.child.sendline("imx attach second")
    terminal.visible("[second]")
    terminal.child.sendline("imx rename renamed")
    terminal.visible("[renamed]")
    configuration(sessions).write_text("[keybindings]\nsplit_right = { key = 'F6' }\n")
    reload_terminal(terminal)
    terminal.child.send("\x1b[17~")
    terminal.visible("1: shell")
    terminal.visible("0: renamed")


def test_timed_out_reload_is_not_applied_after_interface_resumes(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    environment = pane_environment(terminal)
    configuration(sessions).write_text("[panes]\nfocused_border_color = '#abcdef'\n")
    frontend = psutil.Process(terminal.child.pid)
    frontend.suspend()
    try:
        started = time.monotonic()
        result = subprocess.run([str(sessions.binary), "reload"], env=environment, capture_output=True, text=True, timeout=5)
        assert result.returncode == 1 and "ReloadTimeout" in result.stderr
        assert time.monotonic() - started < 4
    finally:
        frontend.resume()
    terminal.command("printf ready", "after-timeout", "ready")
    assert terminal.screen.buffer[0][50].fg == "969cd5"
    reload_terminal(terminal)
    terminal.wait(lambda: terminal.screen.buffer[0][50].fg == "abcdef")
