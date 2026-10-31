from concurrent.futures import ThreadPoolExecutor
import os
import shlex
from threading import Barrier

import pexpect
import pytest

from test_prompt import enter, settings, setup_shell


@pytest.mark.parametrize("shell", ["bash", "zsh", "fish"])
def test_directory_tracks_cd_and_reattach(sessions, shell):
    setup_shell(sessions, shell)
    settings(sessions, True)
    child = enter(sessions)
    original = sessions.sessions()[0]
    assert original["DIRECTORY"] == str(sessions.home)
    directory = sessions.home / "项目 with spaces"
    directory.mkdir()
    child.sendline(f"cd {shlex.quote(str(directory))}; printf '\\nDIRECTORY_READY\\n'")
    child.expect_exact("\r\nDIRECTORY_READY\r\n")
    child.expect_exact("BASE:")
    current = sessions.sessions()[0]
    assert current["DIRECTORY"] == str(directory)
    assert current["PID"] == original["PID"]
    assert current["CREATED"] == original["CREATED"]
    child.sendcontrol("\\")
    child.expect(pexpect.EOF)
    sessions.path = sessions.home
    attached = sessions.spawn(initialize=False)
    attached.expect_exact("BASE:")
    assert sessions.sessions()[0]["DIRECTORY"] == str(directory)
    attached.sendline("cd ..; printf '\\nDIRECTORY_CHANGED\\n'")
    attached.expect_exact("\r\nDIRECTORY_CHANGED\r\n")
    assert sessions.sessions()[0]["DIRECTORY"] == str(sessions.home)


def test_directory_tracks_renaming_and_deletion(sessions):
    child = sessions.spawn()
    directory = sessions.path / "original"
    directory.mkdir()
    sessions.command(child, "cd original")
    renamed = directory.with_name("renamed")
    directory.rename(renamed)
    assert sessions.sessions()[0]["DIRECTORY"] == str(renamed)
    renamed.rmdir()
    assert sessions.sessions()[0]["DIRECTORY"] == f"{renamed} (deleted)"
    assert sessions.run("__complete", "sessions", "").stdout == "dev\n"
    sessions.command(child, f"cd {shlex.quote(str(sessions.path))}")
    assert sessions.sessions()[0]["DIRECTORY"] == str(sessions.path)


def test_directory_resolves_symbolic_links(sessions):
    child = sessions.spawn()
    real = sessions.path / "real"
    real.mkdir()
    (sessions.path / "alias").symlink_to(real, target_is_directory=True)
    sessions.command(child, "cd alias")
    assert sessions.sessions()[0]["DIRECTORY"] == str(real)


@pytest.mark.parametrize("name, shell_name, displayed", [
    (b"line\nbreak", "$'line\\nbreak'", r"line\nbreak"),
    (b"tab\tname", "$'tab\\tname'", r"tab\tname"),
    (b"escape\x1b[31m", "$'escape\\033[31m'", r"escape\x1b[31m"),
    (b"invalid\xff", "$'invalid\\377'", r"invalid\xff"),
    (b'quote"\\name', "$'quote\"\\\\name'", r'quote\"\\name'),
])
def test_directory_escapes_special_bytes(sessions, name, shell_name, displayed):
    child = sessions.spawn()
    os.mkdir(os.fsencode(sessions.path) + b"/" + name)
    sessions.command(child, f"cd {shell_name}")
    rows = sessions.sessions()
    assert len(rows) == 1
    assert rows[0]["DIRECTORY"] == f"{sessions.path}/{displayed}"
    assert rows[0]["STATUS"] == "running"
    output = sessions.command(child, "imx ls")
    assert displayed in output
    assert "\t" not in output


def test_directory_follows_session_shell_during_foreground_job(sessions):
    child = sessions.spawn()
    (sessions.path / "job-directory").mkdir()
    child.sendline("(cd job-directory; printf READY > ../job.ready; sleep 600)")
    sessions.wait(lambda: (sessions.path / "job.ready").exists())
    assert sessions.sessions()[0]["DIRECTORY"] == str(sessions.path)


def test_directory_tracks_program_replacing_shell(sessions):
    child = sessions.spawn()
    original_pid = sessions.sessions()[0]["PID"]
    directory = sessions.path / "exec-directory"
    directory.mkdir()
    child.sendline("exec sh -c 'cd exec-directory; printf READY > ../exec.ready; sleep 600'")
    sessions.wait(lambda: (sessions.path / "exec.ready").exists())
    row = sessions.sessions()[0]
    assert row["PID"] == original_pid
    assert row["DIRECTORY"] == str(directory)


def test_directory_queries_during_session_exit(sessions):
    healthy = sessions.spawn("healthy")
    exiting = [sessions.spawn(f"exiting-{index}") for index in range(8)]
    barrier = Barrier(2)

    def query():
        barrier.wait(timeout=10)
        for _ in range(40):
            rows = sessions.sessions()
            row = next(row for row in rows if row["NAME"] == "healthy")
            assert row["DIRECTORY"] == str(sessions.path)
            assert row["STATUS"] == "running"

    with ThreadPoolExecutor(max_workers=1) as pool:
        result = pool.submit(query)
        barrier.wait(timeout=10)
        for child in exiting:
            child.sendline("exit")
        for child in exiting:
            child.expect(pexpect.EOF)
        result.result(timeout=10)
    assert [row["NAME"] for row in sessions.sessions()] == ["healthy"]
    assert "DIRECTORY_ALIVE" in sessions.command(healthy, "printf 'DIRECTORY_ALIVE\\n'")
