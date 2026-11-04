const std = @import("std");
const vaxis = @import("vaxis");
const vt = @import("ghostty-vt");

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16,
    height: u16,

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and y >= self.y and x < @as(u32, self.x) + self.width and y < @as(u32, self.y) + self.height;
    }
};

fn color(value: vt.Style.Color, palette: vt.color.Palette, default: ?vt.color.RGB) vaxis.Color {
    const rgb = switch (value) {
        .none => default orelse return .default,
        .palette => |index| if (std.meta.eql(palette[index], vt.color.default[index])) return .{ .index = index } else palette[index],
        .rgb => |rgb| rgb,
    };
    return .{ .rgb = .{ rgb.r, rgb.g, rgb.b } };
}

pub const State = struct {
    const Link = struct { first: usize, end: usize, uri: [2]usize, params: [2]usize };
    const Row = struct {
        id: ?vt.RenderState.Row.Id = null,
        bytes: std.ArrayList(u8) = .empty,
        links: std.ArrayList(Link) = .empty,

        fn deinit(self: *Row, allocator: std.mem.Allocator) void {
            self.bytes.deinit(allocator);
            self.links.deinit(allocator);
        }
    };

    render: vt.RenderState = .empty,
    rows: std.ArrayList(Row) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.render.deinit(allocator);
        for (self.rows.items) |*row| row.deinit(allocator);
        self.rows.deinit(allocator);
    }

    pub fn update(self: *State, allocator: std.mem.Allocator, term: *vt.Terminal) !void {
        try self.render.update(allocator, term);
        while (self.rows.items.len > self.render.row_data.len) {
            var row = self.rows.pop().?;
            row.deinit(allocator);
        }
        while (self.rows.items.len < self.render.row_data.len) try self.rows.append(allocator, .{});
        for (self.rows.items, 0..) |*row, y| {
            const source = self.render.row_data.get(y);
            const id = source.id();
            if (self.render.dirty != .full and !source.dirty and row.id != null and row.id.?.eql(id)) continue;
            defer row.id = id;
            row.bytes.clearRetainingCapacity();
            row.links.clearRetainingCapacity();
            if (!source.raw.hyperlink) continue;
            // Ghostty 的绘制状态不保存链接内容，在终端页面变化之前复制链接。
            const page = source.pin.node.page();
            var previous: ?u16 = null;
            for (source.pin.cells(.all), 0..) |*cell, x| {
                const link_id = if (cell.hyperlink) page.lookupHyperlink(cell).? else null;
                defer previous = link_id;
                const current = link_id orelse continue;
                if (previous == current) {
                    row.links.items[row.links.items.len - 1].end = x + 1;
                    continue;
                }
                const entry = page.hyperlink_set.get(page.memory, current);
                const uri_start = row.bytes.items.len;
                try row.bytes.appendSlice(allocator, entry.uri.slice(page.memory));
                const uri_end = row.bytes.items.len;
                if (entry.id == .explicit) {
                    try row.bytes.appendSlice(allocator, "id=");
                    try row.bytes.appendSlice(allocator, entry.id.explicit.slice(page.memory));
                }
                try row.links.append(allocator, .{ .first = x, .end = x + 1, .uri = .{ uri_start, uri_end }, .params = .{ uri_end, row.bytes.items.len } });
            }
        }
    }
};

pub const Cache = struct {
    const Row = struct {
        text: std.ArrayList(u8) = .empty,
        id: ?vt.RenderState.Row.Id = null,
    };

    rows: std.ArrayList(Row) = .empty,
    columns: usize = 0,
    foreground: ?vt.color.RGB = null,
    background: ?vt.color.RGB = null,
    reverse: bool = false,
    title: [128]u8 = undefined,
    title_len: usize = 0,
    selected: bool = false,
    border_color: vaxis.Color = .default,

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*row| row.text.deinit(allocator);
        self.rows.deinit(allocator);
    }
};

fn drawBorder(screen: *vaxis.Screen, rect: Rect, offset: [2]u16, selected: bool, focused_border_color: vaxis.Color, title: []const u8) void {
    const border: vaxis.Style = .{ .fg = if (selected) focused_border_color else .{ .index = 8 }, .bold = selected };
    for (0..rect.width) |x| {
        put(screen, @as(i32, rect.x) + @as(i32, @intCast(x)) - offset[0], @as(i32, rect.y) - offset[1], .{ .char = .{ .grapheme = "─" }, .style = border });
        put(screen, @as(i32, rect.x) + @as(i32, @intCast(x)) - offset[0], @as(i32, rect.y) + rect.height - 1 - offset[1], .{ .char = .{ .grapheme = "─" }, .style = border });
    }
    for (0..rect.height) |y| {
        put(screen, @as(i32, rect.x) - offset[0], @as(i32, rect.y) + @as(i32, @intCast(y)) - offset[1], .{ .char = .{ .grapheme = "│" }, .style = border });
        put(screen, @as(i32, rect.x) + rect.width - 1 - offset[0], @as(i32, rect.y) + @as(i32, @intCast(y)) - offset[1], .{ .char = .{ .grapheme = "│" }, .style = border });
    }
    const corners = [_][]const u8{ "┌", "┐", "└", "┘" };
    for (corners, 0..) |grapheme, i| put(screen, @as(i32, rect.x) + (if (i % 2 == 0) @as(i32, 0) else rect.width - 1) - offset[0], @as(i32, rect.y) + (if (i < 2) @as(i32, 0) else rect.height - 1) - offset[1], .{ .char = .{ .grapheme = grapheme }, .style = border });
    for (title[0..@min(title.len, rect.width - 4)], 0..) |_, i| put(screen, @as(i32, rect.x) + 2 + @as(i32, @intCast(i)) - offset[0], @as(i32, rect.y) - offset[1], .{ .char = .{ .grapheme = title[i..][0..1] }, .style = border });
}

fn clearRow(screen: *vaxis.Screen, rect: Rect, offset: [2]u16, y: usize) void {
    const sy = @as(i32, rect.y) + 1 + @as(i32, @intCast(y)) - offset[1];
    for (0..rect.width - 2) |x| put(screen, @as(i32, rect.x) + 1 + @as(i32, @intCast(x)) - offset[0], sy, .{});
}

fn codepoint(text: *std.ArrayList(u8), cp: u21) !void {
    var bytes: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(if (cp == 0) ' ' else cp, &bytes);
    text.appendSliceAssumeCapacity(bytes[0..len]);
}

pub fn draw(allocator: std.mem.Allocator, cache: *Cache, screen: *vaxis.Screen, term: *vt.Terminal, snapshot: *State, rect: Rect, offset: [2]u16, selected: bool, focused_border_color: vaxis.Color, title: []const u8, force: bool) !void {
    const state = &snapshot.render;
    const foreground = term.colors.foreground.get();
    const background = term.colors.background.get();
    const reverse = term.modes.get(.reverse_colors);
    const full = force or state.dirty == .full or cache.rows.items.len != state.row_data.len or cache.columns != state.cols or
        !std.meta.eql(cache.foreground, foreground) or !std.meta.eql(cache.background, background) or cache.reverse != reverse;
    if (full) for (0..rect.height - 2) |y| clearRow(screen, rect, offset, y);
    if (full or cache.selected != selected or !std.meta.eql(cache.border_color, focused_border_color) or !std.mem.eql(u8, cache.title[0..cache.title_len], title)) {
        @memcpy(cache.title[0..title.len], title);
        cache.title_len = title.len;
        cache.selected = selected;
        cache.border_color = focused_border_color;
        drawBorder(screen, rect, offset, selected, focused_border_color, cache.title[0..cache.title_len]);
    }
    while (cache.rows.items.len > state.row_data.len) {
        var row = cache.rows.pop().?;
        row.text.deinit(allocator);
    }
    while (cache.rows.items.len < state.row_data.len) try cache.rows.append(allocator, .{});
    for (cache.rows.items, 0..) |*row, y| {
        if (y >= rect.height - 2) break;
        const source = state.row_data.get(y);
        const id = source.id();
        if (!full and !source.dirty and row.id != null and row.id.?.eql(id)) continue;
        if (!full) clearRow(screen, rect, offset, y);
        const cells = source.cells;
        var capacity: usize = cells.len * 4;
        for (0..cells.len) |x| {
            const cell = cells.get(x);
            if (cell.raw.content_tag == .codepoint_grapheme) capacity += cell.grapheme.len * 4;
        }
        row.text.clearRetainingCapacity();
        try row.text.ensureTotalCapacity(allocator, capacity);
        const links = snapshot.rows.items[y];
        var link_index: usize = 0;
        for (0..cells.len) |x| {
            if (x >= rect.width - 2) break;
            const cell = cells.get(x);
            if (cell.raw.wide == .spacer_tail or cell.raw.wide == .spacer_head) continue;
            const start = row.text.items.len;
            try codepoint(&row.text, cell.raw.codepoint());
            if (cell.raw.content_tag == .codepoint_grapheme) for (cell.grapheme) |extra| try codepoint(&row.text, extra);
            var style: vt.Style = if (cell.raw.style_id == 0) .{} else cell.style;
            switch (cell.raw.content_tag) {
                .bg_color_palette => style.bg_color = .{ .palette = cell.raw.content.color_palette.data },
                .bg_color_rgb => style.bg_color = .{ .rgb = .{ .r = cell.raw.content.color_rgb.r, .g = cell.raw.content.color_rgb.g, .b = cell.raw.content.color_rgb.b } },
                else => {},
            }
            const width: u8 = if (cell.raw.wide == .wide) 2 else 1;
            const highlighted = if (source.selection) |range| x >= range[0] and x <= range[1] else false;
            const sx = @as(i32, rect.x) + 1 + @as(i32, @intCast(x)) - offset[0];
            const sy = @as(i32, rect.y) + 1 + @as(i32, @intCast(y)) - offset[1];
            while (link_index < links.links.items.len and links.links.items[link_index].end <= x) link_index += 1;
            const link: vaxis.Cell.Hyperlink = if (link_index < links.links.items.len and links.links.items[link_index].first <= x) blk: {
                const range = links.links.items[link_index];
                break :blk .{ .uri = links.bytes.items[range.uri[0]..range.uri[1]], .params = links.bytes.items[range.params[0]..range.params[1]] };
            } else .{};
            const value: vaxis.Cell = .{
                .char = .{ .grapheme = row.text.items[start..], .width = width },
                .link = link,
                .style = .{
                    .fg = color(style.fg_color, state.colors.palette, foreground),
                    .bg = color(style.bg_color, state.colors.palette, background),
                    .ul = color(style.underline_color, state.colors.palette, null),
                    .bold = style.flags.bold,
                    .dim = style.flags.faint,
                    .italic = style.flags.italic,
                    .blink = style.flags.blink,
                    .reverse = (style.flags.inverse != reverse) != highlighted,
                    .invisible = style.flags.invisible,
                    .strikethrough = style.flags.strikethrough,
                    .ul_style = switch (style.flags.underline) {
                        .none => .off,
                        .single => .single,
                        .double => .double,
                        .curly => .curly,
                        .dotted => .dotted,
                        .dashed => .dashed,
                    },
                },
            };
            put(screen, sx, sy, value);
        }
        row.id = id;
    }
    cache.columns = state.cols;
    cache.foreground = foreground;
    cache.background = background;
    cache.reverse = reverse;
    state.clean();
    if (selected) {
        screen.cursor_vis = false;
        if (state.cursor.viewport) |cursor| {
            const x = @as(i32, rect.x) + 1 + cursor.x - offset[0];
            const y = @as(i32, rect.y) + 1 + cursor.y - offset[1];
            if (x >= 0 and y >= 0 and x < screen.width and y < screen.height) {
                screen.cursor = .{ .col = @intCast(x), .row = @intCast(y) };
                screen.cursor_vis = state.cursor.visible;
                screen.cursor_shape = switch (state.cursor.visual_style) {
                    .block, .block_hollow => if (state.cursor.blinking) .block_blink else .block,
                    .underline => if (state.cursor.blinking) .underline_blink else .underline,
                    .bar => if (state.cursor.blinking) .beam_blink else .beam,
                };
            }
        }
    }
}

fn put(screen: *vaxis.Screen, x: i32, y: i32, cell: vaxis.Cell) void {
    if (x < 0 or y < 0 or x >= screen.width or y >= screen.height) return;
    if (cell.char.width == 2 and x + 1 >= screen.width) return;
    screen.writeCell(@intCast(x), @intCast(y), cell);
}

test "pane rendering preserves backgrounds on cleared cells" {
    const allocator = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, allocator, .{ .cols = 48, .rows = 28 });
    defer term.deinit(allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?1049h\x1b[44m\x1b[2J\x1b[H\x1b[1;33mPANE_APPLICATION\x1b[0m");
    var state: State = .{};
    defer state.deinit(allocator);
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 100, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    try state.update(allocator, &term);
    try draw(allocator, &cache, &screen, &term, &state, .{ .x = 50, .width = 50, .height = 30 }, .{ 0, 0 }, true, .{ .index = 6 }, "test", true);
    try std.testing.expectEqual(vaxis.Color{ .index = 4 }, screen.readCell(52, 2).?.style.bg);
    try std.testing.expectEqualStrings("A", screen.readCell(52, 1).?.char.grapheme);
    const selected: vaxis.Color = .{ .rgb = .{ 0x33, 0xaa, 0xff } };
    try draw(allocator, &cache, &screen, &term, &state, .{ .x = 50, .width = 50, .height = 30 }, .{ 0, 0 }, true, selected, "test", false);
    for ([_][2]u16{ .{ 50, 0 }, .{ 52, 0 }, .{ 99, 29 } }) |position| {
        const style = screen.readCell(position[0], position[1]).?.style;
        try std.testing.expectEqual(selected, style.fg);
        try std.testing.expect(style.bold);
    }
    try draw(allocator, &cache, &screen, &term, &state, .{ .x = 50, .width = 50, .height = 30 }, .{ 0, 0 }, false, selected, "test", false);
    try std.testing.expectEqual(vaxis.Color{ .index = 8 }, screen.readCell(50, 0).?.style.fg);
    try std.testing.expect(!screen.readCell(50, 0).?.style.bold);
}

test "pane rendering retains text through partial updates and clears wide cells" {
    const allocator = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, allocator, .{ .cols = 12, .rows = 4 });
    defer term.deinit(allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    var state: State = .{};
    defer state.deinit(allocator);
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 14, .rows = 6, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const rect: Rect = .{ .width = 14, .height = 6 };
    stream.nextSlice("\x1b[H中文e\xcc\x81\x1b[2;1HSTABLE");
    try state.update(allocator, &term);
    try draw(allocator, &cache, &screen, &term, &state, rect, .{ 0, 0 }, true, .{ .index = 6 }, "test", true);
    try std.testing.expectEqualStrings("中", screen.readCell(1, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("文", screen.readCell(3, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("e\xcc\x81", screen.readCell(5, 1).?.char.grapheme);
    for (0..50) |iteration| {
        stream.nextSlice(if (iteration % 2 == 0) "\x1b[HA\x1b[K" else "\x1b[H界\x1b[K");
        try state.update(allocator, &term);
        try draw(allocator, &cache, &screen, &term, &state, rect, .{ 0, 0 }, true, .{ .index = 6 }, "test", false);
        try std.testing.expectEqualStrings(if (iteration % 2 == 0) "A" else "界", screen.readCell(1, 1).?.char.grapheme);
        try std.testing.expectEqualStrings(" ", screen.readCell(2, 1).?.char.grapheme);
        try std.testing.expectEqualStrings(" ", screen.readCell(5, 1).?.char.grapheme);
        for ("STABLE", 1..) |_, x| try std.testing.expectEqualStrings("STABLE"[x - 1 .. x], screen.readCell(@intCast(x), 2).?.char.grapheme);
    }
    stream.nextSlice("\x1b[?5h");
    try state.update(allocator, &term);
    try draw(allocator, &cache, &screen, &term, &state, rect, .{ 0, 0 }, true, .{ .index = 6 }, "test", false);
    try std.testing.expect(screen.readCell(1, 2).?.style.reverse);
    try term.resize(allocator, .{ .cols = 6, .rows = 4 });
    try state.update(allocator, &term);
    screen.clear();
    try draw(allocator, &cache, &screen, &term, &state, .{ .x = 6, .width = 8, .height = 6 }, .{ 0, 0 }, true, .{ .index = 6 }, "test", true);
    try std.testing.expectEqualStrings("界", screen.readCell(7, 1).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(1, 1).?.char.grapheme);
}

test "pane hyperlinks follow captured text through updates scrolling and resize" {
    const allocator = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, allocator, .{ .cols = 12, .rows = 4 });
    defer term.deinit(allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    var state: State = .{};
    defer state.deinit(allocator);
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 14, .rows = 6, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const rect: Rect = .{ .width = 14, .height = 6 };
    stream.nextSlice("\x1b]8;id=first;https://example.com/first\x1b\\中文e\xcc\x81\x1b]8;;\x1b\\ plain");
    try state.update(allocator, &term);
    // 模拟同步绘制暂停期间，终端继续清除页面和输出新内容。
    stream.nextSlice("\x1bcREPLACED");
    try draw(allocator, &cache, &screen, &term, &state, rect, .{ 0, 0 }, true, .default, "test", true);
    for ([_]u16{ 1, 3, 5 }) |column| {
        const cell = screen.readCell(column, 1).?;
        try std.testing.expectEqualStrings("https://example.com/first", cell.link.uri);
        try std.testing.expectEqualStrings("id=first", cell.link.params);
    }
    try std.testing.expectEqualStrings("", screen.readCell(6, 1).?.link.uri);
    try state.update(allocator, &term);
    try draw(allocator, &cache, &screen, &term, &state, rect, .{ 0, 0 }, true, .default, "test", false);
    try std.testing.expectEqualStrings("", screen.readCell(1, 1).?.link.uri);
    stream.nextSlice("\x1b[H\x1b]8;;https://example.com/second\x07LINK\x1b]8;;\x07\r\n1\r\n2\r\n3\r\n4\r\n5");
    term.scrollViewport(.top);
    try state.update(allocator, &term);
    try draw(allocator, &cache, &screen, &term, &state, rect, .{ 0, 0 }, true, .default, "test", false);
    try std.testing.expectEqualStrings("https://example.com/second", screen.readCell(1, 1).?.link.uri);
    try term.resize(allocator, .{ .cols = 6, .rows = 4 });
    term.scrollViewport(.top);
    try state.update(allocator, &term);
    try draw(allocator, &cache, &screen, &term, &state, .{ .width = 8, .height = 6 }, .{ 0, 0 }, true, .default, "test", true);
    try std.testing.expectEqualStrings("https://example.com/second", screen.readCell(1, 1).?.link.uri);
}
