#!/bin/bash
# Head-to-head comparison of Bullet Hell GC workload:
#   Stock GC (system LDC conservative GC)
#   vs
#   Oneday STW Mark (SymGC STW Mark + Coalesced Cards, no summary byte)
#   vs
#   Oneday Concurrent Mark (SymGC Concurrent Mark + Coalesced Cards, no summary byte)
set -euo pipefail

DURATION=${1:-30} # default 30s per run for responsive benchmarking
OUT_DIR=/home/leonardo/Projetos/dmd/plans/bench/core_bench/results/bullet_hell
mkdir -p "$OUT_DIR"

BIN_STOCK=/home/leonardo/Projetos/dmd/plans/bench/core_bench/bullet_hell_stock
BIN_ONEDAY=/home/leonardo/Projetos/dmd/plans/bench/core_bench/bullet_hell_oneday
BIN_STRESS_STOCK=/home/leonardo/Projetos/dmd/plans/bench/core_bench/bullet_hell_stress_stock
BIN_STRESS_ONEDAY=/home/leonardo/Projetos/dmd/plans/bench/core_bench/bullet_hell_stress_oneday

echo "=========================================================================="
echo "Bullet Hell Heavy GC Benchmark ($DURATION s per run)"
echo "CPU: AMD Ryzen 7 3800X (8 physical cores / 16 threads)"
echo "=========================================================================="

run_test() {
    local name="$1"
    local bin="$2"
    local args="$3"
    local env_vars="$4"
    local logfile="$OUT_DIR/${name}.log"

    echo "--- Running $name ---"
    env $env_vars $bin $args > "$logfile" 2>&1
    cat "$logfile"
    echo ""
}

echo "=== Workload 1: Bullet Hell (512 MiB live heap, 20,000 bullets/s) ==="
run_test "bh_512m_stock" "$BIN_STOCK" "$DURATION 512 20000" ""
run_test "bh_512m_oneday_stw" "$BIN_ONEDAY" "$DURATION 512 20000 --DRT-gcopt=gc:sdcq" "SYMGC_CONCURRENT_MARK=0"
run_test "bh_512m_oneday_concurrent" "$BIN_ONEDAY" "$DURATION 512 20000 --DRT-gcopt=gc:sdcq" "SYMGC_CONCURRENT_MARK=1 SYMGC_MARK_THREADS=2 SYMGC_MARK_NICE=10"

echo "=== Workload 2: Bullet Hell Heavy (2 GiB live heap, 40,000 bullets/s) ==="
run_test "bh_2g_stock" "$BIN_STOCK" "$DURATION 2048 40000" ""
run_test "bh_2g_oneday_stw" "$BIN_ONEDAY" "$DURATION 2048 40000 --DRT-gcopt=gc:sdcq" "SYMGC_CONCURRENT_MARK=0"
run_test "bh_2g_oneday_concurrent" "$BIN_ONEDAY" "$DURATION 2048 40000 --DRT-gcopt=gc:sdcq" "SYMGC_CONCURRENT_MARK=1 SYMGC_MARK_THREADS=2 SYMGC_MARK_NICE=10"

echo "=== Workload 3: Extreme Allocation Churn Stress (2 GiB live heap, 100k bullets/s, +256B/shot) ==="
# args: seconds levelMiB bulletsPerSecond lifeScale garbageBytes nogc
run_test "stress_2g_stock" "$BIN_STRESS_STOCK" "$DURATION 2048 100000 0.05 256 0" ""
run_test "stress_2g_oneday_stw" "$BIN_STRESS_ONEDAY" "$DURATION 2048 100000 0.05 256 0 --DRT-gcopt=gc:sdcq" "SYMGC_CONCURRENT_MARK=0"
run_test "stress_2g_oneday_concurrent" "$BIN_STRESS_ONEDAY" "$DURATION 2048 100000 0.05 256 0 --DRT-gcopt=gc:sdcq" "SYMGC_CONCURRENT_MARK=1 SYMGC_MARK_THREADS=2 SYMGC_MARK_NICE=10"

echo "=========================================================================="
echo "SUMMARY RESULTS"
echo "=========================================================================="
for f in "$OUT_DIR"/*.log; do
    echo "=== $(basename "$f" .log) ==="
    grep -E "bullet_hell|frame_" "$f" || cat "$f"
    echo ""
done
