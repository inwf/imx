from concurrent.futures import ThreadPoolExecutor
import fcntl
import os
from pathlib import Path
import shutil
import stat

import pexpect
import pytest


BEGIN = "# BEGIN imx shell integration\n"
END = "# END imx shell integration\n"


def configuration(environment):
    root = environment.environment.get("XDG_CONFIG_HOME")
    return (Path(root) if root else environment.home / ".config") / "imx/config.toml"


def settings(environment, enabled):
    path = configuration(environment)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"[prompt]\nshow_session = {str(enabled).lower()}\n")


def setup_shell(environment, shell):
    executable = shutil.which(shell)
    assert executable
    environment.environment["SHELL"] = executable
    if shell == "bash":
        path = environment.home / ".bashrc"
        original = "PS1='BASE:\\w> '\n"
        (environment.home / ".profile").write_text('. "$HOME/.bashrc"\n')
    elif shell == "zsh":
        path = environment.home / ".zshrc"
        original = "PROMPT='BASE:%~> '\n"
    else:
        path = Path(environment.environment["XDG_CONFIG_HOME"]) / "fish/config.fish"
        original = "set -g fish_greeting\nfunction fish_prompt\n    printf 'BASE:%s> ' (prompt_pwd)\nend\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(original)
    return path, original


def enter(environment, name="dev"):
    child = environment.spawn(name, initialize=False)
    child.expect_exact(f"[{name}] BASE:")
    child.sendline("cd")
    child.expect_exact(f"[{name}] BASE:~> ")
    return child


@pytest.mark.parametrize("shell", ["bash", "zsh", "fish"])
def test_session_prompt_preserves_shell_and_directory(sessions, shell):
    path, original = setup_shell(sessions, shell)
    settings(sessions, True)
    child = enter(sessions)
    directory = sessions.home / "directory"
    directory.mkdir()
    for _ in range(3):
        child.sendline("cd directory; cd ..; cd directory")
        child.expect_exact("[dev] BASE:~/directory> ")
        child.sendline("cd ..")
        child.expect_exact("[dev] BASE:~> ")
    contents = path.read_text()
    assert contents.startswith(original)
    assert contents.count(BEGIN) == 1
    assert contents.count(END) == 1
    second = enter(sessions, "other")
    assert path.read_text() == contents
    child.sendline("exit")
    child.expect(pexpect.EOF)
    assert sessions.sessions()[0]["NAME"] == "other"
    second.sendcontrol("\\")
    second.expect(pexpect.EOF)


@pytest.mark.parametrize("shell", ["bash", "zsh", "fish"])
def test_disabling_prompt_restores_files_and_running_prompt(sessions, shell):
    path, original = setup_shell(sessions, shell)
    settings(sessions, True)
    first = enter(sessions)
    settings(sessions, False)
    second = sessions.spawn("other", initialize=False)
    second.expect_exact("BASE:")
    second.sendline("cd")
    second.expect_exact("BASE:~> ")
    assert path.read_text() == original
    assert not (sessions.home / ".local/state/imx/shell").exists()
    first.sendline("true")
    first.expect_exact("BASE:~> ")
    assert "[dev]" not in first.before
    if shell == "zsh":
        assert not (sessions.home / ".zlogin").exists()
    settings(sessions, True)
    third = enter(sessions, "again")
    assert path.read_text().count(BEGIN) == 1
    third.sendline("exit")
    third.expect(pexpect.EOF)


@pytest.mark.parametrize("profile", [".bash_profile", ".bash_login", ".profile"])
def test_bash_login_file_precedence(sessions, profile):
    path, original = setup_shell(sessions, "bash")
    order = [".bash_profile", ".bash_login", ".profile"]
    originals = {}
    for name in order[order.index(profile):]:
        value = f'. "$HOME/.bashrc"\nPS1="{name}> "\n'
        originals[name] = value
        (sessions.home / name).write_text(value)
    settings(sessions, True)
    child = sessions.spawn(initialize=False)
    child.expect_exact(f"[dev] {profile}> ")
    assert path.read_text().startswith(original)
    for name, value in originals.items():
        contents = (sessions.home / name).read_text()
        assert contents.count(BEGIN) == (1 if name == profile else 0)
        assert contents.startswith(value)
    assert not any((sessions.home / name).exists() for name in order[:order.index(profile)])


@pytest.mark.parametrize("array", [False, True])
def test_bash_prompt_command_theme_status_and_colors(sessions, array):
    path, _ = setup_shell(sessions, "bash")
    path.write_text(
        "__user_prompt() {\n"
        "    local user_exit=$?\n"
        "    PS1=\"\\[\\e[32m\\]STATUS=$user_exit BASE> \\[\\e[0m\\]\"\n"
        "}\n"
        + ("PROMPT_COMMAND=(__user_prompt)\n" if array else "PROMPT_COMMAND=__user_prompt\n")
    )
    settings(sessions, True)
    child = sessions.spawn(initialize=False)
    child.expect_exact("[dev] \x1b[32mSTATUS=0 BASE> \x1b[0m")
    for status, command in [(1, "false"), (0, "true"), (1, "false")]:
        child.sendline(command)
        child.expect_exact(f"[dev] \x1b[32mSTATUS={status} BASE> \x1b[0m")
    child.sendline('. "$HOME/.bashrc"; printf "%s\\n" "${PROMPT_COMMAND[@]}"')
    child.expect_exact("__user_prompt\r\n__imx_prompt\r\n")
    child.expect_exact("[dev] \x1b[32mSTATUS=0 BASE> \x1b[0m")


def test_fish_prompt_preserves_pipeline_status_and_theme_changes(sessions):
    path, _ = setup_shell(sessions, "fish")
    path.write_text(
        "set -g fish_greeting\n"
        "function fish_prompt\n"
        "    set -l user_status $status\n"
        "    set -l user_pipeline $pipestatus\n"
        "    printf 'STATUS=%s PIPE=%s BASE> ' $user_status (string join , $user_pipeline)\n"
        "end\n"
    )
    settings(sessions, True)
    child = sessions.spawn(initialize=False)
    child.expect_exact("[dev] STATUS=0 PIPE=0 BASE> ")
    child.sendline("false | true")
    child.expect_exact("[dev] STATUS=0 PIPE=1,0 BASE> ")
    child.sendline("false")
    child.expect_exact("[dev] STATUS=1 PIPE=1 BASE> ")
    child.sendline("function fish_prompt; printf 'THEME> '; end")
    child.expect_exact("[dev] THEME> ")
    child.sendline("true")
    child.expect_exact("[dev] THEME> ")


def test_zsh_zdotdir_and_login_theme(sessions):
    directory = sessions.home / "zsh configuration"
    directory.mkdir()
    sessions.environment["ZDOTDIR"] = str(directory)
    sessions.environment["SHELL"] = shutil.which("zsh")
    rc = directory / ".zshrc"
    rc.write_text("PROMPT='RC> '\n")
    login = directory / ".zlogin"
    login.write_text("precmd() { PROMPT=\"STATUS=$? LOGIN> \"; }\n")
    settings(sessions, True)
    child = sessions.spawn(initialize=False)
    child.expect_exact("[dev] STATUS=0 LOGIN> ")
    child.sendline("false")
    child.expect_exact("[dev] STATUS=1 LOGIN> ")
    assert rc.read_text().count(BEGIN) == 1
    assert login.read_text().count(BEGIN) == 1
    assert not (sessions.home / ".zshrc").exists()


@pytest.mark.parametrize("shell", ["bash", "zsh", "fish"])
def test_ordinary_shell_keeps_original_prompt(sessions, shell):
    setup_shell(sessions, shell)
    settings(sessions, True)
    enter(sessions)
    child = pexpect.spawn(
        sessions.environment["SHELL"], ["-l"], cwd=str(sessions.path),
        env=sessions.environment, encoding="utf-8", timeout=10,
    )
    sessions.clients.append(child)
    child.expect_exact("BASE:")
    child.sendline("cd")
    child.expect_exact("BASE:~> ")
    assert "[dev]" not in child.before
    child.sendline("exit")
    child.expect(pexpect.EOF)


@pytest.mark.parametrize("enabled", [None, False])
def test_prompt_is_disabled_by_default(sessions, enabled):
    path, original = setup_shell(sessions, "bash")
    if enabled is not None:
        settings(sessions, enabled)
    child = sessions.spawn(initialize=False)
    child.expect_exact("BASE:")
    assert path.read_text() == original
    assert not (sessions.home / ".local/state/imx/shell").exists()


def test_shell_symlink_permissions_attributes_and_user_content(sessions):
    path, original = setup_shell(sessions, "bash")
    target = sessions.path / "bash configuration"
    path.rename(target)
    path.symlink_to(target)
    target.chmod(0o640)
    os.setxattr(target, "user.imx-test", b"retained")
    settings(sessions, True)
    enter(sessions)
    assert path.is_symlink()
    assert stat.S_IMODE(target.stat().st_mode) == 0o640
    assert os.getxattr(target, "user.imx-test") == b"retained"
    with target.open("a") as stream:
        stream.write("\n# 用户追加的配置\n")
    settings(sessions, False)
    child = sessions.spawn("other", initialize=False)
    child.expect_exact("BASE:")
    assert path.is_symlink()
    assert target.read_text() == original + "\n# 用户追加的配置\n"
    assert stat.S_IMODE(target.stat().st_mode) == 0o640
    assert os.getxattr(target, "user.imx-test") == b"retained"
    assert not list(target.parent.glob(".imx-*"))


def test_concurrent_prompt_installation_has_one_block(sessions):
    path, _ = setup_shell(sessions, "bash")
    settings(sessions, True)

    def launch(index):
        return enter(sessions, f"session-{index}")

    with ThreadPoolExecutor(max_workers=8) as pool:
        children = list(pool.map(launch, range(8)))
    assert len(sessions.sessions()) == len(children)
    assert path.read_text().count(BEGIN) == 1
    assert (sessions.home / ".profile").read_text().count(BEGIN) == 1


@pytest.mark.parametrize("value, error", [
    (b"[prompt\n", "InvalidConfiguration"),
    (b"[prompt]\nshow_session = 'true'\n", "PromptShowSessionMustBeBoolean"),
    (b"[prompt]\nshow_sessions = true\n", "UnknownConfigurationOption"),
    (b"[unknown]\nenabled = true\n", "UnknownConfigurationOption"),
    (b"\xff", "InvalidConfigurationUtf8"),
])
def test_invalid_prompt_configuration_fails_before_starting(sessions, value, error):
    path, original = setup_shell(sessions, "bash")
    settings(sessions, True)
    configuration(sessions).write_bytes(value)
    child = sessions.spawn(initialize=False)
    child.expect(pexpect.EOF)
    configuration(sessions).unlink()
    assert error in child.before
    child.close()
    assert child.exitstatus == 1
    assert not (sessions.home / ".local/state/imx").exists()
    assert path.read_text() == original


def test_locked_shell_file_fails_without_modifying_it(sessions):
    path, original = setup_shell(sessions, "bash")
    settings(sessions, True)
    with path.open() as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        child = sessions.spawn(initialize=False)
        child.expect(pexpect.EOF)
        assert "SystemCallFailed" in child.before
        assert path.read_text() == original
        assert not sessions.runtime.exists()
