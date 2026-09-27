--!strict
-- Client-only: the ground, as one MeshPart per heightmap chunk under workspace._Ground.
-- Geometry comes from TerrainMesh (pure); this owns the Instances, the LOD and the budget.
--
-- Why a mesh instead of workspace.Terrain voxels:
--   * UNDERGROUND EXISTS. The ground is a hollow shell, so everything below it is empty
--     space -- pipes, sewers, tunnels and metro boxes just go there, and setUnderground()
--     x-rays the shell so you can see them. Voxel terrain is solid and has no transparency.
--   * NO STAIR EDGES. A voxel column surfaces at the mean of its tile's four corners on a
--     4-stud lattice; a mesh interpolates the corners exactly.
--   * LOD IS OURS, and it answers to the SHAPE as much as to the distance. Every chunk is
--     drawn at the coarsest stride that is geometrically lossless (TerrainMesh.losslessStep),
--     so ground levelled flat is two triangles no matter how close the camera gets, and it
--     regains its detail the instant anything is sculpted there. Distance coarsens on top
--     of that, except on chunks the city has built on -- Roblox renders far terrain off a
--     coarser voxel grid, and that is what swallowed roads at distance (see
--     TerrainGradeService), so distance never takes detail away from a road. Flatness still
--     may: dropping detail the ground does not have cannot hurt anything standing on it.
--   * CHEAP ON LOW-END. These parts are Anchored, CanCollide/CanQuery/CanTouch false,
--     CastShadow false and carry Box collision only -- no collision geometry, no physics,
--     no per-frame work beyond a distance scan every MESH_LOD_REFRESH seconds.
--
-- Picking does NOT come back through these parts: a heightfield cannot be given real
-- collision (PreciseConvexDecomposition on one 64x64 chunk measured 5.8 SECONDS), so
-- CursorRay marches the heightmap analytically instead. That is also why they are cheap.
--
-- Far chunks ARE merged into 4x4 blocks now -- see THE BACKDROP below. That was written here
-- as a draw-call note; what actually forced it was LOAD TIME, because a chunk's cost turned
-- out to be its bake (~30 ms, flat, whatever the triangle count) rather than its geometry.
-- A full map is ~300 parts rather than 1,024, so the draw calls came down with it.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local TerrainMesh = require(ReplicatedStorage.Terrain.TerrainMesh)
local TerrainSurfaceTexture = require(ReplicatedStorage.Terrain.TerrainSurfaceTexture)
local LOD = require(ReplicatedStorage.Shared.LOD)

local TerrainMeshView = {}

local CHUNKS = Constants.CHUNKS_PER_AXIS
local CHUNK_STUDS = Constants.CHUNK_STUDS
local HALF = Constants.MAP_HALF_EXTENT
local STEPS = Constants.MESH_LOD_STEPS
local BUDGET = Constants.MESH_BUILD_BUDGET
local REFRESH = Constants.MESH_LOD_REFRESH
local FLAT_TOL = Constants.MESH_FLAT_TOLERANCE
local BLOCKS = Constants.CHUNK_TILES // Constants.MESH_BLOCK_TILES
local ALPHA = Constants.MESH_UNDERGROUND_ALPHA

-- No part Material texture. A Material is projected onto a MeshPart from the part's own
-- GEOMETRY and ignores mesh UVs (measured: two plates whose UVs differed 8x rendered
-- identically), so it is anchored to the shape -- and sculpting changes the shape and the
-- bounding box on every tick, which drags the texture along with it. That is what "the
-- texture moves while I sculpt" was.
--
-- The grain comes from TextureContent instead, which DOES sample mesh UVs, and TerrainMesh
-- writes those straight from world x/z. The texture is therefore pinned to the world and
-- cannot move no matter what the heights do. SmoothPlastic so nothing projects underneath
-- it, and the vertex colours tint it green/sand/grey per material zone.
--
-- MATTE, not SmoothPlastic. TextureContent replaces what the material would have drawn, but
-- the material still decides how the surface RESPONDS to light, and SmoothPlastic is glossy
-- enough to put a sheet of sun glare across the whole map. Ground does not shine.
local GROUND_MATERIAL = Enum.Material.Concrete
local WHITE = Color3.new(1, 1, 1)

type State = { part: MeshPart?, step: number, em: EditableMesh? }

local _states: { [number]: State } = {}
local _pinned: { [number]: boolean } = {}
local _queue: { number } = {}
local _queued: { [number]: boolean } = {}
-- Queued because the ground itself CHANGED there, as opposed to queued because the chunk
-- needs redrawing at another stride. Only the first kind has to pull its neighbours along,
-- and telling them apart is what stops a rebuild from cascading (see buildChunk).
local _shapeDirty: { [number]: boolean } = {}
-- Forward-declared: buildChunk requeues neighbours, and it is defined above the queue.
local enqueue: (key: number) -> ()
local _sampleY: ((number, number) -> number)? = nil
local _sampleMat: ((number, number) -> number)? = nil
local _ensureData: ((number) -> boolean)? = nil
-- Per-chunk stride error bounds (TerrainMesh.strideErrors): per block for strides 2-8, per
-- chunk for the merged strides. Memoised because computing them reads the chunk's whole corner
-- grid; dropped whenever that chunk's ground changes.
type Errors = { blocks: { number }, chunk: { [number]: number } }
local _errs: { [number]: Errors } = {}
-- The distance bucket every drawn chunk was last BUILT at, whether it draws itself or sits in a
-- backdrop block. The hysteresis in bucketOf is measured against this.
local _drawn: { [number]: number } = {}
-- Per-block shore caps (TerrainMesh.shoreCaps), dropped with _errs. `false` = this chunk
-- never meets the waterline, which is the answer for most of the map.
local _caps: { [number]: { number } | false } = {}
local _heightsOf: ((number) -> buffer?)? = nil
-- A sculpting stroke in progress: the chunks it has touched, and per chunk the blocks it
-- has touched. See editArea for why both are held for the whole stroke rather than per tick.
local _editChunks: { [number]: boolean } = {}
local _editFine: { [number]: { [number]: boolean } } = {}
local _editBusy = false
-- Chunks currently held by a live EditableMesh, least-recently-brushed first. A brush spans
-- at most four chunks at once, but a long drag crosses many, and each one it left behind
-- would otherwise keep its reservation until the stroke ended. Bounded, not unbounded.
local _liveOrder: { number } = {}
-- A brush over a chunk CORNER touches four chunks, and pinning a border block pulls their
-- neighbours in too, so four was low enough that an ordinary stroke near a seam evicted a
-- chunk every tick -- and every eviction is a full static re-bake.
local MAX_LIVE = 9
local BLOCK_TILES = Constants.MESH_BLOCK_TILES
local BLOCK_STUDS = BLOCK_TILES * Constants.SAMPLE_SPACING
local MAX_BLOCK = CHUNKS * BLOCKS - 1
local _folder: Folder? = nil
local _running = false
local _accum = 0
local _underground = false

-- ---------------------------------------------------------------------------
-- THE BACKDROP -- far ground drawn as ONE mesh per SUPER x SUPER block of chunks.
--
-- A chunk's cost is its BAKE and almost nothing else. Measured in this place:
-- CreateDataModelContentAsync + CreateMeshPartAsync is ~30 ms whether the mesh holds 8
-- triangles or 2,000, and the geometry that feeds it is 1-4 ms. So distance LOD -- which is
-- what makes the far map cheap to DRAW -- buys nothing whatsoever on LOAD: an 8-triangle
-- chunk five kilometres away pays the same 30 ms as a city chunk at 2,048 triangles, and
-- 1,024 of them is ~32 seconds of pure API overhead sitting in front of the player.
-- Merged, 49 far chunks bake in 34 ms against 1.5 s built one at a time.
--
-- NOTHING HERE CHANGES WHAT THE GROUND LOOKS LIKE. Every member chunk is still built by
-- TerrainMesh.buildChunk through the same global strideAt, so blocks stitch across a
-- super-chunk seam exactly as they stitch across a chunk seam -- there is no separate case
-- for it, the same way there is none for a chunk boundary. The merge itself is a pure
-- translation and TerrainMesh.spec pins it as one.
--
-- DISTANCE DOES NOT DECIDE THIS. Merging only the FAR map was the first version and it left
-- the near chunks loose, which is where the time actually was: measured on a full map, merging
-- past 1,800 studs took 12.4 s and merging everything took 5.3 s. Near ground merges too.
--
-- What is excluded is what the city has TOUCHED -- see _solo. Excluding it per MEMBER rather
-- than per block is the other half of the number: a block is 16 chunks, and disqualifying all
-- 16 because one was built on cost 7.0 s against 5.3 s on a map with a 36-chunk city.
--
-- 4 and not 8: 8x8 is faster still (2.8 ms per chunk against 4.0) but a MeshPart's extents cap
-- at 2,048 studs and 8 chunks is 2,048 exactly before the ground's own height is added, and a
-- 2,048-stud block re-tiers as one ~180 ms rebuild when the camera crosses an LOD ring.
-- 4x4 is the compromise -- ~65-220 ms of work per rebuild, which DID show up while panning
-- (240 -> 15 fps), so past the loading screen a rebuild is sliced across frames (see breathe).
local SUPER = 4
local SUPERS = CHUNKS // SUPER
-- One EditableMesh will not hold unlimited geometry: past a limit AddTriangle throws
-- "Triangle count above limit" outright rather than degrading, and a block that throws is
-- ground nobody draws. The exact cap is somewhere between 8,192 and 32,768 triangles and is
-- not worth pinning down, because this is checked BEFORE the bake -- the member geometry
-- already knows its triangle count -- and a block over budget simply hands its chunks back to
-- the per-chunk path, which costs speed and nothing else.
local TRI_BUDGET = 20000

type Super = { part: MeshPart?, members: { number } }
local _supers: { [number]: Super } = {}
-- Chunk key -> the block currently drawing it. A chunk in here has no _states entry and no
-- mesh of its own; that is how every other path in this file knows to leave it alone.
local _superOf: { [number]: number } = {}
-- Chunks that draw THEMSELVES instead of joining their block: the ones the city has built on
-- and the ones under a brush. Everything else is scenery. One-way for the session -- a chunk
-- that has been built on does not become scenery again, and the one-way-ness is also what
-- stops the over-budget fallback below from oscillating back into the block it just left.
local _solo: { [number]: boolean } = {}
local _superQueue: { number } = {}
local _superQueued: { [number]: boolean } = {}
-- Ground that has left the queue but does not exist yet. Baking YIELDS, so without this the
-- queues read empty for the whole of the last bake -- and `pending` is what the join gate
-- holds the loading screen on, so the player was let in during it. One part, but the promise
-- the gate makes is that there are no holes at all.
local _inFlight = 0
-- What a pump is baking RIGHT NOW. Two pumps run (see start), and the same block baked twice at
-- once would leave the loser's part standing on top of the winner's.
local _building: { [number]: boolean } = {}
local _buildingSuper: { [number]: boolean } = {}

-- ONE FRAME'S SHARE of rebuild work per pump, once the player is in. Rebuilding a 4x4 block
-- measured ~220 ms of blocking Luau in Studio (61 geometry + 32 merge + 127 mesh fill), and a
-- camera move re-buckets dozens of blocks at once: that took an empty map from 240 fps to 15
-- while panning. Sliced, the same work lands over several frames and the ground catches up a
-- beat later. Only the pumps slice, and never behind the loading screen -- a sculpt stroke and
-- the load gate both want the work done now, so any other thread runs straight through.
local PUMPS = 2 -- see start()
-- Per pump. Small on purpose: LOD changes are rare and far now (see BUCKET_NEAR), so there is
-- no hurry, and the frame rate must not move while they land.
local PLAY_SLICE = 0.001
local _sliceEnd: { [thread]: number } = {}
local _loading = true
local _epoch = 0 -- bumped by reset(): a build that yielded across it throws its result away

local function breathe()
	if _loading then return end
	local co = coroutine.running()
	local e = _sliceEnd[co]
	if not e or os.clock() < e then return end
	RunService.Heartbeat:Wait()
	_sliceEnd[co] = os.clock() + PLAY_SLICE
end

-- The incoming part is parented BEFORE these go, and a locally created MeshPart is in the
-- scene for the frame it is parented in, so there is no gap to cover. Holding the outgoing
-- one for an extra frame is worse, not better: the two surfaces are coincident everywhere
-- the brush did not reach, and where it did the stale one can sit ABOVE the new ground and
-- show the un-lowered shape for a frame.
local function retire(part: MeshPart?, em: EditableMesh?)
	if part then (part :: MeshPart):Destroy() end
	if em then (em :: EditableMesh):Destroy() end
end

local function folder(): Folder
	local f = _folder
	if f and f.Parent then return f end
	f = Workspace:FindFirstChild("_Ground") :: Folder?
	if not f then
		f = Instance.new("Folder")
		;(f :: Folder).Name = "_Ground"
		;(f :: Folder).Parent = Workspace
	end
	_folder = f
	return f :: Folder
end

local function centreX(cx: number): number return -HALF + (cx + 0.5) * CHUNK_STUDS end
local function centreZ(cz: number): number return -HALF + (cz + 0.5) * CHUNK_STUDS end

-- Edge neighbours in the order TerrainMesh stitches them: -Z, +X, +Z, -X.
local NEIGHBOUR_DXZ = table.freeze({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } })

local function neighbourKey(cx: number, cz: number, d: { number }): number?
	local nx, nz = cx + d[1], cz + d[2]
	if nx < 0 or nx >= CHUNKS or nz < 0 or nz >= CHUNKS then return nil end
	return nz * CHUNKS + nx
end

-- To the NEAREST point of the chunk, not its centre: a 256-stud chunk judged by its middle is
-- drawn too coarse along the edge facing the camera, and that edge is what is closest.
local function chunkDist(key: number, camPos: Vector3): number
	local cx = key % CHUNKS
	local cz = (key - cx) / CHUNKS
	local hx, hz = CHUNK_STUDS * 0.5, CHUNK_STUDS * 0.5
	local dx = math.max(math.abs(centreX(cx) - camPos.X) - hx, 0)
	local dy = camPos.Y
	local dz = math.max(math.abs(centreZ(cz) - camPos.Z) - hz, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- HOW MUCH ERROR IS INVISIBLE HERE. Detail is chosen by SCREEN-SPACE ERROR, not by rings: a
-- block is drawn at the coarsest stride whose worst height error covers less than
-- LOD.PIXEL_BUDGET (half a pixel) at this distance. A stride change is therefore never
-- visible by construction -- the geometry moves by less than a pixel -- which is what the old
-- fixed rings (stride 2 at point-blank range, jumps at 900/1800/3200/5200 studs) could not
-- promise: every ring crossing was a re-tessellation the player watched happen.
--
-- Distance is bucketed in steps of BUCKET_RATIO from BUCKET_NEAR, and a bucket is judged by its
-- NEAR edge, so everything inside it is at least as accurate as the budget asks. A chunk only
-- rebuilds when its bucket changes; hysteresis keeps a camera on the boundary from re-baking it
-- every refresh.
--
-- FEW BUCKETS, AND ONLY FAR (user call, 2026-09-23). Doublings from 256 studs meant six rings
-- sweeping past the camera, so panning an empty map re-tessellated something every few frames.
-- Now everything within BUCKET_NEAR is full detail and NEVER changes; past it there are two
-- coarser rings, 1,024 and 4,096 studs out, where a change is both rare and far away.
--
-- Pinned chunks -- the ones the city built on -- are always bucket 0: distance never coarsens
-- ground under a road (see TerrainGradeService). Their own flatness still may.
local LOD_HYSTERESIS = 0.25
local BUCKET_NEAR = 1024
local BUCKET_RATIO = 4
local MAX_BUCKET = 2
-- Past this bucket (4,096 studs) the waterline stops being held at a fixed stride and far
-- coastal chunks may merge like any other -- see strideAt.
local SHORE_FREE_BUCKET = 2

local function bucketFor(d: number): number
	if d < BUCKET_NEAR then return 0 end
	return math.min(math.floor(math.log(d / BUCKET_NEAR, BUCKET_RATIO)) + 1, MAX_BUCKET)
end

local function bucketNearEdge(b: number): number
	return if b <= 0 then 0 else BUCKET_NEAR * BUCKET_RATIO ^ (b - 1)
end

local function bucketOf(key: number, camPos: Vector3): number
	if _pinned[key] then return 0 end
	local d = chunkDist(key, camPos)
	local b = bucketFor(d)
	local current = _drawn[key]
	if current and current ~= b then
		-- Stay put while within the stretched boundary of the bucket we are already drawn in.
		local lo = bucketNearEdge(current) * (1 - LOD_HYSTERESIS)
		local hi = if current >= MAX_BUCKET then math.huge else bucketNearEdge(current + 1) * (1 + LOD_HYSTERESIS)
		if d >= lo and d < hi then return current end
	end
	return b
end

-- The worst height error this bucket can hide. Never finer than one height quantum: detail
-- the heightmap cannot express is not detail.
local function toleranceOf(b: number): number
	return math.max(FLAT_TOL, LOD.toleranceStuds(bucketNearEdge(b)))
end

-- Deep enough to fill the widest crack two neighbours a bucket apart can open between them.
local function skirtDepth(b: number): number
	return 4 * toleranceOf(b) + 1
end

-- How much error each stride would cost in each block of a chunk. Asking FORCES the chunk's
-- heights to exist, because a neighbour's strides have to be exact before this chunk can stitch
-- to them -- and generating it now is free in total, since the background fill was going to
-- generate it anyway, only later. Guessing instead leaves a crack nobody goes back to fix.
local function errorsFor(key: number): Errors?
	local cached = _errs[key]
	if cached then return cached end
	local sampleY, ensureData = _sampleY, _ensureData
	if not sampleY or not ensureData or not ensureData(key) then return nil end
	local cx = key % CHUNKS
	local blocks, chunk = TerrainMesh.strideErrors(cx, (key - cx) / CHUNKS, sampleY)
	local errs = { blocks = blocks, chunk = chunk }
	_errs[key] = errs
	return errs
end

local function shoreCapsFor(key: number): { number }?
	local memo = _caps[key]
	if memo ~= nil then return if memo then memo else nil end
	local heightsOf = _heightsOf
	local heights = if heightsOf then heightsOf(key) else nil
	local caps = if heights then TerrainMesh.shoreCaps(heights) else nil
	_caps[key] = caps or false
	return caps
end

-- The stride of ONE block anywhere on the map: the coarsest its own shape can take within the
-- error its distance hides.
--
-- The WATERLINE is the exception. Where ground meets engine water a vertical error is magnified
-- into a horizontal one -- a quarter stud on a 1:20 beach moves the coast five studs -- so a
-- shore block ignores distance and is drawn at a fixed stride decided by its shape alone (never
-- coarser than its cap). The coast then never changes as the camera moves. Only far out, past
-- SHORE_FREE_BUCKET, does the shore coarsen and merge with the rest of the chunk.
local function strideAt(gbx: number, gbz: number, eye: Vector3): number
	local cx = gbx // BLOCKS
	local cz = gbz // BLOCKS
	-- Off the map there is no neighbour to agree with, and the FINEST stride reads as "never
	-- stitch to me", which leaves the map edge sitting at its true heights.
	if cx < 0 or cx >= CHUNKS or cz < 0 or cz >= CHUNKS then return 1 end
	local key = cz * CHUNKS + cx
	local index = (gbz - cz * BLOCKS) * BLOCKS + (gbx - cx * BLOCKS) + 1
	-- A block the brush is working on is held at full resolution for the whole stroke, ahead
	-- of anything the shape or the distance would say.
	local fine = _editFine[key]
	if fine and fine[index] then return 1 end
	local errs = errorsFor(key)
	if not errs then return 1 end
	local b = bucketOf(key, eye)
	local tol = toleranceOf(b)
	local caps = if b < SHORE_FREE_BUCKET then shoreCapsFor(key) else nil
	-- The whole chunk as one patch, when even that is within tolerance. Never with a shore in
	-- it: the shore holds its own stride.
	if not caps then
		for i = #STEPS, 1, -1 do
			local m = STEPS[i]
			if m <= BLOCK_TILES then break end
			if (errs.chunk[m] or math.huge) <= tol then return m end
		end
	end
	local cap = if caps then caps[index] else 0
	if cap > 0 then
		return math.min(cap, TerrainMesh.blockStride(errs.blocks, index, FLAT_TOL))
	end
	return TerrainMesh.blockStride(errs.blocks, index, tol)
end

local function eyePos(): Vector3
	local cam = Workspace.CurrentCamera
	return if cam then cam.CFrame.Position else Vector3.zero
end

local function superKeyOf(key: number): number
	local cx = key % CHUNKS
	local cz = (key - cx) / CHUNKS
	return (cz // SUPER) * SUPERS + (cx // SUPER)
end

local function superMembers(sk: number): { number }
	local sx = sk % SUPERS
	local sz = (sk - sx) / SUPERS
	local out = table.create(SUPER * SUPER)
	for dz = 0, SUPER - 1 do
		for dx = 0, SUPER - 1 do
			out[#out + 1] = (sz * SUPER + dz) * CHUNKS + (sx * SUPER + dx)
		end
	end
	return out
end

-- The members this block actually draws: everything that has not gone solo.
local function superDist(sk: number, camPos: Vector3): number
	local d = math.huge
	for _, key in superMembers(sk) do
		d = math.min(d, chunkDist(key, camPos))
	end
	return d
end

local function mergeMembers(sk: number): { number }
	local out = {}
	for _, key in superMembers(sk) do
		if not _solo[key] then
			out[#out + 1] = key
		end
	end
	return out
end

local function enqueueSuper(sk: number)
	if _superQueued[sk] then return end
	_superQueued[sk] = true
	_superQueue[#_superQueue + 1] = sk
end

local function enqueueChunk(key: number)
	if _queued[key] then return end
	_queued[key] = true
	_queue[#_queue + 1] = key
end

-- Returns nil when the client's shared Editable budget is momentarily exhausted, which is
-- a "try later", not a failure -- the caller puts the chunk back in the queue. It is a
-- SHARED budget: overrunning it does not just fail terrain, it fails every other
-- EditableMesh in the game (the glass UI was the first casualty).
local function bake(geo: TerrainMesh.Geo, live: boolean): (MeshPart?, EditableMesh?)
	local em = AssetService:CreateEditableMesh()
	if not em then return nil, nil end
	local kept: EditableMesh? = nil
	local ok, result = pcall(function(): MeshPart
		local pos, nrm, col, tri, uvs = geo.pos, geo.nrm, geo.col, geo.tri, geo.uv
		local n = #pos
		local vid, nid, cid, uid = table.create(n), table.create(n), table.create(n), table.create(n)
		for i = 1, n do
			if i % 256 == 0 then breathe() end
			vid[i] = em:AddVertex(pos[i])
			nid[i] = em:AddNormal(nrm[i])
			cid[i] = em:AddColor(col[i], 1)
			uid[i] = em:AddUV(uvs[i])
		end
		-- One scratch table per attribute, refilled per face: the engine copies the ids out, and
		-- three fresh tables a triangle cost 10-30% of the fill in garbage (measured).
		local fn, fc, fu = table.create(3), table.create(3), table.create(3)
		for i = 1, #tri, 3 do
			if i % 384 == 1 then breathe() end -- every 128 triangles
			local a, b, c = tri[i], tri[i + 1], tri[i + 2]
			local f = em:AddTriangle(vid[a], vid[b], vid[c])
			fn[1], fn[2], fn[3] = nid[a], nid[b], nid[c]
			fc[1], fc[2], fc[3] = cid[a], cid[b], cid[c]
			fu[1], fu[2], fu[3] = uid[a], uid[b], uid[c]
			em:SetFaceNormals(f, fn)
			em:SetFaceColors(f, fc)
			em:SetFaceUVs(f, fu)
		end
		if live then
			-- Skip the static bake: measured on a sculpted chunk, this path is ~6 ms against
			-- ~36 ms through CreateDataModelContentAsync, and 36 ms every stroke tick is what
			-- made the ground feel like it was chasing the cursor.
			--
			-- The MeshPart only keeps rendering while an EditableMesh backs it, and it MUST be
			-- the FixedSize snapshot, never this scratch one: a DYNAMIC EditableMesh reserves
			-- a fat slice of the client budget whatever it actually holds, so keeping even a
			-- couple alive exhausts it -- and that budget is shared, so what breaks first is
			-- the glass UI, not terrain. FixedSize reserves only its own size. The scratch dies
			-- in the caller either way.
			local fixed = AssetService:CreateEditableMeshAsync(Content.fromObject(em), { FixedSize = true })
			local ok2, part = pcall(function(): MeshPart
				return AssetService:CreateMeshPartAsync(Content.fromObject(fixed), {
					CollisionFidelity = Enum.CollisionFidelity.Box,
					RenderFidelity = Enum.RenderFidelity.Precise, -- see the static bake below
				})
			end)
			if not ok2 then
				fixed:Destroy()
				error(part)
			end
			kept = fixed
			return part :: MeshPart
		end
		-- Bake to STATIC content and let the EditableMesh die: the client Editable* budget is
		-- about eight live meshes, so a view that kept them alive would fail past chunk eight.
		local res, content = AssetService:CreateDataModelContentAsync(Content.fromObject(em))
		assert(res == Enum.CreateContentResult.Success, tostring(res))
		-- PRECISE: this file decides the detail. The default (Automatic) let the engine decimate
		-- every chunk on its own at distance, so neighbouring chunks stopped agreeing along their
		-- edges and thin gaps opened between terrain pieces as the engine swapped its LODs.
		-- ApplyMesh carries it onto the reshaped part (measured).
		return AssetService:CreateMeshPartAsync(content, {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Precise,
		})
	end)
	em:Destroy() -- the scratch always dies here; only the FixedSize snapshot may outlive it
	if not ok then
		if kept then (kept :: EditableMesh):Destroy() end
		warn("[TerrainMeshView] bake failed:", result)
		return nil, nil
	end
	return result :: MeshPart, kept
end

-- Everything a ground MeshPart is apart from its geometry. Shared by the per-chunk meshes and
-- the merged backdrop, so the two cannot drift apart in appearance -- a backdrop with a
-- different material or a missing grain would draw a visible seam around every chunk the city
-- has touched.
local function dress(mp: MeshPart, geo: TerrainMesh.Geo, name: string)
	mp.Name = name
	mp.Anchored = true
	mp.CanCollide = false
	mp.CanQuery = false
	mp.CanTouch = false
	mp.CastShadow = false
	mp.DoubleSided = false
	mp.Color = WHITE -- vertex colours do the tinting
	mp.Material = GROUND_MATERIAL
	local grain = TerrainSurfaceTexture.image()
	if grain then
		-- pcall: a MeshPart that will not take TextureContent should still be ground.
		pcall(function()
			mp.TextureContent = Content.fromObject(grain)
		end)
	end
	mp.Transparency = if _underground then ALPHA else 0
	mp.CFrame = CFrame.new(geo.origin)
	mp.Parent = folder()
end

-- Build (or rebuild) one chunk and swap it in. The old part is destroyed only after the new
-- one is parented, so the ground never flickers a hole. `eye` is the LOD reference; it
-- defaults to the camera and is passed explicitly during the first fill, when the camera is
-- not yet where the player will be.
function TerrainMeshView.buildChunk(key: number, eye: Vector3?, live: boolean?): boolean
	local sampleY, sampleMat = _sampleY, _sampleMat
	if not sampleY or not sampleMat then return false end
	local cx = key % CHUNKS
	local cz = (key - cx) / CHUNKS
	local at = eye or eyePos()

	-- Scenery is never drawn per chunk, on ANY path. The cold load's near pass calls straight in
	-- here rather than through the queue, and without this those chunks would each be baked
	-- individually and then again as part of a block -- the whole near map rebuilding itself for
	-- no reason. A live sculpt rebuild is exempt: editArea has already soloised its chunk.
	if not live and not _solo[key] then
		enqueue(key)
		return true
	end
	local shapeChanged = _shapeDirty[key] == true
	-- The chunk records only its distance BUCKET: its blocks' strides follow from that plus a
	-- shape that does not change on its own, so the bucket is the whole of what can go stale.
	local tier = bucketOf(key, at)
	local geo = TerrainMesh.buildChunk(cx, cz, sampleY, sampleMat, function(gbx: number, gbz: number): number
		return strideAt(gbx, gbz, at)
	end)
	TerrainMesh.addSkirt(geo, skirtDepth(tier))
	local epoch = _epoch
	local mp, em = bake(geo, live == true)
	if not mp then return false end
	if epoch ~= _epoch then -- the map was torn down while this baked
		retire(mp, em)
		return true
	end
	_shapeDirty[key] = nil -- cleared only once the work it asked for actually landed

	-- RESHAPE the part that is already there instead of swapping in a new one. A swap is two
	-- instances changing places in the render scene, and that hand-off is the flicker the
	-- ground shows on every chunk a road grades -- the old part had to survive until the new
	-- one was parented, and there is no frame at which the engine promises both are drawn.
	-- ApplyMesh replaces the geometry ON the instance that is already drawing: same part, same
	-- draw call, only the mesh changes. Measured: it swaps MeshSize but leaves Size alone, so
	-- Size has to follow it or the new shape is scaled into the old part's extent.
	--
	-- STATIC bakes only. A live part renders only while its OWN EditableMesh is alive, and
	-- whether that content survives being handed to a second instance is not worth relying on.
	local st = _states[key]
	local reuse: MeshPart? = if em == nil and st then st.part else nil
	if reuse then
		local fresh = mp :: MeshPart
		local held = reuse :: MeshPart
		held:ApplyMesh(fresh)
		held.Size = fresh.Size
		fresh:Destroy()
		mp = held
	end

	dress(mp, geo, "G" .. key)

	if st then
		local oldPart, oldEm = st.part, st.em
		st.part = mp
		st.em = em
		st.step = tier
		-- Both together: a live part STOPS RENDERING the moment its EditableMesh dies, so
		-- freeing the mesh early would open the very hole the deferral exists to avoid.
		-- oldPart IS mp when it was reshaped in place; only a real swap has one to retire.
		retire(if oldPart ~= mp then oldPart else nil, oldEm)
	else
		_states[key] = { part = mp, step = tier, em = em }
	end
	_drawn[key] = tier

	-- Neighbouring blocks stitched their edges onto the lines our border blocks draw, so they
	-- are stale when the GROUND here changed shape -- a new height is off by any amount.
	--
	-- NOT when only our distance tier changed. Both sides of the seam are then within their own
	-- tolerance of the true edge, so they disagree by about a pixel at most, and the skirts
	-- fill that. Re-stitching anyway re-queued up to four neighbouring blocks per LOD change:
	-- measured on a camera sweep, 60 block rebuilds against 24 without, and the ground took
	-- 10.4 s to catch up against 0.6 s.
	if not shapeChanged then return true end
	for _, d in NEIGHBOUR_DXZ do
		local nk = neighbourKey(cx, cz, d)
		if nk and (_states[nk] or _superOf[nk]) then enqueue(nk) end
	end
	return true
end

-- Build (or rebuild) one super-chunk: every member's geometry through the SAME strideAt the
-- per-chunk path uses, merged, and baked once. Yields (bake does), like buildChunk.
local function buildSuper(sk: number, eye: Vector3): boolean
	local sampleY, sampleMat, ensureData = _sampleY, _sampleMat, _ensureData
	if not sampleY or not sampleMat or not ensureData then return false end

	local old = _supers[sk]
	local epoch = _epoch
	local function dropOld()
		if old then
			if old.part then (old.part :: MeshPart):Destroy() end
			_supers[sk] = nil
		end
	end

	local members = mergeMembers(sk)
	-- The city grew over all of it. Nothing left to merge, and the solo chunks are already
	-- drawing themselves.
	if #members == 0 then
		dropOld()
		return true
	end

	-- Each member keeps its OWN bucket: a 1,024-stud block spans several, and judging it by
	-- one member draws the far side of it too fine or the near side too coarse.
	local buckets: { [number]: number } = {}
	for _, key in members do
		buckets[key] = bucketOf(key, eye)
	end

	local geos = table.create(#members)
	local tris = 0
	for _, key in members do
		ensureData(key)
		local cx = key % CHUNKS
		local g = TerrainMesh.buildChunk(cx, (key - cx) / CHUNKS, sampleY, sampleMat,
			function(gbx: number, gbz: number): number
				return strideAt(gbx, gbz, eye)
			end)
		TerrainMesh.addSkirt(g, skirtDepth(buckets[key]))
		tris += #g.tri // 3
		geos[#geos + 1] = g
		breathe()
	end

	-- Too much detail to hold in one mesh. Asked BEFORE the bake, because the bake THROWS on
	-- overrun and a block that throws is ground nobody draws. These chunks go solo for the rest
	-- of the session: that is what stops them being re-merged into the same over-budget block on
	-- the next sweep, round and round.
	--
	-- Built HERE, before the block is dropped: queued, sixteen sliced rebuilds left a 1,024-stud
	-- hole in the map for seconds. The block keeps drawing until they have all landed -- the
	-- same overlap soloise accepts, and nobody can see it.
	if tris > TRI_BUDGET then
		for _, key in members do
			_superOf[key] = nil
			_solo[key] = true
		end
		for _, key in members do
			_building[key] = true
			local ok, built = pcall(TerrainMeshView.buildChunk, key, eye)
			_building[key] = nil
			if not ok then warn("[TerrainMeshView] chunk", key, "failed:", built) end
			if not (ok and built) then enqueueChunk(key) end
		end
		if epoch == _epoch then dropOld() end
		return true
	end

	local geo = TerrainMesh.mergeGeo(geos, breathe)
	local mp = bake(geo, false)
	if not mp then return false end -- out of Editable budget; the caller re-queues
	if epoch ~= _epoch then -- the map was torn down while this baked
		mp:Destroy()
		return true
	end
	-- Reshape the block that is already drawing rather than swapping in a new part, for the
	-- same reason buildChunk does: a swap is two instances trading places in the render scene,
	-- and there is no frame at which the engine promises both are drawn.
	if old and old.part and (old.part :: MeshPart).Parent then
		local held = old.part :: MeshPart
		local fresh = mp :: MeshPart
		held:ApplyMesh(fresh)
		held.Size = fresh.Size
		fresh:Destroy()
		mp = held
	elseif old and old.part then
		(old.part :: MeshPart):Destroy()
	end
	dress(mp :: MeshPart, geo, "S" .. sk)
	_supers[sk] = { part = mp, members = members }

	-- A member whose bucket changed moved the edge its outside neighbours stitched to, by about
	-- a pixel. The skirts cover that; see the note at the end of buildChunk for why nothing
	-- re-stitches on a distance change.
	for _, key in members do
		_drawn[key] = buckets[key]
	end

	-- What this draws must not also be drawing itself -- except a member a brush sent solo while
	-- this was building: it draws itself now, and the rebuild soloise queued drops it from here.
	for _, key in members do
		if _solo[key] then continue end
		_shapeDirty[key] = nil -- landed; see the urgency check in tick
		_superOf[key] = sk
		local st = _states[key]
		if st then
			retire(st.part, st.em)
			_states[key] = nil
		end
	end
	return true
end

-- Hand a block back to its chunks: the camera has come close, or something was built out
-- This chunk is not scenery any more -- it has been built on, or a brush is on it. It leaves
-- its block, which rebuilds WITHOUT it, and draws itself from here on.
--
-- Ejecting ONE member rather than splitting the whole block is two bakes instead of sixteen,
-- which is what makes grading a road out in the backdrop cheap.
--
-- The block keeps drawing its old mesh -- this chunk's ground included -- until that rebuild
-- lands, so for a frame or two the ground here is drawn twice. Deliberate: dropping the block
-- first would open a 4x4-chunk hole instead, and a hole is far worse than an overlap nobody
-- can see.
--
-- A chunk with no owner is either already drawing itself or has not been drawn at all yet --
-- which is the case at load, where every edited chunk is pinned BEFORE anything is built.
-- Queueing it here would bake it once now and once more when the queue reached it.
local function soloise(key: number)
	if _solo[key] then return end
	_solo[key] = true
	local owner = _superOf[key]
	if not owner then return end
	_superOf[key] = nil
	enqueueSuper(owner)
	enqueueChunk(key)
end

function enqueue(key: number)
	-- Scenery is drawn by its block, never by itself. THIS REDIRECT IS THE WIN: a cold load asks
	-- for all 1,024 chunks and it becomes ~64 merged bakes.
	if not _solo[key] then
		enqueueSuper(superKeyOf(key))
		return
	end
	enqueueChunk(key)
end

-- LOD RE-TIERS ONLY ONCE THE CAMERA HAS SETTLED. Every rebuild ends in CreateMeshPartAsync,
-- which blocks ~21-27 ms whatever the mesh holds (measured: 256 triangles and 12,288 cost the
-- same) and cannot be sliced, so any LOD change while panning was a dropped frame. Held until the
-- camera rests, the far rings catch up while nothing moves. Behind the loading screen it never
-- waits.
local SETTLE_STUDS = 8 -- camera travel per REFRESH window that still counts as resting
local _sweepPos = Vector3.zero

local function sweepDue(dt: number, camPos: Vector3): boolean
	_accum += dt
	if _accum < REFRESH then return false end
	_accum = 0
	local moved = (camPos - _sweepPos).Magnitude
	_sweepPos = camPos
	return moved < SETTLE_STUDS or _loading
end

local function tick(dt: number, sweeps: boolean)
	local cam = Workspace.CurrentCamera
	if not cam then return end
	-- Past the loading screen one pump is plenty: throughput stops mattering, and two pumps
	-- resuming in the same frame stacked their hitches.
	if not sweeps and not _loading then return end
	local camPos = cam.CFrame.Position

	if sweeps and sweepDue(dt, camPos) then
		-- Not what is mid-build: its bucket updates when it lands, and queueing it again meanwhile
		-- rebuilt every sliced block twice.
		for key, st in _states do
			if not _queued[key] and not _building[key] and bucketOf(key, camPos) ~= st.step then
				enqueue(key)
			end
		end

		-- The backdrop re-tiers the same way a chunk does, off its nearest member. Blocks are
		-- never split by distance -- membership answers to what the city has touched, not to
		-- where the camera is -- so there is nothing to collect and split here.
		for sk, s in _supers do
			if not _superQueued[sk] and not _buildingSuper[sk] then
				for _, key in s.members do
					if bucketOf(key, camPos) ~= _drawn[key] then
						enqueueSuper(sk)
						break
					end
				end
			end
		end

		-- Nearest first, whatever queued it: sliced rebuilds mean the queues can hold seconds of
		-- work, and the ground under the camera must not wait behind the horizon.
		local dist: { [number]: number } = {}
		for _, key in _queue do dist[key] = chunkDist(key, camPos) end
		table.sort(_queue, function(a, b) return dist[a] < dist[b] end)
		local sdist: { [number]: number } = {}
		for _, sk in _superQueue do sdist[sk] = superDist(sk, camPos) end
		table.sort(_superQueue, function(a, b) return sdist[a] < sdist[b] end)
	end

	if #_queue == 0 and #_superQueue == 0 then return end
	-- At least one item per frame whatever the budget says, or a big one would never start.
	-- Past the loading screen that item slices itself (see breathe) instead of dropping frames.
	-- ponytail: one chunk's TerrainMesh.buildChunk is still one unsliced step (2-15 ms); move
	-- the geometry into a parallel Actor if that ever shows up in the MicroProfiler.
	--
	-- Except where the GROUND ITSELF changed (a road graded, a pad levelled): that lands unsliced,
	-- as it always has, or the old surface pokes up through what was just built on it.
	local co = coroutine.running()
	local slice = if _loading then BUDGET else PLAY_SLICE
	local t0 = os.clock()
	repeat
		-- Chunks before blocks: the chunk queue is filled nearest-first, and what the player is
		-- about to look at matters more than the horizon behind it.
		if #_queue > 0 then
			local key = table.remove(_queue, 1) :: number
			_queued[key] = nil
			-- It was merged into the backdrop while it sat in the queue. Building it now would
			-- put a second surface over ground the block is already drawing.
			if _building[key] then
				enqueueChunk(key) -- the other pump is mid-bake on it
				return
			end
			if not _superOf[key] then
				local urgent = _shapeDirty[key] == true
				if urgent then _sliceEnd[co] = math.huge end
				_inFlight += 1
				_building[key] = true
				local ok, built = pcall(TerrainMeshView.buildChunk, key, camPos)
				_building[key] = nil
				if urgent then _sliceEnd[co] = t0 + slice end
				_inFlight = math.max(_inFlight - 1, 0)
				if not ok then
					warn("[TerrainMeshView] chunk", key, "failed:", built)
				elseif not built then
					-- Out of Editable budget this instant. Put it back and yield the frame rather
					-- than spinning: whatever is holding the budget needs a chance to let go.
					enqueue(key)
					return
				end
			end
		else
			local sk = table.remove(_superQueue, 1) :: number
			_superQueued[sk] = nil
			if _buildingSuper[sk] then
				enqueueSuper(sk)
				return
			end
			local urgent = false
			for _, key in superMembers(sk) do
				if _shapeDirty[key] then
					urgent = true
					break
				end
			end
			if urgent then _sliceEnd[co] = math.huge end
			_inFlight += 1
			_buildingSuper[sk] = true
			local ok, built = pcall(buildSuper, sk, camPos)
			_buildingSuper[sk] = nil
			if urgent then _sliceEnd[co] = t0 + slice end
			_inFlight = math.max(_inFlight - 1, 0)
			if not ok then
				warn("[TerrainMeshView] backdrop block", sk, "failed:", built)
				-- A block nobody draws is a 4x4-chunk hole in the map -- measured, one block of
				-- sixteen lost out of a full-map build before this existed. Hand the ground back
				-- to its chunks and let them take the slow path. Marked solo on the way, or the
				-- next sweep merges them straight back into the block that just threw.
				for _, key in superMembers(sk) do
					if not _superOf[key] then
						_solo[key] = true
						enqueueChunk(key)
					end
				end
			elseif not built then
				-- Out of Editable budget, same as a chunk: put it back, yield the frame.
				enqueueSuper(sk)
				return
			end
		end
	until (#_queue == 0 and #_superQueue == 0) or (os.clock() - t0) >= slice
end

-- sampleY(gx, gz) -> heightmap worldY at a global corner; sampleMat(gx, gz) -> material id;
-- ensureData(chunkKey) -> load or generate that chunk's real heights if they are not there
-- yet, and report whether sampleY can now answer for it exactly.
-- heightsOf(chunkKey) -> that chunk's raw height buffer, ensured, for the shore caps; optional.
function TerrainMeshView.setSource(
	sampleY: (number, number) -> number,
	sampleMat: (number, number) -> number,
	ensureData: (number) -> boolean,
	heightsOf: ((number) -> buffer?)?
)
	_sampleY = sampleY
	_sampleMat = sampleMat
	_ensureData = ensureData
	_heightsOf = heightsOf
	table.clear(_errs)
	table.clear(_caps)
end

-- Chunks the city has built on. Distance never coarsens a pinned chunk (its own flatness
-- still may -- see losslessStep).
function TerrainMeshView.pin(key: number)
	-- Pinned means distance never coarsens this chunk. It does NOT mean it needs a mesh of its
	-- own: strideAt is answered per block of tiles, so a merged block already holds members at
	-- different strides, and graded city ground is flat enough to coarsen on shape anyway.
	--
	-- This used to soloise, on the reasoning that a block "has no way to hold one member finer
	-- than the rest" -- which is simply untrue, and cost a bake per city chunk on every load.
	-- The one real risk, a block carrying so much detail that it overruns an EditableMesh, is
	-- what TRI_BUDGET is for: such a block hands its members back to the per-chunk path.
	-- A chunk only leaves its block when a brush actually touches it -- see editArea.
	_pinned[key] = true
end

-- Draw this chunk when there is room in the frame. For the background fill, which has the
-- heights but no reason to stall on the mesh: one queue and ONE budget decide how much
-- terrain work a frame does, instead of two loops each spending their own.
function TerrainMeshView.request(key: number)
	enqueue(key)
end

-- How much ground is still waiting for geometry -- loose chunks and merged blocks alike. The
-- join gate holds the loading screen until this reaches zero, so the player never enters onto
-- a map with holes in it.
function TerrainMeshView.pending(): number
	return #_queue + #_superQueue + _inFlight
end

-- The chunk's heights changed (a brush stroke, a road grade, a building pad): rebuild it,
-- and pull along any neighbour that stitched itself to the edge we just moved.
function TerrainMeshView.markDirty(key: number)
	_shapeDirty[key] = true
	_errs[key] = nil -- the shape decides the strides, so a new shape re-decides them
	_caps[key] = nil
	enqueue(key)
end

-- ONE loop in ONE coroutine -- deliberately NOT a Heartbeat connection.
--
-- Baking yields: CreateDataModelContentAsync and CreateMeshPartAsync are both async. A
-- yielding Heartbeat handler does not hold off the next frame's, so a connection starts a
-- FRESH build every frame while the previous ones are still parked mid-bake, each holding
-- a live EditableMesh. Within a second that exhausts the client's shared Editable budget
-- and every other EditableMesh in the game starts failing to allocate -- which is how this
-- first showed itself, as the glass UI breaking rather than as anything about terrain.
-- A fixed number of coroutines means a fixed number of EditableMeshes alive: PUMPS of them.
--
-- TWO, measured: the engine finishes one CreateDataModelContentAsync per frame however many
-- are waiting, so a third pump only queues behind it. What the second one buys is that the
-- next block's geometry is built while the first waits on its bake -- one pump alone spent a
-- frame on geometry, a frame on the bake and a frame waiting for the next Heartbeat, per
-- block, and at load-time frame rates that was most of the loading screen.
local _pumpGen = 0
function TerrainMeshView.start()
	if _running then return end
	_running = true
	_pumpGen += 1
	local gen = _pumpGen
	for p = 1, PUMPS do
		task.spawn(function()
			local co = coroutine.running()
			-- gen, not just _running: a stop() then start() inside one bake would otherwise leave
			-- the old pumps alive alongside the new ones.
			while _running and gen == _pumpGen do
				local dt = RunService.Heartbeat:Wait()
				_sliceEnd[co] = os.clock() + PLAY_SLICE
				local ok, err = pcall(tick, dt, p == 1)
				if not ok then warn("[TerrainMeshView] pump failed:", err) end
			end
			_sliceEnd[co] = nil
		end)
	end
end

function TerrainMeshView.stop()
	_running = false
end

-- The loading screen is down: from here rebuilds share the frame instead of taking it (see
-- breathe). reset() puts it back up for the next city.
function TerrainMeshView.setLoading(on: boolean)
	_loading = on
end

-- One tick of a sculpting stroke, over the world-space square the brush just changed.
-- Three things here are deliberate, and each one answers a separate complaint:
--
--  * IMMEDIATE, and synchronous rather than queued -- the point is that the ground moves on
--    the frame you clicked. It rebuilds through the LIVE path (see bake), which is ~9 ms
--    for a sculpted chunk against ~44 ms for the static one.
--  * The touched blocks are pinned to stride 1 FOR THE WHOLE STROKE. A levelled block is
--    drawn as a single 32-stud quad, and a smooth falloff applied to one quad is not a
--    dome, it is a tilted plate -- which is what the bumps were.
--  * Every OTHER block keeps the stride it already had, because _errs is not invalidated
--    until editEnd. Recomputing strides mid-stroke re-tessellates ground the brush never
--    touched, and the whole 256-stud plate visibly reshuffles under the cursor.
function TerrainMeshView.editArea(minX: number, minZ: number, maxX: number, maxZ: number)
	if _editBusy then return end -- a rebuild is still in flight; the next tick catches up
	local cam = Workspace.CurrentCamera
	local at = if cam then cam.CFrame.Position else Vector3.zero

	local function blockIndexOf(world: number): number
		return math.clamp(math.floor((world + HALF) / BLOCK_STUDS), 0, MAX_BLOCK)
	end
	local touched: { number } = {}
	for gbz = blockIndexOf(minZ), blockIndexOf(maxZ) do
		for gbx = blockIndexOf(minX), blockIndexOf(maxX) do
			local cx, cz = gbx // BLOCKS, gbz // BLOCKS
			local key = cz * CHUNKS + cx
			-- Sculpting ground the backdrop is drawing: it leaves the block and draws itself, or
			-- the live rebuild below has no per-chunk mesh to reshape and the stroke does nothing.
			_editChunks[key] = true
			soloise(key)
			local fine = _editFine[key]
			if not fine then
				fine = {}
				_editFine[key] = fine
			end
			local bx, bz = gbx - cx * BLOCKS, gbz - cz * BLOCKS
			local index = bz * BLOCKS + bx + 1
			local newlyPinned = fine[index] == nil
			fine[index] = true
			if table.find(touched, key) == nil then touched[#touched + 1] = key end
			-- Pinning a BORDER block changes the line the chunk next door stitched itself to,
			-- and nothing else in the stroke would go back and tell it -- that side would keep
			-- drawing an edge against a stride we no longer use and the seam opens into a crack.
			--
			-- Only when the block is NEWLY pinned. Doing it on every tick the brush sat over a
			-- border rebuilt five chunks a tick instead of one, which overran the live cap and
			-- forced a full static re-bake every tick: that was the flicker, and re-tessellating
			-- the ground that often is also what kept the surface texture reprojecting.
			if newlyPinned and (bx == 0 or bx == BLOCKS - 1 or bz == 0 or bz == BLOCKS - 1) then
				for _, d in NEIGHBOUR_DXZ do
					local nk = neighbourKey(cx, cz, d)
					if nk and _states[nk] and table.find(touched, nk) == nil then
						touched[#touched + 1] = nk
					end
				end
			end
		end
	end

	_editBusy = true
	local ok, err = pcall(function()
		for _, key in touched do
			TerrainMeshView.buildChunk(key, at, true)
			-- Including the neighbours dragged in above: whatever went live has to be in the
			-- set editEnd bakes back down, or its EditableMesh outlives the stroke.
			_editChunks[key] = true
			local seen = table.find(_liveOrder, key)
			if seen then table.remove(_liveOrder, seen) end
			table.insert(_liveOrder, key)
		end
		-- Anything pushed past the cap goes back to static now. It keeps its pinned-fine
		-- blocks, so this costs a bake but changes nothing on screen.
		while #_liveOrder > MAX_LIVE do
			local old = table.remove(_liveOrder, 1) :: number
			local st = _states[old]
			if st and st.em then TerrainMeshView.buildChunk(old, at, false) end
		end
	end)
	_editBusy = false
	if not ok then warn("[TerrainMeshView] live edit failed:", err) end
end

-- The stroke finished. Let every chunk it touched re-decide its strides from its new shape,
-- and rebuild it through the normal queue -- which bakes it back to STATIC content and frees
-- the EditableMesh the live path had to keep alive.
function TerrainMeshView.editEnd()
	if next(_editChunks) == nil then return end
	for key in _editChunks do
		_errs[key] = nil
		_caps[key] = nil
		TerrainMeshView.markDirty(key)
	end
	table.clear(_editChunks)
	table.clear(_editFine)
	table.clear(_liveOrder)
end

-- Is this chunk under an active stroke? The server's patch for it is already on screen --
-- the client predicted it -- so rebuilding on arrival would only re-tessellate the plate
-- mid-drag for no visible change.
function TerrainMeshView.isEditing(key: number): boolean
	return _editChunks[key] == true
end

-- X-ray the ground so what sits BELOW it -- water mains, sewers, tunnels, a metro box --
-- reads from a normal camera. Only possible because the ground is a hollow shell.
function TerrainMeshView.setUnderground(on: boolean)
	if _underground == on then return end
	_underground = on
	local a = if on then ALPHA else 0
	for _, st in _states do
		local p = st.part
		if p then p.Transparency = a end
	end
	for _, s in _supers do
		local p = s.part
		if p then p.Transparency = a end
	end
end

function TerrainMeshView.isUnderground(): boolean
	return _underground
end

-- Tear the whole ground down. Called before a new city loads, so a stale map is never left
-- standing under the new one.
function TerrainMeshView.reset()
	TerrainMeshView.stop()
	_epoch += 1
	_loading = true
	for _, st in _states do
		if st.part then (st.part :: MeshPart):Destroy() end
		if st.em then (st.em :: EditableMesh):Destroy() end
	end
	table.clear(_states)
	table.clear(_editChunks)
	table.clear(_editFine)
	table.clear(_liveOrder)
	table.clear(_pinned)
	table.clear(_queue)
	table.clear(_queued)
	table.clear(_shapeDirty)
	table.clear(_errs)
	table.clear(_drawn)
	table.clear(_caps)
	for _, s in _supers do
		if s.part then (s.part :: MeshPart):Destroy() end
	end
	table.clear(_supers)
	table.clear(_superOf)
	table.clear(_superQueue)
	table.clear(_superQueued)
	table.clear(_solo)
	_accum = 0
	-- Clear through folder(), not the cached handle: a rejoin (or a reload in a test
	-- harness) starts with empty state but the previous _Ground still standing in Workspace,
	-- and iterating _states would walk straight past it and leave two grounds overlaid.
	folder():ClearAllChildren()
end

return TerrainMeshView
