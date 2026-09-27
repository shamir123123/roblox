--!strict
-- The water paint. No framework -- `run(TerrainPainter, Heightmap, Constants)` asserts.
--
-- `fresh` lets a cold build skip a chunk whose ground never goes below sea level, which is
-- most of the map and was most of the loading screen. Skipping is the kind of optimisation
-- that is invisible when it is right and invisible when it is WRONG -- a missed lake reads as
-- "the water didn't load", far from the code that decided not to paint it. So the property
-- asserted here is not "it is faster", it is that fresh and non-fresh put water in EXACTLY the
-- same places.
--
-- No real Terrain is touched: paintChunk's only side effect is one WriteVoxels call, so a
-- stub that records it is the whole seam.

local M = {}

-- Records what paintChunk would have written.
local function fakeTerrain()
	local t = { writes = 0, region = nil, mats = nil, occs = nil }
	function t:WriteVoxels(region, res, mats, occs)
		t.writes += 1
		t.region, t.mats, t.occs = region, mats, occs
	end
	return t
end

-- The set of world cell centres this write puts water in.
local function wetCells(t: any, res: number): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if t.writes == 0 then return out end
	local size = t.region.Size
	local rmin = t.region.CFrame.Position - size * 0.5
	for ix, mx in t.mats do
		for iy, my in mx do
			for iz, mat in my do
				if mat == Enum.Material.Water and t.occs[ix][iy][iz] > 0 then
					local x = rmin.X + (ix - 0.5) * res
					local y = rmin.Y + (iy - 0.5) * res
					local z = rmin.Z + (iz - 0.5) * res
					out[`{math.round(x)}:{math.round(y)}:{math.round(z)}`] = true
				end
			end
		end
	end
	return out
end

local function count(set: { [string]: boolean }): number
	local n = 0
	for _ in set do n += 1 end
	return n
end

function M.run(TerrainPainter: any, Heightmap: any, Constants: any): boolean
	local TILES = Constants.CHUNK_TILES
	local RES = Constants.VOXEL_RESOLUTION
	local SEA_Y = Constants.SEA_Y

	-- One chunk, heights from `shape(lx, lz)` in world studs.
	local function chunkWith(shape: (number, number) -> number)
		local hm = Heightmap.new()
		hm:ensureChunk(0, 0)
		for lz = 0, TILES do
			for lx = 0, TILES do
				hm:setCorner(lx, lz, Constants.worldYToRaw(shape(lx, lz)))
			end
		end
		return hm
	end

	local function paint(hm: any, fresh: boolean?)
		local t = fakeTerrain()
		TerrainPainter.paintChunk(t, hm, 0, 0, nil, true, fresh)
		return t
	end

	-- A: dry land, well above the sea. A fresh build must send NOTHING.
	local dry = chunkWith(function() return SEA_Y + 40 end)
	local dryFresh = paint(dry, true)
	assert(dryFresh.writes == 0,
		`dry land still wrote voxels on a fresh build -- this is the 12.3 s the skip exists to save`)

	-- ...but a REPAINT of the same ground must still write, or filling in a pond leaves the
	-- old water behind, buried under the ground mesh.
	local dryRepaint = paint(dry, false)
	assert(dryRepaint.writes == 1,
		`a repaint of dry land wrote nothing -- water from a filled-in pond would never be cleared`)
	assert(count(wetCells(dryRepaint, RES)) == 0, "dry land was painted wet")

	-- B: ground that dips below the sea. Fresh and repaint must agree on every wet cell --
	-- the fresh path uses a shallower region, and a region that is too shallow silently
	-- clips the bottom of the lake.
	local lake = chunkWith(function(lx, lz)
		local dx, dz = lx - TILES * 0.5, lz - TILES * 0.5
		local r = math.sqrt(dx * dx + dz * dz)
		return if r < TILES * 0.3 then SEA_Y - 30 else SEA_Y + 20
	end)
	local a = wetCells(paint(lake, true), RES)
	local b = wetCells(paint(lake, false), RES)
	assert(count(a) > 200, `the lake only produced {count(a)} wet cells; this check proves nothing`)
	for key in b do
		assert(a[key], `cell {key} is water on a repaint but not on a fresh build -- the fresh region clips the lake`)
	end
	for key in a do
		assert(b[key], `cell {key} is water on a fresh build but not on a repaint`)
	end

	-- C: ground sitting exactly AT sea level is the boundary the skip tests. It holds no
	-- water (a cell is wet only strictly above the surface), so it may be skipped.
	local atSea = chunkWith(function() return SEA_Y end)
	assert(count(wetCells(paint(atSea, false), RES)) == 0,
		"ground exactly at sea level was painted wet, so the >= in the skip is wrong")
	assert(paint(atSea, true).writes == 0, "ground exactly at sea level was not skipped")

	print("[TerrainPainter.spec] OK")
	return true
end

return M
