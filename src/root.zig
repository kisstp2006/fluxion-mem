// SPDX-License-Identifier: BSL-1.0

//! Fluxion Mem - allocators that know something about their memory that a
//! general-purpose one cannot.
//!
//! Six pieces that fit together:
//!
//!   `layout`     alignment arithmetic, and a size a person can read
//!   `Arena`      hand out from one end, give it all back at once
//!   `Stack`      one buffer, handed out from both ends
//!   `Pool`       a fixed number of slots, all one type
//!   `FreeList`   any size, freed in any order, joined back together
//!   `Tracking`   what another allocator did, per category
//!
//! `std.heap` already has a general-purpose allocator, and it is a good one.
//! Nothing here replaces it. What these do is exploit something known about
//! the memory that `malloc` cannot be told:
//!
//! | If you know | then | costs |
//! | --- | --- | --- |
//! | it all dies at the end of the frame | `Arena` | an add |
//! | there are two lifetimes, not many | `Stack` | an add |
//! | everything is the same type | `Pool` | a pointer swap |
//! | it is a fixed budget, freed in any order | `FreeList` | a short search |
//! | you want to know where it went | `Tracking` | a few counters |
//!
//! **Nothing here grows.** Every allocator takes a buffer once and returns
//! `error.OutOfMemory` when it is full, rather than quietly asking the
//! operating system for more. That is the point: an allocator that grows
//! silently is a frame spike you find out about from a player. Every one of
//! them keeps a `high_water` mark instead, which is the number to size the
//! buffer by - measure it once, set it, and the run never allocates again.
//!
//! **They compose.** All six take an `Allocator` or hand one out, so a frame
//! arena inside a tracked category inside a debug allocator is three lines
//! and no glue:
//!
//! ```zig
//! var debug: std.heap.DebugAllocator(.{}) = .init;
//! var tracker: Tracking(Category) = .init(debug.allocator());
//! var frame: Arena = try .initAlloc(tracker.allocator(.frame), 4 << 20);
//! ```
//!
//! **One thread at a time.** None of these lock. An allocator shared between
//! threads needs a lock around it, and the usual answer in an engine is not to
//! share one - give each worker its own arena, which is cheaper than any lock
//! and is why per-thread scratch is the pattern it is.

const std = @import("std");
const testing = std.testing;

pub const layout = @import("layout.zig");

/// Hand out from one end, give it all back at once. See `Arena`.
pub const Arena = @import("Arena.zig");

/// One buffer, handed out from both ends. See `Stack`.
pub const Stack = @import("Stack.zig");

/// Any size, freed in any order, coalesced. See `FreeList`.
pub const FreeList = @import("FreeList.zig");

const pool_module = @import("Pool.zig");
const tracking_module = @import("Tracking.zig");

/// A fixed number of slots of one type. See `Pool`.
pub const Pool = pool_module.Pool;

/// What another allocator did, per category. See `Tracking`.
pub const Tracking = tracking_module.Tracking;

/// What `Tracking` counts, for a caller that wants to read the numbers rather
/// than print them.
pub const Counters = tracking_module.Counters;

// -------------------------------------------------------------------------
// Shorthands
// -------------------------------------------------------------------------

/// A number of bytes, printed the way a person reads one: `{f}` with
/// `mem.size(n)` in it gives `324.4 MiB`.
pub const size = layout.size;

/// The alignment type the `Allocator` interface speaks in.
pub const Alignment = layout.Alignment;

/// Kibibytes, mebibytes and gibibytes, for sizing a buffer at a call site
/// without counting zeroes.
pub inline fn kib(n: usize) usize {
    return n << 10;
}

pub inline fn mib(n: usize) usize {
    return n << 20;
}

pub inline fn gib(n: usize) usize {
    return n << 30;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test {
    // Pull each module in so `zig build test` runs its tests too.
    _ = layout;
    _ = Arena;
    _ = Stack;
    _ = pool_module;
    _ = FreeList;
    _ = tracking_module;
}

test "the pieces compose" {
    // One engine's memory, from the top down.
    const Category = enum { level, frame, entities };

    // Everything is counted, and each category has a budget.
    var tracker: Tracking(Category) = .init(testing.allocator);
    tracker.setLimit(.level, mib(1));

    // The level and the frame share one buffer from opposite ends, so
    // neither has to guess how much the other wants.
    var stack: Stack = try .initAlloc(tracker.allocator(.level), kib(64));
    defer stack.deinit(tracker.allocator(.level));

    const level = stack.allocator(.back);
    const frame = stack.allocator(.front);

    // Entities come out of a pool: same type, so no search and no
    // fragmentation ever.
    const Entity = struct { x: f32, y: f32, health: u16 };
    var entities: Pool(Entity) = try .initAlloc(tracker.allocator(.entities), 512);
    defer entities.deinit(tracker.allocator(.entities));

    // --- load ---------------------------------------------------------
    const mesh = try level.alloc(f32, 1200);
    @memset(mesh, 2.5);

    var alive: [64]Pool(Entity).Index = undefined;
    for (&alive, 0..) |*handle, i| {
        handle.* = entities.createIndex().?;
        entities.at(handle.*).* = .{ .x = @floatFromInt(i), .y = 0, .health = 100 };
    }

    // --- and then some frames ------------------------------------------
    for (0..120) |_| {
        defer stack.reset(.front);

        const visible = try frame.alloc(Pool(Entity).Index, alive.len);
        @memcpy(visible, &alive);

        var total: f32 = 0;
        for (visible) |handle| total += entities.at(handle).x;
        try testing.expectApproxEqAbs(@as(f32, 2016), total, 1e-3);

        // The level data survives every frame reset.
        try testing.expectEqual(@as(f32, 2.5), mesh[600]);
    }

    // --- what it cost ---------------------------------------------------
    try testing.expectEqual(@as(usize, 0), stack.usedBy(.front));
    try testing.expect(stack.highWater(.front) > 0);
    try testing.expectEqual(@as(usize, 64), entities.live);
    try testing.expectEqual(@as(usize, 64), entities.high_water);

    // Two categories are holding memory, which at this point is correct.
    try testing.expectEqual(@as(usize, 2), tracker.leakCount());
    try testing.expect(tracker.stats(.level).live_bytes >= kib(64));
    try testing.expect(tracker.stats(.frame).isEmpty()); // it went through the stack

    // And a category that runs over its budget is refused here rather than
    // by the machine, later, on somebody else's computer.
    const cramped = tracker.allocator(.level);
    try testing.expectError(error.OutOfMemory, cramped.alloc(u8, mib(2)));
    try testing.expectEqual(@as(usize, 1), tracker.stats(.level).refused_count);
}

test "a scratch scope inside a frame" {
    var frame: Arena = try .initAlloc(testing.allocator, kib(16));
    defer frame.deinit(testing.allocator);
    const a = frame.allocator();

    const kept = try a.alloc(u8, 100);
    @memset(kept, 1);

    // Work that needs room but produces one small answer.
    const answer = blk: {
        const scratch = frame.scope();
        defer scratch.end();

        const working = try a.alloc(u32, 1000);
        for (working, 0..) |*v, i| v.* = @intCast(i);

        var sum: u32 = 0;
        for (working) |v| sum += v;
        break :blk sum;
    };

    try testing.expectEqual(@as(u32, 499_500), answer);
    // The thousand words of working memory are gone; the hundred bytes stay.
    try testing.expectEqual(@as(usize, 100), frame.used);
    try testing.expectEqual(@as(u8, 1), kept[50]);
    // And the peak remembers what the scope needed, for sizing the buffer.
    try testing.expect(frame.high_water >= 4000);
}

test "shorthands" {
    try testing.expectEqual(@as(usize, 1024), kib(1));
    try testing.expectEqual(@as(usize, 1024 * 1024), mib(1));
    try testing.expectEqual(@as(usize, 1024 * 1024 * 1024), gib(1));
    try testing.expectEqual(@as(usize, 4 * 1024 * 1024), mib(4));

    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{size(mib(324) + kib(400))});
    try testing.expectEqualStrings("324.4 MiB", w.buffered());

    // The aliases are the same types, not copies of them. The enum has to be
    // named: two anonymous `enum { a }` literals are two different types.
    const One = enum { a };
    try testing.expect(Pool(u32) == pool_module.Pool(u32));
    try testing.expect(Tracking(One) == tracking_module.Tracking(One));
    try testing.expect(Counters == tracking_module.Counters);
    try testing.expect(Alignment == std.mem.Alignment);
}

test "every allocator here satisfies the interface it hands out" {
    // The same exercise against all four, so that a change to any one of them
    // has to keep working with the code that only knows `Allocator`.
    var arena_backing: [kib(32)]u8 align(16) = undefined;
    var arena: Arena = .init(&arena_backing);

    var stack_backing: [kib(32)]u8 align(16) = undefined;
    var stack: Stack = .init(&stack_backing);

    var list_backing: [kib(32)]u8 align(16) = undefined;
    var list: FreeList = .init(&list_backing);

    var tracker: Tracking(enum { all }) = .init(testing.allocator);

    const allocators = [_]std.mem.Allocator{
        arena.allocator(),
        stack.allocator(.front),
        stack.allocator(.back),
        list.allocator(),
        tracker.allocator(.all),
    };

    for (allocators) |a| {
        // Slices of several types and alignments.
        const bytes = try a.alloc(u8, 100);
        const words = try a.alloc(u64, 50);
        const aligned = try a.alignedAlloc(u8, .fromByteUnits(64), 32);
        try testing.expect(std.mem.isAligned(@intFromPtr(aligned.ptr), 64));

        // A single value.
        const one = try a.create(u32);
        one.* = 7;
        try testing.expectEqual(@as(u32, 7), one.*);

        // A growing list, which exercises resize and remap.
        var items: std.ArrayList(u16) = .empty;
        for (0..200) |i| try items.append(a, @intCast(i));
        try testing.expectEqual(@as(usize, 200), items.items.len);
        for (items.items, 0..) |v, i| try testing.expectEqual(@as(u16, @intCast(i)), v);

        // A formatted string, which allocates an exact size.
        const text = try std.fmt.allocPrint(a, "{d} items", .{items.items.len});
        try testing.expectEqualStrings("200 items", text);

        // And back, in the reverse order, which every one of them handles.
        a.free(text);
        items.deinit(a);
        a.destroy(one);
        a.free(aligned);
        a.free(words);
        a.free(bytes);
    }

    // The one that counts says nothing is left.
    try testing.expect(!tracker.leaked());
    // The one that coalesces says the region is whole again.
    try testing.expect(list.verify());
}
