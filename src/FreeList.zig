// SPDX-License-Identifier: BSL-1.0

//! One region of memory, sub-allocated in blocks of any size, with the freed
//! ones joined back together.
//!
//! The one allocator here that behaves like a general-purpose one: any size,
//! any alignment, freed in any order, and adjacent free blocks merged so that
//! two halves become a whole again. That is what an `Arena` will not do and a
//! `Pool` cannot.
//!
//! What it costs is a search. Allocation walks the free blocks from the front
//! and takes the first that fits, which is O(the number of free blocks) - fine
//! for a subsystem with a fixed budget and a few hundred live allocations,
//! and not fine as a replacement for the system allocator. If the answer to
//! "how many blocks are there" is "I do not know", this is the wrong
//! allocator; `Arena` or `Pool` almost certainly is not.
//!
//! **The bookkeeping lives in the free memory itself.** A free block holds
//! its own size and the link to the next one, so there is no side table, no
//! header on a live allocation, and the overhead of a full heap is exactly
//! zero bytes. The price is a minimum block size - a free block has to be big
//! enough to describe itself - so a request that would leave a stub smaller
//! than that takes a different block instead.
//!
//! **Blocks are kept sorted by address**, which is what makes coalescing a
//! comparison against the neighbours rather than a search. It is also what
//! makes `verify` able to check, in a test, that the list is still sound.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const layout = @import("layout.zig");

const FreeList = @This();

/// The header of a free block, written into the block's own first bytes. A
/// live allocation has no header at all.
const Node = struct {
    /// The whole block, in bytes, including this header.
    size: usize,
    /// The next free block, which is always at a higher address.
    next: ?*Node,
};

/// Every block boundary is a multiple of this, so that a `Node` can always be
/// written at the start of a free block.
const granularity: usize = @alignOf(Node);

/// The smallest block that can exist: one that can hold its own header.
pub const min_block: usize = std.mem.alignForward(usize, @sizeOf(Node), granularity);

const gran_align: Alignment = .fromByteUnits(granularity);

const poison: u8 = 0xF7;

/// The region, trimmed to start and end on a block boundary. The alignment is
/// in the type because `deinit` has to give the memory back with the same
/// alignment it was taken with.
buffer: []align(granularity) u8,

/// The free blocks, in address order. Null when nothing is free.
first: ?*Node,

/// Bytes handed out, rounded up to the granularity - so this is what the
/// region is actually spending, not what the caller asked for.
used: usize = 0,

high_water: usize = 0,

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

/// Over memory the caller owns. The front and back are trimmed to block
/// boundaries, so `capacity` may be a few bytes less than `buffer.len`.
pub fn init(buffer: []u8) FreeList {
    const start = gran_align.forward(@intFromPtr(buffer.ptr));
    const end = gran_align.backward(@intFromPtr(buffer.ptr) + buffer.len);

    const front: [*]align(granularity) u8 = @ptrFromInt(start);
    if (end <= start or end - start < min_block) {
        return .{ .buffer = front[0..0], .first = null };
    }
    return fromAligned(front[0 .. end - start]);
}

/// Over memory taken from `child` once. Pair with `deinit`.
pub fn initAlloc(child: Allocator, size: usize) Allocator.Error!FreeList {
    return fromAligned(try child.alignedAlloc(u8, gran_align, size));
}

/// One free block covering as much of an already-aligned region as a whole
/// number of granules will reach.
fn fromAligned(region: []align(granularity) u8) FreeList {
    const usable = gran_align.backward(region.len);
    if (usable < min_block) return .{ .buffer = region, .first = null };

    const node: *Node = @ptrCast(region.ptr);
    node.* = .{ .size = usable, .next = null };
    return .{ .buffer = region, .first = node };
}

pub fn deinit(self: *FreeList, child: Allocator) void {
    child.free(self.buffer);
    self.* = undefined;
}

pub fn allocator(self: *FreeList) Allocator {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Allocator.VTable = .{
    .alloc = allocFn,
    .resize = resizeFn,
    .remap = remapFn,
    .free = freeFn,
};

/// Everything free again, as one block. Does not run destructors and does not
/// care what was live.
pub fn reset(self: *FreeList) void {
    const size = gran_align.backward(self.buffer.len);
    if (std.debug.runtime_safety) @memset(self.buffer, poison);
    if (size < min_block) {
        self.first = null;
    } else {
        const node: *Node = @ptrCast(self.buffer.ptr);
        node.* = .{ .size = size, .next = null };
        self.first = node;
    }
    self.used = 0;
}

// -------------------------------------------------------------------------
// Asking it things
// -------------------------------------------------------------------------

pub inline fn capacity(self: *const FreeList) usize {
    return gran_align.backward(self.buffer.len);
}

/// Bytes not handed out. The sum of the free blocks, which is not the same as
/// the largest allocation that would succeed - see `largestFree`.
pub fn freeBytes(self: *const FreeList) usize {
    var total: usize = 0;
    var maybe = self.first;
    while (maybe) |node| : (maybe = node.next) total += node.size;
    return total;
}

/// The biggest single block. An allocation larger than this cannot succeed
/// however much is free in total, which is what fragmentation means.
pub fn largestFree(self: *const FreeList) usize {
    var largest: usize = 0;
    var maybe = self.first;
    while (maybe) |node| : (maybe = node.next) largest = @max(largest, node.size);
    return largest;
}

/// How many separate free blocks there are. One is a region with no
/// fragmentation; a large number is a region that will start refusing
/// allocations it has room for.
pub fn blockCount(self: *const FreeList) usize {
    var count: usize = 0;
    var maybe = self.first;
    while (maybe) |node| : (maybe = node.next) count += 1;
    return count;
}

pub fn owns(self: *const FreeList, memory: []const u8) bool {
    return layout.ownsSlice(self.buffer, memory);
}

/// Walk the free list and check that it is still what it claims to be:
/// sorted, inside the region, non-overlapping, and fully coalesced.
///
/// For tests and for an assertion after something suspicious. It is a walk of
/// the whole list, so it does not belong in a hot path.
pub fn verify(self: *const FreeList) bool {
    const start = @intFromPtr(self.buffer.ptr);
    const end = start + self.buffer.len;

    var previous_end: usize = start;
    var maybe = self.first;
    var total: usize = 0;

    while (maybe) |node| : (maybe = node.next) {
        const address = @intFromPtr(node);

        if (address < previous_end) return false; // out of order, or overlapping
        if (address + node.size > end) return false; // off the end
        if (node.size < min_block) return false; // too small to hold itself
        if (!gran_align.check(address)) return false; // off a boundary
        if (!gran_align.check(node.size)) return false;

        // Fully coalesced: no two free blocks may touch.
        if (address == previous_end and previous_end != start) return false;

        previous_end = address + node.size;
        total += node.size;
    }

    // What is free and what is used must together be the whole region.
    return total + self.used == self.capacity();
}

// -------------------------------------------------------------------------
// The allocator
// -------------------------------------------------------------------------

/// The bytes a request of `len` actually occupies.
inline fn blockFor(len: usize) ?usize {
    const rounded = std.math.add(usize, len, granularity - 1) catch return null;
    return @max(min_block, rounded & ~(granularity - 1));
}

fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *FreeList = @ptrCast(@alignCast(ctx));
    _ = ret_addr;

    const want = blockFor(len) orelse return null;
    const wanted_align = alignment.max(gran_align);

    var prev: ?*Node = null;
    var maybe = self.first;
    while (maybe) |node| : ({
        prev = node;
        maybe = node.next;
    }) {
        const address = @intFromPtr(node);
        var payload = wanted_align.forward(address);

        // A gap in front of the payload becomes a free block of its own, so
        // it has to be big enough to be one. If it is not, push the payload
        // on until it is.
        if (payload != address and payload - address < min_block) {
            payload = wanted_align.forward(address + min_block);
        }

        const front = payload - address;
        if (front > node.size or node.size - front < want) continue;

        const back = node.size - front - want;
        // The same rule at the far end: a stub too small to describe itself
        // cannot be left behind, and it cannot be absorbed either, because
        // `free` would not know it was there.
        if (back != 0 and back < min_block) continue;

        // Read the link before writing anything: the tail block's header may
        // land on top of this node's.
        const after = node.next;

        const tail: ?*Node = if (back == 0) null else blk: {
            const t: *Node = @ptrFromInt(payload + want);
            t.* = .{ .size = back, .next = after };
            break :blk t;
        };

        if (front != 0) {
            // The front of the block stays free, in place.
            node.size = front;
            node.next = tail orelse after;
        } else {
            // The whole block was taken from its start, so it leaves the list.
            const replacement = tail orelse after;
            if (prev) |p| p.next = replacement else self.first = replacement;
        }

        self.used += want;
        if (self.used > self.high_water) self.high_water = self.used;
        return @ptrFromInt(payload);
    }

    return null;
}

fn freeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *FreeList = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;
    self.release(@intFromPtr(memory.ptr), blockFor(memory.len).?);
}

/// Put `[address, address + size)` back on the list, joined to whichever
/// neighbours it touches.
fn release(self: *FreeList, address: usize, size: usize) void {
    std.debug.assert(gran_align.check(address));
    std.debug.assert(gran_align.check(size));
    std.debug.assert(address >= @intFromPtr(self.buffer.ptr));
    std.debug.assert(address + size <= @intFromPtr(self.buffer.ptr) + self.buffer.len);

    // Where it goes: the list is sorted, so this is a walk to the first block
    // past it.
    var prev: ?*Node = null;
    var maybe = self.first;
    while (maybe) |node| {
        if (@intFromPtr(node) > address) break;
        prev = node;
        maybe = node.next;
    }

    // A block that overlaps a free one is a double free, or a pointer that
    // was never handed out. Either way the list is about to become a cycle,
    // so say so here instead.
    if (prev) |p| std.debug.assert(@intFromPtr(p) + p.size <= address);
    if (maybe) |n| std.debug.assert(address + size <= @intFromPtr(n));

    if (std.debug.runtime_safety) {
        @memset(@as([*]u8, @ptrFromInt(address))[0..size], poison);
    }

    const node: *Node = @ptrFromInt(address);
    node.* = .{ .size = size, .next = maybe };
    if (prev) |p| p.next = node else self.first = node;

    self.used -= size;

    // Join to the block after, then to the one before. In that order: the
    // backward join may absorb the node entirely, and its `next` has to be
    // right by then.
    if (node.next) |n| {
        if (address + node.size == @intFromPtr(n)) {
            node.size += n.size;
            node.next = n.next;
        }
    }
    if (prev) |p| {
        if (@intFromPtr(p) + p.size == address) {
            p.size += node.size;
            p.next = node.next;
        }
    }
}

fn resizeFn(
    ctx: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    const self: *FreeList = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;
    std.debug.assert(@inComptime() or self.owns(memory));

    const old = blockFor(memory.len).?;
    const new = blockFor(new_len) orelse return false;
    if (new == old) return true;

    const address = @intFromPtr(memory.ptr);

    if (new < old) {
        // The tail goes back on the list - but only if it is big enough to
        // be a block. If it is not, refuse: the caller keeps the size it has,
        // which is always safe.
        const tail = old - new;
        if (tail < min_block) return false;
        self.release(address + new, tail);
        return true;
    }

    // Growing: the block immediately after this one has to be free, and big
    // enough, and leave a stub that is either nothing or a whole block.
    const extra = new - old;
    const after = address + old;

    var prev: ?*Node = null;
    var maybe = self.first;
    while (maybe) |node| : ({
        prev = node;
        maybe = node.next;
    }) {
        if (@intFromPtr(node) == after) break;
        if (@intFromPtr(node) > after) return false;
    }
    const node = maybe orelse return false;
    if (node.size < extra) return false;

    const leftover = node.size - extra;
    if (leftover != 0 and leftover < min_block) return false;

    const node_next = node.next;
    const replacement: ?*Node = if (leftover == 0) node_next else blk: {
        const t: *Node = @ptrFromInt(after + extra);
        t.* = .{ .size = leftover, .next = node_next };
        break :blk t;
    };
    if (prev) |p| p.next = replacement else self.first = replacement;

    self.used += extra;
    if (self.used > self.high_water) self.high_water = self.used;
    return true;
}

fn remapFn(
    ctx: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    return if (resizeFn(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

pub fn format(self: *const FreeList, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{f} of {f} used, {d} free blocks, largest {f}", .{
        layout.size(self.used),
        layout.size(self.capacity()),
        self.blockCount(),
        layout.size(self.largestFree()),
    });
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a fresh region is one free block" {
    var backing: [4096]u8 align(16) = undefined;
    var list: FreeList = .init(&backing);

    try testing.expectEqual(@as(usize, 1), list.blockCount());
    try testing.expectEqual(@as(usize, 4096), list.capacity());
    try testing.expectEqual(@as(usize, 4096), list.freeBytes());
    try testing.expectEqual(@as(usize, 0), list.used);
    try testing.expect(list.verify());
}

test "allocate, free, and the region is whole again" {
    var backing: [4096]u8 align(16) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();

    const first = try a.alloc(u8, 100);
    const second = try a.alloc(u8, 200);
    const third = try a.alloc(u8, 300);
    try testing.expect(list.verify());
    try testing.expect(list.used >= 600);

    a.free(second);
    try testing.expect(list.verify());
    a.free(first);
    try testing.expect(list.verify());
    a.free(third);
    try testing.expect(list.verify());

    // Everything back, and coalesced into the single block it started as.
    try testing.expectEqual(@as(usize, 0), list.used);
    try testing.expectEqual(@as(usize, 1), list.blockCount());
    try testing.expectEqual(@as(usize, 4096), list.freeBytes());
}

test "freed neighbours are joined back together" {
    var backing: [4096]u8 align(16) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();

    const one = try a.alloc(u8, 512);
    const two = try a.alloc(u8, 512);
    const three = try a.alloc(u8, 512);
    // A wall big enough that what is left over at the end is smaller than the
    // holes, so `largestFree` is measuring the holes and not the tail.
    _ = try a.alloc(u8, 2048);

    // Free the outer two: two separate holes, with `two` still between them.
    a.free(one);
    a.free(three);
    try testing.expect(list.verify());
    try testing.expectEqual(@as(usize, 3), list.blockCount()); // two holes + the tail
    try testing.expectEqual(@as(usize, 512), list.largestFree());

    // Free the one between them, and all three become one.
    a.free(two);
    try testing.expect(list.verify());
    try testing.expectEqual(@as(usize, 2), list.blockCount()); // the joined hole + the tail
    try testing.expectEqual(@as(usize, 1536), list.largestFree());

    // Which is a block that none of the three could have held on its own.
    const big = try a.alloc(u8, 1500);
    try testing.expect(list.owns(big));
    try testing.expect(list.verify());
}

test "a hole is reused, and split when it is bigger than needed" {
    var backing: [4096]u8 align(16) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();

    _ = try a.alloc(u8, 256);
    const hole = try a.alloc(u8, 1024);
    _ = try a.alloc(u8, 256);

    const address = @intFromPtr(hole.ptr);
    a.free(hole);

    // A smaller allocation lands in the hole and leaves the rest of it free.
    const small = try a.alloc(u8, 100);
    try testing.expectEqual(address, @intFromPtr(small.ptr));
    try testing.expect(list.verify());

    // And the remainder of the hole is still usable.
    const rest = try a.alloc(u8, 800);
    try testing.expect(list.owns(rest));
    try testing.expect(list.verify());
}

test "alignment is honoured, and the gap in front stays usable" {
    var backing: [8192]u8 align(4096) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();

    inline for (.{ 1, 2, 4, 8, 16, 32, 64, 128, 256 }) |n| {
        // Something small first, so the next block does not start aligned.
        const shim = try a.alloc(u8, 17);
        const p = try a.alignedAlloc(u8, .fromByteUnits(n), 40);

        try testing.expect(std.mem.isAligned(@intFromPtr(p.ptr), n));
        try testing.expect(list.owns(p));
        try testing.expect(list.verify());

        a.free(p);
        a.free(shim);
        try testing.expect(list.verify());
    }

    // Everything came back.
    try testing.expectEqual(@as(usize, 0), list.used);
    try testing.expectEqual(@as(usize, 1), list.blockCount());
}

test "a large alignment leaves a hole that is itself allocatable" {
    var backing: [8192]u8 align(4096) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();

    _ = try a.alloc(u8, 8); // knock the front off alignment
    const aligned = try a.alignedAlloc(u8, .fromByteUnits(512), 64);
    try testing.expect(std.mem.isAligned(@intFromPtr(aligned.ptr), 512));
    try testing.expect(list.verify());

    // The gap the alignment skipped is a free block, and it can be used.
    try testing.expect(list.blockCount() >= 2);
    const in_the_gap = try a.alloc(u8, 32);
    try testing.expect(@intFromPtr(in_the_gap.ptr) < @intFromPtr(aligned.ptr));
    try testing.expect(list.verify());
}

test "a full region says so" {
    var backing: [1024]u8 align(16) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();

    const whole = try a.alloc(u8, 1024);
    try testing.expectEqual(@as(usize, 0), list.freeBytes());
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 1));

    a.free(whole);
    try testing.expectEqual(@as(usize, 1024), list.freeBytes());

    // And a request larger than the region never succeeds.
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 2048));
    try testing.expect(list.verify());
}

test "fragmentation is visible, and is what it costs" {
    var backing: [4096]u8 align(16) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();

    // Sixteen blocks, then free every other one.
    var blocks: [16][]u8 = undefined;
    for (&blocks) |*b| b.* = try a.alloc(u8, 200);

    var i: usize = 0;
    while (i < 16) : (i += 2) a.free(blocks[i]);
    try testing.expect(list.verify());

    // Plenty free in total...
    try testing.expect(list.freeBytes() >= 8 * 200);
    // ...but no single block big enough for half of it, which is exactly the
    // failure this allocator can have and an arena cannot.
    try testing.expect(list.largestFree() < 8 * 200);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 8 * 200));
    try testing.expect(list.blockCount() > 4);

    // Freeing the rest joins it all back into one.
    i = 1;
    while (i < 16) : (i += 2) a.free(blocks[i]);
    try testing.expectEqual(@as(usize, 1), list.blockCount());
    try testing.expect(list.verify());
}

test "resize grows into the block after, and shrinks by giving the tail back" {
    var backing: [4096]u8 align(16) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();

    var block = try a.alloc(u8, 100);
    const address = @intFromPtr(block.ptr);

    // Nothing after it but free space, so it grows where it stands.
    try testing.expect(a.resize(block, 500));
    block.len = 500;
    try testing.expectEqual(address, @intFromPtr(block.ptr));
    try testing.expect(list.verify());

    // Shrinking hands the tail back.
    const before = list.used;
    try testing.expect(a.resize(block, 100));
    block.len = 100;
    try testing.expect(list.used < before);
    try testing.expect(list.verify());

    // With something immediately after it, it cannot grow.
    const wall = try a.alloc(u8, 64);
    _ = wall;
    try testing.expect(!a.resize(block, 4000));
    try testing.expect(list.verify());
}

test "an ArrayList lives in it" {
    var backing: [8192]u8 align(16) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();

    var items: std.ArrayList(u64) = .empty;
    defer items.deinit(a);

    for (0..300) |i| try items.append(a, i);
    try testing.expectEqual(@as(usize, 300), items.items.len);
    for (items.items, 0..) |v, i| try testing.expectEqual(i, v);
    try testing.expect(list.verify());

    // And a second one alongside it.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    for (0..20) |_| try names.append(a, "x");
    try testing.expect(list.verify());
}

test "reset puts it back to one block whatever was live" {
    var backing: [4096]u8 align(16) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();

    for (0..10) |_| _ = try a.alloc(u8, 64);
    try testing.expect(list.used > 0);
    try testing.expect(list.blockCount() >= 1);

    list.reset();
    try testing.expectEqual(@as(usize, 0), list.used);
    try testing.expectEqual(@as(usize, 1), list.blockCount());
    try testing.expectEqual(list.capacity(), list.freeBytes());
    try testing.expect(list.verify());
}

test "a region too small to hold a block holds nothing" {
    var tiny: [4]u8 align(16) = undefined;
    var list: FreeList = .init(&tiny);
    const a = list.allocator();

    try testing.expectEqual(@as(usize, 0), list.blockCount());
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    try testing.expect(list.verify());
}

test "the smallest request still gets a whole block" {
    var backing: [1024]u8 align(16) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();

    // One byte occupies `min_block`, because a block has to be able to
    // describe itself once it is freed.
    const one = try a.alloc(u8, 1);
    try testing.expectEqual(min_block, list.used);
    a.free(one);
    try testing.expectEqual(@as(usize, 0), list.used);
    try testing.expect(list.verify());
}

test "churn: five thousand random allocations and frees" {
    var list: FreeList = try .initAlloc(testing.allocator, 8 * 1024);
    defer list.deinit(testing.allocator);
    const a = list.allocator();

    var live: std.ArrayList([]u8) = .empty;
    defer live.deinit(testing.allocator);

    var prng: std.Random.DefaultPrng = .init(0xF2EE1157);
    const rng = prng.random();

    var refused: usize = 0;
    for (0..5000) |_| {
        if (live.items.len > 0 and rng.boolean()) {
            const which = rng.uintLessThan(usize, live.items.len);
            const block = live.swapRemove(which);
            // What was written into it is still what is there.
            for (block) |byte| try testing.expectEqual(@as(u8, 0x5C), byte);
            a.free(block);
        } else {
            const size = 1 + rng.uintLessThan(usize, 700);
            const alignment: Alignment = .fromByteUnits(
                @as(usize, 1) << @intCast(rng.uintLessThan(u6, 7)),
            );
            const block = a.rawAlloc(size, alignment, 0) orelse {
                refused += 1;
                continue;
            };
            const slice = block[0..size];
            try testing.expect(std.mem.isAligned(@intFromPtr(slice.ptr), alignment.toByteUnits()));
            @memset(slice, 0x5C);
            try live.append(testing.allocator, slice);
        }
        try testing.expect(list.verify());
    }

    // Free what is left, and the region must come back whole.
    for (live.items) |block| a.free(block);
    try testing.expect(list.verify());
    try testing.expectEqual(@as(usize, 0), list.used);
    try testing.expectEqual(@as(usize, 1), list.blockCount());

    // It did refuse some, which is the point of a fixed region.
    try testing.expect(refused > 0);
}

test "live allocations never overlap" {
    var list: FreeList = try .initAlloc(testing.allocator, 16 * 1024);
    defer list.deinit(testing.allocator);
    const a = list.allocator();

    var live: std.ArrayList([]u8) = .empty;
    defer live.deinit(testing.allocator);

    var prng: std.Random.DefaultPrng = .init(0x0FFA1AB);
    const rng = prng.random();

    for (0..400) |_| {
        if (live.items.len > 3 and rng.boolean()) {
            a.free(live.swapRemove(rng.uintLessThan(usize, live.items.len)));
        } else {
            const block = a.alloc(u8, 1 + rng.uintLessThan(usize, 200)) catch continue;
            try live.append(testing.allocator, block);
        }

        // Every live block against every other one.
        for (live.items, 0..) |x, i| {
            for (live.items[i + 1 ..]) |y| {
                const x_start = @intFromPtr(x.ptr);
                const y_start = @intFromPtr(y.ptr);
                try testing.expect(x_start + x.len <= y_start or y_start + y.len <= x_start);
            }
        }
    }
    for (live.items) |block| a.free(block);
    try testing.expect(list.verify());
}

test "printing says how full it is" {
    var backing: [4096]u8 align(16) = undefined;
    var list: FreeList = .init(&backing);
    const a = list.allocator();
    _ = try a.alloc(u8, 1024);

    var buf: [160]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{&list});
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "1.0 KiB of 4.0 KiB used") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "1 free blocks") != null);
}
