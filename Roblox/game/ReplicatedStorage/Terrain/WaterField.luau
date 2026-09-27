--!strict
-- Water-field (shared): which below-sea ground actually holds water. Default is "all
-- below-sea = water" (ocean + natural lakes, zero stored state). The only deviation is a
-- sparse DRY set -- below-sea corners the player dug that are ISOLATED from any water.
-- classify() re-checks only the corners a brush touched via a LOCAL flood-fill (a dug
-- component reaching established water becomes water, an enclosed one becomes dry), so it
-- never scans the whole map. The server owns the authoritative set (persisted + streamed);
-- the client keeps its own predicted copy for the overlay. Each VM has its own _dry.
-- belowSea(gx, gz) is injected so the server can use exact corners and the client its
-- generator-backed sampler. Water level is sea (0); the sea is the only source.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)

local WaterField = {}

local SPACING = Constants.SAMPLE_SPACING
local MAX_CORNER = Constants.CORNERS_PER_AXIS - 1 -- 2048
local STRIDE = Constants.CORNERS_PER_AXIS -- 2049
local HALF = Constants.MAP_HALF_EXTENT
local BRUSH_MAX_RADIUS = Constants.BRUSH_MAX_RADIUS
local FLOOD_CAP = 20000 -- safety bound on a single classify flood (huge dig -> treat as water)

local _dry: { [number]: boolean } = {}

local function key(gx: number, gz: number): number
	return gz * STRIDE + gx
end

function WaterField.reset()
	table.clear(_dry)
end

function WaterField.isDryCorner(gx: number, gz: number): boolean
	return _dry[key(gx, gz)] == true
end

-- world point -> nearest corner: is it a dry (waterless) below-sea cell?
function WaterField.isDryAt(worldX: number, worldZ: number): boolean
	local gx = math.round((worldX + HALF) / SPACING)
	local gz = math.round((worldZ + HALF) / SPACING)
	if gx < 0 then gx = 0 elseif gx > MAX_CORNER then gx = MAX_CORNER end
	if gz < 0 then gz = 0 elseif gz > MAX_CORNER then gz = MAX_CORNER end
	return _dry[key(gx, gz)] == true
end

-- Re-classify the below-sea corners under a brush footprint after a stroke applied.
-- belowSea(gx, gz) -> is that corner below sea level. A connected component of (footprint +
-- already-dry) below-sea corners that touches ANY established-water corner (below-sea, not
-- footprint, not dry -- e.g. the ocean) becomes water; an enclosed component becomes dry.
function WaterField.classify(belowSea: (number, number) -> boolean, centerX: number, centerZ: number, radius: number)
	local R = math.clamp(radius, SPACING, BRUSH_MAX_RADIUS)
	local gxMin = math.max(0, math.floor((centerX - R + HALF) / SPACING))
	local gxMax = math.min(MAX_CORNER, math.ceil((centerX + R + HALF) / SPACING))
	local gzMin = math.max(0, math.floor((centerZ - R + HALF) / SPACING))
	local gzMax = math.min(MAX_CORNER, math.ceil((centerZ + R + HALF) / SPACING))

	local inFoot: { [number]: boolean } = {}
	for gz = gzMin, gzMax do
		local wz = -HALF + gz * SPACING
		for gx = gxMin, gxMax do
			local dx, dz = (-HALF + gx * SPACING) - centerX, wz - centerZ
			if dx * dx + dz * dz <= R * R then
				local k = key(gx, gz)
				inFoot[k] = true
				if not belowSea(gx, gz) then _dry[k] = nil end -- raised above sea: no longer a dry pit
			end
		end
	end

	local visited: { [number]: boolean } = {}
	local NB = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
	for gz = gzMin, gzMax do
		for gx = gxMin, gxMax do
			local k0 = key(gx, gz)
			if inFoot[k0] and not visited[k0] and belowSea(gx, gz) then
				visited[k0] = true
				local qx, qz = { gx }, { gz }
				local comp = { k0 }
				local touchedWater = false
				local qh = 1
				while qh <= #qx do
					local cx, cz = qx[qh], qz[qh]; qh += 1
					for _, d in NB do
						local nx, nz = cx + d[1], cz + d[2]
						if nx >= 0 and nx <= MAX_CORNER and nz >= 0 and nz <= MAX_CORNER and belowSea(nx, nz) then
							local nk = key(nx, nz)
							if inFoot[nk] or _dry[nk] then -- traversable (uncertain)
								if not visited[nk] then
									visited[nk] = true
									qx[#qx + 1] = nx; qz[#qz + 1] = nz; comp[#comp + 1] = nk
									if #comp > FLOOD_CAP then touchedWater = true; qh = #qx + 1; break end
								end
							else -- established water anchor
								touchedWater = true
							end
						end
					end
				end
				if touchedWater then
					for _, ck in comp do _dry[ck] = nil end
				else
					for _, ck in comp do _dry[ck] = true end
				end
			end
		end
	end
end

-- After a RAISE-type edit, drain any below-sea pocket the edit sealed off from the sea.
-- Floods the below-sea water next to the footprint: a FULLY ENCLOSED component smaller
-- than SEAL_CAP is a sealed pocket (cut off from the open sea) -> mark dry (it drains). A
-- component that reaches SEAL_CAP is the sea itself (or still connected to it) -> kept.
-- belowSea(gx, gz) reflects the terrain AFTER the stroke applied.
local SEAL_CAP = 8000 -- below-sea corners; an enclosed body bigger than this counts as "the sea"
function WaterField.drainSealed(belowSea: (number, number) -> boolean, centerX: number, centerZ: number, radius: number)
	local R = math.clamp(radius, SPACING, BRUSH_MAX_RADIUS)
	local m = 2 -- seed a margin around the footprint so the pocket beside the new wall is caught
	local gxMin = math.max(0, math.floor((centerX - R + HALF) / SPACING) - m)
	local gxMax = math.min(MAX_CORNER, math.ceil((centerX + R + HALF) / SPACING) + m)
	local gzMin = math.max(0, math.floor((centerZ - R + HALF) / SPACING) - m)
	local gzMax = math.min(MAX_CORNER, math.ceil((centerZ + R + HALF) / SPACING) + m)
	local visited: { [number]: boolean } = {}
	local NB = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
	for gz = gzMin, gzMax do
		for gx = gxMin, gxMax do
			local k0 = key(gx, gz)
			if not visited[k0] and belowSea(gx, gz) then
				visited[k0] = true
				local qx, qz = { gx }, { gz }
				local comp = { k0 }
				local capped = false
				local qh = 1
				while qh <= #qx do
					local cx, cz = qx[qh], qz[qh]; qh += 1
					for _, d in NB do
						local nx, nz = cx + d[1], cz + d[2]
						if nx >= 0 and nx <= MAX_CORNER and nz >= 0 and nz <= MAX_CORNER and belowSea(nx, nz) then
							local nk = key(nx, nz)
							if not visited[nk] then
								visited[nk] = true
								qx[#qx + 1] = nx; qz[#qz + 1] = nz; comp[#comp + 1] = nk
								if #comp > SEAL_CAP then capped = true; qh = #qx + 1; break end
							end
						end
					end
				end
				if not capped then -- enclosed pocket cut off from the sea: drain it
					for _, ck in comp do _dry[ck] = true end
				end
			end
		end
	end
end

-- Merge additional dry corners (a road cut sealed against the sea) without
-- clearing the existing set. Same key encoding as get/setDryKeys.
function WaterField.markDryKeys(keys: { number })
	for _, k in keys do
		if type(k) == "number" then _dry[k] = true end
	end
end

-- Persistence / streaming: the sparse list of dry corner keys.
function WaterField.getDryKeys(): { number }
	local out = {}
	for k in _dry do out[#out + 1] = k end
	return out
end

function WaterField.setDryKeys(keys: { number })
	table.clear(_dry)
	for _, k in keys do
		if type(k) == "number" then _dry[k] = true end
	end
end

return WaterField
