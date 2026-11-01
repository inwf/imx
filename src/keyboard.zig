const std = @import("std");
const vaxis = @import("vaxis");
const vt = @import("ghostty-vt");

pub const Action = enum {
    detach,
    split_right,
    split_down,
    close_pane,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    focus_1,
    focus_2,
    focus_3,
    focus_4,
    focus_5,
    focus_6,
    focus_7,
    focus_8,
    focus_9,
    focus_10,
};
pub const Modifiers = vaxis.Key.Modifiers;

pub const Binding = struct {
    codepoint: u21,
    mods: Modifiers = .{},

    pub fn keyCodepoint(name: []const u8) !u21 {
        inline for (.{ "enter", "tab", "escape", "space", "backspace", "insert", "delete", "left", "right", "up", "down", "page_up", "page_down", "home", "end", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12" }) |key| {
            if (std.ascii.eqlIgnoreCase(name, key)) return @field(vaxis.Key, key);
        }
        const view = std.unicode.Utf8View.init(name) catch return error.InvalidKeybindingKey;
        var it = view.iterator();
        const cp = it.nextCodepoint() orelse return error.InvalidKeybindingKey;
        if (it.nextCodepoint() != null or cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.InvalidKeybindingKey;
        return if (cp >= 'A' and cp <= 'Z') cp + 0x20 else cp;
    }

    pub fn matches(self: Binding, key: vaxis.Key, bytes: []const u8) bool {
        if (key.matchExact(self.codepoint, self.mods)) return true;
        // 普通终端的部分 Ctrl 组合与 Tab、Enter、Backspace 等按键共用字节。
        if (!self.mods.ctrl or self.mods.shift or self.mods.super or self.mods.alt != key.mods.alt) return false;
        const control: u8 = switch (self.codepoint) {
            'a'...'z' => @intCast(self.codepoint - 0x60),
            '@', ' ' => 0,
            '['...'_' => @intCast(self.codepoint - 0x40),
            '?' => 0x7f,
            else => return false,
        };
        return (bytes.len == 1 and bytes[0] == control) or
            (bytes.len == 2 and bytes[0] == 0x1b and bytes[1] == control);
    }
};

pub const Bindings = struct {
    detach: Binding = .{ .codepoint = '\\', .mods = .{ .alt = true } },
    split_right: Binding = .{ .codepoint = 'd', .mods = .{ .alt = true } },
    split_down: Binding = .{ .codepoint = 'd', .mods = .{ .alt = true, .shift = true } },
    close_pane: Binding = .{ .codepoint = 'w', .mods = .{ .alt = true } },
    focus_left: Binding = .{ .codepoint = vaxis.Key.left, .mods = .{ .alt = true } },
    focus_right: Binding = .{ .codepoint = vaxis.Key.right, .mods = .{ .alt = true } },
    focus_up: Binding = .{ .codepoint = vaxis.Key.up, .mods = .{ .alt = true } },
    focus_down: Binding = .{ .codepoint = vaxis.Key.down, .mods = .{ .alt = true } },
    focus_1: Binding = .{ .codepoint = '1', .mods = .{ .alt = true } },
    focus_2: Binding = .{ .codepoint = '2', .mods = .{ .alt = true } },
    focus_3: Binding = .{ .codepoint = '3', .mods = .{ .alt = true } },
    focus_4: Binding = .{ .codepoint = '4', .mods = .{ .alt = true } },
    focus_5: Binding = .{ .codepoint = '5', .mods = .{ .alt = true } },
    focus_6: Binding = .{ .codepoint = '6', .mods = .{ .alt = true } },
    focus_7: Binding = .{ .codepoint = '7', .mods = .{ .alt = true } },
    focus_8: Binding = .{ .codepoint = '8', .mods = .{ .alt = true } },
    focus_9: Binding = .{ .codepoint = '9', .mods = .{ .alt = true } },
    focus_10: Binding = .{ .codepoint = '0', .mods = .{ .alt = true } },

    fn action(self: Bindings, event: vaxis.Event, bytes: []const u8) ?Action {
        if (event != .key_press) return null;
        inline for (std.enums.values(Action)) |candidate| {
            if (@field(self, @tagName(candidate)).matches(event.key_press, bytes)) return candidate;
        }
        return null;
    }
};

pub const Decoder = struct {
    parser: vaxis.Parser = .{},

    pub fn decode(self: *Decoder, bytes: []const u8) !vaxis.Parser.Result {
        var decoded = try self.decodeKey(bytes);
        if (decoded.event) |*event| {
            if (event.* == .key_press) {
                const key = &event.key_press;
                if (key.codepoint >= 'A' and key.codepoint <= 'Z') {
                    key.codepoint += 0x20;
                    const implicit_shift = bytes.len == 1 or (bytes.len == 2 and bytes[0] == 0x1b);
                    if (implicit_shift and !key.mods.caps_lock) key.mods.shift = true;
                }
            }
        }
        return decoded;
    }

    fn decodeKey(self: *Decoder, bytes: []const u8) !vaxis.Parser.Result {
        if (bytes.len == 1 and bytes[0] >= 0x1c and bytes[0] <= 0x1f) {
            return .{ .n = 1, .event = .{ .key_press = .{
                .codepoint = bytes[0] + 0x40,
                .mods = .{ .ctrl = true },
            } } };
        }
        if (bytes[0] != 0x1b) {
            const length = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .n = 1, .event = null };
            if (bytes.len < length) return .{ .n = 0, .event = null };
            if (!std.unicode.utf8ValidateSlice(bytes[0..length])) return .{ .n = length, .event = null };
        } else if (bytes.len > 1 and std.mem.indexOfScalar(u8, "OPX[]^_", bytes[1]) == null) {
            var decoded = try self.decodeKey(bytes[1..]);
            if (decoded.n == 0) return decoded;
            decoded.n += 1;
            if (decoded.event) |*event| {
                if (event.* == .key_press) event.key_press.mods.alt = true;
            }
            return decoded;
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
    bindings: Bindings = .{},
    workspace: bool = false,
    report_events: bool = false,
    pending: [read_size]u8 = undefined,
    pending_len: usize = 0,
    output: [read_size * 2]u8 = undefined,
    output_len: usize = 0,
    deadline: ?i64 = null,
    pasting: bool = false,

    pub const Result = struct { bytes: []const u8, action: ?Action, event: ?vaxis.Event = null };

    pub fn feed(self: *Input, bytes: []const u8, now: i64) !Result {
        std.debug.assert(bytes.len <= read_size);
        self.output_len = 0;
        for (bytes) |byte| {
            const lone_escape = self.pending_len == 1 and self.pending[0] == 0x1b;
            const control_string = !self.pasting and self.pending_len >= 2 and self.pending[0] == 0x1b and std.mem.indexOfScalar(u8, "PX]^_", self.pending[1]) != null;
            if (!control_string and self.pending_len != 0 and (byte == 0x1b or (byte < 0x20 and !lone_escape))) {
                if (self.escapeAction()) |action| return .{ .bytes = self.output[0..self.output_len], .action = action };
                self.flush();
            }
            if (byte == 0x1b and self.pending_len == 0) {
                self.pending[0] = byte;
                self.pending_len = 1;
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
                            if (self.bindings.action(event, self.pending[0..self.pending_len])) |action| {
                                if (self.workspace == (action != .detach)) {
                                    self.pending_len = 0;
                                    self.deadline = null;
                                    return .{ .bytes = self.output[0..self.output_len], .action = action };
                                }
                            }
                        },
                    }
                    if (self.report_events and (!self.pasting or event == .paste_start)) {
                        self.flush();
                        return .{ .bytes = self.output[0..self.output_len], .action = null, .event = event };
                    }
                }
                self.flush();
            } else if (self.pending_len == self.pending.len) self.flush();
        }
        self.deadline = if (self.pending_len == 0) null else now + sequence_timeout_ms;
        return .{ .bytes = self.output[0..self.output_len], .action = null };
    }

    pub fn expire(self: *Input) Result {
        const action = self.escapeAction();
        const event: ?vaxis.Event = if (self.report_events and !self.pasting and self.pending_len == 1 and self.pending[0] == 0x1b) .{ .key_press = .{ .codepoint = vaxis.Key.escape } } else null;
        const bytes = self.takePending();
        return .{ .bytes = if (action == null) bytes else "", .action = action, .event = event };
    }

    fn escapeAction(self: *Input) ?Action {
        if (self.pasting or self.pending_len != 1 or self.pending[0] != 0x1b) return null;
        const action = self.bindings.action(.{ .key_press = .{ .codepoint = vaxis.Key.escape } }, "\x1b") orelse return null;
        return if (self.workspace == (action != .detach)) action else null;
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
        try std.testing.expectEqual(null, (Bindings{}).action(result.event.?, bytes));
    }
    const released = try decoder.decode("\x1b[92;3:3u");
    try std.testing.expect(released.event.? == .key_release);
    try std.testing.expectEqual(null, (Bindings{}).action(released.event.?, "\x1b[92;3:3u"));
}
