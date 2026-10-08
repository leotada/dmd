# Protocol model checker (Phase 0.5)

`gc_model.d` is an explicit-state model of the collector protocol of RFC sections 3.5 (invariants I1 to I6),
4.3 (pause structure) and 4.4 (barrier). It enumerates reachable states breadth-first and reports the shortest
action trace to any violation, or walks long random executions for configurations too large to enumerate.

```
dmd -O -release -inline gc_model.d
./gc_model --track=A --threads=2 --objects=3 --stack=1
./gc_model --track=B --threads=3 --objects=5 --stack=2 --fields=2 --swarm=1500 --len=3000
./gc_model --bug=nodelete ...            # planted bug, must be detected
./run_all.sh                             # clean runs, planted bugs, findings (LONG=1 adds a 7-minute case)
```

## What is modelled

Objects (free, global, or local to a thread), pointer fields, global slots, per-thread stack contexts (the thread's
stack plus `--fibers` suspended fibers), the SATB deletion barrier, the hybrid barrier until a thread's handshake,
black allocation, grey promotion, in-place promotion and globalization (Track B), local collections, stack-address
escape, the collector's STW-1, global-root scan, per-thread handshakes, fiber claim/scan (unscanned, scanning,
scanned), tracing, STW-2 remark and lazy sweep. `--race` splits a store into barrier and write so threads can
interleave between them.

Reductions: object renaming by first reachability, and thread permutation (the smallest relabelling is stored;
halved the 2-thread state counts). `--swarm` samples long random walks, with stack-address escapes made rare
because an escape is permanent for its thread.

## Not modelled

Lines and blocks (I4 holds per object by construction), weak memory, fiber migration between threads, fibers
created during a cycle, I2/I3 (hold by construction), finalizers, interior pointers, no-scan data, large objects.

## Results

| Check | Result |
|---|---|
| Track A, 2 threads, 3 objects, 1 slot, exhaustive | pass, 2.45M states (4.9M before thread symmetry) |
| Track B, same, and 1 thread with 2 slots | pass |
| Fibers, Track A, 1 thread, 1 fiber, exhaustive | pass, 1.23M states |
| `--race --fix=xchg`, Track A, 2 threads, 3 objects, exhaustive | pass, 49.7M states, 389 s |
| `--race` without the fix | **violation**, 10 steps |
| Randomized, Track A and B, 3 threads, 5 objects | pass, millions of steps, 80k+ completed cycles |
| 15 planted bugs | all detected exhaustively; 9 of 10 detected by random walks at 3 threads / 5 objects |

## Findings that changed the design

1. **Stack visibility.** A stack must be scanned before another thread can read it, or a pointer can be copied
   out of an unscanned stack and then overwritten in the owner without a barrier (RFC I5, ADR-9).
2. **Sweep protection and floating garbage** (RFC I5).
3. **The barrier sequence must not be separable by a stop-the-world signal.** If the marking-flag test happens,
   a cycle starts, and then the store happens, the stored object is never logged and is freed (10-step trace
   with `--race`). Either the sequence is restartable (the signal handler rolls the PC back) or the write is an
   exchange followed by the flag test. The exchange form passes 49.7M states.
4. **Registers of a thread mid-store are roots** (found while debugging the model; the real equivalent is that
   suspended threads' registers are scanned).
5. **Fiber switch-in must scan an unscanned fiber** (`nofiberscan`, 13-step trace).

## Limits

The random mode cannot prove absence of bugs, and missed `noescapescan` (a 10-step interleaving found only
exhaustively). A depth-limited search from random states would close that gap. 3 threads with 5 objects is not
reachable exhaustively.

## Slabs, explicit free and allocation during the sweep (`--slabs=K --free`, P2 lazy-sweep design)

Added to check the design in RFC "Lazy-sweep prototype: analysis" before any code is written. With `--slabs=K`
objects are grouped K per slab; each slab is in or out of its bin heap; the sweep empties every bin at its start
(`clearForCollection`), then sweeps one slab at a time and puts it back when it has a free slot; allocation takes a
free slot only from a slab that is in its bin (so, during a sweep, only from swept slabs, and without marking: the
slot is never visited by this sweep); a slab that becomes full leaves the bin. `--free` lets a mutator free an object
only its own slot references (`GC.free`/`delete`); a swept slab re-enters its bin on the first free slot, an unswept
slab does not (the sweep rebuilds it). Invariants added: an unswept slab is never in a bin, a full slab is never in a
bin, and a swept slab with a free slot is always in its bin. Object renaming is off in this mode (objects are no longer
interchangeable), so exhaustive runs use 3 to 4 objects.

| Check | Result |
|---|---|
| Track A, 1 thread, 3 objects, 2 slots, `--slabs=2 --free`, exhaustive | pass, 10.0M states |
| Track A, 2 threads, 3 objects, 1 slot, `--slabs=2 --free`, exhaustive | pass, 14.6M states |
| Track A, 1 thread, 4 objects, 1 slot, `--slabs=2 --free`, exhaustive | pass, 2.4M states |
| Track A, `--free` without slabs, 1 thread, 3 objects, 2 slots, exhaustive | pass, 1.96M states |
| random walks, 2 threads / 4 objects / `--slabs=2 --free`, 300 walks x 100k steps | pass, 1.5M cycles |
| planted `allocunswept`, `freeunswept`, `missedinsert` | detected (use-after-free; double insert; leak) |

**Finding 6: explicit free during marking needs the deletion barrier on the freed object's fields.** The first clean
run failed (11-step trace, also without slabs): the collector greys O0 but has not traced it; a mutator loads O1 from
`O0.f0` into its stack (loads are unbarriered); the mutator then frees O0. Freeing deletes every pointer field of O0
without logging them, O1 is never marked and the sweep frees it while the stack still holds it. Fix: `GC.free`,
`delete` and anything that releases a block containing pointers must log (or shade) its pointer fields while
`marking` is set, exactly like an overwritten field. With the fix the runs above pass; the old behaviour is the planted
bug `nofreebarrier`. For a no-scan block there is nothing to log.
