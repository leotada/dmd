#!/bin/bash
# Head-to-head comparison of trigger-rally-d:
#   Stock GC (system LDC, standard druntime conservative GC)
#   vs
#   Oneday (LDC card-marking barrier + hybrid TLS Immix / dirty-page symgc)
#
# Runs in an isolated Xvfb display so compositor sync throttling does not bias frame pacing.
set -euo pipefail

BENCH_SECS=${1:-15}
TRIGGER_DIR=/home/leonardo/Projetos/trigger-rally-d
BIN_DIR=$TRIGGER_DIR/bin
OUT_DIR=/home/leonardo/Projetos/dmd/plans/bench/core_bench/results/trigger_rally
mkdir -p "$OUT_DIR"

XVFB_PORT=99
rm -f "/tmp/.X${XVFB_PORT}-lock" "/tmp/.X11-unix/X${XVFB_PORT}" 2>/dev/null || true
echo "=== Starting Xvfb on :$XVFB_PORT ==="
Xvfb :$XVFB_PORT -screen 0 1024x768x24 &
XVFB_PID=$!
trap 'kill $XVFB_PID 2>/dev/null || true; rm -f "/tmp/.X${XVFB_PORT}-lock" "/tmp/.X11-unix/X${XVFB_PORT}" 2>/dev/null || true' EXIT
sleep 1

export DISPLAY=:$XVFB_PORT
export TRIGGER_BENCH_SECS=$BENCH_SECS
export LP_NUM_THREADS=4

echo ""
echo "=== Running Stock GC Benchmark ($BENCH_SECS s) ==="
$BIN_DIR/trigger-rally-stock > "$OUT_DIR/stock.log" 2>&1 || true

echo ""
echo "=== Running Oneday (STW Mark: SYMGC_CONCURRENT_MARK=0) Benchmark ($BENCH_SECS s) ==="
SYMGC_CONCURRENT_MARK=0 $BIN_DIR/trigger-rally-oneday > "$OUT_DIR/oneday_stw.log" 2>&1 || true

echo ""
echo "=== Running Oneday (Concurrent Mark: SYMGC_CONCURRENT_MARK=1) Benchmark ($BENCH_SECS s) ==="
SYMGC_CONCURRENT_MARK=1 $BIN_DIR/trigger-rally-oneday > "$OUT_DIR/oneday_concurrent.log" 2>&1 || true

echo ""
echo "==================== COMPARISON SUMMARY ===================="
echo "--- Stock GC ---"
grep -A 25 "BENCHMARK RESULTS" "$OUT_DIR/stock.log" || cat "$OUT_DIR/stock.log"
echo ""
echo "--- Oneday (STW Mark) ---"
grep -A 25 "BENCHMARK RESULTS" "$OUT_DIR/oneday_stw.log" || cat "$OUT_DIR/oneday_stw.log"
echo ""
echo "--- Oneday (Concurrent Mark) ---"
grep -A 25 "BENCHMARK RESULTS" "$OUT_DIR/oneday_concurrent.log" || cat "$OUT_DIR/oneday_concurrent.log"
echo "============================================================"
