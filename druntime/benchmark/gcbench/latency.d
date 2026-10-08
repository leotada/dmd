/**
 * Request loop over a large live set, recording every pause the mutator
 * observes. A "pause" here is the wall-clock time of one request minus the
 * work it was meant to do, so it includes both stop-the-world collections and
 * allocation slow paths.
 *
 * The result is a histogram (log2 buckets of microseconds) plus p50/p99/p99.9
 * and the maximum, printed to stderr.
 *
 * Usage: latency [live-set-MiB] [requests]
 *
 * The task spec uses 1-8 GiB; the default is deliberately small so that the
 * benchmark also runs in CI. Pass e.g. `4096` for the real measurement.
 */
import core.time;
import std.algorithm.sorting : sort;
import std.conv;
import std.stdio;

__gshared size_t LIVE_MIB = 256;
__gshared size_t REQUESTS = 200_000;
void* gcSink; // thread-local; see the temporaries in the request loop

final class Entry
{
    Entry next;
    ubyte[] data;
}

void main(string[] args)
{
    if (args.length > 1)
        LIVE_MIB = to!size_t(args[1]);
    if (args.length > 2)
        REQUESTS = to!size_t(args[2]);

    // Build a live set of mixed-size entries, retained through an array so
    // that it is all reachable and has pointers.
    enum entrySize = 512;
    immutable count = LIVE_MIB * 1024 * 1024 / entrySize;
    auto live = new Entry[](count);
    foreach (i, ref e; live)
    {
        e = new Entry;
        e.data = new ubyte[](entrySize - 64);
        if (i)
            e.next = live[i - 1];
    }

    auto samples = new long[](REQUESTS);
    size_t seed = 12345;
    foreach (r; 0 .. REQUESTS)
    {
        immutable t0 = MonoTime.currTime;

        // The "request": allocate a few temporaries and replace a live entry.
        foreach (k; 0 .. 8)
        {
            auto tmp = new ubyte[](128 + k * 64);
            tmp[0] = cast(ubyte) r;
            gcSink = tmp.ptr; // escape, or LDC's GC2Stack moves the "garbage" to the stack
        }
        seed = seed * 6364136223846793005UL + 1442695040888963407UL;
        auto e = new Entry;
        e.data = new ubyte[](entrySize - 64);
        live[(seed >> 33) % count] = e;

        samples[r] = (MonoTime.currTime - t0).total!"usecs";
    }

    // Report.
    auto sorted = samples.dup;
    sorted.sort();
    size_t[64] buckets;
    foreach (s; samples)
    {
        size_t b;
        for (auto v = s; v > 1; v >>= 1)
            ++b;
        ++buckets[b];
    }
    stderr.writefln("latency: live=%s MiB requests=%s", LIVE_MIB, REQUESTS);
    stderr.writefln("  p50=%s us  p99=%s us  p99.9=%s us  max=%s us",
        sorted[REQUESTS / 2], sorted[REQUESTS * 99 / 100],
        sorted[REQUESTS * 999 / 1000], sorted[$ - 1]);
    foreach (b, n; buckets)
        if (n)
            stderr.writefln("  [%6s us, %6s us): %s", b ? 1L << b : 0L, 2L << b, n);
}
