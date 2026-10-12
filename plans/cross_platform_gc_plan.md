# A low-latency GC for every D compiler and every platform: plan to a DIP

State on 2026-10-12. Companion to `technical_rfc_hybrid_tls_immix_gc_for_d.md` (section 15) and to the collector's
documentation in `symgc/guide/`.

## Goal

One D garbage collector that loses no frame to collection on Windows, Linux, macOS and Android, with iOS later. It
should behave the same whichever of DMD, LDC or GDC builds the program, so developers can switch compilers as they
need. It should reach the official toolchain through ordinary druntime pull requests and one DIP.

## The decision: the write barrier moves into the shared frontend

A concurrent mark has to learn which memory the program wrote while the mark ran. Today oneday learns it in one of
two ways: an LLVM pass in a patched LDC (cards), or the Linux 6.7+ kernel tracker on x86-64. Neither works for DMD
or GDC on Windows, macOS or phones.

DMD, LDC and GDC compile D with the same frontend, dmd's, which is written in D. A frontend lowering marks each
pointer store once, with full type information, for all three compilers. Each backend then only expands one small
intrinsic. The OS trackers stay as a fallback for code built without the barrier.

```
                         your D program
                               |
        shared D frontend: with -gc-barrier, pointer stores into the heap
                  become one intrinsic (type-aware)
              /                |                    \
     DMD backend         LDC (LLVM)             GDC (GCC)
     x86-64              x86-64, arm64,         many CPUs;
     Linux, Windows,     Android, iOS           Linux, MinGW
     macOS Intel
              \                |                    /
         druntime: GC registry, core.memory.GC calls, card table ABI
               /                                    \
  conservative GC (default)          oneday: concurrent mark, paced sweep;
                                      tracking = cards, else OS tracker,
                                      else stop-the-world mark
```

Three rules follow:

1. The collector stays a druntime GC behind `core.gc.registry`, selected with `--DRT-gcopt=gc:<name>`. Plugging it
   in needs no compiler change.
2. The barrier starts as an opt-in compiler switch (proposed `-gc-barrier`), the default only after the DIP.
3. At start-up the collector picks the best tracking available: cards if the binary has the barrier, else an OS
   tracker (Linux 6.7+ now, Windows `GetWriteWatch` later), else a stop-the-world mark with the concurrent sweep.
   Every combination runs; only the pause length differs.

## Where things stand (checked on 2026-10-12)

| Compiler (frontend) | Upstream symgc | oneday | Concurrent mark | Card barrier |
|---|---|---|---|---|
| DMD 2.109, system | Does not build: no `tlsGCData` | Same | — | No |
| LDC 1.40 (2.110), system | Does not build: no `tlsGCData` | Same | — | No |
| GDC 15.3 (2.111), system | Builds; one thread works; dies once a second druntime thread exists | Same, after the 2026-10-12 fix | Same crash | No |
| Unpatched druntime of dmd `master` (2.113-dev) | Not tried | Works | Kernel tracker, Linux 6.7+ (`mark_race` passes; 11,126 lost objects with tracking disabled on purpose) | No |
| Stock DMD or LDC releases, 2.112+ | Supported upstream (not tested here) | Builds | Kernel tracker expected | No |
| DMD 2.113 of this repo, patched druntime | Works | Works | Kernel tracker, Linux 6.7+ | No |
| LDC 1.43-git of `ldc/` | Does not run on this runtime | Works | Cards, or kernel tracker | Yes |

GDC 15's druntime has `tlsGCData` but not the GC's thread-init hook (druntime 2.112, April 2025), so the collector
never learns about druntime's threads.

What each compiler can target:

| | Linux x86-64 | Linux arm64 | Windows x64 | macOS Intel | macOS Apple Silicon | Android arm64 | iOS |
|---|---|---|---|---|---|---|---|
| DMD | Yes | No | Yes | Yes | Rosetta only | No | No |
| LDC | Yes | Yes | Yes | Yes | Yes | Yes | Yes, less tested |
| GDC | Yes | Yes | MinGW | Not checked | Not checked | No | No |

So the promise is: any compiler that targets a platform gets the same collector and the same barrier there. Phones
mean LDC.

## Phases

Sizes are estimates in person-weeks (pw).

| Phase | Work | Exit test | Starts after | Size |
|---|---|---|---|---|
| 0. Community preview | Fork builds on stock druntime (done). Concurrent mark on stock druntime, with the GC thread posing as a placeholder while it scans (done; checked on an unpatched `master` druntime). Support druntime 2.111 (GDC 15) by attaching threads on first use; the fork's legacy pthread-hook mode aborts at start-up under GDC 15. Publish the fork as a dub package. Docs (`symgc/guide/`), benchmark kit, report template. CI on Linux x86-64 with DMD, LDC, GDC | A project adds one dub dependency and runs under stock DMD 2.112+, LDC and GDC on Linux; 0 frames over 16 ms in the 500k city with DMD | Now | 2–4 pw |
| 1. The collector on every OS | Build and run on Windows x64, macOS Intel and Apple Silicon, Linux arm64, Android arm64, stop-the-world mark first. Card table set up through `pragma(crt_constructor)` (all three compilers, works in a `.so`) and sized to the GC's reservation. arm64 syscall numbers. CI on Windows, macOS arm64, Linux arm64, Android emulator | The battery (`mark_race`, `finalizer_order`, `phobos_stress`) passes on each OS; benchmark numbers per OS | Phase 0 | 6–10 pw |
| 2. One barrier for three compilers | Frontend lowering behind `-gc-barrier`: pointer stores to non-local memory, pointer-holding copies, array operations; pointer-free copies skipped by type. An intrinsic expanded inline by DMD's x86-64 backend, LDC's IR (reusing the pass's coalescing) and GDC's GIMPLE. Range-checked card ABI. druntime copy hooks mark ranges | One program built by DMD, LDC and GDC with `-gc-barrier` passes `mark_race` and has 0 frames over 16 ms in the 500k city; LDC within 10% of today's pass; DMD's cost published | Phase 1 on Linux | 10–16 pw |
| 3. Android, then iOS | Below | A sample game on a mid-range Android phone at 60 fps, no GC-caused frame over 16 ms | Phase 1 on Android; phase 2 barrier | 4–8 pw Android; iOS open |
| 4. Upstream and DIP | druntime and symgc pull requests; the DIP with the phase 2 prototype as reference implementation | DIP accepted; a DMD release with the preview switch; the collector selectable through `gcopt` in stock druntime | druntime PRs after phase 0; DIP after phase 2 | 3–5 pw; calendar time set by the DIP process |

The range-checked card ABI: `i = (addr - heapBase) >> 9; if (i < cardCount) cards[i] = 1`. One unsigned compare
skips tagged Android pointers, malloc and stack memory, and lets the table cover only the GC's reservation (39-bit
Android address spaces, iOS limits). It needs the heap in one reserved range; symgc maps it in pieces today
(`base.d`). Its cost is to be measured against today's unchecked store.

## The DIP, and what does not need one

| Change | Route |
|---|---|
| `thread_scanAllType` tolerates a caller that is not a druntime thread (2 lines) | druntime pull request |
| `GCTelemetry`, `GC.frameStats`, `excludeCurrentThread`, `includeCurrentThread`, `isThreadExcluded`, `step`, `defrag` | druntime pull request (a `core.memory` API addition) |
| Latency patches 0001–0036 | Pull requests to symmetryinvestments/symgc, in order |
| The collector shipped with druntime as `gc:oneday` | druntime pull request, after phase 1 |
| Frontend lowering and intrinsic behind a preview switch | **DIP** |

The DIP specifies: which stores are covered (pointers, class references, slices, delegates, associative arrays
stored into non-local memory; copies and array operations of pointer-holding types); the druntime ABI (intrinsics,
card size, range-checked table), usable by any collector; rules for code the compiler cannot see (C, inline
assembly, raw copies), with a new `GC.writeBarrier(void[])`, relying on the spec's existing ban on hiding pointers in
integers; the switch and its default; and the evidence (barrier cost per compiler, pause numbers under DMD, LDC and
GDC). Open questions: `@nogc` and `-betterC` (proposed: barrier when druntime is linked, never under `-betterC`),
unions mixing pointers and integers (proposed: every store marked), and shared libraries built without the barrier
(proposed: allowed, covered by the OS tracker or a stop-the-world remark).

## Android now, iOS later

Toolchain work, useful beyond this GC: one script that cross-builds druntime and Phobos with `ldc-build-runtime` for
aarch64, armv7a and x86_64, with and without the barrier, and writes the `ldc2.conf` sections; a documented
`dub build --arch=aarch64-linux-android`; a Gradle `NativeActivity` template with a frame-time HUD; CI on an x86_64
emulator image.

Collector work: tagged pointers (range-checked ABI, or a mask in the LDC pass, free on arm64 with `ubfx`); start-up
inside a `.so` (`pragma(crt_constructor)` instead of `.preinit_array`); the table sized to the GC's reservation
(39-bit address spaces); suspend signals checked against ART's signal chaining; `GC.defrag()` on memory trim and GC
threads stopped while the activity is paused; mark-thread placement on big.LITTLE cores. The kernel tracker is not a
plan for phones.

iOS: a spike first (GC stress in the simulator and on a device, static library in an Xcode project); the
range-checked table is required by iOS's virtual memory limits; threads stopped through Mach `thread_suspend`; GC
threads at a background QoS class.

## DMD numbers

Measured on 2026-10-12 with `plans/bench/core_bench/dmd_bench.sh` (DMD 2.113, `-O -release -inline`; Ryzen 7
3800X, Linux 6.12, power-saving CPU setting). Worst frame, in ms, and frames over 16 ms; full tables in
`symgc/guide/benchmarks.md`.

| Workload | druntime GC | upstream symgc | oneday, STW mark | oneday (kernel tracker) | oneday, LDC + cards |
|---|---|---|---|---|---|
| Stress, 2 GiB, 100k bullets/s | 139-141 / 4 | 28.0 / 3 | 11.1 / 0 | 1.19-1.27 / 0 | 0.87 / 0 |
| Stress, 8 GiB | 548 / 2 | 63.6 / 1 | 35.3 / 1 | 1.22 / 0 | 0.84 / 0 |
| Bullet hell, 2 GiB, heavy frame | 151 / 1 | 25.4 / 7 | 13.3 / 0 | 4.26 / 0 | 1.30 / 0 |
| City, 500k citizens, 6 jobs | 137-193 / 37 | 107-113 / 40 | 60.7 / 25 | 9.7-9.8 / 0 | 6.9 / 0 |
| City, 100k | 40.4 / 18 | 48.5 / 14 | 17.5 / 10 | 3.68 / 0 | — |
| RTS, 4,000 units | 13.2 / 0 | 36.9 / 14 | 11.0 / 0 | 4.71 / 0 | — |
| Open world, streaming | 16.6 / 2 | 14.1 / 0 | 8.8 / 0 | 1.34 / 0 | — |

Allocation: one thread 15.5 M allocs/s against druntime's 19.6 M (0.79x); eight threads 36.0 M against 4.2 M (8.6x).
The `frag` workload is 1.8x slower under oneday. With DMD and no compiler change, oneday has no frame over 16 ms in
any workload; the kernel tracker's cost shows in the heavy bullet hell (p99.9 4.0 ms against 1.7 ms for druntime's
GC, which in exchange stops for 151 ms once).

## Risks

| Risk | What reduces it |
|---|---|
| The DIP is slow or rejected | Phases 0–1 and the druntime PRs do not depend on it; code without the barrier still runs |
| GDC ships yearly with an older frontend | Support druntime 2.111 in the fork; the barrier lives in the shared frontend |
| DMD's barrier is slower than LDC's | DMD is the development compiler; publish its cost |
| C writing GC pointers into GC memory is invisible to the barrier | `GC.writeBarrier`, the DIP's rules, the verifier and `mark_race` in each port |
| Never built off Linux x86-64 | Phase 1 runs the battery on every OS before barrier work |
| Unexplained 81 ms and 7.1 ms frames at 8 GiB | The 30–60 min soak at 4–8 GiB with the verifier (RFC section 15, option 5) |
| Upstream symgc does not take the patches | Small tested steps; druntime can host the collector directly |

## Progress log

### 2026-10-12: step A, the card ABI that works on every platform (done)

The first step toward Android and the other platforms, and the ABI that the frontend barrier of phase 2 will specify.
Everything below was run on Linux x86-64; nothing was run on another OS.

* **One window.** The memory that holds pointers is one contiguous reservation made when the collector starts
  (256 GiB on a desktop, 16 GiB on Android and iOS, `SYMGC_HEAP_RESERVE_GIB`, halved down to 2 GiB if the system
  refuses). The card table covers the window only: 512 MiB for 256 GiB, 32 MiB for 16 GiB, instead of a table for the
  whole 47-bit address space.
* **Range-checked barrier.** `if ((addr - lo) >> 9 < n) cards[(addr - lo) >> 9] = 1`. Stores to `malloc` memory and
  through pointers with a tag in the top byte (Android's allocator, since Android 11) fall outside and mark nothing.
  `lo`, `n` and the table are zero until the collector starts, so every barrier is a no-op until then: no
  `.preinit_array`, `__mod_init_func` or `.CRT$XCU` hook is needed, which is what keeps it working inside a shared
  library (an Android game is one).
* **Cost.** 0% on class fields, structs and linked lists; +9% on array element stores; +5% to +15% on copies of 8 to
  64 pointers (`barrier_micro`). On the 500k city and the 2 and 8 GiB stress tests, the same as the unchecked barrier
  within noise. The "measure it before adopting it" condition of phase 2 is met on LDC.
* **Correctness.** `mark_race` passes (and loses about 80,000 objects per run without the barrier), as do
  `finalizer_order`, `phobos_stress`, `thread_exit_race` and the 113 unit tests. `cards_window` checks the window,
  the out-of-window cases, the tag, the clipping at the end, and the fallback when address space is limited (a 32 GiB
  limit makes the collector settle for 16 GiB).
* **Compiling for other targets**, `ldc2 -mtriple=<target> -c` on the whole collector with the barrier:
  `x86_64-linux-gnu` and `aarch64-linux-gnu` compile; `aarch64-linux-android` and `x86_64-windows-msvc` compile after
  four fixes (Windows constants imported from the wrong module, `usleep` and a scoping error in Linux-only code, and
  `sched_getcpu`, which Android only has from API 29). macOS and iOS do not compile: the collector has no waiter
  (no futex on Darwin) and its stop-the-world protocol is Linux (signals) or Windows only.
* **What this does not show.** Nothing has been linked or run on Windows, Android or arm64 Linux: there is no NDK,
  emulator, device or cross sysroot on the development machine. "Compiles" is the claim, not "works".

Next for phase 1: run the battery on the Android emulator (build instructions in `symgc/guide/android.md`, untested),
then Windows. For phase 2: a first prototype of the frontend lowering on DMD.
