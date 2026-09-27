--!strict
-- Shared terrain painter: turns one Heightmap chunk into workspace.Terrain voxels.
-- Pure function of (terrain, heightmap, cx, cz), so the server (incremental edit
-- repaint) and the client (full-map build from the replicated seed) run identical
-- voxel logic. Voxel resolution equals the corner spacing, so a voxel column's centre
-- lands on a tile centre: its surface is the average of that tile's four corners, and
-- slope/material come from the same corners -- read straight from the chunk buffer.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)

local TerrainPainter = {}

local RES = Constants.VOXEL_RESOLUTION
local CHUNK_STUDS = Constants.CHUNK_STUDS
local HALF = Constants.MAP_HALF_EXTENT
local CHUNK_CORNERS = Constants.CHUNK_CORNERS
local SPACING = Constants.SAMPLE_SPACING
local SEA_Y = Constants.SEA_Y
local AUTO = Constants.Material.AUTO
local MaterialEnum = Constants.MaterialEnum
local rawToWorldY = Constants.rawToWorldY

-- Studs of solid filled below the surface. All terrain edits write the heightmap, and
-- the painter fills this below the CURRENT surface, so cuts lower the floor with them;
-- chunks share edge corners so the surface stays continuous. Only sets crust thickness
-- (visible at the map edge / seabed). 2 voxels: reads solid, keeps WriteVoxels cheap.
local SOLID_DEPTH = 8

local MAT_WATER = Enum.Material.Water
local MAT_AIR = Enum.Material.Air

-- Every column that holds water at all holds at least this much, reaching down UNDER the
-- ground mesh where nothing sees it. Roblox draws distant water from coarser voxels (up to
-- 32 studs), and a 4-stud skin of water averaged into a 32-stud cell comes out a fraction
-- full: the far water surface sank below the shallows, the seabed showed through, and the
-- coast changed every time the camera zoomed. Measured in Edit: 1, 2, 3 and 4 cells all
-- exposed a seabed 3.5 studs down at 7-9k studs; 8 cells (32 studs, one aligned LOD cell)
-- held.
local WATER_MIN_DEPTH = 32

-- Only genuinely steep faces (cliffs) read as rock; a lower threshold turned every
-- rolling hill and gentle road-grade cut brown, which looked like terrain damage.
local ROCK_SLOPE_DEG = 55
local SHALLOW_SEABED_Y = -16 -- above this the seabed is bright sand (reads teal through the semi-clear water)
local BEACH_TOP_Y = 4        -- gentle land just above the waterline is sand
local SNOW_LINE_Y = 78       -- studs; snow caps on the high peaks
local function autoMaterial(worldY: number, slopeRad: number): Enum.Material
	-- Seabed: shallow = bright sand, deep = dark Slate, so depth reads as a darkening
	-- gradient through the transparent water (no custom water shader needed).
	if worldY < SEA_Y + 1 then
		return if worldY > SHALLOW_SEABED_Y then Enum.Material.Sand else Enum.Material.Slate
	end
	if slopeRad > math.rad(ROCK_SLOPE_DEG) then return Enum.Material.Rock end
	if worldY < BEACH_TOP_Y then return Enum.Material.Sand end -- sandy beaches along the shore
	if worldY > SNOW_LINE_Y then return Enum.Material.Snow end
	return Enum.Material.LeafyGrass
end

-- dryAt(worldX, worldZ) -> true means "below-sea but waterless" (an isolated dug pit the
-- water-field classified dry); those columns get AIR above the ground instead of water.
-- nil = no gating (the client base paint; the server passes the water-field query).
--
-- waterOnly: paint the WATER BODY and nothing else. With TerrainConstants.MESH_GROUND the
-- ground is a MeshPart shell (TerrainMeshView) and workspace.Terrain keeps only water --
-- which is worth keeping, because the engine's water is animated, reflective and free,
-- and WaterView's depth/foam overlay is already built on top of it.
-- fresh: the caller has just CLEARED this terrain, so nothing is already written here that
-- needs overwriting -- only what must EXIST has to be sent. That turns out to be most of a
-- cold load. Measured: the waterOnly region is forced down to MAX_DIG_BELOW_SEA whatever the
-- ground does, so a chunk of dry hillside at y=100 still built a 64 x 12 x 64 array -- 49,152
-- cells -- to write nothing but air, at ~12 ms a chunk before WriteVoxels was even called.
-- Over 1,024 chunks that is 12.3 s of loading screen spent describing empty sky, and on a
-- sampled map 56% of chunks are entirely above sea level.
--
-- A REPAINT must NOT pass this: filling a dug pond back in RAISES minSurf, and the water that
-- used to be there is only removed by writing air over it. That is what the deep floor below
-- is for, and it stays for every caller that is not a fresh build.
function TerrainPainter.paintChunk(terrain: Terrain, hm: any, cx: number, cz: number, dryAt: ((number, number) -> boolean)?, waterOnly: boolean?, fresh: boolean?)
	local chunk = hm:getChunk(cx, cz)
	if not chunk then return end

	local heights = chunk.heights
	local materials = chunk.materials

	local x0 = -HALF + cx * CHUNK_STUDS
	local z0 = -HALF + cz * CHUNK_STUDS

	local cornerY = table.create(CHUNK_CORNERS)
	local minSurf, maxSurf = math.huge, -math.huge
	-- Corner bounds of the ground that sits below the sea, in 0-based corner indices. A chunk
	-- with a lake in one corner should write that corner, not the whole 256 studs.
	local wetX0, wetX1, wetZ0, wetZ1 = math.huge, -math.huge, math.huge, -math.huge
	for lz = 0, CHUNK_CORNERS - 1 do
		local rowBase = lz * CHUNK_CORNERS
		local row = table.create(CHUNK_CORNERS)
		for lx = 0, CHUNK_CORNERS - 1 do
			local y = rawToWorldY(buffer.readu16(heights, (rowBase + lx) * 2))
			row[lx + 1] = y
			if y < minSurf then minSurf = y end
			if y > maxSurf then maxSurf = y end
			if y < SEA_Y then
				if lx < wetX0 then wetX0 = lx end
				if lx > wetX1 then wetX1 = lx end
				if lz < wetZ0 then wetZ0 = lz end
				if lz > wetZ1 then wetZ1 = lz end
			end
		end
		cornerY[lz + 1] = row
	end

	-- Water-only reaches from the deepest a chunk could hold water to just over the surface.
	-- The floor is not just minSurf: filling a dug pond back in RAISES minSurf, and anything
	-- left below it would stay behind as a water body buried under the ground mesh -- visible
	-- the moment the player switches to the underground view. MAX_DIG_BELOW_SEA bounds how
	-- deep a player edit can ever have gone.
	-- Cell offsets into cornerY. Zero unless the region is shrunk to the wet box below, in
	-- which case cell (1,1) of the region is no longer corner (1,1) of the chunk.
	local offX, offZ = 0, 0
	local xLo, xHi, zLo, zHi = x0, x0 + CHUNK_STUDS, z0, z0 + CHUNK_STUDS

	local yLow, yHigh
	if waterOnly and fresh then
		-- Nothing here can hold water, and nothing is already written: send nothing at all.
		if minSurf >= SEA_Y then
			return
		end
		-- Only the band that can actually be wet, rather than down to the dig floor.
		yLow = math.min(minSurf, SEA_Y - WATER_MIN_DEPTH) - RES
		yHigh = SEA_Y + RES

		-- ...and only the FOOTPRINT that can be wet. A cell's surface is the mean of its four
		-- corners, so a cell whose corners are all above the sea is dry whatever its
		-- neighbours do -- which makes the wet corners' box, widened by the one cell each
		-- corner touches, an exact bound rather than a guess. Coastal chunks are mostly a
		-- strip of water against a lot of land, and WriteVoxels costs what the region holds.
		local cellX0 = math.max(1, wetX0)
		local cellX1 = math.min(CHUNK_CORNERS - 1, wetX1 + 1)
		local cellZ0 = math.max(1, wetZ0)
		local cellZ1 = math.min(CHUNK_CORNERS - 1, wetZ1 + 1)
		offX, offZ = cellX0 - 1, cellZ0 - 1
		xLo, xHi = x0 + (cellX0 - 1) * RES, x0 + cellX1 * RES
		zLo, zHi = z0 + (cellZ0 - 1) * RES, z0 + cellZ1 * RES
	elseif waterOnly then
		yLow = math.min(minSurf, SEA_Y - Constants.MAX_DIG_BELOW_SEA) - RES
		yHigh = SEA_Y + RES
	else
		yLow = minSurf - SOLID_DEPTH
		yHigh = math.max(maxSurf, SEA_Y) + RES
	end
	local region = Region3.new(
		Vector3.new(xLo, yLow, zLo),
		Vector3.new(xHi, yHigh, zHi)
	):ExpandToGrid(RES)

	local size = region.Size
	local rmin = region.CFrame.Position - size * 0.5
	local nx = math.floor(size.X / RES + 0.5)
	local ny = math.floor(size.Y / RES + 0.5)
	local nz = math.floor(size.Z / RES + 0.5)

	-- The water-only pass writes Water or Air and nothing else, so the whole material
	-- question -- the override lookup, two gradients, a sqrt and an atan per column -- is
	-- answering something nobody asks. Skipped there, which is most of a cold load.
	local colSurf = table.create(nx)
	local colMat = table.create(nx)
	for ix = 1, nx do
		local sRow = table.create(nz)
		local mRow = if waterOnly then nil else table.create(nz)
		for iz = 1, nz do
			local rowA = cornerY[iz + offZ]
			local rowB = cornerY[iz + offZ + 1]
			local h00 = rowA[ix + offX]
			local h10 = rowA[ix + offX + 1]
			local h01 = rowB[ix + offX]
			local h11 = rowB[ix + offX + 1]
			local top = h00 + (h10 - h00) * 0.5
			local bot = h01 + (h11 - h01) * 0.5
			local s = top + (bot - top) * 0.5
			sRow[iz] = s

			if mRow then
				local ovId = buffer.readu8(materials, (iz + offZ) * CHUNK_CORNERS + (ix + offX))
				if ovId ~= AUTO and MaterialEnum[ovId] then
					mRow[iz] = MaterialEnum[ovId]
				else
					local gradX = ((h10 - h00) + (h11 - h01)) / (2 * SPACING)
					local gradZ = ((h01 - h00) + (h11 - h10)) / (2 * SPACING)
					mRow[iz] = autoMaterial(s, math.atan(math.sqrt(gradX * gradX + gradZ * gradZ)))
				end
			end
		end
		colSurf[ix] = sRow
		colMat[ix] = mRow
	end

	local mats = table.create(nx)
	local occs = table.create(nx)
	for ix = 1, nx do
		local sRow = colSurf[ix]
		local mRow = colMat[ix]
		local dryRow: { boolean }? = nil
		if dryAt then
			dryRow = table.create(nz)
			local wx = rmin.X + (ix - 0.5) * RES
			for iz = 1, nz do
				(dryRow :: { boolean })[iz] = dryAt(wx, rmin.Z + (iz - 0.5) * RES)
			end
		end
		local mx = table.create(ny)
		local ox = table.create(ny)
		for iy = 1, ny do
			local cellBottom = rmin.Y + (iy - 1) * RES
			local cellCenter = cellBottom + RES * 0.5
			local underSea = cellCenter < SEA_Y
			local my = table.create(nz)
			local oy = table.create(nz)
			for iz = 1, nz do
				local occ = (sRow[iz] - cellBottom) / RES
				if waterOnly then
					-- A column is wet when its top cell is; then it is water down to its ground or
					-- to WATER_MIN_DEPTH, whichever is deeper.
					local surf = sRow[iz]
					local wet = underSea and surf < SEA_Y - RES * 0.5
						and (cellCenter > surf or cellCenter > SEA_Y - WATER_MIN_DEPTH)
						and not (dryRow and dryRow[iz])
					my[iz] = if wet then MAT_WATER else MAT_AIR
					oy[iz] = if wet then 1 else 0
				elseif occ >= 1 then
					my[iz] = mRow[iz]
					oy[iz] = 1
				elseif occ > 0 then
					my[iz] = mRow[iz]
					oy[iz] = occ
				elseif underSea and not (dryRow and dryRow[iz]) then
					my[iz] = MAT_WATER
					oy[iz] = 1
				else
					my[iz] = MAT_AIR
					oy[iz] = 0
				end
			end
			mx[iy] = my
			ox[iy] = oy
		end
		mats[ix] = mx
		occs[ix] = ox
	end

	terrain:WriteVoxels(region, RES, mats, occs)
end

return TerrainPainter