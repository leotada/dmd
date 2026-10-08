# Barrier-cost spike (Phase 0.3, gate G0a)

LDC is not buildable here (no LLVM development files), so the RFC section 4.4 barrier is inserted by rewriting
the optimized LLVM IR that `ldc2 -output-ll` emits, then compiled with `clang -O2` (same LLVM 19) and linked
with `ldc2`.

| File | Role |
|---|---|
| `rewrite_ir.d` | IR rewriter. Modes: `satb`, `satb+vis`, `publish[+vis]`, `split[+vis]`, `arena[+vis]`; options `--elide-fresh`, `--invariant` |
| `gcspike_rt.d` | thread-local state read by the barrier, a lazily backed block table, counting slow paths |
| `run_spike.sh [reps]` | builds each workload in each mode, times it, writes `results.csv` |
| `run_variants.sh [reps]` | compares the publication fast paths under both ownership settings |
| `workloads/ptr_heavy.d` | pointer stores with no allocation (worst case) |

`SPIKE_OUT=<dir>` selects the build directory. The nine workloads are `ptr_heavy` and the `gcbench` programs
`tree1 tree2 dlist slist mt_alloc append_heavy parallel_map traverse_locality`.

## Results (re-run after the benchmark fixes; ratio to the unmodified code through the same pipeline)

Geometric mean over the nine workloads, 5 repetitions:

| Variant | no elision | fresh-store elision |
|---|---|---|
| SATB | 0.990 | 1.002 |
| SATB + stack-visibility compare | 1.003 | 0.997 |
| SATB + publication | 1.092 | 1.080 |
| SATB + publication + visibility | 1.121 | 1.065 |

Worst workload: SATB 1.07 to 1.10 (`tree1`, `slist`); publication + visibility 1.46 to 1.63 (`tree2`).

Publication fast paths (7 repetitions, elision and visibility on, both ownership settings):

| Check | Geometric mean | Worst (`tree2`) | `.text` growth |
|---|---|---|---|
| block table, value then slot | 1.047 to 1.054 | 1.51 to 1.59 | x1.45 |
| block table, slot first | 1.047 to 1.062 | 1.61 to 1.75 | x1.44 |
| per-thread contiguous arena | **1.018 to 1.022** | 1.26 to 1.34 | x1.31 |

The `mt_alloc` row of `results.csv` used the old, retaining version of that benchmark (since fixed); its store
count is unchanged but its GC behaviour differs.

## Reading

SATB alone meets M4 (3% geometric mean) and M9 (`.text` x1.10). Publication does not meet M4's 15% worst case
or M9 in any form. `tree2` (a red-black tree with 100 live nodes: 11.6 barriered stores per operation) shows the
cost is the check itself, not reloading thread state. See the RFC verdict for G0a.

## Limits

Post-optimization IR is pessimistic (LLVM cannot hoist or merge checks). Bulk copies (`memcpy`) are not
barriered. Only code compiled into the module is rewritten. Atomic and volatile stores are left alone.
Not done: marking-on cost with a realistic slow path, static against shared druntime TLS, Phobos unit tests under
the barrier, a real LDC change.
