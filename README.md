# imx

## 下载与安装

支持 Linux x86_64 和 ARM64，需要 Linux 5.9 或更新版本、Bash、curl、GNU tar、GNU coreutils 和 GNU findutils。首次发布 Release 后执行：

```bash
curl -fsSL https://github.com/inwf/imx/releases/latest/download/install.sh | bash
```

安装脚本下载当前架构的静态可执行文件，校验 SHA256 和程序版本，安装到 `~/.local/bin/imx`，许可证安装到 `~/.local/share/licenses/imx/`。安装过程无需 Zig。下载和解压使用系统缓存目录，完成后清理临时文件。

如果当前 shell 的 `PATH` 尚未包含安装目录，执行：

```bash
export PATH="$HOME/.local/bin:$PATH"
imx -v
imx attach dev
```

可以将上述 `export` 语句加入自己使用的 shell 配置文件。安装脚本会输出对应的设置命令。

安装指定版本：

```bash
curl -fsSL https://github.com/inwf/imx/releases/download/v0.2.0/install.sh | bash -s -- v0.2.0
```

通过 `IMX_PREFIX` 指定安装前缀：

```bash
curl -fsSL https://github.com/inwf/imx/releases/latest/download/install.sh | IMX_PREFIX="$HOME/apps/imx" bash
```

重新执行安装命令会更新可执行文件；安装脚本通过原子替换保留运行中的会话。升级完成后，已有后台进程继续使用启动时的版本，全部会话结束后，新建会话使用更新后的版本。

卸载：

```bash
imx uninstall
```

## 命令

| 命令 | 功能 |
| --- | --- |
| `imx attach dev` | 创建或进入 dev 会话 |
| `imx list`、`imx ls`、`imx` | 查看全部会话 |
| `imx cat dev` | 查看保留的历史输出和当前屏幕文字 |
| `imx detach` | 在会话内部执行，分离当前会话的全部连接 |
| `imx kill dev` | 终止并删除 dev 会话 |
| `imx uninstall` | 终止会话并清理当前安装及运行文件 |
| `imx -v` | 查看版本 |
| `imx help` | 查看帮助 |

关闭终端、断开 SSH 连接或按下 `Ctrl+\` 会分离当前连接。会话中的 shell 和程序继续运行。重新执行 `imx attach dev` 会恢复屏幕内容和保留的历史。退出会话中的 shell 会结束该会话。

会话名称允许 1–64 个 ASCII 字母、数字、句点、下划线和连字符，`.` 和 `..` 保留。新会话使用创建时的工作目录、环境变量和 `$SHELL`；未设置 `$SHELL` 时使用 `/bin/sh`。会话内部设置 `IMX_SESSION`。嵌套会话会报告错误。

多个终端可以同时连接同一个会话，输入和输出由全部连接共享。最近进入会话的连接决定终端大小；该连接分离后，由剩余的第一个连接决定终端大小。

`cat` 使用 `ghostty-vt` 的纯文本格式化器，处理颜色、光标移动和文字覆盖。历史使用 10,000 行目标及 2 MiB 的容量限制，按完整终端页面修剪，实际保留行数受页面大小和终端宽度影响；当前屏幕及终端状态另行占用内存。使用备用屏幕的程序运行期间，`cat` 输出其当前屏幕。会话结束后释放历史。

`kill` 使用 Linux session ID 和 pidfd 终止所属的 shell、前台作业和后台作业。程序主动通过 `setsid()` 创建独立 Linux session 后，具有独立的生命周期。

`imx uninstall` 直接执行卸载，终止当前用户在已记录运行目录中的全部 imx 会话和后台进程，删除 socket、启动锁、日志、目录记录、当前可执行文件及安装的许可证，并清理属于当前用户的空目录。当前默认目录、`XDG_RUNTIME_DIR` 和 `IMX_DIR` 对应的运行文件也会清理。运行目录中的历史随后台进程退出释放。

通过符号链接运行时，卸载会删除实际可执行文件、调用使用的链接，以及 `PATH` 中指向该文件的 `imx` 链接。安装到 `bin/imx` 时，许可证从同一安装前缀的 `share/licenses/imx/` 清理；独立复制的可执行文件支持直接卸载。

执行用户需要具有删除安装文件和运行目录的权限。卸载会检查待删除文件的身份和删除权限，使用启动锁阻止并发连接重新创建运行文件。会话内部执行卸载时，独立清理进程会在会话关闭后继续完成删除。工作目录中的用户文件保留。

## 编译与安装

需要 Zig 0.17.0、Linux 5.9 或更新版本。默认生成使用 musl 的静态可执行文件，imx 自身开启运行时安全检查，终端库使用 `fast` 模式构建。`debug` 模式同时开启终端库的安全检查。

```bash
zig build
zig build --prefix "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
```

编译模式通过 `-Doptimize=debug|safe|fast|small` 选择，默认使用 `safe`。

```bash
zig build -Dtarget=aarch64-linux-musl --prefix zig-out/aarch64
```

Zig 会根据 `build.zig.zon` 下载并校验固定版本的依赖。`zig-pkg/`、`.zig-cache/`、`zig-out/` 和 `work/` 已加入 `.gitignore`。

## 运行目录

设置 `IMX_DIR` 可以指定绝对路径。默认使用 `$XDG_RUNTIME_DIR/imx`；未设置 `XDG_RUNTIME_DIR` 时使用 `$HOME/.local/state/imx/run`。

运行目录必须属于当前用户，权限为 `0700`。Unix socket 通过 `SO_PEERCRED` 检查连接用户。后台进程通过首次创建会话的命令自动启动，全部会话及连接结束后退出。

`server.log` 记录后台进程的错误。历史保存在内存中。机器重启或后台进程结束后，会话结束。

程序需要设置绝对路径的 `HOME`，使用 `$HOME/.local/state/imx/paths/` 记录使用过的运行目录。`lifecycle.lock` 和可执行文件上的锁负责同步启动与卸载。记录仅在执行命令时更新，后台等待事件的方式保持一致。

## 资源控制

一个用户的全部会话由一个单线程后台进程管理。后台进程使用 `epoll` 和 `signalfd` 等待事件；没有输入、输出或控制请求时，阻塞等待内核通知。

创建会话及最后一个客户端分离时，调用终端库的页面容量压缩和释放接口，释放闲置的预留页面。持续输出期间使用页面池；光标仍然持有样式或超链接引用的页面保持引用表。

实时输出和输入队列分别限制为 256 KiB。慢速客户端超过输出容量限制时断开连接，会话继续运行。终端快照按 16 KiB 分批发送，快照发送期间的实时输出保持顺序。终端尺寸允许最多 512 列、256 行。

2026-10-30 在 x86_64、WSL2 Linux `6.18.33.2-microsoft-standard-WSL2` 上，使用 imx 0.2.0、默认编译模式、80×24 终端和 Bash 测量。PSS 表示按比例分摊共享页面后的物理内存；下表仅统计 imx 后台进程，shell 和会话程序的内存单独统计在测量文件中。会话完成初始化后分离，历史仅包含初始化输出。

| 空闲会话数量 | 后台 PSS | 后台进程数量 | 后台线程数量 |
| --- | --- | --- | --- |
| 1 | 1.47 MiB | 1 | 1 |
| 10 | 2.02 MiB | 1 | 1 |
| 100 | 6.38 MiB | 1 | 1 |

每种场景的 5 秒空闲采样中，后台 CPU 时间、主动进程切换和被动进程切换增量均为零；这些数值表示该次采样结果。连接中的客户端 PSS 约为 0.75 MiB，静态可执行文件大小约为 1.77 MiB。

无人连接时使用 `seq` 输出 500,000 行，PTY 接收约 3.89 MB 数据，生成并处理输出耗时约 0.57 秒，后台消耗约 0.25 秒 CPU 时间，输出后后台 PSS 约为 3.84 MiB。该次测量保留了 2,902 行纯文本，包含当前屏幕。执行 `tests/benchmark.py` 可以在本机复测，结果保存至 `work/benchmark.json`。

## 测试

测试需要 `uv`、Python 3.12 或更新版本、Bash 和 Vim，Python 依赖版本记录在 `tests/uv.lock`。

```bash
zig build test
uv run --frozen --project tests pytest -q
uv run --frozen --project tests python tests/benchmark.py
```

集成测试启动真实 PTY、Bash 和会话程序，检查全部命令、历史、重新连接、终端尺寸、分离、进程清理、并发创建和终端查询。测试目录保存在 `work/`。

安装测试通过真实 HTTP 服务下载编译的软件包，执行 `curl | bash`，检查安装、重复安装、卸载、校验失败、下载失败和运行中的会话。

## GitHub Actions 发布

推送 `main` 和创建 Pull Request 会自动执行 `Release` 工作流程，在 x86_64 和 ARM64 的 Linux 环境中分别编译、运行单元测试和集成测试、检查脚本并生成软件包。每次成功运行的附件保留 7 天，可在 Actions 运行页面的 Artifacts 区域下载。

发布 imx 0.2.0，在已包含当前代码的 `main` 分支执行：

```bash
git tag -a v0.2.0 -m "imx 0.2.0"
git push origin v0.2.0
```

进入 GitHub 仓库的 **Actions → Release**，打开对应版本的运行记录。两个 **Build and test** 任务成功后，**Publish release** 会创建草稿、上传两个架构的软件包、安装脚本和 SHA256 校验文件，再公开发布 Release 并设置为最新版本。发布完成后，上面的单条安装命令即可使用。

也可以在 **Actions → Release → Run workflow** 手动执行：`tag` 留空时执行检查并生成附件；填写已经推送的版本标签，例如 `v0.2.0`，会检查该标签的代码并发布。程序版本必须与标签一致。

后续发布需要修改 `build.zig.zon` 中的 `version` 和相关版本测试，提交并推送代码，再创建并推送对应的 `v版本号` 标签。已经公开发布的版本保留；发布新版本需要使用新标签。发布上传失败时，可以在 Actions 中使用 **Re-run failed jobs**，工作流程会继续上传到已有草稿。

工作流程使用 GitHub 提供的 `GITHUB_TOKEN`，发布任务声明 `contents: write`，无需配置个人 Token。仓库需要启用 GitHub Actions；工作流程文件位于 `.github/workflows/release.yml`。

## 许可证

项目使用 MIT License。终端历史和恢复逻辑参考 zmx，终端处理使用 Ghostty 的 `ghostty-vt`。版权信息见 `LICENSE`、`NOTICE` 和 `licenses/`。
