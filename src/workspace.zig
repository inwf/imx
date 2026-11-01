const std = @import("std");
const vaxis = @import("vaxis");
const vt = @import("ghostty-vt");
const sys = @import("sys.zig");
const c = sys.c;
const config = @import("config.zig");
const protocol = @import("protocol.zig");
const keyboard = @import("keyboard.zig");
const terminal = @import("terminal.zig");
const display = @import("display.zig");
const context = @import("pane_context.zig");
const render = @import("pane_render.zig");
const selection = @import("pane_selection.zig");
const Rect = render.Rect;
const Stream = @TypeOf(@as(*vt.Terminal, undefined).vtStream());
const Handler = @FieldType(Stream, "handler");
const Axis = enum { right, down };
const Direction = enum { left, right, up, down };

const CloseRequest = struct {
    fd: c_int,
    input: protocol.Queue = .{},
    reader: protocol.Reader = .{},

    fn deinit(self: *CloseRequest, allocator: std.mem.Allocator) void {
        sys.close(self.fd);
        self.input.deinit(allocator);
        self.reader.deinit(allocator);
    }
};

const Node = struct {
    rect: Rect,
    content: union(enum) {
        pane: *Pane,
        split: struct {
            axis: Axis,
            first: *Node,
            second: *Node,
            ratio: struct { first: u16 = 1, total: u16 = 2 } = .{},
        },
    },

    fn minimum(self: *const Node) sys.Size {
        return switch (self.content) {
            .pane => .{ .cols = 12, .rows = 5 },
            .split => |split| blk: {
                const a = split.first.minimum();
                const b = split.second.minimum();
                break :blk if (split.axis == .right) .{ .cols = a.cols + b.cols, .rows = @max(a.rows, b.rows) } else .{ .cols = @max(a.cols, b.cols), .rows = a.rows + b.rows };
            },
        };
    }

    fn arrange(self: *Node, rect: Rect) void {
        self.rect = rect;
        switch (self.content) {
            .pane => |pane| pane.rect = rect,
            .split => |split| {
                var first = rect;
                var second = rect;
                const a = split.first.minimum();
                const b = split.second.minimum();
                if (split.axis == .right) {
                    first.width = std.math.clamp(@as(u16, @intCast(@as(u32, rect.width) * split.ratio.first / split.ratio.total)), a.cols, rect.width - b.cols);
                    second.x += first.width;
                    second.width -= first.width;
                } else {
                    first.height = std.math.clamp(@as(u16, @intCast(@as(u32, rect.height) * split.ratio.first / split.ratio.total)), a.rows, rect.height - b.rows);
                    second.y += first.height;
                    second.height -= first.height;
                }
                split.first.arrange(first);
                split.second.arrange(second);
            },
        }
    }

    fn separator(self: *Node, x: i32, y: i32) ?*Node {
        if (!self.rect.contains(x, y)) return null;
        return switch (self.content) {
            .pane => null,
            .split => |split| blk: {
                const coordinate = if (split.axis == .right) x else y;
                const boundary = if (split.axis == .right) split.second.rect.x else split.second.rect.y;
                if (coordinate == boundary or coordinate == @as(i32, boundary) - 1) break :blk self;
                break :blk split.first.separator(x, y) orelse split.second.separator(x, y);
            },
        };
    }

    fn resizeTo(self: *Node, x: i32, y: i32, grab_offset: i32) bool {
        const split = &self.content.split;
        const horizontal = split.axis == .right;
        const a = split.first.minimum();
        const b = split.second.minimum();
        const total = if (horizontal) self.rect.width else self.rect.height;
        const desired = (if (horizontal) x - self.rect.x else y - self.rect.y) - grab_offset;
        const first: u16 = @intCast(std.math.clamp(desired, if (horizontal) a.cols else a.rows, total - (if (horizontal) b.cols else b.rows)));
        if (first == (if (horizontal) split.first.rect.width else split.first.rect.height)) return false;
        split.ratio = .{ .first = first, .total = total };
        return true;
    }

    fn find(self: *Node, pane: *Pane) ?*Node {
        return switch (self.content) {
            .pane => |value| if (value == pane) self else null,
            .split => |split| split.first.find(pane) orelse split.second.find(pane),
        };
    }

    fn remove(self: *Node, allocator: std.mem.Allocator, pane: *Pane) bool {
        switch (self.content) {
            .pane => |value| return value == pane,
            .split => |split| {
                const gone, const kept = if (split.first.remove(allocator, pane)) .{ split.first, split.second } else if (split.second.remove(allocator, pane)) .{ split.second, split.first } else return false;
                self.content = kept.content;
                allocator.destroy(gone);
                allocator.destroy(kept);
                return false;
            },
        }
    }

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        if (self.content == .split) {
            self.content.split.first.deinit(allocator);
            self.content.split.second.deinit(allocator);
        }
        allocator.destroy(self);
    }
};

const Pane = struct {
    app: *App,
    id: usize,
    pid: c.pid_t = 0,
    exit_status: ?c_int = null,
    fd: c_int = -1,
    listener: c_int,
    control: ?c_int = null,
    attached: ?std.json.Parsed(context.State) = null,
    address: []u8,
    cwd: []u8,
    initial: bool,
    rect: Rect,
    term: vt.Terminal,
    stream: Stream,
    state: vt.RenderState = .empty,
    selection: selection.State = .{},
    hold_until: ?i64 = null,
    input: protocol.Queue = .{},
    detaching: bool = false,
    close_requested: bool = false,
    closing: ?CloseRequest = null,

    fn deinit(self: *Pane) void {
        const allocator = self.app.allocator;
        if (self.fd >= 0) sys.close(self.fd);
        if (self.pid != 0) @import("server.zig").terminateSession(self.pid) catch @panic("failed to terminate pane processes");
        if (self.control) |fd| sys.close(fd);
        if (self.attached) |state| state.deinit();
        if (self.closing) |*request| request.deinit(allocator);
        sys.close(self.listener);
        self.stream.deinit();
        self.selection.deinit(&self.term);
        self.term.deinit(allocator);
        self.state.deinit(allocator);
        self.input.deinit(allocator);
        allocator.free(self.address);
        allocator.free(self.cwd);
        allocator.destroy(self);
    }

    fn spawn(self: *Pane, session: ?[]const u8) !void {
        const app = self.app;
        const allocator = app.allocator;
        var environment = try app.environ.createMap(allocator);
        defer environment.deinit();
        _ = environment.swapRemove("IMX_SESSION");
        try environment.put(context.variable, self.address);
        var envp: std.ArrayList(?[*:0]const u8) = .empty;
        defer {
            for (envp.items) |entry| if (entry) |value| allocator.free(std.mem.span(value));
            envp.deinit(allocator);
        }
        var iterator = environment.iterator();
        while (iterator.next()) |entry| try envp.append(allocator, (try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }, 0)).ptr);
        try envp.append(allocator, null);
        const shell = config.env("SHELL") orelse "/bin/sh";
        const executable = try allocator.dupeSentinel(u8, if (session != null) app.executable else shell, 0);
        defer allocator.free(executable);
        const cwd = try allocator.dupeSentinel(u8, self.cwd, 0);
        defer allocator.free(cwd);
        const name = try allocator.dupeSentinel(u8, session orelse "", 0);
        defer allocator.free(name);
        const attach_argv = [_:null]?[*:0]const u8{ executable, "attach", "--", name };
        const shell_argv = [_:null]?[*:0]const u8{ executable, "-l" };
        var ready: [2]c_int = undefined;
        _ = try sys.check(c.pipe2(&ready, c.O_CLOEXEC), "pipe2(pane readiness)");
        defer sys.close(ready[0]);
        var size: c.struct_winsize = .{ .ws_row = self.term.rows, .ws_col = self.term.cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        const pid = try sys.check(c.forkpty(&self.fd, null, &app.termios, &size), "forkpty(pane)");
        if (pid == 0) {
            sys.close(ready[0]);
            if (c.dup3(ready[1], 3, c.O_CLOEXEC) < 0) c._exit(126);
            if (std.os.linux.errno(std.os.linux.close_range(4, std.math.maxInt(c_int), .{ .UNSHARE = false, .CLOEXEC = false })) != .SUCCESS) c._exit(126);
            sys.unblockSignals() catch c._exit(126);
            if (c.chdir(cwd) == 0) _ = c.execve(executable, @ptrCast(if (session != null) &attach_argv else &shell_argv), @ptrCast(envp.items.ptr));
            const failure = c.__errno_location().*;
            _ = c.write(3, &failure, @sizeOf(c_int));
            c._exit(126);
        }
        sys.close(ready[1]);
        self.pid = pid;
        self.exit_status = null;
        errdefer {
            sys.close(self.fd);
            self.fd = -1;
            @import("server.zig").terminateSession(pid) catch @panic("failed to clean up pane process");
            self.pid = 0;
        }
        var failure: c_int = undefined;
        if ((try sys.read(ready[0], std.mem.asBytes(&failure))).? != 0) return error.PaneExecFailed;
        _ = try sys.nonblocking(self.fd, true);
        _ = try sys.check(c.fcntl(self.fd, c.F_SETFD, c.FD_CLOEXEC), "fcntl(pane)");
    }

    fn directory(self: *Pane) ![]u8 {
        const app = self.app;
        var pid = self.pid;
        if (self.attached) |state| {
            var root = try config.Config.initPath(app.allocator, app.io, state.value.directory);
            defer root.deinit();
            const fd = try @import("connection.zig").open(app.allocator, app.io, &root, state.value.session, false);
            defer sys.close(fd);
            try protocol.send(fd, .info, "{}");
            var reader: protocol.Reader = .{};
            defer reader.deinit(app.allocator);
            var bytes: std.ArrayList(u8) = .empty;
            defer bytes.deinit(app.allocator);
            while (try reader.receive(app.allocator, fd)) {
                while (try reader.next()) |message| switch (message.tag) {
                    .ok => {},
                    .output => try bytes.appendSlice(app.allocator, message.payload),
                    .done => break,
                    .failure => return error.SessionDirectoryUnavailable,
                    else => return error.InvalidMessage,
                };
            }
            const info = try std.json.parseFromSlice(protocol.SessionInfo, app.allocator, bytes.items, .{});
            defer info.deinit();
            pid = info.value.pid;
        }
        var path: [64]u8 = undefined;
        const link = try std.fmt.bufPrint(&path, "/proc/{d}/cwd", .{pid});
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const length = try std.Io.Dir.readLinkAbsolute(app.io, link, &buffer);
        return app.allocator.dupe(u8, buffer[0..length]);
    }

    fn rememberDirectory(self: *Pane) !void {
        const path = try self.directory();
        self.app.allocator.free(self.cwd);
        self.cwd = path;
    }

    fn closeSession(self: *Pane, state: context.State) !void {
        const app = self.app;
        var root = try config.Config.initPath(app.allocator, app.io, state.directory);
        defer root.deinit();
        const fd = @import("connection.zig").open(app.allocator, app.io, &root, state.session, false) catch |err| switch (err) {
            error.SessionNotFound => return,
            else => return err,
        };
        var request: CloseRequest = .{ .fd = fd };
        errdefer request.deinit(app.allocator);
        _ = try sys.nonblocking(fd, true);
        try request.input.message(app.allocator, .kill, state.session);
        self.closing = request;
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    executable: []const u8,
    termios: c.struct_termios,
    size: sys.Size,
    panes: std.ArrayList(*Pane) = .empty,
    next_id: usize = 1,
    root: *Node = undefined,
    focused: *Pane = undefined,
    mouse_pane: ?*Pane = null,
    resize_drag: ?struct { node: ?*Node, grab_offset: i32 } = null,
    selection_drag: ?struct { pane: ?*Pane } = null,
    composed: bool = false,
    dirty: bool = false,
    offset: [2]u16 = .{ 0, 0 },
    vx: vaxis.Vaxis,
    focused_border_color: vaxis.Color,
    output: protocol.Queue = .{ .limit = 16 * 1024 * 1024 },
    keys: keyboard.Input,
    keyboard_flags: u5 = 5,
    status: ?[]u8 = null,

    fn create(self: *App, cwd: []const u8, size: sys.Size, session: ?[]const u8) !*Pane {
        try self.panes.ensureUnusedCapacity(self.allocator, 1);
        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);
        const address = try std.fmt.allocPrint(self.allocator, "imx-{d}-{d}", .{ c.getpid(), self.next_id });
        errdefer self.allocator.free(address);
        const path = try self.allocator.dupe(u8, cwd);
        errdefer self.allocator.free(path);
        const listener = try context.listen(address);
        errdefer sys.close(listener);
        pane.* = .{ .app = self, .id = self.next_id, .listener = listener, .address = address, .cwd = path, .initial = session != null, .rect = .{ .width = size.cols, .height = size.rows }, .term = try terminal.init(self.allocator, self.io, size), .stream = undefined };
        pane.stream = pane.term.vtStream();
        errdefer {
            pane.stream.deinit();
            pane.term.deinit(self.allocator);
        }
        if (self.composed) enableEffects(pane);
        try pane.spawn(session);
        self.panes.appendAssumeCapacity(pane);
        self.next_id += 1;
        return pane;
    }

    fn arrange(self: *App) !void {
        const minimum = self.root.minimum();
        const canvas: Rect = .{ .width = @max(self.size.cols, minimum.cols), .height = @max(self.size.rows, minimum.rows) };
        self.root.arrange(canvas);
        const active = self.focused.rect;
        const dragging = if (self.resize_drag) |drag| drag.node != null else false;
        self.offset = .{
            @min(if (dragging) self.offset[0] else active.x, canvas.width - self.size.cols),
            @min(if (dragging) self.offset[1] else active.y, canvas.height - self.size.rows),
        };
        for (self.panes.items) |pane| {
            const size: sys.Size = .{ .cols = pane.rect.width - 2, .rows = pane.rect.height - 2 };
            if (pane.term.cols != size.cols or pane.term.rows != size.rows) {
                if (pane.fd >= 0) try size.set(pane.fd);
                try pane.stream.handler.resize(.{ .cols = size.cols, .rows = size.rows });
            }
        }
        self.dirty = true;
    }

    fn focus(self: *App, pane: *Pane) !void {
        if (self.focused == pane) return;
        self.cancelResize();
        self.cancelSelection();
        if (self.focused.term.modes.get(.focus_event)) try self.focused.input.append(self.allocator, "\x1b[O");
        self.focused = pane;
        if (pane.term.modes.get(.focus_event)) try pane.input.append(self.allocator, "\x1b[I");
        try self.arrange();
    }

    fn focusDirection(self: *App, direction: Direction) !void {
        if (!self.composed) return;
        const active = self.focused.rect;
        const horizontal = direction == .left or direction == .right;
        const backward = direction == .left or direction == .up;
        const start: i32 = if (horizontal) active.x else active.y;
        const end = start + @as(i32, if (horizontal) active.width else active.height);
        const cross_start: i32 = if (horizontal) active.y else active.x;
        const cross_end = cross_start + @as(i32, if (horizontal) active.height else active.width);
        const center = cross_start + cross_end;
        var target: ?*Pane = null;
        var best: [3]u32 = @splat(std.math.maxInt(u32));
        for (self.panes.items) |pane| {
            if (pane == self.focused) continue;
            const rect = pane.rect;
            const other_start: i32 = if (horizontal) rect.x else rect.y;
            const other_end = other_start + @as(i32, if (horizontal) rect.width else rect.height);
            const gap = if (backward) start - other_end else other_start - end;
            const other_cross_start: i32 = if (horizontal) rect.y else rect.x;
            const other_cross_end = other_cross_start + @as(i32, if (horizontal) rect.height else rect.width);
            if (gap < 0 or other_cross_start >= cross_end or other_cross_end <= cross_start) continue;
            const score: [3]u32 = .{
                @intCast(gap),
                @intCast(@max(0, @max(other_cross_start * 2 - center, center - other_cross_end * 2))),
                @abs(center - other_cross_start - other_cross_end),
            };
            if (std.mem.order(u32, &score, &best) == .lt) {
                best = score;
                target = pane;
            }
        }
        if (target) |pane| try self.focus(pane);
    }

    fn focusNumber(self: *App, number: usize) !void {
        if (!self.composed) return;
        for (self.panes.items) |pane| {
            if (pane.id == number) return self.focus(pane);
        }
    }

    fn remove(self: *App, index: usize) !void {
        self.cancelResize();
        self.cancelSelection();
        const pane = self.panes.items[index];
        if (self.panes.items.len > 1) _ = self.root.remove(self.allocator, pane);
        _ = self.panes.orderedRemove(index);
        if (self.mouse_pane == pane) self.mouse_pane = null;
        if (self.panes.items.len > 0 and self.focused == pane) self.focused = self.panes.items[@min(index, self.panes.items.len - 1)];
        pane.deinit();
        if (self.panes.items.len > 0) try self.arrange();
    }

    fn closeRequested(self: *App) !void {
        for (self.panes.items, 0..) |pane, index| {
            if (!pane.close_requested or pane.closing != null or pane.detaching) continue;
            if (pane.attached) |state| {
                try pane.closeSession(state.value);
                if (pane.closing != null) continue;
            } else if (pane.initial and pane.exit_status == null) continue;
            try self.remove(index);
            break;
        }
    }

    fn split(self: *App, axis: Axis) !void {
        const selected = self.focused;
        const rect = if (self.composed) selected.rect else Rect{ .width = self.size.cols, .height = self.size.rows };
        if (rect.width > self.size.cols or rect.height > self.size.rows or rect.width < (if (axis == .right) @as(u16, 24) else 12) or rect.height < (if (axis == .down) @as(u16, 10) else 5)) {
            try self.message("Not enough space to split this pane.");
            return;
        }
        try selected.rememberDirectory();
        const node = self.root.find(selected).?;
        const first = try self.allocator.create(Node);
        errdefer self.allocator.destroy(first);
        const second = try self.allocator.create(Node);
        errdefer self.allocator.destroy(second);
        const pane = try self.create(selected.cwd, .{ .cols = rect.width - 2, .rows = rect.height - 2 }, null);
        first.* = .{ .rect = rect, .content = .{ .pane = selected } };
        second.* = .{ .rect = rect, .content = .{ .pane = pane } };
        self.cancelResize();
        self.cancelSelection();
        node.content = .{ .split = .{ .axis = axis, .first = first, .second = second } };
        if (!self.composed) {
            self.composed = true;
            for (self.panes.items) |value| enableEffects(value);
            try self.output.append(self.allocator, display.reset ++ "\x1b[?1049h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[>4;2m\x1b[>5u");
            self.vx.state.alt_screen = true;
            var writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer writer.deinit();
            try self.vx.resize(self.allocator, &writer.writer, .{ .cols = self.size.cols, .rows = self.size.rows, .x_pixel = 0, .y_pixel = 0 });
            try self.output.append(self.allocator, writer.written());
        }
        try self.focus(pane);
    }

    fn message(self: *App, text: []const u8) !void {
        if (self.status) |value| self.allocator.free(value);
        self.status = try self.allocator.dupe(u8, text);
        if (self.composed) self.dirty = true else try self.output.append(self.allocator, "\x07");
    }

    fn draw(self: *App) !void {
        const flags = self.focused.term.screens.active.kitty_keyboard.current().int() | @as(u5, 5);
        if (flags != self.keyboard_flags) {
            var buffer: [16]u8 = undefined;
            try self.output.append(self.allocator, try std.fmt.bufPrint(&buffer, "\x1b[={d}u", .{flags}));
            self.keyboard_flags = flags;
        }
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const frame = arena.allocator();
        self.vx.screen.clear();
        for (self.panes.items) |pane| {
            const title = try std.fmt.allocPrint(frame, " {d}: {s} ", .{ pane.id, if (pane.attached) |state| state.value.session else "shell" });
            if (pane.hold_until == null) try pane.state.update(self.allocator, &pane.term);
            try render.draw(frame, &self.vx.screen, &pane.term, &pane.state, pane.rect, self.offset, pane == self.focused, self.focused_border_color, title);
        }
        if (self.status) |text| for (text[0..@min(text.len, self.size.cols)], 0..) |_, col| self.vx.screen.writeCell(@intCast(col), self.size.rows - 1, .{ .char = .{ .grapheme = text[col..][0..1] }, .style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 3 } } });
        var writer: std.Io.Writer.Allocating = .init(frame);
        try self.vx.render(&writer.writer);
        try self.output.append(self.allocator, writer.written());
        self.dirty = false;
    }

    fn input(self: *App, result: keyboard.Input.Result) !void {
        const pane = self.focused;
        if (result.event) |event| if (event == .mouse and self.composed) return self.handleMouse(event.mouse);
        if (result.action) |action| {
            if (result.bytes.len != 0 and !pane.close_requested) try pane.input.append(self.allocator, result.bytes);
            switch (action) {
                .focus_left => return self.focusDirection(.left),
                .focus_right => return self.focusDirection(.right),
                .focus_up => return self.focusDirection(.up),
                .focus_down => return self.focusDirection(.down),
                .focus_1, .focus_2, .focus_3, .focus_4, .focus_5, .focus_6, .focus_7, .focus_8, .focus_9, .focus_10 => return self.focusNumber(@backingInt(action) - @backingInt(keyboard.Action.focus_1) + 1),
                else => {},
            }
            if (pane.close_requested) return;
            switch (action) {
                .split_right => try self.split(.right),
                .split_down => try self.split(.down),
                .close_pane => pane.close_requested = true,
                else => unreachable,
            }
            return;
        }
        if (pane.close_requested) return;
        if (result.event) |event| {
            if (event == .key_press and pane.attached != null and pane.attached.?.value.detach.matches(event.key_press, result.bytes)) {
                pane.detaching = true;
                return pane.input.append(self.allocator, result.bytes);
            }
        }
        if (!self.composed) return pane.input.append(self.allocator, result.bytes);
        if (result.event) |event| switch (event) {
            .paste_start, .paste_end => {
                if (event == .paste_start) {
                    self.cancelSelection();
                    pane.selection.cancel(&pane.term);
                    pane.term.screens.active.clearSelection();
                    self.dirty = true;
                }
                if (pane.term.modes.get(.bracketed_paste)) try pane.input.append(self.allocator, result.bytes);
                return;
            },
            .key_press, .key_release => {
                const key = if (event == .key_press) event.key_press else event.key_release;
                if (event == .key_press) {
                    self.cancelSelection();
                    pane.selection.cancel(&pane.term);
                    pane.term.screens.active.clearSelection();
                    pane.term.scrollViewport(.bottom);
                }
                var writer: std.Io.Writer.Allocating = .init(self.allocator);
                defer writer.deinit();
                try encodeKey(&writer.writer, key, event == .key_release, &pane.term);
                try pane.input.append(self.allocator, writer.written());
                self.dirty = true;
                return;
            },
            .focus_in, .focus_out => {
                if (event == .focus_out) {
                    self.cancelResize();
                    self.cancelSelection();
                }
                if (pane.term.modes.get(.focus_event)) try pane.input.append(self.allocator, result.bytes);
                return;
            },
            else => return,
        };
        try pane.input.append(self.allocator, result.bytes);
    }

    fn cancelResize(self: *App) void {
        if (self.resize_drag) |*drag| drag.node = null;
    }

    fn cancelSelection(self: *App) void {
        if (self.selection_drag) |*drag| {
            if (drag.pane) |pane| pane.selection.cancel(&pane.term);
            drag.pane = null;
        }
    }

    fn copySelection(self: *App, pane: *Pane) !void {
        const screen = pane.term.screens.active;
        const sel = screen.selection orelse return;
        const text = try screen.selectionString(self.allocator, .{ .sel = sel });
        defer self.allocator.free(text);
        if (text.len == 0) return;
        const encoder = std.base64.standard.Encoder;
        const encoded = try self.allocator.alloc(u8, encoder.calcSize(text.len));
        defer self.allocator.free(encoded);
        try self.output.append(self.allocator, "\x1b]52;c;");
        try self.output.append(self.allocator, encoder.encode(encoded, text));
        try self.output.append(self.allocator, "\x1b\\");
    }

    fn handleMouse(self: *App, mouse: vaxis.Mouse) !void {
        const x: i32 = @as(i32, mouse.col) + self.offset[0];
        const y: i32 = @as(i32, mouse.row) + self.offset[1];
        if (mouse.type == .press and mouse.button == .left) {
            self.resize_drag = null;
            self.cancelSelection();
            self.selection_drag = null;
            if (self.root.separator(x, y)) |node| {
                const divider = node.content.split;
                self.mouse_pane = null;
                self.resize_drag = .{ .node = node, .grab_offset = if (divider.axis == .right) x - divider.second.rect.x else y - divider.second.rect.y };
                return;
            }
        }
        if (self.resize_drag) |drag| {
            const released = mouse.type == .release and (mouse.button == .left or mouse.button == .none);
            if ((mouse.type == .drag and mouse.button == .left) or released) {
                if (drag.node) |node| if (node.resizeTo(x, y, drag.grab_offset)) try self.arrange();
                if (released) {
                    self.resize_drag = null;
                    try self.arrange();
                }
            }
            return;
        }
        if (self.selection_drag) |drag| {
            const released = mouse.type == .release and (mouse.button == .left or mouse.button == .none);
            if (drag.pane) |pane| {
                const px = x - pane.rect.x - 1;
                const py = y - pane.rect.y - 1;
                const now = try sys.monotonicMilliseconds();
                if (released) {
                    if (try pane.selection.release(&pane.term, px, py, now)) try self.copySelection(pane);
                } else if (mouse.type == .drag and mouse.button == .left) {
                    try pane.selection.move(&pane.term, px, py, now);
                }
                self.dirty = true;
            }
            if (released) self.selection_drag = null;
            return;
        }
        const captured = if (mouse.type == .drag or mouse.type == .release) self.mouse_pane else null;
        if (mouse.type == .release) self.mouse_pane = null;
        for (self.panes.items) |pane| {
            if (captured) |target| {
                if (pane != target) continue;
            } else if (!pane.rect.contains(x, y)) continue;
            if (mouse.type == .press and (mouse.button == .left or mouse.button == .middle or mouse.button == .right)) self.mouse_pane = pane;
            if (mouse.type == .press and mouse.button == .left) try self.focus(pane);
            if (mouse.type == .press and mouse.button == .left and (pane.term.flags.mouse_event == .none or mouse.mods.shift)) {
                self.mouse_pane = null;
                const px = x - pane.rect.x - 1;
                const py = y - pane.rect.y - 1;
                if (px >= 0 and py >= 0 and px < pane.term.cols and py < pane.term.rows) {
                    try pane.selection.press(&pane.term, self.io, px, py);
                    self.selection_drag = .{ .pane = pane };
                    self.dirty = true;
                }
                return;
            }
            if (pane.term.flags.mouse_event == .none and (mouse.button == .wheel_up or mouse.button == .wheel_down)) {
                pane.term.scrollViewport(.{ .delta = if (mouse.button == .wheel_up) -3 else 3 });
                self.dirty = true;
                return;
            }
            var writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer writer.deinit();
            var options = vt.input.MouseEncodeOptions.fromTerminal(&pane.term, .{ .screen = .{ .width = pane.term.cols, .height = pane.term.rows }, .cell = .{ .width = 1, .height = 1 }, .padding = .{} });
            options.any_button_pressed = mouse.type == .press or mouse.type == .drag;
            try vt.input.encodeMouse(&writer.writer, .{
                .action = switch (mouse.type) {
                    .press => .press,
                    .release => .release,
                    .motion, .drag => .motion,
                },
                .button = switch (mouse.button) {
                    .left => .left,
                    .middle => .middle,
                    .right => .right,
                    .wheel_up => .four,
                    .wheel_down => .five,
                    .wheel_left => .six,
                    .wheel_right => .seven,
                    else => null,
                },
                .mods = .{ .shift = mouse.mods.shift, .ctrl = mouse.mods.ctrl, .alt = mouse.mods.alt },
                .pos = .{ .x = @floatFromInt(x - pane.rect.x - 1), .y = @floatFromInt(y - pane.rect.y - 1) },
            }, options);
            try pane.input.append(self.allocator, writer.written());
            return;
        }
    }
};

fn enableEffects(pane: *Pane) void {
    pane.stream.handler.effects.write_pty = &writePty;
    pane.stream.handler.effects.device_attributes = &deviceAttributes;
    pane.stream.handler.effects.render_hold = &renderHold;
    pane.stream.handler.effects.clipboard_write = &writeClipboard;
    pane.stream.handler.effects.size = &paneSize;
}

fn paneSize(handler: *Handler) ?vt.size_report.Size {
    const pane: *Pane = @alignCast(@fieldParentPtr("term", handler.terminal));
    var size: c.struct_winsize = undefined;
    _ = sys.check(c.ioctl(0, c.TIOCGWINSZ, &size), "ioctl(pane geometry)") catch @panic("failed to read terminal geometry");
    return .{
        .rows = pane.term.rows,
        .columns = pane.term.cols,
        .cell_width = @as(u32, size.ws_xpixel) / pane.app.size.cols,
        .cell_height = @as(u32, size.ws_ypixel) / pane.app.size.rows,
    };
}

fn renderHold(handler: *Handler, held: bool) void {
    const pane: *Pane = @alignCast(@fieldParentPtr("term", handler.terminal));
    if (held) {
        pane.state.update(pane.app.allocator, &pane.term) catch @panic("failed to capture synchronized frame");
        pane.hold_until = (sys.monotonicMilliseconds() catch @panic("failed to read render clock")) + 1000;
    } else pane.hold_until = null;
    pane.app.dirty = true;
}

fn writeClipboard(handler: *Handler, request: vt.clipboard.Write) void {
    const pane: *Pane = @alignCast(@fieldParentPtr("term", handler.terminal));
    var writer: std.Io.Writer.Allocating = .init(pane.app.allocator);
    defer writer.deinit();
    const destination: u8 = switch (request.location) {
        .standard => 'c',
        .selection => 's',
        .primary => 'p',
        else => {
            request.reply(.unsupported);
            return;
        },
    };
    for (request.contents) |content| {
        if (!vt.clipboard.isTextMime(content.mime)) continue;
        const encoder = std.base64.standard.Encoder;
        const encoded = pane.app.allocator.alloc(u8, encoder.calcSize(content.data.len)) catch @panic("clipboard allocation failed");
        defer pane.app.allocator.free(encoded);
        writer.writer.print("\x1b]52;{c};{s}\x1b\\", .{ destination, encoder.encode(encoded, content.data) }) catch @panic("clipboard encoding failed");
        pane.app.output.append(pane.app.allocator, writer.written()) catch @panic("clipboard output buffer failed");
        request.reply(.{ .success = .{} });
        return;
    }
    if (request.contents.len == 0) {
        writer.writer.print("\x1b]52;{c};\x1b\\", .{destination}) catch @panic("clipboard encoding failed");
        pane.app.output.append(pane.app.allocator, writer.written()) catch @panic("clipboard output buffer failed");
        request.reply(.{ .success = .{} });
    } else request.reply(.unsupported);
}

fn writePty(handler: *Handler, bytes: []const u8) void {
    const pane: *Pane = @alignCast(@fieldParentPtr("term", handler.terminal));
    pane.input.append(pane.app.allocator, bytes) catch @panic("pane terminal response buffer failed");
}

fn deviceAttributes(_: *Handler) vt.device_attributes.Attributes {
    return .{};
}

fn encodeKey(writer: *std.Io.Writer, key: vaxis.Key, released: bool, term: *vt.Terminal) !void {
    const codepoint = key.codepoint;
    var mapped: vt.input.Key = if (codepoint < 128) vt.input.Key.fromASCII(@intCast(codepoint)) orelse .unidentified else .unidentified;
    inline for (@typeInfo(vt.input.Key).@"enum".field_names) |field| {
        if (@hasDecl(vaxis.Key, field)) {
            if (codepoint == @field(vaxis.Key, field)) mapped = @field(vt.input.Key, field);
        }
        if (comptime std.mem.startsWith(u8, field, "numpad_")) {
            const name = "kp_" ++ field[7..];
            if (@hasDecl(vaxis.Key, name)) {
                if (codepoint == @field(vaxis.Key, name)) mapped = @field(vt.input.Key, field);
            }
        }
    }
    inline for (.{
        .{ "menu", "context_menu" },
        .{ "left_shift", "shift_left" },
        .{ "right_shift", "shift_right" },
        .{ "left_control", "control_left" },
        .{ "right_control", "control_right" },
        .{ "left_alt", "alt_left" },
        .{ "right_alt", "alt_right" },
        .{ "left_super", "meta_left" },
        .{ "right_super", "meta_right" },
        .{ "lower_volume", "audio_volume_down" },
        .{ "raise_volume", "audio_volume_up" },
        .{ "mute_volume", "audio_volume_mute" },
    }) |names| if (codepoint == @field(vaxis.Key, names[0])) {
        mapped = @field(vt.input.Key, names[1]);
    };
    inline for (.{ "left", "right", "up", "down" }) |name| if (codepoint == @field(vaxis.Key, name)) {
        mapped = @field(vt.input.Key, "arrow_" ++ name);
    };
    var buffer: [4]u8 = undefined;
    const text = key.text orelse blk: {
        if ((key.mods.ctrl or key.mods.super) and term.screens.active.kitty_keyboard.current().int() != 0) break :blk "";
        var cp = key.shifted_codepoint orelse codepoint;
        if (cp >= 'a' and cp <= 'z' and key.mods.shift) cp = std.ascii.toUpper(@intCast(cp));
        if (cp < 32 or cp == 127 or (cp >= 57344 and cp <= 63743) or cp > 0x10ffff) break :blk "";
        break :blk buffer[0..try std.unicode.utf8Encode(cp, &buffer)];
    };
    var options = vt.input.KeyEncodeOptions.fromTerminal(term);
    options.macos_option_as_alt = .true;
    try vt.input.encodeKey(writer, .{ .action = if (released) .release else .press, .key = mapped, .mods = .{ .ctrl = key.mods.ctrl, .alt = key.mods.alt, .shift = key.mods.shift, .super = key.mods.super, .caps_lock = key.mods.caps_lock, .num_lock = key.mods.num_lock }, .consumed_mods = .{ .shift = true }, .utf8 = text, .unshifted_codepoint = codepoint }, options);
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, name: []const u8, bindings: keyboard.Bindings, focused_border_color: ?vt.color.RGB) !void {
    _ = try sys.check(c.prctl(c.PR_SET_CHILD_SUBREAPER, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)), "prctl(pane children)");
    var environment = try environ.createMap(allocator);
    defer environment.deinit();
    var executable: [std.fs.max_path_bytes]u8 = undefined;
    const length = try std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &executable);
    var app: App = .{ .allocator = allocator, .io = io, .environ = environ, .executable = executable[0..length], .termios = undefined, .size = try sys.Size.get(0), .vx = try vaxis.init(io, allocator, &environment, .{}), .focused_border_color = if (focused_border_color) |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } } else .{ .index = 6 }, .keys = .{ .bindings = bindings, .workspace = true, .report_events = true } };
    defer {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        app.vx.deinit(allocator, &writer.writer);
        app.output.deinit(allocator);
        if (app.status) |text| allocator.free(text);
        for (app.panes.items) |pane| pane.deinit();
        app.panes.deinit(allocator);
    }
    app.vx.caps.rgb = true;
    _ = try sys.check(c.tcgetattr(0, &app.termios), "tcgetattr(workspace)");
    const signals = try sys.signalFd(&.{ c.SIGWINCH, c.SIGCHLD, c.SIGHUP, c.SIGTERM, c.SIGINT });
    defer sys.close(signals);
    defer sys.unblockSignals() catch @panic("failed to restore workspace signals");
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const initial = try app.create(cwd, app.size, name);
    app.focused = initial;
    app.root = try allocator.create(Node);
    app.root.* = .{ .rect = initial.rect, .content = .{ .pane = initial } };
    defer app.root.deinit(allocator);
    var raw = app.termios;
    c.cfmakeraw(&raw);
    _ = try sys.check(c.tcsetattr(0, c.TCSANOW, &raw), "tcsetattr(workspace)");
    const input_flags = try sys.nonblocking(0, true);
    const output_flags = try sys.nonblocking(1, true);
    var finished = false;
    defer {
        _ = c.fcntl(0, c.F_SETFL, input_flags);
        _ = c.fcntl(1, c.F_SETFL, output_flags);
        _ = c.tcsetattr(0, c.TCSANOW, &app.termios);
        if (app.composed or !finished) @import("client.zig").resetDisplay() catch {};
    }
    var fds: std.ArrayList(c.struct_pollfd) = .empty;
    defer fds.deinit(allocator);
    while (app.panes.items.len > 0) {
        try app.closeRequested();
        if (app.panes.items.len == 0) break;
        if (app.composed and app.dirty and app.output.pending().len == 0) try app.draw();
        fds.clearRetainingCapacity();
        try fds.appendSlice(allocator, &.{ .{ .fd = signals, .events = c.POLLIN, .revents = 0 }, .{ .fd = 0, .events = if (app.focused.input.pending().len < protocol.max_queue - 32768) c.POLLIN else 0, .revents = 0 }, .{ .fd = 1, .events = if (app.output.pending().len > 0) c.POLLOUT else 0, .revents = 0 } });
        for (app.panes.items) |pane| try fds.appendSlice(allocator, &.{
            .{ .fd = pane.fd, .events = (if (app.output.pending().len < protocol.max_queue - 32768) @as(c_short, c.POLLIN) else 0) | (if (pane.input.pending().len > 0) @as(c_short, c.POLLOUT) else 0), .revents = 0 },
            .{ .fd = pane.listener, .events = c.POLLIN, .revents = 0 },
            .{ .fd = pane.control orelse -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (pane.closing) |request| request.fd else -1, .events = @as(c_short, c.POLLIN) | (if (pane.closing != null and pane.closing.?.input.pending().len > 0) @as(c_short, c.POLLOUT) else 0), .revents = 0 },
        });
        const now = try sys.monotonicMilliseconds();
        var deadline = app.keys.deadline;
        for (app.panes.items) |pane| if (pane.hold_until) |until| {
            deadline = @min(deadline orelse until, until);
        };
        if (app.selection_drag) |drag| if (drag.pane) |pane| if (pane.selection.deadline) |until| {
            deadline = @min(deadline orelse until, until);
        };
        const timeout: c_int = if (deadline) |value| @intCast(@max(0, value - now)) else -1;
        const count = c.poll(fds.items.ptr, @intCast(fds.items.len), timeout);
        if (count < 0 and c.__errno_location().* == c.EINTR) continue;
        _ = try sys.check(count, "poll(workspace)");
        const after_poll = try sys.monotonicMilliseconds();
        if (app.selection_drag) |drag| if (drag.pane) |pane| if (pane.selection.deadline) |until| {
            if (after_poll >= until) {
                try pane.selection.tick(&pane.term, after_poll);
                app.dirty = true;
            }
        };
        for (app.panes.items) |pane| if (pane.hold_until) |until| {
            if (after_poll >= until) {
                pane.hold_until = null;
                app.dirty = true;
            }
        };
        if (count == 0) {
            if (app.keys.deadline) |until| if (after_poll >= until) {
                try app.input(app.keys.expire());
            };
            continue;
        }
        if (fds.items[0].revents & c.POLLIN != 0) {
            var info: c.struct_signalfd_siginfo = undefined;
            while ((try sys.read(signals, std.mem.asBytes(&info))) != null) {
                if (info.ssi_signo == c.SIGWINCH) {
                    app.cancelResize();
                    app.cancelSelection();
                    app.size = try sys.Size.get(0);
                    if (app.composed) {
                        var writer: std.Io.Writer.Allocating = .init(allocator);
                        defer writer.deinit();
                        try app.vx.resize(allocator, &writer.writer, .{ .cols = app.size.cols, .rows = app.size.rows, .x_pixel = 0, .y_pixel = 0 });
                        try app.output.append(allocator, writer.written());
                        try app.arrange();
                    } else {
                        try app.size.set(initial.fd);
                        try initial.term.resize(allocator, .{ .cols = app.size.cols, .rows = app.size.rows });
                    }
                } else if (info.ssi_signo == c.SIGCHLD) {
                    while (true) {
                        var status: c_int = undefined;
                        const pid = c.waitpid(-1, &status, c.WNOHANG);
                        if (pid < 0) switch (c.__errno_location().*) {
                            c.EINTR => continue,
                            c.ECHILD => break,
                            else => return sys.failure("waitpid(workspace children)"),
                        };
                        if (pid == 0) break;
                        for (app.panes.items) |pane| {
                            if (pane.pid != pid) continue;
                            pane.exit_status = status;
                            try @import("server.zig").terminateSession(pane.pid);
                            break;
                        }
                    }
                } else return;
            }
        }
        if (fds.items[2].revents & c.POLLOUT != 0) try app.output.flush(1, false);
        if (fds.items[2].revents & (c.POLLHUP | c.POLLERR) != 0) return;
        var removed = false;
        for (app.panes.items, 0..) |pane, index| {
            const events = fds.items[3 + index * 4 ..][0..4];
            if (events[1].revents & c.POLLIN != 0) {
                const fd = try sys.check(c.accept4(pane.listener, null, null, c.SOCK_CLOEXEC | c.SOCK_NONBLOCK), "accept(pane)");
                const peer = try config.peer(fd);
                if (peer.uid != c.getuid()) {
                    sys.close(fd);
                    return error.UnsafePaneClient;
                }
                if (pane.control) |previous| sys.close(previous);
                pane.control = fd;
            }
            if (events[2].revents & (c.POLLIN | c.POLLHUP) != 0) {
                var buffer: [8192]u8 = undefined;
                if (try sys.read(pane.control.?, &buffer)) |n| {
                    if (pane.attached) |state| state.deinit();
                    pane.attached = null;
                    if (n == 0) {
                        sys.close(pane.control.?);
                        pane.control = null;
                        pane.detaching = false;
                    } else pane.attached = try std.json.parseFromSlice(context.State, allocator, buffer[0..n], .{ .allocate = .alloc_always });
                    app.dirty = true;
                }
            }
            if (pane.closing) |*request| {
                if (events[3].revents & c.POLLOUT != 0) try request.input.flush(request.fd, true);
                if (events[3].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) {
                    const alive = try request.reader.receive(allocator, request.fd);
                    var complete = false;
                    while (try request.reader.next()) |reply| {
                        switch (reply.tag) {
                            .ok => {
                                if (reply.payload.len != 0) return error.InvalidMessage;
                                complete = true;
                            },
                            .failure => {
                                if (!std.mem.eql(u8, reply.payload, "SessionNotFound")) return error.SessionCloseFailed;
                                complete = true;
                            },
                            else => return error.InvalidMessage,
                        }
                    }
                    if (complete) {
                        try app.remove(index);
                        removed = true;
                        break;
                    }
                    if (!alive) return error.ConnectionClosed;
                }
            }
            if (events[0].revents & c.POLLOUT != 0) try pane.input.flush(pane.fd, false);
            if (events[0].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) {
                var buffer: [16384]u8 = undefined;
                if (try sys.readPty(pane.fd, &buffer)) |n| {
                    if (n == 0) {
                        var status: c_int = pane.exit_status orelse 0;
                        if (pane.exit_status == null) _ = try sys.check(c.waitpid(pane.pid, &status, 0), "waitpid(pane)");
                        pane.pid = 0;
                        sys.close(pane.fd);
                        pane.fd = -1;
                        if (pane.closing != null) continue;
                        if (pane.close_requested) {
                            try app.remove(index);
                            removed = true;
                            break;
                        }
                        if (!app.composed) {
                            const flush_deadline = try sys.monotonicMilliseconds() + 100;
                            while (app.output.pending().len > 0) {
                                var event: c.struct_pollfd = .{ .fd = 1, .events = c.POLLOUT, .revents = 0 };
                                const remaining = flush_deadline - try sys.monotonicMilliseconds();
                                if (remaining <= 0) return error.RequestFailed;
                                const ready = c.poll(&event, 1, @intCast(remaining));
                                if (ready < 0 and c.__errno_location().* == c.EINTR) continue;
                                if (try sys.check(ready, "poll(final pane output)") == 0) return error.RequestFailed;
                                if (event.revents & (c.POLLHUP | c.POLLERR) != 0) return;
                                try app.output.flush(1, false);
                            }
                            finished = true;
                            if (status != 0) return error.RequestFailed;
                            return;
                        }
                        if (pane.initial) {
                            pane.initial = false;
                            if (pane.attached) |state| state.deinit();
                            pane.attached = null;
                            try pane.spawn(null);
                        } else {
                            try app.remove(index);
                            removed = true;
                        }
                        app.dirty = true;
                        break;
                    }
                    pane.stream.nextSlice(buffer[0..n]);
                    if (pane.stream.handler.semantic_failure) return error.TerminalStateFailure;
                    if (app.composed) app.dirty = true else try app.output.append(allocator, buffer[0..n]);
                }
            }
        }
        if (!removed and fds.items[1].revents & (c.POLLIN | c.POLLHUP) != 0) {
            var bytes: [keyboard.Input.read_size]u8 = undefined;
            if (try sys.readPty(0, &bytes)) |n| {
                if (n == 0) return;
                if (app.status) |text| {
                    allocator.free(text);
                    app.status = null;
                }
                for (bytes[0..n]) |byte| try app.input(try app.keys.feed(&.{byte}, after_poll));
            }
        }
    }
}
