# Audit: pointer deletions that are not barriered stores (needed before P3)

SATB marking is correct only if every deletion of a pointer edge during marking is logged (or the edge's target is
shaded). The compiler barrier covers stores to pointer fields. This audit lists the other ways druntime, symgc and
compiled code remove or overwrite pointer-containing memory, checked against the rule found in the protocol model
(`plans/model/README.md`, finding 6). Sources read: `druntime/src/rt/lifetime.d`, `core/memory.d`, `core/lifetime.d`,
`core/internal/array/{appending,capacity,arrayassign,construction,duplication}.d`, `symgc/source/symgc/gcobj.d`,
`symgc/source/d/gc/{tcache,global,scanner,page}.d`.

## Result

| # | Path | Where | Deletes edges? | Verdict |
|---|---|---|---|---|
| 1 | `GC.free`, `delete`, `__delete`, `_d_delclass`, `_d_delmemory` | `rt/lifetime.d:187,372`, `core/memory.d:1331-1336` all reach `gc_free` -> `__sd_gc_free` | yes: every pointer word of the block | **needs release barrier** (model: `nofreebarrier`, 11 steps) |
| 2 | `GC.realloc` that moves | symgc `tcache.realloc` ends with `memcpy(newPtr, ptr, copySize); free(pd, ptr)` | yes: the old block is released after its contents were copied into a fresh block that is allocated black (not scanned) | **needs release barrier on the old block** (children exist only in the unscanned copy) |
| 3 | `GC.realloc` / `shrinkLarge` that shrinks a large block | `tcache.realloc`: `shrinkLarge(pd, npages)` | yes: the released tail pages | **needs release barrier on the tail** |
| 4 | `GC.realloc(p, 0)` | `tcache.realloc`: `free(ptr)` | yes | same as 1 |
| 5 | `GC.removeRoot`, `GC.removeRange` | `gcobj.d:335,359` -> `GCState.removeRootsImpl` (`d/gc/global.d:141`) | yes: the whole removed root range | **needs shading of the removed range** (model: `--rootrm`, `noremoveroot` 10 steps) |
| 6 | `_d_arrayassign_l/_r`, `_d_arraysetassign`, struct assignment and `destroy`/`.init` stores done by `memcpy`/`memset` over live memory | `core/internal/array/arrayassign.d:94,230,350`; compiler-emitted `llvm.memcpy`/`memset` | yes: the overwritten elements | **needs a bulk pre-barrier** (flag test, then shade the destination range while marking). The model already covers the per-field case, so this is a coverage rule for the compilers and for these druntime functions. The barrier spike did not barrier `memcpy` at all, so its cost figures exclude this. |
| 7 | Append / `length` growth into spare capacity | `core/internal/array/appending.d:56-155`, `capacity.d:123-375` | overwrites slack past the used length | safe: slack is not reachable by the program (aliasing slices past `assumeSafeAppend` are already a documented stomping error); symgc scans the whole block (`scanner.d:670` has `usedCapacity` commented out), so nothing is hidden |
| 8 | Array growth that reallocates (`capacity.d:169`, `appending.d:97`) | copies old to a fresh block | no deletion (old block stays valid until its pointer is overwritten by a barriered store) | safe |
| 9 | `setAttr` / `clrAttr` | symgc `gcobj.d:179,188` are no-ops | n/a | safe in symgc. (The conservative GC supports `clrAttr(NO_SCAN)`, which would make a black, unscanned block scannable: not relevant to the fork.) |
| 10 | Thread exit during marking | `cleanupThread`, `destroyThread` | the thread's stack and TLS vanish | safe by the hybrid barrier (values copied out before the thread's handshake are shaded), provided the exiting thread flushes its SATB buffer (`exitnoflush`) and a thread started during marking is registered as unscanned (`startnoscan`); both modelled with `--threadlife` |
| 11 | Finalizers during a lazy sweep | `finalizeSlabNimble`, `collectSparseAllocations` | resurrection of an object the sweep already decided to free | contract unchanged: destructors must not resurrect or touch other GC objects. With a lazy sweep the order and thread of finalization changes; document it |
| 12 | Thread-cache flush | `Bin.batchFree` | frees cached, never-handed-out slots (no user data) | safe |

## What follows

1. **One central fix covers 1 to 4:** a `shadeBlock(ptr, size)` in the GC, called from `free`, `realloc` (old block
   when moved, released tail when shrunk) while `marking` is set. It scans the block words with the existing pointer
   test and pushes the targets to the SATB queue. No compiler change. Cost: only while marking.
2. **Fix 5 inside `removeRoots`:** shade the removed range while `marking` is set (the table holds the range).
3. **Fix 6 in the compilers and druntime:** `memcpy`/`memmove`/`memset` of unknown or pointer-containing destination
   get a guarded call `if (marking) _d_bulk_pre(dst, n)`; druntime's array assignment functions call it for the
   destination. Measure this in the real LDC build (step 4 of the plan): it is the one item that can add cost to code
   that never allocates.
4. Thread creation and exit are modelled (item 10). Implementation rules: flush the SATB buffer in the thread-exit
   hook; register a new thread as unscanned under the thread-list lock; reset every per-thread cycle field at
   registration.
5. Unit tests to write with the fixes, each failing without the fix: free the parent of a grey, untraced object;
   realloc-move a pointer array during marking; `removeRange` after loading a child to the stack; `arr[] = other` over
   a pointer array during marking.

## Limits

Read by hand, not by a tool; druntime has other `GC.free` callers in tests and in `core.thread` that were not walked.
Phobos was not audited (no matching checkout). Hidden-pointer idioms (xor lists, tagged pointers) are outside the
conservative scan's contract and outside this audit. Whether `std.container` or `std.array` use `GC.free` or
`assumeSafeAppend` in ways that matter remains to be checked once a matching Phobos is available.
