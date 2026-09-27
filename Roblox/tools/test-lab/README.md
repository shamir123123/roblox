# City District headless test lab

Runs the game's real server scripts (roads, lane graph, traffic AI, citizens, economy) under
Lune, outside Roblox, with a small stand-in for the Roblox API (`shim/studio.luau`). Used to
test every change before it ships.

## What you need

- [Lune](https://github.com/lune-org/lune) 0.10.5+ (`rokit install` in `Roblox/` gets it),
  Python 3 with Pillow for the top-down renders, and optionally
  [selene](https://github.com/Kampfkarren/selene).
- The scripts come from this repo's `game/` tree. Run everything from `tools/test-lab`.
- `CITY_LAB_PLACE` = path to the place file (`.rbxl`). The lab loads the models, vehicle
  templates and other non-script assets from it; scripts inside it are ignored.
- To compare against an older version, check it out somewhere
  (`git worktree add /tmp/before <commit>`) and set `CITY_LAB_ORIG=/tmp/before/Roblox/game`;
  mode `orig` then runs that tree.
- `zone_lab.luau` and the scenarios built on it still read `.rbxm` folders from
  `$CITY_LAB_DATA/dump/...` (a `rojo syncback` of the place).

## Main scenarios

| Script | What it checks |
|---|---|
| `t_s1_highway.luau <mode> <seed>` | highway lane changes (needless ones, braking), overlaps |
| `t_s2_grid.luau <mode> <signals\|nosignals> <cars> <seed>` | city grid: arrivals, overlaps, red-light runs, freezes |
| `t_s4_leak.luau <mode>` | 1500 trips, then every driver/index/table must be empty |
| `t_s5_giveway.luau <mode> <cross\|tee\|cross-heavy> <seed> <seconds>` | junctions without lights: fairness, starvation |
| `t_s6_roundabout.luau <mode> <small\|medium\|large> <seed> <seconds> <cars/min/arm>` | traffic through a real RoadService roundabout |
| `t_s7_edge.luau <mode> <seconds> <seed>` | map-edge outside connections: both lanes used to the edge, no late merges, nothing stuck |
| `t_s8_stream.luau <mode> <seconds> <seed> [viewer distance]` | the pose stream a far viewer receives: stop lag, cars drawn inside each other, farewells |
| `t_perf.luau <mode> <cars> <seconds> [grid N] [far]` | traffic tick cost at city scale (ms per tick), and why cars are standing still |
| `t_s9_hwyjunction.luau <mode> <seconds> <seed>` | divided highways: right-in/right-out ramps, no median crossings, far side never waits |
| `t_s10_lanes.luau <mode> <seconds> <seed>` | highway lane discipline: lane share, yields to faster cars behind, faster cars held up, braked lane changes |
| `t_lights_toggle.luau` | junction control by road hierarchy, and the Traffic Light card: add / remove lights, survives save + load |
| `t_signs.luau` | traffic sign plan (USA + Europe) on real junctions: which signs, off the carriageway, facing their traffic |
| `t_city.luau <game days> [seed] [hourly]` | the REAL server (Bootstrap; lobby, teleport and terrain-render stubbed) on a sandbox town: homes, shops, industry, schools and a university, families arriving from the map edge. Hour by hour: are workers at work during their shift and home after it, pupils at school, students in class; trips by purpose. `THROUGH=1` adds through traffic |
| `reg.sh <mode> <outdir>` | the whole traffic suite above, 4 at a time (needs `CITY_LAB_PLACE`; `CITY_LAB_GAME` to test a frozen copy) |
| `render_lab.luau <mode> <scene> <out.json>` then `python3 render/top.py out.json out.png cx cz half ppu` | top-down picture of what the road code builds |
| `DUMP3D="cx,cz,half" lune run render_lab.luau <mode> <scene> out.json` then `python3 render/shade3d.py out.3d.json out.png cx cy cz dist yaw pitch` | angled 3D picture (depth-buffered, PIL only) of the terrain plus everything the road code built -- e.g. scene `walls`: retaining walls on a raised road, a lowered road and a tunnel ramp with its portal |
| `specrun.luau <mode>` | the project's own `.spec` modules |
| `zone_lab.luau <mode> <street\|streethill\|corner\|cornerhill> <out.json>` | zones a street (flat or 1-in-8 hill, straight or with a 90-degree bend) with the real Plot/Building/LotDressing services and the place's templates, waits for construction, then measures how far each lot's ground sits above or below its floor. `ROWS=1` lists every lot, `DIAG=1` dumps the worst lot's ground and terrain-ledger owners |
| `t_earth.luau <mode> streethill x` | one construction site: staged earthworks (ground height per step), its utility badge, build time |
| `t_release.luau <mode> <scene> x` | bulldoze every house (and a site mid-earthworks): the ground must come back exactly, with no pad claims left |
| `t_saveload.luau <mode> <scene> x` | PlotService save + load keeps every building (corner lots included) where it stood |
| `t_cancel.luau <mode> street x` | bulldozing a site under construction frees its plot |
| `t_cluster.luau <mode>` | utility badge clustering with a stand-in camera at three zoom levels |
| `t_padbench.luau <mode>` | time to lay / bulldoze 400 building pads in a dense grid |
| `render/view3d.py dump.json out.png cx cz [dist yaw pitch w h targetY]` | angled 3D render (Blender's `bpy` module, Cycles on the CPU) of a `zone_lab` dump plus its terrain |

`<mode>`: `orig` = the tree at `$CITY_LAB_ORIG`; anything else (e.g. `cur`) = this checkout's
`game/`. Table iteration order is not deterministic, so run several seeds.
