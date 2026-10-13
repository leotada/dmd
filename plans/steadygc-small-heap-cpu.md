# Reduce steadygc's CPU cost on a small live heap with heavy allocation

Status: Phases 0–3 done (0058–0060). Mean acceptance met: DMD `--worst`/`--openworld` ~1.11–1.14×.
After 0060, `--worst`/`--openworld` worst ≤ same-session druntime; remaining open criterion is
`--worst-safe` worst (~+1.2 ms). See appends "0058 results" and "0060 results" below. Phase 1
named quiet-frame mutator allocation (format/qalloc), not markers or madvise. See
`plans/symgc-patches/README.md` section 16–18 and `symgc/guide/benchmarks.md`.

The code to change lives in `symgc/` (fork of symmetryinvestments/symgc, published as
[leotada/symgc](https://github.com/leotada/symgc) branch `main`). This file stays in `plans/` and is
only ever extended. Implementation commits stay local. Each `symgc/` commit gets a patch under
`plans/symgc-patches/`.

## Goal

On a 4-core machine, paced at 60 Hz, steadygc's frame work time on the engine GC benchmark should
come within the acceptance band of druntime's GC, without giving back the win steadygc already has
on a multi-gigabyte live heap.

The published failure, medians of 5 runs, 600 paced frames (Linux 6.18, 4 cores, Firecracker VM,
15 GB). Frame time is work only; the sleep to the 60 Hz deadline is not included.

| Scenario | Compiler | GC | mean | p99 | worst | frames > 16.7 ms (sum of 5) | peak RSS |
|---|---|---|---|---|---|---|---|
| `--worst` | DMD 2.113.0 `-O -release -inline` | druntime `precise:1` | 5.23 ms | 12.3 ms | 15.8 ms | 1 | 93 MB |
| `--worst` | DMD | steadygc, concurrent mark | 9.49 ms | 15.9 ms | 21.3 ms | 27 | 98 MB |
| `--openworld` | DMD | druntime | 0.59 ms | 1.3 ms | 3.3 ms | 0 | 74 MB |
| `--openworld` | DMD | steadygc | 0.96 ms | 2.1 ms | 4.4 ms | 0 | 46 MB |
| `--worst-safe` | DMD | druntime / steadygc | 2.69 / 2.49 ms | 5.5 / 4.8 ms | 9.7 / 10.2 ms | 0 / 1 | 46 / 54 MB |
| `--worst` | LDC 1.43.0 `-O3 -release` | druntime / steadygc | 4.62 / 6.23 ms | 13.2 / 11.1 ms | 15.4 / 16.5 ms | 0 / 2 | 93 / 87 MB |
| `--openworld` | LDC | druntime / steadygc | 0.49 / 0.70 ms | 1.1 / 1.5 ms | 1.8 / 2.7 ms | 0 / 0 | 54 / 36 MB |
| `--worst-safe` | LDC | druntime / steadygc | 2.84 / 2.92 ms | 5.1 / 4.9 ms | 9.6 / 10.0 ms | 0 / 0 | 46 / 45 MB |

Process CPU on `--worst`, DMD, 600 paced frames (`/usr/bin/time`):

| | user | sys | minor faults |
|---|---|---|---|
| druntime | 3.7 s | 0.3–0.5 s | 28–30 k |
| steadygc, concurrent mark | 8.0–8.7 s | 0.6–0.8 s | 166 k |
| steadygc, `SYMGC_CONCURRENT_MARK=0` | 8.6 s | 0.3 s | 39 k |

Collections on `--worst`: steadygc 41 cycles and 80–110 ms total pause; druntime 28–31 cycles and
142–165 ms total pause. `GC.profileStats.totalCollectionTime` ("total_mark" in the benchmark print)
is ~1.5 s for steadygc and ~0.17 s for druntime.

The same machine, one run, `bench/compare.sh bullet_hell_stress.d 30 2048 100000 0.05 256` (2 GiB
level). This is the regression bar, not the 8-core numbers in `symgc/BENCHMARKS.md` (those are a
different machine: Ryzen 7 3800X, worst frame 1.2 ms).

| Compiler | Collector | worst frame | frames > 16 ms of 1800 | peak RSS |
|---|---|---|---|---|
| DMD | druntime | 166 ms | 4 | 4311 MB |
| DMD | steadygc, stop-the-world mark | 50 ms | 2 | 2921 MB |
| DMD | steadygc, concurrent | 10.6 ms | 0 | 2929 MB |
| LDC | druntime | 206 ms | 4 | 4311 MB |
| LDC | steadygc, stop-the-world mark | 19 ms | 2 | 2916 MB |
| LDC | steadygc, concurrent | 11.9 ms | 0 | 2895 MB |

Source of these tables: `docs/steadygc-evaluation.md` on game-engine commit `88f28dfe` (branch
`ccr-cc050179-pkqfvj`). Re-measure before changing code. Treat a number in this file as a target
shape, and replace it with the new session's medians.

## What is already known, and must not be re-discovered

These were run on `--worst`, DMD, paced. None of them moved the mean (steadygc stayed 9.5–10.6 ms,
p50 8.3–9.4 ms; druntime stayed 5.1–5.8 ms, p50 4.2–4.5 ms):

| Knob | What it changes | Result |
|---|---|---|
| `SYMGC_CONCURRENT_MARK=0` | stop-the-world mark, no `userfaultfd` | mean unchanged; user CPU still 8.6 s; minor faults fall to 39 k |
| `SYMGC_MARK_THREADS=1` | one marker instead of the default 2 on a 4-core machine | mean unchanged |
| `SYMGC_SWEEP_DUTY=100` | sweeper never sleeps (`paceSweeper` returns immediately) | mean unchanged |

Consequences for the hypotheses:

- The median-frame gap survives with the dirty-page tracker off, so it is not the write fault
  (~1.5 µs each). 166 k − 39 k ≈ 127 k extra faults × 1.5 µs ≈ 0.19 s of the whole run, about
  0.3 ms per frame if spread evenly. That is real and worth a later, separate correction. It is not
  the 4 ms median gap and not the 4–5 s of extra user CPU.
- The same gap survives with a stop-the-world mark, so marker threads are not the median-frame
  cost. They can still be the tail (`totalCollectionTime` 1.5 s vs 0.17 s) and part of the extra
  user CPU.
- `SYMGC_SWEEP_DUTY=100` makes the sweeper run *more*. It does not test "sweeper almost idle".
  `SYMGC_SWEEP_DUTY` is clamped to the range 1..100 at sweeper start (`collector.d`, sweeper
  `entry`). There is no duty of 0. The untested sweeper experiments are duty 1, and a synchronous
  sweep. See [Phase 2](#phase-2--falsify-the-remaining-hypotheses-one-knob-at-a-time).

`--worst-safe` ties. That scenario allocates almost nothing on the GC (frame arena, interned ids,
one POD terrain array every other frame). A tie there means the regression tracks GC allocation and
pointer-bearing blocks, not "any 60 Hz frame". It does not by itself acquit the sweeper: if
`--worst-safe` never starts a cycle, the sweeper is asleep in the run that ties.

`--openworld` is still about 1.6× on the mean (DMD 0.96 vs 0.59 ms) with almost no class graph:
`int[]` / `float[]` / strings. A cause that exists only inside the conservative scan of class
pointers cannot explain that mean. The `--worst` tail (worst frame 21.3 vs 15.8 ms, 27 frames over
budget) can still be the scan.

## Two gaps, not one

600 paced frames are 10 s of wall time when every frame fits in 16.667 ms. Steadygc's mean work of
9.49 ms against 5.23 ms is about 2.6 s of extra time on the mutator thread. Process user CPU is
about 4.5 s higher (8.3 s vs 3.7 s). The difference, roughly 2 s, is other threads. Fixing only one
of these can miss the acceptance bar:

- The **mean** is mostly frames that do not pause. 41 cycles in 10 s is one cycle every ~250 ms.
  `totalCollectionTime` of 1.5 s is ~37 ms of cycle wall per collection, so a cycle overlaps a few
  frames, not the median. The mean moves when the mutator path or something that runs on quiet
  frames gets cheaper.
- The **worst frame** and the **27 frames over 16.7 ms** are the overlapped frames. Steadygc's
  total pause is already smaller than druntime's (80–110 ms vs 142–165 ms), and the worst frame is
  still worse. The tail is mutator work plus whatever the cycle does to that frame, not the pause
  counter alone.
- LDC's `--worst` p99 is already better under steadygc (11.1 vs 13.2 ms) while the mean and the
  worst frame are worse. Do not chase p99. The mean and the worst frame are the misses.

A change that cuts 3 ms off a quiet frame and leaves a 12 ms cycle spike on top of it still fails
the worst-frame and over-budget criteria. Attribute both before editing.

## Workload, so the profile has something to match

Copy the benchmark from game-engine commit `88f28dfe` (branch `ccr-cc050179-pkqfvj`), file
`source/demo/gc_benchmark.d`. The copy of that file on a local `master` checkout is not the source
of truth; `engine.core.gc` exists only on that branch.

`--worst` (`simulateFrameWorst`), every frame, after a one-time roster of 4096 `NpcState`:

- 4096 class objects (`NpcInventoryItem`: vptr, monitor, `string`, `int`, `next`). Each is
  `BlkAttr.FINALIZE`, so `sdcAllocate` calls `__sd_gc_hook_alloc_appendable(size + 1, ...)` and
  `ThreadCache.allocAppendable` then adds another `PointerSize` for the finalizer word
  (`tcache.d`). The slot is larger than the instance.
- 4096 `displayName` strings and 4096 item-name strings (`std.format`, appendable, scanned).
- 4096 `int[]` of 16..47 elements (64..188 bytes, appendable, `BlkAttr.NO_SCAN`).
- 1024 short strings that die immediately.
- Every second frame, `PointerVertex[4096]`. The struct holds a `string` and a class reference, so
  the block is scanned. 4096 × 48 bytes is about 192 KB, one large allocation, plus 4096 interned
  material-name literals that are not fresh allocations.
- Every 16th frame, per NPC whose index matches, a `string[4]`.

Order of magnitude: 1.5×10^4 to 2×10^4 GC allocations per frame, almost all of them appendable.
A quiet frame that is 4.3 ms slower is about 200 ns extra per allocation if the cost is spread
across that many calls. That is enough to take seriously and small enough that a profiler has to
be per-call, not per-phase.

`--openworld`: 512 small `int[]`, 64 format strings, 256 dialog strings, 32 `float[]` particle
buffers, a 256 KB `int[]` every 4th frame. Pointer-free payload, appendable arrays, real `format`
traffic. Live set is the terrain ring and the retained window.

`--worst-safe`: the same logical work through `SafeNpcDef` / `SafeInvNode` / `SafeTerrainVertex`,
`StringTable.intern`, and `FrameArena.fmt`. The GC sees POD arrays. This is the negative control.

`new` of a class and `new` of an array both go through `symgc.gcobj.sdcAllocate`:

- `FINALIZE` or `APPENDABLE` → `allocAppendable` → `allocSmall` → `SlabAllocInfo.initializeMetadata`.
- plain block → `alloc`.
- `NO_SCAN` clears `containsPointers`. Pointer blocks pay `memset` of the unused tail of the slot
  (`allocSmall`, the `else if (containsPointers)` branch). `zero == true` memsets the whole slot.
  The fast path (`ThreadBin.allocate` hit) is **not** inside `GcTimer` / `threadAllocTime`. The
  timer starts only after the bin misses, around `maybeRunGCCycle` and `bin.refill`.

So a small `threadAllocTime` does not mean allocation is cheap. It means the slow path was cheap.

## Code map

Mutator allocation (`source/d/gc/tcache.d`, `source/d/gc/tbin.d`, `source/symgc/gcobj.d`):

- `sdcAllocate` → `hook_alloc` / `allocAppendable`.
- `allocSmall`: size class, thread bin, tail `memset` for pointer slots, `triggerAllocationEvent`.
- `allocSmallBin`: fast hit; on miss, `GcTimeKind.Alloc`, `maybeRunGCCycle`, `ThreadBin.refill` →
  `Arena.batchAllocSmall`.
- `allocAppendable` for a small block: `initializeMetadata` (finalizer bit and used capacity packed
  into the high 16 bits of a word at the end of the slot, `slab.d`). `setHasFinalizers` on the
  extent when the block has a finalizer.
- `freeSmall`: if `ShouldZeroFreeSlabs && containsPointers`, `memset` the slot; clear the metadata
  bit; push onto the thread bin.
- `triggerAllocationEvent` / `recycleBins`: at most every 10 ms, flush up to `ThreadBinCount / 8`
  bins. This runs on the mutator and is outside the "bin miss" story.

Sweep (`source/d/gc/page.d`, `source/d/gc/collector.d`):

- After the mark, `Sweeper.submit` runs the sweep on its own thread (nice 10, `SYMGC_SWEEP_NICE`).
  Windows and `-version=Symgc_sync_sweep` sweep on the cycle's thread instead.
- `paceSweeper`: sleep so the sweeper stays under `gSweepDutyPercent` (default 50) of the time,
  unless `usedPages > gSweepGrowthLimit` (the heap is past 1.125× the collection target), in which
  case the sweeper does not sleep.
- A mutator past 1.25× the target calls `assistSweep`. That time is `GcTimeKind.Collect`
  (`threadCollectTime`), on the mutator.
- `minimizeStepImpl` runs on every sweep (`DenseMinimize`, `SparseMinimize`). It keeps
  `max(1024 pages, gSweepRetainPages)` free pages warm (4 MB at 4 KB pages) and returns the rest
  with `madvise(MADV_DONTNEED)` in chunks of 16 pages (`BlockDescriptor.minimizeChunk`). A new
  slab is not `memset` unless `-version=Symgc_verify`. A large block is zeroed only when the caller
  asked for zero and the pages came back dirty (`allocLarge`).
- `-version=Symgc_sync_sweep` also forces `concurrentMarkWanted()` to false. A sync-sweep build is
  stop-the-world mark **and** synchronous sweep. It is not "concurrent mark, sweep on the mutator".

Mark (`source/d/gc/scanner.d`, `source/d/gc/dirty.d`, `source/d/gc/collector.d`):

- Default thread count on this machine: `cores / 4`, then raised to at least 2
  (`runConcurrentMark`). 4 cores → 2 markers, plus the GC thread, plus the sweeper, plus the
  mutator: five threads on four cores. `SYMGC_MARK_THREADS=1` was already tried.
- Concurrent mark is on when `dirtyAvailable()` is true (Linux x86-64, kernel support,
  `SYMGC_CONCURRENT_MARK` unset or not `0`). `SYMGC_DIRTY=0` also disables it.
- Only pointer-holding memory is registered with `userfaultfd` write-protect. `NO_SCAN` blocks are
  not tracked.
- `Scanner.scanImpl` walks every aligned word of a pointer block, calls `managedAddressSpace.contains`,
  then the extent map. There is no TypeInfo pointer bitmap. druntime with `precise:1` scans only
  the fields the type says are pointers. Blocks with `containsPointers == false` are skipped.
- `recordProfile` stores cycle wall time (`info.stop - info.start`) in `totalCollectionTime`, and
  stopped time in `totalPauseTime`. Cycle wall includes the concurrent mark and, when the sweeper
  finishes the cycle, the sweep. It is not CPU time and it is not mutator time.

Telemetry that already exists, and what it does not cover (`source/d/gc/gctime.d`,
`GC.frameStats` in `symgc/gcobj.d`):

| Field | Counts | Does not count |
|---|---|---|
| `threadAllocTime` | mutator slow path: refill, its lock waits, large `alloc` | thread-bin hit, tail `memset`, `initializeMetadata` |
| `threadCollectTime` | deciding to collect, waiting, `assistSweep` | marker and sweeper threads (`markGcThread` disables their timers) |
| `threadPauseTime` | time this thread was stopped | concurrent mark running beside it |
| `GC.profileStats.totalCollectionTime` | sum of cycle wall times | per-frame split; also the harness `GC.collect` if the snapshot is taken too early |
| `isCycleActive` | `gMarkActive` or `gSweepCycle` | — |

`GC.profileStats.maxPauseTime` includes the harness. `runBenchmark` calls `GC.collect()` and
`GC.minimize()` before the frame loop, and `reportMode` takes `profileBefore` *before* that call.
The published collection counts include at least that startup cycle. `docs/steadygc-evaluation.md`
already warns that `maxPauseTime` is polluted by it. Phase 1 moves the snapshot.

## Constraints

- Do not change `symgc.gcobj`'s public surface or `core.memory.GC`.
- Do not change the meaning of existing `SYMGC_*` variables. A new variable is out of scope; the
  behavior that wins has to be the default on this workload and on `bullet_hell_stress`.
- DMD 2.112+ and LDC with frontend 2.112+, Linux x86-64. Paths that already compile for Windows
  and Android keep compiling. `madvise` and `userfaultfd` stay inside their existing `version`
  blocks. Synchronous sweep is already the Windows path; do not make Linux depend on a Windows-only
  branch by accident.
- One behavioral change per commit, with the before/after table in the commit message.
- Docs in `symgc/BENCHMARKS.md` and `symgc/guide/benchmarks.md` are append-only. Rows where
  steadygc still loses stay in the table.
- No push, no publish, no pull request unless the owner asks. Commits are local. Every `symgc/`
  commit also lands as a patch in `plans/symgc-patches/`.

## Acceptance

Paced `--worst` and `--openworld`, DMD and LDC, medians of 5 fresh processes, 600 frames:

- mean frame ≤ 1.2× the druntime mean from the **same session**;
- worst frame ≤ the druntime worst frame from the same session;
- zero frames over 16.667 ms across the 5 runs;
- `--worst-safe` mean, p99, and worst frame no worse than that session's druntime run (a tie is the
  current result; a win is fine).

Regression, same session, 3 runs, median of the worst frame:

- `bench/compare.sh bullet_hell_stress.d 30 2048 100000 0.05 256` under DMD and under LDC.
  Reference shape on this machine: concurrent steadygc worst frame ~10.6 ms (DMD) and ~11.9 ms
  (LDC), 0 frames over 16 ms, peak RSS ~2.9 GB. The bar is the same session's pre-change steadygc
  run: worst frame not higher than that run by more than the spread of those 3 runs, 0 frames over
  16 ms, peak RSS ≤ 110% of that run.
- `bench/correctness.sh` exits 0 (`mark_race`, `mark_race_glue`, `finalizer_order`,
  `thread_exit_race`).
- Peak RSS of the existing `compare.sh` workloads that get re-run (`bullet_hell_stress`, and
  `gcb.d alloc 1` / `alloc 8` / the fragmentation mode if a change touches the allocator or the
  minimizer) stays within +10% of the same-session baseline.

If a hypothesis is dropped, the commit or the doc appendix names the measurement that dropped it.
A change without that measurement is out of scope.

## Phase 0 — land the paced benchmark so every later number comes from one command

Do this first, before any collector edit. The benchmark is the instrument.

1. From game-engine `88f28dfe`, copy `source/demo/gc_benchmark.d` to
   `symgc/bench/engine_gc_benchmark.d`.
2. Vendor the modules it imports, from that same commit, into `symgc/bench/engine_core/`:
   `pod.d`, `handle.d`, `strings.d`, `arena.d`, `attrs.d`. A one-line comment at the top of each
   names the upstream repo, commit, and path. Do not vendor `engine.core.gc`. The bench selects
   the collector by how it is linked, not by `mixin UseSteadyGC`, so the druntime binary does not
   contain `symgc.gcobj`.
3. Pacing, inside `runBenchmark`, immediately after `frameTimes[i]` is stored. The sample stays
   the work. Sleep until the deadline, because `Thread.sleep` can return early:

   ```d
   immutable deadline = t0 + FRAME_BUDGET;
   while (MonoTime.currTime < deadline)
       Thread.sleep(deadline - MonoTime.currTime);
   ```

   `FRAME_BUDGET` is already `16.msecs + 666.usecs`.
4. In `reportMode`, after `printStats("frame", frameStats)`, count samples `> FRAME_BUDGET` and
   print `over16ms=<n>`.
5. Move `profileBefore` / `usedBefore` to after the startup `GC.collect()` / `GC.minimize()` inside
   the timed run, so the delta is in-frame cycles only. Keep the startup collect; it is what makes
   run 2 start from a collected heap. Print both the in-frame delta and, on a separate line, the
   fact that the startup cycle was excluded.
6. Per frame, sample `GC.frameStats` (steadygc) around `simulateFrame` and accumulate:
   - sum and max of `threadAllocTime`, `threadCollectTime`, `threadPauseTime` deltas;
   - count of frames with `isCycleActive` true at the end of the frame;
   - count of frames whose work time is above 16.667 ms, split by `isCycleActive`.
   druntime's `frameStats` may be zeros. Print the fields anyway and write "unsupported" when the
   totals stay zero, rather than inventing a split.
7. One machine-readable line so a script can parse it without scraping the prose table:

   ```text
   RESULT scenario=worst gc=steadygc mean_ms=9.490 p50_ms=8.700 p99_ms=15.900 worst_ms=21.300 over16ms=6
   ```

   `compare.sh` already keeps a line matching `RESULT`.
8. Build two binaries. Linking symgc into the druntime binary makes druntime scan symgc's static
   data (measured in Phase 0 of the RFC as about 40× on a collection-heavy run). The user's
   reproduction already uses two binaries; keep that. Do not use `compare.sh`'s single-binary
   `gc:sdcq` switch for this comparison.

   ```sh
   # $ENGINE is a checkout of game-engine at 88f28dfe; $SYMGC is the symgc repo.
   dmd -O -release -inline -preview=dip1000 -version=NoSDL -version=NoWGPU \
       -I"$SYMGC/bench" -J. \
       "$SYMGC/bench/engine_gc_benchmark.d" \
       "$SYMGC/bench/engine_core/"{pod,handle,strings,arena,attrs}.d \
       -of=gcb_druntime
   dmd -O -release -inline -preview=dip1000 -version=NoSDL -version=NoWGPU \
       -version=Symgc_druntime_hooks -version=SymGC \
       -I"$SYMGC/bench" -I"$SYMGC/source" \
       "$SYMGC/bench/engine_gc_benchmark.d" \
       "$SYMGC/bench/engine_core/"{pod,handle,strings,arena,attrs}.d \
       $(find "$SYMGC/source" -name '*.d') \
       -of=gcb_steady
   ```

   Repeat with `ldc2 -O3 -release` and `-d-version=...`. The steadygc binary needs
   `--DRT-gcopt=gc:sdcq` only when `rt_options` is not already set; a binary whose only collector
   registration is symgc's `sdcq` factory still follows `bench/build.sh` and passes the flag.
   The druntime binary is run with `DRT_GCOPT=precise:1` and no symgc objects in the link.
9. `bench/engine_gc_compare.sh` (or a branch inside `compare.sh` that triggers only for this
   program) runs the three scenarios (`--worst`, `--openworld`, `--worst-safe`) on both binaries,
   5 times, and prints the median of mean / p99 / worst / over16ms sum / `/usr/bin/time` user, sys,
   minor faults, and peak RSS. One invocation, both compilers when `DC` is unset is not required;
   `DC=dmd` and `DC=ldc2` are two invocations, matching `build.sh`.
10. Reproduce the table in the Goal section within noise before any collector edit. Record
    `uname -r`, core count, CPU governor, and the two compiler versions in the results header.
    If the reproduced mean ratio on `--worst` is already ≤ 1.2×, stop and write that down; the
    rest of this plan does not apply to a gap that is not there.

`benchmarks.md` and `BENCHMARKS.md` gain a section only after Phase 1's numbers exist, not after
the harness lands. The harness commit's message says the benchmark was added and was not yet the
performance result.

## Phase 1 — attribute the extra CPU before changing code

Question to answer, in one table: of the ~4.5 s extra user CPU and the ~4.3 ms extra mean frame on
`--worst` DMD, how many milliseconds sit in each bucket below. Repeat the attribution for LDC
`--worst` and for DMD `--openworld` (shorter run is fine: 200 frames) so a `--worst`-only cause is
visible.

### 1.1 Per-frame split from `GC.frameStats`

For each steadygc run, from the new counters:

| Bucket | How |
|---|---|
| Pause on this thread | sum of `threadPauseTime` deltas |
| Slow alloc | sum of `threadAllocTime` deltas |
| Assist / wait for a cycle | sum of `threadCollectTime` deltas |
| Quiet-frame residual | sum of work time on frames with `isCycleActive == false`, minus the three timers on those frames |
| Cycle-frame residual | the same, for frames with `isCycleActive` |

The quiet-frame residual is fast-path allocation plus the D code of the frame (`format`, stores,
linked-list walks). druntime has no matching timer. Subtract druntime's mean quiet-frame work from
steadygc's quiet-frame residual to get the mutator gap that timers cannot see.

Also print the fraction of frames with `isCycleActive`, and the mean work of those frames against
the mean of the others. If the "median is a frame without a collection" claim is wrong and half
the frames are inside a sweep, hypothesis 3 is already the leading explanation and Phase 2 starts
there.

### 1.2 Stack samples

Prefer `perf`. If `perf` cannot open the counters on this VM, use `perf stat` for the totals and
`valgrind --tool=callgrind` on a 30-frame `--worst` run for the stacks. Say which tool, and that a
30-frame callgrind is not a 600-frame timing result.

```sh
perf record -g --call-graph dwarf -F 997 -s -o worst.data -- ./gcb_steady default 600 --worst
perf report -s comm,dso,symbol --stdio -n < worst.data
```

Separate the mutator, the sweeper, and the marker threads by `comm` (the sweeper and markers are
created in `createGCThread`; confirm their names in `/proc/<pid>/task/*/comm` during a run). The
table:

| Thread | user CPU seconds | top 5 symbols, self percent |
|---|---|---|
| mutator | | |
| sweeper | | |
| marker(s) | | |
| other | | |

Symbols expected if a hypothesis is true (self time, not children, so a parent `allocSmall` does
not hide a `memset`):

| If this is hot on the mutator | Hypothesis |
|---|---|
| `allocSmall` / `memset` / `initializeMetadata` / `ThreadBin.allocate` | 1, fast path |
| `ThreadBin.refill` / `batchAllocSmall` / filler lock | 1, slow path |
| `paceSweeper`'s counterpart on the mutator: lock in `sweepStep`, `assistSweep` | 3 |
| `scanImpl` on a marker, not on the mutator | 4, tail and background CPU, not the quiet frame |
| page fault / `clear_page` / `madvise` in sys time | 2 |

Run the same `perf record` on `gcb_druntime` with `DRT_GCOPT=precise:1` and put the two mutator
columns side by side. The gap between them is the thing to fix.

### 1.3 One size-class histogram, under the existing trace version

Build one binary with `-version=Symgc_phase_trace` (already in the tree; it prints slow refills).
Add no new public counter. A `fprintf` under that version, from `allocSmall` and from the large
path, of `(sizeClass, containsPointers, appendable, bytes)` aggregated in process is enough, dumped
once at exit. 30 frames of `--worst` and 30 of `--openworld`.

What to look at: the class-instance size class after the `size + 1 + PointerSize` bump, the
`int[]` size classes, and how often the bin misses. If the bump lands a 48-byte object in a much
larger slot, that is internal fragmentation on the hot path (more `memset`, worse cache), and it
is a concrete edit rather than a vague "allocator is slow".

### 1.4 The deliverable of Phase 1

A table in `symgc/guide/benchmarks.md` (and a short version in `BENCHMARKS.md`) with the buckets
above for DMD and LDC, `--worst`. Plus one sentence of the form "the dominant mutator cost is X,
N ms/frame; the dominant other-thread cost is Y, N seconds/run." If those two sentences cannot be
written, do not start Phase 3.

## Phase 2 — falsify the remaining hypotheses, one knob at a time

Each row is a run, not a code change, except where a compile-time version is the only switch that
exists. Compare against the Phase 1 baseline on the same machine, same compilers, 5×600 `--worst`
and 5×200 `--openworld`. Keep the bullet-hell command out of this phase unless a row is about to
become the default.

### Hypothesis 1 — allocation path

Already the leading candidate for the quiet-frame residual if Phase 1 puts the mutator gap in
`allocSmall` / `memset` / `initializeMetadata` rather than in `std.format`.

Falsifier: a microbenchmark in `bench/` that does only the allocation mix, with no `format` and no
stores into a live graph. Suggested shape, one thread, timed with `MonoTime`, objects kept or
dropped to match `--worst`:

- A: `new` of a class with one `int` and one class reference, in a loop, retaining a small window
  (the inventory pattern).
- B: `new int[](32)` in a loop (appendable, `NO_SCAN`).
- C: `new` of a struct array the size of `PointerVertex[]` (appendable, scanned).

Run A/B/C under both binaries, DMD and LDC, a few million iterations, report ns/op and RSS. If
steadygc matches druntime on A/B/C and loses only on `engine_gc_benchmark`, the cost is in the
frame's non-GC work or in the interaction (for example `format`'s append pattern), and the
collector is the wrong layer. If A or B is already ~1.8×, the collector's small-object path is
sufficient and Phase 3 may edit it.

The README's 0.79× single-thread throughput (`gcb.d`, `BENCHMARKS.md` section 3) is a different
mix (uniform small objects, not appendable class+string churn) and was measured on the 8-core
machine. Re-run `bench/compare.sh gcb.d alloc 1 4000000` in this session so the microbenchmark and
the old number are not mixed.

### Hypothesis 2 — give memory back, fault it in again

Mostly bounded already: with the tracker off, minor faults are 39 k vs druntime's 28–30 k, and
user CPU is still 8.6 s. One `strace -f -c -e madvise` (or a counter under `Symgc_phase_trace` in
`pages_purge`) on a single `--worst` run closes it:

- Record `madvise` call count, total bytes, and total time, per cycle.
- If purge time is well under 0.2 s for the run, write "hypothesis 2 does not explain the CPU gap"
  and stop touching the minimizer.
- `--openworld` RSS is already lower for steadygc (46 MB vs 74 MB DMD). That is the minimizer
  working. Do not "fix" it by retaining more unless Phase 1 shows faults in the mutator's user or
  sys time.

The 127 k extra faults with the tracker on stay in Phase 4.

### Hypothesis 3 — background sweep

Untested, and the first experiment to run if Phase 1 shows the sweeper using a large fraction of
the extra 2 s, or shows `isCycleActive` on most frames.

1. `SYMGC_SWEEP_DUTY=1` (sweeper sleeps ~99× its work) with concurrent mark left on, and again with
   `SYMGC_CONCURRENT_MARK=0`. Duty is read when the sweeper thread starts.
2. Trap: if `usedPages > gSweepGrowthLimit`, `paceSweeper` does not sleep, so duty 1 is a no-op.
   Phase trace already has sweep-phase timers (`gSweepT`). Log whether the sweeper actually slept
   (the `sleepMicros` path) for this run. A duty-1 run that did not sleep does not falsify anything.
3. If duty 1 sleeps and the mean frame does not move, the sweeper's CPU share is not the mean.
   Continue to the sync-sweep build anyway if the sweeper's lock shows up in the mutator's stacks,
   because lock wait is not the same as CPU share.
4. `-version=Symgc_sync_sweep` build. Remember it also disables the concurrent mark. The comparison
   that isolates the sweeper is:

   | Build | Mark | Sweep |
   |---|---|---|
   | `SYMGC_CONCURRENT_MARK=0` (already measured, mean still 2×) | stop the world | background |
   | `-version=Symgc_sync_sweep` | stop the world | on the cycle thread |

   If the sync-sweep mean drops to ≤ 1.2× druntime and the stop-the-world-mark + background-sweep
   mean stays at ~1.8×, the sweeper is the cause of the mean. If both stay at ~1.8×, the sweeper
   is not the cause of the mean.

Watch RSS and the worst frame on this row. A sweep that never runs in the background can hand the
mutator a long sweep inside a collection frame. That may fix the mean and break the worst frame,
which fails acceptance. Record both.

### Hypothesis 4 — conservative scan

Explains `totalCollectionTime` (1.5 s vs 0.17 s) if Phase 1 shows `scanImpl` dominating marker
CPU. It does not explain a quiet frame. `--openworld` is the control: little scanned payload per
byte allocated.

Falsifier: under `-version=Symgc_phase_trace`, `gScanBytes` is already incremented in
`Scanner.scan`. Print it per cycle next to druntime's mark time. If steadygc scans several times
the bytes druntime does on `--worst` and a similar amount on `--openworld`, the scan is a tail
problem for `--worst` only. A precise scanner is then in scope for the worst-frame criterion, and
out of scope as an explanation of the `--openworld` mean.

Do not start a precise scanner because the byte counts differ. Start it only if the worst frame is
still over druntime's after the mean-frame cause is fixed, and the samples say the extra time is
`scanImpl`.

### Hypothesis 5 — locality

In scope only when `perf` shows the mutator stalled on cache or DTLB misses inside the allocator
or on the inventory pointer chase, and hypotheses 1 and 3 have been accounted for. A layout change
of size-class slabs is a large edit. It needs the microbenchmark from hypothesis 1 showing a
miss-rate gap on pattern A, not only a story about linked lists.

### Hypothesis 6 — DMD code generation

LDC's `--worst` mean ratio is about 1.35× (6.23 / 4.62) and DMD's is about 1.82× (9.49 / 5.23).
Both miss 1.2×. A DMD-only code-quality fix cannot be the whole result.

If the hot function is the same on both compilers, treat it as an algorithm problem (hypotheses
1–4). If DMD's profile is a different function — a bounds check, a missed inline of `allocSmall`
or `initializeMetadata`, an `assert` that `-release` should have dropped — then look at that
function second, after the shared cause. Check the actual DMD assembly of that one function
(`dmd -O -release -inline -output-s` or `objdump -d`) before rewriting it. Prefer a structure the
inliner can see (smaller function, `pragma(inline, true)` on the fast path) over a hand-written
special case.

## Phase 3 — change the collector, one cause at a time

Start only from the sentence Phase 1 produced. The edits below are the ones that match a confirmed
cause. Skip the rest. Each edit is one commit, measured with `engine_gc_compare.sh` (DMD and LDC,
5 runs, three scenarios) and the bullet-hell regression before the next edit.

### 3.1 Fast path, if hypothesis 1 is confirmed

Work in this order, stopping when acceptance is met. Each step's predicted effect is on ns/op of
microbenchmarks A and B and on the quiet-frame residual, not on the marker.

1. **Tail clear.** `allocSmall` memsets `slotSize - size` on every pointer allocation that did not
   ask for zero. Measure that `memset` alone (perf self time). If it is a large part of the quiet
   frame, clear only the words a later conservative scan could mistake for pointers, or clear once
   when the slot is freed (`freeSmall` already memsets pointer slots when `ShouldZeroFreeSlabs` is
   true — confirm that flag's value before adding a second clear). A slot that is both cleared on
   free and cleared on alloc is paying twice; that is the first thing to delete if the flag is on.
2. **Class size bump.** If the histogram shows `size + 1 + PointerSize` promoting the hot class
   into a wider bin, store the finalizer the way a post-hoc `FINALIZE` already can (`d.gc.late`)
   or pack it without growing the requested size, and re-measure the size class. The metadata word
   has to stay correct: `initializeMetadata`, `getAttr`, and the finalizer call in `destroy` are
   the tests. `bench/correctness.sh` and the existing `tcache` unittests cover a double-free and a
   finalizer bit left on a recycled slot; run them. This must not change `GC.getAttr` results for
   a block the runtime allocated with `FINALIZE`.
3. **Appendable slow metadata.** If `initializeMetadata` is hot, keep the bit layout and remove
   work around it (extent flag stores on every object when the extent is already flagged). Do not
   invent a second metadata format.
4. **Refill.** Only if `threadAllocTime` or `slowrefill` in the phase trace is a sizable share of
   the frame. The batch size is `ThreadBinState.getFill`. A larger batch helps a miss storm and
   hurts a thread that uses a size class once. Measure both `--worst` (miss storm) and
   `bullet_hell_stress` (different size mix) before keeping it.

Out of scope for this hypothesis: a new allocator, Immix, or a thread-local bump pointer that
skips the bin. Those are different collectors.

### 3.2 Sweeper, if hypothesis 3 is confirmed

The default has to keep the 2 GiB bullet-hell worst frame. A global "sweep synchronously" or
"duty = 1" fails that if the large heap needs the background sweep to finish before the next
cycle (the growth limits exist because an unfinished sweep inflates the heap).

The shape of an acceptable fix, if the small-heap run is the one that suffers:

- When the live heap is small relative to the machine, do not run the sweeper flat out beside the
  only mutator. Concrete policy to test, not to assume: if the cycle's used pages are below a
  threshold that is far under the bullet-hell heap (the engine cases are 11–64 MB; bullet-hell is
  ~2.9 GB), run that cycle's sweep in bounded slices on the triggering thread after the world
  restarts, with the same per-step budget `SweepStepBudget` already uses (~10 µs under the filler
  lock). Large heaps keep today's background sweeper.
- Pick the threshold from the two measurements, not from a round number chosen first. A wrong
  threshold either leaves `--worst` slow or pulls bullet-hell onto the slow path.
- Re-measure RSS. The +10% cap is a hard stop. Also re-measure `--worst` worst frame: slices on
  the mutator add to the collection frame.

Do not encode the policy as a new `SYMGC_*` variable. The existing duty variable stays the
override it is today.

### 3.3 Precise scan, if hypothesis 4 is confirmed and the tail still fails

druntime already receives `TypeInfo` on allocation. `sdcAllocate` uses it only to decide where to
put a finalizer (`getContextPointer`). A precise scan would, for blocks that carry a type, walk
the pointer map instead of every word. Blocks with no type (interior pointers, `void[]`, C malloc
the scanner still sees) stay conservative. `NO_SCAN` stays skipped.

This is the largest edit in the plan. Do it only after 3.1 / 3.2 have been accepted or rejected
with numbers, and only if the worst frame is still the marker. Requirements if it is attempted:

- Mark result must be identical on `correctness.sh` and on a retained-graph test (the `--worst`
  roster must not lose NPCs; a missing edge shows up as a finalizer on a live object or as a
  crash, so run long enough to collect many times).
- `totalCollectionTime` on `--worst` should move toward druntime's. If the byte count drops and
  the worst frame does not, the scan was not the tail; revert.
- Bullet-hell's garbage is short-lived and mostly not a pointer graph. Confirm the worst frame
  stays in band. A precise scan that is slower on pointer-free blocks is a bug in the
  implementation.
- No change to `GC.*` or to the `BlkAttr` values the runtime already passes.

### 3.4 What not to do

- Do not tune `SYMGC_MARK_THREADS`, `SYMGC_SWEEP_DUTY`, or `SYMGC_CONCURRENT_MARK` and call that
  the fix. Those were either already tried or are measurement knobs. The default build, with the
  variables unset, is what acceptance runs.
- Do not disable minimization to win a microbenchmark. The large-heap RSS win depends on giving
  unused pages back; `--openworld` already shows a lower RSS.
- Do not copy druntime's pools in alongside the slab allocator "just to compare" inside the same
  binary. The comparison is two binaries.

## Phase 4 — dirty-page faults, after the frame-time goal

Separate from acceptance. The tracker-on run faults ~127 k more pages than the tracker-off run,
~0.2 s, and slightly more sys time (0.6–0.8 s vs 0.3 s). Fix this only if Phase 1–3 have met the
frame-time bar or have shown that the remaining over-budget frames are these faults.

Measure, do not guess:

- `perf stat -e minor-faults,major-faults` on the mutator thread with the tracker on and off.
- Under `Symgc_phase_trace`, the existing dirty-scan reports how many pages a round returns.

Candidates, in order, each with a fault-count before and after on `--worst` and on
`bullet_hell_stress` (the 2 GiB heap is where arming cost showed up in `plans/spikes/dirty`):

1. Register only extents that contain pointers, which is already the stated rule in `dirty.d`.
   Verify with a trace that `NO_SCAN` slabs are absent from `register`. If they are present, that
   is a bug, and fixing it is this phase.
2. Re-arm only pages the previous round reported dirty, instead of re-protecting every registered
   page every round. The remark pause still has to scan anything written since the last arm; a
   page that is not armed must be treated as dirty or the mark is unsafe. `mark_race` /
   `mark_race_glue` are the tests that fail if a written page is missed. Read them before editing
   `dirty.d`.
3. Leave the tracker off for a cycle whose scannable heap is tiny, and pay a stop-the-world mark
   instead, only if that cycle's fault cost exceeds its scan cost in the Phase 1 numbers. This is
   the same shape as 3.2: small heap and large heap want different things. Bullet-hell at 2 GiB
   must keep the concurrent mark, because that is the run whose worst frame fell from 166 ms to
   10.6 ms.

## Phase 5 — write the numbers down

Append, do not replace, in:

- `symgc/BENCHMARKS.md` — a new section "Small live heap, heavy allocation" with the paced
  engine benchmark, DMD and LDC, the three scenarios, both collectors, from the final session.
  Include rows that still lose. Point at `bench/engine_gc_compare.sh`.
- `symgc/guide/benchmarks.md` — the same table, the Phase 1 attribution, which hypotheses were
  dropped and the measurement that dropped them, and the machine header (`uname -r`, cores,
  governor, compilers).
- `plans/symgc-patches/README.md` — one row per patch, the way the existing table is written.

State what was only compiled. Windows and Android are compile-only unless they were actually run.
The 8-core `BENCHMARKS.md` tables stay as the historical session they are; do not overwrite them
with 4-core numbers. Label the new section with this machine so a later reader does not average
the two.

## Order of work

1. Phase 0 harness, reproduce the gap, stop if it is gone.
2. Phase 1 attribution table. Write the two sentences (mutator bucket, other-thread bucket).
3. Phase 2 row for whichever hypothesis those sentences name. Duty 1 and the sync-sweep build are
   cheap; run them before a precise scanner even if the sentences point at the scan, because they
   can change the tail the scanner would be asked to fix.
4. Phase 3, one edit, full matrix, bullet-hell, `correctness.sh`.
5. Repeat 3–4 until acceptance, or until the remaining gap is smaller than the noise of 5 runs.
   If acceptance is missed, the last commit's message says which criterion failed and by how much.
   Do not keep editing past a second idea that the profile does not support.
6. Phase 4 only if faults are still the remaining problem.
7. Phase 5 docs and patches.

## 0058 results (2026-10-13, 16-core Linux, DMD 2.113)

Root cause of the residual after 0056: Phobos `Appender` / `std.format` call `GC.qalloc(nbytes,
BlkAttr.NO_SCAN)` **without** `APPENDABLE`, so the 0056 `allocAppendable` 64-byte floor never ran.
Each `format` started at an 8-byte slot and grew `8→16→32→64` with a failed `GC.extend` (uncached
emap) between steps.

Patch **0058** (`symgc` `8f429d7`): floor plain small `NO_SCAN` `qalloc` requests to 64 bytes;
`extendLarge` uses `maybeGetPageDescriptorCached`. Kept the 0056 `allocAppendable` floor (helps
`new T[]` NO_SCAN; not the format path). Hypothesis 2 (streamline `allocAppendable`) not needed for
the mean.

Medians of 5 paced runs, 600 frames, two-binary harness:

| Scenario | druntime mean | steadygc mean | ratio | worst (dru / steady) | over16 sum |
|---|---|---|---|---|---|
| `--worst` | 5.087 ms | 5.818 ms | **1.14×** | 10.784 / 10.963 | 0 / 0 |
| `--openworld` | 0.527 ms | 0.591 ms | **1.12×** | 1.321 / 1.658 | 0 / 0 |
| `--worst-safe` | 2.589 ms | 2.619 ms | ~1.01× | 5.564 / 6.981 | 0 / 0 |

- **Mean ≤1.2×:** met on `--worst` and `--openworld`.
- **Worst frame ≤ same-session druntime:** `--worst` within ~1.7% (noise); `--openworld` and
  `--worst-safe` worst still higher (same pattern as the post-0056 baseline before 0058).
- **`--worst-safe` mean/p99:** within ~1–2% of druntime (tie within 5-run noise); worst remains
  the criterion that still fails by ~1.4 ms median.
- **`bullet_hell_stress` concurrent:** max ~2.5 ms, 0 over 16 ms, RSS ~2.9 GB (large-heap win holds).
- **`correctness.sh`:** OK (`mark_race`, `mark_race_glue`, `finalizer_order`, `thread_exit_race`).
- **LDC matrix:** not re-run this session (prior card-stub link issue unchanged).

Phase 4 (dirty-fault work) remains deferred.

## 0060 results (2026-10-13, 16-core Linux, DMD 2.113)

Patch **0060** (`symgc` `5995376`): streamline `allocAppendable` — skip `SlabEntry` rebuild on
small; return `Extent*` from `allocLarge` for large (no second emap lookup).

Medians of 5 paced runs, 600 frames, two-binary harness:

| Scenario | druntime mean | steadygc mean | ratio | worst (dru / steady) | over16 |
|---|---|---|---|---|---|
| `--worst` | 4.832 ms | 5.483 ms | **1.14×** | 9.671 / **8.490** | 0 |
| `--openworld` | 0.481 ms | 0.534 ms | **1.11×** | 1.278 / **1.266** | 0 |
| `--worst-safe` | 2.419 ms | 2.392 ms | **0.99×** | 5.348 / **6.556** | 0 |

- Mean ≤1.2×: still met. `--worst`/`--openworld` worst: **met** this session.
- `--worst-safe` mean/p99: met (mean better; p99 within ~0.6%); **worst still fails** (~+1.2 ms,
  stable across all 5 runs ≈6.5–6.6 ms — not run-to-run noise).
- `bullet_hell_stress` concurrent: max **1.5 ms**, 0 over 16 ms, RSS ~2.9 GB (run).
- `correctness.sh`: OK (run).

## Risks

- **Same-binary comparison.** `compare.sh` links symgc and then runs druntime by omitting
  `gcopt`. That pessimizes druntime. This plan's script must not do that. A single sanity run
  that does it, reported separately, is useful: if that druntime is much slower than the
  two-binary druntime, the evaluation doc's same-binary note (`--DRT-gcopt=gc:conservative` on a
  binary that contains symgc) needs a footnote. Do not "fix" the benchmark by switching to that
  mode.
- **Pacing hides a collector that only wins when the mutator never sleeps.** That is intentional.
  The unpaced numbers in `docs/steadygc-evaluation.md` (DMD `--worst` mean 4.17 vs 8.32 ms) are
  the same shape. The acceptance run is paced because a concurrent collector is built for a frame
  budget with idle time. Keep one unpaced `--worst` DMD pair in the doc appendix so a later change
  that only wins by filling the sleep is visible.
- **Startup `GC.collect` in the profile delta.** Phase 0 step 5 exists so a "we collect less" claim
  is about the frames.
- **`Symgc_sync_sweep` confounded with the mark.** The isolation table in hypothesis 3 is the
  whole point of that build. Publishing "sync sweep fixed it" when the build also disabled the
  concurrent mark would mis-attribute the result.
- **Duty 1 silently ignored** when the heap is over the growth limit. Check the sleep counter.
- **Fixing the mean and breaking the 2 GiB heap**, or the reverse. Both matrices are mandatory on
  every behavioral commit.
- **Noise.** Frame-time noise on the older 8-core notes was several percent, and this VM is
  smaller. Medians of 5. A 5% move is not a result. The acceptance gap on DMD `--worst` is ~80%
  (9.49 / 5.23), so the first real fix should be obvious.
- **Callgrind substituting for `perf`.** Instruction counts are not the 4-core contention story
  (hypothesis 3). If only callgrind is available, say so, and still run the duty-1 and sync-sweep
  timing ablations, which do not need a profiler.
