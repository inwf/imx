from functools import partial
import hashlib
from http.server import HTTPServer, SimpleHTTPRequestHandler
import multiprocessing
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import uuid

import pexpect
import pytest

from conftest import BINARY, ROOT, SessionEnvironment
from completion_shell import COMPLETION_FILES


ARCHITECTURE = platform.machine()
VERSION = subprocess.run([str(BINARY), "-v"], check=True, capture_output=True, text=True).stdout.split()[1]
ARCHIVE = f"imx-linux-{ARCHITECTURE}.tar.gz"


def checksum(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


class DownloadInstallation(SessionEnvironment):
    def __init__(self):
        super().__init__()
        self.home.rename(self.path / "home with spaces")
        self.home = self.path / "home with spaces"
        self.environment.update(HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / ".config"), XDG_CACHE_HOME=str(self.path / "cache"))
        self.environment.pop("IMX_PREFIX", None)
        self.binary = self.home / ".local/bin/imx"
        self.environment["IMX_PREFIX"] = str(self.binary.parent.parent)
        self.release = self.path / "releases/download" / f"v{VERSION}"
        self.release.mkdir(parents=True)

    @property
    def requests(self):
        while self.connection.poll():
            self.recorded_requests.append(self.connection.recv())
        return self.recorded_requests

    def install(self, tag=None):
        # curl 和 Bash 通过真实管道执行，HTTP 服务提供实际构建的软件包。
        download = subprocess.Popen(
            ["curl", "-fsSL", f"{self.environment['IMX_RELEASE_BASE_URL']}/download/v{VERSION}/install.sh"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.environment,
        )
        try:
            result = subprocess.run(
                ["bash", *(["-s", "--", tag] if tag else [])], stdin=download.stdout,
                capture_output=True, text=True, env=self.environment, cwd=self.path, timeout=30,
            )
            download.stdout.close()
            _, error = download.communicate(timeout=10)
            assert download.returncode == 0, error.decode()
            return result
        finally:
            if download.poll() is None:
                download.kill()
                download.wait()

    def checksums(self, names=None):
        if names is None:
            names = [ARCHIVE, "VERSION", "install.sh"]
        (self.release / "SHA256SUMS").write_text(
            "".join(f"{checksum(self.release / name)}  {name}\n" for name in names)
        )

    def assert_no_temporary_files(self):
        assert not list((self.path / "cache").glob("imx-install.*"))
        assert not list(self.binary.parent.glob(".imx-install.*"))


@pytest.fixture(scope="module")
def native_package():
    directory = ROOT / "work/install-tests" / uuid.uuid4().hex
    subprocess.run(
        ["python", str(ROOT / "scripts/release.py"), "package", "--arch", ARCHITECTURE,
         "--output", str(directory), "--tag", f"v{VERSION}"],
        check=True, cwd=ROOT, capture_output=True, timeout=30,
    )
    return directory / ARCHIVE


def serve_directory(directory, connection):
    class Handler(SimpleHTTPRequestHandler):
        def do_GET(self):
            connection.send(self.path)
            super().do_GET()

        def log_message(self, format, *args):
            pass

    with HTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(directory))) as server:
        connection.send(server.server_port)
        server.serve_forever()


@pytest.fixture
def downloaded(native_package):
    installation = DownloadInstallation()
    shutil.copy2(native_package, installation.release / ARCHIVE)
    shutil.copy2(ROOT / "install.sh", installation.release / "install.sh")
    (installation.release / "VERSION").write_text(VERSION + "\n")
    installation.checksums()
    latest = installation.path / "releases/latest/download"
    latest.mkdir(parents=True)
    shutil.copy2(installation.release / "VERSION", latest / "VERSION")
    context = multiprocessing.get_context("spawn")
    connection, sender = context.Pipe(duplex=False)
    process = context.Process(target=serve_directory, args=(installation.path, sender))
    process.start()
    sender.close()
    assert connection.poll(10), "HTTP 服务未启动"
    port = connection.recv()
    installation.connection = connection
    installation.recorded_requests = []
    installation.environment["IMX_RELEASE_BASE_URL"] = f"http://127.0.0.1:{port}/releases"
    try:
        yield installation
    finally:
        process.terminate()
        process.join(timeout=10)
        assert not process.is_alive()
        connection.close()
        if installation.binary.exists():
            installation.run("uninstall")
        for child in installation.clients:
            child.close(force=True)


@pytest.mark.parametrize("tag", [None, f"v{VERSION}"])
def test_download_install_and_uninstall(downloaded, tag):
    result = downloaded.install(tag)
    assert result.returncode == 0, result.stderr
    assert "Fetching release information..." in result.stderr
    assert f"Downloading imx {VERSION} ({ARCHITECTURE})..." in result.stderr
    assert "Verifying SHA256 checksum..." in result.stderr
    assert f"Installing imx {VERSION} to " in result.stderr
    assert "100.0%" not in result.stderr
    assert downloaded.run("-v").stdout == f"imx {VERSION}\n"
    assert os.access(downloaded.binary, os.X_OK)
    assert f"Installed imx {VERSION}:" in result.stdout
    license_root = downloaded.binary.parent.parent / "share/licenses/imx"
    source = BINARY.parent.parent / "share/licenses/imx"
    files = [path.relative_to(source) for path in source.rglob("*") if path.is_file()]
    assert len(files) >= 3
    for relative in files:
        assert (source / relative).read_bytes() == (license_root / relative).read_bytes()
    for relative in COMPLETION_FILES:
        path = downloaded.binary.parent.parent / relative
        assert path.read_bytes() == (BINARY.parent.parent / relative).read_bytes()
        assert path.stat().st_mode & 0o777 == 0o644
    if tag is None:
        assert "/releases/latest/download/VERSION" in downloaded.requests
    assert f"/releases/download/v{VERSION}/{ARCHIVE}" in downloaded.requests
    assert not any("latest" in request and not request.endswith("VERSION") for request in downloaded.requests)
    downloaded.assert_no_temporary_files()
    downloaded.run("uninstall")
    assert not downloaded.binary.exists()
    assert not license_root.exists()
    assert all(not (downloaded.binary.parent.parent / name).exists() for name in COMPLETION_FILES)
    assert not (downloaded.home / ".local/state/imx").exists()


def test_package_contains_standard_completion_files(native_package):
    with tarfile.open(native_package) as archive:
        for relative in COMPLETION_FILES:
            entry = archive.getmember(relative)
            assert entry.isfile()
            assert entry.mode == 0o644
            with archive.extractfile(entry) as content:
                assert content.read() == (BINARY.parent.parent / relative).read_bytes()


@pytest.mark.parametrize("failure", ["missing-completion", "completion-symlink", "missing-licenses"])
def test_package_rejects_incomplete_installation(sessions, native_package, failure):
    prefix = sessions.path / "package-source"
    output = sessions.path / "package"
    with tarfile.open(native_package) as archive:
        archive.extractall(prefix, filter="data")
    if failure == "missing-licenses":
        shutil.rmtree(prefix / "share/licenses")
    else:
        completion = prefix / COMPLETION_FILES[0]
        completion.unlink()
        if failure == "completion-symlink":
            completion.symlink_to(BINARY.parent.parent / COMPLETION_FILES[0])
    result = subprocess.run(
        ["python", str(ROOT / "scripts/release.py"), "package", "--arch", ARCHITECTURE,
         "--prefix", str(prefix), "--output", str(output)],
        capture_output=True, text=True, cwd=ROOT, timeout=30,
    )
    assert result.returncode != 0
    assert "不完整" in result.stderr
    assert not output.exists()


def test_download_custom_prefix(downloaded):
    prefix = downloaded.path / "custom prefix"
    downloaded.environment["IMX_PREFIX"] = str(prefix)
    downloaded.binary = prefix / "bin/imx"
    result = downloaded.install()
    assert result.returncode == 0, result.stderr
    assert downloaded.run("-v").stdout == f"imx {VERSION}\n"
    downloaded.assert_no_temporary_files()
    downloaded.run("uninstall")
    assert not prefix.exists()


@pytest.mark.parametrize("failure", ["corrupt", "missing-checksum", "missing-archive", "wrong-version", "missing-version"])
def test_failed_download_preserves_installation(downloaded, failure):
    assert downloaded.install().returncode == 0
    original_inode = downloaded.binary.stat().st_ino
    if failure == "corrupt":
        with (downloaded.release / ARCHIVE).open("ab") as stream:
            stream.write(b"corrupted download")
    elif failure == "missing-checksum":
        downloaded.checksums(["VERSION", "install.sh"])
    elif failure == "missing-archive":
        (downloaded.release / ARCHIVE).unlink()
    elif failure == "wrong-version":
        latest = downloaded.path / "releases/latest/download/VERSION"
        latest.write_text("999.0.0\n")
    else:
        (downloaded.path / "releases/latest/download/VERSION").unlink()
    result = downloaded.install()
    assert result.returncode != 0
    assert "Installed imx" not in result.stdout
    assert "Installing imx" not in result.stderr
    assert downloaded.binary.stat().st_ino == original_inode
    assert downloaded.run("-v").stdout == f"imx {VERSION}\n"
    downloaded.assert_no_temporary_files()


def test_reinstall_preserves_running_session(downloaded):
    assert downloaded.install().returncode == 0
    downloaded.environment["PATH"] = f"{downloaded.binary.parent}:{downloaded.environment['PATH']}"
    child = downloaded.spawn()
    downloaded.command(child, "export INSTALL_MARKER=retained; printf 'REINSTALL_HISTORY\\n'")
    original_pid = downloaded.sessions()[0]["PID"]
    original_inode = downloaded.binary.stat().st_ino
    result = downloaded.install()
    assert result.returncode == 0, result.stderr
    assert downloaded.binary.stat().st_ino != original_inode
    assert downloaded.sessions()[0]["PID"] == original_pid
    assert "REINSTALL_HISTORY" in downloaded.run("cat", "dev").stdout
    assert "retained" in downloaded.command(child, "printf '%s\\n' \"$INSTALL_MARKER\"")
    child.send("\x1b\\")
    child.expect(pexpect.EOF)
    attached = downloaded.spawn(initialize=False)
    attached.expect_exact("IMX_PROMPT> ")
    assert downloaded.sessions()[0]["PID"] == original_pid
    downloaded.run("uninstall")
    attached.expect(pexpect.EOF)
    assert not downloaded.binary.exists()
    assert not downloaded.runtime.exists()
    downloaded.assert_no_temporary_files()


def test_download_uninstall_preserves_user_files(downloaded):
    assert downloaded.install().returncode == 0
    document = downloaded.home / "document.txt"
    document.write_text("用户文档")
    notes = downloaded.binary.parent.parent / "share/licenses/imx/notes.txt"
    notes.write_text("用户安装记录")
    downloaded.run("uninstall")
    assert document.read_text() == "用户文档"
    assert notes.read_text() == "用户安装记录"
    assert not downloaded.binary.exists()
    downloaded.assert_no_temporary_files()


@pytest.mark.parametrize("failure", ["tag", "architecture"])
def test_package_rejects_inconsistent_metadata(downloaded, failure):
    arguments = ["python", str(ROOT / "scripts/release.py"), "package", "--output", str(downloaded.path / "package")]
    if failure == "tag":
        arguments += ["--tag", "v999.0.0"]
    else:
        other = "aarch64" if ARCHITECTURE == "x86_64" else "x86_64"
        arguments += ["--arch", other]
    result = subprocess.run(arguments, capture_output=True, cwd=ROOT, timeout=30)
    assert result.returncode != 0
    assert not (downloaded.path / "package").exists()
