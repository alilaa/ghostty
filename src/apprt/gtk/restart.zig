//! Restart in place: the state carried across `execve` so the new process
//! can rebuild windows, tabs and splits around the still-running children.
//!
//! The old process writes a JSON `Snapshot` to a private file and passes its
//! path in `env_restore`. Each surface carries its PTY master fd (inherited
//! across exec), child pid and a base64 binary terminal snapshot
//! (`terminal.snapshot`).
const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.gtk_restart);

pub const version: u32 = 1;

/// Path of the snapshot file for the new process. Never inherited by shells.
pub const env_restore = "GHOSNTTY_RESTORE";

/// `<count>:<first unix seconds>` of recent automatic restarts (loop guard).
pub const env_count = "GHOSNTTY_RESTART_COUNT";

/// More than this many automatic restarts within `guard_window_s` seconds
/// disables automatic restarts.
pub const guard_max = 3;
pub const guard_window_s = 60;

pub const Snapshot = struct {
    version: u32 = version,
    focused_window: ?u32 = null,
    /// The restart was triggered automatically to recover from a GPU reset.
    gpu_reset: bool = false,
    windows: []const Window = &.{},
    surfaces: []const Surface = &.{},
};

pub const Window = struct {
    width: i32 = 0,
    height: i32 = 0,
    maximized: bool = false,
    fullscreen: bool = false,
    title_override: ?[]const u8 = null,
    selected_tab: u32 = 0,
    tabs: []const Tab = &.{},
};

pub const Tab = struct {
    title_override: ?[]const u8 = null,
    codex_color: ?u24 = null,
    pinned: bool = false,
    /// Node handle of the zoomed split, if any.
    zoomed: ?u16 = null,
    /// Node handle of the focused leaf, if any.
    focused: ?u16 = null,
    /// Split tree nodes, index 0 is the root (`datastruct/split_tree.zig`).
    nodes: []const Node = &.{},
};

pub const Node = union(enum) {
    /// Index into `Snapshot.surfaces`.
    leaf: u32,
    split: Split,

    pub const Split = struct {
        layout: Layout,
        ratio: f32,
        left: u16,
        right: u16,
    };

    pub const Layout = enum { horizontal, vertical };
};

pub const Surface = struct {
    /// PTY master, inherited across exec. -1 if the surface has no
    /// adoptable child and should start a fresh shell instead.
    fd: i32 = -1,
    pid: i32 = 0,
    title: ?[]const u8 = null,
    title_override: ?[]const u8 = null,
    pwd: ?[]const u8 = null,
    font_size: ?f32 = null,
    /// Base64 (standard alphabet) `terminal.snapshot` bytes.
    snapshot: ?[]const u8 = null,
};

/// Encode raw terminal snapshot bytes for `Surface.snapshot`.
pub fn encodeBlob(alloc: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

/// Decode `Surface.snapshot`. Caller owns the result.
pub fn decodeBlob(alloc: Allocator, text: []const u8) (Allocator.Error || error{InvalidBlob})![]u8 {
    const dec = std.base64.standard.Decoder;
    const len = dec.calcSizeForSlice(text) catch return error.InvalidBlob;
    const out = try alloc.alloc(u8, len);
    errdefer alloc.free(out);
    dec.decode(out, text) catch return error.InvalidBlob;
    return out;
}

pub fn stringify(alloc: Allocator, snapshot: Snapshot) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, snapshot, .{ .emit_null_optional_fields = false });
}

pub fn parse(alloc: Allocator, bytes: []const u8) !std.json.Parsed(Snapshot) {
    const parsed = try std.json.parseFromSlice(Snapshot, alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    if (parsed.value.version != version) return error.UnsupportedVersion;
    return parsed;
}

/// Write `snapshot` to a new 0600 file in `dir_path` (created 0700 if
/// needed). Returns the file path; caller owns it.
pub fn writeFile(
    alloc: Allocator,
    io: std.Io,
    dir_path: []const u8,
    snapshot: Snapshot,
) ![:0]u8 {
    const json = try stringify(alloc, snapshot);
    defer alloc.free(json);

    _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir_path, .fromMode(0o700));

    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    const path = try std.fmt.allocPrintSentinel(
        alloc,
        "{s}/restore-{d}-{d}.json",
        .{ dir_path, std.c.getpid(), ts },
        0,
    );
    errdefer alloc.free(path);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    defer file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try file.writeStreamingAll(io, json);
    return path;
}

/// Directory for snapshot files: `$XDG_RUNTIME_DIR/ghosntty`, falling back
/// to `<tmp>/ghosntty-<uid>`. Caller owns the result.
pub fn defaultDir(alloc: Allocator, runtime_dir: ?[]const u8, tmp_dir: []const u8) Allocator.Error![]u8 {
    if (runtime_dir) |dir| if (dir.len > 0) return std.fs.path.join(alloc, &.{ dir, "ghosntty" });
    return std.fmt.allocPrint(alloc, "{s}/ghosntty-{d}", .{ tmp_dir, std.c.getuid() });
}

/// Read and delete a snapshot file written by `writeFile`.
pub fn readFile(alloc: Allocator, io: std.Io, path: []const u8) !std.json.Parsed(Snapshot) {
    defer std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
        log.warn("failed to delete restore file path={s} err={}", .{ path, err });
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 30));
    defer alloc.free(bytes);
    return parse(alloc, bytes);
}

/// Loop guard state for automatic restarts.
pub const Counter = struct {
    count: u32 = 0,
    first: i64 = 0,

    pub fn parse(value: ?[]const u8) Counter {
        const v = value orelse return .{};
        var it = std.mem.splitScalar(u8, v, ':');
        const count = std.fmt.parseInt(u32, it.next() orelse return .{}, 10) catch return .{};
        const first = std.fmt.parseInt(i64, it.next() orelse return .{}, 10) catch return .{};
        return .{ .count = count, .first = first };
    }

    /// The counter after one more automatic restart at `now`, or null if
    /// the guard forbids it.
    pub fn next(self: Counter, now: i64) ?Counter {
        if (self.count == 0 or now - self.first > guard_window_s or now < self.first)
            return .{ .count = 1, .first = now };
        if (self.count >= guard_max) return null;
        return .{ .count = self.count + 1, .first = self.first };
    }

    pub fn format(self: Counter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}:{d}", .{ self.count, self.first });
    }
};

test "restart snapshot JSON round-trip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const blob = try encodeBlob(alloc, "\x00\x01binary\xff");
    defer alloc.free(blob);

    const snapshot: Snapshot = .{
        .focused_window = 0,
        .gpu_reset = true,
        .windows = &.{.{
            .width = 800,
            .height = 600,
            .maximized = true,
            .title_override = "win",
            .selected_tab = 1,
            .tabs = &.{
                .{ .nodes = &.{.{ .leaf = 0 }} },
                .{
                    .title_override = "proj",
                    .codex_color = 0x123456,
                    .pinned = true,
                    .zoomed = 2,
                    .focused = 1,
                    .nodes = &.{
                        .{ .split = .{ .layout = .vertical, .ratio = 0.25, .left = 1, .right = 2 } },
                        .{ .leaf = 1 },
                        .{ .leaf = 2 },
                    },
                },
            },
        }},
        .surfaces = &.{
            .{ .fd = 10, .pid = 100, .title = "zsh", .snapshot = blob },
            .{ .fd = 11, .pid = 101, .pwd = "/tmp", .font_size = 13.5 },
            .{ .title_override = "fresh" },
        },
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);
    const sub = try std.fs.path.join(alloc, &.{ dir, "sub" });
    defer alloc.free(sub);

    const path = try writeFile(alloc, testing.io, sub, snapshot);
    defer alloc.free(path);
    const stat = try std.Io.Dir.cwd().statFile(testing.io, path, .{});
    try testing.expectEqual(0o600, stat.permissions.toMode() & 0o777);

    const parsed = try readFile(alloc, testing.io, path);
    defer parsed.deinit();
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, path, .{}));

    const json_a = try stringify(alloc, snapshot);
    defer alloc.free(json_a);
    const json_b = try stringify(alloc, parsed.value);
    defer alloc.free(json_b);
    try testing.expectEqualStrings(json_a, json_b);

    const decoded = try decodeBlob(alloc, parsed.value.surfaces[0].snapshot.?);
    defer alloc.free(decoded);
    try testing.expectEqualStrings("\x00\x01binary\xff", decoded);
    try testing.expectError(error.InvalidBlob, decodeBlob(alloc, "!!"));

    try testing.expectError(error.UnsupportedVersion, parse(alloc, "{\"version\":99}"));
}

test "restart loop guard" {
    const testing = std.testing;
    try testing.expectEqual(Counter{}, Counter.parse(null));
    try testing.expectEqual(Counter{}, Counter.parse("x:1"));
    try testing.expectEqual(Counter{ .count = 2, .first = 50 }, Counter.parse("2:50"));

    var c: Counter = .{};
    c = c.next(100).?;
    try testing.expectEqual(Counter{ .count = 1, .first = 100 }, c);
    c = c.next(110).?;
    c = c.next(120).?;
    try testing.expectEqual(Counter{ .count = 3, .first = 100 }, c);
    try testing.expectEqual(null, c.next(130));
    // The window expires.
    try testing.expectEqual(Counter{ .count = 1, .first = 200 }, c.next(200).?);

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("3:100", try std.fmt.bufPrint(&buf, "{f}", .{c}));
}
