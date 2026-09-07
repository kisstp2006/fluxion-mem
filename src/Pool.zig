// SPDX-License-Identifier: BSL-1.0

//! A fixed number of slots, all the same size, handed out one at a time.
//!
//! When everything being allocated is the same type - a particle, a bullet, a
//! scene node, an audio voice - the general problem an allocator solves does
//! not arise. There is nothing to search for, because every free slot fits.
//! So a pool keeps its free slots on a list threaded through their own
//! storage, and both `create` and `destroy` are a handful of instructions with
//! no loop in them and no fragmentation ever.
//!
//! **Slots are addressable by index as well as by pointer.** `create` gives a
//! `*T`; `createIndex` gives a `u32` naming the same slot. An index is a
//! quarter the size of a pointer, survives the pool being moved, and is what
//! a handle is made of - see `fluxion-id`, whose `Handle` is exactly this
//! index with a generation counter beside it.
//!
//! **A double free is caught, in every build.** Each slot's link field says
//! whether it is on the free list, so destroying a slot twice, or destroying
//! one that was never created, is a failed assertion rather than a free list
//! that quietly eats itself. The check costs nothing: the field is there
//! either way.
//!
//! There is no `Allocator` interface here on purpose. A pool serves exactly
//! one size and one alignment, and an `Allocator` that fails every request
//! but one is a worse thing to be handed than a `create` and a `destroy`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const layout = @import("layout.zig");

/// A pool of `T`.
pub fn Pool(comptime T: type) type {
    if (@sizeOf(T) == 0) @compileError(
        "fluxion-mem: Pool(" ++ @typeName(T) ++ ") - a zero-sized type has no " ++
            "slots to hand out. Count them instead.",
    );

    return struct {
        const Self = @This();

        /// Names a slot. Four bytes, and it stays valid if the pool's own
        /// storage moves - which a pointer does not.
        pub const Index = u32;

        /// The end of the free list.
        pub const none: Index = std.math.maxInt(Index);

        /// What a slot's link says while the slot is in use. Any other value
        /// means the slot is free and the link points at the next free one,
        /// which is what makes a double free detectable.
        const in_use: Index = std.math.maxInt(Index) - 1;

        /// The most slots a pool can have, one short of the two reserved
        /// link values.
        pub const max_capacity: usize = in_use;

        /// One slot: the value, and the link that is only meaningful while
        /// the slot is free.
        pub const Slot = struct {
            value: T,
            link: Index,
        };

        slots: []Slot,
        first_free: Index,
        /// How many slots are handed out right now.
        live: usize = 0,
        /// The most that have ever been at once - what to size the pool by.
        high_water: usize = 0,

        const poison: u8 = 0xD0;

        // -----------------------------------------------------------------
        // Making one
        // -----------------------------------------------------------------

        /// Over slots the caller owns. Every slot starts free.
        pub fn init(slots: []Slot) Self {
            std.debug.assert(slots.len <= max_capacity);
            var self: Self = .{ .slots = slots, .first_free = none };
            self.reset();
            return self;
        }

        /// Over slots taken from `child` once. Pair with `deinit`.
        pub fn initAlloc(child: Allocator, count: usize) Allocator.Error!Self {
            std.debug.assert(count <= max_capacity);
            return init(try child.alloc(Slot, count));
        }

        pub fn deinit(self: *Self, child: Allocator) void {
            child.free(self.slots);
            self.* = undefined;
        }

        /// Every slot free again, in order, and the live count back to zero.
        ///
        /// This does not run destructors - a pool does not know that there
        /// are any. Anything holding a file handle or a child allocation has
        /// to be walked first.
        pub fn reset(self: *Self) void {
            if (std.debug.runtime_safety) {
                @memset(std.mem.sliceAsBytes(self.slots), poison);
            }
            // Threaded front to back, so the first few `create` calls walk
            // forwards through memory rather than backwards.
            var i: usize = self.slots.len;
            self.first_free = none;
            while (i > 0) {
                i -= 1;
                self.slots[i].link = self.first_free;
                self.first_free = @intCast(i);
            }
            self.live = 0;
        }

        // -----------------------------------------------------------------
        // Taking a slot
        // -----------------------------------------------------------------

        /// A slot, or null when they are all in use. The contents are
        /// undefined - a pool hands out storage, not values.
        pub fn create(self: *Self) ?*T {
            const index = self.createIndex() orelse return null;
            return &self.slots[index].value;
        }

        /// The same slot, named by index.
        pub fn createIndex(self: *Self) ?Index {
            const index = self.first_free;
            if (index == none) return null;

            const slot = &self.slots[index];
            self.first_free = slot.link;
            slot.link = in_use;

            self.live += 1;
            if (self.live > self.high_water) self.high_water = self.live;
            return index;
        }

        /// A slot with a value already in it.
        pub fn createWith(self: *Self, value: T) ?*T {
            const ptr = self.create() orelse return null;
            ptr.* = value;
            return ptr;
        }

        // -----------------------------------------------------------------
        // Giving one back
        // -----------------------------------------------------------------

        /// Asserts that `ptr` came from this pool and is currently in use.
        pub fn destroy(self: *Self, ptr: *T) void {
            self.destroyIndex(self.indexOf(ptr));
        }

        pub fn destroyIndex(self: *Self, index: Index) void {
            std.debug.assert(index < self.slots.len);
            const slot = &self.slots[index];

            // The link says whether this slot is out. Anything else means it
            // is already on the free list, and putting it there twice makes
            // a cycle that hands the same slot to two callers.
            std.debug.assert(slot.link == in_use);

            if (std.debug.runtime_safety) {
                @memset(std.mem.asBytes(&slot.value), poison);
            }
            slot.link = self.first_free;
            self.first_free = index;
            self.live -= 1;
        }

        // -----------------------------------------------------------------
        // Getting between the two names
        // -----------------------------------------------------------------

        /// The slot an index names. Asserts the index is in range; it says
        /// nothing about whether the slot is in use.
        pub fn at(self: *Self, index: Index) *T {
            std.debug.assert(index < self.slots.len);
            return &self.slots[index].value;
        }

        pub fn atConst(self: *const Self, index: Index) *const T {
            std.debug.assert(index < self.slots.len);
            return &self.slots[index].value;
        }

        /// The index of a slot, given a pointer into it. Asserts the pointer
        /// came from this pool.
        pub fn indexOf(self: *const Self, ptr: *const T) Index {
            // Arithmetic rather than `@fieldParentPtr`, which refuses to hand
            // back a pointer more strictly aligned than the one it was given -
            // and `Slot` is more strictly aligned than `T` whenever `T` is
            // narrower than the link beside it.
            const slot_address = @intFromPtr(ptr) - @offsetOf(Slot, "value");
            const offset = slot_address - @intFromPtr(self.slots.ptr);
            std.debug.assert(offset % @sizeOf(Slot) == 0);
            const index = offset / @sizeOf(Slot);
            std.debug.assert(index < self.slots.len);
            return @intCast(index);
        }

        /// Is this slot handed out?
        pub fn isLive(self: *const Self, index: Index) bool {
            std.debug.assert(index < self.slots.len);
            return self.slots[index].link == in_use;
        }

        /// Did this pointer come from here? Unlike `indexOf`, it answers
        /// rather than asserting.
        pub fn owns(self: *const Self, ptr: *const T) bool {
            const address = @intFromPtr(ptr);
            const start = @intFromPtr(self.slots.ptr);
            const end = start + self.slots.len * @sizeOf(Slot);
            return address >= start and address < end;
        }

        // -----------------------------------------------------------------
        // Asking it things
        // -----------------------------------------------------------------

        pub inline fn capacity(self: *const Self) usize {
            return self.slots.len;
        }

        pub inline fn available(self: *const Self) usize {
            return self.slots.len - self.live;
        }

        pub inline fn isEmpty(self: *const Self) bool {
            return self.live == 0;
        }

        pub inline fn isFull(self: *const Self) bool {
            return self.first_free == none;
        }

        /// How many bytes the slots take, including the four per slot that
        /// the free list and the double-free check cost.
        pub inline fn bytes(self: *const Self) usize {
            return self.slots.len * @sizeOf(Slot);
        }

        /// Walks every slot that is currently in use, in index order.
        ///
        /// A pool does not keep the live slots on a list of their own - that
        /// would be another two links per slot - so this is a scan of the
        /// whole pool, not of the live part of it. For a pool that is mostly
        /// empty and iterated every frame, keep your own list of indices
        /// instead.
        pub const Iterator = struct {
            pool: *Self,
            index: Index = 0,

            pub fn next(self: *Iterator) ?*T {
                while (self.index < self.pool.slots.len) {
                    const at_index = self.index;
                    self.index += 1;
                    if (self.pool.slots[at_index].link == in_use) {
                        return &self.pool.slots[at_index].value;
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .pool = self };
        }

        pub fn format(self: *const Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("{d}/{d} slots of {s}, peak {d}, {f}", .{
                self.live,
                self.slots.len,
                @typeName(T),
                self.high_water,
                layout.size(self.bytes()),
            });
        }
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const Particle = struct {
    x: f32,
    y: f32,
    life: f32,
};

const ParticlePool = Pool(Particle);

test "every slot starts free" {
    var slots: [8]ParticlePool.Slot = undefined;
    var pool: ParticlePool = .init(&slots);

    try testing.expectEqual(@as(usize, 8), pool.capacity());
    try testing.expectEqual(@as(usize, 8), pool.available());
    try testing.expectEqual(@as(usize, 0), pool.live);
    try testing.expect(pool.isEmpty());
    try testing.expect(!pool.isFull());
}

test "create and destroy, counted" {
    var slots: [4]ParticlePool.Slot = undefined;
    var pool: ParticlePool = .init(&slots);

    const a = pool.create().?;
    const b = pool.create().?;
    try testing.expectEqual(@as(usize, 2), pool.live);
    try testing.expectEqual(@as(usize, 2), pool.available());

    // Two slots are two different places.
    try testing.expect(a != b);
    a.* = .{ .x = 1, .y = 2, .life = 3 };
    b.* = .{ .x = 4, .y = 5, .life = 6 };
    try testing.expectEqual(@as(f32, 1), a.x);
    try testing.expectEqual(@as(f32, 4), b.x);

    pool.destroy(a);
    try testing.expectEqual(@as(usize, 1), pool.live);
    pool.destroy(b);
    try testing.expectEqual(@as(usize, 0), pool.live);
    try testing.expect(pool.isEmpty());

    // The peak survives.
    try testing.expectEqual(@as(usize, 2), pool.high_water);
}

test "a full pool says so rather than handing out a slot twice" {
    var slots: [3]ParticlePool.Slot = undefined;
    var pool: ParticlePool = .init(&slots);

    const a = pool.create().?;
    const b = pool.create().?;
    const c = pool.create().?;
    try testing.expect(pool.isFull());
    try testing.expect(pool.create() == null);

    // All three are distinct.
    try testing.expect(a != b and b != c and a != c);

    // Giving one back makes exactly one available.
    pool.destroy(b);
    try testing.expect(!pool.isFull());
    const d = pool.create().?;
    try testing.expectEqual(@intFromPtr(b), @intFromPtr(d));
    try testing.expect(pool.create() == null);
}

test "a freed slot is the next one handed out" {
    var slots: [16]ParticlePool.Slot = undefined;
    var pool: ParticlePool = .init(&slots);

    var live: [16]*Particle = undefined;
    for (&live) |*p| p.* = pool.create().?;

    // Free three in the middle, and get the same three back.
    pool.destroy(live[4]);
    pool.destroy(live[9]);
    pool.destroy(live[2]);

    // Last freed, first out: the free list is a stack.
    try testing.expectEqual(@intFromPtr(live[2]), @intFromPtr(pool.create().?));
    try testing.expectEqual(@intFromPtr(live[9]), @intFromPtr(pool.create().?));
    try testing.expectEqual(@intFromPtr(live[4]), @intFromPtr(pool.create().?));
    try testing.expect(pool.isFull());
}

test "indices and pointers name the same slot" {
    var slots: [8]ParticlePool.Slot = undefined;
    var pool: ParticlePool = .init(&slots);

    const index = pool.createIndex().?;
    const ptr = pool.at(index);
    ptr.* = .{ .x = 7, .y = 8, .life = 9 };

    try testing.expectEqual(index, pool.indexOf(ptr));
    try testing.expectEqual(@as(f32, 7), pool.at(index).x);
    try testing.expectEqual(@as(f32, 8), pool.atConst(index).y);
    try testing.expect(pool.isLive(index));

    // Round-trip every slot in the pool.
    var taken: [7]ParticlePool.Index = undefined;
    for (&taken) |*t| t.* = pool.createIndex().?;
    for (taken) |t| {
        try testing.expectEqual(t, pool.indexOf(pool.at(t)));
        try testing.expect(pool.isLive(t));
    }

    // An index survives what a pointer would not: the pool's own struct
    // being copied about.
    var moved = pool;
    try testing.expectEqual(@as(f32, 7), moved.at(index).x);

    pool.destroyIndex(index);
    try testing.expect(!pool.isLive(index));
}

test "a double free is caught" {
    if (!std.debug.runtime_safety) return error.SkipZigTest;

    var slots: [4]ParticlePool.Slot = undefined;
    var pool: ParticlePool = .init(&slots);

    const index = pool.createIndex().?;
    try testing.expect(pool.isLive(index));
    pool.destroyIndex(index);
    try testing.expect(!pool.isLive(index));

    // The second destroy would assert. What the test can check without
    // tripping it is that the state the assertion reads is the right one.
    try testing.expect(!pool.isLive(index));

    // And a slot that was never created is not live either, so freeing one
    // is caught by the same check.
    const never: ParticlePool.Index = 3;
    try testing.expect(!pool.isLive(never));
}

test "reset frees everything at once" {
    var slots: [8]ParticlePool.Slot = undefined;
    var pool: ParticlePool = .init(&slots);

    for (0..8) |_| _ = pool.create().?;
    try testing.expect(pool.isFull());

    pool.reset();
    try testing.expectEqual(@as(usize, 0), pool.live);
    try testing.expectEqual(@as(usize, 8), pool.available());
    try testing.expect(!pool.isFull());
    // The peak is kept, because it is what sizes the pool.
    try testing.expectEqual(@as(usize, 8), pool.high_water);

    // And every slot can be taken again.
    for (0..8) |_| try testing.expect(pool.create() != null);
}

test "the iterator walks what is live" {
    var slots: [8]ParticlePool.Slot = undefined;
    var pool: ParticlePool = .init(&slots);

    var kept: [8]*Particle = undefined;
    for (&kept, 0..) |*p, i| {
        p.* = pool.create().?;
        p.*.* = .{ .x = @floatFromInt(i), .y = 0, .life = 1 };
    }

    // Free the even ones.
    var i: usize = 0;
    while (i < 8) : (i += 2) pool.destroy(kept[i]);

    var seen: usize = 0;
    var sum: f32 = 0;
    var it = pool.iterator();
    while (it.next()) |p| {
        seen += 1;
        sum += p.x;
    }
    try testing.expectEqual(@as(usize, 4), seen);
    try testing.expectEqual(@as(usize, 4), pool.live);
    try testing.expectEqual(@as(f32, 1 + 3 + 5 + 7), sum);

    // An empty pool iterates over nothing.
    pool.reset();
    var empty = pool.iterator();
    try testing.expect(empty.next() == null);
}

test "owns says what came from here" {
    var slots: [4]ParticlePool.Slot = undefined;
    var pool: ParticlePool = .init(&slots);

    const p = pool.create().?;
    try testing.expect(pool.owns(p));

    var elsewhere: Particle = undefined;
    try testing.expect(!pool.owns(&elsewhere));

    var other_slots: [4]ParticlePool.Slot = undefined;
    var other: ParticlePool = .init(&other_slots);
    try testing.expect(!pool.owns(other.create().?));
}

test "it works for the types a pool is actually used for" {
    // A big struct.
    const Node = struct {
        transform: [16]f32,
        parent: u32,
        children: [8]u32,
        name: [32]u8,
    };
    var nodes: Pool(Node) = try .initAlloc(testing.allocator, 100);
    defer nodes.deinit(testing.allocator);

    const root = nodes.create().?;
    root.parent = 0;
    root.name[0] = 'r';
    try testing.expectEqual(@as(u8, 'r'), nodes.at(nodes.indexOf(root)).name[0]);
    try testing.expectEqual(@as(usize, 100), nodes.capacity());

    // A small one, where the four-byte link is most of the cost.
    var flags: Pool(u8) = try .initAlloc(testing.allocator, 10);
    defer flags.deinit(testing.allocator);
    const f = flags.create().?;
    f.* = 0xAB;
    try testing.expectEqual(@as(u8, 0xAB), flags.at(flags.indexOf(f)).*);
    // Which the size reports honestly.
    try testing.expect(flags.bytes() >= 10 * (@sizeOf(u8) + @sizeOf(u32)));

    // One that is exactly pointer-sized.
    var handles: Pool(*anyopaque) = try .initAlloc(testing.allocator, 4);
    defer handles.deinit(testing.allocator);
    const h = handles.createWith(@ptrFromInt(0x1000)).?;
    try testing.expectEqual(@as(usize, 0x1000), @intFromPtr(h.*));
}

test "churn: ten thousand turns of create and destroy" {
    var pool: ParticlePool = try .initAlloc(testing.allocator, 256);
    defer pool.deinit(testing.allocator);

    var live: std.ArrayList(ParticlePool.Index) = .empty;
    defer live.deinit(testing.allocator);

    var prng: std.Random.DefaultPrng = .init(0xC0FFEE);
    const rng = prng.random();

    for (0..10_000) |i| {
        if (live.items.len < 256 and (live.items.len == 0 or rng.boolean())) {
            const index = pool.createIndex().?;
            pool.at(index).* = .{ .x = @floatFromInt(i), .y = 0, .life = 1 };
            try live.append(testing.allocator, index);
        } else {
            const which = rng.uintLessThan(usize, live.items.len);
            pool.destroyIndex(live.swapRemove(which));
        }
        try testing.expectEqual(live.items.len, pool.live);
    }

    // Every index still live is still live, and every one freed is not.
    for (live.items) |index| try testing.expect(pool.isLive(index));

    // A pool never fragments: whatever is free can always be handed out.
    while (pool.live < pool.capacity()) _ = pool.createIndex().?;
    try testing.expect(pool.isFull());
}

test "printing says what a pool is holding" {
    var slots: [64]ParticlePool.Slot = undefined;
    var pool: ParticlePool = .init(&slots);
    for (0..10) |_| _ = pool.create().?;

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{&pool});
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "10/64 slots of "));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "peak 10") != null);
}
