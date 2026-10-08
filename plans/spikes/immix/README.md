# Allocator comparison: Immix against segregated fit (Phase 0.6, gate G0c)

`proto.d` implements two small-object allocators under one stop-the-world mark-sweep collector, so only the
allocator differs. Shared: 16 GiB address reservation, free-block pool and decommit policy, large-object space
(above 2032 bytes), conservative scanning of thread stacks and registers, the collection trigger
(`max(8 MiB, live)` bytes allocated), safepoint rendezvous at allocation slow paths.

- `ImmixGc`: 32 KiB blocks of 128-byte lines, per-thread bump allocation into free-line runs, an overflow block for
  medium objects, blocks recycled by free line. Metadata: a size byte per 16-byte granule, a mark bit per granule,
  line mark and line live bytes. Non-moving. `IMMIX_MEDIUM=overflow` (or `immix-ovf`) sends every object above one
  line to overflow blocks, never into holes; the default tries the hole first, as the Immix paper does.
- `SegfitGc`: 32 KiB slabs, 24 size classes up to 2032 bytes, per-thread slab cache, allocation/mark/no-scan
  bitmaps. Written independently on the structure of the SDC collector. (symgc itself was measured later; see
  `../../bench/core_bench/`.)

`bench.d` has the workloads, shaped like the gcbench programs (`alloc`, `frag`, `fragsmall`, `fragtiny`, `trav`,
`tree`); `perfcount.d` reads user-space cache misses through `perf_event_open`; `regs.c` saves callee-saved
registers for the conservative stack scan.

```
./run.sh [reps] [outdir]       # clang + dmd, 3 allocators x 9 cases, medians; then ./table.sh results.csv
```

## Results (medians of 3; `results/results.csv`, `results/raw.txt`)

| case | Immix | Immix, medium to overflow | segregated fit |
|---|---|---|---|
| alloc 1 thread (Mops/s) | 37.2 | 37.1 | 28.0 |
| alloc 8 threads | 70.2 | 71.2 | 56.1 |
| frag steady RSS, with large objects (MiB) | 952 | 981 | 868 |
| fragsmall steady RSS, 16 B to 2 KiB (MiB) | 1147 | 1245 | **452** |
| fragtiny steady RSS, up to 128 B (MiB) | 338 | 338 | **246** |
| trav, traversal (ms) | **142.7** | 25.8 | 26.1 |
| trav, cache misses per traversal | 3.74M | 0.161M | 0.167M |
| metadata (MiB at the fragsmall heap) | 92 | 101 | 10 |

Why Immix loses on memory: after the last collection every block still holds at least one live line, so 843 MiB
of blocks hold 220 MiB of live lines (26% occupancy; segregated fit: 49%). Without evacuation (the RFC fixes
non-moving) the free lines stay fragmented into runs too short for medium objects. Its locality depends on where
medium objects go: with the paper's policy, hole-first, traversal of the interleaved tree is 5.5x slower.

Engineering size: the Immix allocator is about 250 lines, segregated fit about 210.

## Limits

The comparison is between two prototypes I wrote. It supports "non-moving Immix fragments" but not absolute
numbers. The collector is simple (no lazy sweep, no parallel marking). symgc was measured separately.
