# Using the low-latency symgc in a D program

State on 2026-10-09. Linux x86-64. Everything below was run on this machine (openSUSE Leap 16, kernel
6.12, LDC built from the `ldc/` checkout with LLVM 19).

## What it is

symgc is the SDC garbage collector ported to ordinary D
([symmetryinvestments/symgc](https://github.com/symmetryinvestments/symgc)). This fork (branch
`latency-p3` of `symgc/`, patches in `plans/symgc-patches/`) changes how a collection runs so that the
program almost never stops:

* **concurrent mark**: the program keeps running while the collector marks; a short pause at the end
  (the *remark*, typically 0.2-0.4 ms) rescans only what the program wrote meanwhile;
* **concurrent, paced sweep** on a background thread, with finalizers run in order across arenas before
  any memory is reused;
* **no global allocation lock**: each thread allocates from its own cache, which matters as much as the
  pauses when job threads allocate.

The goal is that game code can be written without pools, without avoiding allocation in the frame loop,
and without calling `GC.collect` by hand. Measured results are in `README.md` (this directory).

## Pick a setup

The concurrent mark needs to know which memory the program wrote while it was marking. There are two ways:

| | **A. Kernel dirty pages** | **B. Compiler card marking** (recommended) |
|---|---|---|
| compiler | a compiler with druntime 2.112+ (this repository's dmd; the LDC from `ldc/`) | the LDC built from `ldc/` (branch `gc-card-marking`) |
| needs | Linux 6.7 or newer (`userfaultfd` write-protect + `PAGEMAP_SCAN`) | nothing from the kernel |
| cost | ~1.5 us fault on the first write to each page per cycle | one byte store after each pointer store |
| blind spot | none | pointer writes made by code compiled **without** the flag (C libraries) |
| if unavailable | falls back to a stop-the-world mark | — |

With B, everything that stores D pointers into the GC heap must be compiled with `-gc-card-marking`: your
code, your D dependencies, druntime and Phobos (the runtime in `ldc-build-rt2` already is). C libraries
holding D pointers are fine (they keep objects alive); C code *writing* D pointers into the GC heap during
a collection is not seen. SDL, OpenGL and OpenAL in `trigger-rally-d` ran without problems.

## Setup B: LDC with card marking

### 1. Build the compiler and runtime (once)

```sh
# in the dmd repository root; LLVM 19 dev package installed; Phobos checked out beside it
cmake -G Ninja -S ldc -B ldc-build-rt2 -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_CONFIG=$(which llvm-config) -DD_COMPILER=$(which ldmd2) \
  -DPHOBOS2_DIR=<phobos checkout> -DBUILD_SHARED_LIBS=OFF -DLDC_DYNAMIC_COMPILE=OFF \
  -DD_EXTRA_FLAGS="-gc-card-marking"
ninja -C ldc-build-rt2
```

The LDC changes are in `plans/ldc-patches/` (0001 the barrier pass, 0002 a druntime fix, 0003 the summary
byte). Use a fresh build directory for a rebuild rather than deleting one.

### 2. A compiler wrapper

Save as `ldc2` in a directory of its own (here `~/bin/symgc-ldc/ldc2`), `chmod +x`:

```sh
#!/bin/sh
# ldc2 with the card-marking runtime and the symgc card backend
D=/home/leonardo/Projetos/dmd
exec $D/ldc-build-rt2/bin/ldc2 -conf=$D/ldc-build-rt2/etc/ldc2.conf \
  -I/home/leonardo/Projetos/phobos -gc-card-marking -d-version=Symgc_cards "$@"
```

(`-I<phobos>` is needed because the `ldc/` checkout's Phobos submodule is empty.)

### 3a. Build with dub

`dub.sdl`:

```sdl
name "mygame"
targetType "executable"
dependency "symgc" path="/home/leonardo/Projetos/dmd/symgc"
```

`source/app.d`:

```d
import symgc.gcobj;                                       // links the collector in
extern(C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];   // select it (sdc = same, with a banner)

void main() { /* ... */ }
```

```sh
PATH=~/bin/symgc-ldc:$PATH dub build -b release --compiler=ldc2
./mygame
```

Use `-b release` (or another optimized build type): symgc is built with the same options as your
project, and an unoptimized collector is slow.

### 3b. Build without dub

```sh
~/bin/symgc-ldc/ldc2 -O3 -release -d-version=Symgc_druntime_hooks \
  -I/home/leonardo/Projetos/dmd/symgc/source \
  mygame.d $(find /home/leonardo/Projetos/dmd/symgc/source -name '*.d')
```

## Setup A: any compiler, kernel dirty pages

The same as above without `-gc-card-marking` and without `-d-version=Symgc_cards`. The compiler's druntime
must be 2.112 or newer (symgc needs `ThreadBase.tlsGCData`): the system LDC 1.40 (frontend 2.110) fails
with `no property tlsGCData`; this repository's dmd (2.113) works:

```sh
D=/home/leonardo/Projetos/dmd
$D/generated/linux/release/64/dmd -O -release -inline -version=Symgc_druntime_hooks \
  -I$D/symgc/source mygame.d $(find $D/symgc/source -name '*.d')
```

or with dub, `dependency "symgc" path="<symgc>"` and `--compiler=<that dmd>`.

## Selecting the collector

symgc is only used when druntime is told to. Either in the program (as above):

```d
extern(C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];
```

or on the command line, which overrides it: `./mygame --DRT-gcopt=gc:sdcq`. `gc:sdc` does the same and
prints `using SYM GC!` at start, which is a quick way to check it is active. Without either, the program
runs with druntime's default conservative GC.

## Runtime options (environment variables)

| variable | default | meaning |
|---|---|---|
| `SYMGC_CONCURRENT_MARK=0` | on | stop-the-world mark instead (the safe fallback) |
| `SYMGC_DIRTY=0` | on | setup A: do not use the kernel tracker (stop-the-world mark) |
| `SYMGC_MARK_THREADS=n` | a quarter of the cores, 2 to 6 | threads used for marking |
| `SYMGC_SWEEP_DUTY=n` | 50 | percent of the time the background sweeper may run |
| `SYMGC_SWEEP_NICE=n` | unset | nice value of the sweeper thread |

## Writing code for it

* Allocate normally: `new`, closures, `~=`, associative arrays, `format`, `.array`. No pools, no
  `GC.collect()` in the frame loop, no `GC.disable()` around levels.
* `GC.collect()` still works (a full collection) if you want one at a loading screen; it is not needed.
* Large pointer-free buffers (pixels, audio, meshes) cost little to the collector: they are never scanned.
* The costs that remain are the language's, not the collector's:
  * shrinking an array with a slice (`a = a[0 .. $ - 1]`) and appending again reallocates on every
    append; keep an index or use `assumeSafeAppend` (an A* written that way allocated 8 GiB/s);
  * the built-in associative array allocates one node per entry; in hot loops prefer arrays indexed by id.
* `GC.stats()` under symgc reports the last collection, not live counters, and `GC.profileStats()` is
  empty.

## Checking a build

* `--DRT-gcopt=gc:sdc` prints `using SYM GC!`.
* Setup B: `nm mygame | grep __sd_gc_card_base` must find the card table.
* The test battery: `plans/bench/core_bench/gate.sh check`, `mark_race.d` (passes with the barrier,
  crashes without it), `finalizer_order.d`, `phobos_stress.d`.

## Known limits

* Linux x86-64 only for the concurrent mark (setup A needs kernel 6.7+; setup B needs this LDC).
  Windows, macOS and dmd's code generator have no barrier yet.
* The card table reserves 256 GiB (+2 GiB) of address space with `MAP_NORESERVE`: it needs
  `vm.overcommit_memory` 0 or 1.
* Measured tails (`README.md`): no frame over 16 ms in any game workload; the collector adds about
  0.25-0.4 ms at p99.9 in the city and RTS workloads and nothing visible in the open world. One
  unexplained 81 ms frame was seen once at 8 GiB in an earlier multi-threaded benchmark, and the
  stress bullet hell had one 7.1 ms frame at 8 GiB; the first did not repeat in 28 reruns, the second
  has not been rerun yet.
* No large real game has been run yet; the workloads are models (`plans/bench/core_bench/aaa_sim.d`).
