const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const config = @import("config.zig");
const protocol = @import("protocol.zig");
const terminal = @import("terminal.zig");
const preview = @import("preview.zig");
const identity = @import("session_identity.zig");
const Stream = @TypeOf(@as(*terminal.vt.Terminal, undefined).vtStream());
const Handler = @FieldType(Stream, "handler");
const Allocator = std.mem.Allocator;

const Client = struct {
    fd: c_int,
    id: u64,
    reader: protocol.Reader = .{},
    output: protocol.Queue = .{},
    live: protocol.Queue = .{},
    live_started: bool = false,
    session: ?*Session = null,
    preview: ?*Session = null,
    preview_name: ?[]u8 = null,
    preview_pending: bool = false,
    preview_revision: ?u64 = null,
    preview_primary: bool = false,
    size: sys.Size = .{ .rows = 24, .cols = 80 },
    snapshot: ?[]u8 = null,
    snapshot_owned: bool = true,
    snapshot_offset: usize = 0,
    preview_frame: preview.Frame = .{},
    closing: bool = false,
    supports_switch: bool = false,
    supports_rename: bool = false,
    supports_readonly: bool = false,
    read_only: bool = false,
    switch_peer: ?*Client = null,
    switch_name: ?[]u8 = null,
    switch_sent: bool = false,
    switch_departing: bool = false,

    fn flushLive(self: *Client) !void {
        const pending = self.live.pending().len;
        try self.live.flush(self.fd, true);
        const remaining = self.live.pending().len;
        self.live_started = remaining != 0 and (self.live_started or remaining < pending);
    }
};

const Session = struct {
    name: []u8,
    identity: identity.Identity,
    created: c.time_t,
    pid: c.pid_t,
    fd: c_int,
    id: u64,
    term: terminal.vt.Terminal,
    stream: Stream,
    input: protocol.Queue = .{},
    clients: std.ArrayList(*Client) = .empty,
    previews: std.ArrayList(*Client) = .empty,
    revision: u64 = 0,
    preview_source: preview.Source = .{},
    leader: ?*Client = null,
    input_client: ?*Client = null,
    exited: bool = false,
    allocator: Allocator,
};

const Resource = union(enum) { listener, signal, client: *Client, session: *Session };

const Server = struct {
    allocator: Allocator,
    io: std.Io,
    cfg: *config.Config,
    epoll: c_int,
    listener: c_int,
    signal: c_int,
    resources: std.AutoHashMap(u64, Resource),
    sessions: std.StringHashMap(*Session),
    next_id: u64 = 3,

    fn watch(self: *Server, operation: c_int, fd: c_int, id: u64, writable: bool) !void {
        var event: c.struct_epoll_event = std.mem.zeroes(c.struct_epoll_event);
        event.events = @intCast(c.EPOLLIN | c.EPOLLRDHUP | @as(c_int, if (writable) c.EPOLLOUT else 0));
        event.data.u64 = id;
        _ = try sys.check(c.epoll_ctl(self.epoll, operation, fd, &event), "epoll_ctl");
    }

    fn add(self: *Server, fd: c_int, resource: Resource) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        try self.resources.put(id, resource);
        try self.watch(c.EPOLL_CTL_ADD, fd, id, false);
        return id;
    }

    fn unwatch(self: *Server, fd: c_int, id: u64) !void {
        _ = try sys.check(c.epoll_ctl(self.epoll, c.EPOLL_CTL_DEL, fd, null), "epoll_ctl(DEL)");
        std.debug.assert(self.resources.remove(id));
        sys.close(fd);
    }

    fn updateClient(self: *Server, client: *Client) !void {
        try self.watch(c.EPOLL_CTL_MOD, client.fd, client.id, client.output.pending().len > 0 or client.live.pending().len > 0 or client.snapshot != null or client.closing);
    }

    fn updateSession(self: *Server, session: *Session) !void {
        try self.watch(c.EPOLL_CTL_MOD, session.fd, session.id, session.input.pending().len > 0);
    }

    fn focus(self: *Server, session: *Session, focused: bool) !void {
        if (session.term.modes.get(.focus_event)) {
            try session.input.append(self.allocator, if (focused) "\x1b[I" else "\x1b[O");
            try self.updateSession(session);
        }
        session.stream.handler.effects.write_pty = if (focused) null else &writePty;
        session.stream.handler.effects.device_attributes = if (focused) null else &deviceAttributes;
    }

    fn dropClient(self: *Server, client: *Client) !void {
        if (client.preview) |session| {
            client.preview_frame.follow(&session.term);
            for (session.previews.items, 0..) |candidate, index| {
                if (candidate == client) {
                    _ = session.previews.swapRemove(index);
                    break;
                }
            }
            if (session.previews.items.len == 0) session.preview_source.deinit(self.allocator);
        }
        if (client.switch_peer) |other| {
            client.switch_peer = null;
            other.switch_peer = null;
            if (!other.closing) {
                if (client.switch_name == null) {
                    other.closing = true;
                    try self.respond(other, .failure, "SwitchClientDisconnected");
                } else if (client.switch_sent) {
                    try self.respond(other, .switch_cancel, "");
                }
            }
        }
        if (client.switch_name) |name| self.allocator.free(name);
        if (client.preview_name) |name| self.allocator.free(name);
        if (client.session) |session| {
            if (session.input_client == client) session.input_client = null;
            for (session.clients.items, 0..) |candidate, i| {
                if (candidate == client) {
                    _ = session.clients.orderedRemove(i);
                    break;
                }
            }
            if (session.leader == client) {
                session.leader = null;
                for (session.clients.items) |candidate| if (!candidate.read_only) {
                    session.leader = candidate;
                    break;
                };
                if (session.leader) |leader| try self.resize(session, leader.size) else try self.focus(session, false);
            }
            if (session.clients.items.len == 0) {
                try terminal.trim(&session.term);
            }
        }
        try self.unwatch(client.fd, client.id);
        client.reader.deinit(self.allocator);
        client.output.deinit(self.allocator);
        client.live.deinit(self.allocator);
        if (client.snapshot_owned) if (client.snapshot) |snapshot| self.allocator.free(snapshot);
        client.preview_frame.deinit(self.allocator);
        self.allocator.destroy(client);
    }

    fn resize(self: *Server, session: *Session, size: sys.Size) anyerror!void {
        try size.set(session.fd);
        try session.term.resize(self.allocator, .{ .rows = size.rows, .cols = size.cols });
        var index: usize = 0;
        while (index < session.clients.items.len) {
            const client = session.clients.items[index];
            if (client.read_only) {
                // 尺寸通知与后续程序输出共用有序队列。
                client.live.message(self.allocator, .resize, &size.encode()) catch |err| switch (err) {
                    error.SlowClient => {
                        try signalClient(client);
                        try self.dropClient(client);
                        continue;
                    },
                    else => return err,
                };
                try self.updateClient(client);
            }
            index += 1;
        }
        try self.changed(session);
    }

    fn sendPreview(self: *Server, client: *Client) !void {
        const session = client.preview.?;
        if (!client.preview_pending or client.preview_revision == session.revision) return;
        if (client.snapshot != null or client.output.pending().len != 0) return;
        // 会话内的选择界面使用备用屏幕，当前会话预览保留其原有主屏幕。
        if (client.preview_primary and session.term.screens.active_key == .alternate and client.preview_revision != null) return;
        const active = session.term.screens.active_key;
        if (client.preview_primary) session.term.screens.switchTo(.primary);
        defer session.term.screens.switchTo(active);
        client.snapshot = try client.preview_frame.render(self.allocator, &session.preview_source, &session.term, client.size, session.revision);
        client.snapshot_owned = false;
        client.preview_revision = session.revision;
        client.preview_pending = false;
        try self.updateClient(client);
    }

    fn changed(self: *Server, session: *Session) !void {
        session.revision +%= 1;
        for (session.previews.items) |client| if (!client.closing) try self.sendPreview(client);
    }

    fn finishSession(self: *Server, session: *Session, terminate: bool) !void {
        if (terminate) try terminateSession(session.pid);
        std.debug.assert(self.sessions.remove(session.name));
        for (session.clients.items) |client| {
            client.session = null;
            client.closing = true;
            try self.updateClient(client);
        }
        for (session.previews.items) |client| {
            client.preview_frame.follow(&session.term);
            client.preview = null;
            client.closing = true;
            try self.respond(client, .failure, "SessionNotFound");
        }
        session.previews.deinit(self.allocator);
        session.preview_source.deinit(self.allocator);
        try self.unwatch(session.fd, session.id);
        session.stream.deinit();
        session.term.deinit(self.allocator);
        session.input.deinit(self.allocator);
        session.clients.deinit(self.allocator);
        session.identity.remove(self.cfg.dir_fd);
        self.allocator.free(session.name);
        self.allocator.destroy(session);
    }

    fn create(self: *Server, name: []const u8, cwd: []const u8, shell: []const u8, environment: []const u8, size: sys.Size) !*Session {
        if (!std.fs.path.isAbsolute(cwd) or !std.fs.path.isAbsolute(shell)) return error.InvalidMessage;
        const created = try sys.timestamp();
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        const saved_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(saved_name);
        var term = try terminal.init(self.allocator, self.io, size);
        errdefer term.deinit(self.allocator);
        const session_identity = try identity.Identity.create(self.io, self.cfg.dir_fd, name);
        errdefer session_identity.remove(self.cfg.dir_fd);
        const process = try spawnShell(self.allocator, self.cfg, name, &session_identity.id, cwd, shell, environment, size);
        session.* = .{
            .name = saved_name,
            .identity = session_identity,
            .created = created,
            .pid = process.pid,
            .fd = process.fd,
            .id = 0,
            .term = term,
            .stream = undefined,
            .allocator = self.allocator,
        };
        session.stream = session.term.vtStream();
        session.stream.handler.effects.write_pty = &writePty;
        session.stream.handler.effects.device_attributes = &deviceAttributes;
        session.id = try self.add(session.fd, .{ .session = session });
        try self.sessions.put(session.name, session);
        return session;
    }

    fn currentDirectory(self: *Server, session: *const Session) ![]u8 {
        if (session.exited) return error.SessionNotFound;
        var path: [64]u8 = undefined;
        const link = try std.fmt.bufPrint(&path, "/proc/{d}/cwd", .{session.pid});
        var directory: [std.fs.max_path_bytes]u8 = undefined;
        const length = std.Io.Dir.readLinkAbsolute(self.io, link, &directory) catch |err| {
            if (err == error.FileNotFound) return error.SessionNotFound;
            return err;
        };
        return std.fmt.allocPrint(self.allocator, "{f}", .{std.zig.fmtString(directory[0..length])});
    }

    fn respond(self: *Server, client: *Client, tag: protocol.Tag, payload: []const u8) !void {
        try client.output.message(self.allocator, tag, payload);
        try self.updateClient(client);
    }

    fn renameSession(self: *Server, session: *Session, name: []const u8) !void {
        if (std.mem.eql(u8, session.name, name)) return;
        for (session.clients.items) |attached| if (attached.switch_peer != null) return error.SwitchInProgress;
        const source_lock = try sys.check(c.openat(self.cfg.dir_fd, self.cfg.lock_name, c.O_RDWR | c.O_NOFOLLOW | c.O_CLOEXEC), "open(rename source lock)");
        defer sys.close(source_lock);
        try renameLock(source_lock);
        defer _ = c.flock(source_lock, c.LOCK_UN);
        var target = (try self.cfg.session(self.io, name, true)).?;
        var adopted = false;
        defer if (!adopted) target.deinit();
        try renameLock(target.lock_fd);
        defer target.unlock() catch @panic("failed to release rename target lock");
        if (try target.connectNonblocking()) |fd| {
            sys.close(fd);
            return error.SessionAlreadyExists;
        }
        const saved_name = try self.allocator.dupe(u8, name);
        defer if (!adopted) self.allocator.free(saved_name);
        try self.sessions.ensureUnusedCapacity(1);
        try session.identity.prepare(self.cfg.dir_fd, name);
        defer session.identity.cancel(self.cfg.dir_fd);
        if (c.unlinkat(target.dir_fd, target.socket_name, 0) < 0 and c.__errno_location().* != c.ENOENT) return sys.failure("unlink(stale rename target)");
        const result = std.os.linux.renameat2(self.cfg.dir_fd, self.cfg.socket_name, target.dir_fd, target.socket_name, .{ .NOREPLACE = true });
        const rename_error = std.os.linux.errno(result);
        if (rename_error != .SUCCESS) {
            c.__errno_location().* = @backingInt(rename_error);
            return sys.failure("rename(session socket)");
        }
        _ = try sys.check(c.renameat(self.cfg.dir_fd, self.cfg.log_name, target.dir_fd, target.log_name), "rename(session log)");
        try session.identity.commit(self.cfg.dir_fd);
        std.debug.assert(self.sessions.remove(session.name));
        self.allocator.free(session.name);
        session.name = saved_name;
        self.sessions.putAssumeCapacity(session.name, session);
        var previous = self.cfg.*;
        self.cfg.* = target;
        adopted = true;
        previous.deinit();
        var index: usize = 0;
        while (index < session.clients.items.len) {
            const attached = session.clients.items[index];
            if (attached.supports_rename) {
                self.respond(attached, .renamed, name) catch |err| switch (err) {
                    error.SlowClient => {
                        try signalClient(attached);
                        try self.dropClient(attached);
                        continue;
                    },
                    else => return err,
                };
            }
            index += 1;
        }
    }

    fn request(self: *Server, client: *Client, msg: protocol.Message) !void {
        if (client.closing) return error.InvalidMessage;
        if (client.read_only) return error.ReadOnlyClient;
        if (client.preview != null and msg.tag != .preview and msg.tag != .preview_scroll) return error.InvalidMessage;
        if (client.switch_name != null and msg.tag != .switch_session and msg.tag != .switch_readonly) return error.InvalidMessage;
        switch (msg.tag) {
            .preview => {
                if (client.session != null or client.snapshot != null or client.preview_pending or client.output.pending().len != 0) return error.InvalidMessage;
                const parsed = std.json.parseFromSlice(protocol.PreviewOptions, self.allocator, msg.payload, .{}) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    return error.InvalidMessage;
                };
                defer parsed.deinit();
                try config.validateName(parsed.value.name);
                try parsed.value.size.validate();
                const session = client.preview orelse self.sessions.get(parsed.value.name) orelse return error.SessionNotFound;
                if (client.preview != null) {
                    if (!std.mem.eql(u8, parsed.value.name, client.preview_name.?)) return error.InvalidMessage;
                    if (!std.meta.eql(client.size, parsed.value.size)) client.preview_revision = null;
                } else {
                    client.preview_name = try self.allocator.dupe(u8, parsed.value.name);
                    try session.previews.append(self.allocator, client);
                    client.preview = session;
                    client.preview_primary = c.getsid((try config.peer(client.fd)).pid) == session.pid;
                }
                client.size = parsed.value.size;
                client.preview_pending = true;
                try self.sendPreview(client);
            },
            .preview_scroll => {
                const session = client.preview orelse return error.InvalidMessage;
                const parsed = std.json.parseFromSlice(protocol.PreviewScroll, self.allocator, msg.payload, .{}) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    return error.InvalidMessage;
                };
                defer parsed.deinit();
                try parsed.value.size.validate();
                const active = session.term.screens.active_key;
                if (client.preview_primary) session.term.screens.switchTo(.primary);
                defer session.term.screens.switchTo(active);
                client.size = parsed.value.size;
                try client.preview_frame.scroll(&session.term, client.size, parsed.value.delta);
                client.preview_revision = null;
                try self.sendPreview(client);
            },
            .attach, .attach_readonly => {
                if (client.session != null or client.snapshot != null or msg.payload.len < 5) return error.InvalidMessage;
                const fields = try protocol.Attach.decode(msg.payload);
                client.size = fields.size;
                if (!std.mem.eql(u8, fields.name, self.cfg.session_name.?)) return error.InvalidSessionName;
                try config.validateName(fields.name);
                var environment = std.mem.splitScalar(u8, fields.environment, 0);
                while (environment.next()) |entry| {
                    if (std.mem.eql(u8, entry, protocol.client_marker)) client.supports_switch = true;
                    if (std.mem.eql(u8, entry, protocol.rename_marker)) client.supports_rename = true;
                    if (std.mem.eql(u8, entry, protocol.readonly_marker)) client.supports_readonly = true;
                }
                const read_only = msg.tag == .attach_readonly;
                const session = self.sessions.get(fields.name) orelse if (read_only) return error.SessionNotFound else try self.create(fields.name, fields.cwd, fields.shell, fields.environment, client.size);
                if (!read_only) try self.resize(session, client.size);
                client.snapshot = try terminal.restore(self.allocator, &session.term);
                client.session = session;
                client.read_only = read_only;
                const first_writer = session.leader == null;
                if (!read_only) session.leader = client;
                try session.clients.append(self.allocator, client);
                if (!read_only and first_writer) try self.focus(session, true);
                try self.respond(client, .ok, "");
                if (read_only) try self.respond(client, .resize, &(sys.Size{ .cols = session.term.cols, .rows = session.term.rows }).encode());
            },
            .switch_prepare => {
                if (client.session != null or client.switch_peer != null or client.switch_name != null) return error.InvalidMessage;
                try config.validateName(msg.payload);
                const session = self.sessions.get(self.cfg.session_name.?) orelse return error.SessionNotFound;
                const caller = try config.peer(client.fd);
                if (c.getsid(caller.pid) != session.pid) return error.SwitchOutsideSession;
                const active = session.input_client orelse session.leader orelse return error.NoAttachedClient;
                if (active.switch_departing) return error.NoAttachedClient;
                if (!active.supports_switch) return error.SwitchUnsupportedByClient;
                if (active.switch_peer != null) return error.SwitchInProgress;
                const name = try self.allocator.dupe(u8, msg.payload);
                errdefer self.allocator.free(name);
                try self.respond(client, .ok, "");
                client.switch_name = name;
                client.switch_peer = active;
                active.switch_peer = client;
            },
            .switch_session, .switch_readonly => {
                if (client.session != null or client.switch_sent) return error.InvalidMessage;
                const active = client.switch_peer orelse return error.SwitchClientDisconnected;
                if (msg.tag == .switch_readonly and !active.supports_readonly) return error.ReadOnlyUnsupportedByClient;
                const name = client.switch_name orelse return error.InvalidMessage;
                const fields = try protocol.Attach.decode(msg.payload);
                if (!std.mem.eql(u8, fields.name, name)) return error.InvalidSessionName;
                self.respond(active, msg.tag, msg.payload) catch |err| {
                    if (err == error.SlowClient) return error.SwitchClientBusy;
                    return err;
                };
                client.switch_sent = true;
            },
            .switch_result => {
                if (client.session == null) return error.InvalidMessage;
                const requester = client.switch_peer orelse {
                    try self.respond(client, .switch_cancel, "");
                    return;
                };
                if (!requester.switch_sent or msg.payload.len > 128) return error.InvalidMessage;
                for (msg.payload) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidMessage;
                if (msg.payload.len == 0) {
                    try self.respond(client, .switch_commit, "");
                    client.switch_departing = true;
                    try self.respond(requester, .ok, "");
                } else {
                    try self.respond(requester, .failure, msg.payload);
                }
                requester.closing = true;
                requester.switch_peer = null;
                client.switch_peer = null;
                self.allocator.free(requester.switch_name.?);
                requester.switch_name = null;
            },
            .info => {
                if (client.session != null) return error.InvalidMessage;
                const options = std.json.parseFromSlice(protocol.ListOptions, self.allocator, msg.payload, .{}) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    return error.InvalidMessage;
                };
                defer options.deinit();
                try sys.validateCreatedFormat(options.value.created_format);
                const session = self.sessions.get(self.cfg.session_name.?) orelse return error.SessionNotFound;
                const directory = if (options.value.names_only) null else try self.currentDirectory(session);
                defer if (directory) |value| self.allocator.free(value);
                var created: [sys.max_created_display]u8 = undefined;
                const info: protocol.SessionInfo = .{
                    .name = session.name,
                    .pid = session.pid,
                    .clients = session.clients.items.len,
                    .directory = directory orelse "",
                    .created = try sys.formatDateTime(&created, session.created, options.value.created_format),
                };
                client.snapshot = try std.json.Stringify.valueAlloc(self.allocator, info, .{});
                client.closing = true;
                try self.respond(client, .ok, "");
            },
            .list => {
                if (client.session != null) return error.InvalidMessage;
                var options: protocol.ListOptions = .{};
                var parsed: ?std.json.Parsed(protocol.ListOptions) = null;
                defer if (parsed) |value| value.deinit();
                if (std.mem.eql(u8, msg.payload, "table")) {
                    options.table = true;
                } else if (msg.payload.len != 0) {
                    parsed = std.json.parseFromSlice(protocol.ListOptions, self.allocator, msg.payload, .{}) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        return error.InvalidMessage;
                    };
                    options = parsed.?.value;
                    try sys.validateCreatedFormat(options.created_format);
                }
                if (options.prefix.len > 64) return error.InvalidMessage;
                const directory = if (options.names_only) null else if (self.sessions.get(self.cfg.session_name.?)) |session| try self.currentDirectory(session) else null;
                defer if (directory) |value| self.allocator.free(value);
                const table = options.table;
                var builder = std.Io.Writer.Allocating.init(self.allocator);
                defer builder.deinit();
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(self.allocator);
                var it = self.sessions.keyIterator();
                while (it.next()) |name| try names.append(self.allocator, name.*);
                std.mem.sort([]const u8, names.items, {}, struct {
                    fn less(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, a, b);
                    }
                }.less);
                if (options.names_only) {
                    for (names.items) |name| {
                        if (std.mem.startsWith(u8, name, options.prefix)) try builder.writer.print("{s}\n", .{name});
                    }
                } else if (names.items.len == 0) {
                    try builder.writer.writeAll("No sessions.\n");
                } else {
                    const headings = [_][]const u8{ "NAME", "PID", "CLIENTS", "CREATED", "DIRECTORY" };
                    var widths = [_]usize{ 4, 3, 7, 7, 9 };
                    if (table) {
                        for (names.items) |name| {
                            const session = self.sessions.get(name).?;
                            var pid: [20]u8 = undefined;
                            var count: [20]u8 = undefined;
                            var created: [sys.max_created_display]u8 = undefined;
                            const fields = [_][]const u8{
                                session.name,
                                try std.fmt.bufPrint(&pid, "{d}", .{session.pid}),
                                try std.fmt.bufPrint(&count, "{d}", .{session.clients.items.len}),
                                try sys.formatDateTime(&created, session.created, options.created_format),
                                directory.?,
                            };
                            for (fields, &widths) |field, *width| width.* = @max(width.*, try displayWidth(field));
                        }
                    }
                    try listRow(&builder.writer, headings, widths, table);
                    for (names.items) |name| {
                        const session = self.sessions.get(name).?;
                        var pid: [20]u8 = undefined;
                        var count: [20]u8 = undefined;
                        var created: [sys.max_created_display]u8 = undefined;
                        try listRow(&builder.writer, .{
                            session.name,
                            try std.fmt.bufPrint(&pid, "{d}", .{session.pid}),
                            try std.fmt.bufPrint(&count, "{d}", .{session.clients.items.len}),
                            try sys.formatDateTime(&created, session.created, options.created_format),
                            directory.?,
                        }, widths, table);
                    }
                }
                client.snapshot = try builder.toOwnedSlice();
                client.closing = true;
                try self.respond(client, .ok, "");
            },
            .rename => {
                if (client.session != null) return error.InvalidMessage;
                const parsed = std.json.parseFromSlice(protocol.Rename, self.allocator, msg.payload, .{}) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    return error.InvalidMessage;
                };
                defer parsed.deinit();
                try config.validateName(parsed.value.name);
                try config.validateName(parsed.value.new_name);
                const session = self.sessions.get(parsed.value.name) orelse return error.SessionNotFound;
                if (parsed.value.expected_id) |id| if (!std.mem.eql(u8, id, &session.identity.id)) return error.SessionNotFound;
                try self.renameSession(session, parsed.value.new_name);
                client.closing = true;
                try self.respond(client, .ok, "");
            },
            .cat => {
                if (client.session != null) return error.InvalidMessage;
                try config.validateName(msg.payload);
                const session = self.sessions.get(msg.payload) orelse return error.SessionNotFound;
                client.snapshot = try terminal.history(self.allocator, &session.term);
                client.closing = true;
                try self.respond(client, .ok, "");
            },
            .detach, .detach_current => {
                if (client.session != null) return error.InvalidMessage;
                const parsed = if (msg.tag == .detach_current) std.json.parseFromSlice(protocol.SessionTarget, self.allocator, msg.payload, .{}) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    return error.InvalidMessage;
                } else null;
                defer if (parsed) |value| value.deinit();
                const name = if (parsed) |value| value.value.name else msg.payload;
                try config.validateName(name);
                const session = self.sessions.get(name) orelse return error.SessionNotFound;
                if (parsed) |value| if (!std.mem.eql(u8, value.value.expected_id, &session.identity.id)) return error.SessionNotFound;
                while (session.clients.items.len > 0) {
                    const attached = session.clients.items[session.clients.items.len - 1];
                    try signalClient(attached);
                    try self.dropClient(attached);
                }
                client.closing = true;
                try self.respond(client, .ok, "");
            },
            .kill => {
                if (client.session != null) return error.InvalidMessage;
                try config.validateName(msg.payload);
                const session = self.sessions.get(msg.payload) orelse return error.SessionNotFound;
                try self.finishSession(session, true);
                client.closing = true;
                try self.respond(client, .ok, "");
            },
            .input => {
                const session = client.session orelse return error.InvalidMessage;
                if (client.switch_departing) return;
                if (msg.payload.len > 0) session.input_client = client;
                try session.input.append(self.allocator, msg.payload);
                try self.updateSession(session);
            },
            .resize => {
                const session = client.session orelse return error.InvalidMessage;
                client.size = try sys.Size.decode(msg.payload);
                if (session.leader == client) try self.resize(session, client.size);
            },
            else => return error.InvalidMessage,
        }
    }

    fn clientEvent(self: *Server, client: *Client, events: u32) !void {
        if (events & c.EPOLLIN != 0) {
            const alive = client.reader.receive(self.allocator, client.fd) catch |err| switch (err) {
                error.ConnectionClosed => false,
                error.MessageTooLarge => {
                    try self.respond(client, .failure, @errorName(err));
                    client.closing = true;
                    return;
                },
                else => return err,
            };
            if (!alive) return self.dropClient(client);
            while (true) {
                const msg = client.reader.next() catch |err| {
                    client.closing = true;
                    try self.respond(client, .failure, @errorName(err));
                    break;
                };
                const message = msg orelse break;
                self.request(client, message) catch |err| switch (err) {
                    error.SlowClient => {
                        try signalClient(client);
                        return self.dropClient(client);
                    },
                    error.SessionNotFound, error.SessionAlreadyExists, error.SessionBusy, error.BackendTimeout, error.InvalidSessionName, error.InvalidMessage, error.InvalidTerminalSize, error.InvalidCreatedFormat, error.ShellExecFailed, error.SwitchOutsideSession, error.NoAttachedClient, error.SwitchUnsupportedByClient, error.SwitchInProgress, error.SwitchClientDisconnected, error.SwitchClientBusy, error.ReadOnlyClient, error.ReadOnlyUnsupportedByClient => {
                        client.closing = true;
                        try self.respond(client, .failure, @errorName(err));
                    },
                    else => return err,
                };
                if (client.closing) break;
            }
        }
        if (events & c.EPOLLOUT != 0) {
            // 已经发送部分字节的输出必须先完成，保持切换消息的字节顺序。
            if (client.live_started) {
                client.flushLive() catch |err| switch (err) {
                    error.ConnectionClosed => return self.dropClient(client),
                    else => return err,
                };
            }
            if (!client.live_started) {
                client.output.flush(client.fd, true) catch |err| switch (err) {
                    error.ConnectionClosed => return self.dropClient(client),
                    else => return err,
                };
                if (client.output.pending().len == 0) {
                    if (client.snapshot) |snapshot| {
                        const count = @min(snapshot.len - client.snapshot_offset, 16 * 1024);
                        try client.output.message(self.allocator, .output, snapshot[client.snapshot_offset..][0..count]);
                        client.snapshot_offset += count;
                        if (client.snapshot_offset == snapshot.len) {
                            if (client.snapshot_owned) self.allocator.free(snapshot);
                            client.snapshot = null;
                            client.snapshot_offset = 0;
                            if (client.preview != null) try client.output.message(self.allocator, .done, "");
                        }
                    } else if (client.live.pending().len > 0) {
                        client.flushLive() catch |err| switch (err) {
                            error.ConnectionClosed => return self.dropClient(client),
                            else => return err,
                        };
                    } else if (client.closing) return self.dropClient(client);
                }
            }
            if (client.preview != null) try self.sendPreview(client);
            try self.updateClient(client);
        }
        if (events & (c.EPOLLERR | c.EPOLLHUP | c.EPOLLRDHUP) != 0 and events & c.EPOLLIN == 0) return self.dropClient(client);
    }

    fn sessionEvent(self: *Server, session: *Session, events: u32) !void {
        if (events & (c.EPOLLIN | c.EPOLLHUP | c.EPOLLERR) != 0) {
            var buffer: [4096]u8 = undefined;
            const n = try sys.readPty(session.fd, &buffer);
            if (n) |count| {
                if (count == 0) return self.finishSession(session, true);
                session.stream.nextSlice(buffer[0..count]);
                if (session.stream.handler.semantic_failure) return error.TerminalStateFailure;
                try self.changed(session);
                const output_limit = @max(protocol.max_queue, @as(usize, session.term.cols) * session.term.rows * 128);
                var i: usize = 0;
                while (i < session.clients.items.len) {
                    const client = session.clients.items[i];
                    // 保留连接经历的最大屏幕容量，窗口缩小时也能发送完已有输出。
                    client.live.limit = @max(client.live.limit, output_limit);
                    // 屏幕快照必须先发送，期间产生的输出保存在有容量限制的队列中。
                    client.live.message(self.allocator, .output, buffer[0..count]) catch |err| switch (err) {
                        error.SlowClient => {
                            try signalClient(client);
                            try self.dropClient(client);
                            continue;
                        },
                        else => return err,
                    };
                    try self.updateClient(client);
                    i += 1;
                }
                try self.updateSession(session);
            } else if (session.exited) return self.finishSession(session, true);
        }
        if (events & c.EPOLLOUT != 0) {
            try session.input.flush(session.fd, false);
            try self.updateSession(session);
        }
    }

    fn acceptClients(self: *Server) !void {
        while (true) {
            const fd = c.accept4(self.listener, null, null, c.SOCK_NONBLOCK | c.SOCK_CLOEXEC);
            if (fd < 0) {
                if (c.__errno_location().* == c.EAGAIN) return;
                if (c.__errno_location().* == c.EINTR) continue;
                return sys.failure("accept4");
            }
            try config.checkPeer(fd);
            if (self.resources.count() - self.sessions.count() >= 258) {
                sys.close(fd);
                continue;
            }
            const client = try self.allocator.create(Client);
            client.* = .{ .fd = fd, .id = 0 };
            client.id = try self.add(fd, .{ .client = client });
        }
    }

    fn signals(self: *Server) !bool {
        var info: c.struct_signalfd_siginfo = undefined;
        while ((try sys.read(self.signal, std.mem.asBytes(&info))) != null) {
            if (info.ssi_signo == c.SIGCHLD) {
                while (true) {
                    const pid = c.waitpid(-1, null, c.WNOHANG);
                    if (pid <= 0) break;
                    var it = self.sessions.valueIterator();
                    while (it.next()) |session| {
                        if (session.*.pid == pid) session.*.exited = true;
                    }
                }
                var exited: std.ArrayList(*Session) = .empty;
                defer exited.deinit(self.allocator);
                var it = self.sessions.valueIterator();
                while (it.next()) |session| {
                    if (session.*.exited) try exited.append(self.allocator, session.*);
                }
                for (exited.items) |session| {
                    const id = session.id;
                    while (self.resources.contains(id)) {
                        try self.sessionEvent(session, c.EPOLLIN);
                    }
                }
            } else return false;
        }
        return true;
    }

    fn loop(self: *Server) !void {
        var events: [64]c.struct_epoll_event = undefined;
        while (true) {
            if (self.sessions.count() == 0 and self.resources.count() == 2) {
                const lock = c.openat(self.cfg.dir_fd, self.cfg.lock_name, c.O_RDWR | c.O_NOFOLLOW | c.O_CLOEXEC);
                _ = try sys.check(lock, "open(shutdown lock)");
                defer sys.close(lock);
                if (c.flock(lock, c.LOCK_EX | c.LOCK_NB) == 0) {
                    try self.acceptClients();
                    if (self.resources.count() == 2) {
                        _ = try sys.check(c.unlinkat(self.cfg.dir_fd, self.cfg.socket_name, 0), "unlink(socket)");
                        return;
                    }
                } else if (c.__errno_location().* != c.EAGAIN) return sys.failure("flock(shutdown)");
            }
            const count = c.epoll_wait(self.epoll, &events, events.len, -1);
            if (count < 0) {
                if (c.__errno_location().* == c.EINTR) continue;
                return sys.failure("epoll_wait");
            }
            for (events[0..@intCast(count)]) |event| {
                const resource = self.resources.get(event.data.u64) orelse continue;
                switch (resource) {
                    .listener => try self.acceptClients(),
                    .signal => if (!try self.signals()) return,
                    .client => |client| try self.clientEvent(client, event.events),
                    .session => |session| try self.sessionEvent(session, event.events),
                }
            }
        }
    }
};

fn displayWidth(text: []const u8) !usize {
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    var width: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| width += terminal.vt.unicode.codepointWidth(codepoint);
    return width;
}

fn listRow(writer: *std.Io.Writer, fields: [5][]const u8, widths: [5]usize, table: bool) !void {
    for (fields, widths, 0..) |field, width, index| {
        try writer.writeAll(field);
        if (index == fields.len - 1) {
            try writer.writeByte('\n');
        } else if (table) {
            try writer.splatByteAll(' ', width - try displayWidth(field) + 2);
        } else {
            try writer.writeByte('\t');
        }
    }
}

fn writePty(handler: *Handler, data: []const u8) void {
    const session: *Session = @fieldParentPtr("term", handler.terminal);
    session.input.append(session.allocator, data) catch @panic("terminal response buffer failed");
}

fn deviceAttributes(_: *Handler) terminal.vt.device_attributes.Attributes {
    return .{};
}

fn signalClient(client: *const Client) !void {
    if (client.session == null) return;
    const credentials = try config.peer(client.fd);
    const raw = std.os.linux.pidfd_open(credentials.pid, 0);
    switch (std.os.linux.errno(raw)) {
        .SUCCESS => {},
        .SRCH => return,
        else => return error.PidfdOpenFailed,
    }
    const fd: c_int = @intCast(raw);
    defer sys.close(fd);
    switch (std.os.linux.errno(std.os.linux.pidfd_send_signal(fd, .TERM, null, 0))) {
        .SUCCESS, .SRCH => {},
        else => return error.PidfdSendSignalFailed,
    }
}

fn stopClients(self: *Server) !void {
    var iterator = self.resources.valueIterator();
    while (iterator.next()) |resource| switch (resource.*) {
        .client => |client| try signalClient(client),
        else => {},
    };
}

pub fn terminateSession(sid: c.pid_t) !void {
    const allocator = std.heap.c_allocator;
    var descriptors: std.ArrayList(c_int) = .empty;
    defer {
        for (descriptors.items) |fd| sys.close(fd);
        descriptors.deinit(allocator);
    }
    const directory = c.opendir("/proc") orelse return sys.failure("opendir(/proc)");
    defer _ = c.closedir(directory);
    while (c.readdir(directory)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (name.len == 0 or !std.ascii.isDigit(name[0])) continue;
        const pid = std.fmt.parseInt(c.pid_t, name, 10) catch return error.InvalidProcessDirectory;
        if (c.getsid(pid) != sid) continue;
        try descriptors.ensureUnusedCapacity(allocator, 1);
        const raw = std.os.linux.pidfd_open(pid, 0);
        switch (std.os.linux.errno(raw)) {
            .SUCCESS => {},
            .SRCH => continue,
            else => return error.PidfdOpenFailed,
        }
        const fd: c_int = @intCast(raw);
        if (c.getsid(pid) != sid) {
            sys.close(fd);
            continue;
        }
        descriptors.appendAssumeCapacity(fd);
        const result = std.os.linux.pidfd_send_signal(fd, .KILL, null, 0);
        switch (std.os.linux.errno(result)) {
            .SUCCESS, .SRCH => {},
            else => return error.PidfdSendSignalFailed,
        }
    }
    const deadline = try sys.monotonicMilliseconds() + 5000;
    for (descriptors.items) |fd| {
        var event: c.struct_pollfd = .{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        while (true) {
            const timeout: c_int = @intCast(@max(0, deadline - try sys.monotonicMilliseconds()));
            const result = c.poll(&event, 1, timeout);
            if (result < 0 and c.__errno_location().* == c.EINTR) continue;
            if (try sys.check(result, "poll(session exit)") == 0) return error.SessionTerminationTimeout;
            if (event.revents & (c.POLLIN | c.POLLHUP) == 0) return error.PidfdWaitFailed;
            break;
        }
    }
    for (descriptors.items) |fd| {
        var info: c.siginfo_t = undefined;
        // pidfd 保持进程身份，waitid 回收已由后台进程接管的子进程。
        while (c.waitid(c.P_PIDFD, @intCast(fd), &info, c.WEXITED) < 0) {
            switch (c.__errno_location().*) {
                c.EINTR => continue,
                c.ECHILD => break,
                else => return sys.failure("waitid(session child)"),
            }
        }
    }
}

fn renameLock(fd: c_int) !void {
    while (c.flock(fd, c.LOCK_EX | c.LOCK_NB) < 0) {
        if (c.__errno_location().* == c.EINTR) continue;
        if (c.__errno_location().* == c.EAGAIN) return error.SessionBusy;
        return sys.failure("flock(rename)");
    }
}

fn spawnShell(allocator: Allocator, cfg: *const config.Config, name: []const u8, session_id: []const u8, cwd: []const u8, shell: []const u8, environment: []const u8, size: sys.Size) !struct { pid: c.pid_t, fd: c_int } {
    const env_bytes = try allocator.dupe(u8, environment);
    defer allocator.free(env_bytes);
    var envp: std.ArrayList(?[*:0]const u8) = .empty;
    defer envp.deinit(allocator);
    var fields = std.mem.splitScalar(u8, env_bytes, 0);
    while (fields.next()) |entry| {
        if (entry.len == 0) continue;
        if (std.mem.indexOfScalar(u8, entry, '=') == null) return error.InvalidMessage;
        if (std.mem.startsWith(u8, entry, "IMX_SESSION=") or std.mem.startsWith(u8, entry, "IMX_DIR=")) continue;
        if (std.mem.startsWith(u8, entry, protocol.client_marker_prefix)) continue;
        if (std.mem.startsWith(u8, entry, protocol.readonly_marker_prefix)) continue;
        if (std.mem.startsWith(u8, entry, protocol.rename_marker_prefix) or std.mem.startsWith(u8, entry, identity.variable ++ "=")) continue;
        if (std.mem.startsWith(u8, entry, @import("pane_context.zig").variable ++ "=")) continue;
        if (std.mem.startsWith(u8, entry, @import("pane_context.zig").readonly_variable ++ "=")) continue;
        try envp.append(allocator, @ptrCast(entry.ptr));
    }
    const session_env = try std.fmt.allocPrintSentinel(allocator, "IMX_SESSION={s}", .{name}, 0);
    defer allocator.free(session_env);
    const directory_env = try std.fmt.allocPrintSentinel(allocator, "IMX_DIR={s}", .{cfg.path}, 0);
    defer allocator.free(directory_env);
    const identity_env = try std.fmt.allocPrintSentinel(allocator, identity.variable ++ "={s}", .{session_id}, 0);
    defer allocator.free(identity_env);
    try envp.appendSlice(allocator, &.{ session_env.ptr, directory_env.ptr, identity_env.ptr, null });
    const cwd_z = try allocator.dupeSentinel(u8, cwd, 0);
    defer allocator.free(cwd_z);
    const shell_z = try allocator.dupeSentinel(u8, shell, 0);
    defer allocator.free(shell_z);
    const argv = [_:null]?[*:0]const u8{ shell_z.ptr, "-l" };
    var ready: [2]c_int = undefined;
    _ = try sys.check(c.pipe2(&ready, c.O_CLOEXEC), "pipe2(shell readiness)");
    defer sys.close(ready[0]);
    var fd: c_int = undefined;
    const winsize: c.struct_winsize = .{ .ws_row = size.rows, .ws_col = size.cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    const pid = try sys.check(c.forkpty(&fd, null, null, &winsize), "forkpty");
    if (pid == 0) {
        sys.close(ready[0]);
        if (c.dup3(ready[1], 3, c.O_CLOEXEC) < 0) c._exit(126);
        checkCloseRange(4, std.math.maxInt(c_int)) catch c._exit(126);
        sys.unblockSignals() catch c._exit(126);
        if (c.chdir(cwd_z) == 0) _ = c.execve(shell_z, @ptrCast(&argv), @ptrCast(envp.items.ptr));
        const errno_value = c.__errno_location().*;
        _ = c.write(3, &errno_value, @sizeOf(c_int));
        c._exit(126);
    }
    sys.close(ready[1]);
    var errno_value: c_int = undefined;
    const n = (try sys.read(ready[0], std.mem.asBytes(&errno_value))).?;
    if (n != 0) {
        sys.close(fd);
        _ = c.waitpid(pid, null, 0);
        return error.ShellExecFailed;
    }
    _ = try sys.nonblocking(fd, true);
    _ = try sys.check(c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC), "fcntl(PTY CLOEXEC)");
    return .{ .pid = pid, .fd = fd };
}

pub fn run(allocator: Allocator, io: std.Io, cfg: *const config.Config, ready_fd: c_int) !void {
    var active_config = (try cfg.session(io, cfg.session_name.?, false)).?;
    defer active_config.deinit();
    _ = try sys.check(c.prctl(c.PR_SET_CHILD_SUBREAPER, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)), "prctl(subreaper)");
    const signal = try sys.signalFd(&.{ c.SIGCHLD, c.SIGTERM, c.SIGINT, c.SIGHUP });
    defer sys.close(signal);
    const listener = try sys.check(c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0), "socket(listener)");
    defer sys.close(listener);
    if (c.unlinkat(cfg.dir_fd, cfg.socket_name, 0) < 0 and c.__errno_location().* != c.ENOENT) return sys.failure("unlink(stale socket)");
    var address = cfg.address();
    _ = try sys.check(c.bind(listener, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)), "bind");
    _ = try sys.check(c.listen(listener, 128), "listen");
    const epoll = try sys.check(c.epoll_create1(c.EPOLL_CLOEXEC), "epoll_create1");
    defer sys.close(epoll);
    var self: Server = .{
        .allocator = allocator,
        .io = io,
        .cfg = &active_config,
        .listener = listener,
        .signal = signal,
        .epoll = epoll,
        .resources = std.AutoHashMap(u64, Resource).init(allocator),
        .sessions = std.StringHashMap(*Session).init(allocator),
    };
    defer self.resources.deinit();
    defer self.sessions.deinit();
    defer {
        var remaining = self.sessions.valueIterator();
        while (remaining.next()) |session| session.*.identity.remove(self.cfg.dir_fd);
    }
    try self.resources.put(1, .listener);
    try self.resources.put(2, .signal);
    try self.watch(c.EPOLL_CTL_ADD, listener, 1, false);
    try self.watch(c.EPOLL_CTL_ADD, signal, 2, false);
    try sys.writeAll(ready_fd, "R", false);
    sys.close(ready_fd);
    self.loop() catch |err| {
        try stopClients(&self);
        var it = self.sessions.valueIterator();
        while (it.next()) |session| try terminateSession(session.*.pid);
        return err;
    };
    try stopClients(&self);
    var it = self.sessions.valueIterator();
    while (it.next()) |session| try terminateSession(session.*.pid);
}

pub fn start(allocator: Allocator, io: std.Io, cfg: *const config.Config) !void {
    var ready: [2]c_int = undefined;
    _ = try sys.check(c.pipe2(&ready, c.O_CLOEXEC), "pipe2(daemon readiness)");
    defer sys.close(ready[0]);
    const pid = try sys.check(c.fork(), "fork(daemon)");
    if (pid == 0) {
        sys.close(ready[0]);
        _ = sys.check(c.setsid(), "setsid") catch c._exit(1);
        const daemon_pid = sys.check(c.fork(), "fork(detach daemon)") catch c._exit(1);
        if (daemon_pid != 0) c._exit(0);
        _ = c.umask(0o077);
        const null_fd = sys.check(c.open("/dev/null", c.O_RDWR | c.O_CLOEXEC), "open(/dev/null)") catch c._exit(1);
        const log_fd = sys.check(c.openat(cfg.dir_fd, cfg.log_name, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600)), "open(session log)") catch c._exit(1);
        for (0..2) |fd| _ = c.dup2(null_fd, @intCast(fd));
        _ = c.dup2(log_fd, 2);
        sys.close(null_fd);
        sys.close(log_fd);
        const first = @min(cfg.dir_fd, ready[1]);
        const last = @max(cfg.dir_fd, ready[1]);
        if (first > 3) checkCloseRange(3, @intCast(first - 1)) catch c._exit(1);
        if (last > first + 1) checkCloseRange(@intCast(first + 1), @intCast(last - 1)) catch c._exit(1);
        checkCloseRange(@intCast(last + 1), std.math.maxInt(c_int)) catch c._exit(1);
        _ = sys.check(c.prctl(c.PR_SET_NAME, @as([*:0]const u8, "imx-server"), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)), "prctl(process name)") catch c._exit(1);
        run(allocator, io, cfg, ready[1]) catch |err| {
            std.log.err("daemon: {s}", .{@errorName(err)});
            c._exit(1);
        };
        c._exit(0);
    }
    sys.close(ready[1]);
    var status: c_int = undefined;
    _ = try sys.check(c.waitpid(pid, &status, 0), "waitpid(daemon launcher)");
    var pollfd: c.struct_pollfd = .{ .fd = ready[0], .events = c.POLLIN, .revents = 0 };
    if (try sys.check(c.poll(&pollfd, 1, 5000), "poll(daemon readiness)") == 0) return error.DaemonStartTimeout;
    var byte: [1]u8 = undefined;
    if ((try sys.read(ready[0], &byte)).? != 1 or byte[0] != 'R') return error.DaemonStartFailed;
}

fn checkCloseRange(first: c_int, last: c_int) !void {
    const errno_value = std.os.linux.errno(std.os.linux.close_range(first, last, .{ .UNSHARE = false, .CLOEXEC = false }));
    if (errno_value != .SUCCESS) return error.CloseRangeFailed;
}
