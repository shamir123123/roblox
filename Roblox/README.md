# City Districts

Every script in the City Districts place, laid out for [Rojo](https://rojo.space).
`game/` mirrors the Explorer: `game/ServerScriptService/Services/NPC/NPCDriverService.luau`
is ServerScriptService > Services > NPC > NPCDriverService.

| File name | Becomes |
| --- | --- |
| `Name.luau` | ModuleScript |
| `Name.server.luau` | Script |
| `Name.client.luau` | LocalScript |
| `Name/init.luau` (etc.) | that script, with the other files in the folder as its children |

Only scripts (and the folders that lead to them) are here. Models, UI, terrain, the map and
the templates stay in the place file. Every folder carries an `init.meta.json` with
`ignoreUnknownInstances`, so a Rojo sync **only updates scripts and never deletes anything
else** in Studio. Scripts inside imported toolbox assets (`ServerStorage.Templates`) are left
out on purpose.

## Getting changes from GitHub into Studio

**With Rojo (recommended)**

1. Once: install [Rokit](https://github.com/rojo-rbx/rokit), run `rokit install` in this
   folder, then `rojo plugin install` (or get the Rojo plugin from the Creator Store).
2. Pull the branch, run `rojo serve` in this folder.
3. In Studio open City Districts, open the Rojo plugin, click **Connect**. Rojo lists the
   scripts it will change; accept, then save the place.

Rojo pushes the repo's version of every script. If you edited a script in Studio after
sending the place file, that edit would be overwritten, so send the place first (below).

**By hand / with your local Claude**: every change is a normal Git commit, so the commit's
diff on GitHub shows exactly which scripts and lines changed.

## Sending a new place file

Upload the `.rbxl`. It is re-extracted with

```
lune run tools/extract-scripts.luau path/to/place.rbxl
```

which rewrites `game/` from the place. Anything you changed in Studio shows up as its own
commit ("sync from Studio"), so nothing done there is lost before new work goes on top.

## Checking the tree

- `rojo build -o CityDistricts.rbxl` builds a place holding just the scripts.
- `tools/test-lab/` runs the real server scripts headless under Lune (traffic, junctions,
  roundabouts, zoning). See its README.
