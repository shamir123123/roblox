# Pending fixes for City District

Script fixes waiting to be applied in Roblox Studio. Each folder is one batch, named by
date. Apply batches oldest first, then delete the folder (or tell Claude it is done).

## Applying a batch with your local Claude

Get the files onto your PC (either way works):

- `git pull` this repo on the branch `claude/inspiring-johnson-hshwzs`, or
- on GitHub, open this folder on that branch and download the files.

Then tell your local Claude (the one connected to Studio):

> Apply `Roblox/pending-fixes/<batch folder>/changes.diff` to the scripts it names in
> Studio. Only change the lines in the diff. Read HOW_TO_APPLY.md in that folder first.

Each batch folder also has the full fixed scripts, named by their place in Studio, in case
you would rather paste them by hand (see that folder's HOW_TO_APPLY.md).
