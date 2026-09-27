--!strict
-- Map presets selectable at city creation. Shared: the client map picker reads
-- names/descriptions, the server feeds seed + relief into terrain generation.

-- seed + relief + shape (and the optional knobs) ARE the map: the generator rebuilds
-- it identically on every load, so nothing about the terrain is persisted.
-- `resources` authors the figures MapResources cannot see from the terrain (oil), and
-- overrides the sampled ones where a map's name promises something specific.
export type MapPreset = {
	id: string,
	name: string,
	description: string,
	seed: number,
	relief: number,
	shape: string?,
	oceanLevel: number?,
	baseHeight: number?,
	ruggedness: number?,
	resources: { [string]: number }?,
	generated: boolean?, -- true = the player rolls the seed and shapes it themselves
}

local MapPresets = {}

MapPresets.DEFAULT_ID = "flatlands"
MapPresets.CUSTOM_ID = "custom"
-- Player-made maps (the generated "custom" preset) are switched off for now: the map
-- picker hides the card and CitySlotService refuses it. Old saves on it still load.
MapPresets.PLAYER_MAPS_ENABLED = false

-- Ten premade maps, one per macro shape, plus the custom slot. Relief is halved
-- against the 2x-smaller world (ZoneGrid.WORLD_SCALE) so hills stay proportional.
MapPresets.List = table.freeze({
	table.freeze({
		id = "flatlands",
		name = "Flatlands",
		description = "Wide open plains with deep soil. Build anywhere, farm everywhere.",
		seed = 5.5,
		relief = 0.075,
		shape = "landlocked",
		resources = table.freeze({ oil = 58 }),
	}),
	table.freeze({
		id = "green_valley",
		name = "Green Valley",
		description = "Gentle rolling hills and soft wooded valleys. A forgiving first city.",
		seed = 12.25,
		relief = 0.5,
		-- Wood and water sit above what the sampler reads: the valleys carry streams and
		-- standing timber the height field alone cannot see.
		resources = table.freeze({ oil = 22, wood = 62, water = 45 }),
	}),
	table.freeze({
		id = "riverbend",
		name = "Riverbend",
		description = "A wide river winding through fertile bottomland. Bridges decide your layout.",
		seed = 21.5,
		relief = 0.35,
		shape = "river",
		-- A river is a fraction of a percent of the map's area but all the water a city
		-- could want; the area measure understates it badly.
		resources = table.freeze({ oil = 30, farmland = 92, water = 88 }),
	}),
	table.freeze({
		id = "twin_lakes",
		name = "Twin Lakes",
		description = "Rolling country wrapped around a deep inland lake. Fresh water, no coast.",
		seed = 33.25,
		relief = 0.42,
		shape = "lake",
		resources = table.freeze({ oil = 25, water = 82 }),
	}),
	table.freeze({
		id = "pine_coast",
		name = "Pine Coast",
		description = "Dense timber running down to an open sea. Sawmills and shipping.",
		seed = 47.75,
		relief = 0.45,
		shape = "coast",
		ruggedness = 0.15,
		resources = table.freeze({ oil = 45, wood = 94 }),
	}),
	table.freeze({
		id = "emerald_isle",
		name = "Emerald Isle",
		description = "One green island, sea on every side. Space is the scarce resource.",
		seed = 58.5,
		relief = 0.55,
		shape = "island",
		resources = table.freeze({ oil = 18 }),
	}),
	table.freeze({
		id = "scattered_isles",
		name = "Scattered Isles",
		description = "A chain of small islands. Every district needs a crossing.",
		seed = 64.25,
		relief = 0.45,
		shape = "archipelago",
		resources = table.freeze({ oil = 74 }),
	}),
	table.freeze({
		id = "harbour_bay",
		name = "Harbour Bay",
		description = "A sheltered inlet made for a working port. Offshore oil within reach.",
		seed = 72.5,
		relief = 0.4,
		shape = "bay",
		resources = table.freeze({ oil = 62 }),
	}),
	table.freeze({
		id = "cape_reach",
		name = "Cape Reach",
		description = "Land reaching out into the sea, joined by one narrow neck.",
		seed = 81.75,
		relief = 0.5,
		shape = "peninsula",
		resources = table.freeze({ oil = 38 }),
	}),
	table.freeze({
		id = "high_ridge",
		name = "High Ridge",
		description = "Rugged upland with hard winters. Flat ground is worth fighting for.",
		seed = 96.5,
		relief = 0.85,
		shape = "highlands",
		ruggedness = 0.4,
		resources = table.freeze({ oil = 15, water = 35, farmland = 12 }),
	}),
	table.freeze({
		id = "custom",
		name = "Custom Map",
		description = "Roll a seed, pick a landmass and shape the terrain yourself.",
		seed = 0,
		relief = 0.5,
		generated = true,
	}),
}) :: { MapPreset }

-- Macro terrain layouts for a generated map. The generator (surfaceY) shapes the
-- whole landmass per id; the picker shows one tile per shape. Shared so the server
-- can validate the client's choice against the same list.
export type MapShape = { id: string, name: string, description: string, icon: string }

MapPresets.DEFAULT_SHAPE = "continent"

MapPresets.Shapes = table.freeze({
	table.freeze({ id = "continent",   name = "Continent",   description = "Balanced mix of land and open sea.",                icon = "rbxassetid://114533061450218" }),
	table.freeze({ id = "island",      name = "Island",      description = "One landmass ringed by sea on every side.",           icon = "rbxassetid://73339013118293" }),
	table.freeze({ id = "archipelago", name = "Archipelago", description = "Many small islands scattered across the water.",        icon = "rbxassetid://96470982228779" }),
	table.freeze({ id = "coast",       name = "Coast",       description = "Land on one side, open sea on the other.",            icon = "rbxassetid://100595100056038" }),
	table.freeze({ id = "peninsula",   name = "Peninsula",   description = "Land reaching out into the sea, joined on one side.",   icon = "rbxassetid://103819058538552" }),
	table.freeze({ id = "bay",         name = "Bay",         description = "A coastline curved around a sheltered inlet.",         icon = "rbxassetid://106653781967392" }),
	table.freeze({ id = "lake",        name = "Lake",        description = "Inland map wrapped around a central lake.",            icon = "rbxassetid://137172209275961" }),
	table.freeze({ id = "river",       name = "River",       description = "A winding river cutting across dry land.",             icon = "rbxassetid://88276132615567" }),
	table.freeze({ id = "landlocked",  name = "Landlocked",  description = "All land. No sea, no river.",                         icon = "rbxassetid://123741080419264" }),
	table.freeze({ id = "highlands",   name = "Highlands",   description = "Raised, rugged country with little water.",           icon = "rbxassetid://127547954029306" }),
}) :: { MapShape }

function MapPresets.getShape(id: any): MapShape?
	for _, s in MapPresets.Shapes do
		if s.id == id then
			return s
		end
	end
	return nil
end

function MapPresets.isShape(id: any): boolean
	return MapPresets.getShape(id) ~= nil
end

function MapPresets.get(id: string): MapPreset?
	-- "random" was the pre-10-map name for the player-built map; old saves still carry it.
	if id == "random" then id = MapPresets.CUSTOM_ID end
	for _, preset in MapPresets.List do
		if preset.id == id then
			return preset
		end
	end
	return nil
end

-- A preset's terrain knobs as a fresh, mutable GenParams table -- what the picker edits
-- and what the client sends to the server on create. Defaults match TerrainGenerator's.
function MapPresets.genOf(preset: MapPreset): { [string]: any }
	return {
		seed = preset.seed,
		heightRange = preset.relief,
		oceanLevel = preset.oceanLevel or 0,
		baseHeight = preset.baseHeight or 0,
		ruggedness = preset.ruggedness or 0,
		shape = preset.shape or MapPresets.DEFAULT_SHAPE,
		persistence = 0.5,
		lacunarity = 2.0,
		-- The picker previews what the server will build: CitySlotService stamps algo 3 on
		-- every new city regardless of what is sent.
		algo = 3,
	}
end

function MapPresets.getOrDefault(id: any): MapPreset
	local preset = if typeof(id) == "string" then MapPresets.get(id) else nil
	return preset or (MapPresets.get(MapPresets.DEFAULT_ID) :: MapPreset)
end

return MapPresets
