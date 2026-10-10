#!/bin/bash
# RTS model (dmd) under stock, upstream symgc and oneday, idle and on an oversubscribed
# machine (N busy processes), interleaved. Usage: rts_tail_check.sh WORKDIR ONEDAY_SRC_DIR [ROUNDS=2] [BURNERS=16]
set -u
WORK=$1; ONE=$2; ROUNDS=${3:-2}; N=${4:-16}
REPO=/home/leonardo/Projetos/dmd
S=/tmp/claude-1000/-home-leonardo-Projetos-dmd/54cf3efb-9d4e-47f2-9106-d4918fdf2d46/scratchpad
B=$REPO/generated/linux/release/64
P=/home/leonardo/Projetos/phobos
F=$REPO/plans/bench/core_bench/aaa_sim.d
mkdir -p "$WORK/up" && git -C $REPO/symgc archive 4a4cb2b source | tar -x -C "$WORK/up"
cd $REPO
DF="-O -release -inline -fPIC -version=SymGC -version=Symgc_druntime_hooks -I$P -Idruntime/import"
LK="-defaultlib= -L-L$B $P/generated/linux/release/64/libphobos2.a -L-lpthread -L-lm -L-ldl -L-lz"
$B/dmd $DF -of=$WORK/stock $F $LK || exit 1
$B/dmd $DF -I$WORK/up/source -of=$WORK/upstream $F $(find $WORK/up/source -name '*.d') $LK || exit 1
$B/dmd $DF -version=Symgc_gctime -I$ONE -of=$WORK/oneday $F $(find $ONE -name '*.d') $LK || exit 1

run() { # label burners binary args...
	label=$1; nb=$2; shift 2
	flock $S/bench.lock bash -c '
		pids=""; for i in $(seq 1 '$nb'); do ( while :; do :; done ) & pids="$pids $!"; done
		timeout 300 "$@" 2>&1 | grep -m1 "^frame_p50" | cut -c1-150
		kill $pids 2>/dev/null; wait $pids 2>/dev/null' bash "$@" | sed "s/^/$label: /" >> "$WORK/results.txt"
}
: > "$WORK/results.txt"
A="rts 60 2048 6 0 100000"
for r in $(seq 1 "$ROUNDS"); do
	run "idle stock #$r" 0 $WORK/stock $A
	run "idle upstream #$r" 0 $WORK/upstream $A --DRT-gcopt=gc:sdcq
	run "idle oneday #$r" 0 $WORK/oneday $A --DRT-gcopt=gc:sdcq
	run "idle oneday nogc #$r" 0 $WORK/oneday rts 60 2048 6 1 100000 --DRT-gcopt=gc:sdcq
done
run "$N busy: stock" $N $WORK/stock $A
run "$N busy: upstream" $N $WORK/upstream $A --DRT-gcopt=gc:sdcq
run "$N busy: oneday" $N $WORK/oneday $A --DRT-gcopt=gc:sdcq
echo DONE >> "$WORK/results.txt"
