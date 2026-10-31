const std = @import("std");
const sys = @import("sys.zig");
const config = @import("config.zig");
const client = @import("client.zig");
const settings = @import("settings.zig");

const commands = [_][]const u8{ "attach", "list", "ls", "cat", "detach", "kill", "update", "uninstall", "-v", "help" };

pub fn run(allocator: std.mem.Allocator, io: std.Io, kind: []const u8, prefix: []const u8) !void {
    if (!std.mem.eql(u8, kind, "commands") and !std.mem.eql(u8, kind, "sessions")) return error.InvalidArguments;
    var preferences = try settings.load(allocator, io, .{});
    defer preferences.deinit(allocator);
    if (!preferences.completion_enabled) return;
    if (std.mem.eql(u8, kind, "commands")) {
        for (commands) |command| {
            if (std.mem.startsWith(u8, command, prefix)) {
                try sys.writeAll(1, command, false);
                try sys.writeAll(1, "\n", false);
            }
        }
        return;
    }
    if (prefix.len > 64) return;
    var cfg = (try config.Config.openExisting(allocator, io)) orelse return;
    defer cfg.deinit();
    try cfg.lock();
    defer cfg.unlock() catch @panic("failed to release startup lock");
    const fd = (try cfg.connect()) orelse return;
    defer sys.close(fd);
    try cfg.unlock();
    return client.completeNames(allocator, fd, prefix);
}
