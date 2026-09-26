# Batch 7: buildings and terrain (Cities: Skylines style)

**None of these five scripts are changed by batches 1-6**, so this batch does not depend on
them. It was tested on top of batches 1-6.

Previews: `../_previews/buildings_hillside_ground.png` (the ground under a hillside row of
houses, before and after) and `../_previews/corner_lot_before_after.png`.

## What changes

**Ground under buildings: nothing floats**

- **Hillside lots no longer sit over a trench.** Each lot blends its edge into the road beside
  it. It treated the road's sloping bank (which runs 16 studs out, down to the natural ground)
  as if it were the road, copied that low height, and locked it. On a slope, that locked strip
  cut a ditch through the *next* lot along, up to 7 studs deep, right under the house.
  - A lot now only joins the road itself.
  - Where two lots meet, each owns the ground inside its own lot line, so a neighbour can
    never dig into it.
- **The land between buildings is filled** (Cities: Skylines' "no pits between houses"). This
  covers:
  - the corner beside a junction,
  - the wedge behind lots on a curve,
  - the strip between two back gardens.

  The ground there now runs smoothly from one lot's level to the next instead of dipping to
  the natural ground and back. Two lots facing each other across a street are left alone:
  the street is between them. Edges with no neighbour still slope back to the natural ground
  as before.
- **Corner lots:** zoning a row right up to a bend now carries the row round the outside of the
  bend with one more lot. Before, that whole corner stayed bare grass. Its garden runs out to
  where the other road's row ends, so the corner is used. It is saved and loaded like any
  other lot. It only appears when the row reaches the bend and the lot fits clear of every
  road and building.
- Bulldozing gives the ground back exactly as it was, including the filled land (tested: 0
  height points different after bulldozing a whole zoned street).

**Construction**

- **Build times depend on the building** (they were a flat 8.4 s for everything), in game
  time, so they pause at speed 0 and run faster at 2x/3x:

  | Building (lot size) | Time at 1x |
  |---|---|
  | house on a 2x2 lot | 24 s |
  | house on a 3x3 lot | 32 s |
  | shop on a 4x4 lot | 50 s |
  | factory on a 5x5 lot, or a mid-rise block | about 60 s (the cap) |

- **The ground settles in steps.** When a lot is claimed, the site is graded in four steps
  (about 3 s) while the scaffold goes up: cut on the uphill side, filled on the downhill
  side. It no longer snaps flat in one frame.
- **Missing-utility badges on construction sites.** A site shows the same no-power / no-water
  / no-sewage badge a finished house there would, so you see a street is off the grid while
  it is still going up. The badge clears as soon as you connect it.

**Badges cluster when you zoom out**

- From far away, badges of the same kind that crowd together on screen merge into one bigger
  badge with a count ("bolt 12"), like Cities: Skylines II. Zoom in and they split again.
  Nearer than 150 studs every badge stands alone. Clusters stay visible further out (2,400
  studs) than single badges (900).

**Bug fix (already in the game)**

- Bulldozing a building that was still under construction threw a script error half-way
  through, so the plot stayed zoned forever and nothing could be built there again. Fixed.

## Test results (headless lab, the real scripts, 1-in-8 hillside)

| | Before | After |
|---|---|---|
| Hillside street, 24 houses: houses with ground more than 0.5 studs below the floor | 16 (worst 6.7 studs) | 4 (worst 0.6) |
| Hillside bend, 21-22 houses: same | 16 (worst 2.6) | 13 (worst 1.1) |
| Flat street and flat bend | 0 | 0 |
| Outside corner of a bend | bare | a corner lot |
| Bulldoze every house: ground back as it was | yes | yes, fills included |
| Bulldoze a site mid-construction | script error, plot stuck zoned | works, ground restored |
| Save + load | same positions | same positions, corner lots included |
| Spec suite | 413 passed, 37 failing | 413 passed, the same 37 failing |

What is left on the hillside is where a flat lot meets a pavement that climbs 1 in 8: the
ground under the kerb dips up to about 1 stud at one corner, mostly under the pavement.
Cities: Skylines does the same (flat buildings, sloping street).

Cost: in the lab, laying one building's ground takes about twice as long as before (6.7 ms
instead of 3.3 ms), and bulldozing one in a dense suburb about 9 ms, because its neighbours
redo their fills. The lab runs slower than a Roblox server, so expect less in game.

## Scripts (5)

| File | Script in Studio |
|---|---|
| `ServerScriptService.Services.Terrain.TerrainOverlayLedger.luau` | ServerScriptService > Services > Terrain > TerrainOverlayLedger |
| `ServerScriptService.Services.Terrain.TerrainPadService.luau` | ServerScriptService > Services > Terrain > TerrainPadService |
| `ServerScriptService.Services.City.BuildingService.luau` | ServerScriptService > Services > City > BuildingService |
| `ServerScriptService.Services.City.PlotService.luau` | ServerScriptService > Services > City > PlotService |
| `StarterPlayer.StarterPlayerScripts.World.NoPowerView.luau` | StarterPlayer > StarterPlayerScripts > World > NoPowerView |

TerrainPadService is mostly rewritten; the rest are local changes.

## Applying

Tell your local Claude:

> Apply `pending-fixes/2026-09-26-buildings-terrain/changes.diff` to the five scripts it
> names in Studio. Only change the lines in the diff. If a line does not match, stop and tell
> me.

## What to check in a playtest

- Zone a street across a hillside. Every house stands on flat ground at its own floor level,
  with no ditch or ledge under it. The ground between houses is smooth.
- Zone right up to a 90-degree bend on the outside of the turn: a house appears on the corner.
- Watch a lot being built: the ground settles in a few steps at the start. A house takes about
  half a minute at 1x; bigger buildings take longer.
- Build a street far from any power line: the construction sites show the lightning badge. Run
  a line to them and the badge goes.
- Zoom right out over a street of unpowered houses: the badges merge into a few badges with
  counts.
- Bulldoze a house that is still under construction: no red error in Output, and you can zone
  that spot again.
- Existing cities: houses already standing get the new ground the next time the city loads
  (every building lays its ground again on load). Corner lots only appear on rows you zone
  from now on.
