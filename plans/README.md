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
- **Target:** real-time games. At 2 GiB live the worst frame is 570 ms (conservative), 40 ms (fork marking) and
  112 ms (symgc). The goal is under 1 ms. symgc also has allocation-path jitter that delays most frames by over 1 ms.
- **Model:** the protocol model found two design flaws: stack visibility, and a marking-flag race between the
  barrier test and the store (needs a restartable sequence or exchange-then-test).
- **Not done:** fibers and Phobos-heavy code under symgc, a real LDC build, 4 to 8 GiB live sets, symgc under the test suites.

## Where things are

| Directory | What | Phase 0 item |
|---|---|---|
| `technical_rfc_hybrid_tls_immix_gc_for_d.md` | the RFC, with the findings, the verdict and the direction | all |
| `bench/` | dmd and LDC baselines (`run_compare.sh`), vibe.d server, pause histogram | 0.1, 0.2 |
| `bench/core_bench/` | Phobos-free workloads run under conservative, parallel, fork and symgc, plus the frame-loop test | 0.6, direction |
| `spikes/barrier/` | barrier-cost spike by LLVM IR rewriting | 0.3 |
| `spikes/census/` | escape census by IR instrumentation and a wrapping GC | 0.4 |
| `spikes/immix/` | out-of-tree Immix and segregated-fit allocators under one collector | 0.6 |
| `model/` | explicit-state model checker of the protocol | 0.5 |
| `audit/` | druntime/symgc paths that delete pointer edges without a store (needed before P3) | P3 prep |
| `../druntime/benchmark/gcbench/` | the benchmark programs themselves | 0.1 |
| `../druntime/src/core/gc/config.d`, `.../conservative/gc.d` | `--DRT-gcopt=trace:FILE` per-collection CSV | 0.2 |

Each directory has its own README with the method, how to run it, the results and the limits.

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
