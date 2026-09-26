# City District

Roblox game source for City District, synced into Roblox Studio with [Rojo](https://rojo.space).

## Layout

| Folder        | Shows up in Studio as                         | Runs on         |
| ------------- | --------------------------------------------- | --------------- |
| `src/server`  | `ServerScriptService.Server`                  | Server          |
| `src/client`  | `StarterPlayer.StarterPlayerScripts.Client`   | Each player     |
| `src/shared`  | `ReplicatedStorage.Shared`                    | Both            |

File names decide the script type:

- `name.server.luau` → `Script`
- `name.client.luau` → `LocalScript`
- `name.luau` → `ModuleScript`
- `init.server.luau` / `init.client.luau` / `init.luau` turn their folder into that script

Rojo only manages the three folders above. Anything you build directly in Studio
(the map in `Workspace`, lighting, UI you haven't moved into code) is left alone,
so keep saving the place file in Studio as usual.

## Setup (once)

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then run `rokit install` in this folder to get Rojo.
2. In Roblox Studio, install the Rojo plugin: run `rojo plugin install`, or get it from the Creator Store.

## Working in Studio

1. In this folder, run `rojo serve`.
2. Open your City District place in Studio, open the Rojo plugin, and click **Connect**.
3. Edit files here; changes appear in Studio straight away.

To build a fresh place file from the code alone: `rojo build -o CityDistrict.rbxl`.
