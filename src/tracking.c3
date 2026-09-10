// SPDX-License-Identifier: BSL-1.0

// What one allocator counts about another.
//
// `Counters` lives in a module of its own so that a caller can read the
// numbers - or store them, or send them somewhere - without naming the
// category enum they came from. Everything inside a generic module is itself
// generic, and a set of counters is not.
module fluxion::mem::counters;
import fluxion::mem::layout;
import std::io;

<*
 What is known about one category.
*>
struct Counters
{
	// Bytes handed out and not yet given back. What leaked, at shutdown.
	sz live_bytes;
	// Allocations outstanding.
	sz live_count;
	// The most `live_bytes` has ever been - what to size a budget by.
	sz peak_bytes;
	// Everything ever asked for, including what has been given back. A large
	// total against a small peak is churn, which an arena would fix.
	sz total_bytes;
	sz total_count;
	// Requests that failed, because the child allocator had nothing left or
	// because this category is over its limit.
	sz refused_count;
	// The budget. Zero means none.
	sz limit;
}

<*
 @param [&in] self
*>
fn bool Counters.is_empty(&self) => self.live_count == 0 && self.live_bytes == 0;

// -------------------------------------------------------------------------

// An allocator that wraps another one and keeps a running total per category.
//
// The question a debug allocator usually answers is "did anything leak". The
// question an engine asks first is different: **where did the memory go?**
// Six hundred megabytes resident is not a bug report, and a list of eleven
// thousand live allocations is not one either. `textures 412 MiB, meshes
// 96 MiB, audio 38 MiB` is - you can act on that before you have found a
// single line of code.
//
// So the categories are yours, as an enum, and each one gets its own
// `Allocator`:
//
// ```c3
// enum Category { TEXTURES, MESHES, AUDIO, SCRATCH }
//
// Tracking{Category} tracker;
// tracker.init(mem);
//
// Allocator textures = tracker.allocator(TEXTURES);
// Allocator meshes = tracker.allocator(MESHES);
// ```
//
// Pass those down as ordinary `Allocator`s and everything below is counted
// without knowing it is.
//
// **The tag is looked up by ordinal, not by declared value.** C3 gives an
// enum's dense position as `.ordinal`, so an enum with gaps in its values
// still indexes the counters correctly - and that is a good deal simpler than
// the Zig original, which had to search the field list to find the same
// number.
//
// **A budget can be set per category.** `set_limit(TEXTURES, 512 * 1024 *
// 1024)` makes the texture allocator start refusing at half a gigabyte rather
// than at the point the machine gives out. That turns "it ran out eventually,
// on someone else's computer" into a failure that happens on yours, in the
// subsystem responsible.
//
// **Free with the allocator you allocated from.** The tag of a release is the
// tag of the allocator it went through, and there is nowhere else to keep it.
// Freeing a texture through the mesh allocator is caught by an assertion in a
// safe build and silently miscounts in a release one.
//
// This does not detect a use-after-free or a buffer overrun. What it adds is
// the accounting that a debug allocator does not do, and it wraps one happily.
//
// **A `Tracking` must not be copied once initialised**, for the same reason a
// `Stack` must not: the per-category allocators hold a pointer back to it.
//
// One thread at a time. Two threads sharing a category race on its counters.
module fluxion::mem::tracking <Tag>;
import fluxion::mem::layout, fluxion::mem::counters;
import std::core::mem::allocators, std::core::mem::alloc;
import std::io, std::math;

// How many categories there are.
const sz COUNT = Tag::len;

<*
 One category's allocator.

 Never built by hand: `tracker.allocator(TEXTURES)` hands one out, already
 wired to the tracker that owns it.
*>
struct Tagged (Allocator)
{
	Tracking* owner;
	sz index;
}

<*
 A tracker over the categories named by `Tag`, which must be an enum.
*>
struct Tracking
{
	Allocator child;
	Counters[COUNT] counters;
	// One `Tagged` per category, so that `allocator` has something whose
	// address it can hand out.
	Tagged[COUNT] handles;
}

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

<*
 @param [&inout] self
 @param [&inout] child : "the allocator everything is really taken from"
*>
fn Tracking* Tracking.init(&self, Allocator child)
{
	self.child = child;
	foreach (i, &counter : self.counters) *counter = {};
	foreach (i, &handle : self.handles) *handle = { .owner = self, .index = (sz)i };
	return self;
}

<*
 The allocator for one category. Hand this down; everything under it is
 counted against `tag`.

 @param [&inout] self
*>
fn Allocator Tracking.allocator(&self, Tag tag)
{
	return (Allocator)&self.handles[tag.ordinal];
}

// -------------------------------------------------------------------------
// Budgets
// -------------------------------------------------------------------------

<*
 Refuse allocations for `tag` beyond `bytes`. Zero removes the limit.

 Setting a limit below what is already live does not free anything; it stops
 the next allocation.

 @param [&inout] self
*>
fn void Tracking.set_limit(&self, Tag tag, sz bytes)
{
	self.counters[tag.ordinal].limit = bytes;
}

<*
 @param [&in] self
*>
fn sz Tracking.limit_of(&self, Tag tag) => self.counters[tag.ordinal].limit;

// -------------------------------------------------------------------------
// Asking it things
// -------------------------------------------------------------------------

<*
 @param [&in] self
*>
fn Counters Tracking.stats(&self, Tag tag) => self.counters[tag.ordinal];

<*
 Every category added together. The `limit` of the result is the sum of the
 limits, which is a number to compare against a machine rather than a budget
 to enforce.

 @param [&in] self
*>
fn Counters Tracking.totals(&self)
{
	Counters out;
	foreach (c : self.counters)
	{
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

<*
 How many categories still hold something. Zero at shutdown is what you want.

 @param [&in] self
*>
fn sz Tracking.leak_count(&self)
{
	sz leaks = 0;
	foreach (c : self.counters)
	{
		if (!c.is_empty()) leaks++;
	}
	return leaks;
}

<*
 @param [&in] self
*>
fn bool Tracking.leaked(&self) => self.leak_count() != 0;

<*
 Forget everything counted so far, without freeing anything.

 For measuring one part of a run - a level load, a frame - rather than the
 whole of it. Anything live at the time would be counted as a negative when it
 was freed, which is why this asserts that nothing is.

 @param [&inout] self
*>
fn void Tracking.reset_counters(&self)
{
	assert(!self.leaked(), "counters reset while something is still live");
	foreach (&c : self.counters)
	{
		sz keep = c.limit;
		*c = { .limit = keep };
	}
}

// -------------------------------------------------------------------------
// The report
// -------------------------------------------------------------------------

<*
 Where the memory went, as a table.

 Print it at shutdown and any category still holding something is a leak with
 a name on it. Print it after a level load and it is a budget review.

 @param [&in] self
 @param [&inout] out
*>
fn void? Tracking.report(&self, OutStream out)
{
	// The first column is as wide as the longest category name, or the word
	// "category", whichever is more.
	sz name_width = 8;
	foreach (name : Tag::names)
	{
		if (name.len > name_width) name_width = (sz)name.len;
	}
	name_width += 2;

	left(out, "category", name_width)!;
	right(out, "live", 11)!;
	right(out, "peak", 12)!;
	right(out, "total", 12)!;
	right(out, "blocks", 9)!;
	right(out, "limit", 11)!;
	out.write_byte('\n')!;

	foreach (i, name : Tag::names)
	{
		Counters c = self.counters[i];
		left(out, name, name_width)!;
		right(out, string::tformat("%s", layout::size(c.live_bytes)), 11)!;
		right(out, string::tformat("%s", layout::size(c.peak_bytes)), 12)!;
		right(out, string::tformat("%s", layout::size(c.total_bytes)), 12)!;
		right(out, string::tformat("%d", c.live_count), 9)!;
		right(out, c.limit == 0 ? "-" : string::tformat("%s", layout::size(c.limit)), 11)!;
		if (c.refused_count != 0) io::fprintf(out, "   %d refused", c.refused_count)!;
		out.write_byte('\n')!;
	}

	Counters all = self.totals();
	left(out, "total", name_width)!;
	right(out, string::tformat("%s", layout::size(all.live_bytes)), 11)!;
	right(out, "", 12)!;
	right(out, string::tformat("%s", layout::size(all.total_bytes)), 12)!;
	right(out, string::tformat("%d", all.live_count), 9)!;
	out.write_byte('\n')!;

	if (all.live_count != 0)
	{
		io::fprintf(out, "\n%d of %d categories still hold something.\n",
			self.leak_count(), COUNT)!;
	}
}

<*
 The report, straight to standard error - for a `defer` at the end of `main`.

 @param [&in] self
*>
fn void Tracking.report_to_stderr(&self)
{
	if (catch self.report(io::stderr())) { /* nothing useful to do about it */ }
}

fn void? left(OutStream out, String text, sz width)
{
	io::fprint(out, text)!;
	for (sz i = (sz)text.len; i < width; i++) out.write_byte(' ')!;
}

fn void? right(OutStream out, String text, sz width)
{
	for (sz i = (sz)text.len; i < width; i++) out.write_byte(' ')!;
	io::fprint(out, text)!;
}

// -------------------------------------------------------------------------
// The allocators
// -------------------------------------------------------------------------

<*
 Implements the `Allocator` interface.

 The child is asked for a little more than the caller wanted, so that a header
 fits in front of the payload: `release` is handed a pointer and no length, and
 the counters have to know what to take off. The numbers in the report are the
 sizes the caller asked for, not the sizes the child was asked for, because
 the former is what a person can act on.

 @param [&inout] self
 @require size > 0
 @require !alignment || math::is_power_of_2(alignment)
 @return? mem::OUT_OF_MEMORY
*>
fn void*? Tagged.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	Tracking* owner = self.owner;
	Counters* c = &owner.counters[self.index];

	if (c.limit != 0 && c.live_bytes + size > c.limit)
	{
		c.refused_count++;
		return mem::OUT_OF_MEMORY~;
	}

	// The alignment goes down to the child exactly as it arrived, zero
	// included. Zero does not mean "unaligned" - it means "whatever the
	// allocator normally does" - and on Windows the difference matters far
	// more than it looks: a non-zero alignment sends the request through
	// _aligned_malloc, which must be given back through _aligned_free. Passing
	// a tidied-up 16 where the caller said 0 would allocate down one path and
	// free down the other, and the crash would be blamed on this file rather
	// than on the tidying.
	//
	// Only the offset to the payload uses the normalised value, because that
	// is arithmetic of our own.
	sz front = layout::forward(Header::size, allocators::alignment_for_allocation(alignment));
	void*? base = owner.child.acquire(front + size, init_type, alignment);
	if (catch why = base)
	{
		c.refused_count++;
		return why~;
	}

	void* payload = base + front;
	Header* header = layout::header_of(payload);
	header.bytes = size;
	header.pad = front;
	header.tail = 0;

	c.live_bytes += size;
	c.live_count++;
	c.total_bytes += size;
	c.total_count++;
	if (c.live_bytes > c.peak_bytes) c.peak_bytes = c.live_bytes;
	return payload;
}

<*
 Implements the `Allocator` interface.

 @param [&inout] self
 @require ptr != null
 @require new_size > 0
 @require !alignment || math::is_power_of_2(alignment)
 @return? mem::OUT_OF_MEMORY
*>
fn void*? Tagged.resize(&self, void* ptr, sz new_size, sz alignment) @dynamic
{
	Tracking* owner = self.owner;
	Counters* c = &owner.counters[self.index];

	Header* header = layout::header_of(ptr);
	sz old_size = header.bytes;
	sz front = header.pad;

	if (new_size > old_size && c.limit != 0 &&
		c.live_bytes + (new_size - old_size) > c.limit)
	{
		c.refused_count++;
		return mem::OUT_OF_MEMORY~;
	}

	void*? base = owner.child.resize(ptr - front, front + new_size, alignment);
	if (catch why = base)
	{
		c.refused_count++;
		return why~;
	}

	void* payload = base + front;
	Header* moved = layout::header_of(payload);
	moved.bytes = new_size;
	moved.pad = front;
	moved.tail = 0;

	if (new_size >= old_size)
	{
		sz extra = new_size - old_size;
		c.live_bytes += extra;
		c.total_bytes += extra;
		if (c.live_bytes > c.peak_bytes) c.peak_bytes = c.live_bytes;
	}
	else
	{
		sz returned = old_size - new_size;
		assert(c.live_bytes >= returned);
		c.live_bytes -= returned;
	}
	return payload;
}

<*
 Implements the `Allocator` interface.

 @param [&inout] self
 @param [&in] ptr
 @require ptr != null
*>
fn void Tagged.release(&self, void* ptr, bool aligned) @dynamic
{
	Tracking* owner = self.owner;
	Counters* c = &owner.counters[self.index];
	Header* header = layout::header_of(ptr);

	// Releasing through the wrong category's allocator would take the bytes
	// off the wrong total, and there is no way to tell from the pointer which
	// was right. The best that can be done is to notice the impossible case.
	assert(c.live_bytes >= header.bytes, "released through the wrong category's allocator");
	assert(c.live_count >= 1, "released through the wrong category's allocator");

	c.live_bytes -= header.bytes;
	c.live_count--;
	owner.child.release(ptr - header.pad, aligned);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

// As with `pool`, a generic module is only compiled once something asks for
// an instance, so the tests live in a plain module underneath.
// The module is not marked `@test` as a whole: a `@test` function may not
// take parameters, and that would swallow the little `spend` helper below.
// Each test says so for itself instead.
module fluxion::mem::tracking_test;
import fluxion::mem::tracking, fluxion::mem::counters, fluxion::mem::arena, fluxion::mem::layout;
import std::core::mem::alloc;
import std::collections::list;
import std::io;

enum Category
{
	TEXTURES,
	MESHES,
	AUDIO,
	SCRATCH,
}

alias Tracker = Tracking{Category};

fn char[] spend(Allocator a, sz bytes) @local
{
	return alloc::alloc_array(a, char, bytes);
}

fn void each_category_counts_its_own() @test
{
	Tracker tracker;
	tracker.init(mem);
	Allocator textures = tracker.allocator(TEXTURES);
	Allocator meshes = tracker.allocator(MESHES);

	char[] t = spend(textures, 1000);
	defer alloc::free(textures, t.ptr);
	char[] m = spend(meshes, 300);
	defer alloc::free(meshes, m.ptr);

	test::eq(tracker.stats(TEXTURES).live_bytes, 1000);
	test::eq(tracker.stats(TEXTURES).live_count, 1);
	test::eq(tracker.stats(MESHES).live_bytes, 300);
	// A category nothing went through is empty.
	test::eq(tracker.stats(AUDIO).live_bytes, 0);
	test::@check(tracker.stats(AUDIO).is_empty());

	test::eq(tracker.totals().live_bytes, 1300);
	test::eq(tracker.totals().live_count, 2);
}

fn void freeing_takes_it_off_again() @test
{
	Tracker tracker;
	tracker.init(mem);
	Allocator a = tracker.allocator(TEXTURES);

	char[] one = spend(a, 500);
	char[] two = spend(a, 700);
	test::eq(tracker.stats(TEXTURES).live_bytes, 1200);

	alloc::free(a, one.ptr);
	test::eq(tracker.stats(TEXTURES).live_bytes, 700);
	test::eq(tracker.stats(TEXTURES).live_count, 1);

	alloc::free(a, two.ptr);
	test::@check(tracker.stats(TEXTURES).is_empty());
	test::@check(!tracker.leaked());
}

fn void the_peak_is_what_a_budget_is_sized_by_and_the_total_is_churn() @test
{
	Tracker tracker;
	tracker.init(mem);
	Allocator a = tracker.allocator(SCRATCH);

	// A hundred turns of allocate-and-free: a small peak, a large total.
	for (int i = 0; i < 100; i++)
	{
		char[] block = spend(a, 1024);
		alloc::free(a, block.ptr);
	}

	Counters s = tracker.stats(SCRATCH);
	test::eq(s.live_bytes, 0);
	test::eq(s.peak_bytes, 1024);
	test::eq(s.total_bytes, 100 * 1024);
	test::eq(s.total_count, 100);
	// Which is exactly the shape that says "this should have been an arena".
	test::@check(s.total_bytes > s.peak_bytes * 10);
}

fn void a_leak_has_a_category_name_on_it() @test
{
	Tracker tracker;
	tracker.init(mem);
	Allocator textures = tracker.allocator(TEXTURES);
	Allocator meshes = tracker.allocator(MESHES);

	char[] kept = spend(textures, 4096);
	char[] returned = spend(meshes, 100);
	alloc::free(meshes, returned.ptr);

	test::@check(tracker.leaked());
	test::eq(tracker.leak_count(), 1);
	test::@check(!tracker.stats(TEXTURES).is_empty());
	test::@check(tracker.stats(MESHES).is_empty());

	alloc::free(textures, kept.ptr);
	test::@check(!tracker.leaked());
	test::eq(tracker.leak_count(), 0);
}

fn void a_limit_refuses_rather_than_letting_a_subsystem_take_the_machine() @test
{
	Tracker tracker;
	tracker.init(mem);
	Allocator a = tracker.allocator(TEXTURES);

	tracker.set_limit(TEXTURES, 4096);
	test::eq(tracker.limit_of(TEXTURES), 4096);

	char[] first = spend(a, 3000);
	defer alloc::free(a, first.ptr);
	char[] second = spend(a, 1000);
	defer alloc::free(a, second.ptr);

	// Over the budget: refused here, not by the operating system later.
	test::@error(alloc::alloc_array_try(a, char, 500), mem::OUT_OF_MEMORY);
	test::eq(tracker.stats(TEXTURES).refused_count, 1);
	// And nothing was counted for the request that failed.
	test::eq(tracker.stats(TEXTURES).live_bytes, 4000);

	// Another category is unaffected by the texture budget.
	Allocator meshes = tracker.allocator(MESHES);
	char[] m = spend(meshes, 100_000);
	defer alloc::free(meshes, m.ptr);
}

fn void a_limit_can_be_lifted_and_lowered() @test
{
	Tracker tracker;
	tracker.init(mem);
	Allocator a = tracker.allocator(AUDIO);

	tracker.set_limit(AUDIO, 1000);
	test::@error(alloc::alloc_array_try(a, char, 2000), mem::OUT_OF_MEMORY);

	tracker.set_limit(AUDIO, 0); // no limit
	char[] block = spend(a, 2000);
	defer alloc::free(a, block.ptr);

	// Lowering it below what is already live does not free anything, but it
	// does stop the next allocation.
	tracker.set_limit(AUDIO, 100);
	test::eq(tracker.stats(AUDIO).live_bytes, 2000);
	test::@error(alloc::alloc_array_try(a, char, 1), mem::OUT_OF_MEMORY);
}

fn void growing_and_shrinking_are_accounted_for() @test
{
	Tracker tracker;
	tracker.init(mem);
	Allocator a = tracker.allocator(MESHES);

	List{ulong} items;
	items.init(a);

	for (ulong i = 0; i < 1000; i++) items.push(i);

	// Whatever the growth strategy did, what is live matches what the list is
	// actually holding.
	Counters s = tracker.stats(MESHES);
	test::eq(s.live_bytes, (sz)items.capacity * 8);
	test::@check(s.peak_bytes >= s.live_bytes);
	test::@check(s.total_bytes >= s.live_bytes);

	items.free();
	test::@check(tracker.stats(MESHES).is_empty());
}

fn void reset_counters_forgets_a_level_without_freeing_it() @test
{
	Tracker tracker;
	tracker.init(mem);
	Allocator a = tracker.allocator(TEXTURES);

	char[] block = spend(a, 2048);
	alloc::free(a, block.ptr);
	test::eq(tracker.stats(TEXTURES).total_bytes, 2048);

	tracker.set_limit(TEXTURES, 9999);
	tracker.reset_counters();

	test::eq(tracker.stats(TEXTURES).total_bytes, 0);
	test::eq(tracker.stats(TEXTURES).peak_bytes, 0);
	// The budget is not part of what was measured, so it survives.
	test::eq(tracker.limit_of(TEXTURES), 9999);
}

fn void it_wraps_whatever_is_underneath_including_an_arena() @test
{
	char[8192] backing;
	Arena underneath;
	Tracker tracker;
	tracker.init((Allocator)underneath.init(&backing));
	Allocator a = tracker.allocator(SCRATCH);

	char[] block = spend(a, 1000);
	test::eq(tracker.stats(SCRATCH).live_bytes, 1000);
	test::@check(underneath.used >= 1000);

	// The arena refuses eventually, and the refusal is counted here.
	test::@error(alloc::alloc_array_try(a, char, 100_000), mem::OUT_OF_MEMORY);
	test::eq(tracker.stats(SCRATCH).refused_count, 1);

	alloc::free(a, block.ptr);
	test::@check(tracker.stats(SCRATCH).is_empty());
}

fn void the_report_says_where_the_memory_went() @test
{
	Tracker tracker;
	tracker.init(mem);
	Allocator textures = tracker.allocator(TEXTURES);
	Allocator meshes = tracker.allocator(MESHES);

	tracker.set_limit(TEXTURES, 1024 * 1024);

	char[] t = spend(textures, 300 * 1024);
	defer alloc::free(textures, t.ptr);
	char[] m = spend(meshes, 64 * 1024);
	defer alloc::free(meshes, m.ptr);

	DString buffer;
	buffer.init(mem);
	defer buffer.free();
	tracker.report(&buffer)!!;
	String text = buffer.str_view();

	// Every category is named, whether or not it holds anything.
	foreach (name : Category::names) test::@check(text.contains(name));
	// The sizes are the readable kind.
	test::@check(text.contains("300.0 KiB"));
	test::@check(text.contains("64.0 KiB"));
	test::@check(text.contains("1.0 MiB")); // the limit
	// And the leak line, because two categories are still holding something.
	test::@check(text.contains("2 of 4 categories"));
}

fn void the_report_says_nothing_about_leaks_when_there_are_none() @test
{
	Tracker tracker;
	tracker.init(mem);
	Allocator a = tracker.allocator(AUDIO);
	char[] block = spend(a, 128);
	alloc::free(a, block.ptr);

	DString buffer;
	buffer.init(mem);
	defer buffer.free();
	tracker.report(&buffer)!!;
	test::@check(!buffer.str_view().contains("categories still hold"));
}

enum Sparse : int (int declared)
{
	FIRST { 10 },
	SECOND { 200 },
	THIRD { 3 },
}

fn void an_enum_with_explicit_values_still_lines_up() @test
{
	// The counters are indexed by ordinal - the declared position - not by
	// the associated value, so an enum with gaps in it works.
	Tracking{Sparse} tracker;
	tracker.init(mem);

	Allocator first = tracker.allocator(FIRST);
	Allocator second = tracker.allocator(SECOND);
	Allocator third = tracker.allocator(THIRD);

	char[] a = spend(first, 100);
	defer alloc::free(first, a.ptr);
	char[] b = spend(second, 200);
	defer alloc::free(second, b.ptr);
	char[] c = spend(third, 300);
	defer alloc::free(third, c.ptr);

	test::eq(tracker.stats(FIRST).live_bytes, 100);
	test::eq(tracker.stats(SECOND).live_bytes, 200);
	test::eq(tracker.stats(THIRD).live_bytes, 300);
	test::eq(Sparse::len, 3);
}

enum Only
{
	EVERYTHING,
}

fn void one_category_on_its_own() @test
{
	Tracking{Only} tracker;
	tracker.init(mem);
	Allocator a = tracker.allocator(EVERYTHING);

	char[] block = spend(a, 42);
	test::eq(tracker.totals().live_bytes, 42);
	alloc::free(a, block.ptr);
	test::@check(!tracker.leaked());
}

fn void alignment_survives_the_wrapping() @test
{
	Tracker tracker;
	tracker.init(mem);
	Tagged{Category}* a = &tracker.handles[Category.TEXTURES.ordinal];

	foreach (alignment : (sz[]){ 16, 32, 64, 128, 256 })
	{
		void* p = a.acquire(40, NO_ZERO, alignment)!!;
		test::@check(layout::ptr_is_aligned(p, alignment));
		a.release(p, true);
	}
	test::@check(!tracker.leaked());
}
