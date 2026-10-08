# Collector comparison on one binary: conservative, parallel, fork, symgc

`gcb.d` is a Phobos-free benchmark (the repo's druntime has no Phobos next to it). It is built twice
with the repo's own dmd (2.113 master) and druntime:

- `gcb_plain`: no symgc linked. Run with `gc:conservative`, `gc:conservative parallel:8`, `gc:conservative fork:1`.
- `gcb_sym`: symgc sources linked (`-version=SymGC -version=Symgc_druntime_hooks`), run with `gc:sdcq`.

Two binaries are needed. With symgc linked in, the conservative collector scans symgc's static data as roots
and `alloc` runs about 40x slower (16.4 s against 0.41 s). Comparing inside one binary would have
produced a false "symgc is 30x faster".

```
./run_core.sh [reps] [outdir]      # builds both, runs 9 cases x 4 collectors, medians of 3
./summarize.sh outdir/raw.txt
```
Results: `results/raw.txt`, `results/summary.txt`. Machine: Ryzen 7 3800X, 16 threads, 32 GiB.

## Results (medians of 3)

| case | collector | secs | RSS MiB (steady) | notes |
|---|---|---:|---:|---|
| alloc, 1 thread, 8M | conservative | 0.42 | 4 | |
| | symgc | 0.54 | 32 | 0.77x |
| alloc, 4 threads, 4M each | conservative / parallel / fork | 2.02 / 1.68 / 1.56 | 4 / 4 / 258 | |
| | symgc | 0.48 | 28 | **4.2x** faster than conservative |
| alloc, 8 threads, 4M each | conservative / parallel / fork | 8.23 / 8.17 / 7.30 | 4 / 4 / 391 | |
| | symgc | 0.75 | 41 | **11x** faster than conservative, 9.8x than fork |
| frag (sizes 16 B to 64 KiB, 100k slots, 15M steps) | conservative | 11.7 | 979 | |
| | fork | 19.4 | 3968 | |
| | symgc | 42.5 | 634 | **3.6x slower**, 35% less memory |
| fragsmall (16 B to 2 KiB, 400k slots, 30M steps) | conservative | 8.5 | 1011 | |
| | symgc | 14.1 | 762 | 1.7x slower, 25% less memory |
| trav (2M nodes, 10 traversals) | conservative | 0.365 | 344 | 36.5 ms per traversal |
| | symgc | 0.248 | 209 | 24.8 ms per traversal (1.5x faster), 39% less memory |
| tree (depth 18) | conservative | 9.8 | 299 | |
| | fork | 6.8 | 1136 | |
| | symgc | 10.3 | 207 | same speed, 31% less memory |
| latency, 256 MiB live, largest request | conservative / parallel / fork / symgc | | 789 / 795 / 1080 / 461 | 122 / 135 / 7.2 / 27.9 ms |
| latency, 1 GiB live, largest request | conservative / parallel / fork / symgc | | 1731 / 1725 / 2045 / 1379 | 506 / 244 / 20.5 / 89 ms |

## What it says

1. **symgc already meets M1 and M5.** M1 asks 3x the conservative collector at 8 threads and no less than symgc: 11x.
   M5 asks no more RSS than the conservative collector: 20 to 40% less in every case. Pause (largest request at
   1 GiB live) is 5.7x shorter than the conservative collector's, because it marks with all cores.
2. **Single-thread allocation is 0.77x**, short of M2's 0.95x. Its thread-cache fast path is not free.
3. **Its weakness is large objects, not small ones.** `frag` spends 3.7 s of 5.5 s in the kernel: 174k `madvise`
   calls for 2M steps, about one per freed large object. That is a decommit policy and can be tuned without a redesign.
4. **It is still stop-the-world.** 0.087 ms per live MiB (89 ms at 1 GiB) puts 4 GiB near 350 ms, against M3's
   2 ms. Parallel marking cut the constant, but only concurrent marking removes the growth with heap size.
5. **fork marking is the best existing pause** (7 ms and 20 ms) but costs 18% to over 300% more memory (copy-on-write; 4x on `frag` and `tree`)
   and is slower on `frag` and Linux-only.
6. Fibers, `std.*` workloads and vibe.d are not covered here (no Phobos for this druntime).

## Frame-loop test (`frames.sh`): the real-time-game case

60 fps loop, 5000 allocations per frame, a 512 MiB or 2 GiB live world, 1200 frames, one run each. The
numbers are the per-frame *work* time, so anything above the median is the collector interfering.

| live | collector | p50 | p99 | p99.9 | worst frame | frames > 1 ms / 2 ms / 5 ms | RSS |
|---|---|---:|---:|---:|---:|---|---:|
| 512 MiB | conservative | 0.56 ms | 1.1 | 65.6 | **249 ms** | 24 / 2 / 2 | 1215 MiB |
| | fork | 0.69 | 1.1 | 8.2 | 13.7 | 53 / 3 / 2 | 1344 |
| | symgc | 0.92 | 1.8 | 35.0 | **52 ms** | **444** / 11 / 10 | 722 |
| 2 GiB | conservative | 0.75 | 1.2 | 1.6 | **570 ms** | 89 / 1 / 1 | 3161 |
| | fork | 0.85 | 1.3 | 9.9 | 40 | 150 / 2 / 2 | 3254 |
| | symgc | 1.17 | 1.8 | 112 | **112 ms** | **1027** / 5 / 4 | 2542 |

None is close to imperceptible. The worst frames are stop-the-world pauses (hundreds of milliseconds for the
conservative collector, 52 to 112 ms for symgc, 14 to 40 ms for fork). symgc has a second problem the pause
numbers hide: its ordinary frames were 1.6x slower at the median in that run. A re-run with
`FRAMES_DUMP=1 build/gcb_sym frames 512 1200 5000 --DRT-gcopt=gc:sdcq` (lists frames over 2 ms) showed that the
frames over 2 ms are the stop-the-world collections only (one every ~114 frames; 20 to 35 ms at 512 MiB, 56 to 89 ms
at 2 GiB), and `strace -f -T` showed ~19.8k `madvise` calls (8 us each, 0.8% of runtime, longest 0.29 ms). The
earlier "allocation-path jitter" reading (1027 frames over 1 ms) did not reproduce (32 at 2 GiB); treat it as noise.

## Where symgc's collection time goes (`symgc_phase_trace.patch`)

`patch -p1 -d symgc < bench/core_bench/symgc_phase_trace.patch`, build with `-version=Symgc_phase_trace`; each cycle
prints one `gcphase` line to stderr (microseconds). The `frames` loop (5000 allocations per frame), last cycles:

| live | threads | stop-the-world (prepare + mark) | sweep after restart | whole cycle |
|---|---:|---:|---:|---:|
| 512 MiB | 16 | 12.6 ms | 13.7 to 18.7 ms | 26 to 32 ms |
| 2 GiB | 16 | 33 ms | 22 to 47 ms | 56 to 81 ms |
| 2 GiB | 1 | 268 ms | 35 ms | 304 ms |
| 2 GiB | 4 / 8 / 16 | 69 / 40 / 29 ms | 37 / 36 / 36 ms | |

- Stop-the-world work is only prepare (1 to 2 ms) and mark; stopping and restarting threads costs 1 to 3 µs.
- The **sweep is not in the pause but it is on the triggering thread** (`collect(gcCycle)` after `restartTheWorld`), so the
  game thread that triggered the cycle loses the whole cycle. It also holds each arena's page-filler mutex for the whole
  sweep, so any thread that needs a refill from that arena waits. It grows with garbage and does not scale with threads.
- Mark is 0.13 ms per live MiB on one thread, scaling ~9x on 16 threads (parallel mark is not a latency fix for a game
  that cannot spare 16 cores).
- The sweep runs finalizers (`runningFinalization`) on the thread that runs it.

### Sweep parts and the probation finding (same patch, `sweepparts` line)

2 GiB live, 16 threads, sweep 17 to 38 ms, split (ms): dense slabs scan 3 to 13 (grows with garbage), dead-extent
free 0.5 to 4, sparse scan 12 to 15 (constant: it walks every live sparse extent), `minimize` (decommit) 1 to 5. At
512 MiB: dense scan 2 to 5, sparse scan 4 to 5, minimize 2 to 3. The sweep is O(live extents) plus O(garbage).

**Probation.** After `restartTheWorld` the threads run again, but any thread that tries to enter the allocator
(`enterBusyState`) waits in `Probation` until `clearWorldProbation()` at the end of the cycle (`tstate.d`). A game
thread allocates every frame, so for it the pause is the whole cycle (mark + sweep), not just the stop-the-world part.
The earlier worst frames (56 to 89 ms at 2 GiB) are exactly the full cycle times.
