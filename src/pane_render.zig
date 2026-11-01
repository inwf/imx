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

pub fn draw(frame: std.mem.Allocator, screen: *vaxis.Screen, term: *vt.Terminal, state: *const vt.RenderState, rect: Rect, offset: [2]u16, selected: bool, focused_border_color: vaxis.Color, title: []const u8) !void {
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
    const rows = state.row_data.items(.cells);
    const selections = state.row_data.items(.selection);
    for (rows, 0..) |cells, y| {
        if (y >= rect.height - 2) break;
        for (0..cells.len) |x| {
            if (x >= rect.width - 2) break;
            const cell = cells.get(x);
            if (cell.raw.wide == .spacer_tail or cell.raw.wide == .spacer_head) continue;
            var text: std.Io.Writer.Allocating = .init(frame);
            const cp = cell.raw.codepoint();
            try text.writer.printUnicodeCodepoint(if (cp == 0) ' ' else cp);
            if (cell.raw.content_tag == .codepoint_grapheme) for (cell.grapheme) |extra| try text.writer.printUnicodeCodepoint(extra);
            var style: vt.Style = if (cell.raw.style_id == 0) .{} else cell.style;
            switch (cell.raw.content_tag) {
                .bg_color_palette => style.bg_color = .{ .palette = cell.raw.content.color_palette.data },
                .bg_color_rgb => style.bg_color = .{ .rgb = .{ .r = cell.raw.content.color_rgb.r, .g = cell.raw.content.color_rgb.g, .b = cell.raw.content.color_rgb.b } },
                else => {},
            }
            const width: u8 = if (cell.raw.wide == .wide) 2 else 1;
            const highlighted = if (selections[y]) |range| x >= range[0] and x <= range[1] else false;
            const sx = @as(i32, rect.x) + 1 + @as(i32, @intCast(x)) - offset[0];
            const sy = @as(i32, rect.y) + 1 + @as(i32, @intCast(y)) - offset[1];
            const value: vaxis.Cell = .{
                .char = .{ .grapheme = try text.toOwnedSlice(), .width = width },
                .style = .{
                    .fg = color(style.fg_color, state.colors.palette, term.colors.foreground.get()),
                    .bg = color(style.bg_color, state.colors.palette, term.colors.background.get()),
                    .ul = color(style.underline_color, state.colors.palette, null),
                    .bold = style.flags.bold,
                    .dim = style.flags.faint,
                    .italic = style.flags.italic,
                    .blink = style.flags.blink,
                    .reverse = (style.flags.inverse != term.modes.get(.reverse_colors)) != highlighted,
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
    }
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
    var state: vt.RenderState = .empty;
    defer state.deinit(allocator);
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 100, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try state.update(allocator, &term);
    try draw(arena.allocator(), &screen, &term, &state, .{ .x = 50, .width = 50, .height = 30 }, .{ 0, 0 }, true, .{ .index = 6 }, "test");
    try std.testing.expectEqual(vaxis.Color{ .index = 4 }, screen.readCell(52, 2).?.style.bg);
    try std.testing.expectEqualStrings("A", screen.readCell(52, 1).?.char.grapheme);
    const selected: vaxis.Color = .{ .rgb = .{ 0x33, 0xaa, 0xff } };
    try draw(arena.allocator(), &screen, &term, &state, .{ .x = 50, .width = 50, .height = 30 }, .{ 0, 0 }, true, selected, "test");
    for ([_][2]u16{ .{ 50, 0 }, .{ 52, 0 }, .{ 99, 29 } }) |position| {
        const style = screen.readCell(position[0], position[1]).?.style;
        try std.testing.expectEqual(selected, style.fg);
        try std.testing.expect(style.bold);
    }
    try draw(arena.allocator(), &screen, &term, &state, .{ .x = 50, .width = 50, .height = 30 }, .{ 0, 0 }, false, selected, "test");
    try std.testing.expectEqual(vaxis.Color{ .index = 8 }, screen.readCell(50, 0).?.style.fg);
    try std.testing.expect(!screen.readCell(50, 0).?.style.bold);
}
