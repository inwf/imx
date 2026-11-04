from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
import os
import shlex
import socket
import struct
import threading
import time

import pexpect
import psutil
import pytest

from completion_shell import CompletionShell
from preview_client import PreviewClient
from test_panes import PaneTerminal
from test_prompt import enter, settings, setup_shell
from test_uninstall import installation


def request_failure(sessions, name, tag, payload):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(2)
        connection.connect(str(sessions.runtime / f"session-{name}.sock"))
        connection.sendall(struct.pack("<IHH", len(payload), tag, 1) + payload)
        with connection.makefile("rb") as reader:
            length, response, version = struct.unpack("<IHH", reader.read(8))
            assert (response, version) == (10, 1)
            return reader.read(length)


def test_rename_preserves_process_history_directory_and_connections(sessions):
    first = sessions.spawn("old")
    second = sessions.spawn("old", initialize=False)
    second.expect_exact("IMX_PROMPT> ")
    directory = sessions.path / "working directory"
    directory.mkdir()
    sessions.command(first, f"cd {shlex.quote(str(directory))}; export RETAINED=yes; printf 'RENAME_HISTORY\\n'")
    before = sessions.sessions()[0]
    identity = next(sessions.runtime.glob("identity-*.name"))
    result = sessions.run("rename", "old", "new")
    assert result.stdout == result.stderr == ""
    assert sessions.sessions() == [{**before, "NAME": "new"}]
    assert identity.read_text() == "new\n"
    assert "RENAME_HISTORY" in sessions.run("cat", "new").stdout
    assert sessions.run("cat", "old", check=False).returncode == 1
    assert not (sessions.runtime / "session-old.sock").exists()
    assert (sessions.runtime / "session-new.sock").exists()
    assert "yes" in sessions.command(second, "printf '%s\\n' \"$RETAINED\"")
    assert sessions.run("__complete", "sessions", "").stdout == "new\n"
    sessions.run("kill", "new")
    first.expect(pexpect.EOF)
    second.expect(pexpect.EOF)
    sessions.wait(lambda: not identity.exists())


@pytest.mark.parametrize("prompt_enabled", [True, False])
def test_current_session_rename_survives_repeated_changes_and_name_reuse(sessions, prompt_enabled):
    settings(sessions, prompt_enabled)
    child = sessions.spawn("old")
    pid = sessions.sessions()[0]["PID"]
    assert "imx:" not in sessions.command(child, "imx rename second; imx rename third")
    replacement = sessions.spawn("old")
    assert "imx:" not in sessions.command(child, "imx rename final")
    rows = {row["NAME"]: row for row in sessions.sessions()}
    assert rows["final"]["PID"] == pid
    assert rows["old"]["PID"] != pid
    child.sendline("imx detach")
    child.expect(pexpect.EOF)
    sessions.wait(lambda: next(row for row in sessions.sessions() if row["NAME"] == "final")["CLIENTS"] == "0")
    assert "REUSED" in sessions.command(replacement, "printf 'REUSED\\n'")
    attached = sessions.spawn("final", initialize=False)
    attached.expect_exact("IMX_PROMPT> ")
    assert "RESTORED" in sessions.command(attached, "printf 'RESTORED\\n'")


def test_renamed_session_can_switch_and_return(sessions):
    child = sessions.spawn("source")
    pid = sessions.sessions()[0]["PID"]
    sessions.run("rename", "source", "renamed")
    assert "imx:" not in sessions.command(child, "imx attach renamed")
    child.sendline("imx attach target")
    child.expect(r"[#$] ")
    child.sendline("imx attach renamed")
    child.expect_exact("IMX_PROMPT> ")
    assert "RETURNED" in sessions.command(child, "printf 'RETURNED\\n'")
    assert next(row for row in sessions.sessions() if row["NAME"] == "renamed")["PID"] == pid


@pytest.mark.parametrize("name", ["new", "-dash", "a" * 64])
def test_rename_detached_session_and_same_name(sessions, name):
    child = sessions.spawn("dev")
    child.send("\x1b\\")
    child.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
    before = sessions.sessions()[0]
    sessions.run("rename", "--", "dev", name)
    sessions.run("rename", "--", name, name)
    assert sessions.sessions() == [{**before, "NAME": name}]
    attached = sessions.spawn(name, initialize=False)
    attached.expect_exact("IMX_PROMPT> ")


@pytest.mark.parametrize("old,new,error", [
    ("missing", "fresh", "SessionNotFound"),
    ("", "fresh", "InvalidSessionName"),
    ("dev", "other", "SessionAlreadyExists"),
    ("dev", "", "InvalidSessionName"),
    ("dev", ".", "InvalidSessionName"),
    ("dev", "..", "InvalidSessionName"),
    ("dev", "bad/name", "InvalidSessionName"),
    ("dev", "会话", "InvalidSessionName"),
    ("dev", "a" * 65, "InvalidSessionName"),
])
def test_rename_failure_preserves_both_sessions(sessions, old, new, error):
    child = sessions.spawn("dev")
    sessions.spawn("other")
    before = sessions.sessions()
    result = sessions.run("rename", "--", old, new, check=False)
    assert result.returncode == 1
    assert error in result.stderr
    assert sessions.sessions() == before
    assert "ALIVE" in sessions.command(child, "printf 'ALIVE\\n'")


def test_two_sessions_cannot_claim_the_same_name(sessions):
    sessions.spawn("alpha")
    sessions.spawn("beta")
    before = {row["NAME"]: row["PID"] for row in sessions.sessions()}
    barrier = threading.Barrier(2)

    def rename(name):
        barrier.wait(timeout=10)
        return name, sessions.run("rename", name, "target", check=False)

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(rename, before))
    winner = next(name for name, result in results if result.returncode == 0)
    failures = [(name, result) for name, result in results if result.returncode != 0]
    assert len(failures) == 1
    loser, result = failures[0]
    assert "SessionAlreadyExists" in result.stderr or "SessionBusy" in result.stderr
    assert {row["NAME"]: row["PID"] for row in sessions.sessions()} == {
        "target": before[winner], loser: before[loser],
    }


def test_listing_during_renames_keeps_valid_session_rows(sessions):
    sessions.spawn("first")
    pid = sessions.sessions()[0]["PID"]
    barrier = threading.Barrier(2)

    def rename():
        barrier.wait(timeout=10)
        for _ in range(15):
            sessions.run("rename", "first", "second")
            sessions.run("rename", "second", "first")

    with ThreadPoolExecutor(max_workers=1) as executor:
        task = executor.submit(rename)
        barrier.wait(timeout=10)
        for _ in range(30):
            rows = sessions.sessions()
            assert len(rows) <= 1
            assert all(row["STATUS"] == "running" and row["PID"] == pid for row in rows)
        task.result(timeout=10)
    assert sessions.sessions()[0]["NAME"] == "first"


@pytest.mark.parametrize("locked", ["dev", "target"])
def test_rename_reports_busy_lock_without_blocking_backend(sessions, locked):
    child = sessions.spawn("dev")
    with (sessions.runtime / f"session-{locked}.lock").open("a") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if locked == "dev":
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(2)
                connection.connect(str(sessions.runtime / "session-dev.sock"))
                payload = json.dumps({"name": "dev", "new_name": "target"}).encode()
                connection.sendall(struct.pack("<IHH", len(payload), 19, 1) + payload)
                assert b"SessionBusy" in connection.recv(4096)
        else:
            result = sessions.run("rename", "dev", "target", check=False)
            assert "SessionBusy" in result.stderr
        assert "RESPONSIVE" in sessions.command(child, "printf 'RESPONSIVE\\n'")
    sessions.run("rename", "dev", "target")


def test_unresponsive_target_does_not_block_rename_source(sessions):
    child = sessions.spawn("dev")
    sessions.spawn("target")
    before = sessions.sessions()
    target = next(row for row in before if row["NAME"] == "target")
    backend = psutil.Process(psutil.Process(int(target["PID"])).ppid())
    connections = []
    backend.suspend()
    try:
        sessions.wait(lambda: backend.status() == psutil.STATUS_STOPPED)
        for _ in range(256):
            connection = socket.socket(socket.AF_UNIX)
            connections.append(connection)
            connection.setblocking(False)
            if connection.connect_ex(str(sessions.runtime / "session-target.sock")) != 0:
                break
        else:
            pytest.fail("目标后台的连接队列没有填满")
        started = time.monotonic()
        result = sessions.run("rename", "dev", "target", check=False)
        assert result.returncode == 1
        assert "BackendTimeout" in result.stderr
        assert time.monotonic() - started < 1
        assert "RESPONSIVE" in sessions.command(child, "printf 'RESPONSIVE\\n'")
    finally:
        for connection in connections:
            connection.close()
        backend.resume()
    assert sessions.sessions() == before


@pytest.mark.parametrize("shell", ["bash", "zsh", "fish"])
def test_rename_refreshes_prompt_and_environment(sessions, shell):
    setup_shell(sessions, shell)
    child = enter(sessions)
    child.sendline("imx rename inside")
    child.expect_exact("[inside] BASE:~> ")
    child.sendline("printf '\\nSESSION=%s\\n' \"$IMX_SESSION\"")
    child.expect_exact("\r\nSESSION=inside\r\n")
    child.expect_exact("[inside] BASE:~> ")
    sessions.run("rename", "inside", "outside")
    child.sendline("true")
    child.expect_exact("[outside] BASE:~> ")
    child.sendline("printf '\\nSESSION=%s\\n' \"$IMX_SESSION\"")
    child.expect_exact("\r\nSESSION=outside\r\n")


def test_rename_updates_all_pane_titles_and_close_target(sessions):
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.child.sendline("imx attach dev")
    terminal.visible("1: dev")
    sessions.run("rename", "dev", "renamed")
    terminal.visible("0: renamed")
    terminal.visible("1: renamed")
    terminal.child.send("\x1bw")
    terminal.wait(lambda: sessions.sessions() == [])


def test_rename_preserves_active_preview(sessions):
    child = sessions.spawn()
    with PreviewClient(sessions, "dev", 24, 80) as preview:
        assert preview.frame()
        sessions.run("rename", "dev", "renamed")
        sessions.command(child, "printf 'UPDATED_PREVIEW\\n'")
        assert b"UPDATED_PREVIEW" in preview.frame()


@pytest.mark.parametrize("tag", [19, 21])
def test_current_command_rejects_reused_name_with_different_identity(sessions, tag):
    original = sessions.spawn("dev")
    identity_file = sessions.path / "identity"
    sessions.command(original, f"printf '%s' \"$IMX_SESSION_ID\" > {shlex.quote(str(identity_file))}")
    identity = identity_file.read_text()
    sessions.run("rename", "dev", "renamed")
    replacement = sessions.spawn("dev")
    before = sessions.sessions()
    request = {"name": "dev", "expected_id": identity}
    if tag == 19:
        request["new_name"] = "wrong"
    assert request_failure(sessions, "dev", tag, json.dumps(request).encode()) == b"SessionNotFound"
    assert sessions.sessions() == before
    assert "ORIGINAL" in sessions.command(original, "printf 'ORIGINAL\\n'")
    assert "REPLACEMENT" in sessions.command(replacement, "printf 'REPLACEMENT\\n'")


def test_rename_preserves_vim_and_unsaved_changes(sessions):
    child = sessions.spawn()
    child.sendline("vim -u NONE -i NONE -n document.txt")
    child.expect_exact("document.txt")
    child.send("iUNSAVED_RENAME_TEXT\x1b")
    child.expect_exact("UNSAVED_RENAME_TEXT")
    sessions.run("rename", "dev", "editor")
    assert "UNSAVED_RENAME_TEXT" in sessions.run("cat", "editor").stdout
    child.send(":wq\r")
    child.expect_exact("IMX_PROMPT> ")
    assert (sessions.path / "document.txt").read_text() == "UNSAVED_RENAME_TEXT\n"


@pytest.mark.parametrize("payload", [b"{", b"{}", b'{"name":"dev","new_name":3}'])
def test_invalid_rename_request_preserves_session(sessions, payload):
    child = sessions.spawn()
    assert request_failure(sessions, "dev", 19, payload) == b"InvalidMessage"
    assert "ALIVE" in sessions.command(child, "printf 'ALIVE\\n'")


def test_uninstall_cleans_renamed_and_interrupted_session_metadata(installation):
    child = installation.spawn("dev")
    installation.run("rename", "dev", "renamed")
    metadata = list(installation.runtime.glob("identity-*.name"))
    assert len(metadata) == 1
    backend = psutil.Process(psutil.Process(int(installation.sessions()[0]["PID"])).ppid())
    backend.kill()
    installation.wait(lambda: not backend.is_running())
    child.expect(pexpect.EOF)
    assert metadata[0].exists()
    installation.run("uninstall")
    assert not installation.runtime.exists()


@pytest.mark.parametrize("shell", ["bash", "zsh", "fish"])
def test_rename_completion_uses_current_names(installation, shell):
    installation.spawn("original")
    installation.run("rename", "original", "renamed")
    with CompletionShell(installation.environment, shell, installation.binary.parent.parent) as terminal:
        assert terminal.complete("imx ren\t") == "imx rename "
        assert terminal.complete("imx rename ren\t") == "imx rename renamed "
        assert terminal.complete("imx rename ori\t") == "imx rename ori"
        assert terminal.complete("imx rename renamed fresh\t") == "imx rename renamed fresh"
