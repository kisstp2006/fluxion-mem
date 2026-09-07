// SPDX-License-Identifier: BSL-1.0

//! A block of memory handed out from one end, and given back all at once.
//!
//! The cheapest allocator there is: an allocation is a bounds check and an
//! addition, and freeing is setting one number back to where it was. There is
//! no free list, no header on each block, and no way to return one allocation
//! without returning the ones after it - which is not a limitation so much as
//! the deal. A frame's worth of scratch does not need individual frees. It
//! needs one `reset` at the top of the next frame.
//!
//! **The buffer is fixed and does not grow.** That is deliberate. An arena
//! that quietly asks the operating system for more is an arena that hides a
//! frame spike inside itself; this one returns `error.OutOfMemory` and
//! `high_water` tells you exactly how much it wanted. Size it once from that
//! number and it never allocates again. `std.heap.ArenaAllocator` is the
//! growing kind, and is the right answer for work whose size is not known.
//!
//! Three ways to give memory back, in order of how much:
//!
//!   `reset`             everything, at the top of a frame
//!   `restore(mark)`     back to where `mark` was taken
//!   `allocator().free`  the most recent allocation only, and only if it is
//!                       still the most recent
//!
//! `mark` and `restore` are what make this a stack allocator as well as a
//! frame allocator: take a mark, do some nested work, restore. `scope` is the
//! same thing with `defer` doing the restoring.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const layout = @import("layout.zig");

const Arena = @This();

/// The memory it hands out of. Not owned unless `initAlloc` made it.
buffer: []u8,

/// How much of `buffer` is in use, from the front.
used: usize = 0,

/// The most `used` has ever been. Survives `reset`, because the whole point
/// of it is to say how big the buffer should have been.
high_water: usize = 0,

/// What a reset arena is filled with in safe builds, so that a pointer into
/// last frame's memory reads as obvious rubbish rather than as plausible
/// stale data.
const poison: u8 = 0xA5;

/// A place in the arena, to come back to. Opaque on purpose: the number
/// inside is meaningless in any other arena, and adding to it is not a thing
/// anyone should do.
pub const Mark = enum(usize) { _ };

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

/// Over memory the caller owns - a static buffer, a page mapping, a slice of
/// a bigger arena.
pub fn init(buffer: []u8) Arena {
    return .{ .buffer = buffer };
}

/// Over memory taken from `child` once, here, and never again. Pair with
/// `deinit`.
///
/// This is the shape a frame arena is usually built in: one allocation at
/// startup, and no allocator touched for the rest of the run.
pub fn initAlloc(child: Allocator, size: usize) Allocator.Error!Arena {
    return .{ .buffer = try child.alloc(u8, size) };
}

/// Give the buffer back to the allocator `initAlloc` took it from. Not for an
/// arena made with `init`, which does not own its memory.
pub fn deinit(self: *Arena, child: Allocator) void {
    child.free(self.buffer);
    self.* = undefined;
}

pub fn allocator(self: *Arena) Allocator {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

// -------------------------------------------------------------------------
// Giving it back
// -------------------------------------------------------------------------

/// Everything, at once. `high_water` is kept, because it is the answer to
/// "how big should this have been".
pub fn reset(self: *Arena) void {
    if (std.debug.runtime_safety) @memset(self.buffer[0..self.used], poison);
    self.used = 0;
}

/// Where the arena is now.
pub fn mark(self: *const Arena) Mark {
    return @enumFromInt(self.used);
}

/// Back to where `mark` was taken, discarding everything allocated since.
///
/// Restoring to a mark taken after the current position does nothing, so
/// restoring twice is harmless. Restoring to a mark from a *different* arena
/// is not, and there is no way to check for it.
pub fn restore(self: *Arena, m: Mark) void {
    const target = @intFromEnum(m);
    if (target >= self.used) return;
    if (std.debug.runtime_safety) @memset(self.buffer[target..self.used], poison);
    self.used = target;
}

/// A mark and the restore that goes with it:
///
/// ```zig
/// const scratch = arena.scope();
/// defer scratch.end();
/// ```
pub const Scope = struct {
    arena: *Arena,
    at: Mark,

    pub fn end(self: Scope) void {
        self.arena.restore(self.at);
    }
};

pub fn scope(self: *Arena) Scope {
    return .{ .arena = self, .at = self.mark() };
}

// -------------------------------------------------------------------------
// Asking it things
// -------------------------------------------------------------------------

pub inline fn capacity(self: *const Arena) usize {
    return self.buffer.len;
}

pub inline fn remaining(self: *const Arena) usize {
    return self.buffer.len - self.used;
}

/// Did this memory come from here?
pub fn owns(self: *const Arena, memory: []const u8) bool {
    return layout.ownsSlice(self.buffer, memory);
}

/// Is this the allocation that would be undone by freeing it?
///
/// False negatives are possible: an allocation that needed padding in front
/// of it cannot be recognised, because rounding up is not reversible. That
/// costs a missed optimisation and nothing else.
pub fn isLastAllocation(self: *const Arena, memory: []const u8) bool {
    return memory.ptr + memory.len == self.buffer.ptr + self.used;
}

// -------------------------------------------------------------------------
// The allocator
// -------------------------------------------------------------------------

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Arena = @ptrCast(@alignCast(ctx));
    _ = ret_addr;

    const skip = std.mem.alignPointerOffset(self.buffer.ptr + self.used, alignment.toByteUnits()) orelse
        return null;
    const start = self.used + skip;
    const end = start + len;
    if (end > self.buffer.len) return null;

    self.used = end;
    if (end > self.high_water) self.high_water = end;
    return self.buffer.ptr + start;
}

fn resize(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    const self: *Arena = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;
    std.debug.assert(@inComptime() or self.owns(memory));

    if (!self.isLastAllocation(memory)) {
        // Anything in the middle can shrink - the bytes are simply wasted -
        // but it cannot grow, because what follows it is somebody else's.
        return new_len <= memory.len;
    }

    if (new_len <= memory.len) {
        self.used -= memory.len - new_len;
        return true;
    }

    const extra = new_len - memory.len;
    if (self.used + extra > self.buffer.len) return false;
    self.used += extra;
    if (self.used > self.high_water) self.high_water = self.used;
    return true;
}

fn remap(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *Arena = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;
    std.debug.assert(@inComptime() or self.owns(memory));

    // The most recent allocation can be handed back. Anything else stays
    // until the next `reset`, which is the arena's whole bargain.
    if (self.isLastAllocation(memory)) {
        if (std.debug.runtime_safety) @memset(memory, poison);
        self.used -= memory.len;
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "an allocation is a bump" {
    var backing: [1024]u8 = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), arena.used);
    try testing.expectEqual(@as(usize, 1024), arena.capacity());

    const first = try a.alloc(u8, 100);
    try testing.expectEqual(@as(usize, 100), arena.used);
    try testing.expectEqual(@as(usize, 924), arena.remaining());

    const second = try a.alloc(u8, 50);
    try testing.expectEqual(@as(usize, 150), arena.used);

    // Two allocations do not overlap, and both are inside the buffer.
    try testing.expect(arena.owns(first));
    try testing.expect(arena.owns(second));
    try testing.expect(@intFromPtr(second.ptr) >= @intFromPtr(first.ptr) + first.len);
}

test "alignment is honoured, and the padding is counted" {
    var backing: [1024]u8 align(64) = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    // One byte, to push the cursor somewhere awkward.
    _ = try a.alloc(u8, 1);
    try testing.expectEqual(@as(usize, 1), arena.used);

    const aligned = try a.alignedAlloc(u8, .fromByteUnits(64), 8);
    try testing.expect(std.mem.isAligned(@intFromPtr(aligned.ptr), 64));
    // The cursor moved past the padding as well as the allocation.
    try testing.expectEqual(@as(usize, 64 + 8), arena.used);

    // Every alignment the interface can ask for.
    inline for (.{ 1, 2, 4, 8, 16, 32, 64, 128 }) |n| {
        _ = try a.alloc(u8, 1); // knock the cursor off alignment again
        const p = try a.alignedAlloc(u8, .fromByteUnits(n), 3);
        try testing.expect(std.mem.isAligned(@intFromPtr(p.ptr), n));
    }
}

test "a full arena says so rather than overrunning" {
    var backing: [64]u8 = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    _ = try a.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 0), arena.remaining());
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 1));

    // And a request larger than the whole buffer fails without moving
    // anything.
    arena.reset();
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 65));
    try testing.expectEqual(@as(usize, 0), arena.used);
}

test "reset gives everything back, and remembers how much there was" {
    var backing: [1024]u8 = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    _ = try a.alloc(u8, 700);
    try testing.expectEqual(@as(usize, 700), arena.high_water);

    arena.reset();
    try testing.expectEqual(@as(usize, 0), arena.used);
    // The high-water mark survives, because it is the answer to "how big
    // should this buffer be".
    try testing.expectEqual(@as(usize, 700), arena.high_water);

    // A smaller frame does not lower it.
    _ = try a.alloc(u8, 100);
    arena.reset();
    try testing.expectEqual(@as(usize, 700), arena.high_water);

    // A bigger one raises it.
    _ = try a.alloc(u8, 900);
    try testing.expectEqual(@as(usize, 900), arena.high_water);
}

test "mark and restore, nested" {
    var backing: [1024]u8 = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    _ = try a.alloc(u8, 100);
    const outer = arena.mark();

    _ = try a.alloc(u8, 200);
    const inner = arena.mark();

    _ = try a.alloc(u8, 300);
    try testing.expectEqual(@as(usize, 600), arena.used);

    arena.restore(inner);
    try testing.expectEqual(@as(usize, 300), arena.used);

    arena.restore(outer);
    try testing.expectEqual(@as(usize, 100), arena.used);

    // Restoring forwards does nothing, so restoring twice is harmless.
    arena.restore(inner);
    try testing.expectEqual(@as(usize, 100), arena.used);
    arena.restore(outer);
    try testing.expectEqual(@as(usize, 100), arena.used);
}

test "scope restores on the way out" {
    var backing: [1024]u8 = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    _ = try a.alloc(u8, 64);
    const before = arena.used;

    {
        const scratch = arena.scope();
        defer scratch.end();

        _ = try a.alloc(u8, 256);
        _ = try a.alloc(u8, 128);
        try testing.expect(arena.used > before);
    }

    try testing.expectEqual(before, arena.used);

    // And the high-water mark still remembers the peak inside the scope.
    try testing.expectEqual(@as(usize, 64 + 256 + 128), arena.high_water);
}

test "the last allocation can be freed and reused" {
    var backing: [1024]u8 = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    const first = try a.alloc(u8, 100);
    const second = try a.alloc(u8, 100);
    try testing.expectEqual(@as(usize, 200), arena.used);

    // Freeing the most recent one gives the space straight back.
    a.free(second);
    try testing.expectEqual(@as(usize, 100), arena.used);

    // So the next allocation lands in the same place.
    const third = try a.alloc(u8, 100);
    try testing.expectEqual(@intFromPtr(second.ptr), @intFromPtr(third.ptr));

    // Freeing anything else is a no-op, which is the bargain.
    a.free(first);
    try testing.expectEqual(@as(usize, 200), arena.used);
}

test "a loop that frees in order never grows" {
    // The stack-allocator case: allocate and free in reverse order, and the
    // arena stays where it started however long the loop runs.
    var backing: [4096]u8 = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    for (0..10_000) |i| {
        const outer = try a.alloc(u8, 64);
        const inner = try a.alloc(u8, 128);
        inner[0] = @truncate(i);
        a.free(inner);
        a.free(outer);
    }
    try testing.expectEqual(@as(usize, 0), arena.used);
    try testing.expectEqual(@as(usize, 192), arena.high_water);
}

test "resize grows and shrinks the last allocation in place" {
    var backing: [1024]u8 = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    var list: std.ArrayList(u32) = .empty;
    // An ArrayList growing into an arena reuses the same memory each time,
    // because every growth is of the last allocation.
    for (0..100) |i| try list.append(a, @intCast(i));
    try testing.expectEqual(@as(usize, 100), list.items.len);
    for (list.items, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);

    // 100 u32s is 400 bytes; the arena holds a little more than that, not a
    // hundred separate copies of a growing buffer.
    try testing.expect(arena.used < 1024);

    // Shrinking the last allocation hands the tail back.
    const before = arena.used;
    _ = a.resize(list.allocatedSlice(), 10);
    try testing.expect(arena.used < before);
}

test "an allocation in the middle can shrink but not grow" {
    var backing: [1024]u8 = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    const middle = try a.alloc(u8, 100);
    _ = try a.alloc(u8, 100); // something after it

    try testing.expect(!a.resize(middle, 200));
    try testing.expect(a.resize(middle, 50));
    // Shrinking in the middle wastes the bytes rather than reclaiming them.
    try testing.expectEqual(@as(usize, 200), arena.used);
}

test "reset poisons what it takes back, in safe builds" {
    if (!std.debug.runtime_safety) return error.SkipZigTest;

    var backing: [256]u8 = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    const written = try a.alloc(u8, 64);
    @memset(written, 0x11);

    arena.reset();
    // The old contents are gone, so a pointer kept across a reset reads as
    // obvious rubbish rather than as plausible stale data.
    for (backing[0..64]) |byte| try testing.expectEqual(poison, byte);

    // Restore poisons too.
    _ = try a.alloc(u8, 32);
    const m = arena.mark();
    const later = try a.alloc(u8, 32);
    @memset(later, 0x22);
    arena.restore(m);
    for (backing[32..64]) |byte| try testing.expectEqual(poison, byte);
}

test "initAlloc takes its buffer once" {
    var arena: Arena = try .initAlloc(testing.allocator, 4096);
    defer arena.deinit(testing.allocator);

    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 4096), arena.capacity());

    const items = try a.alloc(u64, 100);
    try testing.expectEqual(@as(usize, 100), items.len);
    try testing.expect(arena.owns(std.mem.sliceAsBytes(items)));
}

test "it holds the types a caller actually allocates" {
    var backing: [4096]u8 align(16) = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    const Vertex = extern struct { x: f32, y: f32, z: f32 };
    const vertices = try a.alloc(Vertex, 64);
    try testing.expectEqual(@as(usize, 64), vertices.len);
    vertices[0] = .{ .x = 1, .y = 2, .z = 3 };
    try testing.expectEqual(@as(f32, 2), vertices[0].y);

    const one = try a.create(u64);
    one.* = 0xDEADBEEF;
    try testing.expectEqual(@as(u64, 0xDEADBEEF), one.*);

    const text = try a.dupe(u8, "a copy that lives until the frame ends");
    try testing.expectEqualStrings("a copy that lives until the frame ends", text);

    const formatted = try std.fmt.allocPrint(a, "{d} vertices", .{vertices.len});
    try testing.expectEqualStrings("64 vertices", formatted);
}

test "a frame, several times over" {
    // What this is actually for: the same buffer, reused every frame, with
    // nothing allocated after startup.
    var arena: Arena = try .initAlloc(testing.allocator, 64 * 1024);
    defer arena.deinit(testing.allocator);
    const a = arena.allocator();

    for (0..600) |frame| {
        defer arena.reset();

        const visible = try a.alloc(u32, 200 + frame % 100);
        for (visible, 0..) |*id, i| id.* = @intCast(i);

        const commands = try std.fmt.allocPrint(a, "draw {d} things", .{visible.len});
        try testing.expect(commands.len > 0);
    }

    try testing.expectEqual(@as(usize, 0), arena.used);
    // And it never came close to the buffer it was given.
    try testing.expect(arena.high_water < 64 * 1024);
}
