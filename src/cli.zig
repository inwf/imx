const std = @import("std");
const clap = @import("clap");
const sys = @import("sys.zig");
const update = @import("update.zig");

pub const Command = enum { attach, read, list, ls, select, cat, detach, kill, rename, update, uninstall, help };
pub const Invocation = struct { command: Command, name: []const u8 = "", new_name: ?[]const u8 = null, rename_current: bool = false, update_mode: update.Mode = .normal };
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
        .attach, .read, .cat, .kill, .rename, .help => &comptime clap.parseParamsComptime(
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
            if (comptime candidate == .attach or candidate == .read or candidate == .cat or candidate == .kill or candidate == .help) {
                if (result.positionals[0].len > 1) return fail(allocator, "Unexpected argument '{s}'. Run 'imx {s} --help' for usage.", .{ result.positionals[0][1], @tagName(candidate) });
            }
            if (comptime candidate == .rename) {
                if (result.positionals[0].len > 2) return fail(allocator, "Unexpected argument '{s}'. Run 'imx rename --help' for usage.", .{result.positionals[0][2]});
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
                .rename => {
                    const names = result.positionals[0];
                    if (names.len == 0) return fail(allocator, "Missing new session name. Run 'imx rename --help' for usage.", .{});
                    return .{ .run = .{ .command = .rename, .name = if (names.len == 2) names[0] else "", .new_name = names[names.len - 1], .rename_current = names.len == 1 } };
                },
                .attach, .read, .cat, .kill => {
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
        .attach => "Create or attach to a session. Inside a session, switch the current connection.\nAlt+D splits left and right; Alt+Shift+D splits top and bottom. Alt is Option on macOS.\nNew panes start a plain shell in the focused pane's directory.\nAlt+Arrow focuses a neighbor; pane numbers start at 0, and Alt+0 through Alt+9 select matching numbers.\nAlt+Z zooms the focused pane; repeat to restore the layout and proportions.\nOther panes keep running. Focusing another pane, splitting, resizing a pane or closing restores the layout.\nAlt+Shift+Arrow grows the pane; Alt+Ctrl+Arrow shrinks it.\nBoth move a separator in the arrow direction by one column or row. Mouse mode is optional.\nGrowth moves the edge on that side; shrinking moves the opposite edge. Outer edges stay fixed.\nAlt+W closes the focused pane. Writable connections terminate their session and programs;\ndetach first (default: Alt+\\) to keep them running. Read-only connections preserve their session.\nClosing the last pane exits the interface. Configure shortcuts in config.toml under [keybindings].\n",
        .read => "Observe an existing session without sending input or changing its terminal size.\nRequires an interactive terminal. Inside a session, switch the current connection\nto read-only viewing; using the current session name also works.\nPageUp/PageDown and Up/Down browse retained history, Home goes to its beginning,\nEnd follows live output, and Left/Right pan horizontally.\nPress q or Esc to exit and keep the session running.\nThe detach shortcut and Alt+W also close the read-only connection and preserve its session.\nConfigure shortcuts in config.toml under [keybindings].\n",
        .list, .ls => "List sessions, including their shell PID, connections, directory, creation time and status.\nOutput is tab-separated when redirected. This is the default command.\n",
        .select => "Choose a session with a live preview. Requires an interactive terminal.\nUp/Down or j/k move the selection; Enter or Space attaches to it.\nWith panes.mouse enabled, click or scroll in the list to select; double-click to attach.\nScroll over preview contents to browse retained history; scrolling to the bottom resumes live output.\nEsc or q cancels. Inside a session, selection switches the current connection.\nPreviews preserve session sizes and connection counts.\n",
        .cat => "Print retained history and the active screen as plain text.\nHistory uses a 10,000-line target and a 2 MiB scrollback budget.\nScrollback limits are applied in complete terminal pages.\n",
        .detach => "Detach all connections from the current session. Run this command inside a session.\nThe shell and its programs keep running. The detach shortcut affects only its own connection.\n",
        .kill => "Terminate the named session, including its shell, foreground jobs and background jobs.\n",
        .rename => "Rename a session while preserving its programs, history and connections.\nUse 'imx rename <new-name>' inside the current session, or\n'imx rename <old-name> <new-name>' to rename a specific session.\nThe new name must be available. Connected pane titles update immediately;\nshell prompts update when they next appear.\n",
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
            .attach, .read, .cat, .kill => " [--] <name>",
            .rename => " [--] [old-name] <new-name>",
            .help => " [command]",
            else => "",
        } });
        inline for (std.enums.values(Command)) |candidate| {
            if (value == candidate) try clap.help(writer, clap.Help, parameters(candidate)[0..if (candidate == .update) 3 else 1], .{ .description_on_new_line = false });
        }
        if (value == .attach or value == .read or value == .cat or value == .kill or value == .rename) try writer.print("\nNames contain 1-64 ASCII letters, digits, dots, underscores or hyphens.\nUse '--' before names beginning with '-': imx {s} -- -dash\n", .{@tagName(value)});
    } else {
        try writer.writeAll(
            \\imx - persistent terminal sessions for Linux
            \\
            \\Usage: imx [options] <command>
            \\
            \\Commands:
            \\  attach <name>  Create, attach to or switch to a session
            \\  read <name>    Observe an existing session without input or resizing
            \\  list | ls      List sessions (default command)
            \\  select         Choose a session with a live preview
            \\  cat <name>     Print retained history and the active screen
            \\  detach         Detach all connections from the current session
            \\  kill <name>    Terminate and remove a session
            \\  rename [old-name] <new-name>  Rename the current or named session
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
