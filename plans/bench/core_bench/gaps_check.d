// Checks of the druntime interface of symgc: objects given a finalizer with
// setAttr (the monitor of an object), runFinalizers, attributes of realloc,
// profileStats. Prints "GAPS CHECK OK" at the end.
// Usage: gaps_check [rounds=3]
import core.memory;
import core.stdc.stdio : printf;
import core.atomic;
import core.thread;

extern(C) void rt_attachDisposeEvent(Object h, void delegate(Object) e);

shared int disposed;

class Plain {
	int x;
}

class Big {
	long[40] data;
}

class WithDtor {
	static shared int count;
	~this() { atomicOp!"+="(count, 1); }
}

void fail(string what) {
	printf("FAIL: %.*s\n", cast(int) what.length, what.ptr);
	import core.stdc.stdlib : exit;
	exit(1);
}

// monitors: an object that is synchronized on gets its monitor freed when it dies
void monitors(int n) {
	foreach (i; 0 .. n) {
		Object o = (i % 3 == 0) ? new Plain : ((i % 3 == 1) ? new Big : new Object);
		synchronized (o) {}
		rt_attachDisposeEvent(o, (Object) { atomicOp!"+="(disposed, 1); });
	}
}

void monitorsTest(int n) {
	disposed = 0;
	monitors(n);

	foreach (i; 0 .. 3) {
		GC.collect();
	}

	auto d = atomicLoad(disposed);
	printf("monitors: %d of %d disposed\n", d, n);
	// a few may stay alive through stale stack words (the GC is conservative)
	if (d < n * 9 / 10) {
		fail("monitors of dead objects were not freed");
	}
}

// getAttr / setAttr / clrAttr
void attrTest() {
	auto o = new Plain;
	if (GC.getAttr(cast(void*) o) & GC.BlkAttr.FINALIZE) fail("plain object has FINALIZE");
	GC.setAttr(cast(void*) o, GC.BlkAttr.FINALIZE);
	if (!(GC.getAttr(cast(void*) o) & GC.BlkAttr.FINALIZE)) fail("setAttr(FINALIZE) not seen by getAttr");
	GC.clrAttr(cast(void*) o, GC.BlkAttr.FINALIZE);
	if (GC.getAttr(cast(void*) o) & GC.BlkAttr.FINALIZE) fail("clrAttr(FINALIZE) not seen by getAttr");

	// large block
	auto p = GC.malloc(1 << 20, 0);
	if (GC.getAttr(p) & GC.BlkAttr.FINALIZE) fail("large block has FINALIZE");
	GC.setAttr(p, GC.BlkAttr.FINALIZE);
	if (!(GC.getAttr(p) & GC.BlkAttr.FINALIZE)) fail("large setAttr(FINALIZE)");
	GC.clrAttr(p, GC.BlkAttr.FINALIZE);
	if (GC.getAttr(p) & GC.BlkAttr.FINALIZE) fail("large clrAttr(FINALIZE)");
	GC.free(p);
}

// an entry must die with the slot: free objects that have one, reuse the slots
void freedSlotsTest(int n) {
	foreach (round; 0 .. 20) {
		foreach (i; 0 .. n) {
			auto o = new Plain;
			synchronized (o) {}
			GC.free(cast(void*) o); // explicit free: the entry goes with it
			// the same slot, as something that must not be finalized as an object
			auto p = cast(ubyte[]) GC.malloc(16, GC.BlkAttr.NO_SCAN)[0 .. 16];
			p[] = 0xAA;
		}
		GC.collect();
	}
}

// realloc: no attributes keeps the block's
void reallocTest() {
	foreach (m; [16, 1024, 1024 * 1024]) {
		auto p = GC.malloc(8 * m, 0);
		if (GC.getAttr(p) != 0) fail("malloc attr");
		p = GC.realloc(p, 8 * m + 5, GC.BlkAttr.NO_SCAN);
		if (GC.getAttr(p) != GC.BlkAttr.NO_SCAN) fail("realloc did not set NO_SCAN");
		p = GC.realloc(p, 2 * m, 0);
		if (GC.getAttr(p) != GC.BlkAttr.NO_SCAN) fail("shrinking realloc lost NO_SCAN");
		p = GC.realloc(p, 8 * m, 0);
		if (GC.getAttr(p) != GC.BlkAttr.NO_SCAN) fail("growing realloc lost NO_SCAN");
		GC.free(p);
	}
}

// runFinalizers on the destructor of a class
void runFinalizersTest() {
	WithDtor.count = 0;
	auto o = new WithDtor;
	GC.runFinalizers((cast(const void*) typeid(WithDtor).destructor)[0 .. 1]);
	if (atomicLoad(WithDtor.count) != 1) fail("runFinalizers did not run the destructor");

	// not a second time at the collection
	o = null;
	GC.collect();
	GC.collect();
	if (atomicLoad(WithDtor.count) != 1) fail("destructor ran twice");
}

// profileStats counts explicit and automatic collections
void profileTest() {
	auto before = GC.profileStats().numCollections;
	GC.collect();
	auto mid = GC.profileStats().numCollections;
	if (mid <= before) fail("profileStats did not count GC.collect");

	// garbage until an automatic one runs
	foreach (i; 0 .. 4_000_000) {
		auto a = new ubyte[](64);
		a[0] = 1;
	}

	auto after = GC.profileStats();
	printf("profileStats: %llu collections, total %lld ms, longest pause %lld us\n",
	       cast(ulong) after.numCollections, after.totalCollectionTime.total!"msecs",
	       after.maxPauseTime.total!"usecs");
	if (after.numCollections <= mid) fail("profileStats did not count automatic collections");
	if (after.totalCollectionTime.total!"hnsecs" == 0) fail("profileStats has no time");
}

void main(string[] args) {
	import std.conv : to;
	auto rounds = args.length > 1 ? args[1].to!int : 3;
	foreach (r; 0 .. rounds) {
		monitorsTest(3000);
		attrTest();
		freedSlotsTest(2000);
		reallocTest();
		runFinalizersTest();
	}

	profileTest();
	printf("GAPS CHECK OK\n");
}
