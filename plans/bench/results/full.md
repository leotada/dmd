Size `full`, 3 repetitions, medians. Wall in seconds, RSS in MiB, GC and pause in ms.

| workload | dmd wall | dmd RSS | dmd GCs | dmd GC ms | dmd max pause | ldc wall | ldc RSS | ldc GCs | ldc GC ms | ldc max pause |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| tree1 | 8.04 | 219 | 69 | 3114 | 93 | 8.74 | 126 | 136 | 3147 | 47 |
| tree2 | 0.59 | 4 | 216 | 8 | 0 | 0.44 | 6 | 216 | 10 | 0 |
| mt_alloc | 8.11 | 3 | 2284 | 501 | 1 | 6.61 | 6 | 2301 | 505 | 2 |
| mt_share | 1.84 | 4 | 203 | 31 | 1 | 1.25 | 7 | 201 | 22 | 0 |
| append_heavy | 0.90 | 8 | 270 | 11 | 0 | 0.66 | 14 | 225 | 11 | 0 |
| parallel_map | 9.91 | 260 | 23 | 350 | 80 | 10.07 | 183 | 30 | 320 | 39 |
| traverse_locality | 2.80 | 344 | 24 | 879 | 136 | 2.09 | 346 | 24 | 809 | 124 |
| latency | 3.32 | 5283 | 11 | 1160 | 552 | 3.40 | 5285 | 11 | 1082 | 553 |
| fiber_latency | 1.54 | 1726 | 10 | 498 | 170 | 1.58 | 1727 | 10 | 460 | 167 |

Request latency as reported by the benchmarks (microseconds):

| workload | toolchain | p50 | p99 | p99.9 | max |
|---|---|---:|---:|---:|---:|
| latency | dmd | 0 | 2 | 251 | 571590 |
| latency | ldc | 0 | 2 | 251 | 570451 |
| fiber_latency | dmd | 0 | 3 | 247 | 185334 |
| fiber_latency | ldc | 0 | 3 | 246 | 179176 |
