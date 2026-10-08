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
