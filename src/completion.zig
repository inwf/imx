const std = @import("std");
const sys = @import("sys.zig");
const config = @import("config.zig");
const client = @import("client.zig");
const settings = @import("settings.zig");
const sessions = @import("sessions.zig");
const cli = @import("cli.zig");

const commands = [_][]const u8{ "attach", "list", "ls", "cat", "detach", "kill", "update", "uninstall", "help" };

pub fn run(allocator: std.mem.Allocator, io: std.Io, kind: []const u8, prefix: []const u8) !void {
    const options = std.mem.startsWith(u8, kind, "options-");
    if (options) {
        if (std.meta.stringToEnum(cli.Command, kind[8..]) == null) return error.InvalidArguments;
    } else if (!std.mem.eql(u8, kind, "commands") and !std.mem.eql(u8, kind, "sessions") and !std.mem.eql(u8, kind, "help")) return error.InvalidArguments;
    var preferences = try settings.load(allocator, io, .{});
    defer preferences.deinit(allocator);
    if (!preferences.completion_enabled) return;
    if (options) {
        for (cli.help_options) |option| try candidate(option, prefix);
        return;
    }
    if (std.mem.eql(u8, kind, "commands") or std.mem.eql(u8, kind, "help")) {
        for (commands) |command| {
            try candidate(command, prefix);
        }
        if (std.mem.eql(u8, kind, "commands")) for (cli.root_options) |option| try candidate(option, prefix);
        return;
    }
    if (prefix.len > 64) return;
    var cfg = (try config.Config.openExisting(allocator, io)) orelse return;
    defer cfg.deinit();
    if (try cfg.connect()) |legacy| {
        defer sys.close(legacy);
        return client.completeNames(allocator, legacy, prefix);
    }
    return sessions.list(allocator, io, &cfg, sys.default_created_format, prefix);
}

fn candidate(value: []const u8, prefix: []const u8) !void {
    if (!std.mem.startsWith(u8, value, prefix)) return;
    try sys.writeAll(1, value, false);
    try sys.writeAll(1, "\n", false);
}
