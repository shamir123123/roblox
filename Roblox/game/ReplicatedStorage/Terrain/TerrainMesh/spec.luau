--!strict
-- TerrainMesh contract. No framework -- `require(...).run()` asserts, against the real
-- builder rather than a copy of its formula. Five things here are load-bearing and not one
-- of them shows up in a screenshot taken from the usual angle:
--
--   A  A vertex sits at heightmap + RENDER_BULGE, EXACTLY. That is the contract the voxel
--      painter set and every road, pad and building in the game places against. Drop it
--      and the whole city floats two studs, which reads as "the terrain broke".
--   B  Two chunks agree on the corners they SHARE. They are built independently, so a seam
--      is only closed by both sides computing the same number.
--   C  Top triangles wind so their normal points UP. Reverse them and the ground is
--      invisible from above -- backfaces are culled -- while every other check still passes.
--   D  A block facing a COARSER block lands exactly on the line that block draws. Blocks of
--      different strides meet everywhere now, so this is the ordinary case, not an edge
--      case, and nothing is left hiding a mistake since the apron went.
--   E  Strides answer to the SHAPE. Too eager and a kerb or a road cut quietly dissolves at
--      close range; too shy and levelled ground is drawn with thousands of coplanar
--      triangles -- and the reason strides are per BLOCK is that judging a whole 256-stud
--      chunk let one road hold the entire chunk at full detail.
--
-- Run against a CLONE (require() caches by instance), or via the loadstring+setfenv shim.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local TerrainMesh = require(ReplicatedStorage.Terrain.TerrainMesh)

local TILES = Constants.CHUNK_TILES
local BULGE = Constants.RENDER_BULGE
local SPACING = Constants.SAMPLE_SPACING
local BLOCK = Constants.MESH_BLOCK_TILES
local BLOCKS = TILES // BLOCK
local TOL = Constants.MESH_FLAT_TOLERANCE

local M = {}

-- A smooth synthetic heightfield well inside SLOPE_CLAMP_DEG, plus one bench so a flat
-- region is covered too (flat is where a degenerate mesh would hide).
local function field(gx: number, gz: number): number
	if gx > 340 and gx < 380 then return 30 end
	return 20 * math.sin(gx * 0.08) + 15 * math.cos(gz * 0.05) + 6
end

local function noMat(_gx: number, _gz: number): number
	return 0
end

local function uniform(s: number)
	return function(_gbx: number, _gbz: number): number return s end
end

local function faceNormal(geo: TerrainMesh.Geo, t: number): Vector3
	local k = t * 3
	local p1 = geo.pos[geo.tri[k + 1]]
	local p2 = geo.pos[geo.tri[k + 2]]
	local p3 = geo.pos[geo.tri[k + 3]]
	return (p2 - p1):Cross(p3 - p2)
end

-- World Y at a vertex, keyed by its X/Z. Blocks own their vertices outright, so a position
-- on a block boundary carries several copies -- every one of them must agree, which is
-- itself half of "no cracks".
local function heights(geo: TerrainMesh.Geo): { [string]: number }
	local out: { [string]: number } = {}
	for _, p in geo.pos do
		local key = `{math.round((geo.origin.X + p.X) * 8)}:{math.round((geo.origin.Z + p.Z) * 8)}`
		local y = geo.origin.Y + p.Y
		local seen = out[key]
		assert(seen == nil or math.abs(seen - y) < 0.01,
			`two vertices share a position but not a height ({seen} vs {y}) -- that IS a crack`)
		out[key] = y
	end
	return out
end

local function at(h: { [string]: number }, worldX: number, worldZ: number): number
	local key = `{math.round(worldX * 8)}:{math.round(worldZ * 8)}`
	local y = h[key]
	assert(y, `no vertex at ({worldX}, {worldZ})`)
	return y
end

function M.run(): boolean
	-- A stride at or under a block has to divide the block; a coarser one only ever appears
	-- on a MERGED chunk, so it has to divide the chunk instead. Either way a patch's edge
	-- vertices land on the lattice its neighbours use, which is what makes stitching exact.
	for _, step in Constants.MESH_LOD_STEPS do
		if step <= BLOCK then
			assert(BLOCK % step == 0, `stride {step} does not divide MESH_BLOCK_TILES {BLOCK}`)
		else
			assert(TILES % step == 0, `merged stride {step} does not divide CHUNK_TILES {TILES}`)
			assert(step % BLOCK == 0, `merged stride {step} is not a whole number of blocks`)
		end
	end
	assert(TILES % BLOCK == 0, `MESH_BLOCK_TILES {BLOCK} does not divide CHUNK_TILES {TILES}`)

	local cx, cz = 5, 7
	local gx0, gz0 = cx * TILES, cz * TILES
	local geo = TerrainMesh.buildChunk(cx, cz, field, noMat, uniform(1))
	local h = heights(geo)

	assert(#geo.nrm == #geo.pos, "normal count does not match vertex count")
	assert(#geo.uv == #geo.pos, "UV count does not match vertex count")
	assert(#geo.col == #geo.pos, "colour count does not match vertex count")
	assert(#geo.tri % 3 == 0, "triangle list is not a multiple of 3")
	for _, idx in geo.tri do
		assert(idx >= 1 and idx <= #geo.pos, `triangle index {idx} outside 1..{#geo.pos}`)
	end

	-- A: the render-bulge contract, across the chunk including both extremes.
	for _, ij in { { 0, 0 }, { 23, 41 }, { TILES, TILES } } do
		local gx, gz = gx0 + ij[1], gz0 + ij[2]
		local y = at(h, Constants.cornerToWorld(gx), Constants.cornerToWorld(gz))
		assert(math.abs(y - (field(gx, gz) + BULGE)) < 0.01,
			`corner ({ij[1]},{ij[2]}) at Y {y}, expected heightmap + RENDER_BULGE = {field(gx, gz) + BULGE}`)
	end

	-- B: the shared edge between two neighbouring chunks, built independently.
	local east = heights(TerrainMesh.buildChunk(cx + 1, cz, field, noMat, uniform(1)))
	local seamX = Constants.cornerToWorld(gx0 + TILES)
	for j = 0, TILES do
		local worldZ = Constants.cornerToWorld(gz0 + j)
		local a, b = at(h, seamX, worldZ), at(east, seamX, worldZ)
		assert(math.abs(a - b) < 0.02, `chunk seam row {j} splits by {math.abs(a - b)} studs`)
	end

	-- C: every triangle faces up. A heightfield cannot overhang, so a correctly wound face
	-- ALWAYS has a positive Y normal -- there is no steep case that excuses a failure.
	for t = 0, #geo.tri // 3 - 1 do
		assert(faceNormal(geo, t).Y > 0,
			`triangle {t} winds downward -- the ground renders invisible from above`)
	end

	-- The mesh is a SURFACE: nothing below the skin, so the triangle count is exactly the
	-- quads the strides ask for and not one more. An apron would be dead weight on coarse
	-- ground, where it used to cost as many triangles as the ground itself.
	assert(#geo.tri // 3 == TILES * TILES * 2, `stride 1 should be {TILES * TILES * 2} triangles, got {#geo.tri // 3}`)
	local coarse = TerrainMesh.buildChunk(cx, cz, field, noMat, uniform(BLOCK))
	assert(#coarse.tri // 3 == BLOCKS * BLOCKS * 2, "one quad per block is not one quad per block")

	-- D: the seam between two blocks of different stride, which is now the ordinary case.
	-- Block column 0 is drawn as a single quad; column 1 at full resolution. Every vertex of
	-- the fine block's shared edge must lie ON the line the coarse block draws there.
	local mixed = heights(TerrainMesh.buildChunk(cx, cz, field, noMat, function(gbx: number, _gbz: number): number
		return if (gbx - cx * BLOCKS) % 2 == 0 then BLOCK else 1
	end))
	local edgeX = Constants.cornerToWorld(gx0 + BLOCK)
	for b = 0, BLOCKS - 1 do
		local z0 = Constants.cornerToWorld(gz0 + b * BLOCK)
		local z1 = Constants.cornerToWorld(gz0 + (b + 1) * BLOCK)
		local lo, hi = at(mixed, edgeX, z0), at(mixed, edgeX, z1)
		for k = 1, BLOCK - 1 do
			local worldZ = Constants.cornerToWorld(gz0 + b * BLOCK + k)
			local expect = lo + (hi - lo) * (k / BLOCK)
			local got = at(mixed, edgeX, worldZ)
			assert(math.abs(got - expect) < 0.02,
				`block seam at z index {b * BLOCK + k}: fine edge at {got}, coarse block draws {expect}`)
		end
	end

	-- Only DOWN. A block finer than us stitches to OUR line, so ours must not move -- if
	-- both sides moved they would chase each other and neither edge would be the line.
	local facingFiner = heights(TerrainMesh.buildChunk(cx, cz, field, noMat, function(gbx: number, _gbz: number): number
		return if (gbx - cx * BLOCKS) % 2 == 0 then 2 else 1
	end))
	for k = 0, BLOCK, 2 do
		local worldZ = Constants.cornerToWorld(gz0 + k)
		assert(math.abs(at(facingFiner, Constants.cornerToWorld(gx0), worldZ) - at(h, Constants.cornerToWorld(gx0), worldZ)) < 0.02,
			`a coarse block moved for a FINER neighbour; only coarser edges stitch`)
	end

	-- A dead flat chunk must come out dead flat and at the height it was given. Nothing may
	-- be added to fake a vertical extent: corner vertices are shared with the neighbours, so
	-- nudging them to thicken the bounding box would reopen every seam around it.
	-- (CreateMeshPartAsync clamps Size.Y to 0.001 on its own and the triangles survive.)
	local flat = TerrainMesh.buildChunk(cx, cz, function() return 12 end, noMat, uniform(BLOCK))
	for i, p in flat.pos do
		assert(math.abs((flat.origin.Y + p.Y) - (12 + BULGE)) < 0.01,
			`flat chunk vertex {i} sits at {flat.origin.Y + p.Y}, not {12 + BULGE}`)
	end
	assert(faceNormal(flat, 0).Y > 0, "flat chunk triangle winds downward")

	-- == E: strides answer to the shape ======================================
	local function strides(f: (number, number) -> number): { number }
		return TerrainMesh.blockStrides(cx, cz, f, TOL)
	end
	local function every(list: { number }, value: number): boolean
		for _, s in list do if s ~= value then return false end end
		return true
	end

	assert(every(strides(function() return 30 end), BLOCK),
		"dead flat ground did not coarsen to one quad per block -- levelled ground would draw thousands of coplanar triangles")

	-- A straight ramp is EXACTLY what a coarse mesh draws, so a graded slope is as cheap as
	-- flat ground. If this ever fails, the test is measuring curvature wrong, not slope.
	assert(every(strides(function(gx, gz) return gx * 0.35 - gz * 0.2 end), BLOCK),
		"a straight ramp did not coarsen; only CURVATURE costs triangles, not gradient")

	-- One kerb-height step, which is what a road cut actually is. Placed mid-block so no
	-- coarse lattice line can land on it -- exactly the case that must not be smoothed away.
	local stepEdge = gx0 + 3 * BLOCK + 3
	local stepped = strides(function(gx) return if gx >= stepEdge then 6 else 5 end)
	assert(stepped[3 * BLOCKS + 4] == 1, "a one-stud step was coarsened away -- road cuts and kerbs would dissolve up close")

	-- ...and THE POINT: that step must not drag the rest of the chunk down with it. This is
	-- the bug per-block strides exist to fix, so it is asserted by the numbers, not by eye.
	local fine = 0
	for _, s in stepped do if s < BLOCK then fine += 1 end end
	assert(fine <= BLOCKS, `a single 4-stud-wide step held {fine} of {BLOCKS * BLOCKS} blocks at extra detail; it should reach one column`)

	-- The tolerance is a real threshold, not a rounding accident.
	local function wobble(amp: number)
		return function(gx: number, gz: number): number
			return 30 + amp * (if (gx + gz) % 2 == 0 then 1 else -1)
		end
	end
	assert(every(strides(wobble(TOL * 0.4)), BLOCK), `a wobble under the {TOL}-stud tolerance was treated as shape`)
	assert(every(strides(wobble(TOL * 4)), 1), `a wobble well over the {TOL}-stud tolerance was treated as flat`)

	-- UVs come off WORLD position, so the surface texture is nailed to the world: it cannot
	-- swim when a patch is rebuilt at a different stride, and it lines up across a chunk
	-- boundary because both sides derive it from the same coordinate. Every vertex used to
	-- carry UV (0,0), which is no mapping at all and is what made the ground crawl.
	-- Asserted per vertex rather than at samples, because it is the INVARIANT that matters:
	-- a UV is a pure function of world x/z. That alone gives both properties -- the same
	-- column rebuilt at another stride keeps its UV (nothing swims), and two chunks meeting
	-- at a column derive the same UV (the texture runs straight across the seam).
	local uvScale = Constants.MESH_TEXTURE_STUDS
	for i = 1, #geo.pos do
		local p = geo.pos[i]
		local want = Vector2.new((geo.origin.X + p.X) / uvScale, (geo.origin.Z + p.Z) / uvScale)
		assert((geo.uv[i] - want).Magnitude < 1e-4,
			`vertex {i} UV {geo.uv[i]} is not its world position over {uvScale} ({want})`)
	end
	local coarseUV = TerrainMesh.buildChunk(cx, cz, field, noMat, uniform(BLOCK))

	-- A corner must LOOK the same whatever stride its chunk happens to be drawn at, or the
	-- ground visibly changes every time LOD re-tessellates it. Colour is the trap: it is
	-- interpolated across the triangle, so any per-vertex tint spreads differently once the
	-- triangles change size. A noise tint was tried here and did exactly that -- soft blotches
	-- that landed somewhere new on every rebuild and read as the surface crawling. Colour must
	-- depend on the CORNER alone; detail finer than that belongs in a texture, sampled per
	-- pixel, where tessellation cannot reach it.
	local function colourByPosition(g: TerrainMesh.Geo): { [string]: Color3 }
		local out: { [string]: Color3 } = {}
		for i, p in g.pos do
			out[`{math.round((g.origin.X + p.X) * 8)}:{math.round((g.origin.Z + p.Z) * 8)}`] = g.col[i]
		end
		return out
	end
	local fineCol = colourByPosition(TerrainMesh.buildChunk(cx, cz, field, noMat, uniform(1)))
	local coarseCol = colourByPosition(coarseUV)
	local compared = 0
	for key, c in coarseCol do
		local f = fineCol[key]
		if f then
			compared += 1
			local d = math.abs(f.R - c.R) + math.abs(f.G - c.G) + math.abs(f.B - c.B)
			assert(d < 1e-4, `corner {key} is colour {f} at stride 1 but {c} at stride {BLOCK} -- the ground would change appearance when LOD re-tessellates it`)
		end
	end
	assert(compared > 50, `only {compared} corners were shared between the two strides; this check proves nothing`)

	-- The comparison above is necessary but NOT sufficient, and it is worth saying why: a tint
	-- sampled from world position gives a shared corner the same value at either stride, so it
	-- sails through. The damage is in the INTERPOLATION BETWEEN corners -- at stride 8 a tint
	-- spreads across a 32-stud quad, at stride 1 across 4 studs, and that is what crawls.
	--
	-- So the property that actually bites: across ground of ONE material at ONE height, every
	-- corner must be the SAME colour. Then whatever the triangles do, interpolating between
	-- two identical colours is exact. Any per-vertex variation fails this immediately, which
	-- is the point -- a noise tint was reintroduced by hand to confirm this check catches it.
	local evenGround = TerrainMesh.buildChunk(cx, cz, function() return 30 end, noMat, uniform(1))
	local reference = evenGround.col[1]
	for i, c in evenGround.col do
		local d = math.abs(c.R - reference.R) + math.abs(c.G - reference.G) + math.abs(c.B - reference.B)
		assert(d < 1e-4,
			`corner {i} of dead flat single-material ground is {c}, not {reference} -- colour varies WITHIN a triangle, so it is interpolated and will crawl when the mesh re-tessellates`)
	end

	-- Far ground merges the whole chunk into one grid. Capped at a block the coarsest the map
	-- could ever be was one quad per 32 studs, which is not cheap at 5,000 studs away.
	local far = TerrainMesh.buildChunk(cx, cz, field, noMat, uniform(32))
	assert(#far.tri // 3 == (TILES // 32) ^ 2 * 2,
		`a merged far chunk should be {(TILES // 32) ^ 2 * 2} triangles, got {#far.tri // 3}`)
	assert(#far.tri // 3 < #coarseUV.tri // 3, "merging did not make the far chunk cheaper than block-capped")
	assert(faceNormal(far, 0).Y > 0, "merged far chunk winds downward")

	-- F  MERGING IS A TRANSLATION AND NOTHING ELSE.
	-- The far map is drawn as one mesh per block of chunks, because the BAKE is what a chunk
	-- costs (~30 ms flat, whether it holds 8 triangles or 2,000) and 1,024 of them is ~32 s of
	-- a cold load. Every vertex therefore has to come out of mergeGeo at the same WORLD point
	-- it went in at: the merged mesh is positioned by ONE origin instead of four, and an error
	-- in that rebase draws the far ground somewhere the heightmap is not. Nothing near the
	-- camera would show it -- this is the check that does.
	local group = {}
	for dz = 0, 1 do
		for dx = 0, 1 do
			group[#group + 1] = TerrainMesh.buildChunk(cx + dx, cz + dz, field, noMat, uniform(8))
		end
	end
	local one = TerrainMesh.mergeGeo(group)

	local function worldKey(o: Vector3, p: Vector3): string
		return `{math.round((o.X + p.X) * 8)}:{math.round((o.Y + p.Y) * 8)}:{math.round((o.Z + p.Z) * 8)}`
	end

	local sourcePoints: { [string]: boolean } = {}
	local wantVerts, wantTris = 0, 0
	for _, g in group do
		wantVerts += #g.pos
		wantTris += #g.tri // 3
		for _, p in g.pos do
			sourcePoints[worldKey(g.origin, p)] = true
		end
	end

	assert(#one.pos == wantVerts, `merge lost vertices: {#one.pos} of {wantVerts}`)
	assert(#one.tri // 3 == wantTris, `merge lost triangles: {#one.tri // 3} of {wantTris}`)
	for i, p in one.pos do
		assert(sourcePoints[worldKey(one.origin, p)],
			`merged vertex {i} landed at {one.origin + p}, a world point no source chunk had`)
	end

	-- Rebased INDICES, not just positions. This is asserted as exact multiset equality of the
	-- TRIANGLES in world space, because the weaker checks do not bite: a triangle list left
	-- un-offset still indexes inside the merged vertex array and still winds upward -- it just
	-- joins the second chunk's corners to the FIRST chunk's vertices, which shreds the far
	-- ground into stray triangles hundreds of studs long. Every triangle the group had must
	-- come out, once, joining the same three world points.
	local function triKey(g: TerrainMesh.Geo, t: number): string
		local k = t * 3
		local pts = { worldKey(g.origin, g.pos[g.tri[k + 1]]),
			worldKey(g.origin, g.pos[g.tri[k + 2]]),
			worldKey(g.origin, g.pos[g.tri[k + 3]]) }
		table.sort(pts)
		return table.concat(pts, "|")
	end

	local sourceTris: { [string]: number } = {}
	for _, g in group do
		for t = 0, #g.tri // 3 - 1 do
			local key = triKey(g, t)
			sourceTris[key] = (sourceTris[key] or 0) + 1
		end
	end
	for t = 0, wantTris - 1 do
		local key = triKey(one, t)
		local left = sourceTris[key] or 0
		assert(left > 0,
			`merged triangle {t} joins three world points no source chunk joined -- the triangle ` ..
			`indices were not rebased onto the shared vertex list`)
		sourceTris[key] = left - 1
	end
	assert(faceNormal(one, 0).Y > 0, "merged group winds downward -- the far ground would be invisible from above")

	-- The origin has to be the bounding-box centre in X/Z, because CreateMeshPartAsync sizes
	-- the part from the mesh extent and positions it by that centre. For this 2x2 group that is
	-- the corner the four chunks meet at.
	local seam = Constants.cornerToWorld((cx + 1) * TILES)
	assert(math.abs(one.origin.X - seam) < 0.01 and math.abs(one.origin.Z - Constants.cornerToWorld((cz + 1) * TILES)) < 0.01,
		`merged origin {one.origin} is not the centre of the group's footprint ({seam}) -- the part would sit offset from the ground it draws`)

	-- == G: the waterline is never drawn coarse ==============================
	-- A block whose VISIBLE surface (heightmap + bulge) crosses sea level is capped, so the
	-- far LOD cannot lift a beach or a river channel above the water. Dry land and open sea
	-- are left alone -- a cap there would only cost triangles -- and a chunk with no shore at
	-- all answers nil, which is what keeps the far map on its fast path.
	local function capsOf(f: (number) -> number): { number }?
		local w = TILES + 1
		local b = buffer.create(w * w * 2)
		for j = 0, TILES do
			for i = 0, TILES do
				buffer.writeu16(b, (j * w + i) * 2, Constants.worldYToRaw(f(i)))
			end
		end
		return TerrainMesh.shoreCaps(b)
	end
	local shoreCol = 3
	local shoreEdge = shoreCol * BLOCK + BLOCK // 2
	local shore = capsOf(function(i) return (i - shoreEdge) * 0.5 - BULGE end)
	assert(shore, "a chunk with a shoreline reported no caps -- far coasts would pop")
	local shoreCaps = shore :: { number }
	assert(shoreCaps[2 * BLOCKS + shoreCol + 1] == 4,
		`a block crossing sea level was capped at {shoreCaps[2 * BLOCKS + shoreCol + 1]}, not 4 -- far coasts would pop`)
	assert(shoreCaps[2 * BLOCKS + 1] == 0 and shoreCaps[2 * BLOCKS + BLOCKS] == 0,
		"blocks far from the waterline were capped -- the cap would cost triangles over open sea and dry land")
	assert(capsOf(function() return 30 end) == nil, "dry high ground reported caps -- the far fast path would be lost")
	assert(capsOf(function() return -20 end) == nil, "deep seabed reported caps -- the far fast path would be lost")

	-- == H: the error bound the LOD picks strides from ======================
	-- TerrainMeshView draws a block at the coarsest stride whose BOUND is within a pixel, so
	-- the bound must never read under the real error -- an under-read is visible popping.
	-- Measured here against every corner of every block, at every block stride.
	local bounds = TerrainMesh.strideErrors(cx, cz, field)
	local function exactError(bx: number, bz: number, s: number): number
		local worst = 0
		for cj = bz * BLOCK, (bz + 1) * BLOCK - s, s do
			for ci = bx * BLOCK, (bx + 1) * BLOCK - s, s do
				local h00, h10 = field(gx0 + ci, gz0 + cj), field(gx0 + ci + s, gz0 + cj)
				local h01, h11 = field(gx0 + ci, gz0 + cj + s), field(gx0 + ci + s, gz0 + cj + s)
				for dj = 0, s do
					for di = 0, s do
						local u, v = di / s, dj / s
						local on = if u <= v then h00 + (h01 - h00) * (v - u) + (h11 - h00) * u
							else h00 + (h10 - h00) * (u - v) + (h11 - h00) * v
						worst = math.max(worst, math.abs(field(gx0 + ci + di, gz0 + cj + dj) - on))
					end
				end
			end
		end
		return worst
	end
	local checked = 0
	for bz = 0, BLOCKS - 1 do
		for bx = 0, BLOCKS - 1 do
			for k, s in { 2, 4, 8 } do
				local bound = bounds[(bz * BLOCKS + bx) * 3 + k]
				local real = exactError(bx, bz, s)
				assert(bound >= real - 1e-6, `block ({bx},{bz}) stride {s}: bound {bound} under the real error {real} -- LOD would pop`)
				checked += 1
			end
		end
	end
	assert(checked == BLOCKS * BLOCKS * 3, "the bound check skipped blocks")

	-- The skirt hangs below the edge and moves nothing: every surface vertex keeps its world
	-- position after it is added, whatever re-centring the deeper extent forced.
	local skirted = TerrainMesh.buildChunk(cx, cz, field, noMat, uniform(2))
	local before = heights(skirted)
	local surfaceCount = #skirted.pos
	TerrainMesh.addSkirt(skirted, 3)
	for i = 1, surfaceCount do
		local p = skirted.pos[i]
		local y = at(before, skirted.origin.X + p.X, skirted.origin.Z + p.Z)
		assert(math.abs((skirted.origin.Y + p.Y) - y) < 0.01, `skirt moved surface vertex {i}`)
	end
	assert(#skirted.pos > surfaceCount, "no skirt was added")

	print("[TerrainMesh.spec] OK")
	return true
end

return M
