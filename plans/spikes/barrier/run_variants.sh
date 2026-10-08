#!/bin/sh
# Compares publication fast-path variants (RFC Phase 0.3 follow-up):
# publish (two table lookups), split (slot first), arena (range compare),
# each with the stack-visibility compare and fresh-store elision, under both
# GCSPIKE_MINE settings. Reuses the .ll files and runtime from run_spike.sh.
#
#   SPIKE_OUT=<dir used by run_spike.sh> ./run_variants.sh [reps]
set -u
REPS=${1:-7}
HERE=$(cd "$(dirname "$0")" && pwd)
RUNDIR="$HERE/../../../druntime/benchmark"
OUT=${SPIKE_OUT:-$HERE/build}
cd "$OUT" || exit 1

ldc2 -O3 -release -of=rewrite_ir "$HERE/rewrite_ir.d" || exit 1
ldc2 -O3 -release -c -of=gcspike_rt.o "$HERE/gcspike_rt.d" || exit 1

WORKLOADS="
ptr_heavy|1000000 20
tree1|
tree2|
dlist|
slist|
mt_alloc|1000000 4
append_heavy|20000
parallel_map|100000 20
traverse_locality|500000 20
"
MODES="publish+vis split+vis arena+vis"

median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
timeit() { # binary args env
    ts=""
    for i in $(seq "$REPS"); do
        s=$(date +%s.%N)
        (cd "$RUNDIR" && env $3 "$OUT/$1" $2 >/dev/null 2>&1)
        e=$(date +%s.%N)
        ts="$ts $(echo "$s $e" | awk '{printf "%.3f", $2 - $1}')"
    done
    printf '%s\n' $ts | median
}

echo "workload,variant,mine,median_s,ratio,text_bytes" > variants.csv
echo "$WORKLOADS" | while IFS='|' read -r name args; do
    [ -z "$name" ] && continue
    [ -f "$name.ll" ] || continue
    base=$(timeit "$name.none.default.bin" "$args" X=1)
    basetext=$(size "$name.none.default.o" | awk 'NR==2 {print $1}')
    echo "$name,none,-,$base,1.000,$basetext" >> variants.csv
    for mode in $MODES; do
        tag="$name.$mode.v2"
        ./rewrite_ir --mode=$mode --elide-fresh "$name.ll" "$tag.ll" 2>/dev/null || continue
        clang -O2 -c "$tag.ll" -o "$tag.o" 2>/dev/null || continue
        ldc2 -O3 -release "$tag.o" gcspike_rt.o -of="$tag.bin" 2>/dev/null || continue
        text=$(size "$tag.o" | awk 'NR==2 {print $1}')
        for mine in 0 1; do
            t=$(timeit "$tag.bin" "$args" GCSPIKE_MINE=$mine)
            echo "$name,$mode,$mine,$t,$(echo "$t $base" | awk '{printf "%.3f", $1 / $2}'),$text" >> variants.csv
        done
    done
    echo "done $name"
done

echo
echo "geometric mean slowdown by variant and MINE setting:"
awk -F, 'NR>1 && $2!="none" {k=$2" mine="$3; n[k]++; s[k]+=log($5); if($5>mx[k]){mx[k]=$5; w[k]=$1}}
         END {for (k in n) printf "%-26s geomean %.3f  worst %.3f (%s)\n", k, exp(s[k]/n[k]), mx[k], w[k]}' variants.csv | sort
echo
echo ".text growth, geometric mean:"
awk -F, 'NR>1 && $2=="none" {b[$1]=$6} NR>1 && $2!="none" && $3==0 {n[$2]++; s[$2]+=log($6/b[$1])}
         END {for (k in n) printf "%-14s x%.2f\n", k, exp(s[k]/n[k])}' variants.csv | sort
