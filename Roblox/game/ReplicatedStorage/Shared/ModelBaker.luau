--!strict
-- ModelBaker -- turns any Model into the two cheap stand-ins a distance ladder needs:
-- a single vertex-coloured MeshPart, and a flat 2D impostor image. Pure library: it reads
-- a Model and returns instances, it owns no state and no lifecycle. LODProxyCache decides
-- WHEN to bake and what to keep; AssetLODView decides WHICH one to show.
--
-- WHY A MESH AND NOT FEWER PARTS ------------------------------------------------------
-- Measured in this place with Stats.RenderBreakdown: a placed building costs the engine
-- ~40 separate draw calls (one per part, plus its decals) but only ~500 triangles. Roblox's
-- own budget guidance is ~1,000 draw calls against ~1,000,000 triangles per frame, so a
-- 500-building city is roughly 20x over the draw-call budget while sitting at a quarter of
-- the triangle budget. Draw calls are the whole problem; triangles are nearly free.
--
-- So the proxy does NOT try hard to remove geometry. It re-emits the same boxes into ONE
-- mesh. Triangle count barely moves; draw calls collapse by ~40x. Simplification here is
-- limited to what is provably invisible (see MIN_FEATURE_STUDS) rather than an aggressive
-- decimation that would cost silhouette for a resource we are not short of.
--
-- WHY VERTEX COLOURS AND NOT MeshPart.Color -------------------------------------------
-- The engine batches identical meshes into a single draw call only when the mesh content
-- matches. Tinting a shared mesh per instance with MeshPart.Color would be tidier, but
-- whether a differing Color still batches is undocumented, and the entire point of this
-- module is draw calls -- so it is not something to gamble on. Colours are baked into the
-- vertices instead and the cache is keyed by colour (see `signature`): every building that
-- looks the same shares one mesh and therefore one draw call, and two that differ get two
-- meshes. That is a guarantee rather than a hope.
--
-- COLOUR COMES FROM THE TEXTURES, NOT THE PART ----------------------------------------
-- Walls are cream parts wearing a tiling image. Baking Part.Color alone turns every house
-- in the city cream. Effective colour is resolved through Shared.TextureAverages, which
-- folds each decal back into a single colour by its alpha coverage.
--
-- EDITABLE MEMORY ----------------------------------------------------------------------
-- EditableMesh/EditableImage live on a small per-device budget (creation returns nil when
-- it is gone, it does not throw). Everything here is baked to STATIC content via
-- CreateDataModelContentAsync and the editable source destroyed immediately, which is the
-- one path that does not hold budget -- the same pattern RoadMeshView uses. At most one
-- editable object of each kind is alive at a time, whatever the city size.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TextureAverages = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TextureAverages")
)

local ModelBaker = {}

-- A part whose longest side is under this cannot reach a pixel at the distance the proxy
-- is first shown (FAR begins around 1.7 px/stud on the Shared.LOD ladder), so dropping it
-- is free rather than a quality trade. Deliberately conservative -- see the header on why
-- there is no reason to be greedy about triangles.
local MIN_FEATURE_STUDS = 0.6

-- Colour quantisation for the cache key. LotDressingService jitters every placed building's
-- wall/roof colour by a continuous +/-0.06, so without rounding no two buildings would ever
-- share a mesh and nothing would batch.
--
-- 7 levels/channel puts bucket edges ~0.167 apart, comfortably wider than the +/-0.06 jitter,
-- so a palette entry and its jittered copies almost always land together. 12 levels was too
-- fine -- the jitter straddled bucket edges and one template still produced several kinds,
-- which is how the entry cap got exhausted. Coarser buckets can merge two genuinely
-- different palette entries, and at the distance a proxy is first drawn that is invisible.
-- Coarse on purpose. Every distinct colour combination is its own cache kind, and every kind
-- costs ~45 ms of UNSLICEABLE engine work to bake (CreateDataModelContentAsync ~16 ms plus
-- CreateMeshPartAsync ~7 ms, twice, for the full and coarse rungs). Measured at 7 levels,
-- 240 placed buildings still produced 180 distinct kinds -- almost no reuse, so nearly every
-- building paid for its own bake and its own dropped frame.
--
-- 4 levels puts buckets 0.33 apart, far wider than LotDressingService's +/-0.06 jitter, so
-- jittered copies of a template collapse into one kind. The cost is that two genuinely
-- different but similar palette colours may share a proxy -- invisible at 500+ studs, which
-- is the nearest a proxy is ever drawn.
local COLOUR_LEVELS = 4

-- Sides on a baked cylinder. Roblox draws a smooth one; at proxy distance an octagon is
-- indistinguishable and costs a third of the triangles.
local CYLINDER_SIDES = 8

-- Meridians / parallels on a baked sphere: 64 triangles, faceted but round in silhouette,
-- which is all a dome or a water tower needs at this range.
local BALL_MERIDIANS = 8
local BALL_RINGS = 4

-- ---------------------------------------------------------------------------------------
-- Baking leaves
-- ---------------------------------------------------------------------------------------
--
-- A canopy is not solid geometry. It is a couple of hundred big quads wearing a greyscale
-- mask that is mostly holes -- the leaf shapes are punched out by alpha, not modelled. Emit
-- those quads opaque, the way a wall is emitted, and the result is a pile of flat plates
-- roughly three times the area of the tree it stands for: too big, too bright, too smooth,
-- and unmistakably not foliage. Every constant here exists to undo one part of that.
--
-- All three were tuned by baking an oak, standing it next to the real one at 520 studs (the
-- distance the first mesh rung is actually seen from) and matching by eye.

-- How far a leaf card's shading normal leans from its own face toward "outward from the
-- middle of the canopy". Cards are modelled facing every which way, so flat-shading them
-- lights a scattering of them like mirrors while their neighbours stay black -- the spiky,
-- glittery look that gives a baked tree away. Leaning the normals outward makes the canopy
-- shade as one round mass; leaning them ALL the way there makes it shade like a boulder, so
-- this keeps a third of each card's own tilt.
local FOLIAGE_OUTWARD = 0.7

-- Leaves and bark are darkened because the bake throws away the thing that darkens them in
-- the real tree: a canopy is layers deep and shadows itself, and the trunk stands under all
-- of it. A baked tree is a single opaque shell with no interior and no shadow, so without
-- this it reads markedly lighter than the tree it replaces at the moment it swaps in.
local FOLIAGE_SHADE = 0.88
local FOLIAGE_BARK_SHADE = 0.85

-- Per-card colour variation. A real canopy is never one flat green; without a little spread
-- the proxy reads as a solid object painted green rather than as leaves.
--
-- Quantised into a handful of steps rather than a fresh colour per card. Eight is already
-- past the point the eye separates them at this range, and it keeps the whole canopy to eight
-- entries in the mesh's colour table instead of one per triangle.
local FOLIAGE_JITTER = 0.15
local FOLIAGE_JITTER_STEPS = 8

-- Stable 0..1 from a point, so a given canopy always jitters the same way and the same kind
-- baked twice is the same picture.
local function hash01(p: Vector3): number
	local n = math.sin(p.X * 12.9898 + p.Y * 78.233 + p.Z * 37.719) * 43758.5453
	return n - math.floor(n)
end

-- Parts that exist for logic, not for looks. FootprintAnchor is the invisible lot marker;
-- SnowLayer is injected into buildings by SeasonTintClient after replication and is not
-- part of the model's identity.
local SKIP_NAMES: { [string]: boolean } = table.freeze({
	FootprintAnchor = true,
	SnowLayer = true,
})

-- Groups whose contents are PER-INSTANCE lot dressing: the fence, path, driveway and yard
-- clutter LotDressingService gives each placed building. Same folder names BuildingService
-- itself uses to recognise dressing (isLotDressingPart).
--
-- These are BAKED but not HASHED, and that split is the point. The yard IS part of the
-- building -- a house whose drive, path and back garden vanish the moment it swaps to a proxy
-- is a house standing on bare ground -- so the geometry belongs in the mesh. The signature is
-- a separate question: every building gets its OWN dressing, so hashing it makes two
-- otherwise identical houses different KINDS, and a kind costs ~45 ms of unsliceable engine
-- work to bake plus its own mesh in memory.
--
-- ponytail: one shared mesh therefore carries ONE instance's yard for the whole kind -- the
-- first house of that type to ask for a bake. Fence layout and drive side vary per house, so
-- a neighbour's proxy shows the wrong one; at the range a proxy is drawn that is a couple of
-- pixels wide. Hash the dressing too if it ever reads wrong, and pay for a kind per house.
local SKIP_GROUPS: { [string]: boolean } = table.freeze({
	Yard = true,
	Lot = true,
	ParkMarkers = true,
})

-- True when `part` sits under one of the dressing groups, anywhere below `root`.
local function isDressing(part: BasePart, root: Model): boolean
	local cur = part.Parent
	while cur and cur ~= root do
		if SKIP_GROUPS[cur.Name] then
			return true
		end
		cur = cur.Parent
	end
	return false
end

-- A mesh past this is not worth reading for a proxy: the impostor only needs a silhouette,
-- and the cost of walking it is paid on a background thread the player is waiting on.
local MESH_TRI_CAP = 1500

-- How long a bake may run before handing the frame back.
--
-- Bakes run on a background worker with nothing waiting on them -- the real model keeps
-- drawing until its proxy is ready -- so spreading one over several frames costs a little
-- wall time and nothing else. Measured before this existed: reading a tree's uploaded mesh
-- blocked for 25.6 ms and rasterising its impostor for 32.2 ms, both well past a 16.7 ms
-- frame, which is exactly the stutter felt when a distant tree first swaps.
local SLICE_SECS = 0.004

local function slice(deadline: number): number
	if os.clock() >= deadline then
		task.wait()
		return os.clock() + SLICE_SECS
	end
	return deadline
end

export type Spec = {
	cf: CFrame, -- model-LOCAL, so one bake serves every rotation of the template
	size: Vector3,
	kind: string, -- "box" | "wedge" | "corner" | "cylinder" | "ball" | "mesh"
	color: Color3,
	meshId: string?, -- "mesh" kind only; resolved to real geometry by `preload`
	-- Cutout foliage: the fraction of each card the alpha mask actually paints, or nil for
	-- ordinary solid geometry. See TextureAverages.cutout.
	cutout: number?,
}

export type Bake = {
	specs: { Spec },
	center: Vector3, -- model-local centroid of the visible bounds
	extents: Vector3,
	signature: string,
	sourceParts: number,
	keptParts: number,
	-- True when real meshes carry most of this model's volume -- a tree, a rock. Callers
	-- must NOT bake a mesh proxy for these; see `bakeMesh`.
	meshBacked: boolean,
	-- True when any part of this model is cutout foliage -- a tree, a bush. These DO get a
	-- mesh proxy, baked through the leaf path rather than refused; see `bakeMesh`.
	foliage: boolean,
	-- Keep one leaf card in N. 1 is every card; `coarsen` raises it for the rung past the
	-- full mesh, and the cards that survive are grown to hold the painted area steady.
	foliageStride: number?,
}

-- ---------------------------------------------------------------------------------------
-- Solid geometry. Every shape resolves to a vertex list plus faces carrying an OUTWARD
-- local normal, so one emitter handles all of them.
-- ---------------------------------------------------------------------------------------

local BOX_CORNERS = table.freeze({
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, -1), Vector3.new(1, 1, -1), Vector3.new(1, 1, 1), Vector3.new(-1, 1, 1),
})
local BOX_FACES = table.freeze({
	{ n = Vector3.new(0, -1, 0), tris = { { 1, 2, 3 }, { 1, 3, 4 } } },
	{ n = Vector3.new(0, 1, 0), tris = { { 5, 6, 7 }, { 5, 7, 8 } } },
	{ n = Vector3.new(0, 0, -1), tris = { { 1, 2, 6 }, { 1, 6, 5 } } },
	{ n = Vector3.new(0, 0, 1), tris = { { 4, 3, 7 }, { 4, 7, 8 } } },
	{ n = Vector3.new(-1, 0, 0), tris = { { 1, 4, 8 }, { 1, 8, 5 } } },
	{ n = Vector3.new(1, 0, 0), tris = { { 2, 3, 7 }, { 2, 7, 6 } } },
})

-- Roblox WedgePart: full base, a vertical face on +Z, and the slope running up from the
-- bottom -Z edge to the top +Z edge.
local WEDGE_CORNERS = table.freeze({
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, 1), Vector3.new(1, 1, 1),
})

-- CornerWedgePart approximated as the pyramid it reads as at distance: full base, apex over
-- one corner. Only ~1% of the library (hip-roof corners) and never seen close up as a proxy.
local CORNER_CORNERS = table.freeze({
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(1, 1, -1),
})
local CORNER_FACES = table.freeze({
	{ n = Vector3.new(0, -1, 0), tris = { { 1, 2, 3 }, { 1, 3, 4 } } },
	{ n = Vector3.new(0, 0, -1), tris = { { 1, 2, 5 } } },
	{ n = Vector3.new(1, 0, 0), tris = { { 2, 3, 5 } } },
	{ n = Vector3.new(-1, 1, -1).Unit, tris = { { 1, 5, 4 } } },
	{ n = Vector3.new(0, 1, 1).Unit, tris = { { 4, 5, 3 } } },
})

-- Real geometry for uploaded meshes, normalised into a unit box so it can be scaled by any
-- MeshPart.Size. `false` marks an id that could not be read, so it is not retried forever.
local _meshCache: { [string]: any } = {}

-- Reads one uploaded mesh. YIELDS (~1.3 s the first time for a tree), so this is only ever
-- called from `preload`, never from `collect` -- collect has to stay cheap enough to run on
-- the LOD sweep.
local function loadMesh(meshId: string): any
	local hit = _meshCache[meshId]
	if hit ~= nil then
		return hit or nil
	end

	local ok, em = pcall(function()
		return AssetService:CreateEditableMeshAsync(Content.fromUri(meshId))
	end)
	if not ok or not em then
		_meshCache[meshId] = false
		return nil
	end

	local geo = nil
	local built = pcall(function()
		local faceIds = em:GetFaces()
		if #faceIds > MESH_TRI_CAP then
			return
		end
		local posOf: { [number]: Vector3 } = {}
		local minV = Vector3.new(math.huge, math.huge, math.huge)
		local maxV = -minV
		local budget = os.clock() + SLICE_SECS
		for _, vid in em:GetVertices() do
			budget = slice(budget)
			local q = em:GetPosition(vid)
			posOf[vid] = q
			minV = minV:Min(q)
			maxV = maxV:Max(q)
		end
		local span = maxV - minV
		-- A MeshPart scales its mesh to fill Size, so normalise to a unit box about the
		-- centre and the caller can just multiply by Size.
		local sx = if span.X > 1e-6 then 1 / span.X else 0
		local sy = if span.Y > 1e-6 then 1 / span.Y else 0
		local sz = if span.Z > 1e-6 then 1 / span.Z else 0
		local mid = (minV + maxV) * 0.5

		local index: { [number]: number } = {}
		local verts: { Vector3 } = {}
		for vid, q in posOf do
			local d = q - mid
			table.insert(verts, Vector3.new(d.X * sx, d.Y * sy, d.Z * sz))
			index[vid] = #verts
		end

		local faces = {}
		for _, fid in faceIds do
			budget = slice(budget)
			-- GetFaceVertices returns an ARRAY of three vertex ids, not three values.
			local fv = em:GetFaceVertices(fid)
			local ia, ib, ic = index[fv[1]], index[fv[2]], index[fv[3]]
			if ia and ib and ic then
				-- Flat per-triangle normal. Smooth normals would look better up close, but a
				-- proxy is never seen up close and this halves the bookkeeping.
				local n = (verts[ib] - verts[ia]):Cross(verts[ic] - verts[ia])
				if n.Magnitude > 1e-9 then
					table.insert(faces, { n = n.Unit, tris = { { ia, ib, ic } } })
				end
			end
		end
		if #faces > 0 then
			geo = { verts = verts, faces = faces }
		end
	end)
	em:Destroy()

	_meshCache[meshId] = if built and geo then geo else false
	return geo
end

-- Resolves every uploaded mesh this bake refers to. YIELDS. Call once, on a background
-- thread, before bakeMesh/bakeImpostor -- both treat an unresolved mesh as its bounding box.
function ModelBaker.preload(bake: Bake)
	for _, s in bake.specs do
		if s.kind == "mesh" and s.meshId then
			loadMesh(s.meshId)
		end
	end
end

-- Returns local-space vertices (already scaled by `size`) and outward-normalled faces.
local function solidOf(kind: string, size: Vector3, meshId: string?): ({ Vector3 }, { any })
	local half = size * 0.5

	if kind == "mesh" and meshId then
		local geo = _meshCache[meshId]
		if geo then
			local verts = table.create(#geo.verts)
			for i, v in geo.verts do
				verts[i] = Vector3.new(v.X * size.X, v.Y * size.Y, v.Z * size.Z)
			end
			return verts, geo.faces
		end
		-- Not resolved (unreadable, over the triangle cap, or preload was skipped): fall
		-- through to the bounding box.
	end

	if kind == "wedge" then
		local verts = table.create(6)
		for i, c in WEDGE_CORNERS do
			verts[i] = half * c
		end
		-- Slope normal in the YZ plane, perpendicular to the rise: (0, size.Z, -size.Y).
		local faces = {
			{ n = Vector3.new(0, -1, 0), tris = { { 1, 2, 3 }, { 1, 3, 4 } } },
			{ n = Vector3.new(0, 0, 1), tris = { { 4, 3, 6 }, { 4, 6, 5 } } },
			{ n = Vector3.new(0, size.Z, -size.Y).Unit, tris = { { 1, 2, 6 }, { 1, 6, 5 } } },
			{ n = Vector3.new(-1, 0, 0), tris = { { 1, 4, 5 } } },
			{ n = Vector3.new(1, 0, 0), tris = { { 2, 3, 6 } } },
		}
		return verts, faces
	end

	if kind == "corner" then
		local verts = table.create(5)
		for i, c in CORNER_CORNERS do
			verts[i] = half * c
		end
		return verts, CORNER_FACES
	end

	if kind == "ball" then
		-- Lat-long sphere. Poles are single vertices, so the top and bottom bands are
		-- triangles and everything between is quads.
		local verts = {}
		local ringStart = {}
		for i = 0, BALL_RINGS do
			local theta = i / BALL_RINGS * math.pi
			local y, r = math.cos(theta), math.sin(theta)
			if i == 0 or i == BALL_RINGS then
				table.insert(verts, Vector3.new(0, half.Y * y, 0))
				ringStart[i] = #verts
			else
				ringStart[i] = #verts + 1
				for j = 0, BALL_MERIDIANS - 1 do
					local phi = j / BALL_MERIDIANS * math.pi * 2
					table.insert(verts, Vector3.new(
						half.X * r * math.cos(phi), half.Y * y, half.Z * r * math.sin(phi)))
				end
			end
		end
		local faces = {}
		local function face(idx: { number })
			-- Flat-shade each facet along its own outward direction: for a sphere centred on
			-- the origin that is just the centroid direction.
			local c = Vector3.zero
			for _, i in idx do
				c += verts[i]
			end
			c = c / #idx
			local n = if c.Magnitude < 1e-5 then Vector3.yAxis else c.Unit
			local tris = {}
			for k = 2, #idx - 1 do
				table.insert(tris, { idx[1], idx[k], idx[k + 1] })
			end
			table.insert(faces, { n = n, tris = tris })
		end
		for i = 0, BALL_RINGS - 1 do
			for j = 0, BALL_MERIDIANS - 1 do
				local jn = (j + 1) % BALL_MERIDIANS
				if i == 0 then
					face({ ringStart[0], ringStart[1] + j, ringStart[1] + jn })
				elseif i == BALL_RINGS - 1 then
					face({ ringStart[BALL_RINGS], ringStart[i] + jn, ringStart[i] + j })
				else
					face({ ringStart[i] + j, ringStart[i + 1] + j, ringStart[i + 1] + jn, ringStart[i] + jn })
				end
			end
		end
		return verts, faces
	end

	if kind == "cylinder" then
		-- Roblox cylinders extrude along X with the circle in YZ.
		local verts = table.create(CYLINDER_SIDES * 2)
		local faces = {}
		for i = 1, CYLINDER_SIDES do
			local a = (i - 1) / CYLINDER_SIDES * math.pi * 2
			local cy, sz = math.cos(a), math.sin(a)
			verts[i * 2 - 1] = Vector3.new(-half.X, half.Y * cy, half.Z * sz)
			verts[i * 2] = Vector3.new(half.X, half.Y * cy, half.Z * sz)
		end
		local capNeg, capPos = {}, {}
		for i = 1, CYLINDER_SIDES do
			local j = (i % CYLINDER_SIDES) + 1
			local mid = ((i - 1) + 0.5) / CYLINDER_SIDES * math.pi * 2
			table.insert(faces, {
				n = Vector3.new(0, math.cos(mid), math.sin(mid)),
				tris = { { i * 2 - 1, i * 2, j * 2 }, { i * 2 - 1, j * 2, j * 2 - 1 } },
			})
			if i >= 2 and i <= CYLINDER_SIDES - 1 then
				table.insert(capNeg, { 1, i * 2 - 1, (i + 1) * 2 - 1 })
				table.insert(capPos, { 2, i * 2, (i + 1) * 2 })
			end
		end
		table.insert(faces, { n = Vector3.new(-1, 0, 0), tris = capNeg })
		table.insert(faces, { n = Vector3.new(1, 0, 0), tris = capPos })
		return verts, faces
	end

	local verts = table.create(8)
	for i, c in BOX_CORNERS do
		verts[i] = half * c
	end
	return verts, BOX_FACES
end

-- Asset-shaped properties are read through here, never directly.
--
-- `SurfaceAppearance.ColorMap` turned out to need the Plugin capability to READ: it worked
-- in every Studio test (the command bar holds that capability) and threw in the real client,
-- killing every bake in the city. MeshId is readable today, but the cost of being wrong
-- again is the whole system, and the cost of a pcall on a path that runs once per kind is
-- nothing. A read that fails costs one asset its detail instead.
local function meshIdOf(part: BasePart): string?
	local ok, id = pcall(function()
		return (part :: any).MeshId
	end)
	if ok and type(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

local function kindOf(part: BasePart): string
	if part:IsA("MeshPart") and meshIdOf(part) then
		return "mesh"
	elseif part:IsA("WedgePart") then
		return "wedge"
	elseif part:IsA("CornerWedgePart") then
		return "corner"
	elseif part:IsA("Part") then
		if part.Shape == Enum.PartType.Cylinder then
			return "cylinder"
		elseif part.Shape == Enum.PartType.Ball then
			return "ball"
		end
	end
	-- MeshPart, UnionOperation and anything future fall back to their bounding box. Unions
	-- expose no geometry to Luau at all, so there is nothing better available; at proxy range
	-- a box is a fair account of one.
	return "box"
end

-- ---------------------------------------------------------------------------------------
-- Collection
-- ---------------------------------------------------------------------------------------

local function quantise(c: Color3): (number, number, number)
	local n = COLOUR_LEVELS - 1
	return math.round(c.R * n), math.round(c.G * n), math.round(c.B * n)
end

-- FNV-1a over the quantised colour/shape stream. The cache key has to be short enough to
-- be a table key and stable across runs; a hash is both, and a collision only means two
-- near-identical buildings share a mesh, which is the outcome we want anyway.
local function hashSpecs(specs: { Spec }): string
	local h = 2166136261
	local function feed(v: number)
		h = bit32.bxor(h, bit32.band(v, 0xFF))
		h = bit32.band(h * 16777619, 0xFFFFFFFF)
	end
	for _, s in specs do
		local r, g, b = quantise(s.color)
		feed(r); feed(g); feed(b)
		feed(#s.kind)
		-- Hash the mesh ID, not its geometry: the signature has to be computable without
		-- yielding to load meshes, or `collect` could not run on the LOD sweep.
		if s.meshId then
			for i = 1, #s.meshId do
				feed(string.byte(s.meshId, i))
			end
		end
		-- Size to a tenth of a stud: dressing variants differ in geometry, not just colour.
		feed(math.round(s.size.X * 10)); feed(math.round(s.size.Y * 10)); feed(math.round(s.size.Z * 10))
	end
	return string.format("%d_%08x", #specs, h)
end

export type CollectOpts = {
	-- Reads a part's UNTINTED colour. CoverageOverlay tweens Part.Color for its heat/coverage
	-- views, so baking Part.Color straight would freeze whatever overlay happened to be up at
	-- bake time into the proxy. Callers pass CoverageOverlay.originalColor here.
	colorOf: ((BasePart) -> Color3)?,
	minFeature: number?,
}

-- Walks a Model and returns everything a bake needs, in MODEL-LOCAL space. nil when the
-- model has nothing visible worth drawing (not yet replicated, or entirely invisible).
function ModelBaker.collect(model: Model, opts: CollectOpts?): Bake?
	local o = opts or {}
	local colorOf = o.colorOf
	local minFeature = o.minFeature or MIN_FEATURE_STUDS

	local inv = model:GetPivot():Inverse()

	-- Geometry is normalised by the model's own scale, so a bake describes a SHAPE rather than
	-- a shape at one particular size. NaturePlaceService gives every tree a random scale in
	-- 0.82-1.25 and the signature hashes part sizes -- so without this, twelve oak trees
	-- produce ELEVEN different cache kinds, the entry cap fills within seconds, and every
	-- asset placed after that silently gets no proxy at all. Callers scale the clone back per
	-- instance (LODProxyCache.newMesh); normalise-then-rescale is identity, so nothing moves.
	local scale = 1
	pcall(function()
		scale = model:GetScale()
	end)
	if type(scale) ~= "number" or scale <= 1e-4 then
		scale = 1
	end
	local invScale = 1 / scale

	local specs: { Spec } = {}
	-- The specs the SIGNATURE is taken over: everything except per-instance lot dressing.
	local hashable: { Spec } = {}
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = -minV
	local sourceParts = 0
	local meshVolume, totalVolume = 0, 0
	local hasFoliage = false

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			sourceParts += 1
			-- Deliberately tested against the REAL size, not the normalised one: whether a part
			-- is too small to see is a fact about the world, not about the model's local units.
			local skip = SKIP_NAMES[d.Name]
				or d.Transparency >= 0.95
				or math.max(d.Size.X, d.Size.Y, d.Size.Z) < minFeature
			if not skip then
				-- Lot dressing rides along in the geometry but stays out of the signature, the
				-- volume ratio and the foliage test. Those three answer "what KIND of thing is
				-- this", and a garden bush does not make a house a tree.
				local dressing = isDressing(d, model)
				-- Leaves, and how much of each card the mask leaves standing. Read here rather
				-- than guessed from the name, so a species nobody has authored yet classifies
				-- itself the first time one is placed.
				local cutout = TextureAverages.cutout(d)
				if cutout and not dressing then
					hasFoliage = true
				end
				local base = if colorOf then colorOf(d) else d.Color
				-- A SurfaceAppearance overrides the part's own colour entirely, so it is asked
				-- first; only surfaces without one fall through to Part.Color + decals.
				--
				-- A part-built prop cannot carry a SurfaceAppearance (that binds to MeshParts),
				-- so street props wear a MaterialVariant instead. Ask about that too, or a
				-- textured bin bakes from Part.Color alone -- which is white on those parts,
				-- because the variant's ColorMap is what carries their colour.
				local surfaced = TextureAverages.surface(d, base)
					or TextureAverages.variant(d, base)
				local decals: { Decal } = {}
				if not surfaced then
					for _, c in d:GetChildren() do
						if c:IsA("Decal") then
							table.insert(decals, c)
						end
					end
				end
				local kind = kindOf(d)
				local meshId = if kind == "mesh" then meshIdOf(d) else nil
				local raw = inv * d.CFrame
				-- Scale the offset, leave the rotation alone.
				local localCF = CFrame.new(raw.Position * invScale) * (raw - raw.Position)
				local size = d.Size * invScale
				local vol = size.X * size.Y * size.Z
				if not dressing then
					totalVolume += vol
					if kind == "mesh" then
						meshVolume += vol
					end
				end
				local spec: Spec = {
					cf = localCF,
					size = size,
					kind = kind,
					color = surfaced or TextureAverages.over(base, decals),
					meshId = meshId,
					cutout = cutout,
				}
				table.insert(specs, spec)
				if not dressing then
					table.insert(hashable, spec)
				end
				local verts = solidOf(kind, size, meshId)
				for _, v in verts do
					local w = localCF:PointToWorldSpace(v)
					minV = minV:Min(w)
					maxV = maxV:Max(w)
				end
			end
		end
	end

	if #specs == 0 then
		return nil
	end

	return {
		specs = specs,
		center = (minV + maxV) * 0.5,
		extents = maxV - minV,
		-- Over the building, never its dressing -- see SKIP_GROUPS. A model that is ALL dressing
		-- (a bare lot) has nothing else to hash, so it falls back to hashing the lot.
		signature = hashSpecs(if #hashable > 0 then hashable else specs),
		sourceParts = sourceParts,
		keptParts = #specs,
		meshBacked = totalVolume > 0 and (meshVolume / totalVolume) > 0.5,
		foliage = hasFoliage,
		foliageStride = 1,
	}
end

-- ---------------------------------------------------------------------------------------
-- Coarsening -- telling a building's structure from its decoration
-- ---------------------------------------------------------------------------------------
--
-- Produces the rung between the full mesh and the flat impostor, by working out which parts
-- ARE the building and which are stuck to it. Nothing here reads a part's name: a rule keyed
-- to "Body" or "Roof" would work on today's library and silently fail on the first building
-- authored after it. It is all geometry, so a shape nobody has modelled yet classifies
-- correctly the first time it is placed.
--
-- Three roles:
--   CORE       the volume-ranked prefix holding CORE_SHARE of the model's volume. Measured
--              across the library, the largest 3 parts of a building carry ~87% of its volume
--              and the largest 6 carry ~95%, so this lands on the foundation, the body and
--              (on a pitched house) the roof mass, and little else.
--   SECONDARY  not part of the mass, but broad enough to still read as a SURFACE: flat roof
--              slabs, yard slabs, porch roofs, canopies. These matter far more than their
--              volume suggests because a city camera looks down at them.
--   DETAIL     everything else -- trim, coping, mullions, window plates, vents, chimneys.
--
-- The distinction that makes it work is PLANAR aspect: longest side over SECOND-longest,
-- never over thickness. A roof slab and a coping strip are both thin, so a
-- longest-over-thinnest test throws both away and the building loses its roof. In plane a
-- roof is 25x20 (1.3:1, a panel) while a coping is 25x0.7 (37:1, a strip) -- which is exactly
-- the difference between a surface and a piece of trim.

local CORE_SHARE = 0.90 -- volume-ranked prefix that counts as the building's mass
local AREA_FRAC = 0.08 -- a non-core part this broad still reads as a surface
local PLANAR_LIMIT = 6 -- longest/second-longest: low is a slab, high is a strip
local COARSE_WASTE = 0.55 -- merge boxes while wasted volume stays under this share

local function boxVolume(mn: Vector3, mx: Vector3): number
	local d = mx - mn
	return math.max(d.X, 1e-3) * math.max(d.Y, 1e-3) * math.max(d.Z, 1e-3)
end

-- Marks each spec CORE / SECONDARY / DETAIL. Exposed because it is worth being able to
-- inspect the call it made on a given model rather than inferring it from the picture.
function ModelBaker.roles(bake: Bake): { string }
	local order, total = {}, 0
	for i, s in bake.specs do
		local d = { s.size.X, s.size.Y, s.size.Z }
		table.sort(d, function(a, b) return a > b end)
		local vol = d[1] * d[2] * d[3]
		total += vol
		table.insert(order, {
			index = i,
			vol = vol,
			area = d[1] * d[2],
			planar = d[1] / math.max(d[2], 1e-3),
		})
	end
	table.sort(order, function(a, b) return a.vol > b.vol end)

	local e = { bake.extents.X, bake.extents.Y, bake.extents.Z }
	table.sort(e, function(a, b) return a > b end)
	local modelArea = math.max(e[1] * e[2], 1e-3)

	local roles = table.create(#bake.specs, "DETAIL")
	local acc = 0
	for _, x in order do
		if acc < total * CORE_SHARE then
			roles[x.index] = "CORE"
			acc += x.vol
		elseif x.area >= modelArea * AREA_FRAC and x.planar <= PLANAR_LIMIT then
			roles[x.index] = "SECONDARY"
		end
	end
	return roles
end

-- A NEW Bake sharing this one's centre and extents, holding only the structure, merged.
-- Never returns fewer than one spec, so a coarse bake is always renderable.
function ModelBaker.coarsen(bake: Bake): Bake
	local roles = ModelBaker.roles(bake)

	type Box = { mn: Vector3, mx: Vector3, filled: number }
	local groups: { [string]: { color: Color3, boxes: { Box } } } = {}

	local specs: { Spec } = {}

	for i, s in bake.specs do
		if roles[i] ~= "DETAIL" then
			if s.kind ~= "box" then
				-- Anything that is not already a box is kept EXACTLY as it is. A pitched or
				-- hipped roof, a silo, a dome: these are a small minority of parts but they are
				-- most of what makes the building's outline recognisable, and flattening them
				-- into an axis-aligned box is the one simplification that reads as "the roof
				-- just changed shape". Boxes are the only thing worth merging anyway -- merging
				-- is how walls and slabs collapse, and that is where the count actually falls.
				table.insert(specs, s)
			else
				local verts = solidOf(s.kind, s.size, s.meshId)
				local mn, mx
				for _, v in verts do
					local w = s.cf:PointToWorldSpace(v)
					mn = if mn then mn:Min(w) else w
					mx = if mx then mx:Max(w) else w
				end
				if mn and mx then
					local r, g, b = quantise(s.color)
					local key = string.format("%d_%d_%d", r, g, b)
					local grp = groups[key]
					if not grp then
						grp = { color = s.color, boxes = {} }
						groups[key] = grp
					end
					-- `filled` tracks how much real geometry a box stands for, so repeated
					-- merges cannot quietly inflate one into a mostly-empty shell.
					table.insert(grp.boxes, { mn = mn, mx = mx, filled = boxVolume(mn, mx) })
				end
			end
		end
	end
	for _, grp in groups do
		local boxes = grp.boxes
		local merging = true
		while merging and #boxes > 1 do
			merging = false
			local bi, bj, bestWaste, bmn, bmx
			for i = 1, #boxes - 1 do
				for j = i + 1, #boxes do
					local mn = boxes[i].mn:Min(boxes[j].mn)
					local mx = boxes[i].mx:Max(boxes[j].mx)
					local uv = boxVolume(mn, mx)
					local waste = (uv - boxes[i].filled - boxes[j].filled) / uv
					if not bestWaste or waste < bestWaste then
						bi, bj, bestWaste, bmn, bmx = i, j, waste, mn, mx
					end
				end
			end
			-- The waste ceiling is what stops a parapet RING collapsing into a solid block:
			-- merging four thin rails would be ~90% air, and it refuses.
			if bi and bestWaste and bestWaste < COARSE_WASTE then
				local filled = boxes[bi].filled + boxes[bj].filled
				table.remove(boxes, bj)
				boxes[bi] = { mn = bmn, mx = bmx, filled = filled }
				merging = true
			end
		end
		for _, b in boxes do
			table.insert(specs, {
				cf = CFrame.new((b.mn + b.mx) * 0.5),
				size = b.mx - b.mn,
				kind = "box",
				color = grp.color,
				meshId = nil,
			})
		end
	end

	if #specs == 0 then
		return bake
	end

	return {
		specs = specs,
		center = bake.center,
		extents = bake.extents,
		signature = bake.signature .. "c",
		sourceParts = bake.sourceParts,
		keptParts = #specs,
		meshBacked = bake.meshBacked,
		foliage = bake.foliage,
		-- Nothing above coarsens a tree: a canopy is one mesh spec, so there is no decoration
		-- to classify out and no pair of boxes to merge, and the part count comes back
		-- unchanged. Leaves coarsen a rung down instead of a part count: keep one card in two
		-- and grow the survivors to hold the painted area steady, which halves the geometry at
		-- the same silhouette and the same density.
		foliageStride = if bake.foliage then 2 else bake.foliageStride,
	}
end

-- ---------------------------------------------------------------------------------------
-- Mesh bake
-- ---------------------------------------------------------------------------------------

-- One cutout-foliage spec, emitted as opaque leaf cards.
--
-- Per TRIANGLE rather than per solid, because each card is pulled in about its own centre and
-- so cannot share vertices with its neighbours. That shrink is the whole trick. The mask
-- paints about a third of each card, so a card emitted at full size covers roughly three
-- times the area the leaves really do -- which is why an untreated tree proxy comes out fat,
-- bright and plated. Pulling every card in to the square root of its mask coverage puts the
-- painted area back where it belongs, and the gaps that opens are what let the canopy read as
-- leaves with sky behind them rather than as one green shell.
--
-- `cardIndex` runs across the whole model so a stride thins the canopy evenly; it is returned
-- so the caller can carry it into the next spec.
local function emitLeaves(
	em: any,
	s: Spec,
	verts: { Vector3 },
	faces: { any },
	center: Vector3,
	colorId: (Color3) -> number,
	stride: number,
	cardIndex: number
): number
	-- Grown back by the stride, so dropping cards thins the GEOMETRY without thinning the
	-- canopy. Never past full size: a mask that paints everything has nothing to give back.
	local shrink = math.min(1, math.sqrt((s.cutout or 1) * stride))
	local hub = s.cf.Position - center
	local base = Color3.new(
		s.color.R * FOLIAGE_SHADE,
		s.color.G * FOLIAGE_SHADE,
		s.color.B * FOLIAGE_SHADE
	)

	-- The canopy's whole palette, resolved once. Per card this is then an array index rather
	-- than a colour hash, which matters at a few hundred cards a tree.
	local palette = table.create(FOLIAGE_JITTER_STEPS)
	for i = 1, FOLIAGE_JITTER_STEPS do
		local f = 1 + ((i - 1) / (FOLIAGE_JITTER_STEPS - 1) - 0.5) * 2 * FOLIAGE_JITTER
		palette[i] = colorId(Color3.new(
			math.clamp(base.R * f, 0, 1),
			math.clamp(base.G * f, 0, 1),
			math.clamp(base.B * f, 0, 1)
		))
	end

	local world = table.create(#verts)
	for i, v in verts do
		world[i] = s.cf:PointToWorldSpace(v) - center
	end

	-- Sliced per CARD, not per spec. A canopy is ONE spec holding hundreds of cards, so the
	-- yield the caller does between specs never lands inside it -- which put the whole canopy,
	-- ~300 ms of it, into a single frame.
	local budget = os.clock() + SLICE_SECS

	for _, f in faces do
		for _, t in f.tris do
			cardIndex += 1
			if stride > 1 and cardIndex % stride ~= 0 then
				continue
			end
			budget = slice(budget)
			local p1, p2, p3 = world[t[1]], world[t[2]], world[t[3]]
			local flat = (p2 - p1):Cross(p3 - p1)
			if flat.Magnitude < 1e-9 then
				continue
			end
			flat = flat.Unit
			local mid = (p1 + p2 + p3) / 3
			-- Lean the shading normal outward from the middle of the canopy -- see
			-- FOLIAGE_OUTWARD for why a leaf card's own normal is the wrong one to shade with.
			local out = mid - hub
			local n = if out.Magnitude > 1e-6 then flat:Lerp(out.Unit, FOLIAGE_OUTWARD) else flat
			n = if n.Magnitude > 1e-6 then n.Unit else flat
			local step = math.floor(hash01(mid) * FOLIAGE_JITTER_STEPS)
			local cid = palette[math.clamp(step, 0, FOLIAGE_JITTER_STEPS - 1) + 1]
			local nid = em:AddNormal(n)
			local a = em:AddVertex(mid + (p1 - mid) * shrink)
			local b = em:AddVertex(mid + (p2 - mid) * shrink)
			local c = em:AddVertex(mid + (p3 - mid) * shrink)
			-- Wind to agree with the shading normal, as the solid path does.
			if flat:Dot(n) < 0 then
				b, c = c, b
			end
			local fid = em:AddTriangle(a, b, c)
			em:SetFaceColors(fid, { cid, cid, cid })
			em:SetFaceNormals(fid, { nid, nid, nid })
		end
	end
	return cardIndex
end

-- One vertex-coloured MeshPart for the whole model, positioned at the model's pivot by the
-- caller (geometry is emitted relative to `bake.center`, so the part's CFrame is
-- pivot * CFrame.new(center)). Returns nil rather than throwing when the editable budget is
-- gone -- a missing proxy has to degrade to "keep drawing the real model", never to a crash.
--
-- Refuses mesh-backed models that are NOT foliage -- a rock, a boulder. Two reasons, both
-- decisive: they are already only 1-3 draw calls, so consolidating saves almost nothing; and
-- an uploaded mesh carries a cloud-generated LOD chain that a runtime-baked mesh does NOT, so
-- "optimising" one would make it draw its full triangle count at every distance. Those models
-- get an impostor and nothing else.
--
-- FOLIAGE IS THE EXCEPTION, and the LOD-chain argument is why rather than in spite of.
-- Trees used to be refused alongside rocks, which left the ladder with a rung that did
-- literally nothing (FAR hides parts under 1.5 studs; a tree has none) and a jump straight
-- from a full PBR tree to a flat quad. Two things make a tree different from a rock:
--   * The chain has already run out. RenderFidelity.Automatic bottoms out at Lowest at 500
--     studs, which is exactly where the first mesh rung begins -- so past it the engine has
--     no further level to give and a bake throws away nothing that was still coming.
--   * The bake is not a re-emission of the same mesh. It drops the alpha cutout entirely,
--     which is a canopy's real cost, and merges trunk and leaves into ONE vertex-coloured
--     draw call. A tree comes out ~380 triangles with no transparency anywhere.
function ModelBaker.bakeMesh(bake: Bake, name: string?): MeshPart?
	if bake.meshBacked and not bake.foliage then
		return nil
	end
	local em = AssetService:CreateEditableMesh()
	if not em then
		return nil
	end

	local center = bake.center
	local colorIds: { [string]: number } = {}
	local posOf: { [number]: Vector3 } = {}

	local function colorId(c: Color3): number
		local key = c:ToHex()
		local id = colorIds[key]
		if not id then
			id = em:AddColor(c, 1)
			colorIds[key] = id
		end
		return id
	end

	local ok, err = pcall(function()
		-- Building the geometry for a 100-part industrial building measured ~120 ms, which is
		-- eight dropped frames if it runs to completion inside one. The async half of the bake
		-- already yields; this makes the synchronous half yield too, so a bake costs a slice of
		-- several frames instead of stalling one. Nothing is waiting on this thread -- the view
		-- keeps drawing the real model until the proxy is ready -- so spreading it is free.
		local nextYield = os.clock() + 0.004
		-- Bark is darkened only inside a foliage bake -- a building's parts must keep the
		-- colours they were collected with.
		local barkShade = if bake.foliage then FOLIAGE_BARK_SHADE else 1
		local stride = math.max(1, bake.foliageStride or 1)
		local cardIndex = 0
		for _, s in bake.specs do
			if os.clock() >= nextYield then
				task.wait()
				nextYield = os.clock() + 0.004
			end
			local verts, faces = solidOf(s.kind, s.size, s.meshId)
			if s.cutout then
				cardIndex = emitLeaves(em, s, verts, faces, center, colorId, stride, cardIndex)
				continue
			end
			local cid = colorId(Color3.new(
				s.color.R * barkShade, s.color.G * barkShade, s.color.B * barkShade))
			local ids = table.create(#verts)
			for i, v in verts do
				local p = s.cf:PointToWorldSpace(v) - center
				local id = em:AddVertex(p)
				posOf[id] = p
				ids[i] = id
			end
			for _, f in faces do
				local worldN = s.cf:VectorToWorldSpace(f.n)
				local nid = em:AddNormal(worldN)
				for _, t in f.tris do
					local v1, v2, v3 = ids[t[1]], ids[t[2]], ids[t[3]]
					-- Wind every triangle to agree with its shading normal: a mis-wound face
					-- lights as a backface and reads as a dark slice.
					local g = (posOf[v2] - posOf[v1]):Cross(posOf[v3] - posOf[v1])
					if g:Dot(worldN) < 0 then
						v2, v3 = v3, v2
					end
					local fid = em:AddTriangle(v1, v2, v3)
					em:SetFaceColors(fid, { cid, cid, cid })
					em:SetFaceNormals(fid, { nid, nid, nid })
				end
			end
		end
	end)
	if not ok then
		em:Destroy()
		warn("[ModelBaker] geometry build failed: " .. tostring(err))
		return nil
	end

	local okBake, meshOrErr = pcall(function()
		-- Static content: the MeshPart keeps its own copy, so the editable source can die now
		-- instead of holding a slice of the tiny editable budget for the session.
		local result, content = AssetService:CreateDataModelContentAsync(Content.fromObject(em))
		if result ~= Enum.CreateContentResult.Success then
			error(`CreateDataModelContentAsync failed: {tostring(result)}`)
		end
		return AssetService:CreateMeshPartAsync(content, {
			-- Proxies never collide or get queried, so skip the precise decomposition.
			CollisionFidelity = Enum.CollisionFidelity.Box,
		})
	end)
	em:Destroy()
	if not okBake then
		warn("[ModelBaker] mesh bake failed: " .. tostring(meshOrErr))
		return nil
	end

	local mesh = meshOrErr :: MeshPart
	mesh.Name = name or "LODProxy"
	mesh.Anchored = true
	mesh.CanCollide = false
	-- CanQuery=false is load-bearing: BuildingInfoController and the delete tool raycast for
	-- the REAL building body, which is still there (merely transparent). A queryable proxy
	-- sitting in front of it would swallow every click.
	mesh.CanQuery = false
	mesh.CanTouch = false
	mesh.CastShadow = false
	-- Leaf cards are shrunk away from each other, so a canopy is full of gaps that look
	-- straight through to the backs of the cards on the far side. Single-sided, those gaps
	-- render as holes in the tree.
	mesh.DoubleSided = bake.foliage
	mesh.Color = Color3.new(1, 1, 1)
	mesh.Material = Enum.Material.SmoothPlastic
	return mesh
end

-- ---------------------------------------------------------------------------------------
-- Impostor bake -- the model rendered down to one flat picture
-- ---------------------------------------------------------------------------------------
--
-- Roblox has no render-to-texture, so the "screenshot" is taken by rasterising the same box
-- set this module already has, in software: project every face into a view plane, depth-test,
-- and shade it flat against a fixed sun. That is enough because of what an impostor is FOR --
-- it only ever appears once the building is a handful of pixels tall, where the difference
-- between a real render and a shaded silhouette is not resolvable.
--
-- The view is baked at the elevation the game's camera actually sits at -- FreeCamController
-- starts at 45 degrees down -- so the picture shows the same faces the player is looking at.
-- An impostor baked at some other angle shows walls where the player sees roofs, and that
-- mismatch reads instantly as a pop even when the colours are right.
--
-- IT IS BAKED UNLIT, ON PURPOSE. The image ends up on a Decal, and a Decal is lit by the
-- engine like any other surface -- so baking a sun term in would light it TWICE, and the
-- result would shift every time the quad turned to face the camera or the day/night cycle
-- moved the sun. Baking flat albedo and letting the engine light the quad means the impostor
-- picks up the scene's real lighting, atmosphere and colour grading for free, and tracks the
-- time of day with no re-bake. At the distance an impostor appears (a building is ~3 px tall,
-- ~17 px across) there is no internal shading detail left to lose by doing this.

-- An impostor appears at ~17 px on screen and shrinks from there, so 128 was rendering four
-- times the detail anything could resolve, at four times the rasterising cost.
local IMPOSTOR_PIXELS = 96

-- A RING of azimuths is baked per kind, not one view.
--
-- A billboard shows the same picture from every side, so a single baked view is only correct
-- from the exact angle it was baked at: walk round a building and you are looking at its
-- front while standing behind it. Baking a ring and picking the nearest fixes that. Eight
-- leaves at most 22.5 degrees of error, which at the size an impostor is drawn is well under
-- a pixel of parallax.
-- Measured: 8 views at 128 px cost ~300-400 ms per tree kind, and tree kinds dominate the
-- bake queue -- which starved everything else and made the whole city take minutes to warm
-- up. 4 views leaves at most 45 degrees of azimuth error, and an impostor is only ever shown
-- once the model is ~17 px across, where that error is a fraction of a pixel of parallax.
-- ONE view, and the reason is measured rather than assumed.
--
-- Each view costs a CreateDataModelContentAsync call, and that call blocks for ~17 ms no
-- matter how small the image is (17.3 ms at 96px, 16.5 ms at 64px -- a fixed per-call cost).
-- It cannot be sliced, so the only lever on the stutter is calling it less: four views was
-- ~90 ms of unavoidable stall per kind, which is the hitch felt when a distant tree first
-- swaps.
--
-- The view RING was added to stop buildings showing their front while you stood behind them.
-- Buildings no longer use impostors at all -- they keep a baked mesh out to CULL -- so the
-- ring is now solving a problem nothing has. What is left is trees, rocks and bushes: near
-- enough radially symmetric that azimuth barely reads, and only ever drawn past 2000 studs
-- where they are a few pixels across.
--
-- Raise this if a future asset is impostored AND strongly asymmetric; the ring machinery is
-- intact and viewIndexFor still picks the nearest.
local IMPOSTOR_VIEWS = 1

-- Elevation matches FreeCamController.START_PITCH (45 degrees down), so the picture shows the
-- faces the player is actually looking at rather than an elevation they never see.
local IMPOSTOR_ELEVATION = math.rad(45)

-- Eye direction for view `i`, in MODEL-LOCAL space, as an offset FROM the model TOWARD the
-- viewer. Azimuth is measured as atan2(x, z) so it agrees with `viewIndexFor` below.
local function eyeForView(i: number): Vector3
	local a = (i - 1) / IMPOSTOR_VIEWS * math.pi * 2
	local ce = math.cos(IMPOSTOR_ELEVATION)
	return Vector3.new(math.sin(a) * ce, math.sin(IMPOSTOR_ELEVATION), math.cos(a) * ce).Unit
end

local function viewBasis(eye: Vector3): (Vector3, Vector3, Vector3)
	local fwd = -eye
	local right = fwd:Cross(Vector3.yAxis)
	right = if right.Magnitude < 1e-4 then Vector3.xAxis else right.Unit
	local up = right:Cross(fwd).Unit
	return fwd, right, up
end

-- Half-open barycentric fill with a depth test. `depth` holds view depth per pixel; smaller
-- is nearer, because `fwd` points away from the eye.
local function rasterTri(
	px: buffer, depth: { number }, w: number, h: number,
	x1: number, y1: number, z1: number,
	x2: number, y2: number, z2: number,
	x3: number, y3: number, z3: number,
	r: number, g: number, b: number
)
	local minX = math.max(0, math.floor(math.min(x1, x2, x3)))
	local maxX = math.min(w - 1, math.ceil(math.max(x1, x2, x3)))
	local minY = math.max(0, math.floor(math.min(y1, y2, y3)))
	local maxY = math.min(h - 1, math.ceil(math.max(y1, y2, y3)))
	if minX > maxX or minY > maxY then
		return
	end

	local det = (y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3)
	if math.abs(det) < 1e-9 then
		return
	end
	local inv = 1 / det

	for py = minY, maxY do
		local cy = py + 0.5
		for pxx = minX, maxX do
			local cx = pxx + 0.5
			local w1 = ((y2 - y3) * (cx - x3) + (x3 - x2) * (cy - y3)) * inv
			local w2 = ((y3 - y1) * (cx - x3) + (x1 - x3) * (cy - y3)) * inv
			local w3 = 1 - w1 - w2
			if w1 >= 0 and w2 >= 0 and w3 >= 0 then
				local z = w1 * z1 + w2 * z2 + w3 * z3
				local idx = py * w + pxx
				if z < depth[idx + 1] then
					depth[idx + 1] = z
					local o = idx * 4
					buffer.writeu8(px, o, r)
					buffer.writeu8(px, o + 1, g)
					buffer.writeu8(px, o + 2, b)
					buffer.writeu8(px, o + 3, 255)
				end
			end
		end
	end
end

-- Returns STATIC image content for a Decal, plus the world-space size the quad should be.
-- Static rather than a live EditableImage for the same budget reason as the mesh: only a
-- handful of editable objects may exist at once, but baked content is unbounded.
-- Size is symmetric about the model centre so the runtime needs no offset maths.
function ModelBaker.bakeImpostor(bake: Bake, pixels: number?): ({ any }, Vector2)
	-- Bounds are measured across EVERY view before rendering any of them, so the whole ring
	-- shares one quad size. Sizing each view to its own silhouette would make a building
	-- visibly swell and shrink as the camera orbited it.
	local hu, hv = 0, 0
	for i = 1, IMPOSTOR_VIEWS do
		local _, right, up = viewBasis(eyeForView(i))
		for _, s in bake.specs do
			local verts = solidOf(s.kind, s.size, s.meshId)
			for _, v in verts do
				local p = s.cf:PointToWorldSpace(v) - bake.center
				hu = math.max(hu, math.abs(p:Dot(right)))
				hv = math.max(hv, math.abs(p:Dot(up)))
			end
		end
	end
	if hu < 1e-3 or hv < 1e-3 then
		return {}, Vector2.zero
	end

	-- Keep pixels square so the picture is not stretched: the longer axis gets the budget.
	local budget = pixels or IMPOSTOR_PIXELS
	local w, h
	if hu >= hv then
		w = budget
		h = math.max(4, math.round(budget * hv / hu))
	else
		h = budget
		w = math.max(4, math.round(budget * hu / hv))
	end
	local sx, sy = w / (2 * hu), h / (2 * hv)

	local views = {}
	for viewIndex = 1, IMPOSTOR_VIEWS do
		local fwd, right, up = viewBasis(eyeForView(viewIndex))
		local img = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
		if not img then
			-- Editable budget ran out partway round the ring. Whatever was baked already is
			-- still usable -- the runtime picks the nearest view it actually has.
			break
		end

		local px = buffer.create(w * h * 4) -- zero-filled: untouched pixels stay transparent
		local depth = table.create(w * h, math.huge)
		local budget = os.clock() + SLICE_SECS

		for _, s in bake.specs do
			local verts, faces = solidOf(s.kind, s.size, s.meshId)
			-- Project once per solid, not once per face.
			local px2 = table.create(#verts)
			for i, v in verts do
				local p = s.cf:PointToWorldSpace(v) - bake.center
				px2[i] = {
					(p:Dot(right) + hu) * sx,
					(hv - p:Dot(up)) * sy, -- image Y runs down
					p:Dot(fwd),
				}
			end
			-- Shaded exactly as the mesh rungs shade it, so handing a tree over from its baked
			-- mesh to this quad changes its detail without also changing its colour.
			local sh = if s.cutout
				then FOLIAGE_SHADE
				elseif bake.foliage then FOLIAGE_BARK_SHADE
				else 1
			local r = math.clamp(math.round(s.color.R * sh * 255), 0, 255)
			local g = math.clamp(math.round(s.color.G * sh * 255), 0, 255)
			local b = math.clamp(math.round(s.color.B * sh * 255), 0, 255)
			for _, f in faces do
				-- Sliced per FACE, not per solid: a tree is only two solids but hundreds of
				-- faces, so slicing per solid would yield twice and still block the frame.
				budget = slice(budget)
				local n = s.cf:VectorToWorldSpace(f.n)
				-- fwd points away from the eye, so a face we can see has n:Dot(fwd) < 0.
				if n:Dot(fwd) < 0 then
					for _, t in f.tris do
						local a, bb, c = px2[t[1]], px2[t[2]], px2[t[3]]
						rasterTri(px, depth, w, h,
							a[1], a[2], a[3], bb[1], bb[2], bb[3], c[1], c[2], c[3], r, g, b)
					end
				end
			end
		end

		img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), px)
		local okBake, result, content = pcall(function()
			return AssetService:CreateDataModelContentAsync(Content.fromObject(img))
		end)
		img:Destroy()
		if okBake and result == Enum.CreateContentResult.Success then
			views[viewIndex] = content
		else
			warn("[ModelBaker] impostor view bake failed: " .. tostring(result))
		end
	end

	return views, Vector2.new(hu * 2, hv * 2)
end

-- Which baked view to show, given where the eye is relative to a PLACED model. Measured in
-- the model's own frame, which is the entire point: a building rotated 180 degrees has to
-- show its back, and only its own pivot knows which way that is.
function ModelBaker.viewIndexFor(pivot: CFrame, eye: Vector3): number
	local dir = pivot:VectorToObjectSpace(eye - pivot.Position)
	local azi = math.atan2(dir.X, dir.Z)
	local step = math.pi * 2 / IMPOSTOR_VIEWS
	return (math.round(azi / step) % IMPOSTOR_VIEWS) + 1
end

return ModelBaker
