#!/bin/bash
# The card window test (cards_window.d) with the card barrier, under the three
# conditions that matter: the default window, a small one whose whole table is
# checked, and a machine with a small address space (as on a phone), where the
# collector has to settle for less than it asks for.
#
#   LDC=<ldc2 of the card-barrier build> ./cards_window.sh [workdir]
#
# LDC defaults to this repository's ldc-build-rt3 (with its ldc2.conf).
set -u
REPO=${REPO:-/home/leonardo/Projetos/dmd}
PHOBOS=${PHOBOS:-/home/leonardo/Projetos/phobos}
R=${R:-$REPO/ldc-build-rt3}
WORK=${1:-$(mktemp -d)}
LDC=${LDC:-"$R/bin/ldc2 -conf=$R/etc/ldc2.conf"}
H=$REPO/plans/bench/core_bench
mkdir -p "$WORK"
cd "$REPO" || exit 1

$LDC -I"$PHOBOS" -O3 -release -gc-card-marking -d-version=Symgc_cards -d-version=Symgc_druntime_hooks \
	-Isymgc/source -of="$WORK/cards_window" "$H/cards_window.d" $(find symgc/source -name '*.d') || exit 1

fail=0
run() {
	local label=$1; shift
	local out
	out=$("$@" 2>&1); local rc=$?
	echo "== $label"; echo "$out" | sed 's/^/   /'
	[ $rc -eq 0 ] || fail=1
}

run "default window" "$WORK/cards_window" --DRT-gcopt=gc:sdcq
run "4 GiB window, whole table checked" env SYMGC_HEAP_RESERVE_GIB=4 "$WORK/cards_window" checksum --DRT-gcopt=gc:sdcq
run "a window larger than the address space (falls back)" \
	bash -c 'ulimit -v 33554432; SYMGC_HEAP_RESERVE_GIB=256 exec "$0" --DRT-gcopt=gc:sdcq' "$WORK/cards_window"

[ $fail -eq 0 ] && echo "ALL OK" || echo "FAILED"
exit $fail
