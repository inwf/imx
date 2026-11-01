from pathlib import Path
import os
import shlex
import shutil
import signal
import time

import pexpect
import psutil
import pytest

from conftest import BINARY
from test_prompt import enter, settings, setup_shell


def rows(environment):
    return {row["NAME"]: row for row in environment.sessions()}


def switch(environment, child, destination):
    child.sendline(f"imx attach {shlex.quote(destination)}")
    environment.wait(lambda: rows(environment)[destination]["CLIENTS"] == "1")
    child.expect_exact("IMX_PROMPT> ")
    output = environment.command(child, "printf 'SESSION=%s\\n' \"$IMX_SESSION\"")
    assert f"SESSION={destination}" in output


def test_switch_existing_session_preserves_programs_history_and_frontend(sessions):
    target = sessions.spawn("dev2")
    sessions.command(target, "export TARGET_VALUE=retained; printf 'TARGET_HISTORY\\n'")
    target.send("\x1b\\")
    target.expect(pexpect.EOF)
    source = sessions.spawn("dev1")
    sessions.command(source, "export SOURCE_VALUE=retained; printf 'SOURCE_HISTORY\\n'; sleep 600 & printf '%s' \"$!\" > source-job.pid")
    job = psutil.Process(int((sessions.path / "source-job.pid").read_text()))
    original = rows(sessions)
    frontend = psutil.Process(source.pid)
    switch(sessions, source, "dev2")
    sessions.wait(lambda: rows(sessions)["dev1"]["CLIENTS"] == "0")
    assert frontend.is_running() and source.isalive()
    assert job.is_running()
    assert "retained" in sessions.command(source, "printf '%s\\n' \"$TARGET_VALUE\"")
    assert "TARGET_HISTORY" in sessions.run("cat", "dev2").stdout
    assert "SOURCE_HISTORY" in sessions.run("cat", "dev1").stdout
    for name, row in rows(sessions).items():
        assert row["PID"] == original[name]["PID"]
        assert row["CREATED"] == original[name]["CREATED"]
    switch(sessions, source, "dev1")
    assert "retained" in sessions.command(source, "printf '%s\\n' \"$SOURCE_VALUE\"")
    assert job.is_running()
    source.send("\x1b\\")
    source.expect(pexpect.EOF)
    assert all(row["CLIENTS"] == "0" for row in rows(sessions).values())


def test_switch_creates_target_with_current_directory_and_environment(sessions):
    source = sessions.spawn("dev1")
    directory = sessions.path / "项目 with spaces"
    directory.mkdir()
    sessions.command(source, f"cd {shlex.quote(str(directory))}; export SWITCH_VALUE=from_source")
    source.sendline("imx attach dev2")
    source.expect(r"[#$] ")
    source.sendline("stty -echo; PS1='IMX_PROMPT> '; PROMPT_COMMAND=; printf '\\nTARGET_READY\\n'")
    source.expect_exact("\r\nTARGET_READY\r\n")
    source.expect_exact("IMX_PROMPT> ")
    output = sessions.command(source, "printf '%s|%s|%s|%s\\n' \"$PWD\" \"$IMX_SESSION\" \"$SWITCH_VALUE\" \"${IMX_CLIENT_CAPABILITIES-unset}\"")
    assert f"{directory}|dev2|from_source|unset" in output
    assert rows(sessions)["dev1"]["CLIENTS"] == "0"
    assert rows(sessions)["dev2"]["DIRECTORY"] == str(directory)


@pytest.mark.parametrize("active", [0, 1])
def test_switch_moves_only_the_terminal_that_sent_input(sessions, active):
    target = sessions.spawn("dev2")
    target.send("\x1b\\")
    target.expect(pexpect.EOF)
    first = sessions.spawn("dev1", rows=24, cols=80)
    second = sessions.spawn("dev1", initialize=False, rows=40, cols=120)
    second.expect_exact("IMX_PROMPT> ")
    terminals = [first, second]
    switch(sessions, terminals[active], "dev2")
    sessions.wait(lambda: all(row["CLIENTS"] == "1" for row in rows(sessions).values()))
    output = sessions.command(terminals[1 - active], "printf 'REMAINING=%s\\n' \"$IMX_SESSION\"")
    assert "REMAINING=dev1" in output
    size = "24 80" if active == 0 else "40 120"
    assert size in sessions.command(terminals[active], "stty size")


def test_switch_to_same_session_keeps_connection(sessions):
    child = sessions.spawn("dev1")
    original = rows(sessions)
    output = sessions.command(child, "imx attach dev1; printf 'SAME_STATUS=%s\\n' \"$?\"")
    assert "SAME_STATUS=0" in output
    assert rows(sessions) == original


@pytest.mark.parametrize("destination", ["../invalid", ""])
def test_invalid_switch_keeps_source_session(sessions, destination):
    child = sessions.spawn("dev1")
    output = sessions.command(child, f"imx attach {shlex.quote(destination)}; printf 'SWITCH_STATUS=%s\\n' \"$?\"")
    assert "InvalidSessionName" in output and "SWITCH_STATUS=1" in output
    assert list(rows(sessions)) == ["dev1"]
    assert rows(sessions)["dev1"]["CLIENTS"] == "1"


def test_paused_target_reports_timeout_and_keeps_source_connection(sessions):
    target = sessions.spawn("dev2")
    target.send("\x1b\\")
    target.expect(pexpect.EOF)
    source = sessions.spawn("dev1")
    backend = psutil.Process(psutil.Process(int(rows(sessions)["dev2"]["PID"])).ppid())
    backend.suspend()
    try:
        started = time.monotonic()
        output = sessions.command(source, "imx attach dev2; printf 'SWITCH_STATUS=%s\\n' \"$?\"")
        assert time.monotonic() - started < 4
        assert "BackendTimeout" in output and "SWITCH_STATUS=1" in output
        assert "STILL_DEV1" in sessions.command(source, "printf 'STILL_DEV1\\n'")
    finally:
        backend.resume()
    sessions.wait(lambda: rows(sessions)["dev2"]["CLIENTS"] == "0")
    switch(sessions, source, "dev2")


@pytest.mark.parametrize("shell, error", [
    ("/missing/bash", "ShellExecFailed"),
    ("/missing/imx-shell", "UnsupportedPromptShell"),
])
def test_failed_target_shell_preserves_source_connection(sessions, shell, error):
    source = sessions.spawn("dev1")
    output = sessions.command(source, f"SHELL={shell} imx attach broken; printf 'SWITCH_STATUS=%s\\n' \"$?\"")
    assert error in output and "SWITCH_STATUS=1" in output
    sessions.wait(lambda: list(rows(sessions)) == ["dev1"])
    assert "SOURCE_ALIVE" in sessions.command(source, "printf 'SOURCE_ALIVE\\n'")


def test_repeated_switches_reuse_frontend_and_restore_terminal(sessions):
    target = sessions.spawn("dev2")
    target.send("\x1b\\")
    target.expect(pexpect.EOF)
    source = sessions.spawn("dev1")
    process = psutil.Process(source.pid)
    frontend, = [child for child in process.children() if child.name() != "imx-server"]
    processes = [process, frontend]
    descriptor_counts = [item.num_fds() for item in processes]
    child_pids = {child.pid for child in process.children()}
    for index in range(12):
        switch(sessions, source, "dev2" if index % 2 == 0 else "dev1")
    assert [item.num_fds() for item in processes] == descriptor_counts
    assert all(item.num_threads() == 1 for item in processes)
    assert {child.pid for child in process.children()} == child_pids
    assert frontend.children() == []
    source.send("\x1b\\")
    source.expect(pexpect.EOF)
    assert rows(sessions)["dev1"]["CLIENTS"] == "0"


@pytest.mark.parametrize("shell", ["bash", "zsh", "fish"])
def test_switch_updates_session_prompt(sessions, shell):
    setup_shell(sessions, shell)
    settings(sessions, True)
    source = enter(sessions, "dev1")
    source.sendline("imx attach dev2")
    source.expect_exact("[dev2] BASE:~> ")
    source.sendline("imx attach dev1")
    source.expect_exact("[dev1] BASE:~> ")
    assert rows(sessions)["dev1"]["CLIENTS"] == "1"
    assert rows(sessions)["dev2"]["CLIENTS"] == "0"


def test_switch_after_executable_update_uses_installed_backend(sessions):
    installed = sessions.path / "bin/imx"
    installed.parent.mkdir()
    shutil.copy2(BINARY, installed)
    sessions.binary = installed
    sessions.environment["PATH"] = f"{installed.parent}:{sessions.environment['PATH']}"
    source = sessions.spawn("dev1")
    old_inode = installed.stat().st_ino
    replacement = installed.with_name("replacement")
    shutil.copy2(BINARY, replacement)
    replacement.replace(installed)
    source.sendline("imx attach dev2")
    source.expect(r"[#$] ")
    session_rows = rows(sessions)
    old_backend = psutil.Process(int(session_rows["dev1"]["PID"])).ppid()
    new_backend = psutil.Process(int(session_rows["dev2"]["PID"])).ppid()
    assert Path(f"/proc/{old_backend}/exe").stat().st_ino == old_inode
    assert Path(f"/proc/{new_backend}/exe").stat().st_ino == installed.stat().st_ino
    assert source.isalive()


def test_external_process_cannot_switch_a_session_by_environment(sessions):
    source = sessions.spawn("dev1")
    environment = sessions.environment.copy()
    environment["IMX_SESSION"] = "dev1"
    caller = pexpect.spawn(str(sessions.binary), ["attach", "dev2"], env=environment,
                           cwd=str(sessions.path), encoding="utf-8", timeout=10)
    try:
        caller.expect(pexpect.EOF)
        assert "SwitchOutsideSession" in caller.before
    finally:
        caller.close(force=True)
    assert list(rows(sessions)) == ["dev1"]
    assert "SOURCE_ALIVE" in sessions.command(source, "printf 'SOURCE_ALIVE\\n'")


def test_cancelled_switch_releases_source_connection(sessions):
    target = sessions.spawn("dev2")
    target.send("\x1b\\")
    target.expect(pexpect.EOF)
    source = sessions.spawn("dev1")
    backend = psutil.Process(psutil.Process(int(rows(sessions)["dev2"]["PID"])).ppid())
    backend.suspend()
    try:
        source.sendline("sh -c 'printf %s $$ > switch.pid; exec imx attach dev2'; printf '\\nSWITCH_CANCELLED\\n'")
        path = sessions.path / "switch.pid"
        sessions.wait(lambda: path.exists() and path.stat().st_size > 0)
        caller = psutil.Process(int(path.read_text()))
        sessions.wait(lambda: len(caller.net_connections(kind="unix")) >= 2)
        caller.send_signal(signal.SIGTERM)
        source.expect_exact("\r\nSWITCH_CANCELLED\r\n")
        source.expect_exact("IMX_PROMPT> ")
        assert "SOURCE_ACTIVE" in sessions.command(source, "printf 'SOURCE_ACTIVE\\n'")
    finally:
        backend.resume()
    sessions.wait(lambda: rows(sessions)["dev2"]["CLIENTS"] == "0")
    switch(sessions, source, "dev2")


def test_switch_restores_vim_screen(sessions):
    document = sessions.path / "switch-document.txt"
    document.write_text("SWITCH_VIM_DOCUMENT\n终端画面\n")
    target = sessions.spawn("dev2")
    target.sendline("vim -u NONE -i NONE -n switch-document.txt")
    target.expect_exact("SWITCH_VIM_DOCUMENT")
    target.send("\x1b\\")
    target.expect(pexpect.EOF)
    source = sessions.spawn("dev1")
    source.sendline("imx attach dev2")
    source.expect_exact("SWITCH_VIM_DOCUMENT")
    source.send(":q!\r")
    source.expect_exact("IMX_PROMPT> ")
    assert "SESSION=dev2" in sessions.command(source, "printf 'SESSION=%s\\n' \"$IMX_SESSION\"")
    switch(sessions, source, "dev1")


def test_switch_and_detach_restore_original_terminal_attributes(sessions):
    outer = pexpect.spawn("/bin/bash", ["--noprofile", "--norc"], env=sessions.environment,
                          cwd=str(sessions.path), dimensions=(24, 80), encoding="utf-8", timeout=10)
    sessions.clients.append(outer)
    outer.expect(r"[#$] ")
    outer.sendline("stty -g > before-switch; imx attach dev1")
    outer.expect(r"[#$] ")
    outer.sendline("imx attach dev2")
    sessions.wait(lambda: "dev2" in rows(sessions) and rows(sessions)["dev1"]["CLIENTS"] == "0")
    outer.expect(r"[#$] ")
    outer.send("\x1b\\")
    outer.expect(r"[#$] ")
    outer.sendline("stty -g > after-switch; printf '\\nOUTER_RESTORED\\n'")
    outer.expect_exact("\r\nOUTER_RESTORED\r\n")
    assert (sessions.path / "before-switch").read_text() == (sessions.path / "after-switch").read_text()


def test_switch_with_pending_terminal_output(sessions):
    target = sessions.spawn("dev2")
    target.send("\x1b\\")
    target.expect(pexpect.EOF)
    source = sessions.spawn("dev1")
    gate = sessions.path / "switch-gate"
    os.mkfifo(gate)
    descriptor = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
    frontend = psutil.Process(source.pid)
    try:
        source.sendline("printf '\\nOUTPUT_READY\\n'; read -r gate < switch-gate; seq 1 35000; sh -c 'printf %s $$ > switch.pid; exec imx attach dev2'")
        source.expect_exact("\r\nOUTPUT_READY\r\n")
        frontend.suspend()
        try:
            os.write(descriptor, b"continue\n")
            path = sessions.path / "switch.pid"
            sessions.wait(lambda: path.exists() and path.stat().st_size > 0)
            caller = psutil.Process(int(path.read_text()))
            sessions.wait(lambda: len(caller.net_connections(kind="unix")) >= 2)
        finally:
            frontend.resume()
        source.expect_exact("IMX_PROMPT> ")
        assert "SESSION=dev2" in sessions.command(source, "printf 'SESSION=%s\\n' \"$IMX_SESSION\"")
        sessions.wait(lambda: rows(sessions)["dev1"]["CLIENTS"] == "0")
    finally:
        os.close(descriptor)


def test_switch_to_attached_target_preserves_connections_and_resize(sessions):
    target = sessions.spawn("dev2")
    source = sessions.spawn("dev1")
    source.sendline("imx attach dev2")
    source.expect_exact("IMX_PROMPT> ")
    sessions.wait(lambda: rows(sessions)["dev2"]["CLIENTS"] == "2")
    assert "SESSION=dev2" in sessions.command(source, "printf 'SESSION=%s\\n' \"$IMX_SESSION\"")
    source.setwinsize(35, 110)
    sessions.wait(lambda: "35 110" in sessions.command(source, "stty size"))
    assert "TARGET_ALIVE" in sessions.command(target, "printf 'TARGET_ALIVE\\n'")
    source.sendline("imx detach")
    source.expect(pexpect.EOF)
    target.expect(pexpect.EOF)
    assert all(row["CLIENTS"] == "0" for row in rows(sessions).values())
