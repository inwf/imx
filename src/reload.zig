const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const config = @import("config.zig");
const context = @import("pane_context.zig");
const protocol = @import("protocol.zig");
const cli = @import("cli.zig");

pub const Listener = struct {
    fd: c_int,
    address: []u8,
    request: ?struct { fd: c_int, deadline: i64, reply: ?[]u8 = null } = null,

    pub fn init(allocator: std.mem.Allocator) !Listener {
        const address = try std.fmt.allocPrint(allocator, "imx-reload-{d}", .{c.getpid()});
        errdefer allocator.free(address);
        return .{ .fd = try context.listen(address), .address = address };
    }

    pub fn deinit(self: *Listener, allocator: std.mem.Allocator) void {
        self.closeRequest(allocator);
        sys.close(self.fd);
        allocator.free(self.address);
    }

    fn closeRequest(self: *Listener, allocator: std.mem.Allocator) void {
        if (self.request) |request| {
            sys.close(request.fd);
            if (request.reply) |reply| allocator.free(reply);
        }
        self.request = null;
    }

    pub fn respond(self: *Listener, allocator: std.mem.Allocator, message: []const u8) !void {
        const reply = if (message.len <= 8192) message else "imx: Configuration error; diagnostic exceeds 8192 bytes.\n";
        self.request.?.reply = try allocator.dupe(u8, reply);
    }

    pub fn poll(self: *Listener, allocator: std.mem.Allocator, accepting: c_short, events: c_short, now: i64) !bool {
        if (self.request) |request| {
            if (now >= request.deadline or events & (c.POLLHUP | c.POLLERR) != 0) {
                self.closeRequest(allocator);
                return false;
            }
            if (request.reply) |reply| {
                if (events & c.POLLOUT != 0) {
                    const count = sys.write(request.fd, reply, true) catch |err| switch (err) {
                        error.ConnectionClosed => {
                            self.closeRequest(allocator);
                            return false;
                        },
                        else => return err,
                    };
                    if (count != 0) {
                        if (count != reply.len) return error.InvalidMessage;
                        self.closeRequest(allocator);
                        return false;
                    }
                }
            } else if (events & c.POLLIN != 0) {
                var buffer: [16]u8 = undefined;
                const count = (sys.read(request.fd, &buffer) catch |err| switch (err) {
                    error.ConnectionClosed => @as(?usize, 0),
                    else => return err,
                }) orelse return false;
                if (count == 0) {
                    self.closeRequest(allocator);
                } else if (std.mem.eql(u8, buffer[0..count], "reload")) {
                    return true;
                } else try self.respond(allocator, "imx: InvalidReloadRequest\n");
                return false;
            }
        } else if (accepting & c.POLLIN != 0) {
            const fd = try sys.check(c.accept4(self.fd, null, null, c.SOCK_CLOEXEC | c.SOCK_NONBLOCK), "accept(reload)");
            errdefer sys.close(fd);
            config.checkPeer(fd) catch |err| switch (err) {
                error.WrongSocketOwner => {
                    sys.close(fd);
                    return false;
                },
                else => return err,
            };
            self.request = .{ .fd = fd, .deadline = now + 2000 };
        }
        return false;
    }
};

fn destination(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const source = try @import("session_identity.zig").current(arena.allocator());
    if (source) |name| {
        var root = (try config.Config.openExisting(allocator, io)) orelse return error.SessionNotFound;
        defer root.deinit();
        const fd = try @import("connection.zig").open(allocator, io, &root, name, false);
        defer sys.close(fd);
        try protocol.send(fd, .workspace, name);
        var header: [8]u8 = undefined;
        try sys.readExact(fd, &header);
        const response = try protocol.decodeHeader(&header);
        if (response.len > 256) return error.InvalidMessage;
        var buffer: [256]u8 = undefined;
        const bytes = buffer[0..response.len];
        try sys.readExact(fd, bytes);
        if (response.tag == .failure) {
            if (std.mem.eql(u8, bytes, "InvalidMessage")) return error.ReloadUnsupportedByBackend;
            return cli.fail(allocator, "{s}", .{bytes});
        }
        if (response.tag != .output) return error.InvalidMessage;
        return allocator.dupe(u8, bytes);
    }
    const address = config.env(context.workspace_variable) orelse return cli.fail(allocator, "Run 'imx reload' inside an imx session or pane (ReloadOutsideWorkspace).", .{});
    return allocator.dupe(u8, address);
}

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    const address = try destination(allocator, io);
    defer allocator.free(address);
    const endpoint = try context.address(address);
    const fd = try sys.check(c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_CLOEXEC, 0), "socket(reload)");
    defer sys.close(fd);
    try sys.socketTimeout(fd, 2500);
    if (c.connect(fd, @ptrCast(&endpoint.value), endpoint.length) < 0) {
        return switch (c.__errno_location().*) {
            c.ENOENT, c.ECONNREFUSED => error.ReloadUnavailable,
            c.EAGAIN => error.ReloadTimeout,
            else => sys.failure("connect(reload)"),
        };
    }
    try config.checkPeer(fd);
    try sys.writeAll(fd, "reload", true);
    var buffer: [8192]u8 = undefined;
    const count = (try sys.read(fd, &buffer)) orelse return error.ReloadTimeout;
    if (count == 0) return error.ConnectionClosed;
    if (!std.mem.eql(u8, buffer[0..count], "ok")) {
        try sys.writeAll(2, buffer[0..count], false);
        return error.RequestFailed;
    }
    try sys.writeAll(1, "Configuration reloaded.\n", false);
}
