--!strict
-- Natural resources for a map (Water / Wood / Farmland / Oil), sampled from the SAME
-- height formula the map is generated from -- so the bars in the picker describe the
-- land the player actually gets. Pure library: no lifecycle, no state beyond a memo
-- cache, loadable without a game server.
-- Oil is the exception: nothing in the terrain shows it, so it comes from the seed
-- (or an authored override on a premade map).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local TerrainGenerator = require(ReplicatedStorage.Terrain.TerrainGenerator)

local MapResources = {}

export type Resources = { water: number, wood: number, farmland: number, oil: number }

-- Display order for every UI that lists resources. Frozen: read-only for consumers.
MapResources.List = table.freeze({
	table.freeze({ id = "water",    name = "Water",    color = Color3.fromRGB(86, 168, 226) }),
	table.freeze({ id = "wood",     name = "Wood",     color = Color3.fromRGB(96, 172, 96) }),
	table.freeze({ id = "farmland", name = "Farmland", color = Color3.fromRGB(216, 178, 76) }),
	table.freeze({ id = "oil",      name = "Oil",      color = Color3.fromRGB(158, 130, 214) }),
})

local SAMPLES = 32 -- 32x32 grid over the whole map: ~2k height evals, ~10ms
local TILES = Constants.TILES_PER_AXIS

-- Heights are measured against the map's own valley floor (the 10th percentile of land),
-- not sea level: applyShape lifts whole landmasses by fixed amounts, so absolute height
-- says nothing about what grows there. Everything below is studs ABOVE that floor.
local LAND_FLOOR_PERCENTILE = 0.10
local FARM_MAX_RISE = 14
local FARM_MAX_SLOPE = 1.5
local WOOD_MIN_RISE = 12
local WOOD_MAX_RISE = 55
local WOOD_MAX_SLOPE = 7
-- Timber and cropland are shares of the LAND (an island whose land is all forest is
-- timber-rich, however much sea surrounds it); water is a share of the whole map.
-- Gains stretch each onto 0..100; tuned against the ten premade maps.
local WATER_GAIN = 200
local WOOD_GAIN = 150
local FARM_GAIN = 105

local _memo: { [string]: Resources } = {}
local _memoCount = 0
local MEMO_MAX = 256 -- dragging a slider mints a signature per frame; drop the lot when full

local function pct(fraction: number, gain: number): number
	return math.clamp(math.round(fraction * gain), 0, 100)
end

local function signature(p: TerrainGenerator.GenParams): string
	return string.format(
		"%.4f|%.4f|%.4f|%.4f|%.4f|%s|%.3f|%.3f|%d",
		p.seed, p.heightRange or 1, p.oceanLevel or 0, p.baseHeight or 0,
		p.ruggedness or 0, p.shape or "continent", p.persistence or 0.5, p.lacunarity or 2.0, p.algo or 0
	)
end

local function sample(p: TerrainGenerator.GenParams): Resources
	-- Oil is invisible from above; a stable per-seed figure so rerolling a custom map
	-- changes it and returning to the same seed never does.
	local oil = math.clamp(math.round(52 + math.noise(p.seed * 0.371 + 5.1, 11.7, 3.3) * 190), 8, 98)

	local heights, slopes = {}, {}
	local sea = 0

	for iz = 0, SAMPLES - 1 do
		local gz = (iz + 0.5) / SAMPLES * TILES
		for ix = 0, SAMPLES - 1 do
			local gx = (ix + 0.5) / SAMPLES * TILES
			local y = TerrainGenerator.surfaceYAt(gx, gz, p)
			if y < 0 then
				sea += 1
				continue
			end
			table.insert(heights, y)
			table.insert(slopes, math.abs(y - TerrainGenerator.surfaceYAt(gx - 1, gz, p)))
		end
	end

	local land = #heights
	if land == 0 then
		return { water = 100, wood = 0, farmland = 0, oil = oil }
	end

	local sorted = table.clone(heights)
	table.sort(sorted)
	local floorY = sorted[math.max(1, math.floor(land * LAND_FLOOR_PERCENTILE))]

	local wood, farm = 0, 0
	for i = 1, land do
		local rise = heights[i] - floorY
		if rise < FARM_MAX_RISE and slopes[i] < FARM_MAX_SLOPE then farm += 1 end
		if rise >= WOOD_MIN_RISE and rise < WOOD_MAX_RISE and slopes[i] < WOOD_MAX_SLOPE then wood += 1 end
	end

	return {
		water = pct(sea / (SAMPLES * SAMPLES), WATER_GAIN),
		wood = pct(wood / land, WOOD_GAIN),
		farmland = pct(farm / land, FARM_GAIN),
		oil = oil,
	}
end

-- Resources for a parameter set. `overrides` (a premade map's authored figures) wins
-- over the sampled value, key by key. Memoized: the picker re-asks on every repaint.
function MapResources.of(p: TerrainGenerator.GenParams, overrides: { [string]: number }?): Resources
	local key = signature(p)
	local cached = _memo[key]
	if not cached then
		if _memoCount >= MEMO_MAX then
			table.clear(_memo)
			_memoCount = 0
		end
		cached = sample(p)
		_memo[key] = cached
		_memoCount += 1
	end

	local out: Resources = { water = cached.water, wood = cached.wood, farmland = cached.farmland, oil = cached.oil }
	if overrides then
		for _, res in MapResources.List do
			local v = tonumber(overrides[res.id])
			if v then
				(out :: any)[res.id] = math.clamp(math.round(v), 0, 100)
			end
		end
	end
	return out
end

-- "Abundant" / "Plentiful" / ... for a 0-100 figure. One wording shared by every UI.
function MapResources.rank(value: number): string
	if value >= 80 then return "Abundant" end
	if value >= 60 then return "Plentiful" end
	if value >= 40 then return "Moderate" end
	if value >= 20 then return "Sparse" end
	return "Scarce"
end

return MapResources
