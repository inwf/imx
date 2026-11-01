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
    if (std.mem.eql(u8, command, "help")) {
        if (args.len != 2) return error.InvalidArguments;
        return sys.writeAll(1,
            \\imx - persistent terminal sessions for Linux
            \\
            \\Usage:
            \\  imx attach <name>    Create or attach to a session
            \\  imx list | ls       List sessions (default command)
            \\  imx cat <name>       Print retained history and the active screen
            \\  imx detach           Detach clients from the current session
            \\  imx kill <name>      Terminate and remove a session
            \\  imx update           Install the latest published release
            \\  imx uninstall        Terminate sessions and remove the installation
            \\  imx -v               Print version
            \\  imx help             Print help
            \\
            \\Close the terminal or press Ctrl+\ to detach the current client.
            \\Inside a session, attach switches the active connection to the target session.
            \\Names contain 1-64 ASCII letters, digits, dots, underscores or hyphens.
            \\History uses a 10,000-line target and a 2 MiB scrollback budget.
            \\Scrollback limits are applied in complete terminal pages.
            \\IMX_DIR selects an absolute private runtime directory.
            \\
        , false);
    }
    if (std.mem.eql(u8, command, "-v")) {
        if (args.len != 2) return error.InvalidArguments;
        return sys.writeAll(1, "imx " ++ version ++ "\n", false);
    }
    if (std.mem.eql(u8, command, "uninstall")) {
        if (args.len != 2) return error.InvalidArguments;
        return uninstall.run(allocator, io, args[0]);
    }
    if (std.mem.eql(u8, command, "update")) {
        if (args.len != 2) return error.InvalidArguments;
        return update.run(allocator, io, init.environ);
    }
    const tag: protocol.Tag = if (std.mem.eql(u8, command, "attach")) .attach else if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "ls")) .list else if (std.mem.eql(u8, command, "cat")) .cat else if (std.mem.eql(u8, command, "detach")) .detach else if (std.mem.eql(u8, command, "kill")) .kill else return error.UnknownCommand;
    const name: []const u8 = switch (tag) {
        .list => blk: {
            if (args.len > 2) return error.InvalidArguments;
            break :blk "";
        },
        .detach => blk: {
            if (args.len != 2) return error.InvalidArguments;
            break :blk config.env("IMX_SESSION") orelse return error.NotInsideSession;
        },
        else => blk: {
            if (args.len != 3) return error.InvalidArguments;
            break :blk args[2];
        },
    };
    if (tag != .list) try config.validateName(name);
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
    if (tag == .attach) return client.attach(allocator, io, fd, name, &root, &records);
    defer sys.close(fd);
    return client.command(allocator, fd, tag, name, preferences.createdFormat());
}

test {
    _ = @import("keyboard.zig");
    _ = @import("terminal.zig");
    _ = @import("protocol.zig");
    _ = @import("settings.zig");
}
