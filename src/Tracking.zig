// SPDX-License-Identifier: BSL-1.0

//! An allocator that wraps another one and keeps a running total per
//! category.
//!
//! The question a debug allocator usually answers is "did anything leak". The
//! question an engine asks first is different: **where did the memory go?**
//! Six hundred megabytes resident is not a bug report, and a list of eleven
//! thousand live allocations is not one either. `textures 412 MiB, meshes
//! 96 MiB, audio 38 MiB` is - you can act on that before you have found a
//! single line of code.
//!
//! So the categories are yours, as an enum, and each one gets its own
//! `Allocator`:
//!
//! ```zig
//! const Tag = enum { textures, meshes, audio, scratch };
//! var tracker: Tracking(Tag) = .init(gpa);
//!
//! const textures = tracker.allocator(.textures);
//! const meshes = tracker.allocator(.meshes);
//! ```
//!
//! The tag is a comptime argument, so each one has its own vtable and nothing
//! is looked up at run time. Pass those allocators down as ordinary
//! `Allocator`s and everything below is counted without knowing it is.
//!
//! **A budget can be set per category.** `setLimit(.textures, 512 << 20)`
//! makes the texture allocator start returning `error.OutOfMemory` at half a
//! gigabyte rather than at the point the machine gives out. That turns "it
//! ran out eventually, on someone else's computer" into a failure that
//! happens on yours, in the subsystem responsible.
//!
//! **Free with the allocator you allocated from.** The tag of a free is the
//! tag of the allocator it went through, not of the allocation, and there is
//! nowhere to keep the latter without a header on every block. Freeing a
//! texture through the mesh allocator is caught by an assertion in safe
//! builds and silently miscounts in a release one.
//!
//! This does not detect a use-after-free or a buffer overrun; that is what
//! `std.heap.DebugAllocator` is for, and this wraps it happily. What it adds
//! is the accounting that one does not do.
//!
//! One thread at a time. Two threads sharing a tag will race on its counters.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const layout = @import("layout.zig");

/// What is known about one category.
pub const Counters = struct {
    /// Bytes handed out and not yet given back. What leaked, at shutdown.
    live_bytes: usize = 0,
    /// Allocations outstanding.
    live_count: usize = 0,
    /// The most `live_bytes` has ever been - what to size a budget by.
    peak_bytes: usize = 0,
    /// Everything ever asked for, including what has been freed. A large
    /// total against a small peak is churn, which an arena would fix.
    total_bytes: usize = 0,
    total_count: usize = 0,
    /// Requests that failed - because the child allocator had nothing left,
    /// or because this category is over its limit.
    refused_count: usize = 0,
    /// The budget. Zero means none.
    limit: usize = 0,

    pub fn isEmpty(self: Counters) bool {
        return self.live_count == 0 and self.live_bytes == 0;
    }
};

/// A tracker over the categories named by `Tag`, which must be an enum.
pub fn Tracking(comptime Tag: type) type {
    const info = switch (@typeInfo(Tag)) {
        .@"enum" => |e| e,
        else => @compileError(
            "fluxion-mem: Tracking(" ++ @typeName(Tag) ++ ") - the categories " ++
                "have to be an enum, so that each one can have a name to print.",
        ),
    };

    return struct {
        const Self = @This();

        /// How many categories there are.
        pub const count: usize = info.fields.len;

        /// Every category, in the order they were declared - which is the
        /// order `report` prints them in.
        pub const tags: []const Tag = std.enums.values(Tag);

        child: Allocator,
        counters: [count]Counters = @splat(.{}),

        /// Where in `counters` a tag lives. Not `@intFromEnum`, which is the
        /// declared value and need not be a dense index.
        fn slot(comptime tag: Tag) usize {
            comptime {
                for (info.fields, 0..) |field, i| {
                    if (field.value == @intFromEnum(tag)) return i;
                }
                unreachable;
            }
        }

        fn slotOf(tag: Tag) usize {
            inline for (info.fields, 0..) |field, i| {
                if (field.value == @intFromEnum(tag)) return i;
            }
            unreachable;
        }

        // -----------------------------------------------------------------
        // Making one
        // -----------------------------------------------------------------

        pub fn init(child: Allocator) Self {
            return .{ .child = child };
        }

        /// The allocator for one category. Hand this down; everything under
        /// it is counted against `tag`.
        pub fn allocator(self: *Self, comptime tag: Tag) Allocator {
            return .{ .ptr = self, .vtable = vtableFor(tag) };
        }

        // -----------------------------------------------------------------
        // Budgets
        // -----------------------------------------------------------------

        /// Refuse allocations for `tag` beyond `bytes`. Zero removes the
        /// limit.
        ///
        /// Setting a limit below what is already live does not free anything;
        /// it stops the next allocation.
        pub fn setLimit(self: *Self, tag: Tag, bytes: usize) void {
            self.counters[slotOf(tag)].limit = bytes;
        }

        pub fn limitOf(self: *const Self, tag: Tag) usize {
            return self.counters[slotOf(tag)].limit;
        }

        // -----------------------------------------------------------------
        // Asking it things
        // -----------------------------------------------------------------

        pub fn stats(self: *const Self, tag: Tag) Counters {
            return self.counters[slotOf(tag)];
        }

        /// Every category added together. The `limit` of the result is the
        /// sum of the limits, which is a number to compare against a machine
        /// rather than a budget to enforce.
        pub fn totals(self: *const Self) Counters {
            var out: Counters = .{};
            for (self.counters) |c| {
                out.live_bytes += c.live_bytes;
                out.live_count += c.live_count;
                out.peak_bytes += c.peak_bytes;
                out.total_bytes += c.total_bytes;
                out.total_count += c.total_count;
                out.refused_count += c.refused_count;
                out.limit += c.limit;
            }
            return out;
        }

        /// How many categories still hold something. Zero at shutdown is what
        /// you want.
        pub fn leakCount(self: *const Self) usize {
            var leaks: usize = 0;
            for (self.counters) |c| {
                if (!c.isEmpty()) leaks += 1;
            }
            return leaks;
        }

        pub fn leaked(self: *const Self) bool {
            return self.leakCount() != 0;
        }

        /// Forget everything counted so far, without freeing anything.
        ///
        /// For measuring one part of a run - a level load, a frame - rather
        /// than the whole of it. Anything live at the time will be counted
        /// as a negative when it is freed, which is why this asserts that
        /// nothing is.
        pub fn resetCounters(self: *Self) void {
            std.debug.assert(!self.leaked());
            for (&self.counters) |*c| {
                const keep = c.limit;
                c.* = .{ .limit = keep };
            }
        }

        // -----------------------------------------------------------------
        // The report
        // -----------------------------------------------------------------

        /// The width of the first column: the longest category name, or
        /// enough for the word "category", whichever is more.
        const name_width: usize = blk: {
            var widest: usize = "category".len;
            for (info.fields) |field| widest = @max(widest, field.name.len);
            break :blk widest + 2;
        };

        fn writeLeft(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
            try w.writeAll(text);
            var i = text.len;
            while (i < name_width) : (i += 1) try w.writeByte(' ');
        }

        fn writeRight(w: *std.Io.Writer, text: []const u8, width: usize) std.Io.Writer.Error!void {
            var i = text.len;
            while (i < width) : (i += 1) try w.writeByte(' ');
            try w.writeAll(text);
        }

        fn writeSize(w: *std.Io.Writer, bytes: usize, width: usize) std.Io.Writer.Error!void {
            var scratch: [32]u8 = undefined;
            var into = std.Io.Writer.fixed(&scratch);
            into.print("{f}", .{layout.size(bytes)}) catch {};
            try writeRight(w, into.buffered(), width);
        }

        /// Where the memory went, as a table.
        ///
        /// Print it at shutdown and any category with something still in it
        /// is a leak with a name on it. Print it after a level load and it is
        /// a budget review.
        pub fn report(self: *const Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try writeLeft(w, "category");
            try writeRight(w, "live", 11);
            try writeRight(w, "peak", 12);
            try writeRight(w, "total", 12);
            try writeRight(w, "blocks", 9);
            try writeRight(w, "limit", 11);
            try w.writeByte('\n');

            inline for (info.fields, 0..) |field, i| {
                const c = self.counters[i];
                try writeLeft(w, field.name);
                try writeSize(w, c.live_bytes, 11);
                try writeSize(w, c.peak_bytes, 12);
                try writeSize(w, c.total_bytes, 12);

                var digits: [24]u8 = undefined;
                try writeRight(w, std.fmt.bufPrint(&digits, "{d}", .{c.live_count}) catch "?", 9);

                if (c.limit == 0) {
                    try writeRight(w, "-", 11);
                } else {
                    try writeSize(w, c.limit, 11);
                }
                if (c.refused_count != 0) {
                    try w.print("   {d} refused", .{c.refused_count});
                }
                try w.writeByte('\n');
            }

            const all = self.totals();
            try writeLeft(w, "total");
            try writeSize(w, all.live_bytes, 11);
            try writeRight(w, "", 12);
            try writeSize(w, all.total_bytes, 12);
            var digits: [24]u8 = undefined;
            try writeRight(w, std.fmt.bufPrint(&digits, "{d}", .{all.live_count}) catch "?", 9);
            try w.writeByte('\n');

            if (all.live_count != 0) {
                try w.print("\n{d} of {d} categories still hold something.\n", .{
                    self.leakCount(),
                    count,
                });
            }
        }

        /// The report, straight to standard error - for a `defer` at the end
        /// of `main`.
        pub fn reportToStdErr(self: *const Self) void {
            var buffer: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&buffer);
            self.report(&w) catch {};
            std.debug.print("{s}", .{w.buffered()});
        }

        // -----------------------------------------------------------------
        // The allocators
        // -----------------------------------------------------------------

        fn vtableFor(comptime tag: Tag) *const Allocator.VTable {
            const index = comptime slot(tag);
            return &struct {
                const table: Allocator.VTable = .{
                    .alloc = struct {
                        fn f(ctx: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
                            const self: *Self = @ptrCast(@alignCast(ctx));
                            const c = &self.counters[index];

                            if (c.limit != 0 and c.live_bytes + len > c.limit) {
                                c.refused_count += 1;
                                return null;
                            }

                            const result = self.child.rawAlloc(len, a, ra) orelse {
                                c.refused_count += 1;
                                return null;
                            };

                            c.live_bytes += len;
                            c.live_count += 1;
                            c.total_bytes += len;
                            c.total_count += 1;
                            if (c.live_bytes > c.peak_bytes) c.peak_bytes = c.live_bytes;
                            return result;
                        }
                    }.f,

                    .resize = struct {
                        fn f(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) bool {
                            const self: *Self = @ptrCast(@alignCast(ctx));
                            const c = &self.counters[index];

                            if (n > m.len and c.limit != 0 and
                                c.live_bytes + (n - m.len) > c.limit)
                            {
                                c.refused_count += 1;
                                return false;
                            }
                            if (!self.child.rawResize(m, a, n, ra)) return false;

                            self.account(index, m.len, n);
                            return true;
                        }
                    }.f,

                    .remap = struct {
                        fn f(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) ?[*]u8 {
                            const self: *Self = @ptrCast(@alignCast(ctx));
                            const c = &self.counters[index];

                            if (n > m.len and c.limit != 0 and
                                c.live_bytes + (n - m.len) > c.limit)
                            {
                                c.refused_count += 1;
                                return null;
                            }
                            const result = self.child.rawRemap(m, a, n, ra) orelse return null;

                            self.account(index, m.len, n);
                            return result;
                        }
                    }.f,

                    .free = struct {
                        fn f(ctx: *anyopaque, m: []u8, a: Alignment, ra: usize) void {
                            const self: *Self = @ptrCast(@alignCast(ctx));
                            const c = &self.counters[index];

                            // Freeing through the wrong category's allocator
                            // would take the bytes off the wrong total, and
                            // there is no header to say which was right.
                            std.debug.assert(c.live_bytes >= m.len);
                            std.debug.assert(c.live_count >= 1);

                            c.live_bytes -= m.len;
                            c.live_count -= 1;
                            self.child.rawFree(m, a, ra);
                        }
                    }.f,
                };
            }.table;
        }

        /// A block that changed size in place: the difference, either way.
        fn account(self: *Self, index: usize, old_len: usize, new_len: usize) void {
            const c = &self.counters[index];
            if (new_len >= old_len) {
                const extra = new_len - old_len;
                c.live_bytes += extra;
                c.total_bytes += extra;
                if (c.live_bytes > c.peak_bytes) c.peak_bytes = c.live_bytes;
            } else {
                const returned = old_len - new_len;
                std.debug.assert(c.live_bytes >= returned);
                c.live_bytes -= returned;
            }
        }
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const Category = enum { textures, meshes, audio, scratch };
const Tracker = Tracking(Category);

test "each category counts its own" {
    var tracker: Tracker = .init(testing.allocator);
    const textures = tracker.allocator(.textures);
    const meshes = tracker.allocator(.meshes);

    const t = try textures.alloc(u8, 1000);
    defer textures.free(t);
    const m = try meshes.alloc(u8, 300);
    defer meshes.free(m);

    try testing.expectEqual(@as(usize, 1000), tracker.stats(.textures).live_bytes);
    try testing.expectEqual(@as(usize, 1), tracker.stats(.textures).live_count);
    try testing.expectEqual(@as(usize, 300), tracker.stats(.meshes).live_bytes);
    // A category nothing went through is empty.
    try testing.expectEqual(@as(usize, 0), tracker.stats(.audio).live_bytes);
    try testing.expect(tracker.stats(.audio).isEmpty());

    try testing.expectEqual(@as(usize, 1300), tracker.totals().live_bytes);
    try testing.expectEqual(@as(usize, 2), tracker.totals().live_count);
}

test "freeing takes it off again" {
    var tracker: Tracker = .init(testing.allocator);
    const a = tracker.allocator(.textures);

    const one = try a.alloc(u8, 500);
    const two = try a.alloc(u8, 700);
    try testing.expectEqual(@as(usize, 1200), tracker.stats(.textures).live_bytes);

    a.free(one);
    try testing.expectEqual(@as(usize, 700), tracker.stats(.textures).live_bytes);
    try testing.expectEqual(@as(usize, 1), tracker.stats(.textures).live_count);

    a.free(two);
    try testing.expect(tracker.stats(.textures).isEmpty());
    try testing.expect(!tracker.leaked());
}

test "the peak is what a budget is sized by, and the total is churn" {
    var tracker: Tracker = .init(testing.allocator);
    const a = tracker.allocator(.scratch);

    // A hundred turns of allocate-and-free: a small peak, a large total.
    for (0..100) |_| {
        const block = try a.alloc(u8, 1024);
        a.free(block);
    }

    const s = tracker.stats(.scratch);
    try testing.expectEqual(@as(usize, 0), s.live_bytes);
    try testing.expectEqual(@as(usize, 1024), s.peak_bytes);
    try testing.expectEqual(@as(usize, 100 * 1024), s.total_bytes);
    try testing.expectEqual(@as(usize, 100), s.total_count);
    // Which is exactly the shape that says "this should have been an arena".
    try testing.expect(s.total_bytes > s.peak_bytes * 10);
}

test "a leak has a category name on it" {
    var tracker: Tracker = .init(testing.allocator);
    const textures = tracker.allocator(.textures);
    const meshes = tracker.allocator(.meshes);

    const kept = try textures.alloc(u8, 4096);
    const returned = try meshes.alloc(u8, 100);
    meshes.free(returned);

    try testing.expect(tracker.leaked());
    try testing.expectEqual(@as(usize, 1), tracker.leakCount());
    try testing.expect(!tracker.stats(.textures).isEmpty());
    try testing.expect(tracker.stats(.meshes).isEmpty());

    textures.free(kept);
    try testing.expect(!tracker.leaked());
    try testing.expectEqual(@as(usize, 0), tracker.leakCount());
}

test "a limit refuses rather than letting a subsystem take the machine" {
    var tracker: Tracker = .init(testing.allocator);
    const a = tracker.allocator(.textures);

    tracker.setLimit(.textures, 4096);
    try testing.expectEqual(@as(usize, 4096), tracker.limitOf(.textures));

    const first = try a.alloc(u8, 3000);
    defer a.free(first);

    // Under the limit.
    const second = try a.alloc(u8, 1000);
    defer a.free(second);

    // Over it: refused here, not by the operating system later.
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 500));
    try testing.expectEqual(@as(usize, 1), tracker.stats(.textures).refused_count);
    // And nothing was counted for the request that failed.
    try testing.expectEqual(@as(usize, 4000), tracker.stats(.textures).live_bytes);

    // Another category is unaffected by the texture budget.
    const meshes = tracker.allocator(.meshes);
    const m = try meshes.alloc(u8, 100_000);
    defer meshes.free(m);
}

test "a limit can be lifted and lowered" {
    var tracker: Tracker = .init(testing.allocator);
    const a = tracker.allocator(.audio);

    tracker.setLimit(.audio, 1000);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 2000));

    tracker.setLimit(.audio, 0); // no limit
    const block = try a.alloc(u8, 2000);
    defer a.free(block);

    // Lowering it below what is already live does not free anything, but it
    // does stop the next allocation.
    tracker.setLimit(.audio, 100);
    try testing.expectEqual(@as(usize, 2000), tracker.stats(.audio).live_bytes);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
}

test "growing and shrinking are accounted for" {
    var tracker: Tracker = .init(testing.allocator);
    const a = tracker.allocator(.meshes);

    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(a);

    for (0..1000) |i| try list.append(a, i);

    // Whatever the growth strategy did, what is live matches what the list
    // is actually holding.
    const s = tracker.stats(.meshes);
    try testing.expectEqual(list.capacity * @sizeOf(u64), s.live_bytes);
    try testing.expect(s.peak_bytes >= s.live_bytes);
    try testing.expect(s.total_bytes >= s.live_bytes);

    list.clearAndFree(a);
    try testing.expect(tracker.stats(.meshes).isEmpty());
}

test "a shrink in place gives the bytes back to the count" {
    var tracker: Tracker = .init(testing.allocator);
    const a = tracker.allocator(.scratch);

    const block = try a.alloc(u8, 4096);
    try testing.expectEqual(@as(usize, 4096), tracker.stats(.scratch).live_bytes);

    if (a.resize(block, 1024)) {
        try testing.expectEqual(@as(usize, 1024), tracker.stats(.scratch).live_bytes);
        // A comptime-known slice bound gives a pointer-to-array, and `free`
        // wants a slice - so the type has to be said out loud.
        const shrunk: []u8 = block[0..1024];
        a.free(shrunk);
    } else {
        a.free(block);
    }
    try testing.expect(tracker.stats(.scratch).isEmpty());
}

test "resetCounters forgets a level without freeing it" {
    var tracker: Tracker = .init(testing.allocator);
    const a = tracker.allocator(.textures);

    const block = try a.alloc(u8, 2048);
    a.free(block);
    try testing.expectEqual(@as(usize, 2048), tracker.stats(.textures).total_bytes);

    tracker.setLimit(.textures, 9999);
    tracker.resetCounters();

    try testing.expectEqual(@as(usize, 0), tracker.stats(.textures).total_bytes);
    try testing.expectEqual(@as(usize, 0), tracker.stats(.textures).peak_bytes);
    // The budget is not part of what was measured, so it survives.
    try testing.expectEqual(@as(usize, 9999), tracker.limitOf(.textures));
}

test "it wraps whatever is underneath, including an arena" {
    const Arena = @import("Arena.zig");

    var backing: [8192]u8 = undefined;
    var arena: Arena = .init(&backing);

    var tracker: Tracker = .init(arena.allocator());
    const a = tracker.allocator(.scratch);

    const block = try a.alloc(u8, 1000);
    try testing.expectEqual(@as(usize, 1000), tracker.stats(.scratch).live_bytes);
    try testing.expect(arena.used >= 1000);

    // The arena refuses eventually, and the refusal is counted here.
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 100_000));
    try testing.expectEqual(@as(usize, 1), tracker.stats(.scratch).refused_count);

    a.free(block);
    try testing.expect(tracker.stats(.scratch).isEmpty());
}

test "the report says where the memory went" {
    var tracker: Tracker = .init(testing.allocator);
    const textures = tracker.allocator(.textures);
    const meshes = tracker.allocator(.meshes);

    tracker.setLimit(.textures, 1024 * 1024);

    const t = try textures.alloc(u8, 300 * 1024);
    defer textures.free(t);
    const m = try meshes.alloc(u8, 64 * 1024);
    defer meshes.free(m);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tracker.report(&w);
    const text = w.buffered();

    // Every category is named, whether or not it holds anything.
    inline for (@typeInfo(Category).@"enum".fields) |field| {
        try testing.expect(std.mem.indexOf(u8, text, field.name) != null);
    }
    // The sizes are the readable kind.
    try testing.expect(std.mem.indexOf(u8, text, "300.0 KiB") != null);
    try testing.expect(std.mem.indexOf(u8, text, "64.0 KiB") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1.0 MiB") != null); // the limit
    // And the leak line, because two categories are still holding something.
    try testing.expect(std.mem.indexOf(u8, text, "2 of 4 categories") != null);
}

test "the report says nothing about leaks when there are none" {
    var tracker: Tracker = .init(testing.allocator);
    const a = tracker.allocator(.audio);
    const block = try a.alloc(u8, 128);
    a.free(block);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tracker.report(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "categories still hold") == null);
}

test "an enum with explicit values still lines up" {
    // The counters are indexed by position, not by the declared value, so an
    // enum with gaps in it works.
    const Sparse = enum(u8) { first = 10, second = 200, third = 3 };
    var tracker: Tracking(Sparse) = .init(testing.allocator);

    const first = tracker.allocator(.first);
    const second = tracker.allocator(.second);
    const third = tracker.allocator(.third);

    const a = try first.alloc(u8, 100);
    defer first.free(a);
    const b = try second.alloc(u8, 200);
    defer second.free(b);
    const c = try third.alloc(u8, 300);
    defer third.free(c);

    try testing.expectEqual(@as(usize, 100), tracker.stats(.first).live_bytes);
    try testing.expectEqual(@as(usize, 200), tracker.stats(.second).live_bytes);
    try testing.expectEqual(@as(usize, 300), tracker.stats(.third).live_bytes);
    try testing.expectEqual(@as(usize, 3), Tracking(Sparse).count);
}

test "one category on its own" {
    const Only = enum { everything };
    var tracker: Tracking(Only) = .init(testing.allocator);
    const a = tracker.allocator(.everything);

    const block = try a.alloc(u8, 42);
    try testing.expectEqual(@as(usize, 42), tracker.totals().live_bytes);
    a.free(block);
    try testing.expect(!tracker.leaked());
}
