# 开发说明

## 编译

需要 Zig 0.17.0 和 Linux 5.9 或更新版本。Zig 版本记录在 [`.zig-version`](../.zig-version)，依赖版本及校验值记录在 [`build.zig.zon`](../build.zig.zon)。

在仓库根目录执行：

```bash
zig build
./zig-out/bin/imx -v
```

安装到系统目录：

```bash
sudo zig build --prefix /usr/local
sudo install -D -m 644 src/completions/fish.fish /usr/share/fish/vendor_completions.d/imx.fish
imx -v
```

编译会同时安装可执行文件、许可证，以及 `share/bash-completion/completions/imx`、`share/zsh/site-functions/_imx`、`share/zsh/vendor-completions/_imx` 和 `share/fish/vendor_completions.d/imx.fish`。补全加载条件见[使用说明](usage.md#tab-补全)。

系统安装需要在 `/usr/local/share/fish/vendor_completions.d/` 和 `/usr/share/fish/vendor_completions.d/` 同时提供 Fish 补全文件。上面的命令将程序安装到 `/usr/local`，并将 Fish 补全复制到另一个标准目录。使用安装脚本时会自动完成这些操作。

默认生成使用 musl 的静态可执行文件。imx 使用 `safe` 编译模式，开启运行时安全检查；终端库使用 `fast` 模式。`debug` 模式同时开启终端库的安全检查。

通过 `-Doptimize=debug|safe|fast|small` 选择编译模式。例如：

```bash
zig build -Doptimize=debug
```

交叉编译 ARM64：

```bash
zig build -Dtarget=aarch64-linux-musl -Dcpu=baseline --prefix zig-out/aarch64
```

`zig-pkg/`、`.zig-cache/`、`zig-out/` 和 `work/` 已加入 `.gitignore`。Zig 和 uv 的全局缓存使用各自的默认目录。

## 测试与贡献

测试需要 uv、Python 3.12 或更新版本、Bash、bash-completion、Zsh、Fish、Vim、curl、GNU tar、GNU coreutils、GNU findutils、sudo 和 util-linux。系统安装测试通过 `sudo` 创建独立的 Linux 挂载环境，使用真实普通用户和密码验证安装、升级和卸载；需要系统允许挂载文件系统。Python 依赖版本记录在 [`tests/uv.lock`](../tests/uv.lock)。提交改动前执行：

```bash
zig fmt --check build.zig src
zig build
zig build test
mkdir -p work/runtime
TMPDIR="$PWD/work/runtime" uv run --frozen --project tests pytest -q tests
```

集成测试启动真实 PTY、Bash、Zsh、Fish、Vim 和会话程序，检查命令、历史、重新连接、终端尺寸、分离、进程清理、并发创建和终端查询。补全测试使用各个 shell 的原生加载机制和实际 Tab 按键，检查命令、当前会话名称、候选变化和配置开关。安装测试通过真实 HTTP 服务下载编译的软件包，检查安装、更新、卸载和下载失败，并验证默认系统目录中的补全加载。测试目录保存在 `work/`。

`tests/test_panes.py` 验证分屏布局、目录继承、鼠标焦点、独立连接、会话切换、终端恢复和进程回收。`tests/pane_app.py` 在真实 PTY 中启用全屏、鼠标、括号粘贴及不同键盘协议，记录实际收到的输入，用于检查窗格坐标转换和按键编码。

`tests/test_pane_start.py` 验证后台暂停、目录删除、shell 启动失败和取消等待时的窗格隔离。`tests/benchmark_panes.py` 测量 2、4、8 个窗格中连续刷新一行文字时的客户端 CPU 时间、PSS 和终端输出量，复测方法见[性能说明](performance.md)。

修改安装或发布脚本时，还需要 ShellCheck 和 actionlint：

```bash
shellcheck install.sh scripts/*.sh
shellcheck -s bash src/shell/bash.sh src/completions/bash.sh
bash -n src/completions/bash.sh
zsh -n src/completions/zsh.sh
fish -n src/completions/fish.fish
actionlint .github/workflows/release.yml
```

讨论问题时，请附上 `imx -v`、系统和终端信息、复现命令，以及相关运行目录中的 `session-<name>.log`。性能测量方法见[性能说明](performance.md)。

`tests/test_isolation.py` 使用真实的 Linux 进程暂停、恢复、强制终止和持续输出，验证后台之间的隔离、查询期限及单线程运行。验证从 v0.4.1 升级时，可以将对应发布包解压到 `work/compat-v0.4.1/`，运行：

```bash
TMPDIR="$PWD/work/runtime" uv run --frozen --project tests python tests/legacy_upgrade.py --legacy-prefix work/compat-v0.4.1
```

该检查使用发布包中的可执行文件创建会话，验证替换可执行文件后重新连接、保留历史、切换到独立后台，以及卸载两种后台。

## GitHub Actions

工作流程位于 [`.github/workflows/release.yml`](../.github/workflows/release.yml)。

| 触发方式 | 执行内容 |
| --- | --- |
| 推送 `main` | 编译、检查、测试并生成构建附件 |
| 创建或更新 Pull Request | 编译、检查、测试并生成构建附件 |
| 手动运行，`tag` 留空 | 检查所选分支并生成构建附件 |
| 推送 `v*` 版本标签 | 复用同一提交已通过检查的主分支构建附件；需要构建时执行完整检查，然后发布 Release |
| 手动运行，填写已有版本标签 | 按版本标签选择提交，复用或构建通过检查的附件，然后发布 Release |

工作流程分别使用 x86_64 和 ARM64 Linux 环境，原生编译并运行单元测试、集成测试、ShellCheck 和 actionlint。构建附件保留 7 天，可以在 Actions 运行记录的 Artifacts 区域下载。

编译缓存包含 `.zig-cache/`、`zig-pkg/`、`work/zig-global-cache/` 和 `~/.cache/imx-ci/`，按架构、工具版本和 UTC 自然周分别保存。每周由主分支第一次通过检查的构建保存一份缓存，本周后续构建复用该缓存。Zig 根据实际源码和依赖检查编译结果是否有效，全部检查和测试仍然执行。新的一周重新生成缓存，避免缓存内容随着提交持续累积。

主分支每个架构最多保留最近两份编译缓存，标签和 Pull Request 只读取缓存。Actions 运行记录的 Summary 显示各架构保留的缓存数量和占用空间。GitHub 还会清理超过 7 天未使用的缓存，并在达到仓库额度时清理旧缓存；缓存缺失时正常执行完整编译。Python 依赖继续使用 setup-uv 管理的缓存。

发布复用要求构建来自本仓库 `main` 的推送检查、提交 SHA 完全一致、整套检查成功，而且两个架构的附件均存在并保留至少 10 分钟。主分支检查正在运行时，发布流程等待检查完成；检查失败或等待超过 30 分钟时终止发布。没有对应的构建或附件已失效时执行完整构建。发布前继续验证软件包版本及 SHA256 校验值。

## 版本发布

日常更新提交代码并按需推送分支。正式发版时创建并推送版本标签，触发 Release 发布。

发布前更新 `build.zig.zon` 中的 `version`，同步相关版本测试，并提交通过检查的代码。标签需要使用 `v版本号`，与程序输出的版本一致。例如发布 `0.16.0`：

```bash
git tag -a v0.16.0 -m "imx 0.16.0"
git push origin v0.16.0
```

进入仓库的 **Actions / Release**，打开对应标签的运行记录。**Select build** 选择已通过检查的主分支附件，或者安排两个 **Build and test** 任务。构建附件准备完成后，**Publish release** 会创建草稿、上传附件，再公开发布并设置为最新版本。

| 发布附件 | 内容 |
| --- | --- |
| `imx-linux-x86_64.tar.gz` | x86_64 静态可执行文件、许可证及补全文件 |
| `imx-linux-aarch64.tar.gz` | ARM64 静态可执行文件、许可证及补全文件 |
| `install.sh` | 安装脚本 |
| `VERSION` | 发布版本号 |
| `SHA256SUMS` | 软件包、安装脚本和版本文件的 SHA256 校验值 |

发布成功后，README 中的一键安装命令即可下载该版本。

也可以使用 **Actions / Release / Run workflow**，填写已经推送的版本标签进行发布。已公开发布的版本保留；发布新版本需要使用新标签。上传失败时，可以使用 **Re-run failed jobs**，工作流程会继续上传到已有草稿。

发布任务使用 GitHub 提供的 `GITHUB_TOKEN`，声明 `contents: write`，无需配置个人 Token。仓库需要启用 GitHub Actions。
