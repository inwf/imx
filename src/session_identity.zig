const std = @import("std");
const sys = @import("sys.zig");
const config = @import("config.zig");
const c = sys.c;

pub const variable = "IMX_SESSION_ID";

pub fn isFile(name: []const u8) bool {
    if (name.len != 46 or !std.mem.startsWith(u8, name, "identity-")) return false;
    if (!std.mem.endsWith(u8, name, ".name") and !std.mem.endsWith(u8, name, ".next")) return false;
    for (name[9..41]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

pub const Identity = struct {
    id: [32]u8,
    filename: [47:0]u8,
    pending: [47:0]u8,

    pub fn create(io: std.Io, directory: c_int, name: []const u8) !Identity {
        var random: [16]u8 = undefined;
        io.random(&random);
        var self: Identity = undefined;
        self.id = std.fmt.bytesToHex(random, .lower);
        _ = try std.fmt.bufPrintSentinel(&self.filename, "identity-{s}.name", .{self.id}, 0);
        _ = try std.fmt.bufPrintSentinel(&self.pending, "identity-{s}.next", .{self.id}, 0);
        const fd = try sys.check(c.openat(directory, &self.filename, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o600)), "open(session identity)");
        defer sys.close(fd);
        errdefer self.remove(directory);
        try writeName(fd, name);
        return self;
    }

    pub fn prepare(self: *const Identity, directory: c_int, name: []const u8) !void {
        const fd = try sys.check(c.openat(directory, &self.pending, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o600)), "open(session name update)");
        defer sys.close(fd);
        errdefer self.cancel(directory);
        try writeName(fd, name);
    }

    pub fn commit(self: *const Identity, directory: c_int) !void {
        _ = try sys.check(c.renameat(directory, &self.pending, directory, &self.filename), "rename(session identity)");
    }

    pub fn cancel(self: *const Identity, directory: c_int) void {
        if (c.unlinkat(directory, &self.pending, 0) < 0 and c.__errno_location().* != c.ENOENT) @panic("failed to remove pending session name");
    }

    pub fn remove(self: *const Identity, directory: c_int) void {
        if (c.unlinkat(directory, &self.filename, 0) < 0 and c.__errno_location().* != c.ENOENT) @panic("failed to remove session identity");
    }
};

fn writeName(fd: c_int, name: []const u8) !void {
    try sys.writeAll(fd, name, false);
    try sys.writeAll(fd, "\n", false);
}

pub fn current(allocator: std.mem.Allocator) !?[]const u8 {
    const id = config.env(variable) orelse return config.env("IMX_SESSION");
    if (id.len != 32) return error.InvalidSessionIdentity;
    for (id) |byte| if (!std.ascii.isHex(byte)) return error.InvalidSessionIdentity;
    const runtime = try config.runtimePath(allocator);
    defer allocator.free(runtime);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/identity-{s}.name", .{ runtime, id }, 0);
    defer allocator.free(path);
    const fd = try sys.check(c.open(path, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW), "open(current session name)");
    defer sys.close(fd);
    const stat = try sys.stat(fd);
    if (stat.uid != c.getuid() or stat.mode & 0o077 != 0 or stat.mode & c.S_IFMT != c.S_IFREG or stat.size < 2 or stat.size > 65) return error.InvalidSessionIdentity;
    var buffer: [65]u8 = undefined;
    const name = buffer[0..@intCast(stat.size)];
    try sys.readExact(fd, name);
    if (name[name.len - 1] != '\n') return error.InvalidSessionIdentity;
    try config.validateName(name[0 .. name.len - 1]);
    return try allocator.dupe(u8, name[0 .. name.len - 1]);
}
