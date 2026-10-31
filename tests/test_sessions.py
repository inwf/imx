from concurrent.futures import ThreadPoolExecutor
import csv
from datetime import datetime, timedelta, timezone
import io
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import termios
import unicodedata

import pexpect
import psutil
import pyte
import pytest

from conftest import BINARY, ROOT
from test_prompt import configuration


def test_commands_and_empty_list(sessions):
    for args in [(), ("list",), ("ls",)]:
        assert sessions.run(*args).stdout == "No sessions.\n"
    assert not (sessions.runtime / "server.sock").exists()
    assert sessions.run("-v").stdout == "imx 0.4.1\n"
    help_text = sessions.run("help").stdout
    for command in ["attach", "list", "cat", "detach", "kill", "update", "uninstall", "-v", "help"]:
        assert command in help_text
    for args in [("attach",), ("cat", "missing"), ("kill", "missing"), ("detach",), ("unknown",), ("attach", "../bad"), ("-v", "extra"), ("update", "extra")]:
        result = sessions.run(*args, check=False)
        assert result.returncode != 0
        assert result.stderr.startswith("imx: ")


def test_attach_directory_environment_and_aliases(sessions):
    sessions.environment["IMX_TEST_VALUE"] = "真实环境变量"
    child = sessions.spawn()
    output = sessions.command(child, "printf '%s|%s|%s\\n' \"$PWD\" \"$IMX_SESSION\" \"$IMX_TEST_VALUE\"")
    assert f"{sessions.path}|dev|真实环境变量" in output
    baseline = sessions.run("list").stdout
    assert sessions.run("ls").stdout == baseline
    assert sessions.run().stdout == baseline
    assert sessions.sessions()[0]["CLIENTS"] == "1"


@pytest.mark.parametrize("hours", [0, 14, -12])
def test_session_creation_time(sessions, hours):
    sessions.environment["TZ"] = f"UTC{-hours:+d}"
    zone = timezone(timedelta(hours=hours))
    before = datetime.now(zone).replace(microsecond=0)
    child = sessions.spawn()
    after = datetime.now(zone).replace(microsecond=0)
    listing = sessions.run("ls").stdout
    reader = csv.DictReader(io.StringIO(listing), delimiter="\t")
    assert reader.fieldnames == ["NAME", "PID", "CLIENTS", "DIRECTORY", "CREATED"]
    row = next(reader)
    created = row["CREATED"]
    recorded = [datetime.strptime(f"{year} {created}", "%Y %m-%d %H:%M:%S").replace(tzinfo=zone)
                for year in {before.year, after.year}]
    assert any(before <= value <= after for value in recorded)
    assert len(created) == 14
    assert row["NAME"] == "dev" and row["DIRECTORY"] == str(sessions.path)
    assert sessions.run("list").stdout == listing
    assert sessions.run().stdout == listing

    child.sendcontrol("\\")
    child.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
    sessions.environment["TZ"] = "UTC0"
    attached = sessions.spawn(initialize=False)
    attached.expect_exact("IMX_PROMPT> ")
    assert sessions.sessions()[0]["CREATED"] == created
    assert sessions.sessions()[0]["PID"] == row["PID"]


@pytest.mark.parametrize("created_format", [None, "%Y-%m-%d %H:%M:%S", "%Y年%m月%d日"])
def test_terminal_session_list_columns(sessions, created_format):
    if created_format is not None:
        path = configuration(sessions)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"[list]\ncreated_format = '{created_format}'\n")
    original = sessions.path
    clients = []
    for name, directory in [("a", "短目录"), ("session-with-a-long-name", "project with a longer directory"), ("combining", "cafe\u0301")]:
        sessions.path = original / directory
        sessions.path.mkdir()
        clients.append(sessions.spawn(name=name, cols=240))
    sessions.path = original
    rows = sessions.sessions()
    headings = ["NAME", "PID", "CLIENTS", "DIRECTORY", "CREATED"]
    baseline = None
    for invocation in ("imx", "imx ls", "imx list"):
        output = sessions.command(clients[0], invocation)
        assert "\t" not in output
        if baseline is None:
            baseline = output
        else:
            assert output == baseline
        screen = pyte.Screen(240, 24)
        pyte.Stream(screen).feed(output)
        header_line = next(index for index, line in enumerate(screen.display) if all(heading in line for heading in headings))
        positions = [screen.display[header_line].index(heading) for heading in headings] + [240]
        for line, row in enumerate(rows, start=header_line + 1):
            for index, heading in enumerate(headings):
                text = "".join(screen.buffer[line][column].data
                               for column in range(positions[index], positions[index + 1])).rstrip()
                assert text == unicodedata.normalize("NFC", row[heading])
    assert sessions.run("ls").stdout.count("\t") == 4 * (len(rows) + 1)


def test_session_list_after_executable_replacement(sessions):
    installed = sessions.path / "bin/imx"
    installed.parent.mkdir()
    shutil.copy2(BINARY, installed)
    sessions.binary = installed
    sessions.environment["PATH"] = f"{installed.parent}:{sessions.environment['PATH']}"
    child = sessions.spawn(cols=240)
    original_pid = sessions.sessions()[0]["PID"]
    replacement = installed.parent / "replacement"
    shutil.copy2(BINARY, replacement)
    replacement.replace(installed)
    for invocation in ("imx", "imx ls", "imx list"):
        output = sessions.command(child, invocation)
        assert "NAME\tPID\tCLIENTS\tDIRECTORY\tCREATED" in output
        assert original_pid in output
        assert "imx: " not in output
    assert sessions.sessions()[0]["PID"] == original_pid
    path = configuration(sessions)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("[list]\ncreated_format = '%Y-%m-%d %H:%M:%S'\n")
    created = sessions.sessions()[0]["CREATED"]
    assert len(created) == 19
    for invocation in ("imx", "imx ls", "imx list"):
        output = sessions.command(child, invocation)
        assert "\t" not in output
        assert created in output
        assert original_pid in output


def test_detach_and_reattach_preserves_shell_and_history(sessions):
    child = sessions.spawn()
    sessions.command(child, "export IMX_VALUE=retained; printf '历史输出\\n'")
    original_pid = sessions.sessions()[0]["PID"]
    child.sendcontrol("\\")
    child.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
    assert "历史输出" in sessions.run("cat", "dev").stdout
    other = sessions.spawn(initialize=False)
    other.expect_exact("IMX_PROMPT> ")
    assert "retained" in sessions.command(other, "printf '%s\\n' \"$IMX_VALUE\"")
    assert sessions.sessions()[0]["PID"] == original_pid


def test_detach_command_from_inside_session(sessions):
    child = sessions.spawn()
    child.sendline("imx detach")
    child.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
    assert sessions.run("cat", "dev").returncode == 0


def test_closed_terminal_preserves_session(sessions):
    child = sessions.spawn()
    original_pid = sessions.sessions()[0]["PID"]
    child.close(force=True)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
    assert sessions.sessions()[0]["PID"] == original_pid


def test_history_overwrites_color_and_unicode(sessions):
    child = sessions.spawn()
    sessions.command(child, "printf '\\033[2J\\033[H旧内容\\r\\033[2K\\033[32m新内容\\033[0m\\n'")
    history = sessions.run("cat", "dev").stdout
    assert "新内容" in history
    assert "旧内容" not in history
    assert "\x1b" not in history


def test_terminal_resize_and_multiple_clients(sessions):
    first = sessions.spawn()
    second = sessions.spawn(initialize=False, rows=30, cols=100)
    second.expect_exact("IMX_PROMPT> ")
    assert "30 100" in sessions.command(second, "stty size")
    second.setwinsize(40, 120)
    assert "40 120" in sessions.command(second, "stty size")
    assert sessions.sessions()[0]["CLIENTS"] == "2"
    second.sendcontrol("\\")
    second.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "1")
    first.expect_exact("IMX_PROMPT> ")
    assert "24 80" in sessions.command(first, "stty size")


def test_kill_terminates_shell_and_background_jobs(sessions):
    child = sessions.spawn()
    output = sessions.command(child, "sleep 600 & printf '\\nCHILD_PID=%s\\n' \"$!\"")
    lines = output.splitlines()
    job_pid = int(next(line.split("=", 1)[1] for line in lines if line.startswith("CHILD_PID=")))
    shell_pid = int(sessions.sessions()[0]["PID"])
    assert psutil.pid_exists(job_pid)
    sessions.run("kill", "dev")
    child.expect(pexpect.EOF)
    assert not psutil.pid_exists(shell_pid)
    assert not psutil.pid_exists(job_pid)
    assert sessions.sessions() == []


def test_shell_exit_flushes_last_output(sessions):
    child = sessions.spawn()
    child.sendline("printf 'FINAL_OUTPUT\\n'; exit")
    child.expect_exact("FINAL_OUTPUT")
    child.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions() == [])


def test_scrollback_is_bounded(sessions):
    child = sessions.spawn()
    sessions.command(child, "seq 1 30000")
    history = sessions.run("cat", "dev").stdout
    assert "30000\n" in history
    assert len(history.splitlines()) <= 10024
    assert not history.startswith("1\n")


def test_snapshot_restores_active_screen(sessions):
    child = sessions.spawn()
    sessions.command(child, "printf '\\033[2J\\033[H\\033[31mSCREEN_MARKER\\033[0m\\033[5;8H定位内容'")
    before = sessions.run("cat", "dev").stdout
    child.sendcontrol("\\")
    child.expect(pexpect.EOF)
    attached = sessions.spawn(initialize=False)
    restored = sessions.command(attached, "printf 'VIEW_CONNECTED\\n'")
    screen = pyte.Screen(80, 24)
    pyte.Stream(screen).feed(restored)
    assert any("SCREEN_MARKER" in line for line in screen.display)
    assert any("定位内容" in line for line in screen.display)
    assert "SCREEN_MARKER" in before
    assert "定位内容" in sessions.run("cat", "dev").stdout


@pytest.mark.parametrize("alternate", [False, True])
def test_attach_and_detach_preserve_terminal_colors(sessions, alternate):
    initial = io.StringIO()
    child = sessions.spawn(initialize=False)
    child.logfile_read = initial
    child.expect(r"[#$] ")
    child.sendline("stty -echo; PS1='IMX_PROMPT> '; PROMPT_COMMAND=; printf '\\nINITIALIZED\\n'")
    child.expect_exact("\r\nINITIALIZED\r\n")
    child.expect_exact("IMX_PROMPT> ")
    if alternate:
        sessions.command(child, "printf '\\033[?1049h'")
    sessions.command(child, "printf '\\033[2J\\033[H\\033[1;31mINDEXED\\033[0m\\n\\033[38;2;18;52;86mRGB\\033[0m\\n'")
    child.sendcontrol("\\")
    child.expect(pexpect.EOF)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")

    replay = io.StringIO()
    attached = sessions.spawn(initialize=False)
    attached.logfile_read = replay
    attached.expect_exact("IMX_PROMPT> ")
    attached.sendline("imx detach")
    attached.expect(pexpect.EOF)
    restored = replay.getvalue()
    screen = pyte.Screen(80, 24)
    pyte.Stream(screen).feed(restored)
    assert screen.buffer[0][0].bold
    assert screen.buffer[0][0].fg != "default"
    assert screen.buffer[1][0].fg == "123456"
    assert "INDEXED" in restored and "RGB" in restored
    for text in (initial.getvalue(), restored):
        for sequence in ("\x1b]4;", "\x1b]10;", "\x1b]11;", "\x1b]12;", "\x1b]104", "\x1b]110", "\x1b]111", "\x1b]112"):
            assert sequence not in text


def test_creation_race_uses_single_daemon_and_session(sessions):
    def launch(_):
        master, slave = os.openpty()
        termios.tcsetwinsize(slave, (24, 80))
        process = subprocess.Popen(
            [str(BINARY), "attach", "dev"], stdin=slave, stdout=slave, stderr=slave,
            env=sessions.environment, cwd=sessions.path, start_new_session=True,
        )
        os.close(slave)
        return process, master

    with ThreadPoolExecutor(max_workers=8) as pool:
        clients = list(pool.map(launch, range(8)))
    sessions.wait(lambda: len(sessions.sessions()) == 1 and sessions.sessions()[0]["CLIENTS"] == "8")
    sessions.run("kill", "dev")
    for process, master in clients:
        assert process.wait(timeout=10) == 0
        os.close(master)


def test_bad_protocol_does_not_terminate_sessions(sessions):
    child = sessions.spawn()
    for length, tag, version in [(131073, 2, 1), (0, 999, 1), (0, 2, 2)]:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.connect(str(sessions.runtime / "server.sock"))
            connection.sendall(struct.pack("<IHH", length, tag, version))
            connection.settimeout(3)
            assert connection.recv(4096)
    assert "ALIVE" in sessions.command(child, "printf 'ALIVE\\n'")


def test_detached_terminal_answers_queries(sessions):
    child = sessions.spawn()
    result_path = sessions.path / "query.json"
    command = f"{sys.executable} {ROOT / 'tests/terminal_query.py'} {result_path}"
    child.sendline(command)
    child.sendcontrol("\\")
    child.expect(pexpect.EOF)
    sessions.wait(result_path.exists)
    result = json.loads(result_path.read_text())
    assert result["response"] == "1b5b313b3152"


def test_invalid_shell_fails_without_creating_session(sessions):
    sessions.environment["SHELL"] = "/missing/imx-shell"
    child = sessions.spawn(initialize=False)
    child.expect_exact("ShellExecFailed")
    child.expect(pexpect.EOF)
    assert sessions.sessions() == []


def test_runtime_directory_permissions(sessions):
    sessions.runtime.mkdir(mode=0o755)
    result = sessions.run("list", check=False)
    assert result.returncode != 0
    assert "UnsafeRuntimeDirectory" in result.stderr
    sessions.runtime.chmod(0o700)


def test_frontend_restores_terminal_attributes(sessions):
    child = pexpect.spawn(
        "/bin/bash", ["--noprofile", "--norc"], env=sessions.environment,
        cwd=str(sessions.path), dimensions=(24, 80), encoding="utf-8", timeout=10,
    )
    sessions.clients.append(child)
    child.sendline("stty -g > before; imx attach attributes")
    child.expect(r"[#$] ")
    child.sendcontrol("\\")
    child.expect(r"[#$] ")
    child.sendline("stty -g > after; printf '\\nATTRIBUTES_SAVED\\n'")
    child.expect_exact("\r\nATTRIBUTES_SAVED\r\n")
    assert (sessions.path / "before").read_text() == (sessions.path / "after").read_text()


def test_vim_survives_detach_and_restores_document(sessions):
    document = sessions.path / "document.txt"
    document.write_text("VIM_DOCUMENT_MARKER\n真实文档内容\n")
    child = sessions.spawn()
    sessions.command(child, "printf 'BEFORE_VIM\\n'")
    child.sendline("vim -u NONE -i NONE -n document.txt")
    child.expect_exact("VIM_DOCUMENT_MARKER")
    child.sendcontrol("\\")
    child.expect(pexpect.EOF)
    assert "VIM_DOCUMENT_MARKER" in sessions.run("cat", "dev").stdout
    attached = sessions.spawn(initialize=False)
    attached.expect_exact("VIM_DOCUMENT_MARKER")
    attached.send(":q!\r")
    attached.expect_exact("IMX_PROMPT> ")
    assert "BEFORE_VIM" in sessions.run("cat", "dev").stdout


def test_slow_terminal_detaches_without_stopping_output(sessions):
    child = sessions.spawn()
    done = sessions.path / "slow-output.done"
    child.sendline(f"seq 1 1000000; printf DONE > '{done}'")
    sessions.wait(done.exists, timeout=30)
    sessions.wait(lambda: sessions.sessions()[0]["CLIENTS"] == "0")
    sessions.wait(lambda: "1000000\n" in sessions.run("cat", "dev").stdout)
    child.close(force=True)
