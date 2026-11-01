<div align="center">
  <img src="docs/assets/logo.svg" alt="imx 标志" width="80" height="80" />
  <h1>imx</h1>
  <p><strong>让终端会话持续运行。</strong></p>
  <p>面向 Linux 的轻量终端会话管理工具。<br />断开连接后程序继续运行，重新连接即可恢复屏幕和保留的历史。</p>
  <p>
    <a href="#快速开始"><strong>快速开始</strong></a> ·
    <a href="#工作方式">工作方式</a> ·
    <a href="#资源占用">资源占用</a> ·
    <a href="#文档">文档</a> ·
    <a href="README.md">English</a>
  </p>
  <p>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-3b7c57?style=flat-square" alt="MIT 许可证" /></a>
    <a href="install.sh"><img src="https://img.shields.io/badge/Linux-x86__64%20%7C%20ARM64-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux，支持 x86_64 和 ARM64" /></a>
    <a href=".zig-version"><img src="https://img.shields.io/badge/Zig-0.17.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.17.0" /></a>
    <a href="https://github.com/inwf/imx/releases"><img src="https://img.shields.io/github/v/release/inwf/imx?style=flat-square" alt="最新版本" /></a>
  </p>
</div>


## 为断开连接后继续运行的会话准备

关闭终端窗口或断开 SSH 连接后，会话中的 shell 和程序继续在主机上运行。imx 在你回来时恢复屏幕和保留的历史。

每个会话拥有独立的后台进程，内部运行一个事件循环线程。后台在所属会话创建时启动，在该会话及其连接结束后退出。空闲时通过 `epoll` 等待内核事件。某个后台暂停或崩溃时，其他会话仍然可用。

<table>
  <tr>
    <td width="33%" valign="top">
      <h3>保留会话</h3>
      关闭终端或断开 SSH 连接后，shell 和其中的程序继续运行。
    </td>
    <td width="33%" valign="top">
      <h3>恢复现场</h3>
      重新连接时恢复屏幕、颜色和保留的历史，Vim 等全屏程序保持离开时的状态。
    </td>
    <td width="33%" valign="top">
      <h3>查看输出</h3>
      在任意终端通过 <code>imx cat</code> 以纯文本读取会话保留的历史和当前屏幕。
    </td>
  </tr>
  <tr>
    <td valign="top">
      <h3>共享连接</h3>
      多个终端可以同时进入同一个会话，共享它的输入和输出。
    </td>
    <td valign="top">
      <h3>会话提示符</h3>
      开启一个选项，新启动的 Bash、Zsh 和 Fish 会在原有提示符前显示 <code>[dev]</code>，保留原来的路径、颜色和主题。
    </td>
    <td valign="top">
      <h3>Tab 补全</h3>
      在 Bash、Zsh 和 Fish 中补全命令和当前会话的名称，补全文件由安装脚本放到位。
    </td>
  </tr>
  <tr>
    <td valign="top">
      <h3>一个配置文件</h3>
      首次使用时自动创建包含默认值和注释的 TOML 文件，用于设置会话提示符、补全和 <code>CREATED</code> 列的时间格式。语法、选项名称和取值类型都会检查。
    </td>
    <td valign="top">
      <h3>会话隔离</h3>
      每个会话由独立后台进程管理，内部运行一个事件循环线程。某个后台暂停或崩溃时，其他会话仍然可用。
    </td>
    <td valign="top">
      <h3>直接安装</h3>
      发布文件是 x86_64 和 ARM64 的 musl 静态可执行文件，附带补全文件。安装脚本自动选择架构并校验 SHA256，<code>imx update</code> 升级现有安装。
    </td>
  </tr>
</table>

## 快速开始

### 1. 安装

要求 **Linux 5.9 或更新版本**，支持 **x86_64** 和 **ARM64**。安装脚本需要 Bash、curl、GNU tar、GNU coreutils 和 GNU findutils。

```bash
curl -fsSL https://github.com/inwf/imx/releases/latest/download/install.sh | bash
```

| 安装内容   | 位置                                                         |
| ---------- | ------------------------------------------------------------ |
| 可执行文件 | `/usr/local/bin/imx`                                         |
| 许可证     | `/usr/local/share/licenses/imx/`                             |
| 补全文件   | `/usr/local` 下的 `share/bash-completion/`、`share/zsh/` 和 `share/fish/` |

默认情况下，只要 `PATH` 包含 `/usr/local/bin`，脚本就安装到 `/usr/local`。当 `PATH` 缺少该目录且包含 `/usr/bin` 时，安装到 `/usr`。写入系统目录需要管理员权限时会调用 `sudo`。安装后执行 `imx -v` 确认版本。

安装和 `imx update` 会以英文显示获取版本、下载、校验、解压和安装阶段的状态。标准错误输出连接终端时，软件包下载会显示实际百分比的进度条，通过 `curl ... | bash` 安装也可以显示。将标准错误输出重定向到日志时，状态消息使用普通文本行。需要管理员权限时，会在运行 `sudo` 前显示提示。

安装后启动新的 shell 即可加载补全。Bash 4.4 或更新版本需要启用 `bash-completion`，Zsh 需要初始化 `compinit`，Fish 会自动加载。手动加载补全和自定义前缀的设置见[使用说明](docs/usage.md#tab-补全)。

<details>
<summary><strong>指定安装目录或版本</strong></summary>


通过 `IMX_PREFIX` 指定其他安装前缀。该前缀的 `bin/` 目录需要已经位于 `PATH` 中，也可以通过完整路径调用可执行文件：

```bash
curl -fsSL https://github.com/inwf/imx/releases/latest/download/install.sh | IMX_PREFIX="$HOME/apps/imx" bash
"$HOME/apps/imx/bin/imx" -v
```

安装已经发布的指定版本，例如 `v0.5.0`：

```bash
curl -fsSL https://github.com/inwf/imx/releases/download/v0.5.0/install.sh | bash -s -- v0.5.0
```

安装脚本把许可证和补全文件安装到相同前缀下，并在完成后删除下载和解压产生的临时文件。系统安装会同时在 `/usr/local` 和 `/usr` 下提供 Fish 补全文件。使用自定义前缀时，Bash 和 Fish 通过 `XDG_DATA_DIRS` 查找补全文件，Zsh 通过 `fpath` 查找。

</details>

<details>
<summary><strong>从源码编译</strong></summary>


需要 **Zig 0.17.0**。Zig 会下载并校验 `build.zig.zon` 中固定版本的依赖。

```bash
git clone https://github.com/inwf/imx.git
cd imx
zig build
./zig-out/bin/imx attach dev
```

默认生成使用 musl 的静态可执行文件，并把补全文件写入 `zig-out/share/`。编译模式、交叉编译、测试和 GitHub Actions 见[开发说明](docs/development.md)。

</details>

### 2. 创建会话

```bash
imx attach dev
```

照常运行命令。关闭终端、断开 SSH 连接或按下 **`Ctrl+\`** 会分离当前连接，shell 和其中的程序继续运行。

应用启用 Kitty 键盘协议或 xterm 的 modifyOtherKeys 模式时，该快捷键同样有效。启用括号粘贴模式时，粘贴内容会原样传递，不会触发快捷键。

### 3. 返回会话

```bash
imx attach dev   # 重新连接，恢复屏幕和历史
imx ls           # 查看全部会话
imx cat dev      # 在任意终端读取保留的输出
imx kill dev     # 终止会话
```

重新连接会恢复屏幕、颜色和保留的历史，Vim 等全屏程序保持离开时的状态。

退出或分离时会恢复正常的终端显示和输入模式，并在屏幕底部追加空行显示外层 shell 提示符。

在 `dev1` 内执行 `imx attach dev2`，当前终端会切换到 `dev2`，两个会话的程序和历史继续保留。目标不存在时，使用当前目录、环境变量和 `$SHELL` 创建。执行 `imx attach dev1` 可以返回，其他连接到 `dev1` 的终端继续保持连接。连接选择、错误处理和版本要求见[切换会话](docs/usage.md#切换会话)。

> [!IMPORTANT]
> 会话和历史保存在内存中。后台进程退出会释放所属会话，主机重启会释放全部会话。

### 4. 按需配置

执行 `imx`、`imx ls`、`imx list` 或 `imx attach <name>` 时，如果 `~/.config/imx/config.toml` 不存在，程序会自动创建包含全部默认设置和中英文注释的文件。设置了非空的 `XDG_CONFIG_HOME` 时，文件创建在 `$XDG_CONFIG_HOME/imx/config.toml`。已有文件保留原有内容和权限。

自动生成的配置文件包含以下默认设置：

```toml
[prompt]
show_session = true

[list]
created_format = "%m-%d %H:%M:%S"

[completion]
enabled = true
```

- **`prompt.show_session`**：会话中新启动的 Bash、Zsh 和 Fish 在原有提示符前显示 `[dev] `，保留提示符原来的路径、颜色和主题。下一次执行 `imx attach` 时，程序把集成代码写入 shell 初始化文件，以 `# BEGIN imx shell integration` 和 `# END imx shell integration` 标记。改为 `false` 后再次进入会话即可移除。默认值为 `true`，省略该选项时也会启用。
- **`list.created_format`**：用 `strftime` 字段设置 `CREATED` 列的格式。默认显示为 `10-30 14:05:09`，`%Y-%m-%d %H:%M:%S` 会带上年份。
- **`completion.enabled`**：开启或关闭命令和会话名称的 Tab 补全。默认值为 `true`。

语法错误、未知选项和取值类型错误会在进入会话或查看列表时报告。初始化文件的位置和修改方式见使用说明的[配置部分](docs/usage.md#配置文件与会话提示符)。

## 工作方式

`imx` 命令通过私有运行目录中各个会话的 Unix socket 与对应后台进程通信。每个后台持有所属会话的 PTY，并使用 Ghostty 的 `ghostty-vt` 库维护实时的终端状态，包括屏幕内容、颜色和历史。重新连接时把这份状态恢复到终端，`imx cat` 则把同一份状态转换为纯文本。

| 命令                        | 功能                                     |
| --------------------------- | ---------------------------------------- |
| `imx attach dev`            | 创建或进入 `dev`；在会话内部执行时，将当前终端切换到 `dev` |
| `imx list`、`imx ls`、`imx` | 查看全部会话                             |
| `imx cat dev`               | 输出保留的历史和当前屏幕文字             |
| `imx detach`                | 在会话内部执行，分离该会话的全部连接     |
| `imx kill dev`              | 终止会话，包括 shell、前台作业和后台作业 |
| `imx update`                | 在当前安装目录安装最新发布版本           |
| `imx uninstall`             | 终止当前用户的会话并卸载                 |
| `imx -v`                    | 查看版本                                 |
| `imx help`                  | 查看帮助                                 |

会话的生命周期：

1. **进入。** 使用 `imx attach dev` 创建 `dev` 时，启动该会话的后台进程，并使用当前工作目录、环境变量和 `$SHELL` 运行 shell。进入已有会话时保留其状态。
2. **分离。** 关闭终端、连接断开、按下 `Ctrl+\`，或在会话内部执行 `imx detach`，会话都继续运行。
3. **返回或结束。** `imx attach dev` 恢复屏幕和历史；shell 退出或执行 `imx kill dev` 会结束会话。

会话列表包含 `NAME`、`PID`、`CLIENTS`、`DIRECTORY`、`CREATED` 和 `STATUS`。终端输出根据标题和会话内容计算列宽，管道和重定向输出使用制表符分隔。`DIRECTORY` 显示会话 shell 当前的实际目录，随 `cd` 和目录重命名更新。特殊字符采用转义形式，以保持输出结构，详细规则见[会话列表](docs/usage.md#会话列表)。

`CREATED` 按后台进程的本地时区显示创建时间，默认格式为 `MM-DD HH:mm:ss`，例如 `10-30 14:05:09`。每次查看列表都会读取 `list.created_format`，修改后在下一次查询时应用到已有会话。重新进入会话时保留原来的创建时间。

列表并发查询后台，共享一秒查询期限。`STATUS` 显示 `running`、`unresponsive` 或 `error:<错误名称>`，无法获取的字段显示 `-`。连接后台和等待命令响应使用两秒超时。

### 限制

| 项目     | 行为                                                         |
| -------- | ------------------------------------------------------------ |
| 会话名称 | 1–64 个 ASCII 字母、数字、句点、下划线和连字符；`.` 和 `..` 为保留名称 |
| 历史     | 10,000 行目标及 2 MiB 容量限制，按完整终端页面修剪           |
| 终端尺寸 | 最多 512 列、256 行；最近进入的连接决定终端大小              |
| 输出队列 | 每个队列最多 256 KiB；落后的连接会断开，会话继续运行         |

### Shell 集成

| Shell | 提示符集成位置                                               | 安装前缀下的补全文件                                         |
| ----- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| Bash  | `~/.bashrc`，以及 `.bash_profile`、`.bash_login`、`.profile` 中首个可读的登录文件 | `share/bash-completion/completions/imx`                      |
| Zsh   | `$ZDOTDIR` 中的 `.zshrc` 和 `.zlogin`；未设置时使用 `$HOME`  | `share/zsh/site-functions/_imx` 和 `share/zsh/vendor-completions/_imx` |
| Fish  | `$XDG_CONFIG_HOME/fish/config.fish`，或 `~/.config/fish/config.fish` | `share/fish/vendor_completions.d/imx.fish`                   |

集成脚本和修改记录保存在 `~/.local/state/imx/shell/`。`imx attach` 只添加或移除每个初始化文件中带标记的片段，其他内容保持原样；手动修改过的片段会被报告，程序会停止处理。`attach`、`cat` 和 `kill` 的补全在每次按下 Tab 时并发查询当前会话后台，共享 250 毫秒查询期限。新增和删除的会话即时反映在候选中，无响应后台的会话名称仍然保留。

### 运行目录

运行目录按以下顺序选择：`$IMX_DIR`、`$XDG_RUNTIME_DIR/imx`、`~/.local/state/imx/run`。该目录仅属于当前用户（权限 `0700`），各个后台使用 `SO_PEERCRED` 检查连接用户。每个会话在该目录中拥有 `session-<name>.sock`、`session-<name>.lock` 和 `session-<name>.log`，日志记录对应后台的错误。

| 变量              | 用途                                                         |
| ----------------- | ------------------------------------------------------------ |
| `HOME`            | 需要为绝对路径；保存运行目录记录，并提供默认的运行目录和配置目录 |
| `SHELL`           | 创建新会话时运行的 shell；未设置时使用 `/bin/sh`             |
| `IMX_SESSION`     | imx 在会话内部设置的会话名称，供会话切换、`imx detach` 和会话提示符使用 |
| `IMX_DIR`         | 指定绝对路径的运行目录，优先于 `XDG_RUNTIME_DIR`             |
| `XDG_RUNTIME_DIR` | 未设置 `IMX_DIR` 时，使用该目录下的 `imx/`                   |
| `XDG_CONFIG_HOME` | 存放 `imx/config.toml`，并决定 Fish 的配置目录               |
| `XDG_DATA_DIRS`   | Bash 和 Fish 在自定义前缀下查找补全文件                      |
| `ZDOTDIR`         | 选择 Zsh 提示符集成使用的初始化文件                          |
| `IMX_PREFIX`      | 安装脚本使用的安装前缀                                       |

## 更新和卸载

```bash
imx update
imx uninstall
```

`imx update` 把最新发布版本安装到当前安装前缀，自动选择架构并校验 SHA256。可以在会话内部或外部执行。已有后台继续使用启动时的版本，保留程序和历史；新建的独立后台使用更新后的可执行文件。

从 v0.4.1 升级时，已有共享后台继续管理所在运行目录，直到其中的全部会话结束，后续创建的会话使用独立后台。过渡行为见[更新说明](docs/usage.md#更新)，客户端和后台的版本要求见[切换会话](docs/usage.md#切换会话)。

`imx uninstall` 终止当前用户的全部 imx 会话，删除可执行文件、安装的许可证和补全文件、配置文件、记录中的 shell 集成以及记录过的运行文件。工作目录中的用户文件保留。

<details>
<summary><strong>更新和卸载涉及的内容</strong></summary>


- 更新保留当前安装前缀，系统目录、自定义 `IMX_PREFIX` 和通过符号链接运行的安装都可以识别。下载失败、校验不一致或取消 `sudo` 授权时，安装和全部会话保持原状。
- 卸载使用 Linux session ID 和 pidfd 终止会话，随后清理 socket、锁文件、许可证和补全文件、配置文件、记录中写入 shell 初始化文件的集成片段，以及记录过的全部运行目录。通过符号链接运行时，实际可执行文件和调用使用的链接一并删除。手动修改过的集成片段会让卸载停止，并报告对应路径。
- 两个命令只处理当前用户。其他用户的会话和运行文件不受影响；系统安装的可执行文件、许可证和补全文件为共享文件。

</details>

## 资源占用

2026-10-31 在 x86_64 WSL2 Linux 上，使用独立会话后台的开发版本、默认编译模式和 80×24 终端测量：

| 空闲会话数量 | 后台内存（PSS） | 后台进程数量 | 后台线程数量 |
| ------------ | --------------- | ------------ | ------------ |
| 1            | 1.85 MiB        | 1            | 1            |
| 10           | 3.96 MiB        | 10           | 10           |
| 100          | 25.09 MiB       | 100          | 100          |

表中合计全部 imx 后台进程，shell 和会话程序单独占用内存。此次测量中，连接中的客户端约占 1.07 MiB PSS，静态可执行文件约为 2.11 MiB。生成并处理 500,000 行输出（约 3.89 MB）耗时约 0.59 秒，占用后台 CPU 时间约 0.26 秒。上表各场景的 5 秒空闲采样中，后台 CPU 时间增量均为零。

另一个会话持续输出时，健康会话的 100 次命令响应中位数为 1.00 毫秒，最大值为 2.10 毫秒。存在暂停后台时，列表查询约耗时 1,003 毫秒，补全约耗时 252 毫秒。具体资源占用随系统、终端尺寸和会话内容变化。

测量环境、容量限制和复测方法见[性能说明](docs/performance.md)。

## 文档

| 内容                                                   | 文档                            |
| ------------------------------------------------------ | ------------------------------- |
| 英文介绍与快速开始                                     | [English README](README.md)     |
| 会话行为、配置、shell 集成、补全、历史、环境变量和卸载 | [使用说明](docs/usage.md)       |
| 资源限制、性能测量和复测方法                           | [性能说明](docs/performance.md) |
| 编译、测试、贡献和版本发布                             | [开发说明](docs/development.md) |

## 开发

```bash
zig fmt --check build.zig src   # 格式检查
zig build                       # 生成 zig-out/bin/imx 和补全文件
zig build test                  # 单元测试
mkdir -p work/runtime
TMPDIR="$PWD/work/runtime" uv run --frozen --project tests pytest -q tests   # 集成测试：真实 PTY、Bash、Zsh、Fish 和 Vim
```

集成测试启动真实 PTY、Bash、Zsh、Fish 和 Vim，并通过各个 shell 自身的加载机制测试补全。完整的测试环境要求、shell 脚本检查以及使用 `sudo` 的系统安装测试见[开发说明](docs/development.md)。

| 部分  | 使用的技术                                                   |
| ----- | ------------------------------------------------------------ |
| 核心  | Zig 0.17.0 · Ghostty `ghostty-vt` · tomlc17 · musl 静态编译 · `epoll`、`signalfd`、pidfd 和 PTY |
| Shell | Bash · Zsh · Fish · bash-completion                          |
| 测试  | Python 3.12+ · pytest · pexpect · pyte · uv                  |
| 发布  | GitHub Actions · SHA256 校验、附带补全文件的安装包 · `imx update` 复用的安装脚本 |

## 许可证

imx 使用 [MIT 许可证](LICENSE)。

imx 用到的第三方项目：

- [zmx](https://github.com/neurosnap/zmx)：终端历史格式化和状态恢复参考其实现，MIT 许可证。
- [Ghostty](https://github.com/ghostty-org/ghostty)：终端处理使用其 `ghostty-vt` 库，MIT 许可证。
- [tomlc17](https://github.com/cktan/tomlc17)：解析配置文件，MIT 许可证。

版权声明和全部第三方许可证见 [NOTICE](NOTICE) 和 [licenses/](licenses/)，其中包括 `ghostty-vt` 附带的库。

<p align="center"><sub>如果 imx 让你的会话持续运行，欢迎在 <a href="https://github.com/inwf/imx">GitHub</a> 上点亮 Star，让更多人发现它。</sub></p>
