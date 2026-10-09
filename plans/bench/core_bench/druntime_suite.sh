#!/bin/bash
# The druntime unit tests under three collectors: stock, upstream symgc, ours.
# The druntime Makefile builds one test_runner from all the sources and runs it
# once per module; this does the same, building the runner three times (the
# only difference is the symgc object on the command line).
#
# Usage: druntime_suite.sh WORKDIR UPSTREAM_OBJ OURS_OBJ
# Result: WORKDIR/results.txt, one line per module and collector:
#   module collector rc tests seconds peak_MiB
set -u
WORK=$1; UP=$2; OURS=$3
REPO=${REPO:-/home/leonardo/Projetos/dmd}
B=$REPO/generated/linux/release/64
DR=$REPO/druntime
mkdir -p "$WORK/bin" "$WORK/log"
: > "$WORK/results.txt"
cd "$DR"

# the sources as the Makefile lists them (it writes them with backslashes)
SRCS=$(grep -o 'src\\[^ ]*\.d' mak/SRCS | tr '\\' / | grep -v __builtins_msvc)
FLAGS="-conf= -fPIC -m64 -Isrc -Iimport -w -de -preview=dip1000 -preview=fieldwise -preview=dtorfields -g -debug -version=CoreUnittest -unittest -checkaction=context"

build() {
	gc=$1; extra=$2
	mkdir -p "$WORK/obj.$gc"
	$B/dmd $FLAGS -od="$WORK/obj.$gc" -of="$WORK/bin/test_runner.$gc" src/test_runner.d $SRCS \
		$B/errno_c.o $B/threadasm.o $B/valgrind.o $extra \
		-defaultlib= -L-lpthread -L-lm > "$WORK/log/build.$gc.txt" 2>&1
}

RTO=$REPO/plans/bench/core_bench/rt_options_sdcq.d
GCS=${GCS:-"stock upstream ours"}   # which collectors to build and run
for gc in $GCS; do
	case $gc in
		stock) build stock "" & ;;
		upstream) build upstream "$UP $RTO" & ;;
		ours) build ours "$OURS $RTO" & ;;
	esac
done
wait

for gc in $GCS; do
	if [ ! -x "$WORK/bin/test_runner.$gc" ]; then
		echo "runner-$gc BUILD-FAIL 0 0 0 0" >> "$WORK/results.txt"
		tail -3 "$WORK/log/build.$gc.txt"
		continue
	fi

	for src in $SRCS; do
		m=${src#src/}; m=${m%.d}; m=${m//\//.}
		[ "$m" = test_runner ] && continue
		out=$WORK/log/$m.$gc.txt
		/usr/bin/time -f "%e %M" -o "$WORK/log/$m.$gc.mem" timeout 300 "$WORK/bin/test_runner.$gc" "$m" > "$out" 2>&1
		rc=$?
		# the runner prints one line per module: "<time> PASS <config> <module>"
		tests=$(grep -c ' PASS ' "$out")
		read -r secs kib < <(tail -1 "$WORK/log/$m.$gc.mem" 2>/dev/null || echo "0 0")
		printf '%s %s %s %s %s %s\n' "$m" "$gc" "$rc" "${tests:-0}" "${secs:-0}" "$(( ${kib:-0} / 1024 ))" >> "$WORK/results.txt"
	done
done
echo DONE >> "$WORK/results.txt"
