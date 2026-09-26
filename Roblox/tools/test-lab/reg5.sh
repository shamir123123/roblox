#!/bin/sh
cd "$(dirname "$0")"
M=fix5
{
for sd in 1 2 3; do echo "lune run t_s1_highway.luau $M $sd > runs/reg5/s1_$sd.txt 2>&1"; done
for sd in 1 2 3 4 5 6 7 8; do echo "lune run t_s2_grid.luau $M signals 90 $sd > runs/reg5/s2sig_$sd.txt 2>&1"; done
for sd in 1 2 3 4; do echo "lune run t_s2_grid.luau $M nosignals 90 $sd > runs/reg5/s2nos_$sd.txt 2>&1"; done
for sd in 1 2; do echo "lune run t_s2_grid.luau $M signals 220 $sd > runs/reg5/s2heavy_$sd.txt 2>&1"; echo "lune run t_s2_grid.luau $M nosignals 220 $sd > runs/reg5/s2nosheavy_$sd.txt 2>&1"; done
echo "lune run t_s4_leak.luau $M > runs/reg5/s4.txt 2>&1"
echo "lune run specrun.luau $M > runs/reg5/spec.txt 2>&1"
for sd in 1 2 3 4; do for k in cross tee cross-heavy; do echo "lune run t_s5_giveway.luau $M $k $sd 360 log > runs/reg5/s5_${k}_$sd.txt 2>&1"; done; done
} | xargs -P 4 -I{} sh -c "{}"
echo REGDONE
