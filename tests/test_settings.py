import csv
from datetime import datetime, timedelta, timezone
import io
import json
import socket
import struct

import pytest

from test_prompt import configuration, enter, settings, setup_shell


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
        connection.connect(str(sessions.runtime / "server.sock"))
        connection.sendall(struct.pack("<IHH", len(payload), 2, 1) + payload)
        response = bytearray()
        while chunk := connection.recv(4096):
            response.extend(chunk)
    assert response == struct.pack("<IHH", len(error), 10, 1) + error
    assert sessions.sessions()[0] == original
    assert "ALIVE" in sessions.command(child, "printf 'ALIVE\\n'")
