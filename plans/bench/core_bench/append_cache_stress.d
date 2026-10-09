// Stress for the append cache of symgc (ThreadCache.resize): every thread keeps
// appending to arrays of many sizes while arrays die, slabs are freed and their
// pages come back as other size classes, and one thread collects all the time.
// Every array is checked against a pattern, and the stomping rule is checked:
// appending to a slice that ends before the used part must not touch the rest.
// Usage: append_cache_stress [seconds=10] [threads=4]
// Prints "APPEND CACHE OK" at the end.
import core.memory : GC;
import core.atomic;
import core.thread;
import core.time : MonoTime, seconds;
import core.stdc.stdio : printf;
import core.stdc.stdlib : exit;

shared bool stop;
shared ulong failures;
shared ulong appends;

struct Rng {
	ulong s;
	uint next() {
		s = s * 6364136223846793005UL + 1442695040888963407UL;
		return cast(uint) (s >> 33);
	}
}

void fail(string what, uint thread) {
	printf("FAIL thread %u: %.*s\n", thread, cast(int) what.length, what.ptr);
	atomicOp!"+="(failures, 1);
}

// an array of T where element i holds f(i, tag)
void worker(T)(uint id, ulong seed) {
	Rng rng = Rng(seed);
	static T make(size_t i, uint tag) {
		static if (is(T == ubyte)) return cast(ubyte) (i * 7 + tag);
		else static if (is(T == int)) return cast(int) (i * 2654435761U + tag);
		else return T(cast(ulong) i * 31 + tag, cast(ubyte) (i + tag));
	}

	struct Live {
		T[] arr;
		uint tag;
	}

	Live[64] live;
	ulong n;
	while (!atomicLoad(stop)) {
		auto k = rng.next() % live.length;
		auto op = rng.next() % 10;
		auto l = &live[k];

		if (op < 5) {
			// append a few elements to the array
			auto count = 1 + rng.next() % 40;
			foreach (j; 0 .. count) {
				l.arr ~= make(l.arr.length, l.tag);
				n++;
			}
		} else if (op < 6) {
			// start over: the old array dies, its slot or slab may be freed
			l.arr = null;
			l.tag = rng.next();
		} else if (op < 7) {
			// interleave appends between two arrays: thrashes the cache
			auto k2 = rng.next() % live.length;
			auto l2 = &live[k2];
			foreach (j; 0 .. 8) {
				l.arr ~= make(l.arr.length, l.tag);
				l2.arr ~= make(l2.arr.length, l2.tag);
				n += 2;
			}
		} else if (op < 8 && l.arr.length > 4) {
			// the stomping rule: a shorter slice must not append in place
			auto whole = l.arr;
			auto shorter = whole[0 .. whole.length / 2];
			auto before = whole.dup;
			shorter ~= make(shorter.length, l.tag + 1);
			foreach (i; 0 .. whole.length) {
				if (whole[i] != before[i]) {
					fail("append to a shorter slice overwrote the rest", id);
					break;
				}
			}
		} else if (op < 9 && l.arr.length > 10) {
			// an interior slice, appended to
			auto inner = l.arr[3 .. $];
			auto before = l.arr.dup;
			inner ~= make(inner.length, 99);
			foreach (i; 0 .. l.arr.length) {
				if (l.arr[i] != before[i]) {
					fail("append to an interior slice changed the array", id);
					break;
				}
			}
		} else {
			// garbage of many sizes so slabs fill, die and get reused
			auto sz = 1 + rng.next() % 2000;
			auto g = new ubyte[](sz);
			g[0] = 1;
			n++;
		}

		// check the pattern now and then
		if (rng.next() % 16 == 0) {
			foreach (i, v; l.arr) {
				if (v != make(i, l.tag)) {
					fail("array contents changed", id);
					break;
				}
			}
		}

		if (l.arr.length > 4000) {
			l.arr = null;
			l.tag = rng.next();
		}
	}

	atomicOp!"+="(appends, n);
}

void collector() {
	while (!atomicLoad(stop)) {
		GC.collect();
		Thread.sleep(5.msecs);
	}
}

import core.time : msecs;

struct Pair {
	ulong a;
	ubyte b;
}

void main(string[] args) {
	import std.conv : to;
	auto secs = args.length > 1 ? args[1].to!int : 10;
	auto nthreads = args.length > 2 ? args[2].to!uint : 4;

	Thread[] ts;
	foreach (i; 0 .. nthreads) {
		auto id = cast(uint) i;
		final switch (i % 3) {
			case 0: ts ~= new Thread({ worker!ubyte(id, 1000 + id); }); break;
			case 1: ts ~= new Thread({ worker!int(id, 2000 + id); }); break;
			case 2: ts ~= new Thread({ worker!Pair(id, 3000 + id); }); break;
		}
	}

	auto c = new Thread(&collector);
	c.start();
	foreach (t; ts) t.start();

	Thread.sleep(secs.seconds);
	atomicStore(stop, true);
	foreach (t; ts) t.join();
	c.join();

	if (atomicLoad(failures) != 0) {
		printf("APPEND CACHE FAILED: %llu\n", atomicLoad(failures));
		exit(1);
	}

	printf("APPEND CACHE OK (%llu operations)\n", atomicLoad(appends));
}
