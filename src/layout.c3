// SPDX-License-Identifier: BSL-1.0

// The arithmetic the rest of the library is built out of: rounding an address
// up or down to an alignment, asking whether a region contains a pointer, and
// printing a number of bytes the way a person reads one.
//
// The Zig original carried alignments as `std.mem.Alignment`, a power of two
// stored as its own logarithm. C3's `Allocator` interface speaks plain byte
// counts instead - `acquire(size, init, alignment)` takes 16, not 4 - so an
// alignment here is an ordinary `sz` that happens to be a power of two. Every
// routine that takes one says so in a contract, which in a safe build is a
// real check and in a release build costs nothing.
module fluxion::mem::layout;
import std::io, std::math;

// -------------------------------------------------------------------------
// Alignment
// -------------------------------------------------------------------------

<*
 `value` rounded up to the next multiple of `alignment`.

 @require math::is_power_of_2(alignment) : "an alignment is a power of two"
 @require value >= 0
*>
fn sz forward(sz value, sz alignment) @inline
{
	return (value + alignment - 1) & ~(alignment - 1);
}

<*
 `value` rounded down to the previous multiple of `alignment`.

 @require math::is_power_of_2(alignment) : "an alignment is a power of two"
 @require value >= 0
*>
fn sz backward(sz value, sz alignment) @inline
{
	return value & ~(alignment - 1);
}

<*
 @require math::is_power_of_2(alignment) : "an alignment is a power of two"
*>
fn bool is_aligned(sz value, sz alignment) @inline
{
	return (value & (alignment - 1)) == 0;
}

<*
 The gap that `forward` would close: how many bytes are wasted by aligning
 `value` up.

 @require math::is_power_of_2(alignment) : "an alignment is a power of two"
 @require value >= 0
*>
fn sz padding(sz value, sz alignment) @inline
{
	return forward(value, alignment) - value;
}

// The pointer-shaped versions of the same four. They exist separately rather
// than as casts at the call site because an address is a `uptr` and a size is
// a signed `sz`, and mixing the two silently is how alignment bugs start.

<*
 @require math::is_power_of_2(alignment) : "an alignment is a power of two"
*>
fn void* forward_ptr(void* ptr, sz alignment) @inline
{
	return (void*)(((uptr)ptr + (uptr)alignment - 1) & ~((uptr)alignment - 1));
}

<*
 @require math::is_power_of_2(alignment) : "an alignment is a power of two"
*>
fn void* backward_ptr(void* ptr, sz alignment) @inline
{
	return (void*)((uptr)ptr & ~((uptr)alignment - 1));
}

<*
 @require math::is_power_of_2(alignment) : "an alignment is a power of two"
*>
fn bool ptr_is_aligned(void* ptr, sz alignment) @inline
{
	return ((uptr)ptr & ((uptr)alignment - 1)) == 0;
}

<*
 @require math::is_power_of_2(alignment) : "an alignment is a power of two"
*>
fn sz padding_ptr(void* ptr, sz alignment) @inline
{
	return (sz)((uptr)forward_ptr(ptr, alignment) - (uptr)ptr);
}

<*
 The stricter of two alignments, which is simply the larger. Named rather than
 written as `max` at the call site because "stricter" is what the code means
 and "larger" is only how it is computed.
*>
fn sz stricter(sz a, sz b) @inline
{
	return a > b ? a : b;
}

<*
 The alignment a type needs, as a byte count.

 `$Type.alignment` is the compiler's answer, so this is a rename rather than a
 calculation - but it puts the two sides of an allocation, the size and the
 alignment, in the same vocabulary.
*>
macro sz alignment_of($Type) @const
{
	return (sz)$Type::alignment;
}

// -------------------------------------------------------------------------
// Regions
// -------------------------------------------------------------------------

<*
 Whether `ptr` points inside `region`.

 The end is exclusive, so a pointer one past the last byte is not owned -
 which is right, because that pointer is also the start of whatever comes
 next.
*>
fn bool owns(char[] region, void* ptr)
{
	uptr address = (uptr)ptr;
	uptr start = (uptr)region.ptr;
	return address >= start && address < start + (uptr)region.len;
}

<*
 Whether the whole of `part` lies inside `region`.

 An empty slice is owned if its pointer is anywhere in the region *or* one
 past the end, because that is where an empty slice legitimately sits after
 the last allocation.
*>
fn bool owns_slice(char[] region, char[] part)
{
	uptr start = (uptr)region.ptr;
	uptr end = start + (uptr)region.len;
	uptr from = (uptr)part.ptr;
	return from >= start && from + (uptr)part.len <= end;
}

<*
 `region` with the front trimmed off so that it starts on `alignment`.

 Returns an empty slice pointing at the far end if there is not that much
 room, so the result is always a valid slice to hand on.

 @require math::is_power_of_2(alignment) : "an alignment is a power of two"
*>
fn char[] align_slice(char[] region, sz alignment)
{
	sz skip = padding_ptr(region.ptr, alignment);
	if (skip >= region.len) return region[region.len..];
	return region[skip..];
}

// -------------------------------------------------------------------------
// The header
// -------------------------------------------------------------------------

<*
 What every allocator in this library writes immediately in front of a
 payload it hands out.

 This is the one place C3 forces a design the Zig original did not have.
 Zig's `Allocator` passes the whole slice back to `free` and `resize`, so an
 allocator can be told the size it once handed out. C3's interface is
 `release(void* ptr, bool aligned)` and `resize(void* ptr, sz new_size)` - the
 pointer and nothing else - so the size has to be recoverable from the pointer
 alone, and a header in front of it is how the standard library's own
 allocators do it.

 The cost is honest and worth stating: twenty-four bytes per live allocation,
 where the Zig `FreeList` had exactly zero. What you get back is that a caller
 never has to remember a length in order to free correctly.
*>
struct Header
{
	// The payload size, as the caller asked for it - not rounded up.
	sz bytes;
	// How far in front of the payload the allocation began: this header plus
	// whatever alignment padding was skipped. Keeping it means an allocator
	// freeing a block recovers the padding too, rather than leaking a few
	// bytes for every aligned allocation.
	sz pad;
	// Bytes past the end of the payload that still belong to this allocation,
	// because giving them back on their own would leave a fragment too small
	// to be worth anything.
	sz tail;
}

<*
 Everything one allocation occupies: the padding in front, the payload, and
 the tail behind.
*>
macro sz Header.footprint(&self) => self.pad + self.bytes + self.tail;

<*
 The header belonging to a payload pointer.
*>
macro Header* header_of(void* payload)
{
	return (Header*)(payload - Header::size);
}

<*
 Where a payload of `alignment` starts, if the memory available to the
 allocation begins at `from`.

 The header goes between: room for it is reserved first and the payload is
 then aligned, which guarantees the header fits however strict the alignment
 is.

 @require math::is_power_of_2(alignment) : "an alignment is a power of two"
*>
macro void* payload_after(void* from, sz alignment)
{
	return forward_ptr(from + Header::size, alignment);
}

// -------------------------------------------------------------------------
// A readable size
// -------------------------------------------------------------------------

<*
 A number of bytes that prints as `324.4 MiB` rather than as `340123456`.

 Wrap a count in `size(n)` and print it with `%s`; the `Printable` interface
 does the rest. Whole bytes print without a decimal point, because `512 B` is
 what a person writes and `512.0 B` is not.
*>
struct Size (Printable)
{
	sz bytes;
}

const String[4] UNITS @local = { "KiB", "MiB", "GiB", "TiB" };

fn sz? Size.to_format(&self, Formatter* formatter) @dynamic
{
	if (self.bytes < 1024) return formatter.printf("%d B", self.bytes);

	// Divide down until the number is under 1024, keeping the remainder as a
	// fraction so that 1536 reads as "1.5 KiB" rather than "1 KiB".
	double value = (double)self.bytes;
	usz unit = 0;
	while (value >= 1024.0 && unit < UNITS.len)
	{
		value /= 1024.0;
		if (value < 1024.0) break;
		unit++;
	}
	// The loop above stops one unit short when the value is exactly on a
	// boundary, so clamp rather than index past the end.
	if (unit >= UNITS.len) unit = UNITS.len - 1;
	return formatter.printf("%.1f %s", value, UNITS[unit]);
}

<*
 Shorthand: `size(n)` is a `Size` holding `n`.
*>
fn Size size(sz bytes)
{
	return { .bytes = bytes };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_forward_and_backward() @test
{
	test::eq(forward(0, 8), 0);
	test::eq(forward(1, 8), 8);
	test::eq(forward(8, 8), 8);
	test::eq(forward(9, 8), 16);
	test::eq(backward(0, 8), 0);
	test::eq(backward(7, 8), 0);
	test::eq(backward(8, 8), 8);
	test::eq(backward(15, 8), 8);
	// An alignment of one is the identity, which is what makes it safe to
	// pass through from a caller that does not care.
	test::eq(forward(37, 1), 37);
	test::eq(backward(37, 1), 37);
}

fn void test_is_aligned_and_padding() @test
{
	test::@check(is_aligned(0, 16));
	test::@check(is_aligned(64, 16));
	test::@check(!is_aligned(65, 16));
	test::eq(padding(0, 16), 0);
	test::eq(padding(1, 16), 15);
	test::eq(padding(16, 16), 0);
	test::eq(padding(17, 16), 15);
}

fn void test_the_pointer_versions_agree_with_the_integer_ones() @test
{
	char[64] buffer;
	foreach (alignment : (sz[]){ 1, 2, 4, 8, 16, 32 })
	{
		void* raw = &buffer[1];
		void* up = forward_ptr(raw, alignment);
		test::@check(ptr_is_aligned(up, alignment));
		test::eq((sz)((uptr)up - (uptr)raw), padding_ptr(raw, alignment));
		test::@check((uptr)backward_ptr(up, alignment) == (uptr)up);
	}
}

fn void test_stricter_is_the_larger() @test
{
	test::eq(stricter(1, 16), 16);
	test::eq(stricter(64, 8), 64);
	test::eq(stricter(8, 8), 8);
}

fn void test_alignment_of_a_type() @test
{
	test::eq(alignment_of(char), 1);
	test::eq(alignment_of(long), 8);
	// It folds at compile time, so it can size an array.
	char[alignment_of(long)] eight;
	test::eq(eight.len, 8);
}

fn void test_owns() @test
{
	char[16] buffer;
	char[] region = &buffer;
	test::@check(owns(region, &buffer[0]));
	test::@check(owns(region, &buffer[15]));
	// One past the end is not owned: that address belongs to whatever comes
	// next, and treating it as ours is how two allocators start disagreeing.
	test::@check(!owns(region, (void*)&buffer[15] + 1));

	char[4] elsewhere;
	test::@check(!owns(region, &elsewhere[0]));
}

fn void test_owns_slice() @test
{
	char[16] buffer;
	char[] region = &buffer;
	test::@check(owns_slice(region, region));
	test::@check(owns_slice(region, region[4:8]));
	// An empty slice at the very end is still ours - that is where an empty
	// slice sits after the last allocation.
	test::@check(owns_slice(region, region[16..]));

	char[32] bigger;
	test::@check(!owns_slice(region, &bigger));
}

fn void test_align_slice() @test
{
	char[64] buffer;
	char[] region = ((char[])&buffer)[1..];
	char[] aligned = align_slice(region, 16);
	test::@check(ptr_is_aligned(aligned.ptr, 16));
	test::@check(aligned.len <= region.len);

	// A region too small to reach the next boundary comes back empty rather
	// than as a negative length or a wild pointer.
	char[] tiny = region[:2];
	test::eq(align_slice(tiny, 64).len, 0);
}

fn void test_the_header_leaves_room_for_itself() @test
{
	char[256] buffer;
	foreach (alignment : (sz[]){ 8, 16, 64, 128 })
	{
		void* payload = payload_after(&buffer[0], alignment);
		test::@check(ptr_is_aligned(payload, alignment));
		// The header fits in front of the payload without running back past
		// the start of the region, which is the whole point of reserving the
		// space before aligning rather than after.
		test::@check((uptr)header_of(payload) >= (uptr)&buffer[0]);
	}
}

fn void test_the_header_round_trips() @test
{
	char[128] buffer;
	void* payload = payload_after(&buffer[0], 16);
	Header* header = header_of(payload);
	header.bytes = 40;
	header.pad = (sz)((uptr)payload - (uptr)&buffer[0]);
	header.tail = 8;

	test::eq(header_of(payload).bytes, 40);
	test::eq(header.footprint(), header.pad + 48);
	test::@check((void*)payload - header_of(payload).pad == (void*)&buffer[0]);
}

fn void test_size_prints_the_way_a_person_reads_it() @test
{
	test::eq(string::tformat("%s", size(0)), "0 B");
	test::eq(string::tformat("%s", size(512)), "512 B");
	test::eq(string::tformat("%s", size(1023)), "1023 B");
	test::eq(string::tformat("%s", size(1024)), "1.0 KiB");
	test::eq(string::tformat("%s", size(1536)), "1.5 KiB");
	test::eq(string::tformat("%s", size(1024 * 1024)), "1.0 MiB");
	test::eq(string::tformat("%s", size(340_123_456)), "324.4 MiB");
	test::eq(string::tformat("%s", size(1024L * 1024 * 1024)), "1.0 GiB");
}
