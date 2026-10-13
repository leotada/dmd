#!/bin/bash
# The GC write barrier under DMD, LDC and GDC: the same programs, built with each compiler's barrier and the
# same collector (symgc in card mode), run side by side.
#
#   conformance.sh [SECONDS=15] [CITY_SECONDS=60] [compilers: dmd ldc gdc]
#
# 1. the correctness battery (mark_race, mark_race_glue, finalizer_order, thread_exit_race, cards_precision,
#    phobos_stress): every line must say OK;
# 2. the 500k-citizen city (aaa_sim.d, six job threads, 2 GiB of live data): frames over 16 ms must be 0.
#
# Toolchains (see each script): dmd_gcbarrier.sh (the project's DMD + instrumented druntime and Phobos),
# ldc-build-rt3 (the LDC with the card pass), gdc_cards.sh (GCC 15.3 + gdc-gcbarrier/gcbarrier.so).
# Linux x86-64 only. Exit status 0 only if every check passed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-/home/leonardo/Projetos/dmd}
PHOBOS=${PHOBOS:-/home/leonardo/Projetos/phobos}
R=${R:-$REPO/ldc-build-rt3}
secs=${1:-15}
city=${2:-60}
shift 2 2>/dev/null
compilers=${*:-dmd ldc gdc}
WORK=${WORK:-$(mktemp -d)}
mkdir -p "$WORK"
SYMGC=$REPO/symgc/source
fail=0

build() { # compiler out file
	local c=$1 out=$2 file=$3
	case $c in
	dmd) "$HERE/dmd_gcbarrier.sh" build "$out" "$file" ;;
	ldc) "$R/bin/ldc2" -conf="$R/etc/ldc2.conf" -I"$PHOBOS" -O3 -release -preview=gcbarrier \
		-d-version=Symgc_cards -d-version=Symgc_druntime_hooks -I"$SYMGC" -I"$HERE" -I"$REPO/symgc/bench" \
		-of="$out" "$file" $(find "$SYMGC" -name '*.d') ;;
	gdc) "$HERE/gdc_cards.sh" "$out" "$file" -I"$REPO/symgc/bench" ;;
	esac
}

run_test() { # compiler name file args...
	local c=$1 name=$2 file=$3; shift 3
	local bin=$WORK/${c}_$name
	if ! build "$c" "$bin" "$file" >"$bin.build" 2>&1; then
		printf 'FAIL  %-4s %-16s does not build (%s)\n' "$c" "$name" "$bin.build"; fail=1; return
	fi
	local out rc
	out=$(timeout 900 "$bin" "$@" --DRT-gcopt=gc:sdcq 2>&1); rc=$?
	if [ $rc -eq 0 ] && echo "$out" | grep -q "OK"; then
		printf 'ok    %-4s %-16s %s\n' "$c" "$name" "$(echo "$out" | grep OK | tail -1 | cut -c1-90)"
	else
		printf 'FAIL  %-4s %-16s (exit %d) %s\n' "$c" "$name" "$rc" "$(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-110)"; fail=1
	fi
}

for c in $compilers; do
	echo "== $c: correctness"
	run_test "$c" mark_race        "$HERE/mark_race.d" "$secs"
	run_test "$c" mark_race_glue   "$HERE/mark_race_glue.d" "$secs"
	run_test "$c" finalizer_order  "$HERE/finalizer_order.d" "$secs"
	run_test "$c" thread_exit_race "$HERE/thread_exit_race.d"
	run_test "$c" cards_precision  "$HERE/cards_precision.d"
	run_test "$c" phobos_stress    "$HERE/phobos_stress.d" "$secs"
done

echo "== the 500k city, $city s (frames over 16 ms must be 0)"
for c in $compilers; do
	bin=$WORK/${c}_city
	if ! build "$c" "$bin" "$REPO/symgc/bench/aaa_sim.d" >"$bin.build" 2>&1; then
		printf 'FAIL  %-4s city: does not build (%s)\n' "$c" "$bin.build"; fail=1; continue
	fi
	line=$(timeout 900 "$bin" city "$city" 2048 6 0 500000 --DRT-gcopt=gc:sdcq 2>&1 | grep -E "frame_p50|over16" | tail -1)
	over=$(echo "$line" | grep -o 'over16ms=[0-9]*' | head -1 | cut -d= -f2)
	if [ "${over:-x}" = 0 ]; then printf 'ok    %-4s %s\n' "$c" "$(echo "$line" | cut -c1-140)"
	else printf 'FAIL  %-4s %s\n' "$c" "${line:-no result line}"; fail=1; fi
done

[ $fail -eq 0 ] && echo "ALL OK" || echo "FAILED"
exit $fail
