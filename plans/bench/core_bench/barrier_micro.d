// Cost of the card-marking write barrier on the mutator: stores of pointers,
// pointer array copies, appends and AA inserts, and the controls that do not
// get a barrier (stores of ints, stores to the stack, to globals).
// Build it with and without ldc2 -gc-card-marking, against the same collector.
// Collections are off: without the barrier the collector would miss writes.
// Usage: barrier_micro [scale=1] [only]
import core.memory : GC;
import core.time : MonoTime;
import core.stdc.stdio : printf;

__gshared ulong sink;
__gshared void* globalSlot;

final class Node {
	Node next;
	Node other;
	int value;
}

struct Rec {
	void* a;
	void* b;
	long c;
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
		printf("%-34s %8.2f ns/op  (%.0f ms, %llu ops)\n", name.ptr, double(ns) / ops, ns / 1e6, ops);
	}
}

// each store pattern in a noinline function so that the loop stays a loop
pragma(inline, false) void fillArray(void*[] arr, void* p, size_t reps) {
	foreach (r; 0 .. reps)
		foreach (i; 0 .. arr.length)
			arr[i] = p;
}

pragma(inline, false) void fillFieldsClass(Node[] nodes, Node p, size_t reps) {
	foreach (r; 0 .. reps)
		foreach (n; nodes)
			n.next = p;
}

pragma(inline, false) void fillTwoFields(Node[] nodes, Node p, Node q, size_t reps) {
	foreach (r; 0 .. reps)
		foreach (n; nodes) {
			n.next = p;
			n.other = q;
		}
}

pragma(inline, false) void fillStructs(Rec[] recs, void* p, size_t reps) {
	foreach (r; 0 .. reps)
		foreach (ref x; recs) {
			x.a = p;
			x.b = p;
		}
}

pragma(inline, false) void linkList(Node[] nodes, size_t reps) {
	foreach (r; 0 .. reps)
		foreach (i; 1 .. nodes.length)
			nodes[i - 1].next = nodes[i];
}

pragma(inline, false) void fillInts(int[] arr, size_t reps) {
	foreach (r; 0 .. reps)
		foreach (i; 0 .. arr.length)
			arr[i] = cast(int) i;
}

pragma(inline, false) void fillStack(size_t reps, void* p) {
	void*[16] local;
	foreach (r; 0 .. reps)
		foreach (i; 0 .. local.length) {
			local[i] = p;
			sink += cast(size_t) local[(i + 1) & 15];
		}
}

pragma(inline, false) void fillGlobal(size_t reps, void* p) {
	foreach (r; 0 .. reps)
		globalSlot = p;
}

pragma(inline, false) void copyPtrs(void*[] dst, void*[] src, size_t reps) {
	foreach (r; 0 .. reps)
		dst[] = src[];
}

pragma(inline, false) void copyInts(int[] dst, int[] src, size_t reps) {
	foreach (r; 0 .. reps)
		dst[] = src[];
}

void main(string[] args) {
	import std.conv : to;
	import std.algorithm : canFind;
	uint scale = args.length > 1 ? args[1].to!uint : 1;
	string only = args.length > 2 ? args[2] : "";
	bool want(string n) { return only.length == 0 || n.canFind(only); }

	GC.disable();

	enum N = 4096;
	auto objs = new Node[N];
	foreach (ref o; objs) o = new Node;
	auto parr = new void*[N];
	auto recs = new Rec[N];
	auto iarr = new int[N];
	auto probe = new Node;
	enum reps = 20_000;

	if (want("array")) { auto t = Timer("store ptr: array element", ulong(N) * reps * scale); fillArray(parr, cast(void*) probe, reps * scale); }
	if (want("field")) { auto t = Timer("store ptr: class field", ulong(N) * reps * scale); fillFieldsClass(objs, probe, reps * scale); }
	if (want("two")) { auto t = Timer("store ptr: 2 fields of an object", ulong(N) * 2 * reps * scale); fillTwoFields(objs, probe, probe, reps * scale); }
	if (want("struct")) { auto t = Timer("store ptr: 2 fields of a struct", ulong(N) * 2 * reps * scale); fillStructs(recs, cast(void*) probe, reps * scale); }
	if (want("link")) { auto t = Timer("store ptr: linked list", ulong(N - 1) * reps * scale); linkList(objs, reps * scale); }
	if (want("ints")) { auto t = Timer("control: store int", ulong(N) * reps * scale); fillInts(iarr, reps * scale); }
	if (want("stack")) { auto t = Timer("control: store ptr to the stack", ulong(16) * reps * 10 * scale); fillStack(reps * 10 * scale, cast(void*) probe); }
	if (want("global")) { auto t = Timer("control: store ptr to a global", ulong(reps) * 100 * scale); fillGlobal(reps * 100 * scale, cast(void*) probe); }

	enum cp = 1000;
	foreach (n; [8, 64, 1024]) {
		auto d = new void*[n];
		auto s = new void*[n];
		auto di = new int[n];
		auto si = new int[n];
		auto rr = cp * 64 * scale * 4 / n * 8;
		string a = n == 8 ? "copy 8 ptrs (memcpy)" : n == 64 ? "copy 64 ptrs (memcpy)" : "copy 1024 ptrs (memcpy)";
		string b = n == 8 ? "control: copy 8 ints" : n == 64 ? "control: copy 64 ints" : "control: copy 1024 ints";
		if (want("copy")) {
			{ auto t = Timer(a, rr); copyPtrs(d, s, rr / 1); }
			{ auto t = Timer(b, rr); copyInts(di, si, rr / 1); }
		}
	}

	// library code: appends of pointers, AA inserts (compiled into the runtime with the barrier)
	if (want("append")) {
		auto t = Timer("append ptrs (library)", ulong(20_000) * 64 * scale);
		foreach (r; 0 .. 20_000 * scale) {
			void*[] v;
			foreach (i; 0 .. 64) v ~= cast(void*) probe;
			sink += v.length;
		}
	}

	if (want("aa")) {
		auto t = Timer("aa insert (library), ptr values", ulong(100_000) * 5 * scale);
		foreach (r; 0 .. 5 * scale) {
			Node[int] m;
			foreach (i; 0 .. 100_000) m[i] = probe;
			sink += m.length;
		}
	}

	printf("sink=%llu\n", sink);
}
