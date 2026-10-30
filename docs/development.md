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
sudo install -m 755 zig-out/bin/imx /usr/local/bin/imx
sudo install -d -m 755 /usr/local/share/licenses/imx
sudo cp -R zig-out/share/licenses/imx/. /usr/local/share/licenses/imx/
imx -v
```

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

测试需要 uv、Python 3.12 或更新版本、Bash、Vim、curl、GNU tar、GNU coreutils、GNU findutils、sudo 和 util-linux。系统安装测试通过 `sudo` 创建独立的 Linux 挂载环境，使用真实普通用户和密码验证安装、升级和卸载；需要系统允许挂载文件系统。Python 依赖版本记录在 [`tests/uv.lock`](../tests/uv.lock)。提交改动前执行：

```bash
zig fmt --check build.zig src
zig build
zig build test
mkdir -p work/runtime
TMPDIR="$PWD/work/runtime" uv run --frozen --project tests pytest -q
```

集成测试启动真实 PTY、Bash、Vim 和会话程序，检查命令、历史、重新连接、终端尺寸、分离、进程清理、并发创建和终端查询。安装测试通过真实 HTTP 服务下载编译的软件包，检查安装、更新、卸载和下载失败。测试目录保存在 `work/`。

修改安装或发布脚本时，还需要 ShellCheck 和 actionlint：

```bash
shellcheck install.sh scripts/*.sh
actionlint .github/workflows/release.yml
```

讨论问题时，请附上 `imx -v`、系统和终端信息、复现命令，以及相关运行目录中的 `server.log`。性能测量方法见[性能说明](performance.md)。

## GitHub Actions

工作流程位于 [`.github/workflows/release.yml`](../.github/workflows/release.yml)。

| 触发方式 | 执行内容 |
| --- | --- |
| 推送 `main` | 编译、检查、测试并生成构建附件 |
| 创建或更新 Pull Request | 编译、检查、测试并生成构建附件 |
| 手动运行，`tag` 留空 | 检查所选分支并生成构建附件 |
| 推送 `v*` 版本标签 | 检查标签对应的代码并发布 Release |
| 手动运行，填写已有版本标签 | 检查该标签的代码并发布 Release |

工作流程分别使用 x86_64 和 ARM64 Linux 环境，原生编译并运行单元测试、集成测试、ShellCheck 和 actionlint。构建附件保留 7 天，可以在 Actions 运行记录的 Artifacts 区域下载。

## 版本发布

日常更新提交代码并按需推送分支。正式发版时创建并推送版本标签，触发 Release 发布。

发布前更新 `build.zig.zon` 中的 `version`，同步相关版本测试，并提交通过检查的代码。标签需要使用 `v版本号`，与程序输出的版本一致。例如发布 `0.2.0`：

```bash
git tag -a v0.2.0 -m "imx 0.2.0"
git push origin v0.2.0
```

进入仓库的 **Actions / Release**，打开对应标签的运行记录。两个 **Build and test** 任务成功后，**Publish release** 会创建草稿、上传附件，再公开发布并设置为最新版本。

| 发布附件 | 内容 |
| --- | --- |
| `imx-linux-x86_64.tar.gz` | x86_64 静态可执行文件及许可证 |
| `imx-linux-aarch64.tar.gz` | ARM64 静态可执行文件及许可证 |
| `install.sh` | 安装脚本 |
| `VERSION` | 发布版本号 |
| `SHA256SUMS` | 软件包、安装脚本和版本文件的 SHA256 校验值 |

发布成功后，README 中的一键安装命令即可下载该版本。

也可以使用 **Actions / Release / Run workflow**，填写已经推送的版本标签进行发布。已公开发布的版本保留；发布新版本需要使用新标签。上传失败时，可以使用 **Re-run failed jobs**，工作流程会继续上传到已有草稿。

发布任务使用 GitHub 提供的 `GITHUB_TOKEN`，声明 `contents: write`，无需配置个人 Token。仓库需要启用 GitHub Actions。
