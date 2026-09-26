# Batch 4: fair right of way at junctions without traffic lights

**Apply batches 1, 2 and 3 first.** This batch changes one script, on top of batch 3.

## What changes

- **Junctions without lights take turns now.** Before, a car whose turn had come never
  actually went: its wait timer was reset in the same tick that let it in, so it stood at
  the line until a lucky gap. A busy main road could hold a side street (or a car turning
  across it) for two minutes. Now:
  - A car waits for a gap as before. After waiting its turn (2 s on roads of equal rank,
    5 s coming out of a side street) it pulls out as soon as nobody is crossing its path.
  - If a steady stream keeps the junction busy, once it has waited 6 s more the other cars
    stop at their lines and let it in. Only one car per junction gets this at a time (the
    one that has waited longest), so the junction never turns into an all-way stop.
- **Nobody pulls out in front of a car that has already crossed its stop line.** A car
  between its stop line and the start of its turn was invisible to the "is the junction
  clear?" check, so two cars could end up inside each other.
- **Cars queue inside the junction** behind the car ahead on the same turn, instead of
  driving into it.
- **Highways only:** a car that misses the gap for a lane change it needs picks a new
  route instead of stopping in its lane. Batch 1 also did this on city streets and sent
  cars on detours; now it is highway-only.
- Traffic lights are unchanged: red is still an unconditional stop.

## Test results (headless test lab, same scenarios before and after)

| Scenario | Before | After |
|---|---|---|
| T-junction, busy main road: longest any approach waited | 85-122 s (plus a stuck-car rescue) | 13-16 s |
| 4-way junction, equal roads: longest wait | 21-26 s | 12-20 s |
| 4-way junction, one very busy road: longest wait | 30-42 s | 15-19 s |
| Cars inside each other in the junction box | happened | 0 in 29 runs |
| Grid of 220 cars without lights: overlaps / stuck-car rescues | 21 / 4-9 | 5-8 / 0 |
| Grid with lights: red-light runs | 0 | 0 |
| Highway: pointless lane changes / braking in a lane change | 0 / 0 | 0 / 0 |
| Leak test (1500 trips) | clean | clean |

Throughput through a junction stays within a few percent of before.

## Scripts

| File | Script in Studio |
|---|---|
| `ServerScriptService.Services.NPC.NPCDriverService.luau` | ServerScriptService > Services > NPC > NPCDriverService |

## Applying

Tell your local Claude:

> Apply `pending-fixes/2026-09-26-junction-rules/changes.diff` to NPCDriverService in Studio,
> after batches 1, 2 and 3 are applied. Only change the lines in the diff.

Or paste the full file by hand (it already includes batches 1-3 for this script).

## What to check in a playtest

- Build a T-junction of two ordinary two-lane roads, no lights, and send lots of traffic
  down the main road. Side-street cars should get out regularly; now and then a main-road
  car stops at its line to let one in.
- A 4-way junction without lights: all four approaches take turns.
- No cars driving through each other in any junction.
- Traffic lights behave exactly as before.
