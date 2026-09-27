--!strict
-- Ground geometry for ONE heightmap chunk, as flat arrays. Pure library: no Instances, no
-- EditableMesh, no Heightmap -- heights and materials come in through two samplers, so it
-- runs in a spec against plain tables. TerrainMeshView turns the arrays into a MeshPart.
--
-- A chunk is a grid of BLOCKS x BLOCKS blocks, and each block picks its own corner stride
-- (1 = every heightmap corner, 4 studs; 8 = one quad for the whole 32-stud block). Stride
-- is a property of a BLOCK rather than of the chunk because detail is: a road clipping one
-- corner of a 256-stud chunk has shape in a tenth of its area, and judging the chunk as a
-- whole made the other nine tenths -- levelled dead flat -- pay full price for it.
--
-- Blocks of different strides meet everywhere, so stitching is the norm, not an edge case:
-- an edge facing a COARSER block has its in-between vertices pulled onto the straight line
-- that block draws there, so both sides describe the same line and there is no crack. It
-- costs no extra triangles, and because `strideAt` answers for blocks in NEIGHBOURING
-- chunks too, a chunk boundary is just another block boundary -- there is no separate case
-- for it anywhere in this file. The first version hid cracks behind a vertical apron
-- instead; an apron is ~8n triangles against 2n^2, i.e. it doubled the cost of exactly the
-- coarse ground that LOD exists to make cheap.
--
-- This is a SURFACE, not a solid: no underside, no walls. Nothing renders below the skin
-- because nothing needs to yet. When digging cuts a hole through it, that hole's walls get
-- built then, for the holes that exist -- not as a permanent apron on all 1024 chunks.
--
-- Vertices carry the VISIBLE surface: heightmap + RENDER_BULGE. The voxel painter drew the
-- surface half a voxel above the heightmap and every road, pad and building in the game
-- places against THAT, so the mesh keeps the same contract and nothing upstream moves.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)

local TerrainMesh = {}

local CHUNK_TILES = Constants.CHUNK_TILES
local CHUNK_STUDS = Constants.CHUNK_STUDS
local SPACING = Constants.SAMPLE_SPACING
local HALF = Constants.MAP_HALF_EXTENT
local BULGE = Constants.RENDER_BULGE
local SEA_Y = Constants.SEA_Y
local BLOCK_TILES = Constants.MESH_BLOCK_TILES
local TEX_STUDS = Constants.MESH_TEXTURE_STUDS
local cornerToWorld = Constants.cornerToWorld
local BLOCKS = CHUNK_TILES // BLOCK_TILES

export type Geo = {
	origin: Vector3, -- world position of the mesh centre; vertices are relative to it
	pos: { Vector3 },
	nrm: { Vector3 },
	col: { Color3 },
	uv: { Vector2 }, -- world-derived, so the surface texture cannot swim
	tri: { number }, -- 1-based vertex indices, three per triangle
}


-- Ground colour from height, slope and depth, in the palette of a city-builder map: lush
-- green in the lowlands drying to olive and sandy tan as the ground climbs or steepens, rock
-- on real cliffs, sand at the beach, and under the water a seabed that darkens with depth.
--
-- THE SEABED IS THE WATER'S COLOUR. The engine water is translucent, so what shows through it
-- is this: pale sand in the shallows reads turquoise, the drop-off reads teal, deep water
-- reads navy. It used to be painted by a decal a hair above the water surface, which
-- z-fought the animated water and flickered.
--
-- Every term is a SMOOTH blend, never a hard zone edge. A vertex colour is interpolated across
-- its triangle, and LOD changes the triangles; a hard edge between two vertices smears
-- differently at each stride and the boundary visibly crawls. A slow blend barely moves.
-- (A per-vertex NOISE tint was tried once and crawled for the same reason. The fine
-- variation still comes from the surface texture, sampled per pixel.)
local COL_SAND = Color3.fromRGB(214, 198, 152)
local COL_WET_SAND = Color3.fromRGB(190, 178, 132)
local COL_SHELF = Color3.fromRGB(128, 150, 118) -- sand under a few studs of water, algae-tinted
local COL_DROP = Color3.fromRGB(52, 86, 92)
local COL_DEEP = Color3.fromRGB(22, 40, 52)
local COL_LUSH = Color3.fromRGB(88, 124, 46)
local COL_MEADOW = Color3.fromRGB(114, 136, 58)
local COL_DRY = Color3.fromRGB(166, 152, 98)
local COL_ROCK = Color3.fromRGB(128, 118, 104)
local COL_SNOW = Color3.fromRGB(236, 238, 242)

-- Visible studs above the water where sand gives way to grass. A beach is a LINE along the
-- water, not a zone: low coastal flats a stud or two up are grass, as they are on a real coast.
local BEACH_TOP = 1.1
local SNOW_LINE = 170

local function ramp(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Explicit player/road material overrides -> their colour. Keys are TerrainConstants.Material.
local OVERRIDE = table.freeze({
	[1] = COL_MEADOW,
	[2] = COL_SAND,
	[3] = COL_ROCK,
	[4] = COL_SNOW,
	[5] = Color3.fromRGB(134, 112, 88), -- GROUND
	[6] = Color3.fromRGB(92, 74, 56), -- MUD
	[7] = COL_LUSH, -- LEAFY (the base map's own surface)
})

-- worldY is the HEIGHTMAP value; the visible surface, which is what meets the water, is two
-- studs above it (RENDER_BULGE).
function TerrainMesh.surfaceColor(worldY: number, slopeRad: number, matId: number): Color3
	local override = OVERRIDE[matId]
	if override then return override end
	local s = worldY + BULGE - SEA_Y
	if s < 0 then
		local d = -s
		if d < 4 then return COL_WET_SAND:Lerp(COL_SHELF, ramp(0, 4, d)) end
		if d < 16 then return COL_SHELF:Lerp(COL_DROP, ramp(4, 16, d)) end
		return COL_DROP:Lerp(COL_DEEP, ramp(16, 45, d))
	end
	local slopeDeg = math.deg(slopeRad)
	local c = COL_LUSH:Lerp(COL_MEADOW, ramp(4, 30, s))
	c = c:Lerp(COL_DRY, ramp(28, 110, s) * 0.85 + ramp(18, 34, slopeDeg) * 0.5)
	c = c:Lerp(COL_ROCK, ramp(32, 48, slopeDeg))
	c = c:Lerp(COL_SNOW, ramp(SNOW_LINE, SNOW_LINE + 30, s) * (1 - ramp(35, 50, slopeDeg)))
	-- Sand only on the gentle part of the shore: a cliff dropping into the sea stays rock.
	return c:Lerp(COL_SAND, (1 - ramp(0.25, BEACH_TOP, s)) * (1 - ramp(14, 26, slopeDeg)))
end

-- How far the mesh drawn at each stride can stray from the full-resolution grid, for one chunk.
-- Returns `blocks`, three per block row-major (strides 2, 4, 8 at base + 1..3), and `chunk`,
-- keyed by the merged strides 16, 32, 64.
--
-- An UPPER BOUND, built bottom-up, which is what makes it cheap: a stride-2s quad strays from
-- the truth by at most what its four stride-s children do plus how far the stride-s lattice sits
-- from the 2s surface. Both surfaces are linear on every stride-s triangle (the diagonals all
-- run the same way), so that second term is exact at five points per quad. ~5,700 point tests a
-- chunk for every stride at once, against ~34,000 to measure each one exactly. Never under the
-- real error, so a stride it accepts is always within tolerance.
function TerrainMesh.strideErrors(cx: number, cz: number, sampleY: (number, number) -> number): ({ number }, { [number]: number })
	local gx0, gz0 = cx * CHUNK_TILES, cz * CHUNK_TILES
	local w = CHUNK_TILES + 1
	local h = table.create(w * w)
	for j = 0, CHUNK_TILES do
		local base = j * w
		local gz = gz0 + j
		for i = 0, CHUNK_TILES do
			h[base + i + 1] = sampleY(gx0 + i, gz)
		end
	end

	local blocks = table.create(BLOCKS * BLOCKS * 3, 0)
	local chunk: { [number]: number } = {}
	local prev: { number }? = nil
	local n = CHUNK_TILES
	local s = 1
	local level = 0
	while s < CHUNK_TILES do
		local s2 = s * 2
		local n2 = CHUNK_TILES // s2
		local cur = table.create(n2 * n2)
		level += 1
		local worst = 0
		for qj = 0, n2 - 1 do
			local r0 = qj * s2 * w + 1
			local rm = r0 + s * w
			local r1 = r0 + s2 * w
			for qi = 0, n2 - 1 do
				local i = qi * s2
				local h00, h10, h01, h11 = h[r0 + i], h[r0 + i + s2], h[r1 + i], h[r1 + i + s2]
				local dev = math.max(
					math.abs(h[r0 + i + s] - (h00 + h10) * 0.5),
					math.abs(h[rm + i] - (h00 + h01) * 0.5),
					math.abs(h[rm + i + s] - (h00 + h11) * 0.5),
					math.abs(h[rm + i + s2] - (h10 + h11) * 0.5),
					math.abs(h[r1 + i + s] - (h01 + h11) * 0.5)
				)
				local e = dev
				if prev then
					local c = qj * 2 * n + qi * 2 + 1
					e += math.max(prev[c], prev[c + 1], prev[c + n], prev[c + n + 1])
				end
				cur[qj * n2 + qi + 1] = e
				if s2 <= BLOCK_TILES then
					local k = ((i // BLOCK_TILES) + (qj * s2 // BLOCK_TILES) * BLOCKS) * 3 + level
					if e > blocks[k] then blocks[k] = e end
				elseif e > worst then
					worst = e
				end
			end
		end
		if s2 > BLOCK_TILES then chunk[s2] = worst end
		prev, n, s = cur, n2, s2
	end
	return blocks, chunk
end

-- The coarsest block stride (1, 2, 4 or 8) whose error bound is within `tol`. The bound only
-- grows with the stride, so the first fit from the coarse end is the answer.
function TerrainMesh.blockStride(blocks: { number }, index: number, tol: number): number
	local base = (index - 1) * 3
	if blocks[base + 3] <= tol then return 8 end
	if blocks[base + 2] <= tol then return 4 end
	if blocks[base + 1] <= tol then return 2 end
	return 1
end

-- The coarsest lossless stride for EVERY BLOCK of a chunk, row-major, BLOCKS x BLOCKS.
--
-- Per block, not per chunk, and that is the whole point. A chunk is 256 studs across; a
-- road clipping one corner of it has shape in maybe a tenth of that area. Judging the chunk
-- as a whole let that road drag all 8,192 triangles onto ground that had been levelled dead
-- flat. At 32 studs a block is small enough that the road keeps its detail and the field
-- beside it collapses to single quads.
function TerrainMesh.blockStrides(
	cx: number,
	cz: number,
	sampleY: (number, number) -> number,
	tol: number
): { number }
	local blocks = TerrainMesh.strideErrors(cx, cz, sampleY)
	local out = table.create(BLOCKS * BLOCKS)
	for index = 1, BLOCKS * BLOCKS do
		out[index] = TerrainMesh.blockStride(blocks, index, tol)
	end
	return out
end

-- Hang a curtain `depth` studs deep under the chunk's four border edges.
--
-- Neighbouring chunks are separate meshes rebuilt on separate frames, so for a frame or two
-- after one of them changes detail their shared edge can disagree and open a crack onto the
-- sky -- a flicker along the seam. The curtain fills it. It hangs BELOW the surface, so
-- wherever the edges agree none of it can be seen. Both windings, because a crack can be looked
-- into from either side. Kept out of buildChunk: the surface contract (spec A-E) is about the
-- skin, and this is not skin.
function TerrainMesh.addSkirt(geo: Geo, depth: number)
	local half = CHUNK_STUDS * 0.5
	local pos, nrm, col, uv, tri = geo.pos, geo.nrm, geo.col, geo.uv, geo.tri
	-- Border vertices per edge (-Z, +X, +Z, -X), one per position: block corners are
	-- duplicated between the patches that share them.
	local edges: { { number } } = { {}, {}, {}, {} }
	local seen: { [number]: boolean } = {}
	local function take(e: number, i: number, along: number)
		local key = e * 1e7 + math.round(along * 8)
		if seen[key] then return end
		seen[key] = true
		table.insert(edges[e], i)
	end
	for i = 1, #pos do
		local p = pos[i]
		if math.abs(p.Z + half) < 1e-3 then take(1, i, p.X) end
		if math.abs(p.X - half) < 1e-3 then take(2, i, p.Z) end
		if math.abs(p.Z - half) < 1e-3 then take(3, i, p.X) end
		if math.abs(p.X + half) < 1e-3 then take(4, i, p.Z) end
	end

	local down = Vector3.new(0, depth, 0)
	for e, list in edges do
		local alongX = e == 1 or e == 3
		table.sort(list, function(a: number, b: number): boolean
			return if alongX then pos[a].X < pos[b].X else pos[a].Z < pos[b].Z
		end)
		local bottom = table.create(#list)
		for k, i in list do
			local b = #pos + 1
			pos[b] = pos[i] - down
			nrm[b] = nrm[i]
			col[b] = col[i]
			uv[b] = uv[i]
			bottom[k] = b
		end
		for k = 1, #list - 1 do
			local a, b, a2, b2 = list[k], list[k + 1], bottom[k], bottom[k + 1]
			local t = #tri
			tri[t + 1], tri[t + 2], tri[t + 3] = a, b, b2
			tri[t + 4], tri[t + 5], tri[t + 6] = a, b2, a2
			tri[t + 7], tri[t + 8], tri[t + 9] = a, b2, b
			tri[t + 10], tri[t + 11], tri[t + 12] = a, a2, b2
		end
	end

	-- Re-centre Y exactly as buildChunk does: the part is sized and positioned from the mesh
	-- extent, which the curtain just deepened.
	local minY, maxY = math.huge, -math.huge
	for _, p in pos do
		if p.Y < minY then minY = p.Y end
		if p.Y > maxY then maxY = p.Y end
	end
	local yc = (minY + maxY) * 0.5
	for i, p in pos do
		pos[i] = Vector3.new(p.X, p.Y - yc, p.Z)
	end
	geo.origin += Vector3.new(0, yc, 0)
end

-- Per-block stride CAPS for one chunk, straight off its raw height buffer, or nil when no
-- block reaches the waterline (which is most chunks: dry inland and open deep sea alike).
--
-- A block whose visible surface crosses sea level is never drawn coarser than SHORE_STRIDE,
-- however far away it is. Coarse facets there lift the beach and fill river channels above
-- the water, and the coast then jumped every time the camera crossed an LOD ring -- the ground
-- "flickering because of the water".
--
-- Raw u16 reads against raw thresholds, no sampleY: this runs for every far chunk on a cold
-- load, and going through the sampler cost ~2 s a map (measured) against ~0.1 s this way.
local SHORE_STRIDE = 4
local SHORE_BAND = 1.5 -- studs either side of sea level, on the visible surface
local CORNERS = CHUNK_TILES + 1
local RAW_LO = (SEA_Y - SHORE_BAND - BULGE - Constants.FLOOR_Y) / Constants.HEIGHT_STEP
local RAW_HI = (SEA_Y + SHORE_BAND - BULGE - Constants.FLOOR_Y) / Constants.HEIGHT_STEP

function TerrainMesh.shoreCaps(heights: buffer): { number }?
	local caps: { number }? = nil
	for bz = 0, BLOCKS - 1 do
		for bx = 0, BLOCKS - 1 do
			local lo, hi = math.huge, -math.huge
			for j = bz * BLOCK_TILES, (bz + 1) * BLOCK_TILES do
				local o = (j * CORNERS + bx * BLOCK_TILES) * 2
				for _ = 0, BLOCK_TILES do
					local r = buffer.readu16(heights, o)
					if r < lo then lo = r end
					if r > hi then hi = r end
					o += 2
				end
			end
			if lo < RAW_HI and hi > RAW_LO then
				if not caps then caps = table.create(BLOCKS * BLOCKS, 0) end
				(caps :: { number })[bz * BLOCKS + bx + 1] = SHORE_STRIDE
			end
		end
	end
	return caps
end

-- sampleY(gx, gz) -> heightmap worldY at a GLOBAL corner, WITHOUT the render bulge. Called
--   one corner OUTSIDE the chunk as well (for edge normals) and must answer there.
-- sampleMat(gx, gz) -> material id at a global corner (0 = AUTO).
-- strideAt(gbx, gbz) -> stride of the block at GLOBAL block coordinates, including blocks
--   in the neighbouring CHUNKS. That is what closes the chunk seam: to this builder a chunk
--   edge is just another block edge and there is no separate case for it anywhere.
function TerrainMesh.buildChunk(
	cx: number,
	cz: number,
	sampleY: (number, number) -> number,
	sampleMat: (number, number) -> number,
	strideAt: (number, number) -> number
): Geo
	local gx0, gz0 = cx * CHUNK_TILES, cz * CHUNK_TILES
	local gbx0, gbz0 = cx * BLOCKS, cz * BLOCKS
	local half = CHUNK_STUDS * 0.5

	-- ONE full-resolution padded grid for the whole chunk, with a one-corner border outside
	-- it. Every patch reads its heights and normals from here whatever stride it draws at,
	-- so two patches meeting at a corner compute the identical normal there and the boundary
	-- never lights up as a crease. The border does the same job at the chunk edge: a
	-- mirrored edge creases visibly.
	local pad = CHUNK_TILES + 3
	local h = table.create(pad * pad)
	for j = -1, CHUNK_TILES + 1 do
		local base = (j + 1) * pad + 2
		local gz = gz0 + j
		for i = -1, CHUNK_TILES + 1 do
			h[base + i] = sampleY(gx0 + i, gz)
		end
	end
	local inv2span = 1 / (2 * SPACING)

	local pos: { Vector3 } = {}
	local nrm: { Vector3 } = {}
	local col: { Color3 } = {}
	local uv: { Vector2 } = {}
	local tri: { number } = {}
	local minY, maxY = math.huge, -math.huge
	local t = 0

	-- One square of ground at one stride: `size` tiles across, starting at chunk-local tile
	-- (ti0, tj0). A block is one of these; a merged far chunk is a single one covering
	-- everything. `edge` gives the stride facing each of its four sides, in -Z/+X/+Z/-X order.
	local function emitPatch(ti0: number, tj0: number, size: number, step: number, edge: { number })
		local n = size // step
		local verts = n + 1
		local base = #pos

		for j = 0, n do
			local tj = tj0 + j * step
			local gz = gz0 + tj
			local z = tj * SPACING - half
			local worldZ = cornerToWorld(gz)
			local rowBase = (tj + 1) * pad + 2
			for i = 0, n do
				local ti = ti0 + i * step
				local k = rowBase + ti
				local y = h[k]
				local dx = (h[k + 1] - h[k - 1]) * inv2span
				local dz = (h[k + pad] - h[k - pad]) * inv2span
				local surf = y + BULGE
				local vi = base + j * verts + i + 1
				pos[vi] = Vector3.new(ti * SPACING - half, surf, z)
				nrm[vi] = Vector3.new(-dx, 1, -dz).Unit
				local worldX = cornerToWorld(gx0 + ti)
				col[vi] = TerrainMesh.surfaceColor(y, math.atan(math.sqrt(dx * dx + dz * dz)), sampleMat(gx0 + ti, gz))
				-- UV from WORLD position, so the texture is pinned to the world: it does not
				-- swim when a patch is rebuilt at another stride, and it lines up across every
				-- chunk and LOD boundary because neighbours derive it from the same coordinate.
				uv[vi] = Vector2.new(worldX / TEX_STUDS, worldZ / TEX_STUDS)
				if surf < minY then minY = surf end
				if surf > maxY then maxY = surf end
			end
		end

		-- Stitch each edge facing a COARSER patch. Where that patch samples one corner in
		-- `nstep` it draws a straight line between those samples, so our extra vertices in
		-- between move onto that line: both sides describe the same line and the seam closes
		-- exactly rather than being hidden behind anything. Patch CORNERS sit on every
		-- stride's lattice and are never moved, so two edges can never fight over one and a
		-- diagonal neighbour always agrees for free.
		--
		-- The line's end samples are read from the height GRID, not from this patch's vertices:
		-- a merged neighbour draws at 16 or 32 tiles, wider than this patch, so its samples can
		-- sit outside it -- indexing them as our own vertices read the next row (a wrong seam)
		-- or ran off the end (the "index nil with 'Y'" that dropped whole 4x4 blocks).
		-- ponytail: a patch CORNER that is off a merged neighbour's lattice still T-junctions;
		-- closing that means moving corners, which both patches sharing it would have to agree on.
		local function stitch(indexOf: (number) -> number, nstep: number, edgeTile: number, alongX: boolean, start: number)
			if nstep <= step then return end
			for i = 1, n - 1 do
				local t = start + i * step
				local r = t % nstep
				if r ~= 0 then
					local t0 = t - r
					local k0 = if alongX then (edgeTile + 1) * pad + 2 + t0 else (t0 + 1) * pad + 2 + edgeTile
					local k1 = if alongX then k0 + nstep else k0 + nstep * pad
					local vi = indexOf(i)
					local p = pos[vi]
					pos[vi] = Vector3.new(p.X, h[k0] + (h[k1] - h[k0]) * (r / nstep) + BULGE, p.Z)
				end
			end
		end
		local ti1, tj1 = ti0 + size, tj0 + size
		stitch(function(i) return base + i + 1 end, edge[1], tj0, true, ti0)
		stitch(function(j) return base + j * verts + n + 1 end, edge[2], ti1, false, tj0)
		stitch(function(i) return base + n * verts + i + 1 end, edge[3], tj1, true, ti0)
		stitch(function(j) return base + j * verts + 1 end, edge[4], ti0, false, tj0)

		for j = 0, n - 1 do
			for i = 0, n - 1 do
				local a = base + j * verts + i + 1 -- (i, j)
				local b = a + verts -- (i, j+1)
				local c = b + 1 -- (i+1, j+1)
				local d = a + 1 -- (i+1, j)
				tri[t + 1], tri[t + 2], tri[t + 3] = a, b, c
				tri[t + 4], tri[t + 5], tri[t + 6] = a, c, d
				t += 6
			end
		end
	end

	-- Does every block of the chunk want a stride COARSER than a block? Then blocks stop being
	-- a useful unit and it is drawn as ONE patch. A stride of exactly one block stays on the
	-- per-block path, which stitches to its neighbours properly.
	local mergedMemo: { [number]: number } = {}
	local function mergedStride(ccx: number, ccz: number): number -- 0 = drawn as blocks
		local key = ccz * 65536 + ccx
		local memo = mergedMemo[key]
		if memo then return memo end
		local bx0, bz0 = ccx * BLOCKS, ccz * BLOCKS
		local m = strideAt(bx0, bz0)
		if m <= BLOCK_TILES then
			m = 0
		else
			for bz = 0, BLOCKS - 1 do
				for bx = 0, BLOCKS - 1 do
					if strideAt(bx0 + bx, bz0 + bz) ~= m then
						m = 0
						break
					end
				end
				if m == 0 then break end
			end
		end
		mergedMemo[key] = m
		return m
	end
	-- The stride a neighbouring block is actually DRAWN at. Past BLOCK_TILES a block is capped
	-- unless its whole chunk merged into one patch, so strideAt alone overstates it.
	local function drawnStride(gbx: number, gbz: number): number
		local s = strideAt(gbx, gbz)
		if s <= BLOCK_TILES then return s end
		return if mergedStride(gbx // BLOCKS, gbz // BLOCKS) == s then s else BLOCK_TILES
	end

	local merged = mergedStride(cx, cz)
	if merged > 0 then
		-- Stitched like any block: a neighbouring chunk merged even coarser draws a straight
		-- line along our edge, and our extra vertices have to land on it.
		emitPatch(0, 0, CHUNK_TILES, merged, {
			drawnStride(gbx0, gbz0 - 1),
			drawnStride(gbx0 + BLOCKS, gbz0),
			drawnStride(gbx0, gbz0 + BLOCKS),
			drawnStride(gbx0 - 1, gbz0),
		})
	else
		for bz = 0, BLOCKS - 1 do
			for bx = 0, BLOCKS - 1 do
				local step = math.min(strideAt(gbx0 + bx, gbz0 + bz), BLOCK_TILES)
				emitPatch(bx * BLOCK_TILES, bz * BLOCK_TILES, BLOCK_TILES, step, {
					drawnStride(gbx0 + bx, gbz0 + bz - 1),
					drawnStride(gbx0 + bx + 1, gbz0 + bz),
					drawnStride(gbx0 + bx, gbz0 + bz + 1),
					drawnStride(gbx0 + bx - 1, gbz0 + bz),
				})
			end
		end
	end

	-- MeshPart geometry is centred on its own bounding box (CreateMeshPartAsync sizes the
	-- part from the mesh extent), so shift Y here and hand the world centre back as `origin`.
	-- X/Z are already centred: the grid spans -half..half. A dead flat chunk is left alone --
	-- measured, CreateMeshPartAsync clamps its Size.Y to 0.001 and the triangles survive
	-- intact (a ray still lands on the surface), so it needs no artificial thickness.
	local yc = (minY + maxY) * 0.5
	for i = 1, #pos do
		local p = pos[i]
		pos[i] = Vector3.new(p.X, p.Y - yc, p.Z)
	end

	return {
		origin = Vector3.new(-HALF + (cx + 0.5) * CHUNK_STUDS, yc, -HALF + (cz + 0.5) * CHUNK_STUDS),
		pos = pos,
		nrm = nrm,
		col = col,
		uv = uv,
		tri = tri,
	}
end

-- Several chunks' geometry as ONE mesh.
--
-- WHY THIS EXISTS: the BAKE is what a chunk costs, not its geometry. Measured in this place,
-- CreateDataModelContentAsync + CreateMeshPartAsync is ~30 ms whether the mesh holds 8
-- triangles or 2,000 -- so distance LOD, which makes the far map cheap to DRAW, does nothing
-- at all for how long it takes to BUILD, and 1,024 separate bakes is ~32 s of pure API
-- overhead on a cold load. 49 far chunks merged bake in 34 ms; the same 49 separately take
-- 1.5 s.
--
-- Pure translation, so a merged mesh is the same surface as the parts were: each part's
-- vertices are relative to its own centre, so they are rebased onto the shared one. Y is
-- then recentred exactly as buildChunk does it, because CreateMeshPartAsync sizes the part
-- from the mesh extent -- vertices left around each chunk's own midpoint would come back in a
-- part whose Size and therefore whose position is wrong.
--
-- Callers pass a RECTANGULAR group: the mean of the parts' origins is the centre of their
-- union only for a rectangle, and that centre has to be the bounding-box centre in X/Z or
-- the part sits offset from the ground it draws. `step`, if given, runs between parts, so a
-- caller can yield the frame there.
function TerrainMesh.mergeGeo(parts: { Geo }, step: (() -> ())?): Geo
	local n = #parts
	assert(n > 0, "mergeGeo: nothing to merge")

	local sumX, sumZ = 0, 0
	for _, g in parts do
		sumX += g.origin.X
		sumZ += g.origin.Z
	end
	local cx, cz = sumX / n, sumZ / n

	local pos, nrm, col, uv, tri = {}, {}, {}, {}, {}
	local minY, maxY = math.huge, -math.huge
	for _, g in parts do
		local dx, dy, dz = g.origin.X - cx, g.origin.Y, g.origin.Z - cz
		local base = #pos
		for i, p in g.pos do
			local wy = p.Y + dy
			if wy < minY then minY = wy end
			if wy > maxY then maxY = wy end
			pos[base + i] = Vector3.new(p.X + dx, wy, p.Z + dz)
			nrm[base + i] = g.nrm[i]
			col[base + i] = g.col[i]
			uv[base + i] = g.uv[i]
		end
		for _, v in g.tri do
			tri[#tri + 1] = v + base
		end
		if step then step() end
	end

	local yc = (minY + maxY) * 0.5
	for i, p in pos do
		pos[i] = Vector3.new(p.X, p.Y - yc, p.Z)
	end

	return { origin = Vector3.new(cx, yc, cz), pos = pos, nrm = nrm, col = col, uv = uv, tri = tri }
end

return TerrainMesh
