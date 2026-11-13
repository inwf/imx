import json
import shlex
import socket
import struct
import sys
import time

import pexpect
import psutil
import pytest

from conftest import ROOT
from test_panes import PaneTerminal


def observe(sessions, name="dev", rows=20, cols=70):
    child = pexpect.spawn(
        str(sessions.binary), ["read", "--", name],
        cwd=str(sessions.path), env=sessions.environment,
        dimensions=(rows, cols), encoding="utf-8", timeout=10,
    )
    child.delaybeforesend = 0
    sessions.clients.append(child)
    terminal = PaneTerminal(sessions, child=child)
    terminal.screen.resize(rows, cols)
    terminal.visible(f"Read-only: {name}")
    return terminal


@pytest.mark.parametrize("name", ["dev", "-dash"])
def test_readonly_connection_and_local_resize_preserve_session_size(sessions, name):
    writer = sessions.spawn(name, rows=30, cols=100)
    observer = observe(sessions, name=name)
    assert sessions.sessions()[0]["CLIENTS"] == "2"
    assert "28 98" in sessions.command(writer, "stty size")
    observer.screen.resize(40, 140)
    observer.child.setwinsize(40, 140)
    observer.visible(f"Read-only: {name}")
    assert "28 98" in sessions.command(writer, "stty size")
    observer.child.send("\x1b\\")
    observer.child.expect(pexpect.EOF)
    assert "28 98" in sessions.command(writer, "stty size")


@pytest.mark.parametrize("close", ["\x1b\\", "\x1bw", "q", "\x1b", "\x1b[113u", "\x1b[27u"])
def test_readonly_discards_keys_paste_mouse_and_focus_and_closes_safely(sessions, close):
    writer = sessions.spawn()
    destination = sessions.path / "input.bin"
    writer.sendline(shlex.join([sys.executable, str(ROOT / "tests/pane_app.py"), str(destination), "legacy"]))
    sessions.wait(destination.exists)
    observer = observe(sessions)
    observer.child.send("DO_NOT_EXECUTE\r\x03\x1b[200~PASTE\r\x1b[201~\x1b[I\x1b[O\x1b[<0;5;5M\x1b[<0;5;5m")
    observer.child.send(close)
    observer.child.expect(pexpect.EOF)
    observer.child.close()
    assert observer.child.exitstatus == 0
    assert destination.read_bytes() == b""
    assert sessions.sessions()[0]["CLIENTS"] == "1"
    assert writer.isalive()


def test_readonly_ignores_pasted_quit_keys_modified_keys_and_key_releases(sessions):
    writer = sessions.spawn()
    observer = observe(sessions)
    observer.visible("q/Esc: exit")
    observer.child.send("Q\x1bq\x11\x1b[113;1:3u\x1b[27;1:3u\x1b[27;2u")
    observer.child.send("\x1b[200~q\x1b")
    deadline = time.monotonic() + 0.3
    while time.monotonic() < deadline:
        observer.pump()
    observer.child.send("q\x1b[201~")
    sessions.command(writer, "printf 'OBSERVER_STILL_ACTIVE\\n'")
    observer.visible("OBSERVER_STILL_ACTIVE")
    assert sessions.sessions()[0]["CLIENTS"] == "2"
    observer.child.send("q")
    observer.child.expect(pexpect.EOF)
    assert "WRITER_ALIVE" in sessions.command(writer, "printf 'WRITER_ALIVE\\n'")


def test_readonly_browses_retained_history_and_follows_live_output(sessions):
    writer = sessions.spawn(rows=30, cols=100)
    sessions.command(writer, "printf '\\033[3J\\033[2J\\033[H'; printf 'HISTORY-%03d\\n' {1..100}")
    observer = observe(sessions)
    observer.visible("HISTORY-100")
    observer.child.send("\x1b[5~")
    observer.wait(lambda: all("HISTORY-100" not in row for row in observer.screen.display))
    observer.child.send("\x1b[H")
    observer.visible("HISTORY-001")
    observer.child.send("\x1b[F")
    observer.visible("HISTORY-100")
    sessions.command(writer, "printf 'LIVE_OUTPUT\\n'")
    observer.visible("LIVE_OUTPUT")


def test_readonly_follows_source_size_and_crops_without_reflowing(sessions):
    writer = sessions.spawn(rows=30, cols=100)
    observer = observe(sessions)
    writer.setwinsize(40, 140)
    sessions.wait(lambda: "38 138" in sessions.command(writer, "stty size"))
    writer.sendline("printf '\\033[2J\\033[H\\033[35;105HFAR_RIGHT'; sleep 1")
    observer.visible("FAR_RIGHT")
    assert "38 138" in sessions.command(writer, "stty size")


def test_readonly_only_session_answers_terminal_queries(sessions):
    writer = sessions.spawn()
    observer = observe(sessions)
    destination = sessions.path / "query.json"
    writer.sendline("sleep 0.3; " + shlex.join([sys.executable, str(ROOT / "tests/terminal_query.py"), str(destination)]))
    writer.send("\x1b\\")
    writer.expect(pexpect.EOF)
    sessions.wait(destination.exists)
    assert json.loads(destination.read_text())["response"] == "1b5b313b3152"
    assert sessions.sessions()[0]["CLIENTS"] == "1"
    assert observer.child.isalive()


def test_readonly_rename_preserves_mode_and_close_preserves_session(sessions):
    writer = sessions.spawn()
    observer = observe(sessions)
    sessions.run("rename", "dev", "renamed")
    observer.visible("Read-only: renamed")
    observer.child.send("\x1bw")
    observer.child.expect(pexpect.EOF)
    assert sessions.sessions()[0]["NAME"] == "renamed"
    assert writer.isalive()


@pytest.mark.parametrize("same", [False, True])
@pytest.mark.parametrize("close", ["\x1b\\", "q", "\x1b"])
def test_switch_to_readonly_preserves_sessions_and_target_size(sessions, same, close):
    source = sessions.spawn("source", rows=30, cols=100)
    target = source if same else sessions.spawn("target", rows=40, cols=120)
    name = "source" if same else "target"
    source.sendline(f"imx read {name}")
    observer = PaneTerminal(sessions, child=source)
    observer.visible(f"Read-only: {name}")
    sessions.wait(lambda: {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == (
        {"source": "1"} if same else {"source": "0", "target": "2"}
    ))
    if not same:
        assert "38 118" in sessions.command(target, "stty size")
    observer.child.send(close)
    observer.child.expect(pexpect.EOF)
    assert {row["NAME"] for row in sessions.sessions()} == ({"source"} if same else {"source", "target"})


def test_readonly_in_split_pane_keeps_other_panes_interactive(sessions):
    terminal = PaneTerminal(sessions)
    target = sessions.spawn("target", rows=40, cols=120)
    terminal.split()
    terminal.visible("1: shell")
    terminal.child.sendline("imx read target")
    terminal.visible("Read-only: target")
    terminal.focus(0)
    terminal.command("printf ready", "writer-alive", "ready")
    terminal.focus(1)
    terminal.child.send("\x1bw")
    terminal.wait(lambda: all("1: target" not in row for row in terminal.screen.display))
    assert "38 118" in sessions.command(target, "stty size")


@pytest.mark.parametrize("close", ["q", "\x1b"])
def test_readonly_quit_in_split_pane_returns_to_shell(sessions, close):
    terminal = PaneTerminal(sessions)
    target = sessions.spawn("target", rows=40, cols=120)
    terminal.split()
    terminal.visible("1: shell")
    terminal.child.sendline("imx read target")
    terminal.visible("Read-only: target")
    terminal.child.send(close)
    terminal.wait(lambda: all("Read-only: target" not in row for row in terminal.screen.display))
    terminal.visible("1: shell")
    terminal.command("printf returned", "readonly-exited", "returned")
    terminal.focus(0)
    terminal.command("printf ready", "other-pane-alive", "ready")
    assert "38 118" in sessions.command(target, "stty size")
    assert {row["NAME"]: row["CLIENTS"] for row in sessions.sessions()} == {"dev": "1", "target": "1"}


def test_readonly_missing_session_fails_without_creating_it(sessions):
    child = pexpect.spawn(str(sessions.binary), ["read", "missing"],
                          cwd=str(sessions.path), env=sessions.environment, encoding="utf-8", timeout=10)
    sessions.clients.append(child)
    child.expect_exact("SessionNotFound")
    child.expect(pexpect.EOF)
    child.close()
    assert child.exitstatus == 1
    assert sessions.sessions() == []


@pytest.mark.parametrize("tag,payload", [(6, b"FORBIDDEN\r"), (7, struct.pack("<HH", 50, 150)), (5, b"dev")])
def test_backend_rejects_modification_from_readonly_connection(sessions, tag, payload):
    writer = sessions.spawn()
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(sessions.runtime / "session-dev.sock"))
        request = struct.pack("<HH", 20, 70) + b"dev\0" + str(sessions.path).encode() + b"\0/bin/bash\0TERM=xterm-256color\0"
        connection.sendall(struct.pack("<IHH", len(request), 22, 1) + request)
        with connection.makefile("rb") as incoming:
            length, response, version = struct.unpack("<IHH", incoming.read(8))
            assert (length, response, version) == (0, 9, 1)
            connection.sendall(struct.pack("<IHH", len(payload), tag, 1) + payload)
            while True:
                length, response, version = struct.unpack("<IHH", incoming.read(8))
                result = incoming.read(length)
                if response == 10:
                    assert result == b"ReadOnlyClient"
                    break
    assert "22 78" in sessions.command(writer, "stty size")
    assert "FORBIDDEN" not in sessions.run("cat", "dev").stdout


def test_readonly_idle_does_not_wake_backend_or_viewer(sessions):
    sessions.spawn()
    observer = observe(sessions)
    frontend = psutil.Process(observer.child.pid)
    clients = [frontend] + [process for process in frontend.children(recursive=True)
                            if process.exe() == str(sessions.binary) and process.name() != "imx-server"]
    time.sleep(0.2)
    before = [process.num_ctx_switches().voluntary for process in clients]
    time.sleep(0.3)
    assert [process.num_ctx_switches().voluntary for process in clients] == before


def test_readonly_never_becomes_resize_leader(sessions):
    first = sessions.spawn(rows=30, cols=100)
    observer = observe(sessions)
    second = sessions.spawn(rows=40, cols=120)
    assert "38 118" in sessions.command(first, "stty size")
    second.send("\x1b\\")
    second.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "2")
    assert "28 98" in sessions.command(first, "stty size")
    first.send("\x1b\\")
    first.expect(pexpect.EOF)
    observer.child.setwinsize(10, 20)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "1")
    writer = sessions.spawn(rows=35, cols=110)
    assert "33 108" in sessions.command(writer, "stty size")
    observer.child.send("\x1bw")
    observer.child.expect(pexpect.EOF)
    assert "33 108" in sessions.command(writer, "stty size")


def test_readonly_recovers_after_tiny_and_maximum_window_sizes(sessions):
    writer = sessions.spawn()
    observer = observe(sessions)
    observer.screen.resize(1, 1)
    observer.child.setwinsize(1, 1)
    observer.pump()
    observer.child.send("\x1b[5~\x1b[H\x1b[C\x1b[F")
    observer.screen.resize(256, 512)
    observer.child.setwinsize(256, 512)
    observer.visible("Read-only: dev")
    assert "22 78" in sessions.command(writer, "stty size")
    observer.screen.resize(20, 70)
    observer.child.setwinsize(20, 70)
    observer.visible("Read-only: dev")
    sessions.command(writer, "printf 'WINDOW_RECOVERED\\n'")
    observer.visible("WINDOW_RECOVERED")


def test_readonly_mouse_scroll_and_paste_keep_history_local(sessions, mouse_mode):
    writer = sessions.spawn(rows=30, cols=100)
    sessions.command(writer, "printf '\\033[3J\\033[2J\\033[H'; printf 'LOCAL-%03d\\n' {1..100}")
    observer = observe(sessions)
    observer.visible("LOCAL-100")
    observer.child.send("\x1b[H")
    observer.visible("LOCAL-001")
    assert "LOCAL-001" in observer.screen.display[1]
    observer.child.send("\x1b[200~\x1b[F\x1bw\x1b[201~")
    observer.pump()
    observer.visible("LOCAL-001")
    observer.child.send("\x1b[<65;5;5M")
    observer.wait(lambda: "LOCAL-004" in observer.screen.display[1])
    observer.child.send("\x1b[<65;5;5M")
    observer.wait(lambda: "LOCAL-007" in observer.screen.display[1])
    observer.child.send("\x1b[F")
    observer.visible("LOCAL-100")
    assert "28 98" in sessions.command(writer, "stty size")


def test_readonly_preserves_hyperlinks_through_local_redraw(sessions):
    writer = sessions.spawn()
    url = "https://example.com/read-only"
    sessions.command(writer, f"printf '\\033]8;id=observer;{url}\\007READ_ONLY_LINK\\033]8;;\\007\\n'")
    observer = observe(sessions)
    observer.visible("READ_ONLY_LINK")
    assert url in observer.capture.getvalue()
    offset = len(observer.capture.getvalue())
    observer.screen.resize(25, 90)
    observer.child.setwinsize(25, 90)
    observer.wait(lambda: url in observer.capture.getvalue()[offset:])


def test_switch_to_missing_readonly_session_keeps_source_interactive(sessions):
    writer = sessions.spawn()
    assert "SessionNotFound" in sessions.command(writer, "imx read missing")
    assert "SOURCE_ALIVE" in sessions.command(writer, "printf 'SOURCE_ALIVE\\n'")
    assert [row["NAME"] for row in sessions.sessions()] == ["dev"]


def test_readonly_respects_custom_detach_and_close_shortcuts(sessions):
    configuration = sessions.home / ".config/imx/config.toml"
    configuration.parent.mkdir(parents=True)
    configuration.write_text("[keybindings]\ndetach = { key = 'q', alt = true }\nclose_pane = { key = 'x', alt = true }\n")
    writer = sessions.spawn()
    for shortcut in ["\x1bq", "\x1bx"]:
        observer = observe(sessions)
        observer.child.send(shortcut)
        observer.child.expect(pexpect.EOF)
        assert "WRITER_ALIVE" in sessions.command(writer, "printf 'WRITER_ALIVE\\n'")


@pytest.mark.parametrize("release", [False, True])
def test_readonly_respects_synchronized_output_and_its_timeout(sessions, release):
    writer = sessions.spawn()
    sessions.command(writer, "printf '\\033[2J\\033[HSTABLE_FRAME\\n'")
    observer = observe(sessions)
    observer.visible("STABLE_FRAME")
    marker = sessions.path / "frame-held"
    finish = "printf '\\033[?2026l'" if release else "true"
    writer.sendline(f"printf '\\033[?2026h\\033[2J\\033[HUPDATED_FRAME'; touch {shlex.quote(str(marker))}; sleep 0.4; {finish}")
    sessions.wait(marker.exists)
    deadline = time.monotonic() + 0.15
    while time.monotonic() < deadline:
        observer.pump()
        assert any("STABLE_FRAME" in row for row in observer.screen.display)
        assert all("UPDATED_FRAME" not in row for row in observer.screen.display)
    observer.visible("UPDATED_FRAME")
    sessions.command(writer, "printf '\\033[?2026l'")
