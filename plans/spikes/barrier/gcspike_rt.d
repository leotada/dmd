/**
 * Runtime support for the barrier-cost spike (RFC Phase 0, items 0.3 and 0.4).
 *
 * The rewritten LLVM IR (see rewrite_ir.d) reads this thread-local state and
 * the heap block table inline, exactly the loads the RFC section 4.4 fast path
 * needs. The slow paths do nothing but count (cheap, thread-local) so the cost
 * of the fast path is isolated.
 *
 * Environment (read at startup):
 *   GCSPIKE_MARKING=1   pretend a cycle is running: every store takes the slow path
 *   GCSPIKE_MINE=0|1    block table says stored values are (1) / are not (0) in my
 *                       local domain. 1 is the common Track B case (local object
 *                       stored into a local object) and exercises both lookups.
 */
module gcspike_rt;

import core.stdc.stdlib : getenv;
import core.sys.posix.pthread;
import core.sys.posix.sys.mman;

extern (C):

struct GcSpikeTS
{
    ubyte marking;   // a global cycle is running
    ubyte scanned;   // my stack was scanned (hybrid barrier)
    ubyte localOn;   // local domains on (Track B)
    ubyte pad0;
    ushort me;       // owner code of my domain
    ushort pad1;
    size_t stackLo;  // my stack, for the stack-visibility compare
    size_t stackSize;
    size_t arenaLo;  // my arena, for the arena variant (contiguous per-thread range)
    size_t arenaSize;
}

struct GcSpikeHeap
{
    size_t base;     // heap range covered by the block table
    size_t size;
    ushort* table;   // owner code per 32 KiB block
}

GcSpikeTS gcts;            // thread-local (default storage for module variables)
__gshared GcSpikeHeap gcheap;

// Counters, thread-local so counting adds no contention.
size_t cntStoreSlow, cntPublishSlow, cntStackEscaped;

pragma(inline, false) void _d_gc_store_slow(void* slot, void* v) nothrow @nogc { ++cntStoreSlow; }
pragma(inline, false) void _d_gc_publish_slow(void* slot, void* v) nothrow @nogc { ++cntPublishSlow; }
pragma(inline, false) void _d_gc_stack_escaped() nothrow @nogc { ++cntStackEscaped; }

__gshared bool envMarking, envMine;

// Linux values; not exposed by this druntime's mman bindings.
enum MAP_ANONYMOUS_ = 0x20;
enum MAP_NORESERVE_ = 0x4000;
int pthread_getattr_np(pthread_t thread, pthread_attr_t* attr);

extern (D):

shared static this()
{
    envMarking = getenv("GCSPIKE_MARKING") !is null && getenv("GCSPIKE_MARKING")[0] == '1';
    envMine = getenv("GCSPIKE_MINE") !is null && getenv("GCSPIKE_MINE")[0] == '1';

    // Cover the user address space with a lazily-backed block table: 2^47 bytes
    // in 32 KiB blocks is 2^32 entries of 2 bytes. Untouched pages read as zero.
    enum size_t span = size_t(1) << 47;
    enum size_t entries = span >> 15;
    auto p = mmap(null, entries * 2, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS_ | MAP_NORESERVE_, -1, 0);
    if (p is MAP_FAILED)
        return;
    gcheap = GcSpikeHeap(0, span, cast(ushort*) p);
}

static this()
{
    // Per-thread: stack bounds and owner state.
    pthread_attr_t attr;
    if (pthread_getattr_np(pthread_self(), &attr) == 0)
    {
        void* addr;
        size_t size;
        pthread_attr_getstack(&attr, &addr, &size);
        gcts.stackLo = cast(size_t) addr;
        gcts.stackSize = size;
        pthread_attr_destroy(&attr);
    }
    gcts.marking = envMarking;
    // Table content is 0 everywhere. "Mine" means my code equals the table value.
    gcts.localOn = 1;
    gcts.me = envMine ? 0 : 2;
    // Arena variant: "mine" covers all user space, "not mine" covers nothing.
    gcts.arenaLo = 0;
    gcts.arenaSize = envMine ? (size_t(1) << 47) : 0;
}

// Print the counters at exit so a run shows how often the slow paths fired.
static ~this()
{
    import core.stdc.stdio : fprintf, stderr;
    if (cntStoreSlow || cntPublishSlow || cntStackEscaped)
        fprintf(stderr, "gcspike: store_slow=%zu publish_slow=%zu stack_escaped=%zu\n",
                cntStoreSlow, cntPublishSlow, cntStackEscaped);
}
