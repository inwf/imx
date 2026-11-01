const std = @import("std");
const vaxis = @import("vaxis");
const vt = @import("ghostty-vt");

pub const Action = enum { detach };

pub fn shortcut(event: vaxis.Event) ?Action {
    return switch (event) {
        .key_press => |key| if (key.matchExact('\\', .{ .ctrl = true })) .detach else null,
        else => null,
    };
}

pub const Decoder = struct {
    parser: vaxis.Parser = .{},

    pub fn decode(self: *Decoder, bytes: []const u8) !vaxis.Parser.Result {
        if (bytes.len == 1 and bytes[0] >= 0x1c and bytes[0] <= 0x1f) {
            return .{ .n = 1, .event = .{ .key_press = .{
                .codepoint = bytes[0] + 0x40,
                .mods = .{ .ctrl = true },
            } } };
        }
        const decoded = try self.parser.parse(bytes, null);
        // Ghostty 提供 xterm modifyOtherKeys 的 CSI 参数解码。
        if (decoded.event == null and decoded.n != 0 and std.mem.startsWith(u8, bytes, "\x1b[") and std.mem.endsWith(u8, bytes, "~") and std.mem.indexOfScalar(u8, bytes, ':') == null) {
            var parser = vt.Parser.init();
            defer parser.deinit();
            for (bytes) |byte| {
                for (parser.next(byte)) |maybe_action| {
                    const action = maybe_action orelse continue;
                    if (action != .csi_dispatch) continue;
                    const csi = action.csi_dispatch;
                    if (csi.final != '~' or csi.intermediates.len != 0 or csi.params.len != 3 or csi.params[0] != 27) continue;
                    if (csi.params[1] == 0 or csi.params[1] > 256) continue;
                    return .{ .n = bytes.len, .event = .{ .key_press = .{
                        .codepoint = csi.params[2],
                        .mods = @bitCast(@as(u8, @intCast(csi.params[1] - 1))),
                    } } };
                }
            }
            return .{ .n = bytes.len, .event = null };
        }
        return decoded;
    }
};

pub const Input = struct {
    pub const read_size = 4096;
    pub const sequence_timeout_ms = 100;

    decoder: Decoder = .{},
    pending: [read_size]u8 = undefined,
    pending_len: usize = 0,
    output: [read_size * 2]u8 = undefined,
    output_len: usize = 0,
    deadline: ?i64 = null,
    pasting: bool = false,

    pub const Result = struct { bytes: []const u8, action: ?Action };

    pub fn feed(self: *Input, bytes: []const u8, now: i64) !Result {
        std.debug.assert(bytes.len <= read_size);
        self.output_len = 0;
        for (bytes) |byte| {
            if (byte == 0x1b or (byte < 0x20 and self.pending_len != 0)) self.flush();
            if (byte == 0x1b) {
                self.pending[0] = byte;
                self.pending_len = 1;
                continue;
            }
            if (self.pending_len == 0) {
                if (!self.pasting and byte < 0x20) {
                    const decoded = try self.decoder.decode(&.{byte});
                    if (decoded.event) |event| {
                        if (shortcut(event)) |action| return .{ .bytes = self.output[0..self.output_len], .action = action };
                    }
                }
                self.append(&.{byte});
                continue;
            }
            self.pending[self.pending_len] = byte;
            self.pending_len += 1;
            const decoded = try self.decoder.decode(self.pending[0..self.pending_len]);
            if (decoded.n != 0) {
                if (decoded.event) |event| {
                    switch (event) {
                        .paste_start => self.pasting = true,
                        .paste_end => self.pasting = false,
                        else => if (!self.pasting) {
                            if (shortcut(event)) |action| {
                                self.pending_len = 0;
                                self.deadline = null;
                                return .{ .bytes = self.output[0..self.output_len], .action = action };
                            }
                        },
                    }
                }
                self.flush();
            } else if (self.pending[1] != '[' or self.pending_len == self.pending.len) self.flush();
        }
        self.deadline = if (self.pending_len == 0) null else now + sequence_timeout_ms;
        return .{ .bytes = self.output[0..self.output_len], .action = null };
    }

    pub fn takePending(self: *Input) []const u8 {
        const bytes = self.pending[0..self.pending_len];
        self.pending_len = 0;
        self.deadline = null;
        return bytes;
    }

    fn flush(self: *Input) void {
        const bytes = self.takePending();
        self.append(bytes);
    }

    fn append(self: *Input, bytes: []const u8) void {
        @memcpy(self.output[self.output_len..][0..bytes.len], bytes);
        self.output_len += bytes.len;
    }
};

test "keyboard encodings produce consistent shortcut events" {
    var decoder: Decoder = .{};
    for ([_][]const u8{ "\x10", "\x1b[112;5u", "\x1b[27;5;112~" }) |bytes| {
        const result = try decoder.decode(bytes);
        try std.testing.expectEqual(bytes.len, result.n);
        try std.testing.expect(result.event.? == .key_press);
        try std.testing.expect(result.event.?.key_press.matchExact('p', .{ .ctrl = true }));
        try std.testing.expectEqual(null, shortcut(result.event.?));
    }
    const released = try decoder.decode("\x1b[92;5:3u");
    try std.testing.expect(released.event.? == .key_release);
    try std.testing.expectEqual(null, shortcut(released.event.?));
}
