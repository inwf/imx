const std = @import("std");
const config = @import("config.zig");
const server = @import("server.zig");

pub fn open(allocator: std.mem.Allocator, io: std.Io, root: *const config.Config, name: []const u8, create: bool) !c_int {
    if (try root.connect()) |legacy| return legacy;
    var endpoint = (try root.session(io, name, create)) orelse return error.SessionNotFound;
    defer endpoint.deinit();
    try endpoint.lock();
    defer endpoint.unlock() catch @panic("failed to release startup lock");
    if (try endpoint.connect()) |fd| return fd;
    if (!create) return error.SessionNotFound;
    try server.start(allocator, io, &endpoint);
    return (try endpoint.connect()) orelse error.DaemonStartFailed;
}
