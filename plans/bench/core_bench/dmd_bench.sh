#!/bin/bash
# The game benchmarks built with dmd (this repo's, -O -release -inline), so that
# every collector is measured with the compiler that has no card barrier:
#   stock     druntime's conservative GC (the oneday binary run without gcopt)
#   upstream  symgc at the commit before our patches (stop-the-world mark)
#   stw       oneday with SYMGC_CONCURRENT_MARK=0 (concurrent sweep only)
#   oneday    oneday with the kernel's dirty-page tracker (Linux 6.7+)
# plus, for the same session and machine state, LDC -O3 with the card barrier.
#
# Usage: dmd_bench.sh WORKDIR UPSTREAM_SRC_DIR
#   UPSTREAM_SRC_DIR: upstream symgc's `source` directory, e.g.
#     git -C symgc archive 4a4cb2b source | tar -x -C /some/dir   (then /some/dir/source)
# Result: WORKDIR/results.txt (one line per run), WORKDIR/<label>.txt (full output)
set -u
WORK=$1; UPSRC=$2
REPO=${REPO:-/home/leonardo/Projetos/dmd}
PHOBOS=${PHOBOS:-/home/leonardo/Projetos/phobos}
B=$REPO/generated/linux/release/64
H=$REPO/plans/bench/core_bench
R=$REPO/ldc-build-rt2
mkdir -p "$WORK"
cd "$REPO" || exit 1

DMDF="-O -release -inline -fPIC -version=SymGC -version=Symgc_druntime_hooks -I$PHOBOS -Idruntime/import"
LINK="-defaultlib= -L-L$B $PHOBOS/generated/linux/release/64/libphobos2.a -L-lpthread -L-lm -L-ldl -L-lz"
ONEDAY_SRC=$(find symgc/source -name '*.d')
UP_SRC=$(find "$UPSRC" -name '*.d')

build() { # name file extra-flags...
	local name=$1 file=$2; shift 2
	$B/dmd $DMDF -Isymgc/source "$@" -of="$WORK/${name}_oneday" "$file" $ONEDAY_SRC $LINK || exit 1
	$B/dmd $DMDF -I"$UPSRC" -of="$WORK/${name}_upstream" "$file" $UP_SRC $LINK || exit 1
	$R/bin/ldc2 -conf=$R/etc/ldc2.conf -O3 -release -d-version=Symgc_druntime_hooks \
		-d-version=Symgc_cards -gc-card-marking -Isymgc/source -I$PHOBOS \
		-of="$WORK/${name}_ldc" "$file" $ONEDAY_SRC || exit 1
}
build bh $H/bullet_hell.d
build bhs $H/bullet_hell_stress.d
build sim $H/aaa_sim.d -version=Symgc_gctime
$B/dmd -O -release -inline -version=SymGC -version=Symgc_druntime_hooks -Isymgc/source -Idruntime/import \
	-defaultlib= -L-L$B -L-ldruntime -of="$WORK/gcb" $H/gcb.d $H/perfcount.d $ONEDAY_SRC || exit 1

{
	echo "# $(date -Is) $(uname -r) governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor) epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)"
	echo "# dmd: $($B/dmd --version | head -1)"
} > "$WORK/results.txt"

run() { # label env-assignments(;-separated or -) binary args...
	local label=$1 envs=$2; shift 2
	local out=$WORK/$label.txt
	if [ "$envs" = - ]; then envs=; fi
	env $envs /usr/bin/time -f "maxrss_kib=%M" timeout 1200 "$@" > "$out" 2>&1
	local rc=$?
	echo "$label | $(grep -m1 '^frame_p50' "$out" | cut -c1-200)$(grep -m1 '^RESULT' "$out" | cut -c1-220) | $(grep -m1 '^maxrss' "$out") | rc=$rc" >> "$WORK/results.txt"
}
GC="--DRT-gcopt=gc:sdcq"

# 1. bullet-hell stress: 2 GiB, 100k bullets/s, +256 B per shot, 30 s
S2="30 2048 100000 0.05 256"
for rep in 1 2; do
	run stress2g.stock.$rep - "$WORK/bhs_oneday" $S2 0
	run stress2g.oneday.$rep - "$WORK/bhs_oneday" $S2 0 $GC
done
run stress2g.nogc.1 - "$WORK/bhs_oneday" $S2 1
run stress2g.upstream.1 - "$WORK/bhs_upstream" $S2 0 $GC
run stress2g.stw.1 SYMGC_CONCURRENT_MARK=0 "$WORK/bhs_oneday" $S2 0 $GC
run stress2g.ldc_cards.1 - "$WORK/bhs_ldc" $S2 0 $GC

# 2. the same at 8 GiB
S8="30 8192 100000 0.05 256"
run stress8g.stock.1 - "$WORK/bhs_oneday" $S8 0
run stress8g.oneday.1 - "$WORK/bhs_oneday" $S8 0 $GC
run stress8g.stw.1 SYMGC_CONCURRENT_MARK=0 "$WORK/bhs_oneday" $S8 0 $GC
run stress8g.upstream.1 - "$WORK/bhs_upstream" $S8 0 $GC
run stress8g.ldc_cards.1 - "$WORK/bhs_ldc" $S8 0 $GC

# 3. bullet hell (heavy game cost): 2 GiB level, 40k bullets/s, 30 s
H2="30 2048 40000"
run bh2g.stock.1 - "$WORK/bh_oneday" $H2
run bh2g.oneday.1 - "$WORK/bh_oneday" $H2 $GC
run bh2g.stw.1 SYMGC_CONCURRENT_MARK=0 "$WORK/bh_oneday" $H2 $GC
run bh2g.upstream.1 - "$WORK/bh_upstream" $H2 $GC
run bh2g.ldc_cards.1 - "$WORK/bh_ldc" $H2 $GC

# 4. game models: "mode seconds assetMiB jobs nogc population"
for rep in 1 2; do
	C="city 60 2048 6 0 500000"
	run city500k.stock.$rep - "$WORK/sim_oneday" $C
	run city500k.oneday.$rep - "$WORK/sim_oneday" $C $GC
	run city500k.upstream.$rep - "$WORK/sim_upstream" $C $GC
done
run city500k.stw.1 SYMGC_CONCURRENT_MARK=0 "$WORK/sim_oneday" city 60 2048 6 0 500000 $GC
run city500k.ldc_cards.1 - "$WORK/sim_ldc" city 60 2048 6 0 500000 $GC
for s in "city100k city 60 2048 6 0 100000" "rts rts 60 2048 6 0 100000" "openworld openworld 60 2048 6 0 100000"; do
	set -- $s; name=$1; shift
	run $name.stock.1 - "$WORK/sim_oneday" "$@"
	run $name.oneday.1 - "$WORK/sim_oneday" "$@" $GC
	run $name.stw.1 SYMGC_CONCURRENT_MARK=0 "$WORK/sim_oneday" "$@" $GC
	run $name.upstream.1 - "$WORK/sim_upstream" "$@" $GC
done

# 5. allocator throughput and fragmentation (gcb), stock against oneday
for c in "alloc1t alloc 1 8000000" "alloc8t alloc 8 4000000" "frag frag 3000000 100000"; do
	set -- $c; name=$1; shift
	for rep in 1 2 3; do
		run gcb_$name.stock.$rep - "$WORK/gcb" "$@"
		run gcb_$name.oneday.$rep - "$WORK/gcb" "$@" $GC
	done
done
echo DONE >> "$WORK/results.txt"
