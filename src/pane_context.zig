const std = @import("std");
const sys = @import("sys.zig");
const config = @import("config.zig");
const c = sys.c;
const keyboard = @import("keyboard.zig");

pub const variable = "IMX_PANE";
pub const State = struct { session: []const u8, directory: []const u8, detach: keyboard.Binding };

pub fn address(name: []const u8) !struct { value: c.struct_sockaddr_un, length: c.socklen_t } {
    var value = std.mem.zeroes(c.struct_sockaddr_un);
    if (name.len == 0 or name.len + 1 > value.sun_path.len) return error.InvalidPaneAddress;
    value.sun_family = c.AF_UNIX;
    @memcpy(value.sun_path[1..][0..name.len], name);
    return .{ .value = value, .length = @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + 1 + name.len) };
}

pub fn listen(name: []const u8) !c_int {
    const endpoint = try address(name);
    const fd = try sys.check(c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0), "socket(pane)");
    errdefer sys.close(fd);
    _ = try sys.check(c.bind(fd, @ptrCast(&endpoint.value), endpoint.length), "bind(pane)");
    _ = try sys.check(c.listen(fd, 4), "listen(pane)");
    return fd;
}

pub fn connect() !?c_int {
    const name = config.env(variable) orelse return null;
    const endpoint = try address(name);
    const fd = try sys.check(c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_CLOEXEC, 0), "socket(pane context)");
    errdefer sys.close(fd);
    _ = try sys.check(c.connect(fd, @ptrCast(&endpoint.value), endpoint.length), "connect(pane context)");
    return fd;
}

pub fn send(allocator: std.mem.Allocator, fd: c_int, session: []const u8, directory: []const u8, detach: keyboard.Binding) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, State{ .session = session, .directory = directory, .detach = detach }, .{});
    defer allocator.free(bytes);
    try sys.writeAll(fd, bytes, true);
}
