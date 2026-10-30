const std = @import("std");
const sys = @import("sys.zig");
const installer = @embedFile("install.sh");

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = try std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buffer);
    const executable = buffer[0..size];
    const bin = std.fs.path.dirname(executable) orelse return error.UpdateRequiresInstalledBinary;
    if (!std.mem.eql(u8, std.fs.path.basename(executable), "imx") or !std.mem.eql(u8, std.fs.path.basename(bin), "bin")) return error.UpdateRequiresInstalledBinary;
    const prefix = std.fs.path.dirname(bin) orelse return error.UpdateRequiresInstalledBinary;
    var environment = try environ.createMap(allocator);
    defer environment.deinit();
    try environment.put("IMX_PREFIX", prefix);
    var child = try std.process.spawn(io, .{
        .argv = &.{ "bash", "-s", "--" },
        .environ_map = &environment,
        .stdin = .pipe,
    });
    defer child.kill(io);
    try sys.writeAll(child.stdin.?.handle, installer, false);
    child.stdin.?.close(io);
    child.stdin = null;
    if (!(try child.wait(io)).success()) return error.UpdateFailed;
}
