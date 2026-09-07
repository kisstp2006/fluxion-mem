# Fluxion Mem

Allocators that know something about their memory that a general-purpose one
cannot. For Zig 0.16. Six pieces that fit together:

| Module | What it is |
| --- | --- |
| `layout` | Alignment arithmetic, and a number of bytes printed the way a person reads one. |
| `Arena` | Handed out from one end, given back all at once. A frame allocator, and with `mark` and `restore`, a stack one. |
| `Stack` | One buffer, handed out from both ends at once - the level from the back, the frame from the front. |
| `Pool` | A fixed number of slots, all the same type. No search, no fragmentation, and a double free that is caught. |
| `FreeList` | Any size, freed in any order, with the neighbours joined back together. |
| `Tracking` | What another allocator did, per category, with budgets and a report that says where the memory went. |

`std.heap` already has a general-purpose allocator, and it is a good one.
Nothing here replaces it. What these do is exploit something known about the
memory that `malloc` cannot be told:

| If you know | then | and it costs |
| --- | --- | --- |
| it all dies at the end of the frame | `Arena` | an add |
| there are two lifetimes, not many | `Stack` | an add |
| everything is the same type | `Pool` | a pointer swap |
| it is a fixed budget, freed in any order | `FreeList` | a short search |
| you want to know where it went | `Tracking` | a few counters |

**Nothing here grows.** Every allocator takes its buffer once and returns
`error.OutOfMemory` when it is full, rather than quietly asking the operating
system for more. That is the point: an allocator that grows silently is a
frame spike you find out about from a player. Every one of them keeps a
`high_water` mark instead, which is the number to size the buffer by - measure
it once, set it, and the run never allocates again.

**They compose.** All six take an `Allocator` or hand one out, so a frame
arena inside a tracked category inside a debug allocator is three lines and no
glue.

**One thread at a time.** None of these lock. An allocator shared between
threads needs a lock around it, and the usual answer in an engine is not to
share one: give each worker its own arena, which is cheaper than any lock and
is why per-thread scratch is the pattern it is.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-mem
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_mem = .{ .path = "../fluxion-mem" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_mem", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("fluxion_mem", fluxion.module("fluxion_mem"));
```

```zig
const mem = @import("fluxion_mem");
```

## Tour

### Arena

The cheapest allocator there is: an allocation is a bounds check and an
addition, and freeing is setting one number back.

```zig
var frame: mem.Arena = try .initAlloc(gpa, mem.mib(4));
defer frame.deinit(gpa);
const a = frame.allocator();

while (running) {
    defer frame.reset();          // the whole frame, in one instruction

    const visible = try a.alloc(u32, count);
    const label = try std.fmt.allocPrint(a, "{d} draw calls", .{visible.len});
    ...
}

std.log.info("the frame arena peaked at {f}", .{mem.size(frame.high_water)});
```

`mark` and `restore` make the same arena a stack allocator, and `scope` is
that with `defer` doing the restoring:

```zig
const scratch = frame.scope();
defer scratch.end();

const working = try a.alloc(f32, 100_000);   // gone at the end of the block
```

Freeing the most recent allocation reclaims it, so a loop that allocates and
frees in reverse order never grows at all.

### Stack

Two bump allocators facing each other in one buffer. The oldest layout in
games, and still the right one whenever memory divides into two lifetimes
rather than many.

```zig
var stack: mem.Stack = try .initAlloc(gpa, mem.mib(256));
const level = stack.allocator(.back);    // until the level changes
const frame = stack.allocator(.front);   // until the next frame

const mesh = try level.alloc(f32, 200_000);

while (running) {
    defer stack.reset(.front);
    const commands = try frame.alloc(Command, 4096);
    ...
}
```

Neither end is given a budget - they share what is between them, which is the
thing two separate arenas cannot do. `zig build example` draws it:

```
frame         front       back      between   layout
0             414 B    7.2 KiB     24.4 KiB   ...............................>>>>>>>>>
1           1.2 KiB    7.2 KiB     23.6 KiB   <..............................>>>>>>>>>
2           2.0 KiB    7.2 KiB     22.8 KiB   <<.............................>>>>>>>>>
```

### Pool

When everything being allocated is the same type, the problem an allocator
solves does not arise: every free slot fits.

```zig
var entities: mem.Pool(Entity) = try .initAlloc(gpa, 4096);
defer entities.deinit(gpa);

const player = entities.create().?;
player.* = .{ .x = 0, .y = 0, .health = 100 };

entities.destroy(player);
```

**Slots are addressable by index as well as by pointer.** `createIndex` gives
a `u32` naming the same slot - a quarter the size of a pointer, and what a
handle is made of:

```zig
const index = entities.createIndex().?;
entities.at(index).* = .{ ... };
```

That is the same index [Fluxion Id](https://github.com/kisstp2006/fluxion-id)'s
`Handle` carries, with a generation counter beside it.

**A double free is caught in every build**, not only in safe ones. Each slot's
link says whether it is out, so destroying one twice is a failed assertion
rather than a free list that quietly eats itself. The check costs nothing: the
field is there either way.

### FreeList

The one here that behaves like a general-purpose allocator: any size, any
alignment, freed in any order, with adjacent free blocks merged so that two
halves become a whole again.

```zig
var region: mem.FreeList = try .initAlloc(gpa, mem.mib(64));
defer region.deinit(gpa);
const a = region.allocator();

const texture = try a.alloc(u8, width * height * 4);
a.free(texture);                 // joined back to its neighbours

region.largestFree();            // the biggest allocation that would succeed
region.blockCount();             // how fragmented it is
region.verify();                 // for a test, or an assertion after something odd
```

What it costs is a search, and the failure it can have that the others cannot.
`zig build example` shows both:

```
sixteen blocks of 200 bytes:
  ##################################################..............

every other one freed:
  ....###...###...###...###....###...###...###...###..............

  2.4 KiB is free, but the largest single block is 896 B - so an
  allocation of 1.2 KiB is refused.
```

The bookkeeping lives in the free memory itself, so a live allocation has no
header and the overhead of a full heap is exactly zero bytes.

### Tracking

The question a debug allocator answers is "did anything leak". The question an
engine asks first is different: **where did the memory go?** Six hundred
megabytes resident is not a bug report. `textures 412 MiB, meshes 96 MiB` is.

```zig
const Category = enum { level, frame, entities, textures, scratch };

var tracker: mem.Tracking(Category) = .init(gpa);
tracker.setLimit(.textures, mem.mib(512));

const textures = tracker.allocator(.textures);
const meshes = tracker.allocator(.entities);
```

The tag is a comptime argument, so each category has its own vtable and
nothing is looked up at run time. Pass those down as ordinary `Allocator`s and
everything below is counted without knowing it is.

```
category         live        peak       total   blocks      limit
level             0 B    32.0 KiB    32.0 KiB        0          -
frame             0 B         0 B         0 B        0          -
entities          0 B     8.0 KiB     8.0 KiB        0   64.0 KiB
textures          0 B     4.0 KiB     4.0 KiB        0    8.0 MiB   1 refused
scratch           0 B    12.0 KiB    12.0 KiB        0          -
total             0 B                56.0 KiB        0
```

`live` at shutdown is a leak with a category name on it. `peak` is what to
size a budget by. A `total` far above the `peak` is churn, which is what an
`Arena` is for.

**A budget can be set per category.** `setLimit(.textures, 512 << 20)` makes
the texture allocator start refusing at half a gigabyte rather than at the
point the machine gives out - which turns "it ran out eventually, on somebody
else's computer" into a failure that happens on yours, in the subsystem
responsible.

This does not detect a use-after-free or a buffer overrun; that is what
`std.heap.DebugAllocator` is for, and this wraps it happily. What it adds is
the accounting that one does not do.

### layout

The arithmetic the rest is built out of, plus the one piece of formatting:

```zig
mem.layout.padding(address, alignment);   // the gap rounding would close
mem.layout.alignSlice(buffer, .of(u64));  // a buffer trimmed to start aligned
mem.size(340_123_456)                     // prints as "324.4 MiB"
mem.kib(64)  mem.mib(4)  mem.gib(1)       // without counting zeroes
```

## Everything together

```zig
const Category = enum { level, frame, entities };

var tracker: mem.Tracking(Category) = .init(gpa);
tracker.setLimit(.entities, mem.mib(16));

// The level and the frame share one buffer from opposite ends.
var stack: mem.Stack = try .initAlloc(tracker.allocator(.level), mem.mib(256));
const level = stack.allocator(.back);
const frame = stack.allocator(.front);

// Entities come out of a pool: no search, no fragmentation ever.
var entities: mem.Pool(Entity) = try .initAlloc(tracker.allocator(.entities), 4096);

const mesh = try level.alloc(f32, 200_000);

while (running) {
    defer stack.reset(.front);
    const visible = try frame.alloc(Handle, entities.live);
    ...
}

defer tracker.reportToStdErr();   // where it all went, at shutdown
```

`zig build example` runs the whole of that, with the frame arena's high-water
mark, the two ends of the stack drawn as they fill, two thousand turns of pool
churn, a region fragmenting until it refuses an allocation it has room for, and
the report at the end.

## Build

```bash
zig build test        # run the test suite
zig build example     # build and run the demo tour
zig build docs        # generate API documentation into zig-out/docs
```

## Requirements

Zig 0.16.0. No dependencies, and nothing to link against.

## License

Boost Software License 1.0. See [LICENSE](LICENSE).

Permissive, and short enough to read in a minute: use it, change it, ship it,
in anything. The one obligation is that the copyright notice and the licence
text travel with the *source* - a binary built from it carries nothing, which
is the difference from MIT and BSD and the reason this is the usual choice for
a library that ends up compiled into someone else's program.

The rest of the Fluxion libraries are CC0. This one is not, so a project that
vendors it has one file to keep.
