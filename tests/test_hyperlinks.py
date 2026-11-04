import shlex

import pytest

from test_panes import PaneTerminal
from test_select import cancel, selector


URL = "https://example.com/imx-link"


def print_link(terminal, label, ending):
    terminal.command("stty -echo; printf ready", f"{label}-ready", "ready")
    terminal.pump()
    offset = len(terminal.capture.getvalue())
    sequence = rf"\033[2J\033[H\033]8;id=sample;{URL}{ending}%s\033]8;;{ending}\n"
    terminal.child.sendline(shlex.join(["printf", sequence, label]))
    terminal.visible(label)
    terminal.wait(lambda: URL in terminal.capture.getvalue()[offset:])
    return offset


@pytest.mark.parametrize("ending", [r"\007", r"\033\\"])
@pytest.mark.parametrize("layout", ["single", "shell", "attached", "zoom"])
def test_hyperlinks_reach_terminal_in_all_pane_layouts(sessions, ending, layout):
    terminal = PaneTerminal(sessions)
    if layout != "single":
        terminal.split()
        terminal.visible("1: shell")
        if layout in {"attached", "zoom"}:
            terminal.focus(0)
        if layout == "zoom":
            terminal.child.send("\x1bz")
            terminal.visible("[zoom]")
    print_link(terminal, "LINK_VISIBLE", ending)
    if layout != "single":
        offset = len(terminal.capture.getvalue())
        terminal.screen.resize(lines=32, columns=110)
        terminal.child.setwinsize(32, 110)
        terminal.wait(lambda: URL in terminal.capture.getvalue()[offset:])


def test_hyperlinks_survive_preview_and_reattach(sessions):
    terminal = PaneTerminal(sessions)
    print_link(terminal, "LINK_RESTORED", r"\007")
    terminal.child.send("\x1b\\")
    terminal.child.expect_exact("\x1b[?1049l")
    preview = selector(sessions)
    preview.visible("LINK_RESTORED")
    assert URL in preview.capture.getvalue()
    cancel(preview)
    restored = PaneTerminal(sessions, initialize=False)
    restored.split()
    restored.visible("1: shell")
    assert URL in restored.capture.getvalue()
