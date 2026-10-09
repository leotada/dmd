// Natural D code that allocates: appends and associative arrays.
// Usage: append_aa [scale=1]
// Prints nanoseconds per operation for each pattern.
import core.time : MonoTime;
import core.stdc.stdio : printf;

__gshared ulong sink;

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
		printf("%-34s %8.1f ns/op  (%.0f ms, %llu ops)\n", name.ptr, double(ns) / ops, ns / 1e6, ops);
	}
}

// many short arrays, each built by appends
void appendFresh(uint scale) {
	enum arrays = 20_000;
	enum per = 64;
	auto t = Timer("append: fresh arrays of 64", cast(ulong) arrays * per * scale);
	foreach (r; 0 .. scale) {
		foreach (a; 0 .. arrays) {
			int[] v;
			foreach (i; 0 .. per) v ~= i;
			sink += v.length;
		}
	}
}

// one array, appended and emptied with length = 0 (the pitfall)
void appendShrinkReuse(uint scale) {
	enum per = 256;
	enum rounds = 20_000;
	auto t = Timer("append: length=0 then append", cast(ulong) per * rounds * scale);
	int[] v;
	foreach (r; 0 .. rounds * scale) {
		v.length = 0;
		foreach (i; 0 .. per) v ~= i;
		sink += v.length;
	}
}

// the same with assumeSafeAppend, the documented way
void appendShrinkAssume(uint scale) {
	enum per = 256;
	enum rounds = 20_000;
	auto t = Timer("append: length=0, assumeSafeAppend", cast(ulong) per * rounds * scale);
	int[] v;
	foreach (r; 0 .. rounds * scale) {
		v.length = 0;
		v.assumeSafeAppend();
		foreach (i; 0 .. per) v ~= i;
		sink += v.length;
	}
}

// reserve first
void appendReserve(uint scale) {
	enum arrays = 20_000;
	enum per = 64;
	auto t = Timer("append: reserved arrays of 64", cast(ulong) arrays * per * scale);
	foreach (r; 0 .. scale) {
		foreach (a; 0 .. arrays) {
			int[] v;
			v.reserve(per);
			foreach (i; 0 .. per) v ~= i;
			sink += v.length;
		}
	}
}

// big arrays, appended up to a million elements
void appendBig(uint scale) {
	enum arrays = 20;
	enum per = 1_000_000;
	auto t = Timer("append: arrays of 1M", cast(ulong) arrays * per * scale);
	foreach (r; 0 .. scale) {
		foreach (a; 0 .. arrays) {
			int[] v;
			foreach (i; 0 .. per) v ~= i;
			sink += v.length;
		}
	}
}

// concatenation of strings: the other common source of garbage
void concat(uint scale) {
	enum n = 200_000;
	auto t = Timer("concat: a ~ b ~ c", cast(ulong) n * scale);
	string a = "frame ", c = " done";
	foreach (r; 0 .. scale) {
		foreach (i; 0 .. n) {
			string b = "xyz";
			auto s = a ~ b ~ c;
			sink += s.length;
		}
	}
}

// associative arrays
void aaInsert(uint scale) {
	enum n = 100_000;
	auto t = Timer("aa: insert 100k int keys", cast(ulong) n * scale);
	foreach (r; 0 .. scale) {
		int[int] m;
		foreach (i; 0 .. n) m[i * 7] = i;
		sink += m.length;
	}
}

void aaLookup(uint scale) {
	enum n = 100_000;
	int[int] m;
	foreach (i; 0 .. n) m[i * 7] = i;
	enum reps = 20;
	auto t = Timer("aa: lookup int keys", cast(ulong) n * reps * scale);
	foreach (r; 0 .. reps * scale) {
		foreach (i; 0 .. n) sink += m[i * 7];
	}
}

void aaIterate(uint scale) {
	enum n = 100_000;
	int[int] m;
	foreach (i; 0 .. n) m[i * 7] = i;
	enum reps = 20;
	auto t = Timer("aa: iterate", cast(ulong) n * reps * scale);
	foreach (r; 0 .. reps * scale) {
		foreach (k, v; m) sink += v;
	}
}

void aaSmall(uint scale) {
	enum maps = 50_000;
	enum per = 8;
	auto t = Timer("aa: many small maps of 8", cast(ulong) maps * per * scale);
	foreach (r; 0 .. scale) {
		foreach (a; 0 .. maps) {
			int[int] m;
			foreach (i; 0 .. per) m[i] = i;
			sink += m.length;
		}
	}
}

void aaString(uint scale) {
	enum n = 50_000;
	string[] names;
	foreach (i; 0 .. n) {
		import std.conv : to;
		names ~= "citizen" ~ i.to!string;
	}

	auto t = Timer("aa: insert+lookup string keys", cast(ulong) n * 2 * scale);
	foreach (r; 0 .. scale) {
		int[string] m;
		foreach (i, s; names) m[s] = cast(int) i;
		foreach (s; names) sink += m[s];
	}
}

void aaChurn(uint scale) {
	// insert and remove, as a table that lives across frames
	enum n = 20_000;
	enum rounds = 100;
	auto t = Timer("aa: churn (insert, remove)", cast(ulong) n * rounds * 2 * scale);
	int[int] m;
	foreach (r; 0 .. rounds * scale) {
		foreach (i; 0 .. n) m[r * n + i] = i;
		foreach (i; 0 .. n) m.remove(r * n + i);
	}

	sink += m.length;
}

void main(string[] args) {
	import std.conv : to;
	import std.algorithm : canFind;
	uint scale = args.length > 1 ? args[1].to!uint : 1;

	// A second argument runs only the patterns whose function name contains it
	// (for profiling one pattern).
	string only = args.length > 2 ? args[2] : "";
	static immutable names = [
		"appendFresh", "appendShrinkReuse", "appendShrinkAssume", "appendReserve",
		"appendBig", "concat", "aaInsert", "aaLookup", "aaIterate", "aaSmall",
		"aaString", "aaChurn",
	];
	static immutable void function(uint)[] funs = [
		&appendFresh, &appendShrinkReuse, &appendShrinkAssume, &appendReserve,
		&appendBig, &concat, &aaInsert, &aaLookup, &aaIterate, &aaSmall,
		&aaString, &aaChurn,
	];
	foreach (i, f; funs) {
		if (only.length == 0 || names[i].canFind(only)) f(scale);
	}

	printf("sink=%llu\n", sink);
}
