#!/bin/sh
# Pause histogram from a --DRT-gcopt=trace:FILE CSV (RFC Phase 0.2).
#
#   ./pause_hist.sh trace.csv [more.csv ...]
#
# Prints, per file: collections by kind, total/mean/max pause, p50/p90/p99 of the
# stop-the-world pause, and a log2 histogram in microseconds. A "fork-start" record is
# the stop-the-world part of a forking collection and counts as a pause; the later
# "fork" record of the same collection is concurrent work and is excluded.
set -u
[ $# -ge 1 ] || { sed -n '2,9p' "$0"; exit 2; }
for f in "$@"; do
    echo "== $f"
    awk -F, '
    function pct(q,   i) { i = int((n + 1) * q); if (i > n) i = n; if (i < 1) i = 1; return p[i] }
    NR == 1 { next }
    { kind[$2]++; if ($2 == "fork") next
      p[++n] = $3 + 0; tot += $3; if ($3 > mx) mx = $3
      b = 0; for (v = $3 + 0; v > 1; v = int(v / 2)) b++
      h[b]++; if (b > hb) hb = b
      mark += $4; sweep += $5 }
    END {
      if (!n) { print "no pauses"; exit }
      # insertion sort; traces are small
      for (i = 2; i <= n; i++) { v = p[i]; j = i - 1; while (j > 0 && p[j] > v) { p[j + 1] = p[j]; j-- } p[j + 1] = v }
      printf "collections:"; for (k in kind) printf " %s=%d", k, kind[k]; printf "\n"
      printf "pauses=%d total=%d us mean=%.0f us max=%d us\n", n, tot, tot / n, mx
      printf "p50=%d us p90=%d us p99=%d us\n", pct(0.5), pct(0.9), pct(0.99)
      printf "mark=%d us sweep=%d us (sum over collections)\n", mark, sweep
      for (b = 0; b <= hb; b++) if (h[b]) printf "  [%8d us, %8d us): %d\n", (b ? 2 ^ b : 0), 2 ^ (b + 1), h[b]
    }' "$f"
done
