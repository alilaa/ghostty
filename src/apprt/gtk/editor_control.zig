//! Small, pane-targeted Linux API for editor integration. D-Bus dispatches
//! requests on the GTK thread, where split focus and widget changes belong.
const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gtk = @import("gtk");
const Application = @import("class/application.zig").Application;
const SplitTree = @import("class/split_tree.zig").SplitTree;
const Tab = @import("class/tab.zig").Tab;
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
    if (!std.mem.eql(u8, std.mem.span(method), "Execute")) {
        invocation.returnDbusError("org.freedesktop.DBus.Error.UnknownMethod", "Unknown editor-control method");
        return;
    }
    const app: *Application = @ptrCast(@alignCast(data.?));
    var id: u64 = 0;
    var operation: [*:0]const u8 = undefined;
    var value: [*:0]const u8 = undefined;
    var amount: u32 = 0;
    parameters.get("(t&s&su)", &id, &operation, &value, &amount);
    const performed = execute(app, id, std.mem.span(operation), std.mem.span(value), amount) catch false;
    const result = glib.Variant.newBoolean(@intFromBool(performed));
    invocation.returnValue(glib.Variant.newTuple(@ptrCast(&[_]*glib.Variant{result}), 1));
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
