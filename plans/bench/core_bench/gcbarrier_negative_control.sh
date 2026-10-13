#!/bin/bash
# Negative control for DMD's clustering of barriers (backend/gcbarrier.d, clusterList).
#
# Builds a DMD in which a cluster of stores forgets its barrier
# (-version=GCBarrierBrokenCluster), then checks that the tests notice:
#   - gcbarrier_codegen_check.sh must FAIL (the clustered functions have no card store),
#   - mark_race_glue must FAIL (it reports violations and exits non-zero).
# A passing test suite proves little if it also passes a compiler that loses objects.
#
#   gcbarrier_negative_control.sh [SECONDS=15]
#
# The normal DMD (generated/.../dmd) is rebuilt at the end. Needs the instrumented druntime and
# Phobos of `dmd_gcbarrier.sh libs`. Exit status is 0 only if both checks failed on the broken compiler.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-/home/leonardo/Projetos/dmd}
secs=${1:-15}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
GOOD=$REPO/generated/linux/release/64/dmd

# build.d tracks sources by timestamp, not by flags: touch the pass so it is compiled again
touch "$REPO/compiler/src/dmd/backend/gcbarrier.d"
"$REPO/compiler/src/build.d" dmd DFLAGS="-version=GCBarrierBrokenCluster" >/dev/null || { echo "broken DMD does not build"; exit 2; }
cp "$GOOD" "$WORK/dmd.broken"
touch "$REPO/compiler/src/dmd/backend/gcbarrier.d"
"$REPO/compiler/src/build.d" dmd >/dev/null || { echo "normal DMD does not rebuild"; exit 2; }

rc=0
if DMD="$WORK/dmd.broken" "$HERE/gcbarrier_codegen_check.sh" >/dev/null 2>&1; then
	echo "NOT DETECTED  codegen check passes on a compiler whose clusters have no barrier"; rc=1
else
	echo "detected      codegen check fails on the broken compiler"
fi

DMD="$WORK/dmd.broken" "$HERE/dmd_gcbarrier.sh" build "$WORK/glue" "$HERE/mark_race_glue.d" >/dev/null 2>&1 || { echo "mark_race_glue does not build"; exit 2; }
out=$(timeout 300 "$WORK/glue" "$secs" --DRT-gcopt=gc:sdcq 2>&1); grc=$?
if [ $grc -ne 0 ]; then
	echo "detected      mark_race_glue fails on the broken compiler: $(echo "$out" | grep -o 'violations=[0-9]*' | head -1)"
else
	echo "NOT DETECTED  mark_race_glue passes on a compiler whose clusters have no barrier"; rc=1
fi
exit $rc
