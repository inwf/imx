import csv
import io
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

import pexpect
import pyte
import pytest


ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("IMX_BINARY", ROOT / "zig-out/bin/imx")).resolve()


class TerminalScreen(pyte.Screen):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.saved_modes = {}

    def save_modes(self, *modes, private=False):
        if private:
            for mode in modes:
                self.saved_modes[mode] = (mode << 5) in self.mode
        else:
            self.save_cursor()

    def set_margins(self, *parameters, private=False):
        if private:
            for mode in parameters:
                if mode in self.saved_modes:
                    operation = self.set_mode if self.saved_modes[mode] else self.reset_mode
                    operation(mode, private=True)
        else:
            super().set_margins(*parameters)


class TerminalStream(pyte.Stream):
    csi = {**pyte.Stream.csi, "s": "save_modes"}
    events = pyte.Stream.events | {"save_modes"}


class ScreenProcess(pexpect.spawn):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        rows, cols = self.getwinsize()
        self.screen = TerminalScreen(cols, rows)
        self.stream = TerminalStream(self.screen)
        self.output_revision = 0
        self.sent_revision = -1

    def send(self, value):
        self.sent_revision = self.output_revision
        return super().send(value)

    def read_nonblocking(self, size=1, timeout=-1):
        data = super().read_nonblocking(size, timeout)
        rows, cols = self.getwinsize()
        if (rows, cols) != (self.screen.lines, self.screen.columns):
            self.screen.resize(rows, cols)
        self.stream.feed(data)
        self.output_revision += 1
        return data

    def wait_screen(self, condition, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            try:
                self.read_nonblocking(65536, timeout=0.02)
            except pexpect.TIMEOUT:
                pass
        raise AssertionError(f"终端画面未满足条件：{self.screen.display!r}")

    def expect_screen(self, text, timeout=10):
        self.wait_screen(lambda: any(text in row for row in self.screen.display), timeout)

    def expect_prompt(self, text=None, timeout=10):
        def ready():
            if self.output_revision <= self.sent_revision or self.screen.cursor.hidden:
                return False
            y = self.screen.cursor.y
            line = "".join(self.screen.buffer[y][x].data for x in range(self.screen.cursor.x))
            if line.startswith("│"):
                line = line[1:]
                while text is not None and len(line) < len(text) and y > 1:
                    y -= 1
                    line = self.screen.display[y][1:-1] + line
            return line == text if text is not None else re.search(r"(?:[#$] |IMX_PROMPT> )$", line)
        self.wait_screen(ready, timeout)


class SessionEnvironment:
    def __init__(self):
        self.path = ROOT / "work/t" / uuid.uuid4().hex[:8]
        self.path.mkdir(parents=True)
        self.runtime = self.path / "run"
        self.home = self.path / "home"
        self.home.mkdir(mode=0o700)
        self.environment = os.environ.copy()
        self.environment.pop("IMX_SESSION", None)
        self.environment.pop("IMX_SESSION_ID", None)
        self.environment.pop("ZMX_SESSION", None)
        self.environment.pop("ZDOTDIR", None)
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
        child = ScreenProcess(
            str(self.binary),
            ["attach", "--", name],
            cwd=str(self.path),
            env=self.environment,
            dimensions=(rows, cols),
            encoding="utf-8",
            timeout=10,
        )
        child.delaybeforesend = 0
        self.clients.append(child)
        if initialize:
            child.expect_prompt()
            child.sendline("stty -echo; PS1='IMX_PROMPT> '; PROMPT_COMMAND=; printf '\\nINITIAL%s\\n' IZED")
            child.expect_screen("INITIALIZED")
            child.expect_prompt("IMX_PROMPT> ")
        return child

    def command(self, child, command):
        marker = f"IMX_{uuid.uuid4().hex[:8]}"
        child.sendline(f"{command}; printf '\\n{marker}\\n'")
        child.expect_screen(marker)
        child.expect_prompt("IMX_PROMPT> ")
        rows = child.screen.display
        if rows[0].startswith("┌"):
            rows = [row[1:-1] for row in rows[1:-1]]
        return "\n".join(row.rstrip() for row in rows)

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
            self.run("kill", "--", session["NAME"])
        for child in self.clients:
            child.close(force=True)
        self.wait(lambda: not list(self.runtime.glob("*.sock")))
        for log in self.runtime.glob("*.log"):
            assert log.read_text() == ""


@pytest.fixture
def sessions():
    environment = SessionEnvironment()
    yield environment
    environment.cleanup()


@pytest.fixture
def mouse_mode(sessions):
    path = sessions.home / ".config/imx/config.toml"
    path.parent.mkdir(parents=True)
    path.write_text("[panes]\nmouse = true\n")
