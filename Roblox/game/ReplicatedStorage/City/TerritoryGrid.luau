--!strict
-- The city's buyable LAND: a 16x16 grid of 512-stud tiles laid over the map. A new city
-- owns the 3x3 block around its start; every other tile is bought, ANYWHERE on the map --
-- there is no adjacency rule, a far island is as buyable as the tile next door. This is the
-- Cities: Skylines 2 tile system, with its three levers:
--   * PERMITS -- each milestone raises how many tiles the city may hold (allowanceFor)
--   * PRICE   -- each tile costs money up front, rising with how many you hold (priceFor)
--   * UPKEEP  -- every BOUGHT tile costs money each month (UPKEEP_PER_TILE)
--
-- Not to be confused with the two things already called something similar:
--   * PlotService's burgage plots -- the zoning system, one building's frontage on a street.
--   * ZoneGrid.LOT_SIZE -- one building's footprint.
-- This is territory: which ground you are allowed to build on at all.
--
-- Pure library: no lifecycle, no state, no side effects on require. Client and server both
-- run it, so the price the tile panel quotes is the price the server charges.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TerrainConstants = require(ReplicatedStorage.Terrain.TerrainConstants)

local TerritoryGrid = {}

TerritoryGrid.TILES_PER_AXIS = 16
TerritoryGrid.TOTAL = 256
TerritoryGrid.TILE_STUDS = TerrainConstants.MAP_EXTENT / TerritoryGrid.TILES_PER_AXIS -- 512
-- The grid saves made before 2026-09-22 used. Only `fromLegacy` reads it.
TerritoryGrid.LEGACY_TILES_PER_AXIS = 6

local N = TerritoryGrid.TILES_PER_AXIS
local TILE = TerritoryGrid.TILE_STUDS
local HALF = TerrainConstants.MAP_HALF_EXTENT

-- The block a new city starts on, and the tiles that never cost upkeep.
TerritoryGrid.START_SIDE = 3
TerritoryGrid.START_TILES = 9

-- == Permits ===================================================================
-- How many tiles a city at milestone tier N may hold, 1 (Founding) to 20 (Megalopolis).
-- Every milestone grants some, the grants grow, and the last one opens the whole map.
local PERMITS = table.freeze({ 9, 12, 16, 20, 25, 31, 38, 46, 55, 65, 76, 88, 101, 115, 130, 146, 164, 184, 210, 256 })
TerritoryGrid.PERMITS = PERMITS

function TerritoryGrid.allowanceFor(tier: number): number
	return PERMITS[math.clamp(math.floor(tonumber(tier) or 1), 1, #PERMITS)]
end

-- == Money =====================================================================
-- Calibrated against the economy that exists: $50,000 starting treasury, milestone payouts
-- of $5,000 (Tiny Village) to $200,000 (Megalopolis). The first extra tile is $1,000, the
-- last $7,150, and the whole map about $1,000,000 -- a real sink, spread over five hours.
TerritoryGrid.BASE_PRICE = 1000
TerritoryGrid.PRICE_STEP = 25
-- Monthly, per tile BOUGHT (the starting block and grandfathered land are free). A street
-- across one tile costs ~$1,500/month, so land is about a tenth of what you build on it.
TerritoryGrid.UPKEEP_PER_TILE = 150

-- What the NEXT tile costs when you already hold `owned` of them.
function TerritoryGrid.priceFor(owned: number): number
	return TerritoryGrid.BASE_PRICE + math.max(0, math.floor(owned) - TerritoryGrid.START_TILES) * TerritoryGrid.PRICE_STEP
end

-- What `count` tiles cost bought together, holding `owned`: each one is priced as the next.
function TerritoryGrid.priceForBatch(owned: number, count: number): number
	local sum = 0
	for k = 0, math.max(0, math.floor(count)) - 1 do
		sum += TerritoryGrid.priceFor(owned + k)
	end
	return sum
end

-- == Geometry ==================================================================

-- Tile coordinates (0-based) containing a world point. Clamped: the grid IS the map, so a
-- point on the boundary belongs to the edge tile rather than to nothing.
function TerritoryGrid.tileAt(x: number, z: number): (number, number)
	local ix = math.clamp(math.floor((x + HALF) / TILE), 0, N - 1)
	local iz = math.clamp(math.floor((z + HALF) / TILE), 0, N - 1)
	return ix, iz
end

-- A tile's id: 1..TOTAL, which is what the save stores (one small int per owned tile).
function TerritoryGrid.idOf(ix: number, iz: number): number
	return iz * N + ix + 1
end

function TerritoryGrid.fromId(id: number): (number, number)
	local i = math.floor(id) - 1
	return i % N, i // N
end

function TerritoryGrid.isValidId(id: any): boolean
	local n = tonumber(id)
	return n ~= nil and n == math.floor(n) and n >= 1 and n <= TerritoryGrid.TOTAL
end

function TerritoryGrid.idAt(x: number, z: number): number
	return TerritoryGrid.idOf(TerritoryGrid.tileAt(x, z))
end

-- minX, minZ, maxX, maxZ in world studs.
function TerritoryGrid.boundsOf(id: number): (number, number, number, number)
	local ix, iz = TerritoryGrid.fromId(id)
	local minX = -HALF + ix * TILE
	local minZ = -HALF + iz * TILE
	return minX, minZ, minX + TILE, minZ + TILE
end

function TerritoryGrid.centerOf(id: number): (number, number)
	local minX, minZ = TerritoryGrid.boundsOf(id)
	return minX + TILE * 0.5, minZ + TILE * 0.5
end

-- Every tile id inside the grid-aligned rectangle spanned by two tiles, either order.
-- The tile view's drag-box selection.
function TerritoryGrid.idsInRect(a: number, b: number): { number }
	local ax, az = TerritoryGrid.fromId(a)
	local bx, bz = TerritoryGrid.fromId(b)
	local out: { number } = {}
	for iz = math.min(az, bz), math.max(az, bz) do
		for ix = math.min(ax, bx), math.max(ax, bx) do
			table.insert(out, TerritoryGrid.idOf(ix, iz))
		end
	end
	return out
end

-- The starting block: START_SIDE x START_SIDE centred on the tile under `x, z`, shifted
-- inward at the map edge so a city starting in a corner still gets all nine.
function TerritoryGrid.startIds(x: number, z: number): { number }
	local ix, iz = TerritoryGrid.tileAt(x, z)
	local r = TerritoryGrid.START_SIDE // 2
	ix = math.clamp(ix, r, N - 1 - r)
	iz = math.clamp(iz, r, N - 1 - r)
	return TerritoryGrid.idsInRect(TerritoryGrid.idOf(ix - r, iz - r), TerritoryGrid.idOf(ix + r, iz + r))
end

-- A save from the 6x6 era: every new tile whose CENTRE stood on land the city owned then.
-- The grids do not align, so the border moves by up to half a tile -- never more.
function TerritoryGrid.fromLegacy(legacyIds: { any }): { number }
	local L = TerritoryGrid.LEGACY_TILES_PER_AXIS
	local legacyTile = TerrainConstants.MAP_EXTENT / L
	local had: { [number]: boolean } = {}
	for _, raw in legacyIds do
		local n = tonumber(raw)
		if n and n == math.floor(n) and n >= 1 and n <= L * L then had[n] = true end
	end
	local out: { number } = {}
	for id = 1, TerritoryGrid.TOTAL do
		local cx, cz = TerritoryGrid.centerOf(id)
		local lx = math.clamp(math.floor((cx + HALF) / legacyTile), 0, L - 1)
		local lz = math.clamp(math.floor((cz + HALF) / legacyTile), 0, L - 1)
		if had[lz * L + lx + 1] then table.insert(out, id) end
	end
	return out
end

-- Does a BOX (an axis-aligned footprint, half-extents hx/hz about a centre) lie entirely
-- inside the owned set? Asked of anything with real size -- a building, a car park -- so a
-- footprint cannot straddle the border with half of itself on land you do not own.
-- `owned` is an id-keyed set.
function TerritoryGrid.boxOwned(owned: { [number]: boolean }, x: number, z: number, hx: number, hz: number): boolean
	local ix0, iz0 = TerritoryGrid.tileAt(x - hx, z - hz)
	local ix1, iz1 = TerritoryGrid.tileAt(x + hx, z + hz)
	for iz = iz0, iz1 do
		for ix = ix0, ix1 do
			if not owned[TerritoryGrid.idOf(ix, iz)] then return false end
		end
	end
	return true
end

return table.freeze(TerritoryGrid)
