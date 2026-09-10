// SPDX-License-Identifier: BSL-1.0

// Fluxion Mem - allocators that know something about their memory that a
// general-purpose one cannot.
//
// Six pieces that fit together, each its own module under `fluxion::mem`:
//
//   `layout`     alignment arithmetic, the allocation header, and a readable size
//   `arena`      hand out from one end, give it all back at once
//   `stack`      one buffer, handed out from both ends
//   `pool`       a fixed number of slots, all one type
//   `free_list`  any size, freed in any order, joined back together
//   `tracking`   what another allocator did, per category
//
// C3's standard library already has a general-purpose allocator, and it is a
// good one. Nothing here replaces it. What these do is exploit something known
// about the memory that `malloc` cannot be told:
//
// | If you know | then | and it costs |
// | --- | --- | --- |
// | it all dies at the end of the frame | `Arena` | an add |
// | there are two lifetimes, not many | `Stack` | an add |
// | everything is the same type | `Pool` | a pointer swap |
// | it is a fixed budget, freed in any order | `FreeList` | a short search |
// | you want to know where it went | `Tracking` | a few counters |
//
// **Nothing here grows.** Every allocator takes its buffer once and returns
// `mem::OUT_OF_MEMORY` when it is full, rather than quietly asking the
// operating system for more. That is the point: an allocator that grows
// silently is a frame spike you hear about from a player. Every one of them
// keeps a `high_water` mark instead, which is the number to size the buffer
// by - measure it once, set it, and the run never allocates again.
//
// **They compose.** All of them take an `Allocator` or hand one out, so a
// frame arena inside a tracked category inside the heap is three lines and no
// glue.
//
// **One thread at a time.** None of these lock. An allocator shared between
// threads needs a lock around it, and the usual answer in an engine is not to
// share one: give each worker its own arena, which is cheaper than any lock
// and is why per-thread scratch is the pattern it is.
//
// This module holds the shorthands. Importing `fluxion::mem` imports the
// sub-modules with it, so `Arena`, `Stack`, `Pool{T}`, `FreeList` and
// `Tracking{T}` are all in scope from one line.
module fluxion::mem;
import fluxion::mem::layout, fluxion::mem::arena, fluxion::mem::stack;
import fluxion::mem::pool, fluxion::mem::pooling, fluxion::mem::free_list;
import fluxion::mem::tracking, fluxion::mem::counters;
import std::core::mem::alloc;
import std::io;

<*
 A number of bytes, printed the way a person reads one: `%s` with
 `mem::size(n)` in it gives `324.4 MiB`. Shorthand for `layout::size`.
*>
fn Size size(sz bytes) => layout::size(bytes);

// Kibibytes, mebibytes and gibibytes, for sizing a buffer at a call site
// without counting zeroes.
//
// The parameter is written `$n`, which in C3 means it has to be known at
// compile time. That is what lets `char[mem::kib(64)] buffer;` be an array
// size rather than a call - and buffer sizes are exactly the thing that should
// be decided when the program is built rather than while it runs.

<*
 @require $n >= 0
*>
macro sz kib($n) @const => (sz)$n << 10;

<*
 @require $n >= 0
*>
macro sz mib($n) @const => (sz)$n << 20;

<*
 @require $n >= 0
*>
macro sz gib($n) @const => (sz)$n << 30;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

struct Entity
{
	float x;
	float y;
	ushort health;
}

enum Category
{
	LEVEL,
	FRAME,
	ENTITIES,
}

alias Entities = Pool{Entity};
alias EntitySlot = Slot{Entity};
alias Tracker = Tracking{Category};

fn void test_shorthands() @test
{
	test::eq(kib(1), 1024);
	test::eq(mib(1), 1024 * 1024);
	test::eq(gib(1), 1024 * 1024 * 1024);
	test::eq(mib(4), 4 * 1024 * 1024);

	// They fold at compile time, so they can size an array.
	char[kib(1)] buffer;
	test::eq(buffer.len, 1024);

	test::eq(string::tformat("%s", size(mib(324) + kib(400))), "324.4 MiB");
}

fn void test_the_pieces_compose() @test
{
	// One engine's memory, from the top down.
	Tracker tracker;
	tracker.init(mem);
	tracker.set_limit(LEVEL, mib(1));

	// The level and the frame share one buffer from opposite ends, so neither
	// has to guess how much the other wants.
	Stack stack;
	stack.init_alloc(tracker.allocator(LEVEL), kib(64))!!;
	defer stack.free_from(tracker.allocator(LEVEL));

	Allocator level = stack.allocator(BACK);
	Allocator frame = stack.allocator(FRONT);

	// Entities come out of a pool: same type, so no search and no
	// fragmentation ever.
	Entities entities;
	entities.init_alloc(tracker.allocator(ENTITIES), 512)!!;
	defer entities.free_from(tracker.allocator(ENTITIES));

	// --- load ---------------------------------------------------------
	float[] mesh = alloc::alloc_array(level, float, 1200);
	mesh[..] = 2.5;

	Index[64] alive;
	foreach (i, &handle : alive)
	{
		*handle = entities.create_index()!!;
		*entities.at(*handle) = { .x = (float)i, .y = 0, .health = 100 };
	}

	// --- and then some frames ------------------------------------------
	for (int turn = 0; turn < 120; turn++)
	{
		defer stack.reset(FRONT);

		Index[] visible = alloc::alloc_array(frame, Index, alive.len);
		foreach (i, handle : alive) visible[i] = handle;

		float total = 0;
		foreach (handle : visible) total += entities.at(handle).x;
		test::eq(total, 2016.0f);

		// The level data survives every frame reset.
		test::eq(mesh[600], 2.5f);
	}

	// --- what it cost ---------------------------------------------------
	test::eq(stack.used_by(FRONT), 0);
	test::@check(stack.high_water_of(FRONT) > 0);
	test::eq(entities.live, 64);
	test::eq(entities.high_water, 64);

	// Two categories are holding memory, which at this point is correct.
	test::eq(tracker.leak_count(), 2);
	test::@check(tracker.stats(LEVEL).live_bytes >= kib(64));
	// The frame's allocations went through the stack, so the tracker never
	// saw them - which is the whole point of putting an arena underneath.
	test::@check(tracker.stats(FRAME).is_empty());

	// And a category that runs over its budget is refused here rather than by
	// the machine, later, on somebody else's computer.
	test::@error(alloc::alloc_array_try(tracker.allocator(LEVEL), char, mib(2)),
		std::core::mem::OUT_OF_MEMORY);
	test::eq(tracker.stats(LEVEL).refused_count, 1);
}

fn void test_a_scratch_scope_inside_a_frame() @test
{
	Arena frame;
	frame.init_alloc(mem, kib(16))!!;
	defer frame.free_from(mem);
	Allocator a = (Allocator)&frame;

	char[] kept = alloc::alloc_array(a, char, 100);
	kept[..] = 1;

	// Work that needs room but produces one small answer.
	uint answer;
	{
		Scope scratch = frame.scope();
		defer scratch.end();

		uint[] working = alloc::alloc_array(a, uint, 1000);
		foreach (i, &v : working) *v = (uint)i;

		uint sum = 0;
		foreach (v : working) sum += v;
		answer = sum;
	}

	test::eq(answer, 499_500U);
	// The thousand words of working memory are gone; the hundred bytes stay.
	test::eq(kept[50], (char)1);
	// And the peak remembers what the scope needed, for sizing the buffer.
	test::@check(frame.high_water >= 4000);
}

fn void test_every_allocator_here_satisfies_the_interface_it_hands_out() @test
{
	// The same exercise against all of them, so that a change to any one has
	// to keep working with code that only knows `Allocator`.
	char[kib(32)] arena_backing;
	Arena arena;
	arena.init(&arena_backing);

	char[kib(32)] stack_backing;
	Stack stack;
	stack.init(&stack_backing);

	char[kib(32)] list_backing;
	FreeList list;
	list.init(&list_backing);

	Tracker tracker;
	tracker.init(mem);

	Allocator[] allocators = {
		(Allocator)&arena,
		stack.allocator(FRONT),
		stack.allocator(BACK),
		(Allocator)&list,
		tracker.allocator(FRAME),
	};

	foreach (a : allocators)
	{
		// Slices of several types, and a single value.
		char[] bytes = alloc::alloc_array(a, char, 100);
		ulong[] words = alloc::alloc_array(a, ulong, 50);
		uint* one = alloc::new(a, uint);
		*one = 7;
		test::eq(*one, 7U);

		// A formatted string, which allocates an exact size.
		String text = string::format(a, "%d items", 200);
		test::eq(text, "200 items");

		// And back, in the reverse order, which every one of them handles.
		alloc::free(a, text.ptr);
		alloc::free(a, one);
		alloc::free(a, words.ptr);
		alloc::free(a, bytes.ptr);
	}

	// The one that counts says nothing is left.
	test::@check(!tracker.leaked());
	// The one that coalesces says the region is whole again.
	test::@check(list.verify());
}
