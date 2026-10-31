from concurrent.futures import ThreadPoolExecutor
import csv
from datetime import datetime, timedelta, timezone
import io
import json
import socket
import struct
from threading import Barrier
import tomllib

import pytest

from test_prompt import configuration, enter, settings, setup_shell


DEFAULT_SETTINGS = {
    "prompt": {"show_session": False},
    "list": {"created_format": "%m-%d %H:%M:%S"},
    "completion": {"enabled": True},
}


@pytest.mark.parametrize("arguments", [(), ("ls",), ("list",), ("attach",)])
@pytest.mark.parametrize("location", ["home", "empty", "xdg"])
def test_first_use_creates_default_configuration(sessions, arguments, location):
    if location == "home":
        sessions.environment.pop("XDG_CONFIG_HOME")
    elif location == "empty":
        sessions.environment["XDG_CONFIG_HOME"] = ""
    else:
        sessions.environment["XDG_CONFIG_HOME"] = str(sessions.path / "配置 with spaces")
    path = configuration(sessions)
    assert not path.exists()
    if arguments == ("attach",):
        sessions.spawn()
    else:
        assert sessions.run(*arguments).stdout == "No sessions.\n"
    assert tomllib.loads(path.read_text()) == DEFAULT_SETTINGS
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.parent.stat().st_mode & 0o777 == 0o700
    assert list(path.parent.iterdir()) == [path]
    if location == "xdg":
        assert not (sessions.home / ".config/imx").exists()
    assert sessions.run("__complete", "commands", "a").stdout == "attach\n"


@pytest.mark.parametrize("linked", [False, True])
def test_existing_configuration_is_preserved(sessions, linked):
    path = configuration(sessions)
    path.parent.mkdir(parents=True)
    target = sessions.path / "user-config.toml" if linked else path
    contents = "# 用户配置\n[list]\ncreated_format = '%Y'\n[completion]\nenabled = false\n"
    target.write_text(contents)
    target.chmod(0o640)
    if linked:
        path.symlink_to(target)
    before = target.stat()
    sessions.run("ls")
    sessions.spawn()
    after = target.stat()
    assert target.read_text() == contents
    assert (after.st_ino, after.st_mode, after.st_mtime_ns) == (before.st_ino, before.st_mode, before.st_mtime_ns)
    assert path.is_symlink() == linked
    assert sessions.run("__complete", "commands", "a").stdout == ""


def test_concurrent_first_use_creates_complete_configuration(sessions):
    path = configuration(sessions)
    barrier = Barrier(16)

    def launch(_):
        barrier.wait(timeout=10)
        result = sessions.run("ls")
        assert result.stdout == "No sessions.\n"
        return tomllib.loads(path.read_text())

    with ThreadPoolExecutor(max_workers=16) as pool:
        results = list(pool.map(launch, range(16)))
    assert all(value == DEFAULT_SETTINGS for value in results)
    assert list(path.parent.iterdir()) == [path]


@pytest.mark.parametrize("arguments", [("help",), ("-v",), ("__complete", "commands", ""), ("__complete", "sessions", "")])
def test_information_queries_do_not_create_configuration(sessions, arguments):
    sessions.run(*arguments)
    assert not configuration(sessions).parent.exists()


def test_missing_configuration_symlink_target_is_preserved(sessions):
    path = configuration(sessions)
    path.parent.mkdir(parents=True)
    target = sessions.path / "missing-config.toml"
    path.symlink_to(target)
    result = sessions.run("ls", check=False)
    assert result.returncode == 1
    assert "FileNotFound" in result.stderr
    assert path.is_symlink()
    assert not target.exists()
    assert list(path.parent.iterdir()) == [path]
    assert not sessions.runtime.exists()
    path.unlink()


def list_settings(environment, created_format):
    path = configuration(environment)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"[list]\ncreated_format = {json.dumps(created_format, ensure_ascii=False)}\n")
    return path


@pytest.mark.parametrize("hours", [0, 14, -12])
def test_created_format_updates_running_sessions(sessions, hours):
    sessions.environment["TZ"] = f"UTC{-hours:+d}"
    zone = timezone(timedelta(hours=hours))
    before = int(datetime.now().timestamp())
    child = sessions.spawn()
    after = int(datetime.now().timestamp())
    original = sessions.sessions()[0]
    path = list_settings(sessions, "%s")
    epoch = int(sessions.sessions()[0]["CREATED"])
    assert before <= epoch <= after
    created = datetime.fromtimestamp(epoch, zone)
    assert original["CREATED"] == created.strftime("%m-%d %H:%M:%S")

    sessions.environment["TZ"] = "UTC0"
    for created_format in ["%Y-%m-%d %H:%M:%S", "%d/%m/%Y %I:%M:%S %p", "%Y年%m月%d日 %H:%M", "%F %T %z", "%Y %%"]:
        list_settings(sessions, created_format)
        for arguments in [(), ("ls",), ("list",)]:
            listing = sessions.run(*arguments).stdout
            rows = list(csv.DictReader(io.StringIO(listing), delimiter="\t"))
            assert len(rows) == 1
            assert rows[0] == {**original, "CREATED": created.strftime(created_format)}
        output = sessions.command(child, "imx ls")
        assert created.strftime(created_format) in output
        assert "\t" not in output

    path.unlink()
    assert sessions.sessions()[0] == original


def test_prompt_and_created_format_share_configuration(sessions):
    setup_shell(sessions, "bash")
    settings(sessions, True)
    with configuration(sessions).open("a") as stream:
        stream.write("\n[list]\ncreated_format = '%s'\n")
    before = int(datetime.now().timestamp())
    child = enter(sessions)
    after = int(datetime.now().timestamp())
    assert before <= int(sessions.sessions()[0]["CREATED"]) <= after
    child.sendline("true")
    child.expect_exact("[dev] BASE:~> ")


def test_created_format_uses_xdg_configuration_directory(sessions):
    sessions.environment["XDG_CONFIG_HOME"] = str(sessions.path / "configuration with spaces")
    path = list_settings(sessions, "%s")
    assert path == sessions.path / "configuration with spaces/imx/config.toml"
    before = int(datetime.now().timestamp())
    sessions.spawn()
    after = int(datetime.now().timestamp())
    assert before <= int(sessions.sessions()[0]["CREATED"]) <= after
    assert not (sessions.home / ".config/imx/config.toml").exists()


@pytest.mark.parametrize("value, error", [
    (b"list = false\n", "InvalidListConfiguration"),
    (b"[list]\ncreated_format = false\n", "ListCreatedFormatMustBeString"),
    (b"[list]\ncreated_formats = '%Y'\n", "UnknownConfigurationOption"),
    (b"[list]\ncreated_format = ''\n", "InvalidCreatedFormat"),
    (b"[list]\ncreated_format = '%Q'\n", "InvalidCreatedFormat"),
    (b"[list]\ncreated_format = '%'\n", "InvalidCreatedFormat"),
    (b"[list]\ncreated_format = '%n'\n", "InvalidCreatedFormat"),
    (b"[list]\ncreated_format = '%t'\n", "InvalidCreatedFormat"),
    (b'[list]\ncreated_format = "\\u0000"\n', "InvalidCreatedFormat"),
    (b'[list]\ncreated_format = "\\u007f"\n', "InvalidCreatedFormat"),
    (b"[list]\ncreated_format = '" + b"x" * 257 + b"'\n", "InvalidCreatedFormat"),
    (b"[list]\ncreated_format = '" + b"%c" * 127 + b"'\n", "InvalidCreatedFormat"),
])
def test_invalid_list_configuration_fails_before_creating_runtime(sessions, value, error):
    path = list_settings(sessions, "%Y")
    path.write_bytes(value)
    results = [sessions.run(*arguments, check=False) for arguments in [(), ("ls",), ("list",)]]
    path.unlink()
    for result in results:
        assert result.returncode == 1
        assert error in result.stderr
        assert result.stdout == ""
    assert not sessions.runtime.exists()
    assert not (sessions.home / ".local/state/imx").exists()


@pytest.mark.parametrize("payload, error", [
    (b"{", b"InvalidMessage"),
    (b'{"created_format":false}', b"InvalidMessage"),
    (b'{"unknown":true}', b"InvalidMessage"),
    (b'{"created_format":"%n"}', b"InvalidCreatedFormat"),
    (b'{"created_format":"%Q"}', b"InvalidCreatedFormat"),
])
def test_invalid_list_requests_leave_sessions_running(sessions, payload, error):
    child = sessions.spawn()
    original = sessions.sessions()[0]
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(sessions.runtime / "session-dev.sock"))
        connection.sendall(struct.pack("<IHH", len(payload), 2, 1) + payload)
        response = bytearray()
        while chunk := connection.recv(4096):
            response.extend(chunk)
    assert response == struct.pack("<IHH", len(error), 10, 1) + error
    assert sessions.sessions()[0] == original
    assert "ALIVE" in sessions.command(child, "printf 'ALIVE\\n'")
