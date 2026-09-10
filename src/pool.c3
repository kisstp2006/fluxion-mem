// SPDX-License-Identifier: BSL-1.0

// A fixed number of slots, all of one type.
//
// When everything being allocated is the same type, the problem a general
// allocator solves does not arise: every free slot fits every request. There
// is no search, no coalescing, no alignment arithmetic and no fragmentation -
// ever. `create` takes the head of a free list and `destroy` puts it back,
// and both are a pointer swap.
//
// **This is deliberately not an `Allocator`.** It hands out one type and one
// size, which is exactly the knowledge that makes it fast, and dressing it up
// in an interface that promises arbitrary sizes would throw that away. Take a
// `Pool{Entity}` where you want entities and an `Allocator` where you want
// bytes.
//
// **Slots are addressable by index as well as by pointer.** `create_index`
// returns a `uint` naming the same slot: a quarter the size of a pointer, and
// what a handle is made of. That is the same index a `fluxion-id` `Handle`
// carries, with a generation counter beside it.
//
// **A double free is caught in every build**, not only a safe one. Each slot's
// link doubles as its liveness flag, so destroying a slot twice is a failed
// assertion rather than a free list that quietly eats itself and hands the
// same slot out to two owners. The check costs nothing: the field is there
// either way.
//
// One thread at a time.
// The parts of a pool that do not depend on the type in it.
//
// They live in a module of their own because everything declared inside a
// generic module is itself generic: an `Index` declared next to `Pool` would
// be `Index{Entity}`, a different type from `Index{Sound}`, which is exactly
// what an index must not be. A slot number is a slot number.
module fluxion::mem::pooling;

<*
 A slot's name, and half of what a handle is.

 32 bits, so four thousand million slots - far past the point where the
 memory would have run out first - and half the size of a pointer on any
 machine this runs on.
*>
alias Index = uint;

// The end of the free list.
const Index NONE = uint::max;
// A slot that is handed out. Sitting in the same field as the free-list link
// is what makes a double free detectable: a live slot's link is this, and a
// free slot's link is an index or `NONE`, so `destroy` can tell them apart
// without a separate byte per slot.
const Index IN_USE = uint::max - 1;

faultdef POOL_FULL, NO_MORE_ENTRIES;

module fluxion::mem::pool <Type>;
import fluxion::mem::layout, fluxion::mem::pooling;
import std::core::mem::alloc;
import std::io, std::math;

<*
 One slot: the value, and either its free-list link or the mark that says it
 is out.

 The link sits beside the value rather than inside the free memory, so that a
 live slot's bytes are entirely the caller's - a `Pool` never scribbles on
 something it has handed out.
*>
struct Slot
{
	Type value;
	Index link;
}

<*
 A fixed number of `Type` slots.
*>
struct Pool
{
	Slot[] slots;
	// The head of the free list, or `NONE` when the pool is full.
	Index first_free;
	// Slots handed out and not given back.
	sz live;
	// The most `live` has ever been. What to size the pool by.
	sz high_water;
}

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

<*
 Over storage the caller owns and outlives the pool.

 Every slot starts free, linked to the next, so the free list begins as the
 whole array in order - which means the first run of `create` calls hands out
 slots in ascending address order, and that is friendlier to a cache than any
 shuffled order would be.

 @param [&inout] self
 @param [inout] storage
*>
fn Pool* Pool.init(&self, Slot[] storage)
{
	self.slots = storage;
	self.live = 0;
	self.high_water = 0;
	self.clear();
	return self;
}

<*
 Over storage taken from `child` once. Pair with `free_from`.

 @param [&inout] self
 @param [&inout] child
 @require count > 0
*>
fn Pool*? Pool.init_alloc(&self, Allocator child, sz count)
{
	Slot[] storage = alloc::alloc_array_try(child, Slot, count)!;
	return self.init(storage);
}

<*
 @param [&inout] self
 @param [&inout] child
*>
fn void Pool.free_from(&self, Allocator child)
{
	alloc::free(child, self.slots.ptr);
	self.slots = {};
	self.live = 0;
	self.first_free = pooling::NONE;
}

<*
 Every slot free again, in order. Does not run destructors: whatever the
 values were is simply forgotten.

 @param [&inout] self
*>
fn void Pool.clear(&self)
{
	foreach (i, &slot : self.slots)
	{
		slot.link = (Index)i + 1;
	}
	if (self.slots.len > 0)
	{
		self.slots[self.slots.len - 1].link = pooling::NONE;
		self.first_free = 0;
	}
	else
	{
		self.first_free = pooling::NONE;
	}
	self.live = 0;
}

// -------------------------------------------------------------------------
// Asking it things
// -------------------------------------------------------------------------

<*
 @param [&in] self
*>
fn sz Pool.capacity(&self) @inline => self.slots.len;

<*
 Slots not handed out. Every one of them can be taken, whatever order the
 previous ones came and went in - which is the difference between a pool and
 a free list.

 @param [&in] self
*>
fn sz Pool.available(&self) @inline => self.slots.len - self.live;

<*
 @param [&in] self
*>
fn bool Pool.is_full(&self) @inline => self.first_free == pooling::NONE;

<*
 @param [&in] self
*>
fn bool Pool.owns(&self, void* ptr)
{
	uptr address = (uptr)ptr;
	uptr start = (uptr)self.slots.ptr;
	return address >= start && address < start + (uptr)(self.slots.len * Slot::size);
}

<*
 Whether the slot named by `index` is currently handed out.

 An index past the end is not live rather than an error, so a stale handle
 from a smaller pool answers "no" instead of reading past the array.

 @param [&in] self
*>
fn bool Pool.is_live(&self, Index index)
{
	if ((sz)index >= self.slots.len) return false;
	return self.slots[index].link == pooling::IN_USE;
}

<*
 The value in a slot, by index.

 @param [&inout] self
 @require (sz)index < self.slots.len : "index past the end of the pool"
*>
fn Type* Pool.at(&self, Index index)
{
	return &self.slots[index].value;
}

<*
 The index of a slot, by pointer.

 Computed from the address rather than from the offset of `value` within
 `Slot`, because a `Slot` can be more strictly aligned than a `Type` and the
 two would then disagree.

 @param [&in] self
 @require self.owns(ptr) : "the pointer did not come from this pool"
*>
fn Index Pool.index_of(&self, Type* ptr)
{
	uptr offset = (uptr)ptr - (uptr)self.slots.ptr;
	return (Index)(offset / (uptr)Slot::size);
}

// -------------------------------------------------------------------------
// Taking and giving back
// -------------------------------------------------------------------------

<*
 A slot, by index. `POOL_FULL` when there is none.

 The index is the form to keep: it survives the pool being moved, it is half
 the size of a pointer, and it is what a generational handle is built on.

 @param [&inout] self
 @return? pooling::POOL_FULL
*>
fn Index? Pool.create_index(&self)
{
	Index index = self.first_free;
	if (index == pooling::NONE) return pooling::POOL_FULL~;

	self.first_free = self.slots[index].link;
	self.slots[index].link = pooling::IN_USE;
	self.live++;
	if (self.live > self.high_water) self.high_water = self.live;
	return index;
}

<*
 A slot, by pointer. `POOL_FULL` when there is none.

 The value is not initialised: whatever the slot last held is still there.
 Use `create_with` to hand the value over at the same time.

 @param [&inout] self
 @return? pooling::POOL_FULL
*>
fn Type*? Pool.create(&self)
{
	return self.at(self.create_index()!);
}

<*
 A slot holding `value`.

 @param [&inout] self
 @return? pooling::POOL_FULL
*>
fn Type*? Pool.create_with(&self, Type value)
{
	Type* slot = self.create()!;
	*slot = value;
	return slot;
}

<*
 Give a slot back, by index.

 Destroying a slot that is already free is a failed assertion rather than
 something that quietly corrupts the free list into a cycle - at which point
 two callers would be handed the same slot and the bug would show up
 somewhere else entirely.

 @param [&inout] self
 @require (sz)index < self.slots.len : "index past the end of the pool"
*>
fn void Pool.destroy_index(&self, Index index)
{
	assert(self.slots[index].link == pooling::IN_USE, "double free, or a slot that was never taken");
	self.slots[index].link = self.first_free;
	self.first_free = index;
	self.live--;
}

<*
 Give a slot back, by pointer.

 @param [&inout] self
 @param [&in] ptr
*>
fn void Pool.destroy(&self, Type* ptr)
{
	self.destroy_index(self.index_of(ptr));
}

// -------------------------------------------------------------------------
// Walking it
// -------------------------------------------------------------------------

<*
 One live slot.
*>
struct Entry
{
	Index index;
	Type* value;
}

<*
 Walks the live slots in index order, skipping the free ones.

 It ends on a fault rather than by returning nothing, so the loop is
 `while (try entry = it.next())` - the same shape every iterator in Fluxion
 has.
*>
struct PoolIterator
{
	Pool* pool;
	Index next_index;
}

<*
 @param [&inout] self
*>
fn PoolIterator Pool.iterator(&self)
{
	return { .pool = self, .next_index = 0 };
}

<*
 @param [&inout] self
 @return? pooling::NO_MORE_ENTRIES
*>
fn Entry? PoolIterator.next(&self)
{
	while ((sz)self.next_index < self.pool.slots.len)
	{
		Index index = self.next_index++;
		if (self.pool.slots[index].link == pooling::IN_USE)
		{
			return { .index = index, .value = self.pool.at(index) };
		}
	}
	return pooling::NO_MORE_ENTRIES~;
}

// -------------------------------------------------------------------------
// Printing
// -------------------------------------------------------------------------

fn sz? Pool.to_format(&self, Formatter* formatter) @dynamic
{
	return formatter.printf("%d of %d slots live, peak %d, %s",
		self.live, self.slots.len, self.high_water,
		layout::size(self.slots.len * Slot::size));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

// A generic module is only compiled once something asks for an instance of
// it, so the tests live in a plain module underneath that names the instances
// it wants. Anything tested here is tested for real, for those types.
module fluxion::mem::pool_test @test;
import fluxion::mem::pool, fluxion::mem::pooling;
import std::math::random;
import std::collections::list;

struct Entity
{
	float x;
	float y;
	ushort health;
}

alias Entities = Pool{Entity};
alias EntitySlot = Slot{Entity};
alias Numbers = Pool{int};
alias Chars = Pool{char};
alias CharSlot = Slot{char};
alias NumberSlot = Slot{int};

fn void a_fresh_pool_is_all_free()
{
	EntitySlot[16] storage;
	Entities pool;
	pool.init(&storage);

	test::eq(pool.capacity(), 16);
	test::eq(pool.available(), 16);
	test::eq(pool.live, 0);
	test::@check(!pool.is_full());
}

fn void create_and_destroy_are_a_pointer_swap()
{
	EntitySlot[16] storage;
	Entities pool;
	pool.init(&storage);

	Entity* player = pool.create()!!;
	*player = { .x = 1, .y = 2, .health = 100 };
	test::eq(pool.live, 1);
	test::eq(pool.available(), 15);

	pool.destroy(player);
	test::eq(pool.live, 0);
	test::eq(pool.available(), 16);
}

fn void the_first_slots_come_out_in_order()
{
	NumberSlot[8] storage;
	Numbers pool;
	pool.init(&storage);

	// Ascending addresses on a fresh pool, which is what walking the array
	// afterwards wants.
	int* previous = pool.create()!!;
	for (int i = 1; i < 8; i++)
	{
		int* next = pool.create()!!;
		test::@check((uptr)next > (uptr)previous);
		previous = next;
	}
}

fn void a_full_pool_says_so_rather_than_growing()
{
	NumberSlot[4] storage;
	Numbers pool;
	pool.init(&storage);

	for (int i = 0; i < 4; i++) pool.create()!!;
	test::@check(pool.is_full());
	test::@error(pool.create(), pooling::POOL_FULL);
	test::@error(pool.create_index(), pooling::POOL_FULL);
}

fn void a_freed_slot_is_handed_out_again()
{
	NumberSlot[4] storage;
	Numbers pool;
	pool.init(&storage);

	for (int i = 0; i < 4; i++) pool.create()!!;
	Index freed = 2;
	pool.destroy_index(freed);

	// The most recently freed slot is the next one out, because the free list
	// is a stack. That is also the friendliest order for a cache.
	test::eq(pool.create_index()!!, freed);
}

fn void indexes_and_pointers_name_the_same_slot()
{
	EntitySlot[16] storage;
	Entities pool;
	pool.init(&storage);

	Index index = pool.create_index()!!;
	Entity* ptr = pool.at(index);
	*ptr = { .x = 3, .y = 4, .health = 50 };

	test::eq(pool.index_of(ptr), index);
	test::eq(pool.at(index).health, (ushort)50);
	test::@check(pool.owns(ptr));
}

fn void index_of_survives_a_more_strictly_aligned_slot()
{
	// A `Slot{char}` is padded out to the alignment of its link, so the
	// distance between two values is not `sizeof(char)`. Computing the index
	// from the slot size rather than the value size is what makes this work.
	CharSlot[8] storage;
	Chars pool;
	pool.init(&storage);

	for (Index i = 0; i < 8; i++)
	{
		Index index = pool.create_index()!!;
		test::eq(index, i);
		test::eq(pool.index_of(pool.at(index)), index);
	}
}

fn void is_live_tells_taken_from_free()
{
	NumberSlot[8] storage;
	Numbers pool;
	pool.init(&storage);

	Index index = pool.create_index()!!;
	test::@check(pool.is_live(index));
	pool.destroy_index(index);
	test::@check(!pool.is_live(index));
	// A stale index from a bigger pool answers rather than reading past the
	// end.
	test::@check(!pool.is_live(9999));
}

fn void owns_says_what_came_from_here()
{
	NumberSlot[8] mine;
	NumberSlot[8] theirs;
	Numbers pool;
	pool.init(&mine);

	int* p = pool.create()!!;
	test::@check(pool.owns(p));
	test::@check(!pool.owns(&theirs[0]));
}

fn void the_iterator_walks_only_the_live_slots()
{
	NumberSlot[16] storage;
	Numbers pool;
	pool.init(&storage);

	Index[16] taken;
	for (int i = 0; i < 16; i++)
	{
		taken[i] = pool.create_index()!!;
		*pool.at(taken[i]) = i;
	}
	// Free every other one.
	for (int i = 0; i < 16; i += 2) pool.destroy_index(taken[i]);

	sz seen = 0;
	PoolIterator{int} it = pool.iterator();
	while (try entry = it.next())
	{
		test::@check(pool.is_live(entry.index));
		// The value is odd, because the even ones were freed.
		test::@check(*entry.value % 2 == 1);
		seen++;
	}
	test::eq(seen, 8);
	test::eq(seen, pool.live);
}

fn void the_high_water_mark_is_the_worst_moment_not_the_last()
{
	NumberSlot[64] storage;
	Numbers pool;
	pool.init(&storage);

	Index[40] taken;
	for (int i = 0; i < 40; i++) taken[i] = pool.create_index()!!;
	for (int i = 0; i < 40; i++) pool.destroy_index(taken[i]);

	test::eq(pool.live, 0);
	test::eq(pool.high_water, 40);
}

fn void clear_frees_everything_whatever_was_live()
{
	NumberSlot[16] storage;
	Numbers pool;
	pool.init(&storage);

	for (int i = 0; i < 10; i++) pool.create()!!;
	pool.clear();

	test::eq(pool.live, 0);
	test::eq(pool.available(), 16);
	// And all sixteen can be taken again.
	for (int i = 0; i < 16; i++) pool.create()!!;
	test::@check(pool.is_full());
}

fn void a_pool_never_fragments()
{
	// The property that makes this worth having: after any amount of churn,
	// whatever is free can still be handed out, because every free slot fits
	// every request. A free list cannot promise that.
	NumberSlot[128] storage;
	Numbers pool;
	pool.init(&storage);

	List{Index} live;
	live.init(mem);
	defer live.free();

	Random rng = (Random)&&(Sfc64Random){};
	random::seed(rng, 0xE0717EUL);

	for (int turn = 0; turn < 5000; turn++)
	{
		if (live.len() > 0 && random::next_bool(rng))
		{
			sz which = (sz)random::next(rng, (int)live.len());
			pool.destroy_index(live[which]);
			live.swap(which, live.len() - 1);
			live.pop()!!;
		}
		else
		{
			if (try index = pool.create_index()) live.push(index);
		}
	}

	sz still_free = pool.available();
	sz taken = 0;
	while (try index = pool.create_index()) taken++;
	test::eq(taken, still_free);
	test::@check(pool.is_full());
}

fn void live_slots_never_overlap()
{
	EntitySlot[64] storage;
	Entities pool;
	pool.init(&storage);

	List{Entity*} live;
	live.init(mem);
	defer live.free();

	for (int i = 0; i < 64; i++) live.push(pool.create()!!);

	foreach (i, x : live)
	{
		for (sz j = (sz)i + 1; j < live.len(); j++)
		{
			test::@check(x != live[j]);
		}
	}
}

fn void a_value_survives_its_neighbours_coming_and_going()
{
	EntitySlot[32] storage;
	Entities pool;
	pool.init(&storage);

	Index kept = pool.create_index()!!;
	*pool.at(kept) = { .x = 7, .y = 8, .health = 42 };

	for (int turn = 0; turn < 100; turn++)
	{
		Index temporary = pool.create_index()!!;
		*pool.at(temporary) = { .x = 0, .y = 0, .health = 1 };
		pool.destroy_index(temporary);
	}

	test::eq(pool.at(kept).health, (ushort)42);
	test::eq(pool.at(kept).x, 7.0f);
}

fn void it_borrows_its_storage_from_another_allocator()
{
	Entities pool;
	pool.init_alloc(mem, 512)!!;
	defer pool.free_from(mem);

	test::eq(pool.capacity(), 512);
	Entity* e = pool.create()!!;
	test::@check(pool.owns(e));
}

fn void printing_says_how_full_it_is()
{
	EntitySlot[512] storage;
	Entities pool;
	pool.init(&storage);
	for (int i = 0; i < 64; i++) pool.create()!!;

	String printed = string::tformat("%s", &pool);
	test::@check(printed.contains("64 of 512 slots live"));
	test::@check(printed.contains("peak 64"));
}
