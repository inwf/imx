import os
import shutil
import subprocess

import pexpect
import psutil
import pytest

from test_install import ARCHIVE, VERSION, downloaded, native_package


@pytest.mark.parametrize("inside", [False, True])
def test_forced_update_preserves_installation_and_running_session(downloaded, inside):
    assert downloaded.install().returncode == 0
    downloaded.environment["PATH"] = f"{downloaded.binary.parent}:{downloaded.environment['PATH']}"
    downloaded.environment["IMX_PREFIX"] = str(downloaded.path / "another prefix")
    child = downloaded.spawn()
    other = downloaded.spawn("worker")
    downloaded.command(other, "export WORKER_MARKER=retained; printf 'WORKER_HISTORY\\n'")
    downloaded.command(child, "export UPDATE_MARKER=retained; printf 'UPDATE_HISTORY\\n'")
    pid = downloaded.sessions()[0]["PID"]
    pids = {row["NAME"]: row["PID"] for row in downloaded.sessions()}
    inode = downloaded.binary.stat().st_ino
    requests = len(downloaded.requests)
    if inside:
        output = downloaded.command(child, "imx update --force")
        assert "Downloading imx" in output
        assert "100.0%" in output
    else:
        result = downloaded.run("update", "--force")
        output = result.stdout
        assert "Downloading imx" in result.stderr
        assert "100.0%" not in result.stderr
    assert f"Installed imx {VERSION}: {downloaded.binary}" in output
    assert downloaded.binary.stat().st_ino != inode
    assert downloaded.run("-v").stdout == f"imx {VERSION}\n"
    assert not (downloaded.path / "another prefix").exists()
    assert downloaded.sessions()[0]["PID"] == pid
    assert {row["NAME"]: row["PID"] for row in downloaded.sessions()} == pids
    assert "retained" in downloaded.command(other, "printf '%s\\n' \"$WORKER_MARKER\"")
    assert "WORKER_HISTORY" in downloaded.run("cat", "worker").stdout
    assert "UPDATE_HISTORY" in downloaded.run("cat", "dev").stdout
    assert "retained" in downloaded.command(child, "printf '%s\\n' \"$UPDATE_MARKER\"")
    assert "/releases/latest/download/VERSION" in downloaded.requests[requests:]
    assert f"/releases/download/v{VERSION}/{ARCHIVE}" in downloaded.requests[requests:]
    downloaded.assert_no_temporary_files()
    child.send("\x1b\\")
    child.expect(pexpect.EOF)
    attached = downloaded.spawn(initialize=False)
    attached.expect_exact("IMX_PROMPT> ")
    assert downloaded.sessions()[0]["PID"] == pid
    downloaded.spawn("fresh")
    current = {row["NAME"]: row for row in downloaded.sessions()}
    fresh_backend = psutil.Process(int(current["fresh"]["PID"])).ppid()
    assert os.stat(f"/proc/{fresh_backend}/exe").st_ino == downloaded.binary.stat().st_ino
    for shell_pid in pids.values():
        backend = psutil.Process(int(shell_pid)).ppid()
        assert os.stat(f"/proc/{backend}/exe").st_ino == inode


def test_update_through_symbolic_link(downloaded):
    assert downloaded.install().returncode == 0
    alias = downloaded.path / "imx alias"
    alias.symlink_to(downloaded.binary)
    inode = downloaded.binary.stat().st_ino
    result = subprocess.run([str(alias), "update", "--force"], env=downloaded.environment, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    assert downloaded.binary.stat().st_ino != inode
    assert alias.is_symlink()
    assert downloaded.run("-v").stdout == f"imx {VERSION}\n"
    downloaded.assert_no_temporary_files()


@pytest.mark.parametrize("failure", ["corrupt", "missing-archive", "missing-version"])
def test_failed_update_preserves_installation_and_session(downloaded, failure):
    assert downloaded.install().returncode == 0
    child = downloaded.spawn()
    downloaded.command(child, "printf 'UPDATE_FAILURE_HISTORY\\n'")
    inode = downloaded.binary.stat().st_ino
    pid = downloaded.sessions()[0]["PID"]
    if failure == "corrupt":
        with (downloaded.release / ARCHIVE).open("ab") as stream:
            stream.write(b"corrupted download")
    elif failure == "missing-archive":
        (downloaded.release / ARCHIVE).unlink()
    else:
        (downloaded.path / "releases/latest/download/VERSION").unlink()
    result = downloaded.run("update", "--force", check=False)
    assert result.returncode != 0
    assert downloaded.binary.stat().st_ino == inode
    assert downloaded.sessions()[0]["PID"] == pid
    assert "UPDATE_FAILURE_HISTORY" in downloaded.run("cat", "dev").stdout
    assert "ALIVE" in downloaded.command(child, "printf 'ALIVE\\n'")
    downloaded.assert_no_temporary_files()


@pytest.mark.parametrize("arguments", [(), ("--check",)])
@pytest.mark.parametrize("inside", [False, True])
def test_current_version_check_preserves_files_and_session(downloaded, arguments, inside):
    assert downloaded.install().returncode == 0
    downloaded.environment["PATH"] = f"{downloaded.binary.parent}:{downloaded.environment['PATH']}"
    child = downloaded.spawn()
    downloaded.command(child, "export UPDATE_CHECK_MARKER=retained")
    initial = downloaded.sessions()[0]
    prefix = downloaded.binary.parent.parent
    files = {path: (path.stat().st_ino, path.stat().st_mtime_ns) for path in prefix.rglob("*") if path.is_file()}
    requests = len(downloaded.requests)
    if inside:
        output = downloaded.command(child, "imx update" + (" --check" if arguments else ""))
    else:
        output = downloaded.run("update", *arguments).stdout
    assert f"Already up to date (imx {VERSION})." in output
    assert "Downloading imx" not in output
    assert downloaded.requests[requests:] == ["/releases/latest/download/VERSION"]
    assert downloaded.sessions()[0] == initial
    assert "retained" in downloaded.command(child, "printf '%s\\n' \"$UPDATE_CHECK_MARKER\"")
    assert {path: (path.stat().st_ino, path.stat().st_mtime_ns) for path in prefix.rglob("*") if path.is_file()} == files
    downloaded.assert_no_temporary_files()


def test_update_check_does_not_create_configuration_cache_or_runtime(downloaded):
    assert downloaded.install().returncode == 0
    shutil.rmtree(downloaded.path / "cache")
    result = downloaded.run("update", "--check")
    assert f"Already up to date (imx {VERSION})." in result.stdout
    assert not (downloaded.path / "cache").exists()
    assert not downloaded.runtime.exists()
    assert not (downloaded.home / ".config").exists()
    assert not (downloaded.home / ".local/state/imx").exists()


def test_update_rejects_conflicting_modes_before_network_or_installation(downloaded):
    assert downloaded.install().returncode == 0
    requests = len(downloaded.requests)
    inode = downloaded.binary.stat().st_ino
    result = downloaded.run("update", "--check", "--force", check=False)
    assert result.returncode == 1
    assert "cannot be combined" in result.stderr
    assert downloaded.requests[requests:] == []
    assert downloaded.binary.stat().st_ino == inode


@pytest.mark.parametrize("contents", ["invalid\n", "0.6.0\n0.7.0\n", "", "x" * 4097])
def test_update_rejects_invalid_release_metadata_before_installation(downloaded, contents):
    assert downloaded.install().returncode == 0
    (downloaded.path / "releases/latest/download/VERSION").write_text(contents)
    requests = len(downloaded.requests)
    inode = downloaded.binary.stat().st_ino
    result = downloaded.run("update", "--check", check=False)
    assert result.returncode == 1
    assert result.stdout == ""
    assert downloaded.requests[requests:] == ["/releases/latest/download/VERSION"]
    assert downloaded.binary.stat().st_ino == inode
    downloaded.assert_no_temporary_files()


def test_update_requires_bash(downloaded):
    assert downloaded.install().returncode == 0
    environment = downloaded.environment.copy()
    programs = downloaded.path / "curl-only"
    programs.mkdir()
    (programs / "curl").symlink_to(shutil.which("curl"))
    environment["PATH"] = str(programs)
    inode = downloaded.binary.stat().st_ino
    result = subprocess.run([str(downloaded.binary), "update", "--check"], env=environment, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert "Already up to date" in result.stdout
    result = subprocess.run([str(downloaded.binary), "update", "--force"], env=environment, capture_output=True, text=True, timeout=10)
    assert result.returncode != 0
    assert "Cannot start Bash" in result.stderr
    assert downloaded.binary.stat().st_ino == inode
    assert os.access(downloaded.binary, os.X_OK)
    downloaded.assert_no_temporary_files()


def test_update_honors_path_when_curl_is_unavailable(downloaded):
    assert downloaded.install().returncode == 0
    environment = downloaded.environment.copy()
    environment["PATH"] = str(downloaded.path / "missing programs")
    inode = downloaded.binary.stat().st_ino
    requests = len(downloaded.requests)
    result = subprocess.run([str(downloaded.binary), "update", "--check"], env=environment, capture_output=True, text=True, timeout=10)
    assert result.returncode == 1
    assert "Cannot run curl" in result.stderr
    assert downloaded.requests[requests:] == []
    assert downloaded.binary.stat().st_ino == inode
    downloaded.assert_no_temporary_files()
