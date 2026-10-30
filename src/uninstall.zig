const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const config = @import("config.zig");
const registry = @import("registry.zig");
const layout = @import("layout.zig");
const Allocator = std.mem.Allocator;

const File = struct {
    parent: c_int,
    name: [:0]u8,
    stat: c.struct_statx,
};

const Plan = struct {
    allocator: Allocator,
    io: std.Io,
    files: std.ArrayList(File) = .empty,
    directories: std.ArrayList([:0]u8) = .empty,
    runtimes: std.ArrayList(config.Config) = .empty,

    fn deinit(self: *Plan) void {
        for (self.files.items) |file| {
            sys.close(file.parent);
            self.allocator.free(file.name);
        }
        for (self.directories.items) |path| self.allocator.free(path);
        for (self.runtimes.items) |*runtime| runtime.deinit();
        self.files.deinit(self.allocator);
        self.directories.deinit(self.allocator);
        self.runtimes.deinit(self.allocator);
    }

    fn addFile(self: *Plan, path: []const u8) !void {
        const parent_path = try self.allocator.dupeSentinel(u8, std.fs.path.dirname(path) orelse return error.InvalidUninstallPath, 0);
        defer self.allocator.free(parent_path);
        const fd = c.open(parent_path, c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_RDONLY);
        if (fd < 0) {
            if (c.__errno_location().* == c.ENOENT) return;
            return sys.failure("open(uninstall parent)");
        }
        errdefer sys.close(fd);
        const name = try self.allocator.dupeSentinel(u8, std.fs.path.basename(path), 0);
        errdefer self.allocator.free(name);
        var stat: c.struct_statx = undefined;
        if (c.statx(fd, name, c.AT_SYMLINK_NOFOLLOW, c.STATX_BASIC_STATS, &stat) < 0) {
            if (c.__errno_location().* == c.ENOENT) {
                sys.close(fd);
                self.allocator.free(name);
                return;
            }
            return sys.failure("stat(uninstall file)");
        }
        if (stat.stx_mask & (c.STATX_INO | c.STATX_TYPE) != c.STATX_INO | c.STATX_TYPE) return error.IncompleteFileMetadata;
        if (stat.stx_mode & c.S_IFMT == c.S_IFDIR) return error.UninstallFileIsDirectory;
        _ = try sys.check(c.faccessat(fd, ".", c.W_OK | c.X_OK, c.AT_EACCESS), "access(uninstall parent)");
        try self.files.append(self.allocator, .{ .parent = fd, .name = name, .stat = stat });
    }

    fn addDirectory(self: *Plan, path: []const u8) !void {
        if (std.mem.eql(u8, path, "/")) return;
        for (self.directories.items) |existing| if (std.mem.eql(u8, path, existing)) return;
        const copy = try self.allocator.dupeSentinel(u8, path, 0);
        errdefer self.allocator.free(copy);
        var stat: c.struct_statx = undefined;
        if (c.statx(c.AT_FDCWD, copy, c.AT_SYMLINK_NOFOLLOW, c.STATX_BASIC_STATS, &stat) < 0) {
            if (c.__errno_location().* == c.ENOENT) {
                self.allocator.free(copy);
                return;
            }
            return sys.failure("stat(uninstall directory)");
        }
        if (stat.stx_mode & c.S_IFMT != c.S_IFDIR) return error.UninstallDirectoryChanged;
        if (stat.stx_uid != c.getuid()) {
            self.allocator.free(copy);
            return;
        }
        const parent = try self.allocator.dupeSentinel(u8, std.fs.path.dirname(path) orelse return error.InvalidUninstallPath, 0);
        defer self.allocator.free(parent);
        _ = try sys.check(c.faccessat(c.AT_FDCWD, parent, c.W_OK | c.X_OK, c.AT_EACCESS), "access(uninstall directory parent)");
        try self.directories.append(self.allocator, copy);
    }

    fn addRuntime(self: *Plan, path: []const u8) !void {
        if (!std.fs.path.isAbsolute(path)) return error.RuntimePathMustBeAbsolute;
        const input = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(input);
        const directory = c.open(input, c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_RDONLY);
        if (directory < 0) {
            if (c.__errno_location().* == c.ENOENT) return;
            return sys.failure("open(uninstall runtime)");
        }
        defer sys.close(directory);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const size = try (std.Io.Dir{ .handle = directory }).realPath(self.io, &buffer);
        const canonical = buffer[0..size];
        for (self.runtimes.items) |runtime| if (std.mem.eql(u8, runtime.path, canonical)) return;
        var runtime = try config.Config.initPath(self.allocator, self.io, canonical);
        errdefer runtime.deinit();
        try runtime.lock();
        for ([_][]const u8{ "startup.lock", "server.sock", "server.log" }) |name| {
            const file = try std.fs.path.join(self.allocator, &.{ canonical, name });
            defer self.allocator.free(file);
            try self.addFile(file);
        }
        try self.addDirectory(canonical);
        try self.runtimes.append(self.allocator, runtime);
    }

    fn registrations(self: *Plan, records: *const registry.Registry) !void {
        var iterator = (std.Io.Dir{ .handle = records.paths_fd }).iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.name.len != 16 or entry.kind != .sym_link) continue;
            var valid = true;
            for (entry.name) |character| if (!std.ascii.isHex(character)) {
                valid = false;
                break;
            };
            if (!valid) continue;
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const size = try (std.Io.Dir{ .handle = records.paths_fd }).readLink(self.io, entry.name, &buffer);
            const target = buffer[0..size];
            var name_buffer: [17]u8 = undefined;
            const expected = try std.fmt.bufPrint(&name_buffer, "{x:0>16}", .{std.hash.Wyhash.hash(0, target)});
            if (!std.mem.eql(u8, expected, entry.name)) return error.InvalidRuntimeRegistration;
            try self.addRuntime(target);
            const file = try std.fs.path.join(self.allocator, &.{ records.path, "paths", entry.name });
            defer self.allocator.free(file);
            try self.addFile(file);
        }
        const paths = try std.fs.path.join(self.allocator, &.{ records.path, "paths" });
        defer self.allocator.free(paths);
        try self.addDirectory(paths);
        const lock = try std.fs.path.join(self.allocator, &.{ records.path, "lifecycle.lock" });
        defer self.allocator.free(lock);
        try self.addFile(lock);
        try self.addDirectory(records.path);
    }

    fn alias(self: *Plan, path: []const u8, executable: []const u8) !void {
        const input = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(input);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const size = c.readlink(input, &buffer, buffer.len);
        if (size < 0) {
            switch (c.__errno_location().*) {
                c.ENOENT, c.ENOTDIR, c.EINVAL => return,
                else => return sys.failure("readlink(executable alias)"),
            }
        }
        const resolved = c.realpath(input, null) orelse {
            if (c.__errno_location().* == c.ENOENT) return;
            return sys.failure("realpath(executable alias)");
        };
        defer c.free(resolved);
        if (std.mem.eql(u8, std.mem.span(resolved), executable)) try self.addFile(path);
    }

    fn installation(self: *Plan, invocation: []const u8) !void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const size = try std.Io.Dir.readLinkAbsolute(self.io, "/proc/self/exe", &buffer);
        const executable = try self.allocator.dupeSentinel(u8, buffer[0..size], 0);
        defer self.allocator.free(executable);
        var actual: c.struct_statx = undefined;
        var running: c.struct_statx = undefined;
        _ = try sys.check(c.statx(c.AT_FDCWD, executable, 0, c.STATX_BASIC_STATS, &actual), "stat(executable)");
        _ = try sys.check(c.statx(c.AT_FDCWD, "/proc/self/exe", 0, c.STATX_BASIC_STATS, &running), "stat(running executable)");
        if (!sameFile(actual, running)) return error.ExecutableChanged;
        const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);
        if (std.mem.indexOfScalar(u8, invocation, '/') != null) {
            const path = try std.fs.path.resolve(self.allocator, &.{ cwd, invocation });
            defer self.allocator.free(path);
            try self.alias(path, executable);
        }
        if (config.env("PATH")) |value| {
            var directories = std.mem.splitScalar(u8, value, ':');
            while (directories.next()) |directory| {
                const path = try std.fs.path.resolve(self.allocator, &.{ cwd, directory, "imx" });
                defer self.allocator.free(path);
                try self.alias(path, executable);
            }
        }
        const bin = std.fs.path.dirname(executable) orelse return error.InvalidUninstallPath;
        if (std.mem.eql(u8, std.fs.path.basename(bin), "bin")) {
            const prefix = std.fs.path.dirname(bin) orelse return error.InvalidUninstallPath;
            for (layout.license_files) |name| {
                const path = try std.fs.path.join(self.allocator, &.{ prefix, "share/licenses/imx", name });
                defer self.allocator.free(path);
                try self.addFile(path);
            }
            for ([_][]const u8{ "share/licenses/imx/third-party", "share/licenses/imx", "share/licenses", "share", "bin", "" }) |directory| {
                const path = try std.fs.path.join(self.allocator, &.{ prefix, directory });
                defer self.allocator.free(path);
                try self.addDirectory(path);
            }
        }
        try self.addFile(executable);
    }

    fn perform(self: *Plan) !void {
        for (self.runtimes.items) |*runtime| try stopServer(runtime);
        for (self.files.items) |file| {
            var current: c.struct_statx = undefined;
            if (c.statx(file.parent, file.name, c.AT_SYMLINK_NOFOLLOW, c.STATX_BASIC_STATS, &current) < 0) {
                if (c.__errno_location().* == c.ENOENT) continue;
                return sys.failure("stat(before uninstall)");
            }
            if (!sameFile(current, file.stat)) return error.UninstallFileChanged;
            _ = try sys.check(c.unlinkat(file.parent, file.name, 0), "unlink(uninstall file)");
        }
        std.mem.sort([:0]u8, self.directories.items, {}, struct {
            fn deeper(_: void, a: [:0]u8, b: [:0]u8) bool {
                return a.len > b.len;
            }
        }.deeper);
        for (self.directories.items) |path| {
            if (c.rmdir(path) < 0) {
                switch (c.__errno_location().*) {
                    c.ENOENT, c.ENOTEMPTY => {},
                    else => return sys.failure("rmdir(uninstall directory)"),
                }
            }
        }
    }
};

fn sameFile(a: c.struct_statx, b: c.struct_statx) bool {
    return a.stx_ino == b.stx_ino and a.stx_dev_major == b.stx_dev_major and a.stx_dev_minor == b.stx_dev_minor;
}

fn stopServer(runtime: *const config.Config) !void {
    const socket = (try runtime.connect()) orelse return;
    defer sys.close(socket);
    const credentials = try config.peer(socket);
    const raw = std.os.linux.pidfd_open(credentials.pid, 0);
    switch (std.os.linux.errno(raw)) {
        .SUCCESS => {},
        .SRCH => return,
        else => return error.PidfdOpenFailed,
    }
    const fd: c_int = @intCast(raw);
    defer sys.close(fd);
    switch (std.os.linux.errno(std.os.linux.pidfd_send_signal(fd, .TERM, null, 0))) {
        .SUCCESS => {},
        .SRCH => return,
        else => return error.PidfdSendSignalFailed,
    }
    var event: c.struct_pollfd = .{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    while (true) {
        const result = c.poll(&event, 1, 5000);
        if (result < 0 and c.__errno_location().* == c.EINTR) continue;
        if (try sys.check(result, "poll(server exit)") == 0) return error.UninstallServerTimeout;
        return;
    }
}

pub fn run(allocator: Allocator, io: std.Io, invocation: []const u8) !void {
    var records = try registry.Registry.init(allocator, io, true);
    defer records.deinit();
    var plan: Plan = .{ .allocator = allocator, .io = io };
    defer plan.deinit();
    try plan.registrations(&records);
    const current = try config.runtimePath(allocator);
    defer allocator.free(current);
    try plan.addRuntime(current);
    const default = try std.fs.path.join(allocator, &.{ records.path, "run" });
    defer allocator.free(default);
    try plan.addRuntime(default);
    if (config.env("XDG_RUNTIME_DIR")) |value| {
        const path = try std.fs.path.join(allocator, &.{ value, "imx" });
        defer allocator.free(path);
        try plan.addRuntime(path);
    }
    try plan.installation(invocation);
    // 独立的 Linux session 允许从正在卸载的会话内部完成清理。
    const pid = try sys.check(c.fork(), "fork(uninstall)");
    if (pid == 0) {
        _ = sys.check(c.setsid(), "setsid(uninstall)") catch c._exit(1);
        plan.perform() catch |err| {
            std.log.err("uninstall: {s}", .{@errorName(err)});
            c._exit(1);
        };
        c._exit(0);
    }
    var status: c_int = undefined;
    while (c.waitpid(pid, &status, 0) < 0) {
        if (c.__errno_location().* != c.EINTR) return sys.failure("waitpid(uninstall)");
    }
    if (status != 0) return error.UninstallFailed;
    try sys.writeAll(1, "imx uninstalled.\n", false);
}
