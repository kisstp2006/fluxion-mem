// SPDX-License-Identifier: BSL-1.0

// One region of memory, sub-allocated in blocks of any size, with the freed
// ones joined back together.
//
// The one allocator here that behaves like a general-purpose one: any size,
// any alignment, freed in any order, and adjacent free blocks merged so that
// two halves become a whole again. That is what an `Arena` will not do and a
// `Pool` cannot.
//
// What it costs is a search. Allocation walks the free blocks from the front
// and takes the first that fits, which is O(the number of free blocks) - fine
// for a subsystem with a fixed budget and a few hundred live allocations, and
// not fine as a replacement for the system allocator. If the answer to "how
// many blocks are there" is "I do not know", this is the wrong allocator;
// `Arena` or `Pool` almost certainly is not.
//
// **The free-list bookkeeping lives in the free memory itself.** A free block
// holds its own size and the link to the next one, so there is no side table
// and nothing is spent on memory that is not in use. A live block does carry
// a header, because C3's `Allocator` hands `release` a pointer and no length -
// see `layout::Header`, which is where that cost is explained. The Zig
// original had no header at all, and this is the one place the port is
// measurably heavier than what it replaces.
//
// **Blocks are kept sorted by address**, which is what makes coalescing a
// comparison against the neighbours rather than a search. It is also what
// lets `verify` check, in a test, that the list is still sound.
//
// One thread at a time.
module fluxion::mem::free_list;
import fluxion::mem::layout;
import std::core::mem::allocators, std::core::mem::alloc;
import std::collections::list;
import std::io, std::math;

const char POISON @local = 0xF7;

<*
 The head of a free block, written into the block's own first bytes.

 A live block has one of these overwritten by the caller's data and a
 `layout::Header` in front of it instead, so the two never exist at once.
*>
struct Node
{
	// The whole block, in bytes, including this node.
	sz size;
	// The next free block, always at a higher address. Null at the end.
	Node* next;
}

<*
 Every block boundary is a multiple of this, so that a `Node` can always be
 written at the start of a free block.
*>
const sz GRANULARITY = Node::alignment;

<*
 The smallest block that can exist: one big enough to describe itself once it
 is freed. A request that would leave a stub smaller than this has the stub
 folded into the block instead.
*>
const sz MIN_BLOCK = (Node::size + GRANULARITY - 1) & ~(GRANULARITY - 1);

<*
 A region sub-allocated in blocks, with the free ones joined back together.
*>
struct FreeList (Allocator)
{
	// The region, already trimmed to start and end on a block boundary.
	char[] buffer;
	// The free blocks, in address order. Null when nothing is free.
	Node* first;
	// Bytes handed out, counting headers, padding and rounding - so this is
	// what the region is actually spending, not what the callers asked for.
	sz used;
	sz high_water;
}

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

<*
 Over memory the caller owns. The front and the back are trimmed to block
 boundaries, so `capacity` may be a few bytes less than `buffer.len`.

 @param [&inout] self
 @param [inout] buffer
*>
fn FreeList* FreeList.init(&self, char[] buffer)
{
	char[] aligned = layout::align_slice(buffer, GRANULARITY);
	sz usable = layout::backward(aligned.len, GRANULARITY);
	self.buffer = aligned[:usable];
	self.used = 0;
	self.high_water = 0;
	self.rebuild();
	return self;
}

<*
 Over memory taken from `child` once. Pair with `free_from`.

 @param [&inout] self
 @param [&inout] child
 @require size > 0
*>
fn FreeList*? FreeList.init_alloc(&self, Allocator child, sz size)
{
	char[] buffer = alloc::alloc_array_try(child, char, size)!;
	return self.init(buffer);
}

<*
 @param [&inout] self
 @param [&inout] child
*>
fn void FreeList.free_from(&self, Allocator child)
{
	// The buffer was trimmed forward at init, so this frees what was handed
	// out only when the caller's block was already aligned - which it is,
	// because it came from an allocator. Callers who pass their own memory
	// use `init` and free it themselves.
	alloc::free(child, self.buffer.ptr);
	self.buffer = {};
	self.first = null;
	self.used = 0;
}

<*
 Everything free again, as one block. Does not run destructors and does not
 care what was live.

 @param [&inout] self
*>
fn void FreeList.reset(&self)
{
	$if env::COMPILER_SAFE_MODE:
		if (self.buffer.len > 0) self.buffer[..] = POISON;
	$endif
	self.rebuild();
	self.used = 0;
}

<*
 One free block covering the whole region, or none if it is too small to hold
 even one.

 @param [&inout] self
*>
fn void FreeList.rebuild(&self)
{
	if (self.buffer.len < MIN_BLOCK)
	{
		self.first = null;
		return;
	}
	Node* node = (Node*)self.buffer.ptr;
	node.size = self.buffer.len;
	node.next = null;
	self.first = node;
}

// -------------------------------------------------------------------------
// Asking it things
// -------------------------------------------------------------------------

<*
 @param [&in] self
*>
fn sz FreeList.capacity(&self) @inline => self.buffer.len;

<*
 Bytes not handed out. The sum of the free blocks, which is not the same as
 the largest allocation that would succeed - see `largest_free`.

 @param [&in] self
*>
fn sz FreeList.free_bytes(&self)
{
	sz total = 0;
	for (Node* node = self.first; node != null; node = node.next) total += node.size;
	return total;
}

<*
 The biggest single block. An allocation larger than this cannot succeed
 however much is free in total, which is what fragmentation means.

 @param [&in] self
*>
fn sz FreeList.largest_free(&self)
{
	sz largest = 0;
	for (Node* node = self.first; node != null; node = node.next)
	{
		if (node.size > largest) largest = node.size;
	}
	return largest;
}

<*
 How many separate free blocks there are. One is a region with no
 fragmentation; a large number is a region that will start refusing
 allocations it has room for.

 @param [&in] self
*>
fn sz FreeList.block_count(&self)
{
	sz count = 0;
	for (Node* node = self.first; node != null; node = node.next) count++;
	return count;
}

<*
 @param [&in] self
*>
fn bool FreeList.owns(&self, void* ptr) => layout::owns(self.buffer, ptr);

<*
 Walk the free list and check that it is still what it claims to be: sorted,
 inside the region, non-overlapping, on block boundaries, and fully
 coalesced.

 For tests, and for an assertion after something suspicious. It is a walk of
 the whole list, so it does not belong in a hot path.

 @param [&in] self
*>
fn bool FreeList.verify(&self)
{
	uptr start = (uptr)self.buffer.ptr;
	uptr end = start + (uptr)self.buffer.len;
	uptr previous_end = start;
	sz total = 0;

	for (Node* node = self.first; node != null; node = node.next)
	{
		uptr address = (uptr)node;

		if (address < previous_end) return false;                 // out of order, or overlapping
		if (address + (uptr)node.size > end) return false;        // off the end
		if (node.size < MIN_BLOCK) return false;                  // too small to hold itself
		if (!layout::is_aligned((sz)address, GRANULARITY)) return false;
		if (!layout::is_aligned(node.size, GRANULARITY)) return false;

		// Fully coalesced: no two free blocks may touch.
		if (address == previous_end && previous_end != start) return false;

		previous_end = address + (uptr)node.size;
		total += node.size;
	}

	// What is free and what is used must together be the whole region.
	return total + self.used == self.buffer.len;
}

// -------------------------------------------------------------------------
// The allocator
// -------------------------------------------------------------------------

<*
 Implements the `Allocator` interface.

 First fit: the free blocks are walked from the front and the first that can
 hold the request is split. First fit rather than best fit because best fit
 costs a full walk on every allocation and, on the block sizes an engine
 actually asks for, fragments no less.

 @param [&inout] self
 @require size > 0
 @require !alignment || math::is_power_of_2(alignment)
 @return? mem::OUT_OF_MEMORY
*>
fn void*? FreeList.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	alignment = allocators::alignment_for_allocation(alignment);

	Node* previous = null;
	for (Node* node = self.first; node != null; previous = node, node = node.next)
	{
		void* at = (void*)node;

		// Where the payload could go, with room for its header in front.
		void* payload = layout::payload_after(at, alignment);
		void* block = payload - Header::size;

		// Whatever is left in front of the block stays free, so it has to be
		// big enough to be a block of its own. If it is not, push the payload
		// on until it is.
		if (block != at && (uptr)block - (uptr)at < (uptr)MIN_BLOCK)
		{
			payload = layout::payload_after(at + MIN_BLOCK, alignment);
			block = payload - Header::size;
		}

		sz front = (sz)((uptr)block - (uptr)at);
		sz want = layout::forward(Header::size + size, GRANULARITY);
		if (want < MIN_BLOCK) want = MIN_BLOCK;
		if (front > node.size || node.size - front < want) continue;

		sz back = node.size - front - want;
		// The same rule at the far end. A stub too small to be a block cannot
		// be left behind and cannot be dropped either, so it is folded into
		// this allocation - which is what the header's `tail` is for.
		if (back != 0 && back < MIN_BLOCK)
		{
			want += back;
			back = 0;
		}

		// Read the link before writing anything: the tail block's node may
		// land on top of this one's.
		Node* after = node.next;

		Node* tail_node = null;
		if (back != 0)
		{
			tail_node = (Node*)(block + want);
			tail_node.size = back;
			tail_node.next = after;
		}

		if (front != 0)
		{
			// The front of the block stays free, where it is.
			node.size = front;
			node.next = tail_node != null ? tail_node : after;
		}
		else
		{
			// The whole block was taken from its start, so it leaves the list.
			Node* replacement = tail_node != null ? tail_node : after;
			if (previous != null)
			{
				previous.next = replacement;
			}
			else
			{
				self.first = replacement;
			}
		}

		Header* header = layout::header_of(payload);
		header.bytes = size;
		header.pad = Header::size;
		header.tail = want - Header::size - size;

		self.used += want;
		if (self.used > self.high_water) self.high_water = self.used;

		if (init_type == ZERO) mem::clear(payload, (usz)size);
		return payload;
	}

	return mem::OUT_OF_MEMORY~;
}

<*
 Put `[at, at + size)` back on the list, joined to whichever neighbours it
 touches.

 @param [&inout] self
*>
fn void FreeList.give_back(&self, void* at, sz size)
{
	assert(layout::ptr_is_aligned(at, GRANULARITY));
	assert(layout::is_aligned(size, GRANULARITY));
	assert((uptr)at >= (uptr)self.buffer.ptr);
	assert((uptr)at + (uptr)size <= (uptr)self.buffer.ptr + (uptr)self.buffer.len);

	// Where it goes: the list is sorted, so this is a walk to the first block
	// past it.
	Node* previous = null;
	Node* following = self.first;
	while (following != null && (uptr)following < (uptr)at)
	{
		previous = following;
		following = following.next;
	}

	// A block overlapping a free one is a double free, or a pointer that was
	// never handed out. Either way the list is about to become a cycle, so
	// say so here rather than letting it happen.
	if (previous != null)
	{
		assert((uptr)previous + (uptr)previous.size <= (uptr)at, "double free, or a foreign pointer");
	}
	if (following != null)
	{
		assert((uptr)at + (uptr)size <= (uptr)following, "double free, or a foreign pointer");
	}

	$if env::COMPILER_SAFE_MODE:
		mem::set(at, POISON, (usz)size);
	$endif

	Node* node = (Node*)at;
	node.size = size;
	node.next = following;
	if (previous != null)
	{
		previous.next = node;
	}
	else
	{
		self.first = node;
	}

	self.used -= size;

	// Join to the block after, then to the one before. In that order: the
	// backward join may absorb the node entirely, and its `next` has to be
	// right by then.
	if (node.next != null && (uptr)at + (uptr)node.size == (uptr)node.next)
	{
		node.size += node.next.size;
		node.next = node.next.next;
	}
	if (previous != null && (uptr)previous + (uptr)previous.size == (uptr)at)
	{
		previous.size += node.size;
		previous.next = node.next;
	}
}

<*
 Implements the `Allocator` interface.

 @param [&inout] self
 @param [&in] ptr
 @require ptr != null
*>
fn void FreeList.release(&self, void* ptr, bool aligned) @dynamic
{
	assert(self.owns(ptr), "the pointer did not come from this region");
	Header* header = layout::header_of(ptr);
	self.give_back(ptr - header.pad, header.footprint());
}

<*
 Implements the `Allocator` interface.

 Grows into the free block immediately after, when there is one big enough,
 and shrinks by handing the tail back. Either way the address does not move,
 which is what makes a list appending into a region here cheap. When neither
 is possible it allocates and copies.

 @param [&inout] self
 @require ptr != null
 @require new_size > 0
 @require !alignment || math::is_power_of_2(alignment)
 @return? mem::OUT_OF_MEMORY
*>
fn void*? FreeList.resize(&self, void* ptr, sz new_size, sz alignment) @dynamic
{
	alignment = allocators::alignment_for_allocation(alignment);
	assert(self.owns(ptr), "the pointer did not come from this region");

	Header* header = layout::header_of(ptr);
	sz old_size = header.bytes;
	void* block = ptr - header.pad;
	sz old_block = header.footprint();

	sz new_block = layout::forward(header.pad + new_size, GRANULARITY);
	if (new_block < MIN_BLOCK) new_block = MIN_BLOCK;

	if (new_block == old_block && layout::ptr_is_aligned(ptr, alignment))
	{
		header.bytes = new_size;
		header.tail = old_block - header.pad - new_size;
		return ptr;
	}

	if (new_block < old_block && layout::ptr_is_aligned(ptr, alignment))
	{
		// The tail goes back on the list, but only if it is big enough to be
		// a block. If it is not, keep it: the caller sees the size it asked
		// for and the few spare bytes stay in the header's `tail`.
		sz spare = old_block - new_block;
		if (spare >= MIN_BLOCK)
		{
			self.give_back(block + new_block, spare);
			header.bytes = new_size;
			header.tail = new_block - header.pad - new_size;
		}
		else
		{
			header.bytes = new_size;
			header.tail = old_block - header.pad - new_size;
		}
		return ptr;
	}

	if (new_block > old_block && layout::ptr_is_aligned(ptr, alignment))
	{
		// Growing where it stands: the block immediately after has to be
		// free, and big enough, and leave a stub that is either nothing or a
		// whole block.
		sz extra = new_block - old_block;
		void* after = block + old_block;

		Node* previous = null;
		Node* node = self.first;
		while (node != null && (uptr)node < (uptr)after)
		{
			previous = node;
			node = node.next;
		}

		if (node != null && (void*)node == after && node.size >= extra)
		{
			sz leftover = node.size - extra;
			Node* node_next = node.next;
			Node* replacement;
			if (leftover < MIN_BLOCK)
			{
				// Too small to leave behind, so it comes along.
				extra = node.size;
				replacement = node_next;
			}
			else
			{
				Node* stub = (Node*)(after + extra);
				stub.size = leftover;
				stub.next = node_next;
				replacement = stub;
			}

			if (previous != null)
			{
				previous.next = replacement;
			}
			else
			{
				self.first = replacement;
			}

			self.used += extra;
			if (self.used > self.high_water) self.high_water = self.used;
			header.bytes = new_size;
			header.tail = old_block + extra - header.pad - new_size;
			return ptr;
		}
	}

	// Nowhere to grow: a fresh block, and copy.
	void* moved = self.acquire(new_size, NO_ZERO, alignment)!;
	mem::copy(moved, ptr, (usz)math::min(new_size, old_size));
	self.give_back(block, old_block);
	return moved;
}

// -------------------------------------------------------------------------
// Printing
// -------------------------------------------------------------------------

fn sz? FreeList.to_format(&self, Formatter* formatter) @dynamic
{
	return formatter.printf("%s of %s used, %d free blocks, largest %s",
		layout::size(self.used),
		layout::size(self.capacity()),
		self.block_count(),
		layout::size(self.largest_free()));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn char[] spend(Allocator a, sz bytes) @local
{
	return alloc::alloc_array(a, char, bytes);
}

fn void test_a_fresh_region_is_one_free_block() @test
{
	char[4096] backing;
	FreeList list;
	list.init(&backing);

	test::eq(list.block_count(), 1);
	test::@check(list.capacity() >= 4096 - GRANULARITY);
	test::eq(list.free_bytes(), list.capacity());
	test::eq(list.used, 0);
	test::@check(list.verify());
}

fn void test_allocate_free_and_the_region_is_whole_again() @test
{
	char[4096] backing;
	FreeList list;
	Allocator a = (Allocator)list.init(&backing);

	char[] first = spend(a, 100);
	char[] second = spend(a, 200);
	char[] third = spend(a, 300);
	test::@check(list.verify());
	test::@check(list.used >= 600);

	alloc::free(a, second.ptr);
	test::@check(list.verify());
	alloc::free(a, first.ptr);
	test::@check(list.verify());
	alloc::free(a, third.ptr);
	test::@check(list.verify());

	// Everything back, and coalesced into the single block it started as.
	test::eq(list.used, 0);
	test::eq(list.block_count(), 1);
	test::eq(list.free_bytes(), list.capacity());
}

fn void test_freed_neighbours_are_joined_back_together() @test
{
	char[4096] backing;
	FreeList list;
	Allocator a = (Allocator)list.init(&backing);

	char[] one = spend(a, 400);
	char[] two = spend(a, 400);
	char[] three = spend(a, 400);
	// A wall, so what is left at the far end is not the largest block.
	spend(a, 2200);

	// Free the outer two: two separate holes with `two` still between them.
	alloc::free(a, one.ptr);
	alloc::free(a, three.ptr);
	test::@check(list.verify());
	sz separate = list.largest_free();

	// Free the one between them, and all three become one.
	alloc::free(a, two.ptr);
	test::@check(list.verify());
	test::@check(list.largest_free() > separate * 2);

	// Which is a block that none of the three could have held on its own.
	char[] big = spend(a, 1200);
	test::@check(list.owns(big.ptr));
	test::@check(list.verify());
}

fn void test_a_hole_is_reused_and_split_when_it_is_bigger_than_needed() @test
{
	char[4096] backing;
	FreeList list;
	Allocator a = (Allocator)list.init(&backing);

	spend(a, 256);
	char[] hole = spend(a, 1024);
	spend(a, 256);

	void* address = hole.ptr;
	alloc::free(a, hole.ptr);

	// A smaller allocation lands in the hole and leaves the rest of it free.
	char[] small = spend(a, 100);
	test::@check((void*)small.ptr == address);
	test::@check(list.verify());

	// And the remainder of the hole is still usable.
	char[] rest = spend(a, 700);
	test::@check(list.owns(rest.ptr));
	test::@check(list.verify());
}

fn void test_alignment_is_honoured_and_the_gap_in_front_stays_usable() @test
{
	char[8192] backing;
	FreeList list;
	FreeList* self = list.init(&backing);

	foreach (alignment : (sz[]){ 16, 32, 64, 128, 256 })
	{
		// Something small first, so the next block does not start aligned.
		void* shim = self.acquire(17, NO_ZERO, 0)!!;
		void* p = self.acquire(40, NO_ZERO, alignment)!!;

		test::@check(layout::ptr_is_aligned(p, alignment));
		test::@check(list.owns(p));
		test::@check(list.verify());

		self.release(p, true);
		self.release(shim, false);
		test::@check(list.verify());
	}

	// Everything came back.
	test::eq(list.used, 0);
	test::eq(list.block_count(), 1);
}

fn void test_a_large_alignment_leaves_a_hole_that_is_itself_allocatable() @test
{
	// The region is aligned first, so that where the 512-byte boundary falls
	// inside it does not depend on where the stack happened to put the array.
	// Without that this test passes or fails by luck.
	char[8192] backing;
	FreeList list;
	FreeList* self = list.init(layout::align_slice(&backing, 4096));

	self.acquire(8, NO_ZERO, 0)!!;
	void* aligned = self.acquire(64, NO_ZERO, 512)!!;
	test::@check(layout::ptr_is_aligned(aligned, 512));
	test::@check(list.verify());

	// The gap the alignment skipped is a free block, and it can be used.
	test::@check(list.block_count() >= 2);
	void* in_the_gap = self.acquire(32, NO_ZERO, 0)!!;
	test::@check((uptr)in_the_gap < (uptr)aligned);
	test::@check(list.verify());
}

fn void test_a_full_region_says_so() @test
{
	char[1024] backing;
	FreeList list;
	FreeList* self = list.init(&backing);

	// Nearly all of it in one block. What is left over is the header, the
	// alignment gap in front of it, and a stub at the end - none of which is
	// big enough for another allocation of any size worth having.
	void* whole = self.acquire(list.capacity() - 128, NO_ZERO, 0)!!;
	test::@check(list.free_bytes() < 128);
	test::@error(self.acquire(256, NO_ZERO, 0), mem::OUT_OF_MEMORY);

	self.release(whole, false);
	test::eq(list.free_bytes(), list.capacity());

	// And a request larger than the region never succeeds.
	test::@error(self.acquire(4096, NO_ZERO, 0), mem::OUT_OF_MEMORY);
	test::@check(list.verify());
}

fn void test_fragmentation_is_visible_and_is_what_it_costs() @test
{
	char[4096] backing;
	FreeList list;
	Allocator a = (Allocator)list.init(&backing);

	// Sixteen blocks, then free every other one.
	char[][16] blocks;
	for (int i = 0; i < 16; i++) blocks[i] = spend(a, 180);

	for (int i = 0; i < 16; i += 2) alloc::free(a, blocks[i].ptr);
	test::@check(list.verify());

	// Plenty free in total...
	test::@check(list.free_bytes() >= 8 * 180);
	// ...but no single block big enough for half of it, which is exactly the
	// failure this allocator can have and an arena cannot.
	test::@check(list.largest_free() < 8 * 180);
	test::@check(list.block_count() > 4);

	// Freeing the rest joins it all back into one.
	for (int i = 1; i < 16; i += 2) alloc::free(a, blocks[i].ptr);
	test::eq(list.block_count(), 1);
	test::eq(list.used, 0);
	test::@check(list.verify());
}

fn void test_resize_grows_into_the_block_after_and_shrinks_by_giving_the_tail_back() @test
{
	char[4096] backing;
	FreeList list;
	FreeList* self = list.init(&backing);

	void* block = self.acquire(100, NO_ZERO, 0)!!;

	// Nothing after it but free space, so it grows where it stands.
	void* grown = self.resize(block, 500, 0)!!;
	test::@check(grown == block);
	test::@check(list.verify());

	// Shrinking hands the tail back.
	sz before = list.used;
	self.resize(block, 100, 0)!!;
	test::@check(list.used < before);
	test::@check(list.verify());

	// With something immediately after it, it has to move.
	self.acquire(64, NO_ZERO, 0)!!;
	void* moved = self.resize(block, 2000, 0)!!;
	test::@check(moved != block);
	test::@check(list.verify());
}

fn void test_a_growing_list_lives_in_it() @test
{
	char[8192] backing;
	FreeList list;
	Allocator a = (Allocator)list.init(&backing);

	List{ulong} items;
	items.init(a);
	for (ulong i = 0; i < 300; i++) items.push(i);
	test::eq(items.len(), 300);
	for (ulong i = 0; i < 300; i++) test::eq(items[(sz)i], i);
	test::@check(list.verify());
}

fn void test_reset_puts_it_back_to_one_block_whatever_was_live() @test
{
	char[4096] backing;
	FreeList list;
	Allocator a = (Allocator)list.init(&backing);

	for (int i = 0; i < 10; i++) spend(a, 64);
	test::@check(list.used > 0);

	list.reset();
	test::eq(list.used, 0);
	test::eq(list.block_count(), 1);
	test::eq(list.free_bytes(), list.capacity());
	test::@check(list.verify());
}

fn void test_a_region_too_small_to_hold_a_block_holds_nothing() @test
{
	char[4] tiny;
	FreeList list;
	FreeList* self = list.init(&tiny);

	test::eq(list.block_count(), 0);
	test::@error(self.acquire(1, NO_ZERO, 0), mem::OUT_OF_MEMORY);
	test::@check(list.verify());
}

fn void test_the_smallest_request_still_gets_a_whole_block() @test
{
	char[1024] backing;
	FreeList list;
	FreeList* self = list.init(&backing);

	// One byte occupies a header and a whole granule, because a block has to
	// be able to describe itself once it is freed.
	void* one = self.acquire(1, NO_ZERO, 0)!!;
	test::@check(list.used >= MIN_BLOCK);
	self.release(one, false);
	test::eq(list.used, 0);
	test::@check(list.verify());
}

fn void test_churn_five_thousand_random_allocations_and_frees() @test
{
	FreeList list;
	FreeList* self = list.init_alloc(mem, 16 * 1024)!!;
	defer list.free_from(mem);

	List{char[]} live;
	live.init(mem);
	defer live.free();

	Random rng = (Random)&&(Sfc64Random){};
	random::seed(rng, 0xF2EE1157UL);

	sz refused = 0;
	for (int turn = 0; turn < 5000; turn++)
	{
		if (live.len() > 0 && random::next_bool(rng))
		{
			sz which = (sz)random::next(rng, (int)live.len());
			char[] block = live[which];
			// What was written into it is still what is there.
			foreach (byte : block) test::eq(byte, (char)0x5C);
			self.release(block.ptr, false);
			live.swap(which, live.len() - 1);
			live.pop()!!;
		}
		else
		{
			sz size = 1 + (sz)random::next(rng, 700);
			sz alignment = (sz)1 << (uint)random::next(rng, 7);
			void*? got = self.acquire(size, NO_ZERO, alignment);
			if (catch got)
			{
				refused++;
				continue;
			}
			test::@check(layout::ptr_is_aligned(got, alignment));
			char[] block = ((char*)got)[:size];
			block[..] = 0x5C;
			live.push(block);
		}
		test::@check(list.verify());
	}

	// Free what is left, and the region must come back whole.
	foreach (block : live) self.release(block.ptr, false);
	test::@check(list.verify());
	test::eq(list.used, 0);
	test::eq(list.block_count(), 1);

	// It did refuse some, which is the point of a fixed region.
	test::@check(refused > 0);
}

fn void test_live_allocations_never_overlap() @test
{
	FreeList list;
	FreeList* self = list.init_alloc(mem, 16 * 1024)!!;
	defer list.free_from(mem);

	List{char[]} live;
	live.init(mem);
	defer live.free();

	Random rng = (Random)&&(Sfc64Random){};
	random::seed(rng, 0x0FFA1ABUL);

	for (int turn = 0; turn < 400; turn++)
	{
		if (live.len() > 3 && random::next_bool(rng))
		{
			sz which = (sz)random::next(rng, (int)live.len());
			self.release(live[which].ptr, false);
			live.swap(which, live.len() - 1);
			live.pop()!!;
		}
		else
		{
			sz size = 1 + (sz)random::next(rng, 200);
			void*? got = self.acquire(size, NO_ZERO, 0);
			if (catch got) continue;
			live.push(((char*)got)[:size]);
		}

		// Every live block against every other one.
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

	foreach (block : live) self.release(block.ptr, false);
	test::@check(list.verify());
}

fn void test_printing_says_how_full_it_is() @test
{
	char[4096] backing;
	FreeList list;
	Allocator a = (Allocator)list.init(&backing);
	spend(a, 1000);

	String printed = string::tformat("%s", &list);
	test::@check(printed.contains(" used, "));
	test::@check(printed.contains("free blocks"));
	test::@check(printed.contains("largest"));
}
