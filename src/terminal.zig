const std = @import("std");
pub const vt = @import("ghostty-vt");
const sys = @import("sys.zig");

pub const history_lines = 10_000;
pub const history_bytes = 2 * 1024 * 1024;

pub fn init(allocator: std.mem.Allocator, io: std.Io, size: sys.Size) !vt.Terminal {
    var term = try vt.Terminal.init(io, allocator, .{
        .cols = size.cols,
        .rows = size.rows,
        .max_scrollback_lines = history_lines,
        .max_scrollback_bytes = history_bytes,
    });
    errdefer term.deinit(allocator);
    try trim(&term);
    return term;
}

pub fn trim(term: *vt.Terminal) !void {
    var screens = term.screens.all.iterator();
    while (screens.next()) |entry| {
        const screen = entry.value.*;
        var next = screen.pages.pages.first;
        while (next) |node| {
            next = node.next;
            // 光标持有的样式和超链接引用属于当前页面，需要保持该页面的引用表。
            if (node == screen.cursor.page_pin.node and (screen.cursor.style_id != 0 or screen.cursor.hyperlink_id != 0)) continue;
            _ = try screen.pages.compact(node);
        }
        screen.cursorReload();
        const pool = &screen.pages.pool.pages;
        while (pool.free.pop()) |page| pool.release(page);
    }
}

pub fn history(allocator: std.mem.Allocator, term: *vt.Terminal) ![]u8 {
    var builder = std.Io.Writer.Allocating.init(allocator);
    defer builder.deinit();
    var formatter = vt.formatter.TerminalFormatter.init(term, .plain);
    formatter.content = .{ .selection = null };
    formatter.extra = .none;
    try formatter.format(&builder.writer);
    try builder.writer.writeByte('\n');
    return builder.toOwnedSlice();
}

pub fn restore(allocator: std.mem.Allocator, term: *vt.Terminal) ![]u8 {
    var builder = std.Io.Writer.Allocating.init(allocator);
    defer builder.deinit();
    const synchronized = term.modes.get(.synchronized_output);
    term.modes.set(.synchronized_output, false);
    defer term.modes.set(.synchronized_output, synchronized);
    try builder.writer.writeAll("\x1b[?2026l\x1b[?1049l\x1b[0m\x1b[2J\x1b[H");
    if (term.screens.active_key == .alternate) {
        term.screens.switchTo(.primary);
        defer term.screens.switchTo(.alternate);
        try restoreScreen(&builder.writer, term, false);
        term.screens.switchTo(.alternate);
        try builder.writer.writeAll("\x1b[?1049h\x1b[0m\x1b[2J\x1b[H");
    }
    try restoreScreen(&builder.writer, term, true);
    if (term.getPwd()) |pwd| try builder.writer.print("\x1b]7;{s}\x1b\\", .{pwd});
    if (term.getTitle()) |title| try builder.writer.print("\x1b]2;{s}\x07", .{title});
    const style: u8 = if (term.cursor.is_default) 0 else switch (term.screens.active.cursor.cursor_style) {
        .block, .block_hollow => if (term.modes.get(.cursor_blinking)) 1 else 2,
        .underline => if (term.modes.get(.cursor_blinking)) 3 else 4,
        .bar => if (term.modes.get(.cursor_blinking)) 5 else 6,
    };
    try builder.writer.print("\x1b[{d} q", .{style});
    return builder.toOwnedSlice();
}

fn restoreScreen(writer: *std.Io.Writer, term: *vt.Terminal, modes: bool) !void {
    const pages = &term.screens.active.pages;
    const top = pages.getTopLeft(.screen);
    const active = pages.getTopLeft(.active);
    if (!top.eql(active)) {
        var bottom = active.up(1).?;
        bottom.x = @intCast(pages.cols - 1);
        var scroll = vt.formatter.TerminalFormatter.init(term, .vt);
        scroll.content = .{ .selection = vt.Selection.init(top, bottom, false) };
        scroll.extra = .none;
        try scroll.format(writer);
        for (0..pages.rows) |_| try writer.writeAll("\r\n");
        try writer.writeAll("\x1b[0m\x1b[2J\x1b[H");
    }
    var visible = vt.formatter.TerminalFormatter.init(term, .vt);
    visible.content = .{ .selection = vt.Selection.init(
        pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        pages.pin(.{ .active = .{ .x = @intCast(pages.cols - 1), .y = @intCast(pages.rows - 1) } }).?,
        false,
    ) };
    visible.extra = .{
        .palette = false,
        .modes = modes,
        .scrolling_region = true,
        .tabstops = true,
        .pwd = false,
        .keyboard = true,
        .screen = .all,
    };
    try visible.format(writer);
}

test "restore preserves the receiving terminal colors and styled content" {
    const allocator = std.testing.allocator;
    for (0..3) |scenario| {
        var source = try init(allocator, std.testing.io, .{ .rows = 24, .cols = 80 });
        defer source.deinit(allocator);
        var input = source.vtStream();
        defer input.deinit();
        if (scenario != 0) {
            input.nextSlice("\x1b]4;1;rgb:ff/00/00\x1b\\\x1b]10;rgb:00/ff/00\x1b\\\x1b]11;rgb:00/00/ff\x1b\\\x1b]12;rgb:ff/ff/00\x1b\\");
            for (0..40) |_| input.nextSlice("\x1b[31mHISTORY\x1b[0m\r\n");
            if (scenario == 2) input.nextSlice("\x1b[?1049h");
            input.nextSlice("\x1b[2J\x1b[H\x1b[1;31mINDEXED\x1b[0m\r\n\x1b[38;2;18;52;86mRGB\x1b[0m");
        }
        const snapshot = try restore(allocator, &source);
        defer allocator.free(snapshot);

        var target = try init(allocator, std.testing.io, .{ .rows = 24, .cols = 80 });
        defer target.deinit(allocator);
        var output = target.vtStream();
        defer output.deinit();
        output.nextSlice("\x1b]4;0;rgb:12/34/56\x1b\\\x1b]4;1;rgb:ab/cd/ef\x1b\\\x1b]4;255;rgb:65/43/21\x1b\\\x1b]10;rgb:ee/dd/cc\x1b\\\x1b]11;rgb:11/22/33\x1b\\\x1b]12;rgb:aa/bb/cc\x1b\\");
        const colors = target.colors;
        output.nextSlice(snapshot);
        try std.testing.expectEqualDeep(colors.palette.current, target.colors.palette.current);
        try std.testing.expectEqualDeep(colors.foreground, target.colors.foreground);
        try std.testing.expectEqualDeep(colors.background, target.colors.background);
        try std.testing.expectEqualDeep(colors.cursor, target.colors.cursor);

        var expected = std.Io.Writer.Allocating.init(allocator);
        defer expected.deinit();
        var actual = std.Io.Writer.Allocating.init(allocator);
        defer actual.deinit();
        var source_formatter = vt.formatter.TerminalFormatter.init(&source, .vt);
        source_formatter.extra = .none;
        var target_formatter = vt.formatter.TerminalFormatter.init(&target, .vt);
        target_formatter.extra = .none;
        try source_formatter.format(&expected.writer);
        try target_formatter.format(&actual.writer);
        try std.testing.expectEqualStrings(expected.written(), actual.written());
    }
}

test "restore preserves primary history while the alternate screen is active" {
    const allocator = std.testing.allocator;
    var source = try init(allocator, std.testing.io, .{ .rows = 24, .cols = 80 });
    defer source.deinit(allocator);
    var input = source.vtStream();
    defer input.deinit();
    for (0..40) |_| input.nextSlice("PRIMARY_HISTORY\r\n");
    const primary = try history(allocator, &source);
    defer allocator.free(primary);
    input.nextSlice("\x1b[?1049hALTERNATE_SCREEN\x1b[7;4H");
    const alternate = try history(allocator, &source);
    defer allocator.free(alternate);
    const snapshot = try restore(allocator, &source);
    defer allocator.free(snapshot);
    var target = try init(allocator, std.testing.io, .{ .rows = 24, .cols = 80 });
    defer target.deinit(allocator);
    var output = target.vtStream();
    defer output.deinit();
    output.nextSlice(snapshot);
    const restored_alternate = try history(allocator, &target);
    defer allocator.free(restored_alternate);
    try std.testing.expectEqualStrings(alternate, restored_alternate);
    try std.testing.expectEqual(source.screens.active.cursor.x, target.screens.active.cursor.x);
    try std.testing.expectEqual(source.screens.active.cursor.y, target.screens.active.cursor.y);
    output.nextSlice("\x1b[?1049l");
    const restored_primary = try history(allocator, &target);
    defer allocator.free(restored_primary);
    try std.testing.expectEqualStrings(primary, restored_primary);
}

test "history interprets overwritten output and restores Unicode screen" {
    const allocator = std.testing.allocator;
    var term = try init(allocator, std.testing.io, .{ .rows = 24, .cols = 80 });
    defer term.deinit(allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("old\r\x1b[2K\x1b[32m新内容\x1b[0m\r\n");
    const plain = try history(allocator, &term);
    defer allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "old") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "新内容") != null);
    const state = try restore(allocator, &term);
    defer allocator.free(state);
    var other = try init(allocator, std.testing.io, .{ .rows = 24, .cols = 80 });
    defer other.deinit(allocator);
    var other_stream = other.vtStream();
    defer other_stream.deinit();
    other_stream.nextSlice(state);
    const after = try history(allocator, &other);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(plain, after);
}

test "trim preserves colored text, graphemes, hyperlinks and subsequent output" {
    const allocator = std.testing.allocator;
    var term = try init(allocator, std.testing.io, .{ .rows = 24, .cols = 80 });
    defer term.deinit(allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[31mCOLOR\x1b[0m e\xcc\x81 \x1b]8;;https://example.com\x1b\\LINK\x1b]8;;\x1b\\\r\n");
    const before = try restore(allocator, &term);
    defer allocator.free(before);
    try trim(&term);
    const after = try restore(allocator, &term);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    stream.nextSlice("\x1b[32m\x1b]8;;https://example.org\x1b\\");
    try trim(&term);
    stream.nextSlice("CONTINUED\x1b]8;;\x1b\\\x1b[0m\r\n");
    try trim(&term);
    const text = try history(allocator, &term);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "COLOR e\xcc\x81 LINK") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "CONTINUED") != null);
}
