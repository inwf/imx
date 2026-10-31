import pexpect
import pytest

from completion_shell import COMPLETION_FILES, CompletionShell
from test_install import downloaded, native_package
from test_prompt import configuration
from test_uninstall import installation


def test_completion_queries_leave_unused_runtime_untouched(sessions):
    assert sessions.run("__complete", "commands", "a").stdout == "attach\n"
    assert sessions.run("__complete", "commands", "l").stdout == "list\nls\n"
    assert sessions.run("__complete", "commands", "-").stdout == "-v\n"
    assert sessions.run("__complete", "commands", "missing").stdout == ""
    assert sessions.run("__complete", "sessions", "").stdout == ""
    assert not sessions.runtime.exists()
    assert not (sessions.home / ".local/state/imx").exists()
    sessions.runtime.mkdir(mode=0o700)
    assert sessions.run("__complete", "sessions", "").stdout == ""
    assert not list(sessions.runtime.iterdir())


@pytest.mark.parametrize("arguments", [[], ["commands"], ["unknown", ""], ["sessions", "", "extra"]])
def test_completion_rejects_invalid_arguments(sessions, arguments):
    result = sessions.run("__complete", *arguments, check=False)
    assert result.returncode == 1
    assert result.stdout == ""
    assert "InvalidArguments" in result.stderr
    assert not sessions.runtime.exists()


def test_completion_queries_return_current_filtered_names(sessions):
    names = ["zulu", "alpha-test", "alpha-dev", "-dash", ".hidden", "0-start", "upper_X"]
    for name in names:
        sessions.spawn(name)
    assert sessions.run("__complete", "sessions", "").stdout.splitlines() == sorted(names)
    assert sessions.run("__complete", "sessions", "alpha-").stdout == "alpha-dev\nalpha-test\n"
    assert sessions.run("__complete", "sessions", "missing").stdout == ""
    assert sessions.run("__complete", "sessions", "a" * 65).stdout == ""
    path = configuration(sessions)
    path.parent.mkdir(parents=True)
    path.write_text("[list]\ncreated_format = '%Y年%m月%d日'\n")
    assert sessions.run("__complete", "sessions", "").stdout.splitlines() == sorted(names)
    sessions.spawn("new-live")
    assert sessions.run("__complete", "sessions", "new").stdout == "new-live\n"
    sessions.run("kill", "new-live")
    assert sessions.run("__complete", "sessions", "new").stdout == ""
    path.write_text("[completion]\nenabled = false\n")
    assert sessions.run("__complete", "commands", "").stdout == ""
    assert sessions.run("__complete", "sessions", "").stdout == ""


@pytest.mark.parametrize("shell", ["bash", "zsh", "fish"])
def test_native_tab_completes_commands_and_live_sessions(installation, shell):
    names = ["alpha-dev", "alpha-test", "beta", "docs.v1", "-dash", ".hidden", "0-start", "upper_X"]
    for name in names:
        installation.spawn(name)
    (installation.home / "alpha-file").write_text("用户文件")
    prefix = installation.binary.parent.parent
    with CompletionShell(installation.environment, shell, prefix) as terminal:
        assert terminal.complete("imx a\t") == "imx attach "
        assert terminal.complete("imx attach \t") == "imx attach "
        display = terminal.display()
        for name in names:
            assert name in display
        terminal.child.send("b\t")
        assert terminal.buffer() == "imx attach beta "
        for command in ["attach", "cat", "kill"]:
            assert terminal.complete(f"imx {command} d\t") == f"imx {command} docs.v1 "
            assert terminal.complete(f"imx {command} alpha-\t") == f"imx {command} alpha-"
            assert terminal.complete(f"imx {command} missing\t") == f"imx {command} missing"
        for prefix_text, name in [("-d", "-dash"), (".h", ".hidden"), ("0", "0-start"), ("u", "upper_X")]:
            assert terminal.complete(f"imx attach {prefix_text}\t") == f"imx attach {name} "
        assert terminal.complete("imx -\t") == "imx -v "
        assert terminal.complete("imx attach beta a\t") == "imx attach beta a"
        assert terminal.complete("imx list a\t") == "imx list a"
        installation.spawn("gamma-live")
        assert terminal.complete("imx cat g\t") == "imx cat gamma-live "
        installation.run("kill", "gamma-live")
        assert terminal.complete("imx cat g\t") == "imx cat g"
        path = configuration(installation)
        path.parent.mkdir(parents=True)
        path.write_text("[completion]\nenabled = false\n")
        assert terminal.complete("imx a\t") == "imx a"
        assert terminal.complete("imx attach b\t") == "imx attach b"
        path.write_text("[completion]\nenabled = true\n[list]\ncreated_format = '%Y'\n")
        assert terminal.complete("imx a\t") == "imx attach "
        assert terminal.complete("imx cat b\t") == "imx cat beta "


@pytest.mark.parametrize("shell", ["bash", "zsh", "fish"])
def test_curl_install_update_and_uninstall_completion(downloaded, shell):
    prefix = downloaded.path / "completion install"
    downloaded.binary = prefix / "bin/imx"
    downloaded.environment["IMX_PREFIX"] = str(prefix)
    assert downloaded.install().returncode == 0
    for name in COMPLETION_FILES:
        file = prefix / name
        assert file.is_file()
        assert file.stat().st_mode & 0o777 == 0o644
    downloaded.environment["PATH"] = f"{prefix}/bin:{downloaded.environment['PATH']}"
    session = downloaded.spawn("download-live")
    with CompletionShell(downloaded.environment, shell, prefix) as terminal:
        assert terminal.complete("imx a\t") == "imx attach "
        assert terminal.complete("imx attach d\t") == "imx attach download-live "
        downloaded.run("update")
        assert terminal.complete("imx cat d\t") == "imx cat download-live "
    downloaded.run("uninstall")
    session.expect(pexpect.EOF)
    assert all(not (prefix / name).exists() for name in COMPLETION_FILES)
    assert not prefix.exists()


@pytest.mark.parametrize("columns", [32, 100])
def test_bash_session_candidates_preserve_prompt_and_display(installation, columns):
    installation.spawn("alpha")
    installation.spawn("beta")
    with CompletionShell(installation.environment, "bash", installation.binary.parent.parent, columns=columns) as terminal:
        terminal.child.sendline("PS1='\\[\\e[32m\\]目录提示:\\w\\[\\e[0m\\]\\n会话> '")
        terminal.read()
        terminal.child.send("imx attach \t")
        display = terminal.display()
        assert "alpha" in display and "beta" in display
        assert "会话> imx attach" in display
        terminal.child.send("b\t")
        display = terminal.display()
        active = next(line for line in reversed(display.splitlines()) if "会话> imx attach" in line)
        assert active.rstrip() == "会话> imx attach beta"
        assert terminal.buffer() == "imx attach beta "
