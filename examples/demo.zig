// SPDX-License-Identifier: BSL-1.0

//! A tour of Fluxion Mem. Run it with `zig build example`.
//!
//! It builds one engine's memory: a tracked budget at the top, a level and a
//! frame sharing one buffer beneath it, a pool of entities, and a fixed
//! region that fragments where you can watch it. Then it prints the report
//! that says where everything went.

const std = @import("std");
const Io = std.Io;
const mem = @import("fluxion_mem");

const Arena = mem.Arena;
const Stack = mem.Stack;
const FreeList = mem.FreeList;

/// What the engine's memory divides into. One `Allocator` per line, and one
/// row in the report at the end.
const Category = enum {
    level,
    frame,
    entities,
    textures,
    scratch,
};

const Tracker = mem.Tracking(Category);

const Entity = struct {
    x: f32,
    y: f32,
    health: u16,
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [16384]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    const gpa = init.arena.allocator();

    var tracker: Tracker = .init(gpa);
    tracker.setLimit(.textures, mem.mib(8));
    tracker.setLimit(.entities, mem.kib(64));

    try theArena(out);
    try theStack(out, &tracker);
    try thePool(out, &tracker);
    try theFreeList(out, &tracker);
    try theReport(out, &tracker);

    try out.flush();
}

/// A size, rendered into `buf` so that `{s: >10}` can right-align it.
///
/// `{f}` calls a type's own `format`, which writes straight to the stream and
/// so cannot be padded. Rendering first and printing the text is how a column
/// of sizes lines up.
fn sz(buf: []u8, bytes: usize) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{f}", .{mem.size(bytes)}) catch return "?";
    return w.buffered();
}

// -------------------------------------------------------------------------
// The arena
// -------------------------------------------------------------------------

fn theArena(out: *Io.Writer) !void {
    try out.writeAll("\n--- a frame arena ---\n\n");

    var backing: [mem.kib(64)]u8 = undefined;
    var arena: Arena = .init(&backing);
    const a = arena.allocator();

    try out.print("buffer {f}\n\n", .{mem.size(arena.capacity())});
    try out.print("{s: <8} {s: >10} {s: >10} {s: >10}\n", .{ "frame", "used", "peak", "left" });

    for (0..6) |frame| {
        defer arena.reset();

        // A frame's worth of work: a visible list, some strings, some scratch.
        const visible = try a.alloc(u32, 200 + frame * 300);
        for (visible, 0..) |*id, i| id.* = @intCast(i);

        _ = try std.fmt.allocPrint(a, "frame {d}: {d} visible", .{ frame, visible.len });
        _ = try a.alloc(u8, 512);

        var a1: [24]u8 = undefined;
        var a2: [24]u8 = undefined;
        var a3: [24]u8 = undefined;
        try out.print("{d: <8} {s: >10} {s: >10} {s: >10}\n", .{
            frame,
            sz(&a1, arena.used),
            sz(&a2, arena.high_water),
            sz(&a3, arena.remaining()),
        });
    }

    try out.print(
        \\
        \\Six frames, one buffer, and nothing allocated after startup. The peak
        \\is {f}, so a buffer of {f} would have done - which is the number
        \\`high_water` exists to give you.
        \\
    , .{ mem.size(arena.high_water), mem.size(arena.high_water) });

    // And the scratch scope, which is the same arena used as a stack.
    const before = arena.used;
    _ = try a.alloc(u8, 64);
    {
        const scratch = arena.scope();
        defer scratch.end();
        _ = try a.alloc(u8, mem.kib(8));
        try out.print("\ninside a scratch scope: {f} used\n", .{mem.size(arena.used)});
    }
    try out.print("after it:               {f} used\n", .{mem.size(arena.used)});
    std.debug.assert(arena.used == before + 64);
}

// -------------------------------------------------------------------------
// The stack
// -------------------------------------------------------------------------

fn theStack(out: *Io.Writer, tracker: *Tracker) !void {
    try out.writeAll("\n--- a level and its frames, in one buffer ---\n\n");

    const owner = tracker.allocator(.level);
    var stack: Stack = try .initAlloc(owner, mem.kib(32));

    const level = stack.allocator(.back);
    const frame = stack.allocator(.front);

    // Loaded once, and never freed until the level changes.
    const mesh = try level.alloc(f32, 1400);
    @memset(mesh, 1.5);
    const collision = try level.alloc(u16, 900);
    @memset(collision, 7);

    try out.print("{s: <8} {s: >10} {s: >10} {s: >12}   {s}\n", .{
        "frame", "front", "back", "between", "layout",
    });

    for (0..5) |i| {
        defer stack.reset(.front);

        const visible = try frame.alloc(u32, 100 + i * 200);
        for (visible, 0..) |*id, n| id.* = @intCast(n);
        _ = try std.fmt.allocPrint(frame, "{d} draw calls", .{visible.len});

        var s1: [24]u8 = undefined;
        var s2: [24]u8 = undefined;
        var s3: [24]u8 = undefined;
        try out.print("{d: <8} {s: >10} {s: >10} {s: >12}   ", .{
            i,
            sz(&s1, stack.usedBy(.front)),
            sz(&s2, stack.usedBy(.back)),
            sz(&s3, stack.remaining()),
        });
        try drawStack(out, &stack, 40);
        try out.writeByte('\n');
    }

    try out.writeAll(
        \\
        \\`<` is the front, growing right; `>` is the back, growing left; `.` is
        \\what neither has claimed. Neither end was given a budget - they share
        \\what is between them, which is the thing two separate arenas cannot do.
        \\
    );

    // The level data is untouched by any of that.
    std.debug.assert(mesh[700] == 1.5);
    std.debug.assert(collision[400] == 7);

    stack.deinit(owner);
}

/// One line of the stack, as a picture.
fn drawStack(out: *Io.Writer, stack: *const Stack, width: usize) !void {
    const total = stack.capacity();
    const front = stack.usedBy(.front) * width / total;
    const back = stack.usedBy(.back) * width / total;

    for (0..width) |i| {
        try out.writeByte(if (i < front)
            '<'
        else if (i >= width - back)
            '>'
        else
            '.');
    }
}

// -------------------------------------------------------------------------
// The pool
// -------------------------------------------------------------------------

fn thePool(out: *Io.Writer, tracker: *Tracker) !void {
    try out.writeAll("\n--- a pool of entities ---\n\n");

    const owner = tracker.allocator(.entities);
    var pool: mem.Pool(Entity) = try .initAlloc(owner, 512);
    defer pool.deinit(owner);

    try out.print("{f}\n\n", .{&pool});

    // Spawn some, kill some, spawn some more - the shape of a whole run.
    var live: std.ArrayList(mem.Pool(Entity).Index) = .empty;
    defer live.deinit(std.heap.page_allocator);

    var prng: std.Random.DefaultPrng = .init(0xE0717E);
    const rng = prng.random();

    try out.print("{s: <10} {s: >7} {s: >7} {s: >7}\n", .{ "tick", "live", "peak", "spare" });

    for (0..2000) |tick| {
        if (live.items.len < 400 and (live.items.len == 0 or rng.boolean())) {
            const index = pool.createIndex().?;
            pool.at(index).* = .{
                .x = rng.float(f32) * 100,
                .y = rng.float(f32) * 100,
                .health = 100,
            };
            try live.append(std.heap.page_allocator, index);
        } else if (live.items.len > 0) {
            const which = rng.uintLessThan(usize, live.items.len);
            pool.destroyIndex(live.swapRemove(which));
        }

        if (tick % 400 == 0) {
            try out.print("{d: <10} {d: >7} {d: >7} {d: >7}\n", .{
                tick,
                pool.live,
                pool.high_water,
                pool.available(),
            });
        }
    }

    try out.print("{d: <10} {d: >7} {d: >7} {d: >7}\n", .{
        2000,
        pool.live,
        pool.high_water,
        pool.available(),
    });

    // The whole point: after two thousand turns of churn, whatever is free
    // can still be handed out. A pool does not fragment.
    var taken: usize = 0;
    while (pool.createIndex() != null) taken += 1;
    try out.print(
        \\
        \\After 2000 spawns and kills, {d} slots were still free and every one of
        \\them could be taken - a pool cannot fragment, because every free slot
        \\fits every request. `create` and `destroy` are a pointer swap each.
        \\
    , .{taken});
}

// -------------------------------------------------------------------------
// The free list
// -------------------------------------------------------------------------

fn theFreeList(out: *Io.Writer, tracker: *Tracker) !void {
    try out.writeAll("\n--- a fixed region, and what fragments it ---\n\n");

    const owner = tracker.allocator(.textures);
    var list: FreeList = try .initAlloc(owner, mem.kib(4));
    defer list.deinit(owner);

    const a = list.allocator();

    var blocks: [16][]u8 = undefined;
    for (&blocks) |*b| b.* = try a.alloc(u8, 200);

    try out.writeAll("sixteen blocks of 200 bytes:\n  ");
    try drawFreeList(out, &list, 64);
    try out.print("\n  {f}\n", .{&list});

    // Free every other one.
    var i: usize = 0;
    while (i < 16) : (i += 2) a.free(blocks[i]);

    try out.writeAll("\nevery other one freed:\n  ");
    try drawFreeList(out, &list, 64);
    try out.print("\n  {f}\n", .{&list});

    const half = list.freeBytes() / 2;
    if (a.alloc(u8, half)) |_| {
        try out.writeAll("\n  ...and half of what is free could still be allocated.\n");
    } else |_| {
        try out.print(
            \\
            \\  {f} is free, but the largest single block is {f} - so an
            \\  allocation of {f} is refused. That is fragmentation, and it is
            \\  the failure an arena and a pool cannot have.
            \\
        , .{
            mem.size(list.freeBytes()),
            mem.size(list.largestFree()),
            mem.size(half),
        });
    }

    // Free the rest, and it all joins back into one block.
    i = 1;
    while (i < 16) : (i += 2) a.free(blocks[i]);

    try out.writeAll("\nand the rest freed:\n  ");
    try drawFreeList(out, &list, 64);
    try out.print("\n  {f}\n", .{&list});
    std.debug.assert(list.blockCount() == 1);
    std.debug.assert(list.verify());
}

/// The region as a picture: `#` is handed out, `.` is free.
fn drawFreeList(out: *Io.Writer, list: *const FreeList, width: usize) !void {
    const start = @intFromPtr(list.buffer.ptr);
    const total = list.capacity();

    var column: usize = 0;
    while (column < width) : (column += 1) {
        const offset = start + column * total / width;

        // Is this column inside a free block?
        var free = false;
        var maybe = list.first;
        while (maybe) |node| : (maybe = node.next) {
            const at = @intFromPtr(node);
            if (offset >= at and offset < at + node.size) {
                free = true;
                break;
            }
        }
        try out.writeByte(if (free) '.' else '#');
    }
}

// -------------------------------------------------------------------------
// The report
// -------------------------------------------------------------------------

fn theReport(out: *Io.Writer, tracker: *Tracker) !void {
    try out.writeAll("\n--- where the memory went ---\n\n");

    // A little more, so the table has something in every row.
    const scratch = tracker.allocator(.scratch);
    const block = try scratch.alloc(u8, mem.kib(12));
    scratch.free(block);

    // And a category that runs into its budget.
    const textures = tracker.allocator(.textures);
    _ = textures.alloc(u8, mem.mib(16)) catch {};

    try tracker.report(out);

    try out.writeAll(
        \\
        \\`live` at shutdown is a leak, and it has a category name on it rather
        \\than a stack trace to read. `peak` is what to size a budget by.
        \\A `total` far above the `peak` is churn - memory allocated and freed
        \\over and over, which is what an `Arena` is for.
        \\
    );
}
