import io
import signal

import pexpect
import psutil
import pyte
import pytest

from test_prompt import setup_shell


@pytest.mark.parametrize("action", ["exit", "detach", "shortcut", "kill", "terminate"])
@pytest.mark.parametrize("modes", [
    "",
    "\\033[4;12r",
    "\\033[4;12r\\033[?6h",
    "\\033[?7l\\033[4h",
    "\\033(0\\033]8;;https://example.com\\033\\\\",
    "\\033]2;unfinished",
])
def test_return_to_outer_shell_restores_display(sessions, action, modes):
    rc, _ = setup_shell(sessions, "bash")
    capture = io.StringIO()
    outer = pexpect.spawn(
        "/bin/bash", ["--noprofile", "--rcfile", str(rc), "-i"],
        env=sessions.environment, cwd=str(sessions.home), encoding="utf-8",
        dimensions=(24, 80), timeout=10,
    )
    sessions.clients.append(outer)
    outer.delaybeforesend = 0
    outer.logfile_read = capture
    outer.expect_exact("BASE:~> ")
    outer.sendline("stty -echo; stty -g > ../before; imx attach dev")
    outer.expect_exact("[dev] BASE:~> ")
    outer.sendline("stty -echo; PS1='INNER> '; PROMPT_COMMAND=")
    outer.expect_exact("INNER> ")
    if action in ("exit", "detach"):
        command = "exit" if action == "exit" else "imx detach"
        outer.sendline(f"printf '{modes}'; {command}")
    else:
        outer.sendline(f"printf '{modes}'; printf 'MODE_READY'; sleep 600")
        outer.expect_exact("MODE_READY")
        if action == "shortcut":
            outer.send("\x1b\\")
        elif action == "kill":
            sessions.run("kill", "dev")
        else:
            frontend, = psutil.Process(outer.pid).children()
            frontend.send_signal(signal.SIGTERM)
    outer.expect_exact("BASE:~> ")
    screen = pyte.Screen(80, 24)
    stream = pyte.Stream(screen)
    stream.feed(capture.getvalue())
    assert screen.cursor.y == 23
    assert screen.margins is None or screen.margins == (0, 23)
    assert screen.display[-1].startswith("BASE:~> ")

    start = len(capture.getvalue())
    outer.sendline("stty -g > ../after; seq 1 30; printf '%100s\\n' WRAP_END; printf 'q#AFTER_EXIT\\nSECOND_LINE\\n'")
    outer.expect_exact("q#AFTER_EXIT\r\nSECOND_LINE\r\n")
    outer.expect_exact("BASE:~> ")
    stream.feed(capture.getvalue()[start:])
    assert screen.cursor.y == 23
    assert screen.display[-1].startswith("BASE:~> ")
    assert any("WRAP_END" in row for row in screen.display)
    assert any("q#AFTER_EXIT" in row for row in screen.display)
    assert any("SECOND_LINE" in row for row in screen.display)
    assert (sessions.path / "before").read_text() == (sessions.path / "after").read_text()


@pytest.mark.parametrize("modes", [
    "\\033[4;12r\\033[?6h",
    "\\033[?7l\\033[4h",
    "\\033(0",
    "\\033]2;unfinished",
])
def test_switch_redraws_target_after_source_display_modes(sessions, modes):
    target = sessions.spawn("target")
    sessions.command(target, "printf '\\033[2J\\033[H\\033[1;31mTARGET_FIRST\\033[0m\\r\\nTARGET_SECOND\\r\\n'")
    target.send("\x1b\\")
    target.expect(pexpect.EOF)
    source = sessions.spawn("source")
    capture = io.StringIO()
    source.logfile_read = capture
    source.sendline(f"printf '{modes}'; imx attach target")
    source.expect_exact("TARGET_FIRST")
    source.expect_exact("IMX_PROMPT> ")
    screen = pyte.Screen(80, 24)
    pyte.Stream(screen).feed(capture.getvalue())
    assert screen.display[0].startswith("TARGET_FIRST")
    assert screen.display[1].startswith("TARGET_SECOND")
    assert screen.buffer[0][0].bold
    assert screen.buffer[0][0].fg != "default"
    assert screen.margins is None or screen.margins == (0, 23)
    assert "SESSION=target" in sessions.command(source, "printf 'SESSION=%s\\n' \"$IMX_SESSION\"")


@pytest.mark.parametrize("rows, cols", [(12, 40), (40, 120)])
def test_detach_uses_resized_terminal_dimensions(sessions, rows, cols):
    child = sessions.spawn()
    child.setwinsize(rows, cols)
    sessions.wait(lambda: f"{rows} {cols}" in sessions.command(child, "stty size"))
    capture = io.StringIO()
    child.logfile_read = capture
    sessions.command(child, "printf '\\033[3;8r\\033[?6h\\033[?7l'")
    child.send("\x1b\\")
    child.expect(pexpect.EOF)
    screen = pyte.Screen(cols, rows)
    pyte.Stream(screen).feed(capture.getvalue())
    assert screen.cursor.y == rows - 1
    assert screen.cursor.x == 0
    assert screen.margins is None or screen.margins == (0, rows - 1)
