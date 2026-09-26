# Batch 3: every car trip is a real, visible car

**Apply batches 1 and 2 first.** This batch builds on both.

## What changes

- Before: when the traffic AI was full or over its time budget, a trip starting more than
  ~500 m from the camera drove *hidden* (no car, not in traffic) and the car appeared at
  the destination. Hidden cars never got a body back, even when you looked at them.
- Now: every car trip drives on the real traffic AI, wherever it is. Far-away cars are
  still simulated fully, just updated 4 times a second instead of 20. They take part in
  traffic, so rush hours and jams build up from real commuters.
- If the city ever hits the car limit (5000 cars driving at once), a trip waits at home
  and leaves when there is room -- it never teleports. Waiting for room no longer counts
  toward the 60-second "give up and arrive" timer; only a missing road route does.
- Removed the now-unused hidden-car hookup (CitizenService's agent service and the traffic
  AI's time-budget check). Walkers keep their own system unchanged (bodies near the camera,
  a planned route far away, a body again when you come close).

Heads-up: a big city at rush hour now puts thousands of real cars on the server. Watch the
server frame time (Shift+F5 / MicroProfiler) in a big city and tell me if it struggles.

## Scripts

| File | Script in Studio |
|---|---|
| `ServerScriptService.Services.City.Simulation.CitizenService.luau` | ServerScriptService > Services > City > Simulation > CitizenService |
| `ServerScriptService.Services.NPC.NPCDriverService.luau` | ServerScriptService > Services > NPC > NPCDriverService |
| `ServerScriptService.Bootstrap.Bootstrap.luau` | ServerScriptService > Bootstrap > Bootstrap (Script) |

## Applying

Tell your local Claude:

> Apply `Roblox/pending-fixes/2026-09-26-visible-trips/changes.diff` to the three scripts it
> names in Studio, after batches 1 and 2 are applied. Only change the lines in the diff.

The full files here already include batches 1 and 2 for these three scripts.

## What to check in a playtest

- Rush hour (about 06:30-09:30 and 16:00-19:30 game time): visible commuter traffic, also
  in parts of the city you fly the camera to.
- No cars popping into driveways out of nowhere.
- Output window: no red errors mentioning `SetAgentService` or `HasBudget`.
