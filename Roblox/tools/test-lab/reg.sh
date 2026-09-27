#!/bin/sh
# Regression suite: every traffic scenario for one mode, 4 at a time.
# usage: CITY_LAB_PLACE=... [CITY_LAB_ORIG=...] ./reg.sh <mode> <outdir>
cd "$(dirname "$0")"
M=${1:-cur}
O=${2:-runs/reg/$M}
mkdir -p "$O"
{
for sd in 1 2 3; do echo "lune run t_s1_highway.luau $M $sd > $O/s1_$sd.txt 2>&1"; done
for sd in 1 2 3 4; do echo "lune run t_s2_grid.luau $M signals 90 $sd > $O/s2sig_$sd.txt 2>&1"; done
for sd in 1 2; do echo "lune run t_s2_grid.luau $M nosignals 90 $sd > $O/s2nos_$sd.txt 2>&1"; done
for sd in 1 2; do echo "lune run t_s2_grid.luau $M signals 220 $sd > $O/s2heavy_$sd.txt 2>&1"; echo "lune run t_s2_grid.luau $M nosignals 220 $sd > $O/s2nosheavy_$sd.txt 2>&1"; done
echo "lune run t_s4_leak.luau $M > $O/s4.txt 2>&1"
echo "lune run specrun.luau $M > $O/spec.txt 2>&1"
for sd in 1 2; do for k in cross tee cross-heavy; do echo "lune run t_s5_giveway.luau $M $k $sd 360 > $O/s5_${k}_$sd.txt 2>&1"; done; done
for sd in 1 2; do for k in small medium; do echo "lune run t_s6_roundabout.luau $M $k $sd 240 8 > $O/s6_${k}_$sd.txt 2>&1"; done; done
for sd in 1 2; do echo "lune run t_s7_edge.luau $M 360 $sd > $O/s7_$sd.txt 2>&1"; done
for sd in 1 2; do echo "lune run t_s9_hwyjunction.luau $M 300 $sd > $O/s9_$sd.txt 2>&1"; done
for sd in 1 2; do echo "lune run t_s10_lanes.luau $M 240 $sd > $O/s10_$sd.txt 2>&1"; done
echo "lune run t_lights_toggle.luau > $O/lights.txt 2>&1"
echo "lune run t_signs.luau > $O/signs.txt 2>&1"
echo "lune run t_city.luau 2 1 > $O/city.txt 2>&1"
for sd in 1 2; do echo "lune run t_s8_stream.luau $M 200 $sd 1500 > $O/s8_$sd.txt 2>&1"; done
} | xargs -P 4 -I{} sh -c "{}"
echo REGDONE
