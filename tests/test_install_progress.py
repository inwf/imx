import io
import re
import shlex

import pexpect
import pytest

from test_install import ARCHITECTURE, VERSION, downloaded, native_package


def limit_download_rate(environment):
    # 使用 curl 的实际限速配置，验证下载过程中的进度。
    environment.environment["CURL_HOME"] = str(environment.home)
    (environment.home / ".curlrc").write_text("limit-rate = 256K\n")


def wait_for_download_progress(child):
    while True:
        child.expect(r"(\d+\.\d)%")
        percentage = float(child.match.group(1))
        if percentage > 0:
            assert percentage < 100
            return


@pytest.mark.parametrize("operation", ["install", "update"])
@pytest.mark.parametrize("redirect", ["terminal", "stdout", "stderr"])
def test_progress_follows_stderr_terminal(downloaded, operation, redirect):
    if operation == "update":
        assert downloaded.install().returncode == 0
        invocation = shlex.join([str(downloaded.binary), "update", "--force"])
    else:
        url = f"{downloaded.environment['IMX_RELEASE_BASE_URL']}/download/v{VERSION}/install.sh"
        invocation = f"curl -fsSL {shlex.quote(url)} | bash"
    limit_download_rate(downloaded)
    logfile = downloaded.path / "progress.log"
    command = f"set -o pipefail; {{ {invocation}; }}"
    if redirect != "terminal":
        descriptor = "1" if redirect == "stdout" else "2"
        command += f" {descriptor}>{shlex.quote(str(logfile))}"
    output = io.StringIO()
    child = pexpect.spawn(
        "/bin/bash", ["--noprofile", "--norc", "-c", command],
        env=downloaded.environment, cwd=str(downloaded.path),
        encoding="utf-8", dimensions=(24, 100), timeout=20,
    )
    child.logfile_read = output
    try:
        if redirect != "stderr":
            wait_for_download_progress(child)
        child.expect(pexpect.EOF)
    finally:
        child.close(force=True)
    assert child.exitstatus == 0, output.getvalue()

    messages = logfile.read_bytes().decode() if redirect == "stderr" else output.getvalue()
    stages = [
        "Fetching release information...",
        f"Downloading imx {VERSION} ({ARCHITECTURE})...",
        "Verifying SHA256 checksum...",
        "Extracting package...",
        f"Installing imx {VERSION} to {downloaded.binary.parent.parent}...",
    ]
    positions = [messages.index(stage) for stage in stages]
    assert positions == sorted(positions)
    if redirect == "stderr":
        assert "\r" not in messages
        assert re.search(r"\d+\.\d%", messages) is None
    else:
        assert "100.0%" in messages
    completed = logfile.read_text() if redirect == "stdout" else output.getvalue()
    assert f"Installed imx {VERSION}: {downloaded.binary}" in completed
    assert downloaded.run("-v").stdout == f"imx {VERSION}\n"
    downloaded.assert_no_temporary_files()


def test_cancel_download_preserves_installation_and_session(downloaded):
    assert downloaded.install().returncode == 0
    session = downloaded.spawn()
    downloaded.command(session, "printf 'DOWNLOAD_CANCEL_HISTORY\\n'")
    original_inode = downloaded.binary.stat().st_ino
    original_pid = downloaded.sessions()[0]["PID"]
    limit_download_rate(downloaded)
    output = io.StringIO()
    child = pexpect.spawn(
        str(downloaded.binary), ["update", "--force"], env=downloaded.environment,
        cwd=str(downloaded.path), encoding="utf-8", timeout=20,
    )
    child.logfile_read = output
    try:
        wait_for_download_progress(child)
        child.sendcontrol("c")
        child.expect(pexpect.EOF)
    finally:
        child.close(force=True)
    assert child.exitstatus != 0
    assert "Installed imx" not in output.getvalue()
    assert downloaded.binary.stat().st_ino == original_inode
    assert downloaded.sessions()[0]["PID"] == original_pid
    assert "DOWNLOAD_CANCEL_HISTORY" in downloaded.run("cat", "dev").stdout
    downloaded.wait(lambda: not list((downloaded.path / "cache").glob("imx-install.*")))
    downloaded.assert_no_temporary_files()
