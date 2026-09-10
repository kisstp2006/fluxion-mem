// SPDX-License-Identifier: BSL-1.0

// Hand out from one end, give it all back at once.
//
// The cheapest allocator there is. An allocation is a bounds check and an
// addition; freeing everything is setting one number back to zero. That is
// the whole idea, and the reason it is the first thing a frame loop reaches
// for: whatever a frame allocates, the frame's end reclaims, and no
// individual `free` ever has to be written or remembered.
//
// **It never grows.** Given a buffer, it hands out of that buffer and
// returns `mem::OUT_OF_MEMORY` when it is full, rather than quietly asking
// the operating system for more. An allocator that grows silently is a frame
// spike a player finds for you. `high_water` is the number to size the buffer
// by instead: run it once, read the peak, set the buffer to that, and the
// run never allocates again.
//
// `mark` and `restore` turn the same arena into a stack allocator, and
// `scope` is that with `defer` doing the restoring. Freeing the most recent
// allocation reclaims it exactly, so a loop that allocates and frees in
// reverse order does not grow at all.
//
// One thread at a time. Two threads sharing an arena race on `used`.
module fluxion::mem::arena;
import fluxion::mem::layout;
import std::core::mem::allocators, std::core::mem::alloc;
import std::collections::list;
import std::io, std::math;

// What a released or reset byte is filled with in a safe build, so that
// reading through a stale pointer gives obvious rubbish rather than the value
// that happened to be there. 0xA5 is a poor address, a poor float and a poor
// character, which is what makes it a good poison.
const char POISON @local = 0xA5;

<*
 A remembered position in the arena, from `mark`.

 A distinct type rather than a bare `sz` so that a mark cannot be confused
 with a size, a count or an index - the three other `sz` values in scope
 wherever marks are used.
*>
typedef Mark = sz;

<*
 A bump allocator over memory the caller owns.

 Implements C3's `Allocator`, so `(Allocator)&arena` goes anywhere an
 allocator does and everything underneath allocates from the buffer without
 knowing it.
*>
struct Arena (Allocator)
{
	// The memory handed out of. Never grown, never reallocated.
	char[] buffer;
	// Bytes of `buffer` spent, including headers and alignment padding.
	sz used;
	// The most `used` has ever been. What to size the buffer by.
	sz high_water;
}

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

<*
 Over memory the caller owns and outlives the arena.

 Returns `&self` so that `Arena a; a.init(&backing);` and
 `Arena* a = (Arena){}.init(&backing);` both read naturally - the same shape
 the standard library's own allocators use.

 @param [&inout] self
 @param [inout] buffer : "the memory to hand out of"
*>
fn Arena* Arena.init(&self, char[] buffer)
{
	self.buffer = buffer;
	self.used = 0;
	self.high_water = 0;
	return self;
}

<*
 Over memory taken from `child` once. Pair with `free_from`.

 @param [&inout] self
 @param [&inout] child
 @require size > 0
*>
fn Arena*? Arena.init_alloc(&self, Allocator child, sz size)
{
	char[] buffer = alloc::alloc_array_try(child, char, size)!;
	return self.init(buffer);
}

<*
 Give the buffer back to the allocator it came from. Only for an arena made
 with `init_alloc`.

 @param [&inout] self
 @param [&inout] child
*>
fn void Arena.free_from(&self, Allocator child)
{
	alloc::free(child, self.buffer.ptr);
	self.buffer = {};
	self.used = 0;
}

// -------------------------------------------------------------------------
// Giving it all back
// -------------------------------------------------------------------------

<*
 Everything free again. Does not run destructors and does not care what was
 live: every pointer handed out before this call is dangling afterwards.

 The high-water mark survives, because the point of it is to remember the
 worst frame rather than the current one.

 @param [&inout] self
*>
fn void Arena.reset(&self)
{
	$if env::COMPILER_SAFE_MODE:
		if (self.used > 0) self.buffer[:self.used][..] = POISON;
	$endif
	self.used = 0;
}

// -------------------------------------------------------------------------
// Marks and scopes
// -------------------------------------------------------------------------

<*
 The current position, to hand to `restore`.

 @param [&in] self
*>
fn Mark Arena.mark(&self)
{
	return (Mark)self.used;
}

<*
 Back to where `mark` was taken. Everything allocated since is freed.

 Restoring to a mark that is already behind the current position would hand
 out memory that is still live, so it is refused rather than obeyed.

 @param [&inout] self
 @require (sz)mark <= self.used : "a mark can only be restored backwards"
*>
fn void Arena.restore(&self, Mark mark)
{
	sz to = (sz)mark;
	$if env::COMPILER_SAFE_MODE:
		if (self.used > to) self.buffer[to:self.used - to][..] = POISON;
	$endif
	self.used = to;
}

<*
 A mark that restores itself, for `defer`.

 ```c3
 Scope scratch = frame.scope();
 defer scratch.end();
 ```

 Which is the arena used as a stack: the working memory inside the block is
 gone at the end of it, and whatever was allocated before it is untouched.
*>
struct Scope
{
	Arena* arena;
	Mark mark;
}

<*
 @param [&inout] self
*>
fn Scope Arena.scope(&self)
{
	return { .arena = self, .mark = self.mark() };
}

<*
 @param [&in] self
*>
fn void Scope.end(&self)
{
	self.arena.restore(self.mark);
}

// -------------------------------------------------------------------------
// Asking it things
// -------------------------------------------------------------------------

<*
 @param [&in] self
*>
fn sz Arena.capacity(&self) @inline => self.buffer.len;

<*
 Bytes not yet spent. Not the same as the largest allocation that would
 succeed, which is a little less: a header and some alignment padding come out
 of this first.

 @param [&in] self
*>
fn sz Arena.remaining(&self) @inline => self.buffer.len - self.used;

<*
 Whether `ptr` came out of this arena.

 @param [&in] self
*>
fn bool Arena.owns(&self, void* ptr)
{
	return layout::owns(self.buffer, ptr);
}

<*
 Whether `ptr` is the most recent allocation still outstanding - the one, and
 the only one, that `release` can reclaim.

 @param [&in] self
*>
fn bool Arena.is_last(&self, void* ptr)
{
	if (!self.owns(ptr)) return false;
	Header* header = layout::header_of(ptr);
	return ptr + header.bytes == (void*)self.buffer.ptr + self.used;
}

// -------------------------------------------------------------------------
// The allocator
// -------------------------------------------------------------------------

<*
 Implements the `Allocator` interface.

 @param [&inout] self
 @require size > 0
 @require !alignment || math::is_power_of_2(alignment)
 @return? mem::OUT_OF_MEMORY
*>
fn void*? Arena.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	alignment = allocators::alignment_for_allocation(alignment);

	// Reserve room for the header first and align the payload after it, so
	// that the header always fits however strict the alignment is.
	void* from = (void*)self.buffer.ptr + self.used;
	void* payload = layout::payload_after(from, alignment);

	sz end = (sz)((uptr)payload - (uptr)self.buffer.ptr) + size;
	if (end > self.buffer.len) return mem::OUT_OF_MEMORY~;

	Header* header = layout::header_of(payload);
	header.bytes = size;
	header.pad = (sz)((uptr)payload - (uptr)from);
	header.tail = 0;

	self.used = end;
	if (self.used > self.high_water) self.high_water = self.used;

	if (init_type == ZERO) mem::clear(payload, (usz)size);
	return payload;
}

<*
 Implements the `Allocator` interface.

 Grows or shrinks in place when the block is the most recent one, which is
 what makes a builder appending into an arena cost nothing per append.
 Otherwise it allocates and copies, because a bump allocator has nowhere else
 to put the block.

 @param [&inout] self
 @require ptr != null
 @require new_size > 0
 @require !alignment || math::is_power_of_2(alignment)
 @return? mem::OUT_OF_MEMORY
*>
fn void*? Arena.resize(&self, void* ptr, sz new_size, sz alignment) @dynamic
{
	alignment = allocators::alignment_for_allocation(alignment);
	assert(self.owns(ptr), "the pointer did not come from this arena");

	Header* header = layout::header_of(ptr);
	sz old_size = header.bytes;

	if (self.is_last(ptr) && layout::ptr_is_aligned(ptr, alignment))
	{
		sz end = (sz)((uptr)ptr - (uptr)self.buffer.ptr) + new_size;
		if (end > self.buffer.len) return mem::OUT_OF_MEMORY~;
		header.bytes = new_size;
		self.used = end;
		if (self.used > self.high_water) self.high_water = self.used;
		return ptr;
	}

	void* moved = self.acquire(new_size, NO_ZERO, alignment)!;
	mem::copy(moved, ptr, (usz)math::min(new_size, old_size));
	return moved;
}

<*
 Implements the `Allocator` interface.

 Reclaims the block if it is the most recent one, and does nothing at all
 otherwise. That is not a bug being tolerated: an arena's contract is that the
 reset frees everything, and freeing out of order is a no-op by design rather
 than an error, so that code written against a general allocator still runs
 correctly here.

 @param [&inout] self
 @param [&in] ptr
 @require ptr != null
*>
fn void Arena.release(&self, void* ptr, bool aligned) @dynamic
{
	assert(self.owns(ptr), "the pointer did not come from this arena");
	if (!self.is_last(ptr)) return;

	// Back past the payload, the header and the alignment padding in one
	// step, which is what `pad` is kept for: an aligned allocation reclaims
	// its own padding rather than leaving a few bytes behind each time.
	Header* header = layout::header_of(ptr);
	sz to = (sz)((uptr)ptr - (uptr)self.buffer.ptr) - header.pad;
	self.restore((Mark)to);
}

// -------------------------------------------------------------------------
// Printing
// -------------------------------------------------------------------------

fn sz? Arena.to_format(&self, Formatter* formatter) @dynamic
{
	return formatter.printf("%s of %s used, peak %s",
		layout::size(self.used),
		layout::size(self.capacity()),
		layout::size(self.high_water));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

// Allocate and let the block go. Several tests care only that the arena
// moved, not where to - and `alloc_array` is @nodiscard, so the result has to
// be assigned somewhere. Wrapping it here keeps that noise out of the tests.
fn char[] spend(Allocator a, sz bytes) @local
{
	return alloc::alloc_array(a, char, bytes);
}

fn void test_a_fresh_arena_is_empty() @test
{
	char[4096] backing;
	Arena a;
	a.init(&backing);

	test::eq(a.used, 0);
	test::eq(a.capacity(), 4096);
	test::eq(a.remaining(), 4096);
	test::eq(a.high_water, 0);
}

fn void test_allocation_is_a_bump() @test
{
	char[4096] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	int[] first = alloc::alloc_array(a, int, 10);
	sz after_first = arena.used;
	test::@check(after_first >= 40);

	int[] second = alloc::alloc_array(a, int, 10);
	// The second starts after the first, and they do not overlap.
	test::@check((uptr)second.ptr > (uptr)first.ptr);
	test::@check((uptr)second.ptr >= (uptr)first.ptr + 40);
	test::@check(arena.used > after_first);
}

fn void test_reset_gives_it_all_back() @test
{
	char[4096] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	for (int i = 0; i < 10; i++) spend(a, 64);
	test::@check(arena.used > 0);
	sz peak = arena.high_water;

	arena.reset();
	test::eq(arena.used, 0);
	test::eq(arena.remaining(), 4096);
	// The peak is what the buffer has to be sized for, so it outlives the
	// frame that set it.
	test::eq(arena.high_water, peak);
}

fn void test_the_high_water_mark_is_the_worst_frame_not_the_last() @test
{
	char[4096] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	spend(a, 2000);
	sz worst = arena.used;
	arena.reset();

	spend(a, 100);
	test::@check(arena.used < worst);
	test::eq(arena.high_water, worst);
}

fn void test_it_refuses_rather_than_growing() @test
{
	char[256] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	// A request larger than the whole buffer can never be served.
	void*? too_big = arena.acquire(1024, NO_ZERO, 0);
	test::@error(too_big, mem::OUT_OF_MEMORY);

	// And filling it up refuses the next one rather than asking the operating
	// system for more.
	spend(a, 200);
	test::@error(arena.acquire(200, NO_ZERO, 0), mem::OUT_OF_MEMORY);
}

fn void test_alignment_is_honoured() @test
{
	char[8192] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	foreach (alignment : (sz[]){ 16, 32, 64, 128, 256 })
	{
		// Something small first, so the next allocation does not start
		// aligned by accident.
		arena.acquire(1, NO_ZERO, 0)!!;
		void* p = arena.acquire(40, NO_ZERO, alignment)!!;
		test::@check(layout::ptr_is_aligned(p, alignment));
		test::@check(arena.owns(p));
	}
}

fn void test_zeroed_memory_is_zeroed() @test
{
	char[1024] backing;
	backing[..] = 0xFF;
	Arena arena;
	arena.init(&backing);

	char* p = arena.acquire(64, ZERO, 0)!!;
	for (sz i = 0; i < 64; i++) test::eq(p[i], (char)0);
}

fn void test_mark_and_restore_make_it_a_stack() @test
{
	char[4096] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	spend(a, 100);
	sz kept = arena.used;

	Mark mark = arena.mark();
	spend(a, 1000);
	test::@check(arena.used > kept);

	arena.restore(mark);
	test::eq(arena.used, kept);
	// And the space comes back for something else.
	spend(a, 1000);
	test::@check(arena.used > kept);
}

fn void test_a_scope_restores_itself() @test
{
	char[4096] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	char[] kept = alloc::alloc_array(a, char, 100);
	kept[..] = 7;
	sz before = arena.used;

	{
		Scope scratch = arena.scope();
		defer scratch.end();
		spend(a, 2000);
		test::@check(arena.used >= before + 2000);
	}

	test::eq(arena.used, before);
	// The memory from before the scope is untouched.
	test::eq(kept[50], (char)7);
	// And the peak remembers what the scope needed, which is the point of
	// measuring rather than guessing.
	test::@check(arena.high_water >= 2000);
}

fn void test_freeing_the_last_allocation_reclaims_it() @test
{
	char[4096] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	spend(a, 100);
	sz before = arena.used;

	void* last = arena.acquire(500, NO_ZERO, 0)!!;
	test::@check(arena.is_last(last));
	arena.release(last, false);
	// Exactly back, header and alignment padding included.
	test::eq(arena.used, before);
}

fn void test_freeing_out_of_order_is_a_no_op_not_an_error() @test
{
	char[4096] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	void* first = arena.acquire(100, NO_ZERO, 0)!!;
	arena.acquire(100, NO_ZERO, 0)!!;
	sz used = arena.used;

	// Code written against a general allocator frees in whatever order it
	// likes. Here that is simply ignored - the reset is what frees.
	test::@check(!arena.is_last(first));
	arena.release(first, false);
	test::eq(arena.used, used);
}

fn void test_a_loop_that_frees_in_reverse_order_never_grows() @test
{
	char[1024] backing;
	Arena arena;
	arena.init(&backing);

	for (int i = 0; i < 1000; i++)
	{
		void* p = arena.acquire(64, NO_ZERO, 0)!!;
		arena.release(p, false);
	}
	test::eq(arena.used, 0);
	// A thousand turns through a buffer that holds a handful of them at once.
	test::@check(arena.high_water <= 1024);
}

fn void test_resize_grows_the_last_block_in_place() @test
{
	char[4096] backing;
	Arena arena;
	arena.init(&backing);

	void* p = arena.acquire(100, NO_ZERO, 0)!!;
	void* grown = arena.resize(p, 500, 0)!!;
	test::@check(grown == p);
	test::eq(layout::header_of(grown).bytes, 500);

	// Shrinking the last block hands the tail back.
	sz used = arena.used;
	arena.resize(grown, 50, 0)!!;
	test::@check(arena.used < used);
}

fn void test_resize_of_an_older_block_copies() @test
{
	char[4096] backing;
	Arena arena;
	arena.init(&backing);

	char* p = arena.acquire(16, NO_ZERO, 0)!!;
	for (sz i = 0; i < 16; i++) p[i] = (char)i;
	arena.acquire(16, NO_ZERO, 0)!!; // a wall, so `p` is no longer last

	char* moved = arena.resize(p, 64, 0)!!;
	test::@check(moved != p);
	// The contents came with it.
	for (sz i = 0; i < 16; i++) test::eq(moved[i], (char)i);
}

fn void test_a_growing_list_lives_in_it() @test
{
	char[8192] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	List{int} items;
	items.init(a);

	for (int i = 0; i < 300; i++) items.push(i);
	test::eq(items.len(), 300);
	for (int i = 0; i < 300; i++) test::eq(items[i], i);
}

fn void test_a_formatted_string_lives_in_it() @test
{
	char[4096] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	String text = string::format(a, "%d items", 200);
	test::eq(text, "200 items");
}

fn void test_owns_says_what_came_from_here() @test
{
	char[1024] backing;
	char[1024] elsewhere;
	Arena arena;
	arena.init(&backing);

	void* mine = arena.acquire(64, NO_ZERO, 0)!!;
	test::@check(arena.owns(mine));
	test::@check(!arena.owns(&elsewhere[0]));
}

fn void test_it_borrows_a_buffer_from_another_allocator() @test
{
	Arena arena;
	arena.init_alloc(mem, 4096)!!;
	defer arena.free_from(mem);

	test::eq(arena.capacity(), 4096);
	void* p = arena.acquire(1000, NO_ZERO, 0)!!;
	test::@check(arena.owns(p));
}

fn void test_printing_says_how_full_it_is() @test
{
	char[4096] backing;
	Arena arena;
	arena.init(&backing);
	arena.acquire(1024, NO_ZERO, 0)!!;

	String printed = string::tformat("%s", &arena);
	test::@check(printed.contains("of 4.0 KiB used"));
	test::@check(printed.contains("peak"));
}
