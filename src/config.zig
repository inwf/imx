const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;

pub const Config = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    socket_path: [:0]u8,
    session_name: ?[:0]u8,
    socket_name: [:0]u8,
    lock_name: [:0]u8,
    log_name: [:0]u8,
    dir_fd: c_int,
    lock_fd: c_int,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Config {
        const path = try runtimePath(allocator);
        defer allocator.free(path);
        return initPath(allocator, io, path);
    }

    pub fn initPath(allocator: std.mem.Allocator, io: std.Io, value: []const u8) !Config {
        return (try openPath(allocator, io, value, null, true)).?;
    }

    pub fn openExisting(allocator: std.mem.Allocator, io: std.Io) !?Config {
        const path = try runtimePath(allocator);
        defer allocator.free(path);
        return openPath(allocator, io, path, null, false);
    }

    pub fn session(self: *const Config, io: std.Io, name: []const u8, create: bool) !?Config {
        try validateName(name);
        return openPath(self.allocator, io, self.path, name, create);
    }

    fn openPath(allocator: std.mem.Allocator, io: std.Io, value: []const u8, name: ?[]const u8, create: bool) !?Config {
        var initialized = false;
        const path = try allocator.dupeSentinel(u8, value, 0);
        defer if (!initialized) allocator.free(path);
        if (!std.fs.path.isAbsolute(path)) return error.RuntimePathMustBeAbsolute;
        if (create) _ = try std.Io.Dir.cwd().createDirPathStatus(io, path, .fromMode(0o700));
        const dir_fd = c.open(path, c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_RDONLY);
        if (dir_fd < 0) {
            if (!create and c.__errno_location().* == c.ENOENT) return null;
            return sys.failure("open(runtime directory)");
        }
        defer if (!initialized) sys.close(dir_fd);
        const session_name = if (name) |text| try allocator.dupeSentinel(u8, text, 0) else null;
        defer if (!initialized) if (session_name) |text| allocator.free(text);
        const socket_name = if (name) |text| try std.fmt.allocPrintSentinel(allocator, "session-{s}.sock", .{text}, 0) else try allocator.dupeSentinel(u8, "server.sock", 0);
        defer if (!initialized) allocator.free(socket_name);
        const lock_name = if (name) |text| try std.fmt.allocPrintSentinel(allocator, "session-{s}.lock", .{text}, 0) else try allocator.dupeSentinel(u8, "startup.lock", 0);
        defer if (!initialized) allocator.free(lock_name);
        const log_name = if (name) |text| try std.fmt.allocPrintSentinel(allocator, "session-{s}.log", .{text}, 0) else try allocator.dupeSentinel(u8, "server.log", 0);
        defer if (!initialized) allocator.free(log_name);
        const socket_path = try std.fmt.allocPrintSentinel(allocator, "/proc/self/fd/{d}/{s}", .{ dir_fd, socket_name }, 0);
        defer if (!initialized) allocator.free(socket_path);
        var stat = try sys.stat(dir_fd);
        if (stat.uid != c.getuid() or stat.mode & 0o077 != 0) return error.UnsafeRuntimeDirectory;
        const lock_fd = c.openat(dir_fd, lock_name, c.O_RDWR | c.O_NOFOLLOW | c.O_CLOEXEC | @as(c_int, if (create) c.O_CREAT else 0), @as(c_uint, 0o600));
        if (lock_fd < 0) {
            if (!create and c.__errno_location().* == c.ENOENT) return null;
            return sys.failure("open(startup lock)");
        }
        defer if (!initialized) sys.close(lock_fd);
        stat = try sys.stat(lock_fd);
        if (stat.uid != c.getuid() or stat.mode & 0o077 != 0 or stat.mode & c.S_IFMT != c.S_IFREG or stat.nlink != 1) return error.UnsafeLockFile;
        initialized = true;
        return .{ .allocator = allocator, .path = path, .socket_path = socket_path, .session_name = session_name, .socket_name = socket_name, .lock_name = lock_name, .log_name = log_name, .dir_fd = dir_fd, .lock_fd = lock_fd };
    }

    pub fn deinit(self: *Config) void {
        sys.close(self.lock_fd);
        sys.close(self.dir_fd);
        self.allocator.free(self.path);
        self.allocator.free(self.socket_path);
        if (self.session_name) |name| self.allocator.free(name);
        self.allocator.free(self.socket_name);
        self.allocator.free(self.lock_name);
        self.allocator.free(self.log_name);
    }

    pub fn lock(self: *const Config) !void {
        const deadline = try sys.monotonicMilliseconds() + 2000;
        while (c.flock(self.lock_fd, c.LOCK_EX | c.LOCK_NB) < 0) {
            if (c.__errno_location().* != c.EINTR and c.__errno_location().* != c.EAGAIN) return sys.failure("flock");
            if (try sys.monotonicMilliseconds() >= deadline) return error.SessionLockTimeout;
            _ = c.poll(null, 0, 10);
        }
    }

    pub fn unlock(self: *const Config) !void {
        _ = try sys.check(c.flock(self.lock_fd, c.LOCK_UN), "flock(unlock)");
    }

    pub fn address(self: *const Config) c.struct_sockaddr_un {
        var result: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        result.sun_family = c.AF_UNIX;
        @memcpy(@as([*]u8, @ptrCast(&result.sun_path))[0..self.socket_path.len], self.socket_path);
        return result;
    }

    pub fn connect(self: *const Config) !?c_int {
        const fd = try sys.check(c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0), "socket");
        errdefer sys.close(fd);
        try sys.socketTimeout(fd, 2000);
        var addr = self.address();
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) < 0) {
            switch (c.__errno_location().*) {
                c.ENOENT, c.ECONNREFUSED => {
                    sys.close(fd);
                    return null;
                },
                c.EAGAIN => return error.BackendTimeout,
                else => return sys.failure("connect"),
            }
        }
        try checkPeer(fd);
        return fd;
    }
};

pub fn runtimePath(allocator: std.mem.Allocator) ![:0]u8 {
    return if (env("IMX_DIR")) |value|
        try allocator.dupeSentinel(u8, value, 0)
    else if (env("XDG_RUNTIME_DIR")) |value|
        try std.fmt.allocPrintSentinel(allocator, "{s}/imx", .{value}, 0)
    else
        try std.fmt.allocPrintSentinel(allocator, "{s}/.local/state/imx/run", .{env("HOME") orelse return error.HomeNotSet}, 0);
}

pub fn fileSession(name: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "session-") or !std.mem.endsWith(u8, name, suffix)) return null;
    if (name.len <= 8 + suffix.len) return null;
    const result = name[8 .. name.len - suffix.len];
    validateName(result) catch return null;
    return result;
}

pub fn env(name: [:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    return std.mem.span(value);
}

pub fn checkPeer(fd: c_int) !void {
    _ = try peer(fd);
}

pub fn peer(fd: c_int) !c.struct_ucred {
    var credentials: c.struct_ucred = undefined;
    var len: c.socklen_t = @sizeOf(c.struct_ucred);
    _ = try sys.check(c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &credentials, &len), "getsockopt(SO_PEERCRED)");
    if (credentials.uid != c.getuid()) return error.WrongSocketOwner;
    return credentials;
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 64) return error.InvalidSessionName;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return error.InvalidSessionName;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidSessionName;
}
