# Batch 5: roundabouts like the reference picture

**Apply batches 1-4 first.** This batch builds on batch 1 (RoadNavigationGraph) and batch 4
(NPCDriverService).

Preview (top-down renders from the game's own road code): `../_previews/roundabout_before_after.png`
and `../_previews/roundabout_presets.png`.

## What changes

**Looks**

- **No grey disc in the middle any more.** The island's kerb used to be a solid grey cylinder
  taller than the grass, so the whole centre showed grey. The centre is now built like every
  other road piece (mesh data the client bakes, **no Parts**):
  - a brick **truck apron** round the island, with a light kerb band,
  - the island kerb,
  - grass, and the centre preset on it (see below).
- **Ring markings no longer stop at the arms.** The inner edge line and the lane dividers are
  painted as unbroken circles, with short dashes spaced evenly all the way round. The white bars
  that striped across the ring at every entry are gone (the junction treated an entry as a
  Y-fork and painted "gore" lines).
- **Splitter islands** at every two-way arm: kerbed brick triangles with white edge lines. Their
  shape comes from the paths cars actually drive, keeping 3 studs clear of every path. In a
  traffic test, no car touched one in over 80,000 sampled positions.
- The ring's inner sidewalk is gone (the apron replaces it). Street lamps stay on the outer kerb.
- A roundabout's junctions are always level with the ring (the node tool's "flat junction"), so
  on a hill the ring's paint no longer disappears into, or floats over, a sloping junction.
- **Centre presets**, per roundabout: **Empty** (plain grass, for your own design), **Tree**,
  **Garden**, **Palms** and **Fountain**. They use the Nature models already in
  ReplicatedStorage > Nature.

**Traffic**

- **Roundabouts no longer sink into the ground.** Placing a road digs the ground under it down
  by about 1.25 studs. A roundabout dropped onto that road read the dug ground and sat 1.25
  studs below the roads it joins, so every entry was a little ramp. It now takes the height of
  the roads it cuts.
- **Deflected entries and exits:** cars drift 1.6 studs toward their own kerb before curving
  onto the ring, and leave the same way. That makes room for the splitter islands and slows
  entering traffic a little, like a real roundabout.
- **No more cars driving into each other round the ring.** A car now sees a car ahead that has
  already left its lane into the next piece of junction. Before, it only noticed at the last
  moment. Test result: overlapping cars at a Medium roundabout 4-14 (was 20-31).
- **Ring gridlock fix:** a car leaving the ring no longer queues behind a car carrying on round
  it, so a busy ring can't lock into a full circle.

## Test results (headless lab, the real road code, 4-way Medium roundabout)

| | Before | After |
|---|---|---|
| Cars overlapping each other (4 min, 8 cars/min per arm) | 21-31 | 4-9 |
| Cars touching a splitter island | (no islands) | 0 of 80,000+ samples |
| Freezes, stuck-car rescues, script errors | 0 | 0 |
| Cars through per 4 min, 10 cars/min per arm | ~110 (no islands) | ~100 (entries are deflected, so a little slower) |

The rest of the traffic battery was also rerun on batch 5 with no regressions: highway, grids
with and without lights, junction give-way, leak test, and the spec suite (413 passed, the same
pre-existing failures).

## How to use the presets in game

With the **Roundabout** tool open, there is a new chip next to the S/M/L size chip. It shows
the first letter of the centre preset: **E**mpty, **T**ree, **G**arden, **P**alms, **F**ountain.
Click it to cycle. New roundabouts get that centre. Click inside an existing roundabout with the
tool to give it the selected centre. That is undoable (Ctrl+Z) and saved with the city.

## Scripts (16)

| File | Script in Studio |
|---|---|
| `ReplicatedStorage.Road.RoadConstants.luau` | ReplicatedStorage > Road > RoadConstants |
| `ReplicatedStorage.Road.RoadRenderer.luau` | ReplicatedStorage > Road > RoadRenderer |
| `ReplicatedStorage.Road.RoadSceneRenderer.luau` | ReplicatedStorage > Road > RoadSceneRenderer |
| `ReplicatedStorage.Road.IntersectionRenderer.luau` | ReplicatedStorage > Road > IntersectionRenderer (the module itself, not its children) |
| `ReplicatedStorage.Road.RoadNavigationGraph.luau` | ReplicatedStorage > Road > RoadNavigationGraph (the module itself) |
| `ReplicatedStorage.Road.RoadNetwork.luau` | ReplicatedStorage > Road > RoadNetwork (the module itself) |
| `ReplicatedStorage.Road.RoadTypes.luau` | ReplicatedStorage > Road > RoadTypes |
| `ReplicatedStorage.Networker.luau` | ReplicatedStorage > Networker |
| `ServerScriptService.Services.Road.RoadService.luau` | ServerScriptService > Services > Road > RoadService |
| `ServerScriptService.Services.Road.RoadReplicationService.luau` | ServerScriptService > Services > Road > RoadReplicationService |
| `ServerScriptService.Services.Road.RoadSerializer.luau` | ServerScriptService > Services > Road > RoadSerializer |
| `ServerScriptService.Services.Road.RoadHistoryService.luau` | ServerScriptService > Services > Road > RoadHistoryService |
| `ServerScriptService.Services.NPC.NPCDriverService.luau` | ServerScriptService > Services > NPC > NPCDriverService |
| `StarterPlayer.StarterPlayerScripts.Controllers.RoadPlacementController.luau` | StarterPlayer > StarterPlayerScripts > Controllers > RoadPlacementController |
| `StarterPlayer.StarterPlayerScripts.Controllers.RoadDockPanel.luau` | StarterPlayer > StarterPlayerScripts > Controllers > RoadDockPanel |
| `StarterPlayer.StarterPlayerScripts.World.RoadMeshView.luau` | StarterPlayer > StarterPlayerScripts > World > RoadMeshView |

RoadMeshView is a one-line change: it gives the brick apron and islands the paver texture.

## Applying

Tell your local Claude:

> Apply `pending-fixes/2026-09-26-roundabouts/changes.diff` to the scripts it names in Studio,
> after batches 1-4 are applied. Only change the lines in the diff. If a line does not match,
> stop and tell me.

The full files here already include batches 1-4 for these scripts.

## What to check in a playtest

- Drop a Medium roundabout onto a crossing of two ordinary roads: grass (not grey) in the
  middle, a brick ring round it, a kerbed brick triangle at each arm, dashed lines all the way
  round, and the ring level with the roads.
- Cycle the new chip to **T** and click inside the roundabout: a big tree appears. **E** clears it.
- Send traffic through it for a few minutes: nobody drives over a splitter island or through
  another car, and the ring never locks up.
- Old saved roundabouts get the new look the first time they load. Their height stays as it was
  saved; a sunken one can be fixed by deleting and re-placing it.
