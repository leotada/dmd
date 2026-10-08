# Escape census (Phase 0.4, gate G0b)

Measures how much of a program's allocation would have to leave a thread-local domain (RFC section 3.5, I1):
the rate that decides whether Track B can pay for itself (M7: at most 20% of bytes promoted).

## Method

1. `ldc2 -O3 -release -c -output-ll -singleobj -i=std.concurrency -i=std.variant -i=std.parallelism x.d`
   compiles the program with those Phobos modules included, so their stores are seen too.
2. `rewrite_census.d` adds, before every pointer store (not to an alloca) a call
   `_d_census_store(slot, value, site)`, after every `memcpy`/`memmove` a call `_d_census_copy`, and before every call
   to a druntime allocation entry point a thread-local note of "kind:function". Nothing changes behaviour.
3. `census_rt.d` is linked in. `CensusGC` wraps the conservative GC (selected with `rt_options`) and records every
   allocation: address, size, allocating thread, site, no-scan flag. For each store it classifies the slot (own or
   other thread's stack or TLS, a thread-local heap object, or global: static data, memory not from the GC, an
   escaped object). A store of thread T's object into a global slot or another thread's domain promotes the
   object and everything still local that it reaches. Objects are counted when they die (after each collection)
   or at exit. A pointer into a thread's own stack stored elsewhere is a stack-address escape; the thread's stack
   becomes visible when that reaches the global domain, another thread, or an object later promoted.
4. At exit, a coverage audit reports references the stores did not explain (live thread-local objects pointing at
   another thread's object; static data pointing at objects not marked escaped).

```
./run_census.sh [-o outdir] [-I "-i=..."] workload.d [args]     # one program, report on stderr
./census_all.sh [outdir]                                         # the 18 gcbench workloads, reduced sizes
```
The census is 10 to 1000 times slower than a normal run; inputs are reduced. `-i=std` (all of Phobos) takes
about 4 minutes of compile time; the three modules above take 14 seconds and gave the same answer.

## Results (`results/census.txt`, full reports in `results/*.log`)

| workload | threads | objects escaped | bytes escaped | promotions | notes |
|---|---:|---:|---:|---:|---|
| `mt_alloc`, `tree1`, `tree2`, `append_heavy`, `traverse_locality`, `latency`, `frag_longrun`, `rand_small`, `rand_large` | 1 to 5 | 0.00% | under 0.1% | 0 | nothing shared |
| `dlist`, `slist` | 1 | 0.001% | 8.9% | 1 | the one large text buffer |
| `words` | 1 | 13% (2 of 15 objects) | 41% | 0 | too few objects to mean anything |
| `conalloc`, `conappend`, `concpu` | 5 | under 0.05% | under 0.1% | 1 | |
| `mt_share` (message passing) | 3 | **20.3%** | **19.7%** | 20k | messages and their strings escape ~100%; the line-by-line temporary buffer 0% |
| `conmsg` (JSON messages) | 2 | **52.9%** | **67.7%** | 465k | mean graph 8 objects; allocator-internal `aa` nodes 100% |
| `parallel_map` | 16 | **93.2%** | **86.9%** | 61k | workers store results into the caller's array: `std.parallelism` pattern |

Other measurements: stack-address escapes are rare (12 in `parallel_map`, none elsewhere), and when they happen
the escaping thread's stack stays visible for the whole run (`parallel_map`: main thread's stack from 2 ms to
exit, via `std.parallelism`). Promotion graphs are small (`mt_share` mean 1.5 objects, max 22 in `parallel_map`;
`conmsg` 8 to 9). Which path allocated escaped `immutable` data shows in the per-site tables: in `mt_share` the
immutable string built to send escapes 100%, the `char[]` buffer it came from 0%.

## Verdict inputs

Programs without sharing: 0%. Programs that pass data through `std.parallelism` or message queues: 20 to 87% of
bytes. M7 (at most 20%) fails for any program whose bulk data crosses threads.

## Limits

Only code compiled into the module is observed. Precompiled druntime code (for example associative-array
internals) allocates without a tagged site, and stores inside it are unseen, so escape rates are lower bounds.
The coverage audit found 1 to 3 unexplained static-data references per run (runtime internals such as the main
`Thread` object). Fibers are not recognized (their stacks look like global memory), so the vibe.d server was not
run. Allocation locations inside druntime templates are attributed to the template, not to the user function that
called it. The census GC shares the conservative collector's behaviour; it does not model Track B's local
collections, so "died local" means "collected", not "reclaimed without a global cycle".
