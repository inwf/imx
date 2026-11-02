const std = @import("std");
const sys = @import("sys.zig");
const config = @import("config.zig");
const protocol = @import("protocol.zig");
const context = @import("pane_context.zig");

pub const Request = struct {
    fd: c_int,
    name: []u8,
    deadline: i64,
    output: protocol.Queue = .{},
    reader: protocol.Reader = .{},
    bytes: std.ArrayList(u8) = .empty,
    acknowledged: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, state: context.State) !Request {
        const deadline = try sys.monotonicMilliseconds() + 2000;
        var root = try config.Config.initPath(allocator, io, state.directory);
        defer root.deinit();
        const fd = try @import("connection.zig").openExistingNonblocking(io, &root, state.session);
        errdefer sys.close(fd);
        const name = try allocator.dupe(u8, state.session);
        errdefer allocator.free(name);
        var request: Request = .{ .fd = fd, .name = name, .deadline = deadline };
        errdefer request.output.deinit(allocator);
        try request.output.message(allocator, .info, "{}");
        return request;
    }

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        sys.close(self.fd);
        allocator.free(self.name);
        self.output.deinit(allocator);
        self.reader.deinit(allocator);
        self.bytes.deinit(allocator);
    }

    pub fn read(self: *Request, allocator: std.mem.Allocator) !?[]u8 {
        if (!try self.reader.receive(allocator, self.fd)) {
            if (!self.acknowledged or self.reader.bytes.items.len != self.reader.offset) return error.InvalidResponse;
            const info = try std.json.parseFromSlice(protocol.SessionInfo, allocator, self.bytes.items, .{});
            defer info.deinit();
            if (!std.mem.eql(u8, info.value.name, self.name) or info.value.pid <= 0 or !std.fs.path.isAbsolute(info.value.directory)) return error.InvalidResponse;
            return try allocator.dupe(u8, info.value.directory);
        }
        while (try self.reader.next()) |message| switch (message.tag) {
            .ok => {
                if (self.acknowledged or message.payload.len != 0) return error.InvalidMessage;
                self.acknowledged = true;
            },
            .output => {
                if (!self.acknowledged or self.bytes.items.len + message.payload.len > protocol.max_payload) return error.InvalidMessage;
                try self.bytes.appendSlice(allocator, message.payload);
            },
            .failure => return error.SessionDirectoryUnavailable,
            else => return error.InvalidMessage,
        };
        return null;
    }
};
