#!/bin/bash
# Head-to-head comparison of trigger-rally-d on Native Display with GPU Hardware Acceleration:
#   Stock GC (system LDC, standard druntime conservative GC)
#   vs
#   Oneday (LDC card-marking barrier + symgc STW mark)
#   vs
#   Oneday (LDC card-marking barrier + symgc Concurrent mark)
#
# Runs on native DISPLAY=:1 with AMD Radeon RX 6600 hardware acceleration.
set -euo pipefail

BENCH_SECS=${1:-15}
TRIGGER_DIR=/home/leonardo/Projetos/trigger-rally-d
BIN_DIR=$TRIGGER_DIR/bin
OUT_DIR=/home/leonardo/Projetos/dmd/plans/bench/core_bench/results/trigger_rally_native
mkdir -p "$OUT_DIR"

export DISPLAY=${DISPLAY:-:1}
export TRIGGER_BENCH_SECS=$BENCH_SECS

echo "=========================================================================="
echo "Trigger Rally Native GPU Benchmark ($BENCH_SECS s per run)"
echo "Display: $DISPLAY | GPU: AMD Radeon RX 6600 (radeonsi / Mesa 24.3.3)"
echo "CPU: AMD Ryzen 7 3800X (8 physical cores / 16 threads)"
echo "=========================================================================="

echo ""
echo "=== Running Stock GC Benchmark ($BENCH_SECS s) ==="
$BIN_DIR/trigger-rally-stock > "$OUT_DIR/stock_native.log" 2>&1 || true

echo ""
echo "=== Running Oneday (STW Mark: SYMGC_CONCURRENT_MARK=0) Benchmark ($BENCH_SECS s) ==="
SYMGC_CONCURRENT_MARK=0 $BIN_DIR/trigger-rally-oneday > "$OUT_DIR/oneday_stw_native.log" 2>&1 || true

echo ""
echo "=== Running Oneday (Concurrent Mark: SYMGC_CONCURRENT_MARK=1, THREADS=2) Benchmark ($BENCH_SECS s) ==="
SYMGC_CONCURRENT_MARK=1 SYMGC_MARK_THREADS=2 SYMGC_MARK_NICE=10 $BIN_DIR/trigger-rally-oneday > "$OUT_DIR/oneday_concurrent_native.log" 2>&1 || true

echo ""
echo "==================== COMPARISON SUMMARY ===================="
echo "--- Stock GC (Native GPU) ---"
grep -A 25 "BENCHMARK RESULTS" "$OUT_DIR/stock_native.log" || cat "$OUT_DIR/stock_native.log"
echo ""
echo "--- Oneday STW Mark (Native GPU) ---"
grep -A 25 "BENCHMARK RESULTS" "$OUT_DIR/oneday_stw_native.log" || cat "$OUT_DIR/oneday_stw_native.log"
echo ""
echo "--- Oneday Concurrent Mark (Native GPU) ---"
grep -A 25 "BENCHMARK RESULTS" "$OUT_DIR/oneday_concurrent_native.log" || cat "$OUT_DIR/oneday_concurrent_native.log"
echo "============================================================"
