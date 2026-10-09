# Building and using the low-latency symgc (LDC, card barrier, concurrent mark)

State on 2026-10-09. Everything here is local: no download beyond what was approved
(the Phobos checkout and the LLVM 19 dev package).

## What you get

* symgc (the SDC garbage collector ported to D) as the `gc:sdcq` collector, with
  a concurrent paced sweep, finalizers ordered across arenas, and a mostly-concurrent
  mark.
* Two ways for the concurrent mark to know what the program wrote while it ran:
  * **kernel dirty pages** (default; no compiler change; Linux 6.7+;
    `userfaultfd` write-protect async + `PAGEMAP_SCAN`); first write to a tracked page
    costs a fault (~1.5 us), so a program that rewrites a big working set pays it once per cycle;
  * **card marking** (`ldc2 -gc-card-marking` + `-version=Symgc_cards`): the compiler marks a
    512 byte card after each pointer store; no faults; writes from code that was not compiled
    with the flag (C libraries, `read()` into a buffer) are not seen.

## Build the compiler and the runtime

```
# LDC from the checkout in ldc/ (branch gc-card-marking), LLVM 19 dev package installed
cmake -G Ninja -S ldc -B ldc-build-rt2 -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_CONFIG=$(which llvm-config) -DD_COMPILER=$(which ldmd2) \
  -DPHOBOS2_DIR=<phobos checkout> -DBUILD_SHARED_LIBS=OFF -DLDC_DYNAMIC_COMPILE=OFF \
  -DD_EXTRA_FLAGS="-gc-card-marking"
ninja -C ldc-build-rt2
```

druntime and Phobos must be built with `-gc-card-marking` too (the flag above does it).
Use a fresh build directory rather than deleting one.

## Build a program

```
ldc2-from-that-build -conf=ldc-build-rt2/etc/ldc2.conf -O3 -release \
  -d-version=SymGC -d-version=Symgc_druntime_hooks -d-version=Symgc_cards \
  -gc-card-marking -Isymgc/source -I<phobos> \
  yourgame.d $(find symgc/source -name '*.d')
./yourgame --DRT-gcopt=gc:sdcq
```

(For the kernel-dirty-pages variant, drop `-d-version=Symgc_cards`; the compiler
flag can stay, it only costs the stores.)

## Environment

| variable | meaning |
|---|---|
| `SYMGC_CONCURRENT_MARK=0` | stop-the-world mark (the safe fallback) |
| `SYMGC_DIRTY=0` | no kernel tracking |
| `SYMGC_MARK_THREADS=n` | mark threads (default a quarter of the cores, 2 to 6) |
| `SYMGC_SWEEP_DUTY=n` | percent of time the sweeper may use (default 50) |

## Known limits

* No real game has been tested; the workloads are `plans/bench/core_bench/` (`gcb.d`,
  `bullet_hell.d`, `game_mt.d`).
* Worst frames in those workloads: 0.75-1.1 ms for the frame loop up to 8 GiB live;
  1.0-1.5 ms in the bullet hell; the multi-threaded game has p99 0.4-0.75 ms and roughly 0.1% of
  frames over 1 ms, rare ones up to 2-3 ms (cause not found). A hard bound under 1 ms is not shown.
* The card barrier does not see writes from uninstrumented code.
* The 256 GiB (+2 GiB) of address space for the card table is `MAP_NORESERVE`; it needs
  `vm.overcommit_memory` 0 or 1.
* Tests: `plans/bench/core_bench/gate.sh check`, the battery (`mark_race`, `alloc 8` with the
  verifier, Phobos stress, `finalizer_order`), unit tests with and without
  `-version=Symgc_verify`, and the same battery with LDC + cards.
