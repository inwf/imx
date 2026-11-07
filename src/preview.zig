const std = @import("std");
const vt = @import("ghostty-vt");
const sys = @import("sys.zig");
const ScreenKey = @TypeOf(@as(vt.Terminal, undefined).screens.active_key);

pub const Source = struct {
    state: vt.RenderState = .empty,
    rows: std.ArrayList(u64) = .empty,
    revision: ?u64 = null,
    generation: u64 = 0,

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        self.state.deinit(allocator);
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn update(self: *Source, allocator: std.mem.Allocator, term: *vt.Terminal, revision: u64) !void {
        if (self.revision == revision and self.state.screen == term.screens.active_key) return;
        try self.state.update(allocator, term);
        self.generation +%= 1;
        const previous_length = self.rows.items.len;
        try self.rows.resize(allocator, self.state.row_data.len);
        for (self.rows.items, 0..) |*generation, y| {
            if (self.state.dirty == .full or y >= previous_length or self.state.row_data.get(y).dirty) generation.* = self.generation;
        }
        self.revision = revision;
        self.state.clean();
    }
};

pub const Frame = struct {
    const History = struct { screen: ScreenKey, generation: usize, pin: *vt.Pin };
    const Row = struct {
        generation: u64 = 0,
        bytes: std.ArrayList(u8) = .empty,
    };

    buffer: ?std.Io.Writer.Allocating = null,
    rows: std.ArrayList(Row) = .empty,
    size: ?sys.Size = null,
    screen: ?ScreenKey = null,
    top: usize = 0,
    history: ?History = null,
    rendered_history: bool = false,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        std.debug.assert(self.history == null);
        if (self.buffer) |*buffer| buffer.deinit();
        for (self.rows.items) |*row| row.bytes.deinit(allocator);
        self.rows.deinit(allocator);
    }

    pub fn follow(self: *Frame, term: *vt.Terminal) void {
        if (self.history) |history| {
            if (history.generation == term.screens.generation(history.screen)) {
                if (term.screens.get(history.screen)) |screen| screen.pages.untrackPin(history.pin);
            }
        }
        self.history = null;
    }

    fn validateHistory(self: *Frame, term: *vt.Terminal) void {
        if (self.history) |history| {
            if (history.generation != term.screens.generation(history.screen)) self.history = null;
        }
    }

    fn liveTop(term: *vt.Terminal, size: sys.Size) usize {
        const height = @min(size.rows, term.rows);
        return term.screens.active.pages.total_rows - term.rows +
            @min(term.rows - height, (term.screens.active.cursor.y + 1) -| height);
    }

    pub fn scroll(self: *Frame, term: *vt.Terminal, size: sys.Size, delta: i32) !void {
        self.validateHistory(term);
        if (delta == 0 or (delta > 0 and self.history == null)) return;
        const active = term.screens.active_key;
        if (self.history) |history| term.screens.switchTo(history.screen);
        defer term.screens.switchTo(active);
        const pages = &term.screens.active.pages;
        const last = pages.total_rows - @min(size.rows, pages.total_rows);
        const current = if (self.history) |history| pages.pointFromPin(.screen, history.pin.*).?.screen.y else liveTop(term, size);
        const target: usize = @intCast(std.math.clamp(@as(i64, @intCast(@min(current, last))) + delta, 0, @as(i64, @intCast(last))));
        if (delta > 0 and target == last) {
            self.follow(term);
        } else if (self.history) |history| {
            history.pin.* = pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(target) } }).?;
        } else if (target != @min(current, last)) {
            self.history = .{
                .screen = term.screens.active_key,
                .generation = term.screens.generation(term.screens.active_key),
                .pin = try pages.trackPin(pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(target) } }).?),
            };
        }
    }

    pub fn render(self: *Frame, allocator: std.mem.Allocator, source: *Source, term: *vt.Terminal, size: sys.Size, revision: u64) ![]u8 {
        self.validateHistory(term);
        const active = term.screens.active_key;
        if (self.history) |history| term.screens.switchTo(history.screen);
        defer term.screens.switchTo(active);
        const pages = &term.screens.active.pages;
        const browsing = self.history != null;
        if (!browsing) try source.update(allocator, term, revision);
        const height: u16 = @intCast(@min(size.rows, if (browsing) pages.total_rows else term.rows));
        const width = @min(size.cols, term.cols);
        const top = if (self.history) |history| @min(pages.pointFromPin(.screen, history.pin.*).?.screen.y, pages.total_rows - height) else liveTop(term, size);
        const cache_top = if (browsing) top else top - (pages.total_rows - term.rows);
        const full = self.size == null or !std.meta.eql(self.size.?, size) or self.screen != term.screens.active_key or self.top != cache_top or self.rows.items.len != height or self.rendered_history != browsing;
        if (self.buffer == null) self.buffer = .init(allocator);
        const buffer = &self.buffer.?;
        buffer.clearRetainingCapacity();
        if (full) try buffer.writer.writeAll("\x1b[0m\x1b[2J\x1b[H");
        while (self.rows.items.len > height) {
            var row = self.rows.pop().?;
            row.bytes.deinit(allocator);
        }
        while (self.rows.items.len < height) try self.rows.append(allocator, .{});
        var pin = pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(top) } }).?;
        for (self.rows.items, 0..) |*cached, y| {
            if (y != 0) pin = pin.down(1).?;
            const generation = if (browsing) 0 else source.rows.items[top + y - (pages.total_rows - term.rows)];
            if (!browsing and !full and cached.generation == generation) continue;
            const start = buffer.written().len;
            try buffer.writer.print("\x1b[0m\x1b[{d};1H\x1b[2K", .{y + 1});
            var formatter = vt.formatter.TerminalFormatter.init(term, .vt);
            var end = pin;
            end.x = @intCast(@min(width, pin.node.cols()) - 1);
            formatter.content = .{ .selection = vt.Selection.init(pin, end, true) };
            formatter.extra = .none;
            try formatter.format(&buffer.writer);
            const bytes = buffer.written()[start..];
            // 页面重新分配也会标记整页更新，逐行比较保留未变化的画面。
            if (!full and std.mem.eql(u8, cached.bytes.items, bytes)) {
                buffer.writer.end = start;
            } else {
                cached.bytes.clearRetainingCapacity();
                try cached.bytes.appendSlice(allocator, bytes);
            }
            cached.generation = generation;
        }
        self.size = size;
        self.screen = term.screens.active_key;
        self.top = cache_top;
        self.rendered_history = browsing;
        return buffer.written();
    }
};

fn expectCurrent(source: *Source, term: *vt.Terminal, frame: *Frame, target: *vt.Terminal, revision: u64) !usize {
    const allocator = std.testing.allocator;
    const size: sys.Size = .{ .cols = target.cols, .rows = target.rows };
    const bytes = try frame.render(allocator, source, term, size, revision);
    var input = target.vtStream();
    defer input.deinit();
    input.nextSlice(bytes);
    var complete: Frame = .{};
    defer complete.deinit(allocator);
    var expected = try vt.Terminal.init(std.testing.io, allocator, .{ .cols = size.cols, .rows = size.rows });
    defer expected.deinit(allocator);
    var stream = expected.vtStream();
    defer stream.deinit();
    stream.nextSlice(try complete.render(allocator, source, term, size, revision));
    var actual_text: std.Io.Writer.Allocating = .init(allocator);
    defer actual_text.deinit();
    var expected_text: std.Io.Writer.Allocating = .init(allocator);
    defer expected_text.deinit();
    var actual_formatter = vt.formatter.TerminalFormatter.init(target, .vt);
    actual_formatter.extra = .none;
    var expected_formatter = vt.formatter.TerminalFormatter.init(&expected, .vt);
    expected_formatter.extra = .none;
    try actual_formatter.format(&actual_text.writer);
    try expected_formatter.format(&expected_text.writer);
    try std.testing.expectEqualStrings(expected_text.written(), actual_text.written());
    return bytes.len;
}

test "preview clients independently receive changed rows and cleared wide text" {
    const allocator = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, allocator, .{ .cols = 40, .rows = 12 });
    defer term.deinit(allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    for (0..10) |_| stream.nextSlice("\x1b[31mUNCHANGED 中文 e\xcc\x81\x1b[0m\r\n");
    var source: Source = .{};
    defer source.deinit(allocator);
    var first: Frame = .{};
    defer first.deinit(allocator);
    var second: Frame = .{};
    defer second.deinit(allocator);
    var a = try vt.Terminal.init(std.testing.io, allocator, .{ .cols = 40, .rows = 12 });
    defer a.deinit(allocator);
    var b = try vt.Terminal.init(std.testing.io, allocator, .{ .cols = 30, .rows = 10 });
    defer b.deinit(allocator);
    const initial = try expectCurrent(&source, &term, &first, &a, 0);
    _ = try expectCurrent(&source, &term, &second, &b, 0);
    stream.nextSlice("\x1b[2;1H\x1b[44m\x1b[2KCHANGED\x1b[0m");
    const changed = try expectCurrent(&source, &term, &first, &a, 1);
    try std.testing.expect(changed < initial / 2);
    stream.nextSlice("\x1b[3;1H界\x1b[K");
    _ = try expectCurrent(&source, &term, &first, &a, 2);
    stream.nextSlice("\x1b[3;1HX\x1b[K\x1b[4;1HAFTER\x1b[K");
    _ = try expectCurrent(&source, &term, &first, &a, 3);
    _ = try expectCurrent(&source, &term, &second, &b, 3);
    try std.testing.expectEqual(@as(usize, 0), try expectCurrent(&source, &term, &first, &a, 3));
}

test "preview follows screen switches scrolling and size changes" {
    const allocator = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, allocator, .{ .cols = 20, .rows = 8 });
    defer term.deinit(allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    var source: Source = .{};
    defer source.deinit(allocator);
    var frame: Frame = .{};
    defer frame.deinit(allocator);
    var target = try vt.Terminal.init(std.testing.io, allocator, .{ .cols = 12, .rows = 5 });
    defer target.deinit(allocator);
    const sequences = [_][]const u8{
        "PRIMARY\r\nSECOND",
        "\x1b[?1049h\x1b[32mALTERNATE\x1b[0m",
        "\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7",
        "\x1b[?1049l",
    };
    for (sequences, 0..) |bytes, revision| {
        stream.nextSlice(bytes);
        _ = try expectCurrent(&source, &term, &frame, &target, revision);
    }
    try term.resize(allocator, .{ .cols = 6, .rows = 3 });
    _ = try expectCurrent(&source, &term, &frame, &target, 4);
    try target.resize(allocator, .{ .cols = 18, .rows = 8 });
    _ = try expectCurrent(&source, &term, &frame, &target, 4);
}

test "preview history releases tracked positions after pruning and terminal reset" {
    const allocator = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, allocator, .{ .cols = 20, .rows = 6, .max_scrollback_lines = 40 });
    defer term.deinit(allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    var source: Source = .{};
    defer source.deinit(allocator);
    var frame: Frame = .{};
    defer frame.deinit(allocator);
    defer frame.follow(&term);
    const size: sys.Size = .{ .rows = 3, .cols = 15 };
    for (0..60) |_| stream.nextSlice("HISTORY\r\n");
    const tracked = term.screens.active.pages.countTrackedPins();
    _ = try frame.render(allocator, &source, &term, size, 0);
    try frame.scroll(&term, size, -20);
    try std.testing.expectEqual(tracked + 1, term.screens.active.pages.countTrackedPins());
    _ = try frame.render(allocator, &source, &term, size, 0);
    for (0..4096) |_| {
        stream.nextSlice("NEW_CONTENT\r\n");
        if (frame.history.?.pin.garbage) break;
    }
    try std.testing.expect(frame.history.?.pin.garbage);
    const output = try frame.render(allocator, &source, &term, size, 1);
    try std.testing.expect(std.mem.indexOf(u8, output, "NEW_CONTENT") != null);
    try frame.scroll(&term, size, std.math.maxInt(i32));
    try std.testing.expect(frame.history == null);
    try std.testing.expectEqual(tracked, term.screens.active.pages.countTrackedPins());
    stream.nextSlice("\x1b[?1049h1\r\n2\r\n3\r\n4\r\n5\r\n6");
    try frame.scroll(&term, size, -2);
    try std.testing.expect(frame.history != null);
    _ = try frame.render(allocator, &source, &term, size, 2);
    stream.nextSlice("\x1bcRESET_CONTENT");
    const reset = try frame.render(allocator, &source, &term, size, 3);
    try std.testing.expect(std.mem.indexOf(u8, reset, "RESET_CONTENT") != null);
}
