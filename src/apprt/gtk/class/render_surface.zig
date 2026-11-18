const std = @import("std");

const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");
const gtk = @import("gtk");

const global = @import("../../../global.zig");
const Application = @import("application.zig").Application;
const Common = @import("../class.zig").Common;
const scale_util = @import("../scale.zig");
const CoreSurface = @import("../../../Surface.zig");
const rendererpkg = @import("../../../renderer.zig");
const ExportedFrame = rendererpkg.Renderer.ExportedFrame;
const Dmabuf = @import("../../../renderer/Dmabuf.zig");

const log = std.log.scoped(.gtk_render_surface);

/// A widget that displays the rendered output of the Ghostty renderer.
///
/// In the past, Ghostty relied on GTK's builtin `GLArea` to display the
/// rendered output within the GTK-based UI, but this had numerous
/// debilitating limitations.
///
/// Its most significant limitation is that GTK's render lifecycle lives
/// **exclusively on the main UI thread**, from initialization to drawing the
/// rendered framebuffers. This is not only inefficient but also error-prone,
/// as we offload our render work to a dedicated render thread which has
/// to be careful not to access the renderer at the same time as the main
/// thread. Initialization is also far more complex as we had to wait for
/// GTK's OpenGL context to initialize, then we can proceed with initializing
/// the renderer and then the core surface. (The GTK surface widget could not
/// assume it always has a valid core surface, which is obviously absurd!)
/// It was a messy, chicken-and-egg relationship that held us back a lot.
///
/// With our custom `RenderSurface`, the renderer instead renders frames,
/// exports them into DMABUFs, then pushes them into a queue that this widget
/// can consume at its own pace on the main thread, whenever GTK calls for it
/// to be snapshotted. This also allowed us to do triple-buffering and should
/// greatly reduce tearing. Initialization is done on the render thread and
/// always completes before the core surface is created. Furthermore, this
/// surface is actually OpenGL-agnostic, since it operates exclusively on
/// DMABUFs which can also be produced by other graphics APIs like Vulkan.
pub const RenderSurface = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyRenderSurface",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const C = Common(Self, Private);

    pub const Private = struct {
        /// The core surface, used to pull presents from the renderer.
        /// Set by the apprt Surface when it realizes the render surface.
        core_surface: ?*CoreSurface = null,

        /// The GDK Texture currently being displayed.
        texture: ?*gdk.Texture = null,

        /// `notify::scale` handler id on `scale_surface`.
        scale_notify_id: c_ulong = 0,

        /// GdkSurface we connected; ref'd so a replacement cannot dangle the handler.
        scale_surface: ?*gdk.Surface = null,

        /// One-shot so we log the first real allocation, not every size-allocate.
        scale_logged_size: bool = false,

        /// Pending `cpu-fallback` emission while frames arrive via CPU
        /// memory instead of DMABUFs. Cancelled by the next DMABUF frame,
        /// so short fallbacks (e.g. while resizing) are not reported.
        cpu_timer: c_uint = 0,

        /// Why the most recent frame came from CPU memory.
        cpu_reason: ExportedFrame.Memory.Reason = .unhealthy,

        /// Whether the current CPU fallback was already reported.
        cpu_reported: bool = false,

        /// When we last reported a CPU fallback, in seconds on the
        /// awake clock, so a flapping fallback doesn't spam the user.
        cpu_reported_at: ?i64 = null,

        pub var offset: c_int = 0;
    };

    const private = C.private;
    pub const as = C.as;

    /// Why frames are produced or presented on the CPU. Passed as
    /// `c_uint` with the `cpu-rendering` signal.
    pub const CpuRendering = enum(c_uint) {
        /// DMABUFs can't be used, frames are copied through CPU memory.
        unshareable,

        /// The compositor holds all of our DMABUFs, frames are copied
        /// through CPU memory until it releases one.
        buffers_busy,

        /// The GL implementation rasterizes on the CPU (no GPU driver).
        software,
    };

    /// Whether we already reported a software renderer. Reported once
    /// per process since every surface shares the same driver.
    var software_reported = false;

    /// How long frames must keep coming from CPU memory before we
    /// report it.
    const cpu_report_delay_ms = 1000;

    /// The minimum time between two reports.
    const cpu_report_cooldown_s = 60;

    pub const signals = struct {
        /// Emitted when rendering or presenting happens on the CPU:
        /// once when the renderer is a software rasterizer, or when
        /// frames have been presented via CPU readback instead of
        /// DMABUFs for a while. The argument is a `CpuRendering`.
        pub const @"cpu-rendering" = struct {
            pub const name = "cpu-rendering";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{c_uint},
                void,
            );
        };

        pub const resize = struct {
            pub const name = "resize";
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ c_int, c_int },
                void,
            );
        };
    };

    //---------------------------------------------------------------
    // Virtual methods

    fn realize(self: *Self) callconv(.c) void {
        // Call the parent realize.
        gtk.Widget.virtual_methods.realize.call(
            Class.parent,
            self.as(gtk.Widget),
        );

        // Request a draw in case frames were produced before we
        // realized. The snapshot will pull from the renderer's queue.
        self.connectScaleNotify();
        self.as(gtk.Widget).queueDraw();
    }

    fn unrealize(self: *Self) callconv(.c) void {
        const priv = self.private();

        self.disconnectScaleNotify();
        self.cpuFallbackEnded();

        if (priv.texture) |tex| {
            tex.as(gobject.Object).unref();
            priv.texture = null;
        }

        gtk.Widget.virtual_methods.unrealize.call(
            Class.parent,
            self.as(gtk.Widget),
        );
    }

    fn sizeAllocate(
        self: *Self,
        width: c_int,
        height: c_int,
        baseline: c_int,
    ) callconv(.c) void {
        self.connectScaleNotify();
        self.emitDeviceResize(width, height);

        gtk.Widget.virtual_methods.size_allocate.call(
            Class.parent,
            self.as(gtk.Widget),
            width,
            height,
            baseline,
        );

        const priv = self.private();
        if (!priv.scale_logged_size and width > 0 and height > 0) {
            self.logScale("allocated", width, height);
            priv.scale_logged_size = true;
        }
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        const priv = self.private();

        // Take the latest present from the renderer's queue, if any, and
        // build a texture from it. `take` closes any present that was
        // still unconsumed in the queue, but not the texture we're
        // currently displaying.
        if (priv.core_surface) |core| {
            if (!software_reported and core.renderer.isSoftwareRendering()) {
                software_reported = true;
                log.warn("OpenGL is rasterizing on the CPU, no GPU acceleration", .{});
                signals.@"cpu-rendering".impl.emit(
                    self,
                    null,
                    .{@backingInt(CpuRendering.software)},
                    null,
                );
            }

            if (core.renderer.takeFrame()) |frame| {
                self.rebuildTexture(frame) catch |err| switch (err) {
                    // GTK can't import our DMABUFs, e.g. due to an
                    // incompatible format modifier on multi-GPU setups.
                    // Report unhealthy presentation health so the
                    // renderer presents via CPU readback instead.
                    error.DmabufBuildFailed => {
                        log.warn(
                            "failed to import dmabuf, asking renderer for CPU presentation",
                            .{},
                        );
                        core.reportPresentationHealth(.unhealthy);
                    },

                    else => log.warn("error building texture from frame err={}", .{err}),
                };
            }
        }

        // If we have a texture, draw it.
        const texture = priv.texture orelse return;

        const widget = self.as(gtk.Widget);
        if (widget.getWidth() == 0 or widget.getHeight() == 0) return;

        // Map one texture texel to one device pixel. Widget CSS size would
        // stretch a fractionally scaled buffer. Snap the surface-relative
        // origin so parent chrome cannot place the texture between pixels.
        const layout = scale_util.widgetLayout(widget);
        const origin = layout.snapOrigin();
        const scale: f32 = @floatCast(layout.scale);
        const css_w: f32 = @as(f32, @floatFromInt(texture.getWidth())) / scale;
        const css_h: f32 = @as(f32, @floatFromInt(texture.getHeight())) / scale;

        // GTK, Metal, Vulkan, etc. all have their origin points in the
        // top left, but not OpenGL!
        const flip = !rendererpkg.Renderer.custom_shader_y_is_down;
        if (flip) snap.save();
        defer if (flip) snap.restore();
        if (flip) {
            snap.translate(&.{ .f_x = 0, .f_y = css_h });
            snap.scale(1, -1);
        }

        snap.appendTexture(texture, &.{
            .f_origin = .{ .f_x = @floatCast(origin.x), .f_y = @floatCast(origin.y) },
            .f_size = .{ .f_width = css_w, .f_height = css_h },
        });
    }

    //---------------------------------------------------------------
    // Presenting

    /// Return the size of this surface in device pixels. Used by the
    /// apprt surface to report the size to the renderer.
    pub fn deviceSize(self: *Self) struct { width: u32, height: u32 } {
        const size = scale_util.widgetLayout(self.as(gtk.Widget)).size;
        return .{ .width = size.width, .height = size.height };
    }

    fn emitDeviceResize(self: *Self, css_w: c_int, css_h: c_int) void {
        const size = scale_util.widgetLayoutForSize(self.as(gtk.Widget), css_w, css_h).size;
        if (size.width == 0 or size.height == 0) return;
        signals.resize.impl.emit(
            self,
            null,
            .{ @intCast(size.width), @intCast(size.height) },
            null,
        );
    }

    fn connectScaleNotify(self: *Self) void {
        const native = self.as(gtk.Widget).getNative() orelse return;
        const surface = native.getSurface() orelse return;

        const priv = self.private();
        if (priv.scale_notify_id != 0) {
            if (priv.scale_surface == surface) return;
            self.disconnectScaleNotify();
        }

        _ = surface.as(gobject.Object).ref();
        priv.scale_surface = surface;
        priv.scale_logged_size = false;
        priv.scale_notify_id = gobject.Object.signals.notify.connect(
            surface,
            *Self,
            onScaleNotify,
            self,
            .{ .detail = "scale" },
        );
        const widget = self.as(gtk.Widget);
        self.logScale("connected", widget.getWidth(), widget.getHeight());
    }

    fn disconnectScaleNotify(self: *Self) void {
        const priv = self.private();
        if (priv.scale_notify_id == 0) return;
        if (priv.scale_surface) |surface| {
            gobject.signalHandlerDisconnect(
                surface.as(gobject.Object),
                priv.scale_notify_id,
            );
            surface.as(gobject.Object).unref();
        }
        priv.scale_notify_id = 0;
        priv.scale_surface = null;
    }

    fn onScaleNotify(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const widget = self.as(gtk.Widget);
        self.logScale("changed", widget.getWidth(), widget.getHeight());
        self.emitDeviceResize(widget.getWidth(), widget.getHeight());
        widget.queueDraw();
    }

    fn logScale(self: *Self, event: []const u8, css_width: c_int, css_height: c_int) void {
        const widget = self.as(gtk.Widget);
        const native = widget.getNative() orelse return;
        const surface = native.getSurface() orelse return;
        const layout = scale_util.widgetLayoutForSize(widget, css_width, css_height);

        log.debug(
            "surface scale {s}: css={}x{} device={}x{} surface={d} effective={d} surface_factor={} widget_factor={}",
            .{
                event,
                css_width,
                css_height,
                layout.size.width,
                layout.size.height,
                surface.getScale(),
                layout.scale,
                surface.getScaleFactor(),
                widget.getScaleFactor(),
            },
        );
    }

    /// Set the core surface to pull presents from. Nothing will
    /// render when this is unset.
    pub fn setCoreSurface(self: *Self, core: ?*CoreSurface) void {
        self.private().core_surface = core;
    }

    /// Build a `GdkTexture` from the present and set it as our current
    /// texture, unrefing any previous texture.
    fn rebuildTexture(self: *Self, frame: ExportedFrame) !void {
        switch (frame) {
            .dmabuf => |dmabuf| {
                self.cpuFallbackEnded();
                try self.rebuildDmabufTexture(dmabuf);
            },
            .memory => |memory| {
                self.cpuFallbackFrame(memory.reason);
                try self.rebuildMemoryTexture(memory);
            },
        }
    }

    /// Called for every frame presented from CPU memory. Reports the
    /// fallback once it lasted `cpu_report_delay_ms`.
    fn cpuFallbackFrame(self: *Self, reason: ExportedFrame.Memory.Reason) void {
        const priv = self.private();
        priv.cpu_reason = reason;
        if (priv.cpu_reported or priv.cpu_timer != 0) return;
        priv.cpu_timer = glib.timeoutAdd(cpu_report_delay_ms, cpuFallbackTimer, self);
    }

    /// Called for every DMABUF frame: the CPU fallback, if any, is over.
    fn cpuFallbackEnded(self: *Self) void {
        const priv = self.private();
        priv.cpu_reported = false;
        if (priv.cpu_timer != 0) {
            if (glib.Source.remove(priv.cpu_timer) == 0) {
                log.warn("unable to remove cpu fallback timer", .{});
            }
            priv.cpu_timer = 0;
        }
    }

    fn cpuFallbackTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.cpu_timer = 0;
        priv.cpu_reported = true;

        log.info("presenting via CPU readback reason={t}", .{priv.cpu_reason});

        const now = std.Io.Clock.awake.now(global.io()).toSeconds();
        if (priv.cpu_reported_at) |last| {
            if (now - last < cpu_report_cooldown_s) return 0;
        }
        priv.cpu_reported_at = now;

        const kind: CpuRendering = switch (priv.cpu_reason) {
            .buffers_busy => .buffers_busy,
            .unhealthy, .export_failed => .unshareable,
        };
        signals.@"cpu-rendering".impl.emit(
            self,
            null,
            .{@backingInt(kind)},
            null,
        );
        return 0;
    }

    /// Build a `GdkDmabufTexture` from the present and set it as our
    /// current texture, unrefing any previous texture.
    fn rebuildDmabufTexture(self: *Self, frame: Dmabuf) !void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        const display = widget.getDisplay();

        const builder = gdk.DmabufTextureBuilder.new();
        defer builder.unref();

        builder.setDisplay(display);
        builder.setWidth(frame.width);
        builder.setHeight(frame.height);
        builder.setFourcc(frame.fourcc);
        builder.setModifier(frame.modifier);
        builder.setPremultiplied(@intFromBool(frame.premultiplied));
        builder.setNPlanes(@intCast(frame.planes.count));

        for (0..frame.planes.count) |i| {
            builder.setFd(@intCast(i), frame.planes.fds[i]);
            builder.setOffset(@intCast(i), @intCast(frame.planes.offsets[i]));
            builder.setStride(@intCast(i), @intCast(frame.planes.strides[i]));
        }

        // Build the texture. We retain ownership over the DMABUF FDs
        // and its release token for as long as GTK uses the texture,
        // so we have to make a heap copy and send it to GTK, which
        // calls `dmabufDestroy` once the texture is finalized. With
        // graphics offload that's after the compositor released the
        // buffer, so the renderer may then overwrite it.
        const app = Application.default();
        const alloc = app.allocator();

        const holder = alloc.create(Dmabuf) catch |err| {
            frame.deinit();
            return err;
        };
        errdefer alloc.destroy(holder);

        holder.* = frame;
        errdefer holder.deinit();

        var err_: ?*glib.Error = null;
        const texture = builder.build(
            dmabufDestroy,
            holder,
            &err_,
        ) orelse {
            if (err_) |err|
                log.warn("failed to build dmabuf err={s}", .{err.f_message orelse "(unknown)"});
            return error.DmabufBuildFailed;
        };

        // Swap out the old texture.
        if (priv.texture) |old| old.as(gobject.Object).unref();
        priv.texture = texture;
    }

    /// Destroy callback for `GdkDmabufTexture`. GDK calls this when the
    /// texture is released; we close the FDs, release the buffer back
    /// to the renderer and free the holder.
    fn dmabufDestroy(data: ?*anyopaque) callconv(.c) void {
        const app = Application.default();
        const alloc = app.allocator();

        const holder: *Dmabuf = @ptrCast(@alignCast(data orelse return));
        holder.deinit();
        alloc.destroy(holder);
    }

    /// Holder for the pixel data backing a `GdkMemoryTexture`. GTK
    /// ref-counts the `GBytes` we hand it and calls `memoryDestroy`
    /// when it no longer needs the data, at which point we can return
    /// the pixels to the allocator.
    const MemoryHolder = struct {
        alloc: std.mem.Allocator,
        pixels: []u8,
    };

    /// Build a `GdkMemoryTexture` from a CPU memory frame and set it as
    /// our current texture, unrefing any previous texture. This is the
    /// fallback path for drivers that can't export DMA-BUFs.
    fn rebuildMemoryTexture(self: *Self, frame: ExportedFrame.Memory) !void {
        const priv = self.private();

        const app = Application.default();
        const alloc = app.allocator();

        const holder = alloc.create(MemoryHolder) catch |err| {
            // We own the pixels; make sure they don't leak.
            frame.deinit();
            return err;
        };
        errdefer alloc.destroy(holder);
        holder.* = .{ .alloc = alloc, .pixels = frame.pixels };

        // `GdkMemoryTexture` keeps a reference to the `GBytes` for as
        // long as it needs the pixel data, so we hand it our holder and
        // get the pixels freed via the destroy notify below.
        const bytes = glib.Bytes.newWithFreeFunc(
            holder.pixels.ptr,
            holder.pixels.len,
            &memoryDestroy,
            holder,
        );
        errdefer bytes.unref();

        const texture = gdk.MemoryTexture.new(
            @intCast(frame.width),
            @intCast(frame.height),
            .r8g8b8a8_premultiplied,
            bytes,
            frame.width * 4, // stride
        );

        // The texture holds its own reference to the bytes now.
        bytes.unref();

        // Swap out the old texture.
        if (priv.texture) |old| old.as(gobject.Object).unref();
        priv.texture = texture.as(gdk.Texture);
    }

    /// Destroy callback for the `GBytes` backing a `GdkMemoryTexture`.
    fn memoryDestroy(data: ?*anyopaque) callconv(.c) void {
        const holder: *MemoryHolder = @ptrCast(@alignCast(data orelse return));
        holder.alloc.free(holder.pixels);
        holder.alloc.destroy(holder);
    }

    //---------------------------------------------------------------
    // Class

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            // Virtual methods
            gtk.Widget.virtual_methods.realize.implement(class, &realize);
            gtk.Widget.virtual_methods.unrealize.implement(class, &unrealize);
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);

            // Signals
            signals.resize.impl.register(.{});
            signals.@"cpu-rendering".impl.register(.{});
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
