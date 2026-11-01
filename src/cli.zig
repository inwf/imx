const std = @import("std");
const clap = @import("clap");
const sys = @import("sys.zig");
const update = @import("update.zig");

pub const Command = enum { attach, list, ls, cat, detach, kill, update, uninstall, help };
pub const Invocation = struct { command: Command, name: []const u8 = "", update_mode: update.Mode = .normal };
pub const Result = union(enum) { help: ?Command, version, run: Invocation };
pub const root_options = [_][]const u8{ "-h", "--help", "-v", "--version" };
pub const help_options = [_][]const u8{ "-h", "--help" };
pub const update_options = help_options ++ [_][]const u8{ "--check", "--force" };

const root_params = clap.parseParamsComptime(
    \\-h, --help     Show help.
    \\-v, --version  Print the version.
    \\<str>
    \\
);

fn parameters(comptime command: Command) []const clap.Param(clap.Help) {
    return switch (command) {
        .update => &comptime clap.parseParamsComptime(
            \\-h, --help  Show help for this command.
            \\--check     Check the latest version without installing.
            \\--force     Install the latest release even if this version is already installed or newer.
            \\
        ),
        .attach, .cat, .kill, .help => &comptime clap.parseParamsComptime(
            \\-h, --help  Show help for this command.
            \\<str>...
            \\
        ),
        else => &comptime clap.parseParamsComptime(
            \\-h, --help  Show help for this command.
            \\
        ),
    };
}

pub fn fail(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) anyerror {
    const text = std.fmt.allocPrint(allocator, "imx: " ++ format ++ "\n", args) catch |err| return err;
    defer allocator.free(text);
    sys.writeAll(2, text, false) catch |err| return err;
    return error.RequestFailed;
}

fn parseArgs(allocator: std.mem.Allocator, comptime params: []const clap.Param(clap.Help), iter: anytype, command: ?Command, terminating: usize) !clap.ResultEx(clap.Help, params, clap.parsers.default) {
    var diagnostic: clap.Diagnostic = .{};
    return clap.parseEx(clap.Help, params, clap.parsers.default, iter, .{
        .allocator = allocator,
        .diagnostic = &diagnostic,
        .terminating_positional = terminating,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        var message = std.Io.Writer.Allocating.init(allocator);
        defer message.deinit();
        try message.writer.writeAll("imx: ");
        try diagnostic.report(&message.writer, err);
        if (command) |value| {
            try message.writer.print("Run 'imx {s} --help' for usage.\n", .{@tagName(value)});
        } else try message.writer.writeAll("Run 'imx --help' for usage.\n");
        try sys.writeAll(2, message.written(), false);
        return error.RequestFailed;
    };
}

pub fn parse(allocator: std.mem.Allocator, arguments: []const []const u8) !Result {
    var iter = clap.args.SliceIterator{ .args = arguments };
    var root = try parseArgs(allocator, &root_params, &iter, null, 0);
    defer root.deinit();
    const name = root.positionals[0];
    if (root.args.version != 0) {
        if (name != null or iter.next() != null or root.args.help != 0) return fail(allocator, "Use 'imx --version' without other arguments.", .{});
        return .version;
    }
    const command = if (name) |value| std.meta.stringToEnum(Command, value) orelse return fail(allocator, "Unknown command '{s}'. Run 'imx --help' for usage.", .{value}) else {
        return if (root.args.help != 0) .{ .help = null } else .{ .run = .{ .command = .list } };
    };
    inline for (std.enums.values(Command)) |candidate| {
        if (command == candidate) {
            var result = try parseArgs(allocator, parameters(candidate), &iter, candidate, std.math.maxInt(usize));
            defer result.deinit();
            if (comptime candidate == .attach or candidate == .cat or candidate == .kill or candidate == .help) {
                if (result.positionals[0].len > 1) return fail(allocator, "Unexpected argument '{s}'. Run 'imx {s} --help' for usage.", .{ result.positionals[0][1], @tagName(candidate) });
            }
            if (root.args.help != 0 or result.args.help != 0) return .{ .help = candidate };
            switch (candidate) {
                .update => {
                    if (result.args.check != 0 and result.args.force != 0) return fail(allocator, "Options '--check' and '--force' cannot be combined. Run 'imx update --help' for usage.", .{});
                    return .{ .run = .{ .command = .update, .update_mode = if (result.args.check != 0) .check else if (result.args.force != 0) .force else .normal } };
                },
                .help => {
                    if (result.positionals[0].len == 0) return .{ .help = null };
                    const target = result.positionals[0][0];
                    return .{ .help = std.meta.stringToEnum(Command, target) orelse return fail(allocator, "Unknown command '{s}'. Run 'imx --help' for usage.", .{target}) };
                },
                .attach, .cat, .kill => {
                    if (result.positionals[0].len == 0) return fail(allocator, "Missing session name. Run 'imx {s} --help' for usage.", .{@tagName(candidate)});
                    const session = result.positionals[0][0];
                    return .{ .run = .{ .command = candidate, .name = session } };
                },
                else => return .{ .run = .{ .command = candidate } },
            }
        }
    }
    unreachable;
}

fn description(command: Command) []const u8 {
    return switch (command) {
        .attach => "Create or attach to a session. Inside a session, switch the current connection.\nAlt+D splits left and right; Alt+Shift+D splits top and bottom. Alt is Option on macOS.\nNew panes start a plain shell in the focused pane's directory. Click a pane to focus it.\nAlt+Arrow focuses a neighbor; Alt+1 through Alt+9 select pane numbers, and Alt+0 selects 10.\nAlt+W closes the focused pane and terminates its attached session and programs.\nDetach first (default: Alt+\\), then close the pane to keep the session running.\nClosing the last pane exits the interface. Configure shortcuts in config.toml under [keybindings].\n",
        .list, .ls => "List sessions, including their shell PID, connections, directory, creation time and status.\nOutput is tab-separated when redirected. This is the default command.\n",
        .cat => "Print retained history and the active screen as plain text.\nHistory uses a 10,000-line target and a 2 MiB scrollback budget.\nScrollback limits are applied in complete terminal pages.\n",
        .detach => "Detach all connections from the current session. Run this command inside a session.\nThe shell and its programs keep running. The detach shortcut affects only its own connection.\n",
        .kill => "Terminate the named session, including its shell, foreground jobs and background jobs.\n",
        .update => "Check for a newer published release and install it in the current installation directory.\nMatching versions report 'Already up to date'. Newer installed versions are preserved.\nUse --check to query the version, or --force to install the latest release again.\nRunning sessions keep their programs and history.\n",
        .uninstall => "Terminate the current user's sessions and remove the installation, configuration and shell integration.\n",
        .help => "Show general help or help for a named command.\n",
    };
}

pub fn help(allocator: std.mem.Allocator, command: ?Command) !void {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    if (command) |value| {
        try writer.writeAll(description(value));
        try writer.print("\nUsage: imx {s} [options]{s}\n\n", .{ @tagName(value), switch (value) {
            .attach, .cat, .kill => " [--] <name>",
            .help => " [command]",
            else => "",
        } });
        inline for (std.enums.values(Command)) |candidate| {
            if (value == candidate) try clap.help(writer, clap.Help, parameters(candidate)[0..if (candidate == .update) 3 else 1], .{ .description_on_new_line = false });
        }
        if (value == .attach or value == .cat or value == .kill) try writer.writeAll("\nNames contain 1-64 ASCII letters, digits, dots, underscores or hyphens.\nUse '--' before names beginning with '-': imx attach -- -dash\n");
    } else {
        try writer.writeAll(
            \\imx - persistent terminal sessions for Linux
            \\
            \\Usage: imx [options] <command>
            \\
            \\Commands:
            \\  attach <name>  Create, attach to or switch to a session
            \\  list | ls      List sessions (default command)
            \\  cat <name>     Print retained history and the active screen
            \\  detach         Detach all connections from the current session
            \\  kill <name>    Terminate and remove a session
            \\  update         Install the latest published release
            \\  uninstall      Terminate sessions and remove the installation
            \\  help [command] Show help
            \\
            \\Options:
            \\
        );
        try clap.help(writer, clap.Help, root_params[0..2], .{ .description_on_new_line = false });
        try writer.writeAll("\nRun 'imx <command> --help' for command details.\nClose the terminal or use the detach shortcut (default: Alt+\\).\nConfigure it with keybindings.detach in config.toml.\nIMX_DIR selects an absolute private runtime directory.\n");
    }
    try sys.writeAll(1, output.written(), false);
}
