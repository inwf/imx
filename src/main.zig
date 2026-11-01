const std = @import("std");
const sys = @import("sys.zig");
const config = @import("config.zig");
const client = @import("client.zig");
const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const uninstall = @import("uninstall.zig");
const update = @import("update.zig");
const settings = @import("settings.zig");
const shell = @import("shell.zig");
const completion = @import("completion.zig");
const sessions = @import("sessions.zig");
const cli = @import("cli.zig");
const version = @import("build_options").version;
pub const std_options: std.Options = .{ .log_level = .err };

pub fn main(init: std.process.Init.Minimal) void {
    execute(init) catch |err| {
        if (err != error.RequestFailed) {
            var buffer: [512]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "imx: {s}\n", .{@errorName(err)}) catch unreachable;
            sys.writeAll(2, message, false) catch {};
        }
        std.process.exit(1);
    };
}

fn execute(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    var threaded = std.Io.Threaded.init(allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    const command = if (args.len > 1) args[1] else "list";
    if (std.mem.eql(u8, command, "__complete")) {
        if (args.len != 4) return error.InvalidArguments;
        return completion.run(allocator, io, args[2], args[3]);
    }
    const invocation = switch (try cli.parse(allocator, args[1..])) {
        .help => |target| return cli.help(allocator, target),
        .version => return sys.writeAll(1, "imx " ++ version ++ "\n", false),
        .run => |value| value,
    };
    const tag: protocol.Tag = switch (invocation.command) {
        .uninstall => return uninstall.run(allocator, io, args[0]),
        .update => return update.run(allocator, io, init.environ),
        .attach => .attach,
        .list, .ls => .list,
        .cat => .cat,
        .detach => .detach,
        .kill => .kill,
        .help => unreachable,
    };
    const name = if (tag == .detach) config.env("IMX_SESSION") orelse return cli.fail(allocator, "Run 'imx detach' inside a session (NotInsideSession).", .{}) else invocation.name;
    if (tag != .list) config.validateName(name) catch |err| return cli.fail(allocator, "Invalid session name '{s}': use 1-64 ASCII letters, digits, dots, underscores or hyphens; '.' and '..' are reserved ({s}).", .{ name, @errorName(err) });
    if (tag == .attach) {
        if (sys.c.isatty(0) == 0 or sys.c.isatty(1) == 0) return error.TerminalRequired;
        _ = try sys.Size.get(0);
    }
    var preferences = if (tag == .attach or tag == .list) try settings.load(allocator, io, .{}) else settings.Settings{};
    defer preferences.deinit(allocator);
    var records = try registry.Registry.init(allocator, io, false);
    defer records.deinit();
    if (tag == .attach) try records.lockIntegration();
    if (preferences.file_missing) preferences = try settings.load(allocator, io, .{ .create_default = true });
    if (tag == .attach) try shell.synchronize(allocator, io, &records, preferences.show_session, config.env("SHELL") orelse "/bin/sh");
    var root = try config.Config.init(allocator, io);
    defer root.deinit();
    try records.register(io, root.dir_fd);
    records.finishSetup();
    if (tag == .list) {
        if (try root.connect()) |legacy| {
            defer sys.close(legacy);
            return client.command(allocator, legacy, tag, name, preferences.createdFormat());
        }
        return sessions.list(allocator, io, &root, preferences.createdFormat(), null);
    }
    if (tag == .attach) {
        if (config.env("IMX_SESSION")) |source| {
            try config.validateName(source);
            if (std.mem.eql(u8, source, name)) return;
            return client.switchSession(allocator, io, &root, source, name);
        }
    }
    const fd = try connection.open(allocator, io, &root, name, tag == .attach);
    if (tag == .attach) return client.attach(allocator, io, fd, name, &root, &records, preferences.keybindings);
    defer sys.close(fd);
    return client.command(allocator, fd, tag, name, preferences.createdFormat());
}

test {
    _ = @import("keyboard.zig");
    _ = @import("terminal.zig");
    _ = @import("protocol.zig");
    _ = @import("settings.zig");
}
