const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const protocol = @import("protocol.zig");
const config = @import("config.zig");
const registry = @import("registry.zig");
const connection = @import("connection.zig");
const keyboard = @import("keyboard.zig");
const display = @import("display.zig");
const pane_context = @import("pane_context.zig");

pub fn command(allocator: std.mem.Allocator, fd: c_int, tag: protocol.Tag, payload: []const u8, created_format: [:0]const u8) !void {
    const customized = tag == .list and !std.mem.eql(u8, created_format, sys.default_created_format);
    const options: protocol.ListOptions = .{ .table = c.isatty(1) != 0, .created_format = created_format };
    const formatted = if (customized) try std.json.Stringify.valueAlloc(allocator, .{ .table = options.table, .created_format = options.created_format }, .{}) else null;
    defer if (formatted) |bytes| allocator.free(bytes);
    const request = formatted orelse if (tag == .list and options.table and try sameBackendExecutable(fd)) "table" else payload;
    try protocol.send(fd, tag, request);
    return receive(allocator, fd, if (customized) .created_format else .normal);
}

pub fn completeNames(allocator: std.mem.Allocator, fd: c_int, prefix: []const u8) !void {
    const options: protocol.ListOptions = .{ .names_only = true, .prefix = prefix };
    const request = try std.json.Stringify.valueAlloc(allocator, options, .{});
    defer allocator.free(request);
    try protocol.send(fd, .list, request);
    return receive(allocator, fd, .completion);
}

const Response = enum { normal, created_format, completion };

fn receive(allocator: std.mem.Allocator, fd: c_int, context: Response) !void {
    var acknowledged = false;
    while (true) {
        var header: [8]u8 = undefined;
        sys.readExact(fd, &header) catch |err| {
            if (err == error.ConnectionClosed and acknowledged) return;
            return err;
        };
        const message = try protocol.decodeHeader(&header);
        const bytes = try allocator.alloc(u8, message.len);
        defer allocator.free(bytes);
        try sys.readExact(fd, bytes);
        switch (message.tag) {
            .ok => {
                if (acknowledged or bytes.len != 0) return error.InvalidMessage;
                acknowledged = true;
            },
            .output => {
                if (!acknowledged) return error.InvalidMessage;
                try sys.writeAll(1, bytes, false);
            },
            .failure => {
                if (std.mem.eql(u8, bytes, "InvalidMessage")) {
                    switch (context) {
                        .created_format => return error.CreatedFormatUnsupportedByBackend,
                        .completion => return error.CompletionUnsupportedByBackend,
                        .normal => {},
                    }
                }
                try sys.writeAll(2, "imx: ", false);
                try sys.writeAll(2, bytes, false);
                try sys.writeAll(2, "\n", false);
                return error.RequestFailed;
            },
            else => return error.InvalidMessage,
        }
    }
}

fn sameBackendExecutable(fd: c_int) !bool {
    const credentials = try config.peer(fd);
    var path: [64]u8 = undefined;
    const executable = try std.fmt.bufPrintSentinel(&path, "/proc/{d}/exe", .{credentials.pid}, 0);
    var own: c.struct_statx = undefined;
    var backend: c.struct_statx = undefined;
    _ = try sys.check(c.statx(c.AT_FDCWD, "/proc/self/exe", 0, c.STATX_INO, &own), "statx(client executable)");
    _ = try sys.check(c.statx(c.AT_FDCWD, executable, 0, c.STATX_INO, &backend), "statx(backend executable)");
    if (own.stx_mask & backend.stx_mask & c.STATX_INO == 0) return error.IncompleteFileMetadata;
    return own.stx_dev_major == backend.stx_dev_major and own.stx_dev_minor == backend.stx_dev_minor and own.stx_ino == backend.stx_ino;
}

fn attachPayload(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    const size = try sys.Size.get(0);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const shell = config.env("SHELL") orelse "/bin/sh";
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.appendSlice(allocator, &size.encode());
    for ([_][]const u8{ name, cwd, shell }) |field| {
        try payload.appendSlice(allocator, field);
        try payload.append(allocator, 0);
    }
    var environ = c.environ;
    while (environ[0] != null) : (environ += 1) {
        const entry = std.mem.span(environ[0]);
        if (std.mem.startsWith(u8, entry, protocol.client_marker_prefix)) continue;
        try payload.appendSlice(allocator, entry);
        try payload.append(allocator, 0);
    }
    try payload.appendSlice(allocator, protocol.client_marker ++ "\x00");
    if (payload.items.len > protocol.max_payload) return error.EnvironmentTooLarge;
    return payload.toOwnedSlice(allocator);
}

fn acknowledgement(allocator: std.mem.Allocator, fd: c_int) !?[]u8 {
    var header: [8]u8 = undefined;
    try sys.readExact(fd, &header);
    const response = try protocol.decodeHeader(&header);
    if (response.tag == .failure) {
        const text = try allocator.alloc(u8, response.len);
        errdefer allocator.free(text);
        try sys.readExact(fd, text);
        return text;
    }
    if (response.tag != .ok or response.len != 0) return error.InvalidMessage;
    return null;
}

fn requireAcknowledgement(allocator: std.mem.Allocator, fd: c_int, switching: bool) !void {
    if (try acknowledgement(allocator, fd)) |failure| {
        defer allocator.free(failure);
        if (switching and std.mem.eql(u8, failure, "InvalidMessage")) return error.SwitchUnsupportedByBackend;
        try sys.writeAll(2, "imx: ", false);
        try sys.writeAll(2, failure, false);
        try sys.writeAll(2, "\n", false);
        return error.RequestFailed;
    }
}

pub fn switchSession(allocator: std.mem.Allocator, io: std.Io, root: *const config.Config, source: []const u8, name: []const u8) !void {
    const fd = try connection.open(allocator, io, root, source, false);
    defer sys.close(fd);
    const payload = try attachPayload(allocator, io, name);
    defer allocator.free(payload);
    try protocol.send(fd, .switch_prepare, name);
    try requireAcknowledgement(allocator, fd, true);
    // 保持连接，防止新后台在终端完成切换前因没有客户端而退出。
    const target = try connection.open(allocator, io, root, name, true);
    defer sys.close(target);
    try sys.socketTimeout(fd, 15_000);
    try protocol.send(fd, .switch_session, payload);
    try requireAcknowledgement(allocator, fd, false);
}

const SwitchAttempt = union(enum) { ready: c_int, failed: []u8 };

fn prepareSwitch(allocator: std.mem.Allocator, io: std.Io, root: *const config.Config, bytes: []const u8) !SwitchAttempt {
    const payload = try allocator.dupe(u8, bytes);
    defer allocator.free(payload);
    const request = try protocol.Attach.decode(payload);
    try config.validateName(request.name);
    var endpoint = (try root.session(io, request.name, false)) orelse return error.SessionNotFound;
    defer endpoint.deinit();
    const fd = (try endpoint.connect()) orelse return error.SessionNotFound;
    errdefer sys.close(fd);
    const size = try sys.Size.get(0);
    @memcpy(payload[0..4], &size.encode());
    try protocol.send(fd, .attach, payload);
    if (try acknowledgement(allocator, fd)) |failure| {
        sys.close(fd);
        return .{ .failed = failure };
    }
    try sys.socketTimeout(fd, 0);
    _ = try sys.nonblocking(fd, true);
    return .{ .ready = fd };
}

pub fn attach(allocator: std.mem.Allocator, io: std.Io, initial_fd: c_int, name: []const u8, root: *const config.Config, records: *const registry.Registry, bindings: keyboard.Bindings) !void {
    var fd = initial_fd;
    defer sys.close(fd);
    const payload = try attachPayload(allocator, io, name);
    defer allocator.free(payload);
    try protocol.send(fd, .attach, payload);
    try requireAcknowledgement(allocator, fd, false);
    const pane = try pane_context.connect();
    defer if (pane) |context| sys.close(context);
    if (pane) |context| try pane_context.send(allocator, context, name, root.path, bindings.detach);
    try sys.socketTimeout(fd, 0);
    const signal = try sys.signalFd(&.{ c.SIGWINCH, c.SIGTERM, c.SIGHUP, c.SIGINT });
    defer sys.close(signal);
    defer sys.unblockSignals() catch @panic("failed to restore signal mask");
    var saved_termios: c.struct_termios = undefined;
    _ = try sys.check(c.tcgetattr(0, &saved_termios), "tcgetattr");
    var raw = saved_termios;
    c.cfmakeraw(&raw);
    _ = try sys.check(c.tcsetattr(0, c.TCSANOW, &raw), "tcsetattr(raw)");
    defer {
        _ = c.tcsetattr(0, c.TCSANOW, &saved_termios);
        resetDisplay() catch |err| {
            if (err != error.ConnectionClosed) std.process.exit(1);
        };
    }
    const stdin_flags = try sys.check(c.fcntl(0, c.F_GETFL), "fcntl(stdin)");
    const stdout_flags = try sys.check(c.fcntl(1, c.F_GETFL), "fcntl(stdout)");
    _ = try sys.nonblocking(0, true);
    _ = try sys.nonblocking(1, true);
    _ = try sys.nonblocking(fd, true);
    defer {
        _ = c.fcntl(1, c.F_SETFL, stdout_flags);
        _ = c.fcntl(0, c.F_SETFL, stdin_flags);
    }
    try records.unlock();
    var input: protocol.Queue = .{};
    defer input.deinit(allocator);
    var output: protocol.Queue = .{};
    defer output.deinit(allocator);
    var reader: protocol.Reader = .{};
    defer reader.deinit(allocator);
    var connected = true;
    var detaching = false;
    var keys: keyboard.Input = .{ .bindings = bindings };
    var prepared: ?c_int = null;
    defer if (prepared) |next| sys.close(next);
    var prepared_name: ?[]u8 = null;
    defer if (prepared_name) |value| allocator.free(value);
    var switch_deadline: i64 = 0;
    client_loop: while (connected or output.pending().len > 0) {
        if (connected) {
            if (keys.deadline) |deadline| {
                if (try sys.monotonicMilliseconds() >= deadline) {
                    const result = keys.expire();
                    if (result.bytes.len != 0) try input.message(allocator, .input, result.bytes);
                    if (result.action != null) {
                        detaching = true;
                        if (input.pending().len == 0) return;
                    }
                }
            }
        }
        var pollfds = [_]c.struct_pollfd{
            .{ .fd = if (connected and !detaching and prepared == null) 0 else -1, .events = if (input.pending().len < protocol.max_queue - keyboard.Input.read_size * 2 - 16) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (connected) fd else -1, .events = @as(c_short, if (output.pending().len < protocol.max_queue - protocol.max_payload - 8) c.POLLIN else 0) | @as(c_short, if (input.pending().len > 0) c.POLLOUT else 0), .revents = 0 },
            .{ .fd = signal, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (output.pending().len > 0) 1 else -1, .events = c.POLLOUT, .revents = 0 },
        };
        var timeout: c_int = if (prepared != null) blk: {
            const remaining = switch_deadline - try sys.monotonicMilliseconds();
            if (remaining <= 0) return error.SwitchTimeout;
            break :blk @intCast(remaining);
        } else if (connected) -1 else 100;
        if (connected) {
            if (keys.deadline) |deadline| {
                const remaining: c_int = @intCast(@max(0, deadline - try sys.monotonicMilliseconds()));
                timeout = if (timeout < 0) remaining else @min(timeout, remaining);
            }
        }
        const count = c.poll(&pollfds, pollfds.len, timeout);
        if (count < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return sys.failure("poll(client)");
        }
        if (count == 0) {
            if (connected and keys.deadline != null) continue;
            return if (prepared != null) error.SwitchTimeout else error.TerminalOutputBlocked;
        }
        if (pollfds[2].revents & c.POLLIN != 0) {
            var info: c.struct_signalfd_siginfo = undefined;
            while ((try sys.read(signal, std.mem.asBytes(&info))) != null) {
                if (info.ssi_signo == c.SIGWINCH) {
                    const next_size = try sys.Size.get(0);
                    try input.message(allocator, .resize, &next_size.encode());
                } else return;
            }
        }
        if (pollfds[0].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) {
            var buffer: [keyboard.Input.read_size]u8 = undefined;
            if (try sys.readPty(0, &buffer)) |n| {
                if (n == 0) return;
                const result = try keys.feed(buffer[0..n], try sys.monotonicMilliseconds());
                if (result.bytes.len != 0) try input.message(allocator, .input, result.bytes);
                if (result.action) |action| {
                    switch (action) {
                        .detach => detaching = true,
                        .split_right, .split_down, .close_pane => unreachable,
                    }
                    if (input.pending().len == 0) return;
                }
            }
        }
        if (pollfds[1].revents & c.POLLIN != 0) {
            connected = reader.receive(allocator, fd) catch |err| switch (err) {
                error.ConnectionClosed => false,
                else => return err,
            };
            while (try reader.next()) |msg| {
                switch (msg.tag) {
                    .output => try output.append(allocator, msg.payload),
                    .switch_session => {
                        if (prepared != null) return error.InvalidMessage;
                        const pending = keys.takePending();
                        if (pending.len != 0) try input.message(allocator, .input, pending);
                        const attempt = prepareSwitch(allocator, io, root, msg.payload) catch |err| {
                            if (err == error.OutOfMemory) return err;
                            try input.message(allocator, .switch_result, @errorName(err));
                            continue;
                        };
                        switch (attempt) {
                            .ready => |next| {
                                prepared = next;
                                const request = try protocol.Attach.decode(msg.payload);
                                prepared_name = try allocator.dupe(u8, request.name);
                                switch_deadline = try sys.monotonicMilliseconds() + 2000;
                                try input.message(allocator, .switch_result, "");
                            },
                            .failed => |failure| {
                                defer allocator.free(failure);
                                try input.message(allocator, .switch_result, failure);
                            },
                        }
                    },
                    .switch_commit => {
                        if (msg.payload.len != 0) return error.InvalidMessage;
                        const next = prepared orelse return error.InvalidMessage;
                        sys.close(fd);
                        fd = next;
                        prepared = null;
                        if (pane) |context| try pane_context.send(allocator, context, prepared_name.?, root.path, bindings.detach);
                        allocator.free(prepared_name.?);
                        prepared_name = null;
                        reader.deinit(allocator);
                        reader = .{};
                        input.deinit(allocator);
                        input = .{};
                        keys = .{ .bindings = bindings };
                        output.deinit(allocator);
                        output = .{};
                        try output.append(allocator, display.reset);
                        connected = true;
                        continue :client_loop;
                    },
                    .switch_cancel => {
                        if (msg.payload.len != 0) return error.InvalidMessage;
                        if (prepared) |next| sys.close(next);
                        prepared = null;
                        if (prepared_name) |value| allocator.free(value);
                        prepared_name = null;
                    },
                    .failure => return error.RequestFailed,
                    else => return error.InvalidMessage,
                }
            }
        }
        if (pollfds[1].revents & c.POLLOUT != 0) {
            input.flush(fd, true) catch |err| switch (err) {
                error.ConnectionClosed => connected = false,
                else => return err,
            };
        }
        if (detaching and input.pending().len == 0) return;
        if (pollfds[3].revents & c.POLLOUT != 0) try output.flush(1, false);
        if (pollfds[3].revents & (c.POLLHUP | c.POLLERR) != 0) return;
        if (pollfds[1].revents & c.POLLERR != 0) connected = false;
        // POLLHUP 可以和未读取的数据同时到达，继续读取直到取得 EOF。
        if (pollfds[1].revents & c.POLLHUP != 0 and pollfds[1].revents & c.POLLIN == 0) connected = false;
    }
}

pub fn resetDisplay() !void {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try display.finish(&writer, try sys.Size.get(0));
    const flags = try sys.nonblocking(1, true);
    defer _ = c.fcntl(1, c.F_SETFL, flags);
    const bytes = writer.buffered();
    var offset: usize = 0;
    const deadline = try sys.monotonicMilliseconds() + 100;
    while (offset < bytes.len) {
        offset += try sys.write(1, bytes[offset..], false);
        if (offset == bytes.len) break;
        const remaining = deadline - try sys.monotonicMilliseconds();
        if (remaining <= 0) return error.TerminalCleanupBlocked;
        var pollfd: c.struct_pollfd = .{ .fd = 1, .events = c.POLLOUT, .revents = 0 };
        if (c.poll(&pollfd, 1, @intCast(remaining)) < 0 and c.__errno_location().* != c.EINTR) return sys.failure("poll(terminal cleanup)");
        if (pollfd.revents & (c.POLLHUP | c.POLLERR) != 0) return error.ConnectionClosed;
    }
}
