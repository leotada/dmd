#!/bin/sh
# vibe.d server baseline (RFC Phase 0.1 real workload).
#
#   ./run_vibe.sh [-t "dmd ldc"] [-r reps] [-l live-MiB] [-c clients] [-n requests-per-client] [-i idle-connections] [-o outdir]
#
# Builds plans/bench/vibe_server with dub for each compiler (offline, from the dub cache),
# starts the server, drives it with loadgen and records server wall/user/sys/RSS, GC
# collections, total GC ms and max pause, and the clients' p50/p99/p99.9/max latency.
# Medians over the repetitions are written to <outdir>/vibe.csv.
set -u
TOOLCHAINS="dmd ldc"; REPS=3; LIVE=256; CLIENTS=8; REQS=5000; IDLE=2000
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/build
while getopts "t:r:l:c:n:i:o:" opt; do
    case $opt in
        t) TOOLCHAINS=$OPTARG ;; r) REPS=$OPTARG ;; l) LIVE=$OPTARG ;; c) CLIENTS=$OPTARG ;;
        n) REQS=$OPTARG ;; i) IDLE=$OPTARG ;; o) OUT=$OPTARG ;;
        *) exit 2 ;;
    esac
done
mkdir -p "$OUT/bin" "$OUT/logs"
cd "$HERE/vibe_server" || exit 1
dmd -O -release -of="$OUT/bin/loadgen" loadgen.d >/dev/null || exit 1
ulimit -n 65536 2>/dev/null

median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }

echo "toolchain,wall_s,user_s,sys_s,rss_kib,gcs,gc_ms,maxpause_ms,p50_us,p99_us,p999_us,max_us,req_per_s" > "$OUT/vibe.csv"
for tc in $TOOLCHAINS; do
    case $tc in
        dmd) comp=dmd ;;
        ldc) comp=ldc2 ;;
        *) echo "unknown toolchain $tc"; continue ;;
    esac
    dub build --build=release --compiler=$comp --cache=local --skip-registry=all >"$OUT/logs/vibe.$tc.build" 2>&1 \
        || { echo "build failed for $tc (see $OUT/logs/vibe.$tc.build)"; continue; }
    cp gcbench_vibe "$OUT/bin/gcbench_vibe.$tc"
    rm -f "$OUT/logs/vibe.$tc.runs"
    port=8200
    for i in $(seq "$REPS"); do
        port=$((port + 1))
        log=$OUT/logs/vibe.$tc.$i
        GCB_PORT=$port GCB_LIVE_MIB=$LIVE /usr/bin/time -f "%e %U %S %M" -o "$log.time" \
            "$OUT/bin/gcbench_vibe.$tc" >"$log.server" 2>&1 &
        sleep $((LIVE / 100 + 2))
        timeout 600 "$OUT/bin/loadgen" $port "$CLIENTS" "$REQS" "$IDLE" >"$log.client" 2>&1
        wait
        read -r w u s m < "$log.time"
        gcs=$(awk -F: '/Number of collections/ {gsub(/ /,"",$2); print $2}' "$log.server" | tail -n 1)
        gcms=$(awk -F: '/Grand total GC time/ {split($2,a," "); print a[1]}' "$log.server" | tail -n 1)
        maxp=$(awk -F: '/Max Pause Time/ {split($2,a," "); print a[1]}' "$log.server" | tail -n 1)
        lat=$(sed -n 's/.*p50=\([0-9]*\) us *p99=\([0-9]*\) us *p99.9=\([0-9]*\) us *max=\([0-9]*\) us.*/\1,\2,\3,\4/p' "$log.client" | tail -n 1)
        rps=$(sed -n 's/.*(\([0-9]*\) req\/s).*/\1/p' "$log.client" | tail -n 1)
        echo "$tc,$w,$u,$s,$m,$gcs,$gcms,$maxp,$lat,$rps" >> "$OUT/logs/vibe.$tc.runs"
    done
    # median of each column over the repetitions
    row="$tc"
    for col in 2 3 4 5 6 7 8 9 10 11 12 13; do
        row="$row,$(cut -d, -f$col "$OUT/logs/vibe.$tc.runs" | median)"
    done
    echo "$row" >> "$OUT/vibe.csv"
    rm -f "$OUT/logs/vibe.$tc.runs"
done
column -s, -t "$OUT/vibe.csv"
