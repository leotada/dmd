#!/bin/bash
# Build and run a D program with DMD's GC write barrier (-preview=gcbarrier) and
# the fork's symgc in card mode.
#
#   dmd_gcbarrier.sh build OUT FILE.d [extra dmd flags]    compile FILE.d (+ symgc) to OUT
#   dmd_gcbarrier.sh libs                                  (re)build the instrumented druntime and Phobos
#
# The barrier has to be in everything that stores pointers into the GC heap,
# so druntime and Phobos are built with the flag too, into generated/gcb (the
# normal ones are left alone). Programs that use no Phobos still link it
# (`libs` builds both); programs built without the flag lose memory under a
# concurrent mark: mark_race shows it.
set -u
REPO=${REPO:-/home/leonardo/Projetos/dmd}
PHOBOS=${PHOBOS:-/home/leonardo/Projetos/phobos}
DMD=${DMD:-$REPO/generated/linux/release/64/dmd}
GCB_DRT=$REPO/generated/gcb/linux/release/64
GCB_PHO=$PHOBOS/generated/gcb/linux/release/64

libs() {
	make -C "$REPO/druntime" -j"$(nproc)" ROOT_OF_THEM_ALL=../generated/gcb OBJDIR=obj/gcb \
		DFLAGS="-conf= -Isrc -Iimport -w -de -preview=dip1000 -preview=fieldwise -m64 -fPIC -preview=dtorfields -O -release -inline -preview=gcbarrier" \
		../generated/gcb/linux/release/64/libdruntime.a || return 1
	make -C "$PHOBOS" -j"$(nproc)" BUILD=release ROOT_OF_THEM_ALL=generated/gcb DMDEXTRAFLAGS=-preview=gcbarrier \
		generated/gcb/linux/release/64/libphobos2.a
}

build() {
	local out=$1 file=$2; shift 2
	$DMD -conf= -I"$REPO/druntime/import" -I"$PHOBOS" -fPIC -O -release -inline -preview=gcbarrier \
		-version=Symgc_druntime_hooks -version=Symgc_cards -version=Symgc_druntime_cards \
		-I"$REPO/symgc/source" -defaultlib= "$@" \
		-of="$out" "$file" $(find "$REPO/symgc/source" -name '*.d') \
		"$GCB_PHO/libphobos2.a" -L-L"$GCB_DRT" -L-ldruntime -L-lpthread -L-lm -L-ldl -L-lz
}

case "${1:-}" in
	libs) libs ;;
	build) shift; build "$@" ;;
	*) sed -n 2,12p "$0"; exit 2 ;;
esac
