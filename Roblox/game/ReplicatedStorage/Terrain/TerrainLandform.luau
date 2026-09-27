--!strict
-- Generator v3 ("algo 3"): landforms that read like a real map -- fractal coastlines, mountain
-- ranges, meandering rivers with tributaries, lakes -- instead of noise blobs.
--
-- Two stages. A coarse MACRO FIELD (FIELD_N^2 nodes, 32 studs apart) holds everything large:
-- the shape of the land, the warp that makes coasts wander, the mountain massifs and the river
-- valleys. It is built once per params (~0.2 s) and cached. `sample` is then a cheap point
-- function: bicubic over the field, plus the detail that is finer than a node -- ridge crests,
-- surface grain, and the river channel itself (rivers are polylines, so banks are sharp).
--
-- THE FIELD MUST NOT HOLD DETAIL FINER THAN ~4 NODES. Octaves shorter than that alias through
-- the bicubic into a grid-aligned zig-zag on every slope; that is why the octave counts below
-- are capped and the crests live in `sample`. (A stream-power erosion pass was tried here: it
-- cost 0.75 s per map for valleys barely visible at map scale, so it went.)
--
-- Deterministic for equal params on every machine: server and client both regenerate the base
-- map from params alone and must agree to the height quantum.

local Constants = require(script.Parent.TerrainConstants)

local TerrainLandform = {}

export type Params = {
	seed: number,
	heightRange: number?,
	oceanLevel: number?,
	baseHeight: number?,
	ruggedness: number?,
	shape: string?,
	persistence: number?,
	lacunarity: number?,
}

-- halfWidth is never under ~26: TerrainGenerator samples these maps every 16 studs, and a
-- narrower channel can fall between samples and come out dry.
type River = { ax: number, az: number, bx: number, bz: number, halfWidth: number }

export type Field = {
	h: { number }, -- FIELD_N * FIELD_N node heights, worldY before the final lift
	rivers: { River },
	riverCells: { [number]: { number } }, -- RIVER_CELL buckets -> indices into rivers
	lift: number, -- baseHeight - oceanLevel
	seed: number,
}

local HALF = Constants.MAP_HALF_EXTENT
local FIELD_N = 257
local CELL = Constants.MAP_EXTENT / (FIELD_N - 1) -- 32 studs between nodes
local RIVER_CELL = 256
local RIVER_BUCKETS = math.ceil(Constants.MAP_EXTENT / RIVER_CELL) + 2
local SEA_FLOOR = Constants.FLOOR_Y + 6

local RIVER_DEPTH = -7 -- channel bed worldY: below sea, so the channel holds water
local FLOODPLAIN_Y = 3.5

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Normalised fBm, ~[-0.7, 0.7]. The +0.37 offsets keep samples off the integer lattice, where
-- math.noise is exactly zero.
local function fbm(x: number, z: number, seed: number, octaves: number, gain: number, lac: number): number
	local sum, amp, freq, norm = 0, 1, 1, 0
	for i = 1, octaves do
		sum += amp * math.noise(x * freq + 0.37, z * freq + 0.37, seed + i * 13.1)
		norm += amp
		amp *= gain
		freq *= lac
	end
	return sum / norm
end

-- Ridged multifractal, 0..1: sharp crests, and each octave weighted by the last, so the fine
-- ridges sit on the big ones rather than sprinkled evenly over the slopes.
local function ridged(x: number, z: number, seed: number, octaves: number, gain: number, lac: number): number
	local sum, amp, freq, norm, weight = 0, 1, 1, 0, 1
	for i = 1, octaves do
		local n = 1 - math.abs(math.noise(x * freq + 0.37, z * freq + 0.37, seed + i * 29.3) * 1.6)
		n = math.max(n, 0)
		n = n * n * weight
		weight = math.clamp(n * 1.8, 0, 1)
		sum += n * amp
		norm += amp
		amp *= gain
		freq *= lac
	end
	return sum / norm
end

-- Signed land field for a macro shape: > 0 is land, < 0 sea, magnitude ~ how far in.
-- (uw, vw) are warped map coordinates in [-1, 1]; c is the continent noise.
local function shapeField(shape: string, c: number, uw: number, vw: number, seed: number, wx: number, wz: number): number
	local r = math.sqrt(uw * uw + vw * vw)
	if shape == "island" then
		return 0.58 - r * 1.05 + c * 0.55
	elseif shape == "archipelago" then
		local isles = fbm(wx / 1500, wz / 1500, seed + 5, 4, 0.5, 2.1)
		return isles * 1.25 + c * 0.35 - 0.12 - smoothstep(0.75, 1.3, r) * 0.6
	elseif shape == "coast" then
		-- Headlands and bays at two scales on top of the continent noise, so the shoreline
		-- wanders in and out instead of running as one ruled line down the map.
		local bays = fbm(wx / 2300, wz / 2300, seed + 23, 4, 0.5, 2)
		return -uw * 0.45 + c * 0.6 + bays * 0.6 + 0.05
	elseif shape == "peninsula" then
		local core = 0.36 - math.abs(uw + vw * 0.15) * 1.3
		local tip = smoothstep(-0.35, -0.9, vw)
		local mainland = smoothstep(0.62, 1.0, vw)
		return math.max(core - tip * 0.8, mainland * 0.6 - 0.2) + c * 0.45
	elseif shape == "bay" then
		-- The inlet is stretched toward the sea side so its mouth always opens; a round one
		-- left a strip of land across it and the bay came out as a lake.
		local dx = if uw > 0.3 then (uw - 0.3) / 2.2 else (uw - 0.3) / 0.8
		local dz = vw / 0.6
		local inlet = 0.52 - math.sqrt(dx * dx + dz * dz)
		return 0.34 + c * 0.45 - math.max(0, uw - 0.7) * 2.6 - math.max(0, inlet) * 1.9
	elseif shape == "lake" then
		local centre = 0.34 - r
		local ponds = fbm(wx / 1100, wz / 1100, seed + 41, 3, 0.5, 2) - 0.27
		return 0.3 + c * 0.3 - math.max(0, centre) * 1.8 - math.max(0, ponds) * 2.4
	elseif shape == "river" or shape == "landlocked" then
		return 0.34 + c * 0.3
	elseif shape == "highlands" then
		local tarns = fbm(wx / 800, wz / 800, seed + 43, 3, 0.5, 2) - 0.3
		return 0.42 + c * 0.3 - math.max(0, tarns) * 2.2
	end
	return c * 0.9 + 0.1 -- continent
end

-- How much of the land is mountain country, before the inland fade.
local MOUNTAIN_BIAS = table.freeze({
	continent = 0, island = 0.05, archipelago = 0.1, coast = 0.05, peninsula = 0,
	bay = 0, lake = -0.05, river = -0.15, landlocked = -0.05, highlands = 0.35,
})

-- Steps a river keeps going once it reaches water, so the channel runs INTO the sea or lake
-- rather than stopping a bank's width short of it.
local MOUTH_STEPS = 3

-- A meandering river as a polyline: a heading random walk steered back toward `target`
-- (a world direction in radians) so it wanders but crosses the map. It only draws over land:
-- nothing is recorded until it first reaches dry ground, and it ends MOUTH_STEPS after it
-- next meets water. Planning a river without the land under it is what sent them straight
-- on across the seabed and out the far side of a bay.
local function meander(x: number, z: number, dir: number, target: number, seed: number, maxLen: number, halfWidth: number, isWet: (number, number) -> boolean, out: { River })
	local step = 24
	local s = 0
	local h = dir
	local reachedLand = false
	local mouth = -1
	while s < maxLen and mouth ~= 0 do
		local turn = math.noise(s / 620 + 0.37, seed * 0.13 + 0.5, 3.3) * 1.3
			+ math.noise(s / 190 + 0.37, seed * 0.13 + 1.5, 7.7) * 0.6
		local off = (target - h + math.pi) % (2 * math.pi) - math.pi
		h += turn * 0.11 + off * 0.035
		local nx, nz = x + math.cos(h) * step, z + math.sin(h) * step
		local wet = isWet(nx, nz)
		if not wet then reachedLand = true end
		if reachedLand then
			out[#out + 1] = { ax = x, az = z, bx = nx, bz = nz, halfWidth = halfWidth }
			if mouth > 0 then
				mouth -= 1
			elseif mouth < 0 and wet then
				mouth = MOUTH_STEPS
			end
		end
		x, z = nx, nz
		s += step
		if math.abs(x) > HALF + 200 or math.abs(z) > HALF + 200 then break end
	end
end

local function planRivers(shape: string, seed: number, isWet: (number, number) -> boolean): { River }
	local rivers: { River } = {}
	local rng = Random.new(math.floor(seed * 1000) % 2147483647)
	if shape == "river" then
		-- One main river edge to edge, west to east, and two tributaries joining it.
		local z0 = rng:NextNumber(-0.35, 0.35) * HALF
		meander(-HALF - 150, z0, 0, 0, seed, 16000, 34, isWet, rivers)
		local mainCount = #rivers
		if mainCount > 8 then
			for k = 1, 2 do
				local seg = rivers[math.max(math.floor(mainCount * (0.3 + 0.35 * (k - 1))), 1)]
				local side = if k == 1 then -1 else 1
				meander(seg.bx, seg.bz, side * math.pi / 2, side * math.pi / 2 + 0.3, seed + k * 7, 5200, 26, isWet, rivers)
			end
		end
	elseif shape == "coast" or shape == "continent" or shape == "bay" then
		-- One river from the inland (west) edge toward the sea (east).
		local z0 = rng:NextNumber(-0.5, 0.5) * HALF
		meander(-HALF - 150, z0, 0, 0, seed + 3, 9000, 28, isWet, rivers)
	end
	return rivers
end

local function bucketRivers(rivers: { River }): { [number]: { number } }
	local cells: { [number]: { number } } = {}
	local reach = 120 -- channel + banks, the widest a river ever carves at point level
	for i, r in rivers do
		local x0 = math.floor((math.min(r.ax, r.bx) - reach + HALF) / RIVER_CELL)
		local x1 = math.floor((math.max(r.ax, r.bx) + reach + HALF) / RIVER_CELL)
		local z0 = math.floor((math.min(r.az, r.bz) - reach + HALF) / RIVER_CELL)
		local z1 = math.floor((math.max(r.az, r.bz) + reach + HALF) / RIVER_CELL)
		for cz = z0, z1 do
			for cx = x0, x1 do
				local key = (cz + 1) * RIVER_BUCKETS + cx + 1
				local list = cells[key]
				if not list then
					list = {}
					cells[key] = list
				end
				list[#list + 1] = i
			end
		end
	end
	return cells
end

-- Distance to the nearest river, and that river's half-width. math.huge when none is near.
local function riverDistance(f: Field, wx: number, wz: number): (number, number)
	local cx = math.floor((wx + HALF) / RIVER_CELL)
	local cz = math.floor((wz + HALF) / RIVER_CELL)
	local list = f.riverCells[(cz + 1) * RIVER_BUCKETS + cx + 1]
	if not list then return math.huge, 0 end
	local best, bestW = math.huge, 0
	for _, i in list do
		local r = f.rivers[i]
		local dx, dz = r.bx - r.ax, r.bz - r.az
		local len2 = dx * dx + dz * dz
		local t = if len2 > 0 then math.clamp(((wx - r.ax) * dx + (wz - r.az) * dz) / len2, 0, 1) else 0
		local px, pz = r.ax + dx * t - wx, r.az + dz * t - wz
		local d = math.sqrt(px * px + pz * pz)
		if d < best then
			best = d
			bestW = r.halfWidth
		end
	end
	return best, bestW
end

-- Coarse distance from every macro node to the nearest river, out to `reach`. Stamped from
-- every 4th vertex (~96 studs apart): the valley is hundreds of studs wide, so point spacing
-- is invisible in it, and the channel itself is cut per point anyway.
local function valleyDistance(rivers: { River }, reach: number): { number }
	local n = FIELD_N
	local out = table.create(n * n, math.huge)
	local r = math.ceil(reach / CELL)
	for i = 1, #rivers, 4 do
		local rv = rivers[i]
		local cx = math.floor((rv.ax + HALF) / CELL + 0.5)
		local cz = math.floor((rv.az + HALF) / CELL + 0.5)
		for z = math.max(cz - r, 0), math.min(cz + r, n - 1) do
			local dz = -HALF + z * CELL - rv.az
			for x = math.max(cx - r, 0), math.min(cx + r, n - 1) do
				local dx = -HALF + x * CELL - rv.ax
				local d = math.sqrt(dx * dx + dz * dz)
				local k = z * n + x + 1
				if d < out[k] then out[k] = d end
			end
		end
	end
	return out
end

function TerrainLandform.build(p: Params): Field
	local seed = p.seed
	local gain = p.persistence or 0.5
	local lac = p.lacunarity or 2
	local relief = p.heightRange or 1
	local rug = p.ruggedness or 0
	local shape = p.shape or "continent"
	local n = FIELD_N
	local h = table.create(n * n, 0)
	local mBias = MOUNTAIN_BIAS[shape] or 0
	local plateau = if shape == "highlands" then 26 else 0

	for z = 0, n - 1 do
		local wz = -HALF + z * CELL
		for x = 0, n - 1 do
			local wx = -HALF + x * CELL
			-- Two-level domain warp: the first bends the continents into bays and headlands, the
			-- second, finer one roughens the coastline those produce.
			local s = 1 / 2400
			local qx = fbm(wx * s * 0.7, wz * s * 0.7, seed + 101, 3, 0.5, 2)
			local qz = fbm(wx * s * 0.7 + 5.2, wz * s * 0.7 + 1.3, seed + 131, 3, 0.5, 2)
			local px, pz = wx + qx * 1500, wz + qz * 1500
			local rx = fbm(px / 700, pz / 700, seed + 151, 2, 0.5, 2)
			local rz = fbm(px / 700 + 3.1, pz / 700 + 7.7, seed + 181, 2, 0.5, 2)
			px += rx * 200
			pz += rz * 200
			local c = fbm(px * s, pz * s, seed, 5, gain, lac)
			local land = shapeField(shape, c, px / HALF, pz / HALF, seed, px, pz)

			local y
			if land < 0 then
				-- Continental shelf: shallow for a while off the beach, then the drop-off. Starts at
				-- exactly 0 so sea and land meet without a step (see the beach below).
				local d = -land
				y = -d * 40 - smoothstep(0.04, 0.3, d) * 30
				y = math.max(y, SEA_FLOOR)
			else
				local inland = smoothstep(0.0, 0.22, land)
				-- The beach ramps up from exactly 0. A step here (land starting at +2, sea at -1.5)
				-- let the surface grain dither across the waterline into sand speckles and
				-- pinprick islets all along the coast.
				-- It rises fast: a flat coast otherwise sits within a stud of the water for
				-- hundreds of studs and the whole of it reads as beach.
				y = smoothstep(0, 0.012, land) * 3.2 + smoothstep(0, 0.35, land) * 9 + plateau * inland
				-- Rolling hills: low everywhere, fading out at the beach so shores stay gentle.
				y += (fbm(px / 900, pz / 900, seed + 211, 3, gain, lac) + 0.25) * 22 * relief * inland
				-- Mountain ranges: a slow mask decides WHERE, a broad uplift makes the massif.
				-- The crests are cut per point in `sample`, where they cannot alias.
				local mask = smoothstep(-0.1, 0.25, fbm(wx / 3400, wz / 3400, seed + 241, 3, 0.5, 2) + mBias)
				mask *= smoothstep(0.03, 0.25, land)
				if mask > 0 then
					local mass = math.max(fbm(px / 1300, pz / 1300, seed + 261, 4, gain, lac) + 0.28, 0)
					y += mask * mass * mass * 660 * relief * (1 + rug * 0.8)
				end
			end

			h[z * n + x + 1] = y
		end
	end

	-- Rivers are planned against the finished land, so each one knows where the water is.
	local rivers = planRivers(shape, seed, function(wx: number, wz: number): boolean
		if math.abs(wx) > HALF or math.abs(wz) > HALF then return false end
		local x = math.floor((wx + HALF) / CELL + 0.5)
		local z = math.floor((wz + HALF) / CELL + 0.5)
		return h[z * n + x + 1] < 0
	end)
	if #rivers > 0 then
		-- Each river runs in a broad valley floored just above sea level.
		local valley = valleyDistance(rivers, 900)
		for i = 1, n * n do
			local y = h[i]
			local w = smoothstep(900, 120, valley[i])
			if w > 0 and y > -2 then
				h[i] = y + (math.min(y, FLOODPLAIN_Y + valley[i] * 0.012) - y) * w
			end
		end
	end

	return {
		h = h,
		rivers = rivers,
		riverCells = bucketRivers(rivers),
		lift = (p.baseHeight or 0) - (p.oceanLevel or 0),
		seed = seed,
	}
end

-- Built fields, most recent first. Matched FIELD BY FIELD rather than by table identity or a
-- string key: `field` is on the per-corner path (a million calls a map), and the map picker
-- edits its params table in place, so identity would hand back a stale map and a string key
-- would cost more than the sample itself.
-- ponytail: three entries covers a city plus a picker; bump FIELD_CACHE if previews rebuild.
local FIELD_CACHE = 3
type Entry = {
	seed: number, heightRange: number, oceanLevel: number, baseHeight: number,
	ruggedness: number, shape: string, persistence: number, lacunarity: number, field: Field,
}
local _cache: { Entry } = {}

local function matches(e: Entry, p: Params): boolean
	return e.seed == p.seed and e.heightRange == (p.heightRange or 1)
		and e.oceanLevel == (p.oceanLevel or 0) and e.baseHeight == (p.baseHeight or 0)
		and e.ruggedness == (p.ruggedness or 0) and e.shape == (p.shape or "continent")
		and e.persistence == (p.persistence or 0.5) and e.lacunarity == (p.lacunarity or 2)
end

function TerrainLandform.field(p: Params): Field
	local first = _cache[1]
	if first and matches(first, p) then return first.field end
	for i = 2, #_cache do
		local e = _cache[i]
		if matches(e, p) then
			table.remove(_cache, i)
			table.insert(_cache, 1, e)
			return e.field
		end
	end
	local e: Entry = {
		seed = p.seed, heightRange = p.heightRange or 1, oceanLevel = p.oceanLevel or 0,
		baseHeight = p.baseHeight or 0, ruggedness = p.ruggedness or 0,
		shape = p.shape or "continent", persistence = p.persistence or 0.5,
		lacunarity = p.lacunarity or 2, field = TerrainLandform.build(p),
	}
	table.insert(_cache, 1, e)
	if #_cache > FIELD_CACHE then table.remove(_cache) end
	return e.field
end

-- Catmull-Rom weights.
local function cr(t: number): (number, number, number, number)
	local t2, t3 = t * t, t * t * t
	return (-t3 + 2 * t2 - t) * 0.5, (3 * t3 - 5 * t2 + 2) * 0.5, (-3 * t3 + 4 * t2 + t) * 0.5, (t3 - t2) * 0.5
end

-- worldY at a world point: the macro field (bicubic), fine detail, the river channel.
function TerrainLandform.sample(f: Field, wx: number, wz: number): number
	local n = FIELD_N
	local fx = math.clamp((wx + HALF) / CELL, 0, n - 1)
	local fz = math.clamp((wz + HALF) / CELL, 0, n - 1)
	local ix = math.min(math.floor(fx), n - 2)
	local iz = math.min(math.floor(fz), n - 2)
	local tx, tz = fx - ix, fz - iz
	local ax, bx, cx, dx = cr(tx)
	local az, bz, cz, dz = cr(tz)
	local h = f.h
	-- Unrolled: this runs a million times a map. Rows clamp at the field edge.
	local c0 = math.max(ix - 1, 0) + 1
	local c1, c2 = ix + 1, ix + 2
	local c3 = math.min(ix + 2, n - 1) + 1
	local r0 = math.max(iz - 1, 0) * n
	local r1 = iz * n
	local r2 = (iz + 1) * n
	local r3 = math.min(iz + 2, n - 1) * n
	local y = (h[r0 + c0] * ax + h[r0 + c1] * bx + h[r0 + c2] * cx + h[r0 + c3] * dx) * az
		+ (h[r1 + c0] * ax + h[r1 + c1] * bx + h[r1 + c2] * cx + h[r1 + c3] * dx) * bz
		+ (h[r2 + c0] * ax + h[r2 + c1] * bx + h[r2 + c2] * cx + h[r2 + c3] * dx) * cz
		+ (h[r3 + c0] * ax + h[r3 + c1] * bx + h[r3 + c2] * cx + h[r3 + c3] * dx) * dz

	local seed = f.seed
	-- Ridge crests on high ground only: a ridged multifractal scaled by the height it stands on,
	-- so a 150-stud massif grows knife edges and gullies while the plains stay buildable.
	local high = smoothstep(16, 70, y)
	if high > 0 then
		local crest = ridged(wx / 520, wz / 520, seed + 271, 3, 0.5, 2.03)
		y += (crest - 0.3) * math.min(y, 170) * 0.55 * high
	end

	-- Fine relief: stronger up high, a whisper on the lowlands so building ground stays usable,
	-- and quiet within a few studs of sea level -- grain there only re-draws the coastline
	-- pixel by pixel, and the field's warp already gives it all the shape it needs.
	local amp = 0.12 + smoothstep(0.5, 5, math.abs(y)) * 0.6 + math.clamp(y, 0, 160) * 0.03
	y += math.noise(wx / 170 + 0.37, wz / 170 + 0.37, seed + 311) * amp * 2
		+ math.noise(wx / 57 + 0.37, wz / 57 + 0.37, seed + 331) * amp * 0.7

	if #f.rivers > 0 then
		local d, w = riverDistance(f, wx, wz)
		if d < w * 3 then
			-- Channel floor out to the half-width, then banks rising to the floodplain.
			local bed = RIVER_DEPTH + (FLOODPLAIN_Y - RIVER_DEPTH) * smoothstep(w * 0.55, w * 2.6, d)
			if bed < y then y = bed end
		end
	end
	return y + f.lift
end

return TerrainLandform
