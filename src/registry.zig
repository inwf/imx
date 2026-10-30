const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const config = @import("config.zig");

pub const Registry = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    dir_fd: c_int,
    paths_fd: c_int,
    lock_fd: c_int,
    image_fd: c_int,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, exclusive: bool) !Registry {
        const image_fd = try sys.check(c.open("/proc/self/exe", c.O_RDONLY | c.O_CLOEXEC), "open(executable lock)");
        errdefer sys.close(image_fd);
        try lock(image_fd, exclusive);
        var image_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
        const image_size = try std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", image_buffer[0..std.fs.max_path_bytes]);
        image_buffer[image_size] = 0;
        var running: c.struct_statx = undefined;
        var installed: c.struct_statx = undefined;
        _ = try sys.check(c.statx(image_fd, "", c.AT_EMPTY_PATH, c.STATX_BASIC_STATS, &running), "stat(executable lock)");
        if (c.statx(c.AT_FDCWD, @as([*:0]const u8, @ptrCast(&image_buffer)), 0, c.STATX_BASIC_STATS, &installed) < 0) {
            if (c.__errno_location().* == c.ENOENT) return error.ExecutableRemoved;
            return sys.failure("stat(installed executable)");
        }
        if (running.stx_ino != installed.stx_ino or running.stx_dev_major != installed.stx_dev_major or running.stx_dev_minor != installed.stx_dev_minor) return error.ExecutableChanged;
        const input = try std.fmt.allocPrintSentinel(allocator, "{s}/.local/state/imx", .{config.env("HOME") orelse return error.HomeNotSet}, 0);
        defer allocator.free(input);
        if (!std.fs.path.isAbsolute(input)) return error.HomeMustBeAbsolute;
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, input, .fromMode(0o700));
        const dir_fd = try sys.check(c.open(input, c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_RDONLY), "open(imx state)");
        errdefer sys.close(dir_fd);
        try privateDirectory(dir_fd);
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path_size = try (std.Io.Dir{ .handle = dir_fd }).realPath(io, &path_buffer);
        const path = try allocator.dupeSentinel(u8, path_buffer[0..path_size], 0);
        errdefer allocator.free(path);
        const lock_fd = try sys.check(c.openat(dir_fd, "lifecycle.lock", c.O_RDWR | c.O_CREAT | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600)), "open(lifecycle lock)");
        errdefer sys.close(lock_fd);
        const stat = try sys.stat(lock_fd);
        if (stat.uid != c.getuid() or stat.mode & 0o077 != 0 or stat.mode & c.S_IFMT != c.S_IFREG or stat.nlink != 1) return error.UnsafeLockFile;
        try lock(lock_fd, exclusive);
        if (c.mkdirat(dir_fd, "paths", @as(c_uint, 0o700)) < 0 and c.__errno_location().* != c.EEXIST) return sys.failure("mkdir(paths)");
        const paths_fd = try sys.check(c.openat(dir_fd, "paths", c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_RDONLY), "open(paths)");
        errdefer sys.close(paths_fd);
        try privateDirectory(paths_fd);
        return .{ .allocator = allocator, .path = path, .dir_fd = dir_fd, .paths_fd = paths_fd, .lock_fd = lock_fd, .image_fd = image_fd };
    }

    pub fn unlock(self: *const Registry) !void {
        _ = try sys.check(c.flock(self.lock_fd, c.LOCK_UN), "flock(lifecycle unlock)");
        _ = try sys.check(c.flock(self.image_fd, c.LOCK_UN), "flock(executable unlock)");
    }

    pub fn deinit(self: *Registry) void {
        sys.close(self.paths_fd);
        sys.close(self.lock_fd);
        sys.close(self.dir_fd);
        sys.close(self.image_fd);
        self.allocator.free(self.path);
    }

    pub fn register(self: *const Registry, io: std.Io, directory: c_int) !void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const size = try (std.Io.Dir{ .handle = directory }).realPath(io, &buffer);
        const path = buffer[0..size];
        const paths = try std.fmt.allocPrint(self.allocator, "{s}/paths", .{self.path});
        defer self.allocator.free(paths);
        if (std.mem.eql(u8, path, paths) or (std.mem.startsWith(u8, path, paths) and path.len > paths.len and path[paths.len] == '/')) return error.RuntimePathUsesRegistry;
        const target = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(target);
        var name_buffer: [17]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(&name_buffer, "{x:0>16}", .{std.hash.Wyhash.hash(0, path)}, 0);
        if (c.symlinkat(target, self.paths_fd, name) == 0) return;
        if (c.__errno_location().* != c.EEXIST) return sys.failure("symlink(runtime registration)");
        const existing_size = try sys.check(@intCast(c.readlinkat(self.paths_fd, name, &buffer, buffer.len)), "readlink(runtime registration)");
        if (!std.mem.eql(u8, target, buffer[0..@intCast(existing_size)])) return error.RuntimeRegistrationCollision;
    }
};

fn lock(fd: c_int, exclusive: bool) !void {
    while (c.flock(fd, if (exclusive) c.LOCK_EX else c.LOCK_SH) < 0) {
        if (c.__errno_location().* != c.EINTR) return sys.failure("flock(lifecycle)");
    }
}

fn privateDirectory(fd: c_int) !void {
    const stat = try sys.stat(fd);
    if (stat.uid != c.getuid() or stat.mode & 0o077 != 0) return error.UnsafeStateDirectory;
}
