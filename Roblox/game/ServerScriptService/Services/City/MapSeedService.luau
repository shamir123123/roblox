--!strict
-- What a brand-new map ARRIVES with: the preset highways picked on the create screen, and
-- the trees and rocks growing on land nobody has built on yet.
--
-- Runs once, on the fresh-city branch of CitySlotService, and never on a load -- roads and
-- nature props are both persisted, so a saved city already carries whatever this laid down.
-- Everything goes through the owning service (RoadService.placeSegments,
-- NaturePlaceService.scatter), so a seeded highway is an ordinary road and a seeded tree is
-- an ordinary prop: it saves, it bulldozes, and it obeys the same placement rules.

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local Constants = require(RS:WaitForChild("Terrain"):WaitForChild("TerrainConstants"))
local RoadCrossSection = require(RS:WaitForChild("Terrain"):WaitForChild("RoadCrossSection"))
local NatureCatalog = require(RS:WaitForChild("Nature"):WaitForChild("NatureCatalog"))
-- TerrainDataService is an infra singleton (it owns the authoritative heightmap): required
-- directly per the project's dependency rules, never injected.
local TerrainDataService = require(SSS:WaitForChild("Services"):WaitForChild("Terrain"):WaitForChild("TerrainDataService"))

local MapSeedService = {}

local _roadService: any = nil
local _natureService: any = nil

local HALF = Constants.MAP_HALF_EXTENT
local SEA_Y = Constants.SEA_Y

local function groundY(x: number, z: number): number
	local ok, y = pcall(TerrainDataService.getSurfaceY, x, z)
	return if ok and typeof(y) == "number" and y == y then y else SEA_Y
end

-- == Highways ==================================================================

MapSeedService.MAX_HIGHWAYS = 4

local HIGHWAY_TYPE = "Highway4"
local STEP = 256          -- studs between waypoints: how closely a run follows the land
local EDGE_INSET = 8      -- stop this far inside the boundary; the edge tolerance that turns an end into an outside connection is 24
local DECK_OVER_SEA = 8   -- a run meeting water becomes a viaduct rather than a submerged road
local WANDER = 240        -- studs of sideways drift, so a motorway is not a ruled line
local SMOOTH_PASSES = 2
-- Preset highways BRIDGE, they never bore: tunnel walls are still flagged off
-- (RoadSceneRenderer.TUNNEL_WALLS_ENABLED), so a bored run would open into bare terrain.
-- A refused mode falls back to Ground, which is graded through the rise instead.
local ALLOW = table.freeze({ elevated = true, tunnel = false })

-- One run right across the map on the given axis. `across` is its centre offset on the
-- other axis; it drifts either side of that so the road reads as laid over the land.
local function runPoints(axis: string, across: number, seed: number): { Vector3 }
	local from, to = -HALF + EDGE_INSET, HALF - EDGE_INSET
	local steps = math.ceil((to - from) / STEP)
	local pts = table.create(steps + 1)
	for i = 0, steps do
		local t = from + (to - from) * (i / steps)
		local drift = math.sin(t / 1400 + seed) * WANDER + math.noise(t / 2600, seed) * WANDER
		local off = math.clamp(across + drift, -HALF + 400, HALF - 400)
		pts[i + 1] = Vector3.new(
			if axis == "x" then t else off,
			0,
			if axis == "x" then off else t
		)
	end
	return pts
end

-- Heights for a run: the land it crosses, smoothed into a grade a motorway could hold, and
-- never below a deck's clearance over the sea -- which is what makes a water crossing a
-- bridge instead of a road under it.
local function profile(pts: { Vector3 }): { Vector3 }
	local floorY = SEA_Y + DECK_OVER_SEA
	local ys = table.create(#pts)
	for i, p in pts do
		ys[i] = math.max(groundY(p.X, p.Z), floorY)
	end
	for _ = 1, SMOOTH_PASSES do
		local prev = ys[1]
		for i = 2, #ys - 1 do
			local cur = ys[i]
			ys[i] = (prev + cur * 2 + ys[i + 1]) * 0.25
			prev = cur
		end
	end
	local out = table.create(#pts)
	for i, p in pts do
		out[i] = Vector3.new(p.X, math.max(ys[i], floorY), p.Z)
	end
	return out
end

-- Catmull-Rom through the waypoints, written as the cubic Beziers RoadService places.
-- Straight thirds would kink at every joint; this is the same chain with a continuous tangent.
local function curves(pts: { Vector3 }): { any }
	local out = table.create(#pts - 1)
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local before = pts[math.max(i - 1, 1)]
		local after = pts[math.min(i + 2, #pts)]
		out[i] = { p0 = a, p1 = a + (b - before) / 6, p2 = b - (after - a) / 6, p3 = b }
	end
	return out
end

-- Lay the chain, cut into runs of ONE vertical mode each: a segment carries a single vMode
-- and RoadNetwork only welds matching ones, so a viaduct over a river is its own span with
-- ground road either side of it. nil means Ground -- the network's own default.
local function lay(cs: { any }, roadType: string)
	local batch: { any } = {}
	local mode: string? = nil
	local function flush()
		if #batch == 0 then return end
		local ok, err = pcall(_roadService.placeSegments, batch, roadType,
			if mode == RoadCrossSection.GROUND then nil else mode)
		if not ok then
			warn("[MapSeedService] highway span failed: " .. tostring(err))
		end
		batch = {}
	end
	for _, c in cs do
		local m = RoadCrossSection.verticalModeFor({ c.p0, c.p3 }, groundY, ALLOW)
		if m ~= mode then
			flush()
			mode = m
		end
		table.insert(batch, c)
	end
	flush()
end

-- 1 road runs east-west; the second crosses it north-south; 3 and 4 double each axis up.
-- Returns the PRIMARY run's points (nil when there are no highways), because the starting
-- interchange hangs off it and every one of those points is a real node in the graph.
function MapSeedService.seedHighways(count: any, seed: number): { Vector3 }?
	local n = math.clamp(math.floor(tonumber(count) or 0), 0, MapSeedService.MAX_HIGHWAYS)
	if n == 0 or not _roadService then return nil end

	local primary: { Vector3 }? = nil
	local plan = { { axis = "x", k = math.ceil(n / 2) }, { axis = "z", k = n // 2 } }
	for _, row in plan do
		for i = 1, row.k do
			-- One road sits near the middle; a pair straddles it wide enough that what lies
			-- between them is a city and not a central reservation. Jittered off the seed, so
			-- two cities on the same map shape are not handed the same motorway twice.
			local base = if row.k == 1 then 0 else (-1 + 2 * (i - 1) / (row.k - 1)) * 0.40
			local jitter = math.noise(seed * 0.37 + i, if row.axis == "x" then 0.5 else 8.5) * 0.14
			local pts = profile(runPoints(row.axis, (base + jitter) * HALF, seed + i))
			lay(curves(pts), HIGHWAY_TYPE)
			primary = primary or pts
		end
	end
	return primary
end

-- == Trees and rocks ===========================================================
-- Every new map arrives wooded, and wooded DIFFERENTLY in different places: the map is
-- divided into biomes, and a biome decides which species grow there, how thickly, and how
-- much of the ground between them is scrub rather than stone.
--
-- FORESTS, NOT A SPRINKLE. The prop budget is fixed (every tree is a full model, and this has
-- to run on low-end devices), so realism comes from WHERE the trees go. A ragged forest mask
-- decides where woodland is; inside it trees stand dense, at its edge they thin out, and out
-- in the open there is only the odd lone tree. When a map would grow more than the budget,
-- forest EDGES are dropped first, so what survives is solid stands -- an even random thinning
-- made every forest look moth-eaten instead.
--
-- Candidates sit on a jittered grid, and each one still goes through the ordinary planting
-- path, so anything standing on the highway that was just laid is simply refused.

local CELL = 36           -- studs between candidates: forest spacing
local MAX_PROPS = 2200
local LONE_SHARE = 0.2    -- at most this much of the budget goes to trees and scrub outside forests
local FOREST_EDGE = 0.14  -- mask units over which a forest thins from its core to open ground
local SHORE_Y = 3         -- at or below this the ground is beach or under water
-- Too steep to take root. The TerrainLandform maps have real mountainsides (40 degrees and
-- more); the old limit of 12 was tuned when no map went past 24, and on the new ones it
-- turned every forested slope into scree.
local ROCK_SLOPE = math.rad(30)
local PLANT_SLICE = 200

local function keysOf(kind: string): { string }
	local out: { string } = {}
	for _, k in NatureCatalog.order do
		local e = NatureCatalog.get(k)
		-- A clipped hedge is garden furniture, not something that grows on its own.
		if e and e.kind == kind and not string.find(k, "Hedge") then
			table.insert(out, k)
		end
	end
	return out
end

local ROCKS = keysOf("Rock")
local BUSHES = keysOf("Bush")

-- The biomes. `trees` is the species that grow here, `cover` the forest-mask level above which
-- the land is woodland (lower = more of it), `density` how full a forest's core is, `ground`
-- how often an open cell carries scrub or stone anyway, and `rock` how much of that is stone.
--
-- The species are written out rather than derived: which tree grows where IS the content,
-- and a rule that picked them by name would be a worse version of this list.
type Biome = { trees: { string }, cover: number, density: number, ground: number, rock: number }
local BIOMES: { [string]: Biome } = table.freeze({
	-- Above the treeline: bare stone with a few wind-bitten conifers holding on.
	alpine = table.freeze({
		trees = table.freeze({ "SpruceTree", "PineTree" }),
		cover = 0.45, density = 0.35, ground = 0.3, rock = 0.85,
	}),
	-- Cold and high: dense evergreen, very little between the trunks.
	conifer = table.freeze({
		trees = table.freeze({ "SpruceTree", "PineTree", "BirchTree", "PoplarTree" }),
		cover = -0.12, density = 0.95, ground = 0.06, rock = 0.3,
	}),
	-- Temperate lowland: the thickest, mixed woodland, and the only one with real undergrowth.
	broadleaf = table.freeze({
		trees = table.freeze({ "OakTree", "ChestnutTree", "BroadleafTree", "ElderTree", "BirchTree" }),
		cover = -0.02, density = 0.9, ground = 0.08, rock = 0.15,
	}),
	-- Dry open country: a tree here and there, mostly scrub. This is where a city gets built.
	plains = table.freeze({
		trees = table.freeze({ "OakTree", "PoplarTree", "ElderTree" }),
		cover = 0.32, density = 0.8, ground = 0.05, rock = 0.25,
	}),
	-- The shore: palms, and the odd broadleaf behind them.
	coastal = table.freeze({
		trees = table.freeze({ "RoyalPalm", "CoconutPalm", "SylvesterPalm", "FloridaPalm",
			"PalmMedium", "PalmYoung", "BroadleafTree" }),
		cover = 0.18, density = 0.7, ground = 0.06, rock = 0.3,
	}),
})

-- A biome names its species directly, so a renamed catalog key would otherwise just go
-- quiet -- that biome would simply stop growing anything. Say so at load instead.
for name, b in BIOMES do
	for _, k in b.trees do
		if not NatureCatalog.get(k) then
			warn(("[MapSeedService] biome %s lists unknown species %s"):format(name, k))
		end
	end
end

local COAST_PROBE = 240   -- how far a palm may stand from open water

-- A palm is a SHORELINE tree, and "low" alone does not say shoreline: flat inland country
-- sits just as low, and keying the coastal biome off height by itself turned a prairie into
-- a palm grove. It has to be low AND within sight of open water.
--
-- And OPEN water: wet at COAST_PROBE and still wet twice as far out in the same direction.
-- A river is ~50 studs across, so a single probe that landed in one made every river bank a
-- palm beach -- on a map with no sea at all -- and kept the riverside woods off it.
local function wetOut(x: number, z: number, dx: number, dz: number): boolean
	return groundY(x + dx * COAST_PROBE, z + dz * COAST_PROBE) <= SEA_Y
		and groundY(x + dx * COAST_PROBE * 2, z + dz * COAST_PROBE * 2) <= SEA_Y
end
local function nearSea(x: number, z: number): boolean
	return wetOut(x, z, -1, 0) or wetOut(x, z, 1, 0) or wetOut(x, z, 0, -1) or wetOut(x, z, 0, 1)
end

local COAST_Y = 14        -- above this the shore is behind you
local BIOME_STUDS = 1500  -- wavelength of the moisture field, so a biome is a REGION
-- Relief a map needs before it HAS a treeline / a cold upland at all, and where in its own
-- height range each line then falls.
local ALPINE_SPAN, ALPINE_FRAC = 40, 0.80
local CONIFER_SPAN, CONIFER_FRAC = 25, 0.45

type Band = { alpine: number, conifer: number }

-- Where the treeline and the conifer line fall ON THIS MAP, sampled once per city. They have
-- to be relative: measured across the presets, Flatlands never leaves 15 studs while High
-- Ridge runs to 127, so one treeline written in studs is either every peak in the game or
-- none of them. A map without the relief to have highlands gets NEITHER line, which is how a
-- plain stays a plain instead of growing a snowline over its highest field.
local function heightBand(): Band
	local ys: { number } = {}
	for iz = 0, 39 do
		for ix = 0, 39 do
			local y = groundY(-HALF + ix / 39 * HALF * 2, -HALF + iz / 39 * HALF * 2)
			if y > SHORE_Y then table.insert(ys, y) end
		end
	end
	if #ys < 40 then return { alpine = math.huge, conifer = math.huge } end
	table.sort(ys)
	-- Percentiles, not min/max: one noise spike must not define the whole map's range.
	local lo = ys[math.max(1, math.floor(#ys * 0.1))]
	local span = ys[math.floor(#ys * 0.99)] - lo
	return {
		alpine = if span >= ALPINE_SPAN then lo + span * ALPINE_FRAC else math.huge,
		conifer = if span >= CONIFER_SPAN then lo + span * CONIFER_FRAC else math.huge,
	}
end

-- Which biome a point belongs to. Height decides first -- stone above the treeline, evergreen
-- in the cold band below it, palms on the shore -- and everything height does not claim is
-- split by a low-frequency MOISTURE field, so conifer, broadleaf and open plains arrive as
-- regions you can walk out of rather than mixed evenly across the whole map.
local function biomeAt(x: number, z: number, y: number, seed: number, band: Band): Biome
	if y > band.alpine then return BIOMES.alpine end
	if y > band.conifer then return BIOMES.conifer end
	if y < COAST_Y and nearSea(x, z) then return BIOMES.coastal end
	local moisture = math.noise(x / BIOME_STUDS, z / BIOME_STUDS, seed + 17)
	if moisture < -0.12 then return BIOMES.plains end
	if moisture > 0.1 then return BIOMES.conifer end
	return BIOMES.broadleaf
end

local function pick(rng: Random, set: { string }): string
	return set[rng:NextInteger(1, #set)]
end

-- Studs of grass kept between a planted prop and the edge of any carriageway. The planting
-- rule on its own only refuses a prop whose footprint actually TOUCHES the road, which
-- stands a tree flush against the asphalt; a laid-out map wants a verge there.
local ROAD_VERGE = 14

-- A template's own height, for the verge test. The road rule judges a prop over its whole
-- height (RoadProximity.reachesLayer), so a bridge deck and the ground under it stay
-- different places. Cached: this is asked once per candidate.
local _propHeight: { [string]: number } = {}
local function propHeight(key: string): number
	local cached = _propHeight[key]
	if cached then return cached end
	local tpl = RS.Nature:FindFirstChild(key)
	local h = 0
	if tpl and tpl:IsA("Model") then
		local _, size = (tpl :: Model):GetBoundingBox()
		h = size.Y
	end
	_propHeight[key] = h
	return h
end

-- Where woodland is: three scales so a forest has a body, bays and ragged fringes. ~[-1, 1].
local function forestMask(x: number, z: number, seed: number): number
	return math.noise(x / 1300, z / 1300, seed + 41) * 0.7
		+ math.noise(x / 420, z / 420, seed + 43) * 0.35
		+ math.noise(x / 140, z / 140, seed + 47) * 0.15
end

-- Low ground a short walk from INLAND water -- a river bank or a lake shore -- is where the
-- thickest woods grow. Only asked of low ground, and only for non-coastal land.
-- Two rings, because a river is only ~50 studs wide: probes at one radius mostly land on the
-- banks either side of it and see no water at all.
local RIVERSIDE_PROBES = table.freeze({ 50, 110 })
local RIVERSIDE_Y = 12
local RIVERSIDE_BONUS = 0.35
local function nearWater(x: number, z: number): boolean
	for _, r in RIVERSIDE_PROBES do
		if groundY(x - r, z) <= SEA_Y or groundY(x + r, z) <= SEA_Y
			or groundY(x, z - r) <= SEA_Y or groundY(x, z + r) <= SEA_Y then
			return true
		end
	end
	return false
end

-- Species come in STANDS: neighbouring trees mostly share one, as they do in a real wood,
-- with a minority mixed through so a stand is not a monoculture.
local function speciesAt(rng: Random, biome: Biome, x: number, z: number, seed: number): string
	if rng:NextNumber() < 0.3 then return pick(rng, biome.trees) end
	local n = (math.noise(x / 380, z / 380, seed + 53) + 1) * 0.5
	local i = math.clamp(math.floor(n * #biome.trees) + 1, 1, #biome.trees)
	return biome.trees[i]
end

type Planted = { key: string, pos: Vector3, yaw: number, scale: number, wild: boolean }

function MapSeedService.seedNature(seed: number)
	if not _natureService then return end
	local rng = Random.new(math.floor(seed * 1000))
	local band = heightBand()
	-- Forest trees carry how deep in the forest they stand, so trimming takes edges first.
	local forest: { { item: Planted, depth: number } } = {}
	local lone: { Planted } = {}
	local cells = (HALF * 2) // CELL

	for iz = 0, cells - 1 do
		for ix = 0, cells - 1 do
			local x = -HALF + (ix + rng:NextNumber(0.15, 0.85)) * CELL
			local z = -HALF + (iz + rng:NextNumber(0.15, 0.85)) * CELL
			local mask = forestMask(x, z, seed)
			local roll = rng:NextNumber()
			-- Cheap reject first: most candidates are open country that grows nothing, and
			-- this keeps the heightmap queries to the ones that might.
			if mask < -0.2 and roll > 0.06 then continue end
			local y = groundY(x, z)
			if y <= SHORE_Y then continue end

			local key: string? = nil
			local depth = -1
			if TerrainDataService.getSlopeAt(x, z) > ROCK_SLOPE then
				-- Steep ground is scree whatever biome it sits in: nothing takes root on it.
				key = if roll < 0.12 then pick(rng, ROCKS) else nil
			else
				local biome = biomeAt(x, z, y, seed, band)
				if y < RIVERSIDE_Y and biome ~= BIOMES.coastal and nearWater(x, z) then
					mask += RIVERSIDE_BONUS
				end
				depth = (mask - biome.cover) / FOREST_EDGE
				if depth > 0 then
					-- Thin at the fringe, full in the core.
					if roll < biome.density * math.min(0.35 + depth, 1) then
						key = speciesAt(rng, biome, x, z, seed)
					end
				elseif roll < 0.012 then
					key = pick(rng, biome.trees) -- a lone tree out in the open
				elseif roll < 0.012 + biome.ground * 0.25 then
					key = if rng:NextNumber() < biome.rock then pick(rng, ROCKS) else pick(rng, BUSHES)
				end
			end
			if not key then continue end

			local entry = NatureCatalog.get(key)
			if not entry then continue end
			local scale = rng:NextNumber(entry.minScale, entry.maxScale)

			-- The road rule reads `pos.Y` as the prop's BASE and asks whether the prop
			-- reaches the road's layer from there. Passing Y = 0 put every base below every
			-- deck, so only props TALLER than the road was high registered as touching it --
			-- which is how rocks and bushes came to sit on the carriageway while the trees
			-- stayed off it. The seat is the ground here, and it has to say so.
			local pos = Vector3.new(x, y, z)
			if _roadService and _roadService.isPointNearRoad(
				pos, entry.radius * scale + ROAD_VERGE, propHeight(key) * scale) then
				continue
			end

			-- `wild`: the map's OWN vegetation, so it grows across the whole map rather than
			-- only on the one tile the city starts owning. A forest is not something the
			-- player placed, and NaturePlaceService's territory gate honours that.
			local item: Planted = { key = key, pos = pos, yaw = rng:NextNumber(0, math.pi * 2), scale = scale, wild = true }
			if depth > 0 then
				forest[#forest + 1] = { item = item, depth = depth }
			else
				lone[#lone + 1] = item
			end
		end
		if iz % 16 == 0 then task.wait() end
	end

	-- The open-country share is capped and thinned at random (it is scattered anyway); the
	-- forests get the rest of the budget, deepest trees first.
	local loneCap = math.floor(MAX_PROPS * LONE_SHARE)
	while #lone > loneCap do
		local i = rng:NextInteger(1, #lone)
		lone[i] = lone[#lone]
		lone[#lone] = nil
	end
	table.sort(forest, function(p, q) return p.depth > q.depth end)
	local items: { any } = lone
	for i = 1, math.min(#forest, MAX_PROPS - #lone) do
		items[#items + 1] = forest[i].item
	end

	_natureService.scatter(items, PLANT_SLICE)
end

-- == The starting interchange ==================================================
-- A motorway you cannot get off is not a highway system. Cities: Skylines opens every map
-- the same way and this is that: ramps peel off the trunk road, meet the head of a short
-- avenue, and the avenue runs on into open country -- which is where the player builds.
--
-- It hangs off the PRIMARY run's own waypoints, which are already nodes in the graph, so the
-- ramps weld onto the trunk road rather than needing a segment split at an arbitrary point.
-- Laid only when there IS a highway: 0 means the player asked for a blank map.

local RAMP_TYPE = "Highway1W"            -- the catalog's own "Ramp": one lane, one-way
local START_ROAD_TYPE = "CollectorRoad"  -- an avenue: two-way, with footways, ready to zone
local RAMP_SPREAD = 150   -- studs from the trunk road out to where the ramps meet the avenue
local START_LEN = 520     -- how far the avenue then runs on into open land
local RAMP_SPAN = 1       -- waypoints up and down the trunk road that the ramps leave from
local START_MIN_LAND = 0.45 -- below this the best spot on the map is still not worth opening on

-- The trunk road's own direction at a waypoint.
local function alongAt(pts: { Vector3 }, i: number): Vector3
	local a = pts[math.max(i - 1, 1)]
	local b = pts[math.min(i + 1, #pts)]
	local d = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	return if d.Magnitude < 1e-3 then Vector3.new(1, 0, 0) else d.Unit
end

-- How much of the land around a point a city could actually be put on. This is what decides
-- WHERE the map opens, so a fresh city never starts facing a lake or a cliff.
local function buildability(cx: number, cz: number): number
	local ok, total = 0, 0
	for r = 120, 480, 120 do
		for a = 0, 5 do
			local th = a / 6 * math.pi * 2
			local x, z = cx + math.cos(th) * r, cz + math.sin(th) * r
			total += 1
			if groundY(x, z) > SHORE_Y + 4 and TerrainDataService.getSlopeAt(x, z) < ROCK_SLOPE then
				ok += 1
			end
		end
	end
	return ok / total
end

-- Returns where the map now opens (the head of the avenue), or nil if it laid nothing.
function MapSeedService.seedStartJunction(primary: { Vector3 }?, seed: number): Vector3?
	if not _roadService or not primary or #primary < RAMP_SPAN * 2 + 4 then return nil end
	local pts = primary :: { Vector3 }

	-- Walk the WHOLE trunk road and take the exit with the most buildable land beside it, on
	-- the better of its two sides. It does not matter where on the map that lands -- the
	-- camera is pointed at it below, and the player buys their way outward from there.
	-- The seed jitter only breaks TIES: on an evenly buildable map every candidate scores
	-- the same, and picking the first examined would open every such map at its west edge.
	-- It is far too small to beat a real difference in the land.
	local bestI, bestSide, bestScore = 0, 1, -1
	for i = RAMP_SPAN + 2, #pts - RAMP_SPAN - 1 do
		local p = pts[i]
		local dir = alongAt(pts, i)
		local perp = Vector3.new(-dir.Z, 0, dir.X)
		for _, side in { 1, -1 } do
			local c = p + perp * side * (RAMP_SPREAD + START_LEN * 0.5)
			local score = buildability(c.X, c.Z) + math.noise(i * 0.31, side * 3.7, seed) * 0.05
			if score > bestScore then
				bestScore, bestI, bestSide = score, i, side
			end
		end
	end
	-- Nowhere on this map is worth opening onto (a tight archipelago, say). Leave the trunk
	-- road bare rather than running an avenue into the sea.
	if bestI == 0 or bestScore < START_MIN_LAND then return nil end

	local dir = alongAt(pts, bestI)
	local n = Vector3.new(-dir.Z, 0, dir.X) * bestSide
	local floorY = SEA_Y + DECK_OVER_SEA
	local function seat(p: Vector3): Vector3
		return Vector3.new(p.X, math.max(groundY(p.X, p.Z), floorY), p.Z)
	end

	local head = seat(pts[bestI] + n * RAMP_SPREAD)         -- where both ramps meet the avenue
	local tail = seat(pts[bestI] + n * (RAMP_SPREAD + START_LEN))
	local back, fwd = pts[bestI - RAMP_SPAN], pts[bestI + RAMP_SPAN]

	local function flat(a: Vector3, b: Vector3): number
		return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
	end

	-- The off-ramp peels off the trunk road tangentially and arrives at the head pointing
	-- straight up the avenue, so those two weld into one continuous route off the motorway.
	-- The on-ramp is its mirror and branches back, which is what makes the pair read as one
	-- interchange rather than two roads that happen to touch.
	local offLen = flat(head, back)
	lay({ { p0 = back, p1 = back + dir * (offLen / 3), p2 = head - n * (offLen / 3), p3 = head } }, RAMP_TYPE)

	local onLen = flat(fwd, head)
	lay({ { p0 = head, p1 = head - n * (onLen / 3), p2 = fwd - dir * (onLen / 3), p3 = fwd } }, RAMP_TYPE)

	lay({ { p0 = head, p1 = head:Lerp(tail, 1 / 3), p2 = head:Lerp(tail, 2 / 3), p3 = tail } }, START_ROAD_TYPE)
	return head
end

-- == Lifecycle =================================================================

function MapSeedService.Init(roadService: any, naturePlaceService: any)
	assert(roadService, "[MapSeedService] requires RoadService")
	assert(naturePlaceService, "[MapSeedService] requires NaturePlaceService")
	_roadService = roadService
	_natureService = naturePlaceService
end

-- Dress a freshly generated map. Yields: every step grades terrain and places instances.
-- Order is load-bearing: all the road goes down first, so the scatter can see it and refuse
-- a tree standing on it -- and the interchange needs the trunk road to already exist.
--
-- Returns WHERE THE MAP OPENS -- the head of the starting avenue -- so the caller can point
-- a new city's camera at it, or nil when nothing was laid (no highways, or no land worth
-- starting on), in which case the camera keeps its own default over the origin.
function MapSeedService.seed(gen: any, highways: any): Vector3?
	local seed = tonumber(if typeof(gen) == "table" then gen.seed else nil) or 0
	local primary = MapSeedService.seedHighways(highways, seed)
	local startAt = MapSeedService.seedStartJunction(primary, seed)
	MapSeedService.seedNature(seed)
	return startAt
end

return MapSeedService
