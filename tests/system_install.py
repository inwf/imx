import csv
import io
import os
from pathlib import Path
import pwd
import subprocess
import sys
import time
import tomllib
import uuid

import pexpect
import psutil

from completion_shell import COMPLETION_FILES, CompletionShell


USERNAME = "imx-install-tests"
PASSWORD = "imx-install-test-password"
ROOT = Path(__file__).resolve().parents[1]


def checked(*arguments, **kwargs):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=30, **kwargs)
    assert result.returncode == 0, f"{arguments!r}\n{result.stdout}{result.stderr}"
    return result


def overlay(directory, target):
    upper = directory / "upper"
    working = directory / "working"
    merged = directory / "merged"
    for path in (upper, working, merged):
        path.mkdir(parents=True)
    checked("mount", "-t", "overlay", "overlay", "-o", f"lowerdir={target},upperdir={upper},workdir={working}", str(merged))
    checked("mount", "--bind", str(merged), target)


def user_shell(environment):
    variables = [f"{name}={value}" for name, value in environment.items()]
    child = pexpect.spawn(
        "/usr/sbin/runuser", ["--user", USERNAME, "--", "env", *variables, "bash", "--noprofile", "--norc"],
        cwd=environment["HOME"], env=environment, encoding="utf-8", dimensions=(24, 80), timeout=20,
    )
    child.delaybeforesend = 0
    child.expect(r"[#$] ")
    child.sendline("stty -echo; PS1='SYSTEM_PROMPT> '; PROMPT_COMMAND=; printf '\\nREADY\\n'")
    child.expect_exact("\r\nREADY\r\n")
    child.expect_exact("SYSTEM_PROMPT> ")
    return child


def command(child, text, prompt="SYSTEM_PROMPT> "):
    marker = f"STATUS_{uuid.uuid4().hex}"
    child.sendline(f"{text}; printf '\\n{marker}=%s\\n' \"$?\"")
    child.expect_exact(f"\r\n{marker}=0\r\n")
    output = child.before
    child.expect_exact(prompt)
    return output


def authorize(child, text):
    child.sendline(f"{text}; printf '\\nSTATUS=%s\\n' \"$?\"")
    child.expect_exact(f"[sudo] password for {USERNAME}:")
    child.sendline(PASSWORD)


def installed(child, invocation, prompt="SYSTEM_PROMPT> "):
    authorize(child, invocation)
    assert "Administrator permissions are required to install in " in child.before
    child.expect_exact("\r\nSTATUS=0\r\n")
    assert "Installed imx" in child.before
    child.expect_exact(prompt)


def session(child):
    child.sendline("imx attach dev")
    child.expect(r"[#$] ")
    child.sendline("stty -echo; PS1='INNER_PROMPT> '; PROMPT_COMMAND=; printf '\\nINNER_READY\\n'")
    child.expect_exact("\r\nINNER_READY\r\n")
    child.expect_exact("INNER_PROMPT> ")
    command(child, "export SYSTEM_MARKER=retained; printf 'SYSTEM_HISTORY\\n'", "INNER_PROMPT> ")


def main():
    directory = Path(sys.argv[1]).resolve()
    release = sys.argv[2]
    version = sys.argv[3]
    case = sys.argv[4]
    assert os.geteuid() == 0
    checked("mount", "--make-rprivate", "/")
    overlay(directory / "etc", "/etc")
    overlay(directory / "usr", "/usr")
    system = directory / "system"
    system.mkdir()
    checked("mount", "--bind", str(system), "/usr/local")
    checked("mount", "--bind", str(ROOT), "/mnt")
    sudo_run = directory / "sudo-run"
    sudo_run.mkdir(mode=0o700)
    checked("mount", "--bind", str(sudo_run), "/run/sudo")
    mapped = Path("/mnt") / directory.relative_to(ROOT)
    home = mapped / "home"
    home.mkdir()
    checked("useradd", "--no-create-home", "--home-dir", str(home), "--shell", "/bin/bash", USERNAME)
    checked("chpasswd", input=f"{USERNAME}:{PASSWORD}\n")
    account = pwd.getpwnam(USERNAME)
    os.chown(home, account.pw_uid, account.pw_gid)
    policy = Path("/etc/sudoers.d/imx-install-tests")
    policy.write_text(f"{USERNAME} ALL=(root) ALL\n")
    policy.chmod(0o440)
    checked("visudo", "--check", "--file", str(policy))
    environment = dict(
        HOME=str(home), IMX_DIR=str(home / "run"), XDG_CACHE_HOME=str(home / ".cache"),
        XDG_CONFIG_HOME=str(home / ".config"),
        TMPDIR=str(home), SHELL="/bin/bash", TERM="xterm-256color", LC_ALL="C",
        IMX_RELEASE_BASE_URL=release,
        PATH="/usr/bin:/bin" if case in ("usr-path", "completion-usr") else "/usr/local/bin:/usr/bin:/bin",
    )
    binary = Path("/usr/bin/imx" if case in ("usr-path", "completion-usr") else "/usr/local/bin/imx")
    completions = [binary.parent.parent / name for name in COMPLETION_FILES]
    other_prefix = Path("/usr" if binary.parent.parent == Path("/usr/local") else "/usr/local")
    completions.append(other_prefix / "share/fish/vendor_completions.d/imx.fish")
    licenses = binary.parent.parent / "share/licenses/imx"
    download = f"curl -fsSL {release}/download/v{version}/install.sh | bash"
    if case == "root":
        fetch = subprocess.Popen(["curl", "-fsSL", f"{release}/download/v{version}/install.sh"], stdout=subprocess.PIPE)
        try:
            checked("bash", stdin=fetch.stdout, env=environment)
            fetch.stdout.close()
            assert fetch.wait(timeout=10) == 0
        finally:
            if fetch.poll() is None:
                fetch.kill()
                fetch.wait()
        assert checked("imx", "-v", env=environment).stdout == f"imx {version}\n"
        for path in completions:
            assert path.stat().st_mode & 0o777 == 0o644
        inode = binary.stat().st_ino
        checked("imx", "update", env=environment)
        assert binary.stat().st_ino != inode
        checked("imx", "uninstall", env=environment)
        assert not binary.exists()
        assert not licenses.exists()
        assert all(not path.exists() for path in completions)
        assert Path("/usr/local").exists()
        print("System installation and uninstall as root passed.")
        return

    child = user_shell(environment)
    backend = None
    other = None
    other_backend = None
    notes = licenses / "notes.txt"
    try:
        if case == "umask":
            command(child, "umask 077")
        installed(child, download)
        if case == "aliases":
            Path("/usr/bin/imx").symlink_to(binary)
        assert binary.stat().st_uid == 0
        assert binary.stat().st_mode & 0o777 == 0o755
        assert licenses.stat().st_mode & 0o777 == 0o755
        for path in licenses.rglob("*"):
            assert path.stat().st_mode & 0o777 == (0o755 if path.is_dir() else 0o644)
        for path in completions:
            assert path.stat().st_uid == 0
            assert path.stat().st_mode & 0o777 == 0o644
            assert path.parent.stat().st_mode & 0o777 == 0o755
        assert f"imx {version}" in command(child, "imx -v")
        configuration = home / ".config/imx/config.toml"
        assert not configuration.exists()
        if case == "config-permissions":
            command(child, 'mkdir -p "$HOME/.config/imx"; chmod 500 "$HOME/.config/imx"')
            variables = [f"{name}={value}" for name, value in environment.items()]
            result = subprocess.run(
                ["runuser", "--user", USERNAME, "--", "env", *variables, "imx", "ls"],
                capture_output=True, text=True, timeout=10,
            )
            assert result.returncode == 1, result.stdout + result.stderr
            assert "AccessDenied" in result.stderr
            assert not configuration.exists()
            assert not (home / "run").exists()
            command(child, 'chmod 700 "$HOME/.config/imx"')
        assert "No sessions." in command(child, "imx ls")
        assert configuration.stat().st_uid == account.pw_uid
        assert configuration.stat().st_mode & 0o777 == 0o600
        assert configuration.parent.stat().st_mode & 0o777 == 0o700
        assert tomllib.loads(configuration.read_text()) == {
            "prompt": {"show_session": True},
            "list": {"created_format": "%m-%d %H:%M:%S"},
            "completion": {"enabled": True},
        }
        assert list(configuration.parent.iterdir()) == [configuration]
        if case == "preserve-files":
            command(child, f"printf 'USER_DOCUMENT' | sudo tee {notes} > /dev/null")
        if case == "other-user":
            other_home = mapped / "root-home"
            other_home.mkdir(mode=0o700)
            other_environment = environment.copy()
            other_environment.update(HOME=str(other_home), IMX_DIR=str(other_home / "run"))
            other = pexpect.spawn("imx", ["attach", "other"], env=other_environment, encoding="utf-8", timeout=10)
            other.expect(r"[#$] ")
            other.sendline("stty -echo; PS1='OTHER_PROMPT> '; PROMPT_COMMAND=; printf '\\nOTHER_READY\\n'")
            other.expect_exact("\r\nOTHER_READY\r\n")
            other.expect_exact("OTHER_PROMPT> ")
            listing = checked("imx", "ls", env=other_environment).stdout
            other_shell = int(next(csv.DictReader(io.StringIO(listing), delimiter="\t"))["PID"])
            other_backend = psutil.Process(psutil.Process(other_shell).ppid())
        shell_pid = None
        job_pid = None
        if case in ("inside", "reinstall", "update", "update-inside", "cancel-uninstall", "cancel-update", "other-user", "completion", "completion-usr"):
            session(child)
            variables = [f"{name}={value}" for name, value in environment.items()]
            listing = checked("runuser", "--user", USERNAME, "--", "env", *variables, "imx", "ls").stdout
            shell_pid = int(next(csv.DictReader(io.StringIO(listing), delimiter="\t"))["PID"])
            backend = psutil.Process(psutil.Process(shell_pid).ppid())
            if case == "inside":
                output = command(child, "sleep 600 & printf '\\nJOB_PID=%s\\n' \"$!\"", "INNER_PROMPT> ")
                job_pid = int(next(line.removeprefix("JOB_PID=") for line in output.splitlines() if line.startswith("JOB_PID=")))
                assert psutil.pid_exists(job_pid)
            if case not in ("inside", "update-inside"):
                child.sendcontrol("\\")
                child.expect_exact("SYSTEM_PROMPT> ")
        if case in ("completion", "completion-usr"):
            for shell in ("bash", "zsh", "fish"):
                with CompletionShell(environment, shell, user=USERNAME, fixtures=Path("/mnt/tests/completion")) as terminal:
                    completed = terminal.complete("imx a\t")
                    assert completed == "imx attach ", f"{shell}: {completed!r}\n{terminal.log.getvalue()!r}"
                    assert terminal.complete("imx attach d\t") == "imx attach dev "
            command(child, "sudo -k")
            installed(child, "imx update")
            for shell in ("bash", "zsh", "fish"):
                with CompletionShell(environment, shell, user=USERNAME, fixtures=Path("/mnt/tests/completion")) as terminal:
                    assert terminal.complete("imx c\t") == "imx cat "
                    assert terminal.complete("imx kill d\t") == "imx kill dev "
        if case in ("reinstall", "update", "update-inside"):
            inode = binary.stat().st_ino
            prompt = "INNER_PROMPT> " if case == "update-inside" else "SYSTEM_PROMPT> "
            command(child, "sudo -k", prompt)
            installed(child, download if case == "reinstall" else "imx update", prompt)
            assert binary.stat().st_ino != inode
            assert psutil.pid_exists(shell_pid)
            assert "SYSTEM_HISTORY" in command(child, "imx cat dev", prompt)
            if case != "update-inside":
                child.sendline("imx attach dev")
                child.expect_exact("INNER_PROMPT> ")
            assert "retained" in command(child, "printf '%s\\n' \"$SYSTEM_MARKER\"", "INNER_PROMPT> ")
            child.sendcontrol("\\")
            child.expect_exact("SYSTEM_PROMPT> ")
        if case in ("cancel-install", "cancel-uninstall", "cancel-update"):
            inode = binary.stat().st_ino
            command(child, "sudo -k")
            invocation = download if case == "cancel-install" else "imx update" if case == "cancel-update" else "imx uninstall"
            child.sendline(invocation)
            child.expect_exact(f"[sudo] password for {USERNAME}:")
            child.sendcontrol("c")
            child.expect_exact("SYSTEM_PROMPT> ")
            assert binary.stat().st_ino == inode
            assert f"imx {version}" in command(child, "imx -v")
            if shell_pid is not None:
                assert psutil.pid_exists(shell_pid)
                assert "SYSTEM_HISTORY" in command(child, "imx cat dev")
        prompt = "INNER_PROMPT> " if case == "inside" else "SYSTEM_PROMPT> "
        command(child, "sudo -k", prompt)
        child.sendline("/usr/bin/imx uninstall" if case == "aliases" else "imx uninstall")
        child.expect_exact(f"[sudo] password for {USERNAME}:")
        child.sendline(PASSWORD)
        child.expect_exact("SYSTEM_PROMPT> ")
        deadline = time.monotonic() + 10
        while any(path.exists() for path in (binary, home / ".local/state/imx", home / "run")):
            assert time.monotonic() < deadline, "卸载未在限定时间内完成"
            time.sleep(0.02)
        assert not binary.exists()
        if case == "aliases":
            assert not Path("/usr/bin/imx").is_symlink()
        if case == "preserve-files":
            assert notes.read_text() == "USER_DOCUMENT"
            assert list(licenses.iterdir()) == [notes]
        else:
            assert not licenses.exists()
        assert all(not path.exists() for path in completions)
        assert not (home / ".local/state/imx").exists()
        assert not (home / "run").exists()
        assert not configuration.exists()
        assert not list((home / ".cache").glob("imx-install.*"))
        assert not list(binary.parent.glob(".imx-install.*"))
        if shell_pid is not None:
            assert not psutil.pid_exists(shell_pid)
        if job_pid is not None:
            assert not psutil.pid_exists(job_pid)
        if other is not None:
            assert other_backend.is_running()
            assert "OTHER_USER_ALIVE" in command(other, "printf 'OTHER_USER_ALIVE\\n'", "OTHER_PROMPT> ")
            assert (other_home / ".local/state/imx").exists()
            other.sendline("exit")
            other.expect(pexpect.EOF)
            other_backend.wait(timeout=10)
        assert Path("/usr/local").exists()
        print(f"System installation with real sudo authentication passed: {case}")
    finally:
        child.close(force=True)
        if backend is not None and backend.is_running():
            backend.terminate()
            backend.wait(timeout=10)
        if other is not None:
            other.close(force=True)
        if other_backend is not None and other_backend.is_running():
            other_backend.terminate()
            other_backend.wait(timeout=10)


if __name__ == "__main__":
    main()
