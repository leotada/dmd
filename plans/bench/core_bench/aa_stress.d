// Correctness stress for the associative array: random operations compared with a
// plain model (dense arrays indexed by key id), for several key and value types,
// with pointer stability, rehash, dup, clear, literals, CTFE and collections.
// Usage: aa_stress [rounds=1] [seed=1]     Prints "AA STRESS OK" at the end.
import core.memory : GC;
import core.stdc.stdio : printf;
import core.stdc.stdlib : exit;
import core.internal.newaa : _aaVersion;

struct Rng {
	ulong s;
	uint next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return cast(uint) (s >> 11); }
	uint below(uint n) { return next() % n; }
}

ulong checks;

void fail(string what, int line = __LINE__) {
	printf("AA STRESS FAILED at line %d: %.*s\n", line, cast(int) what.length, what.ptr);
	exit(1);
}

void check(bool ok, string what, int line = __LINE__) {
	checks++;
	if (!ok) fail(what, line);
}

// ------------------------------------------------------------------ key and value types
struct SKey { // a struct key with its own hash and equality: only the id matters
	int id;
	int pad;
	size_t toHash() const nothrow @safe { return id * 0x9E3779B1UL; }
	bool opEquals(const SKey o) const nothrow @safe { return id == o.id; }
}

struct BigV { long a, b, c, d; }

K makeKey(K)(uint id) {
	static if (is(K == int)) return cast(int) (id * 3 + 1);
	else static if (is(K == long)) return cast(long) id << 33;
	else static if (is(K == string)) { import std.conv : to; return "key" ~ to!string(id); }
	else static if (is(K == SKey)) return SKey(cast(int) id, cast(int) (id * 7));
	else static if (is(K == ubyte)) return cast(ubyte) id;
	else static assert(0);
}

V makeVal(V)(uint x) {
	static if (is(V == int)) return cast(int) x;
	else static if (is(V == string)) { import std.conv : to; return "v" ~ to!string(x); }
	else static if (is(V == BigV)) return BigV(x, x + 1, x + 2, x + 3);
	else static if (is(V == int*)) { auto p = new int; *p = cast(int) x; return p; }
	else static assert(0);
}

bool sameVal(V)(V a, V b) {
	static if (is(V == int*)) return *a == *b;
	else return a == b;
}

// ------------------------------------------------------------------ the random test
void runType(K, V)(uint keySpace, uint steps, ulong seed, string name) {
	Rng rng = Rng(seed * 2654435761UL + 12345);
	V[K] aa;
	auto has = new bool[](keySpace);
	auto val = new V[](keySpace);
	uint count = 0;

	struct Held { uint id; V* p; }
	Held[16] held;
	uint nheld;

	foreach (step; 0 .. steps) {
		auto id = rng.below(keySpace);
		auto key = makeKey!K(id);
		switch (rng.below(16)) {
			case 0: .. case 5: { // set
				auto v = makeVal!V(rng.next());
				aa[key] = v;
				if (!has[id]) { has[id] = true; count++; }
				val[id] = v;
				break;
			}
			case 6: .. case 8: { // lookup
				auto p = key in aa;
				check((p !is null) == has[id], name ~ ": in");
				if (p) check(sameVal(*p, val[id]), name ~ ": value");
				break;
			}
			case 9: .. case 11: { // remove
				auto r = aa.remove(key);
				check(r == has[id], name ~ ": remove result");
				if (has[id]) { has[id] = false; count--; }
				// a removed key must not be held any more
				foreach (ref h; held[0 .. nheld]) if (h.id == id) h.p = null;
				break;
			}
			case 12: { // require / update
				auto v = makeVal!V(rng.next());
				if (rng.below(2) == 0) {
					auto p = &aa.require(key, v);
					if (!has[id]) { has[id] = true; count++; val[id] = v; }
					check(sameVal(*p, val[id]), name ~ ": require");
				} else {
					bool created, updated;
					aa.update(key, { created = true; return v; }, (ref V old) { updated = true; });
					check(created == !has[id] && updated == has[id], name ~ ": update");
					if (!has[id]) { has[id] = true; count++; val[id] = v; }
				}
				break;
			}
			case 13: { // hold a pointer to a present value
				if (has[id] && nheld < held.length) {
					held[nheld++] = Held(id, key in aa);
				}
				break;
			}
			case 14: { // check held pointers: entries do not move
				foreach (ref h; held[0 .. nheld]) {
					if (h.p is null) continue;
					check((makeKey!K(h.id) in aa) is h.p, name ~ ": pointer moved");
					check(sameVal(*h.p, val[h.id]), name ~ ": held value");
				}
				break;
			}
			default: { // 15: a heavier operation now and then
				auto r = rng.below(64);
				if (r == 0) {
					aa = aa.rehash();
				} else if (r == 1) {
					auto d = aa.dup;
					check(d.length == aa.length, name ~ ": dup length");
					check(d == aa || is(V == int*), name ~ ": dup equal");
					d[makeKey!K(rng.below(keySpace))] = makeVal!V(1); // independent copy
					check(aa.length == count, name ~ ": dup independent");
				} else if (r == 2) {
					GC.collect();
				} else if (r == 3 && rng.below(8) == 0) {
					aa.clear();
					has[] = false; count = 0; nheld = 0;
				} else if (r < 10) {
					uint seen = 0;
					foreach (k, v; aa) {
						seen++;
					}
					check(seen == count, name ~ ": foreach count");
					check(aa.keys.length == count && aa.values.length == count, name ~ ": keys/values");
					uint seen2 = 0;
					foreach (kv; aa.byKeyValue) {
						seen2++;
					}
					check(seen2 == count, name ~ ": byKeyValue count");
				}
				break;
			}
		}
		if (step % 4096 == 0) check(aa.length == count, name ~ ": length");
	}

	// final: everything matches
	check(aa.length == count, name ~ ": final length");
	foreach (id; 0 .. keySpace) {
		auto p = makeKey!K(id) in aa;
		check((p !is null) == has[id], name ~ ": final in");
		if (p) check(sameVal(*p, val[id]), name ~ ": final value");
	}
}

// ------------------------------------------------------------------ the rest
void literalsAndStatics() {
	int[int] lit = [1: 10, 2: 20, 3: 30, 1: 11];
	check(lit.length == 3 && lit[1] == 11, "literal with duplicate");

	static immutable int[string] sa = ["a": 1, "b": 2, "c": 3];
	check(sa["b"] == 2 && ("z" in sa) is null && sa.length == 3, "static AA");

	enum ct = () {
		int[int] a;
		foreach (i; 0 .. 100) a[i * 3] = i;
		foreach (i; 0 .. 50) a.remove(i * 6);
		int s;
		foreach (k, v; a) s += v;
		return s + cast(int) a.length;
	}();
	int[int] rt;
	foreach (i; 0 .. 100) rt[i * 3] = i;
	foreach (i; 0 .. 50) rt.remove(i * 6);
	int s;
	foreach (k, v; rt) s += v;
	check(ct == s + cast(int) rt.length, "CTFE and run time agree");

	// empty and null AAs
	int[int] n;
	check(n.length == 0 && (1 in n) is null && !n.remove(1), "null AA");
	n[1] = 1;
	check(n.length == 1, "null AA grows");
	int[int] e = null;
	check(e == null && e.keys.length == 0, "null equality");

	// shrinking back: many in, most out, still right
	int[int] sh;
	foreach (i; 0 .. 5000) sh[i] = i;
	foreach (i; 0 .. 4990) sh.remove(i);
	check(sh.length == 10, "shrunk length");
	foreach (i; 4990 .. 5000) check(sh[i] == i, "shrunk values");
	foreach (i; 0 .. 4990) check((i in sh) is null, "shrunk gone");

	// small AAs (inline buckets) up to the size where they grow, with removals
	foreach (n0; 0 .. 40) {
		int[int] sm;
		foreach (i; 0 .. n0) sm[i] = i;
		check(sm.length == n0, "small length");
		foreach (i; 0 .. n0) check(sm[i] == i, "small value");
		foreach (i; 0 .. n0) if (i % 2 == 0) sm.remove(i);
		foreach (i; 0 .. n0) check(((i in sm) !is null) == (i % 2 == 1), "small after remove");
		auto rh = sm.dup.rehash();
		check(rh == sm, "small dup rehash");
	}

	// struct values with a destructor and postblit are not copied behind our back
	static struct Counted {
		static int live;
		int x;
		this(int x) { this.x = x; live++; }
		this(this) { live++; }
		~this() { live--; }
	}
	{
		Counted[int] c;
		foreach (i; 0 .. 100) c[i] = Counted(i);
		foreach (i; 0 .. 100) check(c[i].x == i, "counted values");
		foreach (i; 0 .. 100) c.remove(i);
	}
	GC.collect();
}

void main(string[] args) {
	import std.conv : to;
	auto rounds = args.length > 1 ? args[1].to!uint : 1;
	auto seed = args.length > 2 ? args[2].to!ulong : 1;

	foreach (r; 0 .. rounds) {
		auto sd = seed + r;
		runType!(int, int)(40, 200_000, sd, "int/int tiny");
		runType!(int, int)(700, 400_000, sd, "int/int small");
		runType!(int, int)(60_000, 800_000, sd, "int/int large");
		runType!(long, string)(3000, 300_000, sd, "long/string");
		runType!(string, int)(5000, 300_000, sd, "string/int");
		runType!(string, BigV)(2000, 200_000, sd, "string/BigV");
		runType!(SKey, int)(4000, 300_000, sd, "SKey/int");
		runType!(int, int*)(3000, 200_000, sd, "int/pointer");
		runType!(ubyte, int)(200, 100_000, sd, "ubyte/int");
		literalsAndStatics();
	}

	printf("AA STRESS OK (%llu checks, aaVersion=%d)\n", checks, _aaVersion);
}
