# 使用说明

## 帮助与参数

`imx help`、`imx -h` 和 `imx --help` 显示总体帮助；`imx -v` 和 `imx --version` 显示版本。每个命令支持 `-h`、`--help`，例如 `imx attach --help`；也可以使用 `imx help attach` 查看该命令的帮助。

帮助和版本查询支持非交互环境，并在读取配置及执行操作之前处理。未知命令、未知选项、缺少名称和多余参数会报告具体错误及帮助入口。

## 会话生命周期

`imx attach dev` 创建或进入 `dev` 会话。新会话使用创建时的工作目录、环境变量和 `$SHELL`；未设置 `$SHELL` 时使用 `/bin/sh`。进入会话需要交互式终端。

关闭终端、断开 SSH 连接或按下配置的快捷键（默认 `Ctrl+\`）会分离当前连接。会话中的 shell 和程序继续运行，重新执行 `imx attach dev` 会恢复屏幕和保留的历史。

在会话内部执行 `imx detach` 会分离该会话的全部连接。退出会话中的 shell 会结束会话。`imx kill dev` 会终止并删除指定会话。

每个会话在创建时启动独立的后台进程，内部使用一个事件循环线程，拥有该会话的 PTY、程序、屏幕、历史和连接。会话及其连接结束后，对应后台退出。会话和历史保存在内存中，后台退出会释放所属会话，机器重启会释放全部会话。某个后台暂停、崩溃或持续处理大量输出时，其他后台可以独立响应。

会话名称允许 1–64 个 ASCII 字母、数字、句点、下划线和连字符。`.` 和 `..` 为保留名称。以连字符开头的名称需要放在参数分隔符 `--` 后面，例如 `imx attach -- -dash`、`imx cat -- -dash` 和 `imx kill -- -dash`。

## 分屏与窗格

进入 `imx attach <name>` 后，Command+D 将当前窗格左右分屏，Command+Shift+D 将当前窗格上下分屏。新窗格使用当前聚焦窗格的实际工作目录启动普通 shell，用户可以手动执行 `imx attach <name>` 进入需要的会话。每个窗格都可以继续拆分。

鼠标点击窗格切换输入焦点，高亮边框表示当前聚焦的窗格。各个窗格独立处理屏幕、全屏程序、输入协议和历史。程序启用鼠标时，点击坐标转换为窗格内部坐标后传给程序；程序没有接管鼠标时，滚轮浏览窗格历史。

分离快捷键（默认 Ctrl+\\）只分离当前聚焦窗格的连接，随后回到该窗格的普通 shell。其他窗格保持连接，即使它们连接同一个会话。会话中的 shell 退出后，所在窗格返回普通 shell；普通 shell 退出后关闭窗格，剩余窗格重新分配空间。最后一个窗格关闭后退出整个界面。

分屏布局只存在于当前客户端内存中。关闭终端或者断开 SSH 连接会释放布局，并终止窗格中的普通 shell 及其作业，已经进入的会话继续在各自后台运行。重新连接时自行分屏和 attach。窗口缩小时保留全部窗格，空间不足时显示聚焦窗格所在区域；重新扩大窗口后恢复完整布局。新分屏需要每个窗格至少 12 列、5 行（包括边框）。

```toml
[keybindings]
# 在当前窗格右侧创建新窗格。
# Create a new pane to the right of the focused pane.
split_right = { key = 'd', super = true }
# 在当前窗格下方创建新窗格。
# Create a new pane below the focused pane.
split_down = { key = 'd', super = true, shift = true }
```

`super` 对应 macOS 的 Command。快捷键需要由本地终端发送给 imx，可以通过配置文件换用其他组合。分屏快捷键在启动整个界面时读取，修改后退出界面并重新 attach 生效。

## 切换会话

在 `dev1` 会话内部执行以下命令，当前终端会切换到 `dev2`：

```bash
imx attach dev2
```

`dev2` 已经存在时恢复其屏幕、历史和程序状态；尚未存在时，使用执行命令时的工作目录、环境变量和 `$SHELL` 创建。`dev1` 的 shell、程序、环境变量和历史继续保留。在 `dev2` 中执行 `imx attach dev1` 可以返回。目标名称与当前会话相同时，命令直接成功返回。

多个终端连接同一会话时，切换最近发送输入的终端，其他终端继续连接原会话。目标会话使用切换终端的实际尺寸。切换完成后，配置的快捷键分离当前终端，`imx detach` 分离目标会话的全部连接。

目标名称无效、目标后台连接超时或者新会话的 shell 启动失败时，命令报告错误，当前终端继续连接原会话。切换命令需要在所属会话的 Linux session 内运行。

会话切换需要客户端和原会话后台均支持此功能。旧后台会报告 `SwitchUnsupportedByBackend`，旧客户端会报告 `SwitchUnsupportedByClient`。更新可执行文件后，重新连接会使用新客户端；后台使用启动时的版本，结束会话后重新创建会启动新后台。

## 会话列表

`imx ls`、`imx list` 和 `imx` 查看全部会话，按会话名称排序。列表包含 `NAME`、`PID`、`CLIENTS`、`DIRECTORY`、`CREATED` 和 `STATUS`。终端输出根据标题和所有会话内容计算列宽，列间保留两个空格；管道和重定向输出使用制表符分隔。

列表并发查询独立后台，共享一秒查询期限。正常响应显示 `running`，超过期限显示 `unresponsive`，请求错误显示 `error:<错误名称>`；无法获取的字段显示 `-`。已退出后台留下的 socket 不会作为存活会话显示。客户端连接后台及等待响应采用两秒超时，超时报错会保留后台及其会话。

`DIRECTORY` 在每次查询时从 `/proc/<PID>/cwd` 读取会话 shell 的当前实际目录，随 `cd` 和目录重命名更新，并解析符号链接。重新连接保留 shell 当前目录；前台子程序拥有独立目录时，该列继续表示会话 shell 的目录。shell 通过 `exec` 替换为其他程序后，该列跟随相同 PID 的程序。目录被删除后，显示 Linux 提供的 ` (deleted)` 后缀。

目录中的换行、制表符、控制字符、无效 UTF-8 字节、双引号和反斜线采用转义形式，例如 `\n`、`\t`、`\x1b` 和 `\\`，保持终端与制表符分隔输出的结构。普通中文和空格直接显示。会话在查询期间退出时会从结果中移除；读取目录的其他错误会通过该会话的 `STATUS` 显示。

`CREATED` 按后台进程的本地时区显示会话创建时间，默认格式为 `MM-DD HH:mm:ss`，例如 `10-30 14:05:09`。时间在创建会话时记录，分离和重新连接保持该时间；显示格式由 `list.created_format` 控制。

## 配置文件与会话提示符

配置文件使用 `$XDG_CONFIG_HOME/imx/config.toml`；`XDG_CONFIG_HOME` 未设置或为空时，使用 `$HOME/.config/imx/config.toml`。路径需要为绝对路径。

执行 `imx`、`imx ls`、`imx list` 或 `imx attach <name>` 时，如果配置文件不存在，程序会自动创建包含以下默认选项和中英文注释的文件。新建目录使用 `0700` 权限，配置文件使用 `0600` 权限，并遵循当前用户的 umask。已有文件保留原有内容和权限；并发首次运行时，完整写入后才公开配置文件。创建或读取失败会立即报告错误。

`imx help`、`imx -v` 和 Tab 补全查询保持只读。配置文件由执行命令的用户创建，系统安装后的各个用户分别管理自己的配置。

配置错误包含实际文件路径。选项校验还会显示完整名称及要求，例如 `keybindings.detach.ctrl: expected a boolean (true or false)`。TOML 语法错误使用解析库提供的具体原因，文件读取和创建错误也会显示对应路径。

```toml
[prompt]
show_session = true

[list]
created_format = "%m-%d %H:%M:%S"

[completion]
enabled = true

[keybindings]
detach = { key = '\', ctrl = true }
split_right = { key = 'd', super = true }
split_down = { key = 'd', super = true, shift = true }
```

### 快捷键配置

`keybindings.detach` 设置分离当前连接的快捷键，默认是 `Ctrl+\`。省略该选项时使用默认值。例如，改为 `Ctrl+x`：

```toml
[keybindings]
detach = { key = 'x', ctrl = true }
```

`key` 为必填字符串，可以使用单个 Unicode 字符，或者 `Enter`、`Tab`、`Escape`、`Space`、`Backspace`、`Insert`、`Delete`、`Left`、`Right`、`Up`、`Down`、`Page_Up`、`Page_Down`、`Home`、`End`、`F1` 至 `F12`。ASCII 字母和按键名称不区分大小写。`ctrl`、`alt`、`shift`、`super` 为可选布尔值，在显式配置的快捷键中默认为 `false`；需要 Shift 时设置 `shift = true`。例如，`{ key = 'x', ctrl = true, shift = true }` 表示 `Ctrl+Shift+x`，`{ key = 'F12' }` 表示 F12。

分离快捷键由客户端在建立连接时读取。修改后分离并重新连接即可生效，会话中的程序继续运行。同一连接切换会话时保留当前快捷键设置；同时连接的其他客户端继续使用各自建立连接时读取的设置。分屏快捷键在启动整个界面时读取，修改后退出界面并重新进入生效。已有配置文件可以手动添加 `[keybindings]` 部分。

快捷键支持普通终端、Kitty 键盘协议和 xterm 的 modifyOtherKeys 编码。终端需要能够发送所配置组合的编码；某些普通终端无法区分 `Ctrl+Shift+x` 与 `Ctrl+x`，此类组合需要扩展键盘协议。普通编码中的 `Ctrl+i` 与 Tab、`Ctrl+m` 与 Enter、`Ctrl+h` 与部分终端的 Backspace 共用字节，因此配置其中一个组合时，共用编码也会触发。单独的 Escape 等待 100 毫秒，以便识别以 Escape 开头的组合键。

粘贴内容保留原有文字，并按照目标程序是否启用括号粘贴模式发送边界标记。分屏界面根据目标窗格的终端模式编码未绑定的键盘事件；程序启用按键释放报告时同步传递释放事件。未知选项、无效按键名称、缺少 `key`、类型错误或重复绑定会在进入会话或查看列表时报告。

### CREATED 时间格式

`list.created_format` 使用 `strftime` 语法，默认值为 `%m-%d %H:%M:%S`。每次执行 `imx`、`imx ls` 或 `imx list` 都会读取配置，按照后台进程的本地时区格式化已经保存的创建时间。修改配置后，已有会话会在下一次查看列表时使用新格式；删除该选项会恢复默认格式。

| 字段 | 显示内容 |
| --- | --- |
| `%Y` | 四位年份 |
| `%y` | 年份的最后两位数字 |
| `%m` | 月份，01–12 |
| `%d` | 日期，01–31 |
| `%H` | 小时，00–23 |
| `%M` | 分钟，00–59 |
| `%S` | 秒数 |
| `%F` | 日期，相当于 `%Y-%m-%d` |
| `%T` | 时间，相当于 `%H:%M:%S` |
| `%z` | 数字形式的时区偏移 |
| `%Z` | 时区名称 |
| `%%` | 百分号 |

例如，`%Y-%m-%d %H:%M:%S` 显示完整日期和时间，`%Y-%m-%d` 仅显示日期，`%m/%d %H:%M` 显示月份、日期、小时和分钟。

格式需要为非空字符串，最多 256 字节；显示结果最多 1023 字节。未知字段、换行、制表符等控制字符，以及超出长度限制的格式会报告 `InvalidCreatedFormat`。配置类型错误会报告 `ListCreatedFormatMustBeString`。

支持该配置的后台进程可以即时应用格式。使用自定义格式时，由旧版本启动的后台进程会报告 `CreatedFormatUnsupportedByBackend`；全部会话结束后，重新创建会话会启动当前安装的版本。

### 会话提示符

`prompt.show_session` 默认为 `true`，省略该选项时也会启用。在执行 `imx attach <name>` 时安装 shell 集成。之后启动的 Bash、Zsh 和 Fish 会在原有提示符前显示 `[会话名称] `，保留原有路径、颜色和主题。首次启用时已经运行的 shell 需要重新启动，才能加载新加入的初始化代码。

| Shell | 集成位置 |
| --- | --- |
| Bash | `$HOME/.bashrc`，以及按照 `.bash_profile`、`.bash_login`、`.profile` 顺序选择的首个可读登录文件；这些登录文件均不存在时创建 `.bash_profile` |
| Zsh | 继承的 `$ZDOTDIR` 目录中的 `.zshrc` 和 `.zlogin`；未设置 `ZDOTDIR` 时使用 `$HOME` |
| Fish | `$XDG_CONFIG_HOME/fish/config.fish`；未设置 `XDG_CONFIG_HOME` 或为空时使用 `$HOME/.config/fish/config.fish` |

每个初始化文件中的集成片段使用通用的 `# BEGIN imx shell integration` 和 `# END imx shell integration` 注释。集成脚本和修改记录保存在 `$HOME/.local/state/imx/shell/`。多次进入会话会复用已有片段，普通终端保持原有提示符。Bash 支持字符串和数组形式的 `PROMPT_COMMAND`；Zsh 使用 `precmd_functions`；Fish 包装已有的 `fish_prompt`。

将 `show_session` 改为 `false`，再执行 `imx attach <name>`，程序会移除记录中的完整片段和集成脚本，并删除由 imx 创建且已经为空的初始化文件和目录。已经加载集成的 shell 会在下一次显示提示符时移除会话名称。删除该选项会恢复默认启用状态。

初始化文件按照原有符号链接修改实际目标，使用同一目录内的原子替换，保留所有者、权限和扩展属性。文件锁、内容与文件身份检查用于处理并发修改。配置语法、选项名称和类型错误会在 `imx attach` 或查看列表时报告；开启选项时，其他 shell 会报告 `UnsupportedPromptShell`。

手动修改过的集成片段或脚本会保留，关闭选项或卸载会报告对应路径并终止操作。修改记录用于识别程序添加的内容，初始化文件中的其他用户内容会保留。

## Tab 补全

安装脚本和源码编译都会提供 Bash、Zsh 和 Fish 补全文件。输入 `imx a` 后按下 Tab，可以补全为 `imx attach `。随后按下 Tab，有多个会话时会显示会话列表；输入名称前缀后再次按下 Tab，唯一匹配时会补全完整名称。只有一个候选时会直接补全，多个候选共享的名称前缀由 shell 补全。

`attach`、`cat` 和 `kill` 的首个参数支持会话名称补全。每次补全都并发查询当前用户所选运行目录中的独立后台，共享 250 毫秒查询期限。新增和删除会话会即时反映到候选中，无响应后台的会话名称仍然保留。候选按会话名称排序，名称查询独立于 `CREATED` 的显示格式。

帮助和版本选项也支持补全，例如 `imx --ver`、`imx attach --he`。`imx help at` 可以补全命令名称；`imx attach -- -d` 可以补全以连字符开头的会话名称。

`completion.enabled` 默认为 `true`。设置为 `false` 后，下一次按下 Tab 即可停止提供命令和会话候选；设置为 `true` 或删除该选项即可重新开启。

| Shell | 安装前缀下的目录 | 加载条件 |
| --- | --- | --- |
| Bash | `share/bash-completion/completions/imx` | Bash 4.4 或更新版本，安装并启用 `bash-completion` |
| Zsh | `share/zsh/site-functions/_imx`、`share/zsh/vendor-completions/_imx` | 初始化 `compinit`，并通过 `fpath` 搜索补全目录 |
| Fish | `share/fish/vendor_completions.d/imx.fish` | 通过标准补全目录自动加载 |

系统安装会同时提供 `/usr/local/share/fish/vendor_completions.d/imx.fish` 和 `/usr/share/fish/vendor_completions.d/imx.fish`，覆盖 Fish 的两种默认安装位置。卸载会同步清理这两个文件。

默认系统安装使用 `/usr/local`，仅包含 `/usr/bin` 的环境使用 `/usr`。安装完成后启动新的 shell。Bash 和 Zsh 的补全机制由 shell 环境初始化。例如，Ubuntu 和 Debian 的 Bash 可以在当前 shell 中执行：

```bash
source /usr/share/bash-completion/bash_completion
```

Zsh 可以执行：

```zsh
autoload -Uz compinit
compinit
```

使用 `IMX_PREFIX` 自定义安装前缀时，命令目录需要在 `PATH` 中。Bash 和 Fish 通过 `XDG_DATA_DIRS` 搜索该前缀的 `share/`，Zsh 通过 `fpath` 搜索其中的 `share/zsh/site-functions/`。例如，安装到 `$HOME/apps/imx` 时，Bash 使用：

```bash
export PATH="$HOME/apps/imx/bin:$PATH"
export XDG_DATA_DIRS="$HOME/apps/imx/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
source /usr/share/bash-completion/bash_completion
```

Zsh 在初始化 `compinit` 前添加搜索目录：

```zsh
fpath=("$HOME/apps/imx/share/zsh/site-functions" $fpath)
autoload -Uz compinit
compinit
autoload -Uz "$HOME/apps/imx/share/zsh/site-functions/_imx"
```

Fish 可以在启动新的 shell 前设置：

```fish
set -gx PATH "$HOME/apps/imx/bin" $PATH
set -gx XDG_DATA_DIRS "$HOME/apps/imx/share:/usr/local/share:/usr/share"
```

旧版本启动的后台进程不支持名称查询时，会报告 `CompletionUnsupportedByBackend`。全部会话结束后，重新创建会话会启动当前安装的版本。

## 多个终端连接

多个终端可以同时连接同一个会话，全部连接共享输入和输出。

最近进入会话的连接决定终端大小。该连接分离后，由剩余的第一个连接决定终端大小。终端尺寸支持最多 512 列、256 行。

慢速连接超过输出队列容量时会断开，会话继续运行。

## 历史输出

```bash
imx cat dev
```

`cat` 输出保留的历史和当前屏幕文字，使用 `ghostty-vt` 的纯文本格式化器处理颜色、光标移动和文字覆盖。Vim 等使用备用屏幕的程序运行期间，`cat` 输出其当前屏幕。

历史使用 10,000 行目标及 2 MiB 的容量限制，按完整终端页面修剪。实际保留行数受页面大小和终端宽度影响；当前屏幕及终端状态另行占用内存。会话结束后释放历史。

## 环境变量

| 变量 | 用途 |
| --- | --- |
| `HOME` | 需要为绝对路径；保存运行目录记录，并提供默认运行目录 |
| `SHELL` | 创建新会话时运行的 shell；未设置时使用 `/bin/sh` |
| `IMX_SESSION` | imx 在会话内部设置的会话名称，供会话切换和 `detach` 等命令使用 |
| `IMX_DIR` | 指定绝对路径的运行目录，优先于 `XDG_RUNTIME_DIR` |
| `XDG_RUNTIME_DIR` | 未设置 `IMX_DIR` 时，使用该目录下的 `imx/` |
| `XDG_CONFIG_HOME` | 指定 imx 配置目录，并遵循 Fish 的初始化目录设置 |
| `XDG_DATA_DIRS` | Bash 和 Fish 搜索安装前缀下的补全文件 |
| `ZDOTDIR` | shell 为 Zsh 时，使用继承的绝对路径选择初始化文件 |

安装脚本另支持 `IMX_PREFIX` 指定安装前缀。默认优先选择当前 `PATH` 中的 `/usr/local/bin`，安装前缀为 `/usr/local`；仅包含 `/usr/bin` 的环境使用 `/usr`。下载和解压目录位于 `${XDG_CACHE_HOME:-$HOME/.cache}`，安装结束后清理。写入系统目录时自动调用 `sudo`。

## 运行文件

运行目录按以下顺序选择：

1. `$IMX_DIR`。
2. `$XDG_RUNTIME_DIR/imx`。
3. `$HOME/.local/state/imx/run`。

运行目录需要属于当前用户，权限为 `0700`。Unix socket 使用 `SO_PEERCRED` 检查连接用户。每个会话拥有 `session-<name>.sock`、`session-<name>.lock` 和 `session-<name>.log`，日志记录对应后台的错误。相同名称的并发创建请求通过对应启动锁合并到同一个后台。正常退出时删除 socket，启动锁和日志保留至卸载；异常退出遗留的 socket 会在重新创建该名称的会话时清理。

`$HOME/.local/state/imx/paths/` 记录使用过的运行目录。状态目录中的 `lifecycle.lock`、运行目录中的启动锁和可执行文件上的锁负责同步启动与卸载。

## 终止会话

```bash
imx kill dev
```

`kill` 使用 Linux session ID 和 pidfd 终止会话所属的 shell、前台作业和后台作业。程序主动通过 `setsid()` 创建独立 Linux session 后，具有独立的生命周期。

## 更新

```bash
imx update
imx update --check
imx update --force
```

`update` 按语义版本检查 GitHub Release 中最新发布的版本，有更新时执行安装。版本相同时显示 `Already up to date`；本地版本更新时保留现有安装。`--check` 只显示检查结果，不下载软件包、不创建配置、缓存或运行目录，也不请求管理员权限；检查成功返回状态码 0，包括发现可用更新的情况。`--force` 强制安装最新发布版本，本地版本相同或更新时也执行。两个选项不能同时使用，Bash、Zsh 和 Fish 支持补全这些选项。

更新使用当前可执行文件的实际安装前缀，支持系统目录、自定义前缀和通过符号链接运行的 `bin/imx`。程序复用安装脚本，固定使用版本检查得到的发布标签，自动选择架构、校验 SHA256，并在需要管理员权限时调用 `sudo`。

安装和更新都会以英文显示获取版本、下载、校验、解压和安装状态。软件包下载由 curl 显示实际进度；标准错误输出连接终端时显示进度条，重定向到日志或管道时使用普通状态文字。通过 `curl ... | bash` 安装时，标准输入使用管道也能显示进度条。需要管理员权限时，程序会先提示，再运行 `sudo`。

可以在会话内部或外部执行更新。运行中的 shell、程序和历史继续保留；已有后台进程继续使用启动时的版本，新建后台进程使用更新后的版本。下载或校验失败，以及取消 sudo 授权时，原可执行文件和会话保持原状。下载和解压目录在更新结束后清理。

从 v0.4.1 升级时，客户端继续连接运行目录中的 `server.sock`，保留已有共享后台的会话、历史和操作方式。该后台内的全部会话结束后，后续创建会话使用独立后台、当前目录显示、新的列表状态和查询期限。升级过渡期间，相关错误仍记录在 `server.log`。

## 卸载

```bash
imx uninstall
```

卸载会终止当前用户在已记录运行目录中的全部 imx 会话和后台进程，删除 socket、启动锁、日志、目录记录、当前可执行文件、安装的许可证和补全文件、imx 配置文件及记录中的 shell 集成，并清理属于当前用户的空目录。当前默认目录、`XDG_RUNTIME_DIR` 和 `IMX_DIR` 对应的运行文件也会清理。

通过符号链接运行时，卸载会删除实际可执行文件、调用使用的链接，以及 `PATH` 中指向该文件的 `imx` 链接。安装到 `bin/imx` 时，许可证和补全文件从同一安装前缀清理；独立复制的可执行文件也支持卸载。

卸载会检查文件身份和删除权限。普通用户删除系统安装文件时会自动调用 `sudo`，根据系统设置提示输入密码；取消授权会终止卸载，会话继续运行。会话和运行文件按执行命令的当前用户清理，其他用户的运行文件由各用户管理。系统安装的可执行文件和许可证为共享文件。

启动锁阻止并发连接重新创建运行文件。会话内部执行卸载时，独立清理进程会在会话关闭后继续完成运行文件删除。系统的共享目录保留。

工作目录中的用户文件，以及运行目录、配置目录、许可证目录和补全目录中的额外用户文件保留。shell 初始化文件保留原有用户内容；手动修改过的 imx 集成片段或脚本会在删除安装文件之前报告，并终止卸载。
