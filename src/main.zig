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
const identity = @import("session_identity.zig");
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
    var threaded = std.Io.Threaded.init(allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing, .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();
    const command = if (args.len > 1) args[1] else "list";
    if (std.mem.eql(u8, command, "__complete")) {
        if (args.len != 4) return error.InvalidArguments;
        return completion.run(allocator, io, args[2], args[3]);
    }
    var invocation = switch (try cli.parse(allocator, args[1..])) {
        .help => |target| return cli.help(allocator, target),
        .version => return sys.writeAll(1, "imx " ++ version ++ "\n", false),
        .run => |value| value,
    };
    var selected: ?[]u8 = null;
    defer if (selected) |name| allocator.free(name);
    if (invocation.command == .select) {
        var preferences = try settings.load(allocator, io, .{});
        defer preferences.deinit(allocator);
        selected = try @import("select.zig").run(allocator, io, init.environ);
        invocation = .{ .command = .attach, .name = selected orelse return };
    }
    const tag: protocol.Tag = switch (invocation.command) {
        .uninstall => return uninstall.run(allocator, io, args[0]),
        .update => return update.run(allocator, io, init.environ, invocation.update_mode),
        .attach => .attach,
        .list, .ls => .list,
        .cat => .cat,
        .detach => .detach,
        .kill => .kill,
        .rename => .rename,
        .help, .select => unreachable,
    };
    const source = if (tag == .attach or tag == .detach or invocation.rename_current) try identity.current(arena.allocator()) else null;
    const name = if (tag == .detach or invocation.rename_current) source orelse return cli.fail(allocator, "Run 'imx {s}' inside a session (NotInsideSession).", .{@tagName(invocation.command)}) else invocation.name;
    if (tag != .list) config.validateName(name) catch |err| return cli.fail(allocator, "Invalid session name '{s}': use 1-64 ASCII letters, digits, dots, underscores or hyphens; '.' and '..' are reserved ({s}).", .{ name, @errorName(err) });
    if (invocation.new_name) |value| config.validateName(value) catch |err| return cli.fail(allocator, "Invalid session name '{s}': use 1-64 ASCII letters, digits, dots, underscores or hyphens; '.' and '..' are reserved ({s}).", .{ value, @errorName(err) });
    if (tag == .attach) {
        if (sys.c.isatty(0) == 0 or sys.c.isatty(1) == 0) return error.TerminalRequired;
        _ = try sys.Size.get(0);
    }
    var preferences = if (tag == .attach or tag == .list) try settings.load(allocator, io, .{}) else settings.Settings{};
    defer preferences.deinit(allocator);
    var records = try registry.Registry.init(allocator, io, false);
    defer records.deinit();
    if (preferences.file_missing) preferences = try settings.load(allocator, io, .{ .create_default = true });
    if (tag == .attach and source == null and config.env(@import("pane_context.zig").variable) == null) {
        try records.unlock();
        return @import("workspace.zig").run(allocator, io, init.environ, name, preferences);
    }
    if (tag == .attach) {
        try records.lockIntegration();
        try shell.synchronize(allocator, io, &records, preferences.show_session, config.env("SHELL") orelse "/bin/sh");
    }
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
        if (source) |current| {
            try config.validateName(current);
            if (std.mem.eql(u8, current, name)) return;
            return client.switchSession(allocator, io, &root, current, name);
        }
    }
    const fd = try connection.open(allocator, io, &root, name, tag == .attach);
    if (tag == .attach) return client.attach(allocator, io, fd, name, &root, &records, preferences.keybindings);
    defer sys.close(fd);
    if (tag == .rename) {
        const payload = try std.json.Stringify.valueAlloc(arena.allocator(), protocol.Rename{ .name = name, .new_name = invocation.new_name.?, .expected_id = if (invocation.rename_current) config.env(identity.variable) else null }, .{});
        return client.command(allocator, fd, tag, payload, preferences.createdFormat());
    }
    if (tag == .detach) if (config.env(identity.variable)) |id| {
        const payload = try std.json.Stringify.valueAlloc(arena.allocator(), protocol.SessionTarget{ .name = name, .expected_id = id }, .{});
        return client.command(allocator, fd, .detach_current, payload, preferences.createdFormat());
    };
    return client.command(allocator, fd, tag, name, preferences.createdFormat());
}

test {
    _ = @import("keyboard.zig");
    _ = @import("terminal.zig");
    _ = @import("protocol.zig");
    _ = @import("settings.zig");
    _ = @import("update.zig");
    _ = @import("pane_render.zig");
    _ = @import("preview.zig");
}
