const std = @import("std");
pub const c = @import("c");

pub fn failure(operation: []const u8) error{SystemCallFailed} {
    std.log.err("{s}: {s}", .{ operation, std.mem.span(c.strerror(c.__errno_location().*)) });
    return error.SystemCallFailed;
}

pub fn check(result: c_int, operation: []const u8) !c_int {
    if (result < 0) return failure(operation);
    return result;
}

pub fn close(fd: c_int) void {
    std.debug.assert(c.close(fd) == 0);
}

pub fn stat(fd: c_int) !std.os.linux.Statx {
    var result: std.os.linux.Statx = undefined;
    const errno_value = std.os.linux.errno(std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true }, &result));
    if (errno_value != .SUCCESS) {
        c.__errno_location().* = @backingInt(errno_value);
        return failure("statx");
    }
    if (!result.mask.TYPE or !result.mask.MODE or !result.mask.UID or !result.mask.NLINK) return error.IncompleteFileMetadata;
    return result;
}

pub const default_created_format: [:0]const u8 = "%m-%d %H:%M:%S";
pub const max_created_format = 256;
pub const max_created_display = 1024;

pub fn timestamp() !c.time_t {
    const value = c.time(null);
    if (value == -1) return failure("time");
    return value;
}

pub fn formatDateTime(buffer: []u8, value: c.time_t, format: [:0]const u8) ![]const u8 {
    var date = value;
    var calendar: c.struct_tm = undefined;
    if (c.localtime_r(&date, &calendar) == null) return failure("localtime_r");
    const count = c.strftime(buffer.ptr, buffer.len, format, &calendar);
    if (count == 0) return error.InvalidCreatedFormat;
    const text = buffer[0..count];
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidCreatedFormat;
    for (text) |character| if (std.ascii.isControl(character)) return error.InvalidCreatedFormat;
    return text;
}

pub fn validateCreatedFormat(format: [:0]const u8) !void {
    if (format.len == 0 or format.len > max_created_format or !std.unicode.utf8ValidateSlice(format)) return error.InvalidCreatedFormat;
    for (format) |character| if (std.ascii.isControl(character)) return error.InvalidCreatedFormat;
    var buffer: [max_created_display]u8 = undefined;
    _ = try formatDateTime(&buffer, try timestamp(), format);
}

pub fn nonblocking(fd: c_int, enabled: bool) !c_int {
    const flags = try check(c.fcntl(fd, c.F_GETFL), "fcntl(F_GETFL)");
    _ = try check(c.fcntl(fd, c.F_SETFL, if (enabled) flags | c.O_NONBLOCK else flags & ~@as(c_int, c.O_NONBLOCK)), "fcntl(F_SETFL)");
    return flags;
}

pub fn read(fd: c_int, buffer: []u8) !?usize {
    return readFd(fd, buffer, false);
}

pub fn readPty(fd: c_int, buffer: []u8) !?usize {
    return readFd(fd, buffer, true);
}

fn readFd(fd: c_int, buffer: []u8, pty: bool) !?usize {
    while (true) {
        const result = c.read(fd, buffer.ptr, buffer.len);
        if (result >= 0) return @intCast(result);
        switch (c.__errno_location().*) {
            c.EINTR => continue,
            c.EAGAIN => return null,
            c.ECONNRESET => return error.ConnectionClosed,
            c.EIO => if (pty) return 0 else return failure("read"),
            else => return failure("read"),
        }
    }
}

pub fn write(fd: c_int, bytes: []const u8, socket: bool) !usize {
    while (true) {
        const result = if (socket) c.send(fd, bytes.ptr, bytes.len, c.MSG_NOSIGNAL) else c.write(fd, bytes.ptr, bytes.len);
        if (result >= 0) return @intCast(result);
        switch (c.__errno_location().*) {
            c.EINTR => continue,
            c.EAGAIN => return 0,
            c.EPIPE, c.ECONNRESET => return error.ConnectionClosed,
            else => return failure("write"),
        }
    }
}

pub fn writeAll(fd: c_int, bytes: []const u8, socket: bool) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try write(fd, bytes[offset..], socket);
        if (n == 0) {
            var pollfd: c.struct_pollfd = .{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
            _ = try check(c.poll(&pollfd, 1, -1), "poll");
        }
        offset += n;
    }
}

pub fn readExact(fd: c_int, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const n = (try read(fd, buffer[offset..])) orelse return error.WouldBlock;
        if (n == 0) return error.ConnectionClosed;
        offset += n;
    }
}

pub fn signalFd(signals: []const c_int) !c_int {
    var mask: c.sigset_t = undefined;
    _ = try check(c.sigemptyset(&mask), "sigemptyset");
    for (signals) |signal| _ = try check(c.sigaddset(&mask, signal), "sigaddset");
    _ = try check(c.sigprocmask(c.SIG_BLOCK, &mask, null), "sigprocmask");
    return check(c.signalfd(-1, &mask, c.SFD_NONBLOCK | c.SFD_CLOEXEC), "signalfd");
}

pub fn unblockSignals() !void {
    var mask: c.sigset_t = undefined;
    _ = try check(c.sigemptyset(&mask), "sigemptyset");
    _ = try check(c.sigprocmask(c.SIG_SETMASK, &mask, null), "sigprocmask");
}

pub const Size = struct {
    rows: u16,
    cols: u16,

    pub fn validate(self: Size) !void {
        if (self.rows == 0 or self.cols == 0 or self.rows > 256 or self.cols > 512) return error.InvalidTerminalSize;
    }

    pub fn get(fd: c_int) !Size {
        var size: c.struct_winsize = undefined;
        _ = try check(c.ioctl(fd, c.TIOCGWINSZ, &size), "ioctl(TIOCGWINSZ)");
        const result: Size = .{ .rows = size.ws_row, .cols = size.ws_col };
        try result.validate();
        return result;
    }

    pub fn set(self: Size, fd: c_int) !void {
        try self.validate();
        var size: c.struct_winsize = .{ .ws_row = self.rows, .ws_col = self.cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        _ = try check(c.ioctl(fd, c.TIOCSWINSZ, &size), "ioctl(TIOCSWINSZ)");
    }

    pub fn encode(self: Size) [4]u8 {
        var result: [4]u8 = undefined;
        std.mem.writeInt(u16, result[0..2], self.rows, .little);
        std.mem.writeInt(u16, result[2..4], self.cols, .little);
        return result;
    }

    pub fn decode(bytes: []const u8) !Size {
        if (bytes.len != 4) return error.InvalidMessage;
        const result: Size = .{
            .rows = std.mem.readInt(u16, bytes[0..2], .little),
            .cols = std.mem.readInt(u16, bytes[2..4], .little),
        };
        try result.validate();
        return result;
    }
};
