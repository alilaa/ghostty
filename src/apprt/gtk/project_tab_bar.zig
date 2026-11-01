//! Optional project strip backed by the existing AdwTabView. Uses only public
//! GTK widgets, leaving tab lifetime, keyboard shortcuts and splits upstream.
const Self = @This();
const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");
const colors = @import("project_colors.zig");
const ext = @import("ext.zig");
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;

view: *adw.TabView,
scroll: *gtk.ScrolledWindow,
box: *gtk.Box,
fingerprint: ?u64 = null,

pub fn init(view: *adw.TabView) Self {
    const box = gtk.Box.new(.horizontal, 0);
    const scroll = gtk.ScrolledWindow.new();
    _ = scroll.as(gobject.Object).refSink();
    scroll.setPolicy(.automatic, .never);
    scroll.setChild(box.as(gtk.Widget));
    scroll.as(gtk.Widget).setVisible(0);
    return .{ .view = view, .scroll = scroll, .box = box };
}

pub fn deinit(self: *Self) void {
    self.scroll.unref();
}

pub fn widget(self: *Self) *gtk.Widget {
    return self.scroll.as(gtk.Widget);
}

pub fn refresh(self: *Self) void {
    // Hash structure and colors, not animated titles. Update labels in place
    // so a spinner never recreates styled buttons or restarts hover effects.
    var hash = std.hash.Wyhash.init(0);
    const selected = self.view.getSelectedPage();
    var n: c_int = 0;
    while (n < self.view.getNPages()) : (n += 1) {
        const page = self.view.getNthPage(n);
        const id = @intFromPtr(page);
        const active = page == selected;
        hash.update(std.mem.asBytes(&id));
        hash.update(std.mem.asBytes(&active));
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
        // Widen before hashing so the padding bits of u24 are not included.
        const bg: u32 = background(page, tab);
        hash.update(std.mem.asBytes(&bg));
    }
    const fingerprint = hash.final();
    if (self.fingerprint == fingerprint) {
        var group = self.box.as(gtk.Widget).getFirstChild();
        var i: c_int = 0;
        while (i < self.view.getNPages()) : (i += 1) {
            const current = group orelse break;
            const child = current.getFirstChild() orelse break;
            const button = gobject.ext.cast(gtk.Button, child) orelse break;
            const page = self.view.getNthPage(i);
            updateTitle(button, page, page == selected);
            group = current.getNextSibling();
        }
        return;
    }
    self.fingerprint = fingerprint;
    // This traverses our own box, never libadwaita's private tab widgets.
    while (self.box.as(gtk.Widget).getFirstChild()) |child| self.box.remove(child);
    var i: c_int = 0;
    while (i < self.view.getNPages()) : (i += 1) {
        const page = self.view.getNthPage(i);
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
        const bg = background(page, tab);
        const fg = colors.foreground(bg);
        const active = page == selected;
        const button = gtk.Button.new();
        button.as(gtk.Widget).setFocusOnClick(0);
        button.as(gtk.Widget).addCssClass("project-tab");
        // Attach providers to our widgets, avoiding a global stylesheet that
        // would outlive the window or style unrelated application widgets.
        const css = gtk.CssProvider.new();
        defer css.unref();
        var css_buf: [1024]u8 = undefined;
        const style = std.mem.printSentinel(
            &css_buf,
            "{s}button.project-tab {{ background-color: #{x:0>6}; color: #{x:0>6}; font-weight: {s}; }} " ++
                "button.project-tab:hover {{ background-color: #{x:0>6}; }}",
            .{ compact_css, bg, fg, if (active) @as([]const u8, "bold") else "normal", colors.hover(bg) },
            0,
        ) catch continue;
        css.loadFromString(style);
        button.as(gtk.Widget).getStyleContext().addProvider(css.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        const label = gtk.Label.new(null);
        label.setEllipsize(.end);
        label.setMaxWidthChars(32);
        button.setChild(label.as(gtk.Widget));
        updateTitle(button, page, active);
        _ = gtk.Button.signals.clicked.connect(button, *adw.TabPage, selectPage, page, .{});
        const group = gtk.Box.new(.horizontal, 0);
        group.append(button.as(gtk.Widget));
        const close = gtk.Button.newWithLabel("×");
        close.as(gtk.Widget).addCssClass("project-tab");
        close.as(gtk.Widget).setFocusOnClick(0);
        close.as(gtk.Widget).setTooltipText("Close tab");
        close.as(gtk.Widget).getStyleContext().addProvider(css.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        _ = gtk.Button.signals.clicked.connect(close, *adw.TabPage, closePage, page, .{});
        group.append(close.as(gtk.Widget));
        self.box.append(group.as(gtk.Widget));
    }
}

// Both labels and close controls must override the theme's button minimums.
const compact_css =
    "button.project-tab { " ++
    "background-image: none; min-height: 0; min-width: 0; " ++
    "border: none; border-radius: 0; box-shadow: none; " ++
    "margin: 0; padding: 1px 6px; } ";

fn updateTitle(button: *gtk.Button, page: *adw.TabPage, active: bool) void {
    const label = gobject.ext.cast(gtk.Label, button.getChild() orelse return) orelse return;
    var label_buf: [4096]u8 = undefined;
    const text = std.mem.printSentinel(&label_buf, "{s}{s}", .{
        if (active) @as([]const u8, "● ") else "  ",
        std.mem.span(page.getTitle()),
    }, 0) catch "";
    if (std.mem.eql(u8, std.mem.span(label.getText()), text)) return;
    label.setText(text);
    button.as(gtk.Widget).setTooltipText(page.getTitle());
}

fn background(page: *adw.TabPage, tab: *Tab) u24 {
    const surface = tab.getActiveSurface();
    const pane_title: []const u8 = if (surface) |s| s.getTitle() orelse "" else "";
    const codex_process = if (surface) |s| s.isForegroundCodex() else false;
    const identity: []const u8 = tab.getTitleOverride() orelse std.mem.span(page.getTitle());
    return colors.background(identity, pane_title, codex_process);
}

fn selectPage(button: *gtk.Button, page: *adw.TabPage) callconv(.c) void {
    _ = button.ref();
    defer button.unref();
    const window = ext.getAncestor(Window, button.as(gtk.Widget)) orelse return;
    _ = page.ref();
    defer page.unref();
    window.getTabView().setSelectedPage(page);
    if (gobject.ext.cast(Tab, page.getChild())) |tab| {
        if (tab.getActiveSurface()) |surface| surface.grabFocus();
    }
}

fn closePage(button: *gtk.Button, page: *adw.TabPage) callconv(.c) void {
    _ = button.ref();
    defer button.unref();
    const window = ext.getAncestor(Window, button.as(gtk.Widget)) orelse return;
    window.getTabView().closePage(page);
}
