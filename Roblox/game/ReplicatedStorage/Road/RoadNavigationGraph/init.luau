--!strict

local RoadConstants = require(script.Parent.RoadConstants)
local RoadTypeCatalog = require(script.Parent.RoadTypeCatalog)
-- Owns the ACTIVE driving side (a player setting, changeable at runtime). Read through
-- its getters on every use -- see the note in RoadRules.
local RoadRules = require(script.Parent.RoadRules)
local RoadRules = require(script.Parent.RoadRules)
local BezierUtil = require(script.Parent.BezierUtil)
local IntersectionRenderer = require(script.Parent.IntersectionRenderer)
local NavRouter = require(script.Parent.NavRouter)
local NavCost = require(script.Parent.NavCost)

local RoadNavigationGraph = {}
RoadNavigationGraph.__index = RoadNavigationGraph

export type LaneTurnRule = { [string]: boolean }

export type TurnPermissionSet = {
	left: boolean,
	right: boolean,
	straight: boolean,
	uturn: boolean,
	manual: boolean?,
	laneRules: { [string]: LaneTurnRule }?,
	connectionRules: { [string]: boolean }?,
	customConnections: { [string]: { handles: { Vector3 } } }?,
}

export type LaneEdge = {
	id: string,
	segmentId: number,
	laneIndex: number,
	laneOrdinal: number,
	laneCountInDirection: number,
	fromNode: number,
	toNode: number,
	forward: boolean,
	offset: number,
	length: number,
	points: { Vector3 },
	_cum: { number },
	fromDir: Vector3,
	toDir: Vector3,
	out: { string },
	outMovement: { [string]: string },
	-- SECONDS of delay for taking this exit (OSRM turn sigmoid + Valhalla manoeuvre
	-- penalty, see NavCost). Same unit as edge travel time, so they simply add.
	turnCost: { [string]: number },
	speedLimit: number,
	allowedVehicles: { [string]: boolean }?,
	isRoundabout: boolean?,
	-- "highway" | "arterial" | "local" | "alley" -- the road-hierarchy tier the
	-- router prefers/avoids by, beyond what the speed limit alone explains.
	roadClass: string?,
	-- A median splits the carriageway: nobody turns across it into a driveway.
	divided: boolean?,
	-- Dashed lane lines: a driver may move over between this road's same-direction lanes.
	laneChangeOk: boolean?,
}

export type LaneChangeConnection = {
	fromEdgeId: string,
	toEdgeId: string,
	allowed: boolean,
	points: { Vector3 },
}

export type LaneChangeGate = {
	id: string,
	segmentId: number,
	direction: string,
	gateIndex: number,
	pairIndex: number,
	startDistance: number,
	endDistance: number,
	dots: { any },
	connections: { LaneChangeConnection },
}

type HeapItem = { id: string, priority: number }

type NearestResult = {
	edge: LaneEdge,
	index: number,
	distance: number,
}

local UP = Vector3.yAxis
local DEFAULT_WAYPOINT_SPACING = 28
local DEFAULT_CELL_SIZE = 128
local THROUGH_CONE = math.rad(35)
local UTURN_CONE = math.rad(158)

local function defaultPermissions(): TurnPermissionSet
	return { left = true, right = true, straight = true, uturn = false }
end

local function flatUnit(v: Vector3): Vector3?
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-6 then
		return nil
	end
	return flat.Unit
end

local function sideForTangent(tangent: Vector3): Vector3
	local fwd = flatUnit(tangent) or Vector3.xAxis
	local side = fwd:Cross(UP)
	if side.Magnitude < 1e-6 then
		return Vector3.zAxis
	end
	return side.Unit
end

local function signedTurnAngle(inDir: Vector3, outDir: Vector3): number
	local a = flatUnit(inDir) or Vector3.xAxis
	local b = flatUnit(outDir) or Vector3.xAxis
	return math.atan2(a:Cross(b).Y, math.clamp(a:Dot(b), -1, 1))
end

local function classifyTurn(inDir: Vector3, outDir: Vector3): string
	local angle = signedTurnAngle(inDir, outDir)
	local absAngle = math.abs(angle)
	if absAngle >= UTURN_CONE then
		return "uturn"
	elseif absAngle <= THROUGH_CONE then
		return "straight"
	elseif angle > 0 then

		return "left"
	else
		return "right"
	end
end

-- Cost of one junction movement, in SECONDS. Was a set of hand-picked stud-ish
-- numbers (0/8/12/45); now it is OSRM's angle sigmoid plus Valhalla's flat manoeuvre
-- penalty, computed from the ACTUAL geometry of the turn -- so a gentle fork costs
-- almost nothing and a sharp cut across traffic costs real time. See NavCost.
local function movementCost(movement: string, inDir: Vector3?, outDir: Vector3?): number
	if movement == "straight" and not inDir then
		return 0
	end
	local angle = if inDir and outDir then signedTurnAngle(inDir, outDir) else 0
	if movement == "uturn" then
		-- A U-turn's measured angle can land either side of +/-180; charge the full
		-- sigmoid ceiling plus OSRM's u_turn_penalty regardless of sign.
		return NavCost.turnSeconds(math.pi, true) + NavCost.maneuverSeconds(movement)
	end
	return NavCost.turnSeconds(angle, false) + NavCost.maneuverSeconds(movement)
end

local function connectionKey(fromEdgeId: string, toEdgeId: string): string
	return `{fromEdgeId}>{toEdgeId}`
end

local function laneChangeRuleKey(gateId: string, fromEdgeId: string, toEdgeId: string): string
	return `{gateId}>{fromEdgeId}>{toEdgeId}`
end

local function edgeHasOutgoing(edge: LaneEdge, toEdgeId: string): boolean
	for _, id in edge.out do
		if id == toEdgeId then
			return true
		end
	end
	return false
end

type AutoExitPlan = {
	movement: string,
	incomingLaneOrdinal: number?,
}

local function continuationLaneOrdinal(inEdge: LaneEdge, outEdge: LaneEdge): number

	return math.min(inEdge.laneOrdinal, math.max(1, outEdge.laneCountInDirection))
end

-- How many lanes ACROSS an exit sits from the lane you keep by driving straight on.
local function laneShift(inEdge: LaneEdge, outEdge: LaneEdge): number
	return math.abs(outEdge.laneOrdinal - continuationLaneOrdinal(inEdge, outEdge))
end

-- Seconds charged per lane moved over, so a driver only changes lane when the route
-- needs it (reaching a turn lane) rather than weaving for free.
local LANE_SHIFT_SECONDS = 4

-- Straight through a junction you keep your lane: changing lane inside the box reads as a
-- last-second swerve (several US states ban it), so lanes are changed mid-block on the dashed
-- line (GetLaneChangeWindow). A one-lane shift in the box still EXISTS, priced at
-- JUNCTION_SHIFT_SECONDS, because a block too short for a mid-block change would otherwise
-- lock its lanes and cut routes that are really there. An extra kerb lane still does not
-- merge itself through a narrowing junction. The same price holds across a plain join
-- between two pieces of road: shifting there crossed the neighbour lane's cars as they
-- shifted the other way, with no gap check, where a mid-block change waits for a gap.
local JUNCTION_SHIFT_SECONDS = 20
local function junctionStraightLaneAllowed(inEdge: LaneEdge, outEdge: LaneEdge): boolean
	return inEdge.laneOrdinal <= outEdge.laneCountInDirection
		and laneShift(inEdge, outEdge) <= 1
end

-- Which lane of the APPROACH a given exit should be taken from, spreading the available
-- turns across the approach's lanes in the order a driver meets them.
local function rankedLaneOrdinal(rank: number, total: number, laneCount: number, movement: string): number
	local count = math.max(1, laneCount)
	if total <= 1 then
		-- The lone exit: a nearside turn is made from the kerb, anything else from the centre.
		return if movement == RoadRules.getNearsideTurn() then count else 1
	end
	-- `turns` is sorted by signed angle ascending, so rank 1 is the sharpest RIGHT exit and
	-- rank `total` the sharpest LEFT. Ordinal 1 is always the lane against the centreline,
	-- so on a right-hand-drive map that order is backwards: the sharpest right is the
	-- kerbside movement there, not the centre one. Reverse it rather than re-sorting, so
	-- the sort stays a plain geometric ordering.
	local normalized = (rank - 1) / (total - 1)
	if RoadRules.getDrivingSide() == "right" then
		normalized = 1 - normalized
	end
	return math.clamp(math.floor(normalized * (count - 1) + 0.5) + 1, 1, count)
end

local function buildAutoExitPlans(inEdge: LaneEdge, outgoing: { LaneEdge }, nodeDegree: number): { [number]: AutoExitPlan }
	local representatives: { [number]: LaneEdge } = {}
	for _, outEdge in outgoing do
		if not representatives[outEdge.segmentId] then
			representatives[outEdge.segmentId] = outEdge
		end
	end

	local plans: { [number]: AutoExitPlan } = {}
	local exits: { { segmentId: number, angle: number, absAngle: number } } = {}
	local primaryStraight: { segmentId: number, angle: number, absAngle: number }? = nil
	for segmentId, outEdge in representatives do
		local angle = signedTurnAngle(inEdge.toDir, outEdge.fromDir)
		local absAngle = math.abs(angle)
		-- Doubling back onto ANOTHER segment is still a U-turn. Only same-segment exits
		-- were treated as one, so a 170-degree swing onto a neighbouring road was waved
		-- through as a sharp left/right and perms.uturn never saw it. Junctions only: a
		-- 2-arm hairpin joint has no other way on, and blocking it would sever the road.
		if segmentId == inEdge.segmentId or (nodeDegree >= 3 and absAngle >= UTURN_CONE) then
			plans[segmentId] = { movement = "uturn" }
		else
			local exit = { segmentId = segmentId, angle = angle, absAngle = absAngle }
			table.insert(exits, exit)
			if absAngle <= THROUGH_CONE and (
				not primaryStraight
					or absAngle < primaryStraight.absAngle
					or (absAngle == primaryStraight.absAngle and segmentId < primaryStraight.segmentId)
				) then
				primaryStraight = exit
			end
		end
	end

	if primaryStraight then
		plans[primaryStraight.segmentId] = { movement = "straight" }
	end

	local turns: { { segmentId: number, angle: number, movement: string } } = {}
	for _, exit in exits do
		if exit ~= primaryStraight then
			local movement = if exit.angle > 0 then "left" else "right"
			table.insert(turns, { segmentId = exit.segmentId, angle = exit.angle, movement = movement })
		end
	end
	table.sort(turns, function(a, b)
		return a.angle < b.angle or (a.angle == b.angle and a.segmentId < b.segmentId)
	end)
	for rank, exit in turns do
		plans[exit.segmentId] = {
			movement = exit.movement,
			incomingLaneOrdinal = rankedLaneOrdinal(rank, #turns, inEdge.laneCountInDirection, exit.movement),
		}
	end
	return plans
end

local function defaultAutoLaneAllowed(nodeDegree: number, inEdge: LaneEdge, outEdge: LaneEdge, plan: AutoExitPlan): boolean
	local movement = plan.movement
	if nodeDegree <= 1 then
		return movement == "uturn"
			and outEdge.laneOrdinal == math.clamp(inEdge.laneOrdinal, 1, math.max(1, outEdge.laneCountInDirection))
	end

	if nodeDegree == 2 then
		return inEdge.segmentId ~= outEdge.segmentId and laneShift(inEdge, outEdge) <= 1
	end

	-- Turns are matched by what they DO, not by compass direction, so this policy is the
	-- same code in a US city and a UK one -- only RoadConstants decides which is which.
	if movement == "straight" then
		return junctionStraightLaneAllowed(inEdge, outEdge)
	elseif movement == "uturn" then
		return inEdge.laneOrdinal == 1 and outEdge.laneOrdinal == 1
	elseif movement == RoadRules.getNearsideTurn() then
		-- Hugs the kerb and crosses nothing: taken from the kerbside lane of the approach,
		-- lands in the kerbside lane of the new road.
		return inEdge.laneOrdinal == plan.incomingLaneOrdinal
			and outEdge.laneOrdinal == outEdge.laneCountInDirection
	elseif movement == RoadRules.getCrossingTurn() then
		-- Cuts the oncoming carriageway: taken from the lane against the centreline and
		-- lands in the matching lane on the new road.
		return inEdge.laneOrdinal == plan.incomingLaneOrdinal
			and outEdge.laneOrdinal == 1
	end
	return false
end

-- Multi-lane roundabout, the FHWA way: choose the lane BEFORE the ring and keep it all the
-- way round, then leave from the lane you are in. Centre-side lanes pair with the inner
-- ring lane, kerb lanes with the outer one; a single-lane road on either end may use any.
-- Before this every ring lane linked to every other at each arm, so cars weaved lanes all
-- the way round for no reason.
local function roundaboutLaneAllowed(inEdge: LaneEdge, outEdge: LaneEdge): boolean
	if inEdge.isRoundabout and outEdge.isRoundabout then
		return inEdge.laneOrdinal == outEdge.laneOrdinal
	end
	local inCount, outCount = inEdge.laneCountInDirection, outEdge.laneCountInDirection
	if inCount <= 1 or outCount <= 1 then
		return true
	end
	-- Same relative position across the carriageway (centre -> centre, kerb -> kerb).
	local t = (inEdge.laneOrdinal - 1) / (inCount - 1)
	return outEdge.laneOrdinal == math.floor(t * (outCount - 1) + 0.5) + 1
end

local function cellKey(pos: Vector3): string
	local cell = RoadConstants.NAV_SPATIAL_CELL_SIZE or DEFAULT_CELL_SIZE
	return `{math.floor(pos.X / cell)},{math.floor(pos.Z / cell)}`
end

local function distanceSq(a: Vector3, b: Vector3): number
	if math.abs(a.Y - b.Y) > RoadConstants.VERTICAL_CONNECT_TOLERANCE then
		return math.huge
	end
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return dx * dx + dz * dz
end

type LanePlan = {
	offset: number,
	forward: boolean,
	laneIndex: number,
	laneOrdinal: number,
	laneCountInDirection: number,
}

-- Where each lane of a road sits, and what it is FOR.
--
-- `offset` is lateral, in sideForTangent's frame: +1 stud = one stud to the RIGHT of the
-- direction of travel. LANE_SIDE puts a direction's own lanes on the correct side of the
-- centreline for the world's driving side -- it is the one sign that makes the whole map
-- drive American rather than British.
--
-- `laneOrdinal` is the driving-side-AGNOSTIC lane number, and the invariant every caller
-- relies on is:
--
--     ordinal 1              = the lane against the centreline / median (the fast lane,
--                              and the one a crossing turn is made from)
--     ordinal laneCountInDirection = the kerbside lane (the one a nearside turn ends in)
--
-- Stated that way it holds in both the US and the UK; only the compass direction of
-- "crossing" and "nearside" changes. `laneIndex` stays purely geometric (left to right
-- across the carriageway) because it forms edge ids -- do not renumber it.
local function lanePlans(spec: any): { LanePlan }
	local plans: { LanePlan } = {}
	local laneCount = math.max(1, spec.laneCount or 2)
	-- Drive on the carriageway (total width minus the parking apron), never the apron.
	local width = RoadTypeCatalog.carriagewayWidth(spec)
	-- Read per call, never cached at module level: the player can flip the driving side
	-- at runtime and the graph is rebuilt from scratch when they do.
	local LANE_SIDE = RoadRules.getLaneSideSign()

	if spec.oneWay then
		-- A one-way street occupies its whole width whichever side the country drives on,
		-- so the geometry is unchanged -- only the NUMBERING flips. Ordinal 1 has to stay
		-- the lane a crossing turn is made from, which is the leftmost lane on a
		-- right-hand-drive one-way and the rightmost on a left-hand-drive one.
		local laneW = width / laneCount
		for i = 1, laneCount do
			table.insert(plans, {
				offset = -width * 0.5 + (i - 0.5) * laneW,
				forward = true,
				laneIndex = i,
				laneOrdinal = if RoadRules.getDrivingSide() == "right" then i else laneCount - i + 1,
				laneCountInDirection = laneCount,
			})
		end
		return plans
	end

	local perDir = math.max(1, math.floor(laneCount / 2))
	if spec.median then
		local medianW = spec.medianWidth or 4
		local laneW = (width - medianW) / laneCount
		local halfMedian = medianW * 0.5
		for i = 1, perDir do
			table.insert(plans, {
				offset = LANE_SIDE * (halfMedian + (i - 0.5) * laneW),
				forward = true,
				laneIndex = i,
				laneOrdinal = i,
				laneCountInDirection = perDir,
			})
		end
		for i = 1, perDir do
			table.insert(plans, {
				offset = -LANE_SIDE * (halfMedian + (i - 0.5) * laneW),
				forward = false,
				laneIndex = perDir + i,
				laneOrdinal = i,
				laneCountInDirection = perDir,
			})
		end
		return plans
	end

	local laneW = width / laneCount
	for i = 1, perDir do
		table.insert(plans, {
			offset = LANE_SIDE * (i - 0.5) * laneW,
			forward = true,
			laneIndex = i,
			laneOrdinal = i,
			laneCountInDirection = perDir,
		})
	end
	for i = 1, perDir do
		table.insert(plans, {
			offset = -LANE_SIDE * (i - 0.5) * laneW,
			forward = false,
			laneIndex = perDir + i,
			laneOrdinal = i,
			laneCountInDirection = perDir,
		})
	end
	return plans
end

local STRAIGHT_JOIN_DOT = -math.cos(math.rad(RoadConstants.STRAIGHT_JOIN_TOLERANCE_DEG or 2))

local function txSmooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function segDirFromNode(seg: any, nodeId: number): Vector3?
	if seg.startNode == nodeId then
		return flatUnit(seg.p1 - seg.p0) or flatUnit(seg.p3 - seg.p0)
	end
	return flatUnit(seg.p2 - seg.p3) or flatUnit(seg.p0 - seg.p3)
end

local function endTaperWidth(network: any, seg: any, nodeId: number, ownWidth: number): number?
	-- Mirrors RoadSceneRenderer.transitionAtNode: at a 2-arm join, if the neighbour road is
	-- narrower, this segment is rendered tapering down to it, so its lanes must taper too.
	local node = network:getNodes()[nodeId]
	if not node or #node.segments ~= 2 or seg.isArc then
		return nil
	end
	for _, otherId in node.segments do
		if otherId ~= seg.id then
			local other = network:getSegment(otherId)
			if other and not other.isArc then
				local otherWidth = RoadTypeCatalog.getOrDefault(other.roadType).width
				if otherWidth < ownWidth - 1e-3 then
					return otherWidth
				end
			end
		end
	end
	return nil
end

local function sampleLane(seg: any, offset: number, forward: boolean, fullWidth: number?, taperStart: number?, taperEnd: number?): ({ Vector3 }, Vector3, Vector3, number)
	local length = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 20)
	local spacing = RoadConstants.NAV_WAYPOINT_SPACING or DEFAULT_WAYPOINT_SPACING
	-- Base spans only; bends are refined below. The old SAMPLES_PER_SEGMENT (35) cap
	-- let long segments degrade to 50+ stud spacing -- cars visibly left the lane.
	local samples = math.clamp(math.ceil(length / spacing), 2, 128)
	local points: { Vector3 } = table.create(samples + 1)
	local total = 0

	-- When this segment tapers down to a narrower neighbour the rendered surface shrinks
	-- over the transition. Scale the lane offset by the same width profile so lanes follow
	-- the shoulder inward and stay on the road instead of running into the grass; the outer
	-- lanes squeeze together and then merge into the narrow road at the node.
	local taperLen = RoadConstants.ROAD_WIDTH_TRANSITION_LENGTH
	local fullHalf = (fullWidth or RoadConstants.ROAD_WIDTH) * 0.5
	local hasTaper = (taperStart ~= nil or taperEnd ~= nil) and fullHalf > 1e-6 and length > 1e-3
	local startHalf = if taperStart then taperStart * 0.5 else fullHalf
	local endHalf = if taperEnd then taperEnd * 0.5 else fullHalf
	local function offsetFactorAt(dist: number): number
		if not hasTaper then
			return 1
		end
		local half: number
		local startFlareEnd = taperLen
		local endFlareStart = length - taperLen
		if startFlareEnd > endFlareStart then
			half = startHalf + (endHalf - startHalf) * txSmooth(dist / length)
		elseif dist < startFlareEnd then
			half = startHalf + (fullHalf - startHalf) * txSmooth(dist / taperLen)
		elseif dist > endFlareStart then
			half = fullHalf + (endHalf - fullHalf) * txSmooth((dist - endFlareStart) / taperLen)
		else
			half = fullHalf
		end
		return half / fullHalf
	end

	local function lanePointAt(t: number): Vector3
		local center = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local tangent = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
		if tangent.Magnitude < 1e-6 then
			tangent = seg.p3 - seg.p0
		end
		local side = sideForTangent(tangent)
		local dist = t * length
		return center + side * (offset * offsetFactorAt(dist))
	end

	local function push(p: Vector3)
		local prev = points[#points]
		if prev then
			total += (p - prev).Magnitude
		end
		table.insert(points, p)
	end

	-- Cars follow these points with straight lerps (PathFollower), so chord error IS
	-- lane error. Subdivide each base span until its chords hug the true offset curve
	-- (lateral AND vertical -- graded decks too); straights keep one point per span.
	local chordTol = RoadConstants.NAV_CHORD_TOLERANCE or 0.1
	local function refine(t0: number, p0: Vector3, t1: number, p1: Vector3, depth: number)
		if depth > 0 then
			local tm = (t0 + t1) * 0.5
			local pm = lanePointAt(tm)
			local chord = p1 - p0
			local chordLen = chord.Magnitude
			local err: number
			if chordLen < 1e-4 then
				err = (pm - p0).Magnitude
			else
				local u = chord / chordLen
				local v = pm - p0
				err = (v - u * v:Dot(u)).Magnitude
			end
			if err > chordTol then
				refine(t0, p0, tm, pm, depth - 1)
				refine(tm, pm, t1, p1, depth - 1)
				return
			end
		end
		push(p1)
	end

	local refineDepth = RoadConstants.NAV_REFINE_DEPTH or 4
	local startT = if forward then 0 else 1
	push(lanePointAt(startT))
	local prevT = startT
	for i = 1, samples do
		local tRaw = i / samples
		local t = if forward then tRaw else 1 - tRaw
		refine(prevT, points[#points], t, lanePointAt(t), refineDepth)
		prevT = t
	end

	local function travelDirAt(index: number, fallback: Vector3): Vector3
		local p = points[index]
		local q = points[math.clamp(index + 1, 1, #points)]
		if index == #points then
			q = points[index]
			p = points[index - 1]
		end
		local dir = flatUnit(q - p)
		return dir or fallback
	end

	local fallback = flatUnit((forward and (seg.p3 - seg.p0) or (seg.p0 - seg.p3))) or Vector3.xAxis
	local fromDir = travelDirAt(1, fallback)
	local toDir = travelDirAt(#points, fallback)
	return points, fromDir, toDir, total
end

-- Route-search heap (pushHeap/popHeap) + A* moved to NavRouter.

-- segmentFilter: optional predicate deciding which network segments this graph
-- builds edges from. RoadService keeps TWO instances: the car graph (rail filtered
-- out) and the rail graph (rail only) -- so no consumer ever needs a class check.
function RoadNavigationGraph.new(segmentFilter: ((seg: any) -> boolean)?)
	return setmetatable({
		_segmentFilter = segmentFilter,
		_edges = {} :: { [string]: LaneEdge },
		_edgeList = {} :: { LaneEdge },
		_edgesByFromNode = {} :: { [number]: { LaneEdge } },
		_edgesByToNode = {} :: { [number]: { LaneEdge } },
		_spatial = {} :: { [string]: { { edgeId: string, index: number } } },
		_customConnectionHandles = {} :: { [string]: { Vector3 } },
		_laneChangeGates = {} :: { LaneChangeGate },
		_laneChangesByEdge = {} :: { [string]: { any } },
		_laneChangeTargets = {} :: { [string]: { string } },
		-- segmentId -> list of edge ids built from that segment (for incremental removal)
		_edgesBySegment = {} :: { [number]: { string } },
		_network = nil :: any,
		_nodeMouth = {} :: { [number]: { [number]: number } },
		_edgeCongestion = {} :: { [string]: number },
		-- Expected SECONDS of wait at the junction each approach edge feeds into
		-- (Webster delay, published by TrafficSignalService). Zero for uncontrolled
		-- junctions -- their cost is already in the turn penalty.
		_edgeControlDelay = {} :: { [string]: number },
		-- Route bookings: edgeId -> token -> expiry, plus a maintained count per edge
		-- (A* reads the count on every edge expansion, so it must be O(1), never a
		-- walk of the bucket), and token -> the edge list it booked, for release.
		_edgeBookings = {} :: { [string]: { [number]: number } },
		_edgeBookingCount = {} :: { [string]: number },
		_bookingRoutes = {} :: { [number]: { string } },
		_version = 0,
	}, RoadNavigationGraph)
end

function RoadNavigationGraph.Version(self: any): number
	return self._version
end

function RoadNavigationGraph.HasEdges(self: any): boolean
	return #self._edgeList > 0
end

function RoadNavigationGraph.GetEdges(self: any): { LaneEdge }
	return self._edgeList
end

function RoadNavigationGraph.GetEdge(self: any, edgeId: string): LaneEdge?
	return self._edges[edgeId]
end

-- Replaces the live congestion snapshot without changing graph version. Pathfinding
-- can react to traffic without making every active car process a road-edit rebuild.
function RoadNavigationGraph.SetCongestionSnapshot(self: any, snapshot: { [string]: number })
	local clean: { [string]: number } = {}
	for edgeId, pressure in snapshot do
		if self._edges[edgeId] and typeof(pressure) == "number" then
			local value = math.clamp(pressure, 0, 1)
			if value > 0.001 then
				clean[edgeId] = value
			end
		end
	end
	self._edgeCongestion = clean
end

-- Every lane edge built from one network segment (both directions).
function RoadNavigationGraph.GetEdgesForSegment(self: any, segmentId: number): { LaneEdge }
	local out: { LaneEdge } = {}
	for _, edgeId in self._edgesBySegment[segmentId] or {} do
		local edge = self._edges[edgeId]
		if edge then table.insert(out, edge) end
	end
	return out
end

function RoadNavigationGraph.GetEdgeCongestion(self: any, edgeId: string): number
	return self._edgeCongestion[edgeId] or 0
end

-- Signal wait, published the same way congestion is: a snapshot, no graph version
-- bump, so retiming a junction re-routes traffic without rebuilding any geometry.
-- This is what lets "how long is the red here" be a real routing input rather than
-- every signalised junction costing the same flat guess.
function RoadNavigationGraph.SetControlDelaySnapshot(self: any, snapshot: { [string]: number })
	local clean: { [string]: number } = {}
	for edgeId, seconds in snapshot do
		if self._edges[edgeId] and typeof(seconds) == "number" and seconds > 0.05 then
			clean[edgeId] = math.min(seconds, 180)
		end
	end
	self._edgeControlDelay = clean
end

function RoadNavigationGraph.GetEdgeControlDelay(self: any, edgeId: string): number
	return self._edgeControlDelay[edgeId] or 0
end

-- == Route bookings ============================================================
-- A driver that commits to a route reserves capacity along it. Later planners see
-- that reservation as cost (NavRouter weights it under real congestion) and peel off
-- onto alternatives, so a wave of cars leaving at the same moment fans out across
-- parallel streets instead of all discovering the same "empty" road and jamming it
-- together. Bookings never touch graph geometry or version -- they are pure routing
-- hints, replaced wholesale each time a driver re-plans.

local function releaseBooking(self: any, token: number)
	local previous = self._bookingRoutes[token]
	if not previous then
		return
	end
	self._bookingRoutes[token] = nil
	for _, edgeId in previous do
		local bucket = self._edgeBookings[edgeId]
		if bucket and bucket[token] then
			bucket[token] = nil
			local count = (self._edgeBookingCount[edgeId] or 1) - 1
			if count <= 0 then
				self._edgeBookingCount[edgeId] = nil
				self._edgeBookings[edgeId] = nil
			else
				self._edgeBookingCount[edgeId] = count
			end
		end
	end
end

-- Reserve `edgeIds` for `token`, replacing whatever that token held before (a
-- reroute books its new tail and frees the old one in one call). `skip` drops the
-- first N edges: the street outside your own door is not a choice, so booking it
-- would only push the neighbours into detours to avoid a road they must use too.
function RoadNavigationGraph.BookRoute(self: any, token: number, edgeIds: { string }, startIndex: number?)
	releaseBooking(self, token)
	if typeof(edgeIds) ~= "table" or #edgeIds == 0 then
		return
	end

	local expiry = os.clock() + (RoadConstants.NAV_BOOKING_TTL or 150)
	local skip = RoadConstants.NAV_BOOKING_SKIP_EDGES or 2
	local first = math.max(1, startIndex or 1) + skip
	local booked: { string } = {}

	for i = first, #edgeIds do
		local edgeId = edgeIds[i]
		if self._edges[edgeId] then
			local bucket = self._edgeBookings[edgeId]
			if not bucket then
				bucket = {}
				self._edgeBookings[edgeId] = bucket
			end
			if not bucket[token] then
				self._edgeBookingCount[edgeId] = (self._edgeBookingCount[edgeId] or 0) + 1
				table.insert(booked, edgeId)
			end
			bucket[token] = expiry
		end
	end

	if #booked > 0 then
		self._bookingRoutes[token] = booked
	end
end

function RoadNavigationGraph.ReleaseBooking(self: any, token: number)
	releaseBooking(self, token)
end

-- Drops bookings whose owner never released them (car destroyed mid-trip, trip
-- handed to another system). Cheap and rare -- NPCDriverService calls it on the
-- congestion-publish cadence, not per frame.
function RoadNavigationGraph.PruneBookings(self: any)
	local now = os.clock()
	local stale: { number } = {}
	for token, edgeIds in self._bookingRoutes do
		local firstEdge = edgeIds[1]
		local bucket = firstEdge and self._edgeBookings[firstEdge]
		local expiry = bucket and bucket[token]
		if not expiry or expiry <= now then
			table.insert(stale, token)
		end
	end
	for _, token in stale do
		releaseBooking(self, token)
	end
end

-- 0..1 share of this edge's carriageway already spoken for by OTHER drivers' committed
-- routes. `exceptToken` is the asking driver's own booking, which must not count against it.
-- Pooled over every same-direction lane of the road: a booking is intent to use the ROAD,
-- not a queue in one lane. Priced per lane, one booked car made the lane beside it look
-- cheaper than LANE_CHANGE_SECONDS, so each planner moved over to the least-booked lane and
-- highway traffic weaved for nothing. Real queues still split lanes through congestion.
function RoadNavigationGraph.GetEdgeBookingPressure(self: any, edgeId: string, exceptToken: number?): number
	local edge = self._edges[edgeId]
	if not edge then
		return 0
	end
	local count, lanes = 0, 0
	for _, laneId in self._edgesBySegment[edge.segmentId] or { edgeId } do
		local lane = self._edges[laneId]
		if not lane or lane.forward ~= edge.forward then continue end
		lanes += 1
		local laneCount = self._edgeBookingCount[laneId]
		if not laneCount then continue end
		count += laneCount
		if exceptToken ~= nil then
			local bucket = self._edgeBookings[laneId]
			if bucket and bucket[exceptToken] then
				count -= 1
			end
		end
	end
	if count <= 0 then
		return 0
	end
	local capacity = math.max(1, edge.length / (RoadConstants.NAV_BOOKING_CAPACITY_GAP or 90)) * math.max(1, lanes)
	return math.clamp(count / capacity, 0, 1)
end

function RoadNavigationGraph.GetIncomingEdgesForSegment(self: any, nodeId: number, segmentId: number): { LaneEdge }
	local out: { LaneEdge } = {}
	for _, edge in self._edgesByToNode[nodeId] or {} do
		if edge.segmentId == segmentId then
			table.insert(out, edge)
		end
	end
	table.sort(out, function(a, b)
		return a.laneOrdinal < b.laneOrdinal
	end)
	return out
end
-- Every lane edge LEAVING a node, innermost lane first. At an outside connection these are
-- the inbound lanes -- the real ones, rather than a geometric guess at which lane faces in.
function RoadNavigationGraph.GetOutgoingEdgesFromNode(self: any, nodeId: number): { LaneEdge }
	local out: { LaneEdge } = {}
	for _, edge in self._edgesByFromNode[nodeId] or {} do
		table.insert(out, edge)
	end
	table.sort(out, function(a, b)
		return a.laneOrdinal < b.laneOrdinal
	end)
	return out
end

function RoadNavigationGraph.GetIncomingEdgeMovements(self: any, edgeId: string): { [string]: boolean }
	local res = { left = false, right = false, straight = false, uturn = false }
	local edge = self._edges[edgeId]
	if not edge then
		return res
	end
	for _, outId in edge.out do
		local outEdge = self._edges[outId]
		if outEdge then
			local movement = edge.outMovement[outId] or classifyTurn(edge.toDir, outEdge.fromDir)
			res[movement] = true
		end
	end
	return res
end

function RoadNavigationGraph.GetIncomingEdgeArrowDirs(self: any, edgeId: string): { [string]: boolean }
	local res = { left = false, right = false, straight = false }
	local edge = self._edges[edgeId]
	if not edge then
		return res
	end
	for _, outId in edge.out do
		local outEdge = self._edges[outId]
		local movement = outEdge and (edge.outMovement[outId] or classifyTurn(edge.toDir, outEdge.fromDir))
		if movement == "left" or movement == "right" or movement == "straight" then
			res[movement] = true
		end
	end
	return res
end

function RoadNavigationGraph._addEdgeToNodeMap(self: any, mapName: string, nodeId: number, edge: LaneEdge)
	local map = self[mapName]
	local bucket = map[nodeId]
	if not bucket then
		bucket = {}
		map[nodeId] = bucket
	end
	table.insert(bucket, edge)
end

function RoadNavigationGraph._indexEdge(self: any, edge: LaneEdge)
	local lastKey = ""
	for index, point in edge.points do
		local key = cellKey(point)
		if key ~= lastKey then
			local bucket = self._spatial[key]
			if not bucket then
				bucket = {}
				self._spatial[key] = bucket
			end
			table.insert(bucket, { edgeId = edge.id, index = index })
			lastKey = key
		end
	end
end

local function cumulativeDistances(points: { Vector3 }): { number }
	local cum = table.create(#points)
	cum[1] = 0
	for i = 2, #points do
		cum[i] = cum[i - 1] + (points[i] - points[i - 1]).Magnitude
	end
	return cum
end

local function pointAtDistance(points: { Vector3 }, cum: { number }, dist: number): Vector3
	local total = cum[#cum] or 0
	if #points == 0 then
		return Vector3.zero
	end
	if dist <= 0 then
		return points[1]
	elseif dist >= total then
		return points[#points]
	end
	for i = 1, #points - 1 do
		local aD = cum[i]
		local bD = cum[i + 1]
		if bD >= dist then
			local span = bD - aD
			local alpha = if span > 1e-6 then (dist - aD) / span else 0
			return points[i]:Lerp(points[i + 1], alpha)
		end
	end
	return points[#points]
end

local function dirAtDistance(points: { Vector3 }, cum: { number }, dist: number): Vector3?
	if #points < 2 then
		return nil
	end
	local total = cum[#cum] or 0
	dist = math.clamp(dist, 0, total)
	for i = 1, #points - 1 do
		if cum[i + 1] >= dist - 1e-6 then
			local d = points[i + 1] - points[i]
			if d.Magnitude > 1e-6 then
				return d.Unit
			end
		end
	end
	local d = points[#points] - points[#points - 1]
	return if d.Magnitude > 1e-6 then d.Unit else nil
end

-- Mouth distance: how far from the node centre an arm's surface is trimmed
-- (corner-fillet boundary, same math as the renderer). Connectors span
-- mouth-to-mouth so cars turn on the junction surface instead of driving to
-- the node centre first -- on a sharp 2-arm bend the centre can sit in the
-- grass well outside the rendered corner.
function RoadNavigationGraph._mouthDistance(self: any, nodeId: number, segId: number): number?
	local network = self._network
	if not network then
		return nil
	end
	local cached = self._nodeMouth[nodeId]
	if not cached then
		local node = network:getNodes()[nodeId]
		if not node then
			return nil
		end
		cached = {}
		local arms: { IntersectionRenderer.Arm } = {}
		local segIds: { number } = {}
		for _, sid in node.segments do
			local seg = network:getSegment(sid)
			if seg and not seg.isArc then
				local raw: Vector3
				if seg.startNode == nodeId then
					raw = seg.p1 - seg.p0
					if raw.Magnitude < 1e-6 then raw = seg.p3 - seg.p0 end
				else
					raw = seg.p2 - seg.p3
					if raw.Magnitude < 1e-6 then raw = seg.p0 - seg.p3 end
				end
				if raw.Magnitude > 1e-6 then
					local corner, offset = IntersectionRenderer.armOverrides(seg, nodeId)
					table.insert(arms, {
						dir = raw.Unit,
						width = RoadTypeCatalog.getOrDefault(seg.roadType).width,
						corner = corner,
						offset = offset,
					})
					table.insert(segIds, sid)
				end
			end
		end
		local dists = IntersectionRenderer.armBoundaryDistances(node.position, arms)
		for i, sid in segIds do
			cached[sid] = dists[i]
		end
		self._nodeMouth[nodeId] = cached
	end
	return cached[segId]
end

-- Build edges for one segment and register them in all indices.
-- Called by both full Rebuild and incremental RebuildSegments.
function RoadNavigationGraph._buildSegmentEdges(self: any, seg: any, network: any)
	if seg.isArc then return end
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	local laneSpeed = RoadRules.getSpeedLimitStuds(seg, spec)
	local taperStart = endTaperWidth(network, seg, seg.startNode, spec.width)
	local taperEnd = endTaperWidth(network, seg, seg.endNode, spec.width)
	local edgeIds: { string } = {}
	for _, plan in lanePlans(spec) do
		local points, fromDir, toDir, length = sampleLane(seg, plan.offset, plan.forward, spec.width, taperStart, taperEnd)
		local fromNode = if plan.forward then seg.startNode else seg.endNode
		local toNode = if plan.forward then seg.endNode else seg.startNode
		local dirSuffix = if plan.forward then "F" else "R"
		local edge: LaneEdge = {
			id = `S{seg.id}:L{plan.laneIndex}:{dirSuffix}`,
			segmentId = seg.id,
			laneIndex = plan.laneIndex,
			laneOrdinal = plan.laneOrdinal,
			laneCountInDirection = plan.laneCountInDirection,
			fromNode = fromNode,
			toNode = toNode,
			forward = plan.forward,
			offset = plan.offset,
			length = length,
			points = points,
			_cum = cumulativeDistances(points),
			fromDir = fromDir,
			toDir = toDir,
			out = {},
			outMovement = {},
			turnCost = {},
			speedLimit = laneSpeed,
			allowedVehicles = RoadRules.laneAllowedVehicleSet(seg, spec, plan.laneOrdinal, plan.laneCountInDirection),
			isRoundabout = seg.isRoundabout,
			roadClass = NavCost.classifyRoad(spec),
			divided = spec.median == true,
			-- A roundabout ring is never weaved on: you pick your lane before you enter.
			laneChangeOk = spec.laneLineDashed == true and not seg.isRoundabout,
		}
		self._edges[edge.id] = edge
		table.insert(self._edgeList, edge)
		self:_addEdgeToNodeMap("_edgesByFromNode", fromNode, edge)
		self:_addEdgeToNodeMap("_edgesByToNode", toNode, edge)
		self:_indexEdge(edge)
		table.insert(edgeIds, edge.id)
	end
	self._edgesBySegment[seg.id] = edgeIds
end

-- Remove all edges that were built from a given segment id.
function RoadNavigationGraph._removeSegmentEdges(self: any, segmentId: number)
	local ids = self._edgesBySegment[segmentId]
	if not ids then return end
	self._edgesBySegment[segmentId] = nil
	for _, edgeId in ids do
		local edge = self._edges[edgeId]
		if not edge then continue end
		-- Remove from _edgeList
		local idx = table.find(self._edgeList, edge)
		if idx then table.remove(self._edgeList, idx) end
		-- Remove from node maps
		local function removeFromNodeMap(mapName: string, nodeId: number)
			local bucket = self[mapName][nodeId]
			if not bucket then return end
			local i = table.find(bucket, edge)
			if i then table.remove(bucket, i) end
			if #bucket == 0 then self[mapName][nodeId] = nil end
		end
		removeFromNodeMap("_edgesByFromNode", edge.fromNode)
		removeFromNodeMap("_edgesByToNode", edge.toNode)
		-- Remove from spatial index
		for key, bucket in self._spatial do
			for i = #bucket, 1, -1 do
				if bucket[i].edgeId == edgeId then
					table.remove(bucket, i)
				end
			end
			if #bucket == 0 then self._spatial[key] = nil end
		end
		self._edges[edgeId] = nil
	end
end

-- Collect all node ids that are touched by a set of segment ids.
local function affectedNodesForSegments(network: any, segmentIds: { [number]: boolean }): { [number]: boolean }
	local nodes: { [number]: boolean } = {}
	for segId in segmentIds do
		local seg = network:getSegment(segId)
		if seg then
			nodes[seg.startNode] = true
			nodes[seg.endNode] = true
		end
	end
	-- Also include any nodes that neighbour the affected nodes (their outgoing
	-- connections may reference the rebuilt edges and must be re-linked).
	local extra: { number } = {}
	for nodeId in nodes do
		local node = network:getNodes()[nodeId]
		if node then
			for _, sid in node.segments do
				local s = network:getSegment(sid)
				if s then
					if not nodes[s.startNode] then table.insert(extra, s.startNode) end
					if not nodes[s.endNode] then table.insert(extra, s.endNode) end
				end
			end
		end
	end
	for _, nid in extra do nodes[nid] = true end
	return nodes
end

function RoadNavigationGraph.Rebuild(self: any, network: any, turnPermissions: { [number]: TurnPermissionSet }?, laneChangeRules: { [string]: boolean }?)
	self._edges = {}
	self._edgeList = {}
	self._edgesByFromNode = {}
	self._edgesByToNode = {}
	self._spatial = {}
	self._customConnectionHandles = {}
	self._laneChangeGates = {}
	self._laneChangesByEdge = {}
	self._edgesBySegment = {}
	self._network = network
	self._nodeMouth = {}
	self._edgeCongestion = {}
	self._edgeControlDelay = {}
	-- Edge ids do not survive a rebuild, so every booking is stale by definition.
	self._edgeBookings = {}
	self._edgeBookingCount = {}
	self._bookingRoutes = {}
	local permissionData = turnPermissions or {}
	for _, perms in permissionData do
		local custom = (perms :: any).customConnections
		if typeof(custom) == "table" then
			for key, data in custom do
				local handles = typeof(data) == "table" and data.handles
				if typeof(key) == "string" and typeof(handles) == "table" then
					local clean: { Vector3 } = {}
					for _, p in handles do
						if typeof(p) == "Vector3" then
							table.insert(clean, p)
						end
					end
					if #clean > 0 then
						self._customConnectionHandles[key] = clean
					end
				end
			end
		end
	end

	for _, seg in network:getSegments() do
		if self._segmentFilter and not self._segmentFilter(seg) then continue end
		self:_buildSegmentEdges(seg, network)
	end

	self:_rebuildConnections(network, permissionData)
	self:_rebuildLaneChangeGates(laneChangeRules or {}, network)

	self._version += 1
end

-- Incremental rebuild: only re-sample the given dirty segments and
-- re-link only the nodes they touch. Everything else is left untouched.
-- dirtySegmentIds : set of segment ids that were added/changed/removed
-- removedSegmentIds : set of segment ids that no longer exist in the network
function RoadNavigationGraph.RebuildSegments(
	self: any,
	network: any,
	dirtySegmentIds: { [number]: boolean },
	removedSegmentIds: { [number]: boolean }?,
	turnPermissions: { [number]: TurnPermissionSet }?,
	laneChangeRules: { [string]: boolean }?
)
	local permissionData = turnPermissions or {}
	self._network = network
	self._nodeMouth = {}

	-- Refresh custom connection handles from permission data
	self._customConnectionHandles = {}
	for _, perms in permissionData do
		local custom = (perms :: any).customConnections
		if typeof(custom) == "table" then
			for key, data in custom do
				local handles = typeof(data) == "table" and data.handles
				if typeof(key) == "string" and typeof(handles) == "table" then
					local clean: { Vector3 } = {}
					for _, p in handles do
						if typeof(p) == "Vector3" then table.insert(clean, p) end
					end
					if #clean > 0 then self._customConnectionHandles[key] = clean end
				end
			end
		end
	end

	-- Collect ALL segment ids whose edges need rebuilding:
	-- dirty ones + removed ones (which need their old edges stripped).
	local allDirty: { [number]: boolean } = {}
	for id in dirtySegmentIds do allDirty[id] = true end
	if removedSegmentIds then
		for id in removedSegmentIds do allDirty[id] = true end
	end

	-- Determine which nodes will be affected so we can re-link them.
	local affectedNodes = affectedNodesForSegments(network, allDirty)

	-- Strip old edges for all affected segments and clear their connection data.
	for segId in allDirty do
		self:_removeSegmentEdges(segId)
	end
	-- Clear out-edges of every edge ARRIVING at an affected node -- those are exactly the
	-- arrays _rebuildConnectionsForNodes refills below, so each is cleared once and rebuilt
	-- once. An edge's out-links are owned by the node it arrives at; clearing the edges
	-- LEAVING an affected node wiped links owned by a node one hop further out, which the
	-- relink pass never visits -- that lane kept an empty exit list for good and every car
	-- reaching it U-turned in the middle of the road.
	for nodeId in affectedNodes do
		for _, edge in (self._edgesByToNode[nodeId] or {}) do
			edge.out = {}
			edge.outMovement = {}
			edge.turnCost = {}
		end
	end

	-- Re-sample all currently-existing dirty segments (not the removed ones).
	for segId in dirtySegmentIds do
		if removedSegmentIds and removedSegmentIds[segId] then continue end
		local seg = network:getSegment(segId)
		if seg and not (self._segmentFilter and not self._segmentFilter(seg)) then
			self:_buildSegmentEdges(seg, network)
		end
	end

	-- Re-link connections only for the affected nodes.
	self:_rebuildConnectionsForNodes(network, permissionData, affectedNodes)

	-- Full lane-change gate rebuild (cheap — just iterates edge list).
	self._laneChangeGates = {}
	self._laneChangesByEdge = {}
	self:_rebuildLaneChangeGates(laneChangeRules or {}, network)

	self._version += 1
end

-- A degree-1 node within this many studs of the map boundary is an OUTSIDE CONNECTION
-- (traffic enters / leaves the map here), not a turnaround.
local MAP_EDGE_TOL = 30
local function isMapEdgeNode(node: any): boolean
	local p = node.position
	if not p then return false end
	local h = RoadConstants.MAP_HALF_EXTENT
	return math.abs(math.abs(p.X) - h) <= MAP_EDGE_TOL or math.abs(math.abs(p.Z) - h) <= MAP_EDGE_TOL
end

function RoadNavigationGraph._movementAllowed(self: any, network: any, nodeId: number, movement: string, turnPermissions: { [number]: TurnPermissionSet }, incomingEdgeId: string?, outgoingEdgeId: string?): boolean
	local node = network:getNodes()[nodeId]
	if not node then
		return false
	end
	if #node.segments <= 1 then
		-- An outside connection (edge dead-end) is an entry/exit, never a U-turn point.
		if isMapEdgeNode(node) then return false end
		return movement == "uturn"
	end
	if #node.segments < 3 then
		return movement ~= "uturn"
	end
	local perms = turnPermissions[nodeId] or defaultPermissions()
	local anyPerms = perms :: any

	if anyPerms.manual then
		if not (incomingEdgeId and outgoingEdgeId) then
			return false
		end
		local rules = anyPerms.connectionRules
		return rules ~= nil and rules[connectionKey(incomingEdgeId, outgoingEdgeId)] == true
	end
	if incomingEdgeId and outgoingEdgeId then
		local connectionValue = anyPerms.connectionRules and anyPerms.connectionRules[connectionKey(incomingEdgeId, outgoingEdgeId)]
		if connectionValue ~= nil then
			return connectionValue == true
		end
	end
	if incomingEdgeId then
		local laneRule = anyPerms.laneRules and anyPerms.laneRules[incomingEdgeId]
		local laneValue = laneRule and laneRule[movement]
		if laneValue ~= nil then
			return laneValue == true
		end
	end
	if movement == "left" then
		return perms.left
	elseif movement == "right" then
		return perms.right
	elseif movement == "straight" then
		return perms.straight
	elseif movement == "uturn" then
		return perms.uturn
	end
	return false
end

local function edgeBodyPoint(edge: any, atToNode: boolean, back: number): Vector3
	local pts = edge.points
	local n = #pts
	if n == 0 then return Vector3.zero end
	local idx = if atToNode then n else 1
	local step = if atToNode then -1 else 1
	local acc = 0
	while true do
		local ni = idx + step
		if ni < 1 or ni > n then return pts[idx] end
		acc += (pts[ni] - pts[idx]).Magnitude
		idx = ni
		if acc >= back then return pts[idx] end
	end
end

-- Re-link connections for a specific subset of nodes only.
function RoadNavigationGraph._rebuildConnectionsForNodes(self: any, network: any, turnPermissions: { [number]: TurnPermissionSet }, nodeIds: { [number]: boolean })
	for nodeId in nodeIds do
		local node = network:getNodes()[nodeId]
		if not node then continue end
		local incoming = self._edgesByToNode[nodeId]
		local outgoing = self._edgesByFromNode[nodeId]
		if not incoming or not outgoing then continue end

		if #node.segments == 2 then
			local sA = network:getSegment(node.segments[1])
			local sB = network:getSegment(node.segments[2])
			if sA and sB and not sA.isArc and not sB.isArc then
				local wA = RoadTypeCatalog.getOrDefault(sA.roadType).width
				local wB = RoadTypeCatalog.getOrDefault(sB.roadType).width
				local dA = segDirFromNode(sA, nodeId)
				local dB = segDirFromNode(sB, nodeId)
				if math.abs(wA - wB) > 1e-3 and dA and dB and dA:Dot(dB) < STRAIGHT_JOIN_DOT then
					local back = RoadConstants.ROAD_WIDTH_TRANSITION_LENGTH
					local T = incoming[1].toDir
					local cross = Vector3.new(-T.Z, 0, T.X)
					local function lat(edge: any, atToNode: boolean): number
						return (edgeBodyPoint(edge, atToNode, back) - node.position):Dot(cross)
					end
					for _, inEdge in incoming do
						local inLat = lat(inEdge, true)
						local bestOut, bestD = nil, math.huge
						for _, outEdge in outgoing do
							if outEdge.segmentId ~= inEdge.segmentId and outEdge.fromDir:Dot(inEdge.toDir) > 0.5 then
								local d = math.abs(lat(outEdge, false) - inLat)
								if d < bestD then bestD = d; bestOut = outEdge end
							end
						end
						if bestOut and self:_movementAllowed(network, nodeId, "straight", turnPermissions, inEdge.id, bestOut.id) then
							table.insert(inEdge.out, bestOut.id)
							inEdge.outMovement[bestOut.id] = "straight"
							inEdge.turnCost[bestOut.id] = movementCost("straight", inEdge.toDir, bestOut.fromDir)
						end
					end
					continue
				end
			end
		end

		local perms = turnPermissions[nodeId]
		local anyPerms = perms :: any
		local manual = anyPerms and anyPerms.manual == true
		local connectionRules = anyPerms and anyPerms.connectionRules
		-- At a roundabout node the junction lane policy does not apply (every movement is a
		-- merge or a diverge); roundaboutLaneAllowed keeps each car in its lane instead.
		local isRA = network.isRoundaboutNode ~= nil and network:isRoundaboutNode(nodeId)
		for _, inEdge in incoming do
			local autoPlans = buildAutoExitPlans(inEdge, outgoing, #node.segments)
			for _, outEdge in outgoing do
				local plan = autoPlans[outEdge.segmentId] or { movement = classifyTurn(inEdge.toDir, outEdge.fromDir) }
				local movement = plan.movement
				local explicitRule = connectionRules and connectionRules[connectionKey(inEdge.id, outEdge.id)]
				local usesDefaultLanePolicy = not manual and explicitRule == nil
				local laneAllowed = not usesDefaultLanePolicy
					or (if isRA then roundaboutLaneAllowed(inEdge, outEdge)
						else defaultAutoLaneAllowed(#node.segments, inEdge, outEdge, plan))
				if laneAllowed and self:_movementAllowed(network, nodeId, movement, turnPermissions, inEdge.id, outEdge.id) then
					table.insert(inEdge.out, outEdge.id)
					inEdge.outMovement[outEdge.id] = movement
					-- A junction turn's landing lane is the manoeuvre, not a weave -- only
					-- straight-on and plain joints pay for moving over, and inside a real
					-- junction it is the last resort (see junctionStraightLaneAllowed).
					local shift = if movement == "straight" or #node.segments < 3 then laneShift(inEdge, outEdge) else 0
					local perLane = if isRA then LANE_SHIFT_SECONDS else JUNCTION_SHIFT_SECONDS
					inEdge.turnCost[outEdge.id] = movementCost(movement, inEdge.toDir, outEdge.fromDir)
						+ shift * perLane
				end
			end
		end
	end
end

-- A full relink is the incremental one over every node: one copy of the lane policy.
function RoadNavigationGraph._rebuildConnections(self: any, network: any, turnPermissions: { [number]: TurnPermissionSet })
	local all: { [number]: boolean } = {}
	for nodeId in network:getNodes() do
		all[nodeId] = true
	end
	self:_rebuildConnectionsForNodes(network, turnPermissions, all)
end

-- `allows` filters candidate lanes (a class-restricted bus lane is invisible to ordinary
-- traffic); nil considers every lane.
function RoadNavigationGraph.NearestEdge(self: any, pos: Vector3, allows: ((LaneEdge) -> boolean)?): NearestResult?
	if #self._edgeList == 0 then
		return nil
	end
	local cell = RoadConstants.NAV_SPATIAL_CELL_SIZE or DEFAULT_CELL_SIZE
	local cx = math.floor(pos.X / cell)
	local cz = math.floor(pos.Z / cell)
	local bestEdge: LaneEdge? = nil
	local bestIndex = 1
	local bestDistSq = math.huge
	local checked = false
	local evaluatedEdges: { [string]: boolean } = {}

	for radius = 0, 2 do
		for x = cx - radius, cx + radius do
			for z = cz - radius, cz + radius do
				local bucket = self._spatial[`{x},{z}`]
				if bucket then
					checked = true
					for _, item in bucket do
						local edge = self._edges[item.edgeId]
						if edge and not evaluatedEdges[edge.id] and (not allows or allows(edge)) then
							evaluatedEdges[edge.id] = true

							for index, point in edge.points do
								local d = distanceSq(point, pos)
								if d < bestDistSq then
									bestDistSq = d
									bestEdge = edge
									bestIndex = index
								end
							end
						end
					end
				end
			end
		end
		if checked and bestEdge then
			break
		end
	end

	if not bestEdge then
		for _, edge in self._edgeList do
			if allows and not allows(edge) then continue end
			for index, point in edge.points do
				local d = distanceSq(point, pos)
				if d < bestDistSq then
					bestDistSq = d
					bestEdge = edge
					bestIndex = index
				end
			end
		end
	end

	if not bestEdge then
		return nil
	end
	return { edge = bestEdge, index = bestIndex, distance = math.sqrt(bestDistSq) }
end

function RoadNavigationGraph.RandomPoint(self: any): Vector3?
	local count = #self._edgeList
	if count == 0 then
		return nil
	end
	local edge = self._edgeList[math.random(1, count)]
	local points = edge.points
	return points[math.random(1, #points)]
end

local function appendPoint(out: { Vector3 }, p: Vector3)
	local last = out[#out]
	if last and (last - p).Magnitude < 0.05 then
		return
	end
	table.insert(out, p)
end

local function laneChangeRibbonPoints(fromEdge: LaneEdge, toEdge: LaneEdge, startDist: number, endDist: number): { Vector3 }
	local out: { Vector3 } = {}
	local fromCum = fromEdge._cum
	local toCum = toEdge._cum
	local samples = 8
	for i = 0, samples do
		local alpha = i / samples
		local eased = alpha * alpha * (3 - 2 * alpha)
		local dist = startDist + (endDist - startDist) * alpha
		local fromPos = pointAtDistance(fromEdge.points, fromCum, dist)
		local toPos = pointAtDistance(toEdge.points, toCum, dist)
		table.insert(out, fromPos:Lerp(toPos, eased))
	end
	return out
end

function RoadNavigationGraph._indexLaneChange(self: any, edgeId: string, gate: LaneChangeGate, connection: LaneChangeConnection)
	local bucket = self._laneChangesByEdge[edgeId]
	if not bucket then
		bucket = {}
		self._laneChangesByEdge[edgeId] = bucket
	end
	table.insert(bucket, {
		gateId = gate.id,
		segmentId = gate.segmentId,
		direction = gate.direction,
		gateIndex = gate.gateIndex,
		pairIndex = gate.pairIndex,
		startDistance = gate.startDistance,
		endDistance = gate.endDistance,
		fromEdgeId = connection.fromEdgeId,
		toEdgeId = connection.toEdgeId,
		points = connection.points,
	})
end

function RoadNavigationGraph._rebuildLaneChangeGates(self: any, laneChangeRules: { [string]: boolean }, network: any?)
	local INTERSECTION_CLEAR = 20
	self._laneChangeTargets = {}

	local isIntersection: { [number]: boolean } = {}
	if network then
		for nodeId, node in network:getNodes() do
			if #node.segments >= 3 then
				isIntersection[nodeId] = true
			end
		end
	end

	local grouped: { [string]: { LaneEdge } } = {}
	for _, edge in self._edgeList do
		local direction = if edge.forward then "F" else "R"
		local key = `S{edge.segmentId}:{direction}`
		local bucket = grouped[key]
		if not bucket then
			bucket = {}
			grouped[key] = bucket
		end
		table.insert(bucket, edge)
	end

	local ribbonLength = RoadConstants.NAV_LANE_CHANGE_LENGTH or 18
	local halfRibbon = ribbonLength * 0.5

	for _, edges in grouped do
		table.sort(edges, function(a, b)
			return a.laneOrdinal < b.laneOrdinal
		end)

		local refEdge = edges[1]
		if not refEdge or not refEdge.laneChangeOk then continue end

		local fromNode = refEdge.fromNode
		local toNode = refEdge.toNode
		local clearStart = (network and isIntersection[fromNode]) and INTERSECTION_CLEAR or 0
		local clearEnd   = (network and isIntersection[toNode])   and INTERSECTION_CLEAR or 0

		for pairIndex = 1, #edges - 1 do
			local a = edges[pairIndex]
			local b = edges[pairIndex + 1]
			local total = math.min(a.length, b.length)

			local centerDist = total * 0.5
			local startDist  = centerDist - halfRibbon
			local endDist    = centerDist + halfRibbon

			if startDist < clearStart or endDist > total - clearEnd then
				continue
			end

			local direction = if a.forward then "F" else "R"
			local gateId = `S{a.segmentId}:{direction}:G1:P{pairIndex}`
			local aCum = a._cum
			local bCum = b._cum
			local gate: LaneChangeGate = {
				id = gateId,
				segmentId = a.segmentId,
				direction = direction,
				gateIndex = 1,
				pairIndex = pairIndex,
				startDistance = startDist,
				endDistance = endDist,
				dots = {
					{ edgeId = a.id, kind = "in", position = pointAtDistance(a.points, aCum, startDist) },
					{ edgeId = b.id, kind = "in", position = pointAtDistance(b.points, bCum, startDist) },
					{ edgeId = a.id, kind = "out", position = pointAtDistance(a.points, aCum, endDist) },
					{ edgeId = b.id, kind = "out", position = pointAtDistance(b.points, bCum, endDist) },
				},
				connections = {},
			}
			for _, fromEdge in { a, b } do
				for _, toEdge in { a, b } do

					local defaultAllowed = true
					local override = laneChangeRules[laneChangeRuleKey(gateId, fromEdge.id, toEdge.id)]
					local conn: LaneChangeConnection = {
						fromEdgeId = fromEdge.id,
						toEdgeId = toEdge.id,
						allowed = if override == nil then defaultAllowed else override,
						points = laneChangeRibbonPoints(fromEdge, toEdge, startDist, endDist),
					}
					table.insert(gate.connections, conn)
					if conn.allowed then
						self:_indexLaneChange(fromEdge.id, gate, conn)
					end
				end
			end
			table.insert(self._laneChangeGates, gate)
		end
	end
end

function RoadNavigationGraph.GetLaneChangeGateData(self: any): { any }

	local out: { any } = {}
	for _, gate in self._laneChangeGates do
		local liteConns: { any } = {}
		for _, conn in gate.connections do
			table.insert(liteConns, {
				fromEdgeId = conn.fromEdgeId,
				toEdgeId   = conn.toEdgeId,
				allowed    = conn.allowed,

			})
		end
		table.insert(out, {
			id            = gate.id,
			segmentId     = gate.segmentId,
			direction     = gate.direction,
			gateIndex     = gate.gateIndex,
			pairIndex     = gate.pairIndex,
			startDistance = gate.startDistance,
			endDistance   = gate.endDistance,
			dots          = gate.dots,
			connections   = liteConns,
		})
	end
	return out
end

function RoadNavigationGraph.GetLaneChangesForEdge(self: any, edgeId: string): { any }
	return self._laneChangesByEdge[edgeId] or {}
end

function RoadNavigationGraph.HasLaneChangeConnection(self: any, gateId: string, fromEdgeId: string, toEdgeId: string): boolean
	for _, gate in self._laneChangeGates do
		if gate.id == gateId then
			for _, conn in gate.connections do
				if conn.fromEdgeId == fromEdgeId and conn.toEdgeId == toEdgeId then
					return true
				end
			end
		end
	end
	return false
end

function RoadNavigationGraph.LaneChangeRuleKey(_self: any, gateId: string, fromEdgeId: string, toEdgeId: string): string
	return laneChangeRuleKey(gateId, fromEdgeId, toEdgeId)
end

-- Clear road after a junction mouth before anyone moves over, and the solid-line zone before
-- the next one (US practice paints the last stretch before a stop line solid white).
local LANE_CHANGE_CLEAR = 6
local LANE_CHANGE_SOLID_ZONE = 24
-- Shortest a lane change is ever drawn; the driver lengthens it with speed.
local LANE_CHANGE_MIN_LENGTH = 14

-- The stretch of `fromEdgeId` over which a move into the neighbouring lane `toEdgeId` may
-- START: (earliest, latest) distance along fromEdge, or nil when the two are not dashed-line
-- neighbours, the player forbade it (lane-change gate rules), or the block is too short.
function RoadNavigationGraph.GetLaneChangeWindow(self: any, fromEdgeId: string, toEdgeId: string): (number?, number?)
	local allowed = false
	for _, entry in self._laneChangesByEdge[fromEdgeId] or {} do
		if entry.toEdgeId == toEdgeId and toEdgeId ~= fromEdgeId then
			allowed = true
			break
		end
	end
	if not allowed then
		return nil, nil
	end
	local edge: LaneEdge = self._edges[fromEdgeId]
	local cum = edge._cum
	local total = cum[#cum] or edge.length
	local earliest = (self:_mouthDistance(edge.fromNode, edge.segmentId) or 0) + LANE_CHANGE_CLEAR
	local latest = total - (self:_mouthDistance(edge.toNode, edge.segmentId) or 0)
		- LANE_CHANGE_SOLID_ZONE - LANE_CHANGE_MIN_LENGTH
	if latest < earliest then
		return nil, nil
	end
	return earliest, latest
end

-- Every lane this one may move over into mid-block (see GetLaneChangeWindow). Cached: the
-- router asks on every edge it expands, and _rebuildLaneChangeGates resets it.
function RoadNavigationGraph.GetLaneChangeTargets(self: any, edgeId: string): { string }
	local cached = self._laneChangeTargets[edgeId]
	if cached then
		return cached
	end
	local out: { string } = {}
	for _, entry in self._laneChangesByEdge[edgeId] or {} do
		if entry.toEdgeId ~= edgeId and self:GetLaneChangeWindow(edgeId, entry.toEdgeId) then
			table.insert(out, entry.toEdgeId)
		end
	end
	self._laneChangeTargets[edgeId] = out
	return out
end

-- The path a vehicle drives moving over from one lane to its neighbour between two distances.
function RoadNavigationGraph.GetLaneChangeRibbon(self: any, fromEdgeId: string, toEdgeId: string, startDist: number, endDist: number): { Vector3 }
	local fromEdge, toEdge = self._edges[fromEdgeId], self._edges[toEdgeId]
	if not fromEdge or not toEdge then
		return {}
	end
	return laneChangeRibbonPoints(fromEdge, toEdge, startDist, endDist)
end

RoadNavigationGraph.LANE_CHANGE_MIN_LENGTH = LANE_CHANGE_MIN_LENGTH

local function distanceAtIndex(points: { Vector3 }, index: number): number
	if #points == 0 then
		return 0
	end
	local clamped = math.clamp(index, 1, #points)
	local dist = 0
	for i = 2, clamped do
		dist += (points[i] - points[i - 1]).Magnitude
	end
	return dist
end

local function appendEdgeSlice(out: { Vector3 }, edge: LaneEdge, startDist: number, endDist: number)
	local points = edge.points
	if #points == 0 then
		return
	end
	local cum = edge._cum
	local total = cum[#cum] or 0
	local d0 = math.clamp(startDist, 0, total)
	local d1 = math.clamp(endDist, 0, total)
	if d1 < d0 then
		d1 = d0
	end
	appendPoint(out, pointAtDistance(points, cum, d0))
	for i = 2, #points - 1 do
		local d = cum[i]
		if d > d0 + 0.05 and d < d1 - 0.05 then
			appendPoint(out, points[i])
		end
	end
	appendPoint(out, pointAtDistance(points, cum, d1))
end

local function edgeTurnSetback(edge: LaneEdge): number
	local points = edge.points
	if #points < 2 then
		return 0
	end
	local cum = edge._cum
	local total = cum[#cum] or edge.length
	return math.min(RoadConstants.NAV_TURN_SETBACK or 16, total * 0.45)
end

local function resolveDotSetback(edge: LaneEdge, override: number?): number
	if not override then
		return edgeTurnSetback(edge)
	end
	local cum = edge._cum
	local total = cum[#cum] or edge.length
	return math.min(override, total * 0.8)
end

local function appendConnector(out: { Vector3 }, fromEdge: LaneEdge, toEdge: LaneEdge, p0: Vector3, p3: Vector3, d0: Vector3?, d1: Vector3?)
	local flatGap = Vector3.new(p3.X - p0.X, 0, p3.Z - p0.Z)
	local gap = flatGap.Magnitude

	-- Mouth tangents when provided: on curved approaches the edge's node-end
	-- tangent points somewhere else entirely.
	local inDir = flatUnit(d0 or fromEdge.toDir) or Vector3.xAxis
	local outDir = flatUnit(d1 or toEdge.fromDir) or inDir
	local movement = classifyTurn(inDir, outDir)

	if gap < 0.1 then

		local roadWidth = (fromEdge.offset ~= nil and toEdge.offset ~= nil)
			and math.abs(fromEdge.offset - toEdge.offset) or 6
		roadWidth = math.max(roadWidth, 4)
		local right = Vector3.new(inDir.Z, 0, -inDir.X)
		local arcCentre = p0 + right * (roadWidth * 0.5)
		local yAvg = (p0.Y + p3.Y) * 0.5
		local STEPS = 16
		for i = 1, STEPS - 1 do
			local angle = (i / STEPS) * math.pi
			local px = arcCentre.X - right.X * roadWidth * 0.5 * math.cos(angle) + inDir.X * roadWidth * 0.5 * math.sin(angle)
			local pz = arcCentre.Z - right.Z * roadWidth * 0.5 * math.cos(angle) + inDir.Z * roadWidth * 0.5 * math.sin(angle)
			appendPoint(out, Vector3.new(px, yAvg, pz))
		end
		return
	end

	local theta = math.abs(signedTurnAngle(inDir, outDir))
	local handle: number
	if movement == "uturn" and fromEdge.segmentId == toEdge.segmentId then
		-- True U-turn back onto the same road: tight teardrop.
		handle = math.min(gap * 0.25, (RoadConstants.NAV_TURN_HANDLE or 24) * 0.5)
	elseif theta > 0.05 then
		-- Fit the circular arc through both mouths tangent to both lane
		-- directions: (4/3)*tan(theta/4)*R is the exact cubic handle for a
		-- circular sweep. Follows the rendered corner instead of ballooning
		-- outward on sharp bends.
		local radius = gap / (2 * math.sin(theta * 0.5))
		handle = math.min((4 / 3) * math.tan(theta * 0.25) * radius, gap * 0.7)
	else
		handle = gap / 3
	end
	if handle < 0.25 then
		appendPoint(out, p0:Lerp(p3, 0.5))
		return
	end

	-- Full 3D mouth directions keep the connector tangent-continuous on grades.
	local h0 = d0 or inDir
	local h1 = d1 or outDir
	local p1 = p0 + h0 * handle
	local p2 = p3 - h1 * handle
	-- Sample by gap length AND sweep angle: a U-turn covers ~180 deg over a
	-- short flat gap, so distance-only sampling gave 4-point polylines that
	-- cars visibly snapped along. One point per ~10 deg keeps turns smooth.
	local turnDeg = math.deg(theta)
	local samples = math.clamp(math.max(math.ceil(gap / 3), math.ceil(turnDeg / 10)), 4, 32)
	for i = 1, samples - 1 do
		appendPoint(out, BezierUtil.point(p0, p1, p2, p3, i / samples))
	end
end

-- Roundabout entry and exit: deflected, like a real one. An entering car first drifts out
-- toward its own kerb and only then curves onto the ring; a leaving car swings wide off the
-- ring and straightens into its lane. That opens the middle of every two-way arm's mouth for
-- the splitter island (RoadSceneRenderer), which is shaped from these very paths.
local ROUNDABOUT_MOUTH_FLARE = 1.6 -- studs of drift at most; less on a short mouth
local function appendCubic(out: { Vector3 }, a: Vector3, b: Vector3, c: Vector3, d: Vector3, samples: number, includeEnd: boolean)
	for i = 1, (if includeEnd then samples else samples - 1) do
		appendPoint(out, BezierUtil.point(a, b, c, d, i / samples))
	end
end

-- Cubic handle for a circular sweep between two headings (same rule appendConnector uses).
local function arcHandle(gap: number, dirA: Vector3, dirB: Vector3): number
	local theta = math.abs(signedTurnAngle(dirA, dirB))
	if theta <= 0.05 then return gap / 3 end
	local radius = gap / (2 * math.sin(theta * 0.5))
	return math.min((4 / 3) * math.tan(theta * 0.25) * radius, gap * 0.7)
end

local function appendRoundaboutMouthConnector(graph: any, out: { Vector3 }, fromEdge: LaneEdge, toEdge: LaneEdge,
	p0: Vector3, p3: Vector3, d0: Vector3, d1: Vector3): boolean
	local entry = not fromEdge.isRoundabout and toEdge.isRoundabout == true
	local exit = fromEdge.isRoundabout == true and not toEdge.isRoundabout
	if not (entry or exit) then return false end
	local network = graph and graph._network
	local node = network and network:getNodes()[if entry then fromEdge.toNode else toEdge.fromNode]
	if not node then return false end
	-- The arm's direction, pointing IN to the ring for an entry and OUT of it for an exit.
	local armDir = flatUnit(if entry then d0 else d1)
	if not armDir then return false end
	local armPt = if entry then p0 else p3
	local along = Vector3.new(p3.X - p0.X, 0, p3.Z - p0.Z):Dot(armDir)
	if along < 4 then return false end
	local right = Vector3.new(-armDir.Z, 0, armDir.X)
	local lateral = (armPt - node.position):Dot(right)
	if math.abs(lateral) < 0.5 then return false end -- a lane on the arm's centreline: nowhere to drift
	local outward = right * math.sign(lateral)
	local flare = math.min(ROUNDABOUT_MOUTH_FLARE, along * 0.3)
	local half = along * 0.5
	local mid = (if entry then p0 + armDir * half else p3 - armDir * half) + outward * flare
	mid = Vector3.new(mid.X, (p0.Y + p3.Y) * 0.5, mid.Z)
	local ringDir = flatUnit(if entry then d1 else d0) or armDir
	local sLen = half * 0.45
	if entry then
		-- drift out along the arm, then the circular sweep onto the ring
		appendCubic(out, p0, p0 + armDir * sLen, mid - armDir * sLen, mid, math.clamp(math.ceil(half / 1.5), 4, 16), true)
		local gap = Vector3.new(p3.X - mid.X, 0, p3.Z - mid.Z).Magnitude
		local h = arcHandle(gap, armDir, ringDir)
		appendCubic(out, mid, mid + armDir * h, p3 - d1 * h, p3, math.clamp(math.ceil(gap / 1.5), 4, 24), false)
	else
		local gap = Vector3.new(mid.X - p0.X, 0, mid.Z - p0.Z).Magnitude
		local h = arcHandle(gap, ringDir, armDir)
		appendCubic(out, p0, p0 + d0 * h, mid - armDir * h, mid, math.clamp(math.ceil(gap / 1.5), 4, 24), true)
		appendCubic(out, mid, mid + armDir * sLen, p3 - armDir * sLen, p3, math.clamp(math.ceil(half / 1.5), 4, 16), false)
	end
	return true
end

local function appendCustomConnector(out: { Vector3 }, p0: Vector3, p3: Vector3, handles: { Vector3 })
	local h = handles[1]
	if not h then
		appendPoint(out, p0:Lerp(p3, 0.5))
		return
	end
	local flatA = Vector3.new(h.X - p0.X, 0, h.Z - p0.Z).Magnitude
	local flatB = Vector3.new(p3.X - h.X, 0, p3.Z - h.Z).Magnitude
	local samples = math.clamp(math.ceil((flatA + flatB) / 3), 5, 16)
	for i = 1, samples - 1 do
		local t = i / samples
		local a = p0:Lerp(h, t)
		local b = h:Lerp(p3, t)
		appendPoint(out, a:Lerp(b, t))
	end
end

local function connectionEdgeSetbacks(graph: any, fromEdge: LaneEdge, toEdge: LaneEdge): (number, number)
	local fromCum = fromEdge._cum
	local fromTotal = fromCum[#fromCum] or fromEdge.length
	local toCum = toEdge._cum
	local toTotal = toCum[#toCum] or toEdge.length

	-- A true U-turn back onto the same road leaves from the lane tip in a
	-- teardrop. A sharp bend onto ANOTHER segment is NOT a U-turn even when its
	-- angle says so -- it takes the mouth-to-mouth path below.
	local movement = classifyTurn(fromEdge.toDir, toEdge.fromDir)
	if movement == "uturn" and fromEdge.segmentId == toEdge.segmentId then
		return math.min(1.25, fromTotal * 0.08), math.min(1.25, toTotal * 0.08)
	end

	-- Connectors span the junction mouths -- where each arm's surface is
	-- trimmed -- so cars turn ON the junction surface instead of driving to the
	-- node centre first and hooking back out.
	local fromSetback = (graph and graph:_mouthDistance(fromEdge.toNode, fromEdge.segmentId)) or edgeTurnSetback(fromEdge)
	local toSetback = (graph and graph:_mouthDistance(toEdge.fromNode, toEdge.segmentId)) or edgeTurnSetback(toEdge)
	return math.min(fromSetback, fromTotal * 0.45), math.min(toSetback, toTotal * 0.45)
end

local function buildConnectionPoints(graph: any, fromEdge: LaneEdge, toEdge: LaneEdge, customHandles: { Vector3 }?): ({ Vector3 }, number, number)
	local out: { Vector3 } = {}
	local fromCum = fromEdge._cum
	local fromTotal = fromCum[#fromCum] or fromEdge.length
	local toCum = toEdge._cum
	local fromSetback, toSetback = connectionEdgeSetbacks(graph, fromEdge, toEdge)

	local fromDist = math.max(0, fromTotal - fromSetback)
	local p0 = pointAtDistance(fromEdge.points, fromCum, fromDist)
	local p3 = pointAtDistance(toEdge.points, toCum, toSetback)
	local d0 = dirAtDistance(fromEdge.points, fromCum, fromDist)
	local d1 = dirAtDistance(toEdge.points, toCum, toSetback)
	appendPoint(out, p0)
	if customHandles and #customHandles > 0 then
		appendCustomConnector(out, p0, p3, customHandles)
	elseif not appendRoundaboutMouthConnector(graph, out, fromEdge, toEdge, p0, p3, d0, d1) then
		appendConnector(out, fromEdge, toEdge, p0, p3, d0, d1)
	end
	appendPoint(out, p3)
	return out, fromSetback, toSetback
end

function RoadNavigationGraph.GetConnectionPoints(self: any, fromEdgeId: string, toEdgeId: string): ({ Vector3 }, number, number)
	local fromEdge = self._edges[fromEdgeId]
	local toEdge = self._edges[toEdgeId]
	if not fromEdge or not toEdge then
		return {}, 0, 0
	end
	return buildConnectionPoints(self, fromEdge, toEdge, self._customConnectionHandles[connectionKey(fromEdgeId, toEdgeId)])
end

-- Setbacks for the connector between two edges: (distance back from the
-- approach edge's end, distance into the exit edge). Drivers hand off to the
-- connector at the first and resume edge travel at the second.
function RoadNavigationGraph.GetConnectionSetbacks(self: any, fromEdgeId: string, toEdgeId: string): (number, number)
	local fromEdge = self._edges[fromEdgeId]
	local toEdge = self._edges[toEdgeId]
	if not fromEdge or not toEdge then
		return 0, 0
	end
	return connectionEdgeSetbacks(self, fromEdge, toEdge)
end

-- A step between two lanes of the SAME road and direction is a mid-block lane change, not a
-- junction movement.
local function isLaneChangeStep(a: LaneEdge, b: LaneEdge): boolean
	return a.segmentId == b.segmentId and a.forward == b.forward and a.id ~= b.id
end

-- Polyline for an edge route. Junction steps get their connector; lane-change steps leave
-- the lane at the earliest point the dashed line allows and ribbon into the next.
-- `cyclic` routes start and end on the same lane (the goal is behind the start), so the
-- last slice is never stretched to the lane's end.
local function buildWaypoints(self: any, edgeIds: { string }, startIndex: number, goalIndex: number, cyclic: boolean): { Vector3 }
	local out: { Vector3 } = {}
	local landDist: number? = nil
	for pathIndex, edgeId in edgeIds do
		local edge = self._edges[edgeId]
		if not edge then
			continue
		end
		local points = edge.points
		local cum = edge._cum
		local total = cum[#cum] or edge.length
		local prevEdge = if pathIndex > 1 then self._edges[edgeIds[pathIndex - 1]] else nil
		local nextEdge = if pathIndex < #edgeIds then self._edges[edgeIds[pathIndex + 1]] else nil
		local changesLane = nextEdge ~= nil and isLaneChangeStep(edge, nextEdge)

		local startDist: number
		if pathIndex == 1 then
			startDist = distanceAtIndex(points, startIndex)
		elseif landDist then
			startDist = landDist
		elseif prevEdge then
			local _, toSetback = connectionEdgeSetbacks(self, prevEdge, edge)
			startDist = toSetback
		else
			startDist = edgeTurnSetback(edge)
		end
		landDist = nil

		local endDist: number
		if not nextEdge then
			endDist = distanceAtIndex(points, goalIndex)
		elseif changesLane then
			local earliest, latest = self:GetLaneChangeWindow(edge.id, nextEdge.id)
			endDist = math.clamp(startDist, earliest or startDist, latest or startDist)
		else
			local fromSetback, _ = connectionEdgeSetbacks(self, edge, nextEdge)
			endDist = total - fromSetback
		end
		if endDist < startDist then
			endDist = if not nextEdge and not cyclic then total else startDist
		end

		appendEdgeSlice(out, edge, startDist, endDist)

		if nextEdge and changesLane then
			local toTotal = nextEdge._cum[#nextEdge._cum] or nextEdge.length
			local ribbonEnd = math.min(endDist + LANE_CHANGE_MIN_LENGTH, toTotal)
			for _, point in laneChangeRibbonPoints(edge, nextEdge, endDist, ribbonEnd) do
				appendPoint(out, point)
			end
			landDist = ribbonEnd
		elseif nextEdge then
			local key = connectionKey(edge.id, nextEdge.id)
			for _, point in buildConnectionPoints(self, edge, nextEdge, self._customConnectionHandles[key]) do
				appendPoint(out, point)
			end
		end
	end
	return out
end

function RoadNavigationGraph._buildWaypoints(self: any, edgeIds: { string }, startIndex: number, goalIndex: number): { Vector3 }
	return buildWaypoints(self, edgeIds, startIndex, goalIndex, false)
end

function RoadNavigationGraph._buildCyclicWaypoints(self: any, edgeIds: { string }, startIndex: number, goalIndex: number): { Vector3 }
	return buildWaypoints(self, edgeIds, startIndex, goalIndex, true)
end

RoadNavigationGraph.IsLaneChangeStep = isLaneChangeStep

function RoadNavigationGraph.GetLaneDotsForIntersection(self: any, nodeId: number, setbacks: { [number]: number }?): { any }
	local out: { any } = {}
	local function appendDots(edges: { LaneEdge }?, kind: string)
		if not edges then
			return
		end
		for _, edge in edges do
			local cum = edge._cum
			local total = cum[#cum] or edge.length
			local back = resolveDotSetback(edge, setbacks and setbacks[edge.segmentId])
			local dist = if kind == "in" then math.max(0, total - back) else back
			table.insert(out, {
				edgeId = edge.id,
				kind = kind,
				segmentId = edge.segmentId,
				laneIndex = edge.laneIndex,
				laneOrdinal = edge.laneOrdinal,
				laneCountInDirection = edge.laneCountInDirection,
				position = pointAtDistance(edge.points, cum, dist),
			})
		end
	end
	appendDots(self._edgesByToNode[nodeId], "in")
	appendDots(self._edgesByFromNode[nodeId], "out")
	return out
end

function RoadNavigationGraph.GetIntersectionConnectionData(self: any, nodeId: number): { any }
	local out: { any } = {}
	local incoming = self._edgesByToNode[nodeId]
	local outgoing = self._edgesByFromNode[nodeId]
	if not incoming or not outgoing then
		return out
	end
	for _, inEdge in incoming do
		for _, outEdge in outgoing do
			local movement = classifyTurn(inEdge.toDir, outEdge.fromDir)
			local key = connectionKey(inEdge.id, outEdge.id)
			local customHandles = self._customConnectionHandles[key]
			table.insert(out, {
				key = key,
				nodeId = nodeId,
				fromEdgeId = inEdge.id,
				toEdgeId = outEdge.id,
				fromSegmentId = inEdge.segmentId,
				toSegmentId = outEdge.segmentId,
				fromLaneIndex = inEdge.laneIndex,
				toLaneIndex = outEdge.laneIndex,
				movement = movement,
				allowed = edgeHasOutgoing(inEdge, outEdge.id),
				custom = customHandles ~= nil,
				handles = customHandles or {},

			})
		end
	end
	return out
end

function RoadNavigationGraph.GetIntersectionLaneData(self: any, nodeId: number, dotSetbacks: { [number]: number }?): any
	return {
		nodeId = nodeId,
		dots = self:GetLaneDotsForIntersection(nodeId, dotSetbacks),
		connections = self:GetIntersectionConnectionData(nodeId),
	}
end

-- Cost of an existing route under the current congestion snapshot. The optional
-- index lets a directed driver compare only the untravelled tail of its route.
function RoadNavigationGraph.EstimatePathCost(self: any, edgeIds: { string }, startIndex: number?, profile: any?): number
	return NavRouter.estimatePathCost(self, edgeIds, startIndex, profile)
end

function RoadNavigationGraph.NearestEdgeToward(self: any, pos: Vector3, goalPos: Vector3, allows: ((LaneEdge) -> boolean)?): NearestResult?
	return NavRouter.nearestEdgeToward(self, pos, goalPos, allows)
end

-- `vehicleClass` (VehicleTypes.VehicleClass, default Car) decides which lanes the route may
-- use: ordinary traffic is routed around bus lanes, a bus/emergency vehicle straight down them.
-- `profile` (DriverProfile, optional) is the asking driver's own mind -- see NavRouter.
-- Passing none returns the objective shortest/fastest route, which is what buses,
-- trains and emergency vehicles want.
function RoadNavigationGraph.FindPath(self: any, startPos: Vector3, goalPos: Vector3, allowCrossing: boolean?, vehicleClass: string?, profile: any?): ({ Vector3 }?, { string }?)
	return NavRouter.findPath(self, startPos, goalPos, allowCrossing, vehicleClass, profile)
end

return RoadNavigationGraph
