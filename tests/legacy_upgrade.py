import argparse
from pathlib import Path
import shutil

import pexpect
import psutil

from conftest import BINARY, SessionEnvironment


def verify(prefix, terminate_legacy):
    environment = SessionEnvironment()
    destination = environment.path / "installation"
    shutil.copytree(prefix, destination)
    environment.binary = destination / "bin/imx"
    environment.environment["PATH"] = f"{environment.binary.parent}:{environment.environment['PATH']}"
    try:
        assert environment.run("-v").stdout == "imx 0.4.1\n"
        client = pexpect.spawn(str(environment.binary), ["attach", "legacy"],
                               cwd=str(environment.path), env=environment.environment,
                               dimensions=(24, 80), encoding="utf-8", timeout=10)
        environment.clients.append(client)
        client.expect(r"[#$] ")
        client.sendline("stty -echo; PS1='IMX_PROMPT> '; PROMPT_COMMAND=; printf '\\nINITIALIZED\\n'")
        client.expect_exact("\r\nINITIALIZED\r\n")
        client.expect_exact("IMX_PROMPT> ")
        environment.command(client, "export LEGACY_VALUE=retained; printf 'LEGACY_HISTORY\\n'")
        original = environment.sessions()[0]["PID"]
        assert (environment.runtime / "server.sock").exists()
        client.sendcontrol("\\")
        client.expect(pexpect.EOF)
        replacement = environment.binary.with_name("replacement")
        shutil.copy2(BINARY, replacement)
        replacement.replace(environment.binary)
        assert environment.sessions()[0]["PID"] == original
        assert environment.run("__complete", "sessions", "").stdout == "legacy\n"
        assert "LEGACY_HISTORY" in environment.run("cat", "legacy").stdout
        client = environment.spawn("legacy", initialize=False)
        client.expect_exact("IMX_PROMPT> ")
        assert "retained" in environment.command(client, "printf '%s\\n' \"$LEGACY_VALUE\"")
        output = environment.command(client, "imx attach target; printf 'SWITCH_STATUS=%s\\n' \"$?\"")
        assert "SwitchUnsupportedByBackend" in output and "SWITCH_STATUS=1" in output
        assert [row["NAME"] for row in environment.sessions()] == ["legacy"]
        if terminate_legacy:
            environment.run("kill", "legacy")
            client.expect(pexpect.EOF)
            environment.wait(lambda: not (environment.runtime / "server.sock").exists())
            environment.spawn("one")
            environment.spawn("two")
            backend_ids = {psutil.Process(int(row["PID"])).ppid() for row in environment.sessions()}
            assert len(backend_ids) == 2
        environment.run("uninstall")
        environment.wait(lambda: not environment.runtime.exists())
        assert not environment.binary.exists()
    finally:
        if environment.binary.exists():
            environment.cleanup()
        else:
            for child in environment.clients:
                child.close(force=True)


parser = argparse.ArgumentParser()
parser.add_argument("--legacy-prefix", type=Path, required=True)
arguments = parser.parse_args()
for terminate_legacy in [False, True]:
    verify(arguments.legacy_prefix.resolve(), terminate_legacy)
print("v0.4.1 upgrade, reattach, history, independent backends, and uninstall passed")
