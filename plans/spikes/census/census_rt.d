/**
 * Escape census runtime (RFC Phase 0.4).
 *
 * `CensusGC` wraps druntime's conservative GC and records every allocation (address, size,
 * allocating thread, allocation site, no-scan flag). Instrumented code (see rewrite_census.d)
 * reports every pointer store and pointer-containing memcpy. For each store the runtime decides,
 * using the rules of RFC section 3.5 (I1), whether the stored object would have had to be
 * published to the global domain:
 *
 *   - the stored value is an object allocated by thread T;
 *   - the slot belongs to the global domain (static data, memory not from the GC, an escaped
 *     object) or to another thread (its stack, its TLS, an object it owns).
 *
 * In that case the object and everything reachable from it that is still thread-local are marked
 * escaped (a "promotion"), and the graph size is recorded. Objects are counted when they die
 * (after each collection) or at exit, so the report gives the fraction of objects and bytes that
 * would have been promoted, per allocation site and per store site.
 *
 * Stack-address escapes (a pointer into a thread's own stack stored outside that stack) are counted,
 * and a thread's stack becomes "visible" when such a pointer reaches the global domain, another
 * thread, or an object that is later promoted (the stackVisible rule of I5, gate G4).
 *
 * Nothing in this module allocates from the GC. It is slow (a global lock and a GC address lookup
 * per store); run it on reduced inputs. See the limitations in the report and rewrite_census.d.
 */
module census_rt;

import core.atomic;
import core.gc.gcinterface;
import core.gc.registry;
import core.lifetime : emplace;
import core.stdc.stdio;
import core.stdc.stdlib : free, getenv, malloc, realloc, calloc;
import core.stdc.string : memcpy, memset;
import core.sys.linux.link : dl_iterate_phdr, dl_phdr_info;
import core.sys.posix.pthread;
import core.sys.posix.sched : sched_yield;
import core.time;
static import core.memory;

// Select the census GC without a command-line option.
extern (C) __gshared string[] rt_options = ["gcopt=gc:census"];

extern (C) int pthread_getattr_np(pthread_t, pthread_attr_t*) nothrow @nogc;

/// Set by instrumented code before calls into druntime allocation entry points.
extern (C) const(char)* _census_alloc_site;

enum ubyte F_ESC = 1;        // escaped (promoted)
enum ubyte F_NOSCAN = 2;
enum ubyte F_STACKREF = 4;   // holds an address into its owner's stack

struct Rec
{
    size_t addr;     // 0 = empty, 1 = tombstone
    uint size;
    uint site;
    ushort owner;
    ubyte flags;
    ubyte pad;
}

struct SpinLock
{
    shared int v;
    void lock() nothrow @nogc
    {
        int spins;
        while (!cas(&v, 0, 1))
            if (++spins > 64) { sched_yield(); spins = 0; }
    }
    void unlock() nothrow @nogc { atomicStore!(MemoryOrder.rel)(v, 0); }
}

struct SiteStat
{
    const(char)* name;
    ulong objs, bytes, escObjs, escBytes;        // by allocation site, counted at death/exit
    ulong promos, promoObjs, promoBytes;         // by store site that triggered a promotion
}

struct ThreadInfo
{
    ushort id;
    size_t stackLo, stackHi, tlsLo, tlsHi;
    bool alive;
    bool visible;
    long visibleAtNs, endNs;
    const(char)* visibleSite;
    ulong stackEscapes;
}

__gshared
{
    GC inner;
    bool g_enabled;
    SpinLock L;
    Rec* tab;
    size_t cap, used, tombs;
    size_t gcLo = size_t.max, gcHi;
    SiteStat* sites;
    size_t nSites, capSites;
    size_t[8192] siteHash;                   // open addressing: index+1 into sites
    ThreadInfo[256] threads;
    MonoTime t0;
    size_t tlsSize;
    ulong lastCollections;

    // totals, counted at death or exit
    ulong totObjs, totBytes, escObjs, escBytes, deadLocalObjs, deadEscObjs;
    ulong allocCount, allocBytes;
    // events
    ulong nStores, nStoreNull, nCopies, nCopiesTruncated, nPromos, nCrossFound;
    ulong promoObjsTotal, promoBytesTotal, maxGraphObjs, maxGraphBytes;
    ulong[24] graphHist;                     // promotion graph size, log2(objects)
    ulong stackAddrEscapes, stackAddrToLocalHeap, stackAddrVisible;
    ulong unobservedCross, unobservedGlobal, unobservedScanned;
    ulong allocUntagged;
}

shared uint nThreads;
ThreadInfo* myInfo;       // TLS
bool inHook;              // TLS

// ----------------------------------------------------------------------------- tables

size_t hashAddr(size_t a) nothrow @nogc { return (a >> 4) * 0x9E3779B97F4A7C15UL; }

Rec* findRec(size_t addr) nothrow @nogc
{
    if (!cap) return null;
    auto mask = cap - 1;
    auto i = hashAddr(addr) & mask;
    while (true)
    {
        auto r = &tab[i];
        if (r.addr == addr) return r;
        if (r.addr == 0) return null;
        i = (i + 1) & mask;
    }
}

void rehash(size_t newCap) nothrow @nogc
{
    auto old = tab;
    immutable oldCap = cap;
    tab = cast(Rec*) calloc(newCap, Rec.sizeof);
    cap = newCap;
    used = tombs = 0;
    foreach (i; 0 .. oldCap)
        if (old[i].addr > 1)
        {
            auto mask = cap - 1;
            auto j = hashAddr(old[i].addr) & mask;
            while (tab[j].addr) j = (j + 1) & mask;
            tab[j] = old[i];
            ++used;
        }
    free(old);
}

/// Returns the record for `addr`; `existed` tells whether it was already present (a stale
/// record at a reused address) or is fresh and zeroed.
Rec* insertRec(size_t addr, out bool existed) nothrow @nogc
{
    if ((used + tombs + 1) * 10 > cap * 6)
        rehash(cap == 0 ? 1 << 16 : (used * 4 > cap ? cap * 2 : cap));
    auto mask = cap - 1;
    auto i = hashAddr(addr) & mask;
    Rec* tomb;
    while (true)
    {
        auto r = &tab[i];
        if (r.addr == addr) { existed = true; return r; }
        if (r.addr == 1 && !tomb) tomb = r;
        if (r.addr == 0)
        {
            if (tomb) { --tombs; r = tomb; }
            *r = Rec.init;
            r.addr = addr;
            ++used;
            existed = false;
            return r;
        }
        i = (i + 1) & mask;
    }
}

void eraseRec(Rec* r) nothrow @nogc
{
    r.addr = 1;
    --used;
    ++tombs;
}

uint siteIndex(const(char)* name) nothrow @nogc
{
    if (name is null) return 0;
    auto h = (cast(size_t) name >> 3) * 0x9E3779B97F4A7C15UL;
    auto i = (h >> 20) & (siteHash.length - 1);
    while (siteHash[i])
    {
        if (sites[siteHash[i] - 1].name is name) return cast(uint) siteHash[i] - 1;
        i = (i + 1) & (siteHash.length - 1);
    }
    if (nSites == capSites)
    {
        capSites = capSites ? capSites * 2 : 256;
        sites = cast(SiteStat*) realloc(sites, capSites * SiteStat.sizeof);
    }
    sites[nSites] = SiteStat.init;
    sites[nSites].name = name;
    siteHash[i] = ++nSites;
    return cast(uint) nSites - 1;
}

// ----------------------------------------------------------------------------- threads

ushort nextId() nothrow @nogc
{
    return cast(ushort) (atomicOp!"+="(nThreads, 1));
}

static this()
{
    // Per-thread: stack and TLS ranges for the region classifier.
    immutable id = nextId();
    if (id >= threads.length) return;
    auto ti = &threads[id];
    pthread_attr_t attr;
    if (pthread_getattr_np(pthread_self(), &attr) == 0)
    {
        void* addr;
        size_t size;
        pthread_attr_getstack(&attr, &addr, &size);
        ti.stackLo = cast(size_t) addr;
        ti.stackHi = ti.stackLo + size;
        pthread_attr_destroy(&attr);
    }
    // x86-64 glibc: the static TLS block sits just below the thread pointer.
    immutable tp = cast(size_t) pthread_self();
    ti.tlsHi = tp;
    ti.tlsLo = tp - tlsSize;
    ti.id = id;
    ti.alive = true;
    myInfo = ti;
}

static ~this()
{
    if (myInfo)
    {
        myInfo.alive = false;
        myInfo.endNs = (MonoTime.currTime - t0).total!"nsecs";
    }
}

shared static this()
{
    t0 = MonoTime.currTime;
    siteIndex("unknown"); // index 0 stands for allocations without a tagged site
    // Size of the executable's static TLS block, from its PT_TLS program header.
    extern (C) static int cb(dl_phdr_info* info, size_t, void* data) nothrow @nogc
    {
        foreach (i; 0 .. info.dlpi_phnum)
        {
            auto ph = &info.dlpi_phdr[i];
            if (ph.p_type == 7) // PT_TLS
            {
                auto al = ph.p_align ? ph.p_align : 1;
                *cast(size_t*) data = (ph.p_memsz + al - 1) & ~(al - 1);
                return 1;
            }
        }
        return 1; // only the main program
    }
    dl_iterate_phdr(&cb, &tlsSize);
    g_enabled = true;
}

bool inOwnRegions(const ThreadInfo* t, size_t a) nothrow @nogc
{
    return a - t.stackLo < t.stackHi - t.stackLo || a - t.tlsLo < t.tlsHi - t.tlsLo;
}

// ----------------------------------------------------------------------------- death accounting

void account(Rec* r) nothrow @nogc
{
    ++totObjs;
    totBytes += r.size;
    auto s = &sites[r.site];
    ++s.objs;
    s.bytes += r.size;
    if (r.flags & F_ESC)
    {
        ++escObjs;
        escBytes += r.size;
        ++s.escObjs;
        s.escBytes += r.size;
    }
}

void died(Rec* r) nothrow @nogc
{
    account(r);
    if (r.flags & F_ESC) ++deadEscObjs; else ++deadLocalObjs;
}

/// After a collection: records whose memory the collector reclaimed are dead.
void sweepDead() nothrow @nogc
{
    foreach (i; 0 .. cap)
    {
        auto r = &tab[i];
        if (r.addr > 1 && inner.addrOf(cast(void*) r.addr) !is cast(void*) r.addr)
        {
            died(r);
            eraseRec(r);
        }
    }
}

void maybeSweep() nothrow @nogc
{
    immutable c = inner.profileStats().numCollections;
    if (c != lastCollections)
    {
        lastCollections = c;
        sweepDead();
    }
}

// ----------------------------------------------------------------------------- the GC wrapper

void recordAlloc(void* p, size_t size, uint bits) nothrow @nogc
{
    if (!p || !g_enabled || inHook) return;
    inHook = true;
    scope (exit) inHook = false;
    auto site = _census_alloc_site;
    _census_alloc_site = null;
    if (!myInfo) { return; }
    L.lock();
    maybeSweep();
    if (site is null) ++allocUntagged;
    bool existed;
    auto r = insertRec(cast(size_t) p, existed);
    if (existed) // stale record at a reused address: that object died when its memory was reused
    {
        died(r);
        *r = Rec.init;
        r.addr = cast(size_t) p;
    }
    r.size = cast(uint) (size > uint.max ? uint.max : size);
    r.site = siteIndex(site);
    r.owner = myInfo.id;
    r.flags = (bits & core.memory.GC.BlkAttr.NO_SCAN) ? F_NOSCAN : 0;
    ++allocCount;
    allocBytes += size;
    if (cast(size_t) p < gcLo) gcLo = cast(size_t) p;
    if (cast(size_t) p + size > gcHi) gcHi = cast(size_t) p + size;
    L.unlock();
}

final class CensusGC : GC
{
    this(GC i) { inner = i; }

    void enable() { inner.enable(); }
    void disable() { inner.disable(); }
    void collect() nothrow
    {
        inner.collect();
        if (g_enabled && !inHook) { L.lock(); maybeSweep(); L.unlock(); }
    }
    void minimize() nothrow { inner.minimize(); }
    uint getAttr(void* p) nothrow { return inner.getAttr(p); }
    uint setAttr(void* p, uint mask) nothrow { return inner.setAttr(p, mask); }
    uint clrAttr(void* p, uint mask) nothrow { return inner.clrAttr(p, mask); }
    void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        auto p = inner.malloc(size, bits, ti);
        recordAlloc(p, size, bits);
        return p;
    }
    core.memory.GC.BlkInfo qalloc(size_t size, uint bits, const scope TypeInfo ti) nothrow
    {
        auto bi = inner.qalloc(size, bits, ti);
        recordAlloc(bi.base, bi.size, bits);
        return bi;
    }
    void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        auto p = inner.calloc(size, bits, ti);
        recordAlloc(p, size, bits);
        return p;
    }
    void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
    {
        Rec saved;
        bool had;
        if (p && g_enabled && !inHook)
        {
            L.lock();
            if (auto r = findRec(cast(size_t) p))
            {
                saved = *r;
                had = true;
            }
            L.unlock();
        }
        auto np = inner.realloc(p, size, bits, ti);
        if (had && np !is p)
        {
            L.lock();
            if (auto r = findRec(cast(size_t) p)) eraseRec(r);
            L.unlock();
            recordAlloc(np, size, bits);
            // The object keeps its identity: carry owner, site and escape state over.
            L.lock();
            if (auto r = findRec(cast(size_t) np))
            {
                r.owner = saved.owner;
                r.site = saved.site;
                r.flags |= saved.flags & (F_ESC | F_STACKREF);
                --allocCount; // same logical object
            }
            L.unlock();
        }
        else if (had)
        {
            L.lock();
            if (auto r = findRec(cast(size_t) np)) r.size = cast(uint) size;
            L.unlock();
        }
        else
            recordAlloc(np, size, bits);
        return np;
    }
    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {
        auto r = inner.extend(p, minsize, maxsize, ti);
        if (r && g_enabled && !inHook)
        {
            L.lock();
            if (auto rec = findRec(cast(size_t) p)) rec.size = cast(uint) r;
            L.unlock();
        }
        return r;
    }
    size_t reserve(size_t size) nothrow { return inner.reserve(size); }
    void free(void* p) nothrow @nogc
    {
        if (p && g_enabled && !inHook)
        {
            L.lock();
            if (auto r = findRec(cast(size_t) p)) { died(r); eraseRec(r); }
            L.unlock();
        }
        inner.free(p);
    }
    void* addrOf(void* p) nothrow @nogc { return inner.addrOf(p); }
    size_t sizeOf(void* p) nothrow @nogc { return inner.sizeOf(p); }
    core.memory.GC.BlkInfo query(void* p) nothrow { return inner.query(p); }
    core.memory.GC.Stats stats() @trusted nothrow @nogc { return inner.stats(); }
    core.memory.GC.ProfileStats profileStats() @trusted nothrow @nogc { return inner.profileStats(); }
    void addRoot(void* p) nothrow @nogc { inner.addRoot(p); }
    void removeRoot(void* p) nothrow @nogc { inner.removeRoot(p); }
    @property RootIterator rootIter() @nogc { return inner.rootIter; }
    void addRange(void* p, size_t sz, const TypeInfo ti) nothrow @nogc { inner.addRange(p, sz, ti); }
    void removeRange(void* p) nothrow @nogc { inner.removeRange(p); }
    @property RangeIterator rangeIter() @nogc { return inner.rangeIter; }
    void runFinalizers(const scope void[] segment) nothrow { inner.runFinalizers(segment); }
    bool inFinalizer() nothrow @nogc @trusted { return inner.inFinalizer(); }
    ulong allocatedInCurrentThread() nothrow { return inner.allocatedInCurrentThread(); }
}

GC makeCensusGC()
{
    auto base = createGCInstance("conservative");
    enum sz = __traits(classInstanceSize, CensusGC);
    auto mem = malloc(sz);
    return emplace!CensusGC(mem[0 .. sz], base);
}

pragma(crt_constructor) extern (C) void census_register()
{
    registerGCFactory("census", &makeCensusGC);
}

// ----------------------------------------------------------------------------- the hooks

/// Heap record for any address inside a GC allocation, or null.
Rec* lookup(size_t a) nothrow @nogc
{
    if (a < gcLo || a >= gcHi) return null;
    auto base = inner.addrOf(cast(void*) a);
    if (!base) return null;
    return findRec(cast(size_t) base);
}

void markThreadVisible(ushort owner, const(char)* site) nothrow @nogc
{
    if (owner == 0 || owner >= threads.length) return;
    auto t = &threads[owner];
    if (!t.visible)
    {
        t.visible = true;
        t.visibleAtNs = (MonoTime.currTime - t0).total!"nsecs";
        t.visibleSite = site;
        ++stackAddrVisible;
    }
}

/// Mark `o` and everything thread-local reachable from it as escaped.
void promote(Rec* o, const(char)* site) nothrow @nogc
{
    static size_t* stk;
    static size_t stkCap;
    size_t sp;
    ulong objs, bytes;

    void push(size_t a) nothrow @nogc
    {
        if (sp == stkCap)
        {
            stkCap = stkCap ? stkCap * 2 : 4096;
            stk = cast(size_t*) realloc(stk, stkCap * size_t.sizeof);
        }
        stk[sp++] = a;
    }

    o.flags |= F_ESC;
    if (o.flags & F_STACKREF) markThreadVisible(o.owner, site);
    ++objs;
    bytes += o.size;
    push(o.addr);
    immutable root = o.owner;
    while (sp)
    {
        auto x = findRec(stk[--sp]);
        if (!x || (x.flags & F_NOSCAN)) continue;
        auto words = cast(size_t*) x.addr;
        immutable n = x.size / size_t.sizeof;
        foreach (i; 0 .. n)
        {
            immutable w = words[i];
            auto r = lookup(w);
            if (r is null || (r.flags & F_ESC)) continue;
            if (r.owner != root) ++nCrossFound; // a reference no instrumented store explained
            r.flags |= F_ESC;
            if (r.flags & F_STACKREF) markThreadVisible(r.owner, site);
            ++objs;
            bytes += r.size;
            push(r.addr);
        }
    }
    ++nPromos;
    promoObjsTotal += objs;
    promoBytesTotal += bytes;
    if (objs > maxGraphObjs) maxGraphObjs = objs;
    if (bytes > maxGraphBytes) maxGraphBytes = bytes;
    size_t b;
    for (auto v = objs; v > 1; v >>= 1) ++b;
    ++graphHist[b < graphHist.length ? b : graphHist.length - 1];
    auto s = &sites[siteIndex(site)];
    ++s.promos;
    s.promoObjs += objs;
    s.promoBytes += bytes;
}

enum Domain { local, global, other }

/// Where does a slot live, as seen from thread `me`?
Domain classify(const ThreadInfo* me, size_t slot, out ushort owner, out Rec* obj) nothrow @nogc
{
    if (inOwnRegions(me, slot)) { owner = me.id; return Domain.local; }
    foreach (i; 1 .. nThreads + 1)
    {
        if (i >= threads.length) break;
        auto t = &threads[i];
        if (t !is me && t.id && inOwnRegions(t, slot)) { owner = t.id; return Domain.other; }
    }
    auto r = lookup(slot);
    if (r)
    {
        obj = r;
        if (r.flags & F_ESC) return Domain.global;
        owner = r.owner;
        return r.owner == me.id ? Domain.local : Domain.other;
    }
    return Domain.global;
}

void onStore(void* slot, void* v, const(char)* site) nothrow @nogc
{
    auto me = myInfo;
    if (me is null || inHook) return;
    inHook = true;
    scope (exit) inHook = false;
    immutable sv = cast(size_t) v;
    immutable ss = cast(size_t) slot;
    immutable onStack = sv - me.stackLo < me.stackHi - me.stackLo;
    if (!onStack && (sv < gcLo || sv >= gcHi)) return; // cannot be a GC object: no lock needed
    L.lock();
    ++nStores;
    if (onStack)
    {
        // A pointer into my own stack stored somewhere.
        if (!inOwnRegions(me, ss))
        {
            ++stackAddrEscapes;
            ++me.stackEscapes;
            ushort owner;
            Rec* obj;
            final switch (classify(me, ss, owner, obj))
            {
                case Domain.global:
                case Domain.other:
                    markThreadVisible(me.id, site);
                    break;
                case Domain.local:
                    ++stackAddrToLocalHeap;
                    if (obj) obj.flags |= F_STACKREF;
                    break;
            }
        }
        L.unlock();
        return;
    }
    auto o = lookup(sv);
    if (o is null || (o.flags & F_ESC))
    {
        L.unlock();
        return;
    }
    ushort owner;
    Rec* sobj;
    immutable d = classify(me, ss, owner, sobj);
    if (d == Domain.global || (d == Domain.other && owner != o.owner) || (d == Domain.local && owner != o.owner))
        promote(o, site);
    L.unlock();
}

extern (C) void _d_census_store(void* slot, void* v, const(char)* site) nothrow @nogc
{
    if (v is null || !g_enabled) return;
    onStore(slot, v, site);
}

extern (C) void _d_census_copy(void* dst, size_t n, const(char)* site) nothrow @nogc
{
    if (!g_enabled || myInfo is null || inHook) return;
    auto words = cast(size_t*) dst;
    size_t cnt = n / size_t.sizeof;
    L.lock();
    ++nCopies;
    if (cnt > 4096) { cnt = 4096; ++nCopiesTruncated; }
    L.unlock();
    foreach (i; 0 .. cnt)
        if (words[i])
            onStore(&words[i], cast(void*) words[i], site);
}

// ----------------------------------------------------------------------------- report

struct KindStat { const(char)* name; ulong objs, bytes, esc, escBytes; }

shared static ~this()
{
    if (!inner) return;
    // Final accounting: collect what is dead, then count survivors and audit coverage.
    g_enabled = false;
    inner.collect();
    inHook = true;
    L.lock();
    lastCollections = 0;
    maybeSweep();

    // Coverage audit 1: references from live thread-local objects to objects of other threads
    // that no store explained. Audit 2: references from static data to objects not escaped.
    foreach (i; 0 .. cap)
    {
        auto r = &tab[i];
        if (r.addr <= 1 || (r.flags & (F_ESC | F_NOSCAN))) continue;
        ++unobservedScanned;
        auto words = cast(size_t*) r.addr;
        foreach (k; 0 .. r.size / size_t.sizeof)
        {
            auto o = lookup(words[k]);
            if (o && !(o.flags & F_ESC) && o.owner != r.owner) { ++unobservedCross; break; }
        }
    }
    foreach (ref rg; inner.rangeIter)
    {
        auto lo = cast(size_t*) rg.pbot;
        auto hi = cast(size_t*) rg.ptop;
        for (auto p = lo; p < hi; p++)
        {
            auto o = lookup(*p);
            if (o && !(o.flags & F_ESC)) { ++unobservedGlobal; o.flags |= F_ESC; }
        }
    }
    // Survivors.
    foreach (i; 0 .. cap)
    {
        auto r = &tab[i];
        if (r.addr > 1) account(r);
    }
    L.unlock();
    printReport();
}

struct Idents { char[96] buf; size_t len; }

/// Module prefix (first two identifiers) of a D mangled name, "kind:" prefix removed.
void modulePrefix(const(char)* name, char* out_, size_t cap_) nothrow @nogc
{
    size_t o;
    auto p = name;
    while (*p && *p != ':') ++p;
    p = (*p == ':') ? p + 1 : name;
    if (p[0] == '_' && p[1] == 'D') p += 2;
    int idents;
    while (idents < 2)
    {
        size_t n;
        while (*p >= '0' && *p <= '9') { n = n * 10 + (*p - '0'); ++p; }
        if (!n) break;
        if (idents && o + 1 < cap_) out_[o++] = '.';
        foreach (k; 0 .. n)
        {
            if (!p[k]) { n = k; break; }
            if (o + 1 < cap_) out_[o++] = p[k];
        }
        p += n;
        ++idents;
    }
    if (o == 0)
    {
        auto s = name;
        while (*s && *s != ':') ++s;
        s = (*s == ':') ? s + 1 : name;
        foreach (k; 0 .. 24) { if (!s[k]) break; out_[o++] = s[k]; }
    }
    out_[o] = 0;
}

void printReport()
{
    import core.demangle : demangle;
    immutable secs = (MonoTime.currTime - t0).total!"usecs" / 1e6;
    double pct(ulong a, ulong b) { return b ? 100.0 * a / b : 0.0; }
    fprintf(stderr, "\n==== census report ====\n");
    fprintf(stderr, "runtime %.2f s, %u threads, %llu allocations (%llu bytes), %llu untagged\n",
        secs, cast(uint) nThreads, allocCount, allocBytes, allocUntagged);
    fprintf(stderr, "objects: %llu total, %llu escaped (%.2f%%); bytes: %llu total, %llu escaped (%.2f%%)\n",
        totObjs, escObjs, pct(escObjs, totObjs), totBytes, escBytes, pct(escBytes, totBytes));
    fprintf(stderr, "died thread-local: %llu, died escaped: %llu, survivors: %llu\n",
        deadLocalObjs, deadEscObjs, totObjs - deadLocalObjs - deadEscObjs);
    fprintf(stderr, "stores observed: %llu, copies observed: %llu (%llu truncated)\n", nStores, nCopies, nCopiesTruncated);
    fprintf(stderr, "promotions: %llu, objects promoted via graphs: %llu, bytes %llu, mean graph %.1f objects, max %llu objects / %llu bytes\n",
        nPromos, promoObjsTotal, promoBytesTotal, nPromos ? cast(double) promoObjsTotal / nPromos : 0.0, maxGraphObjs, maxGraphBytes);
    fprintf(stderr, "promotion graph sizes (objects):");
    foreach (b, c; graphHist)
        if (c) fprintf(stderr, " [%llu..%llu)=%llu", 1UL << b, 2UL << b, c);
    fprintf(stderr, "\n");
    fprintf(stderr, "stack-address escapes: %llu (%.1f per second), %llu into thread-local heap objects, threads with a visible stack: %llu of %u\n",
        stackAddrEscapes, stackAddrEscapes / secs, stackAddrToLocalHeap, stackAddrVisible, cast(uint) nThreads);
    foreach (i; 1 .. nThreads + 1)
    {
        if (i >= threads.length) break;
        auto t = &threads[i];
        if (!t.visible) continue;
        immutable end = t.alive || !t.endNs ? cast(long) (secs * 1e9) : t.endNs;
        char[128] mod;
        modulePrefix(t.visibleSite, mod.ptr, 128);
        fprintf(stderr, "  thread %u: stack visible from %.3f s for %.3f s (first via %s)\n", cast(uint) i,
            t.visibleAtNs / 1e9, (end - t.visibleAtNs) / 1e9, mod.ptr);
    }
    fprintf(stderr, "coverage audit: %llu live local objects scanned, %llu hold a reference to another thread's object that no store explained; %llu static-data references to objects not marked escaped; %llu cross-thread references found while promoting\n",
        unobservedScanned, unobservedCross, unobservedGlobal, nCrossFound);

    // By allocation kind and by module.
    enum maxKinds = 16;
    KindStat[maxKinds] kinds;
    size_t nk;
    char[64][64] modNames = void;
    memset(modNames.ptr, 0, modNames.sizeof);
    ulong[64] modObjs, modBytes, modEsc, modEscBytes, modPromos, modPromoObjs;
    size_t nm;
    foreach (i; 0 .. nSites)
    {
        auto s = &sites[i];
        if (!s.name) continue;
        // kind = text before ':' for allocation sites
        char[24] kn = void;
        memset(kn.ptr, 0, kn.sizeof);
        size_t k;
        auto q = s.name;
        while (*q && *q != ':' && k < 23) kn[k++] = *q++;
        kn[k] = 0;
        immutable isAlloc = *q == ':' && s.objs;
        if (isAlloc)
        {
            size_t j;
            for (; j < nk; j++)
                if (kinds[j].name !is null)
                {
                    size_t c;
                    while (kinds[j].name[c] && kinds[j].name[c] == kn[c]) ++c;
                    if (!kinds[j].name[c] && !kn[c]) break;
                }
            if (j == nk && nk < maxKinds)
            {
                auto dup = cast(char*) malloc(k + 1);
                memcpy(dup, kn.ptr, k + 1);
                kinds[nk++] = KindStat(dup);
            }
            if (j < maxKinds)
            {
                kinds[j].objs += s.objs; kinds[j].bytes += s.bytes; kinds[j].esc += s.escObjs; kinds[j].escBytes += s.escBytes;
            }
        }
        char[64] mp = void;
        memset(mp.ptr, 0, mp.sizeof);
        modulePrefix(s.name, mp.ptr, 64);
        size_t j;
        for (; j < nm; j++)
        {
            size_t c;
            while (modNames[j][c] && modNames[j][c] == mp[c]) ++c;
            if (!modNames[j][c] && !mp[c]) break;
        }
        if (j == nm && nm < 64) { memcpy(modNames[nm].ptr, mp.ptr, 64); ++nm; }
        if (j < 64)
        {
            modObjs[j] += s.objs; modBytes[j] += s.bytes; modEsc[j] += s.escObjs; modEscBytes[j] += s.escBytes;
            modPromos[j] += s.promos; modPromoObjs[j] += s.promoObjs;
        }
    }
    fprintf(stderr, "by allocation kind:\n");
    foreach (j; 0 .. nk)
        fprintf(stderr, "  %-12s %12llu objects %14llu bytes, escaped %.2f%% of objects, %.2f%% of bytes\n",
            kinds[j].name, kinds[j].objs, kinds[j].bytes, pct(kinds[j].esc, kinds[j].objs), pct(kinds[j].escBytes, kinds[j].bytes));
    fprintf(stderr, "by module (allocation site; promotions by the module whose store triggered them):\n");
    foreach (j; 0 .. nm)
        if (modObjs[j] || modPromos[j])
            fprintf(stderr, "  %-28s %12llu objects, escaped %.2f%% (bytes %.2f%%), %llu promotions moving %llu objects\n",
                modNames[j].ptr, modObjs[j], pct(modEsc[j], modObjs[j]), pct(modEscBytes[j], modBytes[j]), modPromos[j], modPromoObjs[j]);

    // Top allocation sites by bytes.
    fprintf(stderr, "top allocation sites by bytes:\n");
    foreach (round; 0 .. 8)
    {
        size_t best = size_t.max;
        ulong bb;
        foreach (i; 0 .. nSites)
        {
            if (sites[i].bytes > bb)
            {
                bool done;
                foreach (pi; 0 .. round) if (printed[pi] == i) done = true;
                if (!done) { best = i; bb = sites[i].bytes; }
            }
        }
        if (best == size_t.max) break;
        printed[round] = best;
        auto s = &sites[best];
        const(char)* fn = s.name;
        while (*fn && *fn != ':') ++fn;
        immutable hasKind = *fn == ':';
        auto dm = demangle(hasKind ? fn[1 .. 1 + strlen_(fn + 1)] : s.name[0 .. strlen_(s.name)]);
        fprintf(stderr, "  %12llu bytes %10llu objects, escaped %6.2f%%  [%.*s] %.*s\n", s.bytes, s.objs, pct(s.escObjs, s.objs),
            hasKind ? cast(int) (fn - s.name) : 0, s.name, cast(int) (dm.length > 100 ? 100 : dm.length), dm.ptr);
    }
    fprintf(stderr, "top store sites by promoted objects:\n");
    foreach (round; 0 .. 8)
    {
        size_t best = size_t.max;
        ulong bb;
        foreach (i; 0 .. nSites)
        {
            if (sites[i].promoObjs > bb)
            {
                bool done;
                foreach (pi; 0 .. round) if (printed2[pi] == i) done = true;
                if (!done) { best = i; bb = sites[i].promoObjs; }
            }
        }
        if (best == size_t.max) break;
        printed2[round] = best;
        auto s = &sites[best];
        auto dm = demangle(s.name[0 .. strlen_(s.name)]);
        fprintf(stderr, "  %10llu promoted objects in %8llu promotions (%llu bytes)  %.*s\n", s.promoObjs, s.promos, s.promoBytes,
            cast(int) (dm.length > 110 ? 110 : dm.length), dm.ptr);
    }

    fprintf(stderr, "CENSUS runtime_s=%.3f threads=%u allocs=%llu alloc_bytes=%llu objs=%llu esc_objs=%llu esc_obj_pct=%.3f bytes=%llu esc_bytes=%llu esc_byte_pct=%.3f promotions=%llu promoted_objs=%llu max_graph=%llu stack_escapes=%llu stack_escapes_per_s=%.1f stack_visible_threads=%llu unobserved_cross=%llu unobserved_global=%llu stores=%llu\n",
        secs, cast(uint) nThreads, allocCount, allocBytes, totObjs, escObjs, pct(escObjs, totObjs), totBytes, escBytes, pct(escBytes, totBytes),
        nPromos, promoObjsTotal, maxGraphObjs, stackAddrEscapes, stackAddrEscapes / secs, stackAddrVisible, unobservedCross, unobservedGlobal, nStores);
}

__gshared size_t[8] printed, printed2;

size_t strlen_(const(char)* s) nothrow @nogc
{
    size_t n;
    while (s[n]) ++n;
    return n;
}
