#!/bin/sh
# Same binary, several collectors: conservative (default), conservative with parallel marking,
# conservative with fork marking, and symgc (gc:sdcq).
#
#   ./run_core.sh [reps] [outdir]
set -u
REPS=${1:-3}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/../../..
OUT=${2:-$HERE/build}
D=$ROOT/generated/linux/release/64/dmd
mkdir -p "$OUT"
cd "$HERE" || exit 1
$D -O -release -inline -version=SymGC -version=Symgc_druntime_hooks -I"$ROOT/symgc/source" -I"$ROOT/druntime/import" \
    -defaultlib= -L-L"$ROOT/generated/linux/release/64" -L-ldruntime -of="$OUT/gcb_sym" gcb.d perfcount.d \
    $(find "$ROOT/symgc/source" -name "*.d") || exit 1
# Linking symgc into the binary makes the conservative collector slow (about 40x on `alloc`): it
# scans symgc's static data as roots. So the conservative configurations use a binary without it.
$D -O -release -inline -I"$ROOT/druntime/import" \
    -defaultlib= -L-L"$ROOT/generated/linux/release/64" -L-ldruntime -of="$OUT/gcb_plain" gcb.d perfcount.d || exit 1

CONFIGS="conservative|gc:conservative
parallel|gc:conservative parallel:8
fork|gc:conservative fork:1
symgc|gc:sdcq"

CASES="alloc-1t|alloc 1 8000000
alloc-4t|alloc 4 4000000
alloc-8t|alloc 8 4000000
frag|frag 15000000 100000
fragsmall|frag 30000000 400000 2032
trav|trav 2000000 10
tree|tree 18
latency256|latency 256 200000
latency1024|latency 1024 200000"

: > "$OUT/raw.txt"
echo "$CASES" | while IFS='|' read -r label args; do
    echo "$CONFIGS" | while IFS='|' read -r cname copt; do
        for i in $(seq "$REPS"); do
            bin=$OUT/gcb_plain; [ "$cname" = symgc ] && bin=$OUT/gcb_sym
            if timeout 600 "$bin" $args "--DRT-gcopt=$copt" > "$OUT/run.out" 2>&1; then
                grep '^RESULT' "$OUT/run.out" | sed "s/^RESULT /case=$label gc=$cname rep=$i /" >> "$OUT/raw.txt"
            else
                echo "FAILED $label $cname rep $i: $(tail -2 "$OUT/run.out" | tr '\n' ' ')"
            fi
        done
        echo "done $label $cname"
    done
done
