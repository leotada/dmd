#!/bin/sh
# Barrier-cost spike driver (RFC Phase 0.3). For each workload, build it through
# the same clang pipeline in several barrier modes, then time and size it.
#
#   ./run_spike.sh [reps]            (default 5 repetitions, median reported)
#
# Output: results.csv with workload, mode, median seconds, ratio to control,
# and .text bytes of the instrumented object.
#
# Needs: ldc2, clang (same LLVM as ldc2), and Phobos from the LDC install.
set -u
REPS=${1:-5}
HERE=$(cd "$(dirname "$0")" && pwd)
RUNDIR="$HERE/../../../druntime/benchmark"   # extra-files/ lives here
BENCH="$RUNDIR/gcbench"
OUT=${SPIKE_OUT:-$HERE/build}
mkdir -p "$OUT"
cd "$OUT" || exit 1

ldc2 -O3 -release -of=rewrite_ir "$HERE/rewrite_ir.d" || exit 1
ldc2 -O3 -release -c -of=gcspike_rt.o "$HERE/gcspike_rt.d" || exit 1

# workload source | arguments (run from $BENCH so extra-files/ resolves)
WORKLOADS="
$HERE/workloads/ptr_heavy.d|1000000 20
$BENCH/tree1.d|
$BENCH/tree2.d|
$BENCH/dlist.d|
$BENCH/slist.d|
$BENCH/mt_alloc.d|1000000 4
$BENCH/append_heavy.d|20000
$BENCH/parallel_map.d|100000 20
$BENCH/traverse_locality.d|500000 20
"

MODES="none satb satb+vis publish publish+vis"

median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }

echo "workload,mode,median_s,ratio,text_bytes" > results.csv

echo "$WORKLOADS" | while IFS='|' read -r src args; do
    [ -z "$src" ] && continue
    name=$(basename "$src" .d)
    ldc2 -O3 -release -c -output-ll -of="$name.ll" "$src" 2>/dev/null || { echo "skip $name (ldc2 failed)"; continue; }

    for mode in $MODES; do
        for variant in default fresh; do
            [ "$mode" = none ] && [ "$variant" = fresh ] && continue
            flag=""
            [ "$variant" = fresh ] && flag="--elide-fresh"
            tag="$name.$mode.$variant"
            ./rewrite_ir --mode=$mode $flag "$name.ll" "$tag.ll" 2>"$tag.log" || continue
            clang -O2 -c "$tag.ll" -o "$tag.o" 2>>"$tag.log" || { echo "clang failed: $tag"; continue; }
            ldc2 -O3 -release "$tag.o" gcspike_rt.o -of="$tag.bin" 2>>"$tag.log" || { echo "link failed: $tag"; continue; }
            text=$(size "$tag.o" | awk 'NR==2 {print $1}')
            times=""
            for i in $(seq "$REPS"); do
                s=$(date +%s.%N)
                (cd "$RUNDIR" && "$OUT/$tag.bin" $args >/dev/null 2>&1)
                e=$(date +%s.%N)
                times="$times $(echo "$s $e" | awk '{printf "%.3f", $2 - $1}')"
            done
            med=$(printf '%s\n' $times | median)
            echo "$name,$mode.$variant,$med,,$text" >> results.csv
            echo "$name $mode.$variant $med s, .text=$text"
        done
    done
done

# Fill in the ratio against each workload's control (mode none).
awk -F, 'NR==1 {print; next}
         $2=="none.default" {base[$1]=$3}
         {rows[NR]=$0; w[NR]=$1; m[NR]=$2; t[NR]=$3; x[NR]=$5}
         END {for (i=2;i<=NR;i++) printf "%s,%s,%s,%.3f,%s\n", w[i], m[i], t[i], t[i]/base[w[i]], x[i]}' results.csv > results.tmp \
    && mv results.tmp results.csv
column -s, -t results.csv
