import time

import pexpect
import pytest


def input_reader(sessions):
    child = sessions.spawn()
    child.sendline("stty raw -echo; printf '\\033[>5u\\033[>4;2mINPUT_READY'; cat > input.bin")
    child.expect_exact("INPUT_READY")
    path = sessions.path / "input.bin"
    sessions.wait(path.exists)
    return child, path


@pytest.mark.parametrize("sequence", [
    "\x1c",
    "\x1b[92;5u",
    "\x1b[92;5:1u",
    "\x1b[92;5:2u",
    "\x1b[92;69u",
    "\x1b[92;133u",
    "\x1b[92;197u",
    "\x1b[92:124;5u",
    "\x1b[92::92;5u",
    "\x1b[92:124:92;69:1u",
    "\x1b[92;5;28u",
    "\x1b[92;5;28:92u",
    "\x1b[27;5;92~",
    "\x1b[27;69;92~",
    "\x1b[27;133;92~",
    "\x1b[27;197;92~",
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


@pytest.mark.parametrize("sequence", ["\x1b[92;5u", "\x1b[92:124:92;69:1u", "\x1b[27;5;92~"])
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
    "\x1b[92;5:3u",
    "\x1b[92;69:3u",
    "\x1b[92;1u",
    "\x1b[92;6u",
    "\x1b[92;7u",
    "\x1b[92;13u",
    "\x1b[91;5u",
    "\x1b[93;5u",
    "\x1b[27;6;92~",
    "\x1b[27;7;92~",
    "\x1b[27;5;93~",
    "\x1b[?92;5u",
    "\x1b[92;0u",
    "\x1b[27;0;92~",
    "\x1b[27;65541;92~",
    "\x1b[92;65541u",
    "\x1b[A\x1b[B\x1b[I\x1b[O",
    "\x1b[1;2R\x1b[?1;2c",
    "\x1b[<0;10;20M",
    "\x1b[27;5;92u",
    "中文\x00\x7f",
])
def test_unbound_keyboard_input_is_forwarded_unchanged(sessions, sequence):
    child, path = input_reader(sessions)
    child.send(sequence + "received")
    expected = (sequence + "received").encode()
    sessions.wait(lambda: path.read_bytes() == expected)
    assert child.isalive()
    child.send("\x1b[92;5u")
    child.expect(pexpect.EOF)


def test_bracketed_paste_keeps_shortcut_bytes(sessions):
    child, path = input_reader(sessions)
    payload = "中文\x1c\x1b[92;5u\x1b[27;5;92~\x1b[92;5:1u"
    paste = "\x1b[200~" + payload + "\x1b[201~"
    for byte in paste:
        child.send(byte)
        time.sleep(0.002)
    sessions.wait(lambda: path.read_bytes() == paste.encode())
    assert child.isalive()
    child.send("\x1b[92;5u")
    child.expect(pexpect.EOF)


@pytest.mark.parametrize("sequence", ["\x1b", "\x1b[", "\x1b[92;", "\x1b[27;5;"])
def test_incomplete_keyboard_input_is_forwarded_after_timeout(sessions, sequence):
    child, path = input_reader(sessions)
    child.send(sequence)
    sessions.wait(lambda: path.read_bytes() == sequence.encode(), timeout=1)
    child.send("\x1b[92;5u")
    child.expect(pexpect.EOF)


def test_long_and_fragmented_input_preserves_bytes(sessions):
    child, path = input_reader(sessions)
    payload = "中文" * 2000 + "\x1b[" + "0" * 9000 + "mEND"
    child.send(payload)
    sessions.wait(lambda: path.read_bytes() == payload.encode())
    child.send("\x1b[92;5u")
    child.expect(pexpect.EOF)


def test_keyboard_detach_after_session_switch(sessions):
    target, path = input_reader(sessions)
    target.send("\x1b[27;5;92~")
    target.expect(pexpect.EOF)
    source = sessions.spawn(name="source")
    source.sendline("imx attach dev")
    source.expect_exact("INPUT_READY")
    source.send("switched\x1b[92;5u")
    source.expect(pexpect.EOF)
    sessions.wait(lambda: all(row["CLIENTS"] == "0" for row in sessions.sessions()))
    sessions.wait(lambda: path.read_bytes() == b"switched")
