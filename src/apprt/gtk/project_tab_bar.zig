//! Optional project strip backed by the existing AdwTabView. Uses only public
//! GTK widgets, leaving tab lifetime, keyboard shortcuts and splits upstream.
const Self = @This();
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const terminal = @import("../../terminal/main.zig");
const colors = @import("project_colors.zig");
const ext = @import("ext.zig");
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;

const log = std.log.scoped(.gtk_project_tabs);

view: *adw.TabView,
scroll: *gtk.ScrolledWindow,
box: *gtk.Box,
fingerprint: ?u64 = null,
/// Last selected page, compared by identity only and never dereferenced.
selected: ?*adw.TabPage = null,
/// Page whose tab is flashing after a switch, compared by identity only.
flash_page: ?*adw.TabPage = null,
flash_source: ?c_uint = null,
poll_source: ?c_uint = null,

/// The whole strip is exactly this tall; the font is sized to fit it.
const bar_height = 22;
const flash_ms = 3000;
/// Foreground jobs (e.g. Neovim and its working directory) change without
/// any title or property notification, so poll while the strip is shown.
const poll_ms = 1000;

pub fn init(view: *adw.TabView) Self {
    const box = gtk.Box.new(.horizontal, 0);
    const scroll = gtk.ScrolledWindow.new();
    _ = scroll.as(gobject.Object).refSink();
    scroll.setPolicy(.automatic, .never);
    scroll.setChild(box.as(gtk.Widget));
    scroll.as(gtk.Widget).setSizeRequest(-1, bar_height);
    scroll.as(gtk.Widget).setVisible(0);
    return .{ .view = view, .scroll = scroll, .box = box };
}

pub fn deinit(self: *Self) void {
    if (self.flash_source) |v| _ = glib.Source.remove(v);
    if (self.poll_source) |v| _ = glib.Source.remove(v);
    self.flash_source = null;
    self.poll_source = null;
    self.scroll.unref();
}

pub fn widget(self: *Self) *gtk.Widget {
    return self.scroll.as(gtk.Widget);
}

pub fn refresh(self: *Self) void {
    if (self.poll_source == null) self.poll_source = glib.timeoutAdd(poll_ms, poll, self);
    const selected = self.view.getSelectedPage();
    if (selected != self.selected) {
        // The first selection is the window opening, not a switch.
        if (self.selected != null) if (selected) |page| self.startFlash(page);
        self.selected = selected;
    }

    // Hash structure and colors, not animated titles. Update labels in place
    // so a spinner never recreates styled buttons or restarts hover effects.
    var hash = std.hash.Wyhash.init(0);
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
        const flashing = active and page == self.flash_page;
        const button = gtk.Button.new();
        button.as(gtk.Widget).setFocusOnClick(0);
        styleTab(button.as(gtk.Widget), active, flashing);
        // Attach providers to our widgets, avoiding a global stylesheet that
        // would outlive the window or style unrelated application widgets.
        const css = gtk.CssProvider.new();
        defer css.unref();
        var css_buf: [4096]u8 = undefined;
        const style = std.mem.printSentinel(
            &css_buf,
            "{s}button.project-tab {{ background-color: #{x:0>6}; color: #{x:0>6}; }} " ++
                "button.project-tab:hover {{ background-color: #{x:0>6}; }} " ++
                // A bar in the contrasting text color marks the current tab.
                "button.project-tab.active {{ box-shadow: inset 0 3px #{x:0>6}; }} " ++
                // Switching inverts the new tab and pulses a ring around it.
                "button.project-tab.flash {{ background-color: #{x:0>6}; color: #{x:0>6}; " ++
                "animation: project-tab-pulse 400ms ease-in-out infinite alternate; }}",
            .{ compact_css, bg, fg, colors.hover(bg), fg, fg, bg },
            0,
        ) catch continue;
        css.loadFromString(style);
        button.as(gtk.Widget).getStyleContext().addProvider(css.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        // Status marker, optional Neovim logo, then the title.
        const content = gtk.Box.new(.horizontal, 0);
        const marker = gtk.Label.new(null);
        content.append(marker.as(gtk.Widget));
        const logo = gtk.Image.new();
        logo.setPixelSize(bar_height - 8);
        logo.as(gtk.Widget).setVisible(0);
        content.append(logo.as(gtk.Widget));
        const label = gtk.Label.new(null);
        label.setEllipsize(.end);
        label.setMaxWidthChars(32);
        content.append(label.as(gtk.Widget));
        button.setChild(content.as(gtk.Widget));
        updateTitle(button, page, active);
        _ = gtk.Button.signals.clicked.connect(button, *adw.TabPage, selectPage, page, .{});
        const group = gtk.Box.new(.horizontal, 0);
        group.append(button.as(gtk.Widget));
        const close = gtk.Button.newWithLabel("×");
        styleTab(close.as(gtk.Widget), active, flashing);
        close.as(gtk.Widget).setFocusOnClick(0);
        close.as(gtk.Widget).setTooltipText("Close tab");
        close.as(gtk.Widget).getStyleContext().addProvider(css.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        _ = gtk.Button.signals.clicked.connect(close, *adw.TabPage, closePage, page, .{});
        group.append(close.as(gtk.Widget));
        self.box.append(group.as(gtk.Widget));
    }
}

fn styleTab(button: *gtk.Widget, active: bool, flashing: bool) void {
    button.addCssClass("project-tab");
    if (active) button.addCssClass("active");
    if (flashing) button.addCssClass("flash");
}

fn startFlash(self: *Self, page: *adw.TabPage) void {
    if (self.flash_source) |v| _ = glib.Source.remove(v);
    self.flash_page = page;
    self.flash_source = glib.timeoutAdd(flash_ms, endFlash, self);
}

fn endFlash(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
    self.flash_source = null;
    self.flash_page = null;
    // Removing the class lets the CSS transition fade back to normal colors.
    var group = self.box.as(gtk.Widget).getFirstChild();
    while (group) |current| : (group = current.getNextSibling()) {
        var child = current.getFirstChild();
        while (child) |button| : (child = button.getNextSibling()) button.removeCssClass("flash");
    }
    return 0;
}

fn poll(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
    if (self.widget().getMapped() != 0) self.refresh();
    return 1;
}

// Both labels and close controls must override the theme's button minimums.
// Inactive tabs are dimmed so the current one stands out at a glance.
const compact_css = std.fmt.comptimePrint(
    "@keyframes project-tab-pulse {{ " ++
        "from {{ box-shadow: inset 0 3px currentColor, inset 0 0 0 1px currentColor; }} " ++
        "to {{ box-shadow: inset 0 3px currentColor, inset 0 0 0 3px currentColor; }} }} " ++
        "button.project-tab {{ " ++
        "background-image: none; min-height: {d}px; min-width: 0; " ++
        "border: none; border-radius: 0; box-shadow: none; " ++
        "margin: 0; padding: 0 8px; font-size: 16px; opacity: 0.6; " ++
        "transition: background-color 500ms ease-out, color 500ms ease-out, opacity 200ms ease-out; }} " ++
        "button.project-tab:hover, button.project-tab.active {{ opacity: 1; }} " ++
        "button.project-tab.active {{ font-weight: bold; }} " ++
        "button.project-tab label {{ min-height: 0; }} ",
    .{bar_height},
);

fn updateTitle(button: *gtk.Button, page: *adw.TabPage, active: bool) void {
    const content = button.getChild() orelse return;
    const marker = gobject.ext.cast(gtk.Label, content.getFirstChild() orelse return) orelse return;
    const logo_widget = marker.as(gtk.Widget).getNextSibling() orelse return;
    const logo = gobject.ext.cast(gtk.Image, logo_widget) orelse return;
    const label = gobject.ext.cast(gtk.Label, logo_widget.getNextSibling() orelse return) orelse return;
    const tab = gobject.ext.cast(Tab, page.getChild());

    var progress_buf: [16]u8 = undefined;
    const progress: []const u8 = if (tab) |t| progressText(&progress_buf, progressReport(t)) else "";
    var marker_buf: [64]u8 = undefined;
    const marker_text = std.mem.printSentinel(&marker_buf, "{s}{s}", .{
        if (active) @as([]const u8, "● ") else "  ",
        progress,
    }, 0) catch "";
    setLabel(marker, marker_text);

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const nvim_cwd: ?[]const u8 = if (tab) |t| if (t.getActiveSurface()) |s| s.foregroundNvimCwd(&cwd_buf) else null else null;
    const texture = if (nvim_cwd != null) nvimLogo() else null;
    if (texture) |t| {
        if (logo.getPaintable() == null) logo.setFromPaintable(t.as(gdk.Paintable));
    }
    logo.as(gtk.Widget).setVisible(@intFromBool(texture != null));

    var label_buf: [4096]u8 = undefined;
    var tooltip_buf: [4096]u8 = undefined;
    if (nvim_cwd) |cwd| {
        const home = std.mem.span(glib.getHomeDir());
        const rest = std.mem.cutPrefix(u8, cwd, home);
        const in_home = home.len > 1 and rest != null and (rest.?.len == 0 or rest.?[0] == '/');
        // Without the logo, still say what this tab is running.
        const text = std.mem.printSentinel(&label_buf, "{s} · {s}{s}", .{
            if (texture != null) @as([]const u8, "") else "nvim",
            if (in_home) @as([]const u8, "~") else "",
            if (in_home) rest.? else cwd,
        }, 0) catch "";
        // Keep the deepest directories visible in long paths.
        label.setEllipsize(.start);
        setLabel(label, text);
        const tooltip = std.mem.printSentinel(&tooltip_buf, "Neovim — {s}", .{cwd}, 0) catch "";
        button.as(gtk.Widget).setTooltipText(tooltip);
    } else {
        label.setEllipsize(.end);
        setLabel(label, page.getTitle());
        button.as(gtk.Widget).setTooltipText(page.getTitle());
    }
}

fn setLabel(label: *gtk.Label, text: [*:0]const u8) void {
    if (std.mem.orderZ(u8, label.getText(), text) == .eq) return;
    label.setText(text);
}

/// The Neovim logo, decoded once and shared by every tab in the process.
fn nvimLogo() ?*gdk.Texture {
    const State = struct {
        var texture: ?*gdk.Texture = null;
        var loaded = false;
    };
    if (State.loaded) return State.texture;
    State.loaded = true;
    const svg = @embedFile("nvim-logo.svg");
    const bytes = glib.Bytes.new(svg.ptr, svg.len);
    defer bytes.unref();
    var gerr: ?*glib.Error = null;
    State.texture = gdk.Texture.newFromBytes(bytes, &gerr);
    if (gerr) |err| {
        defer err.free();
        log.warn("failed to load the Neovim tab logo err={s}", .{err.f_message orelse "(no message)"});
    }
    return State.texture;
}

fn progressText(buf: []u8, report: ?terminal.osc.Command.ProgressReport) []const u8 {
    const r = report orelse return "";
    return switch (r.state) {
        .remove => "",
        .indeterminate => "🤖 ",
        .@"error" => if (r.progress) |p| std.fmt.bufPrint(buf, "✖ {d}% ", .{p}) catch "✖ " else "✖ ",
        .pause => "❓ ",
        .set => if (r.progress == 100) "✅ " else if (r.progress) |p| std.fmt.bufPrint(buf, "◔ {d}% ", .{p}) catch "◔ " else "⟳ ",
    };
}

fn progressReport(tab: *Tab) ?terminal.osc.Command.ProgressReport {
    const surface = tab.getActiveSurface() orelse return null;
    return surface.getProgressReport();
}

/// Error and pause both mean the agent is blocked on the user.
fn needsAttention(tab: *Tab) bool {
    const report = progressReport(tab) orelse return false;
    return report.state == .@"error" or report.state == .pause;
}

fn background(page: *adw.TabPage, tab: *Tab) u24 {
    if (needsAttention(tab)) return 0xff3b30;
    const surface = tab.getActiveSurface();
    const pane_title: []const u8 = if (surface) |s| s.getTitle() orelse "" else "";
    const codex_process = if (surface) |s| s.isForegroundCodex() else false;
    const identity: []const u8 = tab.getTitleOverride() orelse std.mem.span(page.getTitle());
    return colors.background(identity, pane_title, codex_process, tab.getCodexColor());
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
