<div align="center">
  <img src="docs/assets/logo.svg" alt="imx logo" width="80" height="80" />
  <h1>imx</h1>
  <p><strong>Keep your terminal sessions running.</strong></p>
  <p>A lightweight terminal session manager for Linux.<br />Disconnect while programs keep running. Reattach to restore your screen and retained history.</p>
  <p>
    <a href="#quick-start"><strong>Quick start</strong></a> ·
    <a href="#how-it-works">How it works</a> ·
    <a href="#resource-usage">Resource usage</a> ·
    <a href="#documentation">Documentation</a> ·
    <a href="README.zh-CN.md">简体中文</a>
  </p>
  <p>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-3b7c57?style=flat-square" alt="MIT License" /></a>
    <a href="install.sh"><img src="https://img.shields.io/badge/Linux-x86__64%20%7C%20ARM64-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux, x86_64 and ARM64" /></a>
    <a href=".zig-version"><img src="https://img.shields.io/badge/Zig-0.17.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.17.0" /></a>
    <a href="https://github.com/inwf/imx/releases"><img src="https://img.shields.io/github/v/release/inwf/imx?style=flat-square" alt="Latest release" /></a>
  </p>
</div>


## Built for sessions that outlast the connection

Close a terminal window or disconnect SSH while your session's shell and programs keep running on the host. imx restores the screen and retained history when you return.

Each session has an independent backend process with one event loop thread. The backend starts when its session is created and exits once that session and its connections end. While idle it waits on `epoll` for kernel events. Other sessions remain available when one backend is paused or crashes.

<table>
  <tr>
    <td width="33%" valign="top">
      <h3><img src="docs/assets/icons/infinity.svg" width="24" height="24" align="middle" alt="" /> Persistent sessions</h3>
      Close the terminal or lose the SSH connection. The shell and its programs keep running while you are away.
    </td>
    <td width="33%" valign="top">
      <h3><img src="docs/assets/icons/history.svg" width="24" height="24" align="middle" alt="" /> Screen restoration</h3>
      Reattach to restore the screen, colors, and retained history. Full-screen programs such as Vim come back as you left them.
    </td>
    <td width="33%" valign="top">
      <h3><img src="docs/assets/icons/file-text.svg" width="24" height="24" align="middle" alt="" /> Readable output</h3>
      Read a session's retained history and active screen as plain text from any terminal with <code>imx cat</code>.
    </td>
  </tr>
  <tr>
    <td valign="top">
      <h3><img src="docs/assets/icons/users.svg" width="24" height="24" align="middle" alt="" /> Shared connections</h3>
      Several terminals can attach to one session at once and share its input and output.
    </td>
    <td valign="top">
      <h3><img src="docs/assets/icons/terminal.svg" width="24" height="24" align="middle" alt="" /> Session prompt</h3>
      Turn on one option and new Bash, Zsh, and Fish shells show <code>[dev]</code> before your existing prompt, keeping its path, colors, and theme.
    </td>
    <td valign="top">
      <h3><img src="docs/assets/icons/keyboard.svg" width="24" height="24" align="middle" alt="" /> Tab completion</h3>
      Complete commands and the names of current sessions in Bash, Zsh, and Fish. The installer puts the completion files in place.
    </td>
  </tr>
  <tr>
    <td valign="top">
      <h3><img src="docs/assets/icons/sliders-horizontal.svg" width="24" height="24" align="middle" alt="" /> One configuration file</h3>
      A TOML file with commented defaults is created on first use. It sets the session prompt, completion, and the <code>CREATED</code> time format. Syntax, option names, and value types are checked.
    </td>
    <td valign="top">
      <h3><img src="docs/assets/icons/feather.svg" width="24" height="24" align="middle" alt="" /> Session isolation</h3>
      Each session runs in its own backend with one event loop thread. A paused or crashed backend leaves other sessions available.
    </td>
    <td valign="top">
      <h3><img src="docs/assets/icons/package.svg" width="24" height="24" align="middle" alt="" /> Direct installation</h3>
      Releases ship static musl executables for x86_64 and ARM64 together with completion files. The installer selects the architecture, checks SHA256, and <code>imx update</code> upgrades in place.
    </td>
  </tr>
</table>


## Quick start

### 1. Install

**Linux 5.9 or newer** on **x86_64** or **ARM64**. The install script requires Bash, curl, GNU tar, GNU coreutils, and GNU findutils.

```bash
curl -fsSL https://github.com/inwf/imx/releases/latest/download/install.sh | bash
```

| Installed        | Location                                                     |
| ---------------- | ------------------------------------------------------------ |
| Executable       | `/usr/local/bin/imx`                                         |
| License files    | `/usr/local/share/licenses/imx/`                             |
| Completion files | `share/bash-completion/`, `share/zsh/`, and `share/fish/` under `/usr/local` |

By default, the script installs under `/usr/local` whenever `PATH` includes `/usr/local/bin`. If that directory is absent from `PATH` and `/usr/bin` is present, it installs under `/usr`. It invokes `sudo` when system directories need administrator permissions. Confirm the installation with `imx -v`.

Open a new shell afterwards to load completion. Bash 4.4 or newer needs `bash-completion` enabled, Zsh needs `compinit` initialized, and Fish loads the file automatically. The [usage guide](docs/usage.md#tab-补全) covers loading completion by hand and custom prefixes.

<details>
<summary><strong>Choose an installation directory or version</strong></summary>


Set `IMX_PREFIX` to install under a different prefix. Its `bin/` directory must already be on your `PATH`, or you can invoke the executable by its full path:

```bash
curl -fsSL https://github.com/inwf/imx/releases/latest/download/install.sh | IMX_PREFIX="$HOME/apps/imx" bash
"$HOME/apps/imx/bin/imx" -v
```

Install a specific published version, such as `v0.5.0`:

```bash
curl -fsSL https://github.com/inwf/imx/releases/download/v0.5.0/install.sh | bash -s -- v0.5.0
```

The installer places the license and completion files under the same prefix and removes its temporary download and extraction files when it finishes. System installations provide the Fish completion file under both `/usr/local` and `/usr`. With a custom prefix, Bash and Fish find the completion files through `XDG_DATA_DIRS` and Zsh through `fpath`.

</details>

<details>
<summary><strong>Build from source</strong></summary>


Requires **Zig 0.17.0**. Zig downloads and verifies the dependencies pinned in `build.zig.zon`.

```bash
git clone https://github.com/inwf/imx.git
cd imx
zig build
./zig-out/bin/imx attach dev
```

The default build produces a static executable using musl and writes the completion files under `zig-out/share/`. Build modes, cross-compilation, tests, and GitHub Actions are covered in the [development guide](docs/development.md).

</details>

### 2. Start a session

```bash
imx attach dev
```

Run commands as usual. Closing the terminal, losing the SSH connection, or pressing **`Ctrl+\`** detaches your connection while the shell and its programs keep running.

### 3. Come back

```bash
imx attach dev   # reattach; the screen and history return
imx ls           # list all sessions
imx cat dev      # read retained output from any terminal
imx kill dev     # terminate the session
```

Reattaching restores the screen, colors, and retained history. Full-screen programs such as Vim return with the document as you left it.

To switch sessions, run `imx attach dev2` inside `dev1`. The current terminal moves to `dev2`, and both sessions keep their programs and history. If the target does not exist, it is created using the current directory, environment, and `$SHELL`. Run `imx attach dev1` to return. Other terminals attached to `dev1` stay connected. See [session switching](docs/usage.md#切换会话) for connection selection, error handling, and version requirements.

> [!IMPORTANT]
> Sessions and history are held in memory. A backend exiting releases its session; restarting the host releases all sessions.

### 4. Make it yours

Running `imx`, `imx ls`, `imx list`, or `imx attach <name>` automatically creates `~/.config/imx/config.toml` when it is missing, with all default settings and comments. If `XDG_CONFIG_HOME` is set to a nonempty value, the file is created at `$XDG_CONFIG_HOME/imx/config.toml`. Existing files keep their contents and permissions.

Edit the generated file to enable the session prompt while keeping the other defaults:

```toml
[prompt]
show_session = true

[list]
created_format = "%m-%d %H:%M:%S"

[completion]
enabled = true
```

- **`prompt.show_session`** shows `[dev] ` before the prompt of new Bash, Zsh, and Fish shells inside sessions, keeping the prompt's path, colors, and theme. The next `imx attach` installs the integration between `# BEGIN imx shell integration` and `# END imx shell integration` markers in your shell startup files. Set the option to `false` and attach again to remove it. The default is `false`.
- **`list.created_format`** formats the `CREATED` column with `strftime` fields. The default shows `10-30 14:05:09`; `%Y-%m-%d %H:%M:%S` adds the year.
- **`completion.enabled`** switches Tab completion of commands and session names. The default is `true`.

Syntax errors, unknown options, and wrong value types are reported when you attach or list sessions. The [configuration section](docs/usage.md#配置文件与会话提示符) of the usage guide lists the startup files and describes how they are edited.

## How it works

`imx` commands talk to each session's backend over its own Unix socket in a private runtime directory. Each backend owns its session's PTY and keeps a live terminal model with Ghostty's `ghostty-vt` library: screen contents, colors, and scrollback. Reattaching replays that model to your terminal, and `imx cat` formats the same state as plain text.

| Command                     | Purpose                                                      |
| --------------------------- | ------------------------------------------------------------ |
| `imx attach dev`            | Create or attach to `dev`; inside a session, switch the current terminal to `dev` |
| `imx list`, `imx ls`, `imx` | List all sessions                                            |
| `imx cat dev`               | Print retained history and the active screen as text         |
| `imx detach`                | Run inside a session to detach all of its connections        |
| `imx kill dev`              | Terminate the session, including its shell, foreground jobs, and background jobs |
| `imx update`                | Install the latest published release in the current installation directory |
| `imx uninstall`             | Terminate the current user's sessions and remove the installation |
| `imx -v`                    | Print the version                                            |
| `imx help`                  | Print help                                                   |

A session's life:

1. **Attach.** Creating `dev` with `imx attach dev` starts its backend and runs the shell selected by `$SHELL` with the current working directory and environment. Attaching to an existing session preserves its state.
2. **Detach.** Closing the terminal, a dropped connection, `Ctrl+\`, or `imx detach` inside the session all leave the session running.
3. **Return or finish.** `imx attach dev` restores the screen and history. The session ends when the shell exits or with `imx kill dev`.

Session lists include `NAME`, `PID`, `CLIENTS`, `DIRECTORY`, `CREATED`, and `STATUS`. Terminal output uses column widths calculated from the headings and session contents; piped or redirected output is tab-separated. `DIRECTORY` shows the session shell's current actual directory, following `cd` and directory renames. Special characters are escaped to preserve the output structure; see [session lists](docs/usage.md#会话列表) for details.

`CREATED` shows the creation time in the backend's local timezone, by default as `MM-DD HH:mm:ss` such as `10-30 14:05:09`. Each list command reads `list.created_format`, so format changes apply to existing sessions on the next query. Reattaching keeps the creation time.

List queries run concurrently with a shared one-second deadline. `STATUS` shows `running`, `unresponsive`, or `error:<error name>`; unavailable fields show `-`. Connecting to a backend and waiting for command responses use two-second timeouts.

### Limits

| Item            | Behavior                                                     |
| --------------- | ------------------------------------------------------------ |
| Session names   | 1-64 characters: ASCII letters, digits, dots, underscores, and hyphens; `.` and `..` are reserved |
| History         | 10,000-line target within a 2 MiB budget, trimmed in complete terminal pages |
| Terminal size   | Up to 512 columns × 256 rows; the most recent connection sets the size |
| Output queues   | 256 KiB per queue; a connection that falls behind is disconnected and the session keeps running |

### Shell integration

| Shell | Prompt integration                                           | Completion file under the prefix                             |
| ----- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| Bash  | `~/.bashrc` and the first readable login file among `.bash_profile`, `.bash_login`, and `.profile` | `share/bash-completion/completions/imx`                      |
| Zsh   | `.zshrc` and `.zlogin` in `$ZDOTDIR`, or in `$HOME` when it is unset | `share/zsh/site-functions/_imx` and `share/zsh/vendor-completions/_imx` |
| Fish  | `$XDG_CONFIG_HOME/fish/config.fish`, or `~/.config/fish/config.fish` | `share/fish/vendor_completions.d/imx.fish`                   |

The integration scripts and the record of edited files live in `~/.local/state/imx/shell/`. `imx attach` adds or removes only the marked block in each startup file and leaves your other content in place; a block that was edited by hand is reported instead of changed. Completion for `attach`, `cat`, and `kill` queries the current session backends concurrently on every Tab press, with a shared 250 ms deadline. New and removed sessions appear immediately, and names from unresponsive backends remain available.

### Runtime directory

The runtime directory is chosen in this order: `$IMX_DIR`, then `$XDG_RUNTIME_DIR/imx`, then `~/.local/state/imx/run`. It is private to the current user (mode `0700`), and each backend verifies connecting processes with `SO_PEERCRED`. Each session has `session-<name>.sock`, `session-<name>.lock`, and `session-<name>.log` files in that directory. The log records errors from that session's backend.

| Variable          | Purpose                                                      |
| ----------------- | ------------------------------------------------------------ |
| `HOME`            | Must be an absolute path; stores runtime directory records and provides the default runtime and configuration directories |
| `SHELL`           | Shell used for new sessions; `/bin/sh` when unset            |
| `IMX_SESSION`     | Set inside sessions; identifies the session for switching, `imx detach`, and the session prompt |
| `IMX_DIR`         | Absolute runtime directory; overrides `XDG_RUNTIME_DIR`      |
| `XDG_RUNTIME_DIR` | When `IMX_DIR` is unset, `imx/` under this directory is used |
| `XDG_CONFIG_HOME` | Holds `imx/config.toml` and the Fish configuration directory |
| `XDG_DATA_DIRS`   | Lets Bash and Fish find completion files under a custom prefix |
| `ZDOTDIR`         | Selects the Zsh startup files for the prompt integration     |
| `IMX_PREFIX`      | Installation prefix for the install script                   |

## Update and uninstall

```bash
imx update
imx uninstall
```

`imx update` installs the latest published release into the current installation prefix, detects the architecture, and verifies SHA256 checksums. It can run inside or outside a session. Existing backends keep running the version they started with, preserving their programs and history; newly created independent backends use the updated executable.

When upgrading from v0.4.1, the existing shared backend continues to manage its runtime directory until all of its sessions end. Sessions created afterwards use independent backends. See [updating](docs/usage.md#更新) for this transition and [session switching](docs/usage.md#切换会话) for client and backend version requirements.

`imx uninstall` terminates the current user's sessions and removes the executable, installed license and completion files, the configuration file, the recorded shell integration, and recorded runtime files. User files in working directories are preserved.

<details>
<summary><strong>What update and uninstall touch</strong></summary>


- Update keeps the current installation prefix, whether it is a system directory, a custom `IMX_PREFIX`, or reached through a symlink. A failed download, a checksum mismatch, or a canceled `sudo` prompt leaves the installation and all sessions untouched.
- Uninstall terminates sessions through Linux session IDs and pidfd, then cleans up the socket, lock files, license and completion files, the configuration file, the integration blocks it recorded in shell startup files, and every recorded runtime directory. When imx was reached through a symlink, the real executable and the links used to call it are removed. An integration block that was edited by hand stops the uninstall and is reported with its path.
- Both operate on the current user only. Sessions and runtime files of other users are untouched, and a system-installed executable and its license and completion files are shared.

</details>

## Resource usage

Measured on 2026-10-31 with the development version using independent session backends, on x86_64 WSL2 Linux, using the default build mode and an 80×24 terminal:

| Idle sessions | Backend memory (PSS) | Backend processes | Backend threads |
| ------------- | -------------------- | ----------------- | --------------- |
| 1             | 1.85 MiB             | 1                 | 1               |
| 10            | 3.96 MiB             | 10                | 10              |
| 100           | 25.09 MiB            | 100               | 100             |

The table totals all imx backends; shells and session programs consume additional memory. A connected client used about 1.07 MiB PSS, and the static executable was about 2.11 MiB. Generating and processing 500,000 lines of output (about 3.89 MB) took about 0.59 s, using about 0.26 s of backend CPU time. Backend CPU time did not increase across the 5-second idle samples in each row above.

With another session producing continuous output, 100 commands in a healthy session had a median response time of 1.00 ms and a maximum of 2.10 ms. With a paused backend, a list query took about 1,003 ms and completion took about 252 ms. Resource usage depends on the system, terminal size, and session contents.

See the [performance guide](docs/performance.md) for the measurement environment, capacity limits, and instructions for measuring on your own machine.

## Documentation

| Looking for                                                  | Start here                               |
| ------------------------------------------------------------ | ---------------------------------------- |
| 中文介绍与快速开始                                           | [简体中文 README](README.zh-CN.md)       |
| Session behavior, configuration, shell integration, completion, history, environment variables, and uninstalling | [Usage guide](docs/usage.md)             |
| Resource limits, measurements, and benchmarking              | [Performance guide](docs/performance.md) |
| Building, testing, contributing, and publishing releases     | [Development guide](docs/development.md) |

The detailed guides linked above are in Simplified Chinese.

## Development

```bash
zig fmt --check build.zig src   # Formatting check
zig build                       # Build zig-out/bin/imx and the completion files
zig build test                  # Unit tests
mkdir -p work/runtime
TMPDIR="$PWD/work/runtime" uv run --frozen --project tests pytest -q tests   # Integration tests: real PTY, Bash, Zsh, Fish, and Vim
```

Integration tests drive a real PTY with Bash, Zsh, Fish, and Vim, and exercise completion through each shell's own loading mechanism. The [development guide](docs/development.md) covers the full test setup, the shell script checks, and the system installation tests that use `sudo`.

| Area     | Technologies                                                 |
| -------- | ------------------------------------------------------------ |
| Core     | Zig 0.17.0 · Ghostty `ghostty-vt` · tomlc17 · musl static build · `epoll`, `signalfd`, pidfd, and PTYs |
| Shells   | Bash · Zsh · Fish · bash-completion                          |
| Tests    | Python 3.12+ · pytest · pexpect · pyte · uv                  |
| Releases | GitHub Actions · SHA256-verified packages with completion files · installer reused by `imx update` |

## License

imx is released under the [MIT License](LICENSE).

Third-party projects used by imx:

- [zmx](https://github.com/neurosnap/zmx): terminal history formatting and state restoration are adapted from it. MIT License.
- [Ghostty](https://github.com/ghostty-org/ghostty): terminal processing uses its `ghostty-vt` library. MIT License.
- [tomlc17](https://github.com/cktan/tomlc17): parses the configuration file. MIT License.
- [Lucide](https://lucide.dev): the feature icons in this README. ISC License, see [docs/assets/icons/LICENSE](docs/assets/icons/LICENSE).

Copyright notices and the complete set of third-party licenses are in [NOTICE](NOTICE) and [licenses/](licenses/), including those of the libraries bundled with `ghostty-vt`.

<p align="center"><sub>If imx keeps your sessions alive, a <a href="https://github.com/inwf/imx">GitHub star</a> helps others find it.</sub></p>
