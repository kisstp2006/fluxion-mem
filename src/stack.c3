// SPDX-License-Identifier: BSL-1.0

// One buffer, handed out from both ends at once.
//
// Two bump allocators facing each other. The oldest layout in games, and
// still the right one whenever memory divides into two lifetimes rather than
// many: the level from the back, the frame from the front, and the free space
// between them belongs to whichever needs it. Two separate arenas cannot do
// that - each would have to be given a budget in advance, and one of the two
// guesses would be wrong.
//
// ```
// <<<<<<<<<<<<...........................>>>>>>>>>>>>
// front, growing right      free       back, growing left
// ```
//
// **How the two ends are told apart is the one place this differs from the
// Zig original.** There, `side` was a comptime parameter and each end got its
// own generated vtable, so the choice cost nothing at run time. C3's
// `Allocator` is an interface: a value implementing it is a pointer to
// something, and the something has to exist. So a `Stack` contains two small
// `StackEnd` values, one per side, and hands out a pointer to one of them.
// The cost is a pointer hop and one branch per allocation, which against a
// bump allocator's two instructions is real but tiny - and the interface is
// the same either way, which is what matters to everything downstream.
//
// **A `Stack` must not be copied once initialised.** The two ends hold a
// pointer back to it, so a copy would have ends pointing at the original.
// Build it where it will live and pass it by pointer, which is how an
// allocator wants to be treated anyway.
//
// One thread at a time.
module fluxion::mem::stack;
import fluxion::mem::layout;
import std::core::mem::allocators, std::core::mem::alloc;
import std::collections::list;
import std::io, std::math;

// Distinct from the arena's poison, so that a byte read through a stale
// pointer says which allocator it came from.
const char POISON @local = 0x5A;

<*
 Which end of the buffer.

 `FRONT` grows towards higher addresses and is the short-lived end - the
 frame. `BACK` grows towards lower addresses and is the long-lived end - the
 level.
*>
enum Side
{
	FRONT,
	BACK,
}

<*
 A remembered position at one end, from `Stack.mark`.
*>
typedef Mark = sz;

<*
 One end of a `Stack`, as an `Allocator`.

 Never built by hand: `stack.allocator(FRONT)` hands one out, already wired to
 the stack that owns it.
*>
struct StackEnd (Allocator)
{
	Stack* stack;
	Side side;
}

<*
 A buffer handed out from both ends.
*>
struct Stack
{
	char[] buffer;
	// Bytes spent at each end, headers and padding included. They meet in the
	// middle, and the allocation that would make them cross is refused.
	sz[2] used;
	sz[2] high_water;
	// One `StackEnd` per side, so that `allocator` has something whose address
	// it can hand out. See the note at the top of the file.
	StackEnd[2] ends;
}

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

<*
 Over memory the caller owns and outlives the stack.

 @param [&inout] self
 @param [inout] buffer : "the memory to hand out of"
*>
fn Stack* Stack.init(&self, char[] buffer)
{
	self.buffer = buffer;
	self.used = { 0, 0 };
	self.high_water = { 0, 0 };
	self.ends[0] = { .stack = self, .side = FRONT };
	self.ends[1] = { .stack = self, .side = BACK };
	return self;
}

<*
 Over memory taken from `child` once. Pair with `free_from`.

 @param [&inout] self
 @param [&inout] child
 @require size > 0
*>
fn Stack*? Stack.init_alloc(&self, Allocator child, sz size)
{
	char[] buffer = alloc::alloc_array_try(child, char, size)!;
	return self.init(buffer);
}

<*
 @param [&inout] self
 @param [&inout] child
*>
fn void Stack.free_from(&self, Allocator child)
{
	alloc::free(child, self.buffer.ptr);
	self.buffer = {};
	self.used = { 0, 0 };
}

<*
 The allocator for one end. Hand this down; everything under it allocates
 from that side.

 @param [&inout] self
*>
fn Allocator Stack.allocator(&self, Side side)
{
	return (Allocator)&self.ends[side.ordinal];
}

// -------------------------------------------------------------------------
// Asking it things
// -------------------------------------------------------------------------

<*
 @param [&in] self
*>
fn sz Stack.capacity(&self) @inline => self.buffer.len;

<*
 @param [&in] self
*>
fn sz Stack.used_by(&self, Side side) @inline => self.used[side.ordinal];

<*
 @param [&in] self
*>
fn sz Stack.high_water_of(&self, Side side) @inline => self.high_water[side.ordinal];

<*
 What neither end has claimed. This is the number that matters, because it is
 what both ends are still free to spend.

 @param [&in] self
*>
fn sz Stack.remaining(&self) @inline => self.buffer.len - self.used[0] - self.used[1];

<*
 @param [&in] self
*>
fn bool Stack.owns(&self, void* ptr) => layout::owns(self.buffer, ptr);

<*
 Which end `ptr` came from, or a fault if it came from neither.

 @param [&in] self
*>
fn Side? Stack.side_of(&self, void* ptr)
{
	if (!self.owns(ptr)) return NOT_FROM_HERE~;
	sz offset = (sz)((uptr)ptr - (uptr)self.buffer.ptr);
	return offset < self.used[0] ? FRONT : BACK;
}

faultdef NOT_FROM_HERE;

// -------------------------------------------------------------------------
// Giving it back
// -------------------------------------------------------------------------

<*
 Everything at one end free again. The other end is untouched, which is the
 whole reason the two share a buffer: `reset(FRONT)` at the end of every frame
 never disturbs the level.

 @param [&inout] self
*>
fn void Stack.reset(&self, Side side)
{
	self.restore(side, (Mark)0);
}

<*
 The current position at one end.

 @param [&in] self
*>
fn Mark Stack.mark(&self, Side side) => (Mark)self.used[side.ordinal];

<*
 Back to where `mark` was taken at that end.

 @param [&inout] self
 @require (sz)mark <= self.used[side.ordinal] : "a mark can only be restored backwards"
*>
fn void Stack.restore(&self, Side side, Mark mark)
{
	sz to = (sz)mark;
	usz index = (usz)side.ordinal;
	$if env::COMPILER_SAFE_MODE:
		sz freed = self.used[index] - to;
		if (freed > 0)
		{
			// The front counts from the start of the buffer and the back from
			// the end of it, so the bytes being released sit at opposite ends.
			if (side == FRONT)
			{
				self.buffer[to:freed][..] = POISON;
			}
			else
			{
				self.buffer[self.buffer.len - self.used[index] : freed][..] = POISON;
			}
		}
	$endif
	self.used[index] = to;
}

// -------------------------------------------------------------------------
// The allocator
// -------------------------------------------------------------------------

<*
 Whether `payload` is the most recent allocation at its end - the only one
 that `release` can reclaim.

 @param [&in] self
*>
fn bool Stack.is_last(&self, Side side, void* payload)
{
	if (!self.owns(payload)) return false;
	Header* header = layout::header_of(payload);
	if (side == FRONT)
	{
		// `pad` at the front is everything before the payload, so the block's
		// last byte is simply payload + bytes.
		return payload + header.bytes == (void*)self.buffer.ptr + self.used[0];
	}
	// At the back, the allocation's lowest byte is its header, and `used`
	// counts down from the end of the buffer.
	return (void*)header == (void*)self.buffer.ptr + self.buffer.len - self.used[1];
}

<*
 Implements the `Allocator` interface.

 @param [&inout] self
 @require size > 0
 @require !alignment || math::is_power_of_2(alignment)
 @return? mem::OUT_OF_MEMORY
*>
fn void*? StackEnd.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	alignment = allocators::alignment_for_allocation(alignment);
	Stack* stack = self.stack;
	void* payload;
	sz footprint;

	sz pad;
	sz tail = 0;

	if (self.side == FRONT)
	{
		// The same arithmetic as an arena: reserve the header, then align the
		// payload after it.
		void* from = (void*)stack.buffer.ptr + stack.used[0];
		payload = layout::payload_after(from, alignment);
		pad = (sz)((uptr)payload - (uptr)from);
		footprint = pad + size;
	}
	else
	{
		// Downwards: put the payload as high as it will go and still be
		// aligned, then the header immediately below it. Whatever gap the
		// alignment leaves above the payload is part of this allocation's
		// footprint, so that freeing it recovers the gap too.
		void* top = (void*)stack.buffer.ptr + stack.buffer.len - stack.used[1];
		payload = layout::backward_ptr(top - size, alignment);
		void* header_start = payload - Header::size;
		if ((uptr)header_start < (uptr)stack.buffer.ptr) return mem::OUT_OF_MEMORY~;
		pad = Header::size;
		tail = (sz)((uptr)top - (uptr)payload) - size;
		footprint = pad + size + tail;
	}

	if (footprint > stack.remaining()) return mem::OUT_OF_MEMORY~;

	Header* header = layout::header_of(payload);
	header.bytes = size;
	header.pad = pad;
	header.tail = tail;

	usz index = (usz)self.side.ordinal;
	stack.used[index] += footprint;
	if (stack.used[index] > stack.high_water[index]) stack.high_water[index] = stack.used[index];

	if (init_type == ZERO) mem::clear(payload, (usz)size);
	return payload;
}

<*
 Implements the `Allocator` interface.

 The front end grows its most recent block in place, exactly as an arena
 does. The back cannot: growing downwards would move the pointer, and `resize`
 has to return the same address or a new block. So the back always copies,
 which is one more reason the back is the end for things that are loaded once.

 @param [&inout] self
 @require ptr != null
 @require new_size > 0
 @require !alignment || math::is_power_of_2(alignment)
 @return? mem::OUT_OF_MEMORY
*>
fn void*? StackEnd.resize(&self, void* ptr, sz new_size, sz alignment) @dynamic
{
	alignment = allocators::alignment_for_allocation(alignment);
	Stack* stack = self.stack;
	assert(stack.owns(ptr), "the pointer did not come from this stack");

	Header* header = layout::header_of(ptr);
	sz old_size = header.bytes;

	if (self.side == FRONT && stack.is_last(FRONT, ptr) &&
		layout::ptr_is_aligned(ptr, alignment))
	{
		sz difference = new_size - old_size;
		if (difference > stack.remaining()) return mem::OUT_OF_MEMORY~;
		header.bytes = new_size;
		stack.used[0] += difference;
		if (stack.used[0] > stack.high_water[0]) stack.high_water[0] = stack.used[0];
		return ptr;
	}

	// A shrink at the back keeps the address, because the block is anchored
	// at its low end and the caller only ever reads the front of it.
	if (self.side == BACK && new_size <= old_size)
	{
		header.tail += old_size - new_size;
		header.bytes = new_size;
		return ptr;
	}

	void* moved = self.acquire(new_size, NO_ZERO, alignment)!;
	mem::copy(moved, ptr, (usz)math::min(new_size, old_size));
	return moved;
}

<*
 Implements the `Allocator` interface.

 Reclaims the block if it is the most recent one at its end, and does nothing
 otherwise - the same contract an arena has, for the same reason.

 @param [&inout] self
 @param [&in] ptr
 @require ptr != null
*>
fn void StackEnd.release(&self, void* ptr, bool aligned) @dynamic
{
	Stack* stack = self.stack;
	assert(stack.owns(ptr), "the pointer did not come from this stack");
	if (!stack.is_last(self.side, ptr)) return;

	Header* header = layout::header_of(ptr);
	usz index = (usz)self.side.ordinal;
	stack.restore(self.side, (Mark)(stack.used[index] - header.footprint()));
}

// -------------------------------------------------------------------------
// Printing
// -------------------------------------------------------------------------

fn sz? Stack.to_format(&self, Formatter* formatter) @dynamic
{
	return formatter.printf("front %s, back %s, %s free of %s",
		layout::size(self.used[0]),
		layout::size(self.used[1]),
		layout::size(self.remaining()),
		layout::size(self.buffer.len));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn char[] spend(Allocator a, sz bytes) @local
{
	return alloc::alloc_array(a, char, bytes);
}

fn void test_a_fresh_stack_is_empty() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);

	test::eq(stack.capacity(), 4096);
	test::eq(stack.remaining(), 4096);
	test::eq(stack.used_by(FRONT), 0);
	test::eq(stack.used_by(BACK), 0);
}

fn void test_the_two_ends_grow_towards_each_other() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);
	Allocator front = stack.allocator(FRONT);
	Allocator back = stack.allocator(BACK);

	char[] f = spend(front, 100);
	char[] b = spend(back, 100);

	// The front block is below the back one, with the free space between.
	test::@check((uptr)f.ptr < (uptr)b.ptr);
	test::@check(stack.used_by(FRONT) >= 100);
	test::@check(stack.used_by(BACK) >= 100);
	test::@check(stack.remaining() < 4096 - 200);
}

fn void test_they_share_what_is_between_them() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);

	// Neither end has a budget. The back takes most of the buffer and the
	// front still gets what is left, which two separate arenas could not do
	// without having guessed the split in advance.
	spend(stack.allocator(BACK), 3000);
	char[] f = spend(stack.allocator(FRONT), 900);
	test::eq(f.len, 900);
	test::@check(stack.remaining() < 200);
}

fn void test_neither_end_can_walk_into_the_other() @test
{
	char[1024] backing;
	Stack stack;
	stack.init(&backing);
	StackEnd* front = &stack.ends[0];
	StackEnd* back = &stack.ends[1];

	front.acquire(500, NO_ZERO, 0)!!;
	back.acquire(400, NO_ZERO, 0)!!;
	// What is left is smaller than either request, and both are refused
	// rather than one silently overwriting the other.
	test::@error(front.acquire(200, NO_ZERO, 0), mem::OUT_OF_MEMORY);
	test::@error(back.acquire(200, NO_ZERO, 0), mem::OUT_OF_MEMORY);
}

fn void test_resetting_one_end_leaves_the_other_alone() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);

	char[] level = spend(stack.allocator(BACK), 500);
	level[..] = 9;
	sz back_used = stack.used_by(BACK);

	for (int frame = 0; frame < 20; frame++)
	{
		spend(stack.allocator(FRONT), 200);
		stack.reset(FRONT);
	}

	test::eq(stack.used_by(FRONT), 0);
	test::eq(stack.used_by(BACK), back_used);
	// And the level data survived every one of those frames.
	test::eq(level[250], (char)9);
}

fn void test_the_high_water_mark_is_per_end() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);

	spend(stack.allocator(FRONT), 800);
	stack.reset(FRONT);
	spend(stack.allocator(FRONT), 100);

	test::@check(stack.high_water_of(FRONT) >= 800);
	test::eq(stack.high_water_of(BACK), 0);
}

fn void test_alignment_is_honoured_at_both_ends() @test
{
	char[8192] backing;
	Stack stack;
	stack.init(&backing);
	StackEnd* front = &stack.ends[0];
	StackEnd* back = &stack.ends[1];

	foreach (alignment : (sz[]){ 16, 32, 64, 128, 256 })
	{
		// A shim first, so neither end starts aligned by accident.
		front.acquire(3, NO_ZERO, 0)!!;
		back.acquire(3, NO_ZERO, 0)!!;

		void* f = front.acquire(40, NO_ZERO, alignment)!!;
		void* b = back.acquire(40, NO_ZERO, alignment)!!;
		test::@check(layout::ptr_is_aligned(f, alignment));
		test::@check(layout::ptr_is_aligned(b, alignment));
		test::@check(stack.owns(f) && stack.owns(b));
	}
	// And the two ends never met.
	test::@check(stack.remaining() > 0);
}

fn void test_blocks_at_the_two_ends_never_overlap() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);
	Allocator front = stack.allocator(FRONT);
	Allocator back = stack.allocator(BACK);

	List{char[]} live;
	live.init(mem);
	defer live.free();

	for (int i = 0; i < 20; i++)
	{
		live.push(spend(front, (sz)(30 + i)));
		live.push(spend(back, (sz)(30 + i)));
	}

	foreach (i, x : live)
	{
		for (sz j = (sz)i + 1; j < live.len(); j++)
		{
			char[] y = live[j];
			uptr xs = (uptr)x.ptr;
			uptr ys = (uptr)y.ptr;
			test::@check(xs + x.len <= ys || ys + y.len <= xs);
		}
	}
}

fn void test_marks_work_at_each_end_independently() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);

	spend(stack.allocator(BACK), 100);
	Mark back_mark = stack.mark(BACK);
	spend(stack.allocator(FRONT), 100);
	Mark front_mark = stack.mark(FRONT);

	spend(stack.allocator(FRONT), 500);
	spend(stack.allocator(BACK), 500);

	stack.restore(FRONT, front_mark);
	test::eq(stack.mark(FRONT), front_mark);
	// Restoring the front did not disturb the back.
	test::@check(stack.used_by(BACK) > (sz)back_mark);

	stack.restore(BACK, back_mark);
	test::eq(stack.mark(BACK), back_mark);
}

fn void test_side_of_says_where_a_pointer_came_from() @test
{
	char[4096] backing;
	char[16] elsewhere;
	Stack stack;
	stack.init(&backing);

	char[] f = spend(stack.allocator(FRONT), 100);
	char[] b = spend(stack.allocator(BACK), 100);

	test::eq(stack.side_of(f.ptr)!!, Side.FRONT);
	test::eq(stack.side_of(b.ptr)!!, Side.BACK);
	test::@error(stack.side_of(&elsewhere[0]), NOT_FROM_HERE);
}

fn void test_freeing_the_last_block_reclaims_it_at_either_end() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);
	StackEnd* front = &stack.ends[0];
	StackEnd* back = &stack.ends[1];

	front.acquire(100, NO_ZERO, 0)!!;
	back.acquire(100, NO_ZERO, 0)!!;
	sz front_used = stack.used_by(FRONT);
	sz back_used = stack.used_by(BACK);

	void* f = front.acquire(500, NO_ZERO, 64)!!;
	void* b = back.acquire(500, NO_ZERO, 64)!!;
	front.release(f, true);
	back.release(b, true);

	// Exactly back, alignment padding included - which is what `pad` in the
	// header is kept for.
	test::eq(stack.used_by(FRONT), front_used);
	test::eq(stack.used_by(BACK), back_used);
}

fn void test_freeing_out_of_order_is_a_no_op() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);
	StackEnd* front = &stack.ends[0];

	void* first = front.acquire(100, NO_ZERO, 0)!!;
	front.acquire(100, NO_ZERO, 0)!!;
	sz used = stack.used_by(FRONT);

	front.release(first, false);
	test::eq(stack.used_by(FRONT), used);
}

fn void test_the_front_grows_its_last_block_in_place() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);
	StackEnd* front = &stack.ends[0];

	void* p = front.acquire(100, NO_ZERO, 0)!!;
	sz pad = layout::header_of(p).pad;
	void* grown = front.resize(p, 900, 0)!!;
	// Same address, and the end moved by exactly the difference: no copy, no
	// second header, nothing left behind.
	test::@check(grown == p);
	test::eq(stack.used_by(FRONT), pad + 900);
}

fn void test_the_back_copies_when_it_grows() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);
	StackEnd* back = &stack.ends[1];

	char* p = back.acquire(16, NO_ZERO, 0)!!;
	for (sz i = 0; i < 16; i++) p[i] = (char)i;

	char* moved = back.resize(p, 64, 0)!!;
	// Growing downwards would move the pointer, so the back allocates afresh.
	test::@check(moved != p);
	for (sz i = 0; i < 16; i++) test::eq(moved[i], (char)i);
}

fn void test_a_growing_list_lives_at_the_front() @test
{
	char[8192] backing;
	Stack stack;
	stack.init(&backing);

	List{int} items;
	items.init(stack.allocator(FRONT));

	for (int i = 0; i < 300; i++) items.push(i);
	test::eq(items.len(), 300);
	for (int i = 0; i < 300; i++) test::eq(items[i], i);
}

fn void test_a_formatted_string_lives_at_the_back() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);

	String text = string::format(stack.allocator(BACK), "%d draw calls", 512);
	test::eq(text, "512 draw calls");
}

fn void test_zeroed_memory_is_zeroed_at_both_ends() @test
{
	char[2048] backing;
	backing[..] = 0xFF;
	Stack stack;
	stack.init(&backing);

	char* f = stack.ends[0].acquire(64, ZERO, 0)!!;
	char* b = stack.ends[1].acquire(64, ZERO, 0)!!;
	for (sz i = 0; i < 64; i++)
	{
		test::eq(f[i], (char)0);
		test::eq(b[i], (char)0);
	}
}

fn void test_it_borrows_a_buffer_from_another_allocator() @test
{
	Stack stack;
	stack.init_alloc(mem, 4096)!!;
	defer stack.free_from(mem);

	test::eq(stack.capacity(), 4096);
	char[] f = spend(stack.allocator(FRONT), 100);
	test::@check(stack.owns(f.ptr));
}

fn void test_printing_shows_both_ends() @test
{
	char[4096] backing;
	Stack stack;
	stack.init(&backing);
	spend(stack.allocator(FRONT), 1024);

	String printed = string::tformat("%s", &stack);
	test::@check(printed.contains("front 1.0 KiB"));
	test::@check(printed.contains("of 4.0 KiB"));
}
