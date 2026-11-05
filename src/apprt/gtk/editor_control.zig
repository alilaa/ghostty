//! Small, pane-targeted Linux API for editor integration. D-Bus dispatches
//! requests on the GTK thread, where split focus and widget changes belong.
const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gtk = @import("gtk");
const Application = @import("class/application.zig").Application;
const SplitTree = @import("class/split_tree.zig").SplitTree;
const Surface = @import("class/surface.zig").Surface;
const Tab = @import("class/tab.zig").Tab;
const Window = @import("class/window.zig").Window;
const Overrides = @import("class/Overrides.zig");
const request = @import("control_request.zig");
const ext = @import("ext.zig");

pub const path = "/com/ghosntty/GhosnTTy/EditorControl";
pub const interface = "com.ghosntty.GhosnTTy.EditorControl1";
pub const key_table = "smart-splits";

const xml =
    \\<node><interface name="com.ghosntty.GhosnTTy.EditorControl1">
    \\  <method name="Execute">
    \\    <arg name="surface" type="t" direction="in"/>
    \\    <arg name="operation" type="s" direction="in"/>
    \\    <arg name="value" type="s" direction="in"/>
    \\    <arg name="amount" type="u" direction="in"/>
    \\    <arg name="performed" type="b" direction="out"/>
    \\  </method>
    \\  <method name="ListSurfaces">
    \\    <arg name="surfaces" type="a(tsssb)" direction="out"/>
    \\  </method>
    \\  <method name="FocusedSurface">
    \\    <arg name="surface" type="t" direction="out"/>
    \\  </method>
    \\  <method name="Split">
    \\    <arg name="surface" type="t" direction="in"/>
    \\    <arg name="direction" type="s" direction="in"/>
    \\    <arg name="cwd" type="s" direction="in"/>
    \\    <arg name="argv" type="as" direction="in"/>
    \\    <arg name="new_surface" type="t" direction="out"/>
    \\  </method>
    \\  <method name="Focus">
    \\    <arg name="surface" type="t" direction="in"/>
    \\    <arg name="focused" type="b" direction="out"/>
    \\  </method>
    \\  <signal name="FocusChanged">
    \\    <arg name="surface" type="t"/>
    \\  </signal>
    \\</interface></node>
;

pub fn register(app: *Application, connection: *gio.DBusConnection) !c_uint {
    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();
    const node = gio.DBusNodeInfo.newForXml(xml, &err) orelse return error.InvalidInterface;
    defer node.unref();
    const vtable: gio.DBusInterfaceVTable = .{
        .f_method_call = methodCall,
        .f_get_property = null,
        .f_set_property = null,
        .f_padding = undefined,
    };
    const id = connection.registerObject(path, node.lookupInterface(interface).?, &vtable, app, borrowedApplication, &err);
    if (id == 0) return error.RegistrationFailed;
    return id;
}

// Registration borrows the application, which unregisters before disposal.
fn borrowedApplication(_: ?*anyopaque) callconv(.c) void {}

fn methodCall(
    _: *gio.DBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: ?[*:0]const u8,
    method: [*:0]const u8,
    parameters: *glib.Variant,
    invocation: *gio.DBusMethodInvocation,
    data: ?*anyopaque,
) callconv(.c) void {
    const name = std.mem.span(method);
    const app: *Application = @ptrCast(@alignCast(data.?));
    if (std.mem.eql(u8, name, "ListSurfaces")) return listSurfaces(app, invocation);
    if (std.mem.eql(u8, name, "FocusedSurface")) {
        return replyUint64(invocation, focusedSurface(app));
    }
    if (std.mem.eql(u8, name, "Focus")) {
        var id: u64 = 0;
        parameters.get("(t)", &id);
        return replyBool(invocation, focus(app, id));
    }
    if (std.mem.eql(u8, name, "Split")) return splitMethod(app, parameters, invocation);
    if (!std.mem.eql(u8, name, "Execute")) {
        invocation.returnDbusError("org.freedesktop.DBus.Error.UnknownMethod", "Unknown editor-control method");
        return;
    }
    var id: u64 = 0;
    var operation: [*:0]const u8 = undefined;
    var value: [*:0]const u8 = undefined;
    var amount: u32 = 0;
    parameters.get("(t&s&su)", &id, &operation, &value, &amount);
    const performed = execute(app, id, std.mem.span(operation), std.mem.span(value), amount) catch false;
    replyBool(invocation, performed);
}

fn replyBool(invocation: *gio.DBusMethodInvocation, value: bool) void {
    const result = glib.Variant.newBoolean(@intFromBool(value));
    invocation.returnValue(glib.Variant.newTuple(@ptrCast(&[_]*glib.Variant{result}), 1));
}

fn replyUint64(invocation: *gio.DBusMethodInvocation, value: u64) void {
    const result = glib.Variant.newUint64(value);
    invocation.returnValue(glib.Variant.newTuple(@ptrCast(&[_]*glib.Variant{result}), 1));
}

/// `window:tab` from never-reused IDs; 0 marks a missing ancestor.
fn tabLabel(buf: []u8, surface: *Surface) [:0]const u8 {
    const window = ext.getAncestor(Window, surface.as(gtk.Widget));
    const tab = ext.getAncestor(Tab, surface.as(gtk.Widget));
    return std.fmt.bufPrintSentinel(buf, "{d}:{d}", .{
        if (window) |w| w.getControlId() else 0,
        if (tab) |t| t.getControlId() else 0,
    }, 0) catch unreachable;
}

fn listSurfaces(app: *Application, invocation: *gio.DBusMethodInvocation) void {
    const focused_id = focusedSurface(app);
    const type_ = glib.VariantType.new("(a(tsssb))");
    defer type_.free();
    var builder: glib.VariantBuilder = undefined;
    builder.init(type_);
    {
        const array_type = glib.VariantType.new("a(tsssb)");
        defer array_type.free();
        builder.open(array_type);
        defer builder.close();
        for (app.core().surfaces.items) |item| {
            const surface = item.surface;
            const core = surface.core() orelse continue;
            var buf: [48]u8 = undefined;
            const label = tabLabel(&buf, surface);
            const tab = ext.getAncestor(Tab, surface.as(gtk.Widget));
            const in_tab = if (tab) |t| t.getActiveSurface() == surface else false;
            builder.add(
                "(tsssb)",
                core.id,
                if (surface.getTitle()) |v| v.ptr else "",
                if (surface.getPwd()) |v| v.ptr else "",
                label.ptr,
                @as(c_int, @intFromBool(in_tab or core.id == focused_id)),
            );
        }
    }
    invocation.returnValue(builder.end());
}

/// The pane with keyboard focus, or zero when no window is active.
fn focusedSurface(app: *Application) u64 {
    for (app.core().surfaces.items) |item| {
        const surface = item.surface;
        if (!surface.getFocused()) continue;
        const window = ext.getAncestor(Window, surface.as(gtk.Widget)) orelse continue;
        if (window.as(gtk.Window).isActive() == 0) continue;
        const core = surface.core() orelse continue;
        return core.id;
    }
    return 0;
}

fn focus(app: *Application, id: u64) bool {
    if (id == 0) return false;
    const core = app.core().findSurfaceByID(id) orelse return false;
    const surface = core.rt_surface.surface;
    // Only a window handles the present request.
    if (ext.getAncestor(Window, surface.as(gtk.Widget)) == null) return false;
    // Presenting selects the tab, focuses the pane, and raises the window.
    surface.present();
    return true;
}

/// A new split can only report its ID after GTK realizes it, so the reply
/// is deferred until the core surface exists.
const PendingSplit = struct {
    invocation: *gio.DBusMethodInvocation,
    surface: *Surface,
    source: c_uint = 0,
    attempts: u8 = 0,

    const max_attempts = 150;
    const interval_ms = 20;

    fn poll(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *PendingSplit = @ptrCast(@alignCast(ud.?));
        if (self.surface.core()) |core| {
            replyUint64(self.invocation, core.id);
        } else {
            self.attempts += 1;
            if (self.attempts < max_attempts) return @intFromBool(glib.SOURCE_CONTINUE);
            self.invocation.returnDbusError("com.ghosntty.GhosnTTy.Error.Timeout", "New surface was not realized");
        }
        self.destroy();
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    fn destroy(self: *PendingSplit) void {
        for (pending_splits.items, 0..) |item, i| if (item == self) {
            _ = pending_splits.swapRemove(i);
            break;
        };
        self.surface.unref();
        Application.default().allocator().destroy(self);
    }
};

/// Splits awaiting a reply, so shutdown can answer and free them.
var pending_splits: std.ArrayList(*PendingSplit) = .empty;

/// Answer outstanding requests and stop timers before the app goes away.
pub fn shutdown() void {
    if (focus_check_source != 0) {
        _ = glib.Source.remove(focus_check_source);
        focus_check_source = 0;
    }
    while (pending_splits.items.len > 0) {
        const pending = pending_splits.items[pending_splits.items.len - 1];
        _ = glib.Source.remove(pending.source);
        pending.invocation.returnDbusError("com.ghosntty.GhosnTTy.Error.ShuttingDown", "Application is shutting down");
        pending.destroy();
    }
    pending_splits.deinit(Application.default().allocator());
    pending_splits = .empty;
}

fn splitMethod(
    app: *Application,
    parameters: *glib.Variant,
    invocation: *gio.DBusMethodInvocation,
) void {
    const invalid = "org.freedesktop.DBus.Error.InvalidArgs";
    const spawn_allowed = allowed: {
        const config = app.getConfig();
        defer config.unref();
        break :allowed config.get().@"gtk-editor-control-spawn";
    };
    if (!spawn_allowed) return invocation.returnDbusError(
        "org.freedesktop.DBus.Error.AccessDenied",
        "Split requires gtk-editor-control-spawn",
    );
    var id: u64 = 0;
    var dir_name: [*:0]const u8 = undefined;
    var cwd: [*:0]const u8 = undefined;
    var argv_variant: *glib.Variant = undefined;
    parameters.get("(t&s&s@as)", &id, &dir_name, &cwd, &argv_variant);
    defer argv_variant.unref();
    const dir = request.direction(std.mem.span(dir_name)) orelse
        return invocation.returnDbusError(invalid, "Invalid direction");
    const cwd_s = std.mem.span(cwd);
    if (!request.validPath(cwd_s)) return invocation.returnDbusError(invalid, "Invalid cwd");
    const core = app.core().findSurfaceByID(id) orelse
        return invocation.returnDbusError(invalid, "Unknown surface");
    const surface = core.rt_surface.surface;
    const tree = ext.getAncestor(SplitTree, surface.as(gtk.Widget)) orelse
        return invocation.returnDbusError(invalid, "Surface has no split tree");

    var arena = std.heap.ArenaAllocator.init(app.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    const argc = argv_variant.nChildren();
    if (argc > request.max_argv) return invocation.returnDbusError(invalid, "Too many arguments");
    const argv = alloc.alloc([:0]const u8, argc) catch
        return invocation.returnDbusError(invalid, "Out of memory");
    for (argv, 0..) |*arg, i| {
        const child = argv_variant.getChildValue(i);
        defer child.unref();
        const value = std.mem.span(child.getString(null));
        if (!request.validArg(value)) return invocation.returnDbusError(invalid, "Invalid argument");
        arg.* = alloc.dupeSentinel(u8, value, 0) catch
            return invocation.returnDbusError(invalid, "Out of memory");
    }

    var overrides: Overrides = .none;
    // The argv runs directly via exec, never through a shell.
    if (argv.len > 0) overrides.command = .{ .direct = argv };
    if (cwd_s.len > 0) overrides.working_directory = alloc.dupeSentinel(u8, cwd_s, 0) catch
        return invocation.returnDbusError(invalid, "Out of memory");

    // A surface in a background tab is unmapped, so a split added there would
    // never realize; bring the tab forward first.
    surface.present();
    tree.newSplit(switch (dir) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    }, surface, overrides) catch
        return invocation.returnDbusError(invalid, "Split failed");

    const created = tree.getLastFocusedSurface() orelse
        return invocation.returnDbusError(invalid, "Split failed");
    const pending = app.allocator().create(PendingSplit) catch
        return invocation.returnDbusError(invalid, "Out of memory");
    pending_splits.append(app.allocator(), pending) catch {
        app.allocator().destroy(pending);
        return invocation.returnDbusError(invalid, "Out of memory");
    };
    pending.* = .{ .invocation = invocation, .surface = created.ref() };
    pending.source = glib.timeoutAdd(PendingSplit.interval_ms, PendingSplit.poll, pending);
}

var focus_check_source: c_uint = 0;
var last_focused: u64 = 0;

/// Recompute the focused pane once focus settles and emit `FocusChanged`
/// only when it differs, including 0 when no Ghostty window is active.
/// The delay matches the window's debounce for transient deactivation.
pub fn scheduleFocusCheck(app: *Application) void {
    if (!app.editorControlEnabled() or focus_check_source != 0) return;
    focus_check_source = glib.timeoutAdd(50, focusCheck, null);
}

fn focusCheck(_: ?*anyopaque) callconv(.c) c_int {
    focus_check_source = 0;
    const app = Application.default();
    const id = focusedSurface(app);
    // A pane briefly has no focus while focus moves between panes, e.g. to a
    // new split that is not realized yet; only report 0 once no window is
    // active. The incoming pane schedules another check when it gains focus.
    if (id == 0) if (app.as(gtk.Application).getActiveWindow()) |window| {
        if (window.isActive() != 0) return @intFromBool(glib.SOURCE_REMOVE);
    };
    if (id != last_focused) {
        last_focused = id;
        emitFocusChanged(app, id);
    }
    return @intFromBool(glib.SOURCE_REMOVE);
}

fn emitFocusChanged(app: *Application, id: u64) void {
    if (!app.editorControlEnabled()) return;
    const connection = app.as(gio.Application).getDbusConnection() orelse return;
    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();
    const result = glib.Variant.newUint64(id);
    const params = glib.Variant.newTuple(@ptrCast(&[_]*glib.Variant{result}), 1);
    _ = connection.emitSignal(null, path, interface, "FocusChanged", params, &err);
}

fn execute(app: *Application, id: u64, operation: []const u8, value: []const u8, amount: u32) !bool {
    if (id == 0) return false;
    const core = app.core().findSurfaceByID(id) orelse return false;
    const surface = core.rt_surface.surface;
    if (std.mem.eql(u8, operation, "project")) {
        if (!request.validProject(value)) return false;
        const tab = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse return false;
        const title = try app.allocator().dupeSentinel(u8, value, 0);
        defer app.allocator().free(title);
        tab.setTitleOverride(if (value.len == 0) null else title);
        return true;
    }
    if (std.mem.eql(u8, operation, "editor")) {
        if (std.mem.eql(u8, value, "off")) return core.setEditorNavigation(false);
        if (!std.mem.eql(u8, value, "on") or !surface.getFocused()) return false;
        return core.setEditorNavigation(true);
    }
    // Never let a delayed editor request act on a newly focused pane.
    if (!surface.getFocused()) return false;
    const tree = ext.getAncestor(SplitTree, surface.as(gtk.Widget)) orelse return false;
    if (tree.getActiveSurface() != surface) return false;
    const dir = request.direction(value) orelse return false;
    if (std.mem.eql(u8, operation, "move")) {
        return core.performBindingAction(.{ .goto_split = switch (dir) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        } });
    }
    if (std.mem.eql(u8, operation, "resize")) {
        const scale = surface.getContentScale();
        const pixels = request.resizePixels(amount, switch (dir) {
            .left, .right => core.size.cell.width,
            .up, .down => core.size.cell.height,
        }, switch (dir) {
            .left, .right => scale.x,
            .up, .down => scale.y,
        }) orelse return false;
        return core.performBindingAction(.{ .resize_split = .{ switch (dir) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        }, pixels } });
    }
    return false;
}
