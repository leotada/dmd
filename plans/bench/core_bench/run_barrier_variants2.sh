#!/bin/bash
# Evaluates false sharing and card table layout overhead across threads
set -euo pipefail

BIN="plans/bench/core_bench/barrier_variants2"
if [ ! -f "$BIN" ]; then
    echo "Binary $BIN not found, building..."
    /home/leonardo/Projetos/dmd/ldc-build-rt2/bin/ldc2 -O3 -release \
      -d-version=Symgc_druntime_hooks -d-version=Symgc_cards \
      -I/home/leonardo/Projetos/dmd/symgc/source \
      -I/home/leonardo/Projetos/phobos \
      plans/bench/core_bench/barrier_variants2.d $(find /home/leonardo/Projetos/dmd/symgc/source -name '*.d') \
      -of="$BIN"
fi

echo "=========================================================================="
echo "Card Barrier Multi-Threaded Cache Contention Benchmark (barrier_variants2)"
echo "Machine: AMD Ryzen 7 3800X (8 cores / 16 threads, 32 KiB L1d, 512 KiB L2)"
echo "=========================================================================="
printf "%-10s %-8s %-26s %-12s\n" "THREADS" "LAYOUT" "VARIANT" "NS/STORE/TH"
echo "--------------------------------------------------------------------------"

for threads in 1 2 4 8; do
    for layout in private shared; do
        # Run 3 repeats and capture results
        ./$BIN $threads $layout --DRT-gcopt=gc:sdcq | awk -v th="$threads" -v lay="$layout" '
        /ns\/store\/thread/ {
            variant = $1
            for (i=2; i<=NF; i++) {
                if ($i ~ /^threads=/) break;
                variant = variant " " $i
            }
            val = $(NF-1)
            arr[variant] = arr[variant] " " val
        }
        END {
            for (v in arr) {
                split(arr[v], vals, " ")
                # sort vals
                n = length(vals)
                for (i=1; i<=n; i++) {
                    for (j=i+1; j<=n; j++) {
                        if (vals[i] > vals[j]) {
                            tmp = vals[i]; vals[i] = vals[j]; vals[j] = tmp
                        }
                    }
                }
                med = vals[int(n/2)+1]
                printf "%-10s %-8s %-26s %7.3f ns\n", th, lay, v, med
            }
        }'
        echo "--------------------------------------------------------------------------"
    done
done
