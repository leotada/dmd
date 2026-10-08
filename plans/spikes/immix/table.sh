#!/bin/sh
# Print the interesting columns of a results.csv written by run.sh, one row per case,
# immix first, with the segfit/immix ratio of wall time and RSS on a second line.
#
#   ./table.sh results.csv
set -u
awk -F, '
NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
{ row[$1, $2] = $0; if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 } }
function f(line, name,   a) { split(line, a, ","); return a[h[name]] }
END {
  printf "%-10s %-7s %8s %8s %5s %9s %8s %9s %9s %9s %8s %9s\n", "case", "impl", "secs", "Mops/s", "GCs", "pause ms", "max ms", "mark ms", "sweep ms", "rss MiB", "meta MiB", "steadyMiB"
  for (k = 1; k <= n; k++) {
    c = order[k]
    split("immix immix-ovf segfit", impls, " ")
    for (j = 1; j <= 3; j++) {
      r = row[c, impls[j]]; if (r == "") continue
      printf "%-10s %-7s %8.3f %8.2f %5d %9.1f %8.1f %9.1f %9.1f %9.1f %8.2f %9.1f\n", c, impls[j],
        f(r, "seconds"), f(r, "mops"), f(r, "gcs"), f(r, "pause_ms"), f(r, "maxpause_ms"), f(r, "mark_ms"), f(r, "sweep_ms"),
        f(r, "rss_kib") / 1024, f(r, "meta_kib") / 1024, f(r, "steady_rss_kib") / 1024
    }
    a = row[c, "immix"]; b = row[c, "segfit"]
    if (a != "" && b != "") {
      printf "%-10s %-9s %8.2f %8.2f %5s %9.2f %8s %9.2f %9.2f %9.2f %8.2f %9.2f\n", "", "seg/imx",
        f(b, "seconds") / f(a, "seconds"), f(b, "mops") / f(a, "mops"), "", f(b, "pause_ms") / f(a, "pause_ms"), "",
        f(b, "mark_ms") / f(a, "mark_ms"), f(b, "sweep_ms") / (f(a, "sweep_ms") ? f(a, "sweep_ms") : 1),
        f(b, "rss_kib") / f(a, "rss_kib"), f(b, "meta_kib") / (f(a, "meta_kib") ? f(a, "meta_kib") : 1),
        (f(a, "steady_rss_kib") ? f(b, "steady_rss_kib") / f(a, "steady_rss_kib") : 0)
    }
    for (j = 1; j <= 3; j++) {
      r = row[c, impls[j]]
      if (r != "" && f(r, "cache_misses_per_traversal") > 0)
        printf "%-10s %-7s traversal %.2f ms, cache misses per traversal %.0f, instructions %.0f\n", "", impls[j], f(r, "traversal_ms"), f(r, "cache_misses_per_traversal"), f(r, "instructions_per_traversal")
    }
  }
}' "$1"
