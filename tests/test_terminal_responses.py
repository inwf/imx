import shlex
import sys

import pexpect
import psutil
import pytest

from conftest import ROOT
from test_isolation import backends
from test_panes import PaneTerminal


def start_queries(sessions, child, reading):
    directory = sessions.path / "queries"
    directory.mkdir()
    child.sendline(shlex.join([sys.executable, str(ROOT / "tests/terminal_responses.py"),
                              str(directory), "read" if reading else "blocked"]))
    sessions.wait((directory / "ready").exists)
    return directory, psutil.Process(int((directory / "pid").read_text()))


@pytest.mark.parametrize("reading", [False, True])
def test_detached_terminal_response_queue(sessions, reading):
    child = sessions.spawn("queries")
    healthy = sessions.spawn("healthy")
    processes = backends(sessions)
    directory, writer = start_queries(sessions, child, reading)
    child.send("\x1b\\")
    child.expect(pexpect.EOF)
    (directory / "start").touch()
    if reading:
        sessions.wait((directory / "done").exists, timeout=20)
        assert (directory / "done").read_text() == "131072"
        assert processes["queries"].is_running()
    else:
        sessions.wait(lambda: not processes["queries"].is_running())
        sessions.wait(lambda: not writer.is_running())
        assert not (sessions.runtime / "session-queries.sock").exists()
        log = sessions.runtime / "session-queries.log"
        assert log.read_text() == "imx: TerminalResponseOverflow\n"
        log.rename(sessions.path / "terminal-response-error.log")
    assert "HEALTHY" in sessions.command(healthy, "printf 'HEALTHY\\n'")
    assert processes["healthy"].is_running()


def test_attached_terminal_responses(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.focus(0)
    directory, _ = start_queries(sessions, terminal.child, True)
    (directory / "start").touch()
    terminal.wait((directory / "done").exists)
    assert (directory / "done").read_text() == "131072"
    terminal.command("printf HEALTHY", "healthy-connected-pane", "HEALTHY")


@pytest.mark.parametrize("reading", [False, True])
def test_pane_terminal_response_queue(sessions, reading):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    directory, writer = start_queries(sessions, terminal.child, reading)
    (directory / "start").touch()
    if reading:
        terminal.wait((directory / "done").exists)
        assert (directory / "done").read_text() == "131072"
        terminal.focus(0)
    else:
        terminal.visible("Pane 1 closed: TerminalResponseOverflow.")
        terminal.wait(lambda: all(" 1: shell " not in row for row in terminal.screen.display))
        sessions.wait(lambda: not writer.is_running())
    assert terminal.child.isalive()
    terminal.command("printf HEALTHY", "healthy-pane", "HEALTHY")


def test_last_pane_terminal_response_overflow(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.focus(0)
    terminal.child.send("\x1bw")
    terminal.wait(lambda: all(" 0: " not in row for row in terminal.screen.display))
    terminal.focused(1)
    directory, writer = start_queries(sessions, terminal.child, False)
    (directory / "start").touch()
    terminal.child.expect_exact("imx: TerminalResponseOverflow")
    terminal.child.expect(pexpect.EOF)
    terminal.child.close()
    assert terminal.child.exitstatus == 1
    sessions.wait(lambda: not writer.is_running())
