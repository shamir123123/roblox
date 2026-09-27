--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local BezierUtil = require(ReplicatedStorage.Road.BezierUtil)
local RoadNetwork = require(ReplicatedStorage.Road.RoadNetwork)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadRules = require(ReplicatedStorage.Road.RoadRules)
local RoadNavigationGraph = require(ReplicatedStorage.Road.RoadNavigationGraph)
local RoadVerticalProfile = require(ReplicatedStorage.Road.RoadVerticalProfile)
local RoadMoveGeometry = require(ReplicatedStorage.Road.RoadMoveGeometry)
local ApproachBend = require(ReplicatedStorage.Road.ApproachBend)
local RoadProximity = require(ReplicatedStorage.Road.RoadProximity)
local Types = require(ReplicatedStorage.Road.RoadTypes)
local Quant = require(ReplicatedStorage.Shared.Quant)
local RoadSceneRenderer = require(ReplicatedStorage.Road.RoadSceneRenderer)
local RoadHistoryService = require(script.Parent.RoadHistoryService)
local RoadReplicationService = require(script.Parent.RoadReplicationService)
local RoadTurnPermissionStore = require(script.Parent.RoadTurnPermissionStore)
local RoadSerializer = require(script.Parent.RoadSerializer)
local AddressBook = require(ReplicatedStorage.City.AddressBook)
local TerrainGradeService = require(ServerScriptService.Services.Terrain.TerrainGradeService)
local TerrainDataService = require(ServerScriptService.Services.Terrain.TerrainDataService)
local TerrainConstants = require(ReplicatedStorage.Terrain.TerrainConstants)
local WaterField = require(ReplicatedStorage.Terrain.WaterField)

-- Road<->terrain mode. When grading is enabled (default), placing a road flattens
-- the terrain under it ("terrain follows road"). Toggle off for "road follows
-- terrain": the road keeps its placed height and terrain is left natural.
-- Flip via workspace:SetAttribute("RoadGradeTerrain", false).
local function terrainGradeEnabled(): boolean
	return workspace:GetAttribute("RoadGradeTerrain") ~= false
end

local RoadService = {}

local _network: RoadNetwork.RoadNetwork
local _navGraph: any
-- Trains route here: rail-only twin of _navGraph (same class, rail segment filter).
local _railGraph: any
local _economyService: any = nil  -- injected; nil = free placement (no economy wired)
-- Intersection turn/connection permissions + lane-change rules live in RoadTurnPermissionStore.

-- A free Elevated endpoint more than this far above the heightmap keeps its
-- client-sent height as a deliberate bridge deck. Ground requests always snap
-- to the authoritative heightmap, so voxel/cursor mismatch cannot accidentally
-- turn a ground road into a bridge. Matches SPAN_SKIP in TerrainGradeService.
local ROAD_ELEVATION_KEEP = 6

-- Ground height a GROUND road rests on. Open water is not a road bed: the deck rides
-- at shoreline height across it (an automatic bridge -- pillars/guardrails come from
-- the renderer's existing height checks). Player-drained dry pits still count as ground.
local WATER_DECK_SURFACE = TerrainConstants.SEA_Y + TerrainConstants.RENDER_BULGE
local function groundSurfaceY(x: number, z: number): number
	local y = TerrainDataService.getSurfaceY(x, z)
	if y < WATER_DECK_SURFACE and not WaterField.isDryAt(x, z) then
		return WATER_DECK_SURFACE
	end
	return y
end

-- RoadRenderer receives slab-centre height. Keep a small visible road profile
-- while embedding the rest of the slab in the ground.
local function groundRoadCenterY(x: number, z: number): number
	return groundSurfaceY(x, z) + RoadConstants.GROUND_ROAD_TOP_LIFT - RoadConstants.ROAD_THICKNESS * 0.5
end

local _rebuildPending = false
local _pendingNavLaneSyncAll = false
local _pendingNavLaneSyncNodes: { [Types.NodeId]: boolean } = {}


local _roadTypeCache: { [string]: any } = {}
local function getCachedRoadSpec(roadType: string): any
	local cached = _roadTypeCache[roadType]
	if cached then return cached end
	local spec = RoadTypeCatalog.getOrDefault(roadType)
	_roadTypeCache[roadType] = spec
	return spec
end



-- Segments that need their nav-graph edges rebuilt on the next deferred tick.
local _pendingNavDirtySegs: { [Types.SegmentId]: boolean } = {}
local _pendingNavRemovedSegs: { [Types.SegmentId]: boolean } = {}
-- When true, do a full Rebuild() instead of incremental (e.g. after a turn-perm change
-- that affects all intersections, or an explicit force-rebuild request).
local _navForceFullRebuild = false

-- Runs the pending nav rebuild immediately. Idempotent: the deferred task and
-- the render path can both call it; whoever runs first does the work.
local function flushNavRebuild()
	if not _rebuildPending then return end
	_rebuildPending = false
	local syncAll = _pendingNavLaneSyncAll
	local syncNodes = _pendingNavLaneSyncNodes
	_pendingNavLaneSyncAll = false
	_pendingNavLaneSyncNodes = {}

	local doFull = _navForceFullRebuild
	local dirtySegs = _pendingNavDirtySegs
	local removedSegs = _pendingNavRemovedSegs
	_navForceFullRebuild = false
	_pendingNavDirtySegs = {}
	_pendingNavRemovedSegs = {}

	if _navGraph then
		if doFull or (next(dirtySegs) == nil and next(removedSegs) == nil) then
			-- Full rebuild only when explicitly requested or no segment delta is available
			_navGraph:Rebuild(_network, RoadTurnPermissionStore.permissions(), RoadTurnPermissionStore.laneChangeRules())
		else
			-- Incremental: only re-sample and re-link the changed segments
			_navGraph:RebuildSegments(_network, dirtySegs, removedSegs, RoadTurnPermissionStore.permissions(), RoadTurnPermissionStore.laneChangeRules())
		end
		-- Rail graph rides the same dirty sets; no turn perms / lane-change rules on rail.
		if _railGraph then
			if doFull or (next(dirtySegs) == nil and next(removedSegs) == nil) then
				_railGraph:Rebuild(_network)
			else
				_railGraph:RebuildSegments(_network, dirtySegs, removedSegs)
			end
		end
		RoadReplicationService.broadcastLaneChanges()
		if syncAll then
			RoadReplicationService.broadcastLanePaths()
		else
			for changedNodeId in syncNodes do
				RoadReplicationService.broadcastLanePaths(nil, changedNodeId)
			end
		end

		-- Approach furniture -- the lane arrows and the stop line's lane span -- is read off the
		-- nav graph AT RENDER TIME, and rendering runs before this deferred rebuild. A just-placed
		-- arm therefore asked an empty graph for its movements and painted its crosswalk with no
		-- arrows and no stop line, and nothing re-rendered it afterwards. Redraw the arms now that
		-- their edges exist; only arms at an intersection read the graph, so the rest are skipped.
		-- A turn-permission edit dirties no geometry, so dirtySegs is empty and the repaint
		-- below did nothing -- the painted lane arrows kept the old movements. The arms of an
		-- edited node are exactly what has to re-read the graph.
		for changedNodeId in syncNodes do
			local editedNode = _network:getNodes()[changedNodeId]
			for _, sid in (editedNode and editedNode.segments or {}) do
				dirtySegs[sid] = true
			end
		end

		for sid in dirtySegs do
			local s = _network:getSegment(sid)
			if s and not s.isArc
				and (_network:getNodeKind(s.startNode) == "intersection"
					or _network:getNodeKind(s.endNode) == "intersection")
			then
				local ok, err = pcall(RoadSceneRenderer.renderSegment, s)
				if not ok then
					warn(`[RoadService] approach re-render failed for segment {sid}: {err}`)
				end
			end
		end

		-- Roundabout splitter islands are shaped by the lanes, so the centres go last, off the
		-- graph just rebuilt: the ones these segments touch, or all of them after a full rebuild.
		local fullRebuild = doFull or (next(dirtySegs) == nil and next(removedSegs) == nil)
		local ok, err = pcall(RoadSceneRenderer.refreshRoundaboutsFor, if fullRebuild then nil else dirtySegs)
		if not ok then
			warn(`[RoadService] roundabout centre refresh failed: {err}`)
		end
	end
end

local function scheduleNavRebuild(nodeId: Types.NodeId?, syncAllLanePaths: boolean?, forceFull: boolean?)
	if syncAllLanePaths then
		_pendingNavLaneSyncAll = true
	elseif nodeId then
		_pendingNavLaneSyncNodes[nodeId] = true
	end
	if forceFull then
		_navForceFullRebuild = true
	end
	if _rebuildPending then return end
	_rebuildPending = true
	task.defer(flushNavRebuild)
end
local _topologyListeners: { (any?) -> () } = {}
local _segmentRemovingListeners: { (Types.SegmentId) -> () } = {}

-- Injected by Bootstrap (BuildingService.demolishUnderPavement). Clears buildings a newly
-- placed road/roundabout is laid over. Kept as an injected callback so RoadService never
-- requires the building/zone layer (which already depends on RoadService).
local _buildingClearance: any = nil
-- Injected by Bootstrap (NaturePlaceService.clearUnderPavement). Clears the planted props
-- -- trees, rocks, shapes -- a newly placed road/roundabout is laid over, off the SAME
-- RoadProximity rule that refuses planting one on a carriageway. Separate from the
-- building clearance because the two layers are cleared to different reaches: a building
-- goes when the pavement corridor covers its centre, a tree only when its own footprint
-- overlaps the asphalt.
local _natureClearance: any = nil
-- Development Tree gate (ProgressionService.isRoadAllowed), injected by Bootstrap via
-- setUnlockCheck. Declared up here because placeFromRequest reads it far above the
-- setter. No check injected (tests, tooling) means nothing is gated.
local _isRoadAllowed: ((string) -> boolean)? = nil

local function isRoadUnlocked(roadType: string): boolean
	local check = _isRoadAllowed
	return check == nil or check(roadType) == true
end

-- Territory gate (TerritoryService.isSpanAllowed), injected by Bootstrap via
-- setTerritoryCheck. The unlock check above answers "is this road type available"; this
-- answers "is this GROUND yours". No check injected (tests, tooling) means nothing is gated.
local _territoryCheck: (({ Vector3 }) -> boolean)? = nil

-- A road is a curve, not a point: it is judged along its whole length, or a player could
-- anchor inside their own land and drag the far end clean across the map.
local TERRITORY_SAMPLES = 16
local function isOnOwnedLand(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): boolean
	local check = _territoryCheck
	if check == nil then return true end
	local pts = table.create(TERRITORY_SAMPLES + 1)
	for i = 0, TERRITORY_SAMPLES do
		pts[i + 1] = BezierUtil.point(p0, p1, p2, p3, i / TERRITORY_SAMPLES)
	end
	return check(pts) == true
end
-- Shared with the client, which previews this exact clearance as a white highlight on the
-- buildings the ghost is about to take. It used to live here as a local 4.
local BUILDING_CLEAR_MARGIN = RoadConstants.BUILDING_CLEAR_MARGIN

-- Turn-permission state, defaults and the editing API extracted to RoadTurnPermissionStore.

local function isFiniteVector(v: Vector3): boolean
	return v == v and v.Magnitude < math.huge
end

local function notifyTopologyListeners(change: any?)
	for _, listener in _topologyListeners do
		local ok, err = pcall(listener, change)
		if not ok then
			warn("[RoadService] topology listener failed: " .. tostring(err))
		end
	end
end

local function notifySegmentRemovingListeners(segmentId: Types.SegmentId)
	for _, listener in _segmentRemovingListeners do
		local ok, err = pcall(listener, segmentId)
		if not ok then
			warn("[RoadService] segment-removing listener failed: " .. tostring(err))
		end
	end
end

local function inBounds(v: Vector3): boolean
	local h = RoadConstants.MAP_HALF_EXTENT
	return math.abs(v.X) <= h and math.abs(v.Z) <= h
end

local function sameElevationLayer(a: Vector3, b: Vector3): boolean
	return math.abs(a.Y - b.Y) <= RoadConstants.VERTICAL_CONNECT_TOLERANCE
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end


-- Returns the projected endpoint plus the host SEGMENT when the winner was a body
-- foot (nil for node welds and free endpoints) so the caller can detect lane merges.
-- `ignoreNodes` / `ignoreSegs` hide the caller's OWN geometry from the sweep, so a Move-tool
-- drag cannot snap a node onto the very legs it is dragging. Placement passes neither.
local function projectEndpointToHost(pos: Vector3, ownReach: number, ignoreNodes: { [Types.NodeId]: boolean }?, ignoreSegs: { [Types.SegmentId]: boolean }?): (Vector3, Types.Segment?)
	local weld = RoadConstants.NODE_WELD_RADIUS
	for nid, node in _network:getNodes() do
		if ignoreNodes and ignoreNodes[nid] then continue end
		if sameElevationLayer(node.position, pos) and flatDistance(node.position, pos) <= weld then
			return pos, nil
		end
	end
	local nodes = _network:getNodes()
	local bestTarget: Vector3? = nil
	local bestSeg: Types.Segment? = nil
	local bestDist = math.huge


	for sid, seg in _network:getSegments() do
		if ignoreSegs and ignoreSegs[sid] then continue end
		-- Carriageways only: the end joins a road its asphalt actually TOUCHES. Counting both
		-- sidewalks plus a margin welded ends ~30 studs apart that the preview showed as
		-- clearly separate (the ghost snaps only inside SnapUtil's hold radius).
		local hostReach = getCachedRoadSpec(seg.roadType).width * 0.5
		local band = hostReach + ownReach
		-- Hull broad-phase before closestParam's ~35 curve evaluations. This sweep runs over the
		-- WHOLE network once per endpoint, i.e. twice per placement, so on a grown city it was
		-- the single most expensive thing in the snap step -- and almost every segment is far
		-- enough away to reject in ~30 flops.
		if not BezierUtil.hullNear(seg.p0, seg.p1, seg.p2, seg.p3, pos, band, RoadConstants.VERTICAL_CONNECT_TOLERANCE) then continue end
		local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, pos, RoadConstants.SNAP_SEGMENT_SAMPLES)
		local foot = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		if not sameElevationLayer(foot, pos) then continue end
		local perp = flatDistance(foot, pos)
		if perp > band then continue end

		local sN = nodes[seg.startNode]
		local eN = nodes[seg.endNode]
		if sN and flatDistance(sN.position, foot) <= weld then continue end
		if eN and flatDistance(eN.position, foot) <= weld then continue end
		if perp < bestDist then
			bestDist = perp
			bestTarget = foot
			bestSeg = seg
		end
	end


	for nid, node in nodes do
		if ignoreNodes and ignoreNodes[nid] then continue end
		if #node.segments == 0 then continue end
		if not sameElevationLayer(node.position, pos) then continue end
		local d = flatDistance(node.position, pos)
		local armReach = 0
		for _, sid in node.segments do
			local s = _network:getSegment(sid)
			if s then
				local r = getCachedRoadSpec(s.roadType).width * 0.5
				if r > armReach then armReach = r end
			end
		end
		local band = armReach + ownReach
		if d <= band and d < bestDist then
			bestDist = d
			bestTarget = node.position
			bestSeg = nil
		end
	end

	return bestTarget or pos, bestSeg
end

local function validate(req: any): (boolean, string?)
	if typeof(req) ~= "table" then
		return false, "request not a table"
	end
	for _, key in { "p0", "p1", "p2", "p3" } do
		if typeof(req[key]) ~= "Vector3" then
			return false, `field {key} is not a Vector3`
		end
		if not isFiniteVector(req[key]) then
			return false, `field {key} is not finite`
		end
		if not inBounds(req[key]) then
			return false, `field {key} out of map bounds`
		end
	end

	if typeof(req.roadType) ~= "string" or not RoadTypeCatalog.get(req.roadType) then
		return false, "unknown road type"
	end

	-- Checked HERE rather than at the top of placeFromRequest, because by now the endpoints
	-- have been snapped: what gets tested is the road that would actually be built, not the
	-- one that was asked for.
	if not isOnOwnedLand(req.p0, req.p1, req.p2, req.p3) then
		return false, "you do not own this land"
	end

	local length = BezierUtil.length(req.p0, req.p1, req.p2, req.p3, RoadConstants.SAMPLES_PER_SEGMENT)
	if length < RoadConstants.MIN_SEGMENT_LENGTH then
		return false, "segment too short"
	end

	if RoadConstants.MIN_INTERSECTION_ANGLE_RAD > 1e-6 then
		local angleErr = _network:validateAngles(req.p0, req.p1, req.p2, req.p3, req.roadType)
		if angleErr then
			return false, angleErr
		end
	end

	local curvErr = _network:checkCurvature(req.p0, req.p1, req.p2, req.p3, req.roadType)

	if curvErr then
		return false, curvErr
	end

	local cornerErr = _network:checkCornerRadius(req.p0, req.p1, req.p2, req.p3, req.roadType)
	if cornerErr then
		return false, cornerErr
	end

	-- No grade gate. Height is unrestricted: a road may be drawn as steep as the player
	-- wants, and the vertical profile / pillar builder cope with whatever comes out.

	-- Reject knotted/looped curves that fold through themselves (the client pre-checks the
	-- same, but the server is authoritative). Caught here belt-and-suspenders with the
	-- curvature limit, which already rejects the tight turns a single-cubic loop implies.
	if BezierUtil.selfIntersects(req.p0, req.p1, req.p2, req.p3, 28, RoadConstants.VERTICAL_CONNECT_TOLERANCE) then
		return false, "road would cross itself"
	end

	-- ONE broad-phase for the three network sweeps below (see RoadNetwork.scanPlacement).
	-- They each used to walk every segment recomputing hull bounds, and two of them re-ran
	-- the identical crossing sweep the third had already done. Safe to share: nothing between
	-- here and the last check mutates the network.
	local scan = _network:scanPlacement(req.p0, req.p1, req.p2, req.p3, req.roadType)

	-- Reject body crossings that meet an existing road too sharply (elongated junction the
	-- renderer can't cover -> torn road). Endpoint joins are angle-checked by validateAngles.
	local crossErr = _network:checkCrossingAngle(req.p0, req.p1, req.p2, req.p3, req.roadType, scan)
	if crossErr then
		return false, crossErr
	end

	-- Reject junctions placed where a road is turning hard: past the bend cap inside the
	-- junction reach, the anchored mouths fold the fill/curbs (the sharp-curve junction mess).
	local bendErr = _network:checkJunctionCurvature(req.p0, req.p1, req.p2, req.p3, req.roadType, scan)
	if bendErr then
		return false, bendErr
	end


	-- Delegate the remaining geometry checks (overlap, junction spacing, approach
	-- protection) to RoadNetwork.checkPlacement which already implements them and
	-- runs on the same data. This eliminates the duplicate O(N²) loops that were
	-- previously here in validate().
	local networkErr = _network:checkPlacement(req.p0, req.p1, req.p2, req.p3, req.roadType, scan)
	if networkErr then
		return false, networkErr
	end

	-- Last: it dry-runs the add on a copy of the nearby roads, the costliest check here.
	local twinVMode = if req.vMode == "Elevated" or req.vMode == "Tunnel" then req.vMode else nil
	local twinErr = _network:checkParallelTwin(req.p0, req.p1, req.p2, req.p3, req.roadType, twinVMode, req.constSlope == true, scan)
	if twinErr then
		return false, twinErr
	end

	return true
end

-- Full placement pipeline for an already transport-checked client request:
-- endpoint XZ snap, server-authoritative height snap, validation, history,
-- placement. Returns ok plus a reject reason for the client.
-- `actor` is who asked, and it is used for ONE thing: sending the cost tag, build sound and
-- money flash back to them alone. It is supplied by the remote handler, never read off the
-- request, so a client cannot aim another player's UI.
function RoadService.placeFromRequest(req: any, actor: Player?): (boolean, string?)
	-- Development Tree gate, before any geometry work: a locked road type is refused
	-- outright rather than snapped, validated and then rejected.
	if typeof(req) == "table" and typeof(req.roadType) == "string" and not isRoadUnlocked(req.roadType) then
		return false, "that road type is not unlocked yet"
	end

	-- Non-finite points must be excluded here: the snapping math below feeds them
	-- straight into TerrainDataService.getHeightAt -> Heightmap:getCorner (a buffer
	-- read), which errors on NaN. Skipping snapping for bad input lets validate()
	-- reject it cleanly instead of throwing inside the remote handler.
	if typeof(req) == "table"
		and typeof(req.p0) == "Vector3" and typeof(req.p1) == "Vector3"
		and typeof(req.p2) == "Vector3" and typeof(req.p3) == "Vector3"
		and isFiniteVector(req.p0) and isFiniteVector(req.p1)
		and isFiniteVector(req.p2) and isFiniteVector(req.p3)
		and typeof(req.roadType) == "string" then
		local ownSpec = getCachedRoadSpec(req.roadType)
		local ownReach = ownSpec.width * 0.5
		local op0, op1, op2, op3 = req.p0, req.p1, req.p2, req.p3
		local np0, host0 = projectEndpointToHost(op0, ownReach)
		local np3, host3 = projectEndpointToHost(op3, ownReach)
		-- A road drawn straight must stay straight after its endpoints snap. Shifting
		-- each handle by its own endpoint delta bows the road whenever the two ends snap
		-- by different amounts (the wavy "straight" road bug). Detect a straight chord and
		-- rebuild the handles collinear between the snapped endpoints; curves keep the shift.
		local straight = false
		local och = op3 - op0
		local olen = och.Magnitude
		if olen > 1e-3 then
			local ou = och / olen
			local function perpOff(p: Vector3): number
				local w = p - op0
				return (w - ou * w:Dot(ou)).Magnitude
			end
			straight = perpOff(op1) < 0.05 and perpOff(op2) < 0.05
		end
		local chord = np3 - np0
		if straight and chord.Magnitude > 1e-3 then
			req.p1 = np0 + chord / 3
			req.p2 = np0 + chord * (2 / 3)
		else
			req.p1 = op1 + (np0 - op0)
			req.p2 = op2 + (np3 - op3)
		end
		req.p0 = np0
		req.p3 = np3

		-- CS2 approach shaping, through the SAME function the client ghost drew with: an end
		-- meeting a junction shallower than APPROACH_BEND_MIN_ANGLE_RAD is bent clear of the
		-- arms already there rather than refused. Idempotent, so a curve the client already
		-- bent comes back unchanged; a forged request that skipped the client gets bent here.
		req.p1, req.p2 = ApproachBend.apply(
			req.p0, req.p1, req.p2, req.p3,
			_network:armDirsAt(req.p0), _network:armDirsAt(req.p3),
			RoadTypeCatalog.minCurveRadius(ownSpec)
		)

		-- Heights are server-authoritative. Endpoints welded to an existing road
		-- keep the host's height; free endpoints snap to the heightmap surface
		-- unless deliberately elevated. Handles shift by their endpoint's delta,
		-- same as the XZ snap above.
		local halfThick = RoadConstants.ROAD_THICKNESS * 0.5
		local function endpointY(p: Vector3, welded: boolean): number
			if welded then
				return p.Y
			end
			if req.vMode == "Tunnel" then
				-- Tunnel endpoints are deliberately below grade: keep the requested
				-- depth (but never let it poke above ground). Raw seabed on purpose --
				-- tunnels may run under the water bed.
				return math.min(p.Y, TerrainDataService.getSurfaceY(p.X, p.Z) + halfThick)
			end
			local targetY = groundRoadCenterY(p.X, p.Z)
			if req.vMode == "Elevated" then
				return if p.Y - targetY > ROAD_ELEVATION_KEEP then p.Y else targetY
			end
			return targetY
		end
		local y0 = endpointY(req.p0, host0 ~= nil or (np0 - op0).Magnitude > 1e-4)
		local y3 = endpointY(req.p3, host3 ~= nil or (np3 - op3).Magnitude > 1e-4)
		local dy0 = y0 - req.p0.Y
		local dy3 = y3 - req.p3.Y
		if math.abs(dy0) > 1e-4 or math.abs(dy3) > 1e-4 then
			req.p0 = Vector3.new(req.p0.X, y0, req.p0.Z)
			req.p3 = Vector3.new(req.p3.X, y3, req.p3.Z)
			req.p1 += Vector3.new(0, dy0, 0)
			req.p2 += Vector3.new(0, dy3, 0)
		end

		-- Geometry decides the layer, not the client flag: an "Elevated" request whose
		-- deck never rises meaningfully above the terrain (or a "Tunnel" that never dips
		-- below) is really a ground road. Demote it BEFORE profile conditioning so it
		-- terrain-fits like one. A stray layer flag would strand the segment on its own
		-- network layer -- unable to weld or cross ground roads -- which reads as
		-- "elevated roads randomly don't connect".
		-- Asked to sit at a height, BEFORE the demotion below can forget it. Demotion is about
		-- the network LAYER (can this weld/cross ground roads), not about the profile -- and
		-- reading vMode after it meant a road placed at a shallow offset (-4, say: deliberate,
		-- but under ROAD_ELEVATION_KEEP) was demoted to Ground and then terrain-FITTED, so it
		-- bowed over whatever the land did in between instead of running node to node. That is
		-- also the client ghost lying: the client keys off _verticalMode, which is never demoted.
		local holdGrade = req.vMode == "Elevated" or req.vMode == "Tunnel"

		if req.vMode == "Elevated" or req.vMode == "Tunnel" then
			local maxRise, maxDip = 0, 0
			for i = 0, 8 do
				local p = BezierUtil.point(req.p0, req.p1, req.p2, req.p3, i / 8)
				local d = p.Y - groundRoadCenterY(p.X, p.Z)
				if d > maxRise then maxRise = d end
				if d < maxDip then maxDip = d end
			end
			if (req.vMode == "Elevated" and maxRise < ROAD_ELEVATION_KEEP)
				or (req.vMode == "Tunnel" and maxDip > -ROAD_ELEVATION_KEEP) then
				req.vMode = nil
			end
		end

		-- Standardize the vertical profile. Ground roads terrain-fit along the curve;
		-- constSlope and elevated/tunnel both ramp A->B, so a road
		-- asked to sit at a height holds it; only ground roads chase the terrain.
		if req.constSlope == true then
			req.p1, req.p2 = RoadVerticalProfile.conditionLinear(req.p0, req.p1, req.p2, req.p3)
		elseif holdGrade then
			-- Straight ramp, matching the client ghost exactly -- see the note there. A road
			-- asked to sit at a depth holds that depth along its length.
			req.p1, req.p2 = RoadVerticalProfile.conditionLinear(req.p0, req.p1, req.p2, req.p3)
		else
			req.p1, req.p2 = RoadVerticalProfile.conditionToSurface(req.p0, req.p1, req.p2, req.p3, function(x: number, z: number): number?
				return groundRoadCenterY(x, z)
			end)
		end

		-- Final geometry lands on the 0.01-stud grid so live roads match the saved
		-- blob exactly (CitySerializer rounds saves to 2 decimals). Node welds are
		-- unaffected: SNAP_RADIUS dwarfs the max 0.005 shift.
		req.p0 = Quant.vec(req.p0)
		req.p1 = Quant.vec(req.p1)
		req.p2 = Quant.vec(req.p2)
		req.p3 = Quant.vec(req.p3)
	end

	local ok, reason = validate(req)
	if not ok then
		return false, reason
	end

	-- Charge by the metre. Interactive placement only (restore/undo call placeSegment
	-- directly, never this path), so loading a city is free. Reject if unaffordable;
	-- refund below if the placement itself then errors.
	local roadCost = 0
	if _economyService then
		local lengthStuds = BezierUtil.length(req.p0, req.p1, req.p2, req.p3, 24)
		local costSpec = RoadTypeCatalog.getOrDefault(req.roadType)
		local perMeter = costSpec.costPerMeter or RoadConstants.ROAD_COST_PER_METER
		roadCost = math.ceil(lengthStuds * RoadConstants.STUD_TO_METER * perMeter)
		if roadCost > 0 and not _economyService.trySpend(roadCost) then
			return false, "insufficient funds"
		end
	end

	local snapshot = RoadHistoryService.capture()
	-- Sanitize client-sent vertical placement (untrusted): only Elevated/Tunnel are
	-- real overrides, anything else is Ground (nil); constSlope is a plain bool.
	local reqVMode = (req.vMode == "Elevated" or req.vMode == "Tunnel") and req.vMode or nil
	local reqConstSlope = req.constSlope == true
	local placed, placeErr = pcall(function()
		-- Auto-split long roads into capped-length pieces (CS:S-style node spacing). The pieces
		-- share exact endpoints, so each one welds onto the previous piece's end node, producing
		-- a chain of degree-2 joints. Sub-curves are exact, so the path is unchanged. The whole
		-- chain goes down as ONE edit (placeSegments) -- see the note there.
		local fullLen = BezierUtil.length(req.p0, req.p1, req.p2, req.p3, RoadConstants.SAMPLES_PER_SEGMENT)
		local maxLen = RoadConstants.MAX_PLACE_SEGMENT_LENGTH
		local pieces = if maxLen and maxLen > 0 then math.ceil(fullLen / maxLen) else 1
		if pieces <= 1 then
			RoadService.placeSegment(req.p0, req.p1, req.p2, req.p3, req.roadType, reqVMode, reqConstSlope)
		else
			local curves = table.create(pieces)
			for i = 1, pieces do
				local q0, q1, q2, q3 = BezierUtil.subCurve(req.p0, req.p1, req.p2, req.p3, (i - 1) / pieces, i / pieces)
				curves[i] = { p0 = q0, p1 = q1, p2 = q2, p3 = q3 }
			end
			RoadService.placeSegments(curves, req.roadType, reqVMode, reqConstSlope)
		end
	end)
	if not placed then
		warn(`[RoadService] placement failed: {placeErr}`)
		if _economyService and roadCost > 0 then _economyService.credit(roadCost) end -- refund
		return false, "road placement failed"
	end
	RoadHistoryService.push(snapshot)
	if roadCost > 0 then
		RoadReplicationService.broadcastPlacementCharged(req.p3, roadCost, actor)
	end
	-- Clear any building the new pavement is laid over (carriageway + sidewalk corridor,
	-- plus a small margin). Centre-based, so adjacent lots beside the road are untouched.
	-- Interactive only -- restore/undo never reach this path, so loading a city never
	-- bulldozes its own buildings.
	if _buildingClearance then
		local spec = getCachedRoadSpec(req.roadType)
		local clearRadius = spec.width * 0.5 + RoadConstants.SIDEWALK_WIDTH + BUILDING_CLEAR_MARGIN
		-- The sampler is shared: the ghost sweeps the same corridor at the same cadence, so
		-- it cannot highlight one set of houses while this clears another.
		local pts = RoadProximity.samplePavement(req.p0, req.p1, req.p2, req.p3)
		-- Second reach is measured to the building's own footprint, so it is the BARE
		-- carriageway: a neighbour fronting the new road keeps standing, a wall in the
		-- asphalt does not.
		pcall(_buildingClearance, pts, clearRadius, spec.width * 0.5)
	end
	-- The props the new carriageway covers go with it. Given the CURVE, not the sampled
	-- points above: the client's ghost highlights the doomed props off this exact curve,
	-- so an 8-stud sampling difference here would clear a set that did not light up.
	if _natureClearance then
		pcall(_natureClearance, { { p0 = req.p0, p1 = req.p1, p2 = req.p2, p3 = req.p3, roadType = req.roadType } })
	end
	return true
end

-- Injected by Bootstrap so interactive road placement can be charged to the treasury.
function RoadService.setEconomyService(economyService: any)
	_economyService = economyService
end

-- The client hiding a locked road card is presentation; the gate above is the rule.
-- Interactive placement only -- restoring a save must never drop roads the city already
-- has, whatever the tree says today.
-- Injected by Bootstrap (TerritoryService.isSpanAllowed). See _territoryCheck above.
function RoadService.setTerritoryCheck(fn: (({ Vector3 }) -> boolean)?)
	_territoryCheck = fn
end

function RoadService.setUnlockCheck(fn: ((string) -> boolean)?)
	_isRoadAllowed = fn
end

-- Injected by Bootstrap (BuildingService.demolishUnderPavement). Called after an
-- interactive road/roundabout placement to clear buildings the new pavement covers.
function RoadService.setBuildingClearance(fn: any)
	_buildingClearance = fn
end

-- Injected by Bootstrap (NaturePlaceService.clearUnderPavement). Called after an
-- interactive road/roundabout placement to clear the planted props the new pavement covers.
function RoadService.setNatureClearance(fn: any)
	_natureClearance = fn
end

-- endSurfaceTrim reads renderer-held network state; any hiccup there (restore
-- ordering, a node mid-mutation) must degrade to "no trim" -- the segment simply
-- survives the sliver pass -- rather than kill the whole applyChanges batch.
local function safeEndTrim(nodeId: Types.NodeId, segId: Types.SegmentId): number
	local ok, v = pcall(RoadSceneRenderer.endSurfaceTrim, nodeId, segId)
	return if ok and typeof(v) == "number" then v else 0
end

local function applyChanges()
	-- An edit that added or removed a roundabout entry leaves the ring sliced around the
	-- old node set -- stub arcs the junction mouth swallows whole. Re-lay it before
	-- anything downstream reads the topology.
	_network:reflowDirtyRoundabouts(safeEndTrim)
	local dirtySeg, dirtyNode, deadNode = _network:consumeChanges()
	-- Sliver pass: a junction mouth + the far corner's trim can swallow a short arm
	-- segment whole, and the renderer then builds NOTHING for a live segment (the
	-- invisible Segment_N bug). Dissolving the corner node here -- after every mutation
	-- batch -- keeps the invariant for place, move, crossing-splits, undo AND save
	-- restore, without teaching each tool the renderer's dynamic reach.
	for _ = 1, 4 do -- a merge can expose one more sliver at the same junction; 4 caps runaways
		local candidates: { number } = {}
		for sid in dirtySeg do
			candidates[#candidates + 1] = sid
		end
		if not _network:dissolveSwallowedArms(candidates, safeEndTrim) then
			break
		end
		local moreSeg, moreNode, moreDead = _network:consumeChanges()
		for k in moreSeg do
			dirtySeg[k] = true
		end
		for k in moreNode do
			dirtyNode[k] = true
		end
		for k in moreDead do
			deadNode[k] = true
		end
	end
	-- Snapshot the segments whose GEOMETRY actually changed, BEFORE the node cascade below
	-- widens dirtySeg to every neighbour at a touched node. Terrain grading depends only on
	-- a segment's own centerline, so ONLY these need re-grading; re-grading the render-only
	-- neighbours ungrades+regrades identical terrain voxels every edit -- re-dirtying those
	-- chunks and churning the voxel repaint, the main place/delete hitch at busy nodes.
	local gradeChangedIds: { number } = {}
	for sid in dirtySeg do gradeChangedIds[#gradeChangedIds + 1] = sid end
	local nodes = _network:getNodes()
	local nodeDeltaChanged: { any } = {}
	local nodeDeltaRemoved: { number } = {}
	local segDeltaChanged: { any } = {}
	local segDeltaRemoved: { number } = {}

	for nid in dirtyNode do
		local node = nodes[nid]
		if node then
			for _, sid in node.segments do
				dirtySeg[sid] = true
			end
		end
	end

	for nid in deadNode do
		RoadTurnPermissionStore.invalidate(nid)
		table.insert(nodeDeltaRemoved, nid)
		RoadSceneRenderer.removeNodeVisuals(nid)
	end


	local segsToRender: { any } = {}

	for sid in dirtySeg do
		local s = _network:getSegment(sid)
		if s then
			table.insert(segsToRender, s)
			table.insert(segDeltaChanged, {
				id = s.id,
				p0 = s.p0,
				p1 = s.p1,
				p2 = s.p2,
				p3 = s.p3,
				roadType = s.roadType,
				name = s.name,
				startNode = s.startNode,
				endNode = s.endNode,
				isRoundabout = s.isRoundabout,
				-- Client-side road rendering needs the full render-relevant shape of a segment.
				isArc = s.isArc,
				vMode = s.vMode,
				roundaboutId = s.roundaboutId,
				roundaboutCenter = s.roundaboutCenter,
				roundaboutRadius = s.roundaboutRadius,
				startCorner = s.startCorner,
				endCorner = s.endCorner,
				startOffset = s.startOffset,
				endOffset = s.endOffset,
				startFlat = s.startFlat,
				endFlat = s.endFlat,
			})
		else
			table.insert(segDeltaRemoved, sid)
			RoadSceneRenderer.removeSegmentModel(sid)


			RoadTurnPermissionStore.clearLaneRulesForSegment(sid)
		end
	end

	local nodesToRefresh: { number } = {}

	for nid in dirtyNode do
		table.insert(nodesToRefresh, nid)
		local node = nodes[nid]
		if node then
			table.insert(nodeDeltaChanged, { id = nid, position = node.position })
		elseif not deadNode[nid] then
			table.insert(nodeDeltaRemoved, nid)
		end
	end


	RoadReplicationService.queueNodeDelta(nodeDeltaChanged, nodeDeltaRemoved)
	RoadReplicationService.queueSegDelta(segDeltaChanged, segDeltaRemoved)

	if #segsToRender > 0 or #nodesToRefresh > 0 then
		task.defer(function()
			-- Lane arrows and stop spans are painted from the nav graph, so the graph
			-- must absorb this topology change BEFORE the segments render. The nav
			-- defer is queued after this one, which painted markings one placement
			-- behind -- flush it now instead.
			flushNavRebuild()
			-- Per-item fault isolation: one segment/node that errors while rendering must not
			-- abort the rest of the pass. Without this, a single bad node on a city load left
			-- every node AFTER it in the loop unbuilt -- a swath of junction fills silently
			-- missing while the segments + approach markings survived ("intersections didn't save").
			for _, s in segsToRender do
				if _network:getSegment(s.id) then
					local ok, err = pcall(RoadSceneRenderer.renderSegment, s)
					if not ok then
						warn(`[RoadService] renderSegment failed for seg {s.id}: {err}`)
					end
				end
			end
			for _, nid in nodesToRefresh do
				if _network:getNodes()[nid] then
					local ok, err = pcall(RoadSceneRenderer.refreshNode, nid)
					if not ok then
						warn(`[RoadService] refreshNode failed for node {nid}: {err}`)
					end
				end
			end
		end)
	end

	-- Reconcile roundabout islands unconditionally (even on pure deletions where no
	-- segment/node renders) so a removed ring never leaves its island behind.
	if RoadSceneRenderer.syncRoundabouts then
		RoadSceneRenderer.syncRoundabouts()
	end
	-- Same reconcile for dead-end bulbs: a node that stopped being a dead end must not keep
	-- its turnaround bulb, however the edit got there.
	if RoadSceneRenderer.syncDeadEnds then
		RoadSceneRenderer.syncDeadEnds()
	end

	local changedSegmentIds: { number } = {}
	local changedNodeIds: { number } = {}
	for _, entry in segDeltaChanged do table.insert(changedSegmentIds, entry.id) end
	for _, entry in nodeDeltaChanged do table.insert(changedNodeIds, entry.id) end
	return {
		segmentIds = changedSegmentIds,
		removedSegmentIds = segDeltaRemoved,
		nodeIds = changedNodeIds,
		removedNodeIds = nodeDeltaRemoved,
		-- Geometry-changed only (grading). segmentIds also carries render-only neighbours.
		gradeSegmentIds = gradeChangedIds,
	}
end


-- Keep terrain grades in sync with a topology change: drop grades for removed
-- segments, (re)grade every changed/created one. Routed through here so the split
-- pieces produced when two roads cross get graded, not only the single drawn
-- segment -- otherwise natural ground pokes up through the new junction.
local function syncSegmentGrades(change: { segmentIds: { number }, removedSegmentIds: { number }, gradeSegmentIds: { number }? })
	if not terrainGradeEnabled() then return end
	for _, id in change.removedSegmentIds do
		pcall(TerrainGradeService.ungradeSegmentId, id)
	end
	-- Only re-grade segments whose geometry actually changed -- NOT the render-only cascade of
	-- unchanged neighbours in segmentIds. Re-grading those rewrites identical terrain voxels and
	-- was the redundant per-edit churn behind the place/delete lag. Falls back to segmentIds for
	-- any caller that predates gradeSegmentIds.
	-- EXCEPTION: when something was REMOVED, its released terrain claim can lower the ground
	-- under surviving neighbours (they then read as floating decks and grew guardrails), so
	-- removals re-grade the whole touched set, neighbours included.
	local regradeIds = if #change.removedSegmentIds > 0
		then change.segmentIds
		else (change.gradeSegmentIds or change.segmentIds)
	for _, id in regradeIds do
		local s = _network:getSegment(id)
		if s then
			-- Ungrade first: gradeSegment is idempotent per id, so a segment whose
			-- geometry changed while keeping its id would otherwise keep a stale
			-- grade shaped for the old centerline.
			pcall(TerrainGradeService.ungradeSegmentId, id)
			pcall(TerrainGradeService.gradeSegment, s)
		end
	end
end

-- Stable content key used to reconcile history snapshots. History keeps full snapshots
-- for reliability, but undo/redo only mutates segments whose geometry actually differs.
local function segmentSnapshotKey(s: any): string
	local c = s.roundaboutCenter
	return string.format(
		"%.7g,%.7g,%.7g|%.7g,%.7g,%.7g|%.7g,%.7g,%.7g|%.7g,%.7g,%.7g|%s|%s|%s|%s|%s|%.7g,%.7g,%.7g|%.7g|%s",
		s.p0.X, s.p0.Y, s.p0.Z,
		s.p1.X, s.p1.Y, s.p1.Z,
		s.p2.X, s.p2.Y, s.p2.Z,
		s.p3.X, s.p3.Y, s.p3.Z,
		tostring(s.roadType),
		tostring(s.vMode),
		tostring(s.constSlope == true),
		tostring(s.isRoundabout == true),
		tostring(s.roundaboutId),
		if c then c.X else 0,
		if c then c.Y else 0,
		if c then c.Z else 0,
		tonumber(s.roundaboutRadius) or 0,
		tostring(s.roundaboutPreset)
	)
end

local function applySnapshot(snapshot: { any })
	local currentBuckets: { [string]: { any } } = {}
	local currentCount = 0
	for _, seg in _network:getSegments() do
		currentCount += 1
		local key = segmentSnapshotKey(seg)
		local bucket = currentBuckets[key]
		if not bucket then
			bucket = {}
			currentBuckets[key] = bucket
		end
		table.insert(bucket, seg)
	end

	local missing: { any } = {}
	for _, target in snapshot do
		local bucket = currentBuckets[segmentSnapshotKey(target)]
		if bucket and #bucket > 0 then
			table.remove(bucket)
		else
			table.insert(missing, target)
		end
	end

	local removedIds: { Types.SegmentId } = {}
	for _, bucket in currentBuckets do
		for _, seg in bucket do
			table.insert(removedIds, seg.id)
		end
	end

	-- Release and remove only roads absent from the target snapshot. Unchanged roads keep
	-- their ids, rendered models, terrain overlays, parking spots, and navigation edges.
	for _, id in removedIds do
		pcall(TerrainGradeService.ungradeSegmentId, id)
		_pendingNavRemovedSegs[id] = true
		_network:removeSegment(id)
	end

	-- Snapshot segments are ALREADY topology-resolved (capture() stores the live split
	-- pieces, sharing bit-identical endpoint positions). Re-adding them through
	-- addSegment re-ran the placement heuristics -- 12-stud node welding, junction-band
	-- splits, crossing resolution -- which could merge nodes that were deliberately
	-- distinct when placed (fillet tangent pairs, close ramp welds) and warp the loaded
	-- city. Restore with direct adds and a tiny weld so the saved topology comes back
	-- exactly; RoadService.verifyIntegrity repairs genuinely broken legacy data instead.
	local RESTORE_WELD = 0.25
	-- Roundabout rings go first so subsequently restored arms weld to the ring nodes.
	for _, s in missing do
		if s.isRoundabout then
			pcall(function()
				_network:_directAddSegment(s.p0, s.p1, s.p2, s.p3, s.roadType, {
					id = s.id,
					name = s.name,
					isRoundabout = true,
					roundaboutId = s.roundaboutId,
					center = s.roundaboutCenter,
					radius = s.roundaboutRadius,
					preset = s.roundaboutPreset,
					weld = RESTORE_WELD,
				})
			end)
		end
	end
	for _, s in missing do
		if not s.isRoundabout then
			pcall(function()
				_network:_directAddSegment(s.p0, s.p1, s.p2, s.p3, s.roadType, {
					id = s.id,
					name = s.name,
					vMode = s.vMode,
					constSlope = s.constSlope,
					startCorner = s.startCorner,
					endCorner = s.endCorner,
					startOffset = s.startOffset,
					endOffset = s.endOffset,
					startFlat = s.startFlat,
					endFlat = s.endFlat,
					weld = RESTORE_WELD,
				})
			end)
		end
	end

	local change = applyChanges()
	for _, id in change.segmentIds do
		_pendingNavDirtySegs[id] = true
	end
	for _, id in change.removedSegmentIds do
		_pendingNavRemovedSegs[id] = true
	end
	for _, nodeId in change.nodeIds do
		RoadTurnPermissionStore.invalidate(nodeId)
		RoadReplicationService.queueIntersectionBroadcast(nodeId)
	end

	RoadReplicationService.broadcastTopologyDeltas()

	local changedCount = #change.segmentIds + #change.removedSegmentIds
	local targetCount = #snapshot
	local largeRebuild = currentCount == 0 or changedCount > math.max(24, math.floor(targetCount * 0.35))
	scheduleNavRebuild(nil, largeRebuild, largeRebuild)
	syncSegmentGrades(change)
	notifyTopologyListeners(change)
end

-- City persistence: the flat DataStore-safe format lives in RoadSerializer; this wires
-- it to the current network (via the history capture, the segment source of truth).
function RoadService.serializeRoads(): { any }
	return RoadSerializer.serialize(RoadHistoryService.capture())
end

-- Rebuild the network from a serialized list (RoadSerializer decodes the format; the
-- replay is ours). Segment/node ids regenerate, so anything keyed on ids (zones, turn
-- permissions) must re-anchor by position.
function RoadService.restoreRoads(entries: { any })
	applySnapshot(RoadSerializer.deserialize(entries))
	RoadHistoryService.clear()
	-- Self-heal: the exact restore above preserves whatever the save contained, including
	-- damage from older versions. Audit and repair it before the city goes live.
	RoadService.verifyIntegrity(true)
end

-- Audit the road network (dangling refs, degenerate/duplicate segments, drifted
-- endpoints, orphan nodes, unresolved crossings) and, when fix is true (default),
-- repair it -- routing every repair through the normal render/nav/grade pipeline.
-- Runs automatically after a city load; safe to call any time.
function RoadService.verifyIntegrity(fix: boolean?): any
	local rep = _network:audit(fix ~= false)
	local total = rep.badGeometry + rep.refFixes + rep.endpointPins
		+ rep.duplicates + rep.orphanNodes + rep.crossingsResolved
	if total == 0 then
		return rep
	end
	warn(string.format(
		"[RoadService] integrity: %d bad-geometry, %d ref fixes, %d endpoint pins, %d duplicates, %d orphan nodes, %d unresolved crossings%s",
		rep.badGeometry, rep.refFixes, rep.endpointPins, rep.duplicates, rep.orphanNodes, rep.crossingsResolved,
		if fix ~= false then " -- repaired" else ""
	))
	if fix == false then
		return rep
	end
	local change = applyChanges()
	for _, id in change.segmentIds do
		_pendingNavDirtySegs[id] = true
	end
	for _, id in change.removedSegmentIds do
		_pendingNavRemovedSegs[id] = true
	end
	for _, nodeId in change.nodeIds do
		RoadTurnPermissionStore.invalidate(nodeId)
		RoadReplicationService.queueIntersectionBroadcast(nodeId)
	end
	RoadReplicationService.broadcastTopologyDeltas()
	scheduleNavRebuild(nil, true, true)
	syncSegmentGrades(change)
	notifyTopologyListeners(change)
	return rep
end

-- Total length of all road in metres. CityEconomyService caches this (refreshed on
-- topology change) to charge road upkeep. Mirrors the per-metre placement charge.
local function refreshAllMarkingVisuals()
	for _, seg in _network:getSegments() do
		RoadSceneRenderer.renderSegment(seg)
	end
	for nodeId in _network:getNodes() do
		RoadSceneRenderer.refreshNode(nodeId)
	end
end

function RoadService.getTotalRoadLengthMeters(): number
	local totalStuds = 0
	-- Reads the live segments directly. This used to walk RoadHistoryService.capture(), which
	-- allocates a full undo-shaped copy of every segment in the city -- a whole snapshot built
	-- and thrown away just to add up lengths, on every topology change (CityEconomyService
	-- refreshes both this and the upkeep below whenever roads change).
	for _, s in _network:getSegments() do
		totalStuds += BezierUtil.length(s.p0, s.p1, s.p2, s.p3, 8)
	end
	return totalStuds * RoadConstants.STUD_TO_METER
end

-- Monthly road upkeep, per road TYPE: each segment costs a fraction of its own build
-- price (so a Four-Lane Avenue costs more to maintain than an Alley). CityEconomyService
-- caches this, refreshed on topology change.
local ROAD_UPKEEP_FRACTION = 0.43 -- ~matches the old flat $6/m on a $14/m road
function RoadService.getMonthlyRoadUpkeep(): number
	local total = 0
	-- Live segments, not a discarded history snapshot -- see getTotalRoadLengthMeters.
	for _, s in _network:getSegments() do
		local meters = BezierUtil.length(s.p0, s.p1, s.p2, s.p3, 8) * RoadConstants.STUD_TO_METER
		local spec = RoadTypeCatalog.getOrDefault(s.roadType)
		total += meters * (spec.costPerMeter or RoadConstants.ROAD_COST_PER_METER)
	end
	return total * ROAD_UPKEEP_FRACTION
end

-- Shared pipeline tail for one or more just-added segments: ONE applyChanges,
-- ONE delta broadcast, ONE nav schedule, ONE grade sync, ONE listener pass.
-- placeSegment runs it per placement; commitMovePlans batches every moved leg
-- through a single call -- running this tail per leg was the move-commit lag.
local function finishSegmentAdds(addedSegs: { Types.Segment }, affectedIntersections: { Types.NodeId }, movedSegments: { [Types.SegmentId]: any }?)
	local topologyChange = applyChanges()
	-- The Move tool removes a leg and re-adds it, so its id CHANGES. Anything anchored to a
	-- segment (zoning) has to follow the road here instead of reading the new id as "my road
	-- was deleted". old id -> { id = new id, from = old p0..p3, to = new p0..p3 }.
	topologyChange.movedSegments = movedSegments

	-- Collect all segment ids that were dirtied by addSegment (includes any
	-- newly-split segments from crossing resolution) so we only rebuild those.
	local navDirtySegs: { [Types.SegmentId]: boolean } = {}
	for _, id in RoadReplicationService.pendingChangedSegmentIds() do
		navDirtySegs[id] = true
	end
	-- Always mark the added segments dirty even if the delta flushed them already.
	for _, seg in addedSegs do
		navDirtySegs[seg.id] = true
	end

	local allAffected: { Types.NodeId } = {}
	local affectedSet: { [Types.NodeId]: boolean } = {}
	for _, nodeId in affectedIntersections do
		if not affectedSet[nodeId] then
			affectedSet[nodeId] = true
			table.insert(allAffected, nodeId)
		end
	end
	for _, nid in RoadReplicationService.pendingChangedNodeIds() do
		if not affectedSet[nid] and _network:getNodeKind(nid) == "intersection" then
			affectedSet[nid] = true
			table.insert(allAffected, nid)
		end
	end

	RoadReplicationService.broadcastTopologyDeltas()

	-- Schedule an incremental nav rebuild for only the dirty segments.
	for segId in navDirtySegs do
		_pendingNavDirtySegs[segId] = true
	end
	-- Crossing resolution can also DELETE a segment (a dead-end stub absorbed into the new
	-- junction). Feed those to the nav rebuild's removed set so their lanes/U-turns don't linger.
	for _, id in topologyChange.removedSegmentIds do
		_pendingNavRemovedSegs[id] = true
	end

	for _, nodeId in allAffected do
		-- Splits replace segment ids, so any stored manual rules keyed by the
		-- old edge ids are stale -- regenerate defaults for the new layout.
		RoadTurnPermissionStore.invalidate(nodeId)
		RoadReplicationService.queueIntersectionBroadcast(nodeId)
	end
	scheduleNavRebuild()

	-- Navigation is queued before grading because large terrain jobs yield across frames.
	-- Lot/zoning listeners still run after the grade sees its final terrain surface.
	syncSegmentGrades(topologyChange)
	notifyTopologyListeners(topologyChange)
end

local function recordIntersections(seg: Types.Segment, affectedIntersections: { Types.NodeId })
	for _, nodeId in { seg.startNode, seg.endNode } do
		if _network:getNodeKind(nodeId) == "intersection" then
			RoadTurnPermissionStore.invalidate(nodeId)
			table.insert(affectedIntersections, nodeId)
		end
	end
end

-- Add ONE segment to the network and record any intersection node it touched. The shared
-- pipeline tail is deliberately not run here: a caller adding several segments in a single
-- edit collects them all and runs finishSegmentAdds once for the batch.
local function addSegmentToNetwork(
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	roadType: string, vMode: string?, constSlope: boolean?,
	affectedIntersections: { Types.NodeId }
): Types.Segment
	local spec = RoadTypeCatalog.getOrDefault(roadType)
	local seg = _network:addSegment(p0, p1, p2, p3, spec.id, vMode, constSlope)
	recordIntersections(seg, affectedIntersections)
	return seg
end

function RoadService.placeSegment(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string, vMode: string?, constSlope: boolean?): Types.Segment
	local affectedIntersections: { Types.NodeId } = {}
	local seg = addSegmentToNetwork(p0, p1, p2, p3, roadType, vMode, constSlope, affectedIntersections)
	finishSegmentAdds({ seg }, affectedIntersections)
	return seg
end

-- Place a CHAIN of segments as one edit: every piece is added to the network first, then a
-- single pipeline tail runs for the whole batch. A drag longer than MAX_PLACE_SEGMENT_LENGTH
-- is cut into pieces, and running the tail per piece -- applyChanges, delta broadcast, nav
-- rebuild, terrain grade (which yields across frames) and the listener fan-out -- multiplied
-- the wait by the piece count on exactly the long roads that already take longest. The pieces
-- still weld into a degree-2 chain: they are added in order and share exact endpoints.
function RoadService.placeSegments(
	curves: { { p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3 } },
	roadType: string, vMode: string?, constSlope: boolean?
): { Types.Segment }
	local affectedIntersections: { Types.NodeId } = {}
	local added = _network:addChain(curves, RoadTypeCatalog.getOrDefault(roadType).id, vMode, constSlope)
	for _, seg in added do
		recordIntersections(seg, affectedIntersections)
	end
	if #added > 0 then
		finishSegmentAdds(added, affectedIntersections)
	end
	return added
end

-- Pull a point radially onto the circle of the given radius (keeps its height).
local function projectToCircle(p: Vector3, c: Vector3, r: number): Vector3
	local dx, dz = p.X - c.X, p.Z - c.Z
	local m = math.sqrt(dx * dx + dz * dz)
	if m < 1e-4 then return p end
	return Vector3.new(c.X + dx / m * r, p.Y, c.Z + dz / m * r)
end

-- The control points of the cubic restricted to the parameter range [ta, tb].
local function subBezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, ta: number, tb: number): (Vector3, Vector3, Vector3, Vector3)
	local a0, a1, a2, a3 = p0, p1, p2, p3
	if ta > 1e-6 then
		local _, _, _, _, r0, r1, r2, r3 = BezierUtil.splitAt(p0, p1, p2, p3, ta)
		a0, a1, a2, a3 = r0, r1, r2, r3
		tb = (tb - ta) / (1 - ta)
	end
	if tb < 1 - 1e-6 then
		local l0, l1, l2, l3 = BezierUtil.splitAt(a0, a1, a2, a3, tb)
		return l0, l1, l2, l3
	end
	return a0, a1, a2, a3
end

-- Parameters where the curve crosses the circle of radius r about c (flat plane),
-- found by sampling sign changes of (distance - r) and bisecting.
local function circleCrossings(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, c: Vector3, r: number): { number }
	local function f(t: number): number
		return flatDistance(BezierUtil.point(p0, p1, p2, p3, t), c) - r
	end
	local crossings: { number } = {}
	local SAMPLES = 64
	local prevT, prevV = 0, f(0)
	for i = 1, SAMPLES do
		local t = i / SAMPLES
		local v = f(t)
		if (prevV <= 0) ~= (v <= 0) then
			local a, b, fa = prevT, t, prevV
			for _ = 1, 30 do
				local mid = (a + b) * 0.5
				local fm = f(mid)
				if (fa <= 0) == (fm <= 0) then a, fa = mid, fm else b = mid end
			end
			crossings[#crossings + 1] = (a + b) * 0.5
		end
		prevT, prevV = t, v
	end
	return crossings
end

-- Cut every non-roundabout road at the ring circle: drop the part inside the ring
-- and re-add each outside part as an arm. addSegment welds the inner (circle) end
-- onto the ring (splitting an arc -> an entry/exit node) and the outer end back
-- to whatever the road connected to. A road crossing straight through becomes two
-- opposite arms; the legs of an existing junction at the centre each become an
-- arm. Run AFTER the ring exists.
-- How far above the ring a road may meet it and still be treated as a connecting
-- approach (ramped down). A crossing higher than this is a flyover -- left alone.
local ROUNDABOUT_CONNECT_VERTICAL = 16

local function consumeCrossingRoads(center: Vector3, radius: number)
	local arms: { { Vector3 } } = {}
	local armTypes: { string } = {}
	local toRemove: { Types.SegmentId } = {}
	for id, seg in _network:getSegments() do
		if seg.isRoundabout then continue end
		-- Broad-phase: skip roads whose control-point box can't reach the ring circle
		-- (the curve lies inside its control hull), so a big map isn't sampled per road.
		local minX = math.min(seg.p0.X, seg.p1.X, seg.p2.X, seg.p3.X)
		local maxX = math.max(seg.p0.X, seg.p1.X, seg.p2.X, seg.p3.X)
		local minZ = math.min(seg.p0.Z, seg.p1.Z, seg.p2.Z, seg.p3.Z)
		local maxZ = math.max(seg.p0.Z, seg.p1.Z, seg.p2.Z, seg.p3.Z)
		local nx = math.clamp(center.X, minX, maxX) - center.X
		local nz = math.clamp(center.Z, minZ, maxZ) - center.Z
		if nx * nx + nz * nz > radius * radius then continue end
		local crossings = circleCrossings(seg.p0, seg.p1, seg.p2, seg.p3, center, radius)
		local d0 = flatDistance(seg.p0, center)
		local d3 = flatDistance(seg.p3, center)
		if #crossings == 0 then
			-- Fully inside the ring at a compatible height: swallowed.
			local midY = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, 0.5).Y
			if d0 < radius and d3 < radius and math.abs(midY - center.Y) <= ROUNDABOUT_CONNECT_VERTICAL then
				toRemove[#toRemove + 1] = id
			end
		else
			table.sort(crossings)
			-- A road that only meets the ring well above it is a flyover: leave it.
			local lowestCrossY = math.huge
			for _, t in crossings do
				lowestCrossY = math.min(lowestCrossY, BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t).Y)
			end
			if lowestCrossY - center.Y > ROUNDABOUT_CONNECT_VERTICAL then
				continue
			end
			toRemove[#toRemove + 1] = id
			local bounds = { 0 }
			for _, t in crossings do bounds[#bounds + 1] = t end
			bounds[#bounds + 1] = 1
			for k = 1, #bounds - 1 do
				local ta, tb = bounds[k], bounds[k + 1]
				local pmid = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, (ta + tb) * 0.5)
				if flatDistance(pmid, center) > radius then
					local a0, a1, a2, a3 = subBezier(seg.p0, seg.p1, seg.p2, seg.p3, ta, tb)
					-- Pull the ring end onto the circle at ring height; ramp the whole arm
					-- to it so an elevated approach descends cleanly into the roundabout.
					if ta > 1e-6 then
						local p = projectToCircle(a0, center, radius)
						a0 = Vector3.new(p.X, center.Y, p.Z)
					end
					if tb < 1 - 1e-6 then
						local p = projectToCircle(a3, center, radius)
						a3 = Vector3.new(p.X, center.Y, p.Z)
					end
					a1, a2 = RoadVerticalProfile.condition(a0, a1, a2, a3)
					if BezierUtil.length(a0, a1, a2, a3, 12) >= 1.5 then
						arms[#arms + 1] = { a0, a1, a2, a3 }
						armTypes[#armTypes + 1] = seg.roadType
					end
				end
			end
		end
	end
	for _, id in toRemove do
		_network:removeSegment(id)
	end
	for i, arm in arms do
		pcall(function()
			_network:addSegment(arm[1], arm[2], arm[3], arm[4], armTypes[i])
		end)
	end
end

-- == Street names ==============================================================
-- A street's name is derived from its geometry (AddressBook) unless a player set
-- one. Renaming writes the string onto every segment of the chain, so the name
-- survives a later split, a deleted piece, or a road drawn onto the end of it.
-- MAX_NAME_LEN matches the cap RoadSerializer enforces on load.
local MAX_NAME_LEN = 40

local function addressIndex(): AddressBook.Index
	return AddressBook.buildIndex(_network:getSegments())
end

-- name = nil clears the override and the street falls back to its auto name.
-- Returns false when the segment is gone (a road deleted between click and submit).
function RoadService.setRoadName(segmentId: number, name: string?): boolean
	if typeof(segmentId) ~= "number" or not _network:getSegment(segmentId) then
		return false
	end
	local clean: string? = nil
	if typeof(name) == "string" then
		clean = string.sub((string.gsub(name, "%s+", " ") :: string), 1, MAX_NAME_LEN)
		clean = (string.match(clean :: string, "^%s*(.-)%s*$") :: string)
		if clean == "" then clean = nil end
	end

	for _, id in AddressBook.chainOf(addressIndex(), segmentId) do
		local seg = _network:getSegment(id)
		if seg then seg.name = clean end
	end

	-- ponytail: a rename is a typed-in, once-in-a-while edit, so it re-syncs the
	-- whole road payload rather than carrying its own delta path. Move it onto
	-- queueSegDelta if renaming ever becomes something scripts do in bulk.
	RoadReplicationService.broadcastNodes()
	return true
end

-- Live traffic on the street a segment belongs to: mean/peak lane congestion (0-1)
-- from the nav graph's rolling snapshot, plus the speed limit and street length.
-- Read-only -- it never touches driver state.
function RoadService.getRoadTraffic(segmentId: number): any
	if typeof(segmentId) ~= "number" then return nil end
	local index = addressIndex()
	local chain = AddressBook.chainOf(index, segmentId)
	if #chain == 0 then return nil end

	local total, peak, lanes, length = 0, 0, 0, 0
	for _, id in chain do
		local seg = _network:getSegment(id)
		if not seg then continue end
		length += BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 16)
		if not _navGraph then continue end
		for _, edge in _navGraph:GetEdgesForSegment(id) do
			local c = _navGraph:GetEdgeCongestion(edge.id)
			total += c
			peak = math.max(peak, c)
			lanes += 1
		end
	end

	local seg = _network:getSegment(segmentId)
	local spec = if seg then getCachedRoadSpec(seg.roadType) else nil
	return {
		name = AddressBook.nameOf(index, segmentId),
		roadTypeName = if spec then spec.name else "Road",
		segments = #chain,
		lengthStuds = length,
		speedLimit = if spec then spec.speedLimit else 0,
		congestion = if lanes > 0 then total / lanes else 0,
		peakCongestion = peak,
	}
end

-- Stamp a roundabout from a client request: { center: Vector3, radius: number,
-- roadType: string? }. Dropping it onto existing roads cuts them at the ring and
-- reconnects them as give-way arms; on open ground it just lays the ring and the
-- player draws roads in afterwards.
-- A centre preset from a request, or nil ("Empty"). Only listed names get through.
local function validPreset(p: any): string?
	if typeof(p) ~= "string" or p == "Empty" then return nil end
	for _, k in RoadConstants.ROUNDABOUT_CENTRE_PRESETS do
		if p == k then return k end
	end
	return nil
end

function RoadService.placeRoundaboutFromRequest(req: any): (boolean, string?)
	if typeof(req) ~= "table" or typeof(req.center) ~= "Vector3" or typeof(req.radius) ~= "number" then
		return false, "invalid roundabout request"
	end
	if not isFiniteVector(req.center) or req.radius ~= req.radius then
		return false, "invalid roundabout geometry"
	end
	-- Ring carriageways only: a two-way or otherwise arbitrary catalog type here
	-- would break the one-way circulation the ring assumes.
	local roadType = if typeof(req.roadType) == "string" and string.sub(req.roadType, 1, 10) == "Roundabout"
		and RoadTypeCatalog.get(req.roadType) then req.roadType else "Roundabout"
	if not isRoadUnlocked(roadType) then return false, "roundabouts are not unlocked yet" end
	-- Floor the radius at one full carriageway width as well as the global minimum:
	-- a spoofed tiny radius under a wide ring type would fold the ring through its
	-- own island (inverted, self-overlapping arcs).
	local ringSpec = getCachedRoadSpec(roadType)
	local radius = math.clamp(req.radius, math.max(RoadConstants.ROUNDABOUT_MIN_RADIUS, ringSpec.width), RoadConstants.ROUNDABOUT_MAX_RADIUS)

	-- Server-authoritative centre height. A deliberately-elevated request (the client
	-- applied the elevation slider) keeps its height so the ring rides on pillars; a
	-- ground-level one snaps onto the heightmap. Same rule the road placer uses.
	local terrainY = groundRoadCenterY(req.center.X, req.center.Z)
	local cy = if req.center.Y - terrainY > ROAD_ELEVATION_KEEP then req.center.Y else terrainY
	-- Dropped onto existing roads, a ground ring takes THEIR height where they cross it. The
	-- ground under a road is graded down around its slab, so the terrain read at the centre of
	-- a crossing sat the ring ~1.25 studs below the arms it joins: every entry a ramp, and the
	-- ramped junction surface rising over the ring's paint.
	if cy == terrainY then
		local sum, count = 0, 0
		for _, s in _network:getSegments() do
			if s.isRoundabout or s.isArc then continue end
			for _, t in circleCrossings(s.p0, s.p1, s.p2, s.p3, req.center, radius) do
				local y = BezierUtil.point(s.p0, s.p1, s.p2, s.p3, t).Y
				if math.abs(y - terrainY) <= ROAD_ELEVATION_KEEP then
					sum += y
					count += 1
				end
			end
		end
		if count > 0 then cy = sum / count end
	end
	local center = Vector3.new(req.center.X, cy, req.center.Z)

	local outer = radius + ringSpec.width * 0.5 + RoadConstants.SIDEWALK_WIDTH
	for _, axis in { Vector3.new(outer, 0, 0), Vector3.new(-outer, 0, 0), Vector3.new(0, 0, outer), Vector3.new(0, 0, -outer) } do
		if not inBounds(center + axis) then
			return false, "roundabout out of map bounds"
		end
	end

	-- Roundabouts may be dropped onto existing roads (they get cut at the ring and
	-- reconnected as arms). Only reject overlapping ANOTHER roundabout -- nesting
	-- rings is not supported.
	for _, seg in _network:getSegments() do
		if seg.isRoundabout then
			local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, center, RoadConstants.SNAP_SEGMENT_SAMPLES)
			local cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
			if sameElevationLayer(cp, center) and flatDistance(cp, center) < outer + radius then
				return false, "overlaps another roundabout"
			end
		end
	end

	-- Ring + road-cutting run as ONE protected step. An error mid-cut used to leave
	-- the city half-modified (ring placed, some roads removed) with no history entry
	-- -- un-undoable damage. Now any failure rolls the network back to the snapshot.
	local snapshot = RoadHistoryService.capture()
	local placed, placeErr = pcall(function()
		_network:addRoundabout(center, radius, roadType, RoadConstants.ROUNDABOUT_ARC_COUNT, validPreset(req.preset))
		-- Cut & reconnect any roads the ring lands on.
		consumeCrossingRoads(center, radius)
	end)
	if not placed then
		warn(`[RoadService] roundabout placement failed: {placeErr}`)
		local restored, restoreErr = pcall(applySnapshot, snapshot)
		if not restored then
			warn(`[RoadService] roundabout rollback failed: {restoreErr}`)
		end
		return false, "roundabout placement failed"
	end
	RoadHistoryService.push(snapshot)

	local topologyChange = applyChanges()

	RoadReplicationService.broadcastTopologyDeltas()
	-- Incremental nav rebuild over only the segments this placement touched (the ring
	-- arcs, the cut arms, and any split pieces) plus the roads it consumed. Re-sampling
	-- the whole city's lanes on every roundabout was the placement hitch.
	for _, id in topologyChange.segmentIds do
		_pendingNavDirtySegs[id] = true
	end
	for _, id in topologyChange.removedSegmentIds do
		_pendingNavRemovedSegs[id] = true
	end
	scheduleNavRebuild(nil, true, false)
	syncSegmentGrades(topologyChange)
	notifyTopologyListeners(topologyChange)
	-- Clear buildings under the whole roundabout footprint (ring road + centre island
	-- disc). `outer` already = radius + width/2 + sidewalk; the margin keeps adjacent lots
	-- safe. Interactive only, like the road path above.
	if _buildingClearance then
		pcall(_buildingClearance, { center }, outer + BUILDING_CLEAR_MARGIN, outer)
	end
	-- A roundabout's footprint is a disc, not a curve; `outer` is its pavement edge.
	if _natureClearance then
		pcall(_natureClearance, nil, { center = center, radius = outer })
	end
	return true
end


-- Roundabout tool: give the roundabout under a point (anywhere inside its outer kerb) a new
-- centre preset. Undoable like any other road edit.
function RoadService.setRoundaboutPresetFromRequest(req: any): (boolean, string?)
	if typeof(req) ~= "table" or typeof(req.center) ~= "Vector3" or not isFiniteVector(req.center) then
		return false, "invalid roundabout request"
	end
	if typeof(req.preset) ~= "string" then
		return false, "unknown roundabout centre"
	end
	local preset = validPreset(req.preset)
	if preset == nil and req.preset ~= "Empty" then
		return false, "unknown roundabout centre"
	end
	local raId: number? = nil
	local best = math.huge
	for _, s in _network:getSegments() do
		if s.isRoundabout and s.roundaboutId and s.roundaboutCenter and s.roundaboutRadius then
			local d = flatDistance(s.roundaboutCenter, req.center)
			local spec = getCachedRoadSpec(s.roadType)
			if d < s.roundaboutRadius + spec.width * 0.5 and d < best and sameElevationLayer(s.roundaboutCenter, req.center) then
				best = d
				raId = s.roundaboutId
			end
		end
	end
	if not raId then
		return false, "no roundabout there"
	end
	local snapshot = RoadHistoryService.capture()
	if not _network:setRoundaboutPreset(raId, preset) then
		return false, "no roundabout there"
	end
	RoadHistoryService.push(snapshot)
	RoadSceneRenderer.syncRoundabouts()
	return true
end

function RoadService.getNetwork(): RoadNetwork.RoadNetwork
	return _network
end

function RoadService.onTopologyChanged(listener: (any?) -> ()): () -> ()
	table.insert(_topologyListeners, listener)
	local disconnected = false

	return function()
		if disconnected then return end
		disconnected = true
		local index = table.find(_topologyListeners, listener)
		if index then
			table.remove(_topologyListeners, index)
		end
	end
end

function RoadService.onSegmentRemoving(listener: (Types.SegmentId) -> ()): () -> ()
	table.insert(_segmentRemovingListeners, listener)
	local disconnected = false

	return function()
		if disconnected then return end
		disconnected = true
		local index = table.find(_segmentRemovingListeners, listener)
		if index then
			table.remove(_segmentRemovingListeners, index)
		end
	end
end

function RoadService.getNavigationGraph(): any
	return _navGraph
end

-- The rail-only nav graph trains route on (TrainDispatchService).
function RoadService.getRailGraph(): any
	return _railGraph
end

function RoadService.removeSegment(id: Types.SegmentId)


	local affectedIntersections: { Types.NodeId } = {}
	local seg = _network:getSegment(id)
	if seg then
		notifySegmentRemovingListeners(id)
		for _, nodeId in { seg.startNode, seg.endNode } do
			if _network:getNodeKind(nodeId) == "intersection" then
				table.insert(affectedIntersections, nodeId)
			end
		end
	end
	pcall(TerrainGradeService.ungradeSegmentId, id)
	_network:removeSegment(id)
	local topologyChange = applyChanges()
	-- Deleting one road of a crossing merges the other road's split pieces back into
	-- a new segment id; its grade is refreshed after navigation is queued below.
	RoadReplicationService.broadcastTopologyDeltas()

	-- Mark every removed/re-formed segment so deletion stays on the incremental path.
	_pendingNavRemovedSegs[id] = true
	for _, changedId in topologyChange.segmentIds do
		_pendingNavDirtySegs[changedId] = true
	end
	for _, removedId in topologyChange.removedSegmentIds do
		_pendingNavRemovedSegs[removedId] = true
	end
	scheduleNavRebuild()

	for _, nodeId in affectedIntersections do
		if _network:getNodes()[nodeId] then
			-- The node lost an arm; stored permissions (and any manual connection
			-- rules keyed by the removed segment's edge ids) are stale. Reset to
			-- defaults so lanes and arrows regenerate for the new arm count.
			RoadTurnPermissionStore.invalidate(nodeId)
			if _network:getNodeKind(nodeId) == "intersection" then
				RoadReplicationService.queueIntersectionBroadcast(nodeId)
			end
		end
	end
	syncSegmentGrades(topologyChange)
	notifyTopologyListeners(topologyChange)
end

function RoadService.modifySegment(id: Types.SegmentId, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string?): Types.Segment?
	local old = _network:getSegment(id)
	if not old then
		return nil
	end
	local finalType = roadType or old.roadType

	pcall(TerrainGradeService.ungradeSegmentId, id)
	_network:removeSegment(id)
	local removalChange = applyChanges()

	-- placeSegment() below marks only the NEW segment dirty, which forces the nav
	-- rebuild down its incremental path. Without recording the OLD segment as removed,
	-- its lane edges -- and the dead-end U-turn connector left at the old end node --
	-- are never stripped: stale routes linger and the new lanes draw on top. Mirror
	-- removeSegment: mark the replaced id, plus anything the removal itself dropped or
	-- re-formed (e.g. merged crossing pieces).
	_pendingNavRemovedSegs[id] = true
	for _, removedId in removalChange.removedSegmentIds do
		_pendingNavRemovedSegs[removedId] = true
	end
	for _, changedId in removalChange.segmentIds do
		_pendingNavDirtySegs[changedId] = true
	end

	local newSeg = RoadService.placeSegment(p0, p1, p2, p3, finalType, old.vMode, old.constSlope)
	-- Carry the node-tool shaping across the rebuild. Both endpoints are unchanged on
	-- every caller of this (move / handle edit / road-type swap), so each end still
	-- meets the same junction; without this a single move silently reset both corners.
	if newSeg then
		newSeg.startCorner = old.startCorner
		newSeg.endCorner = old.endCorner
		newSeg.startOffset = old.startOffset
		newSeg.endOffset = old.endOffset
		newSeg.startFlat = old.startFlat
		newSeg.endFlat = old.endFlat
	end
	return newSeg
end

function RoadService.rebuildNavigationGraph()
	scheduleNavRebuild(nil, true, true)


	for nodeId in _network:getNodes() do
		if _network:getNodeKind(nodeId) == "intersection" then
			RoadReplicationService.broadcastTurnPermissions(nil, nodeId)
		end
	end
end

function RoadService.undo(): boolean
	return RoadHistoryService.undo()
end

function RoadService.redo(): boolean
	return RoadHistoryService.redo()
end

-- Node tool (the CS "Node Controller" knobs). Reshapes a junction in place: nothing
-- moves, no segment is rebuilt, so this never touches topology or ids. `seg` omitted
-- means every arm at the node -- that is what "the intersection's radius" means. `flat`
-- describes the plate rather than an arm, so it ignores `seg` and always writes them all.
-- The remaining knob, arm ANGLE, is not here: it rotates the segment's own tangent handle
-- and so goes through the ordinary `handles` move (real geometry, priced and undoable).
-- ponytail: no history push -- a shaping edit is a slider, and the panel's Reset is its
-- undo. Give it snapshot support (segmentSnapshotKey + capture) if Ctrl+Z must cover it.
function RoadService.shapeJunction(req: any): (boolean, string?)
	if typeof(req.node) ~= "number" or req.node ~= req.node then
		return false, "invalid node"
	end
	local nodeId = math.floor(req.node)
	local node = _network:getNodes()[nodeId]
	if not node then
		return false, "no such node"
	end

	local reset = req.reset == true
	local corner: number? = nil
	if req.corner ~= nil then
		if typeof(req.corner) ~= "number" or req.corner ~= req.corner then
			return false, "invalid corner radius"
		end
		corner = math.clamp(req.corner, RoadConstants.NODE_CORNER_MIN, RoadConstants.NODE_CORNER_MAX)
	end
	local offset: number? = nil
	if req.offset ~= nil then
		if typeof(req.offset) ~= "number" or req.offset ~= req.offset then
			return false, "invalid arm offset"
		end
		offset = math.clamp(req.offset, RoadConstants.NODE_OFFSET_MIN, RoadConstants.NODE_OFFSET_MAX)
	end
	-- Flat plate vs. follow-the-roads. Unlike the two above this belongs to the junction,
	-- not to one arm, so it ignores req.seg entirely (below) -- false stores nil, keeping
	-- "absent = the default" true for every shaping field.
	local flat: boolean? = nil
	if req.flat ~= nil then
		if typeof(req.flat) ~= "boolean" then
			return false, "invalid flat flag"
		end
		flat = req.flat
	end
	if not reset and not corner and not offset and flat == nil then
		return false, "nothing to change"
	end

	local only: number? = if typeof(req.seg) == "number" and req.seg == req.seg then math.floor(req.seg) else nil
	local touched = false
	for _, sid in node.segments do
		local seg = _network:getSegment(sid)
		if not seg then continue end
		local atStart = seg.startNode == nodeId
		-- Every arm at the node carries the plate flag, whatever `seg` asked for: the
		-- renderer reads it off whichever arm it happens to hold, so they must agree.
		-- "Reset this arm" (only ~= nil) leaves it alone -- it is not that arm's to reset.
		if flat ~= nil or (reset and not only) then
			local v = if reset or not flat then nil else true
			if atStart then seg.startFlat = v else seg.endFlat = v end
			touched = true
		end
		if only and sid ~= only then continue end
		if reset then
			if atStart then
				seg.startCorner, seg.startOffset = nil, nil
			else
				seg.endCorner, seg.endOffset = nil, nil
			end
		else
			if corner then
				if atStart then seg.startCorner = corner else seg.endCorner = corner end
			end
			if offset then
				if atStart then seg.startOffset = offset else seg.endOffset = offset end
			end
		end
		touched = true
	end
	if not touched then
		return false, "no such arm at that node"
	end

	-- Nothing moved, so no mutation marked anything dirty: say so explicitly, then run
	-- the normal tail so the junction mesh, its arms' markings and the clients all
	-- pick up the new trim distances.
	_network:touchNode(nodeId)
	applyChanges()
	RoadReplicationService.broadcastTopologyDeltas()
	if _network:getNodeKind(nodeId) == "intersection" then
		RoadReplicationService.queueIntersectionBroadcast(nodeId)
	end
	return true
end

function RoadService.setIntersectionTurnPermission(nodeId: Types.NodeId, movement: string, enabled: boolean): boolean
	return RoadTurnPermissionStore.setTurnPermission(nodeId, movement, enabled)
end

function RoadService.setIntersectionLaneTurnPermission(nodeId: Types.NodeId, incomingEdgeId: string, movement: string, enabled: boolean): boolean
	return RoadTurnPermissionStore.setLaneTurnPermission(nodeId, incomingEdgeId, movement, enabled)
end

function RoadService.setIntersectionConnectionHandle(nodeId: Types.NodeId, fromEdgeId: string, toEdgeId: string, handle: Vector3): boolean
	return RoadTurnPermissionStore.setConnectionHandle(nodeId, fromEdgeId, toEdgeId, handle)
end


-- ensureManual moved to RoadTurnPermissionStore.


function RoadService.setIntersectionConnection(nodeId: Types.NodeId, fromEdgeId: string, toEdgeId: string, connected: boolean): boolean
	return RoadTurnPermissionStore.setConnection(nodeId, fromEdgeId, toEdgeId, connected)
end


function RoadService.resetIntersectionConnections(nodeId: Types.NodeId): boolean
	return RoadTurnPermissionStore.resetConnections(nodeId)
end

-- True if a point (with its own footprint radius) would overlap any road's actual
-- paved width. Used by NaturePlaceService so trees/bushes/rocks can't be planted on
-- top of a road. Same shape as projectEndpointToHost/nearestSegmentIdFromWorldPos
-- below: closestParam+point per segment, gated by that segment's real width -- but
-- unlike those two, this only needs a boolean, not the nearest match, so it returns
-- the instant any segment violates clearance instead of scanning for a minimum.
-- Authoritative half of the road-proximity rule. The client previews the SAME predicate
-- (see NaturePlacementController.isNearRoadPreview) -- both now call one implementation in
-- ReplicatedStorage.Road.RoadProximity, so the ghost's colour cannot disagree with what
-- this accepts. Only the segment source differs: the live network here, the replicated
-- mirror there.
-- `height` is how far the prop reaches up from `pos`: a tree under an elevated deck is
-- on the road when its crown is, not when its roots are. Omitted = a bare point.
function RoadService.isPointNearRoad(pos: Vector3, footprintRadius: number, height: number?): boolean
	return RoadProximity.isPointNearRoad(_network:getSegments(), pos, footprintRadius, height)
end

local function nearestSegmentIdFromWorldPos(worldPos: Vector3): number?
	local bestId: number? = nil
	local bestDist = math.huge
	for _, seg in _network:getSegments() do
		local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, worldPos, 16)
		local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local d = if sameElevationLayer(p, worldPos) then flatDistance(p, worldPos) else math.huge
		if d < bestDist then
			bestDist = d
			bestId = seg.id
		end
	end
	if bestDist <= RoadConstants.SNAP_SEGMENT_RADIUS * 1.5 then
		return bestId
	end
	return nil
end

-- A roundabout is ONE object, not eight arcs. Re-type every arc of the ring IN PLACE: the
-- arcs keep their geometry, their ids and their ring metadata, so the entries, the one-way
-- circulation and the island all survive. Rebuilding an arc through modifySegment -- what the
-- upgrade tool used to do to whichever arc was clicked -- re-adds it as an ORDINARY road:
-- isRoundabout / roundaboutId / centre are dropped and the ring renders as a torn kerbed
-- road. That was "upgrading the road from the roundabout glitches the roundabout".
local function retypeRoundabout(raId: number, roadType: string): boolean
	local touched = false
	for id, s in _network:getSegments() do
		if s.isRoundabout and s.roundaboutId == raId and s.roadType ~= roadType then
			s.roadType = roadType
			_network:touchSegment(id)
			touched = true
		end
	end
	if not touched then return false end
	local topologyChange = applyChanges()
	RoadReplicationService.broadcastTopologyDeltas()
	for _, id in topologyChange.segmentIds do _pendingNavDirtySegs[id] = true end
	for _, id in topologyChange.removedSegmentIds do _pendingNavRemovedSegs[id] = true end
	scheduleNavRebuild(nil, true, false)
	syncSegmentGrades(topologyChange)
	notifyTopologyListeners(topologyChange)
	return true
end

-- Replace / reverse a segment from a transport-checked client request. An
-- empty roadType means "reverse direction" for one-way roads; re-applying the
-- same one-way type also reverses. Resolves by id or nearest world position.
function RoadService.replaceSegmentFromRequest(segmentId: any, roadType: string, worldPos: any)
	local resolvedSegmentId: number? = nil
	if typeof(segmentId) == "number" then
		resolvedSegmentId = segmentId
	end
	if (not resolvedSegmentId or not _network:getSegment(resolvedSegmentId)) and typeof(worldPos) == "Vector3" then
		resolvedSegmentId = nearestSegmentIdFromWorldPos(worldPos)
	end
	if not resolvedSegmentId then
		return
	end

	local seg = _network:getSegment(resolvedSegmentId)
	if not seg then
		return
	end

	-- Ring arcs are not upgraded one at a time, and only to another ring carriageway: any
	-- other type breaks the circulation the ring assumes.
	if seg.isRoundabout then
		local raId = seg.roundaboutId
		if not raId or string.sub(roadType, 1, 10) ~= "Roundabout" or not RoadTypeCatalog.get(roadType) then
			return
		end
		if not isRoadUnlocked(roadType) then return end
		-- A ring wider than its own radius folds through its island.
		local ringRadius = seg.roundaboutRadius or RoadConstants.ROUNDABOUT_MIN_RADIUS
		if getCachedRoadSpec(roadType).width > ringRadius then return end
		RoadHistoryService.push(RoadHistoryService.capture())
		retypeRoundabout(raId, roadType)
		return
	end

	local currentSpec = getCachedRoadSpec(seg.roadType)
	if roadType == "" then

		if currentSpec.oneWay then
			RoadHistoryService.push(RoadHistoryService.capture())
			RoadService.modifySegment(resolvedSegmentId, seg.p3, seg.p2, seg.p1, seg.p0, seg.roadType)
		end
		return
	end

	if not RoadTypeCatalog.get(roadType) then
		return
	end

	if roadType == seg.roadType and currentSpec.oneWay then

		RoadHistoryService.push(RoadHistoryService.capture())
		RoadService.modifySegment(resolvedSegmentId, seg.p3, seg.p2, seg.p1, seg.p0, seg.roadType)
		return
	end

	RoadHistoryService.push(RoadHistoryService.capture())
	RoadService.modifySegment(resolvedSegmentId, seg.p0, seg.p1, seg.p2, seg.p3, roadType)
end

-- Move tool. Same math as the client preview (RoadMoveGeometry); the client
-- sends grab ids + drag targets, never rebuilt geometry (except the two curve
-- handles in manipulation mode, which are validated + vertically conditioned).
-- req kinds:
--   node    { id, target, snapGround?, exactY? }  -- drag one node; legs follow
--   segment { id, target }                        -- bend a segment through a point
--   handles { id, p1, p2 }                        -- manipulation: reshape one curve
--   group   { moves = { { id, target } }, rot?, pivot?, snapGround?, exactY? }
--     rot+pivot: XZ rotation the client already applied to the node targets;
--     passed along so fully-selected curves get their handles rotated rigidly.
--     snapGround: force every target onto the heightmap (To Terrain Height).
--     exactY: keep the sent Y, clamped to ground level (To Object Height).
local MAX_GROUP_MOVES = 128

type MovePlan = { id: Types.SegmentId, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string, vMode: string?, constSlope: boolean? }

-- Moving pavement is not free: each affected segment re-costs a fraction of its
-- construction price per commit. Interactive moves only -- undo/restore bypass
-- this path, so loading a city or undoing stays free. Rejecting BEFORE the
-- history push keeps a refused move out of the undo stack.
local MOVE_COST_RATE = 0.25
-- Displacement scaling: a nudge costs a fraction of the full rate; moves at or past
-- MOVE_COST_REF_DIST studs pay the full MOVE_COST_RATE. Keep in sync with the client
-- preview in RoadMoveController.pendingMoveCost.
local MOVE_COST_REF_DIST = 40
local MOVE_COST_MIN_FRAC = 0.1

-- `actor` rides along the whole move path for one reason: the cost tag goes back to the
-- player who dragged, and to nobody else.
local function chargeMoveCost(curves: { MovePlan }, actor: Player?): (boolean, string?)
	if not _economyService then return true, nil end
	local total = 0
	for _, c in curves do
		local lengthStuds = BezierUtil.length(c.p0, c.p1, c.p2, c.p3, 24)
		local spec = RoadTypeCatalog.getOrDefault(c.roadType)
		local perMeter = spec.costPerMeter or RoadConstants.ROAD_COST_PER_METER
		local segCost = lengthStuds * RoadConstants.STUD_TO_METER * perMeter
		-- Scale by how far the curve actually moved: largest control-point displacement
		-- vs the still-live old segment (charge runs before commitMovePlans removes it).
		local frac = 1
		local old = _network:getSegment(c.id)
		if old then
			local disp = math.max(
				(c.p0 - old.p0).Magnitude, (c.p1 - old.p1).Magnitude,
				(c.p2 - old.p2).Magnitude, (c.p3 - old.p3).Magnitude)
			frac = math.clamp(disp / MOVE_COST_REF_DIST, MOVE_COST_MIN_FRAC, 1)
		end
		total += segCost * frac
	end
	local cost = math.ceil(total * MOVE_COST_RATE)
	if cost > 0 and not _economyService.trySpend(cost) then
		return false, "insufficient funds"
	end
	if cost > 0 then
		local c = curves[1]
		RoadReplicationService.broadcastPlacementCharged(BezierUtil.point(c.p0, c.p1, c.p2, c.p3, 0.5), cost, actor)
	end
	return true, nil
end

local function moveTargetY(oldPos: Vector3, target: Vector3, snapGround: boolean?, exactY: boolean?): number
	local newSurf = groundRoadCenterY(target.X, target.Z)
	if snapGround then return newSurf end
	if exactY then return math.max(target.Y, newSurf) end
	-- Default: ground glues to the heightmap at the new spot; a deliberately
	-- elevated point keeps its absolute height (same rule placement uses).
	local oldSurf = groundRoadCenterY(oldPos.X, oldPos.Z)
	if oldPos.Y - oldSurf > ROAD_ELEVATION_KEEP then return oldPos.Y end
	return newSurf
end

-- Shared tail for node/group moves: remove EVERY affected leg first, then
-- re-place them all (modifySegment's internals, batched). Rebuilding one leg at
-- a time lets its new curve cross a sibling still parked on the old node
-- position, and the crossing resolver splits both into junction fragments.
local function commitMovePlans(plans: { MovePlan })
	RoadHistoryService.push(RoadHistoryService.capture())
	-- The centreline each leg had BEFORE the move, kept so the zoning layer can slide its
	-- houses along by the same amount instead of losing them to the new segment id.
	local oldCurve: { [Types.SegmentId]: { Vector3 } } = {}
	for _, plan in plans do
		local old = _network:getSegment(plan.id)
		if old then oldCurve[plan.id] = { old.p0, old.p1, old.p2, old.p3 } end
		pcall(TerrainGradeService.ungradeSegmentId, plan.id)
		_network:removeSegment(plan.id)
		_pendingNavRemovedSegs[plan.id] = true
	end
	local removalChange = applyChanges()
	for _, removedId in removalChange.removedSegmentIds do
		_pendingNavRemovedSegs[removedId] = true
	end
	for _, changedId in removalChange.segmentIds do
		_pendingNavDirtySegs[changedId] = true
	end
	-- Re-add every leg first, then run the pipeline tail ONCE for the whole batch.
	-- Going through placeSegment per leg re-ran applyChanges / broadcast / nav /
	-- grade / zoning listeners N times per move -- the slow redraw on release.
	local added: { Types.Segment } = {}
	local affected: { Types.NodeId } = {}
	local moved: { [Types.SegmentId]: any } = {}
	for _, plan in plans do
		local spec = RoadTypeCatalog.getOrDefault(plan.roadType)
		local ok, segOrErr = pcall(function()
			return _network:addSegment(plan.p0, plan.p1, plan.p2, plan.p3, spec.id, plan.vMode, plan.constSlope)
		end)
		if ok and segOrErr then
			local seg = segOrErr :: Types.Segment
			table.insert(added, seg)
			-- Only a leg that came back WHOLE carries its zoning across: if the re-add welded
			-- or split it, positions ALONG it no longer mean what they did, and the old
			-- drop-the-group behaviour is the honest answer.
			local old = oldCurve[plan.id]
			if old and (seg.p0 - plan.p0).Magnitude < 1 and (seg.p3 - plan.p3).Magnitude < 1 then
				moved[plan.id] = { id = seg.id, from = old, to = { seg.p0, seg.p1, seg.p2, seg.p3 } }
			end
			for _, nodeId in { seg.startNode, seg.endNode } do
				if _network:getNodeKind(nodeId) == "intersection" then
					RoadTurnPermissionStore.invalidate(nodeId)
					table.insert(affected, nodeId)
				end
			end
		else
			warn(`[RoadService] move re-add failed for seg {plan.id}: {segOrErr}`)
		end
	end
	finishSegmentAdds(added, affected, moved)
end

-- Move a set of nodes to per-node targets. All-or-nothing: one leg degenerating
-- (too short / too tight) rejects the whole move instead of tearing junctions.
local function moveNodeSet(moves: { any }, rot: number?, pivot: Vector3?, snapGround: boolean?, exactY: boolean?, actor: Player?): (boolean, string?)
	if #moves == 0 or #moves > MAX_GROUP_MOVES then return false, "invalid move count" end
	local targets: { [Types.NodeId]: Vector3 } = {}
	for _, mv in moves do
		if typeof(mv) ~= "table" or typeof(mv.id) ~= "number" or typeof(mv.target) ~= "Vector3" then
			return false, "invalid move entry"
		end
		if not isFiniteVector(mv.target) or not inBounds(mv.target) then
			return false, "move out of map bounds"
		end
		local node = _network:getNodes()[mv.id]
		if not node then return false, "no such node" end
		if _network:isRoundaboutNode(mv.id) then return false, "roundabouts cannot be moved" end
		targets[mv.id] = Vector3.new(mv.target.X, moveTargetY(node.position, mv.target, snapGround, exactY), mv.target.Z)
	end

	-- A dragged end has to JOIN the road it lands on, exactly as a drawn one does. The move
	-- path re-adds its legs straight through RoadNetwork.addSegment, whose weld band stops at
	-- the host's CARRIAGEWAY edge -- placement's endpoint projection never ran here -- so an end
	-- dropped on another road's pavement came to rest as a free dead end: a stub against the
	-- kerb with a strip of grass between them and no junction. Same function, same band as
	-- placement, blind to the legs and nodes this edit is moving so a drag cannot snap onto
	-- what it is dragging.
	local ownNodes: { [Types.NodeId]: boolean } = {}
	local ownSegs: { [Types.SegmentId]: boolean } = {}
	for nodeId in targets do
		ownNodes[nodeId] = true
		for _, segId in _network:getNodes()[nodeId].segments do
			ownSegs[segId] = true
		end
	end
	for nodeId, target in targets do
		local ownReach = 0
		for _, segId in _network:getNodes()[nodeId].segments do
			local s = _network:getSegment(segId)
			if s then
				local r = getCachedRoadSpec(s.roadType).width * 0.5 + RoadConstants.SIDEWALK_WIDTH
				if r > ownReach then ownReach = r end
			end
		end
		local hit = projectEndpointToHost(target, ownReach, ownNodes, ownSegs)
		-- XZ only: moveTargetY already decided this end's height and the weld tolerates the rest.
		-- ponytail: a join across a real grade keeps the dragged height.
		targets[nodeId] = Vector3.new(hit.X, target.Y, hit.Z)
	end

	local plans: { MovePlan } = {}
	local seen: { [Types.SegmentId]: boolean } = {}
	for nodeId in targets do
		local node = _network:getNodes()[nodeId]
		for _, segId in node.segments do
			if seen[segId] then continue end
			seen[segId] = true
			local seg = _network:getSegment(segId)
			if not seg then continue end
			if seg.isRoundabout then return false, "roundabouts cannot be moved" end
			local tA, tB = targets[seg.startNode], targets[seg.endNode]
			local n0, n3 = tA or seg.p0, tB or seg.p3
			local n1, n2
			if RoadMoveGeometry.isStraight(seg.p0, seg.p1, seg.p2, seg.p3) then
				n1, n2 = n0:Lerp(n3, 1 / 3), n0:Lerp(n3, 2 / 3)
			elseif tA and tB and rot and pivot then
				-- Whole segment inside a rotating selection: handles turn with it.
				-- The per-endpoint residual makes rotate + drag compose rigidly
				-- (pure rotation: residual is zero). Mirrors the client preview.
				n1 = RoadMoveGeometry.rotateY(seg.p1, pivot, rot) + (tA - RoadMoveGeometry.rotateY(seg.p0, pivot, rot))
				n2 = RoadMoveGeometry.rotateY(seg.p2, pivot, rot) + (tB - RoadMoveGeometry.rotateY(seg.p3, pivot, rot))
			else
				n1 = seg.p1 + (n0 - seg.p0)
				n2 = seg.p2 + (n3 - seg.p3)
			end
			local reason = RoadMoveGeometry.validate(n0, n1, n2, n3, seg.roadType)
			if reason then return false, reason end
			plans[#plans + 1] = { id = segId, p0 = n0, p1 = n1, p2 = n2, p3 = n3, roadType = seg.roadType, vMode = seg.vMode, constSlope = seg.constSlope }
		end
	end

	if #plans == 0 then return false, "nothing to move" end
	-- A moved body must not sweep over a foreign node's paving (dead-end cap, bend,
	-- junction fill) -- the same silent-overlap bug as placement, via the Move tool.
	-- The edit's own set is exempt: moved nodes plus the endpoints of every reshaped
	-- segment. ponytail: plan-vs-plan overlaps inside one drag aren't judged here.
	local ignore: { [Types.NodeId]: boolean } = {}
	for nodeId in targets do
		ignore[nodeId] = true
	end
	for _, plan in plans do
		local seg = _network:getSegment(plan.id)
		if seg then
			ignore[seg.startNode] = true
			ignore[seg.endNode] = true
		end
	end
	for _, plan in plans do
		local err = _network:checkNodeFootprintOverlap(plan.p0, plan.p1, plan.p2, plan.p3, plan.roadType, ignore)
		if err then
			return false, err
		end
	end
	local paid, payErr = chargeMoveCost(plans, actor)
	if not paid then return false, payErr end
	commitMovePlans(plans)
	return true
end

-- Swing one segment's tangent handles (the node tool's arm ANGLE, and the move tool's
-- handle drag). Real geometry: conditioned, validated, priced and pushed to history like
-- any other move.
local function moveHandles(id: any, p1: any, p2: any, actor: Player?): (boolean, string?)
	if typeof(id) ~= "number" then return false, "invalid move request" end
	local seg = _network:getSegment(id)
	if not seg then return false, "no such segment" end
	if seg.isRoundabout then return false, "roundabouts cannot be moved" end
	if typeof(p1) ~= "Vector3" or typeof(p2) ~= "Vector3"
		or not isFiniteVector(p1) or not isFiniteVector(p2)
		or not inBounds(p1) or not inBounds(p2) then
		return false, "invalid handles"
	end
	local c1, c2 = RoadVerticalProfile.condition(seg.p0, p1, p2, seg.p3)
	local reason = RoadMoveGeometry.validate(seg.p0, c1, c2, seg.p3, seg.roadType)
	if reason then return false, reason end
	local paid, payErr = chargeMoveCost({ { id = id, p0 = seg.p0, p1 = c1, p2 = c2, p3 = seg.p3, roadType = seg.roadType } }, actor)
	if not paid then return false, payErr end
	RoadHistoryService.push(RoadHistoryService.capture())
	RoadService.modifySegment(id, seg.p0, c1, c2, seg.p3, seg.roadType)
	return true
end

-- Move a whole roundabout by `delta` (XZ). A roundabout is ONE object: the ring is rigid --
-- every arc translated in place, ids and metadata intact -- and the roads that feed it stretch
-- to follow their entry. The ordinary move path rebuilds each leg (remove + re-add), which is
-- exactly what drops a ring arc's isRoundabout/roundaboutId and tears the ring, so the move
-- tool refused rings outright; a rigid translate needs none of that machinery.
-- ponytail: XZ only -- the ring keeps its own height, and no rotation (a circle turned about
-- its centre is itself; only the arms would move, and they follow their entry anyway).
local function moveWholeRoundabout(raId: number, delta: Vector3, actor: Player?): (boolean, string?)
	local center: Vector3? = nil
	local radius = 0
	local ringType = "Roundabout"
	local ringIds: { Types.SegmentId } = {}
	local ringNodes: { [Types.NodeId]: boolean } = {}
	for id, s in _network:getSegments() do
		if s.isRoundabout and s.roundaboutId == raId then
			ringIds[#ringIds + 1] = id
			ringNodes[s.startNode] = true
			ringNodes[s.endNode] = true
			center = center or s.roundaboutCenter
			radius = math.max(radius, s.roundaboutRadius or 0)
			ringType = s.roadType
		end
	end
	if #ringIds == 0 or not center then return false, "no such roundabout" end

	delta = Vector3.new(delta.X, 0, delta.Z)
	if delta.Magnitude < 0.05 then return true end
	local newCenter = (center :: Vector3) + delta

	local outer = radius + getCachedRoadSpec(ringType).width * 0.5 + RoadConstants.SIDEWALK_WIDTH
	for _, axis in { Vector3.new(outer, 0, 0), Vector3.new(-outer, 0, 0), Vector3.new(0, 0, outer), Vector3.new(0, 0, -outer) } do
		if not inBounds(newCenter + axis) then return false, "roundabout out of map bounds" end
	end
	-- Rings may not nest -- the same rule the placer enforces.
	for _, s in _network:getSegments() do
		local otherCenter = s.roundaboutCenter
		if s.isRoundabout and s.roundaboutId ~= raId and otherCenter
			and sameElevationLayer(otherCenter, newCenter)
			and flatDistance(otherCenter, newCenter) < outer + (s.roundaboutRadius or 0) then
			return false, "overlaps another roundabout"
		end
	end

	-- Each arm keeps its far end and stretches its ring end by the same delta. Mirrors
	-- moveNodeSet's handle rules so a stretched arm bends the way a dragged one does.
	local arms: { MovePlan } = {}
	local seenArm: { [Types.SegmentId]: boolean } = {}
	for nodeId in ringNodes do
		local node = _network:getNodes()[nodeId]
		if not node then continue end
		for _, sid in node.segments do
			local s = _network:getSegment(sid)
			if not s or s.isRoundabout or seenArm[sid] then continue end
			seenArm[sid] = true
			local atStart = s.startNode == nodeId
			local n0 = if atStart then s.p0 + delta else s.p0
			local n3 = if atStart then s.p3 else s.p3 + delta
			local n1, n2
			if RoadMoveGeometry.isStraight(s.p0, s.p1, s.p2, s.p3) then
				n1, n2 = n0:Lerp(n3, 1 / 3), n0:Lerp(n3, 2 / 3)
			else
				n1 = s.p1 + (n0 - s.p0)
				n2 = s.p2 + (n3 - s.p3)
			end
			local reason = RoadMoveGeometry.validate(n0, n1, n2, n3, s.roadType)
			if reason then return false, reason end
			arms[#arms + 1] = { id = sid, p0 = n0, p1 = n1, p2 = n2, p3 = n3, roadType = s.roadType }
		end
	end

	local priced: { MovePlan } = {}
	for _, id in ringIds do
		local s = _network:getSegment(id)
		if s then
			priced[#priced + 1] = { id = id, p0 = s.p0 + delta, p1 = s.p1 + delta,
				p2 = s.p2 + delta, p3 = s.p3 + delta, roadType = s.roadType }
		end
	end
	for _, a in arms do priced[#priced + 1] = a end
	local paid, payErr = chargeMoveCost(priced, actor)
	if not paid then return false, payErr end

	RoadHistoryService.push(RoadHistoryService.capture())
	_network:moveRoundaboutBy(raId, delta)
	for _, a in arms do
		local s = _network:getSegment(a.id)
		if s then
			s.p0, s.p1, s.p2, s.p3 = a.p0, a.p1, a.p2, a.p3
			_network:touchSegment(a.id)
		end
	end

	local topologyChange = applyChanges()
	RoadReplicationService.broadcastTopologyDeltas()
	for _, id in topologyChange.segmentIds do _pendingNavDirtySegs[id] = true end
	for _, id in topologyChange.removedSegmentIds do _pendingNavRemovedSegs[id] = true end
	scheduleNavRebuild(nil, true, false)
	syncSegmentGrades(topologyChange)
	notifyTopologyListeners(topologyChange)
	return true
end

-- `actor` is who dragged, supplied by the remote handler and never read off the request.
-- Used only to send the cost tag back to them alone.
function RoadService.moveFromRequest(req: any, actor: Player?): (boolean, string?)
	if typeof(req) ~= "table" then
		return false, "invalid move request"
	end

	if req.kind == "junction" then
		local hasShaping = req.reset ~= nil or req.corner ~= nil or req.offset ~= nil or req.flat ~= nil
		if hasShaping then
			local ok, err = RoadService.shapeJunction(req)
			if not ok then return false, err end
		end
		-- One drag of an arm dot can change BOTH the setback and the angle, and they are one
		-- gesture, so they arrive as one request: this remote is rate-limited, and a second
		-- fire in the same frame would simply be dropped on the floor. Order matters -- the
		-- swing rebuilds the segment, and modifySegment carries the setback written above
		-- onto the replacement.
		local h = req.handles
		if typeof(h) == "table" then
			return moveHandles(h.id, h.p1, h.p2, actor)
		end
		if not hasShaping then return false, "nothing to change" end
		return true
	end

	-- A roundabout moves as ONE object, by an offset -- see moveWholeRoundabout.
	if req.kind == "roundabout" then
		if typeof(req.id) ~= "number" or req.id ~= req.id then return false, "invalid move request" end
		if typeof(req.delta) ~= "Vector3" or not isFiniteVector(req.delta) then return false, "invalid move target" end
		if req.delta.Magnitude > RoadConstants.MAP_HALF_EXTENT * 2 then return false, "move out of map bounds" end
		return moveWholeRoundabout(math.floor(req.id), req.delta, actor)
	end

	if req.kind == "group" then
		if typeof(req.moves) ~= "table" then return false, "invalid move request" end
		local rot = if typeof(req.rot) == "number" and req.rot == req.rot then req.rot else nil
		local pivot = if typeof(req.pivot) == "Vector3" and isFiniteVector(req.pivot) then req.pivot else nil
		return moveNodeSet(req.moves, rot, pivot, req.snapGround == true, req.exactY == true, actor)
	end

	if typeof(req.id) ~= "number" then
		return false, "invalid move request"
	end

	if req.kind == "handles" then
		return moveHandles(req.id, req.p1, req.p2, actor)
	end

	if typeof(req.target) ~= "Vector3" or not isFiniteVector(req.target) or not inBounds(req.target) then
		return false, "move out of map bounds"
	end

	if req.kind == "segment" then
		local seg = _network:getSegment(req.id)
		if not seg then return false, "no such segment" end
		if seg.isRoundabout then return false, "roundabouts cannot be moved" end
		local mid = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, 0.5)
		local target = Vector3.new(req.target.X, moveTargetY(mid, req.target, nil, nil), req.target.Z)
		local n0, n1, n2, n3 = RoadMoveGeometry.bendThrough(seg.p0, seg.p3, target)
		local reason = RoadMoveGeometry.validate(n0, n1, n2, n3, seg.roadType)
		if reason then return false, reason end
		local paid, payErr = chargeMoveCost({ { id = req.id, p0 = n0, p1 = n1, p2 = n2, p3 = n3, roadType = seg.roadType } }, actor)
		if not paid then return false, payErr end
		RoadHistoryService.push(RoadHistoryService.capture())
		RoadService.modifySegment(req.id, n0, n1, n2, n3, seg.roadType)
		return true
	end

	if req.kind ~= "node" then
		return false, "invalid move kind"
	end
	return moveNodeSet({ { id = req.id, target = req.target } }, nil, nil, req.snapGround == true, req.exactY == true, actor)
end

-- Junction trim distance for an arm at an intersection (corner fillet plus the
-- steep-approach apron extension). NPC stop lines and crosswalk paths use this so
-- they stay aligned with the rendered junction.
function RoadService.armJunctionBoundary(nodeId: Types.NodeId, segId: Types.SegmentId): number
	return RoadSceneRenderer.armJunctionBoundary(nodeId, segId)
end

-- Distance from the node to the painted zebra's band. The mouth is square at the wider of
-- the arm's two corner fillets; the paint is seated on their mean.
function RoadService.crosswalkSeat(nodeId: Types.NodeId, segId: Types.SegmentId): number
	return RoadSceneRenderer.crosswalkSeat(nodeId, segId)
end

-- Toggle one lane-change gate connection. Validation of edge existence happens
-- here against the live nav graph.
function RoadService.setLaneChangeConnection(gateId: string, fromEdgeId: string, toEdgeId: string, connected: boolean)
	RoadTurnPermissionStore.setLaneChangeConnection(gateId, fromEdgeId, toEdgeId, connected)
end

-- Delete an ENTIRE roundabout (every ring arc + its island) and rejoin the roads
-- that fed it: each former arm runs straight in to the centre so they reconnect as
-- a junction (or a through-road for two opposite arms) where the ring used to be.
local function removeWholeRoundabout(raId: number, center: Vector3?)
	local ringSegIds: { Types.SegmentId } = {}
	local ringNodeIds: { [Types.NodeId]: boolean } = {}
	for id, s in _network:getSegments() do
		if s.isRoundabout and s.roundaboutId == raId then
			ringSegIds[#ringSegIds + 1] = id
			ringNodeIds[s.startNode] = true
			ringNodeIds[s.endNode] = true
			center = center or s.roundaboutCenter
		end
	end
	if #ringSegIds == 0 then return end

	-- Capture each entry (a ring node with a non-ring arm): position + arm road type.
	local entries: { { pos: Vector3, roadType: string } } = {}
	for nodeId in ringNodeIds do
		local node = _network:getNodes()[nodeId]
		if node then
			for _, sid in node.segments do
				local s = _network:getSegment(sid)
				if s and not s.isRoundabout then
					entries[#entries + 1] = { pos = node.position, roadType = s.roadType }
					break
				end
			end
		end
	end

	for _, id in ringSegIds do
		pcall(TerrainGradeService.ungradeSegmentId, id)
		_network:removeSegment(id)
	end

	if center then
		for _, e in entries do
			local chord = center - e.pos
			if chord.Magnitude > RoadConstants.MIN_SEGMENT_LENGTH then
				pcall(function()
					_network:addSegment(e.pos, e.pos + chord / 3, e.pos + chord * (2 / 3), center, e.roadType)
				end)
			end
		end
	end

	local topologyChange = applyChanges()
	RoadReplicationService.broadcastTopologyDeltas()
	for _, id in topologyChange.segmentIds do _pendingNavDirtySegs[id] = true end
	for _, id in topologyChange.removedSegmentIds do _pendingNavRemovedSegs[id] = true end
	scheduleNavRebuild(nil, true, false)
	for _, nid in topologyChange.nodeIds do
		RoadTurnPermissionStore.invalidate(nid)
		if _network:getNodes()[nid] and _network:getNodeKind(nid) == "intersection" then
			RoadReplicationService.queueIntersectionBroadcast(nid)
		end
	end
	syncSegmentGrades(topologyChange)
	notifyTopologyListeners(topologyChange)
end

-- Delete a segment from a transport-checked client request. Resolves by id or
-- nearest world position.
function RoadService.removeSegmentFromRequest(segmentId: any, worldPos: any)
	local resolvedSegmentId: number? = nil
	if typeof(segmentId) == "number" then
		resolvedSegmentId = segmentId
	end
	if (not resolvedSegmentId or not _network:getSegment(resolvedSegmentId)) and typeof(worldPos) == "Vector3" then
		resolvedSegmentId = nearestSegmentIdFromWorldPos(worldPos)
	end
	if not resolvedSegmentId or not _network:getSegment(resolvedSegmentId) then
		return
	end

	RoadHistoryService.push(RoadHistoryService.capture())
	-- Clicking any part of a roundabout deletes the WHOLE ring and reconnects the
	-- roads; clicking an ordinary road just deletes that segment.
	local clicked = _network:getSegment(resolvedSegmentId)
	if clicked and clicked.isRoundabout and clicked.roundaboutId then
		removeWholeRoundabout(clicked.roundaboutId, clicked.roundaboutCenter)
	else
		RoadService.removeSegment(resolvedSegmentId)
	end
end

-- Batch delete from a transport-checked client request (the bulldozer sweep sends its
-- whole selection at once): ONE history push, ONE topology flush, ONE broadcast, ONE
-- nav rebuild, ONE regrade and ONE listener fan-out for the entire batch. Per-segment
-- requests repeated that full pipeline -- with a full-city history snapshot each --
-- which made big sweeps take seconds. entries: { { id: number?, point: Vector3? } }.
function RoadService.removeSegmentsFromRequest(entries: any)
	if typeof(entries) ~= "table" then return end
	local plainIds: { Types.SegmentId } = {}
	local ringIds: { [number]: boolean } = {}
	local seen: { [number]: boolean } = {}
	for _, e in entries do
		if typeof(e) ~= "table" then continue end
		local id: number? = if typeof(e.id) == "number" then e.id else nil
		local seg = if id then _network:getSegment(id) else nil
		if not seg and typeof(e.point) == "Vector3" and isFiniteVector(e.point) then
			id = nearestSegmentIdFromWorldPos(e.point)
			seg = if id then _network:getSegment(id) else nil
		end
		if not seg or not id or seen[id] then continue end
		seen[id] = true
		if seg.isRoundabout and seg.roundaboutId then
			ringIds[seg.roundaboutId] = true
		else
			plainIds[#plainIds + 1] = id
		end
	end
	if #plainIds == 0 and next(ringIds) == nil then return end

	RoadHistoryService.push(RoadHistoryService.capture())

	-- Whole rings first; each reconnects its arms and runs its own flush (rare in a sweep).
	for raId in ringIds do
		removeWholeRoundabout(raId, nil)
	end
	if #plainIds == 0 then return end

	local affectedIntersections: { Types.NodeId } = {}
	local seenNode: { [Types.NodeId]: boolean } = {}
	for _, id in plainIds do
		local seg = _network:getSegment(id)
		if not seg then continue end -- a ring removal above may have consumed it
		notifySegmentRemovingListeners(id)
		for _, nodeId in { seg.startNode, seg.endNode } do
			if not seenNode[nodeId] and _network:getNodeKind(nodeId) == "intersection" then
				seenNode[nodeId] = true
				table.insert(affectedIntersections, nodeId)
			end
		end
		pcall(TerrainGradeService.ungradeSegmentId, id)
		_network:removeSegment(id)
		_pendingNavRemovedSegs[id] = true
	end

	local topologyChange = applyChanges()
	RoadReplicationService.broadcastTopologyDeltas()
	for _, changedId in topologyChange.segmentIds do
		_pendingNavDirtySegs[changedId] = true
	end
	for _, removedId in topologyChange.removedSegmentIds do
		_pendingNavRemovedSegs[removedId] = true
	end
	scheduleNavRebuild()
	for _, nodeId in affectedIntersections do
		if _network:getNodes()[nodeId] then
			RoadTurnPermissionStore.invalidate(nodeId)
			if _network:getNodeKind(nodeId) == "intersection" then
				RoadReplicationService.queueIntersectionBroadcast(nodeId)
			end
		end
	end
	syncSegmentGrades(topologyChange)
	notifyTopologyListeners(topologyChange)
end

function RoadService.Init()
	_network = RoadNetwork.new()
	-- Cars/buses/trucks never see rail edges; trains never see road edges.
	_navGraph = RoadNavigationGraph.new(function(seg)
		return getCachedRoadSpec(seg.roadType).isRail ~= true
	end)
	_railGraph = RoadNavigationGraph.new(function(seg)
		return getCachedRoadSpec(seg.roadType).isRail == true
	end)

	RoadTurnPermissionStore.init({
		network = _network,
		navGraph = _navGraph,
		scheduleNavRebuild = scheduleNavRebuild,
		broadcastTurnPermissions = RoadReplicationService.broadcastTurnPermissions,
	})

	RoadSceneRenderer.init(_network, _navGraph)
	RoadHistoryService.init(function()
		return _network:getSegments()
	end, applySnapshot)

	RoadReplicationService.init({
		roads = RoadService,
		network = _network,
		navGraph = _navGraph,
		getPermissions = RoadTurnPermissionStore.getOrInit,
		clearPermissions = RoadTurnPermissionStore.invalidate,
		armMarkingSetback = RoadSceneRenderer.armMarkingSetback,
	})
end

function RoadService.Bind()
	RoadReplicationService.bind()
end

function RoadService.Start()
	-- Render any roads that were already restored before Start ran.
	task.defer(refreshAllMarkingVisuals)

	-- Changing the driving side moves every lane to the other side of the centreline, so
	-- everything derived from lane geometry goes stale at once: the nav graph (lane
	-- offsets, which lane may turn where) and the painted markings (which edge carries the
	-- yellow line). Rebuild both. RoadRules fires this only when the value actually
	-- changed, so a city loading on the side it was already built for costs nothing.
	-- The nav rebuild is deferred, so the notify has to be too: signals re-place their
	-- poles off the FRESH geometry, on the kerb the new side puts them on.
	RoadRules.onDrivingSideChanged(function()
		RoadService.rebuildNavigationGraph()
		task.defer(function()
			refreshAllMarkingVisuals()
			notifyTopologyListeners(nil)
		end)
	end)
end

return RoadService
