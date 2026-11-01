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
      首次使用时自动创建包含会话提示符、补全和 <code>CREATED</code> 时间格式的 TOML 文件。<a href="config.example.toml">完整配置模板</a>还说明了自定义快捷键，各项均有中英文注释。语法、选项名称和取值类型都会检查。
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

安装已经发布的指定版本，例如 `v0.8.0`：

```bash
curl -fsSL https://github.com/inwf/imx/releases/download/v0.8.0/install.sh | bash -s -- v0.8.0
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

照常运行命令。关闭终端、断开 SSH 连接或按下默认快捷键 **`Alt+\`** 会分离当前连接，shell 和其中的程序继续运行。可以通过配置文件中的 `keybindings.detach` 修改快捷键。

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

### 4. 分屏

进入会话后，按下 **Alt+D** 将当前窗格左右分屏，按下 **Alt+Shift+D** 将当前窗格上下分屏。Alt 对应 macOS 的 Option。新窗格在当前聚焦窗格的工作目录启动普通 shell，用户可以执行 `imx attach <name>` 连接其他会话。高亮边框表示当前聚焦窗格。分离快捷键只断开该窗格的会话连接，并返回其普通 shell。

使用 **Alt+方向键** 聚焦相邻窗格。**Alt+1** 至 **Alt+9** 对应窗格标题中的编号，**Alt+0** 对应编号 10。关闭窗格后其他窗格的编号保持不变。指定方向没有相邻窗格或编号不存在时保持当前焦点。普通 shell 窗格也可以通过这些快捷键聚焦；编号大于 10 时使用方向快捷键，开启鼠标模式后也可以点击聚焦。

鼠标模式默认关闭（`panes.mouse = false`）。普通 shell 中可以直接拖动建立终端本地选区，再使用终端的复制快捷键，例如 iTerm2 的 Command+C。本地选区可能跨越多个窗格。设置 `panes.mouse = true` 后启用鼠标点击聚焦、滚轮浏览窗格历史、拖动分隔线和窗格内文字选择；修改后退出整个界面并重新 attach 生效。窗格内程序主动请求的鼠标输入仍然有效；关闭鼠标模式时，只向当前聚焦窗格传递鼠标事件。在 iTerm2 中，程序使用鼠标时可以通过 Option+拖动建立本地选区。

开启鼠标模式后，按住鼠标左键拖动窗格之间的分隔边框，即可调整相邻窗格的大小。分隔边框的两侧都可以拖动，嵌套分屏同样支持。拖动过程中，窗格内的程序实时获得新的终端尺寸。每个窗格至少保留 12 列、5 行（包括边框），终端窗口缩放时保留调整后的比例。

开启鼠标模式后，在文字上拖动鼠标可以高亮选择当前窗格内的文字，松开鼠标后自动复制。双击选择单词，三击选择整行，拖动到窗格顶部或底部之外可以滚动选择历史内容。复制通过 OSC 52 完成，SSH 连接同样适用，需要本地终端支持并允许访问剪贴板。程序接管鼠标时仍然接收鼠标事件，按住 Shift 拖动可以选择文字。键盘上报模式跟随当前聚焦的程序，普通 shell 保持正常的输入法文本输入。

每个窗格都可以继续分屏。开启鼠标模式且程序没有接管鼠标时，滚轮用于查看该窗格的历史。按下 **Alt+W** 关闭当前聚焦的窗格，并终止其中连接的会话及程序；其他连接到同一会话的客户端也会断开。需要保留会话时，先按分离快捷键（默认 `Alt+\`），再按 Alt+W。关闭普通 shell 窗格时，其中的程序也会终止。在普通 shell 提示符下输入 `exit`，或者在命令行为空时按下 `Ctrl+D`，同样可以关闭窗格。最后一个窗格关闭后退出分屏界面。

关闭终端会丢弃布局并终止窗格中的普通 shell，已经连接的会话继续运行。布局只保留在当前客户端内存中，不会保存到文件。可以通过 `keybindings.split_right`、`keybindings.split_down` 和 `keybindings.close_pane` 修改快捷键。

### 5. 按需配置

执行 `imx`、`imx ls`、`imx list` 或 `imx attach <name>` 时，如果 `~/.config/imx/config.toml` 不存在，程序会自动创建包含会话名称提示、补全、`CREATED` 格式和鼠标模式设置及中英文注释的文件。设置了非空的 `XDG_CONFIG_HOME` 时，文件创建在 `$XDG_CONFIG_HOME/imx/config.toml`。已有文件保留原有内容和权限。

自动生成的配置文件包含以下默认设置：

```toml
[prompt]
show_session = true

[list]
created_format = "%m-%d %H:%M:%S"

[completion]
enabled = true

[panes]
mouse = false
```

[完整配置模板](config.example.toml)使用中英文注释说明全部选项的用途、默认值和生效时机。快捷键使用内置默认值；需要自定义时，把对应的 `[keybindings]` 配置加入自己的文件即可。模板也说明了 `alt` 对应 macOS 的 Option，`super` 对应 macOS 的 Command。

- **`prompt.show_session`**：会话中新启动的 Bash、Zsh 和 Fish 在原有提示符前显示 `[dev] `，保留提示符原来的路径、颜色和主题。下一次执行 `imx attach` 时，程序把集成代码写入 shell 初始化文件，以 `# BEGIN imx shell integration` 和 `# END imx shell integration` 标记。改为 `false` 后再次进入会话即可移除。默认值为 `true`，省略该选项时也会启用。
- **`list.created_format`**：用 `strftime` 字段设置 `CREATED` 列的格式。默认显示为 `10-30 14:05:09`，`%Y-%m-%d %H:%M:%S` 会带上年份。
- **`completion.enabled`**：开启或关闭命令和会话名称的 Tab 补全。默认值为 `true`。
- **`panes.mouse`**：开启 imx 的鼠标聚焦、拖动分隔线、滚轮浏览历史和窗格内文字选择。默认值为 `false`，省略时也关闭；普通 shell 中的选择和复制交给终端处理。修改后重新启动整个界面生效。
- **`panes.focused_border_color`**：使用 `"#RRGGBB"` 字符串设置聚焦窗格的边框和标题颜色，例如 `"#33AAFF"`；省略时使用终端默认青色。会话窗格和普通 shell 窗格均适用，修改后重新启动整个界面生效。
- **`keybindings.split_right`**、**`keybindings.split_down`**：分别将当前窗格左右分屏、上下分屏，默认使用 Alt+D、Alt+Shift+D；`alt` 对应 macOS 的 Option。新窗格在当前目录启动普通 shell。退出整个界面并重新进入后，快捷键的修改生效。重复的快捷键会报告配置错误。
- **`keybindings.close_pane`**：关闭当前聚焦的窗格，并终止其中连接的会话及程序，默认使用 Alt+W。需要保留会话时先 detach。退出整个界面并重新进入后，关闭快捷键的修改生效。
- **`keybindings.focus_left`**、**`focus_right`**、**`focus_up`**、**`focus_down`**：默认使用 Alt+方向键聚焦相邻窗格。**`keybindings.focus_1`** 至 **`focus_10`**：默认使用 Alt+1 至 Alt+9 和 Alt+0 聚焦对应编号的窗格。修改后重新启动整个界面生效。
- **`keybindings.detach`**：设置分离当前连接的快捷键。例如，`{ key = 'x', ctrl = true }` 表示 `Ctrl+x`，`{ key = 'F12' }` 表示 F12。`key` 接受单个字符或支持的按键名称；`ctrl`、`alt`、`shift`、`super` 使用布尔值，在显式配置的快捷键中默认为 `false`。ASCII 字母名称不区分大小写，需要 Shift 时设置 `shift = true`。修改后重新连接生效，同一连接切换会话时保留当前设置。支持的按键名称及终端编码行为见[快捷键配置](docs/usage.md#快捷键配置)。

语法错误、未知选项和取值类型错误会在进入会话或查看列表时报告。错误信息包含配置文件路径；选项错误还会说明完整配置项名称及其要求。初始化文件的位置和修改方式见使用说明的[配置部分](docs/usage.md#配置文件与会话提示符)。

## 工作方式

`imx` 命令通过私有运行目录中各个会话的 Unix socket 与对应后台进程通信。每个后台持有所属会话的 PTY，并使用 Ghostty 的 `ghostty-vt` 库维护实时的终端状态，包括屏幕内容、颜色和历史。重新连接时把这份状态恢复到终端，`imx cat` 则把同一份状态转换为纯文本。

交互客户端为每个窗格管理一个 PTY 和一份终端状态。libvaxis 绘制窗格及其边框，Ghostty 按照各个窗格启用的终端模式编码键盘和鼠标输入。窗格布局和普通 shell 随该客户端结束，会话后台各自保持独立的生命周期。

| 命令                        | 功能                                     |
| --------------------------- | ---------------------------------------- |
| `imx attach dev`            | 创建或进入 `dev`；在会话内部执行时，将当前终端切换到 `dev` |
| `imx list`、`imx ls`、`imx` | 查看全部会话                             |
| `imx cat dev`               | 输出保留的历史和当前屏幕文字             |
| `imx detach`                | 在会话内部执行，分离该会话的全部连接     |
| `imx kill dev`              | 终止会话，包括 shell、前台作业和后台作业 |
| `imx update`                | 检查并在当前安装目录安装更新的发布版本   |
| `imx uninstall`             | 终止当前用户的会话并卸载                 |
| `imx -v`、`imx --version`    | 查看版本                                 |
| `imx help`、`imx --help`     | 查看帮助，也支持 `imx -h`                 |

每个命令都支持 `-h` 和 `--help`，例如 `imx attach --help`、`imx update --help`；`imx help attach` 显示相同的命令帮助。帮助和版本查询可以在非交互环境使用，并且不会读取配置或启动会话。以连字符开头的会话名称需要放在 `--` 后面，例如 `imx attach -- -dash`、`imx cat -- -dash` 和 `imx kill -- -dash`。Tab 补全支持帮助、版本选项以及 `--` 后面的会话名称。

会话的生命周期：

1. **进入。** 使用 `imx attach dev` 创建 `dev` 时，启动该会话的后台进程，并使用当前工作目录、环境变量和 `$SHELL` 运行 shell。进入已有会话时保留其状态。
2. **分离。** 关闭终端、连接断开、按下配置的快捷键（默认 `Alt+\`），或在会话内部执行 `imx detach`，会话都继续运行。
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
| 会话输出队列 | 每个队列最多 256 KiB；落后的连接会断开，会话继续运行     |
| 分屏绘制队列 | 最多 16 MiB，用于容纳完整屏幕更新；发送完成后继续绘制    |

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
imx update --check
imx update --force
imx uninstall
```

`imx update` 检查最新发布版本，有更新时执行安装。版本相同时显示 `Already up to date`；本地版本更新时保留现有安装。`imx update --check` 只报告检查结果，不下载软件包、不创建配置和运行文件，也不请求管理员权限。检查成功返回状态码 0，包括发现可用更新的情况。`imx update --force` 强制安装最新发布版本，本地版本相同或更新时也会执行。`--check` 和 `--force` 不能同时使用。

安装使用当前安装前缀，自动选择架构并校验 SHA256，并固定使用版本检查得到的发布标签。可以在会话内部或外部执行更新。已有后台继续使用启动时的版本，保留程序和历史；新建的独立后台使用更新后的可执行文件。

从 v0.4.1 升级时，已有共享后台继续管理所在运行目录，直到其中的全部会话结束，后续创建的会话使用独立后台。过渡行为见[更新说明](docs/usage.md#更新)，客户端和后台的版本要求见[切换会话](docs/usage.md#切换会话)。

`imx uninstall` 终止当前用户的全部 imx 会话，删除可执行文件、安装的许可证和补全文件、配置文件、记录中的 shell 集成以及记录过的运行文件。工作目录中的用户文件保留。

<details>
<summary><strong>更新和卸载涉及的内容</strong></summary>


- 更新保留当前安装前缀，系统目录、自定义 `IMX_PREFIX` 和通过符号链接运行的安装都可以识别。下载失败、校验不一致或取消 `sudo` 授权时，安装和全部会话保持原状。
- 卸载使用 Linux session ID 和 pidfd 终止会话，随后清理 socket、锁文件、许可证和补全文件、配置文件、记录中写入 shell 初始化文件的集成片段，以及记录过的全部运行目录。通过符号链接运行时，实际可执行文件和调用使用的链接一并删除。手动修改过的集成片段会让卸载停止，并报告对应路径。
- 两个命令只处理当前用户。其他用户的会话和运行文件不受影响；系统安装的可执行文件、许可证和补全文件为共享文件。

</details>

## 资源占用

2026-11-01 在 x86_64 WSL2 Linux 上，使用支持独立会话后台及分屏的开发版本、默认编译模式和 80×24 终端测量：

| 空闲会话数量 | 后台内存（PSS） | 后台进程数量 | 后台线程数量 |
| ------------ | --------------- | ------------ | ------------ |
| 1            | 2.26 MiB        | 1            | 1            |
| 10           | 4.86 MiB        | 10           | 10           |
| 100          | 30.96 MiB       | 100          | 100          |

表中合计全部 imx 后台进程，shell 和会话程序单独占用内存。此次测量中，单个窗格的管理进程与连接进程合计约占 2.19 MiB PSS；100×30 终端中的两个窗格分别连接不同会话时，三个客户端进程合计约占 4.07 MiB。静态可执行文件约为 2.67 MiB。生成并处理 500,000 行输出（约 3.89 MB）耗时约 0.55 秒，占用后台 CPU 时间约 0.24 秒。上表各场景的 5 秒空闲采样中，后台 CPU 时间增量均为零；两个窗格的客户端空闲采样也没有记录到 CPU 时间增加。

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
- [zig-clap](https://github.com/Hejsil/zig-clap)：解析命令行参数，MIT 许可证。

版权声明和全部第三方许可证见 [NOTICE](NOTICE) 和 [licenses/](licenses/)，其中包括 `ghostty-vt` 附带的库。

<p align="center"><sub>如果 imx 让你的会话持续运行，欢迎在 <a href="https://github.com/inwf/imx">GitHub</a> 上点亮 Star，让更多人发现它。</sub></p>
