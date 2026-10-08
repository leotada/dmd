#!/bin/sh
# GC benchmark comparison across compilers (RFC Phase 0.1 baselines).
#
# Builds every workload in druntime/benchmark/gcbench with each toolchain, runs it
# REPS times and records, per (workload, toolchain):
#   wall/user/sys seconds (median, plus min and max wall), peak RSS,
#   GC count, total GC ms, max pause ms (from --DRT-gcopt=profile:1),
#   and, for the latency benchmarks, the p50/p99/p99.9/max the program reports.
#
#   ./run_compare.sh [-s ci|full] [-r reps] [-t "dmd ldc"] [-o outdir] [workload ...]
#
# Toolchains (all use their own druntime and Phobos, so the numbers are the baselines
# the new collector has to beat):
#   dmd   system dmd,  -O -release -inline        (conservative GC, druntime 2.109)
#   ldc   system ldc2, -O3 -release               (conservative GC, LDC 1.40 druntime)
#
# To measure the new collector:
#   - GCOPT_EXTRA="gc:immix" (any --DRT-gcopt options) is appended to the profile option,
#     so one binary can be run against another collector it links in;
#   - DMD_BIN / LDC_BIN select the compiler, hence the druntime, that is linked
#     (the repo's own dmd needs a Phobos checkout next to the repo to build most of
#     these workloads; see README.md);
#   - run once per configuration with a different -o, then diff with compare_runs.sh.
#
# Output: <outdir>/results.csv, <outdir>/results.md, raw logs in <outdir>/logs/.
set -u

SIZE=ci
REPS=5
TOOLCHAINS="dmd ldc"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/build
while getopts "s:r:t:o:" opt; do
    case $opt in
        s) SIZE=$OPTARG ;;
        r) REPS=$OPTARG ;;
        t) TOOLCHAINS=$OPTARG ;;
        o) OUT=$OPTARG ;;
        *) echo "usage: $0 [-s ci|full] [-r reps] [-t toolchains] [-o outdir] [workload ...]" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

BENCH_ROOT=$(cd "$HERE/../../druntime/benchmark" && pwd)   # extra-files/ lives here
SRC=$BENCH_ROOT/gcbench
DMD_BIN=${DMD_BIN:-dmd}
LDC_BIN=${LDC_BIN:-ldc2}
mkdir -p "$OUT/bin" "$OUT/logs"

# name | args for -s ci | args for -s full
# "ci" finishes in a few seconds per run; "full" uses live sets and counts close to the
# RFC's roadmap sizes (G0c/M3 want multi-GiB live sets: raise latency's MiB further by hand).
# fiber_latency aborts above ~30000 fibers here: each fiber stack costs two mappings and
# vm.max_map_count is 65530. Raise it (sysctl) to test the 100k-fiber shape of ADR-9.
WORKLOADS="
tree1|14 4|18 4
tree2|2000000 100|7000000 100
dlist||
slist||
rand_small||
rand_large||
words||
mt_alloc|1000000 4|4000000 8
mt_share|200000 2|1000000 4
append_heavy|20000|100000
parallel_map|100000 20|400000 40
traverse_locality|500000 20|2000000 40
frag_longrun||
latency|256 200000|2048 1000000
fiber_latency|10000 100000 64|30000 400000 512
"

toolchain_compile() { # toolchain src out
    case $1 in
        dmd) $DMD_BIN -O -release -inline -of="$3" "$2" ;;
        ldc) $LDC_BIN -O3 -release -of="$3" "$2" ;;
        *) echo "unknown toolchain $1" >&2; return 1 ;;
    esac
}

median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
minimum() { sort -n | head -n 1; }
maximum() { sort -n | tail -n 1; }

echo "workload,toolchain,wall_s,wall_min,wall_max,user_s,sys_s,rss_kib,gcs,gc_ms,maxpause_ms,p50_us,p99_us,p999_us,max_us" > "$OUT/results.csv"

echo "$WORKLOADS" | while IFS='|' read -r name cargs fargs; do
    [ -z "$name" ] && continue
    if [ $# -gt 0 ]; then
        case " $* " in *" $name "*) ;; *) continue ;; esac
    fi
    [ -f "$SRC/$name.d" ] || { echo "skip $name (no source)"; continue; }
    if [ "$SIZE" = full ]; then args=$fargs; else args=$cargs; fi
    [ -z "$args" ] && args=$cargs

    for tc in $TOOLCHAINS; do
        bin=$OUT/bin/$name.$tc
        if ! toolchain_compile "$tc" "$SRC/$name.d" "$bin" >"$OUT/logs/$name.$tc.build" 2>&1; then
            echo "build failed: $name $tc (see logs/$name.$tc.build)"
            continue
        fi
        rm -f "$OUT/bin/$name.$tc.o"
        rm -f "$OUT/logs/$name.$tc.lat"
        walls=""; users=""; syss=""; rsss=""; gcs=""; gcms=""; maxp=""
        for i in $(seq "$REPS"); do
            log=$OUT/logs/$name.$tc.$i
            (cd "$BENCH_ROOT" && /usr/bin/time -f "%e %U %S %M" -o "$log.time" \
                "$bin" $args "--DRT-gcopt=profile:1 ${GCOPT_EXTRA:-}" >"$log.out" 2>"$log.err")
            if [ $? -ne 0 ]; then
                echo "run failed: $name $tc (see $log.err)"
                continue 2
            fi
            read -r w u s m < "$log.time"
            walls="$walls $w"; users="$users $u"; syss="$syss $s"; rsss="$rsss $m"
            # druntime prints the profile on stdout; keep both streams in one search.
            cat "$log.out" "$log.err" > "$log.all"
            gcs="$gcs $(awk -F: '/Number of collections/ {gsub(/ /,"",$2); print $2}' "$log.all" | tail -n 1)"
            gcms="$gcms $(awk -F: '/Grand total GC time/ {split($2,a," "); print a[1]}' "$log.all" | tail -n 1)"
            maxp="$maxp $(awk -F: '/Max Pause Time/ {split($2,a," "); print a[1]}' "$log.all" | tail -n 1)"
            # Latency benchmarks print "p50=.. us  p99=.. us  p99.9=.. us  max=.. us" on stderr.
            grep -h -m1 'p50=' "$log.all" | sed -n 's/.*p50=\([0-9]*\) us *p99=\([0-9]*\) us *p99.9=\([0-9]*\) us *max=\([0-9]*\) us.*/\1,\2,\3,\4/p' >> "$OUT/logs/$name.$tc.lat"
        done
        # Tail percentiles move a lot from run to run (which requests meet a collection),
        # so report the median of each column over the repetitions.
        lat=",,,"
        if [ -s "$OUT/logs/$name.$tc.lat" ]; then
            lat=""
            for col in 1 2 3 4; do
                lat="$lat${lat:+,}$(cut -d, -f$col "$OUT/logs/$name.$tc.lat" | median)"
            done
        fi
        row="$name,$tc,$(printf '%s\n' $walls | median),$(printf '%s\n' $walls | minimum),$(printf '%s\n' $walls | maximum),$(printf '%s\n' $users | median),$(printf '%s\n' $syss | median),$(printf '%s\n' $rsss | median),$(printf '%s\n' $gcs | median),$(printf '%s\n' $gcms | median),$(printf '%s\n' $maxp | median),$lat"
        echo "$row" >> "$OUT/results.csv"
        echo "$row"
    done
done

# Markdown table: one row per workload, toolchains side by side, plus the ratio of the
# second toolchain to the first when exactly two were run.
awk -F, -v size="$SIZE" -v reps="$REPS" '
NR == 1 { next }
{ w = $1; t = $2
  if (!(w in seen)) { seen[w] = 1; order[++n] = w }
  if (!(t in tcs)) { tcs[t] = 1; tco[++nt] = t }
  d[w, t] = $0 }
END {
  printf "Size `%s`, %s repetitions, medians. Wall in seconds, RSS in MiB, GC and pause in ms.\n\n", size, reps
  printf "| workload |"; for (i = 1; i <= nt; i++) printf " %s wall | %s RSS | %s GCs | %s GC ms | %s max pause |", tco[i], tco[i], tco[i], tco[i], tco[i]
  printf "\n|---|"; for (i = 1; i <= nt; i++) printf "---:|---:|---:|---:|---:|"; printf "\n"
  for (k = 1; k <= n; k++) {
    w = order[k]; printf "| %s |", w
    for (i = 1; i <= nt; i++) {
      if ((w, tco[i]) in d) { split(d[w, tco[i]], f, ","); printf " %.2f | %.0f | %s | %s | %s |", f[3], f[8] / 1024, f[9], f[10], f[11] }
      else printf " - | - | - | - | - |"
    }
    printf "\n"
  }
  printf "\n"
  for (k = 1; k <= n; k++) {
    w = order[k]
    for (i = 1; i <= nt; i++) if ((w, tco[i]) in d) { split(d[w, tco[i]], f, ","); if (f[12] != "") { lat = 1 } }
  }
  if (lat) {
    printf "Request latency as reported by the benchmarks (microseconds):\n\n| workload | toolchain | p50 | p99 | p99.9 | max |\n|---|---|---:|---:|---:|---:|\n"
    for (k = 1; k <= n; k++) { w = order[k]
      for (i = 1; i <= nt; i++) if ((w, tco[i]) in d) { split(d[w, tco[i]], f, ","); if (f[12] != "") printf "| %s | %s | %s | %s | %s | %s |\n", w, tco[i], f[12], f[13], f[14], f[15] } }
  }
}' "$OUT/results.csv" > "$OUT/results.md"
echo
cat "$OUT/results.md"
