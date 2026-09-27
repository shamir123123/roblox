--!strict
-- NPCWalkingService
-- Sidewalk graph + NPC walker logic in one module.
--
-- KEY DESIGN: crosswalk nodes are placed at the EXACT same world position
-- as the rendered zebra stripes (same formula as RoadSceneRenderer/RoadRenderer).
-- Road-crossing edges ONLY exist between those paired nodes, so NPCs can
-- never cut across the road at a random point.

local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local Workspace       = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

local CitizenModel = require(ReplicatedStorage.City.CitizenModel)

local PathFollower         = require(ServerScriptService.Services.Util.PathFollower)
local RoadConstants        = require(ReplicatedStorage.Road.RoadConstants)
local BezierUtil           = require(ReplicatedStorage.Road.BezierUtil)
local RoadTypeCatalog      = require(ReplicatedStorage.Road.RoadTypeCatalog)
local IntersectionRenderer = require(ReplicatedStorage.Road.IntersectionRenderer)

local NPCWalkingService = {}

-- ── Injected dependencies ─────────────────────────────────────────────────────
local _net:         any
local _roadService: any

-- ── Tuning ────────────────────────────────────────────────────────────────────
-- Half-size world (RoadConstants.WORLD_SCALE): walk speeds and sidewalk-graph stud
-- distances scale together so walkers cover the same blocks per second.
local WS = RoadConstants.WORLD_SCALE
local WALK_SPEED        = 5 * WS    -- studs/s normal walking
local CROSSWALK_SPEED   = 3.5 * WS  -- studs/s while crossing the road (slower, careful)
local STEP_DIST         = 0.25 * WS -- waypoint arrival threshold (studs)
local REPATH_INTERVAL   = 12      -- seconds before forcing a re-path
local MAX_WALKERS       = 3000    -- bodies, all of them near a player (see BODY_RANGE)
-- A citizen walking where no player can see them walks as a Tier-2 plan (CitizenAgentService):
-- real route, real time, no body. Bodies go to walks within BODY_RANGE of a player and are
-- handed back past DEMOTE_RANGE, so the capped pool is always spent where someone is looking
-- -- first-come bodies used to sit across the map while the camera's street stood empty.
local BODY_RANGE        = 1000    -- studs (500 m): everyone walking this close has a body
local DEMOTE_RANGE      = 1200
-- Walkers past MID_TICK_DIST from every player step at MID_TICK instead of WALKER_TICK: still
-- walking their real route, just in coarser steps nobody that far away can see.
local MID_TICK_DIST     = 300
local MID_TICK          = 1 / 10
local DEMOTE_CHECK      = 1       -- s between sweeps for far bodies
local WALKER_COOLDOWN   = 0.5     -- per-player spawn rate limit
local TARGET_WALKERS    = 18      -- default background pedestrians so quiet cities still feel lived-in
local MAX_AMBIENT_WALKERS = 40
local REPATH_RETRY_WAIT = 2       -- seconds to wait before retrying a failed repath
local WALK_SEND_DT      = 1 / 12  -- CFrame replication rate when a player is near
local WALKER_TICK       = 1 / 20  -- server movement rate; clients smooth between writes
local CROSS_CHECK_RADIUS = 24 * WS -- kerb check: cars this close to the zebra centre block crossing
local CROSS_WAIT_MAX     = 6      -- s a walker waits at the kerb before crossing anyway (impatience)
local FOOT_CLEARANCE     = 0.04   -- keeps the model's feet just above the pavement surface

-- ── Graph constants ──────────────────────────────────────────────────────────
local SAMPLE_SPACING      = 3 * WS    -- studs between sidewalk waypoints
local DEFAULT_SNAP_RADIUS = 8 * WS
local NODE_MERGE_DIST     = 4.0 * WS  -- wide enough to merge near-duplicate crosswalk nodes from adjacent segs at the same junction end
local STRIP_MERGE_DIST    = 1.0 * WS  -- interior strip samples only de-dup true overlaps; NODE_MERGE_DIST > SAMPLE_SPACING was collapsing every other strip node into ragged double spacing
local SAME_SIDE_LINK_DIST = 14 * WS   -- max dist to link same-side strip ends at a junction
local BUCKET              = 12 * WS

-- Crosswalk geometry — must exactly mirror RoadSceneRenderer / RoadRenderer:
--   zebraCentre = armBoundary + CROSSWALK_SETBACK
--                + STOP_LINE_DEPTH + CROSSWALK_GAP_FROM_STOP
--                + CROSSWALK_DEPTH * 0.5
-- We insert one crosswalk node per side at that exact t-parameter on the Bezier.
local CW_SETBACK      = RoadConstants.CROSSWALK_SETBACK
local CW_DEPTH        = RoadConstants.CROSSWALK_DEPTH
local JUNCTION_MARGIN = RoadConstants.JUNCTION_MARGIN

-- ── Graph state ───────────────────────────────────────────────────────────────
type SWNode = {
	id:          number,
	pos:         Vector3,
	neighbours:  { number },
	isCrosswalk: boolean,   -- true = this node sits on a zebra crossing
}

local _nodes:   { [number]: SWNode } = {}
local _nextId   = 0
local _built    = false
local _version  = 0
local _buckets: { [string]: { number } } = {}
local _rebuildListeners: { () -> () } = {}
-- Set of "a:b" edge keys (a < b) that are genuine zebra crossing edges.
-- Only these count as road crossings in A*; same-side links between
-- crosswalk-tagged nodes are NOT crossings.
local _crossingEdges: { [number]: boolean } = {}

-- ── Walker state ──────────────────────────────────────────────────────────────
type Walker = {
	model:       Model,
	waypoints:   { Vector3 },
	crossFlags:  { boolean },  -- parallel to waypoints; true = this leg crosses a zebra
	wpIndex:     number,
	repathAt:    number,
	graphVer:    number,
	pos:         Vector3,      -- authoritative position; the part CFrame is only a throttled view of it
	sendAccum:   number,       -- time since the last replicated CFrame write
	crossingCommitted: boolean,-- already stepped onto the current zebra leg
	crossWait:   number,       -- time spent waiting at the kerb for a gap
	-- Directed-commuter extension (all nil for an ambient/test walker). A directed
	-- walker follows a fixed path from->to, fires onArrive once and despawns; it never
	-- random-repaths.
	directed:    boolean?,
	commuterId:  number?,
	destPos:     Vector3?,
	onArrive:    (() -> ())?,
	appearance:  CitizenModel.Appearance?, -- kept so a demoted body re-promotes as the same person
	lodMid:      boolean?,  -- past MID_TICK_DIST from every player: steps at MID_TICK
	lodAccum:    number?,
	lodCheckAt:  number?,
}

local _walkers: { Walker } = {}
-- Directed commuter walkers (a subset of _walkers) keyed by id, for despawn/cleanup.
local _commuters: { [number]: Walker } = {}
local _nextCommuterId = 0
-- Tier 2 of the population (CitizenAgentService), injected in Bootstrap rather than
-- required, because it requires US for findPath/spawnCommuter -- a plain require would be
-- a cycle. Optional: with it unset, overflow falls back to the historical instant arrival.
local _agentService: any
-- Commuter id -> the id that now walks it (a body that became a plan, or a plan that got a
-- body), so the citizen's handle keeps cancelling / following the same person.
local _aliases: { [number]: number } = {}
local _nextWalkerDebugId = 0
local COMMUTER_SNAP_RADIUS = 60   -- doors/cars sit off the sidewalk centreline; snap generously
local _heartbeat: RBXScriptConnection?
local _topologyDisconnect: (() -> ())?
local _rebuildQueued = false
local _pendingDirtySegs: { [any]: boolean } = {}
local _pendingFullRebuild = false
local _lastRebuildAt = 0
local REBUILD_DEBOUNCE = 2

local function hasSidewalkNodes(): boolean
	return next(_nodes) ~= nil
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 1 – Sidewalk Graph (was SidewalkService)
-- ═══════════════════════════════════════════════════════════════════════════════

-- FIX 6: correct bucket key — takes raw cell indices, not world coords
local function bkey(cx: number, cz: number): string
	return cx .. ":" .. cz
end

local function cellOf(x: number, z: number): (number, number)
	return math.floor(x / BUCKET), math.floor(z / BUCKET)
end

local function addToBucket(id: number, pos: Vector3)
	local cx, cz = cellOf(pos.X, pos.Z)
	local k = bkey(cx, cz)
	if not _buckets[k] then _buckets[k] = {} end
	table.insert(_buckets[k], id)
end

local function nearestNodeTo(pos: Vector3, maxDist: number): (number?, number)
	local bestId: number? = nil
	local bestD  = maxDist
	local bx, bz = cellOf(pos.X, pos.Z)
	local r = math.ceil(maxDist / BUCKET)
	for dx = -r, r do
		for dz = -r, r do
			-- FIX 6: pass cell indices directly
			local bucket = _buckets[bkey(bx + dx, bz + dz)]
			if bucket then
				for _, nid in bucket do
					local n = _nodes[nid]
					if n then
						local d = math.sqrt(
							(n.pos.X - pos.X)^2 + (n.pos.Z - pos.Z)^2
						)
						if d < bestD then bestD = d; bestId = nid end
					end
				end
			end
		end
	end
	return bestId, bestD
end

local function newNode(pos: Vector3): number
	_nextId += 1
	_nodes[_nextId] = { id = _nextId, pos = pos, neighbours = {}, isCrosswalk = false }
	addToBucket(_nextId, pos)
	return _nextId
end

local function link(a: number, b: number, isCrossing: boolean?)
	if a == b then return end
	local na, nb = _nodes[a], _nodes[b]
	if not na or not nb then return end
	for _, v in na.neighbours do if v == b then return end end
	table.insert(na.neighbours, b)
	table.insert(nb.neighbours, a)
	if isCrossing then
		na.isCrosswalk = true
		nb.isCrosswalk = true
		-- Use integer-keyed table instead of string concat for the edge set
		local lo = if a < b then a else b
		local hi = if a < b then b else a
		_crossingEdges[lo * 1000000 + hi] = true
	end
end

local function getOrCreate(pos: Vector3, mergeDist: number?): number
	local existing = nearestNodeTo(pos, mergeDist or NODE_MERGE_DIST)
	return existing or newNode(pos)
end

-- ── Geometry helpers ──────────────────────────────────────────────────────────

-- World position on the sidewalk centreline at parameter t along seg.
local function sidewalkPos(seg: any, t: number, sign: number, swOff: number, swY: number): Vector3
	local ctr     = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local rawTang = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local flat    = Vector3.new(rawTang.X, 0, rawTang.Z)
	if flat.Magnitude < 1e-4 then
		-- fallback: use chord direction
		flat = Vector3.new(seg.p3.X - seg.p0.X, 0, seg.p3.Z - seg.p0.Z)
	end
	local dir    = flat.Unit
	local normal = Vector3.new(-dir.Z, 0, dir.X)  -- left normal
	-- RoadRenderer places the sidewalk on top of the road slab, then raises it
	-- by its full height. The old graph omitted half the slab thickness, sinking feet.
	local surfaceY = ctr.Y + RoadConstants.ROAD_THICKNESS * 0.5 + swY + FOOT_CLEARANCE
	return Vector3.new(
		ctr.X + normal.X * (sign * swOff),
		surfaceY,
		ctr.Z + normal.Z * (sign * swOff)
	)
end

-- Compute the arm boundary distance for a given node+seg pair.
-- Mirrors RoadSceneRenderer.nodeArmBoundary EXACTLY:
--   use IntersectionRenderer.armBoundaryDistances (fillet-based, per-arm).
local function armBoundaryForSeg(network: any, nodeId: any, seg: any): number
	local node = network:getNodes()[nodeId]
	if not node then return 0 end

	-- Build the arms list exactly as RoadSceneRenderer.armsAndSegsForNode does
	local arms:   { IntersectionRenderer.Arm } = {}
	local segIds: { any }                       = {}
	for _, sid in node.segments do
		local s = network:getSegment(sid)
		if not s or s.isArc then continue end
		local raw: Vector3
		if s.startNode == nodeId then
			raw = BezierUtil.tangent(s.p0, s.p1, s.p2, s.p3, 0)
		else
			raw = -BezierUtil.tangent(s.p0, s.p1, s.p2, s.p3, 1)
		end
		if raw.Magnitude < 1e-6 then
			raw = if s.startNode == nodeId then (s.p3 - s.p0) else (s.p0 - s.p3)
		end
		if raw.Magnitude > 1e-6 then
			local corner, offset = IntersectionRenderer.armOverrides(s, nodeId)
			table.insert(arms,   { dir = raw.Unit, width = RoadTypeCatalog.getOrDefault(s.roadType).width, corner = corner, offset = offset })
			table.insert(segIds, sid)
		end
	end

	-- Mirror the 2-arm width-equalisation that RoadSceneRenderer applies
	if #arms == 2 then
		local w = math.min(arms[1].width, arms[2].width)
		arms[1].width = w
		arms[2].width = w
	end

	-- Prefer the renderer's junction boundary (fillet + steep-approach apron extension)
	-- so crosswalk walking paths stay on the rendered crosswalks.
	if _roadService and _roadService.armJunctionBoundary then
		local b = _roadService.armJunctionBoundary(nodeId, seg.id)
		if b and b > 0 then
			return b
		end
	end

	-- Per-arm fillet distances (same call the renderer makes)
	local dists = IntersectionRenderer.armBoundaryDistances(node.position, arms)
	for i, sid in segIds do
		if sid == seg.id then
			return dists[i] or (node.position and 0 or 0)
		end
	end
	-- Fallback: max half-width + margin (should never be reached)
	local maxHalf = 0
	for _, a in arms do maxHalf = math.max(maxHalf, a.width * 0.5) end
	return maxHalf + JUNCTION_MARGIN
end

-- Given armBoundary distance from the node, compute the arc-length parameter t
-- along the Bezier that corresponds to that distance FROM the node end.
-- fromStart=true  → measure from p0 (startNode end)
-- fromStart=false → measure from p3 (endNode end)
local function tAtArcDist(seg: any, dist: number, fromStart: boolean): number
	local STEPS = 32
	local totalLen = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, STEPS)
	if totalLen < 1e-3 then return 0 end
	local targetDist = if fromStart then dist else (totalLen - dist)
	targetDist = math.clamp(targetDist, 0, totalLen)
	-- Walk the cumulative arc to find t
	local prev = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, 0)
	local cumLen = 0
	for i = 1, STEPS do
		local t    = i / STEPS
		local curr = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local step = (curr - prev).Magnitude
		if cumLen + step >= targetDist then
			local f = (targetDist - cumLen) / math.max(step, 1e-6)
			return ((i - 1) + f) / STEPS
		end
		cumLen = cumLen + step
		prev   = curr
	end
	return if fromStart then 1 else 0
end

-- ── Strip builder ─────────────────────────────────────────────────────────────
-- Builds a sidewalk strip along one side of a segment.
-- tStart/tEnd clip the strip so it never enters the intersection box;
-- pass 0/1 for a free end (dead-end or corner).
-- Returns (firstNodeId, lastNodeId, stripStartId, stripEndId).
local function buildStrip(
	seg:    any,
	sign:   number,  -- +1 left, -1 right
	swOff:  number,
	swY:    number,
	steps:  number,
	tStart: number,  -- t parameter to begin the strip (0 = full start)
	tEnd:   number   -- t parameter to end the strip   (1 = full end)
): (number, number, number, number)
	local prev:       number? = nil
	local first:      number? = nil
	local last:       number? = nil
	local stripStart: number? = nil
	local stripEnd:   number? = nil
	for i = 0, steps do
		local t   = tStart + (tEnd - tStart) * (i / steps)
		local pos = sidewalkPos(seg, t, sign, swOff, swY)
		-- Wide merge only at the strip ends (they must fuse with crosswalk and
		-- corner nodes); interior samples use a tight radius so consecutive
		-- 3-stud samples don't merge into each other.
		local merge = if i == 0 or i == steps then NODE_MERGE_DIST else STRIP_MERGE_DIST
		local nid = getOrCreate(pos, merge)
		if prev then link(prev, nid) end
		if not first then first = nid end
		if i == 0     then stripStart = nid end
		last     = nid
		stripEnd = nid
		prev = nid
	end
	return first :: number, last :: number, stripStart :: number, stripEnd :: number
end

-- ── Crosswalk node builder ─────────────────────────────────────────────────────
-- Places two sidewalk nodes at the exact rendered zebra-stripe centre on both
-- sides of the road, then links them as a crossing edge.
-- This mirrors the formula in RoadRenderer.crossing():
--   zebraDistFromSegEnd = armBoundary + CROSSWALK_SETBACK
--                        + STOP_LINE_DEPTH + CROSSWALK_GAP_FROM_STOP
--                        + CROSSWALK_DEPTH * 0.5
-- The crossing edge is the ONLY edge that crosses the carriageway.
local function buildCrosswalkNodesForSeg(
	network:   any,
	seg:       any,
	nodeId:    any,    -- road-network node at this end
	fromStart: boolean,-- true = this end is seg.startNode
	swOff:     number,
	swY:       number
): (number?, number?) -- (leftNodeId, rightNodeId) or nil if skipped
	if seg.isArc then return nil, nil end
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	if spec.noCrosswalk then return nil, nil end

	-- Only place crosswalks at intersection nodes (≥3 road-network segments)
	local node = network:getNodes()[nodeId]
	if not node then return nil, nil end
	local realSegCount = 0
	for _, sid in node.segments do
		local s = network:getSegment(sid)
		if s and not s.isArc then realSegCount += 1 end
	end
	if realSegCount < 3 then return nil, nil end  -- not an intersection → no zebra

	-- Roundabout entries are yield-controlled, not zebra crossings (mirror RoadSceneRenderer's
	-- paint suppression). No painted crosswalk there, so no ped crossing node either.
	for _, sid in node.segments do
		local s = network:getSegment(sid)
		if s and s.isRoundabout then return nil, nil end
	end

	local armBound  = armBoundaryForSeg(network, nodeId, seg)
	-- Walk where the stripes actually ARE. The paint is seated on the arm's junction
	-- boundary INCLUDING any steep-approach apron or shallow-fork pushback
	-- (RoadSceneRenderer.crosswalkSeat); the plain corner-fillet boundary above carries
	-- neither, so on those arms it sits studs behind the stripes.
	if _roadService and _roadService.crosswalkSeat then
		local seat = _roadService.crosswalkSeat(nodeId, seg.id)
		if seat and seat > 0 then armBound = seat end
	end
	-- Mirrors RoadRenderer lines 549-556 EXACTLY:
	--   r = crosswalkStartRadius + CROSSWALK_SETBACK
	--   zebraDist = r + CROSSWALK_DEPTH * 0.5
	-- crosswalkStartRadius == armBound (nodeArmBoundary),
	-- STOP_LINE_DEPTH and CROSSWALK_GAP_FROM_STOP are for the stop LINE only.
	local zebraDistFromNode = armBound + CW_SETBACK + CW_DEPTH * 0.5

	-- Convert that distance-from-node to a t parameter along the Bezier.
	-- fromStart=true  → distance measured from p0; fromStart=false → from p3.
	local t = tAtArcDist(seg, zebraDistFromNode, fromStart)

	-- Place one node on each side of the road at that t
	local posL = sidewalkPos(seg, t,  1, swOff, swY)
	local posR = sidewalkPos(seg, t, -1, swOff, swY)

	local nidL = getOrCreate(posL)
	local nidR = getOrCreate(posR)

	-- Tag both nodes as crosswalk nodes
	if _nodes[nidL] then _nodes[nidL].isCrosswalk = true end
	if _nodes[nidR] then _nodes[nidR].isCrosswalk = true end

	-- The single crossing edge between them (this is the zebra)
	link(nidL, nidR, true)

	return nidL, nidR
end

-- ── Graph build ───────────────────────────────────────────────────────────────
local function rebuildGraph()
	table.clear(_nodes)
	table.clear(_buckets)
	table.clear(_crossingEdges)
	_nextId = 0
	_built  = false

	if not _roadService then return end
	local network  = _roadService.getNetwork()
	local segments = network:getSegments()

	-- tipEnds[roadNodeId][sign] = { sidewalkNodeId, ... }
	-- Used after strip building to stitch corners and junction approaches.
	local tipEnds: { [any]: { [number]: { number } } } = {}
	-- crosswalkTips[roadNodeId][sign] = crosswalkNodeId
	-- The exact sidewalk node that sits at the zebra edge on each side.
	local crosswalkTips: { [any]: { [number]: number } } = {}

	local function recordTip(roadNodeId: any, sign: number, nid: number)
		if not tipEnds[roadNodeId] then tipEnds[roadNodeId] = {} end
		if not tipEnds[roadNodeId][sign] then tipEnds[roadNodeId][sign] = {} end
		table.insert(tipEnds[roadNodeId][sign], nid)
	end

	local function recordCrosswalkTip(roadNodeId: any, sign: number, nid: number)
		if not crosswalkTips[roadNodeId] then crosswalkTips[roadNodeId] = {} end
		crosswalkTips[roadNodeId][sign] = nid
	end

	-- Pass 1: crosswalk t-parameters first, then clipped sidewalk strips.
	for _, seg in segments do
		if seg.isArc then continue end
		local spec   = RoadTypeCatalog.getOrDefault(seg.roadType)
		local swOff  = spec.width * 0.5 + RoadConstants.SIDEWALK_WIDTH * 0.5
		local swY    = RoadConstants.SIDEWALK_HEIGHT
		local segLen = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 16)

		-- Compute the t-parameter at which the zebra sits on each end.
		-- The strip is clipped to [tClipStart, tClipEnd] so it never enters
		-- the intersection box — the crosswalk node becomes the strip endpoint.
		local function zebraT(nodeId: any, fromStart: boolean): number?
			local node = network:getNodes()[nodeId]
			if not node then return nil end
			local realSegs = 0
			for _, sid in node.segments do
				local s = network:getSegment(sid)
				if s and not s.isArc then realSegs += 1 end
			end
			if realSegs < 3 then return nil end  -- not an intersection
			if spec.noCrosswalk then return nil end
			local armBound = armBoundaryForSeg(network, nodeId, seg)
			local dist     = armBound + CW_SETBACK + CW_DEPTH * 0.5
			return tAtArcDist(seg, dist, fromStart)
		end

		local tS = zebraT(seg.startNode, true)   -- nil = free end
		local tE = zebraT(seg.endNode,   false)  -- nil = free end
		local tClipStart = tS or 0
		local tClipEnd   = tE or 1

		-- Guard: if segment is too short the clip range may invert
		if tClipStart >= tClipEnd - 1e-4 then
			tClipStart = 0 ; tClipEnd = 1
		end

		local steps = math.max(2, math.ceil(segLen * (tClipEnd - tClipStart) / SAMPLE_SPACING))

		-- Build clipped strips — they stop exactly at the zebra node on each
		-- intersection end, so no strip node ever falls inside the junction box.
		local sNidL, eNidL, ssL, seL = buildStrip(seg,  1, swOff, swY, steps, tClipStart, tClipEnd)
		local sNidR, eNidR, ssR, seR = buildStrip(seg, -1, swOff, swY, steps, tClipStart, tClipEnd)
		recordTip(seg.startNode,  1, sNidL) ; recordTip(seg.endNode,  1, eNidL)
		recordTip(seg.startNode, -1, sNidR) ; recordTip(seg.endNode, -1, eNidR)

		-- Pass 1b: crosswalk nodes — link directly to the strip-end nodes which
		-- are now AT the zebra position (same t), so the link distance is ~0.
		local cwL, cwR = buildCrosswalkNodesForSeg(network, seg, seg.startNode, true, swOff, swY)
		if cwL and cwR then
			recordCrosswalkTip(seg.startNode,  1, cwL)
			recordCrosswalkTip(seg.startNode, -1, cwR)
			recordTip(seg.startNode,  1, cwL)
			recordTip(seg.startNode, -1, cwR)
			-- ssL/ssR are now at (or merged with) the crosswalk node
			if ssL and ssL ~= cwL then link(ssL, cwL) end
			if ssR and ssR ~= cwR then link(ssR, cwR) end
		end

		local cwL2, cwR2 = buildCrosswalkNodesForSeg(network, seg, seg.endNode, false, swOff, swY)
		if cwL2 and cwR2 then
			recordCrosswalkTip(seg.endNode,  1, cwL2)
			recordCrosswalkTip(seg.endNode, -1, cwR2)
			recordTip(seg.endNode,  1, cwL2)
			recordTip(seg.endNode, -1, cwR2)
			if seL and seL ~= cwL2 then link(seL, cwL2) end
			if seR and seR ~= cwR2 then link(seR, cwR2) end
		end
	end

	-- Pass 2: same-side links — stitch strip ends / crosswalk nodes that meet
	-- at the same junction corner on the same side.
	-- NEVER link two crosswalk-tagged nodes together here: that would create
	-- spurious junction-corner shortcuts (the long detour in image 2).
	for roadNodeId, sideMap in tipEnds do
		local roadNode = network:getNodes()[roadNodeId]
		for _, nids in sideMap do
			for i = 1, #nids do
				for j = i + 1, #nids do
					local a, b = _nodes[nids[i]], _nodes[nids[j]]
					if a and b then
						-- Skip if BOTH are crosswalk nodes — that link would be a
						-- same-side arc through the junction, not a zebra.
						if a.isCrosswalk and b.isCrosswalk then continue end
						local d = (a.pos - b.pos).Magnitude
						if d <= SAME_SIDE_LINK_DIST then
							local linked = false
							if roadNode then
								local va = Vector3.new(a.pos.X - roadNode.position.X, 0, a.pos.Z - roadNode.position.Z)
								local vb = Vector3.new(b.pos.X - roadNode.position.X, 0, b.pos.Z - roadNode.position.Z)
								if va.Magnitude > 0.1 and vb.Magnitude > 0.1 and va.Unit:Dot(vb.Unit) < 0.88 then
									local bisector = va.Unit + vb.Unit
									if bisector.Magnitude > 0.2 then
										local radius = math.max(va.Magnitude, vb.Magnitude)
										local corner = roadNode.position + bisector.Unit * radius
										local cornerPos = Vector3.new(corner.X, math.max(a.pos.Y, b.pos.Y), corner.Z)
										local cornerId = getOrCreate(cornerPos, STRIP_MERGE_DIST)
										link(nids[i], cornerId)
										link(cornerId, nids[j])
										linked = true
									end
								end
							end
							if not linked then link(nids[i], nids[j]) end
						end
					end
				end
			end
		end
	end

	_built   = true
	_version += 1
	for _, fn in _rebuildListeners do
		local ok, err = pcall(fn)
		if not ok then warn("[NPCWalkingService] rebuild listener error:", err) end
	end
end

-- ── Graph public helpers (kept for Net.RequestWalkPath) ───────────────────────
local function isBuilt(): boolean return _built end

local function getAllNodePositions(): { Vector3 }
	local out: { Vector3 } = {}
	for _, n in _nodes do
		table.insert(out, n.pos)
	end
	return out
end

-- A* on the graph.
-- An edge crosses the road ONLY when BOTH endpoints have isCrosswalk=true
-- AND neither is just a same-side junction node.
local function edgeIsCrossing(na: SWNode, nb: SWNode): boolean
	local lo = if na.id < nb.id then na.id else nb.id
	local hi = if na.id < nb.id then nb.id else na.id
	return _crossingEdges[lo * 1000000 + hi] == true
end

local function astar(startId: number, goalId: number): { { id: number, crossing: boolean } }?
	if startId == goalId then return { { id = startId, crossing = false } } end
	local goalNode = _nodes[goalId]
	if not goalNode then return nil end
	local goalPos = goalNode.pos

	local gScore: { [number]: number }  = { [startId] = 0 }
	local fScore: { [number]: number }  = {}
	local prev:   { [number]: number }  = {}
	local viaCross: { [number]: boolean } = {}
	local closed: { [number]: boolean } = {}

	local function h(id: number): number
		local p = _nodes[id].pos
		return math.sqrt((p.X - goalPos.X)^2 + (p.Z - goalPos.Z)^2)
	end
	fScore[startId] = h(startId)

	local heap: { number } = { startId }
	local function heapSwap(i: number, j: number) heap[i], heap[j] = heap[j], heap[i] end
	local function heapUp(i: number)
		while i > 1 do
			local p = math.floor(i / 2)
			if (fScore[heap[p]] or math.huge) > (fScore[heap[i]] or math.huge) then
				heapSwap(i, p); i = p
			else break end
		end
	end
	local function heapDown(i: number)
		local n = #heap
		while true do
			local s = i; local l, r = 2*i, 2*i+1
			if l <= n and (fScore[heap[l]] or math.huge) < (fScore[heap[s]] or math.huge) then s = l end
			if r <= n and (fScore[heap[r]] or math.huge) < (fScore[heap[s]] or math.huge) then s = r end
			if s == i then break end
			heapSwap(i, s); i = s
		end
	end
	local function heapPop(): number
		local top = heap[1]; heap[1] = heap[#heap]; heap[#heap] = nil
		if #heap > 0 then heapDown(1) end
		return top
	end
	local function heapPush(id: number) table.insert(heap, id); heapUp(#heap) end

	while #heap > 0 do
		local u = heapPop()
		if closed[u] then continue end
		if u == goalId then
			local path: { { id: number, crossing: boolean } } = {}
			local cur: number? = goalId
			while cur do
				table.insert(path, 1, { id = cur, crossing = viaCross[cur] or false })
				cur = prev[cur]
			end
			return path
		end
		closed[u] = true
		local node = _nodes[u]
		if not node then continue end
		for _, v in node.neighbours do
			if closed[v] then continue end
			local nv = _nodes[v]
			if not nv then continue end
			local crossing = edgeIsCrossing(node, nv)
			local edgeCost = (nv.pos - node.pos).Magnitude
			-- Add a penalty to crossing edges so walkers prefer the pavement
			-- and only cross when the path genuinely requires it.
			if crossing then edgeCost = edgeCost * 1.4 end
			local tentG = (gScore[u] or math.huge) + edgeCost
			if tentG < (gScore[v] or math.huge) then
				gScore[v]    = tentG
				fScore[v]    = tentG + h(v)
				prev[v]      = u
				viaCross[v]  = crossing
				heapPush(v)
			end
		end
	end
	return nil
end

local function findPath(fromPos: Vector3, toPos: Vector3, radius: number?)
		: ({ Vector3 }?, { boolean }?)
	if not _built then return nil, nil end
	local r = radius or DEFAULT_SNAP_RADIUS
	local startId = nearestNodeTo(fromPos, r)
	local goalId  = nearestNodeTo(toPos,   r)
	if not startId or not goalId then return nil, nil end
	local steps = astar(startId, goalId)
	if not steps then return nil, nil end
	local pts:   { Vector3 } = {}
	local flags: { boolean } = {}
	for _, s in steps do
		table.insert(pts,   _nodes[s.id].pos)
		table.insert(flags, s.crossing)
	end
	return pts, flags
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 2 – Walker logic (was NPCWalkingService)
-- ═══════════════════════════════════════════════════════════════════════════════

local function ensureFolder(): Folder
	local city = (Workspace:FindFirstChild("_City") or Instance.new("Folder")) :: Folder
	city.Name   = "_City"
	city.Parent = Workspace
	local f = (city:FindFirstChild("NPCWalkers") or Instance.new("Folder")) :: Folder
	f.Name   = "NPCWalkers"
	f.Parent = city
	return f
end

-- Tagged "NPCWalker" so the client PedestrianView eases the 12 Hz CFrame updates into
-- continuous motion (the same trick NPCDriverView does for cars). Appearance defaults to
-- a random adult for ambient walkers; commuters pass the real citizen's gender/kind.
local function makeModel(pos: Vector3, folder: Folder, appearance: CitizenModel.Appearance?): Model
	_nextWalkerDebugId += 1
	local look: CitizenModel.Appearance = if appearance then table.clone(appearance) else {
		gender = if math.random() < 0.5 then "M" else "F",
		kind = "adult",
	}
	if look.seed == nil then look.seed = _nextWalkerDebugId end
	local model = CitizenModel.build(look)
	model.Name  = "NPCWalker"
	model:SetAttribute("NPCDebugId", string.format("Walker#%d", _nextWalkerDebugId))
	model:SetAttribute("NPCStatus", "Walking")
	-- Start exactly on the graph centreline. Radial jitter could put a foot over the
	-- kerb and made the first few frames look like the citizen clipped through it.
	model:PivotTo(CFrame.new(pos))
	model.Parent = folder
	CollectionService:AddTag(model, "NPCWalker")
	return model
end

-- Returns a random node position, skipping crosswalk-only nodes so
-- NPCs never spawn or path-find to a destination that is stranded in the
-- middle of the road with no reachable sidewalk neighbours.
local function randomNodePos(): Vector3?
	local keys: { number } = {}
	for id, n in _nodes do
		-- Prefer non-crosswalk nodes as destinations; crosswalk nodes are
		-- valid waypoints mid-path but bad random destinations.
		if not n.isCrosswalk then
			table.insert(keys, id)
		end
	end
	if #keys == 0 then
		-- Fallback: all nodes are crosswalk nodes (degenerate graph)
		for id in _nodes do table.insert(keys, id) end
	end
	if #keys == 0 then return nil end
	return _nodes[keys[math.random(1, #keys)]].pos
end

local function nearestNodeToUnbounded(pos: Vector3): number?
	local bestId: number? = nil
	local bestD  = math.huge
	for _, n in _nodes do
		local d = (n.pos - pos).Magnitude
		if d < bestD then bestD = d; bestId = n.id end
	end
	return bestId
end

local function repath(walker: Walker)
	local root = walker.model.PrimaryPart
	if not root then return end

	-- If the NPC's position is stranded off the graph (e.g. graph was rebuilt
	-- while they were on the road), snap them to the nearest node unconditionally
	-- so findPath has a valid start point.
	local snapId = nearestNodeTo(walker.pos, DEFAULT_SNAP_RADIUS)
	if not snapId then
		snapId = nearestNodeToUnbounded(walker.pos)
		if snapId then
			local snapNode = _nodes[snapId]
			walker.pos  = snapNode.pos
			root.CFrame = CFrame.new(snapNode.pos)
		else
			walker.repathAt = os.clock() + REPATH_RETRY_WAIT
			return
		end
	end

	local dest = randomNodePos()
	if not dest then
		walker.repathAt = os.clock() + REPATH_RETRY_WAIT
		return
	end
	local pts, flags = findPath(walker.pos, dest)
	if not pts or #pts < 2 then
		walker.repathAt = os.clock() + REPATH_RETRY_WAIT
		return
	end
	walker.waypoints  = pts
	walker.crossFlags = flags or {}
	walker.wpIndex    = 1
	walker.graphVer   = _version
	walker.repathAt   = os.clock() + REPATH_INTERVAL + math.random() * 5
end

-- A directed commuter reached its destination (or its path could not be resolved).
-- Fire the arrival callback exactly once and remove the pedestrian; the citizen's
-- next leg is launched from inside that callback (event-driven, never polled).
local function finishCommuter(walker: Walker)
	local cb = walker.onArrive
	walker.onArrive = nil
	if walker.commuterId then _commuters[walker.commuterId] = nil end
	if walker.model and walker.model.Parent then walker.model:Destroy() end
	if cb then
		local ok, err = pcall(cb)
		if not ok then warn("[NPCWalkingService] commuter onArrive error:", err) end
	end
end

local function stepWalker(walker: Walker, dt: number)
	local root = walker.model.PrimaryPart
	if not root then return end

	if walker.directed then
		-- Graph rebuilt mid-walk: re-path to the SAME destination (never a random one).
		-- If it can't be resolved, arrive now so a broken sidewalk graph can never freeze
		-- the citizen (the next leg simply starts from the destination).
		if walker.graphVer ~= _version then
			local pts, flags = findPath(walker.pos, walker.destPos or walker.pos, COMMUTER_SNAP_RADIUS)
			if pts and #pts >= 2 then
				walker.waypoints, walker.crossFlags, walker.wpIndex, walker.graphVer = pts, flags or {}, 1, _version
			else
				finishCommuter(walker)
				return
			end
		end
		if walker.wpIndex > #walker.waypoints then
			finishCommuter(walker)
			return
		end
	else
		-- Stale path when graph was rebuilt → force re-path immediately
		if walker.graphVer ~= _version then
			walker.waypoints  = {}
			walker.crossFlags = {}
			walker.wpIndex    = 1
			walker.repathAt   = 0
		end

		if walker.wpIndex > #walker.waypoints or os.clock() >= walker.repathAt then
			repath(walker)
			return
		end
	end

	local target    = walker.waypoints[walker.wpIndex]
	local crossing  = walker.crossFlags[walker.wpIndex] or false
	local pos       = walker.pos
	local diff      = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)

	if diff.Magnitude < STEP_DIST then
		walker.wpIndex += 1
		walker.crossingCommitted = false
		return
	end

	-- Kerb check: before stepping onto a zebra, wait for approaching cars to
	-- pass. Capped so a busy road can never strand a walker at the kerb.
	if crossing and not walker.crossingCommitted then
		local mid = pos:Lerp(target, 0.5)
		if walker.crossWait < CROSS_WAIT_MAX and PathFollower.anyCarApproaching(mid, CROSS_CHECK_RADIUS) then
			walker.crossWait += dt
			return
		end
		walker.crossingCommitted = true
		walker.crossWait = 0
	end

	local speed  = if crossing then CROSSWALK_SPEED else WALK_SPEED
	local dir    = diff.Unit
	local move   = math.min(speed * dt, diff.Magnitude)
	-- FIX 5: smooth Y interpolation instead of snapping to target.Y
	local newX   = pos.X + dir.X * move
	local newZ   = pos.Z + dir.Z * move
	local newY   = pos.Y + (target.Y - pos.Y) * math.min(1, dt * 8)
	walker.pos   = Vector3.new(newX, newY, newZ)

	-- Every walker rides the batched pose stream at WALK_SEND_DT, near or not. The old
	-- 2 s property keepalive for distant walkers was the pedestrian twin of the car
	-- far-tier, and stepped just as visibly.
	walker.sendAccum += dt
	if walker.sendAccum >= WALK_SEND_DT then
		walker.sendAccum = 0
		PathFollower.streamPose(walker.model, CFrame.lookAt(walker.pos, walker.pos + Vector3.new(dir.X, 0, dir.Z)))
	end
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 3 – Lifecycle
-- ═══════════════════════════════════════════════════════════════════════════════

function NPCWalkingService.spawnTestWalker(staggerIndex: number?): boolean
	if #_walkers >= MAX_WALKERS then
		warn("[NPCWalkingService] Walker cap reached")
		return false
	end
	if not _built then
		warn("[NPCWalkingService] Sidewalk graph not built yet")
		return false
	end
	local startPos = randomNodePos()
	if not startPos then
		return false
	end
	local folder = ensureFolder()
	local model  = makeModel(startPos, folder)
	-- Stagger initial repath so walkers don't all find paths in the same frame.
	local stagger = (staggerIndex or 0) * 0.15
	local walker: Walker = {
		model      = model,
		waypoints  = {},
		crossFlags = {},
		wpIndex    = 1,
		repathAt   = os.clock() + stagger,  -- delayed start spreads CPU load
		graphVer   = _version,
		pos        = (model.PrimaryPart :: BasePart).Position,
		sendAccum  = 0,
		crossingCommitted = false,
		crossWait  = 0,
	}
	table.insert(_walkers, walker)
	return true
end

-- Spawn a directed pedestrian that walks `fromPos` -> `toPos` along the sidewalk
-- graph, fires `onArrive` once at the destination, then despawns. Used by
-- CitizenService for the house<->car and car<->workplace legs of a commute.
-- ALWAYS guarantees `onArrive` runs (even with no graph, no path, or at the walker
-- cap) so a citizen can never freeze mid-commute. Returns a commuter id; 0 means no
-- live pedestrian was spawned and the arrival was scheduled for the next frame.
function NPCWalkingService.spawnCommuter(fromPos: Vector3, toPos: Vector3, onArrive: (() -> ())?, label: string?, appearance: CitizenModel.Appearance?): number
	if typeof(fromPos) ~= "Vector3" or typeof(toPos) ~= "Vector3" then
		if onArrive then task.defer(onArrive) end
		return 0
	end
	local unseen = PathFollower.nearestPlayerDistSq(fromPos) > BODY_RANGE * BODY_RANGE
	if not _built or #_walkers >= MAX_WALKERS or (unseen and _agentService) then
		-- No sidewalk graph yet, at the walker cap, or nobody near. Offer the leg to Tier 2 first: the
		-- citizen then WALKS the route as a bodiless agent with an honest travel time, and is
		-- promoted to a real body if a slot frees up while a player is nearby. Only if that
		-- also fails do we fall back to the historical behaviour -- advance the stage with no
		-- walk at all -- so a commute can still never freeze mid-flight.
		if _agentService then
			local agentId = _agentService.adopt(fromPos, toPos, onArrive, label, appearance)
			if agentId ~= 0 then return agentId end
		end
		if onArrive then task.defer(onArrive) end
		return 0
	end
	_nextCommuterId += 1
	local id = _nextCommuterId
	local folder = ensureFolder()
	local model  = makeModel(fromPos, folder, appearance)
	if label then model.Name = label end
	if appearance and typeof(appearance.seed) == "number" then
		model:SetAttribute("CitizenPid", math.floor(appearance.seed))
		CollectionService:AddTag(model, "AdminCitizen")
	end
	model:SetAttribute("NPCStatus", "Walking")
	local pts, flags = findPath(fromPos, toPos, COMMUTER_SNAP_RADIUS)
	local walker: Walker = {
		model      = model,
		waypoints  = if pts and #pts >= 2 then pts else {},
		crossFlags = flags or {},
		wpIndex    = 1,
		repathAt   = math.huge,
		graphVer   = _version,
		pos        = (model.PrimaryPart :: BasePart).Position,
		sendAccum  = 0,
		crossingCommitted = false,
		crossWait  = 0,
		directed   = true,
		commuterId = id,
		destPos    = toPos,
		onArrive   = onArrive,
		appearance = appearance,
	}
	table.insert(_walkers, walker)
	_commuters[id] = walker
	-- No path found: the directed stepper sees wpIndex(1) > #waypoints(0) next tick and
	-- fires onArrive (despawn + advance) -- the required walk-path-failure fallback.
	return id
end

-- Cancel a commuter WITHOUT firing its arrival callback (household removed, or its
-- target building/road deleted mid-walk). Safe with id 0 / unknown id.
function NPCWalkingService.despawnCommuter(id: number?)
	if not id or id == 0 then return end
	local moved = _aliases[id]
	if moved then
		_aliases[id] = nil
		NPCWalkingService.despawnCommuter(moved)
		return
	end
	-- Negative ids are Tier-2 agents: no body to destroy, just a plan to drop.
	if id < 0 then
		if _agentService then _agentService.release(id) end
		return
	end
	local w = _commuters[id]
	if not w then return end
	_commuters[id] = nil
	w.onArrive = nil
	if w.model and w.model.Parent then w.model:Destroy() end
end

-- The live root part of a directed commuter (for the locate-and-follow camera), or nil
-- if it has despawned / never spawned. A read-only handle, not ownership.
function NPCWalkingService.getCommuterRoot(id: number?): BasePart?
	if not id or id == 0 then return nil end
	if _aliases[id] then return NPCWalkingService.getCommuterRoot(_aliases[id]) end
	local w = _commuters[id]
	if not w or not w.model or not w.model.Parent then return nil end
	return w.model.PrimaryPart
end

function NPCWalkingService.GetCommuterDebug(id: number?): { [string]: any }?
	if not id or id == 0 then return nil end
	if id < 0 then
		return if _agentService then _agentService.getDebug(id) else nil
	end
	local w = _commuters[id]
	if not w or not w.model or not w.model.Parent then return nil end
	local points: { Vector3 } = { w.pos }
	for i = math.max(1, w.wpIndex), #w.waypoints do
		table.insert(points, w.waypoints[i])
	end
	if w.destPos then table.insert(points, w.destPos) end
	return {
		kind = "walker",
		polyline = points,
		routeIndex = w.wpIndex,
		routeLength = #w.waypoints,
		status = if w.crossingCommitted then "Crossing at a crosswalk" else "Following the sidewalk graph",
		reason = "A* selected the shortest connected sidewalk route, with a penalty for unnecessary road crossings.",
	}
end

function NPCWalkingService.GetDebugSnapshot(): { any }
	local out: { any } = {}
	for _, w in _walkers do
		if w.model and w.model.Parent then
			local id = w.model:GetAttribute("NPCDebugId")
			table.insert(out, {
				id = if typeof(id) == "string" then id else w.model.Name,
				name = w.model.Name,
				kind = "walker",
				status = if w.directed then "Walking route" else "Ambient walk",
				speed = if w.crossingCommitted then CROSSWALK_SPEED else WALK_SPEED,
				pos = {
					x = math.round(w.pos.X),
					y = math.round(w.pos.Y),
					z = math.round(w.pos.Z),
				},
				routeIndex = w.wpIndex,
				routeLength = #w.waypoints,
			})
		end
	end
	return out
end

-- Free Tier-1 body slots. CitizenAgentService reads this before promoting so it can leave
-- a reserve for genuinely new commutes -- otherwise a backlog of promotable agents would
-- take every slot and a citizen setting out from their front door would get no body.
function NPCWalkingService.walkerHeadroom(): number
	return math.max(0, MAX_WALKERS - #_walkers)
end

-- Injected in Bootstrap after CitizenAgentService exists (see _agentService above).
function NPCWalkingService.alias(fromId: number, toId: number)
	_aliases[fromId] = toId
end

-- Bodies far from every player go back to Tier 2 from where they stand, same destination,
-- same callback -- which frees them for the streets someone is watching.
local function demoteFarWalkers()
	if not _agentService then return end
	for i = #_walkers, 1, -1 do
		local w = _walkers[i]
		if not w.directed or not w.commuterId or not w.model.Parent or not w.destPos then continue end
		if PathFollower.nearestPlayerDistSq(w.pos) <= DEMOTE_RANGE * DEMOTE_RANGE then continue end
		local agentId = _agentService.adopt(w.pos, w.destPos, w.onArrive, w.model.Name, w.appearance)
		if agentId == 0 then continue end
		_aliases[w.commuterId] = agentId
		_commuters[w.commuterId] = nil
		w.onArrive = nil
		w.model:Destroy()
		table.remove(_walkers, i)
	end
end

function NPCWalkingService.SetAgentService(svc: any)
	_agentService = svc
end

-- Init now takes roadService directly (SidewalkService is merged in)
function NPCWalkingService.Init(sidewalkService: any, net: any)
	-- sidewalkService param kept for Bootstrap backwards-compat but is unused;
	-- we now own the graph internally. roadService is injected via the
	-- onTopologyChanged callback wired in Bind().
	assert(net, "[NPCWalkingService] missing net")
	_net = net
end

-- Call this before Init if you want to pass roadService explicitly
-- (Bootstrap wires it via SidewalkService.Init(roadService) — we intercept that).
function NPCWalkingService.SetRoadService(rs: any)
	_roadService = rs
end

function NPCWalkingService.Bind()
	_net.RequestWalkPath.OnServerInvoke = function(
		_player: Player, fromPos: any, toPos: any
	): (boolean, { Vector3 }?)
		if typeof(fromPos) ~= "Vector3" or typeof(toPos) ~= "Vector3" then return false, nil end
		if not _built then return false, nil end
		local pts = findPath(fromPos, toPos)
		return pts ~= nil, pts
	end

	-- SpawnTestWalker is a debug-only hook: only wire it in Studio so live clients
	-- can't spawn server NPC models. Live NPC population comes from tryAutoSpawn.
	if RunService:IsStudio() then
		local _lastSpawnTime: { [Player]: number } = {}
		_net.SpawnTestWalker.OnServerEvent:Connect(function(player: Player)
			local now = os.clock()
			if (now - (_lastSpawnTime[player] or 0)) < WALKER_COOLDOWN then return end
			_lastSpawnTime[player] = now
			NPCWalkingService.spawnTestWalker()
		end)

		Players.PlayerRemoving:Connect(function(p) _lastSpawnTime[p] = nil end)
	end
end

local function targetWalkerCount(): number
	local configured = Workspace:GetAttribute("AmbientWalkerCount")
	if typeof(configured) == "number" then
		return math.clamp(math.floor(configured), 0, math.min(MAX_AMBIENT_WALKERS, MAX_WALKERS))
	end
	return math.min(TARGET_WALKERS, MAX_WALKERS)
end

local function tryAutoSpawn()
	if not _built or not hasSidewalkNodes() then return end
	-- Count only walkers whose model is still in the world
	local alive = 0
	for _, w in _walkers do
		if w.model.Parent then alive += 1 end
	end
	local needed = math.max(0, targetWalkerCount() - alive)
	for i = 1, needed do
		NPCWalkingService.spawnTestWalker(i - 1)
	end
end

local function onGraphRebuilt()
	-- Invalidate all walker paths so they re-path on next step tick.
	-- Also clear the stale waypoint arrays so GC can collect the old Vector3s.
	for _, w in _walkers do
		w.graphVer   = -1
		w.waypoints  = {}
		w.crossFlags = {}
		w.wpIndex    = 1
	end
	tryAutoSpawn()
end

local function queueGraphRebuild()
	if _rebuildQueued then return end
	_rebuildQueued = true
	local delay = math.max(0, _lastRebuildAt + REBUILD_DEBOUNCE - os.clock())
	task.delay(delay, function()
		_rebuildQueued = false
		_lastRebuildAt = os.clock()
		rebuildGraph()
		onGraphRebuilt()
	end)
end

function NPCWalkingService.Start()
	if _roadService then
		if _topologyDisconnect then
			_topologyDisconnect()
			_topologyDisconnect = nil
		end
		_topologyDisconnect = _roadService.onTopologyChanged(queueGraphRebuild)
	end

	-- NOTE: do NOT register onGraphRebuilt as a _rebuildListener here.
	-- It is already called directly after every rebuildGraph() in the
	-- onTopologyChanged callback above and in the initial build below.
	-- Registering it would fire it twice per rebuild, doubling auto-spawns.

	rebuildGraph()
	onGraphRebuilt()

	-- FIX 4: disconnect old heartbeat before creating new one
	if _heartbeat then _heartbeat:Disconnect() end
	local tickAccum = 0
	local demoteAccum = 0
	_heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		tickAccum += math.min(dt, 0.1)
		demoteAccum += dt
		if demoteAccum >= DEMOTE_CHECK then
			demoteAccum = 0
			demoteFarWalkers()
		end
		if tickAccum < WALKER_TICK then return end
		local stepDt = math.min(tickAccum, 0.1)
		tickAccum = 0

		-- Pedestrian decisions run at 20 Hz; the client-side view supplies render-frame
		-- interpolation, so visible motion stays smooth without Heartbeat-rate server work.
		local speed = math.clamp(math.floor(tonumber(Workspace:GetAttribute("GameSpeed")) or 1), 0, 3)
		for i = #_walkers, 1, -1 do
			local w = _walkers[i]
			if not w.model.Parent then
				if w.commuterId then _commuters[w.commuterId] = nil end
				table.remove(_walkers, i)
			end
		end
		local now = os.clock()
		for _ = 1, speed do
			for i = #_walkers, 1, -1 do
				local w = _walkers[i]
				if w.model.Parent then
					if now >= (w.lodCheckAt or 0) then
						w.lodCheckAt = now + 0.75 + math.random() * 0.5
						w.lodMid = PathFollower.nearestPlayerDistSq(w.pos) > MID_TICK_DIST * MID_TICK_DIST
					end
					w.lodAccum = (w.lodAccum or 0) + stepDt
					if w.lodMid and w.lodAccum < MID_TICK then continue end
					stepWalker(w, w.lodAccum)
					w.lodAccum = 0
				end
			end
		end
	end)
end

-- ── SidewalkService-compatible public surface (for anything that required it) ─
function NPCWalkingService.isBuilt(): boolean return _built end
function NPCWalkingService.getVersion(): number return _version end
function NPCWalkingService.getAllNodes(): { Vector3 } return getAllNodePositions() end
function NPCWalkingService.getNearestNode(p: Vector3, r: number?): (number?, number)
	if not _built then return nil, math.huge end
	return nearestNodeTo(p, r or DEFAULT_SNAP_RADIUS)
end
function NPCWalkingService.getNodePos(id: number): Vector3?
	local n = _nodes[id]; return n and n.pos or nil
end
function NPCWalkingService.getNearestPoint(p: Vector3, r: number?): Vector3?
	if not _built then return nil end
	local nid = nearestNodeTo(p, r or DEFAULT_SNAP_RADIUS)
	return if nid then _nodes[nid].pos else nil
end
function NPCWalkingService.findPath(from: Vector3, to: Vector3, r: number?): { Vector3 }?
	local pts = findPath(from, to, r)
	return pts
end
function NPCWalkingService.onRebuilt(fn: () -> ()): () -> ()
	table.insert(_rebuildListeners, fn)
	local disconnected = false

	return function()
		if disconnected then return end
		disconnected = true
		local index = table.find(_rebuildListeners, fn)
		if index then
			table.remove(_rebuildListeners, index)
		end
	end
end
function NPCWalkingService.Rebuild()
	rebuildGraph()
	onGraphRebuilt()
end
function NPCWalkingService.Bind_sidewalk() end  -- no-op stub

return NPCWalkingService