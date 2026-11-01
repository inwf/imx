import os
import shlex
import sys
import time

import pytest

from conftest import ROOT
from test_panes import PaneTerminal


@pytest.mark.parametrize("mode", ["legacy", "kitty", "modify"])
@pytest.mark.parametrize("layout", ["single", "shell", "attached", "initial"])
def test_unicode_input_reaches_application_unchanged(sessions, mode, layout):
    terminal = PaneTerminal(sessions)
    if layout != "single":
        terminal.split()
        terminal.visible("2: shell")
        if layout == "attached":
            terminal.child.sendline("imx attach test")
            terminal.visible("2: test")
        elif layout == "initial":
            terminal.focus(1)
    destination = sessions.path / "unicode-input.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), mode]))
    terminal.wait(destination.exists)
    text = "中文输入测试你好世界é界👩‍🚀"
    expected = ("".join(f"\x1b[{ord(char)};;{ord(char)}u" for char in text) if layout != "single" and mode == "kitty" else text).encode()
    terminal.child.send(text)
    terminal.wait(lambda: len(destination.read_bytes()) >= len(expected))
    assert destination.read_bytes() == expected


@pytest.mark.parametrize("shell", ["/bin/bash", "/usr/bin/zsh", "/usr/bin/fish"])
def test_chinese_input_and_enter_in_pane_shell(sessions, shell):
    sessions.environment.update(SHELL=shell, LANG="C.UTF-8", LC_ALL="C.UTF-8")
    terminal = PaneTerminal(sessions, initialize=False)
    terminal.split()
    terminal.visible("2: shell")
    terminal.command("printf '%s' '中文输入已经确认'", "chinese-enter", "中文输入已经确认")


def test_unicode_input_across_byte_boundaries(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    destination = sessions.path / "unicode-fragments.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), "legacy"]))
    terminal.wait(destination.exists)
    expected = "中文é👩".encode()
    for value in expected:
        os.write(terminal.child.child_fd, bytes([value]))
        time.sleep(0.01)
    terminal.wait(lambda: len(destination.read_bytes()) >= len(expected))
    assert destination.read_bytes() == expected


def test_shell_panes_keep_ime_text_reporting(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    assert "\x1b[>5u" in terminal.capture.getvalue()
    assert "\x1b[>31u" not in terminal.capture.getvalue()
    terminal.command("printf '%s' '中文输入已经确认'", "ime-text", "中文输入已经确认")


def test_keyboard_reporting_follows_focused_application(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    destination = sessions.path / "keyboard-modes.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), "kitty"]))
    terminal.wait(destination.exists)
    terminal.wait(lambda: "\x1b[=31u" in terminal.capture.getvalue())
    offset = len(terminal.capture.getvalue())
    terminal.focus(1)
    terminal.wait(lambda: "\x1b[=5u" in terminal.capture.getvalue()[offset:])
    terminal.command("printf '%s' '中文确认'", "ime-focused-shell", "中文确认")
    offset = len(terminal.capture.getvalue())
    terminal.focus(2)
    terminal.wait(lambda: "\x1b[=31u" in terminal.capture.getvalue()[offset:])
    terminal.child.send("\x1b[97;5:3u")
    terminal.wait(lambda: destination.read_bytes() == b"\x1b[97;5:3u")


@pytest.mark.parametrize("encoding", ["kitty", "kitty_text", "modify", "ime_enter", "ime_text"])
@pytest.mark.parametrize("modifiers", [1, 2, 65, 129])
def test_chinese_keyboard_protocols_preserve_committed_text(sessions, encoding, modifiers):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("2: shell")
    destination = sessions.path / "unicode-protocol.bin"
    terminal.child.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), "legacy"]))
    terminal.wait(destination.exists)
    text = "中文输入已经确认"
    if encoding in {"ime_enter", "ime_text"}:
        key = 13 if encoding == "ime_enter" else 0
        sequence = f"\x1b[{key};{modifiers};" + ":".join(str(ord(char)) for char in text) + "u"
    else:
        template = {"kitty": "\x1b[{0};{1}u", "kitty_text": "\x1b[{0};{1};{0}u", "modify": "\x1b[27;{1};{0}~"}[encoding]
        sequence = "".join(template.format(ord(char), modifiers) for char in text)
    terminal.child.send(sequence)
    terminal.wait(lambda: len(destination.read_bytes()) >= len(text.encode()))
    assert destination.read_bytes() == text.encode()
