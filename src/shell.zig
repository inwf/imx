const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const config = @import("config.zig");
const registry = @import("registry.zig");
const Allocator = std.mem.Allocator;

const begin = "# BEGIN imx shell integration\n";
const end = "# END imx shell integration\n";
const asset_names = [_][:0]const u8{ "bash.sh", "zsh.sh", "fish.fish", "show-session" };

const Registration = struct {
    path: []const u8,
    block: []const u8,
    created: bool,
};

const Asset = struct {
    name: []const u8,
    contents: []const u8,
};

const State = struct {
    version: u32 = 1,
    files: []const Registration = &.{},
    assets: []const Asset = &.{},
    directories: []const []const u8 = &.{},
};

fn metadata(fd: c_int) !c.struct_statx {
    var result: c.struct_statx = undefined;
    _ = try sys.check(c.statx(fd, "", c.AT_EMPTY_PATH, c.STATX_BASIC_STATS, &result), "stat(shell file)");
    if (result.stx_mask & c.STATX_BASIC_STATS != c.STATX_BASIC_STATS) return error.IncompleteFileMetadata;
    return result;
}

fn sameFile(a: c.struct_statx, b: c.struct_statx) bool {
    return a.stx_ino == b.stx_ino and a.stx_dev_major == b.stx_dev_major and a.stx_dev_minor == b.stx_dev_minor;
}

fn sameVersion(a: c.struct_statx, b: c.struct_statx) bool {
    return sameFile(a, b) and a.stx_size == b.stx_size and a.stx_mode == b.stx_mode and
        a.stx_uid == b.stx_uid and a.stx_gid == b.stx_gid and a.stx_nlink == b.stx_nlink and
        a.stx_mtime.tv_sec == b.stx_mtime.tv_sec and a.stx_mtime.tv_nsec == b.stx_mtime.tv_nsec and
        a.stx_ctime.tv_sec == b.stx_ctime.tv_sec and a.stx_ctime.tv_nsec == b.stx_ctime.tv_nsec;
}

fn renameFile(parent: c_int, source: [*:0]const u8, destination: [*:0]const u8, flags: std.os.linux.RENAME) !void {
    const result = std.os.linux.renameat2(parent, source, parent, destination, flags);
    const errno_value = std.os.linux.errno(result);
    if (errno_value != .SUCCESS) {
        c.__errno_location().* = @backingInt(errno_value);
        return sys.failure("rename(shell file)");
    }
}

const Snapshot = struct {
    path: [:0]u8,
    input: [:0]u8,
    parent: c_int,
    name: [:0]u8,
    fd: c_int = -1,
    stat: ?c.struct_statx = null,
    contents: []const u8 = "",

    fn open(allocator: Allocator, value: []const u8) !?Snapshot {
        if (!std.fs.path.isAbsolute(value) or !std.unicode.utf8ValidateSlice(value)) return error.InvalidShellIntegrationPath;
        const input = try allocator.dupeSentinel(u8, value, 0);
        const resolved = c.realpath(input, null);
        const path = if (resolved) |target| blk: {
            defer c.free(target);
            break :blk try allocator.dupeSentinel(u8, std.mem.span(target), 0);
        } else blk: {
            if (c.__errno_location().* != c.ENOENT) return sys.failure("realpath(shell file)");
            var link: c.struct_statx = undefined;
            if (c.statx(c.AT_FDCWD, input, c.AT_SYMLINK_NOFOLLOW, c.STATX_BASIC_STATS, &link) == 0) return error.ShellInitSymlinkTargetMissing;
            if (c.__errno_location().* != c.ENOENT) return sys.failure("stat(shell file)");
            const parent_path = try allocator.dupeSentinel(u8, std.fs.path.dirname(value).?, 0);
            const parent = c.realpath(parent_path, null) orelse {
                if (c.__errno_location().* == c.ENOENT) return null;
                return sys.failure("realpath(shell parent)");
            };
            defer c.free(parent);
            break :blk try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ std.mem.span(parent), std.fs.path.basename(value) }, 0);
        };
        const parent_path = try allocator.dupeSentinel(u8, std.fs.path.dirname(path).?, 0);
        const parent = try sys.check(c.open(parent_path, c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_RDONLY), "open(shell parent)");
        errdefer sys.close(parent);
        const name = try allocator.dupeSentinel(u8, std.fs.path.basename(path), 0);
        var self: Snapshot = .{ .path = path, .input = input, .parent = parent, .name = name };
        const fd = c.openat(parent, name, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) {
            if (c.__errno_location().* == c.ENOENT) return self;
            return sys.failure("open(shell file)");
        }
        errdefer sys.close(fd);
        const stat = try metadata(fd);
        if (stat.stx_uid != c.getuid() or stat.stx_mode & c.S_IFMT != c.S_IFREG or stat.stx_nlink != 1) return error.UnsafeShellIntegrationFile;
        if (stat.stx_size > 4 * 1024 * 1024) return error.ShellIntegrationFileTooLarge;
        _ = try sys.check(c.flock(fd, c.LOCK_EX | c.LOCK_NB), "lock(shell file)");
        const contents = try allocator.alloc(u8, @intCast(stat.stx_size));
        try sys.readExact(fd, contents);
        var extra: [1]u8 = undefined;
        if ((try sys.read(fd, &extra)).? != 0) return error.ShellIntegrationFileChanged;
        self.fd = fd;
        self.stat = stat;
        self.contents = contents;
        try self.check();
        return self;
    }

    fn deinit(self: *Snapshot) void {
        if (self.fd >= 0) sys.close(self.fd);
        sys.close(self.parent);
    }

    fn check(self: *const Snapshot) !void {
        const parent_path = std.fs.path.dirname(if (self.stat != null) self.path else self.input).?;
        const parent_z = try std.heap.c_allocator.dupeSentinel(u8, parent_path, 0);
        defer std.heap.c_allocator.free(parent_z);
        var current_parent: c.struct_statx = undefined;
        if (c.statx(c.AT_FDCWD, parent_z, 0, c.STATX_BASIC_STATS, &current_parent) < 0) return error.ShellIntegrationFileChanged;
        if (!sameFile(current_parent, try metadata(self.parent))) return error.ShellIntegrationFileChanged;
        var current: c.struct_statx = undefined;
        const result = c.statx(self.parent, self.name, c.AT_SYMLINK_NOFOLLOW, c.STATX_BASIC_STATS, &current);
        if (self.stat) |previous| {
            if (result < 0 or !sameVersion(previous, current) or !sameVersion(previous, try metadata(self.fd))) return error.ShellIntegrationFileChanged;
            const resolved = c.realpath(self.input, null) orelse return error.ShellIntegrationFileChanged;
            defer c.free(resolved);
            if (!std.mem.eql(u8, std.mem.span(resolved), self.path)) return error.ShellIntegrationFileChanged;
        } else if (result == 0 or c.__errno_location().* != c.ENOENT) {
            return error.ShellIntegrationFileChanged;
        }
    }

    fn write(self: *const Snapshot, allocator: Allocator, io: std.Io, contents: []const u8) !void {
        if (self.stat != null and std.mem.eql(u8, self.contents, contents)) return;
        try self.check();
        var salt: u64 = undefined;
        io.random(std.mem.asBytes(&salt));
        var name_buffer: [40]u8 = undefined;
        const temporary = try std.fmt.bufPrintSentinel(&name_buffer, ".imx-{x:0>16}", .{salt}, 0);
        const fd = try sys.check(c.openat(self.parent, temporary, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600)), "create(shell temporary file)");
        defer sys.close(fd);
        var temporary_exists = true;
        var preserve_temporary = false;
        defer if (temporary_exists and !preserve_temporary) std.debug.assert(c.unlinkat(self.parent, temporary, 0) == 0);
        try sys.writeAll(fd, contents, false);
        if (self.stat) |previous| {
            const created = try metadata(fd);
            if (created.stx_uid != previous.stx_uid or created.stx_gid != previous.stx_gid) {
                _ = try sys.check(c.fchown(fd, previous.stx_uid, previous.stx_gid), "chown(shell file)");
            }
            _ = try sys.check(c.fchmod(fd, @as(c_uint, previous.stx_mode & 0o7777)), "chmod(shell file)");
            try copyAttributes(allocator, self.fd, fd);
        } else {
            _ = try sys.check(c.fchmod(fd, @as(c_uint, 0o600)), "chmod(shell file)");
        }
        _ = try sys.check(c.fsync(fd), "fsync(shell file)");
        try self.check();
        if (self.stat) |previous| {
            try renameFile(self.parent, temporary, self.name, .{ .EXCHANGE = true });
            var displaced: c.struct_statx = undefined;
            _ = try sys.check(c.statx(self.parent, temporary, c.AT_SYMLINK_NOFOLLOW, c.STATX_BASIC_STATS, &displaced), "stat(replaced shell file)");
            // rename 会更新 ctime，其他属性用于核对原文件。
            var expected = previous;
            expected.stx_ctime = displaced.stx_ctime;
            if (!sameVersion(expected, displaced) or !sameVersion(displaced, try metadata(self.fd))) {
                preserve_temporary = true;
                std.log.err("shell file changed; previous content preserved at {s}/{s}", .{ std.fs.path.dirname(self.path).?, temporary });
                return error.ShellIntegrationFileChanged;
            }
            _ = try sys.check(c.unlinkat(self.parent, temporary, 0), "unlink(replaced shell file)");
        } else {
            try renameFile(self.parent, temporary, self.name, .{ .NOREPLACE = true });
        }
        temporary_exists = false;
        _ = try sys.check(c.fsync(self.parent), "fsync(shell parent)");
    }

    fn remove(self: *const Snapshot) !void {
        if (self.stat == null) return;
        try self.check();
        _ = try sys.check(c.unlinkat(self.parent, self.name, 0), "unlink(shell integration)");
        _ = try sys.check(c.fsync(self.parent), "fsync(shell parent)");
    }
};

fn copyAttributes(allocator: Allocator, source: c_int, destination: c_int) !void {
    const count = c.flistxattr(source, null, 0);
    if (count < 0) {
        if (c.__errno_location().* == c.ENOTSUP) return;
        return sys.failure("list(shell extended attributes)");
    }
    const names = try allocator.alloc(u8, @intCast(count));
    if (c.flistxattr(source, names.ptr, names.len) != count) return error.ShellIntegrationFileChanged;
    var iterator = std.mem.splitScalar(u8, names, 0);
    while (iterator.next()) |name| {
        if (name.len == 0) continue;
        const name_z = try allocator.dupeSentinel(u8, name, 0);
        const size = c.fgetxattr(source, name_z, null, 0);
        if (size < 0) return sys.failure("read(shell extended attribute)");
        const value = try allocator.alloc(u8, @intCast(size));
        if (c.fgetxattr(source, name_z, value.ptr, value.len) != size) return error.ShellIntegrationFileChanged;
        _ = try sys.check(c.fsetxattr(destination, name_z, value.ptr, value.len, 0), "write(shell extended attribute)");
    }
}

const Context = struct {
    allocator: Allocator,
    io: std.Io,
    path: [:0]u8,
    fd: c_int,
    state: State = .{},
    parsed: ?std.json.Parsed(State) = null,

    fn init(allocator: Allocator, io: std.Io, records: *const registry.Registry, create: bool) !?Context {
        if (create and c.mkdirat(records.dir_fd, "shell", @as(c_uint, 0o700)) < 0 and c.__errno_location().* != c.EEXIST) return sys.failure("mkdir(shell integration)");
        const fd = c.openat(records.dir_fd, "shell", c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_RDONLY);
        if (fd < 0) {
            if (!create and c.__errno_location().* == c.ENOENT) return null;
            return sys.failure("open(shell integration)");
        }
        errdefer sys.close(fd);
        const stat = try metadata(fd);
        if (stat.stx_uid != c.getuid() or stat.stx_mode & 0o077 != 0) return error.UnsafeShellIntegrationDirectory;
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/shell", .{records.path}, 0);
        var self: Context = .{ .allocator = allocator, .io = io, .path = path, .fd = fd };
        const state_path = try std.fs.path.join(allocator, &.{ path, "integration.json" });
        var file = (try Snapshot.open(allocator, state_path)).?;
        defer file.deinit();
        if (file.stat != null) {
            const parsed = try std.json.parseFromSlice(State, allocator, file.contents, .{ .allocate = .alloc_always });
            errdefer parsed.deinit();
            if (parsed.value.version != 1) return error.InvalidShellIntegrationState;
            for (parsed.value.files, 0..) |entry, index| {
                if (!std.fs.path.isAbsolute(entry.path) or !std.mem.startsWith(u8, std.mem.trimStart(u8, entry.block, "\n"), begin) or !std.mem.endsWith(u8, entry.block, end)) return error.InvalidShellIntegrationState;
                for (parsed.value.files[0..index]) |previous| {
                    if (std.mem.eql(u8, previous.path, entry.path)) return error.InvalidShellIntegrationState;
                }
            }
            for (parsed.value.assets, 0..) |entry, index| {
                _ = try assetContents(entry.name);
                for (parsed.value.assets[0..index]) |previous| {
                    if (std.mem.eql(u8, previous.name, entry.name)) return error.InvalidShellIntegrationState;
                }
            }
            self.state = parsed.value;
            self.parsed = parsed;
        }
        return self;
    }

    fn deinit(self: *Context) void {
        if (self.parsed) |parsed| parsed.deinit();
        sys.close(self.fd);
    }

    fn save(self: *Context, state: State) !void {
        const value = try std.json.Stringify.valueAlloc(self.allocator, state, .{ .whitespace = .indent_2 });
        const path = try std.fs.path.join(self.allocator, &.{ self.path, "integration.json" });
        var file = (try Snapshot.open(self.allocator, path)).?;
        defer file.deinit();
        try file.write(self.allocator, self.io, value);
    }
};

const Change = struct {
    file: Snapshot,
    contents: ?[]const u8,

    fn apply(self: *const Change, allocator: Allocator, io: std.Io) !void {
        if (self.contents) |value| try self.file.write(allocator, io, value) else try self.file.remove();
    }
};

fn assetContents(name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "bash.sh")) return @embedFile("shell/bash.sh");
    if (std.mem.eql(u8, name, "zsh.sh")) return @embedFile("shell/zsh.sh");
    if (std.mem.eql(u8, name, "fish.fish")) return @embedFile("shell/fish.fish");
    if (std.mem.eql(u8, name, "show-session")) return "imx\n";
    return error.InvalidShellIntegrationState;
}

fn originalAsset(state: State, name: []const u8) ?[]const u8 {
    for (state.assets) |asset| if (std.mem.eql(u8, asset.name, name)) return asset.contents;
    return null;
}

fn validateAsset(file: *const Snapshot, expected: ?[]const u8, current: []const u8) !void {
    if (file.stat == null or std.mem.eql(u8, file.contents, current)) return;
    if (expected) |previous| if (std.mem.eql(u8, file.contents, previous)) return;
    std.log.err("shell integration asset changed: {s}", .{file.path});
    return error.ShellIntegrationAssetChanged;
}

fn blockPosition(contents: []const u8, entry: Registration) !?usize {
    if (std.mem.indexOf(u8, contents, entry.block)) |position| {
        if (std.mem.indexOf(u8, contents[position + entry.block.len ..], begin) != null or std.mem.indexOf(u8, contents[0..position], begin) != null) return error.DuplicateShellIntegration;
        return position;
    }
    if (std.mem.indexOf(u8, contents, begin) != null or std.mem.indexOf(u8, contents, end) != null) {
        std.log.err("shell integration block changed: {s}", .{entry.path});
        return error.ShellIntegrationChanged;
    }
    return null;
}

fn removeEmptyDirectory(allocator: Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    if (c.rmdir(path_z) < 0) {
        switch (c.__errno_location().*) {
            c.ENOENT, c.ENOTEMPTY => return,
            else => return sys.failure("rmdir(shell integration)"),
        }
    }
}

pub const Cleanup = struct {
    allocator: Allocator,
    io: std.Io,
    context: ?Context,
    changes: std.ArrayList(Change) = .empty,

    pub fn init(allocator: Allocator, io: std.Io, records: *const registry.Registry) !Cleanup {
        var self: Cleanup = .{ .allocator = allocator, .io = io, .context = try Context.init(allocator, io, records, false) };
        errdefer self.deinit();
        const context = if (self.context) |*value| value else return self;
        for (context.state.files) |entry| {
            var file = (try Snapshot.open(allocator, entry.path)) orelse continue;
            errdefer file.deinit();
            if (try blockPosition(file.contents, entry)) |position| {
                const remainder = try std.mem.concat(allocator, u8, &.{ file.contents[0..position], file.contents[position + entry.block.len ..] });
                try self.changes.append(allocator, .{ .file = file, .contents = if (entry.created and remainder.len == 0) null else remainder });
            } else {
                file.deinit();
            }
        }
        for (asset_names) |name| {
            const path = try std.fs.path.join(allocator, &.{ context.path, name });
            var file = (try Snapshot.open(allocator, path)).?;
            errdefer file.deinit();
            try validateAsset(&file, originalAsset(context.state, name), try assetContents(name));
            try self.changes.append(allocator, .{ .file = file, .contents = null });
        }
        const path = try std.fs.path.join(allocator, &.{ context.path, "integration.json" });
        var file = (try Snapshot.open(allocator, path)).?;
        errdefer file.deinit();
        try self.changes.append(allocator, .{ .file = file, .contents = null });
        return self;
    }

    pub fn deinit(self: *Cleanup) void {
        for (self.changes.items) |*change| change.file.deinit();
        if (self.context) |*context| context.deinit();
        self.changes.deinit(self.allocator);
    }

    pub fn perform(self: *Cleanup) !void {
        const context = if (self.context) |*value| value else return;
        for (self.changes.items) |*change| try change.file.check();
        for (self.changes.items) |*change| try change.apply(self.allocator, self.io);
        var index = context.state.directories.len;
        while (index > 0) {
            index -= 1;
            try removeEmptyDirectory(self.allocator, context.state.directories[index]);
        }
        try removeEmptyDirectory(self.allocator, context.path);
    }
};

fn ensureDirectory(allocator: Allocator, path: []const u8, directories: *std.ArrayList([]const u8)) !void {
    var missing: std.ArrayList([:0]u8) = .empty;
    var current = path;
    while (true) {
        const value = try allocator.dupeSentinel(u8, current, 0);
        var stat: c.struct_statx = undefined;
        if (c.statx(c.AT_FDCWD, value, 0, c.STATX_BASIC_STATS, &stat) == 0) {
            if (stat.stx_mode & c.S_IFMT != c.S_IFDIR) return error.ShellInitParentIsNotDirectory;
            break;
        }
        if (c.__errno_location().* != c.ENOENT) return sys.failure("stat(shell parent)");
        try missing.append(allocator, value);
        current = std.fs.path.dirname(current) orelse return error.InvalidShellIntegrationPath;
    }
    var index = missing.items.len;
    while (index > 0) {
        index -= 1;
        const value = missing.items[index];
        if (c.mkdir(value, @as(c_uint, 0o700)) == 0) {
            try directories.append(allocator, value);
        } else if (c.__errno_location().* != c.EEXIST) {
            return sys.failure("mkdir(shell parent)");
        }
    }
}

fn quote(writer: *std.Io.Writer, value: []const u8, fish: bool) !void {
    try writer.writeByte('\'');
    for (value) |character| {
        if (character == '\'') {
            try writer.writeAll(if (fish) "\\'" else "'\\''");
        } else if (fish and character == '\\') {
            try writer.writeAll("\\\\");
        } else {
            try writer.writeByte(character);
        }
    }
    try writer.writeByte('\'');
}

fn loadingBlock(allocator: Allocator, directory: []const u8, name: []const u8, separator: bool) ![]const u8 {
    var builder = std.Io.Writer.Allocating.init(allocator);
    const fish = std.mem.eql(u8, name, "fish.fish");
    if (separator) try builder.writer.writeByte('\n');
    try builder.writer.writeAll(begin);
    try builder.writer.writeAll(if (fish) "set -g __imx_shell_dir " else "__imx_shell_dir=");
    try quote(&builder.writer, directory, fish);
    if (fish) {
        try builder.writer.writeAll("\nif status is-interactive; and test -r \"$__imx_shell_dir/fish.fish\"\n    source \"$__imx_shell_dir/fish.fish\"\nend\n");
    } else {
        const variable = if (std.mem.eql(u8, name, "bash.sh")) "BASH_VERSION" else "ZSH_VERSION";
        try builder.writer.print("\nif [ -n \"${{{s}-}}\" ] && [ -r \"$__imx_shell_dir/{s}\" ]; then\n    . \"$__imx_shell_dir/{s}\"\nfi\n", .{ variable, name, name });
    }
    try builder.writer.writeAll(end);
    return builder.toOwnedSlice();
}

fn shellFiles(allocator: Allocator, shell: []const u8, files: *std.ArrayList([]const u8)) ![:0]const u8 {
    const home = config.env("HOME") orelse return error.HomeNotSet;
    if (!std.fs.path.isAbsolute(home)) return error.HomeMustBeAbsolute;
    const name = std.fs.path.basename(shell);
    if (std.mem.eql(u8, name, "bash")) {
        try files.append(allocator, try std.fs.path.join(allocator, &.{ home, ".bashrc" }));
        for ([_][]const u8{ ".bash_profile", ".bash_login", ".profile" }) |profile| {
            const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ home, profile }, 0);
            if (c.faccessat(c.AT_FDCWD, path, c.R_OK, c.AT_EACCESS) == 0) {
                try files.append(allocator, path);
                return "bash.sh";
            }
            if (c.__errno_location().* != c.ENOENT) return sys.failure("access(bash login file)");
        }
        try files.append(allocator, try std.fs.path.join(allocator, &.{ home, ".bash_profile" }));
        return "bash.sh";
    }
    if (std.mem.eql(u8, name, "zsh")) {
        const directory = config.env("ZDOTDIR") orelse home;
        if (!std.fs.path.isAbsolute(directory)) return error.ZdotdirMustBeAbsolute;
        try files.append(allocator, try std.fs.path.join(allocator, &.{ directory, ".zshrc" }));
        try files.append(allocator, try std.fs.path.join(allocator, &.{ directory, ".zlogin" }));
        return "zsh.sh";
    }
    if (std.mem.eql(u8, name, "fish")) {
        const root = config.env("XDG_CONFIG_HOME");
        const directory = if (root) |value| if (value.len != 0) value else try std.fs.path.join(allocator, &.{ home, ".config" }) else try std.fs.path.join(allocator, &.{ home, ".config" });
        if (!std.fs.path.isAbsolute(directory)) return error.ConfigPathMustBeAbsolute;
        try files.append(allocator, try std.fs.path.join(allocator, &.{ directory, "fish", "config.fish" }));
        return "fish.fish";
    }
    return error.UnsupportedPromptShell;
}

pub fn synchronize(allocator: Allocator, io: std.Io, records: *const registry.Registry, enabled: bool, shell: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    if (!enabled) {
        var cleanup = try Cleanup.init(memory, io, records);
        defer cleanup.deinit();
        return cleanup.perform();
    }
    var targets: std.ArrayList([]const u8) = .empty;
    const script = try shellFiles(memory, shell, &targets);
    var context = (try Context.init(memory, io, records, true)).?;
    defer context.deinit();
    var files: std.ArrayList(Registration) = .empty;
    try files.appendSlice(memory, context.state.files);
    var directories: std.ArrayList([]const u8) = .empty;
    try directories.appendSlice(memory, context.state.directories);
    var changes: std.ArrayList(Change) = .empty;
    defer for (changes.items) |*change| change.file.deinit();
    for (targets.items) |target| {
        try ensureDirectory(memory, std.fs.path.dirname(target).?, &directories);
        var file = (try Snapshot.open(memory, target)).?;
        errdefer file.deinit();
        var registered: ?usize = null;
        for (files.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.path, file.path)) {
                registered = index;
                break;
            }
        }
        if (registered) |index| {
            if (try blockPosition(file.contents, files.items[index]) != null) {
                file.deinit();
                continue;
            }
        } else if (std.mem.indexOf(u8, file.contents, begin) != null or std.mem.indexOf(u8, file.contents, end) != null) {
            return error.UntrackedShellIntegration;
        }
        const block = try loadingBlock(memory, context.path, script, file.contents.len != 0 and file.contents[file.contents.len - 1] != '\n');
        const entry: Registration = .{ .path = file.path, .block = block, .created = file.stat == null };
        if (registered) |index| files.items[index] = entry else try files.append(memory, entry);
        const contents = try std.mem.concat(memory, u8, &.{ file.contents, block });
        try changes.append(memory, .{ .file = file, .contents = contents });
    }
    var assets: std.ArrayList(Asset) = .empty;
    var asset_changes: std.ArrayList(Change) = .empty;
    defer for (asset_changes.items) |*change| change.file.deinit();
    for (asset_names) |name| {
        const expected = originalAsset(context.state, name);
        if (expected == null and !std.mem.eql(u8, name, script) and !std.mem.eql(u8, name, "show-session")) continue;
        const contents = try assetContents(name);
        const path = try std.fs.path.join(memory, &.{ context.path, name });
        var file = (try Snapshot.open(memory, path)).?;
        errdefer file.deinit();
        try validateAsset(&file, expected, contents);
        try assets.append(memory, .{ .name = name, .contents = contents });
        try asset_changes.append(memory, .{ .file = file, .contents = contents });
    }
    for (changes.items) |*change| try change.file.check();
    for (asset_changes.items) |*change| try change.file.check();
    for (asset_changes.items) |*change| try change.apply(memory, io);
    // 先记录完整片段，初始化文件写入中断后仍可依据记录清理。
    try context.save(.{ .files = files.items, .assets = assets.items, .directories = directories.items });
    for (changes.items) |*change| try change.apply(memory, io);
}
