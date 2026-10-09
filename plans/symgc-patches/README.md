# symgc fork: patches

The fork lives in `symgc/` (a clone of github.com/symmetryinvestments/symgc, branch `latency-p3`, not tracked by this
repository). These are the commits on top of upstream `4a4cb2b`, as `git format-patch` files, so the work is
reproducible from here: `git -C symgc am ../plans/symgc-patches/*.patch`.

| Patch | What | Evidence |
|---|---|---|
| 0001 | Optional phase tracing (`-version=Symgc_phase_trace`) | `plans/bench/core_bench/README.md`, "Where symgc's collection time goes" |
| 0002 | SATB foundation: `d.gc.satb`; release barrier in `free`, `destroy`, moving and shrinking `realloc`, `removeRoots`; buffer flush at thread exit | model findings 6 and `--rootrm`, `--threadlife`; `plans/audit/druntime_edge_deletions.md` |
| 0003 | Cycle split into `cycleStart`, mark, `cycleRemark`, all still stop-the-world; the SATB flag is on during the mark and the remark asserts the queue is empty | 111 unit tests pass; `alloc`, `frag` and `frames` run with assertions on and no log entry appears |
| 0004 | Verifier mode (`-version=Symgc_verify`): freed slots are filled with `0xDB`, a slot handed out again must be all zero or all poison, new slabs start zeroed | a planted write-after-free is reported with the slot and the offset |
| 0005 | Sweep one block at a time, with the page filler lock released between blocks | unit tests, Phobos stress, gate unchanged |
| 0006 | Sweep concurrently with the mutators on a background thread (see below) | gate, verifier, 30x repeats of the stress loops |

### What 0006 does

The stop-the-world part of a cycle (prepare, mark) is unchanged and still runs on the thread that triggered the
collection. The sweep runs after the world restarts, on a GC thread, while threads allocate.

- The bins are emptied while the world is stopped. A slab is allocated from only once the sweep has visited it and put
  it back, or if it is new. Extents and blocks created during a sweep are tagged with the cycle and are left alone.
- A free into a slab the sweep has not visited yet only clears the slot. Dead slots are found without a lock,
  finalizers and poison run outside any lock, and the slab is updated under its bin lock (the model's rules 1 to 4).
- A step holds the page filler lock for about 10 us. A longer step made a mutator that wanted the lock wait for the
  rest of it (measured: 250 us per wait, 5 ms per frame).
- Pacing: the sweeper runs at most 50% of the time (`SYMGC_SWEEP_DUTY`, percent), unless the heap is past 1.125x the
  collection target. A thread that allocates and finds the heap past 1.25x the target helps with the sweep. Both
  limits are relative to the target, which comes from the survivors; relative to the heap at the start of the cycle
  they ratchet up (measured: alloc 8 threads, 590 MB instead of 64 MB).
- Free pages are kept warm up to the collection target instead of being returned to the OS every cycle (the system
  call and then the page faults were 30% of `alloc-1t`).
- Extents born during a sweep are not counted as survivors, or allocating during a sweep inflates the next target.
- `GC.collect()` and `fork` wait for a running sweep. `SYMGC_SWEEP_DUTY=100` removes the pacing,
  `-version=Symgc_sync_sweep` sweeps on the triggering thread as before.

Measured with `plans/bench/core_bench/gate.sh` (Ryzen 7 3800X, `powersave` governor, medians of 3). Before is
`71ad421` (stop-the-world cycle, synchronous sweep), after is `92da0a9`:

| | before | after |
|---|---|---|
| `frames`, 512 MiB live: worst frame / p99 | 28.9 ms / 1.91 ms | 11.6 ms / 1.44 ms |
| `frames`, 2 GiB live: worst frame / p99 | 76.3 ms / 1.57 ms | 33.9 ms / 1.25 ms |
| `alloc`, 1 thread | 14.8 Mops/s | 17.5 Mops/s |
| `alloc`, 8 threads | 42.2 Mops/s | 43.8 Mops/s |
| `frag` | 8.6 s | 3.6 s |
| `frag` steady RSS | 651 MB | 980 MB (conservative GC: 979 MB) |

The worst frame is now the stop-the-world mark itself (10 ms at 512 MiB, 33 ms at 2 GiB). That is what the concurrent
mark (step 5) has to remove.

Bugs the gate or the stress found on the way, each worth a test: new blocks visited by the sweep before they are in the
extent map; two threads driving the sweep state machine while freeing pages released the lock; a pass that started at
a block already tagged and skipped every sparse block (a leak, only the RSS metric saw it); the sweeper's own thread
cache holding slots nobody scans (double free at exit).

### 0007: finalizers before release (step 2b)

With 0006 alone, a finalizer that read another dead object (the spec says it must not, but a collector that frees
nothing until the end allows it, and programs rely on it) could find that object's slot reused or poisoned, because a
swept slab went back in its bin at once. `finalizer_order.d` shows it: 2,000 to 285,000 damaged partners per run.

Now the sweep starts with a pass over all blocks that runs every finalizer of the cycle, and clears the metadata flag
so the release passes do not call it again. Only then are dead slots released. Threads that help with the sweep leave
the finalize pass to the sweeper (finalizers are user code) and wait without fighting for the lock. A slab remembers
that a slot of it ever had a finalizer (`Extent.hasFinalizers`, sticky), so the pass skips the others without touching
their slots, and with no finalizer anywhere (`gAnyFinalizers`) the pass is skipped. Result: `finalizer_order.d` finds no
damage in 10 of 10 runs, with and without the verifier.

Cost: `alloc` with 8 threads about 12% (median 38.5 against 43.8 Mops/s); everything else within noise (frames, `frag`,
`alloc` 1 thread). A cheaper design for later: a list of slabs that have finalizers, so the pass does not walk all
blocks.

Also fixed in 0007: the sweep serials were 8 bits and `gcCycle + 1` wrapped to 0 at cycle 255, the value of a block
that no sweep has seen. They are 16 bits now.

### 0008 and 0009: a mostly-concurrent mark (step 4 and most of step 5)

`SYMGC_CONCURRENT_MARK=1`, Linux 6.7 or later, default off for now. A GC thread runs the whole cycle and the thread that
triggered it carries on. The program stops twice, briefly, and the rest runs beside it. The design is Boehm, Demers and
Shenker's (PLDI 1991), with the kernel doing what a write barrier would: `plans/spikes/dirty` measures it.

1. Arm the tracker (the kernel write-protects the pointer-holding heap, asynchronously: the first write to a page costs
   under 1 us and no signal). The program runs.
2. **Start pause** (0.2 to 3 ms at 2 GiB): prepare the mark bits, empty the bins, start an epoch, and list the roots,
   stacks and thread local storage as work. Only the listing needs the stop: the ranges are read, and traced, after the
   world restarts.
3. Mark with the program running, on 2 to 6 cores (a quarter of the machine, `SYMGC_MARK_THREADS`). Then, in rounds,
   scan again what the program wrote meanwhile (`PAGEMAP_SCAN` reports it and re-arms it in one call).
4. **Remark pause** (0.1 to 0.6 ms at 2 GiB): scan the roots, stacks and thread locals again, and the pages written
   since the last round. Everything reachable at this instant is marked: marks only get added, a pointer stored into an
   already scanned object dirties its page, and the stacks are scanned last, while no pointer can move.
5. The sweep, as in 0006.

Rules it needs, each found by a failing test:

- Extents and blocks created since the mark started are live, have no marks, and the mark skips them (their pages are
  scanned like any other when written). The tag is a 32 bit epoch counter, not the 8 bit cycle of the mark bits: a
  stale tag that matched would make the mark skip a live object, and free what hangs off it.
- Large extents are not freed or resized in place while the mark runs (a marker may hold the `Extent`), and slabs belong
  to the sweep until it visits them.
- The scan of a dirty page lists the slots on it that are allocated and marked, or born. Adjacent slots are one work
  item: one item per slot took 1.4 s for 28 MiB of dirty pages, under the lock of the work list.
- Allocating threads wait when the heap passes the hard limit during the mark. Without it four threads allocating
  garbage flat out made one remark pause scan 5.7 GiB and last 5.4 s; with it the worst is 13 ms.
- The GC thread's own thread cache is flushed before the sweep (it is not scanned, so the sweep would free what it holds).
- If the kernel stops tracking (a mapping it cannot register, an error), the remark marks everything again with the world
  stopped: a new epoch so the born extents are ordinary ones, empty bins, new mark bits, a new cycle number. The first
  version of this fallback leaked live objects; `mark_race.d` with `SYMGC_DIRTY_FAIL=1` found it.
- `thread_scanAllType` in druntime tolerates a caller that is not a druntime thread (the GC thread). `libphobos2.a` embeds
  its own copy of druntime, so Phobos has to be rebuilt after a druntime change or the old code is linked.

Results (`gate.sh check` with `SYMGC_CONCURRENT_MARK=1`, against the stop-the-world mark of 0007):

| | stop-the-world mark | concurrent mark |
|---|---|---|
| `frames` 512 MiB: worst frame | 10.7 ms | 1.8 ms |
| `frames` 2 GiB: worst frame | 31.0 ms | 3.5 ms |
| `frames` 2 GiB: p99 | 1.26 ms | 1.84 ms |
| `alloc` 1 thread / 8 threads | 18.3 / 38.2 Mops/s | 16.9 / 34.2 Mops/s |
| `frag` | 3.43 s | 3.57 s |

The remaining frame time over 1 ms: the start pause (1 to 3 ms at 2 GiB, almost all of it preparing the mark bits, which
can move out of the pause), and the mark threads competing with the program for memory bandwidth.

Tests: `mark_race.d` (a graph whose pointers are moved through locals while collections run; checks every node) passes
on 8 of 8 runs of 20 s with the verifier, 0 damaged in 1.1M to 7.6M moves per run, and reports 3,202 with the dirty
rescan disabled (`SYMGC_DIRTY_SKIP=1`, verify builds only). The Phobos, fiber and `std.parallelism` stress passes 30 of
30, `alloc` with 8 threads 30 of 30, `finalizer_order.d` 5 of 5.

Build and test with the repo's dmd and druntime (symgc needs `ThreadBase.tlsGCData`; there is no Phobos):

```
D=generated/linux/release/64/dmd
$D -unittest -main -g -version=Symgc_testing -version=Symgc_druntime_hooks -Isymgc/source -Idruntime/import \
   -defaultlib= -L-L$PWD/generated/linux/release/64 -L-ldruntime -of=symgc_ut $(find symgc/source -name "*.d") && ./symgc_ut
```

Add `-version=Symgc_verify` to run the same tests with the verifier (110 tests: the one that checks dirty memory
survives a free is skipped there). Phobos (`dlang/phobos` master of 2026-09-16 builds with the repo's dmd; the tag
`v2.113.0-beta.1` does not) and a threads, fibers and `std.parallelism` stress are in
`plans/bench/core_bench/phobos_stress.d`; it needs `libphobos2.a` built with `make -f posix.mak DMD=... DRUNTIME_PATH=...`.

Baseline before the patches: all unit tests pass (exit 0). After: 11 `d.gc.tcache`, 2 `d.gc.global`, 3 `d.gc.satb` tests
pass. Mutation check: disabling each hook makes its test fail (release hook, shrink-tail hook, `removeRoots` hook).
Cost: `alloc` 8 threads 40.7 to 41.5 Mops/s before, 38.3 to 43.6 after (noise); `frag` 0.357 before, 0.363 after.

The marking flag is never set by the stop-the-world collector, so behaviour is unchanged until the concurrent mark
phase sets it with `satbBegin` and drains with `satbDrain`.

### 0010: prepare the mark bits and start the epoch without a pause

The start pause only lists roots, stacks and thread locals (about 40 us at
2 GiB, was 1 to 3 ms). Mark bits are prepared with the program running, in
short steps like the sweep, after the epoch starts, so what the program
creates meanwhile is born and needs none. Remark pause: 0.1 to 0.4 ms.

Four races this opened, each found by a test:

- the dirty tracker is armed before the epoch starts (mark_race: hundreds of
  damaged nodes otherwise);
- the epoch starts and the bins are emptied as one step with every bin locked
  (`Arena.lockBins`), because in either order a slab slips in between
  (double free under the verifier, `alloc 8`);
- a slab made before the epoch that reaches a bin after it is tagged born;
- the set of arenas to lock is taken once: an arena initialized meanwhile made
  us unlock a mutex we did not hold (rare hang / `Lock not held!`, 4 in 150
  Phobos stress runs; 0 in 200 after the fix).

Gate with `SYMGC_CONCURRENT_MARK=1`: worst frame 512 MiB 10.7 -> 1.7 ms,
2 GiB 31.0 -> 1.75 ms; p99 at 2 GiB 1.26 -> 1.45 ms; alloc -4% to -8%.
Battery: verify workloads, alloc 8 x30, mark_race x8, Phobos stress x30 (and
x200), finalizer_order x5, unit tests with and without the verifier: all clean.

### 8 GiB live (concurrent mark, patch 0010)

`frames 8192 6000 5000`, 16 cycles over 100 s: start pause 34-41 us, remark
pause 84-251 us, concurrent mark 8-16 s of background work. Frames: p50 783 us,
p99 1.42 ms, max 1.82 ms, none over 2 ms. RSS 10.3 GB. The frame's own work is
~0.8 ms p50, so the excess from the collector is about 1 ms at the worst
frame; the under-1 ms target on the worst frame is not met yet. Open: mark
threads competing with the game thread for memory bandwidth/cache (p99 rises
~15%), and the reference being a game's real frame, not this synthetic loop.

### Heap-size independence and the floor (concurrent mark)

`frames L 600 5000`, concurrent mark: live 16 MiB p99 1.26 / max 1.62 ms;
256 MiB 1.29 / 1.52; 2 GiB 1.2-1.3 / 1.4-1.9; 8 GiB 1.42 / 1.82. The worst frame no
longer depends on the live size (16 MiB to 8 GiB), whereas with the
stop-the-world mark it was 4.5 ms at 16 MiB and 9.5 ms at 256 MiB.
Mark threads 1/2/4/6 change nothing meaningful (p99 1.4 / 1.3 / 1.27 / 1.2 ms;
more threads is slightly better because the cycle ends sooner). So the
remaining ~0.5-0.9 ms over the 0.7 ms p50 of a 5000-allocation frame is
allocation-path jitter (refills, sweep assist, lock waits), not the mark.
Next: attribute it with GcbLockStats and the sweep-assist counters.

### Where the jitter is not (256 MiB live, 1200 frames of 5000 allocations)

- Page faults: ~20 per frame (~20 us), not the cause.
- Lock waits (`GcbLockStats`, slow-frame threshold now 1.1 ms): 15 of 1200
  frames are over 1.1 ms; five show 50-260 us of lock wait, the other ten show
  none, so ~0.5 ms is unexplained there (scheduler/SMT/cache interference with
  the background threads is the remaining suspect).
- Sweep duty 10/25/50/100: p99 1.06-1.18 / 1.10-1.33 / 1.16-1.36 / 1.38-1.43 ms,
  max 1.3-1.5 / 1.5-2.0 / 1.6 / 1.8-2.2 ms. Lower duty is slightly better, within noise.

### CPU placement and the malloc floor

Pinning (256 MiB live): all 16 CPUs p99 1.20-1.25 / max 1.5 ms; 8 even CPUs
(no SMT siblings) 1.39-1.43 / 1.7; CPUs 0-3 1.07-1.30 / 1.5-1.7; 2 CPUs
4.2-4.6 ms at p99.9 (too few). Placement is not the lever.
`mallocfloor.d` (same 5000 allocation sizes with malloc/free, no collector):
p50 67 us, p99 110 us, max 130 us per frame. The GC frame is 690 us p50 /
1.2 ms p99: ~140 ns per allocation against ~14 ns, and p99/p50 1.8 against 1.6.
So the gap to close is the allocation path itself (tcache refill, slab
locks, zeroing, `world[]` random stores), not the collector's pauses.

### Correction: the malloc floor above was unfairly hot

`mallocfloor.d` recycles a 64-entry ring, so every block is in L1. With a
working set that does not fit the cache the same malloc loop costs more
(`mallocns.d`, 5M allocations of 32..256 B): ring 64 -> 12.7 ns, 64K -> 14.4,
1M -> 34.0, 4M (~500 MB) -> 77.6 ns. A bare `new ubyte[]` on symgc is
90-110 ns (concurrent mark or not), so the honest gap is ~1.3-3x, not 10x, and
most of what is left is cache misses on recycled cold memory. A SIGPROF
self-sample of the bare loop: 22% in loads (`atomicLoad`, cache misses),
`SlabAllocInfo` / `maybeGetPageDescriptor` / `initializeMetadata` ~12%
(the appendable-array metadata), the rest spread over the tcache path.
perf is not installed here; the profile came from a SIGPROF handler
(`scratchpad` only, not committed).

### Concurrent mark is now the default (patch 0011) and the bullet-hell test

`SYMGC_CONCURRENT_MARK=0` (or `SYMGC_DIRTY=0`, or a kernel without
`UFFD_FEATURE_WP_ASYNC`/`PAGEMAP_SCAN`) gives the stop-the-world mark. The unit
test build (`Symgc_testing`) keeps it opt-in: its threads are not druntime
threads, so there is nothing to stop. Evidence for the switch: battery clean
(verify workloads, alloc 8 x30, mark_race x8, Phobos stress x30 and x200,
finalizer_order x5), gate PASS, unit tests 111/112, and 22 Phobos modules'
unittests (array, conv, string, format, json, containers, range, algorithm,
typecons, bigint, regex, uni, datetime, stdio, file, path, utf, sumtype,
concurrency, parallelism) pass in both modes (one unreproduced rc=1 in
std.typecons with the concurrent mark, 0 in 92 reruns).

`bullet_hell.d`: a headless bullet-hell written with no care for memory (new
Bullet + closure per shot, arrays rebuilt with filter/array every frame,
formatted HUD string, streaming level tiles, no pools, no GC.collect), paced
at 60 fps.

| 60 s, 512 MiB level, 20k bullets/s | p50 | p99 | p99.9 | max | >5 ms | >16 ms |
|---|---|---|---|---|---|---|
| symgc, concurrent mark | 1.03 ms | 1.83 | 2.51 | 5.4 ms | 1 | 0 |
| symgc, stop-the-world | 0.92 | 1.72 | 6.98 | 7.3 | 25 | 0 |
| stock druntime GC | 0.74 | 1.26 | 1.60 | 43.9 | 2 | 2 |

| 120 s, 2 GiB level, 40k bullets/s | p50 | p99 | p99.9 | max | >5 ms | >16 ms |
|---|---|---|---|---|---|---|
| symgc, concurrent mark | 1.82 ms | 3.18 | 4.57 | 7.9 ms | 6 | 0 |
| stock druntime GC | 1.51 | 2.38 | 2.67 | 156.9 ms | 2 | 2 |

symgc never drops a 60 fps frame; the stock GC drops them (a 157 ms hitch at
2 GiB). The price is steady-state speed: symgc's p50/p99 are 20-40% above the
stock GC's (allocation path, dirty-page write faults, the paced sweep).

### Dirty rounds: remark threshold 2048 -> 512 pages (patch 0012)

A bullet-hell frame of 7.8 ms traced to one remark pause of 5.95 ms (556
pages written since the last round, whose reachable subgraph the remark had
to trace). Rounds now repeat until at most 512 pages (2 MiB) are left, not
2048. Bullet hell (60 s, 512 MiB, 20k/s): worst frame 5.4 -> 2.2-2.7 ms, p50
1.03 -> 0.93 ms, max remark pause 0.3-0.6 ms. A threshold of 128 pages (and 12
rounds) was tried and refused: the longer mark let more garbage pile up and
frag's steady RSS went 0.90 -> 1.09 GB (gate FAIL, +25%). With 512: frag RSS
0.90-0.93 GB, gate PASS, battery clean.

### Where the remaining bullet-hell spikes come from (2 GiB, 40k bullets/s)

Slow frames (3-8 ms against a 1.6 ms median) come in groups of 1-4 right after
a cycle's arm, and carry 1300-2300 minor faults against ~6 in a normal frame
(`RUSAGE_THREAD` per frame): the write-protect fault of the first write to each
armed page, ~1.5 us each. The game writes every live bullet each frame
(`b.pos += ...`), so its hot set is ~1500 pages and it pays them once per arm.
That is the price of tracking with the kernel instead of a barrier.

Tried and reverted: leaving the free pages unprotected (`UFFDIO_WRITEPROTECT`
with mode 0 on each free run, "always reported as written"). It did nothing:
the faults are on pages of old, live objects, not on free pages, and most of
the ioctls failed with ENOENT. Not tried: not re-arming the pages that were
hot in the last round (no faults, but they are rescanned in the remark, so the
pause grows to ~1 ms for a 1500-page hot set). A barrier (LDC) has neither cost:
a store of a pointer costs a few ns and nothing faults.

Also tried and reverted: stopping the dirty rounds as soon as the hot set stops
shrinking (fewer re-arms, so fewer fault groups). The remark then rescans ~1500
hot pages and its pause went to 1.4-8.2 ms (worst game frame 11.6 ms), worse
than the faults. With kernel tracking the choice is faults in the game thread
or pause in the remark; both cost about 2-8 ms for this game's hot set.

### Where the game thread's time goes (bullet hell, 30 s, SIGPROF on the game thread only)

~75% is the game's own code (the `filter`/`array` rebuilds, the per-bullet
update, `Appender.put`), ~21% is in code `nm` cannot name (libc memset/memcpy
or PLT stubs, `data_start`), and only ~12% is in the GC (`atomicLoad` 5%,
`initializeMetadata` 4%, the rest under 1%). The 20-40% gap to the stock GC
in typical frames is therefore not the allocation path; cache locality of
where the slots come from (symgc's paced sweep keeps more memory in play) and
the write-protect faults after each arm are the suspects. Not measured yet.

## The compiler route: ldc2 -gc-card-marking + the Symgc_cards backend (patch 0014)

`plans/ldc-patches/` holds the LDC side (branch `gc-card-marking` of the LDC
checkout at `ldc/`, built with the LLVM 19 dev package): an IR pass that runs
last and, after each store of a pointer to memory that is not an alloca or a
global, after atomic pointer stores/exchanges and after memcpy/memmove to such
memory, sets one byte in a card table (one byte per 512 bytes of address
space, `__sd_gc_card_base[addr >> 9] = 1`). Stores of floats, ints and so on
dirty nothing. symgc's side is `d/gc/cards.d` (table mapped in
`.preinit_array`, 2^38 bytes of NORESERVE address space) selected with
`-version=Symgc_cards`: the dirty rounds and the remark read and clear cards
instead of asking the kernel for dirty pages. Runtime and Phobos have to be
built with the flag too (`ldc-build-rt2`: LDC master druntime + the dmd Phobos
checkout, D_EXTRA_FLAGS=-gc-card-marking).

Correctness (LDC -O1 verify build, card barrier, concurrent mark):
`mark_race` 8/8 OK (the same program without the barrier crashes on a freed
live node), `alloc 8` x30 clean, Phobos stress 30/30, all gcb workloads run.

Frames (gcb `frames`, 5000 allocations per frame, LDC -O3, 600 frames):

| 2 GiB live | p50 | p99 | worst |
|---|---|---|---|
| kernel dirty pages (uffd), 5 runs | 0.36 ms | 0.71-0.77 | 0.80-1.09 ms |
| card barrier, 5 runs | 0.33 | 0.68-0.72 | 0.75-0.84 ms |

Bullet hell (LDC -O3):

| 60 s, 512 MiB level, 20k bullets/s | p50 | p99 | worst | >16 ms |
|---|---|---|---|---|
| stock GC (LDC 1.40) | 0.24 ms | 0.55 | 21.6 | 2 |
| symgc, kernel tracking | 0.47 | 0.94 | 1.69 | 0 |
| symgc, card barrier | 0.34 | 0.70 | 2.77 (1 frame) | 0 |

| 120 s, 2 GiB level, 40k bullets/s | p50 | p99 | worst | >16 ms |
|---|---|---|---|---|
| stock GC (LDC 1.40) | 0.52 | 0.94 | 80.2 | 2 |
| symgc, kernel tracking | 0.73 | 1.43 | 3.10 | 0 |
| symgc, card barrier | 0.68 | 1.12 | 1.64 | 0 |

Remark pause with cards at 2 GiB: 0.27-0.47 ms, of which ~0.22 ms is reading
the card table (it grows with the heap; a summary level is the next step).

Fixed (patch 0016), was thought to be LDC-only: `finalizer_order` failed with
symgc built by LDC. The cause was real and in symgc: the finalize-first rule
held inside one arena, not across arenas. A class with a destructor lives in
another arena than the object it points to (finalizable objects have metadata),
and the collector swept the arenas one after the other, so the second arena's
destructor found its partner released and reused. DMD builds passed only because
the arena visited first happened to hold the finalizable objects. The sweep is
now three stages (begin, finalize, finish) driven across arenas by the collector,
with a global flag that keeps the mutator assists out until every finalizer
ran. 8/8 with LDC + cards, 5/5 with DMD, gate and unit tests unchanged.

### Summary level (patch 0015, LDC patch 0003)

The barrier also sets one summary byte per 64 KiB; the collector reads the
summary and only the cards of the regions it marks. Remark at 8 GiB live:
0.55-0.85 -> 0.21-0.34 ms. `frames 8192` (LDC -O3, card barrier): p50 0.38 ms,
p99 0.77-0.81 ms, worst 1.06-1.12 ms (1 to 4 frames of 1200 over 1 ms; the
excess over the median is not a collector pause). Battery with the summary:
`mark_race` 8/8, `alloc 8` verify x30 clean, Phobos stress 30/30.

### Cycle-start spikes (patch 0017)

The few slow frames of the 2 GiB bullet hell (1.5-1.9 ms, 4 of 7200) all sat
at the start of a cycle: the epoch empties the bins, and the program then made
a slab for each size class it used in its next frame. The collector thread now
puts a fresh born slab in each bin that was in use before it lets the program
go, and the concurrent prepare is paced like the sweep. Bullet hell, LDC -O3,
card barrier: 2 GiB / 40k bullets/s p50 0.72, p99 1.22, worst 1.49 ms and no
frame over 1.5 ms (was worst 1.65-1.92 ms); 512 MiB / 20k/s p50 0.38, p99 0.71,
worst 1.04 ms. DMD battery, LDC battery (mark_race 8/8, alloc 8 verify x30,
Phobos stress 30/30), gate and unit tests clean.

### Multi-threaded game (`game_mt.d`), LDC -O3

A main thread at 60 fps building a scene graph (classes, arrays, strings,
`format`) every frame, two job threads running search with associative
arrays and growing arrays all the time, a streaming thread loading and
dropping 1-8 MiB assets every 40 ms, and a level of live data. No pools, no
`GC.collect`. 90 s at 2 GiB, 5400 frames:

| collector | p50 | p99 | p99.9 | worst | >2 ms | >16 ms |
|---|---|---|---|---|---|---|
| stock GC (LDC 1.40) | 0.72 ms | 3.93 | 30.8 | 60.8 ms | 299 | 9 |
| symgc, card barrier (5 runs) | 0.21-0.29 | 0.50-0.82 | 0.95-1.28 | 1.2-6.0 ms | 0-3 | 0 |

At 512 MiB (60 s): stock p50 0.80, p99 2.82, worst 12.9 ms, 75 frames over 2 ms;
symgc p50 0.26, p99 0.80, worst 3.2 ms, 1 frame over 2 ms. Mark threads 1/2/4
change little; the few slow frames are single events at a cycle start (one run
with one mark thread had a 12 ms frame: a long mark with a thread starved).
About 99.8% of symgc's frames are under 1 ms in this workload, and the stock
collector's frame is 3x slower at the median because the four threads
contend on its single lock.

### Lock holds that hurt other threads (patch 0018) and the watchdog

`plans/bench/core_bench/watchdog.c`: a watcher thread notices that a frame has run
longer than a threshold and signals every thread of the process; the handler records a
`backtrace()`. Resolved with `addr2line`, it shows what each thread was doing during the
slow frame, which `perf` (not installed here) would have shown. Per-frame
`getrusage(RUSAGE_THREAD)` counters added the page faults and the context switches.

Findings in the multi-threaded game: slow frames had 1-3 faults (not faults), 6-14
voluntary context switches (waits on a lock), and in the samples the main thread was in
`Mutex.lockSlow` under `PageFiller.allocRun` while the sweeper was in `sweepFinalizers`.
The finalize stage of patch 0016 ran with no pacing and no yield to waiters, so the
threads that needed a slab waited for it. It is paced now. Also, returning pages to the
OS (`madvise`) was one call per block under the same lock: 0.3-3 ms for 2 MiB; it is a
chunk of 16 pages per step now. The slow frames with many context switches are gone;
frames of 2-3 ms remain in some runs (single events with 0-1 switches, cause not found).

After patch 0018, multi-threaded game (LDC -O3, card barrier, 2 GiB live, 180 s, 10800
frames): p50 0.22 ms, p99 0.38 ms, p99.9 0.75 ms, worst 1.99 ms, 5 frames over 1 ms
(0.05%), none over 2 ms. Before it, the same game had p99 0.77 ms and about 20 frames
over 1 ms per 7200. Stock GC (LDC 1.40): p50 0.72, p99 3.9, p99.9 30.8, worst 60.8 ms.

Watchdog note: it first used SIGUSR2, which druntime's stop-the-world uses to resume
threads; one long run hung (a thread at 100% CPU for 47 minutes) and 16 runs of the
same program without the watchdog did not. It uses a real-time signal now, and two 180 s
runs with it finished normally. Over those two runs (21600 frames) 8 frames passed 1.2 ms
(0.04%); in most of them the main thread had already left the frame by the time the sample
landed, one was waiting for the page filler lock (`PageFiller.allocRun`) while another thread
was in the region allocator's tree.

### The rare 1-3 ms frames: the sweeper preempted while it holds the page filler lock

Per-phase timing of the sweeper's steps (multi-threaded game, 120 s, 2 GiB): the longest
single step was 1.0 ms in the dense finalize, 3.0 ms in the sparse finalize and 3.0 ms in the
sparse scan, although the loops check a 10 us budget. Every step over 0.5 ms (30 to 57 per run)
had `faults=0 invol=1`: one involuntary context switch, so the sweeper was descheduled while it
held the lock, and a mutator that needed a slab or a large allocation waited for it to run again.
A scheduling noise test (`noise.c`: a 60 Hz thread with 250 us of work, with and without six
burner threads) shows no such stalls (max 272 us over 7177 frames), so it is the process's own
threads sharing CPUs, not the machine. Neither `nice 0` for the sweeper (`SYMGC_SWEEP_NICE`) nor a
lower duty (25, 10) changed the number of long steps.

What would remove it, not done: a lock-free stash of spare empty slabs per bin (refilled by the
collector thread, retagged as born at each epoch so the sweep does not free them), so the
mutator takes a slab with an atomic pop instead of the filler lock. Large allocations (the 1 to 8
MiB assets) still need the lock.
