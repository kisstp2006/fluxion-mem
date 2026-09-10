// SPDX-License-Identifier: BSL-1.0

// A tour of Fluxion Mem. Run it with `c3c run demo`.
//
// It builds one engine's memory: a tracked budget at the top, a level and a
// frame sharing one buffer beneath it, a pool of entities, and a fixed region
// that fragments where you can watch it. Then it prints the report that says
// where everything went.
module demo;
import fluxion::mem;
import std::core::mem::alloc;
import std::math::random;
import std::collections::list;
import std::io;

// What the engine's memory divides into. One `Allocator` per line, and one row
// in the report at the end.
enum Category
{
	LEVEL,
	FRAME,
	ENTITIES,
	TEXTURES,
	SCRATCH,
}

struct Entity
{
	float x;
	float y;
	ushort health;
}

alias Tracker = Tracking{Category};
alias Entities = Pool{Entity};

// A cell in a column: the text, padded on the left so a column of sizes lines
// up. The sizes are rendered first and then padded, because a `Size` writes
// itself straight to the stream and cannot be given a width.
fn String cell(String text, sz width)
{
	if ((sz)text.len >= width) return text;
	DString padded;
	padded.init(tmem);
	for (sz i = (sz)text.len; i < width; i++) padded.append_char(' ');
	padded.append(text);
	return padded.str_view();
}

fn String bytes(sz n, sz width)
{
	return cell(string::tformat("%s", mem::size(n)), width);
}

fn String number(sz n, sz width)
{
	return cell(string::tformat("%d", n), width);
}

fn int main()
{
	Tracker tracker;
	tracker.init(mem);
	tracker.set_limit(TEXTURES, mem::mib(8));
	tracker.set_limit(ENTITIES, mem::kib(64));

	the_arena();
	the_stack(&tracker);
	the_pool(&tracker);
	the_free_list(&tracker);
	the_report(&tracker);
	return 0;
}

// -------------------------------------------------------------------------
// The arena
// -------------------------------------------------------------------------

fn void the_arena()
{
	io::printn("\n--- a frame arena ---\n");

	char[mem::kib(64)] backing;
	Arena arena;
	Allocator a = (Allocator)arena.init(&backing);

	io::printfn("buffer %s\n", mem::size(arena.capacity()));
	io::printfn("frame          used       peak       left");

	for (sz frame = 0; frame < 6; frame++)
	{
		defer arena.reset();

		// A frame's worth of work: a visible list, a string, some scratch.
		uint[] visible = alloc::alloc_array(a, uint, 200 + frame * 300);
		foreach (i, &id : visible) *id = (uint)i;
		// `(void)` is C3's way of saying "the result really is not wanted":
		// these two allocations exist only to move the arena on.
		(void)string::format(a, "frame %d: %d visible", frame, visible.len);
		(void)alloc::alloc_array(a, char, 512);

		io::printfn("%s %s %s %s",
			cell(string::tformat("%d", frame), 5),
			bytes(arena.used, 10),
			bytes(arena.high_water, 10),
			bytes(arena.remaining(), 10));
	}

	io::printfn("\nSix frames, one buffer, and nothing allocated after startup. The peak\n"
		"is %s, so a buffer of that size would have done - which is the number\n"
		"`high_water` exists to give you.", mem::size(arena.high_water));

	// And the scratch scope, which is the same arena used as a stack.
	(void)alloc::alloc_array(a, char, 64);
	sz outside = arena.used;
	{
		Scope scratch = arena.scope();
		defer scratch.end();
		(void)alloc::alloc_array(a, char, mem::kib(8));
		io::printfn("\ninside a scratch scope: %s used", mem::size(arena.used));
	}
	io::printfn("after it:               %s used", mem::size(arena.used));
	// Exactly where it was before the block, padding and all.
	assert(arena.used == outside);
}

// -------------------------------------------------------------------------
// The stack
// -------------------------------------------------------------------------

fn void the_stack(Tracker* tracker)
{
	io::printn("\n--- a level and its frames, in one buffer ---\n");

	Allocator owner = tracker.allocator(LEVEL);
	Stack stack;
	stack.init_alloc(owner, mem::kib(32))!!;
	defer stack.free_from(owner);

	Allocator level = stack.allocator(BACK);
	Allocator frame = stack.allocator(FRONT);

	// Loaded once, and never freed until the level changes.
	float[] mesh = alloc::alloc_array(level, float, 1400);
	mesh[..] = 1.5;
	ushort[] collision = alloc::alloc_array(level, ushort, 900);
	collision[..] = 7;

	io::printn("frame         front       back      between   layout");

	for (sz i = 0; i < 5; i++)
	{
		defer stack.reset(FRONT);

		uint[] visible = alloc::alloc_array(frame, uint, 100 + i * 200);
		foreach (n, &id : visible) *id = (uint)n;
		(void)string::format(frame, "%d draw calls", visible.len);

		io::printf("%s %s %s %s   ",
			cell(string::tformat("%d", i), 5),
			bytes(stack.used_by(FRONT), 10),
			bytes(stack.used_by(BACK), 10),
			bytes(stack.remaining(), 12));
		draw_stack(&stack, 40);
		io::printn("");
	}

	io::printn("\n`<` is the front, growing right; `>` is the back, growing left; `.` is\n"
		"what neither has claimed. Neither end was given a budget - they share\n"
		"what is between them, which is the thing two separate arenas cannot do.");

	// The level data is untouched by any of that.
	assert(mesh[700] == 1.5f);
	assert(collision[400] == 7);
}

// One line of the stack, as a picture.
fn void draw_stack(Stack* stack, sz width)
{
	sz total = stack.capacity();
	sz front = stack.used_by(FRONT) * width / total;
	sz back = stack.used_by(BACK) * width / total;

	for (sz i = 0; i < width; i++)
	{
		char c = '.';
		if (i < front)
		{
			c = '<';
		}
		else if (i >= width - back)
		{
			c = '>';
		}
		io::printf("%c", c);
	}
}

// -------------------------------------------------------------------------
// The pool
// -------------------------------------------------------------------------

fn void the_pool(Tracker* tracker)
{
	io::printn("\n--- a pool of entities ---\n");

	Allocator owner = tracker.allocator(ENTITIES);
	Entities pool;
	pool.init_alloc(owner, 512)!!;
	defer pool.free_from(owner);

	io::printfn("%s\n", &pool);

	// Spawn some, kill some, spawn some more - the shape of a whole run.
	List{Index} live;
	live.init(mem);
	defer live.free();

	Random rng = (Random)&&(Sfc64Random){};
	random::seed(rng, 0xE0717EUL);

	io::printn("tick          live    peak   spare");

	for (sz tick = 0; tick <= 2000; tick++)
	{
		if (live.len() < 400 && (live.len() == 0 || random::next_bool(rng)))
		{
			Index index = pool.create_index()!!;
			*pool.at(index) = {
				.x = random::next_float(rng) * 100,
				.y = random::next_float(rng) * 100,
				.health = 100,
			};
			live.push(index);
		}
		else if (live.len() > 0)
		{
			sz which = (sz)random::next(rng, (int)live.len());
			pool.destroy_index(live[which]);
			live.swap(which, live.len() - 1);
			live.pop()!!;
		}

		if (tick % 400 == 0)
		{
			io::printfn("%s %s %s %s",
				cell(string::tformat("%d", tick), 6),
				number(pool.live, 7),
				number(pool.high_water, 7),
				number(pool.available(), 7));
		}
	}

	// The whole point: after two thousand turns of churn, whatever is free can
	// still be handed out. A pool does not fragment.
	sz taken = 0;
	while (try index = pool.create_index()) taken++;
	io::printfn("\nAfter 2000 spawns and kills, %d slots were still free and every one of\n"
		"them could be taken - a pool cannot fragment, because every free slot\n"
		"fits every request. `create` and `destroy` are a pointer swap each.", taken);
}

// -------------------------------------------------------------------------
// The free list
// -------------------------------------------------------------------------

fn void the_free_list(Tracker* tracker)
{
	io::printn("\n--- a fixed region, and what fragments it ---\n");

	Allocator owner = tracker.allocator(TEXTURES);
	FreeList list;
	list.init_alloc(owner, mem::kib(4))!!;
	defer list.free_from(owner);

	Allocator a = (Allocator)&list;

	char[][16] blocks;
	for (sz i = 0; i < 16; i++) blocks[i] = alloc::alloc_array(a, char, 180);

	io::printf("sixteen blocks of 180 bytes:\n  ");
	draw_free_list(&list, 64);
	io::printfn("\n  %s", &list);

	// Free every other one.
	for (sz i = 0; i < 16; i += 2) alloc::free(a, blocks[i].ptr);

	io::printf("\nevery other one freed:\n  ");
	draw_free_list(&list, 64);
	io::printfn("\n  %s", &list);

	sz half = list.free_bytes() / 2;
	if (try got = list.acquire(half, NO_ZERO, 0))
	{
		io::printn("\n  ...and half of what is free could still be allocated.");
		list.release(got, false);
	}
	else
	{
		io::printfn("\n  %s is free, but the largest single block is %s - so an\n"
			"  allocation of %s is refused. That is fragmentation, and it is the\n"
			"  failure an arena and a pool cannot have.",
			mem::size(list.free_bytes()), mem::size(list.largest_free()), mem::size(half));
	}

	// Free the rest, and it all joins back into one block.
	for (sz i = 1; i < 16; i += 2) alloc::free(a, blocks[i].ptr);

	io::printf("\nand the rest freed:\n  ");
	draw_free_list(&list, 64);
	io::printfn("\n  %s", &list);
	assert(list.block_count() == 1);
	assert(list.verify());
}

// The region as a picture: `#` is handed out, `.` is free.
fn void draw_free_list(FreeList* list, sz width)
{
	uptr start = (uptr)list.buffer.ptr;
	sz total = list.capacity();

	for (sz column = 0; column < width; column++)
	{
		uptr offset = start + (uptr)(column * total / width);

		bool free = false;
		for (Node* node = list.first; node != null; node = node.next)
		{
			uptr at = (uptr)node;
			if (offset >= at && offset < at + (uptr)node.size)
			{
				free = true;
				break;
			}
		}
		io::printf("%c", free ? '.' : '#');
	}
}

// -------------------------------------------------------------------------
// The report
// -------------------------------------------------------------------------

fn void the_report(Tracker* tracker)
{
	io::printn("\n--- where the memory went ---\n");

	// A little more, so the table has something in every row.
	Allocator scratch = tracker.allocator(SCRATCH);
	char[] block = alloc::alloc_array(scratch, char, mem::kib(12));
	alloc::free(scratch, block.ptr);

	// And a category that runs into its budget.
	Allocator textures = tracker.allocator(TEXTURES);
	if (try over = alloc::alloc_array_try(textures, char, mem::mib(16)))
	{
		alloc::free(textures, over.ptr);
	}

	tracker.report(io::stdout())!!;

	io::printn("\n`live` at shutdown is a leak, and it has a category name on it rather\n"
		"than a stack trace to read. `peak` is what to size a budget by. A\n"
		"`total` far above the `peak` is churn - memory allocated and freed over\n"
		"and over, which is what an `Arena` is for.");
}
