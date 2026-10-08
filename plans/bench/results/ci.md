Size `ci`, 5 repetitions, medians. Wall in seconds, RSS in MiB, GC and pause in ms.

| workload | dmd wall | dmd RSS | dmd GCs | dmd GC ms | dmd max pause | ldc wall | ldc RSS | ldc GCs | ldc GC ms | ldc max pause |
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

Request latency as reported by the benchmarks (microseconds):

| workload | toolchain | p50 | p99 | p99.9 | max |
|---|---|---:|---:|---:|---:|
| latency | dmd | 0 | 3 | 225 | 62019 |
| latency | ldc | 0 | 3 | 226 | 61532 |
| fiber_latency | dmd | 1 | 4 | 18 | 28151 |
| fiber_latency | ldc | 1 | 4 | 15 | 26736 |
