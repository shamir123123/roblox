--!strict
-- RoadMeshView -- mesh blocks per map CELL of road pieces (a dense cell splits into
-- several MeshParts to stay under the engine triangle cap), built from DATA. The server ships each
-- segment / junction / corner / dead-end as a Model holding a "RoadMeshSpecs" blob (boxes,
-- wedges, welded surface strips, AND painted marking lines -- see RoadMeshBuilder) plus one
-- invisible collision MeshPart. This view watches workspace._City.Roads, decodes the blob,
-- and bakes the whole piece into a single vertex-coloured EditableMesh MeshPart: markings
-- are thin ribbons baked in (solid = continuous, dashed = one short quad per dash with bare
-- gaps that reveal the asphalt) -- lane paint is IN the mesh, no beams and no separate mesh.
-- (Roblox does not honour EditableImage alpha on a MeshPart texture, so dashes are geometry
-- gaps, not a tiling texture.) Decal symbol plates (turn arrows, speed numerals) stay live.
--
-- EditableMesh lifetime: geometry is built in ONE scratch dynamic EM per batch, baked to
-- STATIC content via AssetService:CreateDataModelContentAsync (full release May 2026;
-- static content does NOT count against the tiny client Editable* memory budget -- roughly
-- 8 dynamic EMs' worth), and the scratch is destroyed immediately. Bakes run one at a
-- time, so at most ONE EditableMesh ever exists regardless of city size.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadMeshBuilder = require(
	ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadMeshBuilder")
)
local RoadConstants = require(
	ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadConstants")
)
local Quant = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Quant"))
local LOD = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LOD"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local UP = Vector3.yAxis
local DASH_LENGTH = RoadConstants.DASH_LENGTH
local DASH_PITCH = RoadConstants.DASH_LENGTH + RoadConstants.DASH_GAP

local RoadMeshView = {}

local REBUILD_QUIET = 0.1
local FOLDER_WAIT = 30

-- Chunked baking: road pieces bake per map cell, not per piece -- fewer MeshParts and
-- draw calls, and placing a road only rebakes its own 256-stud neighbourhood.
local CELL_SIZE = 256

-- The engine rejects a bake past ~20k triangles ("Triangle count above limit"), so a
-- cell's specs are batched into as many MeshParts as needed, each under this budget.
-- With the static bake there is no memory-budget ceiling on total road geometry.
local MAX_TRIS_PER_MESH = 19_000

-- Distance LOD: the levels of Shared.LOD, applied per CELL, ~tens of cells per tick.
--   NEAR/MID  full
--   FAR       lane paint hidden -- a 0.3-stud ribbon is under the pixel budget by here
--   CULL      lane paint DESTROYED, handing its geometry memory back; re-baked through
--             the normal queue once you are back inside MID
-- Paint is one quad per dash and per zebra stripe, so it is a big slice of the triangle
-- count. The base slabs are never touched -- they ARE the far view of the city.
--
-- Do NOT strip their MaterialVariant/TextureID to save texture sampling: vertex colours here
-- are pre-boosted by `gain` precisely BECAUSE they multiply the colour map, so with the map
-- gone there is nothing to multiply and mid-grey asphalt clamps out to white. Not worth
-- compensating for either -- the maps are shared assets that stay resident for the near cells
-- regardless, so dropping them on far cells frees nothing.
-- The engine offers no cheaper option here: RenderFidelity=Automatic is a no-op for runtime
-- meshes (LOD chains are precomputed at asset upload; EM bakes have none), Model.LevelOfDetail
-- needs StreamingEnabled which this place runs without, and there is no runtime
-- render-to-texture, so a far cell cannot be flattened into a real imposter image.
-- ponytail: next rung if still heavy -- split kerb side/bottom faces out of the base bake.
local LOD_PERIOD = 0.3

-- The shared ladder drops a 0.3-stud ribbon at ~460 studs (1080p, 70 fov), which reads as too
-- eager from a city camera. Stretch the ladder for ROADS only -- the shared bands stay put for
-- buildings and tools -- so paint starts fading out around 1200 studs instead. Still
-- screen-space: a taller viewport or a narrower fov pushes the real cut-off further out.
-- Raising this also pushes CULL out (~1540 -> ~4000 studs), so far paint geometry stays
-- resident longer -- that is the cost of the wider view.
local PAINT_RANGE_SCALE = 2.6

-- Textured surfaces: the bake splits specs by colour family and each family's meshes get a
-- MaterialService MaterialVariant (uploaded CC0 Poly Haven photo maps). Base-material
-- projection is world-space on MeshParts, so no UVs in the bake. `gain` pre-boosts vertex
-- colours: they MULTIPLY the colour map, so the tint is scaled to land the final shade near
-- the old flat colour (clamped at white) while per-road custom colours keep working.
-- Two texturing paths: `variant` = world-projected MaterialVariant (fine for asphalt --
-- no directional pattern), `textureId` + `uvStudsPerTile` = UV-mapped TextureID where the
-- bake lays UVs ALONG each strip, so the sidewalk slab seams follow the road at any angle
-- (world projection drew the grout grid diagonally on non-axis-aligned roads).
type Look = { material: Enum.Material?, variant: string?, gain: number, textureId: string?, uvStudsPerTile: number? }
local ASPHALT_LOOK: Look = { material = Enum.Material.Asphalt, variant = "RoadAsphalt", gain = 3.5 }
local PAVEMENT_LOOK: Look = { gain = 2.0, textureId = "rbxassetid://83572541567624", uvStudsPerTile = 18 }
-- Pavement colour family: RoadConstants.SIDEWALK_COLOR (old + current) + ROUNDABOUT_ISLAND_CURB_COLOR,
-- and ROUNDABOUT_APRON_COLOR (the brick truck apron and splitter islands: brick-tinted pavers).
local PAVE_HEX = { d0cabd = true, b8b8b8 = true, aaaaaf = true, b26048 = true }

type CellState = {
	version: number,
	meshes: { MeshPart },
	details: { MeshPart },
	models: { [Model]: boolean },
	center: Vector3,
	-- Paint geometry was DESTROYED to hand its memory back; rebake it on approach.
	detailsDropped: boolean,
	-- World AABB of the baked base slabs -- the cell's REAL extent, which is not its grid
	-- square. Nil until the first bake lands; see nearestPointIn.
	boundsMin: Vector3?,
	boundsMax: Vector3?,
	-- Level currently applied; 0 means "nothing yet", so the next tick always acts.
	tier: number,
}

local _cells: { [string]: CellState } = {}
local _cellOf: { [Model]: string } = {}
local _conns: { [Model]: { RBXScriptConnection } } = {}
local _meshFolder: Model? = nil

-- Cell key comes from the blob's first vertex, NOT the pivot: live pieces are Models
-- with no BaseParts, so GetPivot() is (0,0,0) -- keying on it funneled every plain
-- segment into one mega-cell "0,0" whose bake blew the engine's per-mesh caps (triangle
-- count, then 2048-stud extents). Pivot is only the pre-replication fallback; the piece
-- migrates to its real cell when the blob arrives (DescendantAdded -> remap).
local function cellKeyFor(model: Model): string
	local p: Vector3? = nil
	local sv = model:FindFirstChild("RoadMeshSpecs", true)
	if sv and sv:IsA("StringValue") then
		p = RoadMeshBuilder.peekFirstPosition(sv.Value)
	end
	local pos = p or model:GetPivot().Position
	return math.floor(pos.X / CELL_SIZE) .. "," .. math.floor(pos.Z / CELL_SIZE)
end

-- The key IS the grid coordinate, so a cell knows where it is before any geometry exists.
-- Y stays 0: camera altitude is part of how far away a road is, and in this game it is
-- most of it -- zooming out is exactly when the flat slabs should take over.
local function centreOf(key: string): Vector3
	local gx, gz = string.match(key, "^(-?%d+),(-?%d+)$")
	if not (gx and gz) then return Vector3.zero end
	return Vector3.new((tonumber(gx) + 0.5) * CELL_SIZE, 0, (tonumber(gz) + 0.5) * CELL_SIZE)
end

local function cellState(key: string): CellState
	local st = _cells[key]
	if not st then
		st = { version = 0, meshes = {}, details = {}, models = {}, center = centreOf(key), tier = 0, detailsDropped = false }
		_cells[key] = st
	end
	return st
end

local BOX_CORNERS = {
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, -1), Vector3.new(1, 1, -1), Vector3.new(1, 1, 1), Vector3.new(-1, 1, 1),
}
local BOX_FACES = {
	{ n = Vector3.new(0, -1, 0), tris = { { 1, 2, 3 }, { 1, 3, 4 } } },
	{ n = Vector3.new(0, 1, 0), tris = { { 5, 6, 7 }, { 5, 7, 8 } } },
	{ n = Vector3.new(0, 0, -1), tris = { { 1, 2, 6 }, { 1, 6, 5 } } },
	{ n = Vector3.new(0, 0, 1), tris = { { 4, 3, 7 }, { 4, 7, 8 } } },
	{ n = Vector3.new(-1, 0, 0), tris = { { 1, 5, 8 }, { 1, 8, 4 } } },
	{ n = Vector3.new(1, 0, 0), tris = { { 2, 3, 7 }, { 2, 7, 6 } } },
}
local WEDGE_CORNERS = {
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, 1), Vector3.new(1, 1, 1),
}

-- Upper-bound triangle estimate per spec (dashed markings emit fewer), used to split
-- a cell into batches that stay under the engine's per-mesh cap.
local function triCount(s): number
	if s.strip then
		return math.max(#s.strip // 2 - 1, 0) * 2
	elseif s.mark then
		return math.max(#s.mark - 1, 0) * 2
	elseif s.fan then
		return #s.fan * 4
	elseif s.wedge then
		return 8
	else
		return 12
	end
end

local function bakeBatch(cellKey: string, specs: { any }, look: Look?): MeshPart
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = -minV
	for _, s in specs do
		if s.strip then
			for _, v in s.strip do minV = minV:Min(v); maxV = maxV:Max(v) end
		elseif s.mark then
			for _, v in s.mark do minV = minV:Min(v); maxV = maxV:Max(v) end
		elseif s.fan then
			for _, v in s.fan do minV = minV:Min(v); maxV = maxV:Max(v) end
			minV = minV:Min(s.center); maxV = maxV:Max(s.center)
		else
			local cf, half = s.cframe, s.size * 0.5
			for _, c in BOX_CORNERS do
				local w = cf:PointToWorldSpace(half * c)
				minV = minV:Min(w); maxV = maxV:Max(w)
			end
		end
	end
	-- Round the batch origin to the codec grid so the baked MeshPart's CFrame reads one
	-- decimal. Vertices are emitted relative to this same origin (p - center), so rounding
	-- it shifts nothing -- the geometry still lands exactly where it did.
	local center = Quant.vec((minV + maxV) * 0.5)

	local em = AssetService:CreateEditableMesh()
	assert(em, "EditableMesh memory budget exhausted")

	local colorIds = {}
	local gain = if look then look.gain else 1
	local uvTile = if look then look.uvStudsPerTile else nil
	local function colorId(c)
		if gain ~= 1 then
			c = Color3.new(math.min(c.R * gain, 1), math.min(c.G * gain, 1), math.min(c.B * gain, 1))
		end
		local key = c:ToHex()
		local id = colorIds[key]
		if not id then
			id = em:AddColor(c, 1)
			colorIds[key] = id
		end
		return id
	end

	local posOf = {}
	local function vtx(p)
		local id = em:AddVertex(p)
		posOf[id] = p
		return id
	end
	-- Consistent winding: DoubleSided lights a mis-wound face as a backface (flipped
	-- normal), which read as alternating dark slices on the junction fan. Every triangle
	-- is emitted through here and swapped to agree with its shading normal.
	local function emitTri(v1, v2, v3, n1, n2, n3, worldN, cid, uvs)
		local g = (posOf[v2] - posOf[v1]):Cross(posOf[v3] - posOf[v1])
		if g:Dot(worldN) < 0 then
			v2, v3 = v3, v2
			n2, n3 = n3, n2
			if uvs then uvs[2], uvs[3] = uvs[3], uvs[2] end
		end
		local fid = em:AddTriangle(v1, v2, v3)
		em:SetFaceColors(fid, { cid, cid, cid })
		em:SetFaceNormals(fid, { n1, n2, n3 })
		if uvs then em:SetFaceUVs(fid, uvs) end
	end

	local function addFace(vertIds, cf, localN, tris, cid)
		local worldN = cf:VectorToWorldSpace(localN)
		local nid = em:AddNormal(worldN)
		for _, t in tris do
			emitTri(vertIds[t[1]], vertIds[t[2]], vertIds[t[3]], nid, nid, nid, worldN, cid)
		end
	end

	-- |normal . UP| below this and the strip is a WALL, not a surface -- see the two-sided
	-- emission in addStrip. Slabs sit near 1 (even at MAX_ROAD_GRADE a road slab is ~0.98),
	-- kerb faces near 0, so there is nothing near the threshold to misclassify.
	local WALL_FACING_DOT = 0.35

	-- Welded surface ribbon: shared vertices + per-station smooth normals (curves read smooth
	-- instead of per-facet boxes that overlapped and z-fought).
	local function addStrip(s)
		local strip = s.strip
		local n = #strip // 2
		if n < 2 then return end
		-- Thin out stations that carry no shape. The sampler emits one every few studs and
		-- each costs two triangles, so a straight run is almost entirely redundant. RDP on
		-- BOTH rails, unioned: a one-sided taper bends only one of them, and a station either
		-- rail still needs has to survive. LOSSLESS_STUDS is under the pixel budget with the
		-- camera on the tarmac, so this changes nothing anyone can see at any distance.
		if n > 2 then
			local left = table.create(n)
			local right = table.create(n)
			for k = 1, n do
				left[k] = strip[k * 2 - 1]
				right[k] = strip[k * 2]
			end

			local keep: { [number]: boolean } = {}
			for _, k in LOD.simplifyIndices(left, LOD.LOSSLESS_STUDS) do keep[k] = true end
			for _, k in LOD.simplifyIndices(right, LOD.LOSSLESS_STUDS) do keep[k] = true end

			local thinned = {}
			for k = 1, n do
				if keep[k] then
					table.insert(thinned, left[k])
					table.insert(thinned, right[k])
				end
			end

			strip = thinned
			n = #strip // 2
		end
		local cid = colorId(s.color)
		local topL = table.create(n)
		local topR = table.create(n)
		local nrm = table.create(n)
		local ups = table.create(n)
		-- UV path: u spans the strip width, v runs with arc length, both in studs/uvTile,
		-- so the slab grid rides the strip's own direction instead of the world axes.
		local uvL: { number }? = nil
		local uvR: { number }? = nil
		local cumLen = 0
		if uvTile then
			uvL = table.create(n)
			uvR = table.create(n)
		end
		for k = 1, n do
			local l, r = strip[k * 2 - 1], strip[k * 2]
			if uvL and uvR then
				if k > 1 then
					cumLen += (l - strip[k * 2 - 3]).Magnitude
				end
				local v = cumLen / uvTile
				uvL[k] = em:AddUV(Vector2.new(0, v))
				uvR[k] = em:AddUV(Vector2.new((r - l).Magnitude / uvTile, v))
			end
			local tangent = strip[math.min(k + 1, n) * 2 - 1] - strip[math.max(k - 1, 1) * 2 - 1]
			local up = (r - l):Cross(tangent)
			up = if up.Magnitude > 1e-6 then up.Unit else UP
			if up:Dot(UP) < 0 then up = -up end
			ups[k] = up
			topL[k] = vtx(l - center)
			topR[k] = vtx(r - center)
			nrm[k] = em:AddNormal(up)
		end
		-- A near-VERTICAL strip is a wall (the kerb faces), and a wall has no back: emit it both
		-- ways. It cannot be left one-sided, because this mesh is DoubleSided = false and the
		-- facing is decided by `up`. For a wall, up:Dot(UP) is 0 (measured: exactly 0.000 on the
		-- kerb faces, against 0.98-1.00 on every slab), so the skyward flip above is a no-op and
		-- `up` keeps whatever (r-l):Cross(tangent) gave. Both rails of a road are built in the
		-- same t order, so that is the SAME world direction for the left and right kerb -- which
		-- means one of them faces out of the kerb and the other faces into it, and the second is
		-- invisible from the road. That is the see-through kerb, and it is one whole side of
		-- every road, not a flicker. It hid while the kerb was 0.15 studs tall.
		-- The reversed copy is the same triangles wound the other way, so backface culling shows
		-- exactly one of the pair from any camera -- no z-fighting and no extra drawn pixels,
		-- only the triangles. Walls are a small share of a piece's mesh, but this does count
		-- against the engine's ~21.8k bake limit.
		local backNrm: { number }? = nil
		do
			local facing = 0
			for k = 1, n do facing += math.abs(ups[k]:Dot(UP)) end
			if facing / n < WALL_FACING_DOT then
				local back = table.create(n)
				for k = 1, n do back[k] = em:AddNormal(-ups[k]) end
				backNrm = back
			end
		end
		for k = 1, n - 1 do
			local wn = ups[k] + ups[k + 1]
			local uvs1 = if uvL and uvR then { uvL[k], uvR[k], uvR[k + 1] } else nil
			local uvs2 = if uvL and uvR then { uvL[k], uvR[k + 1], uvL[k + 1] } else nil
			emitTri(topL[k], topR[k], topR[k + 1], nrm[k], nrm[k], nrm[k + 1], wn, cid, uvs1)
			emitTri(topL[k], topR[k + 1], topL[k + 1], nrm[k], nrm[k + 1], nrm[k + 1], wn, cid, uvs2)
			if backNrm then
				emitTri(topL[k], topR[k], topR[k + 1], backNrm[k], backNrm[k], backNrm[k + 1], -wn, cid, uvs1)
				emitTri(topL[k], topR[k + 1], topL[k + 1], backNrm[k], backNrm[k + 1], backNrm[k + 1], -wn, cid, uvs2)
			end
		end
	end

	-- A painted line baked as a thin ribbon along its centreline. Solid -> continuous;
	-- dashed -> a quad only where the arc length falls inside a dash, bare gaps show asphalt.
	local nUp = em:AddNormal(UP)
	local function addMarking(s)
		local pts = s.mark
		local n = #pts
		if n < 2 then return end
		local hw = (s.width or 0.3) * 0.5
		local cid = colorId(s.color)
		local dashed = s.dashed == true
		-- Solid lines thin like the strips do. Dashed ones must NOT: the dash phase is
		-- decided per segment from arc length, so collapsing a straight run into one long
		-- segment would emit a single dash across the whole span.
		if not dashed and n > 2 then
			pts = LOD.simplify(pts, LOD.LOSSLESS_STUDS)
			n = #pts
		end
		local side = table.create(n)
		local cum = table.create(n)
		cum[1] = 0
		for k = 1, n do
			local tangent = pts[math.min(k + 1, n)] - pts[math.max(k - 1, 1)]
			local sd = tangent:Cross(UP)
			side[k] = if sd.Magnitude > 1e-6 then sd.Unit else Vector3.xAxis
			if k > 1 then
				cum[k] = cum[k - 1] + (pts[k] - pts[k - 1]).Magnitude
			end
		end
		for k = 1, n - 1 do
			if dashed and ((cum[k] + cum[k + 1]) * 0.5) % DASH_PITCH >= DASH_LENGTH then
				continue
			end
			local lA = vtx(pts[k] - side[k] * hw - center)
			local rA = vtx(pts[k] + side[k] * hw - center)
			local rB = vtx(pts[k + 1] + side[k + 1] * hw - center)
			local lB = vtx(pts[k + 1] - side[k + 1] * hw - center)
			emitTri(lA, rA, rB, nUp, nUp, nUp, UP, cid)
			emitTri(lA, rB, lB, nUp, nUp, nUp, UP, cid)
		end
	end

	-- Solid polygon slab: centre->rim top fan + bottom fan + rim skirt, straight into the mesh.
	-- Replaces the junction surface's 2-wedge prisms (16 tris/slice) with 4 tris/slice.
	local function addFan(s)
		local rim = s.fan
		local n = #rim
		if n < 3 then return end
		local c = s.center
		local cid = colorId(s.color)
		local drop = UP * (s.thickness or 0.5)
		local cTop = vtx(c - center)
		local cBot = vtx(c - drop - center)
		local topIds = table.create(n)
		local botIds = table.create(n)
		for k = 1, n do
			topIds[k] = vtx(rim[k] - center)
			botIds[k] = vtx(rim[k] - drop - center)
		end
		local downId = em:AddNormal(-UP)
		for k = 1, n do
			local k2 = (k % n) + 1
			-- top (upward): per-slice flat normal so a tilted junction still shades flat
			local fn = (rim[k] - c):Cross(rim[k2] - c)
			if fn:Dot(UP) < 0 then fn = -fn end
			local wn = if fn.Magnitude > 1e-6 then fn.Unit else UP
			local tnid = em:AddNormal(wn)
			emitTri(cTop, topIds[k], topIds[k2], tnid, tnid, tnid, wn, cid)
			-- bottom (downward)
			emitTri(cBot, botIds[k], botIds[k2], downId, downId, downId, -UP, cid)
			-- skirt (outward from centre)
			local mid = (rim[k] + rim[k2]) * 0.5
			local ow = Vector3.new(mid.X - c.X, 0, mid.Z - c.Z)
			local own = if ow.Magnitude > 1e-6 then ow.Unit else Vector3.xAxis
			local onid = em:AddNormal(own)
			emitTri(topIds[k], botIds[k], botIds[k2], onid, onid, onid, own, cid)
			emitTri(topIds[k], botIds[k2], topIds[k2], onid, onid, onid, own, cid)
		end
	end

	local okBake, meshOrErr = pcall(function()
		for si, s in specs do
			if si % 400 == 0 then
				task.wait() -- spread a big batch build across frames instead of one long hitch
			end
			if s.mark then
				addMarking(s)
			elseif s.fan then
				addFan(s)
			elseif s.strip then
				addStrip(s)
			elseif s.wedge then
				local cf, half = s.cframe, s.size * 0.5
				local cid = colorId(s.color)
				local ids = table.create(6)
				for i, c in WEDGE_CORNERS do
					ids[i] = vtx(cf:PointToWorldSpace(half * c) - center)
				end
				addFace(ids, cf, Vector3.new(0, -1, 0), { { 1, 2, 3 }, { 1, 3, 4 } }, cid)
				addFace(ids, cf, Vector3.new(0, 0, 1), { { 4, 3, 6 }, { 4, 6, 5 } }, cid)
				addFace(ids, cf, Vector3.new(0, s.size.Z, -s.size.Y).Unit, { { 1, 2, 6 }, { 1, 6, 5 } }, cid)
				addFace(ids, cf, Vector3.new(-1, 0, 0), { { 1, 4, 5 } }, cid)
				addFace(ids, cf, Vector3.new(1, 0, 0), { { 2, 3, 6 } }, cid)
			else
				local cf, half = s.cframe, s.size * 0.5
				local cid = colorId(s.color)
				local ids = table.create(8)
				for i, c in BOX_CORNERS do
					ids[i] = vtx(cf:PointToWorldSpace(half * c) - center)
				end
				for _, face in BOX_FACES do
					addFace(ids, cf, face.n, face.tris, cid)
				end
			end
		end
		-- Bake to STATIC content: the MeshPart owns a static copy of the geometry, so the
		-- EditableMesh can die right away instead of being kept alive per mesh (the old
		-- keep-alive pattern is what exhausted the client's Editable* memory budget).
		local result, content = AssetService:CreateDataModelContentAsync(Content.fromObject(em))
		if result ~= Enum.CreateContentResult.Success then
			error(`CreateDataModelContentAsync failed: {tostring(result)}`)
		end
		return AssetService:CreateMeshPartAsync(content, {
			-- ponytail: mesh never collides or gets queried -- Box skips the precise collision
			-- decomposition CreateMeshPartAsync would otherwise compute per road piece.
			CollisionFidelity = Enum.CollisionFidelity.Box,
		})
	end)
	em:Destroy()
	if not okBake then
		error(meshOrErr)
	end
	local mesh = meshOrErr
	mesh.Name = "RoadCell_" .. cellKey
	mesh.Anchored = true
	mesh.CanCollide = false -- ponytail: nothing walks/drives the city by physics; keep roads out of the collision broadphase
	mesh.CanQuery = false
	mesh.CanTouch = false
	mesh.CastShadow = false
	-- Single-sided: emitTri winds every face to agree with its shading normal, so backface
	-- culling is safe and halves the pixel cost (roads are never seen from below).
	mesh.DoubleSided = false
	mesh.Color = Color3.new(1, 1, 1)
	mesh.Material = Enum.Material.SmoothPlastic
	if look then
		if look.textureId then
			mesh.TextureID = look.textureId
		elseif look.material and look.variant then
			mesh.Material = look.material
			mesh.MaterialVariant = look.variant
		end
	end
	mesh.CFrame = CFrame.new(center)
	return mesh
end

-- detailsOnly bakes the paint and nothing else: that is the LOD re-entry path, and the base
-- slabs it would otherwise redo are the expensive half.
local function bake(cellKey: string, models: { Model }, detailsOnly: boolean?): ({ MeshPart }, { MeshPart })
	local baseSpecs = {}
	local paveSpecs = {}
	local plainSpecs = {}
	local markSpecs = {}
	-- Colour family -> texture family: sidewalks/kerbs read as paver blocks, coloured trim
	-- (grass islands etc.) stays flat, everything grey is asphalt.
	local function listFor(s): { any }
		if s.mark then return markSpecs end
		local c = s.color
		if PAVE_HEX[c:ToHex():lower()] then return paveSpecs end
		if math.max(c.R, c.G, c.B) - math.min(c.R, c.G, c.B) > 0.07 then return plainSpecs end
		return baseSpecs
	end
	for _, model in models do
		for _, d in model:GetDescendants() do
			if d:IsA("StringValue") and d.Name == "RoadMeshSpecs" then
				for _, s in RoadMeshBuilder.decodeSpecs(d.Value) do
					table.insert(listFor(s), s)
				end
			end
		end
	end
	local function bakeList(specs, out: { MeshPart }, look: Look?)
		local batch = {}
		local batchTris = 0
		local function flush()
			if #batch == 0 then return end
			table.insert(out, bakeBatch(cellKey, batch, look))
			batch = {}
			batchTris = 0
		end
		for _, s in specs do
			local t = triCount(s)
			if batchTris + t > MAX_TRIS_PER_MESH and #batch > 0 then
				flush()
			end
			table.insert(batch, s)
			batchTris += t
		end
		flush()
	end
	local meshes: { MeshPart } = {}
	local details: { MeshPart } = {}
	local ok, err = pcall(function()
		if not detailsOnly then
			bakeList(baseSpecs, meshes, ASPHALT_LOOK)
			bakeList(paveSpecs, meshes, PAVEMENT_LOOK)
			bakeList(plainSpecs, meshes, nil)
		end
		bakeList(markSpecs, details, nil)
	end)
	if not ok then
		-- Don't leak the batches that DID bake before the failure.
		for _, m in meshes do m:Destroy() end
		for _, m in details do m:Destroy() end
		error(err)
	end
	for _, m in details do
		m.Name = "RoadDetail_" .. cellKey
	end
	return meshes, details
end

-- The cell's real world extent, from the base slabs just baked. Bakes are rare, so this is
-- done once here rather than every LOD tick.
local function refreshBounds(st: CellState)
	local lo: Vector3? = nil
	local hi: Vector3? = nil
	for _, m in st.meshes do
		local half = m.Size * 0.5
		local a, b = m.Position - half, m.Position + half
		lo = if lo then lo:Min(a) else a
		hi = if hi then hi:Max(b) else b
	end
	st.boundsMin = lo
	st.boundsMax = hi
end

local function rebuild(key: string)
	local st = _cells[key]
	if not st then return end
	local models: { Model } = {}
	for m in st.models do
		if m.Parent then table.insert(models, m) end
	end
	local ok, meshesOrErr, newDetails = pcall(bake, key, models)
	if not ok then
		warn(`[RoadMeshView] bake failed for cell {key}: {meshesOrErr}`)
		-- Same retry hook as the detail path: if the paint was dropped, a failed rebuild
		-- leaves it dropped and nothing asks again until the tier moves.
		st.tier = 0
		return
	end
	local oldMeshes, oldDetails = st.meshes, st.details
	st.meshes = meshesOrErr
	refreshBounds(st)
	st.details = newDetails
	-- Fresh meshes come back wearing their baked (NEAR) look; make the next tick re-apply.
	st.tier = 0
	st.detailsDropped = false
	for _, m in st.meshes do
		m.Parent = _meshFolder
	end
	for _, m in st.details do
		m.Parent = _meshFolder
	end
	for _, m in oldMeshes do m:Destroy() end
	for _, m in oldDetails do m:Destroy() end
	if next(st.models) == nil then
		-- The last piece left this cell WHILE the bake was running, so what we just baked is
		-- geometry that no longer exists. Dropping the cell state without destroying it left a
		-- deleted road on screen forever -- the rebuild queued by its removal finds no cell
		-- state and no-ops. Bake yields (task.wait, CreateDataModelContentAsync), so this race
		-- is ordinary, not exotic.
		for _, m in st.meshes do m:Destroy() end
		for _, m in st.details do m:Destroy() end
		_cells[key] = nil
	end
end

-- Re-bake ONLY the paint a far cell gave back. Runs through the same one-at-a-time queue,
-- so the "at most one EditableMesh alive" guarantee still holds.
local function rebuildDetails(key: string)
	local st = _cells[key]
	if not st or not st.detailsDropped then return end

	local models: { Model } = {}
	for m in st.models do
		if m.Parent then table.insert(models, m) end
	end

	local ok, _meshes, newDetails = pcall(bake, key, models, true)
	if not ok then
		warn(`[RoadMeshView] detail rebake failed for cell {key}: {_meshes}`)
		-- The paint is still dropped and applyLevel only re-enqueues on a tier CHANGE, so
		-- without this the cell stays unpainted until you fly out past CULL and back --
		-- one transient bake failure = markings gone for the session.
		-- ponytail: retries at LOD_PERIOD; add a backoff if a cell ever fails forever.
		st.tier = 0
		return
	end

	-- The bake yields, so the cell can have been rebuilt, dropped, or flown away from in
	-- the meantime. Anything but the exact state we started on means throw this away.
	if _cells[key] ~= st or not st.detailsDropped then
		for _, m in newDetails do m:Destroy() end
		return
	end

	st.details = newDetails
	st.detailsDropped = false
	for _, m in st.details do
		m.Parent = _meshFolder
	end
	-- Paint bakes visible, but the bake yields and the camera may have moved out to FAR
	-- meanwhile. Tier is unchanged, so applyLevel would early-return and never dress it.
	-- Reset to "nothing applied" and let the next tick be the single reconciler.
	st.tier = 0
end

type BakeJob = { key: string, detailsOnly: boolean }

local _bakeQueue: { BakeJob } = {}
local _queuedSet: { [string]: boolean } = {}
local _pumping = false
-- For RoadPlacementPrediction: rebuilds waiting out REBUILD_QUIET, and when a bake last
-- finished -- together they say when a road that just replicated is on screen.
local _scheduled = 0
local _lastBakeAt = -math.huge

local function enqueue(key: string, detailsOnly: boolean?)
	local only = detailsOnly == true
	local tag = if only then "d:" .. key else key
	if _queuedSet[tag] then return end
	_queuedSet[tag] = true
	local job = { key = key, detailsOnly = only }
	if only then
		table.insert(_bakeQueue, job)
	else
		-- A road that was just built or changed (by anyone on the server) goes ahead of the
		-- paint-only rebakes that flying the camera around queues up, so another player's
		-- new road appears as soon as it replicates instead of after that backlog.
		local at = #_bakeQueue + 1
		for i, queued in _bakeQueue do
			if queued.detailsOnly then at = i break end
		end
		table.insert(_bakeQueue, at, job)
	end
	if _pumping then return end
	_pumping = true
	task.spawn(function()
		while #_bakeQueue > 0 do
			local job = table.remove(_bakeQueue, 1)
			_queuedSet[if job.detailsOnly then "d:" .. job.key else job.key] = nil
			-- Error boundary. An error escaping a job used to kill this thread with
			-- _pumping still true, so every later enqueue appended to a queue nobody
			-- pumped: road paint (and every rebuild) silently stopped for the session.
			local ok, err = pcall(function()
				if job.detailsOnly then
					rebuildDetails(job.key)
				else
					rebuild(job.key)
				end
			end)
			if not job.detailsOnly then _lastBakeAt = os.clock() end
			if not ok then
				warn(`[RoadMeshView] bake job failed for cell {job.key}: {err}`)
			end
		end
		_pumping = false
	end)
end

local function schedule(key: string)
	local st = _cells[key]
	if not st then return end
	st.version += 1
	local v = st.version
	_scheduled += 1
	task.delay(REBUILD_QUIET, function()
		_scheduled -= 1
		local cur = _cells[key]
		if cur and cur.version == v then
			enqueue(key)
		end
	end)
end

-- (Re)assign a road piece to its cell by pivot -- pieces can arrive before their
-- geometry replicates, so the cell is re-derived on every content change and the
-- piece migrates (rebaking both cells) if it landed somewhere new.
local function remap(child: Model)
	local key = cellKeyFor(child)
	local old = _cellOf[child]
	if old == key then
		schedule(key)
		return
	end
	if old then
		local ost = _cells[old]
		if ost then ost.models[child] = nil end
		schedule(old)
	end
	_cellOf[child] = key
	cellState(key).models[child] = true
	schedule(key)
end

local function track(child)
	if not child:IsA("Model") or _conns[child] then return end
	local conns = {}
	_conns[child] = conns
	-- The bake reads nothing but RoadMeshSpecs blobs -- anything else the sim parents
	-- under a piece at runtime (decal plates, sounds) must not trigger a cell rebake.
	table.insert(conns, child.DescendantAdded:Connect(function(d)
		if d.Name == "RoadMeshSpecs" then remap(child) end
	end))
	table.insert(conns, child.DescendantRemoving:Connect(function(d)
		if d.Name == "RoadMeshSpecs" then remap(child) end
	end))
	remap(child)
end

local function untrack(child)
	local conns = _conns[child]
	if conns then
		for _, c in conns do c:Disconnect() end
		_conns[child] = nil
	end
	local key = _cellOf[child]
	if key then
		_cellOf[child] = nil
		local st = _cells[key]
		if st then
			st.models[child] = nil
			schedule(key)
		end
	end
end

-- A cell is 256 studs across, so its half-diagonal is 181 -- judging it by its centre puts
-- the road directly under the camera a whole level too coarse. Tier on the cell's NEAREST
-- point instead: clamp the eye into the cell footprint.
local CELL_HALF = CELL_SIZE * 0.5

-- ...and the square is not where the cell's geometry actually IS. A piece is filed under the
-- cell of its blob's FIRST vertex (see cellKeyFor), so a long segment's far end -- which is
-- exactly where its crosswalk sits -- can lie hundreds of studs outside that square. Judged by
-- the square, such a cell flipped to FAR while the cell you were looking at was still MID, so
-- a crossing vanished with the dashes beside it still painted. Clamp into the cell's real
-- baked extent instead. Base slabs are never destroyed by the ladder, so their union is a
-- stable stand-in that does not move when the paint is dropped.
local function nearestPointIn(st: CellState, eye: Vector3): Vector3
	local lo, hi = st.boundsMin, st.boundsMax
	if not (lo and hi) then
		local c = st.center
		lo = Vector3.new(c.X - CELL_HALF, 0, c.Z - CELL_HALF)
		hi = Vector3.new(c.X + CELL_HALF, 0, c.Z + CELL_HALF)
	end
	-- Y stays 0 for the reason centreOf gives: altitude is most of how far away a road is.
	return Vector3.new(
		math.clamp(eye.X, lo.X, hi.X),
		0,
		math.clamp(eye.Z, lo.Z, hi.Z)
	)
end

-- One level per cell, not per mesh: half a cell changing look would read as a seam.
local function applyLevel(key: string, st: CellState, tier: number)
	if st.tier == tier then return end
	st.tier = tier

	local paint = if tier >= LOD.FAR then 1 else 0
	for _, m in st.details do
		if m.Transparency ~= paint then
			m.Transparency = paint
		end
	end

	-- Paint is HIDDEN at FAR and DESTROYED at CULL. Two boundaries on purpose: hiding is free
	-- and reversible, dropping the geometry is what actually returns the memory but costs a
	-- bake to undo. CULL is where even a 1-stud feature falls under the pixel budget -- far
	-- outside where you work, so panning never thrashes bake/destroy at a band edge.
	if tier >= LOD.CULL then
		if not st.detailsDropped then
			for _, m in st.details do m:Destroy() end
			st.details = {}
			st.detailsDropped = true
		end
	elseif tier <= LOD.MID and st.detailsDropped then
		-- Only re-bake when the paint would actually be seen: coming back to FAR still
		-- hides it, so paying for a bake there would buy nothing.
		enqueue(key, true)
	end
end

function RoadMeshView.Start()
	local city = workspace:WaitForChild("_City", FOLDER_WAIT)
	local roads = city and city:WaitForChild("Roads", FOLDER_WAIT)
	if not roads then
		warn("[RoadMeshView] workspace._City.Roads never appeared -- roads stay part-rendered")
		return
	end
	-- A Model (not a bare Folder) so the baked road pieces group like every other
	-- placeable. Pivot pinned to the origin -- a clean 1-decimal reference frame that
	-- doesn't drift (an unset Model pivot is the live bounding-box centre, 3 decimals).
	local container = Instance.new("Model")
	container.Name = "_RoadMeshes"
	container.Parent = workspace
	container.WorldPivot = CFrame.new(0, 0, 0)
	_meshFolder = container
	roads.ChildAdded:Connect(track)
	roads.ChildRemoved:Connect(untrack)
	for _, child in roads:GetChildren() do
		track(child)
	end
	task.spawn(function()
		while true do
			task.wait(LOD_PERIOD)
			local cam = workspace.CurrentCamera
			if cam then
				local eye = cam.CFrame.Position
				-- Draw distance setting stretches the ladder for roads too.
				local scale = (tonumber(Settings.get("renderDistance")) or 1) * PAINT_RANGE_SCALE
				for key, st in _cells do
					applyLevel(key, st, LOD.tierAt(nearestPointIn(st, eye), eye, nil, scale))
				end
			end
		end
	end)
end

-- True when no road rebuild is waiting or baking on this client.
function RoadMeshView.isIdle(): boolean
	return _scheduled == 0 and not _pumping and #_bakeQueue == 0
end

-- os.clock() of the last finished road (not paint-only) bake.
function RoadMeshView.lastBakeAt(): number
	return _lastBakeAt
end

return RoadMeshView
