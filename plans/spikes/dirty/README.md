# Spike: dirty-page tracking for a mostly-concurrent mark (step 4)

`dirty.c` asks the kernel which pages of a 2 GiB region were written since the last scan, using
`userfaultfd(UFFD_USER_MODE_ONLY)` with `UFFD_FEATURE_WP_ASYNC` and the `PAGEMAP_SCAN` ioctl (Linux 6.7 or later;
this machine runs 6.12). No signal, no handler, no compiler support: any D, C or asm code that writes memory is
tracked, and so are the writes the kernel does for `read()`.

```
gcc -O2 -o dirty dirty.c -lpthread && ./dirty 2048
```

Results (Ryzen 7 3800X, 2 GiB, 4 KiB pages; with transparent huge pages in brackets):

| | 4 KiB pages | THP |
|---|---|---|
| Arm (write-protect the whole region) | 13 ms | 0.23 ms |
| Scan with nothing written | 1.0 ms | 0.06 ms |
| Scan and re-arm, 1,000 / 10,000 dirty pages | 1.2 / 1.6 ms | 1.4 / 1.9 ms |
| Scan and re-arm, 100,000 / 400,000 dirty pages | 4.4 / 10.3 ms | 4.3 / 10.3 ms |
| First write to an armed page | 0.77 us | 1.15 us (splits the huge page) |
| Writer thread during 50 scans: mean / worst | 0.86 / 9 us | 1.0 / 10 us |
| `read()` into armed pages | works, tracked | works, tracked |

What it means for the plan:

- A frame that dirties a few hundred pages costs the mutator under a millisecond a cycle, in small pieces of under 1 us.
- The final scan of a Boehm-style remark (see "Mostly-concurrent mark" in the plan) costs 1 to 4 ms for 100,000 dirty
  pages (400 MB), and the dirty set can be drained concurrently in rounds before the pause.
- Arming can run before the start pause, concurrently: pages written between the arm and the mark start only make the
  dirty set a superset.
- Unprivileged use needs `UFFD_USER_MODE_ONLY` (`vm.unprivileged_userfaultfd` is 0 here). It worked.
- Needs a fallback to the stop-the-world mark when the kernel lacks it (Linux before 6.7, other systems).
- Writing to a huge page that is armed splits it, so the heap loses its huge pages as it is written; `khugepaged` can
  collapse them again later. The cost is TLB reach, not measured here.
