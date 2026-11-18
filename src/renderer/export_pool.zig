//! A pool of exported render buffers with release semantics.
//!
//! Every frame the renderer copies its render target into a pool slot
//! and hands that slot to the apprt (e.g. as a DMABUF). A slot is never
//! written or deleted again until the apprt releases it through the
//! slot's `ReleaseToken`. Without this, the renderer could overwrite a
//! buffer the compositor is still reading, which isn't safe on drivers
//! without implicit synchronization of shared buffers.
//!
//! This is generic over the GPU `Resource` backing a slot so that the
//! bookkeeping can be tested without a GPU. A resource must provide:
//!
//!   - `fn init(width: u32, height: u32) !Resource`
//!   - `fn deinit(self: *Resource) void`
//!
//! Not thread-safe: all calls happen on the render thread with the
//! graphics context current. Only the tokens are shared.
const std = @import("std");
const Allocator = std.mem.Allocator;
const xev = @import("../global.zig").xev;
const ReleaseToken = @import("ReleaseToken.zig");

pub fn ExportPool(comptime Resource: type) type {
    return struct {
        const Self = @This();

        /// The maximum number of slots. The apprt usually holds one
        /// or two buffers, plus one waiting to be consumed.
        pub const max_slots = 6;

        pub const Slot = struct {
            resource: Resource,
            width: u32,
            height: u32,

            /// The release token of the frame currently using this slot.
            /// Null when the slot is free.
            token: ?*ReleaseToken = null,

            /// The slot no longer matches the current size and is
            /// deleted once released instead of being reused.
            retired: bool = false,
        };

        alloc: Allocator,
        slots: std.ArrayList(*Slot) = .empty,

        /// Notified when a token is released while we're starved.
        wakeup: ?*xev.Async = null,

        /// True if the last `acquire` found no free slot. A slot
        /// release wakes up `wakeup` while this is set.
        starved: bool = false,

        pub fn init(alloc: Allocator) Self {
            return .{ .alloc = alloc };
        }

        /// Delete all slots. Slots still held by the consumer have
        /// their GPU resources deleted too; the consumer's import
        /// keeps the memory alive and we never write it again.
        /// The pool is empty but usable afterwards.
        pub fn deinit(self: *Self) void {
            for (self.slots.items) |slot| {
                if (slot.token) |token| {
                    _ = token.setWakeup(null);
                    token.unref();
                }
                slot.resource.deinit();
                self.alloc.destroy(slot);
            }
            self.slots.clearAndFree(self.alloc);
            self.starved = false;
        }

        /// Set the async handle to notify when a starved pool frees
        /// a slot. Pass null before the handle is destroyed.
        pub fn setWakeup(self: *Self, wakeup: ?*xev.Async) void {
            self.wakeup = wakeup;
            if (wakeup != null) return;
            for (self.slots.items) |slot| {
                const token = slot.token orelse continue;
                _ = token.setWakeup(null);
            }
        }

        /// Return a free slot of the given size with a fresh release
        /// token, or null if every slot is held by the consumer. The
        /// caller must pass the token to the consumer, or `release` it
        /// itself if the frame isn't delivered.
        pub fn acquire(self: *Self, width: u32, height: u32) !?*Slot {
            self.sweep();

            // Busy slots of another size will never be reused.
            for (self.slots.items) |slot| {
                if (slot.width != width or slot.height != height) {
                    if (slot.token != null) slot.retired = true;
                }
            }

            const slot = try self.findSlot(width, height) orelse slot: {
                // Starved. Ask for a wakeup on release. A token may have
                // been released since our sweep, in which case retry.
                if (!self.watchBusy()) return null;
                self.sweep();
                break :slot try self.findSlot(width, height) orelse return null;
            };

            slot.token = try ReleaseToken.create(self.alloc);
            self.starved = false;
            return slot;
        }

        fn findSlot(self: *Self, width: u32, height: u32) !?*Slot {
            var wrong_size: ?*Slot = null;
            for (self.slots.items) |slot| {
                if (slot.token != null) continue;
                if (slot.width == width and slot.height == height) return slot;
                wrong_size = slot;
            }

            if (wrong_size) |slot| {
                const resource = try Resource.init(width, height);
                slot.resource.deinit();
                slot.* = .{ .resource = resource, .width = width, .height = height };
                return slot;
            }

            if (self.slots.items.len >= max_slots) return null;

            try self.slots.ensureUnusedCapacity(self.alloc, 1);
            const slot = try self.alloc.create(Slot);
            errdefer self.alloc.destroy(slot);
            slot.* = .{
                .resource = try Resource.init(width, height),
                .width = width,
                .height = height,
            };
            self.slots.appendAssumeCapacity(slot);
            return slot;
        }

        /// Mark the pool as starved and ask all busy tokens to wake us
        /// on release. Returns true if one was already released.
        fn watchBusy(self: *Self) bool {
            self.starved = true;
            var any_released = false;
            for (self.slots.items) |slot| {
                const token = slot.token orelse continue;
                if (token.setWakeup(self.wakeup)) any_released = true;
            }
            return any_released;
        }

        /// Free slots whose tokens were released by the consumer and
        /// delete retired ones.
        pub fn sweep(self: *Self) void {
            var i: usize = 0;
            while (i < self.slots.items.len) {
                const slot = self.slots.items[i];
                if (slot.token) |token| {
                    if (!token.isReleased()) {
                        i += 1;
                        continue;
                    }
                    token.unref();
                    slot.token = null;
                }

                if (slot.retired) {
                    slot.resource.deinit();
                    self.alloc.destroy(slot);
                    _ = self.slots.swapRemove(i);
                    continue;
                }
                i += 1;
            }
        }

        /// The number of slots held by the consumer.
        pub fn busyCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots.items) |slot| {
                if (slot.token != null) n += 1;
            }
            return n;
        }
    };
}

const testing = std.testing;

/// A fake GPU resource that tracks how many are alive.
const FakeResource = struct {
    var live: usize = 0;

    width: u32,
    height: u32,

    fn init(width: u32, height: u32) !FakeResource {
        live += 1;
        return .{ .width = width, .height = height };
    }

    fn deinit(self: *FakeResource) void {
        _ = self;
        live -= 1;
    }
};

const TestPool = ExportPool(FakeResource);

test "acquire reuses released slots" {
    FakeResource.live = 0;
    var pool: TestPool = .init(testing.allocator);
    defer pool.deinit();

    const a = (try pool.acquire(10, 10)).?;
    const b = (try pool.acquire(10, 10)).?;
    try testing.expect(a != b);
    try testing.expectEqual(2, pool.busyCount());

    // Not released yet: a new slot is allocated.
    a.token.?.release();
    const c = (try pool.acquire(10, 10)).?;
    try testing.expectEqual(a, c);
    try testing.expectEqual(2, FakeResource.live);

    b.token.?.release();
    c.token.?.release();
    pool.sweep();
    try testing.expectEqual(0, pool.busyCount());
}

test "exhaustion returns null until a release" {
    FakeResource.live = 0;
    var pool: TestPool = .init(testing.allocator);
    defer pool.deinit();

    var slots: [TestPool.max_slots]*TestPool.Slot = undefined;
    for (&slots) |*s| s.* = (try pool.acquire(10, 10)).?;
    try testing.expect(try pool.acquire(10, 10) == null);
    try testing.expect(pool.starved);

    slots[3].token.?.release();
    const s = (try pool.acquire(10, 10)).?;
    try testing.expectEqual(slots[3], s);
    try testing.expect(!pool.starved);
    try testing.expectEqual(TestPool.max_slots, FakeResource.live);

    for (slots) |slot| slot.token.?.release();
}

test "resize retires busy slots and deletes them only after release" {
    FakeResource.live = 0;
    var pool: TestPool = .init(testing.allocator);
    defer pool.deinit();

    const old = (try pool.acquire(10, 10)).?;
    const free = (try pool.acquire(10, 10)).?;
    free.token.?.release();

    // The free slot is recreated at the new size, the busy one retired.
    const new = (try pool.acquire(20, 20)).?;
    try testing.expectEqual(free, new);
    try testing.expectEqual(20, new.resource.width);
    try testing.expect(old.retired);
    try testing.expectEqual(2, FakeResource.live);

    pool.sweep();
    try testing.expectEqual(2, FakeResource.live);

    old.token.?.release();
    pool.sweep();
    try testing.expectEqual(1, FakeResource.live);
    try testing.expectEqual(1, pool.slots.items.len);

    new.token.?.release();
}

test "release after deinit frees the token" {
    FakeResource.live = 0;
    var pool: TestPool = .init(testing.allocator);

    const slot = (try pool.acquire(10, 10)).?;
    const token = slot.token.?;
    pool.deinit();
    try testing.expectEqual(0, FakeResource.live);

    // The consumer still owns its reference; testing.allocator
    // catches a leak or double free.
    token.release();
}

test "starved pool wakes up on release" {
    FakeResource.live = 0;
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();

    var pool: TestPool = .init(testing.allocator);
    defer pool.deinit();
    pool.setWakeup(&wakeup);

    var slots: [TestPool.max_slots]*TestPool.Slot = undefined;
    for (&slots) |*s| s.* = (try pool.acquire(10, 10)).?;
    for (slots) |slot| try testing.expect(slot.token.?.wakeup == null);

    try testing.expect(try pool.acquire(10, 10) == null);
    for (slots) |slot| try testing.expectEqual(&wakeup, slot.token.?.wakeup.?);

    pool.setWakeup(null);
    for (slots) |slot| try testing.expect(slot.token.?.wakeup == null);
    for (slots) |slot| slot.token.?.release();
}
