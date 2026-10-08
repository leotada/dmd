#!/bin/sh
# Median per (case, gc) of the numeric keys in raw.txt, printed as a table.
awk '
function med(arr, n,   i, j, t) { for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (arr[j]<arr[i]) {t=arr[i];arr[i]=arr[j];arr[j]=t} return arr[int((n+1)/2)] }
{ delete kv; for (i=1;i<=NF;i++) { p=index($i,"="); if (p) kv[substr($i,1,p-1)]=substr($i,p+1) }
  k=kv["case"] "|" kv["gc"]; if (!(k in seen)) { seen[k]=1; order[++no]=k }
  n[k]++
  split("seconds mops rss_kib peak_kib gcs maxpause_ms steady_rss_kib traversal_ms misses_per_traversal p50_us p99_us p999_us max_us", f, " ")
  for (x in f) v[k, f[x], n[k]] = kv[f[x]] + 0 }
END { printf "%-12s %-13s %8s %8s %9s %9s %8s %9s %9s %9s %9s\n","case","gc","secs","Mops/s","rssMiB","peakMiB","maxp_ms","steadyMiB","trav_ms","p99_us","max_us"
  split("seconds mops rss_kib peak_kib maxpause_ms steady_rss_kib traversal_ms p99_us max_us", g, " ")
  for (i=1;i<=no;i++) { k=order[i]; split(k, kk, "|")
    for (x=1;x<=9;x++) { delete a; for (r=1;r<=n[k];r++) a[r]=v[k,g[x],r]; m[x]=med(a,n[k]) }
    printf "%-12s %-13s %8.3f %8.2f %9.1f %9.1f %8.2f %9.1f %9.2f %9d %9d\n", kk[1], kk[2], m[1], m[2], m[3]/1024, m[4]/1024, m[5], m[6]/1024, m[7], m[8], m[9] } }' "$1"
