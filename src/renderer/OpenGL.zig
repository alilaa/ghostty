//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);
const Dmabuf = @import("Dmabuf.zig");
const xev = global.xev;
pub const Device = @import("opengl/Device.zig");

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
const ExportPool = @import("export_pool.zig").ExportPool(Target.Export);
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// Triple-buffering gives the GPU room to pipeline renders without
/// having to wait on the apprt consuming previous frames.
pub const swap_chain_count = 3;

const log = std.log.scoped(.opengl);

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The shared render device.
device: *const Device,

egl_context: *gl.egl.Context,

/// Whether `egl_context` was created with a lose-context-on-reset
/// notification strategy, so GPU resets can be detected.
robust: bool,

/// glGetGraphicsResetStatus, loaded on the render thread for robust
/// contexts. Not part of the generated GL 4.3 bindings.
get_graphics_reset_status: ?*const fn () callconv(.c) gl.c.GLenum = null,

/// Whether a GPU reset has already been reported for this context.
gpu_reset_reported: bool = false,

/// Set once a GPU reset is detected, until the renderer reports it to the
/// surface via `takeGpuReset`.
gpu_reset_pending: bool = false,

/// Whether the GL implementation rasterizes on the CPU (e.g. llvmpipe).
/// Set on the render thread, read by the apprt.
software_renderer: std.atomic.Value(bool) = .init(false),

/// Textures we export frames through. Render thread only.
export_pool: ExportPool,

/// How many frames fell back to CPU presentation because every
/// export texture was still held by the apprt.
export_starved_count: u64 = 0,

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !OpenGL {
    const display = device.display;

    // Bind to OpenGL API explicitly before we create the context,
    // as otherwise it might fallback to OpenGL ES
    try egl.bindApi(egl.c.EGL_OPENGL_API);

    // Create our context. Contexts are surface-scoped because a
    // context can only be current on one thread at a time.
    //
    // Prefer a context that reports GPU resets (driver timeouts, device
    // removal) so we can log them; without this a reset leaves the
    // surface silently frozen. Not every driver supports it.
    var robust = true;
    const context = egl.Context.create(display, device.config, null, &.{
        egl.c.EGL_CONTEXT_MAJOR_VERSION,                      MIN_VERSION_MAJOR,
        egl.c.EGL_CONTEXT_MINOR_VERSION,                      MIN_VERSION_MINOR,
        egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK,                egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        egl.c.EGL_CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY, egl.c.EGL_LOSE_CONTEXT_ON_RESET,
    }) catch |robust_err| fallback: {
        log.info("GPU reset notification unavailable err={}", .{robust_err});
        robust = false;
        break :fallback egl.Context.create(display, device.config, null, &.{
            egl.c.EGL_CONTEXT_MAJOR_VERSION,       MIN_VERSION_MAJOR,
            egl.c.EGL_CONTEXT_MINOR_VERSION,       MIN_VERSION_MINOR,
            egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        }) catch |err| {
            log.warn("failed to create EGL context err={}", .{err});
            return err;
        };
    };
    errdefer context.destroy(display) catch {};

    display.makeCurrent(null, null, context) catch |err| {
        log.warn("failed to make EGL context current err={}", .{err});
        return err;
    };

    // Release current so that the main thread
    // doesn't hold onto the GL context forever.
    defer display.releaseCurrent();

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = device,
        .egl_context = context,
        .robust = robust,
        .export_pool = .init(alloc),
    };
}

pub fn deinit(self: *OpenGL) void {
    // GL objects are freed on the render thread by `releaseExportPool`.
    std.debug.assert(self.export_pool.slots.items.len == 0);
    self.export_pool.deinit();
    self.device.display.releaseCurrent();
    self.egl_context.destroy(self.device.display) catch {};
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".attrs.@"callconv";

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = try gl.glad.load(getProcAddress);
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer gl.glad.unload();
    log.info("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Enable debug output for the context.
    try gl.enable(gl.c.GL_DEBUG_OUTPUT);

    // Register our debug message callback with the OpenGL context.
    gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
}

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread. The EGL context was created at `init` time on the main thread;
/// here we (re)bind it to this thread and load the thread-local glad
/// function pointers so all subsequent GL work on this thread is valid.
pub fn threadEnter(self: *OpenGL, surface: *apprt.Surface) !void {
    _ = surface;
    try self.device.display.makeCurrent(null, null, self.egl_context);
    // Load our function pointers for this thread's threadlocal.
    try prepareContext(&gl.egl.getProcAddress);

    if (gl.glad.context.GetString.?(gl.c.GL_RENDERER)) |ptr| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
        const software = isSoftwareRenderer(name);
        log.info("OpenGL renderer={s} software={}", .{ name, software });
        self.software_renderer.store(software, .release);
    }

    if (self.robust) {
        const proc = gl.egl.getProcAddress("glGetGraphicsResetStatus") orelse
            gl.egl.getProcAddress("glGetGraphicsResetStatusARB");
        self.get_graphics_reset_status = @ptrCast(proc);
        if (proc == null) log.info("glGetGraphicsResetStatus unavailable", .{});
    }
}

/// Whether the GL_RENDERER string names a CPU rasterizer.
fn isSoftwareRenderer(name: []const u8) bool {
    const needles = [_][]const u8{
        "llvmpipe",
        "softpipe",
        "swrast",
        "SwiftShader",
        "Software Rasterizer",
        // WARP, the D3D12 software adapter used by WSL without a GPU.
        "Microsoft Basic Render Driver",
    };
    for (needles) |needle| {
        if (std.ascii.findIgnoreCase(name, needle) != null) return true;
    }
    return false;
}

/// True if the GL implementation rasterizes on the CPU. Thread-safe.
pub fn isSoftwareRendering(self: *const OpenGL) bool {
    return self.software_renderer.load(.acquire);
}

/// Callback called by renderer.Thread when it exits. Called on the render
/// thread; unbinds the context from this thread so it can be destroyed on
/// the main thread.
pub fn threadExit(self: *OpenGL) void {
    self.releaseExportPool();
    self.device.display.releaseCurrent();
    gl.glad.unload();
}

/// Called by renderer.Thread when it starts the main loop. A starved
/// export pool wakes up the render thread through `wakeup` when the
/// apprt releases a texture.
pub fn setExportWakeup(self: *OpenGL, wakeup: ?*xev.Async) void {
    self.export_pool.setWakeup(wakeup);
}

/// Free all export textures. Textures still held by the apprt are
/// never written again; the apprt's import keeps their memory alive.
/// Must be called on the render thread with the context current.
pub fn releaseExportPool(self: *OpenGL) void {
    self.export_pool.deinit();
}

/// True if the last frame couldn't be exported because all export
/// textures were held by the apprt, so it should be redrawn as soon
/// as one is released.
pub fn needsRedraw(self: *const OpenGL) bool {
    return self.export_pool.starved;
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    _ = self;
    var viewport: [4]gl.c.GLint = undefined;
    gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    return .{
        .width = @intCast(viewport[2]),
        .height = @intCast(viewport[3]),
    };
}

/// Set the GL viewport to cover the given size in device pixels.
///
/// This used to be automatically called by the GtkGLArea upon resizing,
/// but now we need to do this manually.
pub fn setViewport(self: *const OpenGL, width: u32, height: u32) void {
    _ = self;
    gl.viewport(0, 0, @intCast(width), @intCast(height)) catch |err| {
        log.warn("failed to set OpenGL viewport err={}", .{err});
    };
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
pub fn drawFrameEnd(self: *OpenGL) void {
    self.checkGpuReset();
}

/// Log once if the GPU reset this context. After a reset every GL call on
/// the context is a no-op, so the surface stops updating; the log line
/// (with a wall-clock time, since log lines carry none) makes that visible.
fn checkGpuReset(self: *OpenGL) void {
    if (self.gpu_reset_reported) return;
    const getStatus = self.get_graphics_reset_status orelse return;
    const status = getStatus();
    if (status == gl.c.GL_NO_ERROR) return;
    self.gpu_reset_reported = true;
    self.gpu_reset_pending = true;

    const cause: []const u8 = switch (status) {
        0x8253 => "guilty", // GL_GUILTY_CONTEXT_RESET
        0x8254 => "innocent", // GL_INNOCENT_CONTEXT_RESET
        0x8255 => "unknown", // GL_UNKNOWN_CONTEXT_RESET
        else => "unrecognized",
    };
    var buf: [20]u8 = undefined;
    log.err(
        "GPU reset detected, this surface can no longer render cause={s} status=0x{x} time={s}",
        .{ cause, status, formatUtcNow(&buf) },
    );
}

/// Returns true exactly once after a GPU reset was detected.
pub fn takeGpuReset(self: *OpenGL) bool {
    defer self.gpu_reset_pending = false;
    return self.gpu_reset_pending;
}

/// The current time as `YYYY-MM-DDTHH:MM:SSZ`.
fn formatUtcNow(buf: *[20]u8) []const u8 {
    const now = std.Io.Timestamp.now(global.io(), .real).toSeconds();
    const epoch = std.time.epoch;
    const epoch_secs: epoch.EpochSeconds = .{ .secs = @intCast(@max(now, 0)) };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const ds = epoch_secs.getDaySeconds();
    return std.mem.print(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "????-??-??T??:??:??Z";
}

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    _ = self;
    return Target.init(.{
        .width = width,
        .height = height,
    });
}

/// Export a rendered target. Caller takes ownership
/// of the frame and is responsible for freeing it.
///
/// This runs on the render thread.
pub fn present(
    self: *OpenGL,
    target: Target,
    presentation_health: rendererpkg.Health,
) !ExportedFrame {
    // We only export DMABUFs when the apprt can present them.
    // Otherwise, use CPU buffers.
    var cpu_reason: ExportedFrame.Memory.Reason = .unhealthy;
    if (presentation_health == .healthy) dmabuf: {
        cpu_reason = .export_failed;
        const slot = self.export_pool.acquire(
            @intCast(target.width),
            @intCast(target.height),
        ) catch |err| {
            log.warn("failed to create export texture, falling back to CPU presentation err={}", .{err});
            break :dmabuf;
        } orelse {
            // The apprt still holds every export texture. Don't block
            // the render thread; present this frame from CPU memory.
            cpu_reason = .buffers_busy;
            self.export_starved_count += 1;
            if (std.math.isPowerOfTwo(self.export_starved_count)) log.debug(
                "all export textures busy, using CPU presentation count={} busy={}",
                .{ self.export_starved_count, self.export_pool.busyCount() },
            );
            break :dmabuf;
        };

        var dmabuf = target.exportDmabuf(
            self.device.display,
            self.egl_context,
            &slot.resource,
        ) catch {
            // The apprt never gets the frame, so release it ourselves.
            slot.token.?.release();
            log.warn("failed to export DMABUF, falling back to CPU presentation", .{});
            break :dmabuf;
        };
        dmabuf.release = slot.token;
        return .{ .dmabuf = dmabuf };
    }

    return .{ .memory = .{
        .width = @intCast(target.width),
        .height = @intCast(target.height),
        .pixels = try target.readPixelsAlloc(self.alloc),
        .alloc = self.alloc,
        .reason = cpu_reason,
    } };
}

/// A finished frame exported for presentation by the apprt.
pub const ExportedFrame = union(enum) {
    dmabuf: Dmabuf,
    memory: Memory,

    /// RGBA8 pixel data with premultiplied alpha, tightly packed
    /// (`width * 4` bytes per row), in CPU memory.
    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,

        /// Why this frame wasn't exported as a DMABUF.
        reason: Reason,

        pub const Reason = enum {
            /// The apprt asked for CPU frames, e.g. it can't import
            /// our DMABUFs.
            unhealthy,

            /// Exporting the DMABUF failed.
            export_failed,

            /// The apprt still holds every export buffer.
            buffers_busy,
        };

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .dmabuf => |v| v.deinit(),
            .memory => |v| v.deinit(),
        }
    }
};

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2d",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2d",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}

test isSoftwareRenderer {
    const testing = std.testing;
    try testing.expect(isSoftwareRenderer("llvmpipe (LLVM 19.1.7, 256 bits)"));
    try testing.expect(isSoftwareRenderer("D3D12 (Microsoft Basic Render Driver)"));
    try testing.expect(!isSoftwareRenderer("D3D12 (NVIDIA GeForce RTX 4070)"));
    try testing.expect(!isSoftwareRenderer("AMD Radeon Graphics (radeonsi, gfx1103_r1, LLVM 19.1.7, DRM 3.59, 6.12.6)"));
}
