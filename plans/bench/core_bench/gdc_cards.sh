#!/bin/bash
# Build a test with GDC, the barrier plugin (gdc-gcbarrier/), the instrumented libgphobos and symgc in card mode.
#
#   gdc_cards.sh OUT FILE.d [extra gdc flags]
#
# Needs: GCC built from source with D and plugin support (gdc-gcbarrier/README.md), the plugin built, and
# GCC's libphobos rebuilt with the plugin:
#   make -C $GCC_BUILD/x86_64-pc-linux-gnu/libphobos clean
#   make -C $GCC_BUILD/x86_64-pc-linux-gnu/libphobos -j GDCFLAGS="-g -O2 -fplugin=$REPO/gdc-gcbarrier/gcbarrier.so"
# (the installed libphobos is left alone: this script links the one in the build tree, statically).
set -u
REPO=${REPO:-/home/leonardo/Projetos/dmd}
GCC_PREFIX=${GCC_PREFIX:-$HOME/opt/gcc-15.3}
GCC_BUILD=${GCC_BUILD:-$HOME/Projetos/gcc15/build}
GDC=${GDC:-$GCC_PREFIX/bin/gdc}
LIBS=$GCC_BUILD/x86_64-pc-linux-gnu/libphobos/src/.libs
SYMGC=${SYMGC:-$REPO/symgc/source}

[ $# -ge 2 ] || { sed -n 2,6p "$0"; exit 2; }
out=$1; file=$2; shift 2
$GDC -O2 -fplugin="$REPO/gdc-gcbarrier/gcbarrier.so" \
	-fversion=Symgc_cards -fversion=Symgc_druntime_hooks -fversion=SymGC \
	-I"$SYMGC" -I"$REPO/plans/bench/core_bench" "$@" -o "$out" "$file" $(find "$SYMGC" -name '*.d') \
	-static-libphobos -L"$LIBS"
