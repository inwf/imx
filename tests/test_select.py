import os
import shlex
import signal
import sys
import termios
import time

import pexpect
import psutil
import pyte
import pytest

from conftest import ROOT
from preview_client import PreviewClient
from test_panes import PaneTerminal


def selector(sessions, rows=30, cols=100):
    child = pexpect.spawn(
        str(sessions.binary), ["select"], cwd=str(sessions.path),
        env=sessions.environment, dimensions=(rows, cols), encoding="utf-8", timeout=10,
    )
    child.delaybeforesend = 0
    sessions.clients.append(child)
    terminal = PaneTerminal(sessions, child=child)
    terminal.screen.resize(rows, cols)
    return terminal


def shown(terminal, text):
    return any(text in row for row in terminal.screen.display)


def test_preview_clients_keep_independent_updates(sessions):
    session = sessions.spawn("dev", rows=30, cols=100)
    sessions.command(session, "printf '\\033[2J\\033[H'; printf 'STABLE 中文 %060d\\n' {1..15}")
    with PreviewClient(sessions, "dev", 25, 80) as first, PreviewClient(sessions, "dev", 20, 60) as second:
        screens = [pyte.Screen(80, 25), pyte.Screen(60, 20)]
        streams = [pyte.Stream(screen) for screen in screens]
        initial = first.frame()
        streams[0].feed(initial.decode())
        streams[1].feed(second.frame().decode())
        sessions.command(session, "printf '\\033[5;1H\\033[32mCHANGED_A\\033[0m\\033[K'")
        delta = first.frame()
        assert len(delta) < len(initial) // 2
        streams[0].feed(delta.decode())
        sessions.command(session, "printf '\\033[6;1HCHANGED_B\\033[K'")
        streams[0].feed(first.frame().decode())
        streams[1].feed(second.frame().decode())
        for screen in screens:
            assert any("CHANGED_A" in row for row in screen.display)
            assert any("CHANGED_B" in row for row in screen.display)
            assert any("STABLE 中文" in row for row in screen.display)
            assert screen.buffer[4][0].fg == "00cd00"
        assert sessions.sessions()[0]["CLIENTS"] == "1"


def cancel(terminal, key="q"):
    terminal.child.send(key)
    terminal.child.expect(pexpect.EOF)
    terminal.child.close()
    assert terminal.child.exitstatus == 0


@pytest.mark.parametrize("key", ["q", "\x1b", "\x03"])
def test_select_cancel_preserves_session_and_terminal_modes(sessions, key):
    session = sessions.spawn("alpha")
    sessions.command(session, "printf '\\033[2J\\033[HALPHA_CONTENT\\n'")
    before = sessions.sessions()
    terminal = selector(sessions)
    terminal.visible("ALPHA_CONTENT")
    assert sessions.sessions() == before
    terminal.child.send(key)
    terminal.child.expect(pexpect.EOF)
    attributes = termios.tcgetattr(terminal.child.child_fd)
    assert attributes[3] & termios.ICANON
    assert attributes[3] & termios.ECHO
    assert "\x1b[?1049l" in terminal.child.before
    terminal.child.close()
    assert terminal.child.exitstatus == 0
    assert sessions.sessions() == before


@pytest.mark.parametrize("down, up, confirm", [
    ("j", "k", "\r"),
    ("\x1b[B", "\x1b[A", " "),
    ("\x1bOB", "\x1bOA", "\x1b[13u"),
])
def test_select_navigation_preview_and_attach(sessions, down, up, confirm):
    alpha = sessions.spawn("alpha")
    beta = sessions.spawn("beta")
    sessions.command(alpha, "printf '\\033[2J\\033[HALPHA_SCREEN\\n'")
    sessions.command(beta, "printf '\\033[2J\\033[H\\033[31m中文 Beta\\033[0m\\n'")
    terminal = selector(sessions)
    terminal.visible("ALPHA_SCREEN")
    terminal.child.send(down)
    terminal.visible("中文 Beta")
    assert not shown(terminal, "ALPHA_SCREEN")
    assert any(cell.fg == "red" for row in terminal.screen.buffer.values() for cell in row.values())
    terminal.child.send(up)
    terminal.visible("ALPHA_SCREEN")
    terminal.child.send(down)
    terminal.visible("中文 Beta")
    terminal.child.send(confirm)
    terminal.child.expect_exact("IMX_PROMPT> ")
    assert "beta" in sessions.command(terminal.child, "printf '%s\\n' \"$IMX_SESSION\"")
    terminal.child.send("\x1b\\")
    terminal.child.expect(pexpect.EOF)


def test_select_live_preview_keeps_size_clients_and_history(sessions):
    session = sessions.spawn("dev", rows=40, cols=120)
    sessions.command(session, "printf 'HISTORY_ONLY\\n'; printf '\\n%.0s' {1..100}; printf '\\033[2J\\033[HINITIAL_VIEW\\n'")
    terminal = selector(sessions)
    terminal.visible("INITIAL_VIEW")
    assert not shown(terminal, "HISTORY_ONLY")
    assert sessions.sessions()[0]["CLIENTS"] == "1"
    assert "40 120" in sessions.command(session, "stty size")
    sessions.command(session, "printf '\\033[2J\\033[HCHANGED_VIEW\\n'")
    terminal.visible("CHANGED_VIEW")
    assert not shown(terminal, "INITIAL_VIEW")
    terminal.child.setwinsize(16, 60)
    terminal.screen.resize(16, 60)
    terminal.visible("Enter/Space")
    sessions.command(session, "printf '\\033[2J\\033[HAFTER_RESIZE\\n'")
    terminal.visible("AFTER_RESIZE")
    assert "40 120" in sessions.command(session, "stty size")
    assert "HISTORY_ONLY" in sessions.run("cat", "dev").stdout
    cancel(terminal)


def test_select_previews_vim_updates_without_sending_input(sessions):
    document = sessions.path / "document.txt"
    document.write_text("VIM_PREVIEW\n中文文档\n")
    session = sessions.spawn("editor")
    session.sendline("vim -u NONE -i NONE -n document.txt")
    session.expect_exact("VIM_PREVIEW")
    terminal = selector(sessions)
    terminal.visible("VIM_PREVIEW")
    terminal.visible("中文文档")
    session.send("ggIUPDATED_\x1b")
    terminal.visible("UPDATED_VIM_PREVIEW")
    terminal.child.send("jkk")
    cancel(terminal)
    session.send(":wq\r")
    session.expect_exact("IMX_PROMPT> ")
    assert document.read_text() == "UPDATED_VIM_PREVIEW\n中文文档\n"


def test_select_inside_session_switches_current_connection(sessions):
    alpha = sessions.spawn("alpha")
    beta = sessions.spawn("beta")
    sessions.command(beta, "printf '\\033[2J\\033[HTARGET_BETA\\n'")
    alpha.sendline("imx select")
    terminal = PaneTerminal(sessions, child=alpha)
    terminal.visible("Sessions")
    alpha.send("j")
    terminal.visible("TARGET_BETA")
    alpha.send(" ")
    alpha.expect_exact("IMX_PROMPT> ")
    assert "beta" in sessions.command(alpha, "printf '%s\\n' \"$IMX_SESSION\"")
    sessions.wait(lambda: {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == {"alpha": "0", "beta": "2"})


@pytest.mark.parametrize("confirm", ["q", "\r"])
def test_select_current_session_preserves_screen_and_stays_idle(sessions, confirm):
    alpha = sessions.spawn("alpha", rows=30, cols=100)
    sessions.command(alpha, "printf '\\033[2J\\033[HORIGINAL_SCREEN\\n'")
    alpha.sendline("imx select")
    terminal = PaneTerminal(sessions, child=alpha)
    terminal.visible("ORIGINAL_SCREEN")
    terminal.visible("Enter/Space")
    for _ in range(10):
        terminal.pump()
    assert sum("ORIGINAL_SCREEN" in row for row in terminal.screen.display) == 1
    assert sum("Enter/Space" in row for row in terminal.screen.display) == 1
    length = len(terminal.capture.getvalue())
    time.sleep(0.4)
    terminal.pump()
    assert len(terminal.capture.getvalue()) == length
    alpha.send(confirm)
    alpha.expect_exact("IMX_PROMPT> ")
    assert "alpha" in sessions.command(alpha, "printf '%s\\n' \"$IMX_SESSION\"")
    assert "ORIGINAL_SCREEN" in sessions.run("cat", "alpha").stdout
    assert sessions.sessions()[0]["CLIENTS"] == "1"


def test_select_in_plain_pane_attaches_to_that_pane(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    terminal.child.sendline("imx select")
    terminal.visible("Enter/Space")
    terminal.child.send("\r")
    terminal.visible("2: dev")
    terminal.command("printf '%s' \"$IMX_SESSION\"", "selected-session", "dev")
    assert sessions.sessions()[0]["CLIENTS"] == "2"


def test_select_paste_does_not_execute_selection_keys(sessions):
    sessions.spawn("alpha")
    sessions.spawn("beta")
    terminal = selector(sessions)
    terminal.visible("> alpha")
    terminal.child.send("\x1b[200~j\r q\x1b[201~")
    for _ in range(10):
        terminal.pump()
    assert shown(terminal, "> alpha")
    assert terminal.child.isalive()
    cancel(terminal)


@pytest.mark.parametrize("signum", [signal.SIGTERM, signal.SIGHUP, signal.SIGINT])
def test_select_signal_restores_terminal(sessions, signum):
    sessions.spawn("alpha")
    terminal = selector(sessions)
    terminal.visible("Enter/Space")
    os.kill(terminal.child.pid, signum)
    terminal.child.expect(pexpect.EOF)
    attributes = termios.tcgetattr(terminal.child.child_fd)
    assert attributes[3] & termios.ICANON
    assert attributes[3] & termios.ECHO
    assert "\x1b[?1049l" in terminal.child.before
    terminal.child.close()
    assert terminal.child.exitstatus == 0
    assert sessions.sessions()[0]["CLIENTS"] == "1"


def test_select_tracks_new_and_removed_sessions(sessions):
    alpha = sessions.spawn("alpha")
    sessions.command(alpha, "printf '\\033[2J\\033[HALPHA_VIEW\\n'")
    terminal = selector(sessions)
    terminal.visible("ALPHA_VIEW")
    beta = sessions.spawn("beta")
    sessions.command(beta, "printf '\\033[2J\\033[HBETA_VIEW\\n'")
    terminal.visible("  beta")
    terminal.child.send("j")
    terminal.visible("BETA_VIEW")
    sessions.run("kill", "beta")
    terminal.visible("ALPHA_VIEW")
    terminal.wait(lambda: not shown(terminal, "beta"))
    sessions.run("kill", "alpha")
    terminal.visible("No sessions.")
    terminal.child.send("\r ")
    terminal.visible("No sessions.")
    gamma = sessions.spawn("gamma")
    sessions.command(gamma, "printf '\\033[2J\\033[HGAMMA_VIEW\\n'")
    terminal.visible("GAMMA_VIEW")
    cancel(terminal)


def test_select_unresponsive_backend_does_not_block_navigation(sessions):
    sessions.spawn("alpha")
    beta = sessions.spawn("beta")
    sessions.command(beta, "printf '\\033[2J\\033[HRESPONSIVE_BETA\\n'")
    pid = int(sessions.sessions()[0]["PID"])
    backend = psutil.Process(pid).ppid()
    os.kill(backend, signal.SIGSTOP)
    try:
        terminal = selector(sessions)
        terminal.visible("Preview is not responding.")
        started = time.monotonic()
        terminal.child.send("j")
        terminal.visible("RESPONSIVE_BETA")
        assert time.monotonic() - started < 2
        cancel(terminal)
    finally:
        os.kill(backend, signal.SIGCONT)


def test_select_idle_uses_no_repeated_frames_or_polling(sessions):
    session = sessions.spawn("dev")
    sessions.command(session, "printf '\\033[2J\\033[HIDLE_VIEW\\n'")
    terminal = selector(sessions)
    terminal.visible("IDLE_VIEW")
    process = psutil.Process(terminal.child.pid)
    for _ in range(10):
        terminal.pump()
    before = process.cpu_times()
    switches = process.num_ctx_switches().voluntary
    length = len(terminal.capture.getvalue())
    time.sleep(0.5)
    terminal.pump()
    after = process.cpu_times()
    assert after.user + after.system - before.user - before.system < 0.05
    assert process.num_ctx_switches().voluntary - switches <= 2
    assert len(terminal.capture.getvalue()) == length
    cancel(terminal)


def test_select_continuous_output_limits_frames_and_memory(sessions, record_property):
    session = sessions.spawn("alpha", rows=40, cols=120)
    beta = sessions.spawn("beta")
    sessions.command(beta, "printf '\\033[2J\\033[HQUIET_BETA\\n'")
    session.sendline(f"{shlex.quote(sys.executable)} {shlex.quote(str(ROOT / 'tests/select_output.py'))}")
    session.expect_exact("FRAME_")
    session.send("\x1b\\")
    session.expect(pexpect.EOF)
    terminal = selector(sessions)
    terminal.visible("FRAME_")
    process = psutil.Process(terminal.child.pid)
    before_cpu = process.cpu_times()
    offset = len(terminal.capture.getvalue())
    started = time.monotonic()
    while time.monotonic() - started < 1.2:
        terminal.pump()
    elapsed = time.monotonic() - started
    frames = terminal.capture.getvalue()[offset:].count("\x1b[?2026h")
    after_cpu = process.cpu_times()
    cpu_seconds = after_cpu.user + after_cpu.system - before_cpu.user - before_cpu.system
    assert 2 <= frames <= int(elapsed * 10) + 1
    assert cpu_seconds < elapsed * 0.2
    record_property("preview_frames_per_second", frames / elapsed)
    record_property("selector_cpu_seconds", cpu_seconds)
    before_memory = process.memory_info().rss
    time.sleep(1.2)
    assert process.memory_info().rss - before_memory < 4 * 1024 * 1024
    started = time.monotonic()
    terminal.child.send("j")
    terminal.visible("QUIET_BETA")
    assert time.monotonic() - started < 2
    assert {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == {"alpha": "0", "beta": "1"}
    cancel(terminal)


def test_select_large_rgb_frame_is_fully_delivered(sessions):
    session = sessions.spawn("colors", rows=160, cols=320)
    sessions.command(session, f"{shlex.quote(sys.executable)} {shlex.quote(str(ROOT / 'tests/select_output.py'))} --colors")
    terminal = selector(sessions, rows=160, cols=320)
    terminal.child.expect_exact("COLOR_GRID")
    terminal.child.expect_exact("\x1b[?2026l")
    frame = terminal.child.before
    assert len(frame) > 256 * 1024
    assert "\x1b[38:2:20:10:30mX" in frame
    assert "\x1b[38:2:61:154:215mX" in frame
    cancel(terminal)


def test_select_empty_and_noninteractive(sessions):
    result = sessions.run("select", check=False)
    assert result.returncode == 1
    assert "TerminalRequired" in result.stderr
    assert not sessions.runtime.exists()
    child = selector(sessions).child
    child.expect_exact("No sessions.")
    child.expect(pexpect.EOF)
    child.close()
    assert child.exitstatus == 0
    assert not sessions.runtime.exists()


def test_select_scrolls_long_lists_and_handles_small_terminals(sessions):
    for number in range(12):
        session = sessions.spawn(f"session-{number:02}")
        sessions.command(session, f"printf '\\033[2J\\033[HCONTENT_{number:02}\\n'")
    terminal = selector(sessions, rows=16, cols=60)
    terminal.visible("CONTENT_00")
    terminal.child.send("j" * 20)
    terminal.visible("CONTENT_11")
    terminal.visible("> session-11")
    terminal.child.setwinsize(4, 12)
    terminal.screen.resize(4, 12)
    terminal.child.send("k" * 20)
    terminal.child.setwinsize(16, 60)
    terminal.screen.resize(16, 60)
    terminal.visible("CONTENT_00")
    cancel(terminal)
