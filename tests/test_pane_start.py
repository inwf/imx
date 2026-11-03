import os
import shlex
import time

import psutil
import pytest

from test_panes import PaneTerminal


@pytest.mark.parametrize("attached", [False, True])
@pytest.mark.parametrize("name, shell_name", [
    (b'quote"name', "'quote\"name'"),
    (b"back\\slash", "'back\\slash'"),
    (b"line\nbreak", "$'line\\nbreak'"),
    (b"tab\tname", "$'tab\\tname'"),
    (b"invalid\xff", "$'invalid\\377'"),
])
def test_split_inherits_directory_bytes(sessions, attached, name, shell_name):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    if attached:
        terminal.child.sendline("imx attach second")
        terminal.visible("2: second")
    directory = os.fsencode(sessions.path) + b"/" + name
    os.mkdir(directory)
    terminal.command(f"cd {shell_name}; printf ready", "directory-ready", "ready")
    terminal.split("down")
    terminal.visible("3: shell")
    destination = sessions.path / "inherited-directory"
    terminal.child.sendline(f"pwd -P > {shlex.quote(str(destination))}")
    terminal.wait(lambda: destination.exists() and destination.read_bytes() == directory + b"\n")


@pytest.mark.parametrize("timeout", [False, True])
def test_pending_split_keeps_other_panes_responsive(sessions, timeout):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx attach paused")
    terminal.visible("2: paused")
    directory = sessions.path / "current-directory"
    directory.mkdir()
    terminal.command(f"cd {shlex.quote(str(directory))}; pwd", "source-directory", f"{directory}\n")
    row = next(row for row in sessions.sessions() if row["NAME"] == "paused")
    backend = psutil.Process(psutil.Process(int(row["PID"])).ppid())
    backend.suspend()
    try:
        destination = sessions.path / "queued-command"
        terminal.child.send(f"\x1bDpwd > {shlex.quote(str(destination))}\r")
        terminal.visible("3: starting")
        started = time.monotonic()
        terminal.focus(1)
        terminal.command("printf responsive", "healthy-pane", "responsive")
        assert time.monotonic() - started < 1.5
        assert not destination.exists()
        if timeout:
            terminal.visible("SessionDirectoryTimeout")
            terminal.wait(lambda: all(" 3: " not in row for row in terminal.screen.display))
            terminal.command("printf alive", "after-timeout", "alive")
    finally:
        backend.resume()
    if timeout:
        terminal.focus(2)
        terminal.command("printf alive", "source-after-timeout", "alive")
        assert not destination.exists()
    else:
        terminal.visible("3: shell")
        terminal.wait(lambda: destination.exists() and destination.read_text() == f"{directory}\n")
        terminal.focused(1)


@pytest.mark.parametrize("attached", [False, True])
def test_removed_directory_cancels_only_the_new_pane(sessions, attached):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    if attached:
        terminal.child.sendline("imx attach second")
        terminal.visible("2: second")
    directory = sessions.path / "removed-directory"
    directory.mkdir()
    terminal.command(f"cd {shlex.quote(str(directory))}; pwd", "directory-before-removal", f"{directory}\n")
    directory.rmdir()
    terminal.split("down")
    terminal.visible("PaneExecFailed")
    terminal.wait(lambda: all(" 3: " not in row for row in terminal.screen.display))
    terminal.focus(1)
    terminal.command("printf alive", "healthy-after-failure", "alive")
    terminal.focus(2)
    terminal.command(f"cd {shlex.quote(str(sessions.path))}; printf alive", "source-after-failure", "alive")
    terminal.split("down")
    terminal.visible("3: shell")
    terminal.command("pwd", "retry-directory", f"{sessions.path}\n")


def test_closing_a_pending_split_cancels_its_request(sessions):
    terminal = PaneTerminal(sessions)
    row = sessions.sessions()[0]
    backend = psutil.Process(psutil.Process(int(row["PID"])).ppid())
    backend.suspend()
    try:
        terminal.split()
        terminal.visible("2: starting")
        terminal.child.send("\x1bw")
        terminal.wait(lambda: all(" 2: " not in row for row in terminal.screen.display))
        terminal.focused(1)
    finally:
        backend.resume()
    terminal.command("printf alive", "source-after-cancel", "alive")
    terminal.split()
    terminal.visible("2: shell")
    terminal.command("printf ready", "retry-after-cancel", "ready")


def test_missing_shell_executable_preserves_the_existing_session(sessions):
    shell = sessions.path / "bash"
    shell.symlink_to("/bin/bash")
    sessions.environment["SHELL"] = str(shell)
    terminal = PaneTerminal(sessions)
    shell.unlink()
    terminal.split()
    terminal.visible("PaneExecFailed")
    terminal.wait(lambda: all(" 2: " not in row for row in terminal.screen.display))
    terminal.command("printf alive", "source-after-exec-failure", "alive")
