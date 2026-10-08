#!/bin/sh
# Immix vs segregated-fit comparison driver (RFC Phase 0.6).
#
#   ./run.sh [reps] [outdir]       (default 3 repetitions, ./build)
#
# Builds bench.d with dmd, runs every workload for both allocators, and writes
# <outdir>/results.csv (medians) and <outdir>/raw.txt (every RESULT line).
set -u
REPS=${1:-3}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${2:-$HERE/build}
mkdir -p "$OUT"
cd "$OUT" || exit 1

clang -O2 -c "$HERE/regs.c" -o regs.o || exit 1
dmd -O -release -inline -of=bench "$HERE/bench.d" "$HERE/proto.d" "$HERE/perfcount.d" regs.o || exit 1

# label | bench arguments
CASES="
alloc-1t|alloc 1 20000000
alloc-4t|alloc 4 10000000
alloc-8t|alloc 8 10000000
frag|frag 15000000 100000 500000
fragsmall|fragsmall 40000000 400000 1000000
fragtiny|fragtiny 30000000 1500000 3000000
trav|trav 2000000 10
tree|tree 18
"

: > raw.txt
echo "$CASES" | while IFS='|' read -r label args; do
    [ -z "$label" ] && continue
    for impl in immix immix-ovf segfit; do
        for i in $(seq "$REPS"); do
            if ! timeout 900 ./bench $impl $args > run.out 2>&1; then
                echo "FAILED: $impl $label rep $i"; tail -3 run.out; continue
            fi
            { grep -h '^RESULT' run.out | sed "s/^RESULT /label=$label rep=$i /"; } >> raw.txt
            echo "$impl $label $i: $(grep -h '^[a-z]* [a-z]*:' run.out | tail -n 1 | cut -c1-160)"
        done
    done
done

# Median of every numeric key per (label, impl).
awk '
function kv(line,   n, a, i, p) {
    n = split(line, a, " ")
    for (i = 1; i <= n; i++) { p = index(a[i], "="); if (p) cur[substr(a[i], 1, p - 1)] = substr(a[i], p + 1) }
}
{ delete cur; kv($0)
  key = cur["label"] "," cur["impl"]
  if (cur["workload"] != "") {
    cnt[key]++
    for (k in cur) if (k != "label" && k != "impl" && k != "workload" && k != "rep") { v[key, k, cnt[key]] = cur[k]; keys[k] = 1 }
    keyset[key] = 1
  }
}
END {
  nk = 0; for (k in keys) names[++nk] = k
  for (i = 1; i <= nk; i++) for (j = i + 1; j <= nk; j++) if (names[j] < names[i]) { t = names[i]; names[i] = names[j]; names[j] = t }
  printf "label,impl"; for (i = 1; i <= nk; i++) printf ",%s", names[i]; printf "\n"
  for (key in keyset) {
    printf "%s", key
    for (i = 1; i <= nk; i++) {
      n = cnt[key]; delete arr
      for (r = 1; r <= n; r++) arr[r] = v[key, names[i], r] + 0
      for (a = 1; a <= n; a++) for (b = a + 1; b <= n; b++) if (arr[b] < arr[a]) { t = arr[a]; arr[a] = arr[b]; arr[b] = t }
      printf ",%s", arr[int((n + 1) / 2)]
    }
    printf "\n"
  }
}' raw.txt > results.unsorted
{ head -n 1 results.unsorted; tail -n +2 results.unsorted | sort; } > results.csv
rm -f results.unsorted
"$HERE/table.sh" results.csv
