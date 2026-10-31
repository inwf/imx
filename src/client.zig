const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const protocol = @import("protocol.zig");
const config = @import("config.zig");
const registry = @import("registry.zig");

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

pub fn attach(allocator: std.mem.Allocator, io: std.Io, fd: c_int, name: []const u8, records: *const registry.Registry) !void {
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
        try payload.appendSlice(allocator, std.mem.span(environ[0]));
        try payload.append(allocator, 0);
    }
    if (payload.items.len > protocol.max_payload) return error.EnvironmentTooLarge;
    try protocol.send(fd, .attach, payload.items);
    var header: [8]u8 = undefined;
    try sys.readExact(fd, &header);
    const response = try protocol.decodeHeader(&header);
    if (response.tag == .failure) {
        const text = try allocator.alloc(u8, response.len);
        defer allocator.free(text);
        try sys.readExact(fd, text);
        try sys.writeAll(2, "imx: ", false);
        try sys.writeAll(2, text, false);
        try sys.writeAll(2, "\n", false);
        return error.RequestFailed;
    }
    if (response.tag != .ok or response.len != 0) return error.InvalidMessage;
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
    while (connected or output.pending().len > 0) {
        var pollfds = [_]c.struct_pollfd{
            .{ .fd = if (connected and !detaching) 0 else -1, .events = if (input.pending().len < protocol.max_queue - 8192) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (connected) fd else -1, .events = @as(c_short, if (output.pending().len < protocol.max_queue - protocol.max_payload - 8) c.POLLIN else 0) | @as(c_short, if (input.pending().len > 0) c.POLLOUT else 0), .revents = 0 },
            .{ .fd = signal, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (output.pending().len > 0) 1 else -1, .events = c.POLLOUT, .revents = 0 },
        };
        const count = c.poll(&pollfds, pollfds.len, if (connected) -1 else 100);
        if (count < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return sys.failure("poll(client)");
        }
        if (count == 0) return error.TerminalOutputBlocked;
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
            var buffer: [4096]u8 = undefined;
            if (try sys.readPty(0, &buffer)) |n| {
                if (n == 0) return;
                if (std.mem.indexOfScalar(u8, buffer[0..n], 0x1c)) |index| {
                    if (index != 0) try input.message(allocator, .input, buffer[0..index]);
                    detaching = true;
                    if (input.pending().len == 0) return;
                } else try input.message(allocator, .input, buffer[0..n]);
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

fn resetDisplay() !void {
    const flags = try sys.nonblocking(1, true);
    defer _ = c.fcntl(1, c.F_SETFL, flags);
    const bytes = "\x1b[?2026l\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1006l\x1b[?2004l\x1b[>4;0m\x1b[<u\x1b[?25h\x1b[0m\x1b[0 q\r\n";
    if (try sys.write(1, bytes, false) != bytes.len) return error.TerminalCleanupBlocked;
}
