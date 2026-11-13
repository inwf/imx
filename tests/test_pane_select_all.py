import shlex
import sys
import uuid

import pytest

from conftest import ROOT
from test_pane_copy import copy_text
from test_pane_selection import select, selected, selected_text
from test_panes import PaneTerminal
from test_prompt import configuration
from test_readonly import observe
from test_reload import reload_terminal


def show_text(terminal, text):
    content = terminal.sessions.path / f"all-text-{uuid.uuid4().hex}"
    ready = content.with_suffix(".ready")
    content.write_text(text)
    terminal.child.sendline(
        "stty -echo; printf '\\033[3J\\033[2J\\033[H'; cat -- "
        + shlex.quote(str(content))
        + "; touch -- " + shlex.quote(str(ready)) + "; sleep 600"
    )
    terminal.wait(ready.exists)


@pytest.mark.parametrize("mouse", [False, True])
@pytest.mark.parametrize("shortcut", ["\x1ba", "\x1b[97;3u", "\x1b[97;3:1u", "\x1b[27;3;97~"])
def test_select_all_is_limited_to_focused_pane_and_copies_on_request(sessions, mouse, shortcut):
    path = configuration(sessions)
    path.parent.mkdir(parents=True)
    path.write_text(f"[panes]\nmouse = {str(mouse).lower()}\n")
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    text = "    alpha 中文 beta\nsecond line"
    show_text(terminal, text)
    terminal.visible("second line")
    terminal.child.send(shortcut)
    selected(terminal, text)
    assert all(not terminal.screen.buffer[y][x].reverse for y in range(30) for x in range(50))
    assert "\x1b]52;" not in terminal.capture.getvalue()
    copy_text(terminal, text)
    terminal.child.send("\x03")
    terminal.command("printf ready", "after-select-all", "ready")
    terminal.wait(lambda: selected_text(terminal) == "")


def test_select_all_copies_history_unicode_and_wrapped_lines(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    text = "\n".join(f"history-{i:03} 中文 e\u0301 " + "0123456789" * 8 for i in range(80))
    show_text(terminal, text)
    terminal.visible("history-079")
    terminal.child.send("\x1ba")
    terminal.wait(lambda: "history-079" in selected_text(terminal))
    copy_text(terminal, text)


@pytest.mark.parametrize("zoom", [False, True])
def test_select_all_replaces_mouse_selection_and_preserves_zoom(sessions, mouse_mode, zoom):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    show_text(terminal, "alpha beta")
    terminal.visible("alpha beta")
    select(terminal, (52, 2), (57, 2), release=False)
    selected(terminal, "alpha")
    if zoom:
        terminal.child.send("\x1bz")
        terminal.visible("[zoom]")
    terminal.child.send("\x1ba")
    selected(terminal, "alpha beta")
    terminal.child.send("\x1b[<32;59;2M\x1b[<0;59;2m")
    copy_text(terminal, "alpha beta")
    assert ("[zoom]" in terminal.screen.display[0]) == zoom


@pytest.mark.parametrize("mode", ["legacy", "kitty", "modify"])
def test_select_all_uses_application_screen_and_preserves_paste(sessions, mode):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    destination = sessions.path / "all-input.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), mode]))
    terminal.wait(destination.exists)
    terminal.visible("PANE_APPLICATION")
    terminal.child.send("\x1ba")
    selected(terminal, "PANE_APPLICATION")
    terminal.child.send("\x1b[97;3:3u")
    copy_text(terminal, "PANE_APPLICATION")
    assert destination.read_bytes() == b""
    paste = "\x1b[200~\x1ba\x1b[97;3u\x1b[201~"
    terminal.child.send(paste)
    terminal.wait(lambda: destination.read_bytes() == paste.encode())
    terminal.wait(lambda: selected_text(terminal) == "")


@pytest.mark.parametrize("binding,shortcut", [
    ("{ key = 's', alt = true }", "\x1bs"),
    ("{ key = 'a', super = true }", "\x1b[97;9u"),
    ("{ key = 'Escape' }", "\x1b"),
])
def test_select_all_binding_updates_with_reload(sessions, binding, shortcut):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    configuration(sessions).write_text(f"[keybindings]\nselect_all = {binding}\n")
    reload_terminal(terminal)
    show_text(terminal, "reloaded selection")
    terminal.visible("reloaded selection")
    terminal.child.send(shortcut)
    selected(terminal, "reloaded selection")
    copy_text(terminal, "reloaded selection")


@pytest.mark.parametrize("split", [False, True])
@pytest.mark.parametrize("binding,shortcut", [
    ("{ key = 'a', alt = true }", "\x1ba"),
    ("{ key = 'F6' }", "\x1b[17~"),
    ("{ key = 'Escape' }", "\x1b"),
])
def test_readonly_select_all_copies_source_history_without_footer_or_input(sessions, split, binding, shortcut):
    path = configuration(sessions)
    path.parent.mkdir(parents=True)
    path.write_text(f"[keybindings]\nselect_all = {binding}\n")
    writer = PaneTerminal(sessions)
    text = "\n".join(f"read-history-{i:03} " + "abcdef" * 20 for i in range(80))
    show_text(writer, text)
    observer = observe(sessions, rows=30, cols=100)
    observer.visible("read-history-079")
    if split:
        observer.split()
        observer.visible("1: shell")
        observer.focus(0)
    observer.child.send(shortcut)
    observer.wait(lambda: observer.screen.buffer[1][1].reverse)
    assert "\x1b]52;" not in observer.capture.getvalue()
    copy_text(observer, text)
    writer.child.send("\x03")
    writer.command("stty size", "source-size-after-selection", "28 98\n")


def test_select_all_rejects_binding_conflicts(sessions):
    path = configuration(sessions)
    path.parent.mkdir(parents=True)
    path.write_text("[keybindings]\nselect_all = { key = 'c', alt = true }\n")
    try:
        result = sessions.run("list", check=False)
        assert result.returncode == 1
        assert "DuplicateKeybinding" in result.stderr
        assert "keybindings.select_all" in result.stderr and "keybindings.copy_selection" in result.stderr
    finally:
        path.write_text("")


def test_select_all_empty_pane_preserves_clipboard(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    show_text(terminal, "")
    terminal.wait(lambda: all(not row[51:99].strip() for row in terminal.screen.display[1:29]))
    terminal.child.send("\x1ba\x1bc\x03")
    terminal.command("printf ready", "after-empty-selection", "ready")
    assert "\x1b]52;" not in terminal.capture.getvalue()
