#!/bin/bash
# The compiler's runnable tests (compiler/test/runnable) under three collectors:
# the test programs are linked with the stock GC, with upstream symgc, or with
# ours, through the dmd_symgc.sh wrapper. The wrapper is found by the test
# runner through BUILD: generated/linux/symgc_up/64/dmd and symgc_ours/64/dmd
# are small scripts that set SYMGC_OBJ and call dmd_symgc.sh, and the other
# files of those directories are links to generated/linux/release/64 (the
# runner also looks for Phobos in phobos/generated/linux/$BUILD/64: a link to
# release there too).
#
# Usage: compiler_suite.sh WORKDIR [TARGET...]    (default target: runnable)
# Result: WORKDIR/<collector>/summary.txt and failed.txt
set -u
WORK=$1; shift
TARGETS=${*:-runnable}
REPO=${REPO:-/home/leonardo/Projetos/dmd}
cd "$REPO/compiler/test"
export HOST_DMD=$REPO/generated/linux/release/64/dmd

for gc in stock upstream ours; do
	case $gc in
		stock) build=release ;;
		upstream) build=symgc_up ;;
		ours) build=symgc_ours ;;
	esac

	out=$WORK/$gc
	mkdir -p "$out"
	start=$(date +%s)
	BUILD=$build RESULTS_DIR=$out/results ./run.d -f $TARGETS > "$out/run.txt" 2>&1
	rc=$?
	end=$(date +%s)
	# the runner ends with "FAILED targets:" and one "- target" line each
	sed -n '/^FAILED targets:/,$p' "$out/run.txt" | grep '^- ' | sed 's/^- //' | sort > "$out/failed.txt"
	echo "rc=$rc seconds=$((end - start)) failed=$(wc -l < "$out/failed.txt")" > "$out/summary.txt"
done

echo DONE > "$WORK/done.txt"
