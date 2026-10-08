#!/bin/sh
# Ratio table between two result sets from run_compare.sh.
#
#   ./compare_runs.sh <base.csv> <base-toolchain> <new.csv> <new-toolchain>
#
# For each workload prints new/base for wall time, peak RSS, total GC time and max pause
# (a ratio below 1 means the new configuration is better), then geometric means.
# The same file may be given twice to compare two toolchains of one run, e.g.
#   ./compare_runs.sh results/ci.csv dmd results/ci.csv ldc
set -u
[ $# -eq 4 ] || { sed -n '2,10p' "$0"; exit 2; }

awk -F, -v ta="$2" -v tb="$4" '
FNR == 1 { next }
FILENAME == ARGV[1] && $2 == ta { if (!($1 in a)) ord[++cnt] = $1; a[$1] = $0 }
FILENAME == ARGV[2] && $2 == tb { b[$1] = $0 }
function ratio(x, y) { return (x > 0) ? y / x : -1 }
END {
  printf "%-18s %8s %8s %8s %10s\n", "workload", "wall", "RSS", "GC ms", "max pause"
  for (k = 1; k <= cnt; k++) {
    w = ord[k]
    if (!(w in b)) continue
    split(a[w], p, ","); split(b[w], q, ",")
    r[1] = ratio(p[3], q[3]); r[2] = ratio(p[8], q[8]); r[3] = ratio(p[10], q[10]); r[4] = ratio(p[11], q[11])
    printf "%-18s", w
    for (i = 1; i <= 4; i++) {
      if (r[i] < 0) printf " %8s", (i == 4 ? "-" : "-")
      else { printf " %8.2f", r[i]; if (r[i] > 0) { s[i] += log(r[i]); n[i]++ } }
    }
    printf "\n"
  }
  printf "%-18s", "geometric mean"
  for (i = 1; i <= 4; i++) printf " %8.2f", (n[i] ? exp(s[i] / n[i]) : 0)
  printf "\n(ratios of zero-millisecond GC time or pause are skipped; pauses are ms-resolution)\n"
}' "$1" "$3"
