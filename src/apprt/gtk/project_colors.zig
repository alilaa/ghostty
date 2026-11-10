//! Project identity colors, matching Anton's WezTerm djb2 palette.
const std = @import("std");

pub const palette = [_]u24{
    0xe06c75, 0xe5c07b, 0x98c379, 0x56b6c2,
    0x61afef, 0xc678dd, 0xd19a66, 0xbe5046,
    0x528bff, 0x2bbac5, 0xa9dc76, 0xff6ac1,
    0xffd866, 0x78dce8, 0xab9df2, 0xff9e64,
};

pub fn forProject(name: []const u8) u24 {
    var hash: u64 = 5381;
    for (name) |c| hash = (hash * 33 + c) % 2147483647;
    return palette[hash % palette.len];
}

pub fn background(project: []const u8, pane_title: []const u8, codex_process: bool, codex_color: u24) u24 {
    if (!codex_process and !isCodex(pane_title)) return forProject(project);
    return if (needsInput(pane_title)) 0xff3b30 else codex_color;
}

pub fn isCodexExecutable(path: []const u8) bool {
    return executableNamed(path, "codex");
}

pub fn isNvimExecutable(path: []const u8) bool {
    return executableNamed(path, "nvim");
}

fn executableNamed(path: []const u8, expected: []const u8) bool {
    // Linux appends this suffix when an executable is upgraded while running.
    const executable = std.mem.cutSuffix(u8, path, " (deleted)") orelse path;
    const start = if (std.mem.lastIndexOfAny(u8, executable, "/\\")) |i| i + 1 else 0;
    const name = executable[start..];
    const stem = if (name.len == expected.len + 4 and std.ascii.endsWithIgnoreCase(name, ".exe")) name[0..expected.len] else name;
    return std.ascii.eqlIgnoreCase(stem, expected);
}

fn isCodex(title: []const u8) bool {
    var pos: usize = 0;
    while (pos + 5 <= title.len) : (pos += 1) {
        if (!std.ascii.eqlIgnoreCase(title[pos..][0..5], "codex")) continue;
        if (pos > 0 and std.ascii.isAlphanumeric(title[pos - 1])) continue;
        if (pos + 5 < title.len and std.ascii.isAlphanumeric(title[pos + 5])) continue;
        return true;
    }
    return false;
}

fn needsInput(title: []const u8) bool {
    if (title.len == 0 or title[0] != '[') return false;
    const end = std.mem.indexOfScalar(u8, title, ']') orelse return false;
    const marker = std.mem.trim(u8, title[1..end], " \t");
    return std.mem.eql(u8, marker, "!") or std.mem.eql(u8, marker, ".");
}

fn linear(c: u8) f64 {
    const v = @as(f64, @floatFromInt(c)) / 255;
    return if (v <= 0.03928) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

pub fn foreground(color: u24) u24 {
    const luminance = 0.2126 * linear(@truncate(color >> 16)) +
        0.7152 * linear(@truncate(color >> 8)) + 0.0722 * linear(@truncate(color));
    return if ((luminance + 0.05) / 0.05 > 1.05 / (luminance + 0.05)) 0x1e1e1e else 0xffffff;
}

pub fn hover(color: u24) u24 {
    var result: u24 = 0;
    inline for (.{ 0, 8, 16 }) |shift| {
        const c: u32 = @as(u8, @truncate(color >> shift));
        result |= @as(u24, @intCast(c + (255 - c) * 18 / 100)) << shift;
    }
    return result;
}

test "project colors preserve WezTerm hash results" {
    try std.testing.expectEqual(@as(u24, 0xffd866), forProject("ghostty"));
    try std.testing.expectEqual(palette[0], background("repo", "⠋ Codex", false, palette[0]));
    try std.testing.expectEqual(@as(u24, 0xff3b30), background("repo", "[ ! ] Codex", false, palette[0]));
    try std.testing.expectEqual(forProject("repo"), background("repo", "codexical", false, palette[0]));
    try std.testing.expectEqual(@as(u24, 0xffffff), foreground(0));
    try std.testing.expectEqual(@as(u24, 0x1e1e1e), foreground(0xffffff));
    try std.testing.expectEqual(@as(u24, 0xffffff), hover(0xffffff));
}

test "project colors recognize the Codex executable rather than parent directory names" {
    for ([_][]const u8{ "codex", "/usr/bin/codex", "/opt/Codex", "C:\\bin\\codex.exe", "/opt/codex (deleted)" }) |path| {
        try std.testing.expect(isCodexExecutable(path));
    }
    for ([_][]const u8{ "", "/home/codex/zsh", "/opt/codex/node", "codexical", "codex-helper" }) |path| {
        try std.testing.expect(!isCodexExecutable(path));
    }
}

test "project colors recognize the Neovim executable" {
    for ([_][]const u8{ "nvim", "/usr/bin/nvim", "/tmp/.mount_nvimAb12/usr/bin/nvim", "/usr/bin/nvim (deleted)" }) |path| {
        try std.testing.expect(isNvimExecutable(path));
    }
    for ([_][]const u8{ "", "vim", "/usr/bin/vim", "/home/nvim/zsh", "nvim-qt", "/usr/bin/codex" }) |path| {
        try std.testing.expect(!isNvimExecutable(path));
    }
}

test "project colors stay fixed through Codex spinner frames without its name" {
    for (palette) |color| {
        for ([_][]const u8{ "⠋ Working", "⠙ Working", "⠹ Working", "[|] Working", "[/] Working", "[-] Working", "[\\] Working" }) |title| {
            const bg = background(title, title, true, color);
            try std.testing.expectEqual(color, bg);
            try std.testing.expectEqual(foreground(color), foreground(bg));
            try std.testing.expectEqual(bg, background("stable repo", title, true, color));
        }
        try std.testing.expectEqual(@as(u24, 0xff3b30), background("repo", "[ ! ] Approval needed", true, color));
        try std.testing.expectEqual(@as(u24, 0xff3b30), background("repo", "[ . ] Ready", true, color));
        // Resuming work restores this tab's original color, without rerolling.
        try std.testing.expectEqual(color, background("repo", "Working", true, color));
    }
    // Leaving Codex restores the normal deterministic project palette.
    try std.testing.expectEqual(forProject("repo"), background("repo", "zsh", false, palette[0]));
}
