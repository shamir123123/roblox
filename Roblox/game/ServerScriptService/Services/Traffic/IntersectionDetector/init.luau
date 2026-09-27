--!strict
-- IntersectionDetector
-- Scans the road network + nav graph and produces a geometric plan for every
-- signal-controlled intersection: one Arm per road approach with its direction
-- vector (pointing INTO the node), the incoming lane edges, and a pole anchor
-- derived from the road's own bezier -- never from fixed world offsets. Pure
-- library: no state, no lifecycle; callers pass the live RoadService in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadRules       = require(ReplicatedStorage.Road.RoadRules)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local BezierUtil      = require(ReplicatedStorage.Road.BezierUtil)
local TrafficConfig   = require(script.Parent.TrafficConfig)

local IntersectionDetector = {}

export type Arm = {
	segmentId: number,
	dir: Vector3,        -- unit, flat, pointing INTO the node
	right: Vector3,      -- unit, flat, the approaching driver's right-hand side
	halfWidth: number,   -- half the road surface width of this arm
	boundary: number,    -- junction-mouth distance from the node centre along this arm
	polePos: Vector3,    -- world pole-base position on the approach's own kerb (driving side)
	armDir: Vector3,     -- unit, flat, the way the mast arm reaches out over the road
	axis: string,        -- "NS" | "EW" by dominant world axis of dir
	inEdges: { string }, -- every incoming lane-edge id on this arm
	-- Lane-aware split of inEdges by what the lane is allowed to do (turn
	-- permissions baked into edge.out / edge.outMovement at graph build):
	throughEdges: { string },       -- lanes with any straight/right movement (lefts permissive)
	dedicatedLeftEdges: { string }, -- lanes whose every exit is a left/U-turn
}

export type IntersectionPlan = {
	nodeId: number,
	pos: Vector3,
	arms: { Arm },
}

local BEZIER_WALK_STEPS = 64

local function flatUnit(v: Vector3): Vector3?
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-6 then return nil end
	return flat.Unit
end

-- Walks the segment bezier from the node's end inward and returns the world
-- point at the given arc distance (correct Y on graded roads included), plus
-- the LOCAL flat approach direction (into the node) at that point. On curved
-- approaches the tangent at the pole point differs from the tangent at the
-- node -- offsetting with the node tangent planted poles on the asphalt.
local function pointAtArcDistFromNode(seg: any, nodeIsStart: boolean, dist: number): (Vector3, Vector3?)
	local function at(t: number): Vector3
		return BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
	end
	local prevT = if nodeIsStart then 0 else 1
	local prev = at(prevT)
	local acc = 0
	local lastDir: Vector3? = nil
	for i = 1, BEZIER_WALK_STEPS do
		local t = if nodeIsStart then i / BEZIER_WALK_STEPS else 1 - i / BEZIER_WALK_STEPS
		local p = at(t)
		local stepLen = (p - prev).Magnitude
		if stepLen > 1e-9 then
			-- walk moves AWAY from the node; approach dir points back into it
			lastDir = flatUnit(prev - p)
			if acc + stepLen >= dist then
				return prev:Lerp(p, (dist - acc) / stepLen), lastDir
			end
		end
		acc += stepLen
		prev = p
	end
	return prev, lastDir -- arm shorter than dist: clamp to its far end
end

-- Same walk along a lane-edge polyline (edges end at the node centre). Fallback
-- for arc segments whose bezier control points do not describe the lane path.
local function pointAtPolylineDistFromEnd(points: { Vector3 }, dist: number): Vector3?
	if #points < 2 then return nil end
	local acc = 0
	for i = #points - 1, 1, -1 do
		local a, b = points[i + 1], points[i]
		local stepLen = (b - a).Magnitude
		if stepLen > 1e-9 and acc + stepLen >= dist then
			return a:Lerp(b, (dist - acc) / stepLen)
		end
		acc += stepLen
	end
	return points[1]
end

local function buildArm(roadService: any, network: any, graph: any, nodeId: number, nodePos: Vector3, segId: number, inEdges: { any }): Arm?
	local seg = network:getSegment(segId)
	if not seg then return nil end

	-- Approach direction INTO the node. Prefer the segment bezier tangent at the
	-- node's end; average the incoming lane directions when that degenerates.
	local nodeIsStart = seg.startNode == nodeId
	local raw: Vector3
	if not seg.isArc then
		local tangent = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, if nodeIsStart then 0 else 1)
		raw = if nodeIsStart then -tangent else tangent
	else
		raw = Vector3.zero
	end
	if raw.Magnitude < 1e-6 then
		for _, edge in ipairs(inEdges) do
			local d = flatUnit(edge.toDir)
			if d then raw += d end
		end
	end
	local dir = flatUnit(raw)
	if not dir then return nil end
	local right = Vector3.new(-dir.Z, 0, dir.X)

	local halfWidth = RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5
	local boundary = 0
	if roadService.armJunctionBoundary then
		boundary = roadService.armJunctionBoundary(nodeId, segId) or 0
	end

	-- Pole base: follow the road from the junction mouth a short setback, then
	-- step off the road edge onto the curb on the approaching traffic's right.
	local poleDist = boundary + TrafficConfig.POLE_JUNCTION_SETBACK
	local centre: Vector3
	local localRight = right
	if not seg.isArc then
		local localDir: Vector3?
		centre, localDir = pointAtArcDistFromNode(seg, nodeIsStart, poleDist)
		if localDir then
			localRight = Vector3.new(-localDir.Z, 0, localDir.X)
		end
	else
		local sample = pointAtPolylineDistFromEnd(inEdges[1] and inEdges[1].points or {}, poleDist)
		local approx = nodePos - dir * poleDist
		centre = Vector3.new(approx.X, if sample then sample.Y else nodePos.Y, approx.Z)
	end
	-- Pole stands on the approaching driver's OWN kerb and the mast arm reaches out
	-- across the carriageway from there. Which kerb that is flips with the driving
	-- side, so read the sign per call and never cache it (see RoadRules header).
	local kerb = localRight * RoadRules.getLaneSideSign()
	local polePos = centre + kerb * (halfWidth + TrafficConfig.POLE_CURB_MARGIN)

	local edgeIds: { string } = {}
	local throughEdges: { string } = {}
	local dedicatedLeftEdges: { string } = {}
	for _, edge in ipairs(inEdges) do
		table.insert(edgeIds, edge.id)
		local hasAny, allLeft = false, true
		for _, outId in ipairs(edge.out) do
			local movement = if edge.outMovement then edge.outMovement[outId] else nil
			hasAny = true
			if movement ~= "left" and movement ~= "uturn" then
				allLeft = false
			end
		end
		if hasAny and allLeft then
			table.insert(dedicatedLeftEdges, edge.id)
		else
			table.insert(throughEdges, edge.id) -- shared or straight/right lane (or dead end)
		end
	end

	return {
		segmentId = segId,
		dir       = dir,
		right     = right,
		halfWidth = halfWidth,
		boundary  = boundary,
		polePos   = polePos,
		armDir    = -kerb,
		axis      = if math.abs(dir.X) >= math.abs(dir.Z) then "EW" else "NS",
		inEdges   = edgeIds,
		throughEdges = throughEdges,
		dedicatedLeftEdges = dedicatedLeftEdges,
	}
end

-- Returns a plan for every node the road rules mark as signal-controlled.
function IntersectionDetector.detect(roadService: any): { [number]: IntersectionPlan }
	local plans: { [number]: IntersectionPlan } = {}
	local graph = roadService.getNavigationGraph()
	local network = roadService.getNetwork()
	if not graph or not network or not graph:HasEdges() then
		return plans
	end

	for nodeId, node in pairs(network:getNodes() :: any) do
		if network:getNodeKind(nodeId) ~= "intersection" then continue end
		if RoadRules.nodeControl(network, nodeId) ~= "signal" then continue end

		-- Group the node's incoming lane edges by road segment: one arm per road.
		local bySegment: { [number]: { any } } = {}
		for _, edge in pairs((graph._edgesByToNode[nodeId] or {}) :: any) do
			local bucket = bySegment[edge.segmentId]
			if not bucket then
				bucket = {}
				bySegment[edge.segmentId] = bucket
			end
			table.insert(bucket, edge)
		end

		local arms: { Arm } = {}
		for segId, inEdges in pairs(bySegment) do
			local arm = buildArm(roadService, network, graph, nodeId, node.position, segId, inEdges)
			if arm then table.insert(arms, arm) end
		end
		if #arms < 2 then continue end -- nothing to alternate between

		-- Stable angular order so arm indices (and pole keys) survive rebuilds.
		table.sort(arms, function(a, b)
			local aa = math.atan2(a.dir.Z, a.dir.X)
			local bb = math.atan2(b.dir.Z, b.dir.X)
			return aa < bb or (aa == bb and a.segmentId < b.segmentId)
		end)

		plans[nodeId] = {
			nodeId = nodeId,
			pos    = node.position,
			arms   = arms,
		}
	end

	return plans
end

return IntersectionDetector
