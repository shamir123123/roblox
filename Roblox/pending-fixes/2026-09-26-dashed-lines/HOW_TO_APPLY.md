# Batch 6: dashed lines line up where road pieces meet

**Apply batches 1-5 first.** One script, on top of batch 5.

Preview: `../_previews/dashed_lines_before_after.png` (a road drawn as three pieces plus a
bend, and a 3-lane one-way drawn as two pieces).

## What changes

- Before, every road piece started its own dash pattern at its own start, so where two pieces
  met (a road drawn in several goes, a bend) you got a short stub of a dash, or two dashes almost
  touching.
- Now the server lays **whole dashes only**. Each run of dashed paint gets a whole number of
  dashes, with the spacing stretched very slightly to fit, and each end of the run sits in the
  middle of a gap. Two pieces meeting end to end always show one ordinary gap across the join.
- A run too short to hold one full dash gets none, instead of a sliver.
- Applies to the dashed centre line and every dashed lane line. Solid lines are unchanged.
- The road data sent to clients gets smaller (about 20% less paint data on a test road), since
  the gaps no longer carry line points.

## Scripts

| File | Script in Studio |
|---|---|
| `ReplicatedStorage.Road.RoadRenderer.luau` | ReplicatedStorage > Road > RoadRenderer |

## Applying

Tell your local Claude:

> Apply `pending-fixes/2026-09-26-dashed-lines/changes.diff` to RoadRenderer in Studio, after
> batches 1-5 are applied. Only change the lines in the diff.

The full file here already includes batch 5's change to this script.

## What to check in a playtest

- Draw a long road in several pieces, and one with a bend: the dashes run evenly through every
  join.
- Existing roads pick it up the next time they re-render (loading the city re-renders them all).
