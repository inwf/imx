import json
import os
import time

import pexpect
import pytest

from test_prompt import configuration


def set_detach_binding(sessions, key, **modifiers):
    path = configuration(sessions)
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = [f"key = {json.dumps(key, ensure_ascii=False)}"]
    fields.extend(f"{name} = {str(enabled).lower()}" for name, enabled in modifiers.items())
    path.write_text("[keybindings]\ndetach = { " + ", ".join(fields) + " }\n")
    return path


def input_reader(sessions):
    child = sessions.spawn()
    child.sendline("stty raw -echo; printf '\\033[>5u\\033[>4;2mINPUT_READY'; cat > input.bin")
    child.expect_exact("INPUT_READY")
    path = sessions.path / "input.bin"
    sessions.wait(path.exists)
    return child, path


@pytest.mark.parametrize("sequence", [
    "\x1b\\",
    "\x1b[92;3u",
    "\x1b[92;3:1u",
    "\x1b[92;3:2u",
    "\x1b[92;67u",
    "\x1b[92;131u",
    "\x1b[92;195u",
    "\x1b[92:124;3u",
    "\x1b[92::92;3u",
    "\x1b[92:124:92;67:1u",
    "\x1b[92;3;92u",
    "\x1b[92;3;92:92u",
    "\x1b[27;3;92~",
    "\x1b[27;67;92~",
    "\x1b[27;131;92~",
    "\x1b[27;195;92~",
])
def test_keyboard_detach_keeps_application_and_other_clients(sessions, sequence):
    child, path = input_reader(sessions)
    observer = sessions.spawn(initialize=False)
    observer.expect_exact("INPUT_READY")
    original_pid = sessions.sessions()[0]["PID"]
    child.send("before" + sequence + "discarded")
    child.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "1")
    sessions.wait(lambda: path.read_bytes() == b"before")
    assert observer.isalive()
    assert sessions.sessions()[0]["PID"] == original_pid
    attached = sessions.spawn(initialize=False)
    attached.expect_exact("INPUT_READY")
    attached.send("after")
    sessions.wait(lambda: path.read_bytes() == b"beforeafter")


@pytest.mark.parametrize("sequence", ["\x1b\\", "\x1b[92;3u", "\x1b[92:124:92;67:1u", "\x1b[27;3;92~"])
def test_keyboard_detach_across_every_read_boundary(sessions, sequence):
    child, path = input_reader(sessions)
    for split in range(1, len(sequence)):
        child.send("before" + sequence[:split])
        sessions.wait(lambda: path.read_bytes() == b"before" * split)
        time.sleep(0.01)
        child.send(sequence[split:])
        child.expect(pexpect.EOF)
        sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
        assert path.read_bytes() == b"before" * split
        child = sessions.spawn(initialize=False)
        child.expect_exact("INPUT_READY")


@pytest.mark.parametrize("sequence", [
    "\x1c",
    "\x1b[92;5u",
    "\x1b[27;5;92~",
    "\x1b[92;3:3u",
    "\x1b[92;67:3u",
    "\x1b[92;1u",
    "\x1b[92;6u",
    "\x1b[92;7u",
    "\x1b[92;13u",
    "\x1b[91;5u",
    "\x1b[93;5u",
    "\x1b[27;6;92~",
    "\x1b[27;7;92~",
    "\x1b[27;5;93~",
    "\x1b[?92;3u",
    "\x1b[92;0u",
    "\x1b[27;0;92~",
    "\x1b[27;65539;92~",
    "\x1b[92;65539u",
    "\x1b[A\x1b[B\x1b[I\x1b[O",
    "\x1b[1;2R\x1b[?1;2c",
    "\x1b[<0;10;20M",
    "\x1b[27;3;92u",
    "中文\x00\x7f",
])
def test_unbound_keyboard_input_is_forwarded_unchanged(sessions, sequence):
    child, path = input_reader(sessions)
    child.send(sequence + "received")
    expected = (sequence + "received").encode()
    sessions.wait(lambda: path.read_bytes() == expected)
    assert child.isalive()
    child.send("\x1b[92;3u")
    child.expect(pexpect.EOF)


def test_bracketed_paste_keeps_shortcut_bytes(sessions):
    child, path = input_reader(sessions)
    payload = "中文\x1b\\\x1b[92;3u\x1b[27;3;92~\x1b[92;3:1u"
    paste = "\x1b[200~" + payload + "\x1b[201~"
    for byte in paste:
        child.send(byte)
        time.sleep(0.002)
    sessions.wait(lambda: path.read_bytes() == paste.encode())
    assert child.isalive()
    child.send("\x1b[92;3u")
    child.expect(pexpect.EOF)


@pytest.mark.parametrize("sequence", ["\x1b", "\x1b[", "\x1b[92;", "\x1b[27;3;"])
def test_incomplete_keyboard_input_is_forwarded_after_timeout(sessions, sequence):
    child, path = input_reader(sessions)
    child.send(sequence)
    sessions.wait(lambda: path.read_bytes() == sequence.encode(), timeout=1)
    child.send("\x1b[92;3u")
    child.expect(pexpect.EOF)


def test_long_and_fragmented_input_preserves_bytes(sessions):
    child, path = input_reader(sessions)
    payload = "中文" * 2000 + "\x1b[" + "0" * 9000 + "mEND"
    child.send(payload)
    sessions.wait(lambda: path.read_bytes() == payload.encode())
    child.send("\x1b[92;3u")
    child.expect(pexpect.EOF)


def test_keyboard_detach_after_session_switch(sessions):
    target, path = input_reader(sessions)
    target.send("\x1b[27;3;92~")
    target.expect(pexpect.EOF)
    source = sessions.spawn(name="source")
    source.sendline("imx attach dev")
    source.expect_exact("INPUT_READY")
    source.send("switched\x1b[92;3u")
    source.expect(pexpect.EOF)
    sessions.wait(lambda: all(row["CLIENTS"] == "0" for row in sessions.sessions()))
    sessions.wait(lambda: path.read_bytes() == b"switched")


@pytest.mark.parametrize("key, modifiers, sequence", [
    ("\\", {"ctrl": True}, "\x1c"),
    ("\\", {"ctrl": True}, "\x1b[92;5u"),
    ("x", {"ctrl": True}, "\x18"),
    ("X", {"ctrl": True}, "\x1b[120;5u"),
    ("x", {"ctrl": True}, "\x1b[120;69:2u"),
    ("x", {"ctrl": True}, "\x1b[27;5;120~"),
    ("x", {"ctrl": True}, "\x1b[27;5;88~"),
    ("x", {"alt": True}, "\x1bx"),
    ("x", {"alt": True}, "\x1b[120;3u"),
    ("x", {"ctrl": True, "alt": True}, "\x1b\x18"),
    ("x", {"ctrl": True, "alt": True}, "\x1b[27;7;120~"),
    ("x", {"ctrl": True, "shift": True}, "\x1b[120;6u"),
    ("x", {"ctrl": True, "shift": True}, "\x1b[27;6;88~"),
    ("x", {"super": True}, "\x1b[120;9u"),
    ("F1", {}, "\x1bOP"),
    ("F5", {}, "\x1b[15~"),
    ("F12", {"ctrl": True}, "\x1b[24;5~"),
    ("Up", {}, "\x1bOA"),
    ("Tab", {"shift": True}, "\x1b[Z"),
    ("Enter", {}, "\r"),
    ("Backspace", {}, "\x7f"),
    ("i", {"ctrl": True}, "\t"),
    ("h", {"ctrl": True}, "\x08"),
    ("Space", {"ctrl": True}, "\x00"),
    ("Escape", {}, "\x1b"),
    ("[", {"ctrl": True}, "\x1b"),
    ("x", {"shift": True}, "X"),
    ("λ", {}, "λ"),
    ("λ", {"alt": True}, "\x1bλ"),
])
def test_configured_shortcut_detaches_across_terminal_encodings(sessions, key, modifiers, sequence):
    child, path = input_reader(sessions)
    child.send("\x1b\\")
    child.expect(pexpect.EOF)
    set_detach_binding(sessions, key, **modifiers)
    child = sessions.spawn(initialize=False)
    child.expect_exact("INPUT_READY")
    child.send("before\x1b\\\x1b[92;3u" + sequence)
    child.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
    assert path.read_bytes() == b"before\x1b\\\x1b[92;3u"


def test_detach_binding_can_reassign_a_focus_shortcut(sessions):
    configuration_path = configuration(sessions)
    configuration_path.parent.mkdir(parents=True)
    configuration_path.write_text("[keybindings]\ndetach = { key = 'Up', alt = true }\nfocus_up = { key = 'F11' }\n")
    child, path = input_reader(sessions)
    child.send("before\x1b[1;3A")
    child.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
    assert path.read_bytes() == b"before"


def test_configured_shortcut_preserves_unbound_keys_releases_and_paste(sessions):
    set_detach_binding(sessions, "x", ctrl=True, shift=True)
    child, path = input_reader(sessions)
    unbound = "xX\x18\x1b[120;5u\x1b[120;6:3u\x1b[120;8u\x1c"
    paste = "\x1b[200~X\x1b[120;6u\x1b]unfinished\x1b[201~"
    child.send(unbound + paste + "received")
    sessions.wait(lambda: path.read_bytes() == (unbound + paste + "received").encode())
    assert child.isalive()
    child.send("\x1b[120;6u")
    child.expect(pexpect.EOF)


@pytest.mark.parametrize("sequence", ["\x1bx", "\x1bOP", "\x1b[120;5u", "\x1b[27;5;120~", "\x1bλ"])
def test_configured_shortcut_preserves_fragmented_sequences(sessions, sequence):
    child, path = input_reader(sessions)
    child.send("\x1b\\")
    child.expect(pexpect.EOF)
    if sequence == "\x1bOP":
        set_detach_binding(sessions, "F1")
    elif sequence in ("\x1bx", "\x1bλ"):
        set_detach_binding(sessions, sequence[1:], alt=True)
    else:
        set_detach_binding(sessions, "x", ctrl=True)
    raw = sequence.encode()
    for split in range(1, len(raw)):
        child = sessions.spawn(initialize=False)
        child.expect_exact("INPUT_READY")
        os.write(child.child_fd, b"before" + raw[:split])
        sessions.wait(lambda: path.read_bytes() == b"before" * split)
        os.write(child.child_fd, raw[split:])
        child.expect(pexpect.EOF)
        sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
        assert path.read_bytes() == b"before" * split


def test_keybinding_changes_apply_on_reattach_and_survive_session_switch(sessions):
    set_detach_binding(sessions, "x", ctrl=True)
    target, path = input_reader(sessions)
    target.send("\x18")
    target.expect(pexpect.EOF)
    source = sessions.spawn("source")
    set_detach_binding(sessions, "p", ctrl=True)
    source.sendline("imx attach dev")
    source.expect_exact("INPUT_READY")
    source.send("\x10\x1c\x18")
    source.expect(pexpect.EOF)
    sessions.wait(lambda: path.read_bytes() == b"\x10\x1c")
    attached = sessions.spawn(initialize=False)
    attached.expect_exact("INPUT_READY")
    attached.send("\x18\x1c\x10")
    attached.expect(pexpect.EOF)
    sessions.wait(lambda: path.read_bytes() == b"\x10\x1c\x18\x1c")


def test_control_string_responses_do_not_trigger_alt_shortcuts(sessions):
    child, path = input_reader(sessions)
    responses = "\x1b]2;title\x1b\\\x1bP1$r0m\x1b\\\x1b_Gi=1;OK\x1b\\"
    child.send(responses + "received")
    sessions.wait(lambda: path.read_bytes() == (responses + "received").encode())
    child.send("\x1b\\")
    child.expect(pexpect.EOF)
