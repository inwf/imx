const std = @import("std");
const sys = @import("sys.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const installer = @embedFile("install.sh");
const version = @import("build_options").version;

pub const Mode = enum { normal, check, force };
const Action = enum { current, newer, available, install };

fn action(current: []const u8, latest: []const u8, mode: Mode) !Action {
    const installed = try std.SemanticVersion.parse(current);
    const published = try std.SemanticVersion.parse(latest);
    if (mode == .force) return .install;
    return switch (installed.order(published)) {
        .eq => .current,
        .gt => .newer,
        .lt => if (mode == .check) .available else .install,
    };
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, mode: Mode) !void {
    const base = std.mem.trimEnd(u8, config.env("IMX_RELEASE_BASE_URL") orelse "https://github.com/inwf/imx/releases", "/");
    const url = try std.fmt.allocPrint(allocator, "{s}/latest/download/VERSION", .{base});
    defer allocator.free(url);
    try sys.writeAll(2, "Checking for updates...\n", false);
    const release = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https,http", "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "300", "--max-filesize", "4096", url },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| return cli.fail(allocator, "Cannot run curl to check updates ({s}).", .{@errorName(err)});
    defer allocator.free(release.stdout);
    defer allocator.free(release.stderr);
    if (release.stderr.len != 0) try sys.writeAll(2, release.stderr, false);
    if (!release.term.success()) return cli.fail(allocator, "Could not fetch the latest release version (UpdateFailed).", .{});
    const latest = std.mem.trim(u8, release.stdout, "\r\n");
    const next = action(version, latest, mode) catch return cli.fail(allocator, "The release contains an invalid semantic version (InvalidReleaseVersion).", .{});
    const message = switch (next) {
        .current => try std.fmt.allocPrint(allocator, "Already up to date (imx {s}).\n", .{version}),
        .newer => try std.fmt.allocPrint(allocator, "Installed imx {s} is newer than the latest release ({s}).\n", .{ version, latest }),
        .available => try std.fmt.allocPrint(allocator, "Update available: imx {s} -> {s}.\n", .{ version, latest }),
        .install => null,
    };
    if (message) |text| {
        defer allocator.free(text);
        return sys.writeAll(1, text, false);
    }
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = try std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buffer);
    const executable = buffer[0..size];
    const bin = std.fs.path.dirname(executable) orelse return error.UpdateRequiresInstalledBinary;
    if (!std.mem.eql(u8, std.fs.path.basename(executable), "imx") or !std.mem.eql(u8, std.fs.path.basename(bin), "bin")) return error.UpdateRequiresInstalledBinary;
    const prefix = std.fs.path.dirname(bin) orelse return error.UpdateRequiresInstalledBinary;
    var environment = try environ.createMap(allocator);
    defer environment.deinit();
    try environment.put("IMX_PREFIX", prefix);
    // 使用已检查的发布标签，使安装过程保持同一版本。
    const tag = try std.fmt.allocPrint(allocator, "v{s}", .{latest});
    defer allocator.free(tag);
    var child = std.process.spawn(io, .{
        .argv = &.{ "bash", "-s", "--", tag },
        .environ_map = &environment,
        .stdin = .pipe,
    }) catch |err| return cli.fail(allocator, "Cannot start Bash to install the release ({s}).", .{@errorName(err)});
    defer child.kill(io);
    try sys.writeAll(child.stdin.?.handle, installer, false);
    child.stdin.?.close(io);
    child.stdin = null;
    if (!(try child.wait(io)).success()) return error.UpdateFailed;
}

test "update respects semantic version order and explicit check or force modes" {
    try std.testing.expectEqual(Action.current, try action("0.6.0", "0.6.0", .normal));
    try std.testing.expectEqual(Action.current, try action("0.6.0", "0.6.0", .check));
    try std.testing.expectEqual(Action.install, try action("0.6.0", "0.6.0", .force));
    try std.testing.expectEqual(Action.install, try action("0.6.0", "0.10.0", .normal));
    try std.testing.expectEqual(Action.available, try action("0.6.0", "0.10.0", .check));
    try std.testing.expectEqual(Action.newer, try action("0.10.0", "0.6.0", .normal));
    try std.testing.expectEqual(Action.newer, try action("0.10.0", "0.6.0", .check));
    try std.testing.expectEqual(Action.install, try action("0.10.0", "0.6.0", .force));
    try std.testing.expectEqual(Action.install, try action("0.6.0-rc.1", "0.6.0", .normal));
    try std.testing.expectEqual(Action.current, try action("0.6.0+local", "0.6.0", .normal));
    try std.testing.expectError(error.InvalidVersion, action("0.6.0", "not-a-version", .force));
}
