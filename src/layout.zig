// SPDX-License-Identifier: BSL-1.0

//! The arithmetic every allocator in this library is made of, and the one
//! piece of formatting.
//!
//! Alignment is rounding, and rounding a pointer up is the single operation
//! that turns a byte buffer into a place values can live. `std.mem` has most
//! of this; what it does not have is the shape these want to be called in -
//! `padding(address, 16)` rather than `alignForward(address, 16) - address` -
//! and a way to print a number of bytes that a person can read.

const std = @import("std");
const testing = std.testing;

/// The alignment type the `Allocator` interface speaks in: a power of two,
/// stored as its base-two logarithm. Re-exported so that a caller writing an
/// allocator against this library does not have to reach into `std.mem`.
pub const Alignment = std.mem.Alignment;

/// The alignment every allocator here rounds to when nothing stricter is
/// asked for. Enough for a `usize`, a pointer, and the intrusive nodes
/// `FreeList` threads through free memory.
pub const default: Alignment = .of(usize);

// -------------------------------------------------------------------------
// Rounding
// -------------------------------------------------------------------------

/// `value`, rounded up to the next multiple of `alignment`.
pub inline fn forward(value: usize, alignment: Alignment) usize {
    return alignment.forward(value);
}

/// `value`, rounded down.
pub inline fn backward(value: usize, alignment: Alignment) usize {
    return alignment.backward(value);
}

/// Is `value` already a multiple of `alignment`?
pub inline fn isAligned(value: usize, alignment: Alignment) bool {
    return alignment.check(value);
}

/// How many bytes have to be skipped at `value` to reach the next multiple of
/// `alignment`. Zero where it is already there.
pub inline fn padding(value: usize, alignment: Alignment) usize {
    return alignment.forward(value) - value;
}

/// The same, for a pointer.
pub inline fn paddingPtr(ptr: [*]const u8, alignment: Alignment) usize {
    return padding(@intFromPtr(ptr), alignment);
}

/// The stricter of two alignments - which is what an allocation needs when it
/// has to satisfy both a caller's request and an allocator's own bookkeeping.
pub inline fn stricter(a: Alignment, b: Alignment) Alignment {
    return a.max(b);
}

/// The alignment as a number of bytes, for arithmetic and for printing.
pub inline fn bytes(alignment: Alignment) usize {
    return alignment.toByteUnits();
}

// -------------------------------------------------------------------------
// Slices
// -------------------------------------------------------------------------

/// Is `ptr` inside `region`? The question an allocator asks before it agrees
/// that a pointer is one of its own.
pub fn owns(region: []const u8, ptr: [*]const u8) bool {
    const start = @intFromPtr(region.ptr);
    const address = @intFromPtr(ptr);
    // The one-past-the-end address belongs to the next region, not this one -
    // except that an empty allocation at the end is still legitimately ours,
    // which is why this is `<=` rather than `<` in `ownsSlice` below.
    return address >= start and address < start + region.len;
}

/// Is all of `slice` inside `region`?
pub fn ownsSlice(region: []const u8, slice: []const u8) bool {
    const start = @intFromPtr(region.ptr);
    const address = @intFromPtr(slice.ptr);
    return address >= start and address + slice.len <= start + region.len;
}

/// `buffer` with its front trimmed off until it starts on `alignment`, or
/// null where trimming that much would leave nothing.
///
/// This is what an allocator does to the buffer it was handed before it uses
/// any of it, so that every offset inside stays aligned afterwards.
pub fn alignSlice(buffer: []u8, alignment: Alignment) ?[]u8 {
    const skip = paddingPtr(buffer.ptr, alignment);
    if (skip >= buffer.len) return null;
    return buffer[skip..];
}

// -------------------------------------------------------------------------
// Printing
// -------------------------------------------------------------------------

/// A number of bytes, printed the way a person reads one.
///
/// `340123456` is a number you have to count the digits of; `324.4 MiB` is a
/// number you can act on. Units are binary - a kibibyte is 1024 bytes -
/// because that is what an allocator is actually counting.
pub const Size = struct {
    bytes: usize,

    pub inline fn init(n: usize) Size {
        return .{ .bytes = n };
    }

    pub fn format(self: Size, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };

        if (self.bytes < 1024) {
            try w.print("{d} B", .{self.bytes});
            return;
        }

        var value: f64 = @floatFromInt(self.bytes);
        var unit: usize = 0;
        while (value >= 1024 and unit + 1 < units.len) : (unit += 1) {
            value /= 1024;
        }
        try w.print("{d:.1} {s}", .{ value, units[unit] });
    }
};

/// Shorthand, so a call site reads `{f}` with `size(n)` in it.
pub inline fn size(n: usize) Size {
    return .{ .bytes = n };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "rounding up and down" {
    const sixteen: Alignment = .fromByteUnits(16);

    try testing.expectEqual(@as(usize, 0), forward(0, sixteen));
    try testing.expectEqual(@as(usize, 16), forward(1, sixteen));
    try testing.expectEqual(@as(usize, 16), forward(16, sixteen));
    try testing.expectEqual(@as(usize, 32), forward(17, sixteen));

    try testing.expectEqual(@as(usize, 0), backward(15, sixteen));
    try testing.expectEqual(@as(usize, 16), backward(16, sixteen));
    try testing.expectEqual(@as(usize, 16), backward(31, sixteen));

    // An alignment of one rounds nothing.
    const one: Alignment = .fromByteUnits(1);
    for ([_]usize{ 0, 1, 7, 1000 }) |n| {
        try testing.expectEqual(n, forward(n, one));
        try testing.expectEqual(n, backward(n, one));
        try testing.expectEqual(@as(usize, 0), padding(n, one));
    }
}

test "padding is the gap rounding would close" {
    const eight: Alignment = .fromByteUnits(8);
    try testing.expectEqual(@as(usize, 0), padding(0, eight));
    try testing.expectEqual(@as(usize, 7), padding(1, eight));
    try testing.expectEqual(@as(usize, 1), padding(7, eight));
    try testing.expectEqual(@as(usize, 0), padding(8, eight));

    // Which is the identity it is defined by, at every alignment.
    inline for (.{ 1, 2, 4, 8, 16, 64, 4096 }) |n| {
        const a: Alignment = .fromByteUnits(n);
        var value: usize = 0;
        while (value < 200) : (value += 1) {
            try testing.expectEqual(forward(value, a), value + padding(value, a));
            try testing.expect(isAligned(forward(value, a), a));
        }
    }
}

test "isAligned" {
    const sixty_four: Alignment = .fromByteUnits(64);
    try testing.expect(isAligned(0, sixty_four));
    try testing.expect(isAligned(128, sixty_four));
    try testing.expect(!isAligned(1, sixty_four));
    try testing.expect(!isAligned(63, sixty_four));
}

test "stricter takes the larger of two" {
    const four: Alignment = .fromByteUnits(4);
    const sixteen: Alignment = .fromByteUnits(16);
    try testing.expectEqual(sixteen, stricter(four, sixteen));
    try testing.expectEqual(sixteen, stricter(sixteen, four));
    try testing.expectEqual(four, stricter(four, four));

    try testing.expectEqual(@as(usize, 16), bytes(sixteen));
    try testing.expectEqual(@as(usize, 1), bytes(.fromByteUnits(1)));
}

test "owns" {
    var buffer: [64]u8 = undefined;
    const region: []u8 = &buffer;

    try testing.expect(owns(region, region.ptr));
    try testing.expect(owns(region, region.ptr + 63));
    // One past the end is the next region's business.
    try testing.expect(!owns(region, region.ptr + 64));

    try testing.expect(ownsSlice(region, region[0..64]));
    try testing.expect(ownsSlice(region, region[10..20]));
    // A slice that runs off the end is not held.
    try testing.expect(!ownsSlice(region, region.ptr[0..65]));

    var other: [8]u8 = undefined;
    try testing.expect(!owns(region, &other));
    try testing.expect(!ownsSlice(region, &other));
}

test "alignSlice trims the front" {
    var raw: [64]u8 align(64) = undefined;

    // Already aligned: nothing is trimmed.
    const sixteen: Alignment = .fromByteUnits(16);
    const whole = alignSlice(&raw, sixteen).?;
    try testing.expectEqual(@as(usize, 64), whole.len);

    // Starting one byte in, fifteen bytes go.
    const offset = alignSlice(raw[1..], sixteen).?;
    try testing.expectEqual(@as(usize, 48), offset.len);
    try testing.expect(isAligned(@intFromPtr(offset.ptr), sixteen));

    // A buffer too small to align at all has nothing to give.
    try testing.expect(alignSlice(raw[1..8], sixteen) == null);
    try testing.expect(alignSlice(raw[0..0], sixteen) == null);
}

test "sizes are printed the way a person reads them" {
    var buf: [64]u8 = undefined;

    const cases = [_]struct { n: usize, text: []const u8 }{
        .{ .n = 0, .text = "0 B" },
        .{ .n = 1, .text = "1 B" },
        .{ .n = 1023, .text = "1023 B" },
        .{ .n = 1024, .text = "1.0 KiB" },
        .{ .n = 1536, .text = "1.5 KiB" },
        .{ .n = 1024 * 1024, .text = "1.0 MiB" },
        .{ .n = 340_123_456, .text = "324.4 MiB" },
        .{ .n = 1024 * 1024 * 1024, .text = "1.0 GiB" },
    };

    for (cases) |c| {
        var w = std.Io.Writer.fixed(&buf);
        try w.print("{f}", .{size(c.n)});
        try testing.expectEqualStrings(c.text, w.buffered());
    }
}

test "the default alignment holds a pointer" {
    try testing.expect(bytes(default) >= @sizeOf(usize));
    try testing.expect(isAligned(bytes(default), .of(*anyopaque)));
}
