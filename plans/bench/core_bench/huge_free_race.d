// Frees of extents that share a block, from two threads: a huge extent (larger than a block) leaves
// its last block partly free, other large extents are allocated in it, and the huge one is freed while
// another thread frees one of those. Before the fix in PageFiller.freePagesImpl (the block was out of
// every heap while the lock was dropped for the region), the second free unlinked a node that was
// not linked and left a cycle in the block heap: the process hung. Prints "HUGE FREE RACE OK".
import core.atomic;
import core.memory : GC;
import core.thread;
import core.stdc.stdio : printf;
import core.time;

shared bool stop;
shared size_t ops;
uint rng(uint s) { return s * 1664525 + 1013904223; }

void hugeThread(uint id)
{
    uint seed = id * 131 + 5;
    while (!atomicLoad(stop))
    {
        seed = rng(seed);
        auto size = 2_200_000 + (seed >> 9) % 6_000_000;      // 2.2 .. 8.2 MB: spans blocks
        auto p = cast(ubyte*) GC.malloc(size, GC.BlkAttr.NO_SCAN);
        p[0] = 1;
        GC.free(p);
        atomicOp!"+="(ops, 1);
    }
}

void midThread(uint id)
{
    uint seed = id * 977 + 3;
    void*[16] held;
    size_t k;
    while (!atomicLoad(stop))
    {
        seed = rng(seed);
        auto size = 40_000 + (seed >> 9) % 900_000;           // large extents that fit in a block tail
        auto p = GC.malloc(size, GC.BlkAttr.NO_SCAN);
        auto slot = k++ % held.length;
        if (held[slot]) GC.free(held[slot]);
        held[slot] = p;
        atomicOp!"+="(ops, 1);
    }
    foreach (p; held) if (p) GC.free(p);
}

int main(string[] args)
{
    Thread[] ts;
    foreach (i; 0 .. 2) { auto t = new Thread({ hugeThread(i); }); t.start(); ts ~= t; }
    foreach (i; 0 .. 2) { auto t = new Thread({ midThread(i); }); t.start(); ts ~= t; }
    Thread.sleep(dur!"seconds"(args.length > 1 ? 30 : 20));
    atomicStore(stop, true);
    foreach (t; ts) t.join();
    printf("HUGE FREE RACE OK ops=%zu\n", cast(size_t) atomicLoad(ops));
    return 0;
}
