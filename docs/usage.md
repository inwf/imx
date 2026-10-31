# 使用说明

## 会话生命周期

`imx attach dev` 创建或进入 `dev` 会话。新会话使用创建时的工作目录、环境变量和 `$SHELL`；未设置 `$SHELL` 时使用 `/bin/sh`。进入会话需要交互式终端。

关闭终端、断开 SSH 连接或按下 `Ctrl+\` 会分离当前连接。会话中的 shell 和程序继续运行，重新执行 `imx attach dev` 会恢复屏幕和保留的历史。

在会话内部执行 `imx detach` 会分离该会话的全部连接。退出会话中的 shell 会结束会话。`imx kill dev` 会终止并删除指定会话。

后台进程在首次创建会话时自动启动，全部会话及连接结束后退出。会话和历史保存在内存中，机器重启或后台进程结束后释放。

会话名称允许 1–64 个 ASCII 字母、数字、句点、下划线和连字符。`.` 和 `..` 为保留名称。嵌套会话会报告错误。

## 会话列表

`imx ls`、`imx list` 和 `imx` 查看全部会话，按会话名称排序。列表包含 `NAME`、`PID`、`CLIENTS`、`DIRECTORY` 和 `CREATED`。终端输出根据标题和所有会话内容计算列宽，列间保留两个空格；管道和重定向输出使用制表符分隔。

`CREATED` 按后台进程的本地时区显示会话创建时间，默认格式为 `MM-DD HH:mm:ss`，例如 `10-30 14:05:09`。时间在创建会话时记录，分离和重新连接保持该时间；显示格式由 `list.created_format` 控制。

## 配置文件与会话提示符

配置文件使用 `$XDG_CONFIG_HOME/imx/config.toml`；`XDG_CONFIG_HOME` 未设置或为空时，使用 `$HOME/.config/imx/config.toml`。路径需要为绝对路径。

```toml
[prompt]
show_session = true

[list]
created_format = "%m-%d %H:%M:%S"

[completion]
enabled = true
```

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

`prompt.show_session` 默认为 `false`。开启后，在下一次执行 `imx attach <name>` 时安装 shell 集成。之后启动的 Bash、Zsh 和 Fish 会在原有提示符前显示 `[会话名称] `，保留原有路径、颜色和主题。首次启用时已经运行的 shell 需要重新启动，才能加载新加入的初始化代码。

| Shell | 集成位置 |
| --- | --- |
| Bash | `$HOME/.bashrc`，以及按照 `.bash_profile`、`.bash_login`、`.profile` 顺序选择的首个可读登录文件；这些登录文件均不存在时创建 `.bash_profile` |
| Zsh | 继承的 `$ZDOTDIR` 目录中的 `.zshrc` 和 `.zlogin`；未设置 `ZDOTDIR` 时使用 `$HOME` |
| Fish | `$XDG_CONFIG_HOME/fish/config.fish`；未设置 `XDG_CONFIG_HOME` 或为空时使用 `$HOME/.config/fish/config.fish` |

每个初始化文件中的集成片段使用通用的 `# BEGIN imx shell integration` 和 `# END imx shell integration` 注释。集成脚本和修改记录保存在 `$HOME/.local/state/imx/shell/`。多次进入会话会复用已有片段，普通终端保持原有提示符。Bash 支持字符串和数组形式的 `PROMPT_COMMAND`；Zsh 使用 `precmd_functions`；Fish 包装已有的 `fish_prompt`。

将 `show_session` 改为 `false`，或者删除配置中的该选项，再执行 `imx attach <name>`，程序会移除记录中的完整片段和集成脚本，并删除由 imx 创建且已经为空的初始化文件和目录。已经加载集成的 shell 会在下一次显示提示符时移除会话名称。

初始化文件按照原有符号链接修改实际目标，使用同一目录内的原子替换，保留所有者、权限和扩展属性。文件锁、内容与文件身份检查用于处理并发修改。配置语法、选项名称和类型错误会在 `imx attach` 或查看列表时报告；开启选项时，其他 shell 会报告 `UnsupportedPromptShell`。

手动修改过的集成片段或脚本会保留，关闭选项或卸载会报告对应路径并终止操作。修改记录用于识别程序添加的内容，初始化文件中的其他用户内容会保留。

## Tab 补全

安装脚本和源码编译都会提供 Bash、Zsh 和 Fish 补全文件。输入 `imx a` 后按下 Tab，可以补全为 `imx attach `。随后按下 Tab，有多个会话时会显示会话列表；输入名称前缀后再次按下 Tab，唯一匹配时会补全完整名称。只有一个候选时会直接补全，多个候选共享的名称前缀由 shell 补全。

`attach`、`cat` 和 `kill` 的首个参数支持会话名称补全。每次补全都查询当前用户所选运行目录中的后台进程，新增和删除会话会即时反映到候选中。候选按会话名称排序，名称查询独立于 `CREATED` 的显示格式。

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
| `IMX_SESSION` | imx 在会话内部设置的会话名称，供 `detach` 等命令使用 |
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

运行目录需要属于当前用户，权限为 `0700`。Unix socket 使用 `SO_PEERCRED` 检查连接用户。`server.log` 记录后台进程的错误。

`$HOME/.local/state/imx/paths/` 记录使用过的运行目录。状态目录中的 `lifecycle.lock`、运行目录中的启动锁和可执行文件上的锁负责同步启动与卸载。

## 终止会话

```bash
imx kill dev
```

`kill` 使用 Linux session ID 和 pidfd 终止会话所属的 shell、前台作业和后台作业。程序主动通过 `setsid()` 创建独立 Linux session 后，具有独立的生命周期。

## 更新

```bash
imx update
```

`update` 下载并安装 GitHub Release 中最新发布的版本。更新使用当前可执行文件的实际安装前缀，支持系统目录、自定义前缀和通过符号链接运行的 `bin/imx`。程序复用安装脚本，自动选择架构、校验 SHA256，并在需要管理员权限时调用 `sudo`。

可以在会话内部或外部执行更新。运行中的 shell、程序和历史继续保留；已有后台进程继续使用启动时的版本，全部会话结束后，新建后台进程使用更新后的版本。下载或校验失败，以及取消 sudo 授权时，原可执行文件和会话保持原状。下载和解压目录在更新结束后清理。

## 卸载

```bash
imx uninstall
```

卸载会终止当前用户在已记录运行目录中的全部 imx 会话和后台进程，删除 socket、启动锁、日志、目录记录、当前可执行文件、安装的许可证和补全文件、imx 配置文件及记录中的 shell 集成，并清理属于当前用户的空目录。当前默认目录、`XDG_RUNTIME_DIR` 和 `IMX_DIR` 对应的运行文件也会清理。

通过符号链接运行时，卸载会删除实际可执行文件、调用使用的链接，以及 `PATH` 中指向该文件的 `imx` 链接。安装到 `bin/imx` 时，许可证和补全文件从同一安装前缀清理；独立复制的可执行文件也支持卸载。

卸载会检查文件身份和删除权限。普通用户删除系统安装文件时会自动调用 `sudo`，根据系统设置提示输入密码；取消授权会终止卸载，会话继续运行。会话和运行文件按执行命令的当前用户清理，其他用户的运行文件由各用户管理。系统安装的可执行文件和许可证为共享文件。

启动锁阻止并发连接重新创建运行文件。会话内部执行卸载时，独立清理进程会在会话关闭后继续完成运行文件删除。系统的共享目录保留。

工作目录中的用户文件，以及运行目录、配置目录、许可证目录和补全目录中的额外用户文件保留。shell 初始化文件保留原有用户内容；手动修改过的 imx 集成片段或脚本会在删除安装文件之前报告，并终止卸载。
