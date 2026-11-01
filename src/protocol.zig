const std = @import("std");
const sys = @import("sys.zig");

pub const max_payload = 128 * 1024;
pub const max_queue = 256 * 1024;
pub const Tag = enum(u16) { attach = 1, list = 2, cat = 3, detach = 4, kill = 5, input = 6, resize = 7, output = 8, ok = 9, failure = 10, done = 11, info = 12, switch_prepare = 13, switch_session = 14, switch_result = 15, switch_commit = 16, switch_cancel = 17 };
pub const client_marker_prefix = "IMX_CLIENT_CAPABILITIES=";
pub const client_marker = client_marker_prefix ++ "switch-v1";
pub const SessionInfo = struct { name: []const u8, pid: c_int, clients: usize, directory: []const u8, created: []const u8 };
pub const Message = struct { tag: Tag, payload: []const u8 };
pub const Attach = struct {
    size: sys.Size,
    name: []const u8,
    cwd: []const u8,
    shell: []const u8,
    environment: []const u8,

    pub fn decode(payload: []const u8) !Attach {
        if (payload.len < 5) return error.InvalidMessage;
        const size = try sys.Size.decode(payload[0..4]);
        var fields = std.mem.splitScalar(u8, payload[4..], 0);
        const name = fields.next() orelse return error.InvalidMessage;
        const cwd = fields.next() orelse return error.InvalidMessage;
        const shell = fields.next() orelse return error.InvalidMessage;
        const environment = fields.rest();
        if (environment.len == 0 or environment[environment.len - 1] != 0) return error.InvalidMessage;
        if (!std.fs.path.isAbsolute(cwd) or !std.fs.path.isAbsolute(shell)) return error.InvalidMessage;
        return .{ .size = size, .name = name, .cwd = cwd, .shell = shell, .environment = environment };
    }
};
pub const ListOptions = struct {
    table: bool = false,
    created_format: [:0]const u8 = sys.default_created_format,
    names_only: bool = false,
    prefix: []const u8 = "",
};

pub fn header(tag: Tag, length: usize) [8]u8 {
    std.debug.assert(length <= max_payload);
    var result: [8]u8 = undefined;
    std.mem.writeInt(u32, result[0..4], @intCast(length), .little);
    std.mem.writeInt(u16, result[4..6], @backingInt(tag), .little);
    std.mem.writeInt(u16, result[6..8], 1, .little);
    return result;
}

pub fn decodeHeader(bytes: *const [8]u8) !struct { tag: Tag, len: usize } {
    if (std.mem.readInt(u16, bytes[6..8], .little) != 1) return error.ProtocolVersionMismatch;
    const length = std.mem.readInt(u32, bytes[0..4], .little);
    if (length > max_payload) return error.MessageTooLarge;
    const tag = std.enums.fromInt(Tag, std.mem.readInt(u16, bytes[4..6], .little)) orelse return error.InvalidMessage;
    return .{ .tag = tag, .len = length };
}

pub fn send(fd: c_int, tag: Tag, payload: []const u8) !void {
    try sys.writeAll(fd, &header(tag, payload.len), true);
    try sys.writeAll(fd, payload, true);
}

pub const Reader = struct {
    bytes: std.ArrayList(u8) = .empty,
    offset: usize = 0,

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    pub fn receive(self: *Reader, allocator: std.mem.Allocator, fd: c_int) !bool {
        if (self.offset != 0) {
            const left = self.bytes.items.len - self.offset;
            std.mem.copyForwards(u8, self.bytes.items[0..left], self.bytes.items[self.offset..]);
            self.bytes.items.len = left;
            self.offset = 0;
        }
        var buffer: [4096]u8 = undefined;
        const n = (try sys.read(fd, &buffer)) orelse return true;
        if (n == 0) return false;
        if (self.bytes.items.len + n > max_payload + 8) return error.MessageTooLarge;
        try self.bytes.appendSlice(allocator, buffer[0..n]);
        return true;
    }

    pub fn next(self: *Reader) !?Message {
        const remaining = self.bytes.items[self.offset..];
        if (remaining.len < 8) return null;
        const h = try decodeHeader(remaining[0..8]);
        if (remaining.len < h.len + 8) return null;
        self.offset += 8 + h.len;
        return .{ .tag = h.tag, .payload = remaining[8..][0..h.len] };
    }
};

pub const Queue = struct {
    bytes: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    limit: usize = max_queue,

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    pub fn pending(self: *const Queue) []const u8 {
        return self.bytes.items[self.offset..];
    }

    pub fn append(self: *Queue, allocator: std.mem.Allocator, bytes: []const u8) !void {
        const left = self.pending().len;
        if (left + bytes.len > self.limit) return error.SlowClient;
        if (self.offset != 0 and self.bytes.items.len + bytes.len > self.limit) {
            std.mem.copyForwards(u8, self.bytes.items[0..left], self.pending());
            self.bytes.items.len = left;
            self.offset = 0;
        }
        try self.bytes.appendSlice(allocator, bytes);
    }

    pub fn message(self: *Queue, allocator: std.mem.Allocator, tag: Tag, payload: []const u8) !void {
        if (self.pending().len + 8 + payload.len > self.limit) return error.SlowClient;
        try self.append(allocator, &header(tag, payload.len));
        try self.append(allocator, payload);
    }

    pub fn flush(self: *Queue, fd: c_int, socket: bool) !void {
        if (self.pending().len == 0) return;
        self.offset += try sys.write(fd, self.pending(), socket);
        if (self.offset == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.offset = 0;
        }
    }
};

test "protocol validates versions and message limits" {
    const h = header(.attach, 42);
    const decoded = try decodeHeader(&h);
    try std.testing.expectEqual(Tag.attach, decoded.tag);
    try std.testing.expectEqual(@as(usize, 42), decoded.len);
    var bad = h;
    bad[6] = 2;
    try std.testing.expectError(error.ProtocolVersionMismatch, decodeHeader(&bad));
    std.mem.writeInt(u32, bad[0..4], max_payload + 1, .little);
    bad[6] = 1;
    try std.testing.expectError(error.MessageTooLarge, decodeHeader(&bad));
}
