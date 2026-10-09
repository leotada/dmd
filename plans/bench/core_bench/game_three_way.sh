#!/bin/bash
# The game models (aaa_sim) under three collectors, built by the same compiler
# (this repo's dmd, -O -release -inline) so that only the GC differs:
#   stock     the GC of druntime
#   upstream  symgc at the commit before our patches (stop the world)
#   oneday    our branch, with the kernel's dirty page tracking (no card barrier,
#             which needs LDC)
# And, with LDC -O3, stock (the system's LDC) against oneday with the card barrier.
#
# Usage: game_three_way.sh WORKDIR UPSTREAM_SRC_DIR [REPS=3]
#   UPSTREAM_SRC_DIR: the upstream symgc's `source` directory
# Result: WORKDIR/results.txt, WORKDIR/<scenario>.<build>.<rep>.txt
set -u
WORK=$1; UPSRC=$2; REPS=${3:-3}
REPO=${REPO:-/home/leonardo/Projetos/dmd}
B=$REPO/generated/linux/release/64
PHOBOS=/home/leonardo/Projetos/phobos
F=$REPO/plans/bench/core_bench/aaa_sim.d
R=$REPO/ldc-build-rt2
mkdir -p "$WORK"
cd "$REPO"

DMDF="-O -release -inline -fPIC -version=SymGC -version=Symgc_druntime_hooks -I$PHOBOS -Idruntime/import"
LINK="-defaultlib= -L-L$B $PHOBOS/generated/linux/release/64/libphobos2.a -L-lpthread -L-lm -L-ldl -L-lz"

# dmd compiles the symgc sources with the program, as the user guide does
$B/dmd $DMDF -of="$WORK/dmd_stock" $F $LINK || exit 1
$B/dmd $DMDF -I"$UPSRC" -of="$WORK/dmd_upstream" $F $(find "$UPSRC" -name '*.d') $LINK || exit 1
$B/dmd $DMDF -version=Symgc_gctime -Isymgc/source -of="$WORK/dmd_oneday" $F $(find symgc/source -name '*.d') $LINK || exit 1

# LDC: the system's LDC for stock, the one in ldc-build-rt2 for oneday with cards
ldc2 -O3 -release -of="$WORK/ldc_stock" $F || exit 1
$R/bin/ldc2 -conf=$R/etc/ldc2.conf -O3 -release -d-version=Symgc_druntime_hooks \
	-d-version=Symgc_cards -d-version=Symgc_gctime -gc-card-marking -Isymgc/source \
	-I$PHOBOS -of="$WORK/ldc_oneday" $F $(find symgc/source -name '*.d') || exit 1

: > "$WORK/results.txt"
run() {
	label=$1; shift
	out=$WORK/$label.txt
	timeout 900 "$@" > "$out" 2>&1
	echo "== $label: $(grep -m1 '^frame_p50' "$out" | cut -c1-200) | $(grep -m1 '^rss' "$out")" >> "$WORK/results.txt"
}

# scenario: "name mode seconds assetMiB jobs nogc population"
scenarios=("city500k city 60 2048 6 0 500000" "city100k city 60 2048 6 0 100000" "rts rts 60 2048 6 0 100000" "openworld openworld 60 2048 6 0 100000")
for rep in $(seq 1 "$REPS"); do
	for s in "${scenarios[@]}"; do
		set -- $s
		name=$1; shift
		# only the city at 500k is repeated; the others run once
		[ "$name" != city500k ] && [ "$rep" != 1 ] && continue
		run "$name.dmd_stock.$rep" "$WORK/dmd_stock" "$@"
		run "$name.dmd_upstream.$rep" "$WORK/dmd_upstream" "$@" --DRT-gcopt=gc:sdcq
		run "$name.dmd_oneday.$rep" "$WORK/dmd_oneday" "$@" --DRT-gcopt=gc:sdcq
		run "$name.ldc_stock.$rep" "$WORK/ldc_stock" "$@"
		run "$name.ldc_oneday.$rep" "$WORK/ldc_oneday" "$@" --DRT-gcopt=gc:sdcq
	done
done
echo DONE >> "$WORK/results.txt"
