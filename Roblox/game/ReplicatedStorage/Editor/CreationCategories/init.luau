--!strict
-- CreationCategories
-- Where a player's saved creation FILES ITSELF. The creator picks one when they save,
-- and the placement UI shelves it under that chip -- a custom oak lands next to the
-- built-in trees rather than in a separate "my stuff" pile.
--
-- The first three keys are deliberately the SAME strings as NatureCatalog's `kind`
-- values (Tree / Bush / Rock), so a creation and a built-in prop can share one chip row
-- with no translation table between them.
--
-- WHY THESE AND NOT THE BOTTOM BAR'S TABS: Roads, Zoning and Transit place things that
-- DO something -- they carry cost, coverage, capacity and sim behaviour. A creation is
-- geometry with no simulation role, so filing one there would promise a building that
-- works and deliver scenery. Everything here lives in the decorative family, which is
-- what a creation actually is. When customised service buildings ship they get their own
-- entry, gated on the blueprint's kind rather than on the creator's choice.
--
-- Stored as the STRING key on the blueprint's index row, never as an index into `order`
-- -- reordering this list must stay harmless. (NaturePlaceService does the opposite and
-- pays for it: its saves hold array positions.)

export type Category = {
	key: string,
	label: string,
	-- Which existing panel shelves it. One value today; named rather than assumed so a
	-- second home does not need every consumer rewritten.
	panel: string,
	-- One line of guidance in the save dialog, so the choice is not a guess.
	hint: string,
}

local DEFAULT_KEY = "Prop"

local byKey: { [string]: Category } = {
	Tree = table.freeze({
		key = "Tree", label = "Trees", panel = "Nature",
		hint = "Shelved with the trees. For anything tall and planted.",
	}),
	Bush = table.freeze({
		key = "Bush", label = "Bushes", panel = "Nature",
		hint = "Shelved with the bushes. For hedges, shrubs and flower beds.",
	}),
	Rock = table.freeze({
		key = "Rock", label = "Rocks", panel = "Nature",
		hint = "Shelved with the rocks. For boulders, outcrops and rubble.",
	}),
	Prop = table.freeze({
		key = "Prop", label = "Props", panel = "Nature",
		hint = "Street furniture: benches, bins, signs, lamps, fences.",
	}),
	Landmark = table.freeze({
		key = "Landmark", label = "Landmarks", panel = "Nature",
		hint = "The big one-off pieces: statues, fountains, monuments, plazas.",
	}),
}

-- Display order for the chip row. Safe to reorder: nothing persists a position.
local order: { string } = table.freeze({ "Tree", "Bush", "Rock", "Prop", "Landmark" })

local CreationCategories = {}

CreationCategories.byKey = table.freeze(byKey)
CreationCategories.order = order
CreationCategories.DEFAULT = DEFAULT_KEY

function CreationCategories.get(key: any): Category?
	if typeof(key) ~= "string" then return nil end
	return byKey[key]
end

function CreationCategories.isValid(key: any): boolean
	return CreationCategories.get(key) ~= nil
end

-- Never rejects. A creation saved before this list existed carries cat = "Misc", and one
-- saved under a category later removed carries a key nothing answers -- neither should
-- cost the player their build, so both shelve under the default.
function CreationCategories.getOrDefault(key: any): Category
	return CreationCategories.get(key) or byKey[DEFAULT_KEY]
end

-- The key to actually store. Same fallback as getOrDefault, as a bare string.
function CreationCategories.normalize(key: any): string
	return CreationCategories.getOrDefault(key).key
end

function CreationCategories.all(): { Category }
	local out: { Category } = {}
	for _, key in order do
		table.insert(out, byKey[key])
	end
	return out
end

return CreationCategories
