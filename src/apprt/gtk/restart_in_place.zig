//! GTK side of restart in place: capture windows, tabs, splits and every
//! surface's PTY and terminal state, re-exec the process, and rebuild it all
//! in the new process. See `restart.zig` for the serialized data model.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const adw = @import("adw");
const gobject = @import("gobject");
const gio = @import("gio");
const glib = @import("glib");
const gtk = @import("gtk");

const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const terminal = @import("../../terminal/main.zig");
const restart = @import("restart.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;
const Overrides = @import("class/Overrides.zig");

extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const log = std.log.scoped(.gtk_restart);

/// Whether this build and environment can restart in place.
pub fn supported() bool {
    if (comptime builtin.target.os.tag != .linux) return false;
    // Flatpak children are host processes we don't own a PTY for.
    return !internal_os.isFlatpak();
}

pub const ExecOptions = struct {
    /// Loop guard state to pass to the new process.
    counter: restart.Counter = .{},

    /// Restarting to recover from a GPU reset.
    gpu_reset: bool = false,

    /// Set if startup overrode LANG from the config: the value it had
    /// originally (null if unset), so the new process sees the same input.
    original_lang: ?struct { value: ?[:0]const u8 } = null,
};

/// Capture all state and re-exec. Only returns on failure, in which case
/// the current process keeps running unchanged.
pub fn restartInPlace(app: *Application, opts: ExecOptions) !void {
    if (!supported()) return error.Unsupported;

    var arena: std.heap.ArenaAllocator = .init(app.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    // Every captured surface's renderer mutex stays locked until exec so
    // the IO threads stop consuming PTY output that the snapshot would miss.
    var capture: Capture = .{ .alloc = alloc };
    defer capture.unlockAll();
    var snapshot = try capture.run(app);
    snapshot.gpu_reset = opts.gpu_reset;

    const dir = try restart.defaultDir(
        alloc,
        global.environ().getPosix("XDG_RUNTIME_DIR"),
        global.tmpDirPath(),
    );
    const path = try restart.writeFile(alloc, global.io(), dir, snapshot);
    errdefer std.Io.Dir.cwd().deleteFile(global.io(), path) catch {};

    log.info(
        "restarting in place windows={} surfaces={} path={s}",
        .{ snapshot.windows.len, snapshot.surfaces.len, path },
    );
    try execSelf(alloc, path, capture.fds.items, opts);
}

const Capture = struct {
    alloc: Allocator,
    surfaces: std.ArrayList(restart.Surface) = .empty,
    fds: std.ArrayList(posix.fd_t) = .empty,
    locked: std.ArrayList(*std.Io.Mutex) = .empty,

    fn unlockAll(self: *Capture) void {
        for (self.locked.items) |m| m.unlock(global.io());
        self.locked.clearRetainingCapacity();
    }

    fn run(self: *Capture, app: *Application) !restart.Snapshot {
        var windows: std.ArrayList(restart.Window) = .empty;
        var focused_window: ?u32 = null;

        // Ordered most recently focused first.
        var it: ?*glib.List = app.as(gtk.Application).getWindows();
        while (it) |node| : (it = node.f_next) {
            const data = node.f_data orelse continue;
            const gtk_win: *gtk.Window = @ptrCast(@alignCast(data));
            const win = gobject.ext.cast(Window, gtk_win) orelse continue;
            if (win.isQuickTerminal()) continue;
            const saved = try self.captureWindow(win) orelse continue;
            if (focused_window == null) focused_window = @intCast(windows.items.len);
            try windows.append(self.alloc, saved);
        }

        return .{
            .focused_window = focused_window,
            .windows = windows.items,
            .surfaces = self.surfaces.items,
        };
    }

    fn captureWindow(self: *Capture, win: *Window) !?restart.Window {
        const gtk_win = win.as(gtk.Window);
        const tab_view = win.getTabView();

        var tabs: std.ArrayList(restart.Tab) = .empty;
        var selected_tab: u32 = 0;
        const selected = tab_view.getSelectedPage();
        const n: usize = @intCast(tab_view.getNPages());
        for (0..n) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const saved = try self.captureTab(tab, page) orelse continue;
            if (selected == page) selected_tab = @intCast(tabs.items.len);
            try tabs.append(self.alloc, saved);
        }
        if (tabs.items.len == 0) return null;

        const maximized = gtk_win.isMaximized() != 0;
        const fullscreen = gtk_win.isFullscreen() != 0;
        var width: c_int = 0;
        var height: c_int = 0;
        if (maximized or fullscreen) {
            gtk_win.getDefaultSize(&width, &height);
        } else {
            width = gtk_win.as(gtk.Widget).getWidth();
            height = gtk_win.as(gtk.Widget).getHeight();
        }

        return .{
            .width = width,
            .height = height,
            .maximized = maximized,
            .fullscreen = fullscreen,
            .title_override = try self.dupe(win.getTitleOverride()),
            .selected_tab = selected_tab,
            .tabs = tabs.items,
        };
    }

    fn captureTab(self: *Capture, t: *Tab, page: *adw.TabPage) !?restart.Tab {
        const split_tree = t.getSplitTree();
        const tree = split_tree.getTree() orelse return null;
        const nodes = try self.alloc.alloc(restart.Node, tree.nodes.len);
        for (tree.nodes, nodes) |node, *out| out.* = switch (node) {
            .leaf => |surface| .{ .leaf = try self.captureSurface(surface) },
            .split => |s| .{ .split = .{
                .layout = switch (s.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = @floatCast(s.ratio),
                .left = @backingInt(s.left),
                .right = @backingInt(s.right),
            } },
        };

        return .{
            .title_override = try self.dupe(t.getTitleOverride()),
            .codex_color = t.peekCodexColor(),
            .pinned = page.getPinned() != 0,
            .zoomed = if (tree.zoomed) |h| @backingInt(h) else null,
            .focused = if (split_tree.getLastFocusedHandle()) |h| @backingInt(h) else null,
            .nodes = nodes,
        };
    }

    fn captureSurface(self: *Capture, s: *Surface) !u32 {
        try self.locked.ensureUnusedCapacity(self.alloc, 1);
        try self.fds.ensureUnusedCapacity(self.alloc, 1);

        var saved: restart.Surface = .{
            .title = try self.dupe(s.getTitle()),
            .title_override = try self.dupe(s.getTitleOverride()),
            .pwd = try self.dupe(s.getPwd()),
        };

        if (s.core()) |core| {
            saved.font_size = core.font_size.points;
            if (!s.getChildExited()) {
                core.renderer_state.mutex.lockUncancelable(global.io());
                self.locked.appendAssumeCapacity(core.renderer_state.mutex);
                if (core.io.backend.exec.adoptHandle()) |adopt| {
                    var w: std.Io.Writer.Allocating = .init(self.alloc);
                    try terminal.snapshot.encode(self.alloc, &w.writer, &core.io.terminal, .{
                        .continuation = .ground,
                    });
                    saved.snapshot = try restart.encodeBlob(self.alloc, w.written());
                    saved.fd = adopt.fd;
                    saved.pid = adopt.pid;
                    self.fds.appendAssumeCapacity(adopt.fd);
                }
            }
        } else if (s.getRestoreState()) |r| {
            // Never initialized since the previous restart (for example a
            // tab that was never shown), so pass its state on unchanged.
            if (r.adopt) |adopt| {
                saved.fd = adopt.fd;
                saved.pid = adopt.pid;
                self.fds.appendAssumeCapacity(adopt.fd);
                if (r.snapshot) |bytes| saved.snapshot = try restart.encodeBlob(self.alloc, bytes);
            }
        }

        try self.surfaces.append(self.alloc, saved);
        return @intCast(self.surfaces.items.len - 1);
    }

    fn dupe(self: *Capture, value: ?[]const u8) !?[]const u8 {
        return if (value) |v| try self.alloc.dupe(u8, v) else null;
    }
};

fn setCloexec(fd: posix.fd_t, on: bool) !void {
    const flags = posix.system.fcntl(fd, posix.F.GETFD);
    if (flags < 0) return error.InvalidFd;
    const new = if (on) flags | posix.FD_CLOEXEC else flags & ~@as(c_int, posix.FD_CLOEXEC);
    if (posix.system.fcntl(fd, posix.F.SETFD, new) < 0) return error.InvalidFd;
}

fn execSelf(
    alloc: Allocator,
    path: [:0]const u8,
    fds: []const posix.fd_t,
    opts: ExecOptions,
) !void {
    const args = global.args().vector;
    const argv = try alloc.allocSentinel(?[*:0]const u8, args.len, null);
    for (args, argv) |arg, *out| out.* = arg;

    var env: std.ArrayList(?[*:0]const u8) = .empty;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (std.mem.startsWith(u8, e, restart.env_restore ++ "=")) continue;
        if (std.mem.startsWith(u8, e, restart.env_count ++ "=")) continue;
        if (opts.original_lang != null and std.mem.startsWith(u8, e, "LANG=")) continue;
        try env.append(alloc, entry);
    }
    try env.append(alloc, try std.fmt.allocPrintSentinel(alloc, "{s}={s}", .{ restart.env_restore, path }, 0));
    try env.append(alloc, try std.fmt.allocPrintSentinel(alloc, "{s}={f}", .{ restart.env_count, opts.counter }, 0));
    if (opts.original_lang) |lang| if (lang.value) |v| {
        try env.append(alloc, try std.fmt.allocPrintSentinel(alloc, "LANG={s}", .{v}, 0));
    };
    const envp = try alloc.allocSentinel(?[*:0]const u8, env.items.len, null);
    @memcpy(envp, env.items);

    // The PTY masters are the only descriptors that must survive exec.
    var cleared: usize = 0;
    defer for (fds[0..cleared]) |fd| setCloexec(fd, true) catch {};
    for (fds) |fd| {
        try setCloexec(fd, false);
        cleared += 1;
    }

    // Ignored signals and the signal mask survive exec; caught ones are
    // reset by the kernel.
    const signals = [_]posix.SIG{ .PIPE, .CHLD, .HUP, .INT, .TERM, .QUIT };
    var reset: [signals.len]bool = @splat(false);
    var ignore: posix.Sigaction = undefined;
    defer for (signals, reset) |sig, was_reset| {
        if (was_reset) posix.sigaction(sig, &ignore, null);
    };
    for (signals, &reset) |sig, *was_reset| {
        var old: posix.Sigaction = undefined;
        posix.sigaction(sig, null, &old);
        if (old.handler.handler != posix.SIG.IGN) continue;
        ignore = old;
        const dfl: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(sig, &dfl, null);
        was_reset.* = true;
    }
    const empty = posix.sigemptyset();
    var old_mask: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.SETMASK, &empty, &old_mask);
    defer posix.sigprocmask(posix.SIG.SETMASK, &old_mask, null);

    const rc = std.c.execve("/proc/self/exe", argv.ptr, envp.ptr);
    log.err("restart in place: execve failed rc={} errno={}", .{ rc, posix.errno(rc) });
    return error.ExecFailed;
}

/// Read the snapshot the previous process passed in the environment, if
/// any, and remove the variables so new shells never inherit them. Call
/// once, early at startup. Also returns the loop guard counter.
pub fn load(alloc: Allocator) struct { snapshot: ?std.json.Parsed(restart.Snapshot), counter: restart.Counter } {
    const env = global.environ();
    if (env.getPosix(restart.env_restore) != null) restoreProcessName();
    const counter: restart.Counter = .parse(env.getPosix(restart.env_count));
    const path_env = env.getPosix(restart.env_restore);
    const path: ?[]u8 = if (path_env) |p| alloc.dupe(u8, p) catch null else null;
    defer if (path) |p| alloc.free(p);

    _ = unsetenv(restart.env_restore);
    _ = unsetenv(restart.env_count);
    global.syncEnviron();

    const p = path orelse return .{ .snapshot = null, .counter = counter };
    const parsed = restart.readFile(alloc, global.io(), p) catch |err| {
        log.err("failed to read restart state path={s} err={}", .{ p, err });
        return .{ .snapshot = null, .counter = counter };
    };

    // Inherited masters must not leak into children spawned before (or
    // instead of) their surface adopting them.
    for (parsed.value.surfaces) |s| {
        if (s.fd >= 0) setCloexec(s.fd, true) catch {};
    }
    return .{ .snapshot = parsed, .counter = counter };
}

/// Rebuild windows, tabs and splits from `snapshot` and show them.
/// Returns the number of windows created. Every inherited PTY master is
/// either handed to a surface or closed.
pub fn restore(app: *Application, snapshot: *const restart.Snapshot) usize {
    const gpa = app.allocator();
    const used = gpa.alloc(bool, snapshot.surfaces.len) catch {
        closeUnused(snapshot, &.{});
        return 0;
    };
    defer gpa.free(used);
    @memset(used, false);
    defer closeUnused(snapshot, used);

    var windows: std.ArrayList(*Window) = .empty;
    defer windows.deinit(gpa);
    for (snapshot.windows, 0..) |saved, i| {
        const win = restoreWindow(app, snapshot, saved, used) orelse continue;
        windows.append(gpa, win) catch {
            win.as(gtk.Window).present();
            continue;
        };
        if (snapshot.focused_window == @as(?u32, @intCast(i))) {
            // Present the focused window last so it ends up on top.
            std.mem.swap(*Window, &windows.items[0], &windows.items[windows.items.len - 1]);
        }
    }

    var idx = windows.items.len;
    while (idx > 0) {
        idx -= 1;
        windows.items[idx].as(gtk.Window).present();
    }
    if (snapshot.gpu_reset and windows.items.len > 0) {
        windows.items[0].notifyGpuResetRecovered();
    }
    log.info("restored windows={} surfaces={}", .{ windows.items.len, snapshot.surfaces.len });
    return windows.items.len;
}

fn closeUnused(snapshot: *const restart.Snapshot, used: []const bool) void {
    for (snapshot.surfaces, 0..) |s, i| {
        if (s.fd < 0) continue;
        if (i < used.len and used[i]) continue;
        log.warn("closing unrestored terminal fd={} pid={}", .{ s.fd, s.pid });
        _ = posix.system.close(s.fd);
    }
}

fn restoreWindow(
    app: *Application,
    snapshot: *const restart.Snapshot,
    saved: restart.Window,
    used: []bool,
) ?*Window {
    const win = Window.new(app, .none);
    _ = gobject.Object.bindProperty(
        app.as(gobject.Object),
        "config",
        win.as(gobject.Object),
        "config",
        .{},
    );

    const tab_view = win.getTabView();
    var selected: ?*adw.TabPage = null;
    for (saved.tabs, 0..) |saved_tab, i| {
        const tab = restoreTab(app.allocator(), snapshot, saved_tab, used) catch |err| {
            log.warn("failed to restore tab err={}", .{err});
            continue;
        };
        const page = win.appendRestoredTab(tab);
        if (saved_tab.title_override) |t| setTitleZ(Tab, tab, t);
        if (saved_tab.codex_color) |c| tab.setCodexColor(c);
        if (saved_tab.pinned) tab_view.setPagePinned(page, 1);
        if (i == saved.selected_tab) selected = page;
    }
    if (tab_view.getNPages() == 0) {
        win.as(gtk.Window).destroy();
        return null;
    }
    if (selected) |page| tab_view.setSelectedPage(page);

    const gtk_win = win.as(gtk.Window);
    if (saved.title_override) |t| win.setTitleOverride(t);
    if (saved.width > 0 and saved.height > 0) gtk_win.setDefaultSize(saved.width, saved.height);
    if (saved.maximized) gtk_win.maximize() else gtk_win.unmaximize();
    if (saved.fullscreen) gtk_win.fullscreen() else gtk_win.unfullscreen();
    return win;
}

fn restoreTab(
    gpa: Allocator,
    snapshot: *const restart.Snapshot,
    saved: restart.Tab,
    used: []bool,
) !*Tab {
    var created: std.ArrayList(*Surface) = .empty;
    defer {
        // The tree holds its own references.
        for (created.items) |s| s.unref();
        created.deinit(gpa);
    }

    const nodes = try gpa.alloc(Surface.Tree.Node, saved.nodes.len);
    defer gpa.free(nodes);
    for (saved.nodes, nodes) |node, *out| out.* = switch (node) {
        .leaf => |idx| leaf: {
            if (idx >= snapshot.surfaces.len or used[idx]) return error.InvalidTree;
            try created.ensureUnusedCapacity(gpa, 1);
            used[idx] = true;
            const s = newSurface(gpa, snapshot.surfaces[idx]);
            created.appendAssumeCapacity(s);
            break :leaf .{ .leaf = s };
        },
        .split => |s| .{ .split = .{
            .layout = switch (s.layout) {
                .horizontal => .horizontal,
                .vertical => .vertical,
            },
            .ratio = @floatCast(s.ratio),
            .left = @fromBackingInt(@intCast(s.left)),
            .right = @fromBackingInt(@intCast(s.right)),
        } },
    };

    const zoomed: ?Surface.Tree.Node.Handle = if (saved.zoomed) |z| @fromBackingInt(@intCast(z)) else null;
    var tree: Surface.Tree = try .fromNodes(gpa, nodes, zoomed);
    defer tree.deinit();
    if (tree.isEmpty()) return error.InvalidTree;

    const focused: ?*Surface = focused: {
        const h = saved.focused orelse break :focused null;
        if (h >= nodes.len) break :focused null;
        break :focused switch (nodes[h]) {
            .leaf => |s| s,
            .split => null,
        };
    };

    const tab = Tab.newEmpty(null);
    tab.getSplitTree().restoreTree(&tree, focused);
    return tab;
}

/// A new surface that adopts the saved PTY and terminal contents, or starts
/// a fresh shell in the saved directory if there is nothing to adopt. The
/// caller owns one strong reference.
fn newSurface(gpa: Allocator, saved: restart.Surface) *Surface {
    const pwd: ?[:0]u8 = if (saved.pwd) |p| gpa.dupeSentinel(u8, p, 0) catch null else null;
    defer if (pwd) |v| gpa.free(v);
    const title_override: ?[:0]u8 = if (saved.title_override) |t| gpa.dupeSentinel(u8, t, 0) catch null else null;
    defer if (title_override) |v| gpa.free(v);

    var overrides: Overrides = .none;
    overrides.working_directory = pwd;
    overrides.title = title_override;
    const s: *Surface = .new(overrides);
    _ = s.refSink();
    if (saved.title) |t| setTitleZ(Surface, s, t);
    if (pwd) |v| s.setPwd(v);
    if (saved.font_size) |points| s.setFontSizeRequest(points);
    if (saved.fd >= 0) {
        const bytes: ?[]u8 = if (saved.snapshot) |b| restart.decodeBlob(gpa, b) catch |err| bytes: {
            log.warn("invalid terminal snapshot err={}", .{err});
            break :bytes null;
        } else null;
        s.setRestoreState(.{ .fd = saved.fd, .pid = saved.pid }, bytes);
    }
    return s;
}

fn setTitleZ(comptime T: type, obj: *T, title: []const u8) void {
    var buf: [1024]u8 = undefined;
    const len = @min(title.len, buf.len - 1);
    @memcpy(buf[0..len], title[0..len]);
    buf[len] = 0;
    const z: [:0]const u8 = buf[0..len :0];
    switch (T) {
        Surface => obj.setTitle(z),
        Tab => obj.setTitleOverride(z),
        else => @compileError("unsupported"),
    }
}

/// Wait up to two seconds for no one to own the session bus name `name`.
/// Returns true if it's free (or there's no session bus to check).
pub fn waitForBusName(name: [:0]const u8) bool {
    var err: ?*glib.Error = null;
    const conn = gio.busGetSync(.session, null, &err) orelse {
        if (err) |e| e.free();
        return true;
    };
    defer conn.unref();
    const reply_type = glib.VariantType.new("(b)");
    defer reply_type.free();

    var attempt: usize = 0;
    while (attempt < 40) : (attempt += 1) {
        const reply = conn.callSync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            glib.Variant.newTuple(&.{glib.Variant.newString(name)}, 1),
            reply_type,
            .{},
            1000,
            null,
            &err,
        ) orelse {
            if (err) |e| e.free();
            return true;
        };
        defer reply.unref();
        var owned: c_int = 0;
        reply.get("(b)", &owned);
        if (owned == 0) return true;
        std.Io.sleep(global.io(), .fromMilliseconds(50), .awake) catch {};
    }
    return false;
}

/// Exec'ing `/proc/self/exe` names the process "exe", so set it back to the
/// name it had before the restart.
fn restoreProcessName() void {
    const args = global.args().vector;
    if (args.len == 0) return;
    const name = std.fs.path.basenamePosix(std.mem.span(args[0]));
    var buf: [16]u8 = @splat(0);
    const len = @min(name.len, buf.len - 1);
    @memcpy(buf[0..len], name[0..len]);
    _ = std.os.linux.prctl(@backingInt(std.os.linux.PR.SET_NAME), @intFromPtr(&buf), 0, 0, 0);
}
