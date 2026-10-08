/**
 * `latency` plus many suspended fibers with 16-64 KiB stacks (the vibe.d
 * shape). Every fiber stack is a root, so this measures how pause time scales
 * with fiber count (ADR-9, metric M3).
 *
 * Usage: fiber_latency [fibers] [requests] [live-set-MiB]
 */
import core.thread;
import core.time;
import std.algorithm.sorting : sort;
import std.conv;
import std.stdio;

__gshared size_t FIBERS = 10_000;
__gshared size_t REQUESTS = 100_000;
__gshared size_t LIVE_MIB = 64;
void* gcSink; // thread-local; keeps the request-loop garbage from being optimized away

final class Entry
{
    ubyte[] data;
}

void main(string[] args)
{
    if (args.length > 1)
        FIBERS = to!size_t(args[1]);
    if (args.length > 2)
        REQUESTS = to!size_t(args[2]);
    if (args.length > 3)
        LIVE_MIB = to!size_t(args[3]);

    // Suspended fibers, each holding a heap pointer on its stack.
    auto fibers = new Fiber[](FIBERS);
    foreach (i, ref f; fibers)
    {
        immutable stack = (16 + (i % 4) * 16) * 1024; // 16, 32, 48, 64 KiB
        f = new Fiber({
            auto mine = new ubyte[](64);
            mine[0] = 1;
            Fiber.yield();
            mine[1] = 2;
        }, stack);
        f.call(); // runs to the first yield and stays suspended
    }

    immutable count = LIVE_MIB * 1024 * 1024 / 512;
    auto live = new Entry[](count);
    foreach (ref e; live)
    {
        e = new Entry;
        e.data = new ubyte[](448);
    }

    auto samples = new long[](REQUESTS);
    size_t seed = 1;
    foreach (r; 0 .. REQUESTS)
    {
        immutable t0 = MonoTime.currTime;
        foreach (k; 0 .. 8)
            gcSink = (new ubyte[](128 + k * 64)).ptr; // escape, or LDC's GC2Stack removes it
        seed = seed * 6364136223846793005UL + 1442695040888963407UL;
        auto e = new Entry;
        e.data = new ubyte[](448);
        live[(seed >> 33) % count] = e;
        // Wake one fiber now and then so stacks change while marking.
        if ((r & 255) == 0 && fibers[r % FIBERS].state == Fiber.State.HOLD)
            fibers[r % FIBERS].call();
        samples[r] = (MonoTime.currTime - t0).total!"usecs";
    }

    auto sorted = samples.dup;
    sorted.sort();
    stderr.writefln("fiber_latency: fibers=%s live=%s MiB requests=%s", FIBERS, LIVE_MIB, REQUESTS);
    stderr.writefln("  p50=%s us  p99=%s us  p99.9=%s us  max=%s us",
        sorted[REQUESTS / 2], sorted[REQUESTS * 99 / 100],
        sorted[REQUESTS * 999 / 1000], sorted[$ - 1]);
}
