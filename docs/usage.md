# 使用说明

## 帮助与参数

`imx help`、`imx -h` 和 `imx --help` 显示总体帮助；`imx -v` 和 `imx --version` 显示版本。每个命令支持 `-h`、`--help`，例如 `imx attach --help`；也可以使用 `imx help attach` 查看该命令的帮助。

帮助和版本查询支持非交互环境，并在读取配置及执行操作之前处理。未知命令、未知选项、缺少名称和多余参数会报告具体错误及帮助入口。

## 会话生命周期

`imx attach dev` 创建或进入 `dev` 会话。新会话使用创建时的工作目录、环境变量和 `$SHELL`；未设置 `$SHELL` 时使用 `/bin/sh`。进入会话需要交互式终端。

关闭终端、断开 SSH 连接或按下配置的快捷键（默认 `Alt+\`）会分离当前连接。会话中的 shell 和程序继续运行，重新执行 `imx attach dev` 会恢复屏幕和保留的历史。

在会话内部执行 `imx detach` 会分离该会话的全部连接。退出会话中的 shell 会结束会话。`imx kill dev` 会终止并删除指定会话。

detach 或会话退出后，外层 shell 提示符从左上角开始，原来的画面移入历史记录。分屏时只影响退出会话的窗格；关闭最后一个窗格后，外层终端也从左上角显示提示符。

每个会话在创建时启动独立的后台进程，内部使用一个事件循环线程，拥有该会话的 PTY、程序、屏幕、历史和连接。会话及其连接结束后，对应后台退出。会话和历史保存在内存中，后台退出会释放所属会话，机器重启会释放全部会话。某个后台暂停、崩溃或持续处理大量输出时，其他后台可以独立响应。

会话名称允许 1–64 个 ASCII 字母、数字、句点、下划线和连字符。`.` 和 `..` 为保留名称。以连字符开头的名称需要放在参数分隔符 `--` 后面，例如 `imx attach -- -dash`、`imx cat -- -dash` 和 `imx kill -- -dash`。

## 只读连接

`imx read dev` 只读连接已有会话；目标不存在时报告 `SessionNotFound`。在会话内部执行时，当前连接切换为只读模式，使用当前会话名称可以直接观察当前会话。以连字符开头的名称放在 `--` 后面，例如 `imx read -- -dash`。

只读视图接收屏幕和历史，在底部显示 `Read-only` 及会话名称。键盘输入、粘贴、鼠标和焦点事件都不会发送到程序。观察窗口的缩放、分屏和放大保持会话的终端尺寸；视图使用源终端尺寸解析输出，再根据观察窗口进行裁剪，实时模式下跟随程序光标。

PageUp/PageDown 按页浏览历史，方向键上下逐行浏览，Home 前往保留历史的起点，End 恢复跟随实时输出，方向键左右水平移动视图。开启 `panes.mouse` 时也可以使用滚轮浏览。按下 q 或 Esc 退出观察并保留会话和其他连接；从窗格的普通 shell 启动时，退出后返回该 shell。终端通过 bracketed paste 发送的粘贴内容不会触发退出。配置的分离快捷键（默认 Alt+\\）分离观察连接，关闭窗格快捷键（默认 Alt+W）关闭观察窗格，两项操作都会保留会话和其他连接。

`CLIENTS` 包含只读连接。最近进入的可写连接决定会话尺寸；没有可写连接时保留最后的尺寸，后台继续处理程序的终端查询。只读连接要求后台及所在分屏界面支持此功能，旧版本会报告对应的 `ReadOnlyUnsupportedByBackend`、`ReadOnlyUnsupportedByClient` 或 `ReadOnlyUnsupportedByWorkspace` 错误。

## 交互选择会话

执行 `imx select` 打开交互界面，上方显示按名称排序的会话列表，下方显示当前选中会话的屏幕内容。需要交互式终端；没有会话时输出 `No sessions.` 并退出。

| 按键 | 功能 |
| --- | --- |
| ↑ / k | 选择上一项 |
| ↓ / j | 选择下一项 |
| Enter / 空格 | 进入选中的会话 |
| Esc / q | 取消选择并恢复原来的界面 |

开启 `panes.mouse` 后，单击列表中的会话会选中并显示预览，双击进入该会话；在列表区域使用滚轮可以逐项切换。在预览内容区域使用滚轮可以上下浏览保留的历史，每次移动三行。向上滚动暂停实时跟随，滚回底部恢复。新增输出和窗口大小变化时保留当前历史位置；历史超出保留上限后，观看位置移动到最早仍保留的内容。切换会话后显示新选中会话的实时预览。标题、预览边框和底部提示栏不参与鼠标操作。鼠标配置在打开选择界面时读取，退出时恢复原来的终端鼠标设置。

列表超过可用高度时跟随选项滚动，到达首尾后保持当前选项。终端缩放时重新安排界面。新增和结束的会话会自动反映到列表中；列表在打开后变为空时，界面继续等待新会话，也可以取消退出。

预览保留文字颜色和中文内容，显示当前屏幕中光标附近的区域，超出预览宽度的内容会被裁剪。预览不会向会话输入按键、改变会话终端尺寸或增加 `CLIENTS`。在会话内部执行时，当前会话预览保留选择界面打开前的主屏幕；确认其他会话会切换当前终端的连接。在分屏中的普通 shell 执行时，确认选择会进入该窗格。

预览连接只订阅当前选中的会话，各个连接独立保存历史位置。后台在屏幕内容或观看位置更新且收到下一帧请求时发送预览，每秒最多刷新 10 次，仅提取并传输可见区域中的当前画面或历史内容；空闲画面停止刷新。会话列表通过目录变更通知更新。无响应后台会显示提示，仍然可以切换选项或取消选择。

预览和历史滚动需要会话后台支持相应功能。支持实时预览但不支持历史滚动的后台，在尝试滚动时显示滚动不可用，仍然可以确认进入会话或切换选项。完全不支持预览的独立后台会显示预览不可用；旧版共享后台会报告 `SelectUnsupportedByBackend`。安装新版程序后新建的会话使用新版后台，已有会话继续由原来的后台运行。

## 分屏与窗格

外层终端支持 OSC 8 时，窗格内程序输出的超链接可以继续点击。分屏、放大、历史滚动、重新连接和会话预览均保留链接地址，点击方式由外层终端决定。

进入 `imx attach <name>` 后，Alt+D 将当前窗格左右分屏，Alt+Shift+D 将当前窗格上下分屏。Alt 对应 macOS 的 Option。新窗格使用当前聚焦窗格的实际工作目录启动普通 shell，用户可以手动执行 `imx attach <name>` 进入需要的会话。每个窗格都可以继续拆分。

新窗格查询目录和启动 shell 时显示 `starting`，总时限为两秒。等待期间可以操作其他窗格，输入新窗格的内容会在 shell 启动后发送。查询或启动失败时关闭这个新窗格并显示原因；按下 Alt+W 可以取消等待。

鼠标模式默认关闭（`panes.mouse = false`），普通 shell 中的拖动选择由终端处理，可以使用终端的复制快捷键，例如 iTerm2 的 Command+C。终端本地选区可能跨越多个窗格。通过 Alt+方向键或 Alt+数字切换输入焦点，高亮边框表示当前聚焦的窗格。各个窗格独立处理屏幕、全屏程序、输入协议和历史。

设置 `panes.mouse = true` 后，可以通过鼠标点击切换窗格、滚轮浏览窗格历史和拖动分隔线调整大小。修改后退出整个界面并重新 attach 生效。窗格内程序主动请求的鼠标输入仍然有效，坐标转换为窗格内部坐标后传给程序；关闭鼠标模式时，只向当前聚焦窗格传递鼠标事件。在 iTerm2 中，程序使用鼠标时可以通过 Option+拖动建立终端本地选区，再按 Command+C 复制。

开启鼠标模式后，在窗格文字区域按住鼠标左键拖动，可以高亮选中文字。选区限制在开始拖动的窗格内，支持中文、组合字符和多行内容。双击选择单词，三击选择整行；拖动到顶部或底部之外会滚动选择历史。程序启用鼠标报告时，按住 Shift 拖动可以选择文字。

选中文字后按 Alt+C 复制当前聚焦窗格的选区，复制后保留高亮。鼠标释放、双击和三击只改变选区；没有选中文字时按下复制快捷键保持剪贴板内容。复制保留中文、组合字符、缩进和实际换行，合并自动折行，省略行尾空白、窗格边框和文字样式。通过 OSC 52 请求外层终端写入系统剪贴板，因此 SSH 连接也可以复制到本机；终端需要支持并允许 OSC 52，发送请求后无法保证终端已经接受。

使用 `keybindings.copy_selection` 配置复制快捷键。macOS 的 Command+C 通常由终端处理；可以在终端中把它映射为发送 Alt+C，再使用 imx 的默认绑定。iTerm2 需要允许 `Applications in terminal may access clipboard`。

分屏界面的键盘上报模式跟随当前聚焦的程序。普通 shell 保持输入法提交文本的正常路径，程序请求增强键盘事件时启用对应模式；切换回 shell 后恢复普通文本输入。

开启鼠标模式后，按住鼠标左键拖动窗格之间的分隔边框，可以调整左右或上下窗格的大小，分隔边框的两侧均可操作。嵌套分屏按照选中的分隔边框调整对应区域，在交叉处优先调整贯穿整个区域的分隔边框。拖动保持当前输入焦点，并实时更新窗格内程序的终端尺寸。每个窗格至少保留 12 列、5 行（包括边框），嵌套区域会为其中全部窗格预留最小空间。调整后的比例随终端窗口缩放保留，临时缩小窗口后重新扩大也会恢复。拖动过程中关闭窗格、继续分屏、切换焦点或缩放终端会结束当前拖动，重新按住边框即可继续调整。

Alt+方向键按屏幕位置聚焦相邻窗格，优先选择边缘最近且靠近当前窗格中心的窗格。到达边缘时保持当前焦点。窗格编号从 0 开始，Alt+0 至 Alt+9 对应标题中的窗格编号；编号不存在时保持当前焦点。关闭窗格后剩余编号保持不变，新窗格复用最小的空闲编号。普通 shell 窗格也可以聚焦，编号大于 9 时使用方向快捷键，开启鼠标模式后也可以点击聚焦。通过 `keybindings.focus_left`、`focus_right`、`focus_up`、`focus_down` 和 `focus_0` 至 `focus_9` 配置这些快捷键，修改后重新启动整个界面生效。

Alt+Z 将当前窗格临时放大到整个界面，边框显示双实线，标题显示 `[zoom]`；再次使用恢复单实线边框及原有布局、比例和焦点。其他窗格保留终端尺寸，程序和历史记录继续更新。缩放整个终端窗口时保持放大状态，恢复分屏后按照保存的比例和最小尺寸重新计算布局，固定间距继续生效。

切换到其他窗格、继续分屏、使用窗格尺寸调整快捷键或关闭当前窗格时，先恢复分屏布局再执行操作。聚焦当前编号、指定不存在的编号或没有相邻窗格的方向时，继续保持放大。关闭放大的普通 shell 窗格会显示剩余窗格；其他窗格退出时，当前窗格继续放大，剩余一个窗格时结束放大状态。分离会话后，同一窗格的普通 shell 继续保持放大。放大期间，鼠标操作作用于可见窗格。只有一个窗格时，Alt+Z 保持当前显示。通过 `keybindings.zoom_pane` 配置快捷键，修改后重新启动整个界面生效。

Alt+Shift+方向键向箭头方向扩大当前窗格，Alt+Ctrl+方向键将相反方向的边界沿箭头方向移动，缩小当前窗格。每次将选中的分隔线移动一列或一行，关闭鼠标模式时同样有效。调整过程中保持焦点，并通知程序更新终端尺寸。

| 方向键 | 扩大：Alt+Shift | 缩小：Alt+Ctrl |
| --- | --- | --- |
| 向左 | 左边界向左移动 | 右边界向左移动 |
| 向右 | 右边界向右移动 | 左边界向右移动 |
| 向上 | 上边界向上移动 | 下边界向上移动 |
| 向下 | 下边界向下移动 | 上边界向下移动 |

扩大操作与相反方向的缩小操作控制同一条边界。例如，Alt+Shift+上方向键将上边界向上移动，Alt+Ctrl+下方向键将上边界向下移动。四周都有相邻窗格时，可以分别操作四条边界。屏幕外侧边界保持固定，指定边界没有分隔线时保持布局。

嵌套布局沿当前窗格向外寻找控制指定边界的最近分隔位置，共享该区域的窗格一起调整。例如，右侧区域有上下两个窗格时，调整其中一个窗格的左边界会同时调整这两个窗格。每个窗格至少保留包含边框的 12 列、5 行；达到最小尺寸时保持布局。间距保持固定，调整后的比例随终端缩放保留。通过 `keybindings.resize_left`、`resize_right`、`resize_up`、`resize_down` 配置扩大快捷键，通过 `keybindings.shrink_left`、`shrink_right`、`shrink_up`、`shrink_down` 配置缩小快捷键，修改后重新启动整个界面生效。

分离快捷键（默认 Alt+\\）只分离当前聚焦窗格的连接，随后回到该窗格的普通 shell。其他窗格保持连接，即使它们连接同一个会话。会话中的 shell 退出后，所在窗格返回普通 shell；普通 shell 退出后关闭窗格，剩余窗格重新分配空间。最后一个窗格关闭后退出整个界面。

按下 Alt+W 关闭当前聚焦的窗格。可写连接会自动终止其中的会话及程序，其他连接到同一会话的客户端也会断开；需要保留会话时，先 detach（默认 Alt+\\）。只读连接会保留会话及其他连接。关闭普通 shell 窗格会终止其中的程序。在普通 shell 提示符下输入 `exit`，或者在命令行为空时按下 `Ctrl+D`，同样可以关闭窗格。在会话的 shell 中直接执行 `exit` 会结束该会话。

分屏布局只存在于当前客户端内存中。关闭终端或者断开 SSH 连接会释放布局，并终止窗格中的普通 shell 及其作业，已经进入的会话继续在各自后台运行。重新连接时自行分屏和 attach。窗口缩小时保留全部窗格，空间不足时显示聚焦窗格所在区域；重新扩大窗口后恢复完整布局。新分屏需要每个窗格至少 12 列、5 行（包括边框）。

`panes.horizontal_gap` 设置左右相邻窗格边框之间的空白列数，`panes.vertical_gap` 设置上下相邻窗格边框之间的空白行数。两项都接受 `0` 至 `255` 的整数，默认均为 `0`，不会添加界面外侧留白。间距会占用分屏空间，终端缩放时保持固定；空间不足时拒绝创建新分屏。开启鼠标模式后，可以拖动间距区域及两侧边框调整大小。修改后退出整个界面并重新 attach 生效。例如：

```toml
[panes]
horizontal_gap = 2
vertical_gap = 1
```

```toml
[keybindings]
# 在当前窗格右侧创建新窗格。
# Create a new pane to the right of the focused pane.
split_right = { key = 'd', alt = true }
# 在当前窗格下方创建新窗格。
# Create a new pane below the focused pane.
split_down = { key = 'd', alt = true, shift = true }
# 关闭当前窗格并终止其中的会话；需要保留会话时先 detach。
# Close the focused pane and terminate its session; detach first to keep the session running.
close_pane = { key = 'w', alt = true }
# 临时放大当前窗格，再次使用恢复原有布局。
# Temporarily zoom the focused pane; repeat to restore the layout.
zoom_pane = { key = 'z', alt = true }
# 复制当前窗格的选中文字。
# Copy selected text in the focused pane.
copy_selection = { key = 'c', alt = true }
# 向箭头方向扩大当前窗格，将同侧边界移动一列或一行。
# Grow the focused pane by moving the edge on the arrow's side one column or row.
resize_left = { key = 'Left', alt = true, shift = true }
resize_right = { key = 'Right', alt = true, shift = true }
resize_up = { key = 'Up', alt = true, shift = true }
resize_down = { key = 'Down', alt = true, shift = true }
# 缩小当前窗格，将相反方向的边界沿箭头方向移动一列或一行。
# Shrink the focused pane by moving the opposite edge one column or row in the arrow direction.
shrink_left = { key = 'Left', alt = true, ctrl = true }
shrink_right = { key = 'Right', alt = true, ctrl = true }
shrink_up = { key = 'Up', alt = true, ctrl = true }
shrink_down = { key = 'Down', alt = true, ctrl = true }
```

`super` 对应 macOS 的 Command，`alt` 对应 macOS 的 Option。快捷键需要由本地终端发送给 imx，可以通过配置文件换用其他组合。分屏、聚焦、临时放大、复制选区、调整大小和关闭窗格的快捷键在启动整个界面时读取，修改后退出界面并重新 attach 生效。

## 切换会话

在 `dev1` 会话内部执行以下命令，当前终端会切换到 `dev2`：

```bash
imx attach dev2
```

`dev2` 已经存在时恢复其屏幕、历史和程序状态；尚未存在时，使用执行命令时的工作目录、环境变量和 `$SHELL` 创建。`dev1` 的 shell、程序、环境变量和历史继续保留。在 `dev2` 中执行 `imx attach dev1` 可以返回。目标名称与当前会话相同时，命令直接成功返回。

多个终端连接同一会话时，切换最近发送输入的终端，其他终端继续连接原会话。目标会话使用切换终端的实际尺寸。切换完成后，配置的快捷键分离当前终端，`imx detach` 分离目标会话的全部连接。

目标名称无效、目标后台连接超时或者新会话的 shell 启动失败时，命令报告错误，当前终端继续连接原会话。切换命令需要在所属会话的 Linux session 内运行。

会话切换需要客户端和原会话后台均支持此功能。旧后台会报告 `SwitchUnsupportedByBackend`，旧客户端会报告 `SwitchUnsupportedByClient`。更新可执行文件后，重新连接会使用新客户端；后台使用启动时的版本，结束会话后重新创建会启动新后台。

## 重命名会话

在会话内部修改当前会话名称：

```bash
imx rename work
```

在任意位置修改指定会话名称：

```bash
imx rename dev work
```

新名称遵循会话名称规则：长度为 1 至 64 个字符，可以包含 ASCII 字母、数字、点号、下划线和连字符，`.` 和 `..` 保留。以连字符开头的名称放在 `--` 后面，例如 `imx rename -- dev -work`。原名称与新名称相同时直接成功返回；目标名称已被使用时报错 `SessionAlreadyExists`。重命名期间存在并发创建或重命名操作时，可能报告 `SessionBusy`，原会话继续运行。

重命名保留 shell 和所有程序、历史、工作目录、创建时间、终端尺寸及连接。会话列表和 Tab 补全使用新名称，原名称可以用于创建其他会话。已连接的分屏立即更新标题；关闭可写窗格时会终止重命名后的会话，关闭只读窗格时会保留会话。

启用提示符集成时，Bash、Zsh、Fish 在下一次显示提示符时更新会话名称和 `IMX_SESSION`。内部标识 `IMX_SESSION_ID` 在重命名后保持稳定，`imx rename <new-name>`、`imx detach` 和会话切换通过该标识定位当前会话；关闭提示符集成后这些命令也继续有效。运行中的程序已经继承的环境变量保持原值。

会话后台需要支持重命名命令，旧后台会报告 `RenameUnsupportedByBackend`。更新可执行文件后，已有后台继续使用启动时的版本，结束会话并重新创建会启动新后台。即时更新分屏标题需要支持此通知的客户端，重新连接会使用当前可执行文件。

## 会话列表

`imx ls`、`imx list` 和 `imx` 查看全部会话，按会话名称排序。列表依次包含 `NAME`、`PID`、`CLIENTS`、`CREATED`、`STATUS` 和 `DIRECTORY`。终端输出根据标题和所有会话内容计算列宽，列间保留两个空格；管道和重定向输出使用制表符分隔。

列表并发查询独立后台，共享一秒查询期限。正常响应显示 `running`，超过期限显示 `unresponsive`，请求错误显示 `error:<错误名称>`；无法获取的字段显示 `-`。已退出后台留下的 socket 不会作为存活会话显示。客户端连接后台及等待响应采用两秒超时，超时报错会保留后台及其会话。

`DIRECTORY` 在每次查询时从 `/proc/<PID>/cwd` 读取会话 shell 的当前实际目录，随 `cd` 和目录重命名更新，并解析符号链接。重新连接保留 shell 当前目录；前台子程序拥有独立目录时，该列继续表示会话 shell 的目录。shell 通过 `exec` 替换为其他程序后，该列跟随相同 PID 的程序。目录被删除后，显示 Linux 提供的 ` (deleted)` 后缀。

目录中的换行、制表符、控制字符、无效 UTF-8 字节、双引号和反斜线采用转义形式，例如 `\n`、`\t`、`\x1b` 和 `\\`，保持终端与制表符分隔输出的结构。普通中文和空格直接显示。会话在查询期间退出时会从结果中移除；读取目录的其他错误会通过该会话的 `STATUS` 显示。

`CREATED` 按后台进程的本地时区显示会话创建时间，默认格式为 `MM-DD HH:mm:ss`，例如 `10-30 14:05:09`。时间在创建会话时记录，分离和重新连接保持该时间；显示格式由 `list.created_format` 控制。

## 配置文件与会话提示符

配置文件使用 `$XDG_CONFIG_HOME/imx/config.toml`；`XDG_CONFIG_HOME` 未设置或为空时，使用 `$HOME/.config/imx/config.toml`。路径需要为绝对路径。

执行 `imx`、`imx ls`、`imx list`、`imx attach <name>` 或 `imx read <name>` 时，如果配置文件不存在，程序会自动创建包含会话名称提示、补全、`CREATED` 格式、鼠标模式和聚焦窗格颜色设置及中英文注释的文件。新建目录使用 `0700` 权限，配置文件使用 `0600` 权限，并遵循当前用户的 umask。已有文件保留原有内容和权限；并发首次运行时，完整写入后才公开配置文件。创建或读取失败会立即报告错误。

`imx help`、`imx -v` 和 Tab 补全查询保持只读。配置文件由执行命令的用户创建，系统安装后的各个用户分别管理自己的配置。

配置错误包含实际文件路径。选项校验还会显示完整名称及要求，例如 `keybindings.detach.ctrl: expected a boolean (true or false)`。TOML 语法错误使用解析库提供的具体原因，文件读取和创建错误也会显示对应路径。

```toml
[prompt]
show_session = true

[list]
created_format = "%m-%d %H:%M:%S"

[completion]
enabled = true

[panes]
mouse = false
focused_border_color = "#969CD5"
```

仓库根目录的 [config.example.toml](../config.example.toml) 列出全部选项并提供简短的中英文注释，已启用的配置项采用内置默认值。可以将需要的选项合并到自己的配置文件，同一个分组只声明一次。需要自定义快捷键时添加对应的 `[keybindings]` 选项。

### 聚焦窗格颜色

`panes.focused_border_color` 设置当前聚焦窗格的边框和标题颜色，会话窗格和普通 shell 窗格均适用。格式必须为带引号的 `"#RRGGBB"`，十六进制字母不区分大小写。默认值为 `"#969CD5"`，省略时也使用此颜色。修改后退出整个界面并重新 attach 生效。

```toml
[panes]
# 聚焦窗格使用此边框和标题颜色。
# Use this color for the focused pane's border and title.
focused_border_color = "#969CD5"
```

### 快捷键配置

`keybindings.detach` 设置分离当前连接的快捷键，默认是 `Alt+\`。省略该选项时使用默认值。例如，改为 `Ctrl+x`：

```toml
[keybindings]
detach = { key = 'x', ctrl = true }
```

`key` 为必填字符串，可以使用单个 Unicode 字符，或者 `Enter`、`Tab`、`Escape`、`Space`、`Backspace`、`Insert`、`Delete`、`Left`、`Right`、`Up`、`Down`、`Page_Up`、`Page_Down`、`Home`、`End`、`F1` 至 `F12`。ASCII 字母和按键名称不区分大小写。`ctrl`、`alt`、`shift`、`super` 为可选布尔值，在显式配置的快捷键中默认为 `false`；需要 Shift 时设置 `shift = true`。例如，`{ key = 'x', ctrl = true, shift = true }` 表示 `Ctrl+Shift+x`，`{ key = 'F12' }` 表示 F12。

分离快捷键由客户端在建立连接时读取。修改后分离并重新连接即可生效，会话中的程序继续运行。同一连接切换会话时保留当前快捷键设置；同时连接的其他客户端继续使用各自建立连接时读取的设置。分屏、聚焦、临时放大、调整大小和关闭窗格的快捷键在启动整个界面时读取，修改后退出界面并重新进入生效。已有配置文件可以手动添加 `[keybindings]` 部分。

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

`attach`、`read`、`cat`、`kill` 和 `rename` 的首个参数支持会话名称补全。每次补全都并发查询当前用户所选运行目录中的独立后台，共享 250 毫秒查询期限。新增、重命名和删除会话会即时反映到候选中，无响应后台的会话名称仍然保留。候选按会话名称排序，名称查询独立于 `CREATED` 的显示格式。

帮助和版本选项也支持补全，例如 `imx --ver`、`imx attach --he`。`imx help at` 可以补全命令名称；`imx attach -- -d` 可以补全以连字符开头的会话名称。

`imx read -- -d` 可以补全以连字符开头的只读目标会话名称。

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

多个终端可以同时连接同一个会话。可写连接共享输入，全部连接接收程序输出；只读连接在本地浏览画面和历史。

最近进入会话的可写连接决定终端大小。该连接分离后，由剩余的第一个可写连接决定终端大小；只读连接保留程序的终端尺寸。终端尺寸支持最多 512 列、256 行。

后台为每个连接按屏幕尺寸设置输出队列容量，至少允许 256 KiB，按每个屏幕单元 128 字节计算，最多 16 MiB，内存按需分配。连接保留其经历过的最大容量上限，使窗口缩小时可以继续发送已有输出。超过容量的连接会断开，会话继续运行。

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
| `IMX_SESSION` | 当前会话名称，提示符集成会在重命名后更新此变量 |
| `IMX_SESSION_ID` | imx 自动设置的内部会话标识，供命令在重命名后定位当前会话 |
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

可以在会话内部或外部执行更新。运行中的 shell、程序和历史继续保留；已有后台进程继续使用启动时的版本，新建后台进程使用更新后的版本。下载失败、取消下载、校验失败以及取消 sudo 授权时，原可执行文件和会话保持原状。更新结束或收到 SIGINT、SIGHUP、SIGTERM 时，程序清理下载和解压目录。

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
