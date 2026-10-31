from concurrent.futures import ThreadPoolExecutor
import fcntl
import os
import shutil
import subprocess
import termios

import pexpect
import psutil
import pytest

from conftest import BINARY, ROOT, SessionEnvironment
from completion_shell import COMPLETION_FILES
from test_prompt import BEGIN, configuration, enter, settings, setup_shell


@pytest.fixture
def installation():
    environment = SessionEnvironment()
    prefix = environment.path / "install"
    build_environment = os.environ.copy()
    build_environment["TMPDIR"] = str(ROOT / "work/runtime")
    subprocess.run(
        ["zig", "build", "--prefix", str(prefix)], cwd=ROOT,
        env=build_environment, check=True, capture_output=True, timeout=120,
    )
    environment.binary = prefix / "bin/imx"
    environment.environment["PATH"] = f"{environment.binary.parent}:{environment.environment['PATH']}"
    yield environment
    if environment.binary.exists():
        environment.cleanup()
    else:
        for child in environment.clients:
            child.close(force=True)


def state_directory(environment):
    return environment.home / ".local/state/imx"


def assert_removed(environment):
    assert not environment.binary.exists()
    assert not state_directory(environment).exists()
    assert not environment.runtime.exists()
    assert not configuration(environment).exists()
    assert BINARY.exists()
    assert (ROOT / "src/main.zig").exists()


def test_uninstall_unused_installation(installation):
    result = installation.run("uninstall")
    assert result.stdout == "imx uninstalled.\n"
    assert_removed(installation)
    assert not (installation.path / "install").exists()


def test_uninstall_terminates_sessions_and_jobs(installation):
    child = installation.spawn("dev")
    output = installation.command(child, "sleep 600 & printf '\\nJOB_PID=%s\\n' \"$!\"")
    job = int(next(line.split("=", 1)[1] for line in output.splitlines() if line.startswith("JOB_PID=")))
    second = installation.spawn("other")
    shells = [int(row["PID"]) for row in installation.sessions()]
    servers = [psutil.Process(pid).ppid() for pid in shells]
    assert len(set(servers)) == len(shells)
    installation.run("uninstall")
    child.expect(pexpect.EOF)
    second.expect(pexpect.EOF)
    installation.wait(lambda: not any(psutil.pid_exists(pid) for pid in [*servers, job, *shells]))
    assert_removed(installation)


def test_uninstall_cleans_all_registered_runtime_directories(installation):
    first_directory = installation.runtime
    first = installation.spawn("first")
    first.sendcontrol("\\")
    first.expect(pexpect.EOF)
    first_pid = int(installation.sessions()[0]["PID"])
    installation.runtime = installation.path / "another-runtime"
    installation.environment["IMX_DIR"] = str(installation.runtime)
    second = installation.spawn("second")
    second_pid = int(installation.sessions()[0]["PID"])
    second.sendcontrol("\\")
    second.expect(pexpect.EOF)
    installation.run("uninstall")
    installation.wait(lambda: not psutil.pid_exists(first_pid) and not psutil.pid_exists(second_pid))
    assert not first_directory.exists()
    assert_removed(installation)


def test_uninstall_terminates_paused_backend(installation):
    child = installation.spawn("paused")
    other = installation.spawn("healthy")
    processes = [psutil.Process(psutil.Process(int(row["PID"])).ppid())
                 for row in installation.sessions()]
    processes[0].suspend()
    try:
        installation.run("uninstall")
        child.expect(pexpect.EOF)
        other.expect(pexpect.EOF)
        installation.wait(lambda: not any(process.is_running() for process in processes))
        assert_removed(installation)
    finally:
        for process in processes:
            if process.is_running():
                process.resume()


def test_uninstall_default_runtime(installation):
    installation.environment.pop("IMX_DIR")
    installation.environment.pop("XDG_RUNTIME_DIR", None)
    installation.runtime = state_directory(installation) / "run"
    child = installation.spawn()
    installation.run("uninstall")
    child.expect(pexpect.EOF)
    assert_removed(installation)


def test_uninstall_xdg_runtime(installation):
    installation.environment.pop("IMX_DIR")
    xdg = installation.path / "xdg-runtime"
    xdg.mkdir(mode=0o700)
    installation.environment["XDG_RUNTIME_DIR"] = str(xdg)
    installation.runtime = xdg / "imx"
    child = installation.spawn()
    installation.run("uninstall")
    child.expect(pexpect.EOF)
    assert_removed(installation)
    assert xdg.exists()


def test_uninstall_runtime_with_symlink_parent(installation):
    parent = installation.path / ("long-directory-" * 12)
    parent.mkdir(mode=0o700)
    alias = installation.path / "short"
    alias.symlink_to(parent, target_is_directory=True)
    installation.runtime = alias / "run"
    installation.environment["IMX_DIR"] = str(installation.runtime)
    child = installation.spawn()
    installation.run("uninstall")
    child.expect(pexpect.EOF)
    assert not (parent / "run").exists()
    assert alias.is_symlink()
    assert_removed(installation)


def test_uninstall_standalone_binary(installation):
    standalone = installation.path / "imx"
    shutil.copy2(installation.binary, standalone)
    installation.binary = standalone
    child = installation.spawn()
    installation.run("uninstall")
    child.expect(pexpect.EOF)
    assert_removed(installation)
    assert (installation.path / "install/bin/imx").exists()


def test_uninstall_stale_registrations(installation):
    installation.run("list")
    previous = installation.runtime
    shutil.rmtree(previous)
    installation.runtime = installation.path / "new-runtime"
    installation.environment["IMX_DIR"] = str(installation.runtime)
    installation.run("uninstall")
    assert not previous.exists()
    assert_removed(installation)


def test_uninstall_preserves_other_files(installation):
    installation.run("list")
    document = installation.runtime / "document.txt"
    document.write_text("用户文件")
    notes = installation.binary.parent.parent / "share/licenses/imx/notes.txt"
    notes.write_text("安装目录中的用户文件")
    completion_notes = [installation.binary.parent.parent / name for name in COMPLETION_FILES]
    completion_notes = [path.with_name("other-command") for path in completion_notes]
    for path in completion_notes:
        path.write_text("用户补全文件")
    installation.run("uninstall")
    assert document.read_text() == "用户文件"
    assert notes.read_text() == "安装目录中的用户文件"
    assert list(installation.runtime.iterdir()) == [document]
    assert list(notes.parent.iterdir()) == [notes]
    for path in completion_notes:
        assert path.read_text() == "用户补全文件"
        assert list(path.parent.iterdir()) == [path]
    assert not state_directory(installation).exists()
    assert not installation.binary.exists()


def test_uninstall_symlink_installation(installation):
    alias_directory = installation.path / "aliases"
    alias_directory.mkdir()
    alias = alias_directory / "imx"
    alias.symlink_to(installation.binary)
    relative = installation.path / "uninstall-imx"
    relative.symlink_to(installation.binary)
    installation.environment["PATH"] = f"{alias_directory}:{installation.environment['PATH']}"
    result = subprocess.run(
        ["./uninstall-imx", "uninstall"], cwd=installation.path,
        env=installation.environment, capture_output=True, text=True, check=True, timeout=10,
    )
    assert result.stdout == "imx uninstalled.\n"
    assert not alias.is_symlink()
    assert not relative.is_symlink()
    assert_removed(installation)


def test_uninstall_from_inside_session(installation):
    child = installation.spawn()
    shell = int(installation.sessions()[0]["PID"])
    server = psutil.Process(shell).ppid()
    child.sendline("imx uninstall")
    child.expect(pexpect.EOF)
    installation.wait(lambda: not installation.binary.exists() and not state_directory(installation).exists())
    installation.wait(lambda: not psutil.pid_exists(shell) and not psutil.pid_exists(server))
    assert_removed(installation)


def test_uninstall_validates_directories_before_termination(installation):
    child = installation.spawn()
    installation.runtime.chmod(0o755)
    result = installation.run("uninstall", check=False)
    assert result.returncode != 0
    assert "UnsafeRuntimeDirectory" in result.stderr
    assert installation.binary.exists()
    installation.runtime.chmod(0o700)
    assert "STILL_RUNNING" in installation.command(child, "printf 'STILL_RUNNING\\n'")
    installation.run("uninstall")
    child.expect(pexpect.EOF)
    assert_removed(installation)


def test_uninstall_rejects_extra_arguments(installation):
    result = installation.run("uninstall", "extra", check=False)
    assert result.returncode != 0
    assert "InvalidArguments" in result.stderr
    assert installation.binary.exists()
    assert not state_directory(installation).exists()


def test_uninstall_exits_with_blocked_terminal_output(installation):
    child = installation.spawn()
    stopped = installation.path / "output-stopped"
    child.sendline(f"seq 1 1000000; printf DONE > '{stopped}'")
    installation.wait(stopped.exists, timeout=30)
    installation.run("uninstall")
    installation.wait(lambda: not child.isalive())
    assert not psutil.pid_exists(child.pid)
    assert_removed(installation)


def test_uninstall_exits_with_paused_terminal(installation):
    child = installation.spawn()
    terminal = os.open(f"/proc/{child.pid}/fd/1", os.O_WRONLY | os.O_NOCTTY)
    try:
        termios.tcflow(terminal, termios.TCOOFF)
        done = installation.path / "paused-output.done"
        child.sendline(f"seq 1 1000; printf DONE > '{done}'")
        installation.wait(done.exists)
        assert installation.sessions()[0]["CLIENTS"] == "1"
        installation.run("uninstall")
        installation.wait(lambda: not child.isalive())
        assert_removed(installation)
    finally:
        termios.tcflow(terminal, termios.TCOON)
        os.close(terminal)


def test_uninstall_serializes_concurrent_attach(installation):
    child = installation.spawn()
    image = os.open(installation.binary, os.O_RDONLY)
    fcntl.flock(image, fcntl.LOCK_SH)
    remover = subprocess.Popen(
        [str(installation.binary), "uninstall"], env=installation.environment,
        cwd=installation.path, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )

    def launch(_):
        master, slave = os.openpty()
        termios.tcsetwinsize(slave, (24, 80))
        process = subprocess.Popen(
            [str(installation.binary), "attach", "concurrent"],
            stdin=slave, stdout=slave, stderr=slave, env=installation.environment,
            cwd=installation.path, start_new_session=True,
        )
        os.close(slave)
        return process, master

    with ThreadPoolExecutor(max_workers=8) as pool:
        clients = list(pool.map(launch, range(8)))
    assert remover.poll() is None
    fcntl.flock(image, fcntl.LOCK_UN)
    os.close(image)
    stdout, stderr = remover.communicate(timeout=15)
    assert remover.returncode == 0, stderr.decode()
    assert stdout == b"imx uninstalled.\n"
    for process, master in clients:
        assert process.wait(timeout=10) in (0, 1)
        os.close(master)
    child.expect(pexpect.EOF)
    assert_removed(installation)


@pytest.mark.parametrize("shell", ["bash", "zsh", "fish"])
def test_uninstall_removes_prompt_integration(installation, shell):
    path, original = setup_shell(installation, shell)
    settings(installation, True)
    child = enter(installation)
    installation.run("uninstall")
    child.expect(pexpect.EOF)
    assert path.read_text() == original
    assert not configuration(installation).exists()
    assert not configuration(installation).parent.exists()
    assert_removed(installation)


def test_uninstall_reports_edited_shell_integration(installation):
    path, original = setup_shell(installation, "bash")
    settings(installation, True)
    child = enter(installation)
    installed = path.read_text()
    edited = installed.replace(BEGIN, BEGIN + "# 用户修改的集成代码\n")
    path.write_text(edited)
    result = installation.run("uninstall", check=False)
    assert result.returncode == 1
    assert "ShellIntegrationChanged" in result.stderr
    assert path.read_text() == edited
    assert installation.binary.exists()
    child.sendline("true")
    child.expect_exact("[dev] BASE:~> ")
    path.write_text(installed)
    installation.run("uninstall")
    child.expect(pexpect.EOF)
    assert path.read_text() == original
    assert_removed(installation)
