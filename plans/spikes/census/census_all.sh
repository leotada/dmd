#!/bin/sh
# Run the escape census over the gcbench workloads (RFC Phase 0.4).
#
#   ./census_all.sh [outdir]       (default ./build)
#
# Each workload is built and run once through run_census.sh with reduced sizes (the census is
# 10 to 1000 times slower than a normal run). Logs go to <outdir>/<name>.census.log and the
# one-line summaries are collected in <outdir>/census.txt.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/build}
BENCH=$HERE/../../../druntime/benchmark/gcbench
INC="-i=std.concurrency -i=std.variant -i=std.parallelism"
mkdir -p "$OUT"
: > "$OUT/census.txt"

# workload | arguments
WORKLOADS="
mt_alloc|200000 4
mt_share|20000 2
parallel_map|20000 3
append_heavy|2000
tree1|12 4
tree2|200000 100
dlist|extra-files/dante.txt 5 488380
slist|extra-files/dante.txt 5 488380
words|
rand_small|300
rand_large|600
traverse_locality|50000 2
latency|16 20000
frag_longrun|300000 20000 100000
conalloc|
conappend|
concpu|
conmsg|
"

echo "$WORKLOADS" | while IFS='|' read -r name args; do
    [ -z "$name" ] && continue
    [ -f "$BENCH/$name.d" ] || { echo "skip $name"; continue; }
    if "$HERE/run_census.sh" -o "$OUT" -I "$INC" "$BENCH/$name.d" $args > "$OUT/$name.run.log" 2>&1; then
        echo "$name $(cat "$OUT/$name.census.txt")" >> "$OUT/census.txt"
        echo "ok   $name"
    else
        echo "FAIL $name (see $OUT/$name.run.log)"
    fi
done
