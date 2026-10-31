import io
from pathlib import Path
import shlex
import shutil
import time
import uuid

import pexpect
import pyte


COMPLETION_FILES = (
    "share/bash-completion/completions/imx",
    "share/zsh/site-functions/_imx",
    "share/zsh/vendor-completions/_imx",
    "share/fish/vendor_completions.d/imx.fish",
)
FIXTURES = Path(__file__).resolve().parent / "completion"
PROMPT = "COMPLETION> "


class CompletionShell:
    def __init__(self, environment, shell, prefix=None, user=None, fixtures=FIXTURES, columns=100):
        variables = environment.copy()
        self.capture = Path(variables["HOME"]) / f"completion-buffer-{uuid.uuid4().hex}"
        variables["IMX_TEST_SHELL_BUFFER"] = str(self.capture)
        variables["SHELL"] = shutil.which(shell)
        assert variables["SHELL"]
        if prefix is not None:
            variables["PATH"] = f"{prefix}/bin:{variables['PATH']}"
            variables["XDG_DATA_DIRS"] = f"{prefix}/share:/usr/local/share:/usr/share"
            variables["IMX_TEST_COMPLETION_PREFIX"] = str(prefix)
        if shell == "bash":
            arguments = ["--noprofile", "--rcfile", str(fixtures / "bash.sh"), "-i"]
        elif shell == "zsh":
            directory = self.capture.with_name(self.capture.name + "-zsh")
            directory.mkdir(mode=0o755)
            (directory / ".zshrc").symlink_to(fixtures / "zsh.sh")
            variables["ZDOTDIR"] = str(directory)
            arguments = ["-i"]
        else:
            arguments = ["-i", "-C", f"source {shlex.quote(str(fixtures / 'fish.fish'))}"]
        executable = variables["SHELL"]
        if user is not None:
            arguments = ["--user", user, "--", "env", *[f"{key}={value}" for key, value in variables.items()], executable, *arguments]
            executable = "/usr/sbin/runuser"
        self.log = io.StringIO()
        self.child = pexpect.spawn(
            executable, arguments, env=variables, cwd=variables["HOME"],
            encoding="utf-8", dimensions=(24, columns), timeout=10,
        )
        self.child.delaybeforesend = 0
        self.child.logfile_read = self.log
        self.child.expect_exact(PROMPT)
        self.columns = columns
        self.read()

    def read(self):
        while True:
            try:
                self.child.read_nonblocking(size=65536, timeout=0.05)
            except pexpect.TIMEOUT:
                return

    def buffer(self):
        self.capture.unlink(missing_ok=True)
        self.child.sendcontrol("o")
        deadline = time.monotonic() + 10
        while not self.capture.exists():
            self.read()
            assert time.monotonic() < deadline, self.log.getvalue()
        self.read()
        return self.capture.read_text().removesuffix("\n")

    def complete(self, text):
        self.read()
        self.child.sendcontrol("u")
        assert self.buffer() == ""
        self.child.send(text)
        return self.buffer()

    def display(self):
        self.read()
        screen = pyte.Screen(self.columns, 24)
        pyte.Stream(screen).feed(self.log.getvalue())
        return "\n".join(screen.display)

    def close(self):
        self.child.close(force=True)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
