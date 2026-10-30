<div align="center">
  <h1>imx</h1>
  <p><strong>Keep your terminal sessions running.</strong></p>
  <p>A lightweight terminal session manager for Linux.<br />Disconnect while programs keep running. Reattach to restore your screen and retained history.</p>
  <p>
    <a href="#quick-start"><strong>Quick start</strong></a> ·
    <a href="#commands">Commands</a> ·
    <a href="#resource-usage">Resource usage</a> ·
    <a href="#documentation">Documentation</a> ·
    <a href="README.zh-CN.md">简体中文</a>
  </p>
  <p>Linux x86_64 / ARM64 · <a href=".zig-version">Zig 0.17.0</a> · <a href="LICENSE">MIT License</a></p>
</div>

## Features

- **Persistent sessions:** close a terminal or disconnect SSH while your shell and session programs keep running.
- **Screen restoration:** reattach to restore the screen and retained history, including full-screen terminal programs such as Vim.
- **Readable output:** use `imx cat` from outside a session to read retained history and the active screen as text.
- **Shared connections:** multiple terminals can attach to one session and share its input and output.
- **Resource control:** one backend process with one thread manages all sessions for a user and waits for system events while idle.
- **Direct installation:** releases contain static executables; the installer selects your architecture and verifies SHA256 checksums.

## Quick start

### Install

Requires **Linux 5.9 or newer**. Release packages support **x86_64** and **ARM64 (aarch64)**. The installer requires Bash, curl, GNU tar, GNU coreutils, and GNU findutils.

```bash
curl -fsSL https://github.com/inwf/imx/releases/latest/download/install.sh | bash
```

The installer downloads a public GitHub Release from this repository. If no release is available, use [Build from source](#build-from-source).

The default installation path is `/usr/local/bin/imx`. After installation, run:

```bash
imx -v
imx attach dev
```

For regular users, the installer invokes `sudo` and may prompt for a password, depending on system settings. Root users install directly. The installer chooses a system command directory already on your `PATH`; environments with only `/usr/bin` use `/usr/bin/imx`.

<details>
<summary><strong>Choose an installation directory or version</strong></summary>

Set `IMX_PREFIX` to choose an installation prefix. Its `bin/` directory must already be on your `PATH`, or you can invoke the executable by its full path:

```bash
curl -fsSL https://github.com/inwf/imx/releases/latest/download/install.sh | IMX_PREFIX="$HOME/apps/imx" bash
"$HOME/apps/imx/bin/imx" -v
```

Install a specific published version, such as `v0.2.0`:

```bash
curl -fsSL https://github.com/inwf/imx/releases/download/v0.2.0/install.sh | bash -s -- v0.2.0
```

The installer also installs license files and removes temporary download and extraction files when it finishes.

</details>

### Create and reattach to a session

Create a session named `dev`, or attach to it if it already exists:

```bash
imx attach dev
```

Run commands in the session as usual. Press **`Ctrl+\`** to detach the current connection while the shell and programs keep running. Reattach with the same command:

```bash
imx attach dev
```

List sessions and read retained output from another terminal:

```bash
imx ls
imx cat dev
```

Terminate a session when you are finished:

```bash
imx kill dev
```

### Update and uninstall

Run the installation command again to install the latest release while keeping active sessions running. An existing backend continues using the version it started with; once all sessions have ended, a newly created session uses the updated version.

```bash
imx uninstall
```

Uninstalling terminates the current user's imx sessions and removes the current executable, installed licenses, and recorded runtime files. It invokes `sudo` when removing system installation files. User files in working directories are preserved. See the [usage guide](docs/usage.md#卸载) for details.

## Commands

| Command | Purpose |
| --- | --- |
| `imx attach dev` | Create or attach to the `dev` session |
| `imx list`, `imx ls`, `imx` | List all sessions |
| `imx cat dev` | Print retained history and the active screen as text |
| `imx detach` | Run inside a session to detach all its connections |
| `imx kill dev` | Terminate and remove the `dev` session |
| `imx uninstall` | Remove the current installation and runtime files |
| `imx -v` | Print the version |
| `imx help` | Print help |

Session lists include `NAME`, `PID`, `CLIENTS`, `DIRECTORY`, and `CREATED`. The `CREATED` column records the creation date in the backend's local timezone as `YY-MM-DD`, such as `26-10-30`, and stays the same when you reattach.

Sessions and history are held in memory and are released when the machine restarts or the backend exits. Session name rules, history limits, and behavior with multiple terminals are described in the [usage guide](docs/usage.md).

## Resource usage

Measured with imx 0.2.0 on x86_64 WSL2 Linux, using the default build mode and an 80×24 terminal:

| Idle sessions | Backend memory (PSS) | Backend processes | Backend threads |
| --- | --- | --- | --- |
| 1 | 1.47 MiB | 1 | 1 |
| 10 | 2.02 MiB | 1 | 1 |
| 100 | 6.38 MiB | 1 | 1 |

The table covers the imx backend. Shells and session programs consume additional memory. Backend CPU time did not increase during each scenario's 5-second idle sample; the static executable was approximately 1.77 MiB.

See the [performance guide](docs/performance.md) for the measurement environment, sustained output results, capacity limits, and instructions for measuring on your own machine.

## Build from source

Requires **Zig 0.17.0** and Linux. Zig downloads and verifies the dependencies pinned in `build.zig.zon`.

```bash
git clone https://github.com/inwf/imx.git
cd imx
zig build
./zig-out/bin/imx attach dev
```

The default build produces a static executable using musl. Build modes, cross-compilation, tests, and GitHub Actions are covered in the [development guide](docs/development.md).

## Documentation

| Looking for | Start here |
| --- | --- |
| 中文介绍与快速开始 | [简体中文 README](README.zh-CN.md) |
| Session behavior, history, environment variables, and uninstalling | [Usage guide](docs/usage.md) |
| Resource limits, measurements, and benchmarking | [Performance guide](docs/performance.md) |
| Building, testing, contributing, and publishing releases | [Development guide](docs/development.md) |

The detailed guides linked above are in Simplified Chinese.

## License

imx uses the [MIT License](LICENSE). Terminal history formatting and state restoration are adapted from zmx, and terminal processing uses Ghostty's `ghostty-vt`. Copyright notices and third-party licenses are in [NOTICE](NOTICE) and [licenses/](licenses/).
