#!/bin/sh
# Build a workload with escape-census instrumentation and run it (RFC Phase 0.4).
#
#   ./run_census.sh [-o outdir] [-I "-i=std"] workload.d [program args ...]
#
# Pipeline: ldc2 -output-ll (optimized IR, Phobos compiled in with -i=std so its stores are
# seen) -> rewrite_census -> clang -c -> link with census_rt. The program's stderr carries
# the census report; the one-line "CENSUS ..." summary is also written to <outdir>/<name>.census.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/build
INC="-i=std"
while getopts "o:I:" opt; do
    case $opt in o) OUT=$OPTARG ;; I) INC=$OPTARG ;; *) exit 2 ;; esac
done
shift $((OPTIND - 1))
[ -f "${1:-}" ] || { echo "usage: $0 [-o outdir] workload.d [args]"; exit 2; }
SRC=$(readlink -f "$1"); shift
OUT=$(readlink -f "$OUT")
NAME=$(basename "$SRC" .d)
mkdir -p "$OUT"
cd "$OUT" || exit 1

[ -x rewrite_census ] && [ rewrite_census -nt "$HERE/rewrite_census.d" ] || ldc2 -O3 -release -of=rewrite_census "$HERE/rewrite_census.d" || exit 1
[ -f census_rt.o ] && [ census_rt.o -nt "$HERE/census_rt.d" ] || ldc2 -O2 -release -c -of=census_rt.o "$HERE/census_rt.d" || exit 1

ldc2 -O3 -release -c -output-ll -singleobj $INC -of="$NAME.ll" "$SRC" || exit 1
./rewrite_census "$NAME.ll" "$NAME.census.ll" || exit 1
clang -O2 -c "$NAME.census.ll" -o "$NAME.census.o" || exit 1
ldc2 "$NAME.census.o" census_rt.o -of="$NAME.census" || exit 1

# The benchmarks read extra-files/ relative to druntime/benchmark.
cd "$HERE/../../../druntime/benchmark" || exit 1
"$OUT/$NAME.census" "$@" 2> "$OUT/$NAME.census.log" > /dev/null
rc=$?
grep '^CENSUS ' "$OUT/$NAME.census.log" > "$OUT/$NAME.census"'.txt'
cat "$OUT/$NAME.census.log"
exit $rc
