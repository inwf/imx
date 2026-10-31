const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const config = @import("config.zig");
const protocol = @import("protocol.zig");
const terminal = @import("terminal.zig");

const Query = struct {
    name: []const u8,
    fd: c_int = -1,
    state: enum { pending, running, missing, unresponsive, failed } = .pending,
    failure: []const u8 = "InvalidResponse",
    reader: protocol.Reader = .{},
    output: protocol.Queue = .{},
    snapshot: std.ArrayList(u8) = .empty,
    acknowledged: bool = false,
    info: ?protocol.SessionInfo = null,

    fn finish(self: *Query, allocator: std.mem.Allocator) !void {
        if (!self.acknowledged) return error.ConnectionClosed;
        if (self.reader.bytes.items.len != self.reader.offset) return error.InvalidResponse;
        const info = try std.json.parseFromSliceLeaky(protocol.SessionInfo, allocator, self.snapshot.items, .{ .allocate = .alloc_always });
        if (!std.mem.eql(u8, info.name, self.name) or info.pid <= 0) return error.InvalidResponse;
        self.info = info;
        self.state = .running;
    }

    fn read(self: *Query, allocator: std.mem.Allocator) !void {
        if (!try self.reader.receive(allocator, self.fd)) return self.finish(allocator);
        while (try self.reader.next()) |message| {
            switch (message.tag) {
                .ok => {
                    if (self.acknowledged or message.payload.len != 0) return error.InvalidMessage;
                    self.acknowledged = true;
                },
                .output => {
                    if (!self.acknowledged or self.snapshot.items.len + message.payload.len > protocol.max_payload) return error.InvalidMessage;
                    try self.snapshot.appendSlice(allocator, message.payload);
                },
                .failure => {
                    if (std.mem.eql(u8, message.payload, "SessionNotFound")) {
                        self.state = .missing;
                    } else {
                        self.state = .failed;
                        self.failure = try allocator.dupe(u8, message.payload);
                    }
                    return;
                },
                else => return error.InvalidMessage,
            }
        }
    }
};

pub fn names(allocator: std.mem.Allocator, io: std.Io, root: *const config.Config, suffix: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |name| allocator.free(name);
        result.deinit(allocator);
    }
    const directory = try (std.Io.Dir{ .handle = root.dir_fd }).openDir(io, ".", .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const name = config.fileSession(entry.name, suffix) orelse continue;
        const copy = try allocator.dupe(u8, name);
        errdefer allocator.free(copy);
        try result.append(allocator, copy);
    }
    std.mem.sort([]const u8, result.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return result.toOwnedSlice(allocator);
}

pub fn list(allocator: std.mem.Allocator, io: std.Io, root: *const config.Config, created_format: [:0]const u8, prefix: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const available = try names(memory, io, root, ".sock");
    var queries: std.ArrayList(Query) = .empty;
    defer for (queries.items) |query| if (query.fd >= 0) sys.close(query.fd);
    const request = try std.json.Stringify.valueAlloc(memory, protocol.ListOptions{ .created_format = created_format }, .{});
    const deadline = try sys.monotonicMilliseconds() + @as(i64, if (prefix != null) 250 else 1000);
    for (available) |name| {
        if (prefix) |value| if (!std.mem.startsWith(u8, name, value)) continue;
        var endpoint = (try root.session(io, name, false)) orelse continue;
        defer endpoint.deinit();
        const fd = try sys.check(c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0), "socket(session query)");
        var query: Query = .{ .name = name, .fd = fd };
        errdefer sys.close(fd);
        var address = endpoint.address();
        if (c.connect(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) < 0) {
            switch (c.__errno_location().*) {
                c.ENOENT, c.ECONNREFUSED => {
                    sys.close(fd);
                    continue;
                },
                c.EAGAIN => query.state = .unresponsive,
                else => return sys.failure("connect(session query)"),
            }
        } else {
            try config.checkPeer(fd);
            try query.output.message(memory, .info, request);
        }
        try queries.append(memory, query);
    }
    const pollfds = try memory.alloc(c.struct_pollfd, queries.items.len);
    while (true) {
        var pending: usize = 0;
        for (queries.items, pollfds) |query, *event| {
            const active = query.state == .pending;
            pending += @intFromBool(active);
            event.* = .{ .fd = if (active) query.fd else -1, .events = @intCast(c.POLLIN | @as(c_int, if (query.output.pending().len > 0) c.POLLOUT else 0)), .revents = 0 };
        }
        if (pending == 0) break;
        const remaining = deadline - try sys.monotonicMilliseconds();
        if (remaining <= 0) break;
        const count = c.poll(pollfds.ptr, @intCast(pollfds.len), @intCast(remaining));
        if (count < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return sys.failure("poll(session queries)");
        }
        for (queries.items, pollfds) |*query, event| {
            if (query.state != .pending) continue;
            if (event.revents & c.POLLOUT != 0) {
                query.output.flush(query.fd, true) catch |err| {
                    query.state = .failed;
                    query.failure = @errorName(err);
                };
            }
            if (event.revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0 and query.state == .pending) {
                query.read(memory) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    query.state = .failed;
                    query.failure = @errorName(err);
                };
            }
        }
    }
    for (queries.items) |*query| if (query.state == .pending) {
        query.state = .unresponsive;
    };
    if (prefix != null) {
        for (queries.items) |query| {
            if (query.state == .running or query.state == .unresponsive) {
                try sys.writeAll(1, query.name, false);
                try sys.writeAll(1, "\n", false);
            } else if (query.state == .failed) {
                std.log.err("session {s}: {s}", .{ query.name, query.failure });
            }
        }
        return;
    }
    var rows: std.ArrayList([6][]const u8) = .empty;
    for (queries.items) |query| {
        if (query.state == .missing) continue;
        if (query.info) |info| {
            try rows.append(memory, .{ info.name, try std.fmt.allocPrint(memory, "{d}", .{info.pid}), try std.fmt.allocPrint(memory, "{d}", .{info.clients}), info.directory, info.created, "running" });
        } else {
            const status = if (query.state == .unresponsive) "unresponsive" else try std.fmt.allocPrint(memory, "error:{s}", .{query.failure});
            try rows.append(memory, .{ query.name, "-", "-", "-", "-", status });
        }
    }
    if (rows.items.len == 0) return sys.writeAll(1, "No sessions.\n", false);
    const headings = [6][]const u8{ "NAME", "PID", "CLIENTS", "DIRECTORY", "CREATED", "STATUS" };
    var widths = [_]usize{ 4, 3, 7, 9, 7, 6 };
    const table = c.isatty(1) != 0;
    if (table) for (rows.items) |row| {
        for (row, &widths) |field, *width| width.* = @max(width.*, try displayWidth(field));
    };
    var output = std.Io.Writer.Allocating.init(memory);
    try writeRow(&output.writer, headings, widths, table);
    for (rows.items) |row| try writeRow(&output.writer, row, widths, table);
    try sys.writeAll(1, output.written(), false);
}

fn displayWidth(value: []const u8) !usize {
    var iterator = (try std.unicode.Utf8View.init(value)).iterator();
    var width: usize = 0;
    while (iterator.nextCodepoint()) |point| width += terminal.vt.unicode.codepointWidth(point);
    return width;
}

fn writeRow(writer: *std.Io.Writer, fields: [6][]const u8, widths: [6]usize, table: bool) !void {
    for (fields, widths, 0..) |field, width, index| {
        try writer.writeAll(field);
        if (index == fields.len - 1) {
            try writer.writeByte('\n');
        } else if (table) {
            try writer.splatByteAll(' ', width - try displayWidth(field) + 2);
        } else try writer.writeByte('\t');
    }
}
