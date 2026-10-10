// What other barrier sequences would cost, written by hand: the store loops of
// barrier_micro.d with the card marking spelled out in D (build WITHOUT
// -gc-card-marking, with the symgc sources so that the card table exists).
//   none       the plain store
//   current    what the LDC pass emits: compiler barrier, card byte, summary byte
//   nobarrier  the same without the compiler barrier
//   checkset   test the card byte first; only when it is clear store both bytes
//   cardonly   the card byte only (the collector would read the whole table)
//   batched    one barrier for the two fields of an object
// Usage: barrier_variants [scale=1]
import core.time : MonoTime;
import core.stdc.stdio : printf;
import ldc.llvmasm;

extern(C) __gshared ubyte* __sd_gc_card_base;
extern(C) __gshared ubyte* __sd_gc_card_summary_base;

final class Node {
	Node next;
	Node other;
	int value;
}

__gshared ulong sink;

enum Mode { none, current, nobarrier, checkset, cardonly }

pragma(inline, true) void mark(Mode m)(void* addr) {
	static if (m == Mode.current) {
		__asm("", "~{memory}");
		__sd_gc_card_base[cast(size_t) addr >> 9] = 1;
		__sd_gc_card_summary_base[cast(size_t) addr >> 16] = 1;
	} else static if (m == Mode.nobarrier) {
		__sd_gc_card_base[cast(size_t) addr >> 9] = 1;
		__sd_gc_card_summary_base[cast(size_t) addr >> 16] = 1;
	} else static if (m == Mode.checkset) {
		__asm("", "~{memory}");
		auto c = __sd_gc_card_base + (cast(size_t) addr >> 9);
		if (*c == 0) {
			*c = 1;
			__sd_gc_card_summary_base[cast(size_t) addr >> 16] = 1;
		}
	} else static if (m == Mode.cardonly) {
		__asm("", "~{memory}");
		__sd_gc_card_base[cast(size_t) addr >> 9] = 1;
	}
}

pragma(inline, false) void arrayStores(Mode m)(void*[] arr, void* p, size_t reps) {
	foreach (r; 0 .. reps)
		foreach (i; 0 .. arr.length) {
			arr[i] = p;
			mark!m(&arr[i]);
		}
}

pragma(inline, false) void twoFields(Mode m)(Node[] nodes, Node p, Node q, size_t reps) {
	foreach (r; 0 .. reps)
		foreach (n; nodes) {
			n.next = p;
			mark!m(&n.next);
			n.other = q;
			mark!m(&n.other);
		}
}

// the same two stores with one barrier: the fields are in the same object, so
// one mark of the first and one of the last byte covers both (usually the same card)
pragma(inline, false) void twoFieldsBatched(Node[] nodes, Node p, Node q, size_t reps) {
	foreach (r; 0 .. reps)
		foreach (n; nodes) {
			n.next = p;
			n.other = q;
			mark!(Mode.current)(&n.next);
			mark!(Mode.current)(&n.other);
		}
}

pragma(inline, false) void twoFieldsOneMark(Mode m)(Node[] nodes, Node p, Node q, size_t reps) {
	foreach (r; 0 .. reps)
		foreach (n; nodes) {
			n.next = p;
			n.other = q;
			// one mark: both fields are within 16 bytes, on one card unless they straddle a boundary
			// (the pass would have to mark the first and the last when it cannot tell)
			mark!m(&n.next);
		}
}

struct Timer {
	MonoTime t0;
	string name;
	ulong ops;
	this(string name, ulong ops) {
		this.name = name;
		this.ops = ops;
		t0 = MonoTime.currTime;
	}

	~this() {
		auto ns = (MonoTime.currTime - t0).total!"nsecs";
		printf("%-40s %8.3f ns/store\n", name.ptr, double(ns) / ops);
	}
}

void main(string[] args) {
	import std.conv : to;
	uint scale = args.length > 1 ? args[1].to!uint : 1;
	enum N = 4096;
	enum reps = 20_000;

	if (__sd_gc_card_base is null) {
		printf("no card table: link the symgc sources\n");
		return;
	}

	auto objs = new Node[N];
	foreach (ref o; objs) o = new Node;
	auto parr = new void*[N];
	auto probe = new Node;

	foreach (round; 0 .. 2) {
		static foreach (m; [Mode.none, Mode.current, Mode.nobarrier, Mode.checkset, Mode.cardonly]) {
			{ auto t = Timer("array element: " ~ m.stringof, ulong(N) * reps * scale); arrayStores!m(parr, cast(void*) probe, reps * scale); }
		}
		static foreach (m; [Mode.none, Mode.current, Mode.nobarrier, Mode.checkset, Mode.cardonly]) {
			{ auto t = Timer("two fields, a barrier each: " ~ m.stringof, ulong(N) * 2 * reps * scale); twoFields!m(objs, probe, probe, reps * scale); }
		}
		static foreach (m; [Mode.current, Mode.checkset]) {
			{ auto t = Timer("two fields, one barrier: " ~ m.stringof, ulong(N) * 2 * reps * scale); twoFieldsOneMark!m(objs, probe, probe, reps * scale); }
		}
		printf("--\n");
	}

	sink += cast(size_t) cast(void*) probe;
}
