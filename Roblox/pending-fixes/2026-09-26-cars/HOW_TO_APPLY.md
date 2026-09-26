# City District car fixes (v2): how to apply

This replaces the first package. Six scripts changed. Each file here is named after where
the script lives in Studio.

| File | Script in Studio |
|---|---|
| `ReplicatedStorage.Road.NavRouter.luau` | ReplicatedStorage > Road > NavRouter |
| `ReplicatedStorage.Road.RoadNavigationGraph.luau` | ReplicatedStorage > Road > RoadNavigationGraph (the module itself, not its `spec` child) |
| `ServerScriptService.Services.NPC.NPCDriverService.luau` | ServerScriptService > Services > NPC > NPCDriverService |
| `ServerScriptService.Services.Util.PathFollower.luau` | ServerScriptService > Services > Util > PathFollower |
| `ServerScriptService.Services.City.Simulation.CitizenService.luau` | ServerScriptService > Services > City > Simulation > CitizenService |
| `StarterPlayer.StarterPlayerScripts.World.NPCDriverView.luau` | StarterPlayer > StarterPlayerScripts > World > NPCDriverView |

## Option A: your local Claude (it is connected to Studio)

Give it `changes.diff` and say:

> Apply changes.diff to these six scripts in Studio: NavRouter, RoadNavigationGraph,
> NPCDriverService, PathFollower, CitizenService, NPCDriverView. Only change the lines in the diff.

This is the safest option if you edited any of these scripts after saving the place file.

## Option B: paste by hand

Only do this if you have NOT changed these six scripts since you saved the place file you
sent. Pasting a whole file replaces the whole script.

1. Open the script in Studio.
2. Press Ctrl+A, then Delete.
3. Open the matching `.luau` file here, copy everything, and paste it into the script.
4. Repeat for all six, then press Play and watch the Output window for red errors.

## What to check in a playtest

- Highway: cars hold their lane, and when they do move over they keep their speed.
- Jam: build a junction that gridlocks. Cars should stop and stay stopped, never drive
  through each other, until you change the roads.
- Far view: zoom out and tilt so the street you look at is far from the camera; all its cars
  stay drawn.
- Output: a line saying a car "stalled 60s -- rescuing" means a genuinely bugged car was
  pushed through. If you see many, send them to me.
