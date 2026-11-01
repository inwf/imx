const std = @import("std");
const sys = @import("sys.zig");

pub const reset_keyboard = "\x1b[<65535u\x1b[=0u";
pub const reset_screen = "\x1b[0m\x1b[0\"q\x1b]8;;\x1b\\\x1b(B\x1b)B\x1b*B\x1b+B\x0f\x1b}" ++ reset_keyboard;

// 先终止未完成的控制序列，再离开备用屏幕，最后恢复主屏幕的显示和输入模式。
pub const reset = "\x18\x1b\\\x1b[?2026l" ++ reset_keyboard ++
    "\x1b[?1049l\x1b[?1047l\x1b[?47l" ++
    "\x1b[2l\x1b[4l\x1b[12h\x1b[20l" ++
    "\x1b[?1l\x1b[?5l\x1b[?6l\x1b[?7h\x1b[?45l\x1b[?1045l\x1b[?69l\x1b[r" ++
    "\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l" ++
    "\x1b[?66l\x1b[?67l\x1b>\x1b[?2004l\x1b[>4;0m" ++
    "\x1b[?2031l\x1b[?2033l\x1b[?2048l\x1b[?5522l\x1b[?25h\x1b[0 q" ++ reset_screen;

pub fn finish(writer: *std.Io.Writer, size: sys.Size) !void {
    try writer.writeAll(reset);
    try writer.writeAll("\x1b[3g");
    var col: usize = 8;
    while (col < size.cols) : (col += 8) try writer.print("\x1b[{d}G\x1bH", .{col + 1});
    // 在底部追加空行，保留会话内容并为外层提示符提供完整的一行。
    try writer.print("\x1b[{d};1H\r\n", .{size.rows});
}

test "finish restores shell display and input after interrupted application output" {
    const vt = @import("ghostty-vt");
    const allocator = std.testing.allocator;
    const size: sys.Size = .{ .rows = 24, .cols = 80 };
    for ([_][]const u8{ "", "\x1b[", "\x1b]2;unfinished", "\x1bPunfinished", "\x1b_unfinished" }) |unfinished| {
        var term = try vt.Terminal.init(std.testing.io, allocator, .{ .cols = size.cols, .rows = size.rows });
        defer term.deinit(allocator);
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice("KEPT\x1b]4;1;rgb:12/34/56\x1b\\\x1b]11;rgb:65/43/21\x1b\\");
        const colors = term.colors;
        stream.nextSlice("\x1b[=1u\x1b[>3u\x1b[>5u\x1b[?1049h\x1b[>7u\x1b[?2026h");
        stream.nextSlice("\x1b[3;12r\x1b[?69h\x1b[4;30s\x1b[?6h\x1b[?7l\x1b[4h\x1b[20h\x1b[?5h\x1b[?45h\x1b[?1045h");
        stream.nextSlice("\x1b[?1h\x1b=\x1b[?67h\x1b[?1003h\x1b[?1016h\x1b[?1004h\x1b[?2004h\x1b[>4;2m\x1b[?25l\x1b[3g");
        stream.nextSlice("\x1b[31m\x1b[1\"q\x1b(0\x1b]8;;https://example.com\x1b\\");
        stream.nextSlice(unfinished);
        var builder = std.Io.Writer.Allocating.init(allocator);
        defer builder.deinit();
        try finish(&builder.writer, size);
        stream.nextSlice(builder.written());
        try std.testing.expectEqual(.primary, term.screens.active_key);
        try std.testing.expectEqual(@as(u16, 0), term.scrolling_region.top);
        try std.testing.expectEqual(@as(u16, 23), term.scrolling_region.bottom);
        try std.testing.expectEqual(@as(u16, 0), term.scrolling_region.left);
        try std.testing.expectEqual(@as(u16, 79), term.scrolling_region.right);
        inline for (.{ .origin, .insert, .linefeed, .reverse_colors, .reverse_wrap, .reverse_wrap_extended, .cursor_keys, .keypad_keys, .backarrow_key_mode, .mouse_event_any, .mouse_format_sgr_pixels, .focus_event, .bracketed_paste, .synchronized_output }) |mode| {
            try std.testing.expect(!term.modes.get(mode));
        }
        try std.testing.expect(term.modes.get(.wraparound));
        try std.testing.expect(term.modes.get(.cursor_visible));
        try std.testing.expect(!term.flags.modify_other_keys_2);
        try std.testing.expect(!term.screens.active.cursor.protected);
        try std.testing.expect(term.screens.active.cursor.hyperlink == null);
        try std.testing.expectEqual(@as(u5, 0), term.screens.active.kitty_keyboard.current().int());
        try std.testing.expectEqualDeep(colors.palette.current, term.colors.palette.current);
        try std.testing.expectEqualDeep(colors.background, term.colors.background);
        try std.testing.expectEqual(@as(u16, 23), term.screens.active.cursor.y);
        try std.testing.expectEqual(@as(u16, 0), term.screens.active.cursor.x);
        for (0..size.cols) |col| try std.testing.expectEqual(col != 0 and col % 8 == 0, term.tabstops.get(col));
        stream.nextSlice("q#é中文");
        var text = std.Io.Writer.Allocating.init(allocator);
        defer text.deinit();
        var formatter = vt.formatter.TerminalFormatter.init(&term, .plain);
        formatter.extra = .none;
        try formatter.format(&text.writer);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "KEPT") != null);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "q#é中文") != null);
        stream.nextSlice("\x1b[?1049h");
        try std.testing.expectEqual(@as(u5, 0), term.screens.active.kitty_keyboard.current().int());
    }
}
