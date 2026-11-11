const std = @import("std");
const vaxis = @import("vaxis");
const sys = @import("sys.zig");
const c = sys.c;
const config = @import("config.zig");
const sessions = @import("sessions.zig");
const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const keyboard = @import("keyboard.zig");
const terminal = @import("terminal.zig");
const render = @import("pane_render.zig");
const vt = terminal.vt;
const Stream = @TypeOf(@as(*vt.Terminal, undefined).vtStream());
const frame_interval_ms = 100;
const double_click_interval_ms = 400;

const Selector = struct {
    const Click = struct { index: usize, row: i16, col: i16, time: i64 };
    const Directory = struct {
        path: ?[]const u8 = null,
        query: ?sessions.Query = null,
        deadline: ?i64 = null,
        refresh_pending: bool = false,

        fn deinit(self: *Directory, allocator: std.mem.Allocator) void {
            if (self.path) |path| allocator.free(path);
            if (self.query) |*query| query.deinit(allocator);
        }
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    root: *const config.Config,
    names: [][]const u8 = &.{},
    directories: []Directory = &.{},
    pollfds: std.ArrayList(c.struct_pollfd) = .empty,
    selected: usize = 0,
    first: usize = 0,
    size: sys.Size,
    vx: vaxis.Vaxis,
    term: vt.Terminal,
    stream: Stream = undefined,
    state: render.State = .{},
    cache: render.Cache = .{},
    output: protocol.Queue = .{ .limit = 16 * 1024 * 1024 },
    request: protocol.Queue = .{},
    reader: protocol.Reader = .{},
    frame: std.Io.Writer.Allocating,
    keys: keyboard.Input = .{ .report_events = true },
    fd: c_int = -1,
    next_request: ?i64 = null,
    initial_deadline: ?i64 = null,
    message: ?[]const u8 = null,
    dirty: bool = true,
    repaint: bool = true,
    preview_dirty: bool = false,
    scroll_delta: i32 = 0,
    scroll_changed: bool = false,
    scrolling: bool = false,
    mouse_enabled: bool,
    pressed: ?Click = null,
    last_click: ?Click = null,

    fn freeNames(self: *Selector, names: [][]const u8) void {
        for (names) |name| self.allocator.free(name);
        self.allocator.free(names);
    }

    fn freeDirectories(self: *Selector) void {
        for (self.directories) |*directory| directory.deinit(self.allocator);
        self.allocator.free(self.directories);
        self.directories = &.{};
    }

    fn requestDirectory(self: *Selector, index: usize) !void {
        const directory = &self.directories[index];
        if (directory.query != null) {
            directory.refresh_pending = true;
            return;
        }
        directory.query = sessions.Query.init(self.allocator, self.io, self.root, self.names[index], "{}") catch |err| switch (err) {
            error.SessionNotFound => {
                try self.setDirectory(directory, "Unavailable");
                return;
            },
            else => return err,
        };
        directory.deadline = try sys.monotonicMilliseconds() + 1000;
    }

    fn setDirectory(self: *Selector, directory: *Directory, path: []const u8) !void {
        if (directory.path) |previous| if (std.mem.eql(u8, previous, path)) return;
        const copy = try self.allocator.dupe(u8, path);
        if (directory.path) |previous| self.allocator.free(previous);
        directory.path = copy;
        self.dirty = true;
        self.repaint = true;
    }

    fn finishDirectories(self: *Selector, now: i64) !void {
        for (self.directories, 0..) |*directory, index| if (directory.query) |*query| {
            if (query.state == .pending and now < directory.deadline.?) continue;
            try self.setDirectory(directory, if (query.info) |info| info.directory else "Unavailable");
            query.deinit(self.allocator);
            directory.query = null;
            directory.deadline = null;
            if (directory.refresh_pending) {
                directory.refresh_pending = false;
                try self.requestDirectory(index);
            }
        };
    }

    fn listHeight(self: *const Selector) u16 {
        return @intCast(@min(@max(1, self.size.rows / 3), self.names.len, self.size.rows -| 2));
    }

    fn previewRect(self: *const Selector) ?render.Rect {
        const top = self.listHeight() + 1;
        if (self.size.cols < 6 or self.size.rows < top + 5) return null;
        return .{ .y = top, .width = self.size.cols, .height = self.size.rows - top - 1 };
    }

    fn selectedName(self: *const Selector) ?[]const u8 {
        return if (self.names.len == 0) null else self.names[self.selected];
    }

    fn disconnect(self: *Selector) void {
        if (self.fd >= 0) sys.close(self.fd);
        self.fd = -1;
        self.next_request = null;
        self.initial_deadline = null;
        self.scroll_delta = 0;
        self.scroll_changed = false;
        self.scrolling = false;
        self.request.deinit(self.allocator);
        self.request = .{};
        self.reader.deinit(self.allocator);
        self.reader = .{};
    }

    fn refresh(self: *Selector) !void {
        const names = try sessions.names(self.allocator, self.io, self.root, ".sock");
        var adopted = false;
        defer if (!adopted) self.freeNames(names);
        var same = names.len == self.names.len;
        if (same) for (names, self.names) |a, b| {
            if (!std.mem.eql(u8, a, b)) {
                same = false;
                break;
            }
        };
        if (same) return;
        const directories = try self.allocator.alloc(Directory, names.len);
        @memset(directories, .{});
        const previous_rect = self.previewRect();
        self.resetClicks();
        var selected = @min(self.selected, names.len -| 1);
        var retained = false;
        if (self.selectedName()) |previous| for (names, 0..) |name, index| {
            if (std.mem.eql(u8, previous, name)) {
                selected = index;
                retained = true;
                break;
            }
        };
        self.freeDirectories();
        self.freeNames(self.names);
        self.names = names;
        self.directories = directories;
        adopted = true;
        self.selected = selected;
        self.dirty = true;
        self.repaint = true;
        for (self.names, 0..) |_, index| try self.requestDirectory(index);
        if (!retained) {
            try self.preview();
        } else if (!std.meta.eql(previous_rect, self.previewRect())) try self.fitPreview();
    }

    fn preview(self: *Selector) !void {
        self.preview_dirty = false;
        self.disconnect();
        self.message = null;
        self.dirty = true;
        self.repaint = true;
        self.stream.nextSlice("\x1bc");
        const name = self.selectedName() orelse return;
        try self.requestDirectory(self.selected);
        const rect = self.previewRect() orelse return;
        try self.term.resize(self.allocator, .{ .cols = rect.width - 2, .rows = rect.height - 2 });
        self.fd = connection.openExistingNonblocking(self.io, self.root, name) catch |err| switch (err) {
            error.SessionNotFound, error.BackendTimeout => {
                self.message = @errorName(err);
                return;
            },
            else => return err,
        };
        self.message = "Loading preview...";
        self.initial_deadline = try sys.monotonicMilliseconds() + 1000;
        try self.requestPreview();
    }

    fn requestPreview(self: *Selector) !void {
        const payload = try std.json.Stringify.valueAlloc(self.allocator, protocol.PreviewOptions{
            .name = self.selectedName().?,
            .size = .{ .rows = self.term.rows, .cols = self.term.cols },
        }, .{});
        defer self.allocator.free(payload);
        try self.request.message(self.allocator, .preview, payload);
        self.next_request = null;
    }

    fn requestScroll(self: *Selector) !void {
        const payload = try std.json.Stringify.valueAlloc(self.allocator, protocol.PreviewScroll{
            .size = .{ .rows = self.term.rows, .cols = self.term.cols },
            .delta = self.scroll_delta,
        }, .{});
        defer self.allocator.free(payload);
        try self.request.message(self.allocator, .preview_scroll, payload);
        self.scroll_delta = 0;
        self.scroll_changed = false;
        self.scrolling = true;
    }

    fn receive(self: *Selector) !void {
        const alive = self.reader.receive(self.allocator, self.fd) catch |err| switch (err) {
            error.ConnectionClosed => false,
            else => return err,
        };
        if (!alive) {
            self.message = if (self.scrolling) "Preview scrolling unavailable: session ended or backend does not support it." else "Preview unavailable: session ended or backend does not support previews.";
            self.disconnect();
            self.dirty = true;
            self.repaint = true;
            return;
        }
        while (try self.reader.next()) |message| {
            switch (message.tag) {
                .output => self.stream.nextSlice(message.payload),
                .done => {
                    if (message.payload.len != 0) return error.InvalidMessage;
                    if (self.stream.handler.semantic_failure) return error.TerminalStateFailure;
                    if (self.message != null) self.repaint = true;
                    self.message = null;
                    self.initial_deadline = null;
                    self.next_request = try sys.monotonicMilliseconds() + frame_interval_ms;
                    try self.requestDirectory(self.selected);
                    self.dirty = true;
                },
                .failure => {
                    self.message = if (std.mem.eql(u8, message.payload, "SessionNotFound")) "Session ended." else if (self.scrolling) "Preview scrolling unsupported by this session's backend." else "Preview unsupported by this session's backend.";
                    self.disconnect();
                    self.dirty = true;
                    self.repaint = true;
                    return;
                },
                else => return error.InvalidMessage,
            }
        }
    }

    const Choice = enum { waiting, cancel, attach };

    fn resetClicks(self: *Selector) void {
        self.pressed = null;
        self.last_click = null;
    }

    fn choose(self: *Selector, index: usize) void {
        if (self.selected == index) return;
        self.selected = index;
        self.preview_dirty = true;
    }

    fn mouseIndex(self: *const Selector, mouse: vaxis.Mouse) ?usize {
        if (mouse.col < 0 or mouse.col >= self.size.cols or mouse.row < 1 or mouse.row > self.listHeight()) return null;
        const index = self.first + @as(usize, @intCast(mouse.row - 1));
        return if (index < self.names.len) index else null;
    }

    fn handleMouse(self: *Selector, event: vaxis.Mouse) !Choice {
        if (!self.mouse_enabled) return .waiting;
        if (event.mods.shift or event.mods.alt or event.mods.ctrl or event.type == .drag) {
            self.resetClicks();
            return .waiting;
        }
        const index = self.mouseIndex(event);
        if (event.type == .release and (event.button == .left or event.button == .none)) {
            const pressed = self.pressed orelse return .waiting;
            self.pressed = null;
            if (index != pressed.index or event.row != pressed.row or @abs(@as(i32, event.col) - pressed.col) > 1) {
                self.last_click = null;
                return .waiting;
            }
            if (self.last_click) |previous| {
                if (previous.index == pressed.index and previous.row == pressed.row and
                    @abs(@as(i32, previous.col) - pressed.col) <= 1 and pressed.time - previous.time <= double_click_interval_ms)
                {
                    self.last_click = null;
                    return .attach;
                }
            }
            self.last_click = pressed;
            return .waiting;
        }
        if (event.type != .press) return .waiting;
        if (event.button == .wheel_up or event.button == .wheel_down) {
            self.resetClicks();
            if (!self.preview_dirty and self.fd >= 0) if (self.previewRect()) |rect| {
                if (event.col > rect.x and event.col < rect.x + rect.width - 1 and event.row > rect.y and event.row < rect.y + rect.height - 1) {
                    const delta: i32 = if (event.button == .wheel_up) -3 else 3;
                    if (self.scroll_delta != 0 and (self.scroll_delta < 0) != (delta < 0)) try self.requestScroll();
                    self.scroll_delta +|= delta;
                    self.scroll_changed = true;
                    return .waiting;
                }
            };
        }
        self.pressed = null;
        const target = index orelse {
            self.last_click = null;
            return .waiting;
        };
        if (event.button == .left) {
            self.pressed = .{ .index = target, .row = event.row, .col = event.col, .time = try sys.monotonicMilliseconds() };
            self.choose(target);
        } else {
            self.last_click = null;
            if (event.button == .wheel_up) self.choose(self.selected -| 1);
            if (event.button == .wheel_down) self.choose(@min(self.selected + 1, self.names.len -| 1));
        }
        return .waiting;
    }

    fn input(self: *Selector, result: keyboard.Input.Result) !Choice {
        const event = result.event orelse return .waiting;
        if (event == .mouse) return self.handleMouse(event.mouse);
        if (event == .paste_start) self.resetClicks();
        if (event != .key_press) return .waiting;
        self.resetClicks();
        const key = event.key_press;
        if (key.matchExact(vaxis.Key.escape, .{}) or key.matchExact('q', .{}) or key.matchExact('c', .{ .ctrl = true })) return .cancel;
        if (key.matchExact(vaxis.Key.enter, .{}) or key.matchExact(' ', .{})) return if (self.names.len > 0) .attach else .waiting;
        if (key.matchExact(vaxis.Key.up, .{}) or key.matchExact('k', .{})) self.choose(self.selected -| 1);
        if (key.matchExact(vaxis.Key.down, .{}) or key.matchExact('j', .{})) self.choose(@min(self.selected + 1, self.names.len -| 1));
        return .waiting;
    }

    fn draw(self: *Selector) !void {
        if (self.repaint) self.vx.screen.clear();
        const window = self.vx.window();
        _ = window.printSegment(.{ .text = "Sessions", .style = .{ .bold = true } }, .{ .wrap = .none });
        var name_width: u16 = 0;
        for (self.names) |name| name_width = @max(name_width, @as(u16, @intCast(name.len)));
        // 名称只包含 ASCII；窄窗口为目录保留一半左右的宽度。
        const directory_col = @min(@max(name_width + 4, 9), self.size.cols / 2);
        const show_directory = self.size.cols >= 20;
        if (show_directory) _ = window.printSegment(.{ .text = "Directory", .style = .{ .bold = true } }, .{ .col_offset = directory_col, .wrap = .none });
        const height = self.listHeight();
        self.first = @min(self.first, self.selected);
        if (height > 0 and self.selected >= self.first + height) self.first = self.selected + 1 - height;
        for (self.names[self.first..@min(self.names.len, self.first + height)], self.first..) |name, index| {
            const style: vaxis.Style = .{ .reverse = index == self.selected, .bold = index == self.selected };
            const row: u16 = @intCast(index - self.first + 1);
            const label = window.child(.{ .y_off = row, .height = 1, .width = if (show_directory) directory_col - 2 else self.size.cols });
            _ = label.printSegment(.{ .text = if (index == self.selected) "> " else "  ", .style = style }, .{ .wrap = .none });
            printClipped(label.child(.{ .x_off = 2 }), name, style);
            if (show_directory) {
                const directory = window.child(.{ .x_off = directory_col, .y_off = row, .height = 1 });
                printClipped(directory, self.directories[index].path orelse "Loading...", style);
            }
        }
        if (self.previewRect()) |rect| {
            try self.state.update(self.allocator, &self.term);
            try render.draw(self.allocator, &self.cache, &self.vx.screen, &self.term, &self.state, rect, .{ 0, 0 }, false, false, .default, self.selectedName() orelse "Preview", self.repaint);
            if (self.message) |message| _ = window.printSegment(.{ .text = message }, .{ .row_offset = rect.y + 1, .col_offset = 1, .wrap = .none });
        }
        if (self.names.len == 0 and self.size.rows > 1) _ = window.printSegment(.{ .text = "No sessions." }, .{ .row_offset = 1, .wrap = .none });
        const help = if (self.mouse_enabled) "Click/Wheel: select | Double-click/Enter/Space: attach | Preview wheel: history | Esc/q: cancel" else "Up/Down j/k: select | Enter/Space: attach | Esc/q: cancel";
        _ = window.printSegment(.{ .text = help, .style = .{ .dim = true } }, .{ .row_offset = self.size.rows - 1, .wrap = .none });
        self.vx.screen.cursor_vis = false;
        self.frame.clearRetainingCapacity();
        try self.vx.render(&self.frame.writer);
        try self.output.append(self.allocator, self.frame.written());
        self.dirty = false;
        self.repaint = false;
    }

    fn resize(self: *Selector) !void {
        self.resetClicks();
        self.size = try sys.Size.get(0);
        self.frame.clearRetainingCapacity();
        try self.vx.resize(self.allocator, &self.frame.writer, .{ .cols = self.size.cols, .rows = self.size.rows, .x_pixel = 0, .y_pixel = 0 });
        try self.output.append(self.allocator, self.frame.written());
        try self.fitPreview();
    }

    fn fitPreview(self: *Selector) !void {
        if (self.fd >= 0 and self.scrolling) {
            if (self.previewRect()) |rect| {
                try self.term.resize(self.allocator, .{ .cols = rect.width - 2, .rows = rect.height - 2 });
                self.scroll_changed = true;
            }
            self.dirty = true;
            self.repaint = true;
        } else try self.preview();
    }

    fn loop(self: *Selector, signal: c_int, changes: c_int) !?[]u8 {
        while (true) {
            const now = try sys.monotonicMilliseconds();
            try self.finishDirectories(now);
            if (self.preview_dirty) try self.preview();
            if (self.scroll_changed and self.fd >= 0) try self.requestScroll();
            if (self.keys.deadline) |deadline| if (now >= deadline) {
                if (try self.input(self.keys.expire()) == .cancel) return null;
            };
            if (self.initial_deadline) |deadline| if (now >= deadline) {
                self.message = "Preview is not responding.";
                self.initial_deadline = null;
                self.dirty = true;
                self.repaint = true;
            };
            if (self.output.pending().len == 0) {
                if (self.dirty) try self.draw();
                if (self.previewRect() != null) if (self.next_request) |deadline| if (now >= deadline) try self.requestPreview();
            }
            var deadline = self.keys.deadline;
            for (self.directories) |directory| if (directory.deadline) |value| {
                deadline = @min(deadline orelse value, value);
            };
            if (self.initial_deadline) |value| deadline = @min(deadline orelse value, value);
            if (self.output.pending().len == 0 and self.previewRect() != null) if (self.next_request) |value| {
                deadline = @min(deadline orelse value, value);
            };
            try self.pollfds.resize(self.allocator, 5 + self.directories.len);
            const fds = self.pollfds.items;
            fds[0..5].* = .{
                .{ .fd = 0, .events = c.POLLIN, .revents = 0 },
                .{ .fd = 1, .events = if (self.output.pending().len > 0) c.POLLOUT else 0, .revents = 0 },
                .{ .fd = signal, .events = c.POLLIN, .revents = 0 },
                .{ .fd = changes, .events = c.POLLIN, .revents = 0 },
                .{ .fd = self.fd, .events = @as(c_short, c.POLLIN) | @as(c_short, if (self.request.pending().len > 0) c.POLLOUT else 0), .revents = 0 },
            };
            for (self.directories, fds[5..]) |directory, *event| {
                event.* = if (directory.query) |query| query.pollEvent() else .{ .fd = -1, .events = 0, .revents = 0 };
            }
            const count = c.poll(fds.ptr, @intCast(fds.len), if (deadline) |value| @intCast(@max(0, value - now)) else -1);
            if (count < 0 and c.__errno_location().* == c.EINTR) continue;
            _ = try sys.check(count, "poll(select)");
            if (fds[2].revents & c.POLLIN != 0) {
                var info: c.struct_signalfd_siginfo = undefined;
                while ((try sys.read(signal, std.mem.asBytes(&info))) != null) {
                    if (info.ssi_signo != c.SIGWINCH) return null;
                    try self.resize();
                }
                continue;
            }
            if (fds[3].revents & c.POLLIN != 0) {
                var buffer: [4096]u8 = undefined;
                while ((try sys.read(changes, &buffer)) != null) {}
                try self.refresh();
                continue;
            }
            if (fds[0].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) {
                var buffer: [keyboard.Input.read_size]u8 = undefined;
                if (try sys.readPty(0, &buffer)) |n| {
                    if (n == 0) return null;
                    for (buffer[0..n]) |byte| switch (try self.input(try self.keys.feed(&.{byte}, try sys.monotonicMilliseconds()))) {
                        .waiting => {},
                        .cancel => return null,
                        .attach => return try self.allocator.dupe(u8, self.selectedName().?),
                    };
                }
                continue;
            }
            for (self.directories, fds[5..]) |*directory, event| {
                if (directory.query) |*query| try query.update(self.allocator, event);
            }
            if (fds[4].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) try self.receive();
            if (self.fd >= 0 and fds[4].revents & c.POLLOUT != 0) self.request.flush(self.fd, true) catch |err| switch (err) {
                error.ConnectionClosed => {
                    self.disconnect();
                    self.message = "Session disconnected.";
                    self.dirty = true;
                    self.repaint = true;
                },
                else => return err,
            };
            if (fds[1].revents & c.POLLOUT != 0) try self.output.flush(1, false);
            if (fds[1].revents & (c.POLLHUP | c.POLLERR) != 0) return null;
        }
    }
};

fn printClipped(window: vaxis.Window, text: []const u8, style: vaxis.Style) void {
    if (window.width == 0) return;
    const measured = window.printSegment(.{ .text = text }, .{ .wrap = .none, .commit = false });
    if (!measured.overflow and measured.col <= window.width) {
        _ = window.printSegment(.{ .text = text, .style = style }, .{ .wrap = .none });
        return;
    }
    var graphemes = vaxis.unicode.graphemeIterator(text);
    var end: usize = 0;
    var columns: u16 = 0;
    while (graphemes.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width = window.gwidth(bytes);
        if (width > window.width - 1 - columns) break;
        columns += width;
        end += bytes.len;
    }
    _ = window.printSegment(.{ .text = text[0..end], .style = style }, .{ .wrap = .none });
    _ = window.printSegment(.{ .text = "…", .style = style }, .{ .col_offset = window.width - 1, .wrap = .none });
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, mouse_enabled: bool) !?[]u8 {
    if (c.isatty(0) == 0 or c.isatty(1) == 0) return error.TerminalRequired;
    const size = try sys.Size.get(0);
    var root = (try config.Config.openExisting(allocator, io)) orelse {
        try sys.writeAll(1, "No sessions.\n", false);
        return null;
    };
    defer root.deinit();
    if (try root.connectNonblocking()) |legacy| {
        sys.close(legacy);
        return error.SelectUnsupportedByBackend;
    }
    const changes = try sys.check(c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC), "inotify_init1(select)");
    defer sys.close(changes);
    var path: [64]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&path, "/proc/self/fd/{d}", .{root.dir_fd}, 0);
    _ = try sys.check(c.inotify_add_watch(changes, directory, c.IN_CREATE | c.IN_DELETE | c.IN_MOVED_FROM | c.IN_MOVED_TO | c.IN_DELETE_SELF | c.IN_MOVE_SELF), "inotify_add_watch(select)");
    var environment = try environ.createMap(allocator);
    defer environment.deinit();
    var app: Selector = .{
        .allocator = allocator,
        .io = io,
        .root = &root,
        .size = size,
        .vx = try vaxis.init(io, allocator, &environment, .{}),
        .term = try vt.Terminal.init(io, allocator, .{ .cols = 1, .rows = 1, .max_scrollback_lines = 0, .max_scrollback_bytes = 0 }),
        .frame = .init(allocator),
        .mouse_enabled = mouse_enabled,
    };
    app.stream = app.term.vtStream();
    defer {
        app.disconnect();
        app.stream.deinit();
        app.term.deinit(allocator);
        app.state.deinit(allocator);
        app.cache.deinit(allocator);
        app.freeDirectories();
        app.freeNames(app.names);
        app.pollfds.deinit(allocator);
        app.output.deinit(allocator);
        app.frame.clearRetainingCapacity();
        app.vx.deinit(allocator, &app.frame.writer);
        app.frame.deinit();
    }
    try app.refresh();
    if (app.names.len == 0) {
        try sys.writeAll(1, "No sessions.\n", false);
        return null;
    }
    const signals = try sys.signalFd(&.{ c.SIGWINCH, c.SIGHUP, c.SIGTERM, c.SIGINT });
    defer sys.close(signals);
    defer sys.unblockSignals() catch @panic("failed to restore selector signals");
    var saved: c.struct_termios = undefined;
    _ = try sys.check(c.tcgetattr(0, &saved), "tcgetattr(select)");
    var raw = saved;
    c.cfmakeraw(&raw);
    _ = try sys.check(c.tcsetattr(0, c.TCSANOW, &raw), "tcsetattr(select)");
    defer _ = c.tcsetattr(0, c.TCSANOW, &saved);
    const input_flags = try sys.nonblocking(0, true);
    defer _ = c.fcntl(0, c.F_SETFL, input_flags);
    const output_flags = try sys.nonblocking(1, true);
    defer _ = c.fcntl(1, c.F_SETFL, output_flags);
    // 成对保存终端模式，使取消选择可以恢复原有提示符和鼠标设置。
    const begin = "\x1b[?1000;1002;1003;1006;2004s\x1b[?1000;1002;1003;1006l\x1b[?1049h\x1b[?2004h\x1b[>1u";
    const finish = "\x1b[?2026l\x1b[0m\x1b[?25h\x1b[<u\x1b[?1049l\x1b[?1000;1002;1003;1006;2004r";
    try writeTerminal(begin);
    defer {
        writeTerminal(finish) catch {};
    }
    if (app.mouse_enabled) try writeTerminal("\x1b[?1000h\x1b[?1006h");
    app.vx.state.alt_screen = true;
    app.vx.caps.rgb = true;
    try app.resize();
    return app.loop(signals, changes);
}

fn writeTerminal(bytes: []const u8) !void {
    const deadline = try sys.monotonicMilliseconds() + 100;
    var offset: usize = 0;
    while (offset < bytes.len) {
        offset += try sys.write(1, bytes[offset..], false);
        if (offset == bytes.len) return;
        const remaining = deadline - try sys.monotonicMilliseconds();
        if (remaining <= 0) return error.TerminalOutputBlocked;
        var event: c.struct_pollfd = .{ .fd = 1, .events = c.POLLOUT, .revents = 0 };
        if (c.poll(&event, 1, @intCast(remaining)) < 0 and c.__errno_location().* != c.EINTR) return sys.failure("poll(select terminal)");
        if (event.revents & (c.POLLHUP | c.POLLERR) != 0) return error.ConnectionClosed;
    }
}
