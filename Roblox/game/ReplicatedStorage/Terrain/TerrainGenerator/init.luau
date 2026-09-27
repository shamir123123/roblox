--!strict
-- Procedural base-map generator. Pure library: fills a Heightmap's chunk buffers
-- from a seed. Writes buffers directly (not via setCorner) to skip per-corner
-- routing over a million corners; shared edges agree because neighbouring chunks
-- evaluate the same global formula. Leaves material AUTO and flags clear.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local Heightmap = require(ReplicatedStorage.Terrain.Heightmap)
local TerrainLandform = require(ReplicatedStorage.Terrain.TerrainLandform)

local TerrainGenerator = {}

-- How to build a base map. seed picks the noise; the rest are the player-facing
-- knobs from the map picker. Defaults reproduce the original (seed, relief) formula
-- exactly, so old saves / baked presets regenerate unchanged.
export type GenParams = {
	seed: number,
	heightRange: number?, -- amplitude scale (was "relief"); ~0.15 flat .. 1 hilly
	oceanLevel: number?,  -- studs the sea is raised relative to land (more water)
	baseHeight: number?,  -- studs the whole landmass is lifted
	ruggedness: number?,  -- 0..1 extra sharp ridges on top; 0 = smooth original
	shape: string?,       -- macro layout (island/coast/lake/...); nil = "continent"
	persistence: number?, -- fbm amplitude gain (0..1); how strong smaller details are. def 0.5
	lacunarity: number?,  -- fbm frequency step (1..4); how fast detail freq grows. def 2.0
	-- Which generator. nil = the original formula below, kept byte-for-byte because every city
	-- saved before 2026-09-22 stores its terrain as a DIFF against it. 3 = TerrainLandform.
	-- Stamped on new slots by CitySlotService; never chosen by the client.
	algo: number?,
}

local CHUNKS = Constants.CHUNKS_PER_AXIS
local CT = Constants.CHUNK_TILES
local CC = Constants.CHUNK_CORNERS
local cornerToWorld = Constants.cornerToWorld
local worldYToRaw = Constants.worldYToRaw
local HALF = Constants.MAP_HALF_EXTENT
-- Base noise wavelength, scaled with the map so a bigger map shows similarly-sized
-- landmasses (not just more of them). 900 was tuned for the old 4096-stud map.
local NOISE_SCALE = Constants.MAP_EXTENT * 900 / 4096

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Fractal noise (sum of octaves), normalised to ~[-1,1]. More octaves = more natural,
-- detailed landmass; the seed offset per octave decorrelates them.
local function fbm(x: number, z: number, seed: number, octaves: number, gain: number, lacunarity: number): number
	local sum, amp, freq, norm = 0, 1, 1, 0
	for i = 1, octaves do
		sum += amp * math.noise(x * freq, z * freq, seed + i * 13)
		norm += amp
		amp *= gain
		freq *= lacunarity
	end
	return sum / norm
end

-- Bend the raw land height into a macro layout. Works in pre-sea-offset studs (sea
-- ends up at 0 after the +8 below): pushing y far negative makes sea, clamping it
-- above ~2.5 guarantees dry land. wx,wz are world studs centred on the origin.
local function applyShape(shape: string, y: number, wx: number, wz: number, seed: number): number
	local r = math.sqrt(wx * wx + wz * wz) / HALF -- 0 centre .. ~1.41 corner
	if shape == "island" then
		return y + smoothstep(0.55, 0.0, r) * 22 - smoothstep(0.40, 1.0, r) * 150
	elseif shape == "archipelago" then
		-- high-frequency island field so the map breaks into many small landmasses
		local islands = math.noise(wx / 170, wz / 170, seed + 7) * 54
		return y * 0.5 + islands - 4 - smoothstep(0.62, 1.2, r) * 50
	elseif shape == "coast" then
		return y + (-wx / HALF) * 58 + 10
	elseif shape == "peninsula" then
		local southLand = smoothstep(-0.15, 0.55, wz / HALF) -- ~0 near south edge: keep the land bridge
		return y - smoothstep(0.40, 0.98, r) * southLand * 160
	elseif shape == "bay" then
		local bd = math.sqrt((wx - HALF * 0.55) ^ 2 + wz * wz) / HALF
		return y + (-wx / HALF) * 40 + 14 - smoothstep(0.55, 0.0, bd) * 80
	elseif shape == "lake" then
		local lifted = y + smoothstep(0.55, 1.05, r) * 30 + 18 - smoothstep(0.34, 0.0, r) * 95
		return if r > 0.40 then math.max(lifted, 2.5) else lifted
	elseif shape == "river" then
		local centre = math.sin(wx / 520 + seed) * 540 + math.noise(wx / 1500, seed) * 300
		local bank = math.abs(wz - centre)
		local land = y + 18
		if bank > 150 then land = math.max(land, 2.5) end
		return land - smoothstep(150, 0, bank) * 70
	elseif shape == "landlocked" then
		return math.max(y * 0.85 + 26, 2.5)
	elseif shape == "highlands" then
		return y * 1.45 + 42
	end
	return y
end

-- Layered value noise -> worldY for a global corner. Continent term decides
-- land vs sea; hills and detail add relief. Biased slightly above sea so basins
-- dip under for water while most of the map is buildable.
local function surfaceY(gx: number, gz: number, p: GenParams): number
	if p.algo == 3 then
		return TerrainLandform.sample(TerrainLandform.field(p), cornerToWorld(gx), cornerToWorld(gz))
	end
	local seed = p.seed
	local wx = cornerToWorld(gx)
	local wz = cornerToWorld(gz)
	local nx = wx / NOISE_SCALE
	local nz = wz / NOISE_SCALE
	-- Domain warp: bend the sample coords by low-freq noise so coastlines wind into
	-- inlets/headlands instead of looking like round noise blobs.
	local wpx = nx + math.noise(nx * 0.7, nz * 0.7, seed + 200) * 0.55
	local wpz = nz + math.noise(nx * 0.7, nz * 0.7, seed + 300) * 0.55
	local gain = p.persistence or 0.5
	local lac = p.lacunarity or 2.0
	local continent = fbm(wpx, wpz, seed, 4, gain, lac) -- smooth landmasses, -1..1
	-- Dramatic relief: ridged mountains, but only stacked on ground that is already high
	-- so the sea stays where it is and peaks tower over the interior.
	local n = continent
	if continent > 0.15 then
		local ridge = 1 - math.abs(fbm(wpx * 2.6, wpz * 2.6, seed + 71, 3, gain, lac))
		n += ridge * ridge * (continent - 0.15) * 1.6
	end
	n += math.noise(nx * 7.3, nz * 7.3, seed + 91) * 0.12 -- fine detail
	local rug = p.ruggedness or 0
	if rug > 0 then
		local ridge = math.abs(math.noise(nx * 5.5, nz * 5.5, seed + 53))
		n += ridge * rug * 0.7
	end
	local y = n * 64 * (p.heightRange or 1)
	local shape = p.shape
	if shape and shape ~= "continent" then
		y = applyShape(shape, y, wx, wz, seed)
	end
	return y + 8 + (p.baseHeight or 0) - (p.oceanLevel or 0)
end

-- Fill ONE chunk's height buffer from the params. Pure: no dirty marking, no side
-- effects beyond the chunk buffer -- the client generates base chunks on demand (one
-- at a time, in view order) so it never pays for the whole map up front.
-- Sample the noise on a coarse grid (every 2nd corner; every 4th for TerrainLandform) and
-- bilinearly fill the rest. Terrain features are far larger than that, so the result is
-- visually identical at a fraction of the noise evaluations. Chunk EDGE corners are exact-sampled grid points, so
-- neighbouring chunks still agree on shared edges (no seams).
-- TerrainLandform maps sample every 4th corner (16 studs). Everything that generator draws
-- finer than that is gentle surface grain, which bilinear carries fine, and its rivers are
-- wide enough that every 16-stud cell along one has a sample inside the flat bed. It is a
-- MAP-wide choice, never per chunk: neighbours share their edge corners and must sample them
-- identically or the seam steps.
local COARSE_STEP = 2
local LANDFORM_STEP = 4

function TerrainGenerator.generateChunk(hm: Heightmap.Heightmap, cx: number, cz: number, p: GenParams)
	local chunk = hm:ensureChunk(cx, cz)
	-- The base map is BARE ground. Heights are rewritten below, but a heightmap that
	-- already held a city keeps its materials and flags unless they are cleared here -- and
	-- the server reuses ONE heightmap for every city it loads. A stale LOCKED flag then
	-- makes the next road grade skip its own bed (gradeCenterline treats a locked corner as
	-- owned by something else), so on the second load in a server the ground stands up to
	-- natural height through the road.
	buffer.fill(chunk.materials, 0, 0)
	buffer.fill(chunk.flags, 0, 0)
	local heights = chunk.heights
	local baseX = cx * CT
	local baseZ = cz * CT

	-- The landform field is resolved once per chunk, not per corner.
	local field = if p.algo == 3 then TerrainLandform.field(p) else nil
	local step = if field then LANDFORM_STEP else COARSE_STEP
	local cols = CT // step + 1
	local coarse = table.create(cols * cols)
	for lz = 0, CT, step do
		local gz = baseZ + lz
		local ci = (lz // step) * cols
		local wz = cornerToWorld(gz)
		for lx = 0, CT, step do
			coarse[ci + lx // step + 1] = if field
				then TerrainLandform.sample(field, cornerToWorld(baseX + lx), wz)
				else surfaceY(baseX + lx, gz, p)
		end
	end

	for lz = 0, CT do
		local fz = lz / step
		local z0 = math.floor(fz)
		local tz = fz - z0
		local row0 = z0 * cols
		local row1 = math.min(z0 + 1, cols - 1) * cols
		local outRow = lz * CC
		for lx = 0, CT do
			local fx = lx / step
			local x0 = math.floor(fx)
			local tx = fx - x0
			local x1 = math.min(x0 + 1, cols - 1)
			local a = coarse[row0 + x0 + 1]
			local b = coarse[row0 + x1 + 1]
			local c = coarse[row1 + x0 + 1]
			local d = coarse[row1 + x1 + 1]
			local top = a + (b - a) * tx
			local bot = c + (d - c) * tx
			buffer.writeu16(heights, (outRow + lx) * 2, worldYToRaw(top + (bot - top) * tz))
		end
	end
end

-- Sample the base-map height (worldY) at one global corner. Pure, no heightmap
-- needed -- used by the map-picker preview to draw params before the map is built.
function TerrainGenerator.surfaceYAt(gx: number, gz: number, p: GenParams): number
	return surfaceY(gx, gz, p)
end

function TerrainGenerator.generate(hm: Heightmap.Heightmap, p: GenParams)
	for cz = 0, CHUNKS - 1 do
		for cx = 0, CHUNKS - 1 do
			TerrainGenerator.generateChunk(hm, cx, cz, p)
			hm:markRenderDirty(cx, cz) -- render only: base is reproducible from params, never saved
		end
	end
end

return TerrainGenerator
