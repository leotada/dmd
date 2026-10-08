# symgc fork: patches

The fork lives in `symgc/` (a clone of github.com/symmetryinvestments/symgc, branch `latency-p3`, not tracked by this
repository). These are the commits on top of upstream `4a4cb2b`, as `git format-patch` files, so the work is
reproducible from here: `git -C symgc am ../plans/symgc-patches/*.patch`.

| Patch | What | Evidence |
|---|---|---|
| 0001 | Optional phase tracing (`-version=Symgc_phase_trace`) | `plans/bench/core_bench/README.md`, "Where symgc's collection time goes" |
| 0002 | SATB foundation: `d.gc.satb`; release barrier in `free`, `destroy`, moving and shrinking `realloc`, `removeRoots`; buffer flush at thread exit | model findings 6 and `--rootrm`, `--threadlife`; `plans/audit/druntime_edge_deletions.md` |
| 0003 | Cycle split into `cycleStart`, mark, `cycleRemark`, all still stop-the-world; the SATB flag is on during the mark and the remark asserts the queue is empty | 111 unit tests pass; `alloc`, `frag` and `frames` run with assertions on and no log entry appears |

Build and test with the repo's dmd and druntime (symgc needs `ThreadBase.tlsGCData`; there is no Phobos):

```
D=generated/linux/release/64/dmd
$D -unittest -main -g -version=Symgc_testing -version=Symgc_druntime_hooks -Isymgc/source -Idruntime/import \
   -defaultlib= -L-L$PWD/generated/linux/release/64 -L-ldruntime -of=symgc_ut $(find symgc/source -name "*.d") && ./symgc_ut
```

Baseline before the patches: all unit tests pass (exit 0). After: 11 `d.gc.tcache`, 2 `d.gc.global`, 3 `d.gc.satb` tests
pass. Mutation check: disabling each hook makes its test fail (release hook, shrink-tail hook, `removeRoots` hook).
Cost: `alloc` 8 threads 40.7 to 41.5 Mops/s before, 38.3 to 43.6 after (noise); `frag` 0.357 before, 0.363 after.

The marking flag is never set by the stop-the-world collector, so behaviour is unchanged until the concurrent mark
phase sets it with `satbBegin` and drains with `satbDrain`.
