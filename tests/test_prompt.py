from pathlib import Path
import shutil

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
