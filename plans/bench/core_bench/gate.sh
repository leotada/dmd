#!/bin/sh
# Pass/fail benchmark gate for the symgc fork.
#
#   ./gate.sh save    [outdir]   run the gates and store the medians as the baseline (baseline.txt)
#   ./gate.sh check   [outdir]   run the gates and fail if any metric is worse than the baseline by more than TOL percent
#   ./gate.sh compare A B        compare two result files (no run); used by the self-test
#   ./gate.sh selftest           plant a slowdown in a copy of the baseline and check that it is flagged
#
# Environment: REPS (default 3), TOL percent (default 10), FRAME_TOL percent for frame metrics (default 30).
# Frame maxima are noisy and live in a different regime (a whole collection), so they get a wider band.
# The CPU governor is recorded: on `powersave` the numbers move a lot (the first `frames` run was spoiled that way).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/../../..
REPS=${REPS:-3}
TOL=${TOL:-10}
FRAME_TOL=${FRAME_TOL:-30}
BASE=$HERE/baseline.txt

# metric|direction (higher or lower is better)|tolerance class (t = TOL, f = FRAME_TOL, i = informational)
METRICS="mops|higher|t
seconds|lower|t
steady_rss_kib|lower|t
frame_max_us|lower|f
frame_p99_us|lower|f
over1ms|lower|i"

# label|args
CASES="alloc-1t|alloc 1 8000000
alloc-8t|alloc 8 4000000
frag|frag 3000000 100000
frames512|frames 512 600 5000
frames2048|frames 2048 600 5000"

build() {
    OUT=$1
    mkdir -p "$OUT"
    $ROOT/generated/linux/release/64/dmd -O -release -inline -version=SymGC -version=Symgc_druntime_hooks \
        -I"$ROOT/symgc/source" -I"$ROOT/druntime/import" -defaultlib= \
        -L-L"$ROOT/generated/linux/release/64" -L-ldruntime -of="$OUT/gcb_sym" \
        "$HERE/gcb.d" "$HERE/perfcount.d" $(find "$ROOT/symgc/source" -name "*.d") || exit 1
}

run() { # outdir -> prints "label metric value" medians
    OUT=$1
    : > "$OUT/gate_raw.txt"
    echo "$CASES" | while IFS='|' read -r label args; do
        i=0
        while [ $i -lt "$REPS" ]; do
            i=$((i + 1))
            if timeout 900 "$OUT/gcb_sym" $args "--DRT-gcopt=gc:sdcq" > "$OUT/run.out" 2>&1; then
                grep '^RESULT' "$OUT/run.out" | sed "s/^RESULT /case=$label /" >> "$OUT/gate_raw.txt"
            else
                echo "FAILED $label rep $i: $(tail -2 "$OUT/run.out" | tr '\n' ' ')" >&2
            fi
        done
    done
    awk -v metrics="$(echo "$METRICS" | cut -d'|' -f1 | tr '\n' ' ')" '
    function med(arr, n,   i, j, t) { for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (arr[j]<arr[i]) {t=arr[i];arr[i]=arr[j];arr[j]=t} return arr[int((n+1)/2)] }
    BEGIN { nm = split(metrics, M, " ") }
    { delete kv; for (i=1;i<=NF;i++) { p=index($i,"="); if (p) kv[substr($i,1,p-1)]=substr($i,p+1) }
      c=kv["case"]; if (!(c in seen)) { seen[c]=1; order[++no]=c }
      n[c]++
      for (x=1;x<=nm;x++) if (M[x] in kv) v[c, M[x], n[c]] = kv[M[x]] + 0 }
    END { for (i=1;i<=no;i++) { c=order[i]
            for (x=1;x<=nm;x++) { m=M[x]; delete a; k=0
              for (r=1;r<=n[c];r++) if ((c, m, r) in v) a[++k]=v[c,m,r]
              if (k > 0) printf "%s %s %.4f\n", c, m, med(a, k) } } }' "$OUT/gate_raw.txt"
}

compare() { # baseline current -> exit 1 on regression
    awk -v metrics="$METRICS" -v tol="$TOL" -v ftol="$FRAME_TOL" '
    BEGIN { n = split(metrics, L, "\n"); for (i=1;i<=n;i++) { split(L[i], f, "|"); dir[f[1]]=f[2]; cls[f[1]]=f[3] } }
    NR==FNR { base[$1 " " $2] = $3; next }
    { k = $1 " " $2; if (!(k in base)) next
      b = base[k]; c = $3; t = (cls[$2] == "f") ? ftol : tol
      if (b == 0) next
      pct = (c - b) / b * 100
      worse = (dir[$2] == "higher") ? -pct : pct
      status = (worse > t) ? "FAIL" : "ok  "
      if (cls[$2] == "i") status = "info"       # informational: too noisy to gate (same code gave 89 and 40)
      else if (worse > t) bad = 1
      printf "%s %-11s %-16s base=%-12s now=%-12s %+6.1f%% (limit %d%%)\n", status, $1, $2, b, c, pct, t }
    END { exit bad }' "$1" "$2"
}

governor() { cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown; }

case "${1:-}" in
save)
    OUT=${2:-$HERE/build}; build "$OUT"
    echo "# governor=$(governor) reps=$REPS date=$(date -I) symgc=$(git -C "$ROOT/symgc" rev-parse --short HEAD)" > "$BASE"
    run "$OUT" >> "$BASE"
    cat "$BASE" ;;
check)
    OUT=${2:-$HERE/build}; build "$OUT"
    [ -f "$BASE" ] || { echo "no baseline: run '$0 save' first"; exit 2; }
    echo "governor=$(governor) (baseline: $(head -1 "$BASE"))"
    run "$OUT" > "$OUT/gate_now.txt"
    compare "$BASE" "$OUT/gate_now.txt"; rc=$?
    [ $rc -eq 0 ] && echo "GATE PASS" || echo "GATE FAIL"
    exit $rc ;;
compare)
    compare "$2" "$3" ;;
selftest)
    T=$(mktemp -d)
    grep -v '^#' "$BASE" > "$T/base.txt"
    # a 20% slowdown: throughput down, time/RSS/latency up
    awk '{ if ($2=="mops") $3*=0.8; else $3*=1.2; print }' "$T/base.txt" > "$T/slow.txt"
    if compare "$T/base.txt" "$T/slow.txt" > "$T/out.txt"; then echo "SELFTEST FAIL: slowdown not detected"; rm -rf "$T"; exit 1; fi
    # a 3% wobble must pass
    awk '{ if ($2=="mops") $3*=0.97; else $3*=1.03; print }' "$T/base.txt" > "$T/wobble.txt"
    if ! compare "$T/base.txt" "$T/wobble.txt" > /dev/null; then echo "SELFTEST FAIL: noise flagged"; rm -rf "$T"; exit 1; fi
    echo "SELFTEST PASS: 20% slowdown flagged, 3% wobble accepted"; rm -rf "$T" ;;
*)
    sed -n '2,10p' "$0"; exit 2 ;;
esac
