import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile

from elftools.elf.elffile import ELFFile


ROOT = Path(__file__).resolve().parents[1]
ARCHITECTURES = {"x86_64": "EM_X86_64", "aarch64": "EM_AARCH64"}


def version():
    result = subprocess.run([str(ROOT / "zig-out/bin/imx"), "-v"], check=True, text=True, capture_output=True)
    if not result.stdout.startswith("imx ") or len(result.stdout.splitlines()) != 1:
        raise ValueError("imx 的版本输出不正确")
    return result.stdout.removeprefix("imx ").strip()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def package(prefix, architecture, output, tag):
    current = version()
    if tag and tag != f"v{current}":
        raise ValueError(f"标签 {tag} 与编译版本 v{current} 不一致")
    with (prefix / "bin/imx").open("rb") as stream:
        executable = ELFFile(stream)
        if executable.header["e_machine"] != ARCHITECTURES[architecture]:
            raise ValueError("可执行文件架构不正确")
        if any(segment.header["p_type"] == "PT_INTERP" for segment in executable.iter_segments()):
            raise ValueError("发布文件需要静态链接")
    files = [prefix / "bin/imx", *sorted((prefix / "share/licenses/imx").rglob("*"))]
    files = [path for path in files if path.is_file()]
    if len(files) < 3 or any(path.is_symlink() for path in files):
        raise ValueError("安装文件或许可证不完整")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"imx-linux-{architecture}.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(prefix / "share/licenses/imx", arcname="share/licenses/imx", recursive=False)
        for path in files:
            bundle.add(path, arcname=path.relative_to(prefix), recursive=False)
    metadata = {"architecture": architecture, "version": current, "sha256": digest(archive)}
    (output / f"{architecture}.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(archive)


def assemble(directory, tag):
    versions = set()
    for architecture in ARCHITECTURES:
        metadata = json.loads((directory / f"{architecture}.json").read_text())
        archive = directory / f"imx-linux-{architecture}.tar.gz"
        if metadata["architecture"] != architecture or metadata["sha256"] != digest(archive):
            raise ValueError(f"{architecture} 发布文件的 SHA256 校验失败")
        versions.add(metadata["version"])
    if len(versions) != 1:
        raise ValueError("两个架构的版本不一致")
    current = versions.pop()
    if tag and tag != f"v{current}":
        raise ValueError(f"标签 {tag} 与编译版本 v{current} 不一致")
    (directory / "VERSION").write_text(current + "\n")
    shutil.copyfile(ROOT / "install.sh", directory / "install.sh")
    names = ["imx-linux-x86_64.tar.gz", "imx-linux-aarch64.tar.gz", "install.sh", "VERSION"]
    (directory / "SHA256SUMS").write_text("".join(f"{digest(directory / name)}  {name}\n" for name in names))
    for architecture in ARCHITECTURES:
        (directory / f"{architecture}.json").unlink()
    print(f"Prepared imx {current}: {directory}")


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("package")
    build.add_argument("--arch", choices=ARCHITECTURES, default=platform.machine())
    build.add_argument("--prefix", type=Path, default=ROOT / "zig-out")
    build.add_argument("--output", type=Path, default=ROOT / "work/release")
    build.add_argument("--tag", default="")
    publish = commands.add_parser("assemble")
    publish.add_argument("--directory", type=Path, default=ROOT / "work/release")
    publish.add_argument("--tag", default="")
    state = commands.add_parser("state")
    state.add_argument("--tag", required=True)
    args = parser.parse_args()
    if args.command == "package":
        package(args.prefix, args.arch, args.output, args.tag)
    elif args.command == "assemble":
        assemble(args.directory, args.tag)
    else:
        pages = json.load(sys.stdin)
        matches = [release for page in pages for release in page if release["tag_name"] == args.tag]
        if len(matches) > 1:
            raise ValueError("同一标签存在多个 Release")
        print("missing" if not matches else "draft" if matches[0]["draft"] else "published")


if __name__ == "__main__":
    main()
