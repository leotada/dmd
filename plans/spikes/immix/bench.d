/**
 * Workloads for the Immix vs segregated-fit comparison (RFC Phase 0.6).
 *
 *   bench <immix|segfit> alloc  [threads] [allocs-per-thread]   (mt_alloc shape, M1)
 *   bench <immix|segfit> frag   [steps] [slots] [sample-every]   (frag_longrun shape, M5/M7)
 *   bench <immix|segfit> trav   [nodes] [traversals]             (traverse_locality shape, locality)
 *   bench <immix|segfit> tree   [depth]                          (tree1 shape, collector throughput)
 *
 * Each prints human-readable lines and one machine-readable line starting with "RESULT".
 * Object layouts mimic the D classes the original benchmarks allocate (16-byte header words
 * included), so sizes and pointer density are comparable.
 */
module bench;

import core.atomic : atomicOp;
import core.stdc.stdio;
import core.stdc.stdlib : calloc, exit, malloc;
import core.stdc.string : memset;
import core.thread;
import core.time;
import perfcount;
import proto;

__gshared Gc gc;

ulong nextRng(ref ulong r) { r = r * 6364136223846793005UL + 1442695040888963407UL; return r >> 33; }

size_t rssKiB()
{
    auto f = fopen("/proc/self/statm", "r");
    if (!f) return 0;
    size_t a, b;
    fscanf(f, "%zu %zu", &a, &b);
    fclose(f);
    return b * 4;
}

size_t peakRssKiB()
{
    auto f = fopen("/proc/self/status", "r");
    if (!f) return 0;
    char[256] line;
    size_t v;
    while (fgets(line.ptr, 256, f))
        if (sscanf(line.ptr, "VmHWM: %zu kB", &v) == 1) break;
    fclose(f);
    return v;
}

ThreadCtx* newCtx()
{
    auto t = cast(ThreadCtx*) calloc(1, ThreadCtx.sizeof);
    gc.registerThread(t);
    return t;
}

void report(string workload, double seconds, double ops, string extra, const(char)* kv = "")
{
    printf("%s %s: %.3f s, %.2f Mops/s, %zu GCs, pause total %.1f ms max %.1f ms (mark %.1f sweep %.1f los %.1f), live %zu KiB, rss %zu KiB peak %zu KiB, meta %zu KiB %s\n",
        gc.name.ptr, workload.ptr, seconds, ops / seconds / 1e6, gc.numGc,
        gc.pauseTotalUs / 1000.0, gc.pauseMaxUs / 1000.0, gc.markUs / 1000.0, gc.sweepUs / 1000.0,
        gc.losUs / 1000.0, gc.liveBytes / 1024, rssKiB(), peakRssKiB(), gc.metaResidentBytes() / 1024, extra.ptr);
    printf("RESULT impl=%s workload=%s seconds=%.4f mops=%.3f gcs=%zu pause_ms=%.2f maxpause_ms=%.2f mark_ms=%.2f sweep_ms=%.2f los_ms=%.2f live_kib=%zu rss_kib=%zu peak_kib=%zu meta_kib=%zu %s\n",
        gc.name.ptr, workload.ptr, seconds, ops / seconds / 1e6, gc.numGc,
        gc.pauseTotalUs / 1000.0, gc.pauseMaxUs / 1000.0, gc.markUs / 1000.0, gc.sweepUs / 1000.0, gc.losUs / 1000.0,
        gc.liveBytes / 1024, rssKiB(), peakRssKiB(), gc.metaResidentBytes() / 1024, kv);
}

// ---------------------------------------------------------------------------- alloc

__gshared size_t allocN = 2_000_000;
shared size_t allocBad;

void allocWorker()
{
    auto t = newCtx();
    enum window = 64;
    auto ring = cast(void**) calloc(window, (void*).sizeof);
    t.roots = ring;
    t.nroots = window;
    foreach (i; 0 .. allocN)
    {
        auto n = cast(size_t*) gc.alloc(16, false);
        // Same shape as gcbench/mt_alloc.d: chains stay short, the live set is the 64-slot ring.
        n[0] = (i & 1) ? cast(size_t) ring[(i + 1) % window] : 0;
        n[1] = i;
        ring[i % window] = n;
        if ((i & 15) == 0)
        {
            auto a = cast(ubyte*) gc.alloc(16 + (i & 0x3F0), true);
            a[0] = cast(ubyte) i;
        }
    }
    // The ring must hold the newest node of every slot, and every chain must be sane:
    // a node's payload identifies its slot, and chains only go back in time.
    foreach (s; 0 .. window)
    {
        auto p = cast(size_t*) ring[s];
        if (!p || p[1] % window != s || p[1] + window < allocN) { atomicOp!"+="(allocBad, 1); continue; }
        size_t prev = p[1];
        for (auto q = cast(size_t*) p[0]; q; q = cast(size_t*) q[0])
        {
            if (q[1] >= prev || q[1] > allocN) { atomicOp!"+="(allocBad, 1); break; }
            prev = q[1];
        }
    }
    t.roots = null;
    gc.unregisterThread(t);
}

void runAlloc(int threads)
{
    auto me = newCtx();
    immutable t0 = MonoTime.currTime;
    Thread[] ts;
    foreach (i; 0 .. threads)
    {
        auto th = new Thread(&allocWorker);
        th.start();
        ts ~= th;
    }
    gc.blocked(true);
    foreach (th; ts) th.join();
    gc.blocked(false);
    immutable secs = (MonoTime.currTime - t0).total!"usecs" / 1e6;
    if (allocBad) { printf("FAILED: %zu corrupted chains\n", cast(size_t) allocBad); exit(1); }
    report("alloc", secs, cast(double) allocN * threads * (1.0 + 1.0 / 16), "");
}

// ---------------------------------------------------------------------------- frag

size_t pickSize(ref ulong rng)
{
    immutable r = nextRng(rng);
    switch (r % 10)
    {
        case 0: .. case 5: return 16 + (r >> 4) % 240;
        case 6: .. case 8: return 256 + (r >> 4) % 3840;
        default:           return 4096 + (r >> 4) % 61440;
    }
}

// maxSize 2032 keeps every object out of the shared large-object space, so the result
// isolates the small-object allocators.
void runFrag(size_t steps, size_t slotCount, size_t every, size_t maxSize = 65535, string label = "frag")
{
    auto t = newCtx();
    auto slots = cast(void**) calloc(slotCount, (void*).sizeof);
    t.roots = slots;
    t.nroots = slotCount;
    ulong rng = 42;
    size_t live;
    size_t[2048] samples;
    size_t nsamples;
    immutable t0 = MonoTime.currTime;
    foreach (step; 0 .. steps)
    {
        immutable i = nextRng(rng) % slotCount;
        if (slots[i]) live -= *cast(size_t*) (cast(ubyte*) slots[i] + 8);
        auto n = pickSize(rng);
        if (n > maxSize) n = 16 + n % (maxSize - 16);
        auto p = cast(ubyte*) gc.alloc(n, true);
        // D's `new ubyte[](n)` writes the whole array, so every page of a large object is resident.
        if (n > MAXSMALL) memset(p, 0, n);
        p[0] = 1;
        *cast(size_t*) (p + 8) = n < 16 ? 0 : n; // size tag, for the live-bytes tally
        slots[i] = p;
        live += n;
        if (step % every == 0 && nsamples < samples.length)
            samples[nsamples++] = rssKiB();
    }
    immutable secs = (MonoTime.currTime - t0).total!"usecs" / 1e6;
    foreach (i; 0 .. slotCount)
        if (slots[i] && (cast(ubyte*) slots[i])[0] != 1) { printf("FAILED: slot %zu corrupted\n", i); exit(1); }
    gc.trigger = 0; gc.madeAvailable = 1; gc.collect();
    // Steady state: mean RSS over the second half of the samples.
    size_t sum, cnt, peak;
    foreach (i; 0 .. nsamples)
    {
        if (samples[i] > peak) peak = samples[i];
        if (i >= nsamples / 2) { sum += samples[i]; cnt++; }
    }
    char[240] kv;
    snprintf(kv.ptr, 240, "steady_rss_kib=%zu sampled_peak_kib=%zu live_payload_kib=%zu blocks_kib=%zu live_units_kib=%zu",
        cnt ? sum / cnt : 0, peak, live / 1024, gc.statBlocks * 32, gc.statLiveUnits * 128 / 1024);
    report(label, secs, steps, "", kv.ptr);
}

// ---------------------------------------------------------------------------- trav

// Layouts: 16 header words, then payload.   Small 40 B, Medium 136 B, Large 440 B, ListNode 56 B.
size_t* newSmall() { return cast(size_t*) gc.alloc(40, false); }

size_t* buildSmall(size_t n)
{
    if (!n) return null;
    auto s = newSmall();
    s[4] = n;
    gc.alloc(136, false);
    if (n % 4 == 0) gc.alloc(440, false);
    auto l = buildSmall(n / 2);
    s[2] = cast(size_t) l;
    auto r = buildSmall(n - n / 2 - 1);
    s[3] = cast(size_t) r;
    return s;
}

size_t sumTree(size_t* s)
{
    return s is null ? 0 : s[4] + sumTree(cast(size_t*) s[2]) + sumTree(cast(size_t*) s[3]);
}

size_t sumList(size_t* n)
{
    size_t t;
    for (; n; n = cast(size_t*) n[2]) t += n[3];
    return t;
}

void runTrav(size_t nodes, size_t traversals)
{
    auto t = newCtx();
    auto roots = cast(void**) calloc(2, (void*).sizeof);
    t.roots = roots;
    t.nroots = 2;
    roots[0] = buildSmall(nodes);
    size_t* head;
    foreach (i; 0 .. nodes)
    {
        auto n = cast(size_t*) gc.alloc(56, false);
        n[3] = i;
        n[2] = cast(size_t) head;
        head = n;
        roots[1] = head;
        if (i % 3 == 0) gc.alloc(200 + i % 600, true);
    }
    gc.trigger = 0; gc.madeAvailable = 1; gc.collect();
    immutable expectedTree = sumTree(cast(size_t*) roots[0]);
    immutable expectedList = sumList(cast(size_t*) roots[1]);
    if (expectedList != nodes * (nodes - 1) / 2) { printf("FAILED: list sum %zu\n", expectedList); exit(1); }

    auto cm = PerfCounter.open(PERF_COUNT_HW_CACHE_MISSES);
    auto ci = PerfCounter.open(PERF_COUNT_HW_INSTRUCTIONS);
    size_t total;
    immutable t0 = MonoTime.currTime;
    cm.start(); ci.start();
    foreach (_; 0 .. traversals)
        total += sumTree(cast(size_t*) roots[0]) + sumList(cast(size_t*) roots[1]);
    immutable misses = cm.stop();
    immutable instr = ci.stop();
    immutable secs = (MonoTime.currTime - t0).total!"usecs" / 1e6;
    if (total != traversals * (expectedTree + expectedList)) { printf("FAILED: traversal mismatch\n"); exit(1); }
    printf("trav: %zu traversals in %.3f s (%.2f ms each), cache-misses %llu (%.0f per traversal), instructions %llu\n",
        traversals, secs, secs * 1000 / traversals, misses, cast(double) misses / traversals, instr);
    char[160] kv;
    snprintf(kv.ptr, 160, "traversal_ms=%.3f cache_misses_per_traversal=%.0f instructions_per_traversal=%.0f",
        secs * 1000 / traversals, cast(double) misses / traversals, cast(double) instr / traversals);
    report("trav", secs, cast(double) traversals * nodes * 2, "", kv.ptr);
}

// ---------------------------------------------------------------------------- tree

size_t* bottomUp(size_t item, size_t depth)
{
    auto n = newSmall();
    n[4] = item;
    if (depth)
    {
        auto l = bottomUp(2 * item - 1, depth - 1);
        n[2] = cast(size_t) l;
        auto r = bottomUp(2 * item, depth - 1);
        n[3] = cast(size_t) r;
    }
    return n;
}

long check(size_t* n)
{
    if (!n[2]) return cast(long) n[4];
    return cast(long) n[4] + check(cast(size_t*) n[2]) - check(cast(size_t*) n[3]);
}

void runTree(size_t n)
{
    auto t = newCtx();
    auto roots = cast(void**) calloc(1, (void*).sizeof);
    t.roots = roots;
    t.nroots = 1;
    enum minDepth = 4;
    immutable maxDepth = minDepth + 2 > n ? minDepth + 2 : n;
    long total = check(bottomUp(0, maxDepth + 1));
    roots[0] = bottomUp(0, maxDepth);
    immutable t0 = MonoTime.currTime;
    size_t nodes;
    for (size_t depth = minDepth; depth <= maxDepth; depth += 2)
    {
        immutable iterations = size_t(1) << (maxDepth - depth + minDepth);
        long c;
        foreach (i; 1 .. iterations + 1)
        {
            c += check(bottomUp(i, depth));
            c += check(bottomUp(-i, depth));
        }
        nodes += iterations * 2 * ((size_t(2) << depth) - 1);
        total += c;
    }
    total += check(cast(size_t*) roots[0]);
    immutable secs = (MonoTime.currTime - t0).total!"usecs" / 1e6;
    printf("tree checksum %lld\n", total);
    report("tree", secs, nodes, "");
}

// ---------------------------------------------------------------------------- main

int main(string[] args)
{
    if (args.length < 3)
    {
        fprintf(stderr, "usage: bench <immix|segfit> <alloc|frag|trav|tree> [params]\n");
        return 2;
    }
    import std.conv : to;
    // "immix-ovf" is Immix with medium objects restricted to overflow blocks (see proto.d).
    if (args[1] == "immix-ovf")
    {
        import core.sys.posix.stdlib : setenv;
        setenv("IMMIX_MEDIUM", "overflow", 1);
        args[1] = "immix";
    }
    gc = args[1] == "immix" ? cast(Gc) new ImmixGc : cast(Gc) new SegfitGc;
    immutable w = args[2];
    size_t arg(size_t i, size_t dflt) { return args.length > i ? to!size_t(args[i]) : dflt; }
    switch (w)
    {
        case "alloc": allocN = arg(4, 2_000_000); runAlloc(cast(int) arg(3, 4)); break;
        case "frag": runFrag(arg(3, 20_000_000), arg(4, 200_000), arg(5, 500_000)); break;
        case "fragsmall": runFrag(arg(3, 40_000_000), arg(4, 400_000), arg(5, 1_000_000), 2032, "fragsmall"); break;
        case "fragtiny": runFrag(arg(3, 80_000_000), arg(4, 1_500_000), arg(5, 2_000_000), 128, "fragtiny"); break;
        case "trav": runTrav(arg(3, 500_000), arg(4, 20)); break;
        case "tree": runTree(arg(3, 16)); break;
        default: fprintf(stderr, "unknown workload\n"); return 2;
    }
    return 0;
}
