import pytest

from test_prompt import configuration


@pytest.mark.parametrize("arguments", [("help",), ("-h",), ("--help",), ("-v",), ("--version",)])
def test_information_flags_leave_runtime_and_configuration_untouched(sessions, arguments):
    result = sessions.run(*arguments)
    assert result.stderr == ""
    assert result.stdout
    assert not configuration(sessions).exists()
    assert not sessions.runtime.exists()
    assert not (sessions.home / ".local/state/imx").exists()


@pytest.mark.parametrize("command", ["attach", "list", "ls", "cat", "detach", "kill", "update", "uninstall", "help"])
def test_command_help_precedes_configuration_and_execution(sessions, command):
    path = configuration(sessions)
    path.parent.mkdir(parents=True)
    path.write_text("[invalid configuration\n")
    try:
        results = [sessions.run(*arguments) for arguments in [
            (command, "--help"), (command, "-h"), ("help", command),
        ]]
        assert all(result.stderr == "" for result in results)
        assert len({result.stdout for result in results}) == 1
        assert f"Usage: imx {command}" in results[0].stdout
        assert path.read_text() == "[invalid configuration\n"
        assert not sessions.runtime.exists()
        assert not (sessions.home / ".local/state/imx").exists()
    finally:
        path.unlink()


@pytest.mark.parametrize("arguments, message", [
    (("attach",), "Missing session name"),
    (("attach", "dev", "extra"), "extra"),
    (("attach", "--unknown"), "--unknown"),
    (("attach", "--help=true"), "does not take a value"),
    (("attach", "../bad"), "Invalid session name '../bad'"),
    (("unknown",), "Unknown command 'unknown'"),
    (("help", "unknown"), "Unknown command 'unknown'"),
    (("--version", "extra"), "without other arguments"),
    (("update", "extra"), "extra"),
])
def test_argument_errors_are_specific_and_leave_runtime_untouched(sessions, arguments, message):
    result = sessions.run(*arguments, check=False)
    assert result.returncode == 1
    assert result.stdout == ""
    assert message in result.stderr
    assert not configuration(sessions).exists()
    assert not sessions.runtime.exists()


@pytest.mark.parametrize("name", ["--help", "-h", "-dash"])
def test_separator_allows_session_names_that_look_like_options(sessions, name):
    session = sessions.spawn(name)
    assert "SESSION_ALIVE" in sessions.command(session, "printf 'SESSION_ALIVE\\n'")
    assert "SESSION_ALIVE" in sessions.run("cat", "--", name).stdout
    sessions.run("kill", "--", name)
    sessions.wait(lambda: not sessions.sessions())


@pytest.mark.parametrize("contents, key, message", [
    ("[unknown]\nvalue = 1\n", "unknown", "unknown configuration option"),
    ("prompt = false\n", "prompt", "expected a table"),
    ("[prompt]\nshow_session = 'true'\n", "prompt.show_session", "expected a boolean"),
    ("[list]\ncreated_format = 12\n", "list.created_format", "expected a string"),
    ("[keybindings]\ndetach = { key = 'x', ctrl = 'true' }\n", "keybindings.detach.ctrl", "expected a boolean"),
    ("[keybindings]\ndetach = { key = 'x', control = true }\n", "keybindings.detach.control", "unknown configuration option"),
    ("[keybindings]\ndetach = {}\n", "keybindings.detach.key", "required key is missing"),
])
def test_configuration_errors_identify_file_option_and_requirement(sessions, contents, key, message):
    path = configuration(sessions)
    path.parent.mkdir(parents=True)
    path.write_text(contents)
    try:
        result = sessions.run("list", check=False)
        assert result.returncode == 1
        assert result.stdout == ""
        assert f"{path}: {key}: {message}" in result.stderr
        assert len(result.stderr.splitlines()) == 1
        assert not sessions.runtime.exists()
    finally:
        path.unlink()


def test_toml_syntax_errors_include_the_configuration_path(sessions):
    path = configuration(sessions)
    path.parent.mkdir(parents=True)
    path.write_text("[prompt\n")
    try:
        result = sessions.run("list", check=False)
        assert result.returncode == 1
        assert str(path) in result.stderr
        assert "InvalidConfiguration" in result.stderr
        assert not sessions.runtime.exists()
    finally:
        path.unlink()
