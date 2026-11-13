import pexpect
import pytest

from test_panes import PaneTerminal
from test_prompt import settings, setup_shell


@pytest.mark.parametrize("length", [77, 78, 79, 156, 157])
def test_attach_preserves_prompts_at_inner_column_boundary(sessions, length):
    path, _ = setup_shell(sessions, "bash")
    settings(sessions, False)
    prompt = "p" * (length - 2) + "$ "
    path.write_text(f"PS1='{prompt}'\n")
    child = sessions.spawn(initialize=False)
    child.expect_prompt()
    child.expect_prompt(prompt)
    terminal = PaneTerminal(sessions, child=child)
    terminal.command("printf ready", "long-prompt-command", "ready")
    child.send("\x1b\\")
    child.expect(pexpect.EOF)


@pytest.mark.parametrize("rows, cols", [(24, 80), (30, 100), (5, 12)])
def test_attach_displays_single_frame_and_uses_inner_size(sessions, rows, cols):
    child = sessions.spawn(initialize=False, rows=rows, cols=cols)
    terminal = PaneTerminal(sessions, child=child)
    terminal.screen.resize(rows, cols)
    terminal.visible("0: dev")
    terminal.command("stty size", "initial-size", f"{rows - 2} {cols - 2}\n")
    terminal.wait(lambda: terminal.screen.display[0][0] == "┌"
                  and terminal.screen.display[0][-1] == "┐"
                  and terminal.screen.display[-1][0] == "└"
                  and terminal.screen.display[-1][-1] == "┘")
    assert terminal.screen.buffer[0][3].fg == "969cd5"
    child.send("\x1b\\")
    child.expect(pexpect.EOF)
    child.close()
    assert child.exitstatus == 0
    assert sessions.sessions()[0]["CLIENTS"] == "0"


def test_attach_frame_resizes_splits_and_restores_history(sessions):
    child = sessions.spawn(initialize=False)
    terminal = PaneTerminal(sessions, child=child)
    terminal.screen.resize(24, 80)
    terminal.visible("0: dev")
    terminal.command("stty size", "before-resize", "22 78\n")
    terminal.screen.resize(30, 100)
    child.setwinsize(30, 100)
    terminal.wait(lambda: terminal.screen.display[0][-1] == "┐")
    terminal.command("stty size", "after-resize", "28 98\n")
    terminal.split()
    terminal.visible("1: shell")
    terminal.command("stty size", "split-size", "28 48\n")
    terminal.focus(0)
    terminal.child.sendline("printf 'RESTORED_FRAME_HISTORY\\n'")
    terminal.visible("RESTORED_FRAME_HISTORY")
    terminal.child.send("\x1b\\")
    terminal.visible("0: shell")
    restored = PaneTerminal(sessions, child=sessions.spawn(initialize=False))
    restored.screen.resize(24, 80)
    restored.visible("0: dev")
    restored.visible("RESTORED_FRAME_HISTORY")
    restored.child.send("\x1b\\")
    restored.child.expect(pexpect.EOF)
