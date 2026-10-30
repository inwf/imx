import os
import subprocess
import sys
import uuid

import pytest

from conftest import ROOT
from test_install import VERSION, downloaded, native_package


@pytest.mark.parametrize("case", ["root", "sudo", "inside", "reinstall", "cancel-install", "cancel-uninstall", "usr-path", "umask", "other-user", "preserve-files", "aliases"])
def test_system_installation(case, downloaded):
    directory = ROOT / "work/system-tests" / uuid.uuid4().hex
    directory.mkdir(parents=True)
    command = ["unshare", "--mount", "--fork", sys.executable, str(ROOT / "tests/system_install.py"),
               str(directory), downloaded.environment["IMX_RELEASE_BASE_URL"], VERSION, case]
    if os.geteuid() != 0:
        command = ["sudo", "--preserve-env=TMPDIR", "--", *command]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "passed" in result.stdout
