import base64
import shlex
import sys

import pytest

from conftest import ROOT
from test_pane_selection import select, selected, selected_text, text_terminal
from test_panes import PaneTerminal


pytestmark = pytest.mark.usefixtures("mouse_mode")


def copy_text(terminal, expected, shortcut="\x1bc"):
    offset = len(terminal.capture.getvalue())
    highlighted = selected_text(terminal)
    payload = base64.b64encode(expected.encode()).decode()
    sequence = f"\x1b]52;c;{payload}\x1b\\"
    terminal.child.send(shortcut)
    terminal.wait(lambda: sequence in terminal.capture.getvalue()[offset:])
    assert terminal.capture.getvalue()[offset:].count("\x1b]52;") == 1
    assert selected_text(terminal) == highlighted


@pytest.mark.parametrize("text,start,end,highlighted,copied", [
    ("alpha 中文 beta\nsecond line", (2, 2), (7, 2), "alpha", "alpha"),
    ("alpha 中文 beta\nsecond line", (7, 2), (2, 2), "alpha", "alpha"),
    ("alpha 中文 beta\nsecond line", (9, 2), (12, 2), "中文", "中文"),
    ("alpha 中文 beta\nsecond line", (2, 2), (8, 3), "alpha 中文 beta\nsecond", "alpha 中文 beta\nsecond"),
    ("0123456789" * 7, (2, 2), (24, 3), "0123456789" * 4 + "01234567\n8901234567890123456789", "0123456789" * 7),
    ("e\u0301lan", (2, 2), (6, 2), "e\u0301lan", "e\u0301lan"),
    ("\x1b[31mcolored\x1b[0m", (2, 2), (9, 2), "colored", "colored"),
    ("\x1b]8;;https://example.com\x07link\x1b]8;;\x07", (2, 2), (6, 2), "link", "link"),
    ("    alpha\n\n  beta", (2, 2), (8, 4), "    alpha\n\n  beta", "    alpha\n\n  beta"),
])
def test_copy_selection_preserves_text_and_highlight(sessions, text, start, end, highlighted, copied):
    terminal = text_terminal(sessions, text)
    select(terminal, start, end)
    selected(terminal, highlighted)
    assert "\x1b]52;" not in terminal.capture.getvalue()
    copy_text(terminal, copied)
    copy_text(terminal, copied)


@pytest.mark.parametrize("shortcut", ["\x1b[99;3u", "\x1b[99;3:1u", "\x1b[27;3;99~"])
def test_copy_shortcut_supports_terminal_encodings(sessions, shortcut):
    terminal = text_terminal(sessions)
    select(terminal, (2, 2), (7, 2))
    selected(terminal, "alpha")
    copy_text(terminal, "alpha", shortcut)


@pytest.mark.parametrize("binding,shortcut", [
    ("{ key = 'y', alt = true }", "\x1by"),
    ("{ key = 'c', super = true }", "\x1b[99;9u"),
    ("{ key = 'Escape' }", "\x1b"),
])
def test_copy_shortcut_is_configurable(sessions, binding, shortcut):
    configuration = sessions.home / ".config/imx/config.toml"
    configuration.write_text(f"[panes]\nmouse = true\n[keybindings]\ncopy_selection = {binding}\n")
    terminal = text_terminal(sessions)
    select(terminal, (2, 2), (7, 2))
    selected(terminal, "alpha")
    copy_text(terminal, "alpha", shortcut)


def test_copy_shortcut_requires_selection_in_focused_pane(sessions):
    terminal = text_terminal(sessions)
    select(terminal, (2, 2), (7, 2))
    selected(terminal, "alpha")
    terminal.focus(1)
    terminal.child.send("\x1bc")
    terminal.command("printf ready", "empty-selection", "ready")
    assert "\x1b]52;" not in terminal.capture.getvalue()
    terminal.focus(0)
    copy_text(terminal, "alpha")


def test_copy_double_and_triple_click_selections(sessions):
    terminal = text_terminal(sessions)
    terminal.click(3, 2)
    terminal.click(3, 2)
    selected(terminal, "alpha")
    assert "\x1b]52;" not in terminal.capture.getvalue()
    copy_text(terminal, "alpha")
    count = terminal.capture.getvalue().count("\x1b]52;")
    terminal.click(3, 2)
    selected(terminal, "alpha 中文 beta")
    assert terminal.capture.getvalue().count("\x1b]52;") == count
    copy_text(terminal, "alpha 中文 beta")


def test_copy_retained_history(sessions):
    terminal = PaneTerminal(sessions)
    sessions.command(terminal.child, "printf '\\033[3J\\033[2J\\033[H'; printf 'HISTORY-%03d\\n' {0..100}")
    terminal.split()
    terminal.visible("1: shell")
    terminal.child.send("\x1b[<64;5;5M" * 100)
    terminal.wait(lambda: "HISTORY-000" in terminal.screen.display[1])
    select(terminal, (2, 2), (13, 4))
    expected = "HISTORY-000\nHISTORY-001\nHISTORY-002"
    selected(terminal, expected)
    assert "\x1b]52;" not in terminal.capture.getvalue()
    copy_text(terminal, expected)


def test_copy_in_mouse_application_keeps_keys_and_paste_separate(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    destination = sessions.path / "copy-input.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), "legacy"]))
    terminal.wait(destination.exists)
    terminal.visible("PANE_APPLICATION")
    select(terminal, (52, 2), (68, 2), modifiers=4)
    selected(terminal, "PANE_APPLICATION")
    terminal.child.send("\x1b[99;3:3u")
    copy_text(terminal, "PANE_APPLICATION")
    assert destination.read_bytes() == b""
    count = terminal.capture.getvalue().count("\x1b]52;")
    paste = "\x1b[200~\x1bc\x1b[99;3u\x1b[201~"
    terminal.child.send(paste)
    terminal.wait(lambda: destination.read_bytes() == paste.encode())
    assert terminal.capture.getvalue().count("\x1b]52;") == count


def test_copy_binding_conflicts_are_reported(sessions):
    configuration = sessions.home / ".config/imx/config.toml"
    configuration.write_text("[keybindings]\ncopy_selection = { key = 'd', alt = true }\n")
    result = sessions.run("list", check=False)
    assert result.returncode == 1
    assert "keybindings.copy_selection" in result.stderr
    assert "keybindings.split_right" in result.stderr
    configuration.write_text("[panes]\nmouse = true\n")
