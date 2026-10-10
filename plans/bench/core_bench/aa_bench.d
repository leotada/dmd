// Associative arrays, the cases that natural game code produces.
// Usage: aa_bench [scale=1] [only]    best of 3 repetitions, ns per operation
// Prints which newaa.d was compiled in (`_aaMarker` exists only in the modified one).
import core.time : MonoTime;
import core.stdc.stdio : printf;
import core.internal.newaa : _aaVersion;

__gshared ulong sink;

static if (__traits(compiles, { import core.internal.newaa : _aaMarker; auto x = _aaMarker; }))
	enum haveMarker = true;
else
	enum haveMarker = false;

struct Stat {
	string name;
	double best = double.max;
	ulong ops;
}

Stat[] stats;
string only;

void bench(string name, ulong ops, scope void delegate() body_) {
	import std.algorithm : canFind;
	if (only.length && !name.canFind(only)) return;
	double best = double.max;
	foreach (rep; 0 .. 3) {
		auto t0 = MonoTime.currTime;
		body_();
		auto ns = (MonoTime.currTime - t0).total!"nsecs";
		auto per = double(ns) / ops;
		if (per < best) best = per;
	}
	printf("%-40s %8.1f ns/op  (%llu ops)\n", name.ptr, best, ops);
}

struct V3 { long a, b, c; }

struct Rng {
	ulong s = 88172645463325252UL;
	uint next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return cast(uint) (s >> 11); }
}

void main(string[] args) {
	import std.conv : to;
	uint scale = args.length > 1 ? args[1].to!uint : 1;
	only = args.length > 2 ? args[2] : "";
	static if (haveMarker) printf("newaa: modified (marker)\n"); else printf("newaa: original\n");

	enum N = 100_000;

	bench("insert 100k int->int (fresh map)", N * scale, {
		foreach (r; 0 .. scale) {
			int[int] m;
			foreach (i; 0 .. N) m[i * 7] = i;
			sink += m.length;
		}
	});

	{
		int[int] big;
		foreach (i; 0 .. N) big[i * 7] = i;
		bench("lookup hit int", N * 20 * scale, {
			foreach (r; 0 .. 20 * scale)
				foreach (i; 0 .. N) sink += big[i * 7];
		});
		bench("lookup miss int (in)", N * 20 * scale, {
			foreach (r; 0 .. 20 * scale)
				foreach (i; 0 .. N) sink += (i * 7 + 1) in big ? 1 : 0;
		});
		bench("update existing (m[k] += 1)", N * 20 * scale, {
			foreach (r; 0 .. 20 * scale)
				foreach (i; 0 .. N) big[i * 7] += 1;
		});
		bench("iterate foreach k,v", N * 20 * scale, {
			foreach (r; 0 .. 20 * scale)
				foreach (k, v; big) sink += v;
		});
		bench("iterate .byValue", N * 20 * scale, {
			foreach (r; 0 .. 20 * scale)
				foreach (v; big.byValue) sink += v;
		});
		bench(".keys + .values", N * 4 * scale, {
			foreach (r; 0 .. 2 * scale) {
				sink += big.keys.length;
				sink += big.values.length;
			}
		});
	}

	bench("small maps of 2 (create+fill)", 100_000UL * 2 * scale, {
		foreach (r; 0 .. scale)
			foreach (a; 0 .. 100_000) {
				int[int] m;
				m[1] = 1; m[2] = 2;
				sink += m.length;
			}
	});

	bench("small maps of 8 (create+fill)", 50_000UL * 8 * scale, {
		foreach (r; 0 .. scale)
			foreach (a; 0 .. 50_000) {
				int[int] m;
				foreach (i; 0 .. 8) m[i] = i;
				sink += m.length;
			}
	});

	bench("small maps of 32 (create+fill)", 20_000UL * 32 * scale, {
		foreach (r; 0 .. scale)
			foreach (a; 0 .. 20_000) {
				int[int] m;
				foreach (i; 0 .. 32) m[i] = i;
				sink += m.length;
			}
	});

	bench("struct value (24 B), insert+lookup", N * 2 * scale, {
		foreach (r; 0 .. scale) {
			V3[int] m;
			foreach (i; 0 .. N) m[i] = V3(i, i, i);
			foreach (i; 0 .. N) sink += m[i].a;
		}
	});

	{
		string[] names;
		foreach (i; 0 .. 50_000) {
			import std.conv : to;
			names ~= "citizen" ~ i.to!string;
		}
		bench("string keys: insert + lookup", 50_000UL * 2 * scale, {
			foreach (r; 0 .. scale) {
				int[string] m;
				foreach (i, s; names) m[s] = cast(int) i;
				foreach (s; names) sink += m[s];
			}
		});
	}

	bench("churn sequential (insert, remove)", 20_000UL * 100 * 2 * scale, {
		int[int] m;
		foreach (r; 0 .. 100 * scale) {
			foreach (i; 0 .. 20_000) m[r * 20_000 + i] = i;
			foreach (i; 0 .. 20_000) m.remove(r * 20_000 + i);
		}
		sink += m.length;
	});

	// a table that lives across frames: about 32k entries come and go
	bench("churn random 64k keys (insert, remove)", 1_000_000UL * 2 * scale, {
		int[int] m;
		Rng rng;
		foreach (i; 0 .. 32768) m[rng.next() & 0xFFFF] = i;
		foreach (i; 0 .. 1_000_000UL * scale) {
			m[rng.next() & 0xFFFF] = cast(int) i;
			m.remove(rng.next() & 0xFFFF);
		}
		sink += m.length;
	});

	bench("grow to 1M int keys", 1_000_000UL * scale, {
		foreach (r; 0 .. scale) {
			int[int] m;
			foreach (i; 0 .. 1_000_000) m[i] = i;
			sink += m.length;
		}
	});

	bench("clear + refill 10k", 10_000UL * 100 * scale, {
		int[int] m;
		foreach (i; 0 .. 10_000) m[i] = i;
		foreach (r; 0 .. 100 * scale) {
			m.clear();
			foreach (i; 0 .. 10_000) m[i] = i;
		}
		sink += m.length;
	});

	printf("sink=%llu aaVersion=%d\n", sink, _aaVersion);
}
