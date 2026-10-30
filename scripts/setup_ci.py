import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
architecture = platform.machine()
if architecture not in ("x86_64", "aarch64") or platform.system() != "Linux":
    raise RuntimeError("构建需要 x86_64 或 aarch64 Linux")
tools = json.loads((ROOT / "scripts/ci-tools.json").read_text())
if tools["zig"]["version"] != (ROOT / ".zig-version").read_text().strip():
    raise ValueError("Zig 版本与 .zig-version 不一致")
cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "imx-ci"
cache.mkdir(parents=True, exist_ok=True)
for name, tool in tools.items():
    source = tool[architecture]
    destination = cache / f"{name}-{tool['version']}-{architecture}"
    if not destination.exists():
        with tempfile.TemporaryDirectory(dir=cache) as temporary:
            directory = Path(temporary)
            archive = directory / "download.tar"
            with urllib.request.urlopen(source["url"], timeout=60) as response, archive.open("wb") as output:
                shutil.copyfileobj(response, output)
            with archive.open("rb") as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != source["sha256"]:
                    raise ValueError(f"{name} 的 SHA256 校验失败")
            unpacked = directory / "unpacked"
            with tarfile.open(archive) as package:
                package.extractall(unpacked, filter="data")
            (unpacked / source["directory"]).rename(destination)
    executable = destination / name
    argument = "version" if name == "zig" else "-version"
    result = subprocess.run([str(executable), argument], check=True, capture_output=True, text=True)
    if tool["version"] != result.stdout.splitlines()[0]:
        raise ValueError(f"{name} 的可执行文件版本不正确")
    if "GITHUB_PATH" in os.environ:
        with Path(os.environ["GITHUB_PATH"]).open("a") as output:
            output.write(f"{destination}\n")
    print(destination)
