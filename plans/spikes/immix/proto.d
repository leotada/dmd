/**
 * Out-of-tree allocator comparison for RFC Phase 0.6 (ADR-2, gate G0c).
 *
 * Two small-object allocators under one stop-the-world mark-sweep collector, so that
 * allocation speed, fragmentation, locality and metadata cost can be compared on equal terms:
 *
 *   ImmixGc    32 KiB blocks of 128-byte lines. Per-thread bump allocation into runs of free
 *              lines ("holes"), an overflow block for medium objects, blocks recycled by free
 *              line count after each collection. Metadata: one size byte per 16-byte granule
 *              (also marks object starts and the no-scan flag), one mark bit per granule,
 *              line mark and line live bytes.
 *   SegfitGc   32 KiB slabs, one size class per slab (24 classes up to 2032 bytes), per-thread
 *              slab cache, free slots found in an allocation bitmap. This is the structure of
 *              the SDC collector that symgc ports, written independently; symgc itself was
 *              not available. Metadata: allocation, mark and no-scan bitmaps per slab.
 *
 * Shared by both: the 16 GiB address reservation, free-block pool and decommit policy, the
 * large-object space (objects above 2032 bytes, 4 KiB pages), conservative scanning of thread
 * stacks, registers and registered root arrays, the collection trigger, and stop-the-world
 * rendezvous at allocation slow paths. Memory is zeroed on allocation. Interior pointers
 * keep objects alive. Nothing here uses the D garbage collector for its own data.
 *
 * Deliberately not done: parallel marking, lazy sweeping, finalizers, precise scanning,
 * weak references, growth heuristics beyond "collect after allocating max(8 MiB, live)".
 */
module proto;

import core.atomic;
import core.stdc.stdio;
import core.stdc.stdlib : abort, free, malloc, realloc;
import core.stdc.string : memset;
import core.sys.posix.pthread;
import core.sys.posix.sched : sched_yield;
import core.sys.posix.sys.mman;
import core.time;

// Linux values missing from this druntime's bindings.
enum MAP_ANON_ = 0x20;
enum MAP_NORESERVE_ = 0x4000;
enum MADV_DONTNEED_ = 4;
extern (C) nothrow @nogc
{
    int pthread_getattr_np(pthread_t, pthread_attr_t*);
    int madvise(void*, size_t, int);
    int mincore(void*, size_t, ubyte*);
    void gcproto_save_regs(void** out_);
}

enum size_t BLOCK = 32 * 1024;
enum size_t LINE = 128;
enum size_t LINES = BLOCK / LINE;       // 256
enum size_t GRAN = 16;
enum size_t GRANS_PER_BLOCK = BLOCK / GRAN; // 2048
enum size_t MAXSMALL = 2032;            // 127 granules; larger objects go to the large-object space
enum size_t PAGE = 4096;
enum size_t RESERVE = size_t(16) << 30;
enum size_t NBLOCKS = RESERVE / BLOCK;  // 512 Ki
enum uint NONE = uint.max;

void* reserve(size_t bytes) nothrow @nogc
{
    auto p = mmap(null, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON_ | MAP_NORESERVE_, -1, 0);
    if (p is MAP_FAILED)
    {
        fprintf(stderr, "mmap of %zu bytes failed\n", bytes);
        abort();
    }
    return p;
}

void decommit(void* p, size_t bytes) nothrow @nogc
{
    madvise(p, bytes, MADV_DONTNEED_);
}

struct SpinLock
{
    shared int v;
    void lock() nothrow @nogc
    {
        int spins;
        while (!cas(&v, 0, 1))
            if (++spins > 100) { sched_yield(); spins = 0; }
    }
    void unlock() nothrow @nogc { atomicStore!(MemoryOrder.rel)(v, 0); }
}

/// Growable array of POD in malloc memory.
struct Vec(T)
{
    T* ptr;
    size_t len, cap;
    void push(T x) nothrow @nogc
    {
        if (len == cap)
        {
            cap = cap ? cap * 2 : 1024;
            ptr = cast(T*) realloc(ptr, cap * T.sizeof);
        }
        ptr[len++] = x;
    }
    T pop() nothrow @nogc { return ptr[--len]; }
}

/// Per-thread allocator and collector state.
struct ThreadCtx
{
    ThreadCtx* next;
    shared int state;           // 0 running, 1 parked/blocked, 2 gone
    ubyte* stackHi;
    void* sp;                   // lowest stack address to scan while parked
    void*[8] savedRegs;         // callee-saved registers captured when parking
    void* pending;              // object being handed out across a possible collection
    void** roots;               // optional precise-slot array, scanned conservatively
    size_t nroots;
    size_t allocated;           // bytes made available since last flush
    // Immix
    ubyte* cur, lim;
    uint blk;
    uint lineCur;
    ubyte* ocur, olim;
    // Segfit
    uint[24] slab;
    uint[24] cursor;
}

ThreadCtx* tc; // thread-local

/// Result of looking up a word that may point into the heap.
struct Hit
{
    ubyte* start;
    size_t size;
    bool noscan;
    bool fresh;     // newly marked by this lookup
}

abstract class Gc
{
    // ---- address space shared by both allocators
    ubyte* base;                // small-object blocks
    shared size_t highWater;    // blocks handed out so far (bump)
    uint* freePool;             // stack of free block indices
    size_t freeCount;
    ubyte* blockZero;           // 1 = block memory is known zero
    SpinLock poolLock;

    // ---- large-object space
    ubyte* losBase;
    ubyte* losUsed;             // per page
    uint* losHead;              // per page: head page + 1 (0 = free)
    uint* losPages;             // per head page: length in pages
    ubyte* losMark;             // per head page
    ubyte* losNoscan;           // per head page
    size_t losCursor;
    size_t losLive, losHigh;
    SpinLock losLock;

    // ---- threads and rendezvous
    ThreadCtx* threads;
    SpinLock threadLock;
    pthread_mutex_t gcMutex;
    shared int stopFlag;
    shared size_t epoch;

    // ---- trigger and statistics
    shared size_t madeAvailable;
    size_t trigger = 8 << 20;
    size_t liveBytes;
    size_t numGc;
    ulong pauseTotalUs, pauseMaxUs;
    ulong markUs, sweepUs, losUs;   // mark, small-object sweep, large-object sweep
    size_t statBlocks, statLiveUnits;   // after the last sweep: blocks holding data; live lines (Immix) or live slabs' slots
    Vec!(size_t) markStack;     // pairs: ptr, size

    this()
    {
        base = cast(ubyte*) reserve(RESERVE);
        freePool = cast(uint*) reserve(NBLOCKS * uint.sizeof);
        blockZero = cast(ubyte*) reserve(NBLOCKS);
        losBase = cast(ubyte*) reserve(RESERVE);
        immutable pages = RESERVE / PAGE;
        losUsed = cast(ubyte*) reserve(pages);
        losHead = cast(uint*) reserve(pages * 4);
        losPages = cast(uint*) reserve(pages * 4);
        losMark = cast(ubyte*) reserve(pages);
        losNoscan = cast(ubyte*) reserve(pages);
        pthread_mutex_init(&gcMutex, null);
    }

    abstract string name();
    abstract void initThread(ThreadCtx* t);
    abstract void* allocSmall(size_t granules, bool noscan);
    abstract bool lookupSmall(size_t addr, ref Hit h, bool mark);
    abstract void retireThread(ThreadCtx* t);
    abstract size_t sweepSmall();           // returns live bytes
    abstract size_t metaResidentBytes();

    // ------------------------------------------------------------------ threads
    final void registerThread(ThreadCtx* t)
    {
        pthread_attr_t attr;
        pthread_getattr_np(pthread_self(), &attr);
        void* addr;
        size_t size;
        pthread_attr_getstack(&attr, &addr, &size);
        pthread_attr_destroy(&attr);
        t.stackHi = cast(ubyte*) addr + size;
        initThread(t);
        // A new thread must not appear while the world is stopped.
        pthread_mutex_lock(&gcMutex);
        t.state = 0;
        threadLock.lock();
        t.next = threads;
        threads = t;
        threadLock.unlock();
        pthread_mutex_unlock(&gcMutex);
        tc = t;
    }

    final void unregisterThread(ThreadCtx* t)
    {
        flushAllocated(t);
        atomicStore(t.state, 2);
    }

    /// Save registers and the stack pointer so a collector on another thread can scan this stack.
    pragma(inline, false) final void parkSelf(ThreadCtx* t)
    {
        void* here;
        gcproto_save_regs(t.savedRegs.ptr);
        t.sp = &here;
        atomicStore!(MemoryOrder.rel)(t.state, 1);
        while (atomicLoad!(MemoryOrder.acq)(stopFlag))
            sched_yield();
        atomicStore!(MemoryOrder.rel)(t.state, 0);
    }

    /// Mark the current thread as blocked in a call that cannot allocate (join, sleep).
    pragma(inline, false) final void blocked(bool on)
    {
        auto t = tc;
        if (on)
        {
            void* here;
            gcproto_save_regs(t.savedRegs.ptr);
            t.sp = &here;
            atomicStore!(MemoryOrder.rel)(t.state, 1);
        }
        else
        {
            while (true)
            {
                atomicStore!(MemoryOrder.rel)(t.state, 0);
                if (!atomicLoad!(MemoryOrder.acq)(stopFlag))
                    break;
                atomicStore!(MemoryOrder.rel)(t.state, 1);
                while (atomicLoad!(MemoryOrder.acq)(stopFlag))
                    sched_yield();
            }
        }
    }

    final void pollOrPark()
    {
        if (atomicLoad!(MemoryOrder.acq)(stopFlag))
            parkSelf(tc);
    }

    final void flushAllocated(ThreadCtx* t)
    {
        if (t.allocated)
        {
            atomicOp!"+="(madeAvailable, t.allocated);
            t.allocated = 0;
        }
    }

    /// Called at allocation slow paths with the thread's counters.
    final void account(ThreadCtx* t, size_t bytes)
    {
        t.allocated += bytes;
        if (t.allocated >= 64 * 1024)
            flushAllocated(t);
        pollOrPark();
        if (atomicLoad(madeAvailable) >= trigger)
            collect();
    }

    // ------------------------------------------------------------------ block pool
    final uint getBlock(out bool zero)
    {
        poolLock.lock();
        scope (exit) poolLock.unlock();
        if (freeCount)
        {
            auto b = freePool[--freeCount];
            zero = blockZero[b] != 0;
            return b;
        }
        auto b = cast(uint) highWater;
        if (b >= NBLOCKS)
        {
            fprintf(stderr, "heap reservation exhausted\n");
            abort();
        }
        highWater = b + 1;
        zero = true;
        return b;
    }

    final void putBlock(uint b, bool zero)
    {
        blockZero[b] = zero;
        freePool[freeCount++] = b;
    }

    // ------------------------------------------------------------------ large objects
    final void* allocLarge(size_t bytes, bool noscan)
    {
        immutable n = (bytes + PAGE - 1) / PAGE;
        // Account first: a collection here must not see a half-handed-out object.
        account(tc, n * PAGE);
        losLock.lock();
        immutable total = RESERVE / PAGE;
        size_t start = size_t.max;
        // next-fit from the cursor, wrapping once
        foreach (pass; 0 .. 2)
        {
            size_t i = pass == 0 ? losCursor : 0;
            immutable end = pass == 0 ? total : losCursor + n;
            size_t run;
            for (; i < end && i < total; i++)
            {
                if (losUsed[i]) { run = 0; continue; }
                if (++run == n) { start = i + 1 - n; break; }
            }
            if (start != size_t.max) break;
        }
        if (start == size_t.max)
        {
            fprintf(stderr, "large-object space exhausted\n");
            abort();
        }
        foreach (i; start .. start + n)
        {
            losUsed[i] = 1;
            losHead[i] = cast(uint) start + 1;
        }
        losPages[start] = cast(uint) n;
        losNoscan[start] = noscan;
        losCursor = start + n;
        if (losCursor > losHigh) losHigh = losCursor;
        losLive += n * PAGE;
        losLock.unlock();
        // Pages come from the OS zeroed or from a decommitted run, so no memset is needed.
        return losBase + start * PAGE;
    }

    final bool lookupLarge(size_t addr, ref Hit h, bool mark)
    {
        immutable off = addr - cast(size_t) losBase;
        immutable page = off / PAGE;
        immutable head = losHead[page];
        if (!head)
            return false;
        immutable hp = head - 1;
        h.start = losBase + hp * PAGE;
        h.size = losPages[hp] * PAGE;
        h.noscan = losNoscan[hp] != 0;
        h.fresh = false;
        if (mark && !losMark[hp])
        {
            losMark[hp] = 1;
            h.fresh = true;
        }
        return true;
    }

    final size_t sweepLarge()
    {
        size_t live;
        size_t i;
        while (i < losHigh)
        {
            if (!losUsed[i]) { i++; continue; }
            immutable head = losHead[i] - 1;
            immutable n = losPages[head];
            if (losMark[head])
            {
                losMark[head] = 0;
                live += n * PAGE;
            }
            else
            {
                foreach (k; head .. head + n)
                {
                    losUsed[k] = 0;
                    losHead[k] = 0;
                }
                decommit(losBase + head * PAGE, n * PAGE);
            }
            i = head + n;
        }
        losLive = live;
        losCursor = 0;
        return live;
    }

    // ------------------------------------------------------------------ allocation entry
    final void* alloc(size_t n, bool noscan)
    {
        if (n == 0) n = 1;
        if (n > MAXSMALL)
            return allocLarge(n, noscan);
        return allocSmall((n + GRAN - 1) / GRAN, noscan);
    }

    // ------------------------------------------------------------------ collection
    final bool lookup(size_t addr, ref Hit h, bool mark)
    {
        immutable lo = cast(size_t) base;
        if (addr - lo < highWater * BLOCK)
            return lookupSmall(addr, h, mark);
        immutable llo = cast(size_t) losBase;
        if (addr - llo < losHigh * PAGE)
            return lookupLarge(addr, h, mark);
        return false;
    }

    final void scanRange(size_t* lo, size_t* hi)
    {
        Hit h;
        for (auto p = lo; p < hi; p++)
        {
            immutable w = *p;
            if (lookup(w, h, true) && h.fresh && !h.noscan)
            {
                markStack.push(cast(size_t) h.start);
                markStack.push(h.size);
            }
        }
    }

    final void drain()
    {
        while (markStack.len)
        {
            immutable size = markStack.pop();
            immutable start = markStack.pop();
            scanRange(cast(size_t*) start, cast(size_t*) (start + size));
        }
    }

    final void collect()
    {
        // Another thread may be collecting: keep polling so it can stop us.
        while (pthread_mutex_trylock(&gcMutex) != 0)
            pollOrPark();
        if (atomicLoad(madeAvailable) < trigger)
        {
            pthread_mutex_unlock(&gcMutex);
            return;
        }
        immutable t0 = MonoTime.currTime;
        // Stop the world: every other registered thread must park, block or exit.
        atomicStore!(MemoryOrder.rel)(stopFlag, 1);
        auto me = tc;
        void* here;
        gcproto_save_regs(me.savedRegs.ptr);
        me.sp = &here;
        for (auto t = threads; t; t = t.next)
        {
            if (t is me) continue;
            int spins;
            while (atomicLoad!(MemoryOrder.acq)(t.state) == 0)
                if (++spins > 100) { sched_yield(); spins = 0; }
        }
        // Mutators are stopped. Retire thread-local allocation state.
        for (auto t = threads; t; t = t.next)
        {
            flushAllocated(t);
            retireThread(t);
        }
        immutable tMark = MonoTime.currTime;
        for (auto t = threads; t; t = t.next)
        {
            if (atomicLoad(t.state) == 2) continue;
            scanRange(cast(size_t*) ((cast(size_t) t.sp) & ~7), cast(size_t*) t.stackHi);
            scanRange(cast(size_t*) t.savedRegs.ptr, cast(size_t*) (t.savedRegs.ptr + 8));
            if (t.roots)
                scanRange(cast(size_t*) t.roots, cast(size_t*) (t.roots + t.nroots));
            drain();
        }
        immutable tSweep = MonoTime.currTime;
        immutable liveSmall = sweepSmall();
        immutable tLos = MonoTime.currTime;
        immutable liveLarge = sweepLarge();
        liveBytes = liveSmall + liveLarge;
        immutable tEnd = MonoTime.currTime;
        losUs += (tEnd - tLos).total!"usecs";

        atomicStore(madeAvailable, cast(size_t) 0);
        trigger = liveBytes > (8 << 20) ? liveBytes : (8 << 20);
        numGc++;
        immutable pause = (tEnd - t0).total!"usecs";
        pauseTotalUs += pause;
        if (pause > pauseMaxUs) pauseMaxUs = pause;
        markUs += (tSweep - tMark).total!"usecs";
        sweepUs += (tLos - tSweep).total!"usecs";
        atomicStore!(MemoryOrder.rel)(stopFlag, 0);
        pthread_mutex_unlock(&gcMutex);
    }

    final size_t committedSmallBlocks() { return highWater - freeCount; }
}

// =====================================================================================
// Immix
// =====================================================================================

final class ImmixGc : Gc
{
    ubyte* sz;          // per granule: granules | 0x80 if no-scan, 0 = no object starts here
    ubyte* markBits;    // per granule bit
    ubyte* lineMark;    // per line, transient
    ubyte* lineLive;    // per line, persistent after each sweep
    ubyte* blockUsed;   // per block: 1 = holds Immix data
    Vec!uint recyclable;
    SpinLock recLock;
    /// IMMIX_MEDIUM=overflow: objects above one line always go to overflow blocks, never into
    /// holes. The Immix paper tries the hole first (the default here); this variant is kept to
    /// show how much the locality and fragmentation results depend on that policy.
    bool mediumOverflowOnly;

    this()
    {
        super();
        import core.stdc.stdlib : getenv;
        import core.stdc.string : strcmp;
        auto e = getenv("IMMIX_MEDIUM");
        mediumOverflowOnly = e !is null && strcmp(e, "overflow") == 0;
        sz = cast(ubyte*) reserve(RESERVE / GRAN);
        markBits = cast(ubyte*) reserve(RESERVE / GRAN / 8);
        lineMark = cast(ubyte*) reserve(RESERVE / LINE);
        lineLive = cast(ubyte*) reserve(RESERVE / LINE);
        blockUsed = cast(ubyte*) reserve(NBLOCKS);
    }

    override string name() { return mediumOverflowOnly ? "immix-ovf" : "immix"; }
    override void initThread(ThreadCtx* t) { t.blk = NONE; }

    override void retireThread(ThreadCtx* t)
    {
        t.cur = t.lim = null;
        t.ocur = t.olim = null;
        t.blk = NONE;
    }

    private ubyte* blockAddr(uint b) { return base + cast(size_t) b * BLOCK; }

    /// Next hole in the thread's current block, or a new block.
    private bool nextHole(ThreadCtx* t, size_t needLines)
    {
        while (true)
        {
            if (t.blk != NONE)
            {
                auto ll = lineLive + cast(size_t) t.blk * LINES;
                uint i = t.lineCur;
                while (i < LINES && ll[i]) i++;
                if (i < LINES)
                {
                    uint j = i;
                    while (j < LINES && !ll[j]) j++;
                    auto start = blockAddr(t.blk) + i * LINE;
                    auto end = blockAddr(t.blk) + j * LINE;
                    if (!blockZero[t.blk])
                        memset(start, 0, end - start);
                    t.cur = start;
                    t.lim = end;
                    t.lineCur = j;
                    account(t, end - start);
                    return true;
                }
            }
            // Current block exhausted: take a recyclable block, else a free one.
            uint b = NONE;
            bool zero;
            recLock.lock();
            if (recyclable.len)
                b = recyclable.pop();
            recLock.unlock();
            if (b == NONE)
                b = getBlock(zero);
            else
                zero = false;
            blockUsed[b] = 1;
            blockZero[b] = zero; // a recycled block is dirty; a fresh one is zero
            t.blk = b;
            t.lineCur = 0;
        }
    }

    override void* allocSmall(size_t g, bool noscan)
    {
        auto t = tc;
        immutable bytes = g * GRAN;
        ubyte* p;
        if (t.cur + bytes <= t.lim && (bytes <= LINE || !mediumOverflowOnly))
        {
            // Fits in the current hole (any size class, as in the Immix paper).
            p = t.cur;
            t.cur += bytes;
        }
        else if (bytes > LINE)
        {
            // Medium object that does not fit the hole: bump in an overflow block made of
            // completely free lines, so the remaining hole space is not abandoned.
            while (t.ocur + bytes > t.olim)
            {
                bool zero;
                auto b = getBlock(zero);
                blockUsed[b] = 1;
                blockZero[b] = zero;
                if (!zero)
                    memset(blockAddr(b), 0, BLOCK);
                // The overflow block is private to this thread until the next collection; mark
                // its lines live so no other hole search enters it.
                memset(lineLive + cast(size_t) b * LINES, 1, LINES);
                t.ocur = blockAddr(b);
                t.olim = t.ocur + BLOCK;
                account(t, BLOCK);
            }
            p = t.ocur;
            t.ocur += bytes;
        }
        else
        {
            while (t.cur + bytes > t.lim)
                nextHole(t, 1);
            p = t.cur;
            t.cur += bytes;
        }
        sz[(p - base) / GRAN] = cast(ubyte) (g | (noscan ? 0x80 : 0));
        return p;
    }

    override bool lookupSmall(size_t addr, ref Hit h, bool mark)
    {
        immutable off = addr - cast(size_t) base;
        immutable blk = off / BLOCK;
        if (!blockUsed[blk]) return false;
        size_t g = off / GRAN;
        immutable blockFirst = blk * GRANS_PER_BLOCK;
        // Find the object start at or before g: scan back at most 127 granules.
        size_t s = g;
        while (!sz[s])
        {
            if (s == blockFirst || g - s >= 127) return false;
            s--;
        }
        immutable e = sz[s];
        immutable n = e & 0x7f;
        if (g >= s + n) return false;
        h.start = base + s * GRAN;
        h.size = n * GRAN;
        h.noscan = (e & 0x80) != 0;
        h.fresh = false;
        if (mark)
        {
            if (markBits[s >> 3] & (1 << (s & 7))) return true;
            markBits[s >> 3] |= cast(ubyte) (1 << (s & 7));
            h.fresh = true;
            immutable l0 = (s * GRAN) / LINE;
            immutable l1 = (s * GRAN + n * GRAN - 1) / LINE;
            foreach (l; l0 .. l1 + 1)
                lineMark[l] = 1;
        }
        return true;
    }

    override size_t sweepSmall()
    {
        size_t liveBytes;
        statBlocks = statLiveUnits = 0;
        recyclable.len = 0;
        // Pool of free blocks is rebuilt from scratch: everything unused returns to it.
        freeCount = 0;
        size_t freeBlocks;
        immutable hw = highWater;
        // First pass: classify.
        Vec!uint freed;
        foreach (b; 0 .. hw)
        {
            if (!blockUsed[b]) { continue; }
            auto lm = lineMark + b * LINES;
            auto ll = lineLive + b * LINES;
            auto szb = sz + b * GRANS_PER_BLOCK;
            auto mb = markBits + b * (GRANS_PER_BLOCK / 8);
            size_t liveLines;
            foreach (l; 0 .. LINES)
            {
                if (lm[l])
                {
                    liveLines++;
                    ll[l] = 1;
                    lm[l] = 0;
                    // Drop dead objects that share this live line, so they cannot be resurrected.
                    foreach (k; 0 .. 8)
                    {
                        immutable gi = l * 8 + k;
                        if (!szb[gi]) continue;
                        if (mb[gi >> 3] & (1 << (gi & 7)))
                            liveBytes += (szb[gi] & 0x7f) * GRAN;
                        else
                            szb[gi] = 0;
                    }
                }
                else
                {
                    ll[l] = 0;
                    *cast(ulong*) (szb + l * 8) = 0;
                }
            }
            memset(mb, 0, GRANS_PER_BLOCK / 8);
            if (liveLines)
            {
                statBlocks++;
                statLiveUnits += liveLines;
            }
            if (liveLines == 0)
            {
                blockUsed[b] = 0;
                freed.push(cast(uint) b);
            }
            else if (liveLines < LINES)
            {
                blockZero[b] = 0;
                recyclable.push(cast(uint) b);
            }
        }
        // Free blocks: keep a reserve committed, decommit the rest.
        immutable inUse = hw - freed.len;
        immutable keep = (inUse / 8) > 4 ? inUse / 8 : 4;
        foreach (i; 0 .. freed.len)
        {
            immutable b = freed.ptr[i];
            if (i < keep)
            {
                blockZero[b] = 0;
            }
            else
            {
                decommit(blockAddr(b), BLOCK);
                blockZero[b] = 1;
            }
            freePool[freeCount++] = b;
        }
        free(freed.ptr);
        return liveBytes;
    }

    override size_t metaResidentBytes()
    {
        return residentBytes(sz, highWater * GRANS_PER_BLOCK)
            + residentBytes(markBits, highWater * GRANS_PER_BLOCK / 8)
            + residentBytes(lineLive, highWater * LINES)
            + residentBytes(lineMark, highWater * LINES)
            + residentBytes(blockUsed, highWater) + residentBytes(blockZero, highWater);
    }
}

size_t residentBytes(void* p, size_t len) nothrow @nogc
{
    if (!len) return 0;
    auto start = cast(size_t) p & ~(PAGE - 1);
    auto end = (cast(size_t) p + len + PAGE - 1) & ~(PAGE - 1);
    immutable pages = (end - start) / PAGE;
    auto vec = cast(ubyte*) malloc(pages);
    size_t n;
    if (mincore(cast(void*) start, end - start, vec) == 0)
        foreach (i; 0 .. pages)
            n += vec[i] & 1;
    free(vec);
    return n * PAGE;
}

// =====================================================================================
// Segregated fit
// =====================================================================================

immutable size_t[24] classSize = [
    16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256,
    320, 384, 448, 512, 640, 768, 896, 1024, 1280, 1536, 1792, 2032,
];

final class SegfitGc : Gc
{
    ubyte* cls;          // per block: class + 1, 0 = not a slab
    ubyte* allocB;       // per block 256 bytes
    ubyte* markB;
    ubyte* noscanB;
    ubyte* classOf;      // granules -> class, indexed 1..127
    Vec!uint[24] partial;
    SpinLock[24] partialLock;

    this()
    {
        super();
        cls = cast(ubyte*) reserve(NBLOCKS);
        allocB = cast(ubyte*) reserve(NBLOCKS * 256);
        markB = cast(ubyte*) reserve(NBLOCKS * 256);
        noscanB = cast(ubyte*) reserve(NBLOCKS * 256);
        classOf = cast(ubyte*) malloc(128);
        size_t c;
        foreach (g; 1 .. 128)
        {
            while (classSize[c] < g * GRAN) c++;
            classOf[g] = cast(ubyte) c;
        }
    }

    override string name() { return "segfit"; }

    override void initThread(ThreadCtx* t)
    {
        t.slab[] = NONE;
        t.cursor[] = 0;
    }

    override void retireThread(ThreadCtx* t)
    {
        t.slab[] = NONE;
        t.cursor[] = 0;
    }

    private ubyte* blockAddr(uint b) { return base + cast(size_t) b * BLOCK; }

    private size_t slots(size_t c) { return BLOCK / classSize[c]; }

    private void initSlab(uint b, size_t c, bool zero)
    {
        cls[b] = cast(ubyte) (c + 1);
        auto ab = allocB + cast(size_t) b * 256;
        memset(ab, 0, 256);
        memset(markB + cast(size_t) b * 256, 0, 256);
        memset(noscanB + cast(size_t) b * 256, 0, 256);
        // Bits past the last slot are pre-set so the free-slot search never returns them.
        foreach (i; slots(c) .. 2048)
            ab[i >> 3] |= cast(ubyte) (1 << (i & 7));
        blockZero[b] = zero;
    }

    override void* allocSmall(size_t g, bool noscan)
    {
        auto t = tc;
        immutable c = classOf[g];
        immutable size = classSize[c];
        while (true)
        {
            immutable b = t.slab[c];
            if (b != NONE)
            {
                auto ab = allocB + cast(size_t) b * 256;
                auto words = cast(ulong*) ab;
                size_t w = t.cursor[c] >> 6;
                for (; w < 32; w++)
                {
                    if (words[w] != ulong.max)
                    {
                        import core.bitop : bsf;
                        immutable bit = bsf(~words[w]);
                        immutable i = w * 64 + bit;
                        words[w] |= ulong(1) << bit;
                        t.cursor[c] = cast(uint) i;
                        auto p = blockAddr(b) + i * size;
                        if (!blockZero[b])
                            memset(p, 0, size);
                        auto nb = noscanB + cast(size_t) b * 256;
                        if (noscan) nb[i >> 3] |= cast(ubyte) (1 << (i & 7));
                        else nb[i >> 3] &= cast(ubyte) ~(1 << (i & 7));
                        return p;
                    }
                }
                t.slab[c] = NONE;
            }
            // Slow path: a partial slab of this class, else a free block.
            uint nb = NONE;
            partialLock[c].lock();
            if (partial[c].len)
                nb = partial[c].pop();
            partialLock[c].unlock();
            if (nb == NONE)
            {
                bool zero;
                nb = getBlock(zero);
                initSlab(nb, c, zero);
            }
            t.slab[c] = nb;
            t.cursor[c] = 0;
            // Count only the free slots handed to the mutator, as Immix counts only hole bytes.
            size_t used;
            foreach (w; 0 .. 32)
                used += popcnt((cast(ulong*) (allocB + cast(size_t) nb * 256))[w]);
            immutable freeSlots = slots(c) - (used - (2048 - slots(c)));
            account(t, freeSlots * size);
        }
    }

    override bool lookupSmall(size_t addr, ref Hit h, bool mark)
    {
        immutable off = addr - cast(size_t) base;
        immutable b = off / BLOCK;
        immutable c1 = cls[b];
        if (!c1) return false;
        immutable c = c1 - 1;
        immutable size = classSize[c];
        immutable i = (off % BLOCK) / size;
        if (i >= slots(c)) return false;
        auto ab = allocB + b * 256;
        if (!(ab[i >> 3] & (1 << (i & 7)))) return false;
        h.start = base + b * BLOCK + i * size;
        h.size = size;
        h.noscan = (noscanB[b * 256 + (i >> 3)] & (1 << (i & 7))) != 0;
        h.fresh = false;
        if (mark)
        {
            auto mb = markB + b * 256;
            if (mb[i >> 3] & (1 << (i & 7))) return true;
            mb[i >> 3] |= cast(ubyte) (1 << (i & 7));
            h.fresh = true;
        }
        return true;
    }

    override size_t sweepSmall()
    {
        size_t liveBytes;
        statBlocks = statLiveUnits = 0;
        foreach (ref p; partial) p.len = 0;
        freeCount = 0;
        immutable hw = highWater;
        Vec!uint freed;
        foreach (b; 0 .. hw)
        {
            immutable c1 = cls[b];
            if (!c1) continue;
            immutable c = c1 - 1;
            auto words = cast(ulong*) (allocB + b * 256);
            auto mwords = cast(ulong*) (markB + b * 256);
            size_t live;
            foreach (w; 0 .. 32)
            {
                words[w] &= mwords[w];
                mwords[w] = 0;
                live += popcnt(words[w]);
            }
            immutable n = slots(c);
            // Re-set the sentinel bits beyond the last slot (they were cleared by the mask above,
            // because the mark bits there are 0); counted separately.
            auto ab = allocB + b * 256;
            foreach (i; n .. 2048)
                ab[i >> 3] |= cast(ubyte) (1 << (i & 7));
            // popcnt counted only marked slots (sentinels are unmarked and were masked out)
            liveBytes += live * classSize[c];
            if (live)
            {
                statBlocks++;
                statLiveUnits += live * classSize[c] / 128; // in 128-byte units, comparable to Immix lines
            }
            if (live == 0)
            {
                cls[b] = 0;
                freed.push(cast(uint) b);
            }
            else
            {
                blockZero[b] = 0;
                if (live < n)
                    partial[c].push(cast(uint) b);
            }
        }
        immutable inUse = hw - freed.len;
        immutable keep = (inUse / 8) > 4 ? inUse / 8 : 4;
        foreach (i; 0 .. freed.len)
        {
            immutable b = freed.ptr[i];
            if (i < keep)
                blockZero[b] = 0;
            else
            {
                decommit(blockAddr(b), BLOCK);
                blockZero[b] = 1;
            }
            freePool[freeCount++] = b;
        }
        free(freed.ptr);
        return liveBytes;
    }

    override size_t metaResidentBytes()
    {
        return residentBytes(allocB, highWater * 256) + residentBytes(markB, highWater * 256)
            + residentBytes(noscanB, highWater * 256) + residentBytes(cls, highWater)
            + residentBytes(blockZero, highWater);
    }
}

size_t popcnt(ulong x) nothrow @nogc
{
    import core.bitop : bitPopcnt = popcnt;
    return bitPopcnt(x);
}
