// More barrier shapes, written by hand (build WITHOUT -gc-card-marking, with the
// symgc sources). The loads of the two table bases are the same value for the
// whole run (set in .preinit_array), so the pass could mark them invariant and
// let LLVM keep them in registers; this measures what that is worth, alone and
// with threads that write into neighbouring objects (the card and summary
// bytes are then shared cache lines).
//   current   what the pass emits today: the bases are reloaded for each mark
//   hoisted   the bases loaded once, before the loop
//   hoisted-cardonly   hoisted, and no summary byte
//   none      the plain store
// Usage: barrier_variants2 [threads=1] [layout=private|shared]
import core.time : MonoTime;
import core.stdc.stdio : printf;
import core.thread;
import core.atomic;
import ldc.llvmasm;

extern(C) __gshared ubyte* __sd_gc_card_base;
extern(C) __gshared ubyte* __sd_gc_card_summary_base;

final class Node {
	Node next;
	Node other;
	int value;
}

enum Mode { none, current, hoisted, hoistedCardOnly }

pragma(inline, false) void twoFields(Mode m)(Node[] nodes, size_t from, size_t step, Node p, Node q, size_t reps) {
	static if (m == Mode.hoisted || m == Mode.hoistedCardOnly) {
		auto cb = __sd_gc_card_base;
		auto sb = __sd_gc_card_summary_base;
	}

	foreach (r; 0 .. reps)
		for (size_t i = from; i < nodes.length; i += step) {
			auto n = nodes[i];
			n.next = p;
			static if (m == Mode.current) {
				__asm("", "~{memory}");
				__sd_gc_card_base[cast(size_t) &n.next >> 9] = 1;
				__sd_gc_card_summary_base[cast(size_t) &n.next >> 16] = 1;
			} else static if (m == Mode.hoisted) {
				__asm("", "~{memory}");
				cb[cast(size_t) &n.next >> 9] = 1;
				sb[cast(size_t) &n.next >> 16] = 1;
			} else static if (m == Mode.hoistedCardOnly) {
				__asm("", "~{memory}");
				cb[cast(size_t) &n.next >> 9] = 1;
			}

			n.other = q;
			static if (m == Mode.current) {
				__asm("", "~{memory}");
				__sd_gc_card_base[cast(size_t) &n.other >> 9] = 1;
				__sd_gc_card_summary_base[cast(size_t) &n.other >> 16] = 1;
			} else static if (m == Mode.hoisted) {
				__asm("", "~{memory}");
				cb[cast(size_t) &n.other >> 9] = 1;
				sb[cast(size_t) &n.other >> 16] = 1;
			} else static if (m == Mode.hoistedCardOnly) {
				__asm("", "~{memory}");
				cb[cast(size_t) &n.other >> 9] = 1;
			}
		}
}

void run(Mode m)(string name, Node[] objs, uint threads, bool shared_, Node probe, size_t reps) {
	auto t0 = MonoTime.currTime;
	Thread[] ts;
	foreach (t; 0 .. threads) {
		auto tt = t;
		ts ~= new Thread({
			// shared layout: the threads take every threads-th object, so they write into the same cards;
			// private layout: each thread has a range of its own
			if (shared_)
				twoFields!m(objs, tt, threads, probe, probe, reps);
			else {
				auto per = objs.length / threads;
				twoFields!m(objs[tt * per .. (tt + 1) * per], 0, 1, probe, probe, reps);
			}
		});
		ts[$ - 1].start();
	}

	foreach (t; ts) t.join();
	auto ns = (MonoTime.currTime - t0).total!"nsecs";
	// stores per thread: 2 per object visited
	double stores = double(objs.length) / threads * 2 * reps;
	printf("%-34s threads=%u %-8s %7.3f ns/store/thread\n", name.ptr, threads, shared_ ? "shared".ptr : "private".ptr, ns / stores);
}

void main(string[] args) {
	import std.conv : to;
	uint threads = args.length > 1 ? args[1].to!uint : 1;
	bool sharedLayout = args.length > 2 && args[2] == "shared";
	if (__sd_gc_card_base is null) {
		printf("no card table: link the symgc sources\n");
		return;
	}

	enum N = 16384;
	auto objs = new Node[N];
	foreach (ref o; objs) o = new Node;
	auto probe = new Node;
	size_t reps = 8000;

	foreach (round; 0 .. 2) {
		run!(Mode.none)("none", objs, threads, sharedLayout, probe, reps);
		run!(Mode.current)("current (bases reloaded)", objs, threads, sharedLayout, probe, reps);
		run!(Mode.hoisted)("hoisted bases", objs, threads, sharedLayout, probe, reps);
		run!(Mode.hoistedCardOnly)("hoisted, card byte only", objs, threads, sharedLayout, probe, reps);
		printf("--\n");
	}
}
