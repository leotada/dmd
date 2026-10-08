# RFC: Hybrid TLS-Immix Garbage Collector for the D Programming Language

**Status:** Draft Technical Proposal / Systems Architecture RFC, Revision 3  
**Area:** Runtime (`druntime`), Frontend (`dmd`), Code generation (LDC first, then DMD; GDC is covered by automatic runtime fallback), Memory Management  
**Target:** Modern D. LDC/LLVM is the performance target. The DMD backend is the bring-up and reference compiler. GDC must keep working through automatic runtime fallback.  
**Reviewed against:** `dmd` master `92ac966eeb` (2026-10-07). File references (`path:line`) are relative to the repository root and were checked at that commit.

| Revision | Date | Summary |
|---|---|---|
| 1 | — | Initial proposal: TLAB-based thread-local heaps, Immix shared heap, LDC statepoints, SATB marking. |
| 2 | 2026-10-07 | Checked against the code base. Corrected the thread-locality and barrier model. Added heap invariants, metadata design, a design review (§9) and the complete roadmap with decision gates (§10). |
| 3 | 2026-10-07 | Turned the open questions into decision records tied to the gates (§11). Phase 4 now scans thread and fiber stacks one at a time instead of rescanning them at remark. DMD emits both barriers as correct out-of-line calls. Covered thread exit for attached and main threads. Refined `immutable` routing, `std.parallelism` and finalizer semantics. |
| 3.1 | 2026-10-07 | Phase 0.5 done as an executable model (`plans/model/`). It found that per-thread handshakes are unsound when other threads can read a stack. Added the stack-visibility rule (I5, §4.3, §4.4, ADR-9), sweep-long protection of new objects, and the floating-garbage rule. |

> **What changed in Revision 2 (read this first)**
> 1. **In D, whether data is thread-local is decided at run time, not by the type system.** `immutable` data is implicitly shared. `cast(shared)`, `__gshared`, the lock-then-cast-away-`shared` idiom, closures handed to `Thread`, and `std.parallelism` all move unqualified pointers to other threads. Collecting each thread separately therefore needs a **publication barrier that checks where a pointer is stored**, plus a fail-safe ("globalization"). Checking `shared` qualifiers is not enough (§2.4, §3.4, §4.4).
> 2. **Allocation buffers and thread-local heaps are now separate.** Lock-free per-thread bump allocation into one shared heap (Track A) is low risk and ships first. Thread-local collection domains (Track B) are a research track behind measured go/no-go gates, with explicit kill criteria (§10, Phase 0).
> 3. **Revision 1 misdescribed the current GC.** druntime's GC already has parallel marking, fork-based concurrent marking and an optional precise heap. `symgc`, a port of the SDC GC without a global lock (`gc:sdc`), also exists. Every target is now measured against the best existing configuration (§2.1, §8).
> 4. **Exact stack maps via `gc.statepoint` are now an optional late phase.** For a non-moving collector they cost a lot and buy little. Precise static-data and TLS roots and a precise heap come first (§4.2).
> 5. **The prototype now includes the metadata that druntime's `GC` interface needs.** That is object starts and sizes, attributes, finalization, appendable-array bookkeeping and interior-pointer queries, all missing from Revision 1 (§5).

> **What Revision 3 adds**
> 1. **Decision records (§11).** Each records the decision, a corrected rationale, its consequences, its status, the gate where it is revisited, and the result that would overturn it. Decisions that depend on Phase 0 data stay *provisional* until their gate has run.
> 2. **Pause times no longer grow with the number of threads and fibers (Phase 4.7).**
>    - Thread stacks are scanned one at a time, with Go's hybrid barrier.
>    - Each suspended fiber's stack is scanned before it next runs, or by a background worker.
>    - No stack is rescanned at remark. Revision 2's "rescan stacks" step was both unnecessary under SATB and the pause bottleneck for fiber-heavy programs.
> 3. **DMD emits both barriers as out-of-line calls (§4.5, Phase 4.5).** They are slow but correct, so this repository's CI can test Track B and the reference binaries can enable it.
> 4. **Thread exit is covered for every kind of thread (Phase 5.4).** That includes the main thread and threads attached from C, which `GC.cleanupThread` never sees.
> 5. **Narrower claims.**
>    - Running local finalizers on the owning thread is best effort, not a guarantee.
>    - `immutableGlobal` remains a measured setting.
>    - The `std.parallelism` change promotes the data the workers can reach instead of globalizing the whole domain, which is not the same as keeping the domain isolated.

---

## 1. Executive Summary

This proposal describes the architecture and implementation roadmap for a high-throughput, low-latency garbage collector for D: the **TLS-Immix GC**, selected with `--DRT-gcopt=gc:immix`.

It addresses three structural bottlenecks of druntime's default collector (details and evidence in §2.1):
1. **Allocation contention.** Every GC allocation takes one process-wide spinlock, so allocation throughput collapses as threads are added.
2. **Pauses that grow with the whole heap.** Every collection stops all threads. Marking is parallel but walks the entire live heap. Concurrent marking exists only as the POSIX `fork:1` mode.
3. **Conservative roots.** Stacks, registers, static data and TLS are always scanned conservatively, and the heap is too unless `gc:precise` is set. Integers that look like addresses keep memory alive.

The design is built in two tracks.

**Track A: an Immix heap with per-thread allocation buffers (low risk).**
* The heap is **mark-region (Immix)** and non-moving, with 32 KiB blocks and 128-byte lines.
* Each thread bump-allocates into a private *hole*. This is the thread-local allocation buffer (TLAB). The common allocation path takes no lock. Getting a new block, allocating a large object and starting a collection still need synchronization, which §3.2 keeps cheap and per-block.
* Collection starts as stop-the-world with parallel marking. It becomes concurrent in two steps: fork-based marking on POSIX, then a SATB (snapshot-at-the-beginning) write barrier on all platforms.
* Precise static-data and TLS roots plus a precise heap reduce false retention.
* Objects never move, so slices, interior pointers and pointers handed to C stay valid.

**Track B: thread-local collection domains (research, gated).**
* Blocks are owned by threads. A thread can collect its own domain without stopping any other thread.
* That is only safe while this invariant holds: *no memory outside a thread's domain points to that thread's unpublished objects*.
* D's type system cannot guarantee the invariant. So the compiler emits a **publication barrier** on heap pointer stores, which promotes objects *in place* when they escape.
* Whenever the runtime cannot prove the invariant, it falls back to **globalizing** the whole domain.
* Track B is built only if Phase 0 shows that its barrier cost and escape rate are acceptable.

**Exact stack maps** (`llvm.experimental.gc.statepoint` in LDC) are an optional late phase. They are pursued only if measurements show that stack-induced retention matters, or if opt-in defragmentation needs fewer pinned objects.

**Non-goals.**
* Moving objects by default.
* Changing D's language semantics.
* Requiring changes to programs that follow the existing GC rules in `spec/garbage.dd`.

Track B adds exactly one documented rule: handing a GC pointer to another thread *through foreign code* requires `GC.addRoot` or the new `GC.publish`. This extends the existing foreign-code rule in `spec/garbage.dd` (section `gc_foreign_obj`).

---

## 2. Motivation and D-Specific Design Constraints

### 2.1 The current druntime GC (verified)

The default collector always scans stacks, registers, static data and TLS conservatively. It scans the heap conservatively by default and precisely with `gc:precise`. It is **not** a purely synchronous collector: marking is parallel by default, and on POSIX it can run concurrently in a forked child. Its real limits are the global allocation lock, pauses that grow with the whole live heap, and conservative roots.

| Property | Current state | Evidence |
|---|---|---|
| Allocation path | One process-wide spinlock around every `malloc`/`qalloc`/`calloc` | `ConservativeGC.gcLock` at `druntime/src/core/internal/gc/impl/conservative/gc.d:164`; `runLocked!(mallocNoSync, …)` at `gc.d:502,559,613` |
| Size classes | Segregated bins per page; an object's size is implied by its page's bin | `smallAlloc` at `gc.d:2198` |
| Marking | Stop-the-world; parallel by default (`parallel:N`, default "up to cores − 1") | `version = COLLECT_PARALLEL` at `gc.d:34`; `markParallel` at `gc.d:3605`; `parallel = 99` in `druntime/src/core/gc/config.d` |
| Concurrent marking | Optional on POSIX (`fork:1`): marking runs in a `clone`/`fork` child | `version = COLLECT_FORK` at `gc.d:37`; `markFork` at `gc.d:3204` |
| Heap precision | Conservative by default. Precise with `gc:precise`, using a per-word pointer bitmap copied from `RTInfo` | registration at `gc.d:117-136`; `is_pointer` at `gc.d:3869` |
| Root precision | Always conservative. Whole writable `PT_LOAD` segments are registered as untyped ranges | `druntime/src/rt/sections_elf_shared.d:809`; `druntime/src/rt/memory.d:23` |
| Thread scanning | All stack contexts (threads and fibers) are in one global list | `druntime/src/core/thread/threadbase.d:1182` |
| Pluggability | `registerGCFactory(name, factory, threadInit)` is called from a `pragma(crt_constructor)`; the GC is selected with `--DRT-gcopt=gc:<name>` | `druntime/src/core/gc/registry.d`; `gc.d:117-136` |
| Per-thread GC hooks | `GC.initThread` / `GC.cleanupThread`, and a per-thread GC slot `ThreadBase.tlsGCData` | `druntime/src/core/gc/gcinterface.d:286,300`; `threadbase.d:128` |

How long pauses actually are ("hundreds of milliseconds") depends on heap size, thread count and options. Phase 0 measures them before any targets are fixed.

### 2.2 Why conventional moving/copying collectors fail in D

Mainstream runtimes such as the JVM and the .NET CLR rely on copying or compacting generational collectors. In D a fully moving collector is impractical:
* **Interior pointers and native slices.** A slice is `struct Slice { size_t length; T* ptr; }`, and `arr[10 .. 20]` points into the middle of an allocation. Moving an object means finding and rewriting every interior reference to it.
* **Ambiguous roots.** Stacks, registers, static data and TLS are scanned conservatively. A word that *might* be a pointer cannot be rewritten, so any object it points to cannot move (it is *pinned*).
* **C interoperability (`ImportC`, `extern(C)`).** Pointers handed to C cannot be updated. `GC.BlkAttr.NO_MOVE` exists (`druntime/src/core/memory.d:326`), but the ecosystem assumes the GC never moves anything. Relocation can therefore only ever be opt-in (Phase 7).

### 2.3 D's thread-local default: what it does and does not guarantee

Module-level and `static` variables are thread-local unless declared `shared` or `__gshared`.

**Heap objects, however, have no owning thread in the type system.** An unqualified type means "not shared *through this reference*", and only if the code is `@safe` and its casts are honest. It does not mean "allocated for one thread and reachable only from it".

The current collector ignores thread-locality and treats all memory as one heap behind one lock. That wastes the information, but it is also why the current collector needs no barriers.

### 2.4 Escape channels: how unqualified data reaches other threads

A thread-local heap is sound only if every channel below is covered. None of them is caught by checking `shared` qualifiers at compile time.

| # | Channel | Example | Handling in this design |
|---|---|---|---|
| 1 | `immutable` is implicitly shared | `immutable s = buildPure(); send(tid, s);`, `.idup`, `assumeUnique` | `immutable` allocations go to the global domain by default; the publication barrier covers the rest |
| 2 | Casting to `shared` | `auto s = cast(shared) obj;`, stored where another thread reads it | The barrier fires on the store into the shared location |
| 3 | Locking, then casting away `shared` | `synchronized (m) { (cast(Queue) q).push(new Node); }` | **The barrier checks the target's address, not its static type** |
| 4 | `__gshared` globals | `__gshared Foo g; g = new Foo;` | The target is in the data segment, so it is non-local: publish |
| 5 | Closures and `Thread` | `new Thread({ use(local); }).start();`. The closure comes from `_d_allocmemory` (`druntime/src/rt/lifetime.d:69`), and the parent creates the `Thread` object | `Thread.start` publishes `this` and its delegate context |
| 6 | Stack addresses escaping | `parallel` foreach hands the caller's stack frame (the delegate context) to worker threads; `&local` stored globally | The barrier sees a stack address as the stored value: **globalize** the domain (§3.4) |
| 7 | Work queues and result arrays | `foreach (i, ref r; parallel(results)) r = format(...);`: a worker's allocation is stored into the caller's array | Barrier: the target is not in the worker's domain |
| 8 | Hand-off through C | `pthread_create(..., cast(void*) obj)`, `void* userData` callbacks, lock-free queues of `size_t` | No barrier can see this, so it becomes a documented rule: use `GC.addRoot` (which publishes) or `GC.publish` |
| 9 | Atomics | `atomicStore(sharedPtr, p)`, `cas(&head, old, p)` | `core.atomic` pointer operations call the barrier explicitly |
| 10 | Raw copies | `memcpy` of structs that contain pointers (allowed "with extreme caution" by `spec/garbage.dd`) | Bulk barrier in druntime's copy hooks. A raw libc `memcpy` that publishes a local pointer is documented UB |
| 11 | Fiber migration | Resuming a `Fiber` on another thread | Already documented as unsafe (`druntime/src/core/thread/fiber/package.d:1163`). Fibers record an owner, and migration globalizes |
| 12 | Thread exit | `Thread.join` rethrows an exception allocated by the thread that just exited | The domain is globalized at thread exit |

### 2.5 Prior art and lessons

* **Immix** (Blackburn & McKinley, PLDI 2008) introduced blocks, lines and opportunistic evacuation. It assumes every object has a header, as in Java. **D objects have no GC header.** The size, attribute and type information Immix reads from headers must therefore come from side metadata (§5). That is a real cost on every allocation, and Revision 1 left it out.
* **Conservative Immix** (Shahriyar, Blackburn & McKinley, "Fast Conservative Garbage Collection", OOPSLA 2014) pins objects that ambiguous roots point to, and filters ambiguous pointers through an object map. It found conservative root scanning cheap, which supports keeping conservative stacks (§4.2).
* **LXR** (Zhao, Blackburn & McKinley, PLDI 2022) combines Immix, reference counting and SATB marking for low latency. It is a possible later evolution of Track A.
* **Thread-local heaps for Java** (Domani et al., ISMM 2002) used a per-object "global" bit and a write barrier that detects escapes at run time. It is the closest ancestor of Track B.
* **GHC local heaps** (Marlow & Peyton Jones, ISMM 2011) promote objects when they are published, through a write barrier. They rely on a precise, *moving* runtime.
* **OCaml 5** (Sivaramakrishnan et al., "Retrofitting Parallelism onto OCaml", ICFP 2020) chose stop-the-world parallel minor collections over concurrent per-domain ones. The concurrent design needed a read barrier and broke assumptions in the C API.
* **Go's Request-Oriented Collector** (2016) had an always-on publication barrier. It was abandoned largely because of that barrier's cost (R. Hudson, "Getting to Go", ISMM 2018 keynote).
* **Nim** moved from thread-local `refc` heaps to a shared heap with ARC/ORC as the default in 2.0. **Kotlin/Native** moved from strict thread confinement to a new memory model, the default since 1.7.20. Both left thread-isolated heaps for usability reasons.
* **D:** the fork-based concurrent GC (`fork:1`), the precise GC (`gc:precise`), and **symgc**, a port of the SDC GC with no global lock (`gc:sdc`, on code.dlang.org since 2025).

**Lesson.** Thread-local collection has repeatedly lost out to barrier cost and to friction for API users. Revision 2 therefore requires Track B to pass measured gates in Phase 0, and keeps Track A worthwhile on its own.

---

## 3. System Architecture: TLS-Immix

```
┌────────────────────────────────────────────────────────────────────────┐
│ PER-THREAD STATE (Track A)                                             │
│  [ Thread 1 ]                         [ Thread 2 ]                     │
│  AllocBuffers (one hole per kind)     AllocBuffers (one hole per kind) │
│  SATB buffer, barrier state           SATB buffer, barrier state       │
├────────────────────────────────────────────────────────────────────────┤
│ THREAD-LOCAL DOMAINS (Track B, gated)                                  │
│  Domain T1: blocks owned by T1        Domain T2: blocks owned by T2    │
│  local GC scans T1's roots only       local GC never stops T1          │
│  escaped objects stay in place        escaped objects stay in place    │
└────────────────────────────────────────────────────────────────────────┘
                 │ publication barrier: in-place promotion (escaped bit)
                 │ globalization: flip all block owners to GLOBAL
                 ▼
┌────────────────────────────────────────────────────────────────────────┐
│ GLOBAL IMMIX SPACE + LARGE OBJECT SPACE                                │
│  - 32 KiB blocks / 128 B lines, bump allocation into holes             │
│  - global cycle: STW roots -> concurrent SATB mark -> remark -> sweep  │
│  - non-moving: slices, interior pointers and C pointers stay valid     │
├────────────────────────────────────────────────────────────────────────┤
│ SIDE METADATA (one VA reservation, never inside blocks)                │
│  block owner/kind/state, line liveness, object start/end bits,         │
│  local + global mark bits, escaped bits, finalize bits,                │
│  precise pointer bitmap                                                │
└────────────────────────────────────────────────────────────────────────┘
```

### 3.1 Layer 0: Heap reservation and side metadata
* **One reservation.** On 64-bit targets, one contiguous virtual-address reservation (configurable `heapReserve`, committed lazily) holds every Immix block and the large-object space. Checking "is this a GC pointer, and in which block?" then costs a subtraction, a compare and a shift. Conservative scanning and both barriers (§4.3, §4.4) depend on this.
* **Side tables only.** All per-block and per-object metadata lives in side tables indexed by block or granule number (§5). Nothing is stored at the start of a block. All 256 lines stay usable, and block headers no longer collide in the same cache sets every 32 KiB.
* **32-bit targets** fall back to a chunk lookup table in the style of `pooltable.d`. Track B is 64-bit only.

### 3.2 Layer 1: Per-thread allocation buffers (TLABs)
* **Structure.** Threads register through `initThread`/`cleanupThread`, or through the registry's `threadInit` hook if they start before the GC is initialized. Each registered thread owns a small set of `AllocBuffer`s, one per *block kind*: scan, no-scan and finalizable. Under Track B there is one set for the local domain and one for the global domain. Each buffer has exclusive use of one block and bump-allocates into its current hole.
* **Allocation path.**
  * A non-atomic pointer increment.
  * Setting the object-start and object-end bits. These live in side-bitmap words that belong to the same block, so no atomics are needed.
  * In precise mode, also copying the type's pointer bitmap.
* **When a hole or block runs out (the slow path),** synchronization is still needed, and is kept short:
  * Free and recyclable blocks come from a lock-free block pool: a tagged Treiber stack, sharded per CPU or NUMA node.
  * The LOS has its own lock.
  * A collection is started with a single atomic compare-and-swap on the collection state.

  The goal is that no lock is ever held while scanning or allocating objects. It is not a lock-free allocator end to end.
* **A TLAB is an allocation mechanism, not a collection domain.** Under Track A all blocks form one logical heap, collected by one collector. Only Track B adds per-thread collection.

### 3.3 Layer 2: Immix mark-region space
* **Block and line layout.** 32 KiB naturally aligned blocks, 128-byte lines (256 per block) and 16-byte granules, which is D's default GC alignment.
* **Size classes.**
  * *Small* objects (≤ 128 B) are bump-allocated with *conservative line marking*, as in the Immix paper. A small object marks only its first line, and the allocator treats the first free line after a live line as possibly occupied.
  * *Medium* objects (128 B to 8 KiB) mark every line they span. A medium object that does not fit the current hole goes to a per-thread *overflow block*, so holes are not skipped.
  * *Large* objects (≥ 8 KiB) go to a page-granular **large object space (LOS)** inside the same reservation. So do `NO_INTERIOR` requests and alignments above 4 KiB. Under Track B, large objects are always global.
* **Hole allocation.** After a collection, runs of free lines form *holes*. Blocks are classified as *free*, *recyclable* (has holes) or *full*. The allocator bump-allocates through a hole until `cursor + size > limit`, then moves to the next hole or block.
* **Ambiguous-pointer validity.** After every collection, the object-start bitmap is reconciled with the mark bitmap, so dead objects inside live lines stop being valid targets. Otherwise a stale conservative pointer could bring back an object whose referents were already reclaimed.
* **Finalization.** A mark-region collector never visits dead objects. Finalizable objects (`FINALIZE`, `STRUCTFINAL`) are therefore allocated from *finalizable* blocks that carry a finalize bitmap. The sweep walks those bits and calls `rt_finalizeFromGC` (`druntime/src/rt/lifetime.d:529`).
* **Non-moving.** Surviving objects never change address. Interior pointers, sub-slices and pointers held by C stay valid across collections. The only relocation is the opt-in defragmentation of Phase 7, which never moves pinned objects.

### 3.4 Layer 3: Thread-local collection domains (Track B)
* **Ownership.** Every block has an owner code in the side block table: `FREE`, `GLOBAL`, `local(T)` or `mixed(T)`. A *mixed* block is a local block holding at least one escaped object. Each escaped object has its **escaped bit** set.
* **Publication (in-place promotion).** The barrier (§4.4) can see a pointer to an unescaped object of thread *T* being stored into a slot that *T* does not own. When it does, *T* marks that object, and everything it reaches, as escaped. **Nothing moves.** The blocks involved become *mixed*, so later stores into or out of them take the barrier's slow path. If promotion exceeds a work budget, *T* stops and globalizes instead.
* **Globalization (the fail-safe).** Every block of *T*'s domain is switched to `GLOBAL`. This takes time proportional to the number of blocks and is always safe, because afterwards no local objects exist. It happens:
  * at thread exit;
  * when a stack address is published;
  * on fiber migration;
  * when a D module compiled without barriers is `dlopen`ed;
  * when the promotion budget runs out;
  * when the verifier fails.
* **Local collection.** *T* collects its own domain when its local allocation reaches a threshold. The roots are *T*'s registers, its own stack contexts (its main stack and the fibers it owns) and its TLS block.
  * **No other thread is suspended.**
  * The global data segment is not scanned: invariant I1 guarantees it holds no pointers to *T*'s unpublished objects.
  * It frees only unescaped objects, and runs their finalizers on *T*. That is best effort, not a guarantee: an object that escapes is finalized by a global cycle on another thread (ADR-5).
* **Global collection.** It traces global and escaped objects. Instead of one global stop-the-world, each thread contributes its roots in a short per-thread *handshake*, including pointers from its local domain to global objects.

### 3.5 Heap invariants (normative)

Every implementation phase must preserve these invariants. Phase 0 model-checks them.

* **I1 — No outside pointers to unpublished objects.** Nothing outside thread *T*'s stacks, registers, TLS and local or mixed blocks points to an unescaped object of *T*. "Outside" includes global blocks, other threads' blocks, the data segment, the C heap and registered ranges.
* **I2 — Only the owner changes a block.** Only the owner thread allocates into its blocks, promotes objects in them, and changes their allocation metadata (holes, line liveness, start/end bits). Other threads only read side metadata. Global markers set bits in a *separate* global mark bitmap, with atomic OR.
* **I3 — Non-moving.** No object is relocated unless `defrag:1` is enabled and the object is unpinned (Phase 7).
* **I4 — A line is free only if nothing on it is live.** A line in a local or mixed block is reused only if both of these hold:
  * no object on it is live according to the owner's last local mark;
  * no escaped object on it is live according to the most recent *completed* global cycle that started after the object escaped.
* **I5 — Snapshot-at-the-beginning, one stack at a time (both tracks).** During a global cycle, every object reachable when the cycle starts gets marked. This holds even though stacks are captured one at a time rather than all at once. Specifically:
  * **Deletion barrier (Yuasa).** For every barriered pointer store, the barrier logs the old value. The exceptions are stores into the current stack and, under Track B, stores into the thread's own purely local blocks. This covers heap slots, global data, TLS, and other threads' or fibers' stacks.
  * **Hybrid barrier until the handshake (Go style).** Until a thread's stack has been scanned at its handshake, its barriered stores also log the *new* value.
  * **Suspended fibers.** A fiber's stack is scanned before the fiber runs again. Code that writes into a suspended fiber's stack through a pointer is covered by the deletion barrier above.
  * **Stack visibility (found by the Phase 0 model).** A stack is scanned before any other thread can read it. A scanned thread could otherwise copy a pointer out of an unscanned stack, after which the owner overwrites the slot with an unbarriered local store, and no scan ever sees the pointer. The rule has two parts:
    * the escape barrier (`_d_gc_stackEscaped`, §4.4) makes the thread scan its own stack first when a cycle is running and the stack has not been scanned yet;
    * STW-1 scans, as one group, every stack already flagged `stackVisible`.
  * **New objects.** Objects allocated during the cycle count as live immediately ("black"). Objects promoted during the cycle (Track B) are queued for scanning ("grey"). This protection lasts until the cycle's **sweep has finished**, not just until remark: with a lazy sweep, an object allocated or promoted after remark but before its block is swept would otherwise be freed.
  * **Globalized blocks.** Blocks globalized during the cycle (Track B) are skipped by that cycle's sweep.
  * **Floating garbage.** A dead global object can hold a stale pointer into memory that was freed and reused. The marker follows a pointer only if the target block's owner is `GLOBAL`; it ignores free and local blocks. I1 is checked on live objects only, as the verifier of Phase 5.9 does.
  * **No stack is ever rescanned.** Remark only drains the SATB buffers.
* **I6 — Fail-safe.** Whenever the runtime cannot establish I1, it globalizes the affected domain(s) before continuing.

---

## 4. Compiler Modifications (Frontend + LDC / DMD)

### 4.1 Allocation routing: use the existing lowering hooks

The frontend already lowers every GC allocation to a druntime template hook. Routing therefore needs **no new hooks**. It only needs the qualifier information that some hooks strip today:

| Allocation | Hook today | Can the hook see `shared`/`immutable`? | Change |
|---|---|---|---|
| `new C(...)` | `_d_newclassT!T` (`druntime/src/core/lifetime.d:2641`) | Yes: only `inout` is stripped (`compiler/src/dmd/expressionsem.d:7033`) | `static if (is(T == shared) \|\| is(T == immutable))` → global domain |
| `new S`, `new int` | `_d_newitemT!T` (`lifetime.d:2723`) | No: `shared`/`immutable` are stripped to limit instantiations (`expressionsem.d:6621`) | Add a `bool isShared` runtime argument, as `_d_newarrayT` has |
| `new T[](n)` | `_d_newarrayT!T(n, isShared)` → `_d_newarrayU` | `isShared` is computed (`expressionsem.d:7217`) but dropped before `__arrayAlloc` (`druntime/src/core/internal/array/construction.d:369-388`); it does not include `immutable` | Pass the flag through; include `immutable` in it |
| `new T[][](n, m)` | `_d_newarraymTX` | `isShared` is passed (`expressionsem.d:7251`) | Pass the flag through |
| `[a, b, c]` | `_d_arrayliteralTX` | No: stripped (`expressionsem.d:5362`) | Add the flag |
| Closures | `_d_allocmemory(sz)` → `GC.malloc(sz)`, untyped (`druntime/src/rt/lifetime.d:69`) | n/a | Stay local; Phase 3 may add typed closure frames |
| `~`, `~=`, `.length =`, `.dup`/`.idup` | `_d_arraycatnTX`, `_d_arrayappendT`/`_d_arrayappendcTX`, `_d_arraysetlengthT`, `core.internal.array.*` | Partially | Audited in Phase 5 |
| `GC.malloc`/`GC.qalloc` | direct | — | New hint `BlkAttr.SHARED_HINT = 0x40`. Bits `0x40` and `0x80` are free (`druntime/src/core/memory.d:321-386`). GCs that do not know the hint ignore it |

Routing happens inside the hook templates, so LDC and GDC inherit it through the shared frontend and druntime. LDC's `GC2Stack` optimization recognizes allocation hooks by name and must keep matching them.

### 4.2 Precise roots first; exact stack maps optional

Revision 1 proposed `llvm.experimental.gc.statepoint` to "completely eliminate" conservative scanning. For this collector that is neither achievable nor the best first investment:
1. **The collector is non-moving.** It needs only maps of which stack slots hold live pointers, not relocation. LLVM's statepoint machinery (`RewriteStatepointsForGC`, "RS4GC") exists mainly to relocate pointers.
2. **D has no GC-pointer type.** RS4GC identifies GC references by a separate address space, conventionally `addrspace(1)`. A D `T*` can point to the stack, `malloc` memory, static data or the GC heap. LDC would have to move *all* pointers into a GC address space, which touches codegen, C interop and inline asm everywhere.
3. **Exact maps need threads to stop at safepoints.** That means polls on loop back-edges and state transitions around `extern(C)` calls. It would replace druntime's signal-based `thread_suspendAll` (`druntime/src/core/thread/osthread.d:811`).
4. **Some conservatism remains anyway.** C, asm and signal frames have no maps. `spec/garbage.dd` explicitly allows unions in which pointers overlap integers. Precision can only shrink ambiguous roots, not eliminate them.
5. **Ambiguous stack roots appear to be cheap** for an Immix-style collector (Shahriyar et al., 2014).

The precision work is therefore reordered:
* **Phase 3 (all compilers): precise static-data and TLS roots.**
  * The frontend generates, per module, an enumerator of (address, size, `RTInfo` pointer bitmap) for module-level and `static` variables that contain pointers. TLS variables get a per-thread form.
  * A new `ModuleInfo` flag, `MIgcRoots = 0x4000`, advertises it. That is the next free bit after `MIunitTests = 0x2000` (`druntime/src/object.d:2312-2330`).
  * druntime then registers typed ranges instead of whole writable segments.
  * A DSO containing any module without the flag (C objects, older D objects) keeps scanning its segment conservatively.
  * The **precise heap** becomes the default under `gc:immix`.
* **Phase 8 (optional, LDC only): non-relocating stack maps.**
  * Signal-based suspension stays.
  * The innermost frame is scanned conservatively, as in Go's asynchronous preemption.
  * Frames without maps are scanned conservatively.

### 4.3 Concurrent marking barrier (Yuasa / SATB)

Revision 1's pseudo-assembly checked the flag but never loaded the **old value**. That old value is exactly what a snapshot-at-the-beginning barrier must preserve. Corrected (x86-64 pseudo-assembly):

```asm
  ; Pre-write barrier for `*rdi = rsi` (pointer store not into the current stack)
  cmp   byte ptr fs:[gcThreadState@tpoff + marking], 0   ; thread-local phase flag
  jne   .satb_slow                                       ; cold, out of line
.store:
  mov   qword ptr [rdi], rsi
  ; ...
.satb_slow:
  mov   rax, qword ptr [rdi]        ; the OLD value being overwritten
  test  rax, rax
  jz    .store
  ; append rax to this thread's SATB buffer; call _d_gc_satbFlush when full
  ; (before this thread's stack has been scanned: also append rsi, see I5)
  jmp   .store
```

* **Which stores get the barrier.**
  * Every pointer store except one into the current stack frame. That covers heap slots, `static`/`__gshared`/TLS variables, and stores through pointers into other stacks.
  * The compiler omits it for direct stores to local variables, unless the variable has been moved into a heap-allocated closure frame (in which case the store is a heap store). At run time, the slow path ignores stores whose slot turns out to be in the current stack.
  * Track B also exempts stores into the thread's own purely local blocks.
* **Pause structure (Revision 3).** This follows Go's design, so no pause grows with thread count, fiber count or stack size:
  * **STW-1, tiny.** Set `marking` and enable allocate-black. This reuses `thread_suspendAll`, so every thread sees the flag consistently. Also scan, as one group, the stacks that other threads can already read (`stackVisible`, set by the escape barrier below). Those are usually few: threads that handed a stack address to another thread. Every other stack waits for its own handshake.
  * **Concurrent work:**
    * Scan global data roots (precise after Phase 3).
    * Scan each thread's registers, stack and TLS in a *per-thread handshake*: suspend that thread only, scan, resume.
    * Scan suspended fiber stacks lazily (Phase 4.7).
    * Trace the heap.
  * **STW-2, tiny.** Flush the SATB buffers through a handshake, confirm every stack has been scanned, and finish a bounded amount of marking.

  Revision 2 rescanned every stack at remark. With SATB plus allocate-black that rescan is unnecessary, and with thousands of vibe.d fibers it alone would break the 2 ms target.
* **Bulk operations** call `_d_gc_bulkPreWrite(dst, len, ptrmap)` once instead of a per-word barrier. These are struct copies that contain pointers, the array copy/assign/append hooks, and `core.lifetime.move`/`copyEmplace`.

### 4.4 Publication barrier (Track B only)

The barrier fires based on **where the store goes**, which it determines at run time from block ownership. It never relies on the static type of the slot. That is what makes it correct for the lock-and-cast-away-`shared` idiom (§2.4, channel 3). The fast path below combines the SATB and publication checks:

```d
// Emitted (inlined) at every store of a pointer value `v` into `*slot`, except
// stores proven to target a non-escaping local or an object freshly allocated
// in the current thread's local domain (elision rules below).
pragma(inline, true)
void gcStore(void** slot, void* v) nothrow @nogc
{
    auto ts = &gcThreadState;                  // initial-exec TLS: one segment-relative access
    immutable ushort me = ts.ownerCode;        // 0 when local heaps are off (Track A)

    // SATB (Phase 4, both tracks): log overwritten references, except in the
    // current stack and (Track B) in heap blocks I own outright.
    if (ts.marking)
    {
        immutable bool logIt = heap.contains(slot)
            ? ownerOf(slot) != me              // Track A: me == 0 never matches a heap block
            : !ts.inCurrentStack(slot);        // global data, TLS, other stacks
        if (logIt)
        {
            satbLog(ts, *slot);                // Yuasa deletion barrier
            if (!ts.stackScanned)
                satbLog(ts, v);                // hybrid barrier until my handshake (I5)
        }
    }

    // Stack visibility (both tracks, found by the Phase 0 model, I5): my stack
    // becomes readable by other threads. One range compare on `v`.
    if (ts.onOwnStack(v) && !ts.onOwnStack(slot))
        _d_gc_stackEscaped(ts);                // scans my stack first if a cycle is running
                                               // and I am not yet scanned; Track B then also
                                               // globalizes my domain (I6)

    // Publication (Phase 5): is an object of mine becoming visible elsewhere?
    if (me != 0)
    {
        immutable ushort ov = ownerOf(v);      // 0 for non-heap values
        if ((ov | 1) == (me | 1))              // v lies in one of my blocks (pure or mixed)
        {
            if (ov != me || ownerOf(slot) != me)
                _d_gc_publishSlow(slot, v);    // resolves object, escaped bit, stack/TLS targets
        }
    }
    *slot = v;
}
```

Owner codes: `0` means "not in the heap" and `1` means `GLOBAL`. A local domain is `tid << 1`, with the low bit set for *mixed* blocks.

* **Cost of the fast path.** One TLS access, two or three loads from the block table, and three to five well-predicted branches. Phase 0 measures this, and gate G0a can kill Track B on the result.
* **When the barrier can be omitted.**
  * Stores to locals that do not escape. In LDC, `mem2reg` removes them. In the frontend, two existing analyses can prove it: the DIP1000 `scope` analysis in `compiler/src/dmd/escape.d` and the `-preview=fastdfa` engine in `compiler/src/dmd/dfa/fast/`.
  * *Initializing* stores into an object freshly allocated in the **local** domain, before it escapes.
  * Initializing stores into a fresh *global* object keep the barrier, because publication still applies.
* **Places that publish explicitly.**
  * `Thread.start` (`druntime/src/core/thread/osthread.d:157`, `posix_impl.d:251`) publishes the thread object and its delegate context.
  * `GC.addRoot`/`GC.addRange` publish what they reference.
  * The new `GC.publish(const void*)` covers hand-offs through C.
  * `core.atomic` pointer operations call the barrier.
* **Marking compiled modules.** Modules compiled with barriers set a new `ModuleInfo` flag, `MIgcBarriers = 0x8000`, and predefine `version (D_GCBarriers)`. Modules that also have the publication barrier set `MIgcPublish = 0x10000` (`ModuleInfo._flags` is a `uint`: `druntime/src/object.d:2354`) and predefine `version (D_GCPublish)`. Libraries can then use a different strategy only when Track B is possible (ADR-6).
  * druntime enables concurrent SATB marking only if **every** loaded module has `MIgcBarriers`, and local domains (Track B) only if every module also has `MIgcPublish`.
  * If a D library without the flag is loaded later, SATB marking is turned off (falling back to STW or fork marking) and all domains are globalized (I6).
  * GDC, whose code generation is out of scope here, is therefore handled safely: without the flag, it gets the fallback.

### 4.5 Where the code lives

| Component | Repository | Notes |
|---|---|---|
| Frontend: hook flags, `MIgcRoots`/`MIgcBarriers` metadata, root enumerators, `version (D_GCBarriers)`, barrier switch, analysis for omitting barriers | `dmd` (`compiler/src/dmd/`) | Reaches LDC and GDC through frontend merges |
| druntime: `gc:immix`, routing, bulk barriers, thread handshakes, typed root ranges, `GC.publish` | `dmd` (`druntime/`) | LDC carries a fork of druntime and merges it |
| DMD barrier emission and `ModuleInfo` fields | `dmd` (`compiler/src/dmd/glue/e2ir.d`, `glue/package.d`, `glue/toobj.d`) | Both barriers, emitted as out-of-line calls to `_d_gc_store` (ADR-4): correct, small, slow. Needed so this repository's test suite, druntime and Phobos (all built with DMD) can test and enable both tracks |
| LDC barrier emission | `ldc` (IR generation for assignments/stores, `ModuleInfo` emission, driver flag) | Optimized inline fast path. Inserted during IR generation, where D types are known. A late LLVM pass is not enough: with opaque pointers, SROA/InstCombine and `memcpy` lowering can turn pointer copies into integer or bulk copies. LLVM does not remove D barriers on its own: dropping them for fresh objects is custom work |
| Phobos audits (`std.parallelism`, `std.concurrency`) | `phobos` | Phase 6 |
| Spec amendments (`spec/garbage.dd`) | `dmd` (`spec/`) | Phases 5 and 9 |

---

## 5. Core Data Structures and Runtime Prototype

Revision 1 put a 256-byte line map inside each block and modelled only the bump pointer. D objects have no GC header, so the collector also has to:
* answer `addrOf`, `sizeOf` and `query` for interior pointers;
* keep `APPENDABLE` arrays working (`getArrayUsed`/`expandArrayUsed`/`reserveArrayCapacity`/`shrinkArrayUsed`, `druntime/src/core/gc/gcinterface.d:214` ff.);
* find dead finalizable objects;
* know every object's extent in order to scan it.

The revised prototype keeps all of this in side tables:

```d
module core.internal.gc.impl.immix.layout;

enum size_t GRANULE         = 16;                     // min alignment and metadata resolution
enum size_t LINE_SIZE       = 128;
enum size_t BLOCK_SIZE      = 32 * 1024;
enum size_t LINES_PER_BLOCK = BLOCK_SIZE / LINE_SIZE; // 256
enum size_t LARGE_THRESHOLD = 8 * 1024;               // >= 8 KiB: large object space

// Block owner codes (Track B). 0 = not a heap address / free block.
enum ushort OWNER_FREE   = 0;
enum ushort OWNER_GLOBAL = 1;
// local(T) = cast(ushort)(T.id << 1); mixed(T) = local(T) | 1

/// Attribute segregation: per-object attribute bits are replaced by block kinds.
enum BlockKind  : ubyte { scan, noScan, finalizable }
enum BlockState : ubyte { free, allocating, recyclable, full }

/// One entry per 32 KiB block, in a side table (never inside the block).
struct BlockMeta
{
    ushort     owner;            // OWNER_* or local/mixed owner code
    BlockKind  kind;
    BlockState state;
    ushort     freeLines;        // as of the last sweep
    uint       escapeEpoch;      // I4: newest global epoch in which an object here escaped
    uint       globalizedEpoch;  // I5: skipped by the sweep of this global cycle
}

/// One VA reservation covers the Immix space and the LOS, so "is this a GC
/// pointer?" and "which block?" are a subtraction, a compare and a shift.
struct HeapLayout
{
    void*      base;             // BLOCK_SIZE-aligned, committed lazily
    size_t     size;
    BlockMeta* blocks;           // size / BLOCK_SIZE entries
    ubyte*     lineLive;         // size / LINE_SIZE entries: local and global liveness epochs
    size_t*    startBits;        // 1 bit / granule: a *valid* object starts here
    size_t*    endBits;          // 1 bit / granule: an object ends here (size recovery)
    size_t*    markLocal;        // 1 bit / granule: written only by the owner's local GC (I2)
    size_t*    markGlobal;       // 1 bit / granule: written by global markers (atomic OR)
    size_t*    escapedBits;      // 1 bit / granule: promoted in place (Track B)
    size_t*    finalizeBits;     // 1 bit / granule: FINALIZE / STRUCTFINAL objects
    size_t*    pointerBits;      // 1 bit / word: precise pointer map copied from RTInfo

    pragma(inline, true)
    bool contains(const void* p) const nothrow @nogc
    {
        return cast(size_t) p - cast(size_t) base < size; // wraps when p < base
    }

    pragma(inline, true)
    size_t blockIndex(const void* p) const nothrow @nogc
    {
        return (cast(size_t) p - cast(size_t) base) / BLOCK_SIZE;
    }
}

/// Per-thread allocation buffer: the hole currently being bump-allocated.
/// A thread holds one per BlockKind (and, under Track B, per domain).
struct AllocBuffer
{
    void*  cursor;
    void*  limit;                // end of the current hole
    size_t block;                // block held exclusively by this buffer (I2)

    // Fast path, inlined into the GC's malloc entry points. The caller has
    // already rounded `size` to GRANULE, chosen the buffer by BlockKind and
    // domain, and copies the precise pointer bitmap afterwards if needed.
    pragma(inline, true)
    void* allocate(ref HeapLayout h, size_t size) nothrow @nogc
    {
        void* p = cursor;
        if (size <= cast(size_t)(limit - p))   // cannot overflow, unlike `p + size <= limit`
        {
            cursor = p + size;
            h.setStart(p);                     // owner-exclusive bitmap words: no atomics
            h.setEnd(p + size - GRANULE);
            return p;
        }
        return allocateSlow(h, size);          // next hole, overflow block, LOS, or collect
    }

    void* allocateSlow(ref HeapLayout h, size_t size) nothrow @nogc;
}
```

**Metadata budget.** The start, end, two mark, escaped and finalize bitmaps cost 1/128 of the heap each. The precise pointer map costs 1/64. That is at most about 6.3% of the **committed** heap, and less when a bitmap is unused: escaped bits exist only under Track B, and pointer bits only for scan blocks.

Side tables are *reserved* for the whole address range but *committed* only together with the blocks they describe. Committing them for a 64 GiB reservation would cost about 4 GiB.

Compared with a segregated-fit allocator, this is a cost, not an advantage. Such an allocator gets object size from the page and needs no start or end bitmaps. The side tables only beat in-block headers. Gate G0c weighs this (ADR-2).

The alternative is an 8-byte header per object. With 16-byte alignment it effectively costs 16 bytes per object, which is far too much for small D objects. Phase 0.6 and Phase 1 measure both options before the layout is frozen.

**Other per-object information:**
* **`APPENDABLE` used-length** is stored inside the allocation, as `druntime/src/core/internal/gc/blockmeta.d` does today: padding at the end for small and medium blocks, a prefix header for large ones. Appendable allocations are rounded up to a capacity class, so that in-place `~=` stays common.
* **The `STRUCTFINAL` `TypeInfo` pointer** is stored inside the allocation, as today.
* **`NO_INTERIOR`** is honoured only in the LOS. That matches its documented contract, "only implemented for data structures at least a page in size" (`druntime/src/core/memory.d:356`).

---

## 6. Implementation Roadmap: Overview

Revision 1 had four phases: engine, then heap segregation, then statepoints, then concurrent marking. Revision 2 replaces them with two tracks and measured gates:
* Phase 0 runs before any large investment.
* Track A is worth delivering even if Track B is never built.
* The full work breakdown, with files, tests, gates and estimates, is in **§10**.

```
            ┌──────────────────────────────────────────────────────────┐
            │ Phase 0  baselines, instrumentation, barrier and         │
            │          escape spikes, formal model, allocator choice   │
            └──────────────────────────────────────────────────────────┘
                 │ gate G0c (allocator)          gates G0a, G0b (Track B)
                 ▼
 Track A   Phase 1  gc:immix core: STW, parallel mark, TLABs ......... G1
             ├──▶ Phase 2  fork-based concurrent marking (POSIX) ..... G2
             ├──▶ Phase 3  precise static/TLS roots, precise heap .... G3
             └──▶ Phase 4  barrier infrastructure + SATB marking ..... G4
                                  │
                                  ▼  (also requires G0a and G0b)
 Track B   Phase 5  thread-local collection domains .................. G5
             └──▶ Phase 6  ecosystem hardening (Phobos, vibe.d, spec)

 Optional  Phase 7  opt-in defragmentation  ·  Phase 8  exact stack maps (LDC)
 Always    Phase 9  productization and upstreaming (default switch last)
```

---

## 7. Risk Assessment and Architectural Mitigations

| Technical Risk | Severity | Probability | Architectural Mitigation |
|---|---|---|---|
| **Use-after-free because thread-locality is violated** by casts, `immutable`, `__gshared`, escaping stack addresses or C hand-offs (§2.4) | Critical | High without a barrier | Publication barrier that checks the target address (§4.4); globalization fail-safe (I6); `localheaps:verify` mode in CI; model checking (Phase 0.5). Revision 1's "copy/migrate the object graph" is rejected: copying breaks interior pointers held in conservatively scanned frames, so promotion happens **in place** |
| **Publication barrier too expensive** (as with Go's ROC) | High | Medium | Gate G0a measures it before any Track B work is integrated; Track A does not depend on it |
| **Mixed builds** (modules without barriers, GDC, old binaries, C) | High | High | `MIgcBarriers` `ModuleInfo` flag; automatic fallback to STW/fork marking without local domains; `dlopen` of a module without the flag globalizes |
| **The optimizer hides pointer stores** (copies turned into integer stores, `memcpy` of aggregates) | High | Medium | LDC inserts barriers during IR generation, where D types are known; bulk barriers for aggregate copies; barrier-coverage verifier (Phase 4.8) |
| **Side metadata makes Immix lose to segregated fits** (symgc) on RSS or speed | Medium | Medium | Decision gate G0c. The ownership and barrier design works with any allocator whose ownership unit is the block |
| **Pathological line fragmentation** | Medium | Medium | Immix's published space efficiency relies on opportunistic evacuation, which this RFC makes opt-in. A non-moving Immix therefore carries *more* fragmentation risk than segregated fit, because one live small object pins a whole 128-byte line. Mitigations: conservative line marking, separate block kinds, recycling thresholds, a long-running fragmentation benchmark in G0c (ADR-2), and opt-in defragmentation that never moves pinned objects (Phase 7). Revision 1's "evacuate scalar or non-interior-pointed types" is rejected: whether an object can move depends on what points *to* it (ambiguous roots, slices, C), not on what it contains |
| **Pauses dominated by stack scanning** (many threads, or thousands of fibers as in vibe.d) | High | High | Per-thread handshakes with a hybrid barrier; fiber stacks scanned lazily or before they resume; no rescan at remark (Phase 4.7, I5). The `fiber_latency` benchmark is part of M3 |
| **Frequent globalization** from stack addresses escaping (`std.parallelism`) | Medium | High | Measured in G0b. Under `version (D_GCPublish)` only, Phobos passes heap closures, which promotes the data the workers can reach instead of globalizing the whole domain (ADR-6, Phase 6). Globalization costs time proportional to the number of blocks |
| **Large promotion graphs** cause latency spikes in the program | Medium | Medium | A promotion work budget, after which the thread globalizes |
| **Owner-thread finalization mistaken for a guarantee** (it only holds until an object escapes) | Medium | Medium | Documented as best effort; finalizers must still not depend on which thread runs them, as today (ADR-5); `GC.inFinalizer` unchanged |
| **Domains orphaned at thread exit** (`cleanupThread` is never called for the main thread or for threads attached from C) | High | Medium | Exit hooks in `thread_detachThis`/`thread_detachByAddr`, a pthread-key destructor for attached threads that exit without detaching, and `rt_term` handling for the main thread (Phase 5.4) |
| **TLS access cost in the barrier** when druntime is a shared library | Medium | Medium | Initial-exec TLS for `gcThreadState`; G0a measures both static and shared druntime |
| **Fork-based marking**: copy-on-write memory blow-up, libraries that are not fork-safe | Medium | Medium | Reuse the `fork:1` fallbacks; Phase 4 removes the dependency |
| **LLVM churn in the GC intrinsics** | High | High | Statepoints moved to optional Phase 8; Tracks A and B need none |
| **32-bit targets** (VA reservation) | Low | High | Chunk-table fallback; Track B is 64-bit only |
| **Upstream reviewability and maintenance burden** | High | Medium | Land each phase behind `gc:immix` and gcopts; the default does not change until the §8 targets hold for two releases |

---

## 8. Success Metrics and Verification Targets

Each target is measured against the **best existing configuration** for that metric, not only against the defaults.

* **Configurations:** `gc:conservative`, `gc:precise`, `parallel:N`, `fork:1` and `gc:sdc` (symgc).
* **Builds:** LDC `-O3 -release`, with both static and shared druntime.
* **Platforms:** Linux x86-64 and AArch64, Windows x64, macOS arm64.

The numbers below are **proposals**. They are confirmed once the Phase 0 baselines exist.

| # | Metric | Baseline | Target | Gate |
|---|---|---|---|---|
| M1 | Multi-threaded small-object allocation throughput (`mt_alloc`, 8 and 32 threads) | conservative, symgc | ≥ 3× conservative at 8 threads; ≥ 1.0× symgc | G1 |
| M2 | Single-threaded throughput (gcbench geometric mean) | conservative | ≥ 0.95× | G1 |
| M3 | P99 stop-the-world pause (`latency`: 4 GiB live, 16 threads; `fiber_latency`: same plus 10k suspended fibers) | conservative with `parallel`, `fork:1` | ≤ 10 ms with fork marking (Linux, `latency`); **≤ 2 ms** with SATB marking (Linux and Windows, both benchmarks) | G2, G4 |
| M4 | Slowdown of program code caused by barriers | same compiler without barriers | SATB, while not marking: ≤ 3% geometric mean. SATB + publication: ≤ 5% geometric mean and ≤ 15% worst case | G0a, G4, G5 |
| M5 | Resident set size at equal `heapSizeFactor` | conservative, symgc | ≤ 1.0× conservative; ≤ 1.1× symgc | G1 |
| M6 | False retention from static data and TLS | conservative | 0 objects retained in the false-pointer suite | G3 |
| M7 | Escape rate (Track B) | — | ≤ 20% of allocated bytes promoted; ≤ 1 globalization per 10 ms per thread | G0b, G5 |
| M8 | Isolation (Track B) | — | A local collection adds 0 µs of pause to other threads | G5 |
| M9 | Code size growth from barriers | no barriers | ≤ 10% of `.text` | G0a, G4 |
| M10 | Compatibility | — | All druntime, Phobos and dmd tests pass; project-tester parity; C ABI unchanged (no relocation unless `defrag:1`) | every gate |

---

## 9. Design Review of Revision 1

| # | Revision 1 statement | Finding | Resolution |
|---|---|---|---|
| R1 | The current GC is "a purely synchronous Stop-the-World mark-and-sweep system" | It has parallel marking (`gc.d:34`), fork-based concurrent marking (`gc.d:37`, `fork:1`) and an optional precise heap (`gc:precise`) | §2.1; baselines in §8 |
| R2 | "Global variables and standard allocations are thread-local unless explicitly qualified with `shared`" | True for variables. False for heap data: `immutable` is implicitly shared, and casts, `__gshared`, closures and C move unqualified pointers to other threads | §2.3, §2.4 |
| R3 | Thread-local collections have "zero external impact" | True only while invariant I1 holds, and I1 must be maintained at run time | §3.4, §3.5 |
| R4 | "Mutations affecting purely thread-local references are completely free from write barriers" | Static types cannot identify such mutations (lock-and-cast-away-`shared`). The check has to be on the target address, at run time | §4.4 |
| R5 | Hooks `_d_alloc_thread_local`, `_d_alloc_immix_shared`, `_d_newitem_shared` | They do not exist. The real hooks are templates. Some strip qualifiers, and the array hooks receive `isShared` but ignore it | §4.1 |
| R6 | A promotion helper that "copies" or "migrates" the object graph | Copying invalidates interior pointers held in conservatively scanned frames | In-place promotion, §3.4 |
| R7 | SATB pseudo-assembly | Never reads the overwritten value, so it is not a SATB barrier | §4.3 |
| R8 | Statepoints "completely eliminate conservative scanning artifacts" | Unions, C/asm frames and untyped `GC.malloc` stay conservative. RS4GC needs GC pointers in their own address space, and threads that stop only at safepoints | §4.2; Phase 8 is optional |
| R9 | `BlockHeader` with an in-block line map; bump pointer only | Wastes lines and causes cache conflicts. Omits the object start/size/attribute/finalization/appendable metadata that `core.gc.gcinterface.GC` requires | §5 |
| R10 | "D's pluggable `core.internal.gc.impl` interface" | The real interface is `core.gc.gcinterface.GC` plus `core.gc.registry.registerGCFactory` | Phase 1 |
| R11 | Fragmentation fix: "evacuate scalar or non-interior-pointed types" | Whether an object can move depends on the pointers to it, not on its contents | §7; Phase 7 |
| R12 | No medium objects, large objects or finalization | Immix needs overflow allocation and a LOS. Mark-region never visits dead objects, so finalizable objects need separate tracking | §3.3 |
| R13 | Metrics measured against "the standard druntime collector" | Must compare with the best existing options and with symgc. Targets were not tied to phases | §8 |
| R14 | Target "LDC" only | The frontend and druntime live in this repository. Barriers are per backend. Mixed builds must fall back safely | §4.4, §4.5 |
| R15 | Thread exit, fibers, C-attached threads, `dlopen` not covered | All need explicit rules | Globalization (I6); fiber owner; Phase 5 |
| R16 | "TLAB" used for both allocation buffers and collection domains | Two different mechanisms with very different risk | §3.2 vs §3.4 |

---

## 10. Complete Implementation Roadmap

Estimates are rough figures in **person-weeks (pw)**, for one engineer experienced with druntime and the relevant compiler. They exclude upstream review time. Each phase lands upstream behind an opt-in option, so the default GC does not change before Phase 9.

### Phase 0 — Baselines, instrumentation and feasibility spikes `[gates both tracks]`
**Goal.** Replace assumptions with measurements. Decide (a) whether Immix is the right allocator for D, and (b) whether Track B is worth building.
**Depends on.** Nothing.

- [ ] **0.1 Benchmark matrix.** *(Status: 8 of 9 workloads written in `druntime/benchmark/gcbench/`: `mt_alloc`, `mt_share`, `parallel_map`, `latency`, `append_heavy`, `fiber_latency`, `frag_longrun`, `traverse_locality`. Defaults are CI-sized; the real runs need the large parameters in each file header. Baselines for dmd and LDC were taken with `plans/bench/run_compare.sh` (results in "Phase 0 findings", section 8); real workloads (dmd/Phobos, vibe.d) and roadmap-size live sets remain.)* Extend `druntime/benchmark/gcbench/`, driven by `druntime/benchmark/runbench.d`. It currently has `conalloc`, `conappend`, `concpu`, `conmsg`, `dlist`, `huge_single`, `rand_large`, `rand_small`, `slist`, `testgc3`, `tree1`, `tree2`, `vdparser` and `words`. Add:
  - `mt_alloc`: N threads allocating short-lived small objects, with no sharing;
  - `mt_share`: producer/consumer over `std.concurrency`;
  - `parallel_map`: the `std.parallelism` result-array pattern (§2.4, channel 7);
  - `latency`: a request loop over a 1–8 GiB live set that records every pause;
  - `append_heavy`: `~=`, `capacity` and `assumeSafeAppend`;
  - `fiber_latency`: `latency` plus 10k suspended fibers with 16–64 KiB stacks (the vibe.d shape);
  - `frag_longrun`: hours-long mixed-size allocation with a slowly changing live set, to expose line fragmentation;
  - `traverse_locality`: build and traverse trees and lists of mixed-size nodes, reporting last-level cache misses with `perf stat`;
  - real workloads: dmd building Phobos with the GC enabled, and a vibe.d HTTP server under load.
- [ ] **0.2 Instrumentation.** *(Status: `trace:<file>` implemented in `config.d` and the conservative GC's `fullcollect`; CSV columns `collection,kind,pause_us,mark_us,sweep_us,live_bytes,committed_bytes,threads`, with an extra `fork-start` record for a forking collection's stop-the-world part. Live and committed bytes are page-granular. The pause histogram exists in `latency` and `fiber_latency`; not yet in `runbench.d`.)* Two pieces give baselines for all configurations in §8:
  - a trace record for each collection (kind, pause, mark and sweep time, live and committed bytes, thread count), written through a new `--DRT-gcopt=trace:<file>` handled in `druntime/src/core/gc/config.d`;
  - a pause histogram in the benchmark harness.
- [ ] **0.3 Barrier-cost spike (LDC).** *(Status: partly done, with an IR-rewriting stand-in because LDC is not buildable here: no LLVM development files. Code and driver are in `plans/spikes/barrier/`. Results below. Remaining: marking-on cost, static vs. shared druntime, Phobos unit tests for coverage, and a repeat with a real LDC change.)*
  * **Method.** `ldc2 -O3 -output-ll`, then `rewrite_ir.d` replaces every non-atomic `store ptr` (except to allocas) with the §4.4 fast path as an always-inline function, then `clang -O2 -c` (same LLVM 19), then link. Nine workloads (the `gcbench` set plus `ptr_heavy`, a no-allocation pointer-store worst case), median of 5. `--elide-fresh` additionally skips stores into memory returned by an allocation call in the same function, as the §4.4 elision rules allow.
  * **Time, geometric mean over the 9 workloads** (ratio to the unmodified code through the same pipeline; run-to-run noise is about ±5%):

    | Variant | no elision | with fresh-store elision |
    |---|---|---|
    | SATB | 1.027 | 1.004 |
    | SATB + stack-visibility compare | 1.030 | 1.011 |
    | SATB + publication (stored value not in my domain) | 1.127 | 1.075 |
    | SATB + publication + visibility | 1.128 | 1.097 |

    Worst single workload: SATB 1.08 (with elision), publication + visibility 1.58 (`tree2`, a store-dense tree insert). With the stored value in my own domain (the common Track B case, which needs both block-table lookups), `tree2` reaches 1.79, `dlist` 1.18, `ptr_heavy` 1.14.
  * **Code size** (`.text` of the rewritten object, geometric mean): SATB ×1.10 with elision, ×1.16 without; publication + visibility ×1.46 and ×1.79. This is the user object only, so whole-binary growth is smaller, but M9 (≤10%) is not met by the publication barrier in this form.
  * **Cheaper publication fast paths (follow-up run, 7 repetitions, fresh-store elision and the visibility compare on, both "stored value is mine" settings).**

    | Publication check | Geometric mean | Worst workload | `.text` growth |
    |---|---|---|---|
    | Block table, value then slot (two lookups) | 1.054–1.058 | 1.46–1.61 (`tree2`) | ×1.46 |
    | Block table, slot first (`split`) | 1.043–1.070 | 1.55–1.70 (`tree2`) | ×1.45 |
    | Per-thread contiguous arena (`arena`) | **1.013–1.017** | 1.25–1.28 (`tree2`) | ×1.31 |

    Testing the slot first does not help: the extra branch costs about what the saved lookup does. A per-thread virtual address arena replaces the table lookups with one range compare and brings the geometric mean inside M4 (≤5%). The `tree2` worst case still exceeds the 15% limit, and M9 is still missed. The arena is a design change, not a tuning: local blocks must come from a contiguous per-thread range of address space, and globalizing a block leaves it inside that range, so "value is in my arena" no longer implies "value is mine" and the slow path must check the escaped bit. It needs its own decision record and a model update before it can be adopted.
  * **Why `tree2` is the worst case.** It is `std.container`'s red-black tree with 100 live nodes: 81M barriered stores in 7M operations (11.6 per operation, one every ~5 ns), almost all rotations and relinking of existing nodes that no elision rule can prove local. SATB costs 0–5% there. The arena publication check costs 30–43%, and 23–27% when the per-thread bounds are marked `!invariant.load` so LLVM can hoist them (`--invariant`). So reloading the thread state is not the main cost; the check itself, about five instructions and several dependent branches per store, is. Any software publication barrier of this size will land near this number on store-dense pointer code.
  * **Reading against M4/M9.** The SATB barrier meets M4 (≤3% geometric mean) when fresh-store elision applies. The publication barrier does **not** meet M4 (≤5% geometric mean, ≤15% worst case) or M9 in this spike. Per gate G0a that would shelve Track B, but the spike is a crude upper bound: it works on post-optimization IR, so LLVM could not hoist or merge the checks or lay out the cold paths; it does not cover bulk copies; and noise is high on the sub-second workloads. **Treat G0a as undecided.** With block-table ownership it leans to fail. With per-thread arenas the geometric mean passes and only the worst case (`tree2`, 1.25–1.28 against a 15% limit) fails, but `tree2` shows the worst case is structural (store-dense mutation of existing nodes), not an artifact of the stand-in. Unless a real LDC change gets it under 15%, the choice is between keeping M4 as written, which shelves Track B, and restating M4's worst-case limit for publication. That is a decision for the project, not something the numbers settle. ADR-2's block layout should not be tied to arenas until it is made. the §4.4 fast path at every heap pointer store, with a slow path that does nothing. Include the stack-visibility range compare on the stored value (§4.4), which the 0.5 model added to both tracks. Measure two variants, SATB only and SATB plus publication, each with and without that compare so its own cost is visible:
  - slowdown of the program's own code;
  - `.text` growth;
  - static vs. shared druntime, which use different TLS access models.

  Run the Phobos unit tests to check barrier coverage.
- [x] **0.4 Escape census.** *(Status: done with an IR-instrumentation tool and a census GC wrapper, `plans/spikes/census/`; 18 workloads, results in `plans/spikes/census/results/`, summary in the verdict below. Not measurable with this tool: the allocation path of `immutable` data beyond the per-site table, and fibers. Only code compiled into the module is observed, so escape rates are lower bounds.)* Build the same prototype with a counting slow path. For the 0.1 workloads, report:
  - the fraction of objects and bytes that would be promoted;
  - the size of promotion graphs;
  - stack-address escapes per second;
  - **`stackVisible` stacks** (I5, stack-visibility rule): how many threads' stacks become readable by other threads, when it happens (thread start, `std.parallelism` call, other), and for how long each stays visible. This number sets the size of STW-1 (gate G4);
  - for `immutable` data (ADR-3): how many bytes escape versus die locally, and which path allocated them. The paths are a typed hook (`.idup`, `~`, `~=` on `string`), `GC.qalloc` from Phobos's `Appender`, or a mutable buffer later cast with `assumeUnique` or converted from a pure function's unique result;
  - globalizations caused by `std.parallelism` versus all other causes (ADR-6).
- [x] **0.5 Formal model.** *(Done as an executable model rather than TLA+: `plans/model/gc_model.d`, reproduced by `plans/model/run_all.sh`. No Java was available, and a hand-written TLA+ spec that cannot be run would be unchecked. A TLA+ port is optional and would cross-check this one.)* It is a breadth-first explicit-state checker with object-renaming symmetry reduction. It models allocation, the §4.4 store barrier, in-place promotion, globalization, local collection, stack-address escape, and a global SATB cycle with per-thread handshakes, SATB buffers, incremental field-by-field tracing, remark, and a lazy per-object sweep running against the mutators. The original wording was: write a TLA+ (or PlusCal) model and check I1–I6 with TLC (2–3 threads, 4–6 objects).
  * **Results.** Clean runs pass: Track A with 2 threads, 3 objects, 1 stack slot (4.9M states); Track B with 2/3/1 (19.0M states) and with 1 thread, 3 objects, 2 stack slots (6.6M states). Larger configurations (2 threads with 2 stack slots; 1 thread with 4 objects; 2 fields) hit the 120–150M-state cap with no violation found, which is inconclusive. **The roadmap's 2–3 threads and 4–6 objects were not reached.** Symmetry over threads and a partial-order reduction would be needed.
  * **The checker detects planted bugs.** Each of these produces a counterexample: no deletion barrier, no hybrid barrier, no publication, no globalization, no local-domain tracing at the handshake, no greying of promoted objects, no skip for globalized blocks, no protection of new objects during the sweep, and the two halves of the stack-visibility rule.
  * **Findings that changed the design** (all applied above): (1) **stack visibility.** Per-thread handshakes alone are unsound when other threads can read a stack. See I5 and ADR-9. (2) **Sweep protection.** Allocate-black and grey-on-promote must last until the sweep ends, not just until remark. (3) **Floating garbage.** The marker must follow only pointers into `GLOBAL` blocks.
  * **Model extension: done (details in `plans/model/README.md`).** Thread symmetry (halves the 2-thread state count), fibers with the `unscanned → scanning → scanned` states, two-step stores for racing writers, and a randomized mode for 3 threads / 5 objects. Results: clean runs pass (fibers exhaustively at 1 thread; random walks at 3 threads / 5 objects, over 80,000 completed cycles); 9 of 10 planted bugs are found by random walks, the tenth (`noescapescan`) only exhaustively. **New design finding:** the barrier as written (test `marking`, then store) loses an object if a cycle starts between the two; with `--race` this is a 10-step counterexample. Exchange-then-test passes 49.7M states; the alternative is a restartable barrier sequence. Fiber switch-in scanning is necessary (`nofiberscan`, 13 steps). The text below is the original task, kept for reference. **Original wording:** The roadmap's 2–3 threads and 4–6 objects need thread symmetry and a partial-order reduction. Also add: fibers (with the `unscanned → scanning → scanned` state of Phase 4.7), a racing second writer to one slot, and the `stackVisible` group scan at STW-1 with several visible stacks. Exit condition: the clean runs pass at 3 threads and 5 objects and every planted bug is still detected. Mixed blocks and line reuse (I4) are added before Phase 5 starts.
  * **Not modelled.** Lines and blocks (I4 holds per object by construction), weak memory (sequential consistency assumed), racing writers to one slot (the barrier plus store is one atomic action), fibers, finalizers, interior pointers, no-scan data, large objects. I2 and I3 hold by construction. Treat these as the remaining modelling work before Phase 5's gate.
- [x] **0.6 Allocator decision record (ADR-2).** *(Status: done. Immix and segregated-fit prototypes under one collector, `plans/spikes/immix/`, then symgc measured on the repository's druntime, `plans/bench/core_bench/`. Outcome: Immix rejected, symgc adopted as the base; see "Phase 0 verdict" and "Direction".)* Build an out-of-tree Immix allocator, with a minimal stop-the-world collector so that holes are actually recycled. Compare it with symgc on:
  - allocation throughput, single- and multi-threaded;
  - RSS over `frag_longrun` (fragmentation), not just at peak;
  - last-level cache misses in `traverse_locality` (the locality argument for Immix);
  - metadata RSS, for side tables vs. 8-byte headers;
  - engineering cost: the remaining work to reach G1 by extending symgc vs. finishing Immix.

  The minimal collector is what makes the fragmentation and locality numbers meaningful; it adds about 1–2 pw to this phase.

**Exit gates.**
- **G0a (barrier cost):**
  - Pass (M4 and M9 met): Track B may proceed.
  - Fail: Track B is shelved; Track A continues.
- **G0b (escape rate):**
  - Pass (M7 met): Track B may proceed.
  - Fail: Track B is shelved, or reduced to an opt-in per thread.
- **G0c (allocator):**
  - Pass: build Immix. All of these must hold:
    - steady-state RSS on `frag_longrun` within 10% of symgc;
    - allocation throughput at least on par with symgc;
    - a measurable reduction in cache misses on `traverse_locality`, since locality is the reason to prefer Immix.
  - Fail: apply the Track A/B design on top of symgc's segregated-fit allocator, keeping ownership per block. Also choose symgc if Immix's advantages are within noise and the engineering-cost estimate favours symgc.

**Estimate.** 8–13 pw (the model extension adds 1–2).

#### Phase 0 findings (status report, 2026-10-07)

This section collects what Phase 0 has produced so far. All six items have results (some partial, see section 6); the verdict and the direction follow section 8. Section 8 holds the first baselines (dmd and LDC, conservative GC). They are below roadmap size (the largest live set is 2 GiB, against the 1–8 GiB of G0c), and no allocator comparison exists.

**1. What was built and where**

| Item | Artifact | State |
|---|---|---|
| 0.1 | `druntime/benchmark/gcbench/`: `mt_alloc`, `mt_share`, `parallel_map`, `latency`, `append_heavy`, `fiber_latency`, `frag_longrun`, `traverse_locality` | 8 of 9 workloads written; `runbench.d` picks them up unchanged. Baselines taken with dmd and LDC by `plans/bench/run_compare.sh` (see 8 below and `plans/bench/README.md`). Missing: dmd building Phobos and a vibe.d server. |
| 0.2 | `--DRT-gcopt=trace:<file>` in `druntime/src/core/gc/config.d` and `fullcollect` in `conservative/gc.d` | Done. CSV `collection,kind,pause_us,mark_us,sweep_us,live_bytes,committed_bytes,threads`; kinds `stw`, `parallel`, `fork`, plus `fork-start` for the stop-the-world part of a forking collection. Live and committed bytes are page-granular. Checked on a two-thread program in parallel and fork mode. druntime's own unit tests were not run. |
| 0.3 | `plans/spikes/barrier/`: `rewrite_ir.d`, `gcspike_rt.d`, `run_spike.sh`, `run_variants.sh`, `workloads/ptr_heavy.d` | Partly done, through an IR-rewriting stand-in (LDC is not buildable here). |
| 0.4 | `plans/spikes/census/` | Done (18 workloads). |
| 0.5 | `plans/model/gc_model.d`, `plans/model/run_all.sh` | Done, extended: thread symmetry, fibers, two-step racing stores, randomized mode. Exhaustive at 2 threads / 3 objects; randomized at 3 threads / 5 objects. |
| 0.6 | `plans/spikes/immix/`, `plans/bench/core_bench/` | Done. |

Environment facts that affect reproduction: the system `dmd` (2.109.1) cannot build this repository's druntime (a layout assert in `object.d` fails), so the repository's own compiler is built first with `rdmd compiler/src/build.d HOST_DMD=/usr/bin/dmd dmd`. No Java, `perf`, `bc`, `opt` or LLVM development files are installed. The untracked `ldc/` directory is an LDC source checkout (commit `ac0e420af3`, 2026-09-11) with no build tree.

**2. Model-checking findings (0.5)**

The model is a breadth-first explicit-state checker with object-renaming symmetry reduction. It covers allocation, the §4.4 store barrier, in-place promotion, globalization, local collection, stack-address escape, and a global SATB cycle with per-thread handshakes, SATB buffers, field-by-field tracing, remark and a lazy per-object sweep running against the mutators.

*Results.* Clean runs pass: Track A with 2 threads, 3 objects and 1 stack slot (4.9M states); Track B with the same size (19.0M states); Track B with 1 thread, 3 objects and 2 stack slots (6.6M states). Larger configurations (2 threads with 2 stack slots, 1 thread with 4 objects, 2 fields) stopped at the 120–150M-state cap with no violation found, which is inconclusive. The roadmap's 2–3 threads and 4–6 objects were not reached.

*The checker detects planted bugs.* All 15 planted-bug runs produce a counterexample: no deletion barrier, no hybrid barrier, no publication, no globalization, no local-domain tracing at the handshake, no greying of promoted objects, no skip for globalized blocks, no protection of new objects during the sweep, and each half of the stack-visibility rule. One bug (`nolocaltrace`) was missed by the first Track B configuration because one stack slot cannot store a pointer into a held object; a 2-slot configuration was added.

*Findings that changed the design (all applied in §3.5, §4.3, §4.4, Phase 4.7 and ADR-9):*

1. **Per-thread handshakes alone are unsound in D.** Counterexample, in both tracks:
   1. T0 stores its stack address into a heap object.
   2. T1, already scanned, copies a pointer out of T0's unscanned stack.
   3. T0 overwrites that slot with an unbarriered local store.
   4. No scan sees the pointer, and the sweep frees an object T1 holds.

   Go avoids this because its stacks are never visible to other goroutines; D stacks can be. The fix is the *stack-visibility rule*: a stack is scanned before another thread can read it, at the escape barrier and, as a group, at STW-1. STW-1 therefore scans the `stackVisible` stacks, and the escape check (a range compare on the stored value) is in the Track A fast path too.
2. **Sweep protection.** Allocate-black and grey-on-promote must last until the cycle's sweep has finished, not only until remark. With a lazy sweep an object allocated or promoted after remark but before its block is swept would be freed.
3. **Floating garbage.** A dead global object can hold a stale pointer into memory that was freed and reused. The marker must follow only pointers into `GLOBAL` blocks, and I1 is checked on live objects only (as the verifier of Phase 5.9 does).

*Not modelled:* lines and blocks (I4 holds per object by construction), weak memory (sequential consistency assumed), racing writers to one slot, fibers, finalizers, interior pointers, no-scan data, large objects. I2 and I3 hold by construction. A pass means no counterexample in small configurations; it is not a proof for the full design.

*Open work:* a model extension of 1–2 pw (thread symmetry, partial-order reduction, fibers, a racing writer, several visible stacks at STW-1) must finish before Phase 4 starts; mixed blocks and line reuse before Phase 5.

**3. Barrier-cost findings (0.3)**

*Method.* `ldc2 -O3 -output-ll`, then `rewrite_ir.d` replaces every non-atomic, non-volatile `store ptr` (except to allocas) with the §4.4 fast path as an always-inline function, then `clang -O2 -c` (same LLVM 19.1.7), then link. Nine workloads, median of 5 (7 for the variant comparison). `--elide-fresh` skips stores into memory returned by an allocation call in the same function.

*Limitations.* The rewrite works on post-optimization IR, so LLVM could not hoist, merge or lay out the checks (mildly pessimistic); stores through `memcpy` and the bulk barrier are not covered; only code compiled into the module is rewritten, not precompiled Phobos or druntime; run-to-run noise is about ±5%, higher on sub-second workloads; no `perf`, so no cache-miss counts. Code size is the user object's `.text`, which overstates whole-binary growth.

*Time, geometric mean over the 9 workloads (ratio to unmodified code through the same pipeline):*

| Variant | No elision | Fresh-store elision |
|---|---|---|
| SATB (marking flag test only) | 1.027 | 1.004 |
| SATB + stack-visibility compare | 1.030 | 1.011 |
| SATB + publication, block table (value not mine) | 1.127 | 1.075 |
| SATB + publication + visibility | 1.128 | 1.097 |

*Publication fast-path variants (fresh elision and visibility on, both "stored value is mine" settings):*

| Publication check | Geometric mean | Worst workload | `.text` growth |
|---|---|---|---|
| Block table, value then slot | 1.054–1.058 | 1.46–1.61 (`tree2`) | ×1.46 |
| Block table, slot first | 1.043–1.070 | 1.55–1.70 (`tree2`) | ×1.45 |
| Per-thread contiguous arena | 1.013–1.017 | 1.25–1.28 (`tree2`) | ×1.31 |

SATB alone: `.text` ×1.10 with elision, ×1.16 without.

*`tree2` analysis.* `tree2` is `std.container`'s red-black tree with 100 live nodes: 81M barriered stores in 7M operations (11.6 per operation, one every ~5 ns), mostly relinking existing nodes that no elision rule can prove local. SATB costs 0–5% there; the arena publication check costs 30–43%, or 23–27% with the per-thread bounds marked `!invariant.load` (`--invariant`). The cost is the check itself (about five instructions and several dependent branches per store), not reloading thread state.

*Reading.*
- The SATB barrier meets M4 (≤3% geometric mean) when fresh-store elision applies.
- The publication barrier meets M4's geometric-mean limit (≤5%) only with a per-thread arena, and misses the worst-case limit (≤15%) in every variant. M9 (≤10% `.text`) is missed by all publication variants.
- The worst case is structural to store-dense mutation of existing nodes, so a real LDC implementation is unlikely to remove it.
- **Gate G0a is undecided and needs a project decision:** keep M4 as written, which shelves Track B, or restate the worst-case limit for publication (for example, geometric mean only, or opt-in per module with the cost documented). ADR-2's block layout should not be tied to per-thread arenas until that is decided. The arena itself needs its own ADR and a model update (a block globalized in place stays inside the thread's range, so the slow path must check the escaped bit).
- Not yet measured: cost while a cycle is running, static vs. shared druntime TLS models, Phobos unit tests for coverage, and a repeat with a real LDC change.

**4. Gate status**

| Gate | Status | Basis |
|---|---|---|
| G0a (barrier cost) | Undecided; SATB passes, publication fails the worst-case limit | §3 above |
| G0b (escape rate) | Not started | Needs 0.4 and an ownership-tracking layer |
| G0c (allocator) | Not started | Needs 0.6 |

**5. Changes to the plan caused by Phase 0**

- New rule in I5, §4.3, §4.4, Phase 4.7 and ADR-9: stack visibility. Phase 4 grows by about 1 pw (now 15–25 pw).
- Sweep-long protection of new and promoted objects, and the floating-garbage rule, added to I5.
- 0.3 now includes the visibility compare; 0.4 now counts `stackVisible` stacks; gate G4 now requires that the stacks scanned at STW-1 keep STW-1 within the M3 pause, otherwise Phase 4 switches to a barrier on stores to address-taken locals.
- A model-extension task (1–2 pw) was added before Phase 4. Phase 0 is now 8–13 pw; Track A totals 57–90 pw, and 87–140 pw with Track B.
- 0.5 was done as an executable model in D rather than TLA+: no Java was available, and an unrunnable spec would be unchecked. A TLA+ port is optional and would cross-check the model.

**6. What remains in Phase 0**

Superseded by the verdict and direction below. Done since this list was first written: the vibe.d server (0.1; dmd and LDC baselines in `plans/bench/`), the pause histogram (0.2, `plans/bench/pause_hist.sh`), the escape census (0.4), the model extension (0.5) and the allocator comparison including symgc (0.6). Still open: dmd compiling Phobos is measured only as a one-off (GC is 1.5% of a full compile, 12% of a semantic-only run); roadmap-size live sets (4–8 GiB); marking-on cost, static against shared druntime TLS, and Phobos unit tests under the barrier (0.3); fibers and Phobos-heavy code under symgc; a real LDC build for G0a.

**7. Reproduction**

```sh
# model: rebuild, run every clean and planted-bug case (about 5 minutes)
plans/model/run_all.sh
# barrier spike: build all variants and time them (about 20 minutes, needs ldc2 and clang)
SPIKE_OUT=/some/dir plans/spikes/barrier/run_spike.sh 5
SPIKE_OUT=/some/dir plans/spikes/barrier/run_variants.sh 7
# GC trace
./prog '--DRT-gcopt=trace:/tmp/gc.csv'
# baselines: dmd and LDC, CI tier (about 5 minutes) and full tier (about 4 minutes)
plans/bench/run_compare.sh -s ci -r 5 -o /some/dir
plans/bench/run_compare.sh -s full -r 3 -o /some/dir tree1 tree2 mt_alloc mt_share append_heavy parallel_map traverse_locality latency fiber_latency
# compare a new configuration against a saved one
plans/bench/compare_runs.sh plans/bench/results/ci.csv dmd new/results.csv dmd
```

**8. GC baselines (dmd 2.109.1, LDC 1.40.1; details and tables in `plans/bench/README.md`)**

Measured on a Ryzen 7 3800X (governor `powersave`), 15 workloads, 5 repetitions (`ci`) or 3 (`full`), medians. Results are in `plans/bench/results/`.

- **Both compilers run the same conservative collector**, so they are one baseline: collection counts match, GC time agrees within 10–20% on the GC-bound workloads, and LDC is 10–35% faster only where the mutator dominates (geometric mean of wall time 0.87). Compare a new GC against the same toolchain.
- **GC share of run time (dmd):** `rand_large` 33%, `traverse_locality` 31–40%, `tree1` 30–39%, `latency` 24–35%, `fiber_latency` 24–32%, `rand_small` 21%, `dlist`/`slist` 10%; about 5% or less for the rest (`mt_alloc` 5–6%).
- **M3 baseline.** Pauses are stop-the-world and scale with the live set: 57 ms at 256 MiB, 552 ms at 2 GiB (about 0.22–0.27 ms per live MiB, for a mostly pointer-free object mix), so about 1.1 s at 4 GiB by extrapolation. The mutator's worst request is 5–8% above the max pause. With 30k suspended fibers and 512 MiB live the max pause is 170 ms, about 30–60 ms more than the live set alone explains.
- **Tail latency.** p50 ≤ 1 µs and p99 2–4 µs, but p99.9 is 225–250 µs in the large-heap runs, with only about 10 collections in the run. A shorter pause does not by itself improve it.
- **Memory.** Peak RSS is 2.6× the live set at 2 GiB (5.3 GiB), and 1.9 GiB for `frag_longrun`. An earlier draft of this section reported 1.3 GiB for `mt_alloc`; that was a benchmark bug (every node stayed reachable) and is fixed. Now `mt_alloc` peaks at 3–6 MiB, with 2284 collections at 8 threads.
- **Allocation scalability (M1 baseline).** `mt_alloc` at 8 threads × 4M allocations takes 8.1 s (dmd) and spends 31 s in the kernel against 33 s in user code: signal-based stop-the-world and the global allocator lock. This is the number the lock-free fast path must improve.
- **Method hazard.** LDC's GC2Stack pass removes allocations that do not escape. Five benchmarks (`latency`, `fiber_latency`, `mt_alloc`, `traverse_locality`, `tree1`) were changed so that their garbage escapes; before that, LDC looked 2.5× faster. The Phase 0.3 spike ratios for `tree1`, `mt_alloc` and `traverse_locality` were taken on the old versions and must be re-measured (`tree2`, the M4 worst case, is unaffected).
- **Limits found:** `fiber_latency` aborts above about 30k fibers because `vm.max_map_count` is 65530; `parallel_map` and `rand_large` spend as much or more time in the kernel than in user code (not investigated); `--DRT-gcopt=profile:1` has millisecond resolution, so sub-millisecond pauses need the `trace:` option.

#### Phase 0 verdict (gates G0a, G0b, G0c)

Written from the measurements in this section and in `plans/bench/`, `plans/spikes/{barrier,immix,census}/` and `plans/model/`. Where a measurement used a stand-in, the verdict says so. Items still open are listed at the end; none of them can reverse a *fail* below, but two could reverse a *pass*.

| Gate | Verdict | Basis |
|---|---|---|
| **G0a** barrier cost | **Fail as written; Track B shelved unless M4 is restated** | M4 asks ≤ 5% geometric mean and ≤ 15% worst case for SATB + publication. Table-based publication: 1.05–1.07 geometric mean, 1.46–1.75 worst (`tree2`), `.text` ×1.45 (M9 asks ≤ 1.10). The arena variant meets the geometric mean (1.02) but not the worst case (1.26–1.34) or M9 (×1.31). SATB alone passes (1.00, worst 1.07, `.text` ×1.10). The `tree2` cost is the check itself, not thread-state reloads, so a real LDC change is unlikely to remove it. The spike works on post-optimization IR, which is pessimistic, and no real LDC change was measured. |
| **G0b** escape rate | **Fail for programs that share data; pass for programs that do not. Track B would be opt-in per thread at best** | M7 asks ≤ 20% of bytes promoted. Measured (bytes escaped): `mt_alloc`, `tree1`, `tree2`, `dlist`, `slist`, `latency`, `frag_longrun` 0%; `mt_share` 19.7% (at the limit); `conmsg` 67.7%; `parallel_map` 86.9%, 93% of objects, from the `std.parallelism` result-array pattern. Any program that uses `std.parallelism` or message passing for its bulk data fails M7. The census sees only code compiled into the module, and the coverage audit found 1–3 unexplained static-data references per run, so these are lower bounds. |
| **G0c** allocator | **Fail for non-moving Immix; build on symgc (measured, see the symgc subsection below)** | The gate needs RSS within 10% of symgc, throughput at least on par, and a measurable cache-miss reduction. On the same collector and large-object space: throughput passes (Immix allocates 1.2–1.3× faster, 8 threads included). Steady-state RSS fails on every small-object workload: +37% (objects ≤ 128 B), +153% (16 B–2 KiB), because every block keeps at least one live line (26% block occupancy against 49%). `frag` with large objects shows +10% only because 83% of its bytes sit in the shared large-object space. Locality does not pass: with the Immix paper's policy, traversal is 5.5× slower (3.7M cache misses per traversal against 0.17M); with medium objects forced to overflow blocks it ties segfit (−3.5% misses). Side metadata is 6–8% of heap against 2.2%. Engineering cost is similar (252 against 212 lines for the two allocators). **Caveat:** the comparison is against my own size-class allocator built on the SDC/symgc design, not symgc, which was not available. Immix without evacuation cannot recover this fragmentation, and the RFC fixes I3 (non-moving), so the result is structural, but symgc's absolute numbers are unmeasured. |

**symgc measured (`plans/bench/core_bench/`, repo dmd 2.113 and druntime, same workloads, medians of 3).** symgc builds and runs against this repository's druntime (the system dmd and LDC druntimes are too old: no `tlsGCData`).

| | conservative | symgc | M-target |
|---|---|---|---|
| `alloc`, 8 threads | 4.1 Mops/s | 45.5 Mops/s (**11×**; fork 4.7) | M1 ≥ 3×: **pass** |
| `alloc`, 4 threads | 8.4 | 35.7 (4.2×) | |
| `alloc`, 1 thread | 20.4 | 15.8 (0.77×) | M2 ≥ 0.95×: **fail** (this workload) |
| steady RSS: `frag` / `fragsmall` / `tree` / `trav` / `latency` 1 GiB | 979 / 1011 / 299 / 344 / 1731 MiB | 634 / 762 / 207 / 209 / 1379 MiB (0.61–0.80×) | M5 ≤ 1.0×: **pass** |
| `trav` traversal | 36.5 ms | 24.8 ms (1.5× faster) | locality: better |
| `frag` (large objects) / `fragsmall` | 11.7 s / 8.5 s | 42.5 s (**3.6× slower**) / 14.1 s (1.7× slower) | |
| `latency` largest request, 256 MiB / 1 GiB | 122 / 506 ms (parallel: 135 / 244) | 28 / 89 ms (fork: 7 / 20, at +37% / +18% RSS) | M3 ≤ 2 ms: **fail** |

Findings about symgc: it is stop-the-world with parallel mark threads and per-thread caches (no global lock); no concurrent marking, no fork mode. Its slowness on `frag` is kernel time (174k `madvise` calls per 2M steps, one per freed large object), a decommit policy that can be tuned. Its pause grows with the heap (0.087 ms per live MiB, about 350 ms at 4 GiB). Linking symgc into a binary makes the *conservative* collector about 40× slower (it scans symgc's static data), so comparisons need separate binaries.

**What this means for the goal ("the best and fastest GC for D").** symgc already delivers what Immix was meant to: lock-free multi-thread allocation (M1), lower memory (M5), better locality. The remaining gaps are exactly Track A's: pauses (M3) and the single-thread fast path, plus the large-object decommit policy.

**Consequences for the plan (ADR-2, ADR-9, Phases 1–5)**
1. **ADR-2 is reversed: adopt symgc as the base and build on it.** Phases 1–2 shrink from "write an Immix heap" to "bring symgc up to parity with the tests and fix its gaps": run druntime's tests and the project tester under `gc:sdc`; tune large-object decommit (frag 3.6×); recover single-thread throughput (0.77×); add the missing features (precise scanning, `fork`, config/trace options, Windows). Add SATB concurrent marking (Track A) on its mark threads and thread caches. Keep from the Immix work only what helps symgc. Phase 1 must be re-estimated; the 16–24 pw figure assumed a new Immix heap. Upstream is Symmetry Investments' port of SDC (MIT), so this is a collaboration or fork decision.
2. **Track A stands.** SATB passes M4 and M9. The baselines give the targets: M3 (stop-the-world max pause 0.22–0.27 ms per live MiB, 552 ms at 2 GiB, 130 ms with 2000 idle fibers and 256 MiB), M1 (`mt_alloc`, 8 threads: 8.1 s, 31 s of kernel time against 33 s of user time).
3. **Track B is not funded by Phase 0.** It needs both a restated M4 worst case and an escape rate that holds for the target workloads. Neither is shown. Keep the design and the model; do not start Phase 5 unless a real LDC change gets `tree2` under 15% and a representative service workload gets under 20% escape.
4. **New requirement from the model extension (applies to Track A).** The marking-flag test and the store must not be separable by a stop-the-world signal. With the barrier as written, a cycle that starts between the test and the store loses the stored object (model counterexample, 10 steps). Either the sequence is restartable (the signal handler rolls back a PC inside it) or the store is an exchange followed by the flag test. The exchange form passed 49.7M states; the plain form fails. Add this to I5 and §4.4 before Phase 4.
5. **Fiber scanning rule confirmed.** Switch-in scanning of an unscanned fiber is necessary: dropping it is detected (13-step counterexample).
6. **Explicit free during marking needs the deletion barrier on the freed block's fields** (11-step counterexample, found while checking the slab-level lazy-sweep design; see "Lazy-sweep design checked in the protocol model").

**Still open in Phase 0 (does not change the verdicts above)**
- symgc is now measured (above) on Phobos-free workloads only. Still unmeasured: fibers and the vibe.d server under symgc (they need a Phobos matching the repo druntime), symgc under the druntime and project test suites, and Windows.
- A real LDC change for G0a (needs the LLVM development package). Could reverse G0a to pass for the arena variant only if `tree2` drops under 15%.
- Roadmap-size live sets (4–8 GiB) and the model at 3 threads / 5 objects exhaustively (reached by random walks only, which found 9 of 10 planted bugs).
- Phobos unit tests under the barrier, marking-on cost, static against shared druntime TLS.

#### Direction (decided after the symgc measurements)

**Goal set by the project owner:** real-time games with a full GC and imperceptible pauses, and other latency-sensitive programs. Peak performance is the priority, and forking symgc is acceptable. This replaces the throughput-first reading of M3: the metric is the **worst frame**, not the 99th percentile.

**Target.** At a live heap of 2 GiB or more, on a 60 fps loop: no frame delayed by the collector by more than 1 ms (worst case, not p99), and fewer than 0.1% of frames delayed by more than 0.25 ms. Allocation tail latency is part of this, not only pauses.

**Measured gap (`frames.sh`, 2 GiB live):** conservative 570 ms worst frame; fork marking 40 ms; symgc 112 ms. The first run showed symgc delaying 1027 of 1200 ordinary frames by more than 1 ms and I attributed it to allocation jitter. **That did not reproduce and the attribution was wrong** (follow-up run with `FRAMES_DUMP=1` and `strace -f -T`, same machine): at 2 GiB, 32 frames over 1 ms and p50 0.67 ms; at 512 MiB, 90 over 1 ms. The frames over 2 ms are exactly the collections, evenly spaced (every ~114 frames at 512 MiB, 20 ms growing to 35 ms as the heap grew; four collections at 2 GiB of 56, 73, 78 and 89 ms), run by the allocating thread. The main thread made ~19.8k `madvise(MADV_DONTNEED)` calls in 20 s (mostly 4 to 16 KiB; 8 µs each, 0.8% of the time, longest 0.29 ms), so decommit is a small, steady cost, not a source of multi-millisecond frames. The first run's 1027 was most likely machine noise (the `powersave` governor). **The gap is therefore pauses, not allocation jitter**; the p50 frame time (symgc 0.67 to 1.17 ms against 0.5 to 0.75 ms) is the allocation-speed difference seen in `alloc-1t` (0.77×).

**Design, in priority order**
1. **Fork symgc** and keep it mergeable upstream where that is cheap. Its thread caches, extent map and parallel mark threads are the right base.
2. **Allocation speed and tail latency** (cheap; measured to be secondary to pauses, see "Measured gap"; matters for `frag` and 1-thread throughput): no system call on the allocation path (move `madvise`/`mmap` to a background thread with a retained pool); batch thread-cache refills; optional pre-faulting of pools; bounded work per slow path. Test: `frames` with the 1 ms count under 0.1%.
3. **Concurrent marking with bounded stop-the-world work (Track A, SATB).** The two pauses must be O(threads), not O(heap): a short STW-1 that only flips the `marking` flag and scans stacks already visible to others, per-thread handshakes, mark threads running beside the program, and a remark that only drains buffers. Target: each pause under 200 µs at 8 GiB. Include the restartable barrier or exchange-then-test sequence (model finding), and the stack-visibility rule.
4. **Concurrent sweep and bounded recycling.** No whole-heap sweep in a pause; lazy per-extent sweep; decommit decisions off the mutator path.
5. **Pacing.** Start cycles early enough from the measured allocation rate; if the program outruns the collector, throttle allocators in small bounded steps (mutator assists) instead of stopping the world.
6. **Game-facing controls** (designed with the first users): a pause budget and a way to ask for a collection step between frames; threads that opt out of the GC entirely (audio and render threads that must never be suspended: no GC allocation, stack not scanned); core pinning and priority for the mark threads; per-cycle statistics for a frame profiler.
7. **Track B stays shelved**; revisit only if a real LDC build shows the barrier under 15% on `tree2`.

**Order of work** (replaces Phases 1–5 of this document for planning; the old text stays as design background):
- **P1** fork, test parity, build setup in the repo, benchmark gates in CI (`frames`, `alloc`, `frag`): 3–5 pw.
- **P2** allocation speed and decommit policy: 3–5 pw. Exit: `alloc-1t` at least equal to the conservative collector; `frag` within 1.5× of the conservative collector.
- **P3** SATB barrier in the compiler (LDC and dmd), model re-run with the new sequence rule, concurrent marking: 15–25 pw. Exit: worst pause under 1 ms at 2 GiB.
- **P4** concurrent sweep, pacing, opt-out threads, controls: 8–12 pw. Exit: worst frame delayed under 1 ms at 8 GiB on the `frames` and a real game-shaped workload.

**Pause anatomy of symgc (phase trace, `bench/core_bench/symgc_phase_trace.patch`):** at 2 GiB live the stop-the-world part (prepare + mark, 16 threads) is 33 ms and the sweep that follows the restart is 22 to 47 ms, run synchronously by the triggering thread while holding each arena's page-filler mutex. So the worst frame is **about 40% mark and 60% sweep**, and mark on one thread is 268 ms (0.13 ms/MiB; 9× speedup at 16 threads). Consequences for the design order: (a) a *lazy, bounded, per-block sweep with the lock released between blocks* is the first and lowest-risk cut (no barrier, no model change) and removes more than half of today's worst frame; it also lets the finalizer policy be decided explicitly (finalizers now run on the triggering thread); (b) concurrent SATB mark (P3) is needed for the remaining 12 to 33 ms and must run on one or two background cores, since a game cannot lend 16; (c) P2 and the sweep work should be merged into one phase "bounded work in every slow path". Work order is updated accordingly: **P2 = lazy sweep + decommit policy + allocation speed**.

**Lazy-sweep prototype: analysis, not a patch (decided after reading `page.d`, `bin.d`, `extent.d`, `tstate.d`).** Two facts change the picture. (1) *Probation*: after the restart, a thread that enters the allocator waits until the whole cycle ends, so an allocating game thread loses mark + sweep, not only the stop-the-world part. Letting threads allocate during the sweep is the actual goal, and it is not just "run the sweep elsewhere". (2) Sweep cost split at 2 GiB (ms): dense scan 3–13 (grows with garbage), sparse scan 12–15 (constant, every live sparse extent), dead-extent free 0.5–4, decommit 1–5. Requirements for allocating during the sweep, found in the code: (a) objects allocated after the mark must survive: new extents need a "born after mark" flag (`Extent._pad1` is free) that the sweep skips, and slots handed out from cached or old slabs must be marked or taken only from slabs already swept; (b) `Bin.batchFreeImpl` does `slabs.remove(e)` when a slab becomes empty and `slabs.insert(e)` when it becomes non-full, but the sweep empties the bin heaps first (`clearForCollection`) and rebuilds them at the end, so a concurrent free into an unswept slab corrupts the heap: the sweep must hold `Bin.mutex` per extent, re-insert as it goes, and unswept slabs need an explicit state; (c) slab bit updates are marked "not atomic" in `finalizeSlabNimble`; (d) finalizers must run somewhere defined (today the triggering thread, with `runningFinalization` set); (e) `minimize`/`freePagesImpl` work on blocks under the filler mutex and must be chunked. These are one coherent change (lazy per-extent sweep with an `unswept → swept` state, swept on demand at refill and by a background sweeper), about the size P2 already budgets, and must be covered by the protocol model before it is written (new actions: free into an unswept slab, allocation during sweep, refill sweeping on demand). Cheap, safe interim wins that do not need it: parallel sweep by block with the existing GC threads while the world is stopped (the scan is data-parallel), and skipping extents with no garbage.

**Lazy-sweep design checked in the protocol model (`plans/model/README.md`, `--slabs --free`).** Rules that pass exhaustively (1 to 2 threads, 3 to 4 objects, 2 slabs) and in 1.5M random cycles: (1) the sweep empties the bin heaps at its start and puts each slab back when it is swept and has a free slot; (2) allocation takes slots only from slabs that are in a bin, so during a sweep only from swept slabs, and needs no marking; (3) a free into a swept slab re-inserts it on the first free slot, a free into an unswept slab only clears the slot (the sweep inserts it, otherwise it is in the heap twice); (4) a slab that becomes full leaves the bin. Each of the three ways to break them (`allocunswept`, `freeunswept`, `missedinsert`) is detected in 3 to 7 steps. **New design finding (6):** an explicit `GC.free`/`delete` during marking must run the deletion barrier on the freed block's pointer fields; otherwise a mutator can load a child out of a grey, untraced object, free the parent, and the child is swept while still on its stack (11-step trace, independent of slabs). The same applies to any path that drops a pointer-containing block outside a store: array shrink with reuse (`assumeSafeAppend`, `.length = 0` then reuse), `destroy` followed by free, and realloc that moves. The druntime/symgc audit is done (`plans/audit/druntime_edge_deletions.md`): `free`/`delete`, `realloc` that moves or shrinks a large block, and `removeRoot`/`removeRange` need a release barrier (one `shadeBlock` in the GC covers the first group; `removeRoots` shades the removed range, verified in the model as `--rootrm`, `noremoveroot` found in 10 steps); bulk `memcpy`/`memset`/array assignment over live pointer memory needs a guarded bulk pre-barrier in the compilers and druntime (the barrier spike did not include it, so its cost figures are a lower bound); appends, slack, attributes and cache flushes are safe; finalizer resurrection under a lazy sweep is not modelled. **Thread creation and exit are now modelled** (`--threadlife`): a thread started during marking must be registered as not yet handshaken (the collector scans it; loses the closure otherwise, `startnoscan`, 8 steps), an exiting thread must flush its SATB buffer (`exitnoflush`, 8 steps), and all per-thread cycle state must be reset at registration. Passes exhaustively (2 threads) and in 300k short random walks (3 threads).

**Still to measure before P3 starts:** fibers and `std.*`-heavy programs under symgc (needs a Phobos matching the repo druntime), symgc under the druntime and compiler test suites, a real LDC build for barrier cost, and an actual game-like workload from the project owner.

**Next steps, in order (first actions of P1 to P3)**
1. **Fork symgc and set up the project** (1 to 2 days). Put it in its own repository (it is Symmetry Investments' MIT code; this tree only holds a local copy at `symgc/`, uncommitted). Make it build against this repository's druntime in CI. Turn `frames`, `alloc` and `frag` from `plans/bench/core_bench/` into pass/fail gates so every later change is measured. Decide at the start whether to keep the fork mergeable with upstream; that is far cheaper than reconciling later.
2. **Run symgc under the real test suites** (druntime tests, compiler tests, fiber-based code). Nothing has been measured there, and a failure is a blocker found cheaply. Fibers and Phobos-heavy code need a Phobos checkout that matches this repository's druntime. **Needs from the project owner:** that checkout, or approval to download it.
3. **Fix the decommit policy and the single-thread allocation speed** (P2, 3 to 5 pw; lower priority than step 5 after the `FRAMES_DUMP` finding: the frames over 2 ms are the collections, see "Measured gap"). Move `madvise`/`mmap` off the allocation path into a background thread with a retained pool; batch thread-cache refills; bound the work in every slow path. Also fixes `frag` (3.6× slower than the conservative collector, 174k `madvise` calls per 2M steps). Exit test: `frames`, fewer than 0.1% of frames above 1 ms.
4. **One real LDC build to confirm the barrier cost** before the compiler work in P3. **Needs from the project owner:** approval to install the LLVM development package.
5. **Concurrent marking** (P3, 15 to 25 pw): the SATB barrier in LDC and dmd with the restartable-sequence rule from the model, then the concurrent mark phase. Re-run `plans/model/run_all.sh` with the final sequence first.
6. **In parallel, from the project owner:** a real game-shaped workload (or a description of one: live heap size, allocation per frame, thread count, whether audio and render threads allocate). The synthetic `frames` loop is a proxy; the 1 ms target should be tuned against something real.

**Decisions recorded:** build on symgc, fork allowed; Immix rejected; Track B shelved; the metric is the worst frame, not p99.

### Phase 1 — `gc:immix` core: STW, parallel marking, TLABs `[Track A]`
**Goal.** A complete and correct implementation of `core.gc.gcinterface.GC` on an Immix heap that passes every test suite. No compiler changes.
**Depends on.** G0c.

- [ ] **1.1 Module layout.**
  - Create `druntime/src/core/internal/gc/impl/immix/` with:
    - `gc.d`: the `final class ImmixGC : GC`;
    - `heap.d`: reservation and side tables;
    - `alloc.d`: AllocBuffers, holes, overflow blocks, block recycling;
    - `los.d`, `mark.d`, `sweep.d`, `finalize.d` and `arrays.d`.
  - List the files in `druntime/mak/SRCS`, and in `mak/COPY`/`mak/DOCS` wherever the `impl/conservative` files are listed.
- [ ] **1.2 Registration.** A `pragma(crt_constructor)` that calls `registerGCFactory("immix", &initialize, &threadInitImmix)`, mirroring `gc.d:117-136`. Add `gc:immix` to the help text in `config.d`.
- [ ] **1.3 Heap reservation and side metadata (§3.1, §5).** Use `core.internal.gc.os` to map, commit and decommit. Implement the 32-bit chunk table.
- [ ] **1.4 Thread integration.**
  - Keep AllocBuffers in `ThreadBase.tlsGCData` (`threadbase.d:128`).
  - Hook `initThread`/`cleanupThread` (`gcinterface.d:286,300`).
  - Retire partially used holes at thread exit.
  - Make the child of a fork safe (only the forking thread survives).
- [ ] **1.5 Allocation.**
  - Small, medium (overflow block) and large (LOS) paths.
  - `ALIGNMENT_*` attributes (`memory.d:361`) through hole padding; alignments above 4 KiB go to the LOS.
  - Pick the block kind from `NO_SCAN`/`FINALIZE`/`STRUCTFINAL`.
  - Copy the precise pointer bitmap when `ti` is non-null.
- [ ] **1.6 Heap sizing and triggers.** Honour `heapSizeFactor`, `heapSizeLimit`, `initReserve` and `disable`. Re-interpret `minPoolSize`/`maxPoolSize`/`incPoolSize` as steps for reserving blocks.
- [ ] **1.7 Marking.**
  - Stop the world with `thread_suspendAll`/`thread_scanAllType`.
  - Take roots from `rangeIter`/`rootIter`, reusing the `core.internal.container.treap` approach.
  - Resolve ambiguous pointers through the start/end bitmaps, with a bounded backward search.
  - Honour `NO_INTERIOR`.
  - Scan objects precisely or conservatively.
  - Parallel marking with work stealing (`parallel:N`).
- [ ] **1.8 Line marking.** Exact for medium objects. Conservative for small objects, also marking the following line.
- [ ] **1.9 Sweep.**
  - Classify lines and blocks.
  - Reconcile start bits (§3.3).
  - Return empty blocks to the OS under `minimize`.
  - Sweep the LOS.
  - Reclaim lines lazily, per block, on first reuse.
- [ ] **1.10 Finalization.**
  - Walk the finalize bitmaps and call `rt_finalizeFromGC` (`druntime/src/rt/lifetime.d:529`).
  - Implement `runFinalizers(segment)` through `rt_hasFinalizerInSegment` (`lifetime.d:422`), for shared-library unload.
  - Support `inFinalizer` and all three `cleanup:` modes.
- [ ] **1.11 Arrays.**
  - Implement `getArrayUsed`/`expandArrayUsed`/`reserveArrayCapacity`/`shrinkArrayUsed`, including the atomic variants.
  - Define a capacity rounding policy.
  - Clear the per-thread block-info caches after each collection, as the conservative GC does (`thread_processTLSGCData(&clearBlkCacheData)`, `gc.d:3184,3417`).
- [ ] **1.12 API completeness.** `addrOf`, `sizeOf`, `query`, `get/set/clrAttr`, `free`, `realloc`, `extend`, `reserve`, `minimize`, `stats`, `profileStats`, `allocatedInCurrentThread`, roots and ranges.
- [ ] **1.13 Debug modes.** `MEMSTOMP`, sentinel guards, `INVARIANT` and Valgrind annotations, mirroring the conservative GC's `debug` switches.

**Tests.**
- Add `immix` and `immix_precise` targets for `druntime/test/gc/*`, next to `precise.done` (`druntime/test/gc/Makefile:72`).
- Run the druntime and Phobos unit tests with `rt_options = ["gcopt=gc:immix"]`.
- Add a CI job that runs `compiler/test/runnable` under `gc:immix`.
- New stress tests:
  - an allocation/free/realloc fuzzer checked against a shadow model;
  - a test that ambiguous pointers cannot bring dead objects back;
  - finalizer coverage, including classes whose only destructors are field destructors (cf. #23979);
  - appendable-array semantics.

**Exit gate G1.** All suites pass; M1, M2 and M5 are met; no pause regression against the conservative GC with `parallel`.
**Estimate.** 16–24 pw.

### Phase 2 — Fork-based concurrent marking for Immix `[Track A, POSIX]`
**Goal.** Shorter pauses without any compiler work, by reusing druntime's `clone`/`fork` approach (`gc.d:3204-3290`).
**Depends on.** G1.

- [ ] **2.1** Put the mark bitmaps in `MAP_SHARED` memory, so the parent sees the child's marks.
- [ ] **2.2** Allocation epochs: blocks and holes allocated after the fork are excluded from that cycle's sweep, so objects allocated during the cycle survive it.
- [ ] **2.3** Keep `fork:1` behaviour identical to the conservative GC, including the fallback to in-process marking on error, and `disableFork`.
- [ ] **2.4** Record copy-on-write cost in the trace. Skip forking when the projected copy-on-write cost exceeds a threshold.

**Tests.** `druntime/test/gc/forkgc.d`, `hospital.d`, `concurrent`, `precise_concurrent` and `issue22843.d`, run under `gc:immix fork:1`.
**Exit gate G2.** The fork column of M3 is met on Linux; no correctness regressions.
**Estimate.** 4–6 pw.

### Phase 3 — Precise static-data/TLS roots and precise heap by default `[Track A, all compilers]`
**Goal.** Remove false retention caused by data segments and TLS.
**Depends on.** G1. Can run in parallel with Phase 2.

- [ ] **3.1 Frontend.** For every module, generate a root enumerator. It reports (address, size, `RTInfo` bitmap) for each module-level or `static` variable (TLS, `shared`, `__gshared`) whose type contains pointers. For TLS it is a function evaluated in each thread. Union fields that overlap pointers are reported as conservative words.
- [ ] **3.2 `ModuleInfo`.** Add the flag `MIgcRoots = 0x4000` and its optional field (`druntime/src/object.d:2312-2330`). DMD emits it in `compiler/src/dmd/glue/package.d`; LDC and GDC emit it in their own glue code.
- [ ] **3.3 druntime.** When every module of a DSO has `MIgcRoots`, register typed ranges instead of the whole writable segment (`sections_elf_shared.d:809`, `rt/memory.d:23`, and the Mach-O/PE `sections_*` equivalents). Otherwise keep the conservative segment for that DSO.
- [ ] **3.4 Precise heap by default** under `gc:immix`. Optionally type closure frames, by passing a pointer bitmap of the frame to a typed variant of `_d_allocmemory`.

**Tests.**
- A false-pointer suite: large integer arrays in static, TLS and heap data whose values equal live object addresses, asserting that those objects are still reclaimed.
- Cross-compiler builds where only some modules carry `MIgcRoots`.

**Exit gate G3.** M6 is met; root-scan time is no worse than conservative; full suites pass.
**Estimate.** 8–12 pw.

### Phase 4 — Barrier infrastructure and SATB concurrent marking `[Track A, LDC + DMD]`
**Goal.** Pauses under 2 ms on every platform, plus the store-site infrastructure that Track B extends.
**Depends on.** G1 and G3 (precise roots shorten the remaining pause).

- [ ] **4.1 Store-site taxonomy** (frontend and backends):
  - (a) scalar pointer stores: `T*`, class and interface references, slice and delegate pointers, AA handles;
  - (b) copies of aggregates that contain pointers (assignment, blits, postblit and copy constructors);
  - (c) druntime bulk hooks: `_d_arraycopy`, `_d_arrayassign*`, `_d_arraysetassign`, `_d_arrayappend*`, `_d_arraycatnTX`, `core.lifetime.move`/`moveEmplace`/`copyEmplace`;
  - (d) `core.atomic` pointer operations;
  - (e) code exempt from barriers, such as the GC itself, marked with a `pragma` or UDA.
- [ ] **4.2 Runtime ABI.**
  - `gcThreadState` (initial-exec TLS), `_d_gc_satbFlush` and `_d_gc_bulkPreWrite(dst, len, ptrmap)`.
  - `_d_gc_store(slot, v)`: the complete barrier, out of line. DMD calls it at every store site; LDC uses it as its slow path.
  - The compiler switch `-gc-barriers=none|satb|satb+publish` (ADR-4).
  - Predefined `version (D_GCBarriers)`, plus `version (D_GCPublish)` for `satb+publish`.
- [ ] **4.3 Marking compiled modules.** Add `MIgcBarriers = 0x8000` and `MIgcPublish = 0x10000`. The runtime checks every module at startup and on `dlopen`. If any module lacks `MIgcBarriers` it falls back to STW/fork marking; if any lacks `MIgcPublish` it disables local domains.
- [ ] **4.4 LDC.**
  - Emit barriers during IR generation: fast path inlined, slow path `cold`/`noinline`.
  - Omit them for allocas that do not escape, and for initializing stores into fresh objects.
  - Keep `GC2Stack` working.
  - Add a `-gc-barriers` driver flag.
- [ ] **4.5 DMD (ADR-4).**
  - At every site in the store-site taxonomy, emit an out-of-line call from `compiler/src/dmd/glue/e2ir.d`: `_d_gc_store`, or `_d_gc_bulkPreWrite` for aggregates. This covers both barrier modes, so Track B can be tested in this repository's CI.
  - Omit the call only for direct stores to locals that do not live in a heap closure frame.
  - Emit `MIgcBarriers` and `MIgcPublish`.
  - Performance is not a goal: §8 is measured with LDC.
- [ ] **4.6 druntime bulk paths and `core.atomic`.** Call the bulk and scalar barriers explicitly.
- [ ] **4.7 Collector (pause structure of §4.3, invariant I5).**
  - **STW-1.** Set `marking` and allocate-black (blocks taken during the cycle count as live). Clear every thread's `stackScanned` flag and reset every stack context's scan state. The only stacks scanned in this pause are those flagged `stackVisible` (§4.3, I5), as one group. Add the `_d_gc_stackEscaped` slow path of §4.4: it sets `stackVisible`, self-scans first if a cycle is running, and (Track B) globalizes. `Thread.start` and the C hand-off hooks of ADR-7 call it for stack-address arguments.
  - **Global roots.** Scan the precise global data roots concurrently. This is safe because stores into globals are barriered.
  - **Per-thread handshakes.** Suspend one thread at a time, using the private per-thread `suspend`/`resume` that already exist (`druntime/src/core/thread/osthread.d:766,872`), exposed to the GC as an internal API. Scan its registers, its current stack context, every context suspended under it (the `StackContext.within` chain), and its TLS. Set `stackScanned` and resume it. Each pause is bounded by one thread's stacks.
  - **Fiber stacks.** Add a scan state to `StackContext` (`druntime/src/core/thread/context.d:15`): `unscanned → scanning → scanned`.
    - Background mark workers claim suspended fibers with a compare-and-swap and scan them.
    - `FiberBase.switchIn` (`druntime/src/core/thread/fiber/base.d:597`) scans an `unscanned` fiber itself before switching in. If a worker is in the middle of scanning it, it waits.
    - So once a thread has passed its handshake, whatever it is running is always already scanned.
  - **Tracing.** Concurrent and parallel. SATB buffers are flushed to a global queue.
  - **STW-2 (mark termination).** A handshake flushes every SATB buffer. Check that every thread and stack context has been scanned (scan any stragglers), then finish draining. **No stack is rescanned.**
  - **Sweep.** Concurrent and lazy, per block.
- [ ] **4.8 Coverage verifier.**
  - `--DRT-gcopt=verify:1` stops the world at the end of each cycle, retraces from scratch, and reports any object that is reachable but unmarked.
  - A compiler mode, for testing, that sends every barrier through its slow path.

**Tests.**
- The full suites under `gc:immix` with SATB marking and `verify:1`.
- A randomized stress test that swaps pointers between threads during marking.
- Fiber tests during marking:
  - random `switchIn` order;
  - fibers writing through pointers into each other's suspended stack frames (the eventcore waiter pattern);
  - fibers created during the cycle.
- `fiber_latency` in CI.
- Windows CI, where fork marking does not exist.

**Exit gate G4.** The SATB column of M3 is met on both `latency` and `fiber_latency`, and M4 and M9 for SATB, on Linux and Windows. The verifier reports zero misses across the suites. In the 0.4 census workloads, the stacks scanned at STW-1 (the `stackVisible` group, I5) keep STW-1 within the M3 pause; if they do not, Phase 4 switches to a barrier on stores to address-taken locals (ADR-9).
**Estimate.** 15–25 pw (LDC 6–8, DMD 3–5, druntime 5–8 including one-stack-at-a-time scanning, the fiber scan states and the handshakes, the stack-visibility rule, and updating the model 0–3).

### Phase 5 — Thread-local collection domains `[Track B, gated]`
**Goal.** Per-thread collections that never stop other threads, without changing D semantics.
**Depends on.** G0a, G0b, G4.

- [ ] **5.1 Ownership.**
  - Owner codes in the block table, and the escaped bitmap.
  - Owner ids for the main thread, threads started through `Thread`, and threads registered with `thread_attachThis`.
  - Threads beyond the id limit go to `GLOBAL` (no domain).
- [ ] **5.2 Routing.**
  - `_d_newclassT` uses `static if` on `shared`/`immutable`.
  - Pass `isShared` through in `_d_newarrayU` and `_d_newarraymTX`, and include `immutable` in it.
  - Add the `isShared` argument to `_d_newitemT` and `_d_arrayliteralTX`. This changes the frontend (`expressionsem.d:6621` and `:5362`) and druntime.
  - Add `BlkAttr.SHARED_HINT`.
  - In `_d_newarrayU` and `_dup`, route `immutable` from the template argument (`is(T == immutable)`). `.idup` already reaches `_d_newarrayU!U` with `U = immutable(char)` (`druntime/src/core/internal/array/duplication.d:24`).
  - New options: `localheaps:0|1` (default 0 until Phase 9) and `immutableGlobal:0|1`. `immutableGlobal` defaults to 1 *provisionally*; the G0b data decide (ADR-3).
  - Allocation-site routing cannot see buffers that start out mutable and later become `immutable` (`assumeUnique`, the unique result of a pure function). Those stay local and are published on escape, which is cheap (5.3).
- [ ] **5.3 Publication slow path.**
  - Find the start of the object.
  - If it is not escaped, promote it and everything it reaches, within a work budget. Use precise scanning when the type is known, conservative otherwise.
  - Mark the affected blocks *mixed*.
  - During a global cycle, queue promoted objects for scanning (I5).
  - Objects in no-scan blocks (strings, numeric arrays) promote in O(1): one escaped bit, no tracing, no budget used. Their remaining cost is that more blocks become mixed and take the slow path; 0.4 and G0b measure how much.
- [ ] **5.4 Globalization.** Switch every block owner, stamping an epoch (I5). Takes time proportional to the number of blocks. Triggered by:
  - an escaping stack address;
  - thread exit, after a final local collection. `GC.cleanupThread` covers only threads started by druntime; it is called neither for the main thread nor for threads attached from C (`gcinterface.d:290-300`). The remaining exits need their own hooks:
    - `thread_detachThis`/`thread_detachByAddr` (`threadbase.d:915,943`), for threads attached from C;
    - a pthread-key destructor (fiber-local-storage callback on Windows), for attached threads that exit without detaching;
    - `rt_term`, for the main thread, which then follows the `cleanup:` mode;
  - fiber migration;
  - `dlopen` of a module without `MIgcPublish`;
  - running out of promotion budget;
  - a verifier failure.
- [ ] **5.5 Explicit publication.**
  - In `Thread.start`.
  - In `GC.addRoot`/`addRange`.
  - A new `GC.publish`/`gc_publish`, exposed through an optional extension interface (`interface GCPublish`, found by casting) so other GC implementations such as symgc keep working.
  - In the `core.atomic` pointer operations.
- [ ] **5.6 Local collection.**
  - Trigger: `localHeapFactor`.
  - Roots: registers, the thread's own stack contexts and its TLS. This requires recording an owner on each `StackContext`, because today all contexts share one global list (`threadbase.d:1182`).
  - Frees only unescaped objects and reclaims lines per I4.
  - Runs the finalizers of dead local objects on the owner thread, during the collection. This mirrors today's GC, which runs finalizers on whichever thread collects. It is **best effort, not a guarantee**: an object that escapes is finalized by a global cycle on another thread (ADR-5).
  - Suspends no other thread.
- [ ] **5.7 Global cycle with domains.**
  - Per-thread handshakes reuse Phase 4.7's handshake, extended: also trace the thread's local domain from its roots, queue the global objects it references, then resume the thread. This can be combined with a local collection.
  - Hybrid barrier until the handshake (I5); global objects allocated during the cycle count as live.
  - Global sweep of `GLOBAL` blocks.
  - Owners reclaim lines in mixed blocks using the global epoch (I2, I4).
- [ ] **5.8 Fibers.** Record the owner when a fiber is created. Calling `Fiber.call` from another thread asserts in debug builds and globalizes in release builds (`fiber/package.d:1163`).
- [ ] **5.9 Verifier.** `localheaps:verify` checks I1 on every global cycle: no pointer from a global object to an unescaped one. It reports the slot, plus the store site when the compiler records it.

**Tests.**
- Every channel in §2.4 as a regression test, each asserting no use-after-free under `localheaps:verify`.
- Thread-exit tests for every kind of thread: druntime `Thread`, attached and detached, attached and exiting without detaching, and the main thread with each `cleanup:` mode.
- The full suites with `localheaps:1 verify:1` in CI.
- Re-run `plans/model/run_all.sh` after any protocol change, and extend the model first.

**Exit gate G5.** M7, M8 and M4 (publication) are met, and the suites pass. If the gate is missed, Track B ships disabled by default, or is removed.
**Estimate.** 24–40 pw.

### Phase 6 — Ecosystem hardening `[Track B]`
**Goal.** Make the common libraries cheap to run with local domains.
**Depends on.** Phase 5 working.

- [ ] **6.1 `std.parallelism` (ADR-6; only if G0b shows it is a major source of globalizations).**
  - Under `version (D_GCPublish)` only, declare the delegate parameter of `ParallelForeach.opApply` (and similar entry points) without `scope`. The compiler then allocates a heap closure for the loop body's frame. Publishing that closure promotes only what the workers can reach, instead of globalizing the caller's whole domain. Track A builds keep today's `scope` delegates and pay nothing.
  - This is **not** isolation. The processed range and everything reachable from the closure become global. If that subgraph exceeds the promotion budget, the domain is globalized anyway.
  - `scopedTask` is unchanged. It exists to keep the `Task` on the stack, so handing it to a worker still globalizes; document this.
  - Rejected alternative: exempting the caller's frame while the loop runs ("structured sharing"). A worker can keep a pointer it read from the frame after the loop ends, and the owner's next local collection would then free the object while the worker still uses it.
  - Measure globalizations per second and promoted bytes before and after, on `parallel_map` and the real workloads.
- [ ] **6.2 Audit** `std.concurrency` (`MessageBox`), `std.experimental.allocator` (`GCAllocator`), `std.container`, and the `__gshared` caches in Phobos.
- [ ] **6.2a `Appender` (ADR-3).** If 0.4 confirms that `Appender` allocates through `GC.qalloc` directly (behind `format`, `to!string` and others), pass `BlkAttr.SHARED_HINT` when the element type is `immutable`. The runtime honours the hint only when `immutableGlobal:1`.
- [ ] **6.3 Downstream validation.** Run vibe.d/eventcore (fibers plus worker threads) and the D project tester's top packages with `localheaps:1 verify:1`.
- [ ] **6.4 Diagnostics.** `profile:2` statistics for promotions, globalizations (with their cause), and local vs. global cycles.

**Exit criteria.** M7 is met on the Phase 0 workloads after the library changes, and downstream packages show no verifier failures.
**Estimate.** 6–10 pw.

### Phase 7 — Opt-in defragmentation that never moves pinned objects `[optional]`
**Goal.** Recover heavily fragmented blocks without breaking the non-moving guarantee for code that has not opted in.

- [ ] **7.1** Candidate blocks are those below an occupancy threshold.
- [ ] **7.2** An object may move only if all of these hold:
  - no ambiguous reference (a conservative root, or a conservatively scanned word) pointed to it during this cycle;
  - every pointer to it was a precise slot recorded during marking;
  - it does not have `NO_MOVE`.
- [ ] **7.3** Enabled only with `defrag:1`. Documented as requiring `NO_MOVE` (or `GC.addRoot` plus pinning) for buffers whose addresses C code keeps.

**Gate.** Fragmentation benchmarks show RSS improving by ≥ 15%, with no suite regressions under `defrag:1`.
**Estimate.** 8–12 pw.

### Phase 8 — Exact stack maps `[optional, LDC]`
**Do this only if** Phase 3 data show that stack-induced retention exceeds an agreed threshold, or Phase 7 is limited by pinned objects.

- [ ] **8.1** Non-relocating stack maps at call sites, and frame walking through the unwinder. Frames without maps, and the innermost frame of a thread stopped by a signal, are scanned conservatively.
- [ ] **8.2** Keep the LLVM GC-strategy code in a single LDC module, so changes upstream in LLVM stay contained.

**Estimate.** 16–30 pw.

### Phase 9 — Productization and upstreaming `[continuous; default switch last]`

- [ ] **9.1** One upstream PR series per phase, each behind `gc:immix` or a gcopt, with `changelog/` entries and `--DRT-gcopt=help` text.
- [ ] **9.2** CI matrix: `gc:immix` × {STW, fork, SATB, localheaps} × {Linux x86-64/AArch64, Windows, macOS}, plus Valgrind jobs (`druntime/test/valgrind`).
- [ ] **9.3** Spec:
  - amend `spec/garbage.dd` with the rule for C hand-offs and `GC.publish` (ADR-7) and with `NO_MOVE` guidance (Phase 7);
  - amend the destructors section of `spec/class.dd` to say that GC finalizers may run on any thread. This is already true today but not written down (ADR-5).
- [ ] **9.4** Coordinate frontend changes with LDC and GDC merges; land the LDC barrier work in the `ldc` repository.
- [ ] **9.5** Criteria for changing the default:
  - at least two releases as opt-in with no open critical GC bugs;
  - the §8 targets met on project-tester workloads.

  Then decide separately whether `gc:immix` becomes the default, and whether `localheaps` is on by default.

### Effort summary

| Phase | Track | Depends on | Estimate (pw) |
|---|---|---|---|
| 0 Baselines and spikes | both | — | 8–13 |
| 1 `gc:immix` core | A | G0c | 16–24 |
| 2 Fork marking | A | G1 | 4–6 |
| 3 Precise roots | A | G1 | 8–12 |
| 4 Barriers + SATB | A | G1, G3 | 15–25 |
| 5 Local domains | B | G0a, G0b, G4 | 24–40 |
| 6 Ecosystem | B | 5 | 6–10 |
| 7 Defragmentation | optional | G1 (+3) | 8–12 |
| 8 Exact stacks | optional | 3, 4 | 16–30 |
| 9 Productization | continuous | — | 6–10 |
| **Track A total (0–4, 9)** | | | **57–90** |
| **With Track B (+5, 6)** | | | **87–140** |

If G0c selects symgc, Phases 1–2 become "extend symgc" (ownership and escaped metadata, SATB integration) and must be re-estimated (ADR-2).

---

## 11. Architectural Decision Records

These records answer the open questions of Revision 2 and add one decision that came out of reviewing them (ADR-9). Each record has a **status**:
* **Accepted:** the plan relies on it now.
* **Provisional:** a working assumption that a named Phase 0 gate confirms or overturns. Provisional decisions must not be treated as settled before their gate has run.

Each record also states the result that would overturn it.

| ADR | Topic | Status | Answers | Settled at |
|---|---|---|---|---|
| 1 | Track A is the product; Track B is gated research | Accepted | — | G0a, G0b |
| 2 | Allocator: Immix is the working hypothesis | Provisional | old Q1 | G0c |
| 3 | Placement of `immutable` allocations | Provisional | old Q2 | G0b |
| 4 | Barrier implementation per compiler | Accepted | old Q3 | — |
| 5 | Which thread runs finalizers | Accepted | old Q4 | revisit at G5 |
| 6 | `std.parallelism` stack frames | Provisional | old Q5 | G0b, Phase 6 |
| 7 | Hand-off through foreign code | Accepted | old Q6 | Phase 9.3 |
| 8 | Evolving the GC interface | Accepted | old Q7 | — |
| 9 | Pause structure: no stop-the-world stack scanning | Accepted | new | G4 |

### ADR-1 — Track A is the product; Track B is gated research
* **Status.** Accepted.
* **Decision.** Track A is the deliverable: lock-free TLAB fast path, fork and then SATB concurrent marking, precise roots, on the allocator chosen by ADR-2. Track B starts only after G0a, G0b and G4 pass.
* **Rationale.**
  * The global allocation lock (`gc.d:164`) and pauses that grow with the live heap are the *expected* bottlenecks. Phase 0.1–0.2 confirm them before any target is fixed.
  * Track A needs no publication barrier, and its correctness does not depend on tracking escapes. Its SATB barrier is still emitted by the compiler, but it only does work while marking.
  * The evidence on thread-local heaps is mixed, not negative, which is why it is a gate and not a verdict:
    * Go's Request-Oriented Collector is the one direct precedent for an always-on publication barrier, and it was abandoned over that barrier's cost.
    * OCaml 5 is **not** such a precedent. It rejected concurrent minor heaps because they needed a *read* barrier and broke the C API.
    * Nim and Kotlin/Native left thread-isolated heaps for usability reasons.
    * Domani et al. reported gains on Java.
* **Consequences.**
  * "Lock-free" covers the allocation fast path only (§3.2).
  * SATB alone does not deliver sub-2 ms pauses; that also needs ADR-9.
* **Overturned if.** Phase 0 shows that lock contention and pause times are not significant in the target workloads. Track A then shrinks to the Phase 3 precision work plus adopting symgc.

### ADR-2 — Allocator: Immix is the working hypothesis; G0c decides
* **Status.** Provisional until G0c.
* **Decision.** Carry Immix as the plan and build the Phase 0.6 spike. Phase 1 does not start until G0c has compared Immix with symgc on the criteria listed there.
* **Rationale.**
  * **For Immix: locality.** Bump allocation keeps objects that are allocated together physically together, even when their sizes differ. This helps traversal (Blackburn & McKinley, 2008). Segregated fit keeps same-size objects together per thread, but spreads mixed-size sequences across pages. The gain depends on the workload and is measured with `traverse_locality`.
  * **Neutral: non-moving.** symgc is also non-moving, so interior pointers, slices and C pointers stay valid with either allocator. Slice contiguity is not a factor either, because a `T[]` is a single allocation under any allocator.
  * **Against Immix: metadata.** A segregated-fit allocator gets object size from the page. Immix needs start and end bitmaps, and sets two bits on every allocation (§5). Side tables only beat in-block headers.
  * **Against Immix: fragmentation.** Immix's published space efficiency relies on opportunistic evacuation, which is opt-in here (Phase 7). One live small object pins a whole 128-byte line.
  * **Against Immix: engineering cost.** symgc already delivers the lock-free fast path; Phase 1 is 16–24 pw.
* **Consequences.** The Track A and Track B designs work with any allocator whose ownership unit is the block. If symgc wins, Phases 1–2 become "extend symgc" and are re-estimated.
* **Overturned if.** Any G0c criterion fails (Phase 0).

### ADR-3 — Placement of `immutable` allocations
* **Status.** Provisional until G0b.
* **Decision.** `immutableGlobal:1` is the default. It applies to allocations whose `immutable` type is visible where they are allocated: typed hooks, `.idup`, and `~`/`~=` on `string`. It also applies to `Appender` (6.2a) if 0.4 confirms how `Appender` allocates. Everything else stays local and is published if it escapes.
* **Rationale.**
  * **The benefit.** Strings that do cross threads would otherwise turn blocks *mixed* and send more stores through the slow path.
  * **Not "barrier thrashing".** Publishing a no-scan object is O(1) and uses no promotion budget (5.3).
  * **A real cost.** Most strings are short-lived temporaries. In the global domain only global cycles can reclaim them, which may remove most of Track B's benefit for code that builds many strings.
  * **Limited reach.** Routing at the allocation site cannot see buffers that become `immutable` later, through `assumeUnique` or a pure function's unique result. Those stay local whatever this setting says.
* **Overturned if.** 0.4 shows that most `immutable` bytes die without leaving their thread (switch the default to 0). Or `immutableGlobal:0` keeps the mixed-block slow-path rate within M4.

### ADR-4 — Barrier implementation per compiler
* **Status.** Accepted.
* **Decision.**
  * **LDC:** optimized inline barriers. LDC is the performance reference for §8.
  * **DMD:** both barriers (SATB and publication) at every store site, as out-of-line calls to `_d_gc_store` / `_d_gc_bulkPreWrite`. Correct, small, slow.
  * **GDC:** no barriers. The runtime falls back through the module flags.
  * **Naming:** the switch is `-gc-barriers=none|satb|satb+publish`, with `version (D_GCBarriers)` / `version (D_GCPublish)` and the `ModuleInfo` flags `MIgcBarriers` / `MIgcPublish`.
* **Rationale.**
  * **Barriers are all-or-nothing per process**, through the module flags. This repository's test suite, druntime and Phobos are all built with DMD. Without DMD barriers, neither concurrent marking nor Track B could be tested here, and DMD-built binaries could never enable them.
  * **One out-of-line call per store is the simplest correct implementation:** a single emission path in `e2ir.d` and no inline fast path to maintain. §8 is measured with LDC, so DMD's overhead does not distort any baseline.
  * **Corrections to the original reasoning:**
    * DMD does have a global optimizer, including dead-assignment elimination. It lacks SROA and inlines at the AST level, so it is less aggressive, not missing these passes.
    * LLVM does not remove D barriers by itself; omitting them for fresh objects is custom LDC work.
    * Stores to local variables need no optimizer, because IR generation already knows they are local.
* **Overturned if.** DMD's out-of-line barriers make the dmd test suite too slow for CI. The fix would then be a minimal inline check of `marking == 0` in front of the call.

### ADR-5 — Which thread runs finalizers
* **Status.** Accepted, with the semantics documented. Revisit at G5.
* **Decision.**
  * A local collection runs the finalizers of dead local objects on the owning thread, synchronously.
  * A global cycle runs finalizers on the thread that collects, or on an optional finalizer thread.
  * Running on the owning thread is documented as **best effort, not a guarantee**.
* **Rationale.**
  * **There is no existing guarantee to protect.** Today's GC runs finalizers on whichever thread triggered the collection, and the destructors section of `spec/class.dd` does not say which thread. Code that relies on owner-thread finalization is already wrong.
  * **Promising it would create an invisible rule that changes at run time.** An object that escapes loses the property. A destructor that touches thread-local state would pass its tests and then fail whenever an object happens to escape.
  * **Running finalizers synchronously** adds to the local pause. It also keeps today's re-entrancy hazard: a finalizer runs inside an allocation and may take a mutex the interrupted code already holds. That is not a regression, but it is not safer either.
  * **Thread exit** is handled on every exit path, not only `cleanupThread` (5.4).
* **Consequences.** Phase 9.3 adds to `spec/class.dd` that GC finalizers may run on any thread.
* **Overturned if.** Phase 6's downstream validation finds code that relies on owner-thread finalization at scale. The fix would then be an opt-in queue of owner-thread finalizers, run at the owner's next allocation slow path.

### ADR-6 — `std.parallelism` stack frames
* **Status.** Provisional. Applies only if G0b shows `std.parallelism` is a major source of globalizations.
* **Decision.** Under `version (D_GCPublish)` only:
  * `parallel` foreach takes a non-`scope` delegate, so the compiler allocates a heap closure for the loop body's frame.
  * Publishing that closure promotes only what the workers can reach, instead of globalizing the whole domain (Phase 6.1).
  * `scopedTask` is unchanged.
* **Rationale.**
  * **What is actually wrong today.** A published stack address is not itself an I1 violation. It is a *possible future* violation that the runtime cannot track, which is why it globalizes. A heap closure makes the shared data explicit and traceable.
  * **This is not isolation.** The processed data becomes global, and a large reachable subgraph still exhausts the budget and globalizes.
  * **Rejected alternative: structured sharing** (exempting the frame while the loop runs). A worker can keep a pointer it read from the frame after the loop ends, and the owner's next local collection would then free the object while the worker still uses it.
* **Cost.** One closure allocation and one promotion per loop. Attribute inference changes, but only in `D_GCPublish` builds.
* **Overturned if.** In most real loops, promoting the closure's subgraph exceeds the budget anyway. Globalization was then the cheaper outcome and the change is dropped.

### ADR-7 — Hand-off through foreign code
* **Status.** Accepted. The spec text lands in Phase 9.3.
* **Decision.**
  * **Keep the existing rule.** If C code keeps a pointer, it must be registered with `GC.addRoot`/`GC.addRange` (`spec/garbage.dd`, `gc_foreign_obj`). Under Track B these calls also publish.
  * **Add `GC.publish(const void*)`** to `core.memory` as a `static nothrow @nogc` function. It publishes without creating a root. It covers transient hand-offs where D code keeps a visible reference but another thread receives the pointer through C: a `pthread_create` argument, or a queue of `size_t`.
  * **`GC.publish` is a no-op when local domains are off,** so code can call it unconditionally.
* **Rationale.** This is the smallest possible new rule. `addRoot` is already required when C keeps the only reference, and `publish` covers the one case it does not.

### ADR-8 — Evolving the GC interface
* **Status.** Accepted.
* **Decision.** Do not add methods to `core.gc.gcinterface.GC`; that would break symgc and every other out-of-tree GC. Instead:
  * add optional interfaces (`GCPublish`; `GCLocalDomains` for statistics and control), which druntime discovers with a cast;
  * `core.memory.GC.publish` forwards to `GCPublish` when it is implemented, and does nothing otherwise.
* **Rationale.** Existing implementations keep compiling and behave as if local domains were off. Standardizing these interfaces waits until a second GC implements them.

### ADR-9 — Pause structure: no stop-the-world stack scanning
* **Status.** Accepted. It came out of reviewing ADR-1's claim that SATB alone gives sub-2 ms pauses.
* **Decision.** Phase 4 follows Go's pause structure (§4.3, I5, Phase 4.7):
  * a tiny STW-1;
  * concurrent scanning of global roots;
  * per-thread handshakes with a hybrid barrier;
  * lazy scanning of fiber stacks, each scanned before it is resumed;
  * a tiny STW-2 that never rescans stacks.
* **Rationale.**
  * With SATB alone, the initial stop-the-world must scan every thread and fiber stack. For fiber-heavy programs that scan by itself can exceed 2 ms.
  * Revision 2 also rescanned every stack at remark. That is unnecessary under SATB plus allocate-black, and it doubled the problem.
  * A suspended fiber cannot change its own stack, so scanning it just before it next runs is equivalent to scanning it at the start of the cycle. Writes into it by other code go through the deletion barrier.
* **Consequences.**
  * The barrier now also covers stores into globals, TLS and other stacks, not only the heap.
  * The per-thread `suspend`/`resume` in `osthread.d` become internal API.
  * `StackContext` gets a scan state. The executable model of Phase 0.5 does not yet include fibers.
  * Phase 4 grows by about 2–4 pw, plus about 1 pw for the stack-visibility rule below.
* **Amendment from the Phase 0.5 model.** Per-thread handshakes alone are unsound in D, because D stacks can be read by other threads (a `std.parallelism` worker reads the caller's frame). The model produces a ten-step counterexample in Track A, and the same one under Track B:
  1. thread T0 stores its stack address into a heap object (the escape);
  2. T1, whose handshake has already happened, copies a pointer out of T0's unscanned stack;
  3. T0 overwrites that stack slot with an unbarriered local store;
  4. no scan ever sees the pointer, and the sweep frees an object T1 still holds.

  Go avoids this because its stacks are never visible to other goroutines. D needs the **stack-visibility rule** (I5): scan a stack before it becomes readable by others, i.e. at the escape barrier and, as a group, at STW-1.
* **Consequences of the amendment.** STW-1 is no longer free of scanning: it scans the stacks flagged `stackVisible`. That is usually a small number, but a program that hands every thread's stack to others would pay for all of them. The escape check (a range compare on the stored value) is now in the Track A fast path too, not just Track B.
* **Overturned if.** Handshake latency (signal delivery) dominates the pause. The fix would then be to batch handshakes. Also revisit if M3 shows many `stackVisible` stacks in real programs; the alternative is a barrier on stores to address-taken locals.

## 12. Remaining Open Questions

1. **Promotion budget.** How large should the work budget be, and should it adapt per thread or per cycle?
2. **Owner-id width.** A `ushort` owner code leaves about 32k domains, because the low bit marks mixed blocks. Is that enough for thread-per-connection servers, or should threads beyond it share domains instead of falling back to `GLOBAL`?
3. **Finalizer thread by default.** Should global cycles default to a dedicated finalizer thread? ADR-5 leaves it optional.
4. **Windows handshakes.** Per-thread `SuspendThread`/`GetThreadContext` versus a cooperative safepoint: which gives better latency in Phase 4.7?
5. **Keeping `fork:1`.** Is fork-based marking (Phase 2) still worth maintaining on POSIX once Phase 4 ships?

## 13. References

- S. M. Blackburn, K. S. McKinley. *Immix: A Mark-Region Garbage Collector with Space Efficiency, Fast Collection, and Mutator Performance.* PLDI 2008.
- R. Shahriyar, S. M. Blackburn, K. S. McKinley. *Fast Conservative Garbage Collection.* OOPSLA 2014.
- W. Zhao, S. M. Blackburn, K. S. McKinley. *Low-Latency, High-Throughput Garbage Collection* (LXR). PLDI 2022.
- T. Domani, G. Goldshtein, E. K. Kolodner, E. Lewis, E. Petrank, D. Sheinwald. *Thread-Local Heaps for Java.* ISMM 2002.
- S. Marlow, S. Peyton Jones. *Multicore Garbage Collection with Local Heaps.* ISMM 2011.
- K. C. Sivaramakrishnan et al. *Retrofitting Parallelism onto OCaml.* ICFP 2020.
- R. L. Hudson. *Getting to Go: The Journey of Go's Garbage Collector.* ISMM 2018 keynote (covers the Request-Oriented Collector).
- A. Clements, R. L. Hudson. *Proposal: Eliminate STW stack re-scanning* (Go hybrid write barrier), 2016.
- symgc: https://github.com/symmetryinvestments/symgc (`gc:sdc`).
- D language specification, *Garbage Collection*: `spec/garbage.dd`.
