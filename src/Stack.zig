// SPDX-License-Identifier: BSL-1.0

//! One buffer, handed out from both ends at once.
//!
//! Two bump allocators facing each other. The front grows upwards, the back
//! grows downwards, and they share whatever is between them - so neither has
//! to be given a budget, and the only number that matters is whether they have
//! met.
//!
//! That is the oldest layout in games, and it is still the right one whenever
//! memory divides into two lifetimes rather than many:
//!
//!   the back    what is loaded once and lives until the level changes -
//!               meshes, textures, the level itself
//!   the front   what lasts one frame - visible lists, command buffers,
//!               the strings a debug overlay builds
//!
//! Reset the front every frame and the back never; when the level changes,
//! reset both. Neither end has to guess how much the other will want, which
//! is the thing two separate arenas cannot do.
//!
//! Each end is an `Arena` in all but name: same bump, same `mark` and
//! `restore`, same opportunistic reclaim on `free`. What this adds is that
//! they share one buffer. One difference is worth knowing: freeing a back
//! allocation reclaims the allocation but not any alignment padding in front
//! of it, because rounding down is not reversible either. In a loop that costs
//! the padding once rather than once per turn, and `restore` recovers it.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const layout = @import("layout.zig");

const Stack = @This();

/// The memory both ends share. Not owned unless `initAlloc` made it.
buffer: []u8,

/// Bytes taken from the front, counting up from `buffer[0]`.
front_used: usize = 0,

/// Bytes taken from the back, counting down from the end of `buffer`.
back_used: usize = 0,

front_high_water: usize = 0,
back_high_water: usize = 0,

const poison: u8 = 0x5A;

/// Which end. Passed at comptime, so each end gets its own vtable and no
/// branch survives into the allocation path.
pub const Side = enum { front, back };

/// A place at one end, to come back to. Meaningless at the other end and in
/// any other stack.
pub const Mark = enum(usize) { _ };

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

pub fn init(buffer: []u8) Stack {
    return .{ .buffer = buffer };
}

/// Over memory taken from `child` once. Pair with `deinit`.
pub fn initAlloc(child: Allocator, size: usize) Allocator.Error!Stack {
    return .{ .buffer = try child.alloc(u8, size) };
}

pub fn deinit(self: *Stack, child: Allocator) void {
    child.free(self.buffer);
    self.* = undefined;
}

/// The allocator for one end. `stack.allocator(.front)` for this frame,
/// `stack.allocator(.back)` for the level.
pub fn allocator(self: *Stack, comptime side: Side) Allocator {
    return .{ .ptr = self, .vtable = vtableFor(side) };
}

// -------------------------------------------------------------------------
// Giving it back
// -------------------------------------------------------------------------

/// Everything at one end.
pub fn reset(self: *Stack, side: Side) void {
    self.restoreTo(side, 0);
}

/// Both ends: what happens when a level unloads.
pub fn resetAll(self: *Stack) void {
    self.reset(.front);
    self.reset(.back);
}

pub fn mark(self: *const Stack, side: Side) Mark {
    return @enumFromInt(self.usedBy(side));
}

pub fn restore(self: *Stack, side: Side, m: Mark) void {
    self.restoreTo(side, @intFromEnum(m));
}

fn restoreTo(self: *Stack, side: Side, target: usize) void {
    switch (side) {
        .front => {
            if (target >= self.front_used) return;
            if (std.debug.runtime_safety) {
                @memset(self.buffer[target..self.front_used], poison);
            }
            self.front_used = target;
        },
        .back => {
            if (target >= self.back_used) return;
            const len = self.buffer.len;
            if (std.debug.runtime_safety) {
                @memset(self.buffer[len - self.back_used .. len - target], poison);
            }
            self.back_used = target;
        },
    }
}

/// A mark and the restore that goes with it.
pub const Scope = struct {
    stack: *Stack,
    side: Side,
    at: Mark,

    pub fn end(self: Scope) void {
        self.stack.restore(self.side, self.at);
    }
};

pub fn scope(self: *Stack, side: Side) Scope {
    return .{ .stack = self, .side = side, .at = self.mark(side) };
}

// -------------------------------------------------------------------------
// Asking it things
// -------------------------------------------------------------------------

pub inline fn capacity(self: *const Stack) usize {
    return self.buffer.len;
}

pub inline fn usedBy(self: *const Stack, side: Side) usize {
    return switch (side) {
        .front => self.front_used,
        .back => self.back_used,
    };
}

pub inline fn highWater(self: *const Stack, side: Side) usize {
    return switch (side) {
        .front => self.front_high_water,
        .back => self.back_high_water,
    };
}

/// How much is still between the two ends. When this reaches zero they have
/// met, and the next allocation at either end fails.
pub inline fn remaining(self: *const Stack) usize {
    return self.buffer.len - self.front_used - self.back_used;
}

pub fn owns(self: *const Stack, memory: []const u8) bool {
    return layout.ownsSlice(self.buffer, memory);
}

/// Which end an allocation came from, or null if it did not come from here.
pub fn sideOf(self: *const Stack, memory: []const u8) ?Side {
    if (!self.owns(memory)) return null;
    const offset = @intFromPtr(memory.ptr) - @intFromPtr(self.buffer.ptr);
    return if (offset < self.front_used) .front else .back;
}

// -------------------------------------------------------------------------
// The allocators
// -------------------------------------------------------------------------

fn vtableFor(comptime side: Side) *const Allocator.VTable {
    return &struct {
        const table: Allocator.VTable = .{
            .alloc = struct {
                fn f(ctx: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
                    _ = ra;
                    return allocAt(@ptrCast(@alignCast(ctx)), side, len, a);
                }
            }.f,
            .resize = struct {
                fn f(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) bool {
                    _ = a;
                    _ = ra;
                    return resizeAt(@ptrCast(@alignCast(ctx)), side, m, n);
                }
            }.f,
            .remap = struct {
                fn f(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) ?[*]u8 {
                    _ = a;
                    _ = ra;
                    return if (resizeAt(@ptrCast(@alignCast(ctx)), side, m, n)) m.ptr else null;
                }
            }.f,
            .free = struct {
                fn f(ctx: *anyopaque, m: []u8, a: Alignment, ra: usize) void {
                    _ = a;
                    _ = ra;
                    freeAt(@ptrCast(@alignCast(ctx)), side, m);
                }
            }.f,
        };
    }.table;
}

fn allocAt(self: *Stack, comptime side: Side, len: usize, alignment: Alignment) ?[*]u8 {
    const base = @intFromPtr(self.buffer.ptr);

    switch (side) {
        .front => {
            const start = alignment.forward(base + self.front_used) - base;
            const end = start + len;
            // The two ends must not cross. `back_used` is measured from the
            // far end, so this is the only bound either of them needs.
            if (end + self.back_used > self.buffer.len) return null;
            self.front_used = end;
            if (end > self.front_high_water) self.front_high_water = end;
            return self.buffer.ptr + start;
        },
        .back => {
            // The back grows downwards, so the block is placed by rounding
            // its *start* down rather than up.
            const top = base + self.buffer.len - self.back_used;
            if (len > top - base) return null;
            const start = alignment.backward(top - len);
            if (start < base + self.front_used) return null;
            self.back_used = base + self.buffer.len - start;
            if (self.back_used > self.back_high_water) self.back_high_water = self.back_used;
            return @ptrFromInt(start);
        },
    }
}

fn isLastAt(self: *const Stack, comptime side: Side, memory: []const u8) bool {
    return switch (side) {
        .front => memory.ptr + memory.len == self.buffer.ptr + self.front_used,
        .back => memory.ptr == self.buffer.ptr + self.buffer.len - self.back_used,
    };
}

fn resizeAt(self: *Stack, comptime side: Side, memory: []u8, new_len: usize) bool {
    std.debug.assert(@inComptime() or self.owns(memory));

    // Only the newest allocation at this end can move, and the back end
    // cannot grow in place at all: growing downwards would move the pointer,
    // which `resize` is not allowed to do.
    if (!self.isLastAt(side, memory)) return new_len <= memory.len;

    switch (side) {
        .front => {
            if (new_len <= memory.len) {
                self.front_used -= memory.len - new_len;
                return true;
            }
            const extra = new_len - memory.len;
            if (self.front_used + extra + self.back_used > self.buffer.len) return false;
            self.front_used += extra;
            if (self.front_used > self.front_high_water) {
                self.front_high_water = self.front_used;
            }
            return true;
        },
        .back => return new_len <= memory.len,
    }
}

fn freeAt(self: *Stack, comptime side: Side, memory: []u8) void {
    std.debug.assert(@inComptime() or self.owns(memory));
    if (!self.isLastAt(side, memory)) return;

    if (std.debug.runtime_safety) @memset(memory, poison);
    switch (side) {
        .front => self.front_used -= memory.len,
        .back => {
            // Back to just past the end of this block. Any padding that was
            // skipped in front of it stays counted, because rounding down is
            // not reversible - see the note at the top.
            const base = @intFromPtr(self.buffer.ptr);
            const after = @intFromPtr(memory.ptr) + memory.len;
            self.back_used = base + self.buffer.len - after;
        },
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the two ends grow towards each other" {
    var backing: [1024]u8 = undefined;
    var stack: Stack = .init(&backing);

    const front = stack.allocator(.front);
    const back = stack.allocator(.back);

    const a = try front.alloc(u8, 100);
    const b = try back.alloc(u8, 200);

    try testing.expectEqual(@as(usize, 100), stack.usedBy(.front));
    try testing.expectEqual(@as(usize, 200), stack.usedBy(.back));
    try testing.expectEqual(@as(usize, 724), stack.remaining());

    // The front block is at the bottom, the back block at the top.
    try testing.expectEqual(@intFromPtr(backing[0..].ptr), @intFromPtr(a.ptr));
    try testing.expectEqual(
        @intFromPtr(backing[0..].ptr) + 1024 - 200,
        @intFromPtr(b.ptr),
    );

    // And they do not overlap.
    try testing.expect(@intFromPtr(a.ptr) + a.len <= @intFromPtr(b.ptr));
    try testing.expectEqual(Side.front, stack.sideOf(a).?);
    try testing.expectEqual(Side.back, stack.sideOf(b).?);
}

test "neither end needs a budget: they share what is left" {
    var backing: [1000]u8 = undefined;
    var stack: Stack = .init(&backing);
    const front = stack.allocator(.front);
    const back = stack.allocator(.back);

    // The back takes most of it, and the front is not told in advance.
    _ = try back.alloc(u8, 900);
    try testing.expectEqual(@as(usize, 100), stack.remaining());

    _ = try front.alloc(u8, 100);
    try testing.expectEqual(@as(usize, 0), stack.remaining());

    // Now neither end can take another byte.
    try testing.expectError(error.OutOfMemory, front.alloc(u8, 1));
    try testing.expectError(error.OutOfMemory, back.alloc(u8, 1));

    // Giving one end back lets the other have it.
    stack.reset(.front);
    _ = try back.alloc(u8, 50);
    try testing.expectEqual(@as(usize, 950), stack.usedBy(.back));
}

test "they meet exactly, and not one byte past" {
    var backing: [256]u8 = undefined;
    var stack: Stack = .init(&backing);
    const front = stack.allocator(.front);
    const back = stack.allocator(.back);

    _ = try front.alloc(u8, 128);
    _ = try back.alloc(u8, 128);
    try testing.expectEqual(@as(usize, 0), stack.remaining());
    try testing.expectError(error.OutOfMemory, front.alloc(u8, 1));
    try testing.expectError(error.OutOfMemory, back.alloc(u8, 1));
}

test "alignment at both ends" {
    var backing: [2048]u8 align(64) = undefined;
    var stack: Stack = .init(&backing);
    const front = stack.allocator(.front);
    const back = stack.allocator(.back);

    inline for (.{ 1, 2, 4, 8, 16, 32, 64, 128 }) |n| {
        _ = try front.alloc(u8, 1); // knock both cursors off alignment
        _ = try back.alloc(u8, 1);

        const f = try front.alignedAlloc(u8, .fromByteUnits(n), 3);
        const b = try back.alignedAlloc(u8, .fromByteUnits(n), 3);

        try testing.expect(std.mem.isAligned(@intFromPtr(f.ptr), n));
        try testing.expect(std.mem.isAligned(@intFromPtr(b.ptr), n));
        try testing.expect(@intFromPtr(f.ptr) + f.len <= @intFromPtr(b.ptr));
    }
}

test "each end resets on its own" {
    var backing: [1024]u8 = undefined;
    var stack: Stack = .init(&backing);
    const front = stack.allocator(.front);
    const back = stack.allocator(.back);

    _ = try front.alloc(u8, 100);
    _ = try back.alloc(u8, 200);

    stack.reset(.front);
    try testing.expectEqual(@as(usize, 0), stack.usedBy(.front));
    // The level data is untouched.
    try testing.expectEqual(@as(usize, 200), stack.usedBy(.back));

    stack.resetAll();
    try testing.expectEqual(@as(usize, 0), stack.usedBy(.back));
    try testing.expectEqual(@as(usize, 1024), stack.remaining());

    // High-water marks survive both, because they are what sizes the buffer.
    try testing.expectEqual(@as(usize, 100), stack.highWater(.front));
    try testing.expectEqual(@as(usize, 200), stack.highWater(.back));
}

test "marks and scopes, at either end" {
    var backing: [1024]u8 = undefined;
    var stack: Stack = .init(&backing);
    const front = stack.allocator(.front);
    const back = stack.allocator(.back);

    _ = try front.alloc(u8, 50);
    _ = try back.alloc(u8, 50);

    const f = stack.mark(.front);
    const b = stack.mark(.back);

    _ = try front.alloc(u8, 200);
    _ = try back.alloc(u8, 200);

    stack.restore(.front, f);
    try testing.expectEqual(@as(usize, 50), stack.usedBy(.front));
    try testing.expectEqual(@as(usize, 250), stack.usedBy(.back));

    stack.restore(.back, b);
    try testing.expectEqual(@as(usize, 50), stack.usedBy(.back));

    {
        const s = stack.scope(.front);
        defer s.end();
        _ = try front.alloc(u8, 300);
        try testing.expectEqual(@as(usize, 350), stack.usedBy(.front));
    }
    try testing.expectEqual(@as(usize, 50), stack.usedBy(.front));
}

test "freeing in order works at either end; out of order does nothing" {
    var backing: [1024]u8 = undefined;
    var stack: Stack = .init(&backing);
    const front = stack.allocator(.front);
    const back = stack.allocator(.back);

    const f1 = try front.alloc(u8, 100);
    const f2 = try front.alloc(u8, 100);

    // Out of order: `f1` is not the newest, so nothing happens. That is the
    // arena bargain, and the reason `mark` and `restore` exist.
    front.free(f1);
    try testing.expectEqual(@as(usize, 200), stack.usedBy(.front));

    // In order, each one comes back as it is released - which makes this a
    // stack allocator and not merely a bump allocator.
    front.free(f2);
    try testing.expectEqual(@as(usize, 100), stack.usedBy(.front));
    front.free(f1);
    try testing.expectEqual(@as(usize, 0), stack.usedBy(.front));

    // The back end behaves the same way, downwards.
    const b1 = try back.alloc(u8, 100);
    const b2 = try back.alloc(u8, 100);

    back.free(b1);
    try testing.expectEqual(@as(usize, 200), stack.usedBy(.back));

    back.free(b2);
    try testing.expectEqual(@as(usize, 100), stack.usedBy(.back));
    back.free(b1);
    try testing.expectEqual(@as(usize, 0), stack.usedBy(.back));
}

test "a LIFO loop at the back settles rather than creeping" {
    // Freeing a back allocation does not recover the padding in front of it,
    // so the first turn of the loop loses it - and no turn after that does.
    var backing: [4096]u8 align(64) = undefined;
    var stack: Stack = .init(&backing);
    const back = stack.allocator(.back);

    _ = try back.alignedAlloc(u8, .fromByteUnits(64), 10);
    const after_first = stack.usedBy(.back);
    stack.reset(.back);

    var settled: usize = 0;
    for (0..1000) |i| {
        const p = try back.alignedAlloc(u8, .fromByteUnits(64), 10);
        back.free(p);
        if (i == 1) settled = stack.usedBy(.back);
        if (i > 1) try testing.expectEqual(settled, stack.usedBy(.back));
    }
    // It settles at a few bytes, not at a thousand allocations' worth.
    try testing.expect(stack.usedBy(.back) < after_first + 64);
    try testing.expect(stack.usedBy(.back) < 128);

    // And a restore recovers all of it.
    stack.reset(.back);
    try testing.expectEqual(@as(usize, 0), stack.usedBy(.back));
}

test "the front grows in place, so an ArrayList is cheap there" {
    var backing: [4096]u8 = undefined;
    var stack: Stack = .init(&backing);
    const front = stack.allocator(.front);

    var list: std.ArrayList(u32) = .empty;
    for (0..200) |i| try list.append(front, @intCast(i));

    try testing.expectEqual(@as(usize, 200), list.items.len);
    for (list.items, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);
    // 200 u32s is 800 bytes, and the front holds not much more than that.
    try testing.expect(stack.usedBy(.front) < 2048);
}

test "a level, and the frames inside it" {
    // What this is actually for.
    var stack: Stack = try .initAlloc(testing.allocator, 64 * 1024);
    defer stack.deinit(testing.allocator);

    const level = stack.allocator(.back);
    const frame = stack.allocator(.front);

    // Loaded once.
    const mesh = try level.alloc(f32, 900);
    const texture = try level.alloc(u8, 4096);
    @memset(mesh, 1.5);
    @memset(texture, 0xFF);
    const level_used = stack.usedBy(.back);

    // And then six hundred frames on top of it.
    for (0..600) |i| {
        defer stack.reset(.front);

        const visible = try frame.alloc(u32, 100 + i % 50);
        for (visible, 0..) |*id, n| id.* = @intCast(n);
        const line = try std.fmt.allocPrint(frame, "frame {d}: {d} visible", .{ i, visible.len });
        try testing.expect(line.len > 0);

        // The level data is still there, and still correct.
        try testing.expectEqual(@as(f32, 1.5), mesh[450]);
        try testing.expectEqual(@as(u8, 0xFF), texture[2000]);
    }

    try testing.expectEqual(level_used, stack.usedBy(.back));
    try testing.expectEqual(@as(usize, 0), stack.usedBy(.front));
    try testing.expect(stack.highWater(.front) > 0);
}

test "sideOf and owns say what is theirs" {
    var backing: [512]u8 = undefined;
    var stack: Stack = .init(&backing);
    const front = stack.allocator(.front);
    const back = stack.allocator(.back);

    const f = try front.alloc(u8, 64);
    const b = try back.alloc(u8, 64);

    try testing.expect(stack.owns(f));
    try testing.expect(stack.owns(b));
    try testing.expectEqual(Side.front, stack.sideOf(f).?);
    try testing.expectEqual(Side.back, stack.sideOf(b).?);

    var elsewhere: [8]u8 = undefined;
    try testing.expect(!stack.owns(&elsewhere));
    try testing.expect(stack.sideOf(&elsewhere) == null);
    try testing.expectEqual(@as(usize, 512), stack.capacity());
}

test "a request larger than the whole buffer fails without moving anything" {
    var backing: [128]u8 = undefined;
    var stack: Stack = .init(&backing);
    const front = stack.allocator(.front);
    const back = stack.allocator(.back);

    try testing.expectError(error.OutOfMemory, front.alloc(u8, 129));
    try testing.expectError(error.OutOfMemory, back.alloc(u8, 129));
    try testing.expectEqual(@as(usize, 0), stack.usedBy(.front));
    try testing.expectEqual(@as(usize, 0), stack.usedBy(.back));
    try testing.expectEqual(@as(usize, 128), stack.remaining());
}
