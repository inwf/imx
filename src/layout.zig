const std = @import("std");

pub const license_files = [_][]const u8{
    "LICENSE",
    "NOTICE",
    "third-party/Ghostty.txt",
    "third-party/Highway.txt",
    "third-party/UTF8.txt",
    "third-party/Unicode.txt",
    "third-party/Wuffs.txt",
    "third-party/simdutf.txt",
    "third-party/translate-c.txt",
    "third-party/tomlc17.txt",
    "third-party/uucode.md",
    "third-party/zlib.txt",
    "third-party/zmx.txt",
};

pub const completion_files = [_]struct { source: []const u8, destination: []const u8 }{
    .{ .source = "src/completions/bash.sh", .destination = "share/bash-completion/completions/imx" },
    .{ .source = "src/completions/zsh.sh", .destination = "share/zsh/site-functions/_imx" },
    .{ .source = "src/completions/zsh.sh", .destination = "share/zsh/vendor-completions/_imx" },
    .{ .source = "src/completions/fish.fish", .destination = "share/fish/vendor_completions.d/imx.fish" },
};

pub fn systemFishCompletion(prefix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, prefix, "/usr/local")) return "/usr/share/fish/vendor_completions.d/imx.fish";
    if (std.mem.eql(u8, prefix, "/usr")) return "/usr/local/share/fish/vendor_completions.d/imx.fish";
    return null;
}
