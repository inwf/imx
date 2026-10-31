<div align="center">
  <h1>imx</h1>
  <p><strong>让终端会话持续运行。</strong></p>
  <p>面向 Linux 的轻量终端会话管理工具。<br />断开连接后保留程序、屏幕和历史，重新连接即可继续工作。</p>
  <p>
    <a href="#快速开始"><strong>快速开始</strong></a> ·
    <a href="#命令">命令</a> ·
    <a href="#资源占用">资源占用</a> ·
    <a href="#文档">文档</a> ·
    <a href="README.md">English</a>
  </p>
  <p>Linux x86_64 / ARM64 · <a href=".zig-version">Zig 0.17.0</a> · <a href="LICENSE">MIT License</a></p>
</div>

## 功能

- **保留会话**：关闭终端或断开 SSH 后，shell 和会话中的程序继续运行。
- **恢复现场**：重新连接时恢复终端屏幕和保留的历史，支持 Vim 等全屏终端程序。
- **查看输出**：通过 `imx cat` 在会话外读取历史输出和当前屏幕文字。
- **共享连接**：多个终端可以同时进入同一个会话，共享输入和输出。
- **显示会话名称**：通过配置选项，在原有 Bash、Zsh 或 Fish 提示符前显示 `[dev]`。
- **设置时间格式**：通过配置文件修改会话列表中 `CREATED` 列的创建时间显示格式。
- **控制资源**：当前用户的全部会话由一个单线程后台进程管理，空闲时等待系统事件。
- **直接安装**：发布文件为静态可执行文件，安装脚本自动选择架构并校验 SHA256。

## 快速开始

### 安装

支持 **Linux 5.9 或更新版本**，发布软件包提供 **x86_64** 和 **ARM64（aarch64）** 两种架构。安装需要 Bash、curl、GNU tar、GNU coreutils 和 GNU findutils。

```bash
curl -fsSL https://github.com/inwf/imx/releases/latest/download/install.sh | bash
```

一键安装下载仓库中公开的 GitHub Release。仓库尚无发布版本时，可以使用下方的[源码编译](#源码编译)。

默认安装到 `/usr/local/bin/imx`，安装后即可直接运行：

```bash
imx -v
imx attach dev
```

普通用户安装时，脚本会自动调用 `sudo`，根据系统设置提示输入密码。root 用户直接安装。安装过程自动选择当前 `PATH` 中的系统命令目录；仅包含 `/usr/bin` 的环境会使用 `/usr/bin/imx`。

<details>
<summary><strong>指定安装目录或版本</strong></summary>

通过 `IMX_PREFIX` 指定安装前缀。自定义前缀的 `bin/` 目录需要已经位于当前 `PATH` 中，或者通过可执行文件的完整路径运行：

```bash
curl -fsSL https://github.com/inwf/imx/releases/latest/download/install.sh | IMX_PREFIX="$HOME/apps/imx" bash
"$HOME/apps/imx/bin/imx" -v
```

安装已经发布的指定版本，例如 `v0.3.1`：

```bash
curl -fsSL https://github.com/inwf/imx/releases/download/v0.3.1/install.sh | bash -s -- v0.3.1
```

安装脚本同时安装许可证，并在完成后删除下载和解压产生的临时文件。

</details>

### 创建和恢复会话

创建一个名为 `dev` 的会话；会话已经存在时，直接进入：

```bash
imx attach dev
```

在会话中照常运行命令。按下 **`Ctrl+\`** 可以分离当前连接，shell 和程序继续运行。重新连接时执行相同命令：

```bash
imx attach dev
```

在另一个终端中查看会话列表和保留的输出：

```bash
imx ls
imx cat dev
```

需要结束会话时执行：

```bash
imx kill dev
```

### 在提示符中显示会话名称

创建 `~/.config/imx/config.toml`，开启以下选项：

```toml
[prompt]
show_session = true
```

设置了 `XDG_CONFIG_HOME` 时，配置文件使用 `$XDG_CONFIG_HOME/imx/config.toml`。选项默认值为 `false`。

下一次执行 `imx attach dev` 时，程序自动添加以 `# BEGIN imx shell integration` 和 `# END imx shell integration` 标记的集成代码。之后启动的 Bash、Zsh 和 Fish 会在原有提示符前显示 `[dev] `，保留路径、配色和主题。首次启用时已经运行的 shell 会在重新启动后加载集成代码。普通终端继续显示原有提示符。

将 `show_session` 改为 `false`，执行 `imx attach <name>` 后，程序会移除记录的集成片段和脚本。已经加载集成代码的 shell 会在下一次显示提示符时移除前缀。初始化文件和文件管理行为见[配置说明](docs/usage.md#配置文件与会话提示符)。

### 修改创建时间的显示格式

在同一个配置文件中添加以下选项：

```toml
[list]
created_format = "%m-%d %H:%M:%S"
```

格式使用 `strftime` 语法。默认的 `%m-%d %H:%M:%S` 显示为 `MM-DD HH:mm:ss`，例如 `10-30 14:05:09`。需要显示年份时使用 `%Y-%m-%d %H:%M:%S`，仅显示日期时使用 `%Y-%m-%d`。

每次执行 `imx`、`imx ls` 或 `imx list` 都会读取当前配置，按照后台进程的本地时区显示已经记录的创建时间。修改格式后，下一次查看列表即可应用到已有会话。支持的字段和格式检查见[格式说明](docs/usage.md#created-时间格式)。

### 更新和卸载

安装最新发布版本：

```bash
imx update
```

更新命令保留当前安装目录，自动选择架构并校验 SHA256。更新系统安装文件需要管理员权限时，会提示输入 `sudo` 密码。可以在会话内部或外部执行，运行中的会话继续运行；已有后台进程继续使用启动时的版本，全部会话结束后，新建后台进程使用更新后的版本。也可以重新执行安装命令完成更新。

```bash
imx uninstall
```

卸载会终止当前用户的 imx 会话，清理当前可执行文件、安装的许可证、配置文件、shell 集成和已记录的运行文件。删除系统安装文件时会自动调用 `sudo`。工作目录中的用户文件保留。手动修改过的集成片段会保留，程序会报告对应路径并终止卸载。详细行为见[使用说明](docs/usage.md#卸载)。

## 命令

| 命令 | 功能 |
| --- | --- |
| `imx attach dev` | 创建或进入 `dev` 会话 |
| `imx list`、`imx ls`、`imx` | 查看全部会话 |
| `imx cat dev` | 输出保留的历史和当前屏幕文字 |
| `imx detach` | 在会话内部执行，分离该会话的全部连接 |
| `imx kill dev` | 终止并删除 `dev` 会话 |
| `imx update` | 在当前安装目录安装最新发布版本 |
| `imx uninstall` | 卸载当前安装并清理运行文件 |
| `imx -v` | 查看版本 |
| `imx help` | 查看帮助 |

会话列表包含 `NAME`、`PID`、`CLIENTS`、`DIRECTORY` 和 `CREATED`。终端输出根据标题和会话内容计算列宽，管道和重定向输出使用制表符分隔。`CREATED` 按后台进程的本地时区显示创建时间，默认格式为 `MM-DD HH:mm:ss`，例如 `10-30 14:05:09`。通过 `list.created_format` 修改显示格式，重新进入会话时保留原来的创建时间。

会话和历史保存在内存中，机器重启或后台进程结束后释放。会话名称规则、历史容量和多终端连接行为见[使用说明](docs/usage.md)。

## 资源占用

在 imx 0.2.0、x86_64 WSL2 Linux、默认编译模式和 80×24 终端下测量：

| 空闲会话数量 | 后台内存（PSS） | 后台进程数量 | 后台线程数量 |
| --- | --- | --- | --- |
| 1 | 1.47 MiB | 1 | 1 |
| 10 | 2.02 MiB | 1 | 1 |
| 100 | 6.38 MiB | 1 | 1 |

表中统计 imx 后台进程，shell 和会话程序单独占用内存。每种场景的 5 秒空闲采样中，后台 CPU 时间增量均为零；静态可执行文件大小约为 1.77 MiB。

测量环境、持续输出结果、容量限制和复测方法见[性能说明](docs/performance.md)。

## 源码编译

需要 **Zig 0.17.0** 和 Linux。Zig 会下载并校验 `build.zig.zon` 中固定版本的依赖。

```bash
git clone https://github.com/inwf/imx.git
cd imx
zig build
./zig-out/bin/imx attach dev
```

默认生成使用 musl 的静态可执行文件。编译模式、交叉编译、测试和 GitHub Actions 操作见[开发说明](docs/development.md)。

## 文档

| 内容 | 文档 |
| --- | --- |
| 英文介绍与快速开始 | [English README](README.md) |
| 会话行为、配置、历史、环境变量和卸载 | [使用说明](docs/usage.md) |
| 资源限制、性能测量和复测方法 | [性能说明](docs/performance.md) |
| 编译、测试、贡献和版本发布 | [开发说明](docs/development.md) |

## 许可证

imx 使用 [MIT License](LICENSE)。终端历史格式化和状态恢复参考 zmx，终端处理使用 Ghostty 的 `ghostty-vt`。版权与第三方许可证见 [NOTICE](NOTICE) 和 [licenses/](licenses/)。
