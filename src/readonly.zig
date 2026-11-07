const std = @import("std");
const vaxis = @import("vaxis");
const terminal = @import("terminal.zig");
const vt = terminal.vt;
const Stream = @TypeOf(@as(*vt.Terminal, undefined).vtStream());
const Handler = @FieldType(Stream, "handler");
const sys = @import("sys.zig");
const keyboard = @import("keyboard.zig");
const protocol = @import("protocol.zig");
const render = @import("pane_render.zig");
const display = @import("display.zig");

pub const View = struct {
    allocator: std.mem.Allocator,
    term: vt.Terminal,
    stream: Stream = undefined,
    state: render.State = .{},
    cache: render.Cache = .{},
    vx: vaxis.Vaxis,
    frame: std.Io.Writer.Allocating,
    name: []u8,
    dirty: bool = true,
    repaint: bool = true,
    next_frame: i64 = 0,
    hold_until: ?i64 = null,
    following: bool = true,
    top: u16 = 0,
    left: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, name: []const u8) !View {
        var environment = try environ.createMap(allocator);
        defer environment.deinit();
        var frame: std.Io.Writer.Allocating = .init(allocator);
        errdefer frame.deinit();
        var vx = try vaxis.init(io, allocator, &environment, .{});
        errdefer vx.deinit(allocator, &frame.writer);
        vx.caps.rgb = true;
        vx.sgr = .legacy;
        vx.state.alt_screen = true;
        var term = try terminal.init(allocator, io, .{ .cols = 80, .rows = 24 });
        errdefer term.deinit(allocator);
        return .{ .allocator = allocator, .term = term, .vx = vx, .frame = frame, .name = try allocator.dupe(u8, name) };
    }

    pub fn start(self: *View, output: *protocol.Queue, mouse: bool) !void {
        self.stream = self.term.vtStream();
        self.stream.handler.effects.render_hold = &renderHold;
        output.limit = 16 * 1024 * 1024;
        try output.append(self.allocator, display.reset ++ "\x1b[?1049h\x1b[?2004h\x1b[>1u");
        if (mouse) try output.append(self.allocator, "\x1b[?1000h\x1b[?1006h");
        try self.resize(output);
    }

    pub fn deinit(self: *View) void {
        self.stream.deinit();
        self.term.deinit(self.allocator);
        self.state.deinit(self.allocator);
        self.cache.deinit(self.allocator);
        self.frame.clearRetainingCapacity();
        self.vx.deinit(self.allocator, &self.frame.writer);
        self.frame.deinit();
        self.allocator.free(self.name);
    }

    pub fn rename(self: *View, name: []const u8) !void {
        const value = try self.allocator.dupe(u8, name);
        self.allocator.free(self.name);
        self.name = value;
        self.dirty = true;
        self.repaint = true;
    }

    pub fn resize(self: *View, output: *protocol.Queue) !void {
        const size = try sys.Size.get(0);
        self.frame.clearRetainingCapacity();
        try self.vx.resize(self.allocator, &self.frame.writer, .{ .cols = size.cols, .rows = size.rows, .x_pixel = 0, .y_pixel = 0 });
        try output.append(self.allocator, self.frame.written());
        self.dirty = true;
        self.repaint = true;
    }

    pub fn sourceSize(self: *View, size: sys.Size) !void {
        try self.term.resize(self.allocator, .{ .cols = size.cols, .rows = size.rows });
        self.dirty = true;
        self.repaint = true;
    }

    pub fn receive(self: *View, bytes: []const u8) !void {
        self.stream.nextSlice(bytes);
        if (self.stream.handler.semantic_failure) return error.TerminalStateFailure;
        self.dirty = true;
    }

    pub fn frameDeadline(self: *const View) i64 {
        return @max(self.next_frame, self.hold_until orelse 0);
    }

    fn renderHold(handler: *Handler, held: bool) void {
        const self: *View = @alignCast(@fieldParentPtr("term", handler.terminal));
        self.hold_until = if (held) (sys.monotonicMilliseconds() catch @panic("failed to read render clock")) + 1000 else null;
    }

    fn height(self: *const View) u16 {
        return @max(1, self.vx.screen.height -| 1);
    }

    fn scroll(self: *View, delta: isize) void {
        const pages = &self.term.screens.active.pages;
        const current: isize = @intCast(pages.scrollbar().offset + self.top);
        const last: isize = @intCast(pages.total_rows -| self.height());
        const target: usize = @intCast(std.math.clamp(current + delta, 0, last));
        self.term.scrollViewport(.{ .row = target });
        self.top = @intCast(target - pages.scrollbar().offset);
        self.following = false;
    }

    pub fn input(self: *View, result: keyboard.Input.Result) void {
        const event = result.event orelse return;
        if (event == .mouse and event.mouse.type == .press) {
            switch (event.mouse.button) {
                .wheel_up => self.scroll(-3),
                .wheel_down => self.scroll(3),
                else => return,
            }
        } else if (event == .key_press) {
            const key = event.key_press;
            if (key.matchExact(vaxis.Key.page_up, .{})) {
                self.scroll(-@as(isize, self.height()));
            } else if (key.matchExact(vaxis.Key.page_down, .{})) {
                self.scroll(self.height());
            } else if (key.matchExact(vaxis.Key.up, .{})) {
                self.scroll(-1);
            } else if (key.matchExact(vaxis.Key.down, .{})) {
                self.scroll(1);
            } else if (key.matchExact(vaxis.Key.home, .{})) {
                self.term.scrollViewport(.top);
                self.top = 0;
                self.following = false;
            } else if (key.matchExact(vaxis.Key.end, .{})) {
                self.term.scrollViewport(.bottom);
                self.following = true;
            } else if (key.matchExact(vaxis.Key.left, .{})) {
                self.left -|= 1;
                self.following = false;
            } else if (key.matchExact(vaxis.Key.right, .{})) {
                self.left = @min(self.left + 1, self.term.cols -| self.vx.screen.width);
                self.following = false;
            } else return;
        } else return;
        self.dirty = true;
        self.repaint = true;
    }

    pub fn draw(self: *View, output: *protocol.Queue) !void {
        self.hold_until = null;
        const previous = [2]u16{ self.left, self.top };
        if (self.following) {
            self.top = @min(self.term.rows -| self.height(), self.term.screens.active.cursor.y + 1 -| self.height());
            self.left = @min(self.term.cols -| self.vx.screen.width, self.term.screens.active.cursor.x + 1 -| self.vx.screen.width);
        }
        self.top = @min(self.top, self.term.rows -| self.height());
        self.left = @min(self.left, self.term.cols -| self.vx.screen.width);
        if (!std.mem.eql(u16, &previous, &.{ self.left, self.top })) self.repaint = true;
        // 本地窗口裁剪画面，源终端始终使用后台发布的实际尺寸。
        if (self.repaint) self.vx.screen.clear();
        try self.state.update(self.allocator, &self.term);
        try render.draw(self.allocator, &self.cache, &self.vx.screen, &self.term, &self.state, .{
            .width = @max(4, self.vx.screen.width + self.left + 2),
            .height = self.height() + self.top + 2,
        }, .{ self.left + 1, self.top + 1 }, false, false, .default, "", self.repaint);
        var footer: [160]u8 = undefined;
        const label = try std.fmt.bufPrint(&footer, "Read-only: {s} | q/Esc: exit | PgUp/PgDn: history | End: live", .{self.name});
        for (0..self.vx.screen.width) |column| self.vx.screen.writeCell(@intCast(column), self.vx.screen.height - 1, .{ .style = .{ .reverse = true } });
        _ = self.vx.window().printSegment(.{ .text = label, .style = .{ .reverse = true } }, .{ .row_offset = self.vx.screen.height - 1, .wrap = .none });
        self.vx.screen.cursor_vis = false;
        self.frame.clearRetainingCapacity();
        try self.vx.render(&self.frame.writer);
        try output.append(self.allocator, self.frame.written());
        self.dirty = false;
        self.repaint = false;
        self.next_frame = try sys.monotonicMilliseconds() + 16;
    }
};
