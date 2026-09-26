# City District headless test lab

Runs the game's real server scripts (roads, lane graph, traffic AI, citizens, economy) under
Lune, outside Roblox, with a small stand-in for the Roblox API (`shim/studio.luau`). Used to
test every fix in `../../pending-fixes/` before it ships.

## What you need

- [Lune](https://github.com/lune-org/lune) 0.10+ (`lune run <script>`), Python 3 with Pillow for
  the top-down renders, and optionally [selene](https://github.com/Kampfkarren/selene).
- An extracted copy of the place's scripts (not committed; the scripts are your game):
  `rojo syncback` of the place file into a folder, laid out as the lab expects:

  ```
  $CITY_LAB_DATA/dump/ReplicatedStorage, dump/ReplicatedFirst, dump/ServerScriptService,
                 dump/ServerStorage, dump2/SPS   (StarterPlayerScripts)
  $CITY_LAB_DATA/fix*/new/...                     (patched files per batch, see shim/setup.luau)
  ```

  Point `CITY_LAB_DATA` at that folder.

## Main scenarios

| Script | What it checks |
|---|---|
| `t_s1_highway.luau <mode> <seed>` | highway lane changes (needless ones, braking), overlaps |
| `t_s2_grid.luau <mode> <signals\|nosignals> <cars> <seed>` | city grid: arrivals, overlaps, red-light runs, freezes |
| `t_s4_leak.luau <mode>` | 1500 trips, then every driver/index/table must be empty |
| `t_s5_giveway.luau <mode> <cross\|tee\|cross-heavy> <seed> <seconds>` | junctions without lights: fairness, starvation |
| `t_s6_roundabout.luau <mode> <small\|medium\|large> <seed> <seconds> <cars/min/arm>` | traffic through a real RoadService roundabout |
| `render_lab.luau <mode> <scene> <out.json>` then `python3 render/top.py out.json out.png cx cz half ppu` | top-down picture of what the road code builds |
| `specrun.luau <mode>` | the project's own `.spec` modules |

`<mode>`: `orig` = the place as sent; `fix4`, `fix5`, ... = with the pending batches overlaid
(see `shim/setup.luau`). Table iteration order is not deterministic, so run several seeds.
