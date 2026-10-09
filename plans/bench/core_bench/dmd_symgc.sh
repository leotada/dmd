#!/bin/bash
# A dmd that links symgc into the programs it builds, for running the compiler
# test suite with another collector: set DMD to this script and SYMGC_OBJ to the
# symgc object (dmd -c -version=SymGC -version=Symgc_druntime_hooks).
# Compile-only and library invocations are passed through unchanged.
REAL=${REAL_DMD:-/home/leonardo/Projetos/dmd/generated/linux/release/64/dmd}
RTO=${RT_OPTIONS_SRC:-/home/leonardo/Projetos/dmd/plans/bench/core_bench/rt_options_sdcq.d}

for a in "$@"; do
	case "$a" in
		-c|-lib|-o-|-shared|-Xf*|-E|-H|-Hf*|-D|-Df*|-i|-version=NoMain) exec "$REAL" "$@" ;;
	esac
done

[ -n "${SYMGC_LOG:-}" ] && echo "symgc: $*" >> "$SYMGC_LOG"
exec "$REAL" "$SYMGC_OBJ" "$RTO" "$@"
