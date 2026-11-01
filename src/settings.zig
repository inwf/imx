const std = @import("std");
const config = @import("config.zig");
const sys = @import("sys.zig");
const toml = @import("toml");
const keyboard = @import("keyboard.zig");
const vt = @import("ghostty-vt");

const Context = struct {
    allocator: std.mem.Allocator,
    filename: ?[]const u8 = null,
    keys: [3][]const u8 = .{ "", "", "" },
    depth: usize = 0,

    fn child(self: Context, key: []const u8) Context {
        var result = self;
        result.keys[result.depth] = key;
        result.depth += 1;
        return result;
    }

    fn reject(self: Context, err: anyerror, message: []const u8) anyerror {
        const filename = self.filename orelse return err;
        var output = std.Io.Writer.Allocating.init(self.allocator);
        defer output.deinit();
        output.writer.print("imx: {s}: ", .{filename}) catch |failure| return failure;
        for (self.keys[0..self.depth], 0..) |key, index| {
            if (index != 0) output.writer.writeByte('.') catch |failure| return failure;
            output.writer.writeAll(key) catch |failure| return failure;
        }
        if (self.depth != 0) output.writer.writeAll(": ") catch |failure| return failure;
        output.writer.print("{s} ({s})\n", .{ message, @errorName(err) }) catch |failure| return failure;
        sys.writeAll(2, output.written(), false) catch |failure| return failure;
        return error.RequestFailed;
    }
};

pub const Settings = struct {
    show_session: bool = true,
    completion_enabled: bool = true,
    keybindings: keyboard.Bindings = .{},
    focused_border_color: ?vt.color.RGB = null,
    created_format: ?[:0]u8 = null,
    file_missing: bool = false,

    pub fn createdFormat(self: Settings) [:0]const u8 {
        return self.created_format orelse sys.default_created_format;
    }

    pub fn deinit(self: *Settings, allocator: std.mem.Allocator) void {
        if (self.created_format) |format| allocator.free(format);
    }
};

pub fn path(allocator: std.mem.Allocator) ![:0]u8 {
    const root = config.env("XDG_CONFIG_HOME");
    const home = config.env("HOME") orelse return error.HomeNotSet;
    if (!std.fs.path.isAbsolute(home)) return error.HomeMustBeAbsolute;
    if (root) |value| {
        if (value.len != 0) {
            if (!std.fs.path.isAbsolute(value)) return error.ConfigPathMustBeAbsolute;
            return std.fmt.allocPrintSentinel(allocator, "{s}/imx/config.toml", .{value}, 0);
        }
    }
    return std.fmt.allocPrintSentinel(allocator, "{s}/.config/imx/config.toml", .{home}, 0);
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, options: struct { create_default: bool = false }) !Settings {
    const filename = try path(allocator);
    defer allocator.free(filename);
    const context: Context = .{ .allocator = allocator, .filename = filename };
    const contents = std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(1024 * 1024)) catch |err| blk: {
        if (err != error.FileNotFound) return context.reject(err, "cannot read configuration");
        if (!options.create_default) return .{ .file_missing = true };
        createDefault(io, filename) catch |failure| return context.reject(failure, "cannot create default configuration");
        break :blk std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(1024 * 1024)) catch |failure| return context.reject(failure, "cannot read configuration");
    };
    defer allocator.free(contents);
    return parseDocument(context, contents);
}

fn createDefault(io: std.Io, filename: []const u8) !void {
    const parent = std.fs.path.dirname(filename).?;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, parent, .fromMode(0o700));
    const directory = try std.Io.Dir.openDirAbsolute(io, parent, .{ .iterate = true });
    defer directory.close(io);
    var file = try directory.createFileAtomic(io, std.fs.path.basename(filename), .{ .permissions = .fromMode(0o600) });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, @embedFile("default-config.toml"));
    try file.file.sync(io);
    // 完整写入后再公开文件；并发创建时读取已经存在的配置。
    file.link(io) catch |err| {
        if (err == error.PathAlreadyExists) return;
        return err;
    };
    _ = try sys.check(sys.c.fsync(directory.handle), "fsync(configuration directory)");
}

fn parse(allocator: std.mem.Allocator, contents: []const u8) !Settings {
    return parseDocument(.{ .allocator = allocator }, contents);
}

fn validateKeys(context: Context, table: toml.toml_datum_t, allowed: []const []const u8) !void {
    for (0..@intCast(table.u.tab.size)) |index| {
        const key = std.mem.span(table.u.tab.key[index]);
        for (allowed) |known| {
            if (std.mem.eql(u8, key, known)) break;
        } else return context.child(key).reject(error.UnknownConfigurationOption, "unknown configuration option");
    }
}

fn parseDocument(context: Context, contents: []const u8) !Settings {
    if (!std.unicode.utf8ValidateSlice(contents)) return context.reject(error.InvalidConfigurationUtf8, "expected UTF-8 text");
    const result = toml.toml_parse(contents.ptr, @intCast(contents.len));
    defer toml.toml_free(result);
    if (!result.ok) {
        return context.reject(error.InvalidConfiguration, std.mem.sliceTo(&result.errmsg, 0));
    }
    const root = result.toptab;
    try validateKeys(context, root, &.{ "prompt", "list", "completion", "keybindings", "panes" });
    var preferences: Settings = .{};
    const prompt = toml.toml_get(root, "prompt");
    if (prompt.type != toml.TOML_UNKNOWN) {
        const field = context.child("prompt");
        if (prompt.type != toml.TOML_TABLE) return field.reject(error.InvalidPromptConfiguration, "expected a table");
        try validateKeys(field, prompt, &.{"show_session"});
        const enabled = toml.toml_get(prompt, "show_session");
        if (enabled.type != toml.TOML_UNKNOWN) {
            if (enabled.type != toml.TOML_BOOLEAN) return field.child("show_session").reject(error.PromptShowSessionMustBeBoolean, "expected a boolean (true or false)");
            preferences.show_session = enabled.u.boolean;
        }
    }
    const completion = toml.toml_get(root, "completion");
    if (completion.type != toml.TOML_UNKNOWN) {
        const field = context.child("completion");
        if (completion.type != toml.TOML_TABLE) return field.reject(error.InvalidCompletionConfiguration, "expected a table");
        try validateKeys(field, completion, &.{"enabled"});
        const enabled = toml.toml_get(completion, "enabled");
        if (enabled.type != toml.TOML_UNKNOWN) {
            if (enabled.type != toml.TOML_BOOLEAN) return field.child("enabled").reject(error.CompletionEnabledMustBeBoolean, "expected a boolean (true or false)");
            preferences.completion_enabled = enabled.u.boolean;
        }
    }
    const bindings = toml.toml_get(root, "keybindings");
    if (bindings.type != toml.TOML_UNKNOWN) {
        const field = context.child("keybindings");
        if (bindings.type != toml.TOML_TABLE) return field.reject(error.InvalidKeybindingsConfiguration, "expected a table");
        for (0..@intCast(bindings.u.tab.size)) |index| {
            const name = std.mem.span(bindings.u.tab.key[index]);
            if (std.meta.stringToEnum(keyboard.Action, name) == null) return field.child(name).reject(error.UnknownConfigurationOption, "unknown configuration option");
        }
        inline for (std.enums.values(keyboard.Action)) |action| {
            const binding = toml.toml_get(bindings, @tagName(action));
            if (binding.type != toml.TOML_UNKNOWN) @field(preferences.keybindings, @tagName(action)) = try parseBinding(field.child(@tagName(action)), binding);
        }
        inline for (std.enums.values(keyboard.Action), 0..) |action, index| {
            const value = @field(preferences.keybindings, @tagName(action));
            inline for (std.enums.values(keyboard.Action)[0..index]) |previous| {
                const other = @field(preferences.keybindings, @tagName(previous));
                if (value.codepoint == other.codepoint and value.mods.eql(other.mods)) return field.child(@tagName(action)).reject(error.DuplicateKeybinding, "shortcut conflicts with keybindings." ++ @tagName(previous));
            }
        }
    }
    const panes = toml.toml_get(root, "panes");
    if (panes.type != toml.TOML_UNKNOWN) {
        const field = context.child("panes");
        if (panes.type != toml.TOML_TABLE) return field.reject(error.InvalidPanesConfiguration, "expected a table");
        try validateKeys(field, panes, &.{"focused_border_color"});
        const color = toml.toml_get(panes, "focused_border_color");
        if (color.type != toml.TOML_UNKNOWN) {
            const entry = field.child("focused_border_color");
            if (color.type != toml.TOML_STRING) return entry.reject(error.FocusedBorderColorMustBeString, "expected a string in #RRGGBB format");
            const value = color.u.str.ptr[0..@intCast(color.u.str.len)];
            if (value.len != 7 or value[0] != '#') return entry.reject(error.InvalidFocusedBorderColor, "expected # followed by six hexadecimal digits (#RRGGBB)");
            preferences.focused_border_color = vt.color.RGB.parse(value) catch return entry.reject(error.InvalidFocusedBorderColor, "expected # followed by six hexadecimal digits (#RRGGBB)");
        }
    }
    const listing = toml.toml_get(root, "list");
    if (listing.type != toml.TOML_UNKNOWN) {
        const field = context.child("list");
        if (listing.type != toml.TOML_TABLE) return field.reject(error.InvalidListConfiguration, "expected a table");
        try validateKeys(field, listing, &.{"created_format"});
        const format = toml.toml_get(listing, "created_format");
        if (format.type != toml.TOML_UNKNOWN) {
            const entry = field.child("created_format");
            if (format.type != toml.TOML_STRING) return entry.reject(error.ListCreatedFormatMustBeString, "expected a string");
            const value = format.u.str.ptr[0..@intCast(format.u.str.len) :0];
            sys.validateCreatedFormat(value) catch |err| return entry.reject(err, "expected a valid, nonempty, single-line strftime format (for example '%Y-%m-%d %H:%M:%S')");
            preferences.created_format = try context.allocator.dupeSentinel(u8, value, 0);
        }
    }
    return preferences;
}

fn parseBinding(context: Context, value: toml.toml_datum_t) !keyboard.Binding {
    if (value.type != toml.TOML_TABLE) return context.reject(error.KeybindingMustBeTable, "expected a table (for example { key = 'x', ctrl = true })");
    const modifiers = .{ "ctrl", "alt", "shift", "super" };
    try validateKeys(context, value, &.{ "key", "ctrl", "alt", "shift", "super" });
    const key = toml.toml_get(value, "key");
    const field = context.child("key");
    if (key.type == toml.TOML_UNKNOWN) return field.reject(error.KeybindingKeyRequired, "required key is missing");
    if (key.type != toml.TOML_STRING) return field.reject(error.KeybindingKeyMustBeString, "expected a string");
    const codepoint = keyboard.Binding.keyCodepoint(key.u.str.ptr[0..@intCast(key.u.str.len)]) catch |err| return field.reject(err, "expected one printable character or a supported key name (for example Enter, Escape or F1-F12)");
    var binding: keyboard.Binding = .{ .codepoint = codepoint };
    inline for (modifiers) |modifier| {
        const enabled = toml.toml_get(value, modifier);
        if (enabled.type != toml.TOML_UNKNOWN) {
            if (enabled.type != toml.TOML_BOOLEAN) return context.child(modifier).reject(error.KeybindingModifierMustBeBoolean, "expected a boolean (true or false)");
            @field(binding.mods, modifier) = enabled.u.boolean;
        }
    }
    return binding;
}

test "default configuration matches built-in settings" {
    const allocator = std.testing.allocator;
    var preferences = try parse(allocator, @embedFile("default-config.toml"));
    defer preferences.deinit(allocator);
    const defaults: Settings = .{};
    try std.testing.expectEqual(defaults.show_session, preferences.show_session);
    try std.testing.expectEqual(defaults.completion_enabled, preferences.completion_enabled);
    try std.testing.expectEqualDeep(defaults.keybindings, preferences.keybindings);
    try std.testing.expectEqualDeep(defaults.focused_border_color, preferences.focused_border_color);
    try std.testing.expectEqualStrings(defaults.createdFormat(), preferences.createdFormat());
}

test "TOML prompt settings validate types and names" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try parse(allocator, "")).show_session);
    try std.testing.expect((try parse(allocator, "[prompt]\n")).show_session);
    try std.testing.expect((try parse(allocator, "[prompt]\nshow_session = true\n")).show_session);
    try std.testing.expect(!(try parse(allocator, "prompt = { show_session = false }\n")).show_session);
    try std.testing.expectError(error.PromptShowSessionMustBeBoolean, parse(allocator, "[prompt]\nshow_session = 'true'\n"));
    try std.testing.expectError(error.UnknownConfigurationOption, parse(allocator, "[prompt]\nshow_sessions = true\n"));
}

test "TOML list settings preserve the format and prompt option" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings(sys.default_created_format, (try parse(allocator, "")).createdFormat());
    var preferences = try parse(allocator, "[prompt]\nshow_session = true\n[list]\ncreated_format = '%Y-%m-%d %H:%M:%S'\n");
    defer preferences.deinit(allocator);
    try std.testing.expect(preferences.show_session);
    try std.testing.expectEqualStrings("%Y-%m-%d %H:%M:%S", preferences.createdFormat());
    try std.testing.expectError(error.InvalidListConfiguration, parse(allocator, "list = false\n"));
    try std.testing.expectError(error.ListCreatedFormatMustBeString, parse(allocator, "[list]\ncreated_format = true\n"));
    try std.testing.expectError(error.UnknownConfigurationOption, parse(allocator, "[list]\ncreated_formats = '%Y'\n"));
    try std.testing.expectError(error.InvalidCreatedFormat, parse(allocator, "[list]\ncreated_format = '%n'\n"));
    try std.testing.expectError(error.InvalidCreatedFormat, parse(allocator, "[list]\ncreated_format = '%Q'\n"));
}

test "TOML completion settings default to enabled and validate types" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try parse(allocator, "")).completion_enabled);
    try std.testing.expect(!(try parse(allocator, "[completion]\nenabled = false\n")).completion_enabled);
    try std.testing.expectError(error.InvalidCompletionConfiguration, parse(allocator, "completion = true\n"));
    try std.testing.expectError(error.CompletionEnabledMustBeBoolean, parse(allocator, "[completion]\nenabled = 'true'\n"));
    try std.testing.expectError(error.UnknownConfigurationOption, parse(allocator, "[completion]\nenable = true\n"));
}

test "TOML keybindings retain defaults and read explicit modifiers" {
    const allocator = std.testing.allocator;
    const defaults: Settings = .{};
    try std.testing.expectEqualDeep(defaults.keybindings, (try parse(allocator, "")).keybindings);
    try std.testing.expectEqualDeep(defaults.keybindings, (try parse(allocator, "[keybindings]\n")).keybindings);
    const preferences = try parse(allocator, "[keybindings]\ndetach = { key = 'X', ctrl = true, alt = true, shift = true, super = true }\n");
    try std.testing.expectEqual(@as(u21, 'x'), preferences.keybindings.detach.codepoint);
    try std.testing.expectEqual(keyboard.Modifiers{ .ctrl = true, .alt = true, .shift = true, .super = true }, preferences.keybindings.detach.mods);
    const plain = try parse(allocator, "[keybindings.detach]\nkey = 'F5'\n");
    try std.testing.expectEqual(keyboard.Modifiers{}, plain.keybindings.detach.mods);
    try std.testing.expectEqual(try keyboard.Binding.keyCodepoint("f5"), plain.keybindings.detach.codepoint);
}
