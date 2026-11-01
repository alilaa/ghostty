//! Validation shared by the Linux editor-control interface and its tests.
const std = @import("std");

pub const Direction = enum { left, right, up, down };

pub fn direction(value: []const u8) ?Direction {
    return std.meta.stringToEnum(Direction, value);
}

pub fn validProject(value: []const u8) bool {
    if (value.len > 512 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// Ghostty's GTK split tree uses logical pixels; smart-splits uses cells.
pub fn resizePixels(cells: u32, cell_pixels: u32, scale: f32) ?u16 {
    if (cells == 0 or cells > 1000 or cell_pixels == 0 or
        !std.math.isFinite(scale) or scale <= 0) return null;
    const pixels = @ceil(@as(f64, @floatFromInt(cells)) *
        @as(f64, @floatFromInt(cell_pixels)) / scale);
    return @intFromFloat(@min(pixels, std.math.maxInt(u16)));
}

test "editor control validates direction and project identity" {
    const t = std.testing;
    try t.expectEqual(Direction.left, direction("left").?);
    try t.expectEqual(null, direction("next"));
    try t.expect(validProject("P.M.åäö"));
    try t.expect(validProject(""));
    try t.expect(!validProject("repo\x1b]2;injected"));
    try t.expect(!validProject("\xff"));
    const long: [513]u8 = @splat('a');
    try t.expect(!validProject(&long));
}

test "editor control resize converts cells at fractional DPI and clamps" {
    const t = std.testing;
    try t.expectEqual(@as(?u16, 24), resizePixels(3, 12, 1.5));
    try t.expectEqual(@as(?u16, 33), resizePixels(3, 11, 1));
    try t.expectEqual(@as(?u16, 65535), resizePixels(1000, 100, 1));
    try t.expectEqual(null, resizePixels(0, 12, 1));
    try t.expectEqual(null, resizePixels(1001, 12, 1));
    try t.expectEqual(null, resizePixels(3, 12, 0));
}
