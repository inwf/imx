const std = @import("std");
const Translator = @import("translate_c").Translator;
const manifest = @import("build.zig.zon");
const layout = @import("src/layout.zig");

pub fn build(b: *std.Build) void {
    var target_query = b.standardTargetOptionsQueryOnly(.{
        .default_target = .{ .os_tag = .linux, .abi = .musl },
    });
    if (target_query.abi == null) target_query.abi = .musl;
    const target = b.resolveTargetQuery(target_query);
    if (target.result.os.tag != .linux) @panic("imx supports Linux only");
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode") orelse .safe;
    const tomlc17 = b.dependency("tomlc17", .{});
    const toml: Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "toml",
        .c_source_file = tomlc17.path("src/tomlc17.h"),
        .target = target,
        .optimize = optimize,
    });
    toml.mod.addCSourceFile(.{ .file = tomlc17.path("src/tomlc17.c"), .flags = &.{"-std=c17"} });
    const translator: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("src/system.h"),
        .target = target,
        .optimize = optimize,
    });
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        // 终端库按需使用预留的内存页面，imx 自身保留安全检查。
        .optimize = @as(std.builtin.OptimizeMode, if (optimize == .debug) .debug else .fast),
        .@"emit-lib-vt" = true,
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = b.option(bool, "strip", "Strip debug information") orelse (optimize != .debug),
        .imports = &.{
            .{ .name = "c", .module = translator.mod },
            .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
            .{ .name = "toml", .module = toml.mod },
        },
    });
    module.addOptions("build_options", options);
    module.addAnonymousImport("install.sh", .{ .root_source_file = b.path("install.sh") });
    const exe = b.addExecutable(.{ .name = "imx", .root_module = module });
    b.installArtifact(exe);
    for (layout.license_files) |file| {
        const source = if (std.mem.startsWith(u8, file, "third-party/")) b.fmt("licenses/{s}", .{file[12..]}) else file;
        b.installFile(source, b.fmt("share/licenses/imx/{s}", .{file}));
    }
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run imx").dependOn(&run.step);
    const unit = b.addTest(.{ .root_module = module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit).step);
}
