/**
 * Explicit-state model checker for the hybrid TLS-Immix GC protocol
 * (plans/technical_rfc_hybrid_tls_immix_gc_for_d.md, Phase 0 item 0.5).
 *
 * It enumerates every reachable state of a small abstract system by breadth-
 * first search and checks the invariants of RFC section 3.5 in each state.
 * A violation is reported with a shortest action trace. For configurations too
 * large to enumerate there is a randomized mode (`--swarm`) that walks long
 * random executions and checks the same invariants; it can find violations but
 * cannot prove their absence.
 *
 * Build:  dmd -O -release -inline gc_model.d
 * Run:    ./gc_model                      # Track B, 2 threads, 4 objects
 *         ./gc_model --track=A            # SATB only, no local domains
 *         ./gc_model --bug=nodelete       # planted bug; must be detected
 *         ./gc_model --threads=3 --objects=5 --swarm=200 --len=200000
 * See `./gc_model --help` and the "Model" comment below.
 *
 * ---------------------------------------------------------------- Model ----
 * Objects O0..O(NO-1). Each is FREE, GLOBAL, or LOCAL(t). "GLOBAL" stands for
 * a global block or an object with its escaped bit set (in-place promotion).
 * Each object has NF pointer fields. There are NG global slots. Each thread has
 * NC stack contexts (its own stack plus NC-1 fibers, `--fibers`) of NS slots
 * each; one context is current. Values are null or an object reference.
 *
 * Mutator actions (per thread t), each atomic: allocate, drop or copy a slot of
 * the current context, load from a field / global / escaped foreign stack, store
 * to the same through the barrier of RFC section 4.4, publish the address of the
 * thread's own stack (I6), switch to another fiber, and a local collection
 * (Track B). With `--race` a store is two steps (barrier, then the write) so
 * that two threads can race on one slot.
 *
 * Collector actions: start a cycle (STW-1), scan one global slot, a per-thread
 * handshake (current context + the thread's local domain), claim and scan a
 * suspended fiber (unscanned -> scanning -> scanned, Phase 4.7), flush one SATB
 * buffer, trace one field of one grey object, remark (STW-2, drains everything,
 * requires every context scanned), and sweep one object at a time.
 *
 * Reductions: objects are interchangeable names (renamed by first reachability),
 * and threads are interchangeable (the smallest relabelling over all thread
 * permutations is stored).
 *
 * Not modelled (stated so the result is not over-read):
 *  - Lines and blocks: reuse is per object, so I4 holds by construction.
 *  - Weak memory: actions are sequentially consistent. With `--race` the barrier
 *    and the store are separate steps, but each is still atomic.
 *  - Fiber migration between threads, fibers created during a cycle.
 *  - I2 (owner-only mutation) and I3 (non-moving) hold by construction.
 *  - Finalizers, interior pointers, typed (no-scan) data, large objects.
 */
module gc_model;

import core.stdc.string : memcmp, memcpy;
import core.time;
import std.conv : to;
import std.format : format;
import std.getopt;
import std.stdio;

// ------------------------------------------------------------ configuration

__gshared int NT = 2, NO = 4, NS = 2, NF = 1, NG = 1, NFB = 0, NC = 1;
__gshared bool trackB = true;
__gshared bool race;           // two-step stores
__gshared bool fixXchg;        // with race: the write step also logs the value it really overwrites
__gshared string bug = "";
__gshared ulong maxStates = 400_000_000;
__gshared int swarmWalks;
__gshared long walkLen = 100_000;
__gshared ulong seed = 1;

// byte offsets inside the packed state
__gshared int oOwn, oFld, oStk, oGlb, oMark, oSkip, oEsc, oPhase, oGidx, oHs,
    oGrey, oCur, oIdx, oSwept, oBuf, oCtx, oScn, oPendL, oPendV, USED;

enum MAXB = 112;
struct S { ubyte[MAXB] b; }

enum : ubyte { FREE = 0, GLOBAL = 1 } // owner codes; LOCAL(t) = 2 + t
enum : ubyte { IDLE = 0, MARKING = 1, SWEEPING = 2 }

void layout()
{
    NC = NFB + 1;
    int p;
    int take(int n) { auto r = p; p += n; return r; }
    oOwn = take(NO);
    oFld = take(NO * NF);
    oStk = take(NT * NC * NS);
    oGlb = take(NG);
    oMark = take(1); oSkip = take(1); oEsc = take(1); oPhase = take(1);
    oGidx = take(1); oHs = take(1); oGrey = take(1); oCur = take(1);
    oIdx = take(1); oSwept = take(1);
    oBuf = take(NT);
    oCtx = take(NT);
    oScn = take(NT * NC);
    oPendL = take(NT);
    oPendV = take(NT);
    USED = p;
    assert(USED <= MAXB, "state too large; raise MAXB");
    assert(NO <= 8 && NT <= 6);
}

bool isBug(string n) { return bug == n; }

// ------------------------------------------------------------ state access

ubyte own(in S s, int o) { return s.b[oOwn + o]; }
size_t fi(int o, int f) { return oFld + o * NF + f; }
size_t sc(int t, int c, int i) { return oStk + (t * NC + c) * NS + i; }   // slot i of context c of thread t
size_t cs(in S s, int t, int i) { return sc(t, s.b[oCtx + t], i); }       // slot i of the current context
size_t sflat(int t, int k) { return oStk + t * NC * NS + k; }             // k = c * NS + i
bool bit(ubyte m, int o) { return ((m >> o) & 1) != 0; }
ubyte phase(in S s) { return s.b[oPhase]; }

struct Loc { int kind, a, b; } // 0 = field(a,b), 1 = global a, 2 = stack(thread a, flat slot b)

ubyte readLoc(in S s, Loc l)
{
    final switch (l.kind)
    {
        case 0: return s.b[fi(l.a, l.b)];
        case 1: return s.b[oGlb + l.a];
        case 2: return s.b[sflat(l.a, l.b)];
    }
}

void writeLoc(ref S s, Loc l, ubyte v)
{
    final switch (l.kind)
    {
        case 0: s.b[fi(l.a, l.b)] = v; break;
        case 1: s.b[oGlb + l.a] = v; break;
        case 2: s.b[sflat(l.a, l.b)] = v; break;
    }
}

int locId(Loc l)
{
    final switch (l.kind)
    {
        case 0: return l.a * NF + l.b;
        case 1: return NO * NF + l.a;
        case 2: return NO * NF + NG + l.a * NC * NS + l.b;
    }
}

Loc locFromId(int id)
{
    if (id < NO * NF) return Loc(0, id / NF, id % NF);
    id -= NO * NF;
    if (id < NG) return Loc(1, id, 0);
    id -= NG;
    return Loc(2, id / (NC * NS), id % (NC * NS));
}

string locStr(Loc l)
{
    final switch (l.kind)
    {
        case 0: return format("O%s.f%s", l.a, l.b);
        case 1: return format("G%s", l.a);
        case 2: return NC > 1 ? format("T%s.c%s.s%s", l.a, l.b / NS, l.b % NS) : format("T%s.s%s", l.a, l.b);
    }
}

string refStr(ubyte r) { return r ? format("O%s", r - 1) : "null"; }

void freeObj(ref S s, int o)
{
    s.b[oOwn + o] = FREE;
    foreach (f; 0 .. NF)
        s.b[fi(o, f)] = 0;
    immutable m = cast(ubyte) ~(1 << o);
    s.b[oMark] &= m; s.b[oSkip] &= m; s.b[oGrey] &= m; s.b[oSwept] &= m;
}

// ------------------------------------------------------------ collector ops

/// Mark a GLOBAL object and queue it for tracing (grey).
void markGrey(ref S s, int o)
{
    if (!bit(s.b[oMark], o))
    {
        s.b[oMark] |= 1 << o;
        s.b[oGrey] |= 1 << o;
    }
}

void bufAdd(ref S s, int t, ubyte r)
{
    if (r)
        s.b[oBuf + t] |= 1 << (r - 1);
}

/// Move a thread's SATB buffer into the global queue (mark + grey GLOBAL entries).
void flush(ref S s, int t)
{
    foreach (o; 0 .. NO)
        if (bit(s.b[oBuf + t], o) && own(s, o) == GLOBAL)
            markGrey(s, o);
    s.b[oBuf + t] = 0;
}

/// References a thread holds in registers while a two-step store is in flight: the object
/// being written and the value. They are roots (scanned at the handshake with the registers).
int regRoots(in S s, int t, ref ubyte[2] r)
{
    if (!s.b[oPendL + t]) return 0;
    int n;
    r[n++] = s.b[oPendV + t];
    immutable l = locFromId(s.b[oPendL + t] - 1);
    if (l.kind == 0) r[n++] = cast(ubyte)(l.a + 1);
    return n;
}

/// Scan one stack context of thread t: grey the GLOBAL objects it names and trace the
/// thread's local domain from it. With `regs`, the thread's in-flight store is scanned too.
void scanSlots(ref S s, int t, int c, bool regs = false)
{
    ubyte seen;
    int[16] work;
    int nw;
    void visit(ubyte r)
    {
        if (!r) return;
        immutable o = r - 1;
        if (own(s, o) == GLOBAL)
            markGrey(s, o);
        else if (own(s, o) == 2 + t && !isBug("nolocaltrace") && !bit(seen, o))
        {
            seen |= 1 << o;
            work[nw++] = o;
        }
    }
    foreach (i; 0 .. NS)
        visit(s.b[sc(t, c, i)]);
    if (regs)
    {
        ubyte[2] rr;
        foreach (r; rr[0 .. regRoots(s, t, rr)])
            visit(r);
    }
    while (nw)
    {
        immutable o = work[--nw];
        foreach (f; 0 .. NF)
            visit(s.b[fi(o, f)]);
    }
}

/// Per-thread handshake: scan the current context and the registers, set stackScanned.
void handshake(ref S s, int t)
{
    immutable c = s.b[oCtx + t];
    scanSlots(s, t, c, true);
    s.b[oScn + t * NC + c] = 2;
    s.b[oHs] |= 1 << t;
}

void traceFields(ref S s, int o, int from)
{
    foreach (f; from .. NF)
    {
        immutable v = s.b[fi(o, f)];
        if (v && own(s, v - 1) == GLOBAL)
            markGrey(s, v - 1);
    }
}

void endCycle(ref S s)
{
    s.b[oMark] = s.b[oSkip] = s.b[oGrey] = s.b[oSwept] = 0;
    s.b[oCur] = s.b[oIdx] = s.b[oGidx] = s.b[oHs] = 0;
    s.b[oScn .. oScn + NT * NC] = 0;
    s.b[oPhase] = IDLE;
}

bool allContextsScanned(in S s)
{
    foreach (i; 0 .. NT * NC)
        if (s.b[oScn + i] != 2)
            return false;
    return true;
}

/// STW-2: flush buffers, finish tracing. Sweeping starts afterwards.
void remark(ref S s)
{
    foreach (t; 0 .. NT)
        flush(s, t);
    if (s.b[oCur])
    {
        traceFields(s, s.b[oCur] - 1, s.b[oIdx]);
        s.b[oCur] = s.b[oIdx] = 0;
    }
    while (s.b[oGrey])
    {
        int o;
        while (!bit(s.b[oGrey], o)) ++o;
        s.b[oGrey] &= ~(1 << o);
        traceFields(s, o, 0);
    }
    s.b[oPhase] = SWEEPING;
    s.b[oSwept] = 0;
}

// ------------------------------------------------------------ mutator ops

/// Treat a GLOBAL object that appears during a cycle as live for that cycle.
void protectNew(ref S s, int o, bool promoted)
{
    if (s.b[oPhase] == MARKING)
    {
        if (promoted)
        {
            if (!isBug("nopromotegrey"))
                markGrey(s, o);
        }
        else
            s.b[oMark] |= 1 << o; // allocated black
    }
    else if (s.b[oPhase] == SWEEPING && !isBug("sweepnoprotect"))
        s.b[oMark] |= 1 << o;
}

/// publishSlow: promote the local subgraph reachable from `root` in place.
void publish(ref S s, int t, int root)
{
    int[16] work;
    int nw;
    work[nw++] = root;
    while (nw)
    {
        immutable o = work[--nw];
        if (own(s, o) != 2 + t)
            continue;
        s.b[oOwn + o] = GLOBAL;
        protectNew(s, o, true);
        foreach (f; 0 .. NF)
        {
            immutable v = s.b[fi(o, f)];
            if (v) work[nw++] = v - 1;
        }
    }
}

/// globalizeSelf: flip the whole domain to GLOBAL (I6).
void globalizeSelf(ref S s, int t)
{
    foreach (o; 0 .. NO)
        if (own(s, o) == 2 + t)
        {
            s.b[oOwn + o] = GLOBAL;
            if (s.b[oPhase] != IDLE && !isBug("noskip"))
                s.b[oSkip] |= 1 << o; // skipped by this cycle's sweep
        }
}

/// The barrier of RFC section 4.4 without the store itself. With `logSatb` false the SATB logging
/// is left to the write step (see completeStore).
void barrier(ref S s, int t, Loc loc, ubyte v, bool stackAddr, bool logSatb = true)
{
    immutable old = readLoc(s, loc);
    immutable heapSlot = loc.kind == 0;
    immutable slotOwner = heapSlot ? own(s, loc.a) : cast(ubyte) 0;
    immutable me = trackB ? cast(ubyte)(2 + t) : cast(ubyte) 0;

    if (logSatb && s.b[oPhase] == MARKING)
    {
        immutable logIt = heapSlot ? slotOwner != me : true;
        if (logIt)
        {
            if (!isBug("nodelete"))
                bufAdd(s, t, old);
            if (!bit(s.b[oHs], t) && !stackAddr && !isBug("nohybrid"))
                bufAdd(s, t, v);
        }
    }
    if (stackAddr)
        scanBeforeEscape(s, t);
    if (trackB)
    {
        if (stackAddr)
        {
            if (!isBug("noglobalize"))
                globalizeSelf(s, t);
        }
        else if (v && own(s, v - 1) == me)
        {
            if (!(heapSlot && slotOwner == me) && !isBug("nopublish"))
                publish(s, t, v - 1);
        }
    }
}

/// Barrier followed by the store, as one atomic action.
void doStore(ref S s, int t, Loc loc, ubyte v, bool stackAddr)
{
    barrier(s, t, loc, v, stackAddr);
    writeLoc(s, loc, stackAddr ? 0 : v);
    if (stackAddr)
        s.b[oEsc] |= 1 << t;
}

/// With --race: the barrier ran, the write is still pending. Another thread, or the start of a
/// collection cycle, can run between the two steps.
///
/// Plain ordering (the RFC's §4.4 as written): the barrier tests `marking` and logs before the
/// write. A cycle that starts in between is missed: the write then stores a pointer into an
/// already scanned slot with nothing logged.
/// With `--fix=xchg`: the write step is an atomic exchange followed by the `marking` test, so it
/// logs the value it really overwrote, and a cycle cannot start unnoticed.
void startStore(ref S s, int t, Loc loc, ubyte v)
{
    barrier(s, t, loc, v, false, !fixXchg);
    s.b[oPendL + t] = cast(ubyte)(locId(loc) + 1);
    s.b[oPendV + t] = v;
}

void completeStore(ref S s, int t)
{
    immutable loc = locFromId(s.b[oPendL + t] - 1);
    immutable v = s.b[oPendV + t];
    if (fixXchg && s.b[oPhase] == MARKING)
    {
        immutable heapSlot = loc.kind == 0;
        immutable me = trackB ? cast(ubyte)(2 + t) : cast(ubyte) 0;
        if (heapSlot ? own(s, loc.a) != me : true)
        {
            if (!isBug("nodelete"))
                bufAdd(s, t, readLoc(s, loc));
            if (!bit(s.b[oHs], t) && !isBug("nohybrid"))
                bufAdd(s, t, v);
        }
    }
    writeLoc(s, loc, v);
    s.b[oPendL + t] = 0;
    s.b[oPendV + t] = 0;
}

/// Visibility rule (found by this model): a stack must be scanned before another
/// thread can read it. Without it, a scanned thread can copy a pointer out of an
/// unscanned stack, and the owner then overwrites the slot with an unbarriered
/// local store, so no scan ever sees the pointer.
void scanBeforeEscape(ref S s, int t)
{
    if (s.b[oPhase] == MARKING && !bit(s.b[oHs], t) && !isBug("noescapescan"))
        handshake(s, t);
}

/// Local collection: free LOCAL(t) objects not reachable from any of t's contexts.
void localGC(ref S s, int t)
{
    ubyte live;
    int[16] work;
    int nw;
    void visit(ubyte r)
    {
        if (r && own(s, r - 1) == 2 + t && !bit(live, r - 1))
        {
            live |= 1 << (r - 1);
            work[nw++] = r - 1;
        }
    }
    foreach (c; 0 .. NC)
        foreach (i; 0 .. NS)
            visit(s.b[sc(t, c, i)]);
    ubyte[2] rr;
    foreach (r; rr[0 .. regRoots(s, t, rr)])
        visit(r);
    while (nw)
    {
        immutable o = work[--nw];
        foreach (f; 0 .. NF)
            visit(s.b[fi(o, f)]);
    }
    foreach (o; 0 .. NO)
        if (own(s, o) == 2 + t && !bit(live, o))
            freeObj(s, o);
}

// ------------------------------------------------------------ transitions

alias Emit = void delegate(ref S c, lazy string d);
__gshared bool emitGc; // true while the collector's successors are being enumerated
__gshared int emitKind; // 1 while a stack-address escape is being emitted (the random mode makes it rare)
__gshared int escapeOdds = 64; // random mode: an escape is considered once in this many times

void successors(in S s0, scope Emit emit)
{
    immutable ph = phase(s0);
    immutable allHs = cast(ubyte)((1 << NT) - 1);

    // ---- collector
    emitGc = true;
    if (ph == IDLE)
    {
        S c = s0;
        c.b[oPhase] = MARKING;
        // Stacks that other threads can already read are scanned in this pause, all contexts.
        if (!isBug("nostw1scan"))
            foreach (t; 0 .. NT)
                if (bit(c.b[oEsc], t))
                {
                    handshake(c, t);
                    foreach (k; 0 .. NC)
                    {
                        scanSlots(c, t, k);
                        c.b[oScn + t * NC + k] = 2;
                    }
                }
        emit(c, "GC: start cycle (STW-1)");
    }
    else if (ph == MARKING)
    {
        if (s0.b[oGidx] < NG)
        {
            S c = s0;
            immutable r = c.b[oGlb + c.b[oGidx]];
            if (r && own(c, r - 1) == GLOBAL)
                markGrey(c, r - 1);
            ++c.b[oGidx];
            emit(c, format("GC: scan global G%s", s0.b[oGidx]));
        }
        foreach (t; 0 .. NT)
        {
            if (!bit(s0.b[oHs], t))
            {
                S c = s0;
                handshake(c, t);
                emit(c, format("GC: handshake T%s", t));
            }
            if (s0.b[oBuf + t])
            {
                S c = s0;
                flush(c, t);
                emit(c, format("GC: flush SATB buffer of T%s", t));
            }
            // Suspended fibers: a worker claims one, then scans it.
            foreach (k; 0 .. NC)
            {
                if (k == s0.b[oCtx + t]) continue;
                immutable st = s0.b[oScn + t * NC + k];
                if (st == 0)
                {
                    S c = s0;
                    c.b[oScn + t * NC + k] = 1;
                    emit(c, format("GC: claim fiber T%s.c%s", t, k));
                }
                else if (st == 1)
                {
                    S c = s0;
                    scanSlots(c, t, k);
                    c.b[oScn + t * NC + k] = 2;
                    emit(c, format("GC: finish scan of fiber T%s.c%s", t, k));
                }
            }
        }
        if (!s0.b[oCur])
        {
            foreach (o; 0 .. NO)
                if (bit(s0.b[oGrey], o))
                {
                    S c = s0;
                    c.b[oGrey] &= ~(1 << o);
                    c.b[oCur] = cast(ubyte)(o + 1);
                    c.b[oIdx] = 0;
                    emit(c, format("GC: pick grey O%s", o));
                }
        }
        else
        {
            S c = s0;
            immutable o = c.b[oCur] - 1;
            immutable v = c.b[fi(o, c.b[oIdx])];
            if (v && own(c, v - 1) == GLOBAL)
                markGrey(c, v - 1);
            if (++c.b[oIdx] == NF)
                c.b[oCur] = c.b[oIdx] = 0;
            emit(c, format("GC: trace O%s.f%s -> %s", o, s0.b[oIdx], refStr(v)));
        }
        if (s0.b[oGidx] == NG && s0.b[oHs] == allHs && allContextsScanned(s0))
        {
            S c = s0;
            remark(c);
            emit(c, "GC: remark (STW-2), start sweep");
        }
    }
    else // SWEEPING
    {
        foreach (o; 0 .. NO)
            if (!bit(s0.b[oSwept], o))
            {
                S c = s0;
                c.b[oSwept] |= 1 << o;
                if (own(c, o) == GLOBAL && !bit(c.b[oMark], o) && !bit(c.b[oSkip], o))
                    freeObj(c, o);
                emit(c, format("GC: sweep O%s", o));
            }
        if (s0.b[oSwept] == cast(ubyte)((1 << NO) - 1))
        {
            S c = s0;
            endCycle(c);
            emit(c, "GC: end of cycle");
        }
    }

    // ---- mutators
    emitGc = false;
    foreach (t; 0 .. NT)
    {
        immutable ubyte me = cast(ubyte)(2 + t);

        // A store whose barrier ran but whose write has not happened: only that can happen next.
        if (s0.b[oPendL + t])
        {
            S c = s0;
            immutable l = locFromId(s0.b[oPendL + t] - 1);
            completeStore(c, t);
            emit(c, format("T%s: write %s = %s", t, locStr(l), refStr(s0.b[oPendV + t])));
            continue;
        }

        // allocate into slot i
        int free = -1;
        foreach (o; 0 .. NO)
            if (own(s0, o) == FREE) { free = o; break; }
        if (free >= 0)
            foreach (i; 0 .. NS)
            {
                S c = s0;
                immutable local = trackB && !bit(c.b[oEsc], t);
                c.b[oOwn + free] = local ? me : GLOBAL;
                if (!local)
                    protectNew(c, free, false);
                c.b[cs(c, t, i)] = cast(ubyte)(free + 1);
                emit(c, format("T%s: s%s = new O%s (%s)", t, i, free, local ? "local" : "global"));
            }

        foreach (i; 0 .. NS)
        {
            if (s0.b[cs(s0, t, i)])
            {
                S c = s0;
                c.b[cs(c, t, i)] = 0;
                emit(c, format("T%s: s%s = null", t, i));
            }
            foreach (j; 0 .. NS)
                if (i != j && s0.b[cs(s0, t, j)] != s0.b[cs(s0, t, i)])
                {
                    S c = s0;
                    c.b[cs(c, t, i)] = s0.b[cs(s0, t, j)];
                    emit(c, format("T%s: s%s = s%s", t, i, j));
                }
        }

        // switch to another fiber; an unscanned one is scanned first (FiberBase.switchIn)
        foreach (k; 0 .. NC)
        {
            if (k == s0.b[oCtx + t] || s0.b[oScn + t * NC + k] == 1) continue; // a worker is scanning it: wait
            S c = s0;
            if (c.b[oPhase] == MARKING && c.b[oScn + t * NC + k] == 0 && !isBug("nofiberscan"))
            {
                scanSlots(c, t, k);
                c.b[oScn + t * NC + k] = 2;
            }
            c.b[oCtx + t] = cast(ubyte) k;
            emit(c, format("T%s: switch to fiber c%s", t, k));
        }

        // locations thread t can reach
        Loc[40] locs;
        int nl;
        ubyte heldMask;
        foreach (i; 0 .. NS)
            if (s0.b[cs(s0, t, i)])
                heldMask |= 1 << (s0.b[cs(s0, t, i)] - 1);
        foreach (o; 0 .. NO)
            if (bit(heldMask, o) && own(s0, o) != FREE)
                foreach (f; 0 .. NF)
                    locs[nl++] = Loc(0, o, f);
        foreach (g; 0 .. NG)
            locs[nl++] = Loc(1, g, 0);
        foreach (u; 0 .. NT)
            if (bit(s0.b[oEsc], u))
                foreach (k; 0 .. NC * NS)
                    if (!(u == t && k / NS == s0.b[oCtx + t]))
                        locs[nl++] = Loc(2, u, k);

        foreach (l; locs[0 .. nl])
        {
            // load into slot i
            foreach (i; 0 .. NS)
            {
                immutable v = readLoc(s0, l);
                if (v != s0.b[cs(s0, t, i)])
                {
                    S c = s0;
                    c.b[cs(c, t, i)] = v;
                    emit(c, format("T%s: s%s = %s  (= %s)", t, i, locStr(l), refStr(v)));
                }
            }
            // store from slot j (j may hold null)
            foreach (j; 0 .. NS)
            {
                immutable v = s0.b[cs(s0, t, j)];
                if (v == readLoc(s0, l) && !race)
                    continue;
                S c = s0;
                if (race)
                {
                    startStore(c, t, l, v);
                    emit(c, format("T%s: barrier for %s = s%s  (%s)", t, locStr(l), j, refStr(v)));
                }
                else
                {
                    doStore(c, t, l, v, false);
                    emit(c, format("T%s: %s = s%s  (%s)", t, locStr(l), j, refStr(v)));
                }
            }
            // publish the address of own stack into this location
            if (!bit(s0.b[oEsc], t))
            {
                S c = s0;
                doStore(c, t, l, 0, true);
                emitKind = 1;
                emit(c, format("T%s: %s = &stack(T%s)", t, locStr(l), t));
                emitKind = 0;
            }
        }

        if (trackB)
        {
            S c = s0;
            localGC(c, t);
            emit(c, format("T%s: local collection", t));
        }
    }
}

// ------------------------------------------------------------ invariants

/// Returns null if all invariants hold, otherwise a description.
///
/// I1 and memory safety are checked on what is reachable from the roots (every
/// context of every thread, and the globals). A dead object that has not been
/// swept yet can hold a stale pointer into memory that was freed and reused;
/// that is normal for a tracing collector and harmless because nothing traces
/// or reads it again. (RFC verifier 5.9 also only walks live objects.)
string check(in S s)
{
    ubyte seen;
    int[16] work;
    int nw;
    string viol;

    // `thread` is the thread whose private area holds the place, or -1.
    void visit(ubyte r, int thread, lazy string where)
    {
        if (!r || viol !is null) return;
        immutable o = r - 1;
        immutable ow = own(s, o);
        if (ow == FREE)
        {
            viol = format("use-after-free: %s points to freed O%s", where, o);
            return;
        }
        if (ow >= 2 && ow - 2 != thread)
        {
            viol = format("I1: %s points to unpublished O%s of T%s", where, o, ow - 2);
            return;
        }
        if (!bit(seen, o)) { seen |= 1 << o; work[nw++] = o; }
    }

    foreach (u; 0 .. NT)
    {
        foreach (k; 0 .. NC * NS)
            visit(s.b[sflat(u, k)], u, locStr(Loc(2, u, k)));
        ubyte[2] rr;
        foreach (r; rr[0 .. regRoots(s, u, rr)])
            visit(r, u, format("registers of T%s", u));
    }
    foreach (g; 0 .. NG)
        visit(s.b[oGlb + g], -1, format("global G%s", g));
    while (nw && viol is null)
    {
        immutable o = work[--nw];
        immutable ow = own(s, o);
        foreach (f; 0 .. NF)
            visit(s.b[fi(o, f)], ow >= 2 ? ow - 2 : -1, format("O%s.f%s", o, f));
    }
    if (viol) return viol;

    // I6: an escaped stack means no local domain.
    foreach (t; 0 .. NT)
        if (bit(s.b[oEsc], t))
            foreach (o; 0 .. NO)
                if (own(s, o) == 2 + t)
                    return format("I6: stack of T%s escaped but O%s is still local", t, o);

    // Freed objects hold nothing; collector bookkeeping never names a freed object.
    foreach (o; 0 .. NO)
        if (own(s, o) == FREE)
        {
            foreach (f; 0 .. NF)
                if (s.b[fi(o, f)])
                    return format("freed O%s still has a field value", o);
            if (bit(s.b[oGrey], o) || bit(s.b[oMark], o))
                return format("collector state refers to freed O%s", o);
        }
    return null;
}

// ------------------------------------------------------------ symmetry

/// Relabel objects in order of first reachability from the roots (stacks, then
/// globals), then other live objects, then free ones. Objects are interchangeable
/// names, so isomorphic states collapse to one.
S canonObjects(in S s)
{
    int[8] perm = -1;
    int[8] queue;
    int nq, head, next;
    void visit(ubyte r)
    {
        if (r && perm[r - 1] < 0 && own(s, r - 1) != FREE)
        {
            perm[r - 1] = next++;
            queue[nq++] = r - 1;
        }
    }
    foreach (u; 0 .. NT)
    {
        foreach (k; 0 .. NC * NS)
            visit(s.b[sflat(u, k)]);
        ubyte[2] rr;
        foreach (r; rr[0 .. regRoots(s, u, rr)])
            visit(r);
    }
    foreach (g; 0 .. NG)
        visit(s.b[oGlb + g]);
    while (head < nq)
    {
        immutable o = queue[head++];
        foreach (f; 0 .. NF)
            visit(s.b[fi(o, f)]);
    }
    foreach (o; 0 .. NO)
        if (perm[o] < 0 && own(s, o) != FREE)
            perm[o] = next++;
    foreach (o; 0 .. NO)
        if (perm[o] < 0)
            perm[o] = next++;

    ubyte mapRef(ubyte r) { return r ? cast(ubyte)(perm[r - 1] + 1) : cast(ubyte) 0; }
    ubyte mapMask(ubyte m)
    {
        ubyte r;
        foreach (o; 0 .. NO)
            if (bit(m, o))
                r |= 1 << perm[o];
        return r;
    }

    S c = s;
    foreach (o; 0 .. NO)
    {
        c.b[oOwn + perm[o]] = s.b[oOwn + o];
        foreach (f; 0 .. NF)
            c.b[fi(perm[o], f)] = mapRef(s.b[fi(o, f)]);
    }
    foreach (u; 0 .. NT)
    {
        foreach (k; 0 .. NC * NS)
            c.b[sflat(u, k)] = mapRef(s.b[sflat(u, k)]);
        c.b[oBuf + u] = mapMask(s.b[oBuf + u]);
        // A pending write names a location (field locations name an object) and a value.
        if (s.b[oPendL + u])
        {
            auto l = locFromId(s.b[oPendL + u] - 1);
            if (l.kind == 0) l.a = perm[l.a];
            c.b[oPendL + u] = cast(ubyte)(locId(l) + 1);
            c.b[oPendV + u] = mapRef(s.b[oPendV + u]);
        }
    }
    foreach (g; 0 .. NG)
        c.b[oGlb + g] = mapRef(s.b[oGlb + g]);
    c.b[oMark] = mapMask(s.b[oMark]);
    c.b[oSkip] = mapMask(s.b[oSkip]);
    c.b[oGrey] = mapMask(s.b[oGrey]);
    c.b[oSwept] = mapMask(s.b[oSwept]);
    c.b[oCur] = mapRef(s.b[oCur]);
    return c;
}

/// Relabel threads: new thread P[t] is old thread t.
S permuteThreads(in S s, in int[] P)
{
    S c = s;
    ubyte mapOwner(ubyte ow) { return ow >= 2 ? cast(ubyte)(2 + P[ow - 2]) : ow; }
    foreach (o; 0 .. NO)
        c.b[oOwn + o] = mapOwner(s.b[oOwn + o]);
    c.b[oHs] = c.b[oEsc] = 0;
    foreach (t; 0 .. NT)
    {
        immutable n = P[t];
        foreach (k; 0 .. NC * NS)
            c.b[sflat(n, k)] = s.b[sflat(t, k)];
        c.b[oBuf + n] = s.b[oBuf + t];
        c.b[oCtx + n] = s.b[oCtx + t];
        foreach (k; 0 .. NC)
            c.b[oScn + n * NC + k] = s.b[oScn + t * NC + k];
        if (bit(s.b[oHs], t)) c.b[oHs] |= 1 << n;
        if (bit(s.b[oEsc], t)) c.b[oEsc] |= 1 << n;
        c.b[oPendV + n] = s.b[oPendV + t];
        if (s.b[oPendL + t])
        {
            auto l = locFromId(s.b[oPendL + t] - 1);
            if (l.kind == 2) l.a = P[l.a];
            c.b[oPendL + n] = cast(ubyte)(locId(l) + 1);
        }
        else
            c.b[oPendL + n] = 0;
    }
    return c;
}

__gshared int[][] threadPerms;

void makePerms()
{
    int[] p = new int[](NT);
    foreach (i; 0 .. NT) p[i] = i;
    void rec(int k)
    {
        if (k == NT) { threadPerms ~= p.dup; return; }
        foreach (i; k .. NT)
        {
            auto t = p[k]; p[k] = p[i]; p[i] = t;
            rec(k + 1);
            t = p[k]; p[k] = p[i]; p[i] = t;
        }
    }
    rec(0);
}

/// Smallest representative over all thread permutations (objects renamed after each).
S canon(in S s)
{
    if (NT == 1)
        return canonObjects(s);
    S best = canonObjects(permuteThreads(s, threadPerms[0]));
    foreach (pi; 1 .. threadPerms.length)
    {
        S c = canonObjects(permuteThreads(s, threadPerms[pi]));
        if (memcmp(c.b.ptr, best.b.ptr, USED) < 0)
            best = c;
    }
    return best;
}

// ------------------------------------------------------------ state store

struct Store
{
    ubyte[] data;
    uint[] parent;
    uint[] table;
    size_t n, mask;

    void init()
    {
        table = new uint[](1 << 20);
        table[] = uint.max;
        mask = table.length - 1;
    }

    static ulong hash(const(ubyte)[] d)
    {
        ulong h = 0xcbf29ce484222325UL;
        foreach (x; d)
        {
            h ^= x;
            h *= 0x100000001b3UL;
        }
        h ^= h >> 29; h *= 0xbf58476d1ce4e5b9UL; h ^= h >> 32;
        return h;
    }

    const(ubyte)[] at(size_t i) const { return data[i * USED .. (i + 1) * USED]; }

    void grow()
    {
        auto nt = new uint[](table.length * 2);
        nt[] = uint.max;
        immutable nm = nt.length - 1;
        foreach (i; 0 .. n)
        {
            auto h = hash(at(i)) & nm;
            while (nt[h] != uint.max) h = (h + 1) & nm;
            nt[h] = cast(uint) i;
        }
        table = nt;
        mask = nm;
    }

    /// Returns true if the state was new.
    bool insert(in S c0, uint par)
    {
        immutable S c = canon(c0);
        auto d = c.b[0 .. USED];
        auto h = hash(d) & mask;
        while (table[h] != uint.max)
        {
            if (memcmp(at(table[h]).ptr, d.ptr, USED) == 0)
                return false;
            h = (h + 1) & mask;
        }
        table[h] = cast(uint) n;
        data ~= d;
        parent ~= par;
        ++n;
        if (n * 2 > table.length)
            grow();
        return true;
    }
}

S stateAt(ref Store st, size_t i)
{
    S s;
    memcpy(s.b.ptr, st.at(i).ptr, USED);
    return s;
}

string dump(in S s)
{
    string r;
    foreach (o; 0 .. NO)
    {
        immutable ow = own(s, o);
        if (ow == FREE) continue;
        string flags;
        if (bit(s.b[oMark], o)) flags ~= "M";
        if (bit(s.b[oGrey], o)) flags ~= "g";
        if (bit(s.b[oSkip], o)) flags ~= "k";
        r ~= format("    O%s %s%s ->", o, ow == GLOBAL ? "GLOBAL" : "LOCAL(T" ~ to!string(ow - 2) ~ ")",
                    flags.length ? " [" ~ flags ~ "]" : "");
        foreach (f; 0 .. NF)
            r ~= " " ~ refStr(s.b[fi(o, f)]);
        r ~= "\n";
    }
    foreach (t; 0 .. NT)
    {
        r ~= format("    T%s stack:", t);
        foreach (c; 0 .. NC)
        {
            if (NC > 1) r ~= format(" %s[", c == s.b[oCtx + t] ? "*c" ~ to!string(c) : "c" ~ to!string(c));
            foreach (i; 0 .. NS)
                r ~= " " ~ refStr(s.b[sc(t, c, i)]);
            if (NC > 1) r ~= format(" scan=%s ]", s.b[oScn + t * NC + c]);
        }
        r ~= format("  hs=%s esc=%s buf=%02x", bit(s.b[oHs], t), bit(s.b[oEsc], t), s.b[oBuf + t]);
        if (s.b[oPendL + t])
            r ~= format("  pending write %s = %s", locStr(locFromId(s.b[oPendL + t] - 1)), refStr(s.b[oPendV + t]));
        r ~= "\n";
    }
    r ~= "    globals:";
    foreach (g; 0 .. NG)
        r ~= " " ~ refStr(s.b[oGlb + g]);
    r ~= format("  phase=%s\n", ["idle", "marking", "sweeping"][s.b[oPhase]]);
    return r;
}

void printTrace(ref Store st, size_t bad, string why)
{
    size_t[] path;
    for (size_t i = bad;; i = st.parent[i])
    {
        path ~= i;
        if (i == 0) break;
    }
    writeln("\nVIOLATION: ", why);
    writeln("Shortest trace (", path.length - 1, " steps):");
    writeln("  initial state");
    foreach_reverse (k; 1 .. path.length)
    {
        immutable p = path[k], ch = path[k - 1];
        S ps = stateAt(st, p);
        string found;
        successors(ps, (ref S c, lazy string d) {
            immutable S cc = canon(c);
            if (!found && memcmp(cc.b.ptr, st.at(ch).ptr, USED) == 0)
                found = d;
        });
        writefln("  %2s. %s", path.length - k, found);
        write(dump(stateAt(st, ch)));
    }
}

// ------------------------------------------------------------ randomized walks

struct Rng
{
    ulong s;
    ulong next()
    {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
        return s;
    }
    ulong below(ulong n) { return next() % n; }
}

int swarm()
{
    auto rng = Rng(seed * 0x9E3779B97F4A7C15UL + 1);
    S init0;
    ulong steps, cycles, remarks, publishes, escapes, switches, pending;
    immutable t0 = MonoTime.currTime;
    immutable baseOdds = escapeOdds;
    foreach (walk; 0 .. swarmWalks)
    {
        // Vary how rare escapes are from walk to walk: an escape is permanent for its thread, so
        // walks with rare escapes keep local domains alive for a long time.
        escapeOdds = baseOdds << (2 * cast(int) rng.below(5));
        S s = init0;
        string[64] trail;
        S[64] trailState;
        size_t nt;
        foreach (step; 0 .. walkLen)
        {
            if (auto why = check(s))
            {
                writeln("\nVIOLATION: ", why);
                writefln("walk %s, step %s (seed %s). Last %s actions:", walk, step, seed, nt < 64 ? nt : 64);
                foreach (k; (nt < 64 ? 0 : nt - 64) .. nt)
                {
                    writefln("  %s", trail[k % 64]);
                    write(dump(trailState[k % 64]));
                }
                return 1;
            }
            // Reservoir sampling over collector and mutator successors separately.
            S cg, cm;
            string dg, dm;
            ulong ng, nm;
            successors(s, (ref S c, lazy string d) {
                if (emitGc)
                {
                    ++ng;
                    if (rng.below(ng) == 0) { cg = c; dg = d; }
                }
                else
                {
                    // An escape is permanent for a thread, so unweighted walks escape every thread
                    // within a few steps and never again exercise local domains.
                    if (emitKind == 1 && rng.below(escapeOdds) != 0) return;
                    ++nm;
                    if (rng.below(nm) == 0) { cm = c; dm = d; }
                }
            });
            if (!ng && !nm)
            {
                writeln("DEADLOCK: no successor");
                write(dump(s));
                return 1;
            }
            // The collector has few moves and the mutators many; give the collector a fair share.
            immutable useGc = ng && (!nm || rng.below(100) < 30);
            s = useGc ? cg : cm;
            immutable d = useGc ? dg : dm;
            ++steps;
            if (useGc)
            {
                if (d.length > 14 && d[0 .. 14] == "GC: end of cyc") ++cycles;
                else if (d.length > 10 && d[0 .. 10] == "GC: remark") ++remarks;
            }
            else
            {
                import std.algorithm : canFind;
                if (d.canFind("&stack")) ++escapes;
                else if (d.canFind("switch")) ++switches;
                else if (d.canFind("barrier for")) ++pending;
            }
            trail[nt % 64] = d;
            trailState[nt % 64] = s;
            ++nt;
        }
    }
    writefln("OK: no violation in %s random steps over %s walks (%s completed cycles, %s remarks, %s stack escapes, %s fiber switches, %s two-step stores), %.1fs",
             steps, swarmWalks, cycles, remarks, escapes, switches, pending, (MonoTime.currTime - t0).total!"msecs" / 1000.0);
    return 0;
}

// ------------------------------------------------------------ main

int main(string[] args)
{
    string track = "B";
    auto help = getopt(args,
        "threads", "number of threads (default 2)", &NT,
        "objects", "number of objects (default 4, max 8)", &NO,
        "stack", "stack slots per context (default 2)", &NS,
        "fields", "pointer fields per object (default 1)", &NF,
        "globals", "global slots (default 1)", &NG,
        "fibers", "extra (suspended) fiber contexts per thread (default 0)", &NFB,
        "race", "stores are two steps (barrier, then write) so threads can race on a slot", &race,
        "fix", "with --race: 'xchg' also logs the value the write really overwrites", &fixXchgName,
        "track", "A (SATB only) or B (local domains), default B", &track,
        "bug", "plant a bug: nodelete nohybrid nopublish noglobalize nolocaltrace "
               ~ "nopromotegrey noskip sweepnoprotect noescapescan nostw1scan nofiberscan", &bug,
        "swarm", "random walks instead of exhaustive search: number of walks", &swarmWalks,
        "len", "steps per random walk (default 100000)", &walkLen,
        "seed", "random seed (default 1)", &seed,
        "escape-odds", "random mode: a stack-address escape is considered once in N times (default 64)", &escapeOdds,
        "max-states", "stop after this many states", &maxStates);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("gc_model options:", help.options);
        return 0;
    }
    trackB = track == "B";
    fixXchg = fixXchgName == "xchg";
    layout();
    makePerms();

    writefln("model: track=%s threads=%s objects=%s stack=%s fibers=%s fields=%s globals=%s race=%s%s bug=%s state=%s bytes%s",
             track, NT, NO, NS, NFB, NF, NG, race, fixXchg ? "+xchg" : "", bug.length ? bug : "none", USED,
             swarmWalks ? " (randomized)" : "");

    if (swarmWalks)
        return swarm();

    Store st;
    st.init();
    S init0;
    st.insert(init0, 0);

    immutable t0 = MonoTime.currTime;
    ulong transitions;
    for (size_t i = 0; i < st.n; i++)
    {
        S s = stateAt(st, i);
        if (auto why = check(s))
        {
            printTrace(st, i, why);
            writefln("\nchecked %s states before the violation", i + 1);
            return 1;
        }
        successors(s, (ref S c, lazy string d) {
            ++transitions;
            st.insert(c, cast(uint) i);
        });
        if (st.n > maxStates)
        {
            writefln("stopped: more than %s states (inconclusive)", maxStates);
            return 2;
        }
        if ((i & 0x3fffff) == 0 && i)
            stderr.writefln("  ... %s explored, %s found, %.0fs", i, st.n,
                            (MonoTime.currTime - t0).total!"msecs" / 1000.0);
    }
    writefln("OK: no violation. %s reachable states, %s transitions, %.1fs",
             st.n, transitions, (MonoTime.currTime - t0).total!"msecs" / 1000.0);
    return 0;
}

__gshared string fixXchgName = "";
