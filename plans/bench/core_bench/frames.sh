#!/bin/sh
# Game-shaped latency test: ./frames.sh outdir  (needs gcb_plain and gcb_sym in outdir, from run_core.sh)
OUT=${1:?outdir}
: > "$OUT/frames.txt"
for live in 512 2048; do
  for cfg in "conservative|gc:conservative|gcb_plain" "parallel|gc:conservative parallel:8|gcb_plain" "fork|gc:conservative fork:1|gcb_plain" "symgc|gc:sdcq|gcb_sym"; do
    IFS='|' read -r name opt bin <<EOT
$cfg
EOT
    "$OUT/$bin" frames $live 1200 5000 "--DRT-gcopt=$opt" 2>&1 | grep '^RESULT' | sed "s/^RESULT /live=$live gc=$name /" >> "$OUT/frames.txt"
    echo "done $live $name"
  done
done
