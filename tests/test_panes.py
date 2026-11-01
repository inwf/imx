import io
import json
import shlex
import sys
import time

import pexpect
import pyte
import psutil
import pytest

from conftest import ROOT, SessionEnvironment


class PaneTerminal:
    def __init__(self, sessions, name="dev", initialize=True, child=None):
        self.sessions = sessions
        self.child = child if child is not None else sessions.spawn(name, initialize=initialize, rows=30, cols=100)
        if child is None and not initialize:
            self.child.sendline("printf '\\nPANE_READY\\n'")
            self.child.expect_exact("\r\nPANE_READY\r\n")
        self.capture = io.StringIO()
        self.child.logfile_read = self.capture
        self.screen = pyte.Screen(100, 30)
        self.stream = pyte.Stream(self.screen)
        self.offset = 0

    def pump(self):
        try:
            self.child.read_nonblocking(65536, timeout=0.02)
        except pexpect.TIMEOUT:
            pass
        output = self.capture.getvalue()
        self.stream.feed(output[self.offset:])
        self.offset = len(output)

    def wait(self, condition):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            self.pump()
            if condition():
                return
        raise AssertionError(f"终端状态未满足条件：{self.screen.display!r}\n{self.capture.getvalue()[-3000:]!r}")

    def visible(self, value):
        self.wait(lambda: any(value in row for row in self.screen.display))

    def split(self, direction="right"):
        self.child.send("\x1bd" if direction == "right" else "\x1bD")

    def click(self, col, row=3):
        self.child.send(f"\x1b[<0;{col};{row}M\x1b[<0;{col};{row}m")

    def command(self, command, filename, expected):
        path = self.sessions.path / filename
        self.child.sendline(f"{command} > {shlex.quote(str(path))}")
        self.wait(lambda: path.exists() and path.read_text() == expected)


def test_panes_inherit_directory_and_attach_independent_sessions(sessions):
    terminal = PaneTerminal(sessions)
    directory = sessions.path / "current directory"
    directory.mkdir()
    sessions.command(terminal.child, f"cd {shlex.quote(str(directory))}")
    terminal.split()
    terminal.visible("2: shell")
    terminal.command("pwd", "right-directory", f"{directory}\n")
    terminal.command("printf '%s' \"$IMX_SESSION\"", "right-unattached", "")
    assert [row["NAME"] for row in sessions.sessions()] == ["dev"]

    terminal.child.sendline("imx attach test")
    terminal.visible("2: test")
    terminal.command("printf '%s' \"$IMX_SESSION\"", "right-session", "test")
    terminal.click(3)
    terminal.command("printf '%s' \"$IMX_SESSION\"", "left-session", "dev")
    terminal.click(55)
    terminal.child.sendcontrol("\\")
    terminal.visible("2: shell")
    terminal.command("pwd", "detached-directory", f"{directory}\n")
    sessions.wait(lambda: {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == {"dev": "1", "test": "0"})

    terminal.click(3)
    terminal.child.sendcontrol("\\")
    terminal.visible("1: shell")
    terminal.command("pwd", "left-detached-directory", f"{directory}\n")
    assert all(row["CLIENTS"] == "0" for row in sessions.sessions())


def test_nested_splits_resize_and_close_without_ending_sessions(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.split("down")
    terminal.visible("3: shell")
    terminal.command("stty size", "third-size", "13 48\n")
    terminal.child.sendline("exit")
    terminal.wait(lambda: all("3: shell" not in row for row in terminal.screen.display))
    terminal.command("stty size", "second-size", "28 48\n")
    terminal.screen.resize(lines=12, columns=40)
    terminal.child.setwinsize(12, 40)
    terminal.command("stty size", "small-size", "10 18\n")
    terminal.screen.resize(lines=30, columns=100)
    terminal.child.setwinsize(30, 100)
    terminal.command("stty size", "restored-size", "28 48\n")
    terminal.child.close(force=True)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
    assert sessions.sessions()[0]["NAME"] == "dev"


def test_configured_split_shortcuts(sessions):
    path = sessions.home / ".config/imx/config.toml"
    path.parent.mkdir(parents=True)
    path.write_text("[keybindings]\nsplit_right = { key = 'F6' }\nsplit_down = { key = 'F7' }\n")
    terminal = PaneTerminal(sessions)
    terminal.child.send("\x1b[17~")
    terminal.visible("2: shell")
    terminal.child.send("\x1b[18~")
    terminal.visible("3: shell")


@pytest.mark.parametrize("right, down", [
    ("\x1bd", "\x1bD"),
    ("\x1b[100;3u", "\x1b[100;4u"),
    ("\x1b[27;3;100~", "\x1b[27;4;68~"),
])
def test_default_split_shortcuts_across_terminal_encodings(sessions, right, down):
    terminal = PaneTerminal(sessions)
    terminal.child.send(right)
    terminal.visible("2: shell")
    terminal.command("stty size", "right-size", "28 48\n")
    terminal.child.send(down)
    terminal.visible("3: shell")
    terminal.command("stty size", "down-size", "13 48\n")


@pytest.mark.parametrize("initial", [False, True])
@pytest.mark.parametrize("mode, shortcut", [
    ("legacy", "\x1bw"),
    ("kitty", "\x1b[119;3u"),
    ("modify", "\x1b[27;3;119~"),
])
def test_close_shortcut_terminates_focused_session_and_jobs(sessions, initial, mode, shortcut):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach test")
    terminal.visible("2: test")
    target, remaining, pane_id = ("dev", "test", 1) if initial else ("test", "dev", 2)
    if initial:
        terminal.click(3)
    row = next(row for row in sessions.sessions() if row["NAME"] == target)
    shell_pid = int(row["PID"])
    backend_pid = psutil.Process(shell_pid).ppid()
    background = sessions.path / "background-pid"
    terminal.child.sendline(f"sleep 600 & printf '%s' $! > {shlex.quote(str(background))}")
    terminal.wait(lambda: background.exists() and background.read_text().isdigit())
    background_pid = int(background.read_text())
    destination = sessions.path / "close-application.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), mode]))
    terminal.wait(lambda: destination.with_suffix(".json").exists() and destination.exists())
    application_pid = json.loads(destination.with_suffix(".json").read_text())["pid"]
    terminal.visible("PANE_APPLICATION")
    terminal.child.send(shortcut)
    terminal.wait(lambda: all(f"{pane_id}:" not in row for row in terminal.screen.display))
    sessions.wait(lambda: {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == {remaining: "1"})
    sessions.wait(lambda: all(not psutil.pid_exists(pid) for pid in [shell_pid, background_pid, application_pid, backend_pid]))
    terminal.command("printf '%s' \"$IMX_SESSION\"", "remaining-session", remaining)


@pytest.mark.parametrize("initial", [False, True])
def test_detach_then_close_in_one_write_preserves_session(sessions, initial):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach test")
    terminal.visible("2: test")
    target, remaining, pane_id = ("dev", "test", 1) if initial else ("test", "dev", 2)
    if initial:
        terminal.click(3)
    pid = int(next(row for row in sessions.sessions() if row["NAME"] == target)["PID"])
    terminal.child.send("\x1c\x1bw")
    terminal.wait(lambda: all(f"{pane_id}:" not in row for row in terminal.screen.display))
    sessions.wait(lambda: {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == {target: "0", remaining: "1"})
    assert psutil.pid_exists(pid)
    terminal.command("printf '%s' \"$IMX_SESSION\"", "remaining-session", remaining)


def test_close_session_shared_with_another_pane(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach dev")
    terminal.visible("2: dev")
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "2")
    terminal.child.send("\x1bw")
    terminal.wait(lambda: all("2:" not in row for row in terminal.screen.display))
    terminal.visible("1: shell")
    assert sessions.sessions() == []
    terminal.command("printf ready", "remaining-shell", "ready")


@pytest.mark.parametrize("key, shortcut", [("F8", "\x1b[19~"), ("Escape", "\x1b")])
def test_configured_close_shortcut(sessions, key, shortcut):
    path = sessions.home / ".config/imx/config.toml"
    path.parent.mkdir(parents=True)
    path.write_text(f"[keybindings]\nclose_pane = {{ key = '{key}' }}\n")
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.send(shortcut)
    terminal.wait(lambda: all("2:" not in row for row in terminal.screen.display))
    assert sessions.sessions()[0]["CLIENTS"] == "1"


def test_closing_pane_waits_for_backend_without_blocking_other_panes(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach test")
    terminal.visible("2: test")
    row = next(row for row in sessions.sessions() if row["NAME"] == "test")
    backend = psutil.Process(psutil.Process(int(row["PID"])).ppid())
    backend.suspend()
    try:
        terminal.child.send("\x1bw")
        terminal.click(3)
        terminal.command("printf responsive", "healthy-pane", "responsive")
    finally:
        backend.resume()
    terminal.wait(lambda: all("2:" not in row for row in terminal.screen.display))
    sessions.wait(lambda: [row["NAME"] for row in sessions.sessions()] == ["dev"])


def test_close_shortcut_before_splitting_ends_session(sessions):
    child = sessions.spawn()
    child.send("\x1bw")
    child.expect(pexpect.EOF)
    child.close()
    assert child.exitstatus == 0
    assert sessions.sessions() == []


def test_close_uses_attached_sessions_runtime_directory(sessions):
    other = SessionEnvironment()
    try:
        terminal = PaneTerminal(sessions)
        terminal.split()
        terminal.visible("2: shell")
        terminal.child.sendline(f"IMX_DIR={shlex.quote(str(other.runtime))} imx attach dev")
        terminal.visible("2: dev")
        assert other.sessions()[0]["CLIENTS"] == "1"
        terminal.child.send("\x1bw")
        terminal.wait(lambda: all("2:" not in row for row in terminal.screen.display))
        assert other.sessions() == []
        assert sessions.sessions()[0]["CLIENTS"] == "1"
        terminal.command("printf '%s' \"$IMX_SESSION\"", "remaining-session", "dev")
    finally:
        other.cleanup()


@pytest.mark.parametrize("mode, encoded", [
    ("legacy", b"\x01"),
    ("kitty", b"\x1b[97;5u"),
    ("modify", b"\x1b[27;5;97~"),
])
def test_pane_terminal_modes_mouse_coordinates_and_detach(sessions, mode, encoded):
    terminal = PaneTerminal(sessions)
    sessions.command(terminal.child, "printf '\\033[2J\\033[HLEFT_SESSION\\n'")
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach test")
    terminal.visible("2: test")
    destination = sessions.path / "application.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), mode]))
    terminal.wait(lambda: destination.with_suffix(".json").exists() and destination.exists())
    terminal.visible("PANE_APPLICATION")
    state = json.loads(destination.with_suffix(".json").read_text())
    assert (state["rows"], state["cols"]) == (28, 48)
    assert "LEFT_SESSION" in terminal.screen.display[1][:50]
    assert "PANE_APPLICATION" in terminal.screen.display[1][50:]
    assert terminal.screen.buffer[2][52].bg != "default"
    assert terminal.screen.buffer[2][52].bg == terminal.screen.buffer[1][52].bg

    terminal.child.send("\x1b[97;5u")
    terminal.wait(lambda: destination.read_bytes() == encoded)
    terminal.child.send("\x1b[57414u")
    keypad_enter = b"\x1b[57414u" if mode == "kitty" else b"\r"
    terminal.wait(lambda: destination.read_bytes() == encoded + keypad_enter)
    terminal.click(55)
    terminal.wait(lambda: b"\x1b[<0;4;2M\x1b[<0;4;2m" in destination.read_bytes())
    terminal.child.send("\x1b[<0;55;3M\x1b[<32;3;3M\x1b[<0;3;3m")
    terminal.wait(lambda: b"\x1b[<0;4;2M\x1b[<0;1;2m" in destination.read_bytes())
    paste = "\x1b[200~pasted 中文\x1bw\x1bd\x1bD\x1b[119;3u\x1b[201~"
    terminal.child.send(paste)
    terminal.wait(lambda: paste.encode() in destination.read_bytes())
    terminal.child.send("\x1b[119;3:3u")
    terminal.child.send("\x1b[97;5u")
    terminal.wait(lambda: destination.read_bytes().endswith(encoded))
    assert {row["NAME"] for row in sessions.sessions()} == {"dev", "test"}
    terminal.child.sendcontrol("\\")
    terminal.visible("2: shell")
    assert psutil.pid_exists(state["pid"])
    sessions.wait(lambda: {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == {"dev": "1", "test": "0"})


def test_detaching_one_pane_preserves_other_connection_to_same_session(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach dev")
    terminal.visible("2: dev")
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "2")
    terminal.child.sendcontrol("\\")
    terminal.visible("2: shell")
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "1")
    terminal.click(3)
    terminal.command("printf '%s' \"$IMX_SESSION\"", "remaining-session", "dev")


@pytest.mark.parametrize("close", ["exit\r", "\x1bw"])
def test_exiting_pane_terminates_its_ordinary_shell_jobs(sessions, close):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    path = sessions.path / "ordinary-job"
    terminal.child.sendline(f"sleep 600 & printf '%s' $! > {shlex.quote(str(path))}")
    terminal.wait(lambda: path.exists() and path.read_text().isdigit())
    pid = int(path.read_text())
    assert psutil.pid_exists(pid)
    terminal.child.send(close)
    terminal.wait(lambda: all("2: shell" not in row for row in terminal.screen.display))
    sessions.wait(lambda: not psutil.pid_exists(pid))
    assert sessions.sessions()[0]["NAME"] == "dev"


@pytest.mark.parametrize("shell", ["/bin/bash", "/usr/bin/zsh", "/usr/bin/fish"])
def test_new_pane_starts_selected_shell_in_current_directory(sessions, shell):
    sessions.environment["SHELL"] = shell
    terminal = PaneTerminal(sessions, initialize=False)
    directory = sessions.path / "窗格 directory"
    directory.mkdir()
    terminal.child.sendline(f"cd {shlex.quote(str(directory))}")
    sessions.wait(lambda: sessions.sessions()[0]["DIRECTORY"] == str(directory))
    terminal.split()
    terminal.visible("2: shell")
    terminal.command("pwd", "shell-directory", f"{directory}\n")


def test_split_and_following_input_in_one_write(sessions):
    terminal = PaneTerminal(sessions)
    path = sessions.path / "following-input"
    terminal.child.send(f"\x1bdprintf preserved > {shlex.quote(str(path))}\r")
    terminal.wait(lambda: path.exists() and path.read_text() == "preserved")


def test_pane_detaches_while_its_backend_is_paused(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach test")
    terminal.visible("2: test")
    rows = {row["NAME"]: row for row in sessions.sessions()}
    backend = psutil.Process(psutil.Process(int(rows["test"]["PID"])).ppid())
    backend.suspend()
    try:
        terminal.child.sendcontrol("\\")
        terminal.visible("2: shell")
        terminal.click(3)
        terminal.command("printf responsive", "healthy-pane", "responsive")
    finally:
        backend.resume()


def test_pane_reaps_completed_session_backends(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach test")
    terminal.visible("2: test")
    rows = {row["NAME"]: row for row in sessions.sessions()}
    backend_pid = psutil.Process(int(rows["test"]["PID"])).ppid()
    terminal.child.sendline("exit")
    terminal.visible("2: shell")
    sessions.wait(lambda: not psutil.pid_exists(backend_pid))


def test_switching_in_a_pane_updates_its_title_and_split_directory(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach second")
    terminal.visible("2: second")
    directory = sessions.path / "switched directory"
    directory.mkdir()
    terminal.child.sendline(f"cd {shlex.quote(str(directory))}; imx attach third")
    terminal.visible("2: third")
    terminal.split("down")
    terminal.visible("3: shell")
    terminal.command("pwd", "switched-directory", f"{directory}\n")
    assert {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == {"dev": "1", "second": "0", "third": "1"}
    terminal.click(55)
    terminal.child.send("\x1bw")
    terminal.wait(lambda: all("2:" not in row for row in terminal.screen.display))
    sessions.wait(lambda: {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == {"dev": "1", "second": "0"})
    terminal.command("printf ready", "remaining-shell", "ready")


def test_configured_detach_and_mouse_focus(sessions):
    path = sessions.home / ".config/imx/config.toml"
    path.parent.mkdir(parents=True)
    path.write_text("[keybindings]\ndetach = { key = 'F12' }\n")
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach second")
    terminal.visible("2: second")
    right_style = terminal.screen.buffer[0][50]
    assert right_style.bold
    terminal.click(3)
    terminal.wait(lambda: terminal.screen.buffer[0][0].bold)
    assert not terminal.screen.buffer[0][50].bold
    terminal.child.send("\x1b[24~")
    terminal.visible("1: shell")
    assert {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == {"dev": "0", "second": "1"}


def test_small_terminal_preserves_panes_and_rejects_extra_splits(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.screen.resize(lines=6, columns=15)
    terminal.child.setwinsize(6, 15)
    terminal.command("stty size", "minimum-size", "4 10\n")
    terminal.split()
    terminal.visible("Not enough spac")
    terminal.screen.resize(lines=30, columns=100)
    terminal.child.setwinsize(30, 100)
    terminal.command("stty size", "enlarged-size", "28 48\n")
    terminal.visible("1: dev")
    terminal.visible("2: shell")
    assert all("3: shell" not in row for row in terminal.screen.display)


def test_output_in_one_pane_preserves_other_pane_input_and_close_cleanup(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    path = sessions.path / "ordinary-background-job"
    terminal.child.sendline(f"sleep 600 & printf '%s' $! > {shlex.quote(str(path))}")
    terminal.wait(lambda: path.exists() and path.read_text().isdigit())
    job = psutil.Process(int(path.read_text()))
    terminal.click(3)
    terminal.child.sendline("yes CONTINUOUS_OUTPUT")
    terminal.visible("CONTINUOUS_OUTPUT")
    terminal.click(55)
    terminal.command("printf responsive", "output-responsive", "responsive")
    terminal.child.close(force=True)
    sessions.wait(lambda: not job.is_running())
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
    assert sessions.sessions()[0]["NAME"] == "dev"


@pytest.mark.parametrize("close", ["exit\r", "\x1bw"])
def test_closing_last_pane_restores_outer_terminal(sessions, close):
    outer = pexpect.spawn("/bin/bash", ["--noprofile", "--norc"], env=sessions.environment,
                          cwd=str(sessions.path), dimensions=(30, 100), encoding="utf-8", timeout=10)
    sessions.clients.append(outer)
    outer.delaybeforesend = 0
    outer.expect(r"[#$] ")
    outer.sendline("stty -g > pane-before; imx attach dev; printf '\\nWORKSPACE_CLOSED\\n'")
    outer.expect(r"[#$] ")
    terminal = PaneTerminal(sessions, child=outer)
    terminal.split()
    terminal.visible("2: shell")
    outer.send(close)
    terminal.wait(lambda: all("2: shell" not in row for row in terminal.screen.display))
    outer.sendcontrol("\\")
    terminal.visible("1: shell")
    outer.send(close)
    outer.expect_exact("\r\nWORKSPACE_CLOSED\r\n")
    outer.sendline("stty -g > pane-after; printf '\\nOUTER_RESTORED\\n'")
    outer.expect_exact("\r\nOUTER_RESTORED\r\n")
    assert (sessions.path / "pane-before").read_text() == (sessions.path / "pane-after").read_text()
    assert sessions.sessions()[0]["CLIENTS"] == "0"


@pytest.mark.parametrize("binding", ["split_right", "split_down", "close_pane"])
def test_conflicting_shortcuts_report_configuration_option(sessions, binding):
    path = sessions.home / ".config/imx/config.toml"
    path.parent.mkdir(parents=True)
    path.write_text(f"[keybindings]\n{binding} = {{ key = '\\', ctrl = true }}\n")
    try:
        result = sessions.run("list", check=False)
        assert result.returncode != 0
        assert f"keybindings.{binding}" in result.stderr
        assert "conflicts with keybindings.detach" in result.stderr
    finally:
        path.unlink()
