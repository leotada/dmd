#!/bin/bash
# Phobos unit tests under three collectors, one module at a time:
#   stock   the GC that comes with druntime
#   upstream symgc at the commit before our patches (stop the world)
#   ours    the latency-p3 branch (concurrent mark and sweep, kernel dirty pages)
#
# Usage: phobos_suite.sh WORKDIR UPSTREAM_OBJ OURS_OBJ [JOBS=6] [MODULE...]
#   WORKDIR       where objects, binaries and results go
#   UPSTREAM_OBJ  symgc compiled with dmd -c, version=SymGC,Symgc_druntime_hooks
#   OURS_OBJ      the same for our branch
# Without MODULEs, every std module that has unit tests is run.
# Result: WORKDIR/results.txt, one line per module and collector:
#   module collector rc tests seconds peak_MiB
set -u
WORK=$1; UP=$2; OURS=$3; JOBS=${4:-6}; shift 4 || true
REPO=${REPO:-/home/leonardo/Projetos/dmd}
PHOBOS=${PHOBOS:-/home/leonardo/Projetos/phobos}
B=$REPO/generated/linux/release/64
mkdir -p "$WORK/obj" "$WORK/bin" "$WORK/log"
: > "$WORK/results.txt"

one() {
	m=$1                       # e.g. std/array
	n=$(echo "$m" | tr / .)
	src=$PHOBOS/$m.d
	obj=$WORK/obj/$n.o
	log=$WORK/log/$n.build.txt
	if ! $B/dmd -c -unittest -version=StdUnittest -main -g -debug -w \
		-preview=dip1000 -preview=dtorfields -preview=fieldwise \
		-version=SymGC -version=Symgc_druntime_hooks \
		-I$PHOBOS -I$REPO/symgc/source -I$REPO/druntime/import \
		-of="$obj" "$src" > "$log" 2>&1; then
		echo "$n all BUILD-FAIL 0 0 0" >> "$WORK/results.txt"
		return
	fi

	for gc in stock upstream ours; do
		extra=""; opt=""
		[ $gc = upstream ] && extra=$UP && opt="--DRT-gcopt=gc:sdcq"
		[ $gc = ours ] && extra=$OURS && opt="--DRT-gcopt=gc:sdcq"
		bin=$WORK/bin/$n.$gc
		if ! $B/dmd -of="$bin" "$obj" $extra -defaultlib= -L-L$B -L-ldruntime \
			-L$PHOBOS/generated/linux/release/64/libphobos2.a \
			-L-lpthread -L-lm -L-ldl -L-lz > "$WORK/log/$n.$gc.link.txt" 2>&1; then
			echo "$n $gc LINK-FAIL 0 0 0" >> "$WORK/results.txt"
			continue
		fi

		out=$WORK/log/$n.$gc.run.txt
		/usr/bin/time -f "%e %M" -o "$WORK/log/$n.$gc.mem" timeout 900 "$bin" $opt > "$out" 2>&1
		rc=$?
		tests=$(grep -m1 -oE '[0-9]+ unittests? (passed|failed)' "$out" | cut -d' ' -f1)
		read -r secs kib < <(tail -1 "$WORK/log/$n.$gc.mem" 2>/dev/null || echo "0 0")
		printf '%s %s %s %s %s %s\n' "$n" "$gc" "$rc" "${tests:-0}" "${secs:-0}" "$(( ${kib:-0} / 1024 ))" >> "$WORK/results.txt"
		rm -f "$bin"
	done
}
export -f one
export WORK UP OURS REPO PHOBOS B

if [ $# -gt 0 ]; then
	mods=("$@")
else
	mods=()
	while IFS= read -r f; do
		rel=${f#$PHOBOS/}; rel=${rel%.d}
		grep -q "unittest" "$f" && mods+=("$rel")
	done < <(find "$PHOBOS/std" -name '*.d' | sort)
fi

printf '%s\n' "${mods[@]}" | xargs -P "$JOBS" -I{} bash -c 'one {}'
echo DONE >> "$WORK/results.txt"
