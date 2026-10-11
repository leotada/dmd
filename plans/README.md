# GC redesign: Phase 0 discovery

Everything here supports `technical_rfc_hybrid_tls_immix_gc_for_d.md`. Phase 0 asked whether the proposed
collector (Immix allocator, SATB concurrent marking, optional thread-local domains) is worth building and what
to build instead if not. The answer is in the RFC sections "Phase 0 verdict" and "Direction".

## Outcome in six lines

- **Allocator:** non-moving Immix loses on memory (37% to 153% more on small-object workloads). symgc (the SDC
  collector ported to druntime, a downloaded copy in `../symgc/`, not committed here) already gives 11x the conservative
  collector's 8-thread allocation, 20 to 40% less memory and 5.7x shorter pauses. **Build on symgc.**
- **Concurrent marking (Track A):** the SATB barrier costs about 0 to 7% and fits its budget. **Build it.**
- **Thread-local domains (Track B):** the publication barrier costs up to 26 to 75% on store-dense code and programs
  that share data escape 20 to 93% of their bytes. **Shelved.**
- **Target:** real-time games. The goal is under 1 ms p99.9 and 0 frames over 16 ms. Under `oneday` (LDC card-marking barrier + coalescing + new AA), the 500k city benchmark achieved p50 = 3.59 ms, p99.9 = 6.58 ms, max = 7.60 ms, and **0 of 3,600 frames over 16 ms** (rock-solid 60 FPS floor).
- **Real game validation (`trigger-rally-d`):** Under headless Xvfb llvmpipe, oneday delivered +79.2% throughput over stock and 4.8x lower stall. Under **native GPU hardware acceleration (AMD Radeon RX 6600)**, oneday delivered rock-solid **74.4 FPS across 1,116 frames**, with **0.000 ms main thread GC pause time**, peak frame latency capped at 14.35 ms (0 missed frames > 16.6 ms), 4.4x lower mutator assist, and -9.8% smaller memory RSS (270.8 MiB vs Stock's 300.3 MiB).
- **Heavy allocation stress (`bullet_hell.d` & `bullet_hell_stress.d`):** Under 100k bullets/s + 256 B/shot on a 2 GiB heap, oneday Concurrent Mark achieved p99.9 = **0.805 ms** and max = **0.805 ms** (**60x lower peak stall than Stock GC's 48.1 ms**), with **0 of 900 frames over 1 ms** (holy-grail target achieved).
- **Compiler write barrier:** LDC pass `GCCardMarking.cpp` (patches 0001-0008) implements post-store card marking with pointer-free copy skipping (0006), same-object store coalescing (0007, -23.8% store latency), and optional summary byte elimination (0008, dropping 2-field stores to 0.98-1.05 ns/op and eliminating cross-core false sharing).
- **Collector tuning:** symgc patches 0032 and 0033 unify `SYMGC_MARK_THREADS` with default `nice = 10` on Linux, and add direct unrolled 32-card scanning in `collectCards`.
- **Status details:** see `plans/symgc-patches/README.md` and `plans/symgc-patches/BUILD_AND_USE.md`.

## Where things are

| Directory | What | Phase 0 item |
|---|---|---|
| `technical_rfc_hybrid_tls_immix_gc_for_d.md` | the RFC, with the findings, the verdict and the direction | all |
| `symgc-patches/` | `latency-p3` / `oneday` fork patches (0004-0031), `BUILD_AND_USE.md`, and results `README.md` | Phase 3 implementation |
| `ldc-patches/` | LDC card-marking write barrier pass patches (0001-0007), including coalescing (0007) | write barrier |
| `bench/` | dmd and LDC baselines (`run_compare.sh`), vibe.d server, pause histogram | 0.1, 0.2 |
| `bench/core_bench/` | Phobos-free workloads, `barrier_micro.d`, and `trigger_rally_bench.sh` (real game 3-way test) | 0.6, validation |
| `spikes/barrier/` | barrier-cost spike by LLVM IR rewriting | 0.3 |
| `spikes/census/` | escape census by IR instrumentation and a wrapping GC | 0.4 |
| `spikes/immix/` | out-of-tree Immix and segregated-fit allocators under one collector | 0.6 |
| `model/` | explicit-state model checker of the protocol | 0.5 |
| `audit/` | druntime/symgc paths that delete pointer edges without a store (needed before P3) | P3 prep |
| `../druntime/benchmark/gcbench/` | the benchmark programs themselves | 0.1 |
| `../druntime/src/core/gc/config.d`, `.../conservative/gc.d` | `--DRT-gcopt=trace:FILE` per-collection CSV | 0.2 |

Each directory has its own README with the method, how to run it, the results and the limits.
See `plans/symgc-patches/README.md` for complete benchmark results of `oneday` (500k city, RTS, microbenchmarks, and `trigger-rally-d`).

## Environment this was done in

Linux 6.12, Ryzen 7 3800X (16 threads, `powersave` governor), 32 GiB. System dmd 2.109.1 and LDC 1.40.1
(LLVM 19.1.7); the repository's own dmd 2.113 (built with `rdmd compiler/src/build.d`) and druntime
(`make -C druntime DMD=<that dmd> BUILD=release target`). No Java, `perf`, `valgrind` or LLVM development
package; hardware counters come from `perf_event_open` called directly. symgc needs this repository's
druntime (it uses `ThreadBase.tlsGCData`); the system compilers' druntimes are too old.

## Method cautions learned the hard way

- LDC's GC2Stack pass deletes allocations that do not escape. Benchmarks must make their garbage escape, and
  collection counts should match between toolchains as a check.
- Check that a benchmark's live set is what its comment says (`mt_alloc` once retained everything).
- Linking symgc into a binary makes the conservative collector about 40x slower (it scans symgc's static data).
  Compare collectors in separate binaries.
- D strings from `argv` are not NUL-terminated; do not pass `.ptr` to `atol`.
- Wall-clock noise on this machine is 3 to 10%; the `powersave` governor is on.
