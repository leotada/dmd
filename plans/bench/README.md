# GC baseline benchmarks: dmd vs LDC

Baselines for the hybrid TLS-Immix GC (RFC Phase 0.1, metrics M1 to M3, M6, M7). The suite
is the set of workloads in `druntime/benchmark/gcbench/`; the driver builds each one with
both compilers, runs it, and records time, memory and collector statistics.

```
plans/bench/run_compare.sh [-s ci|full] [-r reps] [-t "dmd ldc"] [-o outdir] [workload ...]
plans/bench/compare_runs.sh <base.csv> <base-toolchain> <new.csv> <new-toolchain>
```

Results from this machine are in `results/{ci,full}.{csv,md}`. `ci` is every workload at
a few seconds each, 5 repetitions. `full` is the scaling workloads with larger live sets and
counts, 3 repetitions.

## Setup

| | |
|---|---|
| CPU | AMD Ryzen 7 3800X, 8 cores / 16 threads, governor `powersave` (noisy), THP `always` |
| OS | Linux 6.12, 32 GiB RAM |
| dmd | 2.109.1, `-O -release -inline`, system druntime and Phobos |
| LDC | 1.40.1 (LLVM 19.1.7, frontend 2.110.0), `-O3 -release`, LDC's druntime and Phobos |
| GC | the conservative GC of each druntime, defaults, no `gcopt` tuning |
| Recorded | wall, user, sys (`/usr/bin/time`), peak RSS, and from `--DRT-gcopt=profile:1`: collections, total GC time, max pause |

Medians over the repetitions; min and max wall are in the CSV. `profile:1` has **millisecond
resolution**, so pauses under 1 ms read 0; use `--DRT-gcopt=trace:FILE` (this repo's
druntime, see the RFC) for microsecond pauses once the benchmarks run against it.

The repo's own druntime cannot be benchmarked here yet: there is no Phobos checkout next
to the repo and most workloads import `std.*`. Put one at `../phobos` (what the generated
`dmd.conf` expects), build it, and add a toolchain case to `toolchain_compile`.
For the new collector, either link it into druntime and select it with
`GCOPT_EXTRA="gc:<name>"`, or build a second tree and run with a different `-o`.

## Workloads

| workload | stresses | RFC metric |
|---|---|---|
| `tree1`, `tree2` | allocation of small linked nodes, tree churn | M1 throughput, M4 (tree2 is the store-dense worst case for barriers) |
| `dlist`, `slist` | list nodes built from a text file | M1 |
| `rand_small`, `rand_large` | random-size allocations, many collections | M1, large-object path |
| `words` | associative array of strings | M1, M2 |
| `mt_alloc` | threads allocating short-lived objects, nothing shared | G0b best case for thread-local domains |
| `mt_share` | `std.concurrency` message passing, every object escapes | G0b worst case |
| `append_heavy` | `~=`, `capacity`, `reserve`, `assumeSafeAppend` | M1, array path |
| `parallel_map` | `std.parallelism` over objects | M1, multi-thread scaling |
| `traverse_locality` | tree and list traversal after interleaved garbage | M6 (fragmentation, locality) |
| `frag_longrun` | long-running mixed-size churn, RSS sampling | M7 (RSS over time) |
| `latency` | request loop over a live set; reports p50/p99/p99.9/max | M3 pauses |
| `fiber_latency` | `latency` with many suspended fibers | M3, ADR-9 (fiber stacks as roots) |

## Results

Medians; GC ms is the sum over collections.

### `ci` tier (5 repetitions)

| workload | dmd wall s | dmd RSS MiB | dmd GCs | dmd GC ms | dmd max pause ms | ldc wall s | ldc RSS MiB | ldc GCs | ldc GC ms | ldc max pause ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| tree1 | 0.32 | 15 | 37 | 95 | 4 | 0.31 | 10 | 87 | 64 | 1 |
| tree2 | 0.19 | 4 | 62 | 3 | 0 | 0.12 | 6 | 62 | 2 | 0 |
| dlist | 1.02 | 13 | 101 | 99 | 2 | 0.83 | 16 | 101 | 93 | 1 |
| slist | 0.95 | 13 | 101 | 91 | 1 | 0.81 | 16 | 101 | 83 | 1 |
| rand_small | 3.22 | 14 | 7637 | 684 | 0 | 2.89 | 17 | 7637 | 619 | 0 |
| rand_large | 1.69 | 3 | 7726 | 566 | 0 | 1.79 | 8 | 7813 | 589 | 1 |
| words | 0.70 | 324 | 5 | 50 | 36 | 0.60 | 333 | 5 | 10 | 8 |
| mt_alloc | 0.56 | 4 | 281 | 27 | 0 | 0.49 | 6 | 281 | 30 | 0 |
| mt_share | 0.24 | 4 | 43 | 4 | 0 | 0.17 | 7 | 46 | 6 | 0 |
| append_heavy | 0.17 | 8 | 55 | 2 | 0 | 0.13 | 14 | 46 | 2 | 0 |
| parallel_map | 1.23 | 68 | 10 | 47 | 17 | 1.25 | 49 | 12 | 48 | 5 |
| traverse_locality | 0.46 | 98 | 18 | 182 | 32 | 0.40 | 100 | 18 | 182 | 31 |
| frag_longrun | 15.82 | 1881 | 102 | 828 | 8 | 15.63 | 1883 | 102 | 749 | 8 |
| latency | 0.53 | 792 | 8 | 126 | 57 | 0.56 | 794 | 8 | 119 | 58 |
| fiber_latency | 0.39 | 293 | 7 | 93 | 25 | 0.40 | 296 | 8 | 91 | 23 |

Request latency reported by the benchmarks (microseconds, median of the 5 runs):

| workload | toolchain | p50 | p99 | p99.9 | max |
|---|---|---:|---:|---:|---:|
| latency (256 MiB live) | dmd | 0 | 3 | 225 | 62019 |
| latency (256 MiB live) | ldc | 0 | 3 | 226 | 61532 |
| fiber_latency (10k fibers, 64 MiB) | dmd | 1 | 4 | 18 | 28151 |
| fiber_latency (10k fibers, 64 MiB) | ldc | 1 | 4 | 15 | 26736 |

### `full` tier (3 repetitions)

| workload | dmd wall s | dmd RSS MiB | dmd GCs | dmd GC ms | dmd max pause ms | ldc wall s | ldc RSS MiB | ldc GCs | ldc GC ms | ldc max pause ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| tree1 (n=18) | 8.04 | 219 | 69 | 3114 | 93 | 8.74 | 126 | 136 | 3147 | 47 |
| tree2 (7M) | 0.59 | 4 | 216 | 8 | 0 | 0.44 | 6 | 216 | 10 | 0 |
| mt_alloc (4M x 8) | 8.11 | 3 | 2284 | 501 | 1 | 6.61 | 6 | 2301 | 505 | 2 |
| mt_share | 1.84 | 4 | 203 | 31 | 1 | 1.25 | 7 | 201 | 22 | 0 |
| append_heavy (100k) | 0.90 | 8 | 270 | 11 | 0 | 0.66 | 14 | 225 | 11 | 0 |
| parallel_map | 9.91 | 260 | 23 | 350 | 80 | 10.07 | 183 | 30 | 320 | 39 |
| traverse_locality | 2.80 | 344 | 24 | 879 | 136 | 2.09 | 346 | 24 | 809 | 124 |
| latency (2 GiB live) | 3.32 | 5283 | 11 | 1160 | 552 | 3.40 | 5285 | 11 | 1082 | 553 |
| fiber_latency (30k fibers, 512 MiB) | 1.54 | 1726 | 10 | 498 | 170 | 1.58 | 1727 | 10 | 460 | 167 |

| workload | toolchain | p50 | p99 | p99.9 | max |
|---|---|---:|---:|---:|---:|
| latency (2 GiB live) | dmd | 0 | 2 | 251 | 571590 |
| latency (2 GiB live) | ldc | 0 | 2 | 251 | 570451 |
| fiber_latency (30k fibers, 512 MiB) | dmd | 0 | 3 | 247 | 185334 |
| fiber_latency (30k fibers, 512 MiB) | ldc | 0 | 3 | 246 | 179176 |

## Findings

1. **The two toolchains share one collector, so they are one baseline for the GC.** The
   GC counts match (7637 for `rand_small`, 101 for `dlist` and `slist`, 62 for `tree2`, 18 and
   24 for `traverse_locality`), total GC time agrees within about 10 to 20% on the GC-bound
   workloads, and the latency-benchmark percentiles match to within a few percent. LDC is 10 to
   35% faster on the mutator-bound workloads (`tree2` 0.63x, `mt_share` 0.71x, `append_heavy`
   0.76x, `mt_alloc` 0.82 to 0.88x, `dlist` 0.81x), and equal where the collector dominates (`rand_*`,
   `frag_longrun`, `latency`). Geometric mean of LDC/dmd wall time is 0.87 in both tiers
   (`compare_runs.sh results/ci.csv dmd results/ci.csv ldc`). One unexplained exception:
   `words` spends 50 ms in the GC with dmd and 10 ms with LDC (max pause 36 vs 8 ms) for the
   same 5 collections. Compare a new GC against the same toolchain, never across.

2. **Collection is a large share of run time**, which is the headroom the new GC is
   aiming at. GC time over wall time (dmd): `rand_large` 33%, `traverse_locality` 40% (`ci`) and
   31% (`full`), `tree1` 30% (`ci`) and 39% (`full`), `latency` 24% and 35%, `fiber_latency`
   24% and 32%, `rand_small` 21%, `dlist`/`slist` 10%; about 5% or less for `mt_alloc`
   (5 to 6%), `frag_longrun`, `parallel_map`, `tree2`, `append_heavy`, `mt_share`.

3. **Pauses are stop-the-world and grow with the live set.** `latency`: max pause 57 ms at
   256 MiB live, 552 ms at 2 GiB, i.e. about 0.22 to 0.27 ms per live MiB, and the
   mutator sees exactly that: the largest request took 62 ms and 572 ms (5 to 8% above the
   max pause). That is the M3 baseline for this object mix (mostly pointer-free arrays), and a
   linear extrapolation gives about 1.1 s at 4 GiB and 2.2 s at 8 GiB. `fiber_latency` shows
   what the fiber-stack roots add: 25 ms with 10k fibers and 64 MiB, 170 ms with 30k fibers
   and 512 MiB. The live set alone would account for about 16 ms and 110 to 140 ms by the
   figure above, so the fibers cost roughly 10 ms and 30 to 60 ms.

4. **Tail latency below the pauses is not collections.** p50 is at most 1 us and p99 is 2 to
   4 us everywhere. p99.9 is 225 to 250 us in `latency` and in `full` `fiber_latency`, but 15
   to 18 us in `ci` `fiber_latency`. Collections number about 10 against 200k to 1M requests,
   so the slowest 0.1% of requests cannot be collections. Likely causes are allocator slow
   paths and first-touch page faults (THP is `always`, so a fault can zero a 2 MiB page);
   not verified. A GC that shortens pauses but leaves p99.9 near 250 us has not improved it.

5. **Memory use is generous for large live sets.** `latency` at 2 GiB live uses 5.2 GiB RSS
   (2.6x) and `frag_longrun` ends at 1.9 GiB. Line reuse may reduce this; set the M7 target
   against these figures. (An earlier version of this section reported 1.3 GiB for
   `mt_alloc` "whose live set is a few KiB". That was a benchmark bug: each node was linked
   to the previous node of its slot, so every node stayed reachable. Fixed; `mt_alloc` now
   peaks at 3 to 6 MiB.)

6. **Kernel time is large in some workloads.** `parallel_map` spends about as much
   system time as user time (8.8 s sys vs 7.9 s user over 1.2 s wall at `ci`),
   `rand_large` 1.1 s sys out of 1.7 s wall, and `mt_alloc` at 8 threads 31 s sys against
   33 s user over 8.1 s wall, with 2284 collections (each stops 8 threads by signals) and a
   single allocator lock. That suggests the large-object path (mmap/munmap and page faults)
   and thread stop/resume signalling. Not investigated; worth a `strace -c` before the new
   GC is blamed or credited for syscall changes. `mt_alloc` is the M1 workload, so this is
   the number the lock-free fast path has to improve.

7. **Collection counts on `tree1` are not stable across compilers or even trivial source
   changes** (dmd: 86 collections before a one-line edit that accumulates the checksum, 37
   after; LDC 87; `full` dmd 69, LDC 136). Conservative stack roots decide how much
   is retained when the heap grows, so compare wall time and GC ms there, not counts.

8. **Fibers hit an OS limit near 30k.** `fiber_latency` aborts at 50k fibers: each fiber
   stack takes two mappings (stack and guard page) and `vm.max_map_count` is 65530. The
   RFC's 100k-fiber scenario needs the sysctl raised.

## Caveats

- **Check that a benchmark's live set is what its comment says.** `mt_alloc` retained its
  whole history until fixed (see finding 5). `GC ms` and RSS against the live set it was
  meant to have are the quick test.

- **LDC's GC2Stack pass removes allocations that do not escape.** The original `latency`,
  `fiber_latency`, `mt_alloc` and `traverse_locality` allocated garbage that LDC moved to
  the stack, and `tree1` dropped dead trees. LDC then looked up to 2.5x faster (`latency`
  at 2 GiB: 1.46 s against 3.66 s) with a worst request of 655 us against 685 ms, for the wrong
  reason. All five now make the garbage escape (a thread-local
  `gcSink`, or an accumulated checksum). Any new benchmark must do the same, and the
  collection counts should be compared between toolchains as a check.
- The Phase 0.3 barrier-cost spike used the earlier versions of `tree1`, `mt_alloc` and
  `traverse_locality` through LDC. Those three ratios (the store counts changed) should be
  re-measured with `plans/spikes/barrier/run_spike.sh`; `tree2`, the M4 worst case, is
  unchanged.
- Wall times vary 3 to 10% between repetitions on this machine (governor `powersave`,
  desktop load); `words` with LDC ranged 0.45 to 0.86 s. Treat differences under 10% as
  noise and use at least 5 repetitions.
- `profile:1` is millisecond-resolution; max pauses of 0 are under 1 ms.
- Sizes are below the RFC's multi-GiB live sets (G0c wants 1 to 8 GiB). `latency 8192`
  needs about 21 GiB of RAM with these collectors.
- One machine, one run per tier; no confidence intervals beyond min and max wall.

## Also in this directory

| Path | What |
|---|---|
| `run_vibe.sh`, `vibe_server/` | a vibe.d HTTP server (256 MiB live store, 2000 idle keep-alive connections held as fibers) and a socket load generator; builds with dub from the local cache, once per compiler. Baseline, 40000 requests: dmd 13.9 s, 20 collections, 1.85 s in the GC, max pause 130 ms, p99.9 133 ms; LDC 11.7 s, 1.67 s, 117 ms, 118 ms. Server is configured by environment (`GCB_PORT`, `GCB_LIVE_MIB`) because vibe rejects unknown arguments, and prints its own GC stats at `/quit` because vibe's exit path skips druntime's `profile:1` summary. `vibe_server/dub.sdl` links OpenSSL 3 explicitly because `libssl.so` here is LibreSSL |
| `pause_hist.sh` | log2 pause histogram and percentiles from a `--DRT-gcopt=trace:FILE` CSV |
| `compare_runs.sh` | ratio table between two `run_compare.sh` result sets |
| `core_bench/` | Phobos-free workloads built with the repo's own dmd and run under every collector, including symgc; and the frame-loop test for real-time games. See its README |
| `results/` | the stored `run_compare.sh` outputs |

A compiler run over Phobos (`dmd -lowmem -c -O -inline -release` on the 162 Phobos source files, GC enabled) was
measured once: 22.4 s wall, 8 collections, GC 337 ms (1.5%), max pause 95 ms; the semantic-only variant (`-o-`) takes
2.6 s with the GC at 12%. Not scripted.
