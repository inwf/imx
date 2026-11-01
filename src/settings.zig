const std = @import("std");
const config = @import("config.zig");
const sys = @import("sys.zig");
const toml = @import("toml");
const keyboard = @import("keyboard.zig");

pub const Settings = struct {
    show_session: bool = true,
    completion_enabled: bool = true,
    keybindings: keyboard.Bindings = .{},
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
    const contents = std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(1024 * 1024)) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        if (!options.create_default) return .{ .file_missing = true };
        try createDefault(io, filename);
        break :blk try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(1024 * 1024));
    };
    defer allocator.free(contents);
    return parse(allocator, contents);
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
    if (!std.unicode.utf8ValidateSlice(contents)) return error.InvalidConfigurationUtf8;
    const result = toml.toml_parse(contents.ptr, @intCast(contents.len));
    defer toml.toml_free(result);
    if (!result.ok) {
        std.log.err("config.toml: {s}", .{std.mem.sliceTo(&result.errmsg, 0)});
        return error.InvalidConfiguration;
    }
    const root = result.toptab;
    for (0..@intCast(root.u.tab.size)) |index| {
        const key = std.mem.span(root.u.tab.key[index]);
        if (!std.mem.eql(u8, key, "prompt") and !std.mem.eql(u8, key, "list") and !std.mem.eql(u8, key, "completion") and !std.mem.eql(u8, key, "keybindings")) return error.UnknownConfigurationOption;
    }
    var preferences: Settings = .{};
    const prompt = toml.toml_get(root, "prompt");
    if (prompt.type != toml.TOML_UNKNOWN) {
        if (prompt.type != toml.TOML_TABLE) return error.InvalidPromptConfiguration;
        for (0..@intCast(prompt.u.tab.size)) |index| {
            if (!std.mem.eql(u8, std.mem.span(prompt.u.tab.key[index]), "show_session")) return error.UnknownConfigurationOption;
        }
        const enabled = toml.toml_get(prompt, "show_session");
        if (enabled.type != toml.TOML_UNKNOWN) {
            if (enabled.type != toml.TOML_BOOLEAN) return error.PromptShowSessionMustBeBoolean;
            preferences.show_session = enabled.u.boolean;
        }
    }
    const completion = toml.toml_get(root, "completion");
    if (completion.type != toml.TOML_UNKNOWN) {
        if (completion.type != toml.TOML_TABLE) return error.InvalidCompletionConfiguration;
        for (0..@intCast(completion.u.tab.size)) |index| {
            if (!std.mem.eql(u8, std.mem.span(completion.u.tab.key[index]), "enabled")) return error.UnknownConfigurationOption;
        }
        const enabled = toml.toml_get(completion, "enabled");
        if (enabled.type != toml.TOML_UNKNOWN) {
            if (enabled.type != toml.TOML_BOOLEAN) return error.CompletionEnabledMustBeBoolean;
            preferences.completion_enabled = enabled.u.boolean;
        }
    }
    const bindings = toml.toml_get(root, "keybindings");
    if (bindings.type != toml.TOML_UNKNOWN) {
        if (bindings.type != toml.TOML_TABLE) return error.InvalidKeybindingsConfiguration;
        for (0..@intCast(bindings.u.tab.size)) |index| {
            const name = std.mem.span(bindings.u.tab.key[index]);
            if (std.meta.stringToEnum(keyboard.Action, name) == null) return error.UnknownConfigurationOption;
        }
        inline for (std.enums.values(keyboard.Action)) |action| {
            const binding = toml.toml_get(bindings, @tagName(action));
            if (binding.type != toml.TOML_UNKNOWN) @field(preferences.keybindings, @tagName(action)) = try parseBinding(binding);
        }
    }
    const listing = toml.toml_get(root, "list");
    if (listing.type != toml.TOML_UNKNOWN) {
        if (listing.type != toml.TOML_TABLE) return error.InvalidListConfiguration;
        for (0..@intCast(listing.u.tab.size)) |index| {
            if (!std.mem.eql(u8, std.mem.span(listing.u.tab.key[index]), "created_format")) return error.UnknownConfigurationOption;
        }
        const format = toml.toml_get(listing, "created_format");
        if (format.type != toml.TOML_UNKNOWN) {
            if (format.type != toml.TOML_STRING) return error.ListCreatedFormatMustBeString;
            const value = format.u.str.ptr[0..@intCast(format.u.str.len) :0];
            try sys.validateCreatedFormat(value);
            preferences.created_format = try allocator.dupeSentinel(u8, value, 0);
        }
    }
    return preferences;
}

fn parseBinding(value: toml.toml_datum_t) !keyboard.Binding {
    if (value.type != toml.TOML_TABLE) return error.KeybindingMustBeTable;
    const modifiers = .{ "ctrl", "alt", "shift", "super" };
    for (0..@intCast(value.u.tab.size)) |index| {
        const field = std.mem.span(value.u.tab.key[index]);
        if (std.mem.eql(u8, field, "key")) continue;
        var known = false;
        inline for (modifiers) |modifier| {
            if (std.mem.eql(u8, field, modifier)) known = true;
        }
        if (!known) return error.UnknownConfigurationOption;
    }
    const key = toml.toml_get(value, "key");
    if (key.type == toml.TOML_UNKNOWN) return error.KeybindingKeyRequired;
    if (key.type != toml.TOML_STRING) return error.KeybindingKeyMustBeString;
    var binding: keyboard.Binding = .{ .codepoint = try keyboard.Binding.keyCodepoint(key.u.str.ptr[0..@intCast(key.u.str.len)]) };
    inline for (modifiers) |modifier| {
        const enabled = toml.toml_get(value, modifier);
        if (enabled.type != toml.TOML_UNKNOWN) {
            if (enabled.type != toml.TOML_BOOLEAN) return error.KeybindingModifierMustBeBoolean;
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
