import csv
import io
import os
from pathlib import Path
import subprocess
import time
import uuid

import pexpect
import pytest


ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("IMX_BINARY", ROOT / "zig-out/bin/imx")).resolve()


class SessionEnvironment:
    def __init__(self):
        self.path = ROOT / "work/t" / uuid.uuid4().hex[:8]
        self.path.mkdir(parents=True)
        self.runtime = self.path / "run"
        self.home = self.path / "home"
        self.home.mkdir(mode=0o700)
        self.environment = os.environ.copy()
        self.environment.pop("IMX_SESSION", None)
        self.environment.pop("ZMX_SESSION", None)
        self.environment.update(
            IMX_DIR=str(self.runtime),
            HOME=str(self.home),
            XDG_CONFIG_HOME=str(self.home / ".config"),
            SHELL="/bin/bash",
            TERM="xterm-256color",
            PATH=f"{BINARY.parent}:{self.environment['PATH']}",
        )
        self.clients = []
        self.binary = BINARY

    def run(self, *args, check=True, **kwargs):
        return subprocess.run(
            [str(self.binary), *args],
            env=self.environment,
            cwd=self.path,
            capture_output=True,
            text=True,
            check=check,
            timeout=10,
            **kwargs,
        )

    def sessions(self):
        output = self.run("list").stdout
        if output == "No sessions.\n":
            return []
        return list(csv.DictReader(io.StringIO(output), delimiter="\t"))

    def spawn(self, name="dev", initialize=True, rows=24, cols=80):
        child = pexpect.spawn(
            str(self.binary),
            ["attach", name],
            cwd=str(self.path),
            env=self.environment,
            dimensions=(rows, cols),
            encoding="utf-8",
            timeout=10,
        )
        child.delaybeforesend = 0
        self.clients.append(child)
        if initialize:
            child.expect(r"[#$] ")
            child.sendline("stty -echo; PS1='IMX_PROMPT> '; PROMPT_COMMAND=; printf '\\nINITIALIZED\\n'")
            child.expect_exact("\r\nINITIALIZED\r\n")
            child.expect_exact("IMX_PROMPT> ")
        return child

    def command(self, child, command):
        marker = f"IMX_DONE_{uuid.uuid4().hex}"
        child.sendline(f"{command}; printf '\\n{marker}\\n'")
        child.expect_exact(f"\r\n{marker}\r\n")
        output = child.before
        child.expect_exact("IMX_PROMPT> ")
        return output

    def wait(self, condition, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = condition()
            if result:
                return result
            time.sleep(0.02)
        raise AssertionError("条件未在限定时间内满足")

    def cleanup(self):
        for session in self.sessions():
            self.run("kill", session["NAME"])
        for child in self.clients:
            child.close(force=True)
        self.wait(lambda: not (self.runtime / "server.sock").exists())
        log = self.runtime / "server.log"
        if log.exists():
            assert log.read_text() == ""


@pytest.fixture
def sessions():
    environment = SessionEnvironment()
    yield environment
    environment.cleanup()
