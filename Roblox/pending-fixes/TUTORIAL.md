# How to apply the City District fixes (step by step)

There are six batches of fixes waiting in this folder. Apply them **in this order**,
because each one builds on the one before:

| # | Folder | What it does |
|---|---|---|
| 1 | `2026-09-26-cars` | Car AI: no pointless lane changes, jams stay real, smooth highway lane changes, far cars drawn correctly |
| 2 | `2026-09-26-stock-and-time` | 24-minute days (12-hour months), one "Stock" item, realistic deliveries and shopping |
| 3 | `2026-09-26-visible-trips` | Every car trip is a real, visible car in traffic |
| 4 | `2026-09-26-junction-rules` | Junctions without lights take turns fairly; no cars inside each other in a junction |
| 5 | `2026-09-26-roundabouts` | Roundabouts like the reference picture: brick apron, splitter islands, unbroken ring lines, centre presets |
| 6 | `2026-09-26-dashed-lines` | Dashed lines line up where road pieces meet; no half dashes |

Every batch folder has the same things inside:

- `changes.diff` -- only the lines that changed. This is what your local Claude uses.
- one `.luau` file per changed script, named after where it lives in Studio
  (`ServerScriptService.Services.NPC.NPCDriverService.luau` = ServerScriptService >
  Services > NPC > NPCDriverService). These are the complete fixed scripts, for pasting by hand.
- `HOW_TO_APPLY.md` -- what the batch does and what to check.

---

## Step 0: back up your game (do not skip)

1. Open City District in Roblox Studio.
2. **File > Save to File As...**, pick a folder you will remember, and save it as
   `CityDistrict-before-fixes.rbxl`.

If anything goes wrong, you open that file and you are back where you started.
(If the game is published, Roblox also keeps older versions: Creator Dashboard > your
experience > the place > Version History.)

## Step 1: get the fix files onto your PC

Easiest way, no Git needed:

1. Open https://github.com/shamir123123/unity-project/tree/claude/inspiring-johnson-hshwzs
   (make sure the branch button at the top left says `claude/inspiring-johnson-hshwzs`).
2. Click the green **Code** button, then **Download ZIP**.
3. Unzip it. Inside, go to `Roblox` > `pending-fixes`.
4. Copy the whole `pending-fixes` folder into the folder where your local Claude works on
   City District (the folder with your `CLAUDE.md` and `CODE_INDEX.md`).

If you already use Git on your PC: `git clone` the repo, or `git pull` on that branch.

## Step 2 (recommended): let your local Claude apply them

Your local Claude is already connected to Studio, so it can edit the scripts directly.

1. Open Roblox Studio with City District, the same way you normally do when your local
   Claude edits scripts (its Studio connection has to be working).
2. Start your local Claude in your City District folder.
3. Give it **one batch at a time**. Copy this for batch 1:

   > Read `pending-fixes/TUTORIAL.md` and `pending-fixes/2026-09-26-cars/HOW_TO_APPLY.md`.
   > Then apply `pending-fixes/2026-09-26-cars/changes.diff` to the scripts it names in
   > Studio. Only change the lines in the diff. If a line in the diff does not match what is
   > in Studio (because I changed that script since), stop and tell me instead of guessing.
   > When you are done, list every script you changed.

4. When it says batch 1 is done, press **Play** in Studio and look at the **Output** window
   (View > Output). Red text means an error -- copy it and give it to Claude.
5. If there are no errors, stop the playtest and **save** (File > Save to Roblox, or
   Ctrl+S). Then do the same for batch 2, with the folder name
   `2026-09-26-stock-and-time`, then batch 3 with `2026-09-26-visible-trips`, batch 4 with
   `2026-09-26-junction-rules`, batch 5 with `2026-09-26-roundabouts`, and then batch 6 with
   `2026-09-26-dashed-lines`.

Why one batch at a time: if something breaks, you know exactly which batch did it.

## Step 2 (other way): paste the scripts by hand

Use this only if you have **not** changed any of these scripts since the place file you sent
me. Pasting a whole file replaces the whole script.

For each batch, in order, for each `.luau` file in its folder:

1. In Studio's **Explorer**, find the script. The file name is the path: for
   `ServerScriptService.Services.City.Economy.SupplyService.luau` open ServerScriptService >
   Services > City > Economy and double-click **SupplyService**.
   (Tip: typing the script name into the Explorer's search box finds it fast.)
2. Click inside the script, press **Ctrl+A**, then **Delete**.
3. Open the `.luau` file in Notepad (or any text editor), press **Ctrl+A**, **Ctrl+C**.
4. Click back in the Studio script and press **Ctrl+V**.
5. Repeat for every file in that batch.

Some scripts appear in more than one batch (CitizenService, NPCDriverService, RoadNavigationGraph, RoadRenderer). That is fine:
the file in a later batch already includes the earlier batch's changes, so the last one you
paste wins. After each batch: Play, check Output for red errors, then save.

## Step 3: playtest checklist

After all six batches:

- **Clock:** a full day takes about 24 real minutes at 1x.
- **Highway:** cars stay in their lane and keep their speed when they do change lanes.
- **Jams:** make a junction gridlock on purpose. Cars stop and stay stopped (no driving
  through each other) until you fix the road.
- **Junctions without lights:** every approach gets its turn (no side street waiting
  minutes); now and then a main-road car stops to let one out. No cars inside each other.
- **Roundabouts:** green centre (not grey), brick ring, brick triangles at the entries, dashed
  lines all the way round. The new chip next to S/M/L picks the centre (Empty/Tree/Garden/
  Palms/Fountain); click inside a roundabout with the tool to apply it.
- **Dashed lines:** even spacing straight through places where a road was drawn in pieces.
- **Far away:** zoom out and tilt the camera; the street you look at keeps all its cars.
- **Shops/factories:** click one. "Sells/Produces: Stock" and how much it holds. Delivery
  trucks are rare (about twice a game week per shop) and bigger for bigger shops.
- **Rush hour:** around 06:30-09:30 and 16:00-19:30 game time, visible commuter traffic.
- **Output window:** no red errors. A yellow line saying a car "stalled 60s -- rescuing"
  means a genuinely bugged car was pushed through; a few are fine, lots are worth sending me.
- **Budget:** monthly numbers should look similar to before. Retail/export income will be
  different because shopping is realistic now -- tell me how it feels.

## If something goes wrong

- **Red error after a batch:** copy the whole red text from Output and send it to your local
  Claude (or to me). The error names the script and line.
- **The game is broken and you want to go back:** open `CityDistrict-before-fixes.rbxl`
  from Step 0 (or restore the older version in Version History).
- **A diff does not fit** (your local Claude says lines do not match): you probably changed
  that script after sending me the place file. Send me the current version of that script
  and I will redo the change on top of it.

## After applying

Delete the batch folders you have applied (or tell Claude they are done), so nobody applies
them twice. New fixes will keep arriving in `Roblox/pending-fixes/` as new dated folders.
