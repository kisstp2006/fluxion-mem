# Fluxion Mem

Allocators that know something about their memory that a general-purpose one
cannot. For C3 0.8. Six pieces that fit together:

| Module | What it is |
| --- | --- |
| `layout` | Alignment arithmetic, the allocation header, and a number of bytes printed the way a person reads one. |
| `arena` | Handed out from one end, given back all at once. A frame allocator, and with `mark` and `restore`, a stack one. |
| `stack` | One buffer, handed out from both ends at once - the level from the back, the frame from the front. |
| `pool` | A fixed number of slots, all the same type. No search, no fragmentation, and a double free that is caught. |
| `free_list` | Any size, freed in any order, with the neighbours joined back together. |
| `tracking` | What another allocator did, per category, with budgets and a report that says where the memory went. |

C3's standard library already has a general-purpose allocator, and it is a good
one. Nothing here replaces it. What these do is exploit something known about
the memory that `malloc` cannot be told:

| If you know | then | and it costs |
| --- | --- | --- |
| it all dies at the end of the frame | `Arena` | an add |
| there are two lifetimes, not many | `Stack` | an add |
| everything is the same type | `Pool` | a pointer swap |
| it is a fixed budget, freed in any order | `FreeList` | a short search |
| you want to know where it went | `Tracking` | a few counters |

**Nothing here grows.** Every allocator takes its buffer once and returns
`mem::OUT_OF_MEMORY` when it is full, rather than quietly asking the operating
system for more. That is the point: an allocator that grows silently is a frame
spike you hear about from a player. Every one of them keeps a `high_water` mark
instead, which is the number to size the buffer by - measure it once, set it,
and the run never allocates again.

**They compose.** All of them take an `Allocator` or hand one out, so a frame
arena inside a tracked category inside the heap is three lines and no glue.

**One thread at a time.** None of these lock. An allocator shared between
threads needs a lock around it, and the usual answer in an engine is not to
share one: give each worker its own arena, which is cheaper than any lock and
is why per-thread scratch is the pattern it is.

## Install

The library is the `fluxion_mem.c3l` directory in this repository. For a
checkout next to your project, add to `project.json`:

```json
"dependency-search-paths": ["../fluxion-mem"],
"dependencies": ["fluxion_mem"]
```

Then, in the code:

```c3
import fluxion::mem;
```

One import is the whole library: C3 imports a module's sub-modules with it, so
`Arena`, `Stack`, `Pool{T}`, `FreeList` and `Tracking{T}` are all in scope from
that line.

## The header, and why there is one

C3's `Allocator` interface is three methods:

```c3
fn void*? acquire(sz size, AllocInitType init_type, sz alignment = 0);
fn void*? resize(void* ptr, sz new_size, sz alignment = 0);
fn void release(void* ptr, bool aligned);
```

`release` is handed a pointer and nothing else. So every allocator here writes
a small header immediately in front of the payload it hands out, which is how
the standard library's own allocators do it. That costs 24 bytes per live
allocation. It is worth saying plainly because the Zig original this was ported
from had zero: Zig's `Allocator` passes the whole slice back to `free`, so a
free list there needed no header at all. What the header buys is that a caller
never has to remember a length in order to free correctly.

There is one trap worth knowing if you write an allocator that wraps another,
as `Tracking` does. **An alignment of zero is not the same as an alignment of
16.** Zero means "whatever you normally do"; on Windows a non-zero alignment
sends the request through `_aligned_malloc`, which must be given back through
`_aligned_free`. Tidying a caller's `0` into a `16` before passing it down
allocates on one path and frees on the other, and the crash lands nowhere near
the tidying. Pass the alignment through exactly as it arrived.

## Tour

### Arena

The cheapest allocator there is: an allocation is a bounds check and an
addition, and freeing everything is setting one number back.

```c3
Arena frame;
frame.init_alloc(mem, mem::mib(4))!;
defer frame.free_from(mem);
Allocator a = (Allocator)&frame;

while (running)
{
    defer frame.reset();          // the whole frame, in one instruction

    uint[] visible = alloc::alloc_array(a, uint, count);
    String label = string::format(a, "%d draw calls", visible.len);
    ...
}

io::printfn("the frame arena peaked at %s", mem::size(frame.high_water));
```

`mark` and `restore` make the same arena a stack allocator, and `scope` is that
with `defer` doing the restoring:

```c3
Scope scratch = frame.scope();
defer scratch.end();

float[] working = alloc::alloc_array(a, float, 100_000);   // gone at the end of the block
```

Freeing the most recent allocation reclaims it exactly, padding included, so a
loop that allocates and frees in reverse order never grows at all.

### Stack

Two bump allocators facing each other in one buffer. The oldest layout in
games, and still the right one whenever memory divides into two lifetimes
rather than many.

```c3
Stack stack;
stack.init_alloc(mem, mem::mib(256))!;

Allocator level = stack.allocator(BACK);    // until the level changes
Allocator frame = stack.allocator(FRONT);   // until the next frame

float[] mesh = alloc::alloc_array(level, float, 200_000);

while (running)
{
    defer stack.reset(FRONT);
    Command[] commands = alloc::alloc_array(frame, Command, 4096);
    ...
}
```

Neither end is given a budget - they share what is between them, which is the
thing two separate arenas cannot do. `c3c run demo` draws it:

```
frame         front       back      between   layout
    0      479 B    7.3 KiB     24.3 KiB   ...............................>>>>>>>>>
    1    1.2 KiB    7.3 KiB     23.5 KiB   <..............................>>>>>>>>>
    2    2.0 KiB    7.3 KiB     22.7 KiB   <<.............................>>>>>>>>>
```

Zig picked the two ends apart with a comptime parameter, so each got its own
generated vtable. C3's `Allocator` is an interface, and an interface value is a
pointer to something that exists, so a `Stack` holds two small `StackEnd`
values and hands out a pointer to one of them. One branch per allocation. A
`Stack` must not be copied once initialised, because those ends point back at
it.

### Pool

When everything being allocated is the same type, the problem an allocator
solves does not arise: every free slot fits.

```c3
Pool{Entity} entities;
entities.init_alloc(mem, 4096)!;
defer entities.free_from(mem);

Entity* player = entities.create()!;
*player = { .x = 0, .y = 0, .health = 100 };

entities.destroy(player);
```

**Slots are addressable by index as well as by pointer.** `create_index` gives
a `uint` naming the same slot - a quarter the size of a pointer, and what a
handle is made of:

```c3
Index index = entities.create_index()!;
*entities.at(index) = { ... };
```

That is the same index [Fluxion Id](https://github.com/kisstp2006/fluxion-id)'s
`Handle` carries, with a generation counter beside it.

**A double free is caught in every build**, not only a safe one. Each slot's
link says whether it is out, so destroying one twice is a failed assertion
rather than a free list that quietly eats itself. The check costs nothing: the
field is there either way.

`Pool` is deliberately not an `Allocator`. It hands out one type and one size,
which is exactly the knowledge that makes it fast.

### FreeList

The one here that behaves like a general-purpose allocator: any size, any
alignment, freed in any order, with adjacent free blocks merged so that two
halves become a whole again.

```c3
FreeList region;
region.init_alloc(mem, mem::mib(64))!;
defer region.free_from(mem);
Allocator a = (Allocator)&region;

char[] texture = alloc::alloc_array(a, char, width * height * 4);
alloc::free(a, texture.ptr);      // joined back to its neighbours

region.largest_free();            // the biggest allocation that would succeed
region.block_count();             // how fragmented it is
region.verify();                  // for a test, or an assertion after something odd
```

What it costs is a search, and the failure it can have that the others cannot.
`c3c run demo` shows both:

```
sixteen blocks of 180 bytes:
  .####################################################...........

every other one freed:
  ....###....###...###....###...###....###...###....###...........

  2.4 KiB is free, but the largest single block is 744 B - so an
  allocation of 1.2 KiB is refused.
```

The free-list bookkeeping lives in the free memory itself, so nothing is spent
on memory that is not in use.

### Tracking

The question a debug allocator answers is "did anything leak". The question an
engine asks first is different: **where did the memory go?** Six hundred
megabytes resident is not a bug report. `textures 412 MiB, meshes 96 MiB` is.

```c3
enum Category { LEVEL, FRAME, ENTITIES, TEXTURES, SCRATCH }

Tracking{Category} tracker;
tracker.init(mem);
tracker.set_limit(TEXTURES, mem::mib(512));

Allocator textures = tracker.allocator(TEXTURES);
Allocator meshes = tracker.allocator(ENTITIES);
```

Pass those down as ordinary `Allocator`s and everything below is counted
without knowing it is.

```
category         live        peak       total   blocks      limit
LEVEL             0 B    32.0 KiB    32.0 KiB        0          -
FRAME             0 B         0 B         0 B        0          -
ENTITIES          0 B     8.0 KiB     8.0 KiB        0   64.0 KiB
TEXTURES          0 B     4.0 KiB     4.0 KiB        0    8.0 MiB   1 refused
SCRATCH           0 B    12.0 KiB    12.0 KiB        0          -
total             0 B                56.0 KiB        0
```

`live` at shutdown is a leak with a category name on it. `peak` is what to size
a budget by. A `total` far above the `peak` is churn, which is what an `Arena`
is for.

**A budget can be set per category.** `set_limit(TEXTURES, mem::mib(512))`
makes the texture allocator start refusing at half a gigabyte rather than at
the point the machine gives out - which turns "it ran out eventually, on
somebody else's computer" into a failure that happens on yours, in the
subsystem responsible.

The category is found by `.ordinal`, C3's dense position for an enum value, so
an enum with gaps in its declared values still indexes the counters correctly.
The Zig original had to search the field list to compute the same number.

**Free with the allocator you allocated from.** The tag of a release is the tag
of the allocator it went through, and there is nowhere else to keep it.

### layout

The arithmetic the rest is built out of, plus the one piece of formatting:

```c3
layout::padding(offset, alignment);       // the gap rounding would close
layout::align_slice(buffer, 16);          // a buffer trimmed to start aligned
mem::size(340_123_456)                    // prints as "324.4 MiB"
mem::kib(64)  mem::mib(4)  mem::gib(1)    // without counting zeroes
```

The size shorthands take a compile-time argument, so `char[mem::kib(64)] buf;`
is an array size rather than a call.

## Everything together

```c3
enum Category { LEVEL, FRAME, ENTITIES }

Tracking{Category} tracker;
tracker.init(mem);
tracker.set_limit(ENTITIES, mem::mib(16));

// The level and the frame share one buffer from opposite ends.
Stack stack;
stack.init_alloc(tracker.allocator(LEVEL), mem::mib(256))!;
Allocator level = stack.allocator(BACK);
Allocator frame = stack.allocator(FRONT);

// Entities come out of a pool: no search, no fragmentation ever.
Pool{Entity} entities;
entities.init_alloc(tracker.allocator(ENTITIES), 4096)!;

float[] mesh = alloc::alloc_array(level, float, 200_000);

while (running)
{
    defer stack.reset(FRONT);
    Index[] visible = alloc::alloc_array(frame, Index, entities.live);
    ...
}

defer tracker.report_to_stderr();   // where it all went, at shutdown
```

`c3c run demo` runs the whole of that, with the frame arena's high-water mark,
the two ends of the stack drawn as they fill, two thousand turns of pool churn,
a region fragmenting until it refuses an allocation it has room for, and the
report at the end.

## Build

```bash
c3c test          # run the test suite
c3c run demo      # build and run the demo tour
```

## Layout

```
fluxion_mem.c3l/manifest.json   what a consumer's build reads
src/                            the library, one module per file
examples/demo.c3                the tour
project.json5                   this repository's own build: tests and the demo
```

## Requirements

C3 0.8.3. No dependencies, and nothing to link against.

## License

Boost Software License 1.0. See [LICENSE](LICENSE).

Permissive, and short enough to read in a minute: use it, change it, ship it,
in anything. The one obligation is that the copyright notice and the licence
text travel with the *source* - a binary built from it carries nothing, which
is the difference from MIT and BSD and the reason this is the usual choice for
a library that ends up compiled into someone else's program.

The rest of the Fluxion libraries are CC0. This one is not, so a project that
vendors it has one file to keep.
