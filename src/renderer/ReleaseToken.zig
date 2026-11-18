//! Release token for a GPU buffer exported to the apprt (e.g. a DMABUF).
//!
//! The renderer must not write to (or delete) an exported buffer until
//! the consumer is done reading it. The token is shared by the producer
//! (the export pool) and the consumer (the apprt) and is independently
//! ref-counted so that either side may drop it first. The consumer calls
//! `release` exactly once when it is done with the buffer; the producer
//! polls `isReleased` and drops its own reference with `unref`.
const ReleaseToken = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;

const log = std.log.scoped(.renderer);

alloc: Allocator,

/// One reference for the producer and one for the consumer.
refs: std.atomic.Value(u8) = .init(2),

/// Set by the consumer once it no longer reads from the buffer.
released: std.atomic.Value(bool) = .init(false),

/// Protects `wakeup` so the producer can clear it before the async
/// handle is destroyed, even while the consumer is releasing.
mutex: std.Io.Mutex = .init,

/// If set, notified on release to wake up the producer. Only set
/// while the producer is waiting for a free buffer.
wakeup: ?*xev.Async = null,

pub fn create(alloc: Allocator) Allocator.Error!*ReleaseToken {
    const self = try alloc.create(ReleaseToken);
    self.* = .{ .alloc = alloc };
    return self;
}

/// Consumer side: the buffer is no longer in use. May be called from
/// any thread. Must be called exactly once by the consumer.
pub fn release(self: *ReleaseToken) void {
    {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.released.store(true, .release);
        if (self.wakeup) |wakeup| wakeup.notify() catch |err| {
            log.warn("error notifying export release err={}", .{err});
        };
    }
    self.unref();
}

/// Producer side: whether the consumer has released the buffer.
pub fn isReleased(self: *ReleaseToken) bool {
    return self.released.load(.acquire);
}

/// Producer side: set (or clear, with null) the wakeup notified on
/// release. Returns true if the token is already released, in which
/// case no notification will follow.
pub fn setWakeup(self: *ReleaseToken, wakeup: ?*xev.Async) bool {
    const io = global.io();
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.wakeup = wakeup;
    return self.released.load(.acquire);
}

/// Drop one reference, freeing the token when none are left.
pub fn unref(self: *ReleaseToken) void {
    if (self.refs.fetchSub(1, .acq_rel) == 1) self.alloc.destroy(self);
}

test "release then unref frees" {
    const t = try ReleaseToken.create(std.testing.allocator);
    try std.testing.expect(!t.isReleased());
    try std.testing.expect(!t.setWakeup(null));
    t.release();
    try std.testing.expect(t.isReleased());
    try std.testing.expect(t.setWakeup(null));
    t.unref();
}

test "unref then release frees" {
    const t = try ReleaseToken.create(std.testing.allocator);
    t.unref();
    t.release();
}

test "release notifies wakeup" {
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();

    const t = try ReleaseToken.create(std.testing.allocator);
    try std.testing.expect(!t.setWakeup(&wakeup));
    t.release();
    t.unref();
}
