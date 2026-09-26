#!/bin/sh
# usage: summ.sh files... -> one line per variant/scenario aggregated over seeds
for f in "$@"; do awk -v F="$f" '
/overlap t=/ { split($3,a,","); x=a[1]; z=a[2]; if (x<0) x=-x; if (z<0) z=-z; if (x<40 && z<40) box++ }
/^   arm / { match($0,/through +[0-9]+/); n=substr($0,RSTART+8,RLENGTH-8)+0; th+=n;
  match($0,/avg +[0-9.]+/); d=substr($0,RSTART+4,RLENGTH-4)+0; sd+=d*n;
  match($0,/starve +[0-9.]+/); s=substr($0,RSTART+7,RLENGTH-7)+0; if (s>ws) ws=s;
  match($0,/spawned +[0-9]+/); ns+=substr($0,RSTART+8,RLENGTH-8)+0 }
/stall rescues/ { match($0,/rescues [0-9]+/); st+=substr($0,RSTART+8,RLENGTH-8)+0 }
END { printf "%-34s through %4d unspawned %3d avgDelay %5.1f worstStarve %5.1f box %d stalls %d\n", F, th, ns, (th>0?sd/th:0), ws, box, st }' "$f"; done
