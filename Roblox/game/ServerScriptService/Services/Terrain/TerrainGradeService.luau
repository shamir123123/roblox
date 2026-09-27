--!strict
-- TerrainGradeService
-- "Terrain follows road": when a road segment is placed, grades the terrain under its
-- footprint to the road's CROSS-SECTION (bedSurfaceY -- land at natural ground, the whole
-- road standing on top of it), then blends an 8-stud shoulder out to natural ground. Reversible per-segment (refcounted) so deleting a road restores
-- the terrain it graded within the session. Pure server; writes through the
-- authoritative Heightmap owned by TerrainDataService.
--
-- Persistence saves the natural heightmap underneath these overlays, so roads can
-- be deleted after a reload and still release terrain back to its pre-road shape.

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local RoadConstants    = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog  = require(ReplicatedStorage.Road.RoadTypeCatalog)
local BezierUtil       = require(ReplicatedStorage.Road.BezierUtil)
local TerrainConstants = require(ReplicatedStorage.Terrain.TerrainConstants)
local RoadCrossSection = require(ReplicatedStorage.Terrain.RoadCrossSection)
local TerrainDataService = require(ServerScriptService.Services.Terrain.TerrainDataService)

local TerrainGradeService = {}

-- A road grade is deliberately local. The former 20-48 stud shoulder reached
-- through the sidewalk and into adjacent lots, where it fought building foundations.
local SHOULDER_MIN      = 4.0
-- A bank is only as smooth as the number of CORNERS it spans: at 4 studs apart, 10 studs of
-- shoulder is two and a half steps, which reads as a staircase rather than a slope. 16 gives
-- four, which reads as an angle. Still deliberately local -- the 20-48 stud shoulder this
-- replaced reached into lots and fought building foundations.
local SHOULDER_MAX      = 16.0
local MAX_GRADE         = 0.75
-- The visible terrain is raw height + RENDER_BULGE, so every height bedSurfaceY returns
-- is a VISIBLE one and the writer subtracts this to get the raw value.
local RENDER_BULGE      = TerrainConstants.RENDER_BULGE
-- How deep the hidden bed sits under the asphalt slab. Not a visible lip: the land beside
-- a road is the footway top, not this (see bedSurfaceY).
local ROAD_EDGE_HEIGHT  = RoadConstants.GROUND_ROAD_EDGE_HEIGHT
local WALK_HEIGHT       = RoadConstants.SIDEWALK_HEIGHT
-- How far past the asphalt edge the bed stops digging and the ground comes back up to the
-- verge. Half a voxel, so the step hides under the kerb slab. It no longer has to clear a
-- junction fillet's reach: the verge itself is below the asphalt now, so ground rising through
-- a junction fill is not a case that exists any more.
local KERB_STEP_INSET   = TerrainConstants.SAMPLE_SPACING * 0.5
-- Fill cap applies ONLY under open water now: a ground road crossing the sea stays an
-- auto-bridge instead of raising an earth causeway. On land, fill is uncapped so a dip
-- under the slab builds an embankment and the road never hovers (CS-style).
local GROUND_MAX_FILL   = 2.5
local SEA_Y             = TerrainConstants.SEA_Y
local FLAG_LOCKED       = TerrainConstants.Flag.LOCKED
local FLAG_ROAD_GRADED  = TerrainConstants.Flag.ROAD_GRADED
local CORNERS_PER_AXIS  = TerrainConstants.CORNERS_PER_AXIS
local MAX_CORNER        = CORNERS_PER_AXIS - 1
local cornerToWorld     = TerrainConstants.cornerToWorld
local worldToCorner     = TerrainConstants.worldToCorner
local rawToWorldY       = TerrainConstants.rawToWorldY
local worldYToRaw       = TerrainConstants.worldYToRaw

-- Deliberately elevated roads more than this far above natural ground span as
-- bridges instead of pulling terrain up into a berm. Ground roads do not use
-- this skip; they grade a narrow bed so they sit on the terrain.
local SPAN_SKIP = 6

-- Tunnel depth tiers (CS2): a Tunnel-mode road transitions per corner with depth.
--   depth < CUT_WALL_MIN_DEPTH (3 m): SUNKEN -- ground-style soft blend, no walls.
--   up to TUNNEL_COVER_DEPTH  (8 m): OPEN CUT -- tight bed ending at the wall's
--     back face, NO shoulder (the bed jumps to natural in one corner span, as
--     vertical as the voxel grid carves; the retaining wall covers the bevel),
--     grass-stamped and water-sealed.
--   deeper: COVERED TUNNEL -- terrain stays untouched on top; the road runs buried.
-- Thresholds mirrored by the wall band in RoadSceneRenderer.addTunnelWalls.
-- Shared with the mode decision on purpose: "deep enough that the ground is CUT rather than
-- dipped" is the same judgement whether it decides to draw walls or to call the span a
-- tunnel. Two numbers meaning one thing is how they drift apart.
local CUT_WALL_MIN_DEPTH = RoadCrossSection.tunnelMinDepth
local TUNNEL_COVER_DEPTH = 16
-- Corners past the cut bed (studs) that still get the grass stamp + water seal, so
-- the lip corner never auto-paints rock and boundary voxel columns never flood.
local CUT_RING = 8

-- All corner bookkeeping (refcounts, original height/flags, overlap merging)
-- lives in the shared overlay ledger so road grades and building pads can
-- claim the same corners without clobbering each other.
local function ledger()
	return TerrainDataService.getOverlayLedger()
end

-- The cross-section itself lives in ReplicatedStorage.Terrain.RoadCrossSection, because the
-- CLIENT needs the same shape: it predicts the grade the moment a road is placed, and the
-- road modes ask what the ground would do before choosing to bridge, bore or sit down. Two
-- copies would drift, and that drift is precisely the class of bug this took many passes to
-- clear. Re-exported here so existing callers and the spec keep their entry points.
local bedSurfaceY = RoadCrossSection.bedSurfaceY
local footprintHalf = RoadCrossSection.footprintHalf
local KERB_STEP_INSET = RoadCrossSection.kerbStepInset

TerrainGradeService.bedSurfaceY = bedSurfaceY
TerrainGradeService.footprintHalf = footprintHalf
-- How far the flat, locked region reaches on a HARD CUT. Never tighter than the ordinary
-- footprint, and that floor is the entire point:
--
-- TUNNEL_WALL_THICKNESS is 1 stud, sized for a wall. Terrain corners are 4 studs apart. So a
-- lock ending 1 stud past the pavement means the very NEXT corner outward already belongs to
-- the rising shoulder, and the mesh ramps from under the slab straight up over the kerb --
-- grass laterally on top of the pavement, in 4-stud steps.
--
-- That is why no amount of height clearance ever fixed this: it is not two surfaces fighting
-- over a depth, it is the flat band being narrower than the lattice can represent. The verge
-- needs a whole corner outside the pavement before anything is allowed to climb.
local function cutFootprintHalf(width: number): number
	return math.max(
		width * 0.5 + RoadConstants.SIDEWALK_WIDTH + RoadConstants.TUNNEL_WALL_THICKNESS,
		footprintHalf(width)
	)
end
TerrainGradeService.cutFootprintHalf = cutFootprintHalf
TerrainGradeService.kerbStepInset = KERB_STEP_INSET
TerrainGradeService.vergeSink = RoadCrossSection.vergeSink

-- Sample the segment centerline densely enough (~2-stud spacing) that nearest-point
-- distance is accurate to well under one terrain corner (4 studs). Returns the
-- points plus their world-space X/Z bounds.
local function sampleCenterline(seg: any): ({ Vector3 }, number, number, number, number)
	local length = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, RoadConstants.SAMPLES_PER_SEGMENT)
	local n = math.clamp(math.floor(length / 2), 8, 256)
	local pts = table.create(n + 1)
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for i = 0, n do
		local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, i / n)
		pts[i + 1] = p
		if p.X < minX then minX = p.X end
		if p.X > maxX then maxX = p.X end
		if p.Z < minZ then minZ = p.Z end
		if p.Z > maxZ then maxZ = p.Z end
	end
	return pts, minX, maxX, minZ, maxZ
end

-- Flat (X/Z) distance from a world point to the nearest centerline sample, plus
-- that sample's Y (the road centerline height there).
local function nearestOnCenterline(pts: { Vector3 }, wx: number, wz: number): (number, number)
	local bestD2 = math.huge
	local bestY = 0
	for _, p in pts do
		local dx = p.X - wx
		local dz = p.Z - wz
		local d2 = dx * dx + dz * dz
		if d2 < bestD2 then
			bestD2 = d2
			bestY = p.Y
		end
	end
	return math.sqrt(bestD2), bestY
end

-- Grade the terrain along a road centerline `pts` (world-space samples), flattening
-- a footprint of the given road `width` down to the slab underside and blending out
-- to natural ground. `ownerKey` namespaces the grade for refcounted restore (segment
-- ids are positive; connectors use a negative space). Idempotent per owner key.
local _ownerGeneration: { [string]: number } = {}
-- Seconds of work between frame yields. The old fixed counters (8192 candidate checks /
-- 512 writes) burned a WHOLE FRAME every few milliseconds of maths: a 200-stud road spent
-- ~15 frames (~250 ms) inside a job worth a few ms of CPU, and the player waits on all of
-- it -- RoadReplicationService only answers PlaceRoadResult once placeFromRequest returns,
-- and grading runs inside it. Budget on elapsed time instead: short grades never yield at
-- all, long ones still hand the server a frame when they have actually earned one.
local FRAME_BUDGET = 0.008
-- Corners this far past the locked bed still get the dense (every-sample) stamp; past that
-- the shoulder ring is walked at SHOULDER_STRIDE. See the two-pass note in gradeCenterline.
local BED_ACCURATE_MARGIN = 6
local SHOULDER_STRIDE = 4
local WRITE_YIELD_CHECK_EVERY = 256

-- materialId (optional): a terrain-path road (gravel/dirt) paints its footprint corners with
-- this TerrainConstants.Material id as it grades. setMaterial marks chunks dirty so the
-- renderer repaints. ponytail: the paint is NOT tracked for restore -- deleting the path
-- releases its graded HEIGHT but leaves the material, same as the manual paint tool (paint is
-- permanent). Upgrade path: stash the corner's prior material in the overlay ledger if
-- auto-restore on bulldoze is wanted.
-- Every road grade -- segment or corner connector -- claims corners under ONE kind.
--
-- They used to be two ("seg:" / "conn:"), and that is what put grass on the carriageway:
-- lockedByOtherKind made a connector's locked corner read as somebody else's to the segment
-- running through it, so the segment SKIPPED its own carriageway there and the corner kept
-- the connector's bed -- which is higher, because the connector arc is lifted clear of the
-- slab. Measured on the saved city: 696 corners across 33 of 199 segments, every one of them
-- owned by a conn: and nothing else. Whichever of the two graded first won, which is why it
-- looked like the grade "sometimes forgets".
--
-- Nothing is lost by merging them: the ledger resolves overlapping road claims with min(),
-- so the lower bed always wins and neither can bury the other. The guard still does its real
-- job, which is keeping a road off a building's locked foundation ("pad:").
local ROAD_KIND = "road:"

local function gradeCenterline(ownerKey: string, pts: { Vector3 }, _minX: number, _maxX: number, _minZ: number, _maxZ: number, width: number, spanAsBridge: boolean, materialId: number?, cutWalls: boolean?, walkWidth: number?)
	local led = ledger()
	if not led or not led:beginOwner(ownerKey) then return end -- already graded under this key

	-- Terrain-path paint: the bed corners within ~half-width get the road's material. A little
	-- past the carriageway edge so the painted strip reads as the path, not the whole graded bed.
	local hm = if materialId or cutWalls then TerrainDataService.getHeightmap() else nil
	local paintHalf = width * 0.5 + 2

	local generation = (_ownerGeneration[ownerKey] or 0) + 1
	_ownerGeneration[ownerKey] = generation

	-- Land corners this grade pushes below sea level; sealed against the water field at
	-- the end so the cut never floods. NOT tunnel-only: every road seats its bed
	-- SURFACE_CLEARANCE under the slab, so any land within that of sea level is dug below
	-- it. On a lake shore there is always such a band, which is why an ordinary ground road
	-- along one flooded every time -- the seal was gated on cutWalls (Tunnel mode).
	local dryKeys: { number } = {}

	-- Ground roads build a narrow, clamped seat: shave/fill only a small amount so
	-- the slab reads as grounded without turning nearby hills into vertical shelves.
	-- Deliberately elevated roads keep bridge spans open. Tunnel cuts keep the bed
	-- tight: it ends at the retaining wall line, not a sidewalk + margin past it.
	local lockHalf  = footprintHalf(width)
	-- Open-cut tier: the locked bed ends at the retaining wall's back face.
	local cutLockHalf = cutFootprintHalf(width)
	local reach     = lockHalf + SHOULDER_MAX
	local halfThick = RoadConstants.ROAD_THICKNESS * 0.5
	local walk      = walkWidth or RoadConstants.SIDEWALK_WIDTH

	-- Rasterize a corridor around the sampled centerline. The former implementation
	-- scanned the curve's whole axis-aligned bounding rectangle and then searched every
	-- centerline sample for every corner. That becomes enormous for long diagonal roads.
	-- This visits only corners that can actually fall within the grading shoulder.
	--
	-- Two passes, both stamping "distance to the nearest centerline sample" into the same map
	-- (nearest wins, so a later coarse pass can never beat an earlier exact one):
	--   bed      -- EVERY sample, out to the locked bed plus a small margin. The bed's height
	--               is read from the nearest sample's Y, so it keeps full ~2-stud accuracy.
	--   shoulder -- every SHOULDER_STRIDE-th sample, out to the full shoulder reach. The
	--               shoulder is a smoothstep blend to natural ground, so a stud or two of slack
	--               there is invisible -- whereas stamping a ~67-stud disc around every 2-stud
	--               sample recomputed each corner dozens of times over.
	local bestDistanceSq: { [number]: number } = {}
	local bestCenterY: { [number]: number } = {}
	local budgetUntil = os.clock() + FRAME_BUDGET
	local superseded = false

	-- False when a newer grade claimed this owner key mid-pass; the caller must bail.
	local function stampPoint(p: Vector3, stampReach: number, stampReachSq: number): boolean
		local gxMin = math.clamp(math.floor(worldToCorner(p.X - stampReach)), 0, MAX_CORNER)
		local gxMax = math.clamp(math.ceil(worldToCorner(p.X + stampReach)), 0, MAX_CORNER)
		local gzMin = math.clamp(math.floor(worldToCorner(p.Z - stampReach)), 0, MAX_CORNER)
		local gzMax = math.clamp(math.ceil(worldToCorner(p.Z + stampReach)), 0, MAX_CORNER)
		local px, py, pz = p.X, p.Y, p.Z
		for gz = gzMin, gzMax do
			local dz = pz - cornerToWorld(gz)
			local dz2 = dz * dz
			local rowBase = gz * CORNERS_PER_AXIS
			for gx = gxMin, gxMax do
				local dx = px - cornerToWorld(gx)
				local d2 = dx * dx + dz2
				if d2 <= stampReachSq then
					local key = rowBase + gx
					local prior = bestDistanceSq[key]
					if not prior or d2 < prior then
						bestDistanceSq[key] = d2
						bestCenterY[key] = py
					end
				end
			end
			-- Budget checked once per corner ROW, so the clock read is amortised over ~30 corners.
			if os.clock() >= budgetUntil then
				task.wait()
				if _ownerGeneration[ownerKey] ~= generation then return false end
				budgetUntil = os.clock() + FRAME_BUDGET
			end
		end
		return true
	end

	-- Walk pts at `stride`, always including the LAST sample so a road's end cap never ends up
	-- short of its blend when the stride does not divide the sample count.
	local function stampPass(stride: number, stampReach: number)
		local stampReachSq = stampReach * stampReach
		local n = #pts
		local i = 1
		while i <= n do
			if not stampPoint(pts[i], stampReach, stampReachSq) then
				superseded = true
				return
			end
			if i == n then break end
			i = math.min(i + stride, n)
		end
	end

	local bedReach = math.min(reach, math.max(lockHalf, cutLockHalf) + BED_ACCURATE_MARGIN)
	stampPass(1, bedReach)
	if not superseded and reach > bedReach then
		stampPass(if #pts > SHOULDER_STRIDE * 4 then SHOULDER_STRIDE else 1, reach)
	end
	if superseded then return end

	local writes = 0
	for key, d2 in bestDistanceSq do
		local gz = math.floor(key / CORNERS_PER_AXIS)
		local gx = key - gz * CORNERS_PER_AXIS
		local d = math.sqrt(d2)
		local centerY = bestCenterY[key]
		if led:lockedByOtherKind(gx, gz, ROAD_KIND) then
			continue -- a building's locked foundation owns this corner
		end

		local naturalY = rawToWorldY(led:naturalRaw(gx, gz))
		local shouldSpan = spanAsBridge and centerY - naturalY > SPAN_SKIP
		-- Tunnel depth tier at this corner (see constants above).
		local cutDepth = if cutWalls then naturalY - centerY else -math.huge
		local covered = cutWalls and cutDepth >= TUNNEL_COVER_DEPTH
		local hardCut = cutWalls and not covered and cutDepth >= CUT_WALL_MIN_DEPTH
		if not shouldSpan and not covered then
			-- A CROSS-SECTION, not one flat shelf: the old single target dug the whole
			-- footprint -- carriageway, footway and margin alike -- to one level 0.8 studs
			-- under the asphalt, standing the entire road assembly on a 0.4 m plinth.
			local roadTopY = centerY + halfThick
			local targetY = bedSurfaceY(roadTopY, d, width, walk) - RENDER_BULGE
			local gradedY
			if spanAsBridge then
				gradedY = math.min(naturalY, targetY)
			elseif naturalY < SEA_Y then
				-- Seabed: small fill cap keeps water crossings open (auto-bridge), no causeway.
				-- ponytail: player-drained pits below sea level also keep the cap; route through
				-- WaterField.isDryAt if embankments in drained land matter.
				gradedY = math.min(targetY, naturalY + GROUND_MAX_FILL)
			else
				-- Cut AND fill uncapped on land: the bed always reaches the slab underside, so
				-- hills never poke through and dips fill into an embankment instead of leaving
				-- the road hovering. The grade-limited shoulder below banks both into the ground.
				gradedY = targetY
			end
			local myLock = if hardCut then cutLockHalf else lockHalf
			if d <= myLock then
				led:write(ownerKey, gx, gz, worldYToRaw(gradedY), FLAG_LOCKED + FLAG_ROAD_GRADED)
				-- +2 margin: boundary voxel columns interpolate between corners, so a
				-- written corner just above sea can still front a below-sea column.
				if gradedY < SEA_Y + 2 and naturalY >= SEA_Y then
					dryKeys[#dryKeys + 1] = key
				end
			elseif not hardCut and math.abs(gradedY - naturalY) > 1e-3 then
				-- Shoulder widens with the height it must absorb so embankment/cut sides
				-- never exceed MAX_GRADE (mirrors TerrainPadService's shoulder). The hard
				-- open cut has NO shoulder: its bed jumps to natural in one corner span
				-- and the retaining wall covers the voxel bevel.
				local shoulder = math.clamp(math.abs(gradedY - naturalY) / MAX_GRADE, SHOULDER_MIN, SHOULDER_MAX)
				if d <= myLock + shoulder then
					local t = (d - myLock) / shoulder
					local s = t * t * (3 - 2 * t)
					local newY = gradedY + (naturalY - gradedY) * s
					led:write(ownerKey, gx, gz, worldYToRaw(newY), FLAG_ROAD_GRADED)
					if newY < SEA_Y + 2 and naturalY >= SEA_Y then
						dryKeys[#dryKeys + 1] = key
					end
				end
			end
			if materialId and hm and d <= paintHalf then
				hm:setMaterial(gx, gz, materialId :: number)
			elseif hardCut and hm and naturalY >= SEA_Y and d <= cutLockHalf + CUT_RING then
				-- Open-cut corridor + lip ring: LEAFY = the base map surface, so the
				-- steep face never auto-paints rock/sand or sprouts grass blades
				-- (that's GRASS). The same ring is sealed dry: boundary columns round
				-- to these corners, so under-sealing let water paint at the trench lip.
				-- Same no-restore rule as the terrain-path paint above.
				hm:setMaterial(gx, gz, TerrainConstants.Material.LEAFY)
				dryKeys[#dryKeys + 1] = key
			end
		end

		writes += 1
		if writes % WRITE_YIELD_CHECK_EVERY == 0 and os.clock() >= budgetUntil then
			task.wait()
			if _ownerGeneration[ownerKey] ~= generation then return end
			budgetUntil = os.clock() + FRAME_BUDGET
		end
	end

	-- Seal the trench against the water field: dug-below-sea land corners are walled
	-- concrete, never open water. Chunks repainted mid-grade may have flooded before
	-- the seal landed, so re-dirty them (plus border neighbours, whose paint shares
	-- these corners). ponytail: seals are not released on ungrade -- a dry flag on
	-- restored above-sea ground is inert, and a later brush stroke re-classifies it.
	if #dryKeys > 0 then
		TerrainDataService.markDryCornerKeys(dryKeys)
		local hm = TerrainDataService.getHeightmap()
		local chunkTiles = TerrainConstants.CHUNK_TILES
		local seen: { [number]: boolean } = {}
		for _, k in dryKeys do
			local gz = k // CORNERS_PER_AXIS
			local gx = k % CORNERS_PER_AXIS
			for dz = -1, 1 do
				for dx = -1, 1 do
					local cx = math.floor(math.clamp(gx + dx, 0, MAX_CORNER) / chunkTiles)
					local cz = math.floor(math.clamp(gz + dz, 0, MAX_CORNER) / chunkTiles)
					local ck = cz * 4096 + cx
					if not seen[ck] then
						seen[ck] = true
						hm:markRenderDirty(cx, cz)
					end
				end
			end
		end
	end
end

-- Grade the terrain under one segment. Idempotent per segment id.
function TerrainGradeService.gradeSegment(seg: any)
	if seg.isArc then return end
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	local pts, minX, maxX, minZ, maxZ = sampleCenterline(seg)
	gradeCenterline(ROAD_KIND .. "seg:" .. seg.id, pts, minX, maxX, minZ, maxZ, spec.width, seg.vMode == "Elevated", spec.terrainMaterialId, seg.vMode == "Tunnel", (if spec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH))
end

-- Grade the terrain under a render-only corner connector (the rounded road arc that
-- fills a 2-arm bend). The connector is NOT a network segment, so without this its
-- footprint went ungraded -- on a steep bend the connector ramps down the slope while
-- the ground stays at the node height, poking natural terrain up through the road.
-- Keyed in a negative id space so it refcounts/restores independently of segments.
function TerrainGradeService.gradeConnector(nodeId: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, width: number, cutWalls: boolean?, walkWidth: number?)
	assert(type(nodeId) == "number", "[TerrainGradeService] gradeConnector expects a numeric nodeId")
	local STEPS = 12
	local pts = table.create(STEPS + 1)
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for i = 0, STEPS do
		local p = BezierUtil.point(p0, p1, p2, p3, i / STEPS)
		pts[i + 1] = p
		if p.X < minX then minX = p.X end
		if p.X > maxX then maxX = p.X end
		if p.Z < minZ then minZ = p.Z end
		if p.Z > maxZ then maxZ = p.Z end
	end
	-- A rendered corner is still a ground road. Treating it as a bridge only cut
	-- high terrain and left grass in any low seam where two roads joined.
	gradeCenterline(ROAD_KIND .. "conn:" .. nodeId, pts, minX, maxX, minZ, maxZ, width, false, nil, cutWalls, walkWidth)
end

function TerrainGradeService.ungradeConnector(nodeId: number)
	assert(type(nodeId) == "number", "[TerrainGradeService] ungradeConnector expects a numeric nodeId")
	local ownerKey = ROAD_KIND .. "conn:" .. nodeId
	_ownerGeneration[ownerKey] = (_ownerGeneration[ownerKey] or 0) + 1
	local led = ledger()
	if led then
		led:release(ownerKey)
	end
end

-- Release one segment's grade. Corners re-merge from surviving owners, or drop
-- back to original ground + flags once nothing owns them.
function TerrainGradeService.ungradeSegmentId(segId: number)
	local ownerKey = ROAD_KIND .. "seg:" .. segId
	_ownerGeneration[ownerKey] = (_ownerGeneration[ownerKey] or 0) + 1
	local led = ledger()
	if led then
		led:release(ownerKey)
	end
end

function TerrainGradeService.ungradeSegment(seg: any)
	TerrainGradeService.ungradeSegmentId(seg.id)
end

return TerrainGradeService
