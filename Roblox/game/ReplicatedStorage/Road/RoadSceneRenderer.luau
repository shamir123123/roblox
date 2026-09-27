--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local BezierUtil = require(ReplicatedStorage.Road.BezierUtil)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local BridgeBuilder = require(script.Parent.BridgeBuilder)
local RoadRenderer = require(ReplicatedStorage.Road.RoadRenderer)
local RoadMeshBuilder = require(ReplicatedStorage.Road.RoadMeshBuilder)
local IntersectionRenderer = require(ReplicatedStorage.Road.IntersectionRenderer)
local DeadEndRenderer = require(ReplicatedStorage.Road.DeadEndRenderer)
local RoadRules = require(ReplicatedStorage.Road.RoadRules)
local RoadCrossSection = require(ReplicatedStorage.Terrain.RoadCrossSection)
-- Terrain access is server-only infra; on the client, init() must inject equivalents
-- via deps (getSurfaceY from the local heightmap; grade calls are server-side no-ops).
local _getSurfaceY: (number, number) -> number
local _gradeConnector: (any, Vector3, Vector3, Vector3, Vector3, number, boolean?, number?, string?) -> () = function() end
local _ungradeConnector: (any) -> () = function() end
-- Natural (pre-road) ground, for the retaining walls. Server only: a client-side render (no
-- terrain ledger) simply builds no walls.
local _getNaturalY: ((number, number) -> number)? = nil
if RunService:IsServer() then
	local ServerScriptService = game:GetService("ServerScriptService")
	local TerrainGradeService = require(ServerScriptService.Services.Terrain.TerrainGradeService)
	local TerrainDataService = require(ServerScriptService.Services.Terrain.TerrainDataService)
	_getSurfaceY = TerrainDataService.getSurfaceY
	_getNaturalY = TerrainDataService.getNaturalSurfaceY
	_gradeConnector = TerrainGradeService.gradeConnector
	_ungradeConnector = TerrainGradeService.ungradeConnector
else
	_getSurfaceY = function()
		error("[RoadSceneRenderer] client init() must inject deps.getSurfaceY")
	end
end
local Types = require(ReplicatedStorage.Road.RoadTypes)

local RoadSceneRenderer = {}

local _network: any = nil
local _navGraph: any = nil
local _roadsFolder: Folder = nil :: any
local _models: { [Types.SegmentId]: Model } = {}
local _caps: { [Types.NodeId]: Model } = {}
local _intersections: { [Types.NodeId]: Model } = {}
local _islands: { [number]: Model } = {}

local MAP_HALF = RoadConstants.MAP_HALF_EXTENT
-- A dead-end node within this many studs of a boundary is an outside connection (matches
-- OutsideConnectionService's edge tolerance); its turnaround cap is skipped so the road
-- runs off the map instead of capping out over the void.
local MAP_EDGE_TOL = 24

local function isMapEdgeNode(node: any): boolean
	local p = node.position
	return math.abs(p.X) >= MAP_HALF - MAP_EDGE_TOL or math.abs(p.Z) >= MAP_HALF - MAP_EDGE_TOL
end

local nodeMarkingSetback: (Types.NodeId) -> number
local armMarkingSetback: (Types.NodeId, Types.SegmentId) -> number
local nodeHasRoundabout: (Types.NodeId) -> boolean
local rerenderIntersectionApproaches: (Types.NodeId) -> ()
local segFrameFromNode: (Types.Segment, Types.NodeId, number) -> (Vector3, Vector3)

local function nodeJunctionRadius(nodeId: Types.NodeId): number
	local node = _network:getNodes()[nodeId]
	local maxHalf = 0
	if node then
		for _, sid in node.segments do
			local s = _network:getSegment(sid)
			if s then
				maxHalf = math.max(maxHalf, RoadTypeCatalog.getOrDefault(s.roadType).width * 0.5)
			end
		end
	end
	return maxHalf + RoadConstants.JUNCTION_MARGIN
end

function nodeMarkingSetback(nodeId: Types.NodeId): number
	return nodeJunctionRadius(nodeId)
		+ RoadConstants.STOP_LINE_DEPTH
		+ RoadConstants.CROSSWALK_GAP_FROM_STOP
		+ RoadConstants.CROSSWALK_DEPTH
		+ RoadConstants.MARKING_GAP
end

local function armsAndSegsForNode(nodeId: Types.NodeId): ({ IntersectionRenderer.Arm }, { Types.SegmentId })
	local node = _network:getNodes()[nodeId]
	local arms: { IntersectionRenderer.Arm } = {}
	local segIds: { Types.SegmentId } = {}
	if not node then
		return arms, segIds
	end
	-- A roundabout's junctions are always flat plates at the ring's own height (the node-tool
	-- "flat" junction): the ring is level, and its painted circles (buildRoundaboutCentre) run
	-- straight across these plates -- a plate following a sloping arm buried them uphill and
	-- left them floating downhill.
	local ringNode = false
	for _, sid in node.segments do
		local s = _network:getSegment(sid)
		if s and s.isRoundabout then ringNode = true break end
	end
	for _, sid in node.segments do
		local s = _network:getSegment(sid)

		if s and s.isArc then
			continue
		end
		if s then
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
				local corner, offset, flat = IntersectionRenderer.armOverrides(s, nodeId)
				flat = flat or (ringNode or nil)
				local armSpec = RoadTypeCatalog.getOrDefault(s.roadType)
				-- Arm sides are seen looking OUT of the node, so they match the segment's own
				-- left/right at its start node and swap at its end node.
				local swMode = armSpec.sidewalkMode or (if armSpec.noSidewalk then "none" else "both")
				local segR = swMode == "both" or swMode == "right"
				local segL = swMode == "both" or swMode == "left"
				local atStart = s.startNode == nodeId
				table.insert(arms, { dir = raw.Unit, width = armSpec.width, ring = s.isRoundabout, corner = corner, offset = offset, flat = flat,
					swRight = if atStart then segR else segL,
					swLeft  = if atStart then segL else segR })
				table.insert(segIds, sid)
			end
		end
	end

	if #arms == 2 then
		local w = math.min(arms[1].width, arms[2].width)
		arms[1].width = w
		arms[2].width = w
	end
	return arms, segIds
end

local function armsForNode(nodeId: Types.NodeId): { IntersectionRenderer.Arm }
	local arms = armsAndSegsForNode(nodeId)
	return arms
end

local function nodeArmBoundary(nodeId: Types.NodeId, segId: Types.SegmentId): number
	local node = _network:getNodes()[nodeId]
	if not node then
		return 0
	end
	local arms, segIds = armsAndSegsForNode(nodeId)
	local dists = IntersectionRenderer.armBoundaryDistances(node.position, arms)
	for i, sid in segIds do
		if sid == segId then
			return dists[i]
		end
	end
	return nodeJunctionRadius(nodeId)
end

-- Junction trim distance for an arm at an intersection. Starts from the corner-fillet
-- boundary; arms that arrive well above (or below) the node plane get pushed further
-- out so the junction apron -- the warped throat between the mouth and the crossing
-- road -- stays at a drivable grade instead of folding into a cliff. Arms that continue
-- straight through keep the fillet distance: their surface crosses the junction intact
-- (same -0.866 pairing rule as IntersectionRenderer's through-corridor priority).
local APRON_MAX_GRADE = 0.16
local APRON_MAX_EXTENSION = 36
-- Arms no steeper than any placeable road keep the compact fillet mouth (see below).
local APRON_KEEP_GRADE = RoadConstants.MAX_ROAD_GRADE * 1.2

-- Two arms forking at a shallow angle (cosT >= MERGE_FORK_COS_MIN) leave a long thin gore
-- between them. At the natural junction reach their mouths sit closer than their combined
-- half-widths, so IntersectionRenderer can't fit a corner curb in the gore -- it drops the
-- curb and the arms' own inner sidewalks overshoot into it and pile up (the scar). Push BOTH
-- mouths back to where the gore has opened past the combined half-widths (plus a curb nose),
-- so the normal rounded corner curb fits and curves cleanly around the nose. Every per-arm
-- element keys off this reach, so surface/crosswalk/stop-line/sidewalk all push back together.
-- Returns 0 for a normal junction, leaving its reach untouched.
local MERGE_FORK_COS_MIN = RoadConstants.FORK_COS_MIN
local FORK_NOSE_MARGIN = RoadConstants.FORK_NOSE_MARGIN
local function forkRequiredReach(nodeId: Types.NodeId, segId: Types.SegmentId): number
	local node = _network:getNodes()[nodeId]
	if not node then
		return 0
	end
	local arms, segIds = armsAndSegsForNode(nodeId)
	if #arms < 3 then
		return 0
	end
	local me: IntersectionRenderer.Arm? = nil
	for i, sid in segIds do
		if sid == segId then
			me = arms[i]
			break
		end
	end
	if not me then
		return 0
	end
	local myFlat = Vector3.new(me.dir.X, 0, me.dir.Z)
	if me.ring or myFlat.Magnitude < 1e-6 then
		return 0
	end
	myFlat = myFlat.Unit
	local myHw = me.width * 0.5
	local req = 0
	for j, sid in segIds do
		if sid ~= segId then
			local other = arms[j]
			local oFlat = Vector3.new(other.dir.X, 0, other.dir.Z)
			if not other.ring and oFlat.Magnitude > 1e-6 then
				oFlat = oFlat.Unit
				local cosT = math.clamp(myFlat:Dot(oFlat), -1, 1)
				if cosT >= MERGE_FORK_COS_MIN then
					local sinHalf = math.sqrt(math.max(1e-6, (1 - cosT) * 0.5))
					req = math.max(req, (myHw + other.width * 0.5 + FORK_NOSE_MARGIN) / (2 * sinHalf))
				end
			end
		end
	end
	if req > 0 then
		-- Don't extend so far the segment's own surface is fully trimmed away (empty stub).
		-- A too-short fork arm falls back to the merge behaviour + crosswalk yield instead.
		local seg = _network:getSegment(segId)
		if seg then
			local segLen = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, RoadConstants.SAMPLES_PER_SEGMENT)
			req = math.min(req, math.max(0, (segLen - 4) * 0.5))
		end
	end
	return req
end

local function computeArmJunctionBoundary(nodeId: Types.NodeId, segId: Types.SegmentId): number
	local base = nodeArmBoundary(nodeId, segId)
	local node = _network:getNodes()[nodeId]
	local seg = _network:getSegment(segId)
	if not node or not seg then
		return base
	end
	local arms, segIds = armsAndSegsForNode(nodeId)
	if #arms < 3 then
		return base
	end
	local myFlat: Vector3? = nil
	for i, sid in segIds do
		if sid == segId then
			local f = Vector3.new(arms[i].dir.X, 0, arms[i].dir.Z)
			myFlat = if f.Magnitude > 1e-6 then f.Unit else nil
			break
		end
	end
	if not myFlat then
		return base
	end
	for i, sid in segIds do
		if sid ~= segId then
			local f = Vector3.new(arms[i].dir.X, 0, arms[i].dir.Z)
			if f.Magnitude > 1e-6 and myFlat:Dot(f.Unit) < -0.866 then
				return base
			end
		end
	end

	-- Arms no steeper than any placeable road keep the fillet mouth: the mouth
	-- anchors to the arm's real surface and the junction interior follows its
	-- height profile, so a legal grade renders as a clean short throat with the
	-- crosswalk right at the junction. The apron walk below only remains for
	-- legacy arms placed before MAX_ROAD_GRADE existed, which are steep enough
	-- to fold the throat into a cliff.
	do
		local armAtEnd = seg.endNode == nodeId
		local prevPt = if armAtEnd then seg.p3 else seg.p0
		local acc, steepest = 0, 0
		local limit = base * 1.5
		for i = 1, 24 do
			local t = if armAtEnd then 1 - i / 48 else i / 48
			local pt = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
			local run = Vector3.new(pt.X - prevPt.X, 0, pt.Z - prevPt.Z).Magnitude
			if run > 1e-4 then
				steepest = math.max(steepest, math.abs(pt.Y - prevPt.Y) / run)
			end
			acc += (pt - prevPt).Magnitude
			prevPt = pt
			if acc >= limit then break end
		end
		if steepest <= APRON_KEEP_GRADE then
			return base
		end
	end

	-- Walk outward from the node; take the first mouth distance whose drop to the node
	-- plane fits over the throat length. The allowed apron grade is APRON_MAX_GRADE, or
	-- the road's own local grade if the road itself is steeper -- the apron may match
	-- the approach, it just must not be a cliff steeper than it. Flat arms exit at `base`.
	local landing = nodeJunctionRadius(nodeId) - RoadConstants.JUNCTION_MARGIN + 4
	local approxLen = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 16)
	local maxReach = math.max(base, math.min(base + APRON_MAX_EXTENSION, approxLen * 0.6))
	local nodeAtEnd = seg.endNode == nodeId
	local samples = 48
	local prev = if nodeAtEnd then seg.p3 else seg.p0
	local acc = 0
	local reach = base
	local checkedBase = false
	for i = 1, samples do
		local t = if nodeAtEnd then 1 - i / samples else i / samples
		local pt = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local span = (pt - prev).Magnitude
		local localGrade = if span > 1e-6 then math.abs(pt.Y - prev.Y) / span else 0
		local okGrade = math.max(APRON_MAX_GRADE, localGrade * 1.15)
		local prevAcc = acc
		acc += span
		if not checkedBase and acc >= base then
			checkedBase = true
			local f = (base - prevAcc) / math.max(span, 1e-6)
			local y = prev.Y + (pt.Y - prev.Y) * f
			if math.abs(y - node.position.Y) <= math.max(base - landing, 0.5) * okGrade + 0.05 then
				return base
			end
		elseif checkedBase then
			reach = math.min(acc, maxReach)
			local drop = math.abs(pt.Y - node.position.Y)
			if drop <= math.max(reach - landing, 0.5) * okGrade + 0.05 then
				break
			end
			if reach >= maxReach then
				break
			end
		end
		prev = pt
	end
	return reach
end

-- A shallow fork pushes both arm mouths back so the corner curb fits (see forkRequiredReach).
local function armJunctionBoundary(nodeId: Types.NodeId, segId: Types.SegmentId): number
	local reach = math.max(computeArmJunctionBoundary(nodeId, segId), forkRequiredReach(nodeId, segId))
	-- Never reach past the segment's midpoint: when two junctions share a short link their
	-- mouths meet there instead of crossing THROUGH each other (overlapping warped fills
	-- and furniture stranded inside the opposite junction -- the crowded-junction mess).
	-- The clamp trims only the EXTENSIONS (steep-arm apron / fork pushback) and never cuts
	-- below the corner-fillet minimum: IntersectionRenderer trusts an anchored reach as-is,
	-- and a mouth inside the fillet leaves adjacent arm edges crossing past it -- folded
	-- curbs and a cracked fill (the fast-placement short-piece bug).
	local seg = _network:getSegment(segId)
	if seg then
		local segLen = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 16)
		local half = segLen * 0.5
		if reach > half then
			reach = math.max(half, nodeArmBoundary(nodeId, segId))
		end
		-- Hard cap: the mouth must stay strictly INSIDE this segment. At or past the far
		-- end, segFrameFromNode returns the far node's own frame, and the junction then
		-- anchors its mouth inside the NEIGHBOURING junction (curb slicing across the fill).
		reach = math.min(reach, math.max(segLen - 2, 1))
	end
	return reach
end

-- How far out this arm's zebra sits: at the arm's MOUTH -- exactly where its slab starts
-- (surfaceStartOffset = armJunctionBoundary), so the whole CROSSWALK_DEPTH band lands on
-- this arm's own surface. The band itself is always SQUARE across the carriageway
-- (RoadRenderer.crossing); only how far out it sits changes with the junction.
--
-- It was seated at the MEAN of the arm's two corner fillets for a while, to sit against the
-- near corner on a skewed junction. That can only ever move the band INWARD (mean <= max),
-- and inward of the mouth there is no slab -- so the stripes were painted onto the junction
-- fill, which is a separate mesh and won the depth fight along its rim: a zebra sliced
-- through on the diagonal. The error is (max - mean): 0 on a square junction, but 5-19 studs
-- on a skewed one against a band only CROSSWALK_DEPTH (4) deep -- it grows with the WIDEST
-- arm's half-width, so a junction with a highway in it is where it always showed.
local function crosswalkSeat(nodeId: Types.NodeId, segId: Types.SegmentId): number
	return armJunctionBoundary(nodeId, segId)
end

-- Roadway ONE end's approach markings occupy past its junction boundary: the stop line, the
-- zebra, and the gaps around them. ~6.7 studs. armMarkingSetback is the boundary plus this,
-- and the cramped-link test in renderSegment asks for exactly this much per painting end.
local MARKING_BAND_DEPTH = RoadConstants.CROSSWALK_SETBACK
	+ RoadConstants.STOP_LINE_DEPTH
	+ RoadConstants.CROSSWALK_GAP_FROM_STOP
	+ RoadConstants.CROSSWALK_DEPTH
	+ RoadConstants.MARKING_GAP

function armMarkingSetback(nodeId: Types.NodeId, segId: Types.SegmentId): number
	-- A roundabout node paints no zebra and no stop line (the crosswalk/stopLine guards in
	-- renderSegment all check nodeHasRoundabout), so reserving their band there just strips
	-- the ring's lane dashes and the approach's centre line for furniture that never comes.
	-- Keep the plain gap so the dashes stop clear of the junction fill.
	if nodeHasRoundabout(nodeId) then
		return armJunctionBoundary(nodeId, segId) + RoadConstants.MARKING_GAP
	end
	-- No zebra and no stop line on a crosswalk-less road (highways): its lines run right up to
	-- the mouth, where a Y's gore paint picks the dividing line up.
	local seg = _network:getSegment(segId)
	if seg and RoadTypeCatalog.getOrDefault(seg.roadType).noCrosswalk then
		return armJunctionBoundary(nodeId, segId)
	end
	return armJunctionBoundary(nodeId, segId) + MARKING_BAND_DEPTH
end

-- Two arms leaving a junction at a shallow angle form a near-parallel fork. Each draws its
-- own approach crosswalk and stop-line square across its own mouth, and in the thin shared
-- throat those land on top of each other and cross into an X. The wider arm keeps the
-- furniture (tie-break: lower segment id); the narrower one yields it, so a single clean
-- crosswalk spans the shared mouth and the gore stays curb-only -- the same merge-pair rule
-- IntersectionRenderer already applies to the surface gore. Only fires at real intersections;
-- clean wide-angle junctions fail the near-parallel test and are left exactly as they were.
local function armYieldsFurniture(nodeId: Types.NodeId, segId: Types.SegmentId): boolean
	local node = _network:getNodes()[nodeId]
	if not node then
		return false
	end
	local arms, segIds = armsAndSegsForNode(nodeId)
	if #arms < 3 then
		return false
	end
	local myIdx: number? = nil
	for i, sid in segIds do
		if sid == segId then
			myIdx = i
			break
		end
	end
	if not myIdx then
		return false
	end
	local me = arms[myIdx]
	local myFlat = Vector3.new(me.dir.X, 0, me.dir.Z)
	if myFlat.Magnitude < 1e-6 then
		return false
	end
	myFlat = myFlat.Unit
	local myHw = me.width * 0.5
	local myReach = armJunctionBoundary(nodeId, segId)
	for j, sid in segIds do
		if sid ~= segId then
			local other = arms[j]
			local oFlat = Vector3.new(other.dir.X, 0, other.dir.Z)
			if oFlat.Magnitude > 1e-6 then
				oFlat = oFlat.Unit
				local cosT = math.clamp(myFlat:Dot(oFlat), -1, 1)
				if cosT >= MERGE_FORK_COS_MIN then
					-- Separation from the REAL curve mouths, not straight rays off the node
					-- tangents: a curved arm bends the gore, and the ray model kept furniture
					-- that the neighbouring arm's surface actually buries (the half zebra).
					local otherReach = armJunctionBoundary(nodeId, sid)
					local sep: number
					local mySeg = _network:getSegment(segId)
					local otherSeg = _network:getSegment(sid)
					if mySeg and otherSeg then
						local myMouth = segFrameFromNode(mySeg, nodeId, myReach)
						local oMouth = segFrameFromNode(otherSeg, nodeId, otherReach)
						sep = Vector3.new(myMouth.X - oMouth.X, 0, myMouth.Z - oMouth.Z).Magnitude
					else
						local sinHalf = math.sqrt(math.max(0, (1 - cosT) * 0.5))
						sep = (myReach + otherReach) * sinHalf
					end
					local oHw = other.width * 0.5
					if sep < (myHw + oHw) then
						if other.width > me.width + 1e-3 then
							return true
						end
						if math.abs(other.width - me.width) <= 1e-3 and sid < segId then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

-- An arm of an OVERLAPPED shallow fork (the merge case: mouths still closer than the
-- combined half-widths after the pushback was clamped by a short segment) keeps its
-- kerb/edge line on the GORE side only from where the two carriageways have actually
-- separated. Between the mouth and that point the gore-side kerb lies ON the neighbouring
-- arm's pavement and slices across its surface and zebra (the diagonal kerb scar at
-- shallow crossings). Returns per-side minimum kerb start distances from this node's end
-- in the ARM frame (right = armDir x UP); nil = no constraint.
local function goreSidewalkStarts(nodeId: Types.NodeId, segId: Types.SegmentId): (number?, number?)
	local node = _network:getNodes()[nodeId]
	if not node then
		return nil, nil
	end
	local arms, segIds = armsAndSegsForNode(nodeId)
	if #arms < 3 then
		return nil, nil
	end
	local myIdx: number? = nil
	for i, sid in segIds do
		if sid == segId then
			myIdx = i
			break
		end
	end
	if not myIdx then
		return nil, nil
	end
	local me = arms[myIdx]
	local myFlat = Vector3.new(me.dir.X, 0, me.dir.Z)
	if me.ring or myFlat.Magnitude < 1e-6 then
		return nil, nil
	end
	myFlat = myFlat.Unit
	local myHw = me.width * 0.5
	local myReach = armJunctionBoundary(nodeId, segId)
	local mySeg = _network:getSegment(segId)
	local rightStart: number? = nil
	local leftStart: number? = nil
	for j, sid in segIds do
		if sid ~= segId then
			local other = arms[j]
			local oFlat = Vector3.new(other.dir.X, 0, other.dir.Z)
			if not other.ring and oFlat.Magnitude > 1e-6 then
				oFlat = oFlat.Unit
				local cosT = math.clamp(myFlat:Dot(oFlat), -1, 1)
				if cosT >= MERGE_FORK_COS_MIN then
					local oHw = other.width * 0.5
					local otherReach = armJunctionBoundary(nodeId, sid)
					local otherSeg = _network:getSegment(sid)
					local sep: number
					if mySeg and otherSeg then
						local myMouth = segFrameFromNode(mySeg, nodeId, myReach)
						local oMouth = segFrameFromNode(otherSeg, nodeId, otherReach)
						sep = Vector3.new(myMouth.X - oMouth.X, 0, myMouth.Z - oMouth.Z).Magnitude
					else
						local sinHalfEst = math.sqrt(math.max(0, (1 - cosT) * 0.5))
						sep = (myReach + otherReach) * sinHalfEst
					end
					if sep < (myHw + oHw) then
						local sinHalf = math.sqrt(math.max(1e-6, (1 - cosT) * 0.5))
						-- Where this arm's gore-side kerb is fully off the neighbour's pavement.
						local clear = (myHw + oHw + RoadConstants.SIDEWALK_WIDTH + 1) / (2 * sinHalf)
						local rightDir = Vector3.new(-myFlat.Z, 0, myFlat.X)
						if rightDir:Dot(oFlat) > 0 then
							rightStart = math.max(rightStart or 0, clear)
						else
							leftStart = math.max(leftStart or 0, clear)
						end
					end
				end
			end
		end
	end
	return rightStart, leftStart
end

-- A roundabout ENTRY node: a ring arc meets an approach road here. It is yield-controlled
-- (RoadRules), never a signalised crosswalk junction, so it skips the zebra/stop-line paint
-- and the curb across the circulating ring. Pure ring nodes (2 arcs, no approach) are not
-- "intersection" style anyway, so this only ever fires at real entries.
function nodeHasRoundabout(nodeId: Types.NodeId): boolean
	local node = _network:getNodes()[nodeId]
	if not node then
		return false
	end
	for _, sid in node.segments do
		local s = _network:getSegment(sid)
		if s and s.isRoundabout then
			return true
		end
	end
	return false
end

-- True when `segId`'s arm at this node has a nearly opposite arm: the segment is one
-- half of a road running straight THROUGH the junction (a fork/merge host carriageway).
local function throughAt(nodeId: Types.NodeId, segId: Types.SegmentId): boolean
	local arms, segIds = armsAndSegsForNode(nodeId)
	local myDir: Vector3? = nil
	for k, sid in segIds do
		if sid == segId then
			myDir = arms[k].dir
			break
		end
	end
	if not myDir then return false end
	for k, sid in segIds do
		if sid ~= segId and arms[k].dir:Dot(myDir) < -0.866 then
			return true
		end
	end
	return false
end

-- Every arm at the node is a highway: merge furniture (give-way teeth) only belongs
-- on pure highway forks/merges, never at a signalised junction with a normal road.
local function allArmsHighway(nodeId: Types.NodeId): boolean
	local node = _network:getNodes()[nodeId]
	if not node then return false end
	for _, sid in node.segments do
		local s = _network:getSegment(sid)
		if s and not s.isArc and not RoadTypeCatalog.getOrDefault(s.roadType).isHighway then
			return false
		end
	end
	return true
end

-- A ramp joining ONE side of a highway: two arms of the same highway run straight through
-- and the third leaves at a shallow angle. That is a lane merge/diverge, not a crossing --
-- no traffic on the far side has anywhere to go -- so the highway renders straight through
-- (median, far carriageway and lane lines untouched) and only the ramp is trimmed, back to
-- where it clears the highway's edge. Returns the ramp's and the host arm's segment ids.
local STRAIGHT_THROUGH_DOT = -math.cos(math.rad(RoadConstants.STRAIGHT_JOIN_TOLERANCE_DEG))
local function mergeBranch(arms: { IntersectionRenderer.Arm }, segIds: { Types.SegmentId }, nodeId: Types.NodeId?): (Types.SegmentId?, Types.SegmentId?)
	if #arms ~= 3 then return nil, nil end
	-- A street or steep ramp joining a DIVIDED highway from one side is right-in/right-out
	-- (RoadRules.highwayJunction): the highway, median and all, runs straight past it exactly
	-- as it does past a shallow ramp, instead of a junction box cutting the median open.
	local oneSidedDivided = false
	if nodeId then
		local kind, divided = RoadRules.highwayJunction(_network, nodeId)
		oneSidedDivided = kind == "onesided" and divided
	end
	-- Every pairing is tried: a ramp drawn in tangent to the highway is ALSO straight against
	-- the far highway arm, and that pair must not hide the real one.
	for k = 1, 3 do
		local i, j = k % 3 + 1, (k + 1) % 3 + 1
		if arms[k].ring or arms[i].dir:Dot(arms[j].dir) >= STRAIGHT_THROUGH_DOT then continue end
		local si, sj = _network:getSegment(segIds[i]), _network:getSegment(segIds[j])
		if not si or not sj or si.roadType ~= sj.roadType
			or not RoadTypeCatalog.getOrDefault(si.roadType).isHighway then
			continue
		end
		local di, dj = arms[k].dir:Dot(arms[i].dir), arms[k].dir:Dot(arms[j].dir)
		if math.max(di, dj) >= MERGE_FORK_COS_MIN or oneSidedDivided then
			return segIds[k], if di >= dj then segIds[i] else segIds[j]
		end
	end
	return nil, nil
end

-- Distance along the ramp from the node to where its inner edge clears the highway edge.
-- Keyed on both curves' control points: renderSegment asks several times per build.
local _mergeSepCache: { [Types.NodeId]: { key: { Vector3 }, sep: number } } = {}
local function mergeSep(nodeId: Types.NodeId, branch: Types.Segment, host: Types.Segment): number
	local key = { branch.p0, branch.p1, branch.p2, branch.p3, host.p0, host.p1, host.p2, host.p3 }
	local hit = _mergeSepCache[nodeId]
	if hit then
		local same = true
		for i, v in key do
			if hit.key[i] ~= v then same = false break end
		end
		if same then return hit.sep end
	end
	local reach = (RoadTypeCatalog.getOrDefault(host.roadType).width + RoadTypeCatalog.getOrDefault(branch.roadType).width) * 0.5
	local len = BezierUtil.length(branch.p0, branch.p1, branch.p2, branch.p3, 16)
	local sep = math.max(len - 2, 1)
	for d = 2, sep, 2 do
		local p = segFrameFromNode(branch, nodeId, d)
		local f = BezierUtil.point(host.p0, host.p1, host.p2, host.p3, BezierUtil.closestParam(host.p0, host.p1, host.p2, host.p3, p, 16))
		if Vector3.new(p.X - f.X, 0, p.Z - f.Z).Magnitude >= reach then
			sep = d
			break
		end
	end
	_mergeSepCache[nodeId] = { key = key, sep = sep }
	return sep
end

-- Trim at a merge node: the ramp's clear distance, 0 for the highway running through.
local function mergeTrim(nodeId: Types.NodeId, segId: Types.SegmentId): number
	local arms, segIds = armsAndSegsForNode(nodeId)
	local branchId, hostId = mergeBranch(arms, segIds, nodeId)
	if branchId ~= segId or not hostId then return 0 end
	local branch, host = _network:getSegment(branchId), _network:getSegment(hostId)
	if not branch or not host then return 0 end
	return mergeSep(nodeId, branch, host)
end

local function nodeStyle(nodeId: Types.NodeId): string
	local node = _network:getNodes()[nodeId]
	if not node then
		return "deadend"
	end

	local arms, segIds = armsAndSegsForNode(nodeId)
	local deg = #arms
	if deg >= 3 then
		return if mergeBranch(arms, segIds, nodeId) then "merge" else "intersection"
	end
	if deg <= 1 then

		if #node.segments == 0 then

			return "straight"
		end
		if #node.segments >= 2 then

			return "straight"
		end

		return "deadend"
	end
	local straightDot = -math.cos(math.rad(RoadConstants.STRAIGHT_JOIN_TOLERANCE_DEG))
	if #arms == 2 and arms[1].dir:Dot(arms[2].dir) < straightDot then
		return "straight"
	end
	return "corner"
end

local function endSetback(nodeId: Types.NodeId, style: string, segId: Types.SegmentId): number
	if style == "intersection" then

		return armMarkingSetback(nodeId, segId)
	elseif style == "corner" then

		return nodeArmBoundary(nodeId, segId)
	elseif style == "merge" then
		return mergeTrim(nodeId, segId)
	end
	return 0
end

local function endCurbSetback(nodeId: Types.NodeId, style: string, segId: Types.SegmentId): number
	if style == "intersection" then
		return math.max(0, armJunctionBoundary(nodeId, segId) - RoadConstants.JUNCTION_CURB_JOIN_OVERLAP)
	elseif style == "corner" then
		return math.max(0, nodeArmBoundary(nodeId, segId) - RoadConstants.JUNCTION_CURB_JOIN_OVERLAP)
	elseif style == "merge" then
		return mergeTrim(nodeId, segId)
	end
	return 0
end

local function transitionAtNode(nodeId: Types.NodeId, segId: Types.SegmentId, ownWidth: number): (number?, any)
	local node = _network:getNodes()[nodeId]

	local style = nodeStyle(nodeId)
	if not node or #node.segments ~= 2 or (style ~= "straight" and style ~= "corner") then
		return nil
	end
	for _, otherId in node.segments do
		if otherId ~= segId then
			local other = _network:getSegment(otherId)
			if other then
				local otherWidth = RoadTypeCatalog.getOrDefault(other.roadType).width
				if otherWidth < ownWidth - 1e-3 then
					return otherWidth, RoadTypeCatalog.getOrDefault(other.roadType)
				end
			end
		end
	end
	return nil
end

local function mergeArrowsAtEnd(nodeId: Types.NodeId, seg: Types.Segment, spec: any): { RoadRenderer.MergeSpec }?
	if not spec.oneWay then return nil end
	local node = _network:getNodes()[nodeId]
	if not node or #node.segments ~= 2 then return nil end

	for _, otherId in node.segments do
		if otherId ~= seg.id then
			local other = _network:getSegment(otherId)
			if not other then return nil end
			local otherSpec = RoadTypeCatalog.getOrDefault(other.roadType)
			if not otherSpec.oneWay or otherSpec.laneCount >= spec.laneCount then return nil end

			local width = RoadTypeCatalog.carriagewayWidth(spec)
			local laneW = width / spec.laneCount
			local out: { RoadRenderer.MergeSpec } = {}
			-- One-way ordinals count from the RIGHT lane (nav keeps the right lanes
			-- through a narrowing), so any lane the narrower continuation cannot keep
			-- is on the LEFT and must merge right.
			for i = 1, spec.laneCount - otherSpec.laneCount do
				table.insert(out, {
					offset = -width * 0.5 + (i - 0.5) * laneW,
					left = false,
				})
			end
			return if #out > 0 then out else nil
		end
	end
	return nil
end

local function approachArrowsAt(nodeId: Types.NodeId, seg: Types.Segment): { RoadRenderer.ArrowSpec }?
	local node = _network:getNodes()[nodeId]
	if not node then
		return nil
	end
	if not _navGraph then
		return nil
	end

	local out: { RoadRenderer.ArrowSpec } = {}
	for _, edge in _navGraph:GetIncomingEdgesForSegment(nodeId, seg.id) do
		local mv = _navGraph:GetIncomingEdgeArrowDirs(edge.id)
		if mv.left or mv.straight or mv.right then
			table.insert(out, { offset = edge.offset, left = mv.left, through = mv.straight, right = mv.right })
		end
	end
	return if #out > 0 then out else nil
end

-- Lane arrows for a junction that sits just BEYOND this end's node. A `straight` node is a
-- mid-road split, and the stub between it and the junction can be shorter than a single arrow --
-- RoadRenderer drops them and the approach paints bare. Hand them to the segment behind
-- instead: same movements, one node further back from the stop line. Offsets mirror when the
-- two segments' travel directions oppose at the shared node, since their side vectors flip.
local ARROW_RELAY_MAX_STUB = 90
-- Roadway a segment has left for painted symbols once both ends' junction setbacks are
-- taken out -- the same span RoadRenderer measures its arrows against.
local function approachRoom(seg: Types.Segment): number
	return BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 16)
		- endSetback(seg.startNode, nodeStyle(seg.startNode), seg.id)
		- endSetback(seg.endNode, nodeStyle(seg.endNode), seg.id)
end
-- Room one arrow row actually needs: RoadRenderer sets it back ARROW_GAP + half an arrow + 4
-- from the stop line and then refuses to draw within half an arrow of either segment end.
-- ONE predicate decides the hand-off, so a stub and the segment behind it can never both
-- paint the row, nor both skip it.
local ARROW_MIN_APPROACH = RoadConstants.ARROW_GAP + RoadConstants.ARROW_LENGTH * 2 + 6
-- The segment carrying on past a mid-road `straight` node -- the only place an arm too short
-- for its own arrow row can hand it to. Both sides of the hand-off ask this same question, so
-- an arm never withholds the row for a neighbour that will not take it (a dead-end stub then
-- keeps it and RoadRenderer squeezes it back instead).
local function arrowRelayTarget(seg: Types.Segment, nodeId: Types.NodeId): Types.Segment?
	local node = _network:getNodes()[nodeId]
	if not node or #node.segments ~= 2 or nodeStyle(nodeId) ~= "straight" then
		return nil
	end
	if BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 16) > ARROW_RELAY_MAX_STUB then
		return nil
	end
	local otherId = if node.segments[1] == seg.id then node.segments[2] else node.segments[1]
	if otherId == seg.id then
		return nil
	end
	local other = _network:getSegment(otherId)
	if not other or other.isArc then
		return nil
	end
	return other
end
local function relayedApproachArrows(seg: Types.Segment, nodeId: Types.NodeId): { RoadRenderer.ArrowSpec }?
	local node = _network:getNodes()[nodeId]
	if not node or #node.segments ~= 2 then
		return nil
	end
	local stubId = if node.segments[1] == seg.id then node.segments[2] else node.segments[1]
	if stubId == seg.id then
		return nil
	end
	local stub = _network:getSegment(stubId)
	if not stub or stub.isArc then
		return nil
	end
	local junctionId = if stub.startNode == nodeId then stub.endNode else stub.startNode
	if nodeStyle(junctionId) ~= "intersection" then
		return nil
	end
	if arrowRelayTarget(stub, nodeId) == nil then
		return nil -- stub too long to hand its row this far back
	end
	if approachRoom(stub) >= ARROW_MIN_APPROACH then
		return nil -- the stub paints its own
	end
	local specs = approachArrowsAt(junctionId, stub)
	if not specs then
		return nil
	end
	local function travelTangent(s: Types.Segment, nid: Types.NodeId): Vector3
		return if s.startNode == nid
			then BezierUtil.tangent(s.p0, s.p1, s.p2, s.p3, 0)
			else BezierUtil.tangent(s.p0, s.p1, s.p2, s.p3, 1)
	end
	local tSeg = travelTangent(seg, nodeId)
	local tStub = travelTangent(stub, nodeId)
	if tSeg.Magnitude < 1e-6 or tStub.Magnitude < 1e-6 then
		return nil
	end
	if tSeg.Unit:Dot(tStub.Unit) >= 0 then
		return specs
	end
	local out = table.create(#specs)
	for i, s in specs do
		out[i] = { offset = -s.offset, left = s.left, through = s.through, right = s.right }
	end
	return out
end

local function stopSpanFromArrows(specs: { RoadRenderer.ArrowSpec }?, laneW: number): Vector2?
	if not specs or #specs == 0 then
		return nil
	end
	local lo, hi = math.huge, -math.huge
	for _, s in specs do
		lo = math.min(lo, s.offset - laneW * 0.5)
		hi = math.max(hi, s.offset + laneW * 0.5)
	end
	return Vector2.new(lo, hi)
end

local function laneOffsetsForSpec(spec: any): { number }

	-- Lanes live inside the carriageway (total width minus the parking apron), so the
	-- dashed lane lines and cars stay off the apron. Offsets are about the carriageway
	-- centre; RoadRenderer shifts them by the carriageway centre offset.
	local width = RoadTypeCatalog.carriagewayWidth(spec)
	local laneOffsets: { number } = {}
	if spec.oneWay then

		if spec.laneCount <= 1 then
			return laneOffsets
		end
		local laneW = width / spec.laneCount
		for i = 1, spec.laneCount - 1 do

			local offset = -width * 0.5 + i * laneW
			table.insert(laneOffsets, offset)
		end
	elseif spec.laneCount == 2 then

		return laneOffsets
	elseif spec.laneCount > 2 then

		local mW = if spec.median then (spec.medianWidth or 4) else 0
		local halfMedian = mW * 0.5
		local halfLanes = spec.laneCount / 2
		local halfCarriageway = width * 0.5 - halfMedian
		local laneW = halfCarriageway / halfLanes
		for i = 1, halfLanes - 1 do
			table.insert(laneOffsets, halfMedian + i * laneW)
		end
		for i = 1, halfLanes - 1 do
			table.insert(laneOffsets, -(halfMedian + i * laneW))
		end
	end
	return laneOffsets
end

-- Kerbside lane CENTRE of each travel direction (about the carriageway centre) plus that
-- lane's width: the band a bus-lane road paints red. Mirrors RoadNavigationGraph's lane
-- plans, so the paint lands exactly on the lane RoadRules restricts. Empty when a direction
-- has only one lane -- that lane is never restricted, so nothing is painted.
local function busLaneBandsForSpec(spec: any): ({ number }, number)
	local width = RoadTypeCatalog.carriagewayWidth(spec)
	local laneCount = math.max(1, spec.laneCount or 2)
	if spec.oneWay then
		if laneCount < 2 then return {}, 0 end
		local laneW = width / laneCount
		-- One-way lane ordinals run right-to-left, so the highest ordinal is the -side lane.
		return { -(width * 0.5 - laneW * 0.5) }, laneW
	end
	local perDir = math.floor(laneCount / 2)
	if perDir < 2 then return {}, 0 end
	local medianW = if spec.median then (spec.medianWidth or 4) else 0
	local laneW = (width - medianW) / laneCount
	local outer = width * 0.5 - laneW * 0.5
	return { -outer, outer }, laneW
end

-- == elevated supports =====================================================
--
-- Piers stand on NODES, and never on a road. Both rules are answered from the road
-- GRAPH rather than from raycasts: this runs inside the same render pass that rebuilds
-- the road parts, so a ray here can hit geometry about to be destroyed or miss geometry
-- not yet parented.

-- Exactly one pier per node. Two elevated segments meeting at a node would each want a
-- support there and the two would z-fight into one smeared column, so the node's
-- lowest-numbered real segment owns it and the others leave it alone. Arcs never own one:
-- renderSegment draws no geometry for them.
local function ownsNodePier(nodeId: Types.NodeId, segId: Types.SegmentId): boolean
	local node = _network:getNodes()[nodeId]
	if not node then return true end
	local owner: Types.SegmentId? = nil
	for _, sid in node.segments do
		local s = _network:getSegment(sid)
		if s and not s.isArc and (owner == nil or sid < owner) then owner = sid end
	end
	return owner == nil or owner == segId
end

-- The smallest support height wanted by ANY segment at the node. A Bridge segment (min
-- ELEVATED_PILLAR_MIN_HEIGHT) that owns a node it shares with a low Elevated one still
-- has to plant that node's pier, so the threshold there is the neighbour's, not its own.
local function nodePierMinHeight(nodeId: Types.NodeId, fallback: number): number
	local node = _network:getNodes()[nodeId]
	if not node then return fallback end
	local minH = fallback
	for _, sid in node.segments do
		local s = _network:getSegment(sid)
		if s and not s.isArc then
			minH = math.min(minH, if s.vMode == "Elevated" then 2 else RoadConstants.ELEVATED_PILLAR_MIN_HEIGHT)
		end
	end
	return minH
end

-- Studs a road surface must sit BELOW the deck soffit before it counts as something
-- underneath rather than part of this structure. A neighbouring deck ramping away from a
-- shared node falls at most MAX_ROAD_GRADE over the half-deck-width a pier reaches, so
-- this stays clear of it; a road genuinely passing under is at least
-- ELEVATED_PILLAR_MIN_HEIGHT down.
local PIER_ROAD_CLEARANCE = 4
-- Broad-phase pad only: the widest footing a pier can grow (max colD * 3 / 2).
local PIER_FOOT_MAX = 6

-- Plan-view distance from (x, z) to a segment's centreline, and the centreline height
-- there. XZ only -- a 3-D closest point would let a deck 30 studs overhead drag the
-- answer along its own curve.
local function centrelineNear(s: Types.Segment, x: number, z: number): (number, number)
	local bestSq, bestY = math.huge, 0
	for i = 0, 12 do
		local q = BezierUtil.point(s.p0, s.p1, s.p2, s.p3, i / 12)
		local dx, dz = q.X - x, q.Z - z
		local dSq = dx * dx + dz * dz
		if dSq < bestSq then
			bestSq, bestY = dSq, q.Y
		end
	end
	return math.sqrt(bestSq), bestY
end

-- Builds the "may a pier leg stand here?" test for ONE elevated segment. The network is
-- narrowed once, against a circle around this deck, so the per-leg call walks a handful of
-- candidates instead of every road in the city.
--
-- Segments sharing a node with this one are ignored outright: they are the same continuous
-- structure, physically joined to this deck, never something it comes down on top of. A
-- road that merely CROSSES an elevated deck never shares a node with it -- RoadNetwork
-- only welds crossings within the same vMode and within VERTICAL_CONNECT_TOLERANCE.
local function pierClearanceFor(seg: Types.Segment, pts: { Vector3 }, deckHalf: number)
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in pts do
		minX = math.min(minX, p.X)
		maxX = math.max(maxX, p.X)
		minZ = math.min(minZ, p.Z)
		maxZ = math.max(maxZ, p.Z)
	end
	local centre = Vector3.new((minX + maxX) * 0.5, 0, (minZ + maxZ) * 0.5)
	local reach = Vector2.new(maxX - minX, maxZ - minZ).Magnitude * 0.5 + deckHalf + PIER_FOOT_MAX

	local joined: { [Types.NodeId]: boolean } = { [seg.startNode] = true, [seg.endNode] = true }
	local cands: { { seg: Types.Segment, edge: number } } = {}
	for _, s in _network:getSegments() do
		if s.id == seg.id or joined[s.startNode] or joined[s.endNode] then continue end
		local sSpec = RoadTypeCatalog.getOrDefault(s.roadType)
		local edge = sSpec.width * 0.5 + (if sSpec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
		if BezierUtil.hullNear(s.p0, s.p1, s.p2, s.p3, centre, reach + edge) then
			table.insert(cands, { seg = s, edge = edge })
		end
	end
	-- Junction surfaces are their own models: the paved box around a node reaches past what
	-- its arms' half-widths cover, so nodes are tested separately from the segments.
	local junctions: { { pos: Vector3, r: number } } = {}
	for id, node in _network:getNodes() do
		if joined[id] then continue end
		local r = nodeJunctionRadius(id)
		local dx, dz = node.position.X - centre.X, node.position.Z - centre.Z
		if dx * dx + dz * dz <= (reach + r) * (reach + r) then
			table.insert(junctions, { pos = node.position, r = r })
		end
	end

	return function(pos: Vector3, topY: number, radius: number): boolean
		local ceiling = topY - PIER_ROAD_CLEARANCE
		for _, c in cands do
			local dist, y = centrelineNear(c.seg, pos.X, pos.Z)
			if dist <= c.edge + radius and y < ceiling then return false end
		end
		for _, j in junctions do
			if j.pos.Y >= ceiling then continue end
			local dx, dz = j.pos.X - pos.X, j.pos.Z - pos.Z
			local rr = j.r + radius
			if dx * dx + dz * dz <= rr * rr then return false end
		end
		return true
	end
end

-- An elevated deck gets real bridge structure -- girders under the slab and piers with
-- a cap beam and columns -- instead of the single box pillar this used to drop. The
-- geometry lives in BridgeBuilder so an elevated road and a hand-placed bridge come out
-- as the same object; this function only samples the curve, reports the ground under it,
-- and decides WHERE a support is allowed. Ground comes from the authoritative heightmap,
-- not a raycast: the voxel repaint is frame-budgeted, so a raycast here can measure stale
-- terrain.
local function addElevationPillars(model: Model, seg: Types.Segment, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, vMode: string?, spec: any)
	local length = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
	if length < 1 then return end

	local function groundYBelow(pt: Vector3): number
		local ok, y = pcall(_getSurfaceY, pt.X, pt.Z)
		return if ok then y else RoadConstants.getGroundY()
	end

	local ownStart = ownsNodePier(seg.startNode, seg.id)
	local ownEnd = ownsNodePier(seg.endNode, seg.id)
	local minH = if vMode == "Elevated" then 2 else RoadConstants.ELEVATED_PILLAR_MIN_HEIGHT
	local nodeMinH = minH
	if ownStart then nodeMinH = math.min(nodeMinH, nodePierMinHeight(seg.startNode, minH)) end
	if ownEnd then nodeMinH = math.min(nodeMinH, nodePierMinHeight(seg.endNode, minH)) end

	local steps = math.clamp(math.floor(length / 24), 2, 32)
	local pts: { Vector3 } = {}
	local grounds: { number } = {}
	local elevated = false
	for i = 0, steps do
		local pt = BezierUtil.point(p0, p1, p2, p3, i / steps)
		local gy = groundYBelow(pt)
		local soffitY = pt.Y - RoadConstants.ROAD_THICKNESS * 0.5
		if soffitY - gy >= nodeMinH then elevated = true end
		table.insert(pts, Vector3.new(pt.X, soffitY, pt.Z))
		table.insert(grounds, gy)
	end
	if not elevated then return end

	BridgeBuilder.addElevatedStructure(model, pts, grounds, spec, vMode, {
		pierAtStart = ownStart,
		pierAtEnd = ownEnd,
		minHeight = minH,
		nodeMinHeight = nodeMinH,
		columnClear = pierClearanceFor(seg, pts, BridgeBuilder.deckHalfFor(spec)),
	})
end

-- == Retaining walls (Cities: Skylines 2) ====================================
-- A road raised less than a bridge sits on walled fill; one lowered less than a tunnel runs
-- in a walled cut (a tunnel's approach ramp too). Where the footway top and the NATURAL
-- ground beside the road differ by RoadCrossSection.wallMinHeight or more, a concrete wall
-- stands at the back of the footway and TerrainGradeService leaves the land outside it at its
-- natural height -- both sides decide with RoadCrossSection.wallStep, so a wall never stands
-- without its step or a step without its wall.
--
-- The walls are measured from the natural ground (the terrain ledger's original heights),
-- never from the graded ground: the road has already cut or filled that, which is what made
-- the old tunnel walls come out as sawtooth panels standing out of the ground. Each side is a
-- welded strip (inner face, outer face, top), so the top edge is one smooth line; a run
-- carries one station past each end at its real (small) height, so walls taper out instead
-- of stopping dead. They bake into the road piece's mesh like the kerbs -- no Parts.
local WALL_STEP = 4            -- studs between wall stations (one terrain corner spacing)
local WALL_COLOR = Color3.fromRGB(170, 170, 175) -- kerb concrete: bakes with the pavement look
local WALL_LIP = 0.6           -- a cut wall stands this far proud of the ground it holds back
local WALL_PARAPET = 1.1       -- a fill wall stands this far above the footway: its railing
local WALL_EMBED = 1.5         -- and reaches this far into the ground at its foot
local PORTAL_CLEARANCE = 9     -- studs of headroom under a tunnel portal
local PORTAL_THICKNESS = 2
local PORTAL_MOUTH_COLOR = Color3.fromRGB(22, 22, 26)
local WALL_COPING = 6          -- a cut wall's top covers this much of the ground behind it,
                               -- where the terrain lattice bevels up from the bed to natural

-- Where walls start along a road from `nodeId` (0 at a plain continuation).
local function wallClearAt(nodeId: number, ownWidth: number): number
	local node = _network and _network:getNodes()[nodeId]
	if not node then return RoadCrossSection.wallNodeClear(1, ownWidth) end
	local widest = ownWidth
	for _, sid in node.segments do
		local sg = _network:getSegment(sid)
		if sg then widest = math.max(widest, RoadTypeCatalog.getOrDefault(sg.roadType).width) end
	end
	return RoadCrossSection.wallNodeClear(#node.segments, widest)
end

local function addRetainingWalls(model: Model, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, spec: any, vMode: string?, clearStart: number, clearEnd: number)
	local natural = _getNaturalY
	if not natural then return end
	local walk = if spec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH
	local halfThick = RoadConstants.ROAD_THICKNESS * 0.5
	local thk = RoadCrossSection.wallThickness
	local inner = RoadCrossSection.wallInnerOffset(spec.width, walk)
	local length = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
	if length < WALL_STEP then return end
	local n = math.clamp(math.ceil(length / WALL_STEP), 2, 256)
	local centres: { Vector3 } = table.create(n + 1)
	local sides: { Vector3 } = table.create(n + 1)
	local lastSide = Vector3.xAxis
	for i = 0, n do
		local t = i / n
		local tan = BezierUtil.tangent(p0, p1, p2, p3, t)
		local flat = Vector3.new(tan.X, 0, tan.Z)
		if flat.Magnitude > 1e-4 then
			flat = flat.Unit
			lastSide = Vector3.new(-flat.Z, 0, flat.X)
		end
		centres[i + 1] = BezierUtil.point(p0, p1, p2, p3, t)
		sides[i + 1] = lastSide
	end
	local builder = RoadMeshBuilder.new()
	for _, sgn in { -1, 1 } do
		local step: { number } = table.create(n + 1)
		local nat: { number } = table.create(n + 1)
		local edge: { number } = table.create(n + 1)
		for i = 1, n + 1 do
			local c = centres[i]
			local mid = c + sides[i] * (sgn * (inner + thk * 0.5))
			local ok, y = pcall(natural, mid.X, mid.Z)
			nat[i] = if ok then y else c.Y
			edge[i] = RoadCrossSection.edgeTopY(c.Y + halfThick, walk)
			local along = length * (i - 1) / n
			step[i] = if along >= clearStart and along <= length - clearEnd
				then RoadCrossSection.wallStep(c.Y, halfThick, walk, nat[i], vMode)
				else 0
		end
		local i = 1
		while i <= n + 1 do
			if step[i] == 0 then
				i += 1
				continue
			end
			local a = i
			while i <= n + 1 and step[i] ~= 0 do i += 1 end
			local lo, hi = math.max(1, a - 1), math.min(n + 1, i)
			local isCut = step[a] > 0
			local inB, inT, outB, outT, copeO = {}, {}, {}, {}, {}
			for k = lo, hi do
				local c, side = centres[k], sides[k] * sgn
				local cut = nat[k] >= edge[k]
				local top = if cut then nat[k] + WALL_LIP else edge[k] + WALL_PARAPET
				local bottom = if cut then edge[k] - RoadConstants.SIDEWALK_HEIGHT else nat[k] - WALL_EMBED
				local pi = c + side * inner
				local po = c + side * (inner + thk)
				table.insert(inB, Vector3.new(pi.X, bottom, pi.Z))
				table.insert(inT, Vector3.new(pi.X, top, pi.Z))
				table.insert(outB, Vector3.new(po.X, bottom, po.Z))
				table.insert(outT, Vector3.new(po.X, top, po.Z))
				local pc = c + side * (inner + thk + WALL_COPING)
				table.insert(copeO, Vector3.new(pc.X, top, pc.Z))
			end
			if #inB >= 2 then
				builder:addSurfaceStrip(inB, inT, WALL_COLOR, thk)
				builder:addSurfaceStrip(outB, outT, WALL_COLOR, thk)
				builder:addSurfaceStrip(inT, outT, WALL_COLOR, thk)
				if isCut then builder:addSurfaceStrip(outT, copeO, WALL_COLOR, 0.4) end
				-- End faces, so a wall reads solid where it stops.
				for _, e in { 1, #inB } do
					builder:addSurfaceStrip({ inB[e], inT[e] }, { outB[e], outT[e] }, WALL_COLOR, thk)
				end
			end
		end
	end
	-- Tunnel portal: where the walled cut meets the covered tunnel the cut would end in a bank
	-- of ground. A concrete headwall spans the cut there, over a dark mouth the road runs into.
	if vMode == "Tunnel" then
		local function covered(i: number): boolean
			local c = centres[i]
			local ok, y = pcall(natural, c.X, c.Z)
			return ok and y - (c.Y + halfThick) >= RoadCrossSection.coverDepth
		end
		local prevCovered = covered(1)
		for i = 2, n + 1 do
			local cov = covered(i)
			if cov ~= prevCovered then
				-- The station on the open side of the change, facing into the cut.
				local k = if cov then i - 1 else i
				local c, side = centres[k], sides[k]
				local along = Vector3.new(side.Z, 0, -side.X) * (if cov then 1 else -1)
				local roadTop = c.Y + halfThick
				local ok, y = pcall(natural, c.X, c.Z)
				local groundY = if ok then y else roadTop + RoadCrossSection.coverDepth
				local span = (inner + thk) * 2
				local mouthTop = roadTop + PORTAL_CLEARANCE
				local headH = math.max(1, groundY + WALL_LIP - mouthTop)
				local look = CFrame.lookAt(Vector3.zero, along)
				builder:addBox(look + Vector3.new(c.X, mouthTop + headH * 0.5, c.Z), Vector3.new(span, headH, PORTAL_THICKNESS), WALL_COLOR)
				-- The mouth: a dark panel on the headwall's face, in front of the bank of ground
				-- the cut ends in, so the road reads as running in.
				local m = Vector3.new(c.X, 0, c.Z) - along * (PORTAL_THICKNESS * 0.5 + 0.3)
				builder:addBox(look + Vector3.new(m.X, roadTop + PORTAL_CLEARANCE * 0.5, m.Z),
					Vector3.new(span - thk * 2, PORTAL_CLEARANCE, 0.4), PORTAL_MOUTH_COLOR)
			end
			prevCovered = cov
		end
	end
	local walls = builder:bake({ name = "RetainingWalls", canCollide = false })
	if walls then walls.Parent = model end
end

-- Retaining wall wrapped around a tunnel dead-end bulb: chords along the semicircle
-- past the node, same depth band / probe rules as the straight tunnel walls.
local function addDeadEndTunnelWalls(model: Model, center: Vector3, outDir: Vector3, width: number)
	local flat = Vector3.new(outDir.X, 0, outDir.Z)
	if flat.Magnitude < 1e-4 then return end
	flat = flat.Unit
	local thk = RoadConstants.TUNNEL_WALL_THICKNESS
	local r = width * 0.5 + RoadConstants.SIDEWALK_WIDTH + thk * 0.5
	local probeR = r + thk * 0.5 + 7
	local surfaceY = center.Y + RoadConstants.ROAD_THICKNESS * 0.5
	local right = Vector3.new(-flat.Z, 0, flat.X)
	local function groundYAt(pt: Vector3): number
		local ok, y = pcall(_getSurfaceY, pt.X, pt.Z)
		return if ok then y else RoadConstants.getGroundY()
	end
	local STEPS = 10
	local walls: Folder? = nil
	local prevDir = right
	for i = 1, STEPS do
		local ang = math.pi * i / STEPS
		local dirI = right * math.cos(ang) + flat * math.sin(ang)
		local a = center + prevDir * r
		local b = center + dirI * r
		local chord = b - a
		local len = chord.Magnitude
		if len > 1e-3 then
			local mid = (a + b) * 0.5
			local groundY = groundYAt(center + (prevDir + dirI).Unit * probeR)
			local depth = groundY - surfaceY
			if depth >= 6 and depth <= 18 then
				if not walls then
					walls = Instance.new("Folder")
					walls.Name = "TunnelWalls"
					walls.Parent = model
				end
				local wallH = depth + 1
				local look = chord / len
				local wc = Vector3.new(mid.X, surfaceY + wallH * 0.5, mid.Z)
				local wall = Instance.new("Part")
				wall.Name = "TunnelWall"
				wall.Anchored = true
				wall.CanCollide = true
				wall.CanTouch = false
				wall.CanQuery = false
				wall.CastShadow = true
				wall.Material = Enum.Material.Concrete
				wall.Color = RoadConstants.TUNNEL_WALL_COLOR
				wall.Size = Vector3.new(thk, wallH, len + 0.6)
				wall.CFrame = CFrame.lookAt(wc, wc + look, Vector3.yAxis)
				wall.Parent = walls :: Folder
			end
		end
		prevDir = dirI
	end
end

-- Max height of the road deck above natural ground along the segment. Drives the edge
-- barrier: a metal guardrail once it's off the ground, a solid parapet wall when high.
local function maxDeckHeight(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): number
	local maxH = 0
	for i = 0, 8 do
		local pt = BezierUtil.point(p0, p1, p2, p3, i / 8)
		local ok, gy = pcall(_getSurfaceY, pt.X, pt.Z)
		local groundY = if ok then gy else RoadConstants.getGroundY()
		local h = (pt.Y - RoadConstants.ROAD_THICKNESS * 0.5) - groundY
		if h > maxH then maxH = h end
	end
	return maxH
end

-- Pick the edge barrier for a deck of the given height: a concrete wall once it's off the
-- ground, a taller concrete parapet when high; both get a metal cap rail (added by
-- RoadRenderer). Falls back to the road type's own guardrail spec at ground level.
local function barrierFor(deckHeight: number, spec: any, vMode: string?): boolean
	return deckHeight >= RoadConstants.GUARDRAIL_MIN_HEIGHT or spec.guardrail == true or vMode == "Elevated"
end

-- A speed-limit numeral is painted only where the posted limit actually CHANGES: a road
-- connected at this node has a different speed limit. Drivers entering see the new limit once,
-- instead of it repeating down every road.
local function speedDiffersAt(nodeId: Types.NodeId, seg: Types.Segment, mySpeed: number?): boolean
	local node = _network:getNodes()[nodeId]
	if not node then return false end
	for _, otherId in node.segments do
		if otherId ~= seg.id then
			local other = _network:getSegment(otherId)
			if other and not other.isArc then
				local oSpec = RoadTypeCatalog.getOrDefault(other.roadType)
				if oSpec.speedLimit ~= mySpeed then return true end
			end
		end
	end
	return false
end

-- Street lamps: server clones a ServerStorage lamp template into each segment model
-- (they replicate for free and die with the model on rerender/removal).
-- Roads up to 2 lanes get a single-arm lamp on ONE kerb (right of travel); wider roads
-- get the twin-arm mast on both.
local LAMP_SPACING = 90
local LAMP_MIN_RUN = 30
local _propTemplates: { [string]: Model } = {}
local _propWarned: { [string]: boolean } = {}

local function propTemplate(name: string): Model?
	if not RunService:IsServer() then return nil end
	local cached = _propTemplates[name]
	if cached and cached.Parent then return cached end
	local found = game:GetService("ServerStorage"):FindFirstChild(name, true)
	if found and found:IsA("Model") then
		_propTemplates[name] = found
		return found
	end
	if not _propWarned[name] then
		_propWarned[name] = true
		warn(`[RoadSceneRenderer] no {name} model in ServerStorage -- that prop is not placed`)
	end
	return nil
end

-- Yaw-only frame with local +X = toward the road (arm direction), like TrafficLightPlacer.
local function propCFrame(position: Vector3, inward: Vector3): CFrame
	local x = Vector3.new(inward.X, 0, inward.Z)
	x = if x.Magnitude < 1e-4 then Vector3.xAxis else x.Unit
	local z = x:Cross(Vector3.yAxis).Unit
	return CFrame.fromMatrix(position, x, z:Cross(x).Unit, z)
end

-- Walk the curve ONCE and call `place` at `count` evenly spaced stations between arc
-- lengths s0 and s1, handing it the station's position and the road's right vector there.
-- Shared by the lamps and the street trees so kerbside furniture lines up on one pass.
local function forEachStation(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, length: number,
	s0: number, s1: number, count: number, place: (number, Vector3, Vector3) -> ())
	local n = math.clamp(math.ceil(length / 4), 8, 128)
	local prev = p0
	local acc = 0
	local nextIdx = 1
	for i = 1, n do
		local pt = BezierUtil.point(p0, p1, p2, p3, i / n)
		local span = (pt - prev).Magnitude
		while nextIdx <= count do
			local target = s0 + (s1 - s0) * (nextIdx - 0.5) / count
			if acc + span < target then break end
			local f = (target - acc) / math.max(span, 1e-6)
			local tan = BezierUtil.tangent(p0, p1, p2, p3, (i - 1 + f) / n)
			if tan.Magnitude > 1e-6 then
				local dir = tan.Unit
				place(nextIdx, prev + (pt - prev) * f, Vector3.new(-dir.Z, 0, dir.X))
			end
			nextIdx += 1
		end
		acc += span
		prev = pt
		if nextIdx > count then break end
	end
end

-- `onlySide` (+1 right, -1 left) keeps every lamp on that kerb: a roundabout ring has no
-- inner footway to stand one on.
local function addStreetLamps(model: Model, spec: any, vMode: string?, setbackS: number, setbackE: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, onlySide: number?)
	if spec.isRail or spec.terrainPath or vMode == "Tunnel" then return end

	local length = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
	local s0 = math.max(setbackS, 6)
	local s1 = length - math.max(setbackE, 6)
	if s1 - s0 < LAMP_MIN_RUN then return end

	local bothSides = spec.laneCount > 2
	-- Wide roads take the taller twin-arm mast: long arm over the carriageway, short over the footway.
	local template = propTemplate(if bothSides then "StreetLampTwin" else "StreetLamp")
	if not template then return end
	-- Hard against the kerb (0.2 of the footway), where a real lamp column stands and
	-- where its arm can reach out over the carriageway. The rest of the pavement is
	-- walking room: trees take 0.7 and cabinets 0.88.
	local lateral = spec.width * 0.5 + (if spec.noSidewalk then 1.5 else RoadConstants.SIDEWALK_WIDTH * 0.2)
	local count = math.max(math.floor((s1 - s0) / LAMP_SPACING + 0.5), 1)

	local function place(idx: number, pos: Vector3, offset: Vector3, inward: Vector3, tag: string)
		local clone = template:Clone()
		clone.Name = `StreetLamp_{idx}{tag}`
		clone:PivotTo(propCFrame(pos + offset + Vector3.new(0, RoadConstants.SIDEWALK_HEIGHT, 0), inward))
		clone.Parent = model
	end

	forEachStation(p0, p1, p2, p3, length, s0, s1, count, function(idx, pos, right)
		if onlySide == -1 then
			place(idx, pos, -right * lateral, right, "L")
			return
		end
		place(idx, pos, right * lateral, -right, "R")
		if bothSides and onlySide == nil then
			place(idx, pos, -right * lateral, right, "L")
		end
	end)
end

-- Street trees: the "tr=" road option plants a Nature model along both kerbs, as children
-- of the segment model -- so they replicate for free, die with the road, and need no
-- separate persistence (the species rides in the segment's own roadType id).
local TREE_SPACING = 48
local TREE_MIN_RUN = 20

local function addStreetTrees(model: Model, spec: any, vMode: string?, setbackS: number, setbackE: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3)
	local key = spec.streetTrees
	if typeof(key) ~= "string" or spec.isRail or spec.terrainPath or vMode == "Tunnel" then return end
	-- Server only: these clones replicate, so planting them client-side too would double
	-- every avenue (same rule as the lamps).
	if not RunService:IsServer() then return end
	local folder = ReplicatedStorage:FindFirstChild("Nature")
	local template = folder and folder:FindFirstChild(key)
	if not (template and template:IsA("Model")) then return end

	local length = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
	local s0 = math.max(setbackS, 6)
	local s1 = length - math.max(setbackE, 6)
	if s1 - s0 < TREE_MIN_RUN then return end

	-- Outer third of the sidewalk, so a tree never shares its spot with a lamp post.
	local lateral = spec.width * 0.5 + (if spec.noSidewalk then 2 else RoadConstants.SIDEWALK_WIDTH * 0.7)
	local count = math.max(math.floor((s1 - s0) / TREE_SPACING + 0.5), 1)
	local baseScale = (template :: Model):GetScale()

	local function plant(idx: number, pos: Vector3, offset: Vector3, tag: string)
		local clone = (template :: Model):Clone()
		clone.Name = `StreetTree_{idx}{tag}`
		-- Jitter from the index, not random: a re-render must not reshuffle the avenue.
		clone:ScaleTo(baseScale * (0.9 + (idx % 3) * 0.1))
		clone:PivotTo(CFrame.new(pos + offset + Vector3.new(0, RoadConstants.SIDEWALK_HEIGHT, 0))
			* CFrame.Angles(0, idx * 2.4, 0))
		clone.Parent = model
	end

	forEachStation(p0, p1, p2, p3, length, s0, s1, count, function(idx, pos, right)
		plant(idx, pos, right * lateral, "R")
		plant(idx, pos, -right * lateral, "L")
	end)
end

local PAD_THICKNESS = 1

-- Terrain paths (gravel/dirt) render no asphalt slab -- the painted terrain is the visible
-- surface. This builds only an invisible, collidable + queryable pad swept along the
-- centerline: cars ride a flat surface at road height, sims walk it, and the bulldoze/hover
-- raycast still selects the segment. Its top sits at the centerline Y (where the nav lanes run).
local function buildTerrainPathPad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, spec: any): Model?
	local length = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
	local n = math.clamp(math.floor(length / 6), 2, 128)
	local builder = RoadMeshBuilder.new()
	local prev = BezierUtil.point(p0, p1, p2, p3, 0)
	for i = 1, n do
		local cur = BezierUtil.point(p0, p1, p2, p3, i / n)
		local dir = cur - prev
		local len = dir.Magnitude
		if len > 1e-3 then
			local mid = (prev + cur) * 0.5
			local cf = CFrame.lookAt(mid, mid + dir) * CFrame.new(0, -PAD_THICKNESS * 0.5, 0)
			builder:addBox(cf, Vector3.new(spec.width, PAD_THICKNESS, len + 0.5), spec.surfaceColor)
		end
		prev = cur
	end
	return builder:bake({
		name = "TerrainPathPad",
		anchored = true,
		canCollide = true,
		canQuery = true,
		transparency = 1,
	})
end

-- Yield sign prop at a roundabout entry: red inverted-triangle plate on a pole at
-- the approaching arm's own kerb (which side that is rides the driving side),
-- beside the painted give-way teeth.
-- ponytail: solid red plate (no white inset) -- two wedges + a pole per sign.
local function addYieldSign(model: Model, seg: Types.Segment, nodeId: Types.NodeId, spec: any)
	local dist = armJunctionBoundary(nodeId, seg.id) + RoadConstants.GIVEWAY_SETBACK
	-- An arm shorter than the sign's setback would place the sign at its FAR end
	-- (segFrameFromNode clamps to the opposite node) -- skip the sign instead.
	if dist >= BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 8) then return end
	local pos, awayDir = segFrameFromNode(seg, nodeId, dist)
	local fwd = -awayDir -- travel direction of the approaching driver
	local right = fwd:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-6 then return end
	-- Kerb side flips with the driving side. The plate below is built symmetrically
	-- about this axis, so the sign itself is unchanged either way.
	right = right.Unit * RoadRules.getLaneSideSign()
	local base = pos + right * (spec.width * 0.5 + RoadConstants.SIDEWALK_WIDTH * 0.5)
	local poleH = RoadConstants.YIELD_SIGN_POLE_HEIGHT
	local plate = RoadConstants.YIELD_SIGN_PLATE_SIZE

	local pole = Instance.new("Part")
	pole.Name = "YieldSignPole"
	pole.Shape = Enum.PartType.Cylinder
	pole.Size = Vector3.new(poleH, 0.5, 0.5)
	pole.Color = Color3.fromRGB(120, 124, 130)
	pole.Material = Enum.Material.Metal
	pole.Anchored = true
	pole.CanCollide = false
	pole.CanQuery = false
	pole.CFrame = CFrame.new(base + Vector3.new(0, poleH * 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90))
	pole.Parent = model

	-- Inverted triangle from two mirrored wedges: a wedge's triangular cross-section
	-- lies in its local Y-Z plane, so map local Z across the plate (+-right), local Y
	-- to -up (apex down); the thickness axis then faces the approaching driver.
	local up = Vector3.yAxis
	local plateH = plate * 0.87
	local centre = base + Vector3.new(0, poleH - plateH * 0.5, 0)
	for _, s in { -1, 1 } do
		local zv = right * s
		local yv = -up
		local xv = yv:Cross(zv)
		local w = Instance.new("WedgePart")
		w.Name = "YieldSignPlate"
		w.Size = Vector3.new(0.3, plateH, plate * 0.5)
		w.Color = RoadConstants.YIELD_SIGN_COLOR
		w.Material = Enum.Material.SmoothPlastic
		w.Anchored = true
		w.CanCollide = false
		w.CanQuery = false
		w.CFrame = CFrame.fromMatrix(centre - right * (s * plate * 0.25), xv, yv, zv)
		w.Parent = model
	end

	-- "YIELD" label on an invisible plate in front of the triangle, facing the driver.
	local face = Instance.new("Part")
	face.Name = "YieldSignLabel"
	face.Size = Vector3.new(plate, plateH, 0.05)
	face.Transparency = 1
	face.Anchored = true
	face.CanCollide = false
	face.CanQuery = false
	-- Front (-Z) face toward the approaching driver, nudged clear of the plate.
	face.CFrame = CFrame.lookAt(centre - fwd * 0.25, centre - fwd * 2)
	face.Parent = model
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.CanvasSize = Vector2.new(200, 174)
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Parent = face
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	-- Upper half of the inverted triangle is the wide part -- keep the text there.
	text.Size = UDim2.fromScale(0.7, 0.34)
	text.Position = UDim2.fromScale(0.15, 0.1)
	text.Font = Enum.Font.GothamBlack
	text.Text = "YIELD"
	text.TextScaled = true
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Parent = gui
end

-- == Kerbside furniture =====================================================
-- Three props that dress a finished street, placed exactly the way the lamps are:
-- a ServerStorage template cloned into the SEGMENT model, so each one replicates
-- once, carries no persistence of its own and dies with the road it belongs to.
--   Manhole covers -- on the carriageway, down a wheel track, alternating sides.
--   Utility boxes  -- at the back of the footway, broad side facing the road.
--   Name blades    -- one per arm, at junctions the lights do not control.
local MANHOLE_SPACING = 420
local MANHOLE_MIN_RUN = 170
local MANHOLE_JITTER_ALONG = 45
local MANHOLE_LIFT = RoadConstants.ROAD_THICKNESS * 0.5 + 0.02
local BOX_SPACING = 320
local BOX_MIN_RUN = 130
local BOX_KEYS = { "UtilityBox_Big", "UtilityBox_Wide", "UtilityBox_Small" }
local BOX_JITTER_ALONG = 40 -- studs of scatter up/down the kerb

-- -1..1 from a position, not from math.random: a re-render must reproduce it.
local function scatter(seed: number): number
	local h = math.sin(seed) * 43758.5453
	return (h - math.floor(h)) * 2 - 1
end
local HYDRANT_SPACING = 300
local HYDRANT_MIN_RUN = 140
local HYDRANT_JITTER_ALONG = 50
local SIGN_SETBACK = 3

-- Furniture belongs to an ordinary street at ground level: nothing stands on rail
-- ballast, a dirt track, a tunnel bore or an elevated deck.
local function dressable(spec: any, vMode: string?): boolean
	return not (spec.isRail or spec.terrainPath or vMode == "Tunnel" or vMode == "Elevated")
end

-- Which of the segment's own sides are paved (+1 = the segment's right).
local function hasFootway(spec: any, sideSign: number): boolean
	local mode = spec.sidewalkMode or (if spec.noSidewalk then "none" else "both")
	if mode == "none" then return false end
	if mode == "left" then return sideSign < 0 end
	if mode == "right" then return sideSign > 0 end
	return true
end

local function addManholes(model: Model, spec: any, vMode: string?, setbackS: number, setbackE: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3)
	if not dressable(spec, vMode) then return end
	local template = propTemplate("ManholeCover")
	if not template then return end

	local length = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
	-- Well clear of the junction mouths at either end: a cover in a crosswalk reads
	-- as a mistake, and it is also where two segments' covers would collide.
	local s0 = math.max(setbackS, 22)
	local s1 = length - math.max(setbackE, 22)
	if s1 - s0 < MANHOLE_MIN_RUN then return end

	-- Somewhere in a wheel track: off the centre line, inside the edge line. Every
	-- part of that is scattered off the station's own position rather than stepped off
	-- the index -- two segments meeting at a node each lay their own covers, and on a
	-- fixed offset those two land on the same patch of road.
	local half = RoadTypeCatalog.carriagewayWidth(spec) * 0.5
	local count = math.max(math.floor((s1 - s0) / MANHOLE_SPACING + 0.5), 1)

	forEachStation(p0, p1, p2, p3, length, s0, s1, count, function(idx, pos, right)
		local clone = template:Clone()
		clone.Name = `Manhole_{idx}`
		local seed = pos.X * 1.7 + pos.Z * 0.9
		local side = scatter(seed)
		local lateral = half * (0.2 + math.abs(side) * 0.35) * (if side < 0 then -1 else 1)
		local forward = Vector3.yAxis:Cross(right)
		local slide = forward * (scatter(seed + 5) * MANHOLE_JITTER_ALONG)
		clone:PivotTo(CFrame.new(pos + right * lateral + slide + Vector3.new(0, MANHOLE_LIFT, 0)))
		clone.Parent = model
	end)
end

local function addUtilityBoxes(model: Model, spec: any, vMode: string?, setbackS: number, setbackE: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3)
	if not dressable(spec, vMode) or spec.noSidewalk then return end
	local sideSign = if hasFootway(spec, 1) then 1 elseif hasFootway(spec, -1) then -1 else 0
	if sideSign == 0 then return end

	local length = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
	local s0 = math.max(setbackS, 12)
	local s1 = length - math.max(setbackE, 12)
	if s1 - s0 < BOX_MIN_RUN then return end

	-- Back of the footway, where a cabinet stands clear of the walking line: the
	-- lamps take the kerb (0.5 of the width) and the trees the outer third (0.7).
	local lateral = spec.width * 0.5 + RoadConstants.SIDEWALK_WIDTH * 0.88
	local count = math.max(math.floor((s1 - s0) / BOX_SPACING + 0.5), 1)

	forEachStation(p0, p1, p2, p3, length, s0, s1, count, function(idx, pos, right)
		-- Seeded off the station's own position, so which cabinet stands here, how far
		-- it slides along the kerb and how square it sits are all scattered but fixed.
		local seed = pos.X * 0.7 + pos.Z * 1.3
		local template = propTemplate(BOX_KEYS[math.floor(math.abs(scatter(seed) * 1000)) % #BOX_KEYS + 1])
		if not template then return end
		local clone = template:Clone()
		clone.Name = `UtilityBox_{idx}`
		local out = right * sideSign
		local forward = Vector3.yAxis:Cross(right)
		local slide = forward * (scatter(seed + 11) * BOX_JITTER_ALONG)
		local base = pos + out * lateral + slide + Vector3.new(0, RoadConstants.SIDEWALK_HEIGHT, 0)
		clone:PivotTo(propCFrame(base, -out))
		clone.Parent = model
	end)
end

local function addHydrants(model: Model, spec: any, vMode: string?, setbackS: number, setbackE: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3)
	if not dressable(spec, vMode) or spec.noSidewalk then return end
	-- Opposite kerb to the cabinets where both are paved, so one pavement does not
	-- carry every piece of street furniture.
	local sideSign = if hasFootway(spec, -1) then -1 elseif hasFootway(spec, 1) then 1 else 0
	if sideSign == 0 then return end
	local template = propTemplate("FireHydrantProp")
	if not template then return end

	local length = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
	local s0 = math.max(setbackS, 14)
	local s1 = length - math.max(setbackE, 14)
	if s1 - s0 < HYDRANT_MIN_RUN then return end

	-- Near the kerb like a real hydrant, just outboard of the lamp line at 0.2.
	local lateral = spec.width * 0.5 + RoadConstants.SIDEWALK_WIDTH * 0.28
	local count = math.max(math.floor((s1 - s0) / HYDRANT_SPACING + 0.5), 1)

	forEachStation(p0, p1, p2, p3, length, s0, s1, count, function(idx, pos, right)
		local clone = template:Clone()
		clone.Name = `FireHydrant_{idx}`
		local seed = pos.X * 1.1 + pos.Z * 2.3
		local out = right * sideSign
		local slide = Vector3.yAxis:Cross(right) * (scatter(seed) * HYDRANT_JITTER_ALONG)
		clone:PivotTo(propCFrame(pos + out * lateral + slide + Vector3.new(0, RoadConstants.SIDEWALK_HEIGHT, 0), -out))
		clone.Parent = model
	end)
end

-- A junction with no lights gets a name blade on the corner instead. "signal"
-- carries its own gantry (TrafficSignalService) and "none" is a bend, a dead end or
-- a roundabout mouth -- neither is an intersection anyone needs directing through.
local function unsignalisedJunction(nodeId: Types.NodeId): boolean
	return RoadRules.nodeControl(_network, nodeId) == "priority"
end

local function addStreetNameSign(model: Model, seg: Types.Segment, nodeId: Types.NodeId, spec: any)
	if not dressable(spec, seg.vMode) or spec.noSidewalk or spec.isHighway then return end
	local template = propTemplate("StreetNameSign")
	if not template then return end

	local dist = armJunctionBoundary(nodeId, seg.id) + SIGN_SETBACK
	if dist >= BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 8) then return end
	local pos, awayDir = segFrameFromNode(seg, nodeId, dist)
	local along = Vector3.new(awayDir.X, 0, awayDir.Z)
	if along.Magnitude < 1e-4 then return end
	along = along.Unit

	-- The corner the arriving driver sees: their right-hand kerb, which flips with
	-- the driving side. Their travel direction is INTO the junction, -along.
	local mode = spec.sidewalkMode or "both"
	if mode == "none" then return end
	local kerb
	if mode == "both" then
		kerb = (-along):Cross(Vector3.yAxis).Unit * RoadRules.getLaneSideSign()
	else
		-- One paved kerb only: the blade stands on it, whichever side of travel it is.
		local segRight = along:Cross(Vector3.yAxis).Unit
		if seg.endNode == nodeId then segRight = -segRight end
		kerb = if mode == "right" then segRight else -segRight
	end

	local clone = template:Clone()
	clone.Name = `StreetNameSign_{nodeId}`
	-- The blade reads ALONG the street it names, so a driver on the crossing road
	-- sees it face on. Template local +X runs the length of the plate.
	clone:PivotTo(CFrame.fromMatrix(
		pos + kerb * (spec.width * 0.5 + RoadConstants.SIDEWALK_WIDTH * 0.5)
			+ Vector3.new(0, RoadConstants.SIDEWALK_HEIGHT, 0),
		along, Vector3.yAxis))
	clone.Parent = model
end

-- A roundabout ring piece (an arc, or the corner joining two arcs) has its sidewalk only on
-- the outside -- the centre's brick apron takes the inside -- and no lane dividers or inner
-- edge line: the centre paints those as unbroken circles (buildRoundaboutCentre), so they
-- carry on through every arm instead of stopping at each. True when the ring's centre lies
-- to the RIGHT (+side) of travel from a to b.
local function ringInnerIsRight(center: Vector3, a: Vector3, b: Vector3, mid: Vector3): boolean
	local chord = b - a
	local right = Vector3.new(chord.X, 0, chord.Z):Cross(Vector3.yAxis)
	return (center - mid):Dot(right) > 0
end

local function renderSegment(seg: Types.Segment)

	if seg.isArc then
		local old = _models[seg.id]
		if old then
			old:Destroy()
			_models[seg.id] = nil
		end
		return
	end
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	local sStyle = nodeStyle(seg.startNode)
	local eStyle = nodeStyle(seg.endNode)
	local ringInnerRight: boolean? = if seg.isRoundabout and seg.roundaboutCenter
		then ringInnerIsRight(seg.roundaboutCenter, seg.p0, seg.p3, BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, 0.5))
		else nil
	local sidewalkMode = if ringInnerRight == nil then spec.sidewalkMode elseif ringInnerRight then "left" else "right"

	-- ponytail: cramped-link furniture suppression removed (user: keep markings/arrows/sidewalk on short links).

	local zo = RoadConstants.ZFIGHT_OFFSET
	local rp0 = if sStyle == "intersection" or sStyle == "corner"
		then Vector3.new(seg.p0.X, seg.p0.Y + zo, seg.p0.Z)
		else seg.p0
	local rp3 = if eStyle == "intersection" or eStyle == "corner"
		then Vector3.new(seg.p3.X, seg.p3.Y + zo, seg.p3.Z)
		else seg.p3
	local rp1 = Vector3.new(seg.p1.X, seg.p1.Y + (if sStyle == "intersection" or sStyle == "corner" then zo * 0.5 else 0), seg.p1.Z)
	local rp2 = Vector3.new(seg.p2.X, seg.p2.Y + (if eStyle == "intersection" or eStyle == "corner" then zo * 0.5 else 0), seg.p2.Z)

	-- Terrain path: no asphalt slab, no markings/curbs. Build an invisible drivable pad; the
	-- terrain paint done by TerrainGradeService is what the player actually sees.
	if spec.terrainPath then
		local ok, newModel = pcall(buildTerrainPathPad, rp0, rp1, rp2, rp3, spec)
		if ok and newModel then
			local m = newModel :: Model
			m.Name = `Segment_{seg.id}`
			m.Parent = _roadsFolder
			local old = _models[seg.id]
			if old then old:Destroy() end
			_models[seg.id] = m
		else
			warn(`[RoadSceneRenderer] terrain-path pad {seg.id} failed: {tostring(newModel)}`)
		end
		return
	end

	local whiteColor = RoadConstants.MARKING_WHITE

	local laneOffsets = laneOffsetsForSpec(spec)
	local busLaneOffsets, busLaneWidth = busLaneBandsForSpec(spec)

	local wantCrosswalk = not spec.noCrosswalk
	local wantSidewalk  = not spec.noSidewalk

	local arrowsStart = if sStyle == "intersection" then approachArrowsAt(seg.startNode, seg) else nil
	local arrowsEnd   = if eStyle == "intersection" then approachArrowsAt(seg.endNode,   seg) else nil
	-- The stop line still spans the arm's own approach lanes (arrowsStart/End above). Only the
	-- painted ARROW ROW moves: an arm with no room for it hands it to the segment behind (the
	-- relay below), and painting it here as well would double it up.
	-- Hand the row back only when something is actually there to take it. The junction at THIS
	-- end relays through the OTHER end's node, so a stub that dead-ends keeps its own row.
	local ownArrowRoom = approachRoom(seg) >= ARROW_MIN_APPROACH
	local arrowsDrawStart = if ownArrowRoom or arrowRelayTarget(seg, seg.endNode) == nil then arrowsStart else nil
	local arrowsDrawEnd = if ownArrowRoom or arrowRelayTarget(seg, seg.startNode) == nil then arrowsEnd else nil
	if not arrowsDrawStart and sStyle == "straight" then
		arrowsDrawStart = relayedApproachArrows(seg, seg.startNode)
	end
	if not arrowsDrawEnd and eStyle == "straight" then
		arrowsDrawEnd = relayedApproachArrows(seg, seg.endNode)
	end
	if spec.isRail then arrowsStart, arrowsEnd = nil, nil end -- no turn arrows on track
	local laneW = RoadTypeCatalog.carriagewayWidth(spec) / spec.laneCount

	-- Shallow fork: the secondary arm yields its crosswalk/stop-line so two near-parallel
	-- arms don't stamp overlapping zebras across the shared throat (see armYieldsFurniture).
	local yieldStart = sStyle == "intersection" and armYieldsFurniture(seg.startNode, seg.id)
	local yieldEnd = eStyle == "intersection" and armYieldsFurniture(seg.endNode, seg.id)

	-- Overlapped-fork gore kerbs: only the gore side pulls back to the separation point.
	-- Arm frame right at the START node is the segment's right (travel leaves the node);
	-- at the END node the arm dir is -travel, so the arm's right is the segment's LEFT.
	local goreStartRight: number?, goreStartLeft: number? = nil, nil
	local goreEndRight: number?, goreEndLeft: number? = nil, nil
	if sStyle == "intersection" then
		goreStartRight, goreStartLeft = goreSidewalkStarts(seg.startNode, seg.id)
	end
	if eStyle == "intersection" then
		local armRight, armLeft = goreSidewalkStarts(seg.endNode, seg.id)
		goreEndRight, goreEndLeft = armLeft, armRight
	end

	-- A link consumed by its two junction reaches has no roadway left for furniture:
	-- crosswalks / stop lines / arrows would float inside the neighbouring junction's fill
	-- (the stranded-zebra mess when a road is drawn across two crowding roads). Drop them
	-- and let the two fills merge into one paved expanse. Ordinary short links that keep a
	-- real clear length keep their markings (deliberate -- see the cramped-link note above).
	local reachS = if sStyle == "intersection" then armJunctionBoundary(seg.startNode, seg.id)
		elseif sStyle == "corner" then nodeArmBoundary(seg.startNode, seg.id)
		elseif sStyle == "merge" then mergeTrim(seg.startNode, seg.id)
		else 0
	local reachE = if eStyle == "intersection" then armJunctionBoundary(seg.endNode, seg.id)
		elseif eStyle == "corner" then nodeArmBoundary(seg.endNode, seg.id)
		elseif eStyle == "merge" then mergeTrim(seg.endNode, seg.id)
		else 0
	local linkLen = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 16)
	-- Only a link squeezed between two ends that actually TERMINATE the roadway is cramped.
	-- A `straight` node is a mid-road split (auto-split, or a node dropped while drawing) and the
	-- carriageway runs on past it, so this end's furniture has the continuation's length to sit
	-- in. Measuring the raw segment length instead made a short stub off a junction read as
	-- cramped and stripped its crosswalk, stop line and arrows -- a bare approach on a road that
	-- carries on for hundreds of studs.
	local linkBounded = sStyle ~= "straight" and eStyle ~= "straight"
	-- Ask each end for exactly the room its OWN marking band needs, and only from ends that
	-- actually paint one. The old rule demanded a flat CRAMPED_LINK_USABLE (14 studs, i.e. two
	-- bands) from every bounded link and then stripped BOTH ends -- so a link with a single
	-- intersection end (the far end a corner, a dead end, or an arm already yielding to a fork)
	-- came out bare while it had twice the room it needed. That is the "junction where some arms
	-- have no zebra or stop line" bug: a big junction's reach eats the usable length, and an
	-- ordinary short block beside it loses markings it had plenty of room for.
	local usable = linkLen - reachS - reachE
	-- Charge an end only for what it actually paints: a roundabout end draws no zebra or stop
	-- line (see the crosswalk/stopLine guards below) and an already-yielding fork arm has
	-- handed its band to its neighbour, so neither needs room reserved for one.
	local startPaintsBand = sStyle == "intersection" and not yieldStart and not nodeHasRoundabout(seg.startNode)
	local endPaintsBand = eStyle == "intersection" and not yieldEnd and not nodeHasRoundabout(seg.endNode)
	local bandsNeeded = (if startPaintsBand then MARKING_BAND_DEPTH else 0)
		+ (if endPaintsBand then MARKING_BAND_DEPTH else 0)
	if linkBounded and usable < bandsNeeded then
		if sStyle == "intersection" then yieldStart = true end
		if eStyle == "intersection" then yieldEnd = true end
		-- arrowsStart/arrowsEnd are deliberately LEFT ALONE. They are the stop line's lane span
		-- (stopSpanFromArrows), not the painted row -- clearing them here killed the stop line
		-- along with the arrows. The painted row is arrowsDraw*, and it already has its own,
		-- stricter room test (ownArrowRoom >= ARROW_MIN_APPROACH, ~18.2 studs) above.
		arrowsDrawStart = nil
		arrowsDrawEnd = nil
	end

	-- Crossing seat per painting end. Placed after the cramped-link block above, which can
	-- still flip yieldStart/yieldEnd.
	local cwStartRadius: number? = if wantCrosswalk and sStyle == "intersection" and not nodeHasRoundabout(seg.startNode) and not yieldStart
		then crosswalkSeat(seg.startNode, seg.id) else nil
	local cwEndRadius: number? = if wantCrosswalk and eStyle == "intersection" and not nodeHasRoundabout(seg.endNode) and not yieldEnd
		then crosswalkSeat(seg.endNode, seg.id) else nil

	-- Roundabout entries give way (circulating traffic has priority -- RoadRules):
	-- shark teeth + a yield sign on any non-ring arm where it meets a ring node,
	-- across the approaching lanes only. An exit-only one-way arm has no incoming
	-- lanes (arrows nil) -> no teeth, no sign. Ring arcs themselves never yield.
	local giveWayRoundStart = not seg.isRoundabout and sStyle == "intersection"
		and nodeHasRoundabout(seg.startNode) and arrowsStart ~= nil
	local giveWayRoundEnd = not seg.isRoundabout and eStyle == "intersection"
		and nodeHasRoundabout(seg.endNode) and arrowsEnd ~= nil

	local startWidth, startNext = transitionAtNode(seg.startNode, seg.id, spec.width)
	local endWidth, endNext = transitionAtNode(seg.endNode, seg.id, spec.width)
	local mergeEnd = if endWidth then mergeArrowsAtEnd(seg.endNode, seg, spec) else nil

	local startHold = if startWidth and sStyle == "corner" then nodeArmBoundary(seg.startNode, seg.id) else 0
	local endHold = if endWidth and eStyle == "corner" then nodeArmBoundary(seg.endNode, seg.id) else 0

	local transLen = RoadConstants.ROAD_WIDTH_TRANSITION_LENGTH
	-- Interior lane lines must not run the whole way through a width transition. A 4-lane
	-- road that tapers to 2 lanes has no interior lanes in the throat, so dashes piling up
	-- in the narrow end look wrong. Stop them partway into the taper: they run from full
	-- width down to LANE_LINE_TAPER_KEEP of the transition, leaving the throat clean while
	-- not ending so early it leaves a bare gap. Centre line and shoulder edge lines still
	-- run the full length, and the junction setback still applies on top.
	local LANE_LINE_TAPER_KEEP = 0.5
	local laneLineStart = endSetback(seg.startNode, sStyle, seg.id)
	local laneLineEnd = endSetback(seg.endNode, eStyle, seg.id)
	-- A highway running straight through a junction keeps its lane dashes unbroken:
	-- a ramp joining must not interrupt the through carriageway's markings.
	if spec.isHighway then
		if sStyle == "intersection" and throughAt(seg.startNode, seg.id) then laneLineStart = 0 end
		if eStyle == "intersection" and throughAt(seg.endNode, seg.id) then laneLineEnd = 0 end
	end
	if startWidth then
		laneLineStart = math.max(laneLineStart, startHold + transLen * LANE_LINE_TAPER_KEEP)
	end
	if endWidth then
		laneLineEnd = math.max(laneLineEnd, endHold + transLen * LANE_LINE_TAPER_KEEP)
	end

	-- Elevated decks get a metal guardrail at the edge (carried through corners by connectors).
	local barrierOn = barrierFor(maxDeckHeight(rp0, rp1, rp2, rp3), spec, seg.vMode)

	local mySpeed = spec.speedLimit
	local showSpeed = not spec.noSidewalk and mySpeed ~= nil
	local speedNumberStart = showSpeed and speedDiffersAt(seg.startNode, seg, mySpeed)
	local speedNumberEnd = showSpeed and not spec.oneWay and speedDiffersAt(seg.endNode, seg, mySpeed)

	-- Build the replacement BEFORE the old model is touched, and keep the old one when
	-- the build throws: a renderer error must never strip a healthy road (it used to
	-- leave a half-drawn slab with only a warn).
	local newModel: Model? = nil
	local built, buildErr = xpcall(function()
		newModel = RoadRenderer.build(rp0, rp1, rp2, rp3, _roadsFolder, {
		color = spec.surfaceColor,
		anchored = true,
		canCollide = true,
		width = spec.width,
		widthStart = startWidth,
		widthEnd = endWidth,
		widthTransitionLength = RoadConstants.ROAD_WIDTH_TRANSITION_LENGTH,
		widthStartHold = startHold,
		widthEndHold = endHold,
		-- Trim the slab at corner AND intersection mouths. The junction surface is anchored
		-- to the exact mouth cross-section, so it owns the box area; running the slab through
		-- the junction poked its side edges up through the warped surface on grades.
		surfaceStartOffset = if sStyle == "intersection" or sStyle == "corner" or sStyle == "merge" then reachS else nil,
		surfaceEndOffset = if eStyle == "intersection" or eStyle == "corner" or eStyle == "merge" then reachE else nil,
		centerLineColor = spec.centerLineColor,
		centerLineWidth = spec.centerLineWidth,
		centerLineDashed = spec.centerLineDashed,
		centerLineDouble = spec.centerLineDouble,
		edgeLineColor = spec.edgeLineColor,
		edgeLineColorLeft = spec.edgeLineColorLeft,
		edgeLineWidth = spec.edgeLineWidth,
		edgeLinePlus = if ringInnerRight == true then false else nil,
		edgeLineMinus = if ringInnerRight == false then false else nil,
		laneLineColor = if ringInnerRight == nil then spec.laneLineColor else nil,
		laneLineWidth = spec.laneLineWidth,
		laneOffsets = laneOffsets,
		laneLineStartOffset = laneLineStart,
		laneLineEndOffset = laneLineEnd,
		busLaneColor = if spec.busLane and #busLaneOffsets > 0 then RoadConstants.BUS_LANE_COLOR else nil,
		busLaneOffsets = busLaneOffsets,
		busLaneWidth = busLaneWidth,
		-- Shark teeth: a one-way highway ramp merging into a through carriageway, and
		-- any arm entering a roundabout. Spans limit roundabout teeth to the approach
		-- lanes so a two-way arm's exit half stays clean.
		giveWayEnd = (spec.isHighway and spec.oneWay == true and eStyle == "intersection"
			and not throughAt(seg.endNode, seg.id) and allArmsHighway(seg.endNode))
			or (spec.isHighway and spec.oneWay == true and reachE > 0 and eStyle == "merge")
			or giveWayRoundEnd,
		giveWayEndSpan = if giveWayRoundEnd then stopSpanFromArrows(arrowsEnd, laneW) else nil,
		giveWayStart = giveWayRoundStart,
		giveWayStartSpan = if giveWayRoundStart then stopSpanFromArrows(arrowsStart, laneW) else nil,
		sidewalk = wantSidewalk,
		groundSkirt = RoadConstants.GROUND_SKIRT,
		sidewalkMode = sidewalkMode,
		markingStartOffset = endSetback(seg.startNode, sStyle, seg.id),
		markingEndOffset = endSetback(seg.endNode, eStyle, seg.id),
		sidewalkStartOffset = endCurbSetback(seg.startNode, sStyle, seg.id),
		sidewalkEndOffset = endCurbSetback(seg.endNode, eStyle, seg.id),
		sidewalkStartOffsetRight = goreStartRight,
		sidewalkStartOffsetLeft = goreStartLeft,
		sidewalkEndOffsetRight = goreEndRight,
		sidewalkEndOffsetLeft = goreEndLeft,
		crosswalkColor = if wantCrosswalk then whiteColor else nil,
		crosswalkStartRadius = cwStartRadius,
		crosswalkEndRadius   = cwEndRadius,
		stopLineStart = if wantCrosswalk and sStyle == "intersection" and not nodeHasRoundabout(seg.startNode) and not yieldStart then stopSpanFromArrows(arrowsStart, laneW) else nil,
		stopLineEnd   = if wantCrosswalk and eStyle == "intersection" and not nodeHasRoundabout(seg.endNode) and not yieldEnd then stopSpanFromArrows(arrowsEnd, laneW) else nil,
		arrowColor = whiteColor,
		arrowsStart = arrowsDrawStart,
		arrowsEnd   = arrowsDrawEnd,
		mergeEnd = mergeEnd,

		carriagewayWidth = RoadTypeCatalog.carriagewayWidth(spec),
		parkingLane = spec.parkingLane,
		parkingLaneWidth = spec.parkingLaneWidth,
		parkingSides = spec.parkingSides,
		parkingSide = spec.parkingSide,
		-- Parking is part of the road surface now (same colour), just extra width on the side(s).
		parkingApronColor = spec.surfaceColor,
		median = spec.median,
		medianWidth = spec.medianWidth,
		medianColor = spec.medianColor,
		vergeMode = spec.vergeMode,
		vergeWidth = spec.vergeWidth,
		-- A strip the narrower road past a width taper ALSO carries runs on through and merges;
		-- otherwise it stops where the taper begins.
		medianThroughStart = startNext ~= nil and startNext.median == true,
		medianThroughEnd = endNext ~= nil and endNext.median == true,
		vergeThroughStart = startNext ~= nil and startNext.vergeMode ~= nil,
		vergeThroughEnd = endNext ~= nil and endNext.vergeMode ~= nil,
		guardrail = barrierOn,
		speedLimit = if showSpeed then spec.speedLimit else nil,
		laneCount = spec.laneCount,
		speedNumberStart = speedNumberStart,
		speedNumberEnd = speedNumberEnd,
		oneWay = spec.oneWay,
		isRail = spec.isRail,
	})
		addElevationPillars(newModel :: Model, seg, rp0, rp1, rp2, rp3, seg.vMode, spec)
		if RoadCrossSection.takesWalls(spec, seg) then
			-- Clear distances are from the nodes; this piece is drawn from its trimmed ends.
			local flatDist = function(a: Vector3, b: Vector3): number
				return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
			end
			addRetainingWalls(newModel :: Model, rp0, rp1, rp2, rp3, spec, seg.vMode,
				wallClearAt(seg.startNode, spec.width) - flatDist(rp0, seg.p0),
				wallClearAt(seg.endNode, spec.width) - flatDist(rp3, seg.p3))
		end
	end, debug.traceback)
	if not built or not newModel then
		if newModel then (newModel :: Model):Destroy() end
		warn(`[RoadSceneRenderer] renderSegment {seg.id} failed -- keeping previous visual: {buildErr}`)
		return
	end
	local model = newModel :: Model
	model.Name = `Segment_{seg.id}`
	-- Lot access checks this lightweight metadata to stop paths at a sidewalk when
	-- one exists, or at the asphalt edge on road types without a sidewalk.
	model:SetAttribute("HasSidewalk", wantSidewalk and sidewalkMode ~= "none")
	model:SetAttribute("SidewalkMode", sidewalkMode or "both")
	addStreetLamps(model, spec, seg.vMode,
		endCurbSetback(seg.startNode, sStyle, seg.id),
		endCurbSetback(seg.endNode, eStyle, seg.id),
		rp0, rp1, rp2, rp3,
		if ringInnerRight == nil then nil elseif ringInnerRight then -1 else 1)
	addStreetTrees(model, spec, seg.vMode,
		endCurbSetback(seg.startNode, sStyle, seg.id),
		endCurbSetback(seg.endNode, eStyle, seg.id),
		rp0, rp1, rp2, rp3)
	addUtilityBoxes(model, spec, seg.vMode,
		endCurbSetback(seg.startNode, sStyle, seg.id),
		endCurbSetback(seg.endNode, eStyle, seg.id),
		rp0, rp1, rp2, rp3)
	addHydrants(model, spec, seg.vMode,
		endCurbSetback(seg.startNode, sStyle, seg.id),
		endCurbSetback(seg.endNode, eStyle, seg.id),
		rp0, rp1, rp2, rp3)
	addManholes(model, spec, seg.vMode,
		endCurbSetback(seg.startNode, sStyle, seg.id),
		endCurbSetback(seg.endNode, eStyle, seg.id),
		rp0, rp1, rp2, rp3)
	for _, nid in { seg.startNode, seg.endNode } do
		if unsignalisedJunction(nid) then
			local ok, err = pcall(addStreetNameSign, model, seg, nid, spec)
			if not ok then warn(`[RoadSceneRenderer] name blade at node {nid} failed: {err}`) end
		end
	end
	if giveWayRoundStart then
		pcall(addYieldSign, model, seg, seg.startNode, spec)
	end
	if giveWayRoundEnd then
		pcall(addYieldSign, model, seg, seg.endNode, spec)
	end
	local old = _models[seg.id]
	if old then
		old:Destroy()
	end
	-- Tripwire: a live segment must never render to nothing. The graph dissolves
	-- swallowed slivers (RoadNetwork.dissolveSwallowedArms), so an empty build here
	-- means a case that rule missed -- shout with enough context to diagnose it. A link
	-- between two junctions is exempt: their mouths meet on it and the fills cover it.
	if #model:GetChildren() == 0 and not (sStyle == "intersection" and eStyle == "intersection") then
		warn(`[RoadSceneRenderer] segment {seg.id} rendered EMPTY (len {math.floor(linkLen * 10) / 10}, trims S={reachS} E={reachE}) -- unrenderable sliver survived in the graph`)
	end
	_models[seg.id] = model
end

-- Point and unit "away from node" direction on a segment at `dist` arc-length from `nodeId`'s
-- end. On a straight, flat approach this equals node.position + armDir*dist and the arm
-- direction, so straight corners stay byte-for-byte the same; on a curved or graded approach
-- it follows the real road, so the corner connector starts exactly where the arm's surface was
-- trimmed (and at the right slope) instead of a straight-line guess off the node tangent.
function segFrameFromNode(seg: Types.Segment, nodeId: Types.NodeId, dist: number): (Vector3, Vector3)
	local nodeAtEnd = seg.endNode == nodeId
	local samples = 48
	local prev = if nodeAtEnd then seg.p3 else seg.p0
	local acc = 0
	local foundT: number? = nil
	for i = 1, samples do
		local t = if nodeAtEnd then 1 - i / samples else i / samples
		local pt = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local span = (pt - prev).Magnitude
		if acc + span >= dist then
			local f = (dist - acc) / math.max(span, 1e-6)
			local tPrev = if nodeAtEnd then 1 - (i - 1) / samples else (i - 1) / samples
			foundT = tPrev + (t - tPrev) * f
			break
		end
		acc += span
		prev = pt
	end
	local t = foundT or (if nodeAtEnd then 0 else 1)
	local pos = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
	if tan.Magnitude < 1e-6 then
		tan = seg.p3 - seg.p0
	end
	tan = tan.Unit
	return pos, (if nodeAtEnd then -tan else tan)
end

-- Centerline heights at uniform arc-length steps from the node end out to `dist`
-- (profile[1] at the node, profile[#profile] at `dist`). The junction interior uses
-- these to follow the arm's real vertical curve instead of a straight grade line.
local PROFILE_STEPS = 8
local function segHeightProfileFromNode(seg: Types.Segment, nodeId: Types.NodeId, dist: number): { number }
	local nodeAtEnd = seg.endNode == nodeId
	local samples = 48
	local profile = table.create(PROFILE_STEPS + 1)
	local prev = if nodeAtEnd then seg.p3 else seg.p0
	profile[1] = prev.Y
	local nextIdx = 2
	local acc = 0
	for i = 1, samples do
		local t = if nodeAtEnd then 1 - i / samples else i / samples
		local pt = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local span = (pt - prev).Magnitude
		while nextIdx <= PROFILE_STEPS + 1 do
			local target = dist * (nextIdx - 1) / PROFILE_STEPS
			if acc + span < target then break end
			profile[nextIdx] = prev.Y + (pt.Y - prev.Y) * ((target - acc) / math.max(span, 1e-6))
			nextIdx += 1
		end
		acc += span
		prev = pt
		if nextIdx > PROFILE_STEPS + 1 then
			break
		end
	end
	-- Segment shorter than `dist` (degenerate): hold the last height.
	for i = nextIdx, PROFILE_STEPS + 1 do
		profile[i] = prev.Y
	end
	return profile
end

-- The gore wedge of a merge node: between the highway's edge and the ramp's OUTER edge, from
-- where that edge leaves the highway out to the ramp's trimmed mouth. Everything inside the
-- highway's edge is the highway's own surface, which runs through untouched.
local function buildMergeTaper(nodeId: Types.NodeId, branch: Types.Segment, host: Types.Segment, sep: number): Model
	local bSpec = RoadTypeCatalog.getOrDefault(branch.roadType)
	local hwB = bSpec.width * 0.5
	local hwH = RoadTypeCatalog.getOrDefault(host.roadType).width * 0.5
	local thickness = RoadConstants.ROAD_THICKNESS
	local lift = Vector3.new(0, thickness * 0.5, 0)
	local function hostFrame(p: Vector3): (Vector3, Vector3)
		local t = BezierUtil.closestParam(host.p0, host.p1, host.p2, host.p3, p, 16)
		local f = BezierUtil.point(host.p0, host.p1, host.p2, host.p3, t)
		local tan = BezierUtil.tangent(host.p0, host.p1, host.p2, host.p3, t)
		return f, Vector3.new(-tan.Z, 0, tan.X).Unit
	end
	local mouth, mouthTan = segFrameFromNode(branch, nodeId, sep)
	local mf = hostFrame(mouth)
	local out = Vector3.new(mouth.X - mf.X, 0, mouth.Z - mf.Z)
	out = if out.Magnitude > 1e-4 then out.Unit else Vector3.new(-mouthTan.Z, 0, mouthTan.X).Unit
	local inner, outer = {}, {}
	local steps = math.max(4, math.ceil(sep / 3))
	for s = 0, steps do
		local p, tan = segFrameFromNode(branch, nodeId, sep * s / steps)
		local side = Vector3.new(-tan.Z, 0, tan.X)
		side = if side.Magnitude > 1e-6 then side.Unit else out
		if side:Dot(out) < 0 then side = -side end
		local o = p + side * hwB
		local f, hs = hostFrame(o)
		if hs:Dot(out) < 0 then hs = -hs end
		-- Only stations where the ramp's outer edge is already past the highway's edge. The
		-- inner point is where the ramp's OWN cross-section meets that edge, so the last station
		-- lands exactly on the mouth the ramp's surface was trimmed at.
		local latO = (o - f):Dot(hs)
		if latO > hwH + 0.05 then
			local c = p - side * hwB
			local latC = (c - f):Dot(hs)
			local u = if latO - latC > 1e-4 then math.clamp((latO - hwH) / (latO - latC), 0, 1) else 1
			table.insert(inner, o:Lerp(c, u) + lift)
			table.insert(outer, o + lift)
		end
	end
	local model = Instance.new("Model")
	if #inner >= 2 then
		local builder = RoadMeshBuilder.new()
		-- RoadRenderer's strip convention: `right` is on the travel-direction x UP side.
		local right = mouthTan:Cross(Vector3.yAxis)
		if right:Dot(out) > 0 then
			builder:addSurfaceStrip(inner, outer, bSpec.surfaceColor, thickness)
		else
			builder:addSurfaceStrip(outer, inner, bSpec.surfaceColor, thickness)
		end
		-- Carry the ramp's outer edge line down the taper onto the highway edge.
		local edgeW = bSpec.edgeLineWidth or 0.4
		local paint = table.create(#outer)
		for k, o in outer do
			local toIn = inner[k] - o
			local inset = if toIn.Magnitude > 1e-4 then toIn.Unit * math.min(edgeW * 0.5 + 0.05, toIn.Magnitude) else Vector3.zero
			paint[k] = o + inset + Vector3.new(0, RoadConstants.ZFIGHT_OFFSET * 2, 0)
		end
		builder:addMarkingLine(paint, edgeW, bSpec.edgeLineColor or RoadConstants.MARKING_WHITE, false)
		local mesh = builder:bake({
			name = "Junction",
			anchored = true,
			canCollide = true,
			canQuery = true,
			collisionFidelity = Enum.CollisionFidelity.Default,
		})
		if mesh then mesh.Parent = model end
	end
	model.Parent = _roadsFolder
	return model
end

local function refreshNode(nodeId: Types.NodeId)
	local style = nodeStyle(nodeId)
	local node = _network:getNodes()[nodeId]
	if not node then
		return
	end
	-- Drop any prior terrain grade under this node's corner connector; the corner
	-- branch below re-grades it if the node is still a bend.
	_ungradeConnector(nodeId)
	if style == "deadend" then
		local stale = _intersections[nodeId]
		if stale then
			stale:Destroy()
			_intersections[nodeId] = nil
		end
		-- The old cap survives until its replacement is built (swap below), so a build
		-- error can never strip a healthy bulb.
		local function dropOldCap()
			local oldCap = _caps[nodeId]
			if oldCap then
				oldCap:Destroy()
				_caps[nodeId] = nil
			end
		end
		-- A dead-end AT the map boundary is an outside connection: the road runs off the
		-- map, so skip the turnaround cap (it would hang out over the void). The segment
		-- slab already ends flush at the edge node.
		if isMapEdgeNode(node) then
			dropOldCap()
			return
		end
		local arms, segIds = armsAndSegsForNode(nodeId)
		local seg = segIds[1] and _network:getSegment(segIds[1])
		local spec = RoadTypeCatalog.getOrDefault(seg and seg.roadType)
		-- Terrain paths have no slab, so no turnaround bulb either -- the painted footprint just ends.
		if spec.terrainPath then
			dropOldCap()
			return
		end
		-- Clear room on the approach between this bulb and whatever the road runs into at its far end.
		local approachLen = math.huge
		if seg then
			local segLen = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, RoadConstants.SAMPLES_PER_SEGMENT)
			local otherNode = if seg.startNode == nodeId then seg.endNode else seg.startNode
			approachLen = segLen - endSetback(otherNode, nodeStyle(otherNode), seg.id)
		end
		-- The cap is ALWAYS rendered, however short the arm: the bulb is a disc drawn at the
		-- node (sunk below the slab, sidewalk arc on the outward half), so it needs no
		-- approach length, and the junction mouth can never pass the tip (reach is clamped
		-- to the segment midpoint). Suppressing it on short arms left roads ending in a raw
		-- flat cut right after an intersection. approachLen still feeds the renderer so the
		-- U-turn arrow pulls back or drops itself when the run is cramped.
		-- Wrap the bulb kerb only on the sides the road actually carries a sidewalk. The cap's
		-- left/right are as seen facing arms[1].dir (out along the road), so they match the
		-- segment's own kerbs when the bulb sits at its START and swap when it sits at its END.
		local swMode = spec.sidewalkMode or (if spec.noSidewalk then "none" else "both")
		local atStart = seg ~= nil and seg.startNode == nodeId
		local hasRight = swMode == "both" or swMode == "right"
		local hasLeft = swMode == "both" or swMode == "left"
		if arms[1] then
			local okCap, capOrErr = xpcall(function()
				return DeadEndRenderer.build(node.position, arms[1].dir, _roadsFolder, {
					approachLength = approachLen,
					width = spec.width,
					carriagewayWidth = RoadTypeCatalog.carriagewayWidth(spec),
					laneCount = spec.laneCount,
					oneWay = spec.oneWay,
					surfaceColor = spec.surfaceColor,
					markingColor = RoadConstants.MARKING_WHITE,
					edgeLineColor = spec.edgeLineColor,
					edgeLineWidth = spec.edgeLineWidth,
					sidewalk = not spec.noSidewalk,
					groundSkirt = RoadConstants.GROUND_SKIRT,
					sidewalkRight = if atStart then hasRight else hasLeft,
					sidewalkLeft = if atStart then hasLeft else hasRight,
					anchored = true,
					canCollide = true,
				})
			end, debug.traceback)
			if not okCap then
				warn(`[RoadSceneRenderer] dead-end cap failed for node {nodeId} -- keeping previous visual: {capOrErr}`)
				return
			end
			dropOldCap()
			local cap = capOrErr :: Model
			cap.Name = `DeadEnd_{nodeId}`
			_caps[nodeId] = cap
			-- Tunnel dead end: wrap the retaining wall around the turnaround bulb and
			-- cut the bulb's disc out of the terrain (the segment's own grade stops at
			-- the node, which left the cap buried). Reuses the conn: owner key -- a
			-- node is one style at a time and refreshNode ungrades it first.
			if seg and (seg :: any).vMode == "Tunnel" then
				local outDir = -arms[1].dir
				addDeadEndTunnelWalls(cap, node.position, outDir, spec.width)
				if workspace:GetAttribute("RoadGradeTerrain") ~= false then
					local flat = Vector3.new(outDir.X, 0, outDir.Z)
					if flat.Magnitude > 1e-4 then
						-- Near-point stub: the cut bed radius around it digs the disc.
						local tip = node.position + flat.Unit
						_gradeConnector(nodeId, node.position, node.position, tip, tip, spec.width, true, (if spec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH))
					end
				end
			end
		else
			dropOldCap()
		end
		return
	elseif style ~= "corner" and style ~= "intersection" and style ~= "merge" then
		local stale = _intersections[nodeId]
		if stale then
			stale:Destroy()
			_intersections[nodeId] = nil
		end
		local staleCap = _caps[nodeId]
		if staleCap then
			staleCap:Destroy()
			_caps[nodeId] = nil
		end
		return
	end

	-- Swap AFTER building: the stale cap/fill survive until the replacement exists, so a
	-- build error keeps the junction visually intact instead of leaving a hole.
	local function swapIn(model: Model)
		local cap = _caps[nodeId]
		if cap then
			cap:Destroy()
			_caps[nodeId] = nil
		end
		local old = _intersections[nodeId]
		if old then
			old:Destroy()
		end
		_intersections[nodeId] = model
	end
	local arms, segIds = armsAndSegsForNode(nodeId)

	if style == "merge" then
		local branchId, hostId = mergeBranch(arms, segIds, nodeId)
		local branch = branchId and _network:getSegment(branchId)
		local host = hostId and _network:getSegment(hostId)
		if not branch or not host then return end
		local okT, taperOrErr = xpcall(buildMergeTaper, debug.traceback, nodeId, branch, host, mergeSep(nodeId, branch, host))
		if not okT then
			warn(`[RoadSceneRenderer] merge taper failed for node {nodeId} -- keeping previous visual: {taperOrErr}`)
			return
		end
		local taper = taperOrErr :: Model
		taper.Name = `Junction_{nodeId}`
		swapIn(taper)
		return
	end

	local bestRealSeg: Types.Segment? = nil
	local bestWidth = -1
	for _, sid in node.segments do
		local s = _network:getSegment(sid)
		if s and not s.isArc then
			local w = RoadTypeCatalog.getOrDefault(s.roadType).width
			if w > bestWidth then
				bestWidth = w
				bestRealSeg = s
			end
		end
	end
	local spec = RoadTypeCatalog.getOrDefault(bestRealSeg and bestRealSeg.roadType)

	if style == "corner" and #arms == 2 and #segIds == 2 then

		local reach0 = nodeArmBoundary(nodeId, segIds[1])
		local reach1 = nodeArmBoundary(nodeId, segIds[2])
		local lift = Vector3.new(0, RoadConstants.ZFIGHT_OFFSET * 2, 0)

		local startSeg = _network:getSegment(segIds[1])
		local endSeg = _network:getSegment(segIds[2])
		local startSpec = RoadTypeCatalog.getOrDefault(startSeg and startSeg.roadType)
		local endSpec = RoadTypeCatalog.getOrDefault(endSeg and endSeg.roadType)
		-- Connector matches the NARROWER arm regardless of segId order. Using the
		-- widest arm funneled a wide connector over the narrow arm (small->big notch).
		local connSpec = if startSpec.width <= endSpec.width then startSpec else endSpec

		-- Anchor the connector to where each arm's surface is ACTUALLY trimmed -- its point
		-- and tangent at `reach` arc-length from the node -- not a straight guess off the node
		-- tangent. They match on straight, flat roads (those corners are unchanged); on curved
		-- or graded approaches the old guess floated off the trimmed end, so the turn and any
		-- slope failed to line up.
		local p0: Vector3
		local awayStart: Vector3
		local p3: Vector3
		local awayEnd: Vector3
		if startSeg and endSeg then
			p0, awayStart = segFrameFromNode(startSeg, nodeId, reach0)
			p3, awayEnd = segFrameFromNode(endSeg, nodeId, reach1)
		else
			p0, awayStart = node.position + arms[1].dir * reach0, arms[1].dir
			p3, awayEnd = node.position + arms[2].dir * reach1, arms[2].dir
		end
		p0 += lift
		p3 += lift
		local inDir = -awayStart -- connector leaves p0 heading back toward the node
		local outDir = awayEnd -- and continues outward along the far arm at p3
		local angle = math.acos(math.clamp(inDir:Dot(outDir), -1, 1))
		local chord = (p3 - p0).Magnitude
		-- Cubic handle that reproduces a circular arc of this chord and turn angle, so the
		-- bend keeps even curvature and constant width from end to end. For a symmetric
		-- straight corner this equals the previous reach/tangent handle exactly.
		local handle = if angle < 1e-3
			then chord / 3
			else (2 / 3) * chord * math.tan(angle * 0.25) / math.max(math.sin(angle * 0.5), 1e-3)
		local c1 = p0 + inDir * handle
		local c2 = p3 - outDir * handle
		-- Same elevation-driven guardrail as the straight segments, so the rail carries
		-- through the corner instead of leaving a gap where two roads meet.
		local cOn = barrierFor(maxDeckHeight(p0, c1, c2, p3), connSpec)
		local ringInnerRight: boolean? = nil
		if startSeg and endSeg and startSeg.isRoundabout and endSeg.isRoundabout and startSeg.roundaboutCenter then
			ringInnerRight = ringInnerIsRight(startSeg.roundaboutCenter, p0, p3, BezierUtil.point(p0, c1, c2, p3, 0.5))
		end
		local okCorner, cornerOrErr = xpcall(function()
			return RoadRenderer.build(
			p0,
			c1,
			c2,
			p3,
			_roadsFolder,
			{
				color = connSpec.surfaceColor,
				anchored = true,
				canCollide = true,

				width = connSpec.width,
				centerLineColor = connSpec.centerLineColor,
				centerLineWidth = connSpec.centerLineWidth,
				centerLineDashed = connSpec.centerLineDashed,
				centerLineDouble = connSpec.centerLineDouble,
				edgeLineColor = connSpec.edgeLineColor,
				edgeLineColorLeft = connSpec.edgeLineColorLeft,
				edgeLineWidth = connSpec.edgeLineWidth,
				edgeLinePlus = if ringInnerRight == true then false else nil,
				edgeLineMinus = if ringInnerRight == false then false else nil,
				laneLineColor = if ringInnerRight == nil then connSpec.laneLineColor else nil,
				laneLineWidth = connSpec.laneLineWidth,
				laneOffsets = laneOffsetsForSpec(connSpec),

				sidewalk = (not startSpec.noSidewalk) and (not endSpec.noSidewalk),
				groundSkirt = RoadConstants.GROUND_SKIRT,
				carriagewayWidth = RoadTypeCatalog.carriagewayWidth(connSpec),
				parkingLane = connSpec.parkingLane,
				parkingLaneWidth = connSpec.parkingLaneWidth,
				parkingSides = connSpec.parkingSides,
				parkingSide = connSpec.parkingSide,
				parkingApronColor = connSpec.surfaceColor,
				median = connSpec.median,
				medianWidth = connSpec.medianWidth,
				medianColor = connSpec.medianColor,
				sidewalkMode = if ringInnerRight == nil then connSpec.sidewalkMode elseif ringInnerRight then "left" else "right",
				vergeMode = connSpec.vergeMode,
				vergeWidth = connSpec.vergeWidth,
				guardrail = cOn,
			}
		)
		end, debug.traceback)
		if not okCorner then
			warn(`[RoadSceneRenderer] corner build failed for node {nodeId} -- keeping previous visual: {cornerOrErr}`)
			return
		end
		local model = cornerOrErr :: Model
		model.Name = `Corner_{nodeId}`
		swapIn(model)
		-- The connector is render-only; grade the ground under its arc so a steep bend
		-- doesn't poke natural terrain up through the road surface. Ring corner nodes
		-- are skipped: the flat ring arcs already grade the area, and the extra little
		-- per-node carves only scatter shave-marks around the roundabout.
		local isRingNode = _network.isRoundaboutNode ~= nil and _network:isRoundaboutNode(nodeId)
		local bothTunnel = startSeg ~= nil and endSeg ~= nil
			and (startSeg :: any).vMode == "Tunnel" and (endSeg :: any).vMode == "Tunnel"
		-- The bend carries the roads' retaining walls round it (when both roads are built the
		-- same way), so a walled cut or fill doesn't break open at every bend.
		local wallMode: string? = nil
		if startSeg and endSeg and not isRingNode
			and RoadCrossSection.takesWalls(RoadTypeCatalog.getOrDefault((startSeg :: any).roadType), startSeg)
			and RoadCrossSection.takesWalls(RoadTypeCatalog.getOrDefault((endSeg :: any).roadType), endSeg)
			and ((startSeg :: any).vMode or "Ground") == ((endSeg :: any).vMode or "Ground") then
			wallMode = (startSeg :: any).vMode or "Ground"
		end
		if wallMode then
			addRetainingWalls(model, p0, c1, c2, p3, connSpec, wallMode, 0, 0)
		end
		if workspace:GetAttribute("RoadGradeTerrain") ~= false and not isRingNode then
			_gradeConnector(nodeId, p0, c1, c2, p3, connSpec.width, bothTunnel, (if connSpec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH), wallMode)
		end
		return
	end

	-- Sidewalk is decided per CORNER inside IntersectionRenderer, from each arm's own
	-- swLeft/swRight: a corner is kerbed when either of the two sides it joins has a
	-- sidewalk, so one bare approach (alley, highway) no longer strips the kerbs off the
	-- corners it isn't part of -- the ones it does touch curve round and stop at its mouth.
	local anyArmWantsSidewalk = false
	for _, a in arms do
		if a.swLeft or a.swRight then
			anyArmWantsSidewalk = true
			break
		end
	end

	local intersectionMarkingColor: Color3? = nil
	for _, sid in node.segments do
		local s = _network:getSegment(sid)
		if s and not s.isArc then
			local armSpec = RoadTypeCatalog.getOrDefault(s.roadType)
			if armSpec.edgeLineColor then
				intersectionMarkingColor = armSpec.edgeLineColor
				break
			end
		end
	end
	-- Anchor every arm to its segment's real surface at the trim distance (fillet plus
	-- any steep-approach apron extension), so the box junction meets curved and graded
	-- approaches exactly instead of extrapolating a straight line from the node tangent.
	for i, sid in segIds do
		local s = _network:getSegment(sid)
		local reach = if s then armJunctionBoundary(nodeId, sid) else nil
		if s and reach and reach > 0 then
			local mouthPos, mouthTan = segFrameFromNode(s, nodeId, reach)
			arms[i].reach = reach
			arms[i].mouthPos = mouthPos
			arms[i].mouthTan = mouthTan
			arms[i].profile = segHeightProfileFromNode(s, nodeId, reach)
		end
	end

	local okJ, junctionOrErr = xpcall(function()
		return IntersectionRenderer.build(node.position, arms, _roadsFolder, {
			surfaceColor = spec.surfaceColor,
			markingColor = intersectionMarkingColor,
			anchored = true,
			canCollide = true,
			shape = "box",
			sidewalk = anyArmWantsSidewalk,
			groundSkirt = RoadConstants.GROUND_SKIRT,
			setback = nodeMarkingSetback(nodeId),
			edgeLineWidth = spec.edgeLineWidth,
		})
	end, debug.traceback)
	if not okJ then
		warn(`[RoadSceneRenderer] junction build failed for node {nodeId} -- keeping previous visual: {junctionOrErr}`)
		return
	end
	local model = junctionOrErr :: Model
	model.Name = `Junction_{nodeId}`
	swapIn(model)
end

rerenderIntersectionApproaches = function(nodeId: Types.NodeId)
	local node = _network:getNodes()[nodeId]
	if not node then
		return
	end
	for _, sid in node.segments do
		local seg = _network:getSegment(sid)
		if seg then
			renderSegment(seg)
		end
	end
	refreshNode(nodeId)
end

export type Deps = {
	getSurfaceY: (number, number) -> number,
	gradeConnector: ((any, Vector3, Vector3, Vector3, Vector3, number, boolean?, number?, string?) -> ())?,
	ungradeConnector: ((any) -> ())?,
}

function RoadSceneRenderer.init(network: any, navGraph: any, deps: Deps?)
	_network = network
	_navGraph = navGraph
	if deps then
		_getSurfaceY = deps.getSurfaceY
		_gradeConnector = deps.gradeConnector or function() end
		_ungradeConnector = deps.ungradeConnector or function() end
	end

	local cityFolder = workspace:FindFirstChild("_City")
	if not cityFolder then
		cityFolder = Instance.new("Folder")
		cityFolder.Name = "_City"
		cityFolder.Parent = workspace
	end
	local roads = cityFolder:FindFirstChild("Roads")
	if not roads then
		roads = Instance.new("Folder")
		roads.Name = "Roads"
		roads.Parent = cityFolder
	end
	_roadsFolder = roads :: Folder

	-- Road models have no PrimaryPart, so under StreamingEnabled their parts would stream
	-- in independently and leave gaps in the pavement at the streaming frontier. Atomic =
	-- the whole segment/junction/connector streams as one unit. Inert when streaming is off.
	local function makeAtomic(child: Instance)
		if child:IsA("Model") then
			child.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		end
	end
	for _, child in (roads :: Folder):GetChildren() do makeAtomic(child) end
	(roads :: Folder).ChildAdded:Connect(makeAtomic)


end

-- == Roundabout centre ====================================================================
-- Everything inside the ring and at its mouths, built as ONE road piece (mesh data, like every
-- other piece -- no Parts): the brick truck apron with its kerbs, the island, the ring's
-- inner edge line and lane dividers as unbroken circles (the ring arcs leave those out, so
-- they no longer stop at every arm), and a kerbed brick splitter island at each two-way arm.
-- The island itself shows the roundabout's centre preset.

local RING_POINT_SPACING = 2 -- studs between points around a circle
local KERB_SKIRT = 0.3 -- kerb faces reach this far under the surface they stand on

local function circlePts(center: Vector3, r: number, y: number, n: number): { Vector3 }
	local pts = table.create(n + 1)
	for i = 0, n do
		local a = (i % n) / n * 2 * math.pi
		pts[i + 1] = Vector3.new(center.X + r * math.cos(a), y, center.Z + r * math.sin(a))
	end
	return pts
end

local function circleCount(r: number): number
	return math.clamp(math.ceil(2 * math.pi * r / RING_POINT_SPACING), 24, 720)
end

-- A raised kerb band between two radii: its top plus both faces (the junction kerb recipe).
local function addKerbRing(builder: any, center: Vector3, rIn: number, rOut: number, yBase: number, yTop: number, color: Color3)
	if rOut - rIn <= 0.05 or rIn < 0 then return end
	local n = circleCount(rOut)
	local inT, outT = circlePts(center, rIn, yTop, n), circlePts(center, rOut, yTop, n)
	builder:addSurfaceStrip(inT, outT, color, yTop - yBase + KERB_SKIRT)
	builder:addSurfaceStrip(circlePts(center, rIn, yBase - KERB_SKIRT, n), inT, color, 0.05)
	builder:addSurfaceStrip(outT, circlePts(center, rOut, yBase - KERB_SKIRT, n), color, 0.05)
end

-- A painted circle. Dashed ones are laid dash by dash, as solid pieces, with the spacing
-- stretched so a whole number of dashes goes round: no half dash where the circle closes.
local function addCircleMarking(builder: any, center: Vector3, r: number, y: number, width: number, color: Color3, dashed: boolean)
	if r <= width then return end
	if not dashed then
		builder:addMarkingLine(circlePts(center, r, y, circleCount(r)), width, color, false)
		return
	end
	local circumference = 2 * math.pi * r
	local pitch = RoadConstants.ROUNDABOUT_DASH_LENGTH + RoadConstants.ROUNDABOUT_DASH_GAP
	local count = math.max(1, math.floor(circumference / pitch + 0.5))
	local step = circumference / count
	local dash = math.min(RoadConstants.ROUNDABOUT_DASH_LENGTH, step * 0.5)
	local pieces = math.max(1, math.ceil(dash / 1.5))
	for i = 0, count - 1 do
		local a0 = i * step / r
		local pts = table.create(pieces + 1)
		for k = 0, pieces do
			local a = a0 + (dash / r) * (k / pieces)
			pts[k + 1] = Vector3.new(center.X + r * math.cos(a), y, center.Z + r * math.sin(a))
		end
		builder:addMarkingLine(pts, width, color, false)
	end
end

-- Splitter island at one arm: the kerbed brick island between the arm's entry and exit,
-- where a real roundabout deflects the traffic. Its outline is found, not drawn: every path a
-- car takes through this mouth (the arm's lanes, and the lane graph's connectors between them
-- and the ring) keeps SPLITTER_CLEARANCE of kerb-free road either side of its centreline, and
-- the island fills what is left between the entry and the exit, tapering to a nose up the arm.
-- An arm with nothing free down its middle (a one-way arm, a road too narrow) gets none.
local SPLITTER_STEP = 0.5
local function addSplitterIsland(builder: any, nodeId: number, arm: any, ringHalfCW: number, roadTop: number)
	local g = _navGraph
	local node = _network:getNodes()[nodeId]
	if not g or not node or not g._edgesByToNode then return end
	local origin = node.position
	local u = if arm.startNode == nodeId then arm.p1 - arm.p0 else arm.p2 - arm.p3
	u = Vector3.new(u.X, 0, u.Z)
	if u.Magnitude < 1e-3 then return end
	u = u.Unit
	local v = u:Cross(Vector3.yAxis) -- right, looking out along the arm

	local clear = RoadConstants.ROUNDABOUT_SPLITTER_CLEARANCE
	local maxLen = RoadConstants.ROUNDABOUT_SPLITTER_MAX_LENGTH
	local s0 = ringHalfCW + 0.5 -- never out into the circulating carriageway
	local nSt = math.floor(maxLen / SPLITTER_STEP)
	-- Every path point near the mouth, in (s, t) = (out along the arm, to its right).
	local pts: { Vector2 } = {}
	-- `from`/`to`: the stretch of the polyline, by arc length, that a car actually drives.
	local function addPolyline(poly: { Vector3 }, from: number?, to: number?)
		local d = 0
		for i = 1, #poly do
			local a = poly[i]
			local b = poly[math.min(i + 1, #poly)]
			local len = (b - a).Magnitude
			local pieces = math.max(1, math.ceil(len / SPLITTER_STEP))
			for k = 0, (if i == #poly then 0 else pieces - 1) do
				local at = d + len * (k / pieces)
				if (from and at < from) or (to and at > to) then continue end
				local p = a + (b - a) * (k / pieces) - origin
				local s, t = p:Dot(u), p:Dot(v)
				if s > s0 - clear and s < s0 + maxLen + clear and math.abs(t) < maxLen then
					table.insert(pts, Vector2.new(s, t))
				end
			end
			d += len
		end
	end
	local function lengthOf(poly: { Vector3 }): number
		local d = 0
		for i = 2, #poly do d += (poly[i] - poly[i - 1]).Magnitude end
		return d
	end
	-- Each movement through the mouth: the approach lane up to where the car hands off to
	-- the connector, the connector, and the exit lane from where it takes over again. A lane
	-- drawn on to the node is not driven past its hand-off, and counting it walled the
	-- middle of the mouth off to a strip one lane-gap wide.
	for _, e in g._edgesByToNode[nodeId] or {} do
		local ePts = e.points or {}
		local eLen = lengthOf(ePts)
		for _, outId in e.out or {} do
			local out = g:GetEdge(outId)
			local fromSetback, toSetback = g:GetConnectionSetbacks(e.id, outId)
			addPolyline(ePts, nil, eLen - fromSetback)
			addPolyline((g:GetConnectionPoints(e.id, outId)))
			if out then addPolyline(out.points or {}, toSetback, nil) end
		end
	end
	if #pts == 0 then return end

	local armSpec = RoadTypeCatalog.getOrDefault(arm.roadType)
	local tCap = RoadTypeCatalog.carriagewayWidth(armSpec) * 0.5 - 0.5
	-- Free interval round t = 0 at each station.
	local lo, hi = table.create(nSt + 1, 0), table.create(nSt + 1, 0)
	local ok = table.create(nSt + 1, false)
	for i = 0, nSt do
		local s = s0 + i * SPLITTER_STEP
		local l, h = -tCap, tCap
		local blocked = false
		for _, p in pts do
			local ds = p.X - s
			if ds > -clear and ds < clear then
				local w = math.sqrt(clear * clear - ds * ds)
				local a, b = p.Y - w, p.Y + w
				if a <= 0 and b >= 0 then
					blocked = true
					break
				end
				if b < 0 then
					l = math.max(l, b)
				elseif a > 0 then
					h = math.min(h, a)
				end
			end
		end
		lo[i + 1], hi[i + 1] = l, h
		ok[i + 1] = not blocked and h - l >= RoadConstants.ROUNDABOUT_SPLITTER_MIN_WIDTH
	end
	-- The island is the first free run out from the ring.
	local first: number? = nil
	for i = 1, nSt + 1 do
		if ok[i] then
			first = i
			break
		end
		if (i - 1) * SPLITTER_STEP > clear * 2 then break end -- nothing free near the ring
	end
	if not first then return end
	local last = first
	while last + 1 <= nSt + 1 and ok[last + 1] do last += 1 end
	-- The free space is a triangle while the entry and exit paths spread apart, then a strip
	-- one lane-gap wide where the arm's lanes run straight. Keep the triangle and finish it
	-- with a short nose: a splitter, not a median running on up the road.
	local narrowest = math.huge
	for i = first, last do narrowest = math.min(narrowest, hi[i] - lo[i]) end
	local noseAt = last
	for i = first, last do
		if hi[i] - lo[i] <= narrowest * 1.1 + 0.05 then
			noseAt = i
			break
		end
	end
	local noseLen = math.clamp(narrowest * 1.5, 2, 6)
	last = math.min(last, noseAt + math.floor(noseLen / SPLITTER_STEP))
	if (last - first) * SPLITTER_STEP < 4 then return end
	local noseHalf = (hi[noseAt] - lo[noseAt]) * 0.5
	local left: { Vector3 } = {}
	local right: { Vector3 } = {}
	local count = last - first
	local rRound = math.min(1.2, (hi[first] - lo[first]) * 0.25)
	for i = first, last do
		local d = (i - first) * SPLITTER_STEP
		local mid = (lo[i] + hi[i]) * 0.5
		local half = (hi[i] - lo[i]) * 0.5
		if i > noseAt then
			half = math.min(half, noseHalf * (1 - (i - noseAt) / math.max(1, last - noseAt)))
		end
		if d < rRound then -- round off the corners facing the ring
			local x = (rRound - d) / rRound
			half = math.max(0, half - rRound * (1 - math.sqrt(math.max(0, 1 - x * x))))
		end
		half = math.max(half, 0)
		local c = origin + u * (s0 + (i - 1) * SPLITTER_STEP) + v * mid
		table.insert(left, c - v * half)
		table.insert(right, c + v * half)
	end
	if count < 2 then return end
	-- Kerb all round, brick inside it, faces down to the road.
	local kerbW = RoadConstants.ROUNDABOUT_KERB_WIDTH * 0.5
	local top = roadTop + RoadConstants.SIDEWALK_HEIGHT
	local function lift(list: { Vector3 }, y: number): { Vector3 }
		local out = table.create(#list)
		for k, p in list do out[k] = Vector3.new(p.X, y, p.Z) end
		return out
	end
	local lT, rT = lift(left, top), lift(right, top)
	builder:addSurfaceStrip(lT, rT, RoadConstants.ROUNDABOUT_ISLAND_CURB_COLOR, RoadConstants.SIDEWALK_HEIGHT + KERB_SKIRT)
	local inL, inR = table.create(#left), table.create(#left)
	for k = 1, #left do
		local c = (left[k] + right[k]) * 0.5
		local half = (right[k] - left[k]).Magnitude * 0.5
		local inset = math.max(0, half - kerbW)
		local dir = if half > 1e-4 then (right[k] - left[k]).Unit else v
		inL[k] = Vector3.new(c.X, top + 0.02, c.Z) - dir * inset
		inR[k] = Vector3.new(c.X, top + 0.02, c.Z) + dir * inset
	end
	builder:addSurfaceStrip(inL, inR, RoadConstants.ROUNDABOUT_APRON_COLOR, 0.05)
	builder:addSurfaceStrip(lift(left, roadTop - KERB_SKIRT), lT, RoadConstants.ROUNDABOUT_ISLAND_CURB_COLOR, 0.05)
	builder:addSurfaceStrip(rT, lift(right, roadTop - KERB_SKIRT), RoadConstants.ROUNDABOUT_ISLAND_CURB_COLOR, 0.05)
	-- White edge lines down both long sides, just off the kerb: the entry and exit lanes'
	-- inner edges, carried round the island.
	local armSpec2 = RoadTypeCatalog.getOrDefault(arm.roadType)
	local ew = armSpec2.edgeLineWidth or 0.4
	local lineY = roadTop + RoadConstants.ZFIGHT_OFFSET * 3
	for _, side in { { left, -1 }, { right, 1 } } do
		local rail, sign = side[1], side[2]
		local line: { Vector3 } = {}
		for k = 1, #rail do
			local c = (left[k] + right[k]) * 0.5
			local d = rail[k] - c
			local dir = if d.Magnitude > 1e-3 then d.Unit else v * sign
			local p = rail[k] + dir * (ew * 0.5 + 0.35)
			table.insert(line, Vector3.new(p.X, lineY, p.Z))
		end
		if #line >= 2 then
			builder:addMarkingLine(line, ew, armSpec2.edgeLineColor or RoadConstants.MARKING_WHITE, false)
		end
	end
end

-- Centre presets, planted from the Nature models (server only: the clones replicate).
local function natureTemplate(key: string): Model?
	local folder = ReplicatedStorage:FindFirstChild("Nature")
	local t = folder and folder:FindFirstChild(key)
	return if t and t:IsA("Model") then t else nil
end

-- One Nature model on the island, scaled so its footprint is about `width` studs across.
local function plantCentreModel(model: Model, key: string, pos: Vector3, width: number, yaw: number)
	local template = natureTemplate(key)
	if not template then
		warn(`[RoadSceneRenderer] no Nature.{key} model -- that part of the roundabout centre is not placed`)
		return
	end
	local clone = template:Clone()
	local ext = clone:GetExtentsSize()
	local foot = math.max(ext.X, ext.Z, 0.1)
	local base = clone:GetScale()
	clone:ScaleTo(base * math.clamp(width / foot, 0.4, 6))
	clone:PivotTo(CFrame.new(pos) * CFrame.Angles(0, yaw, 0))
	clone.Name = `Centre_{key}`
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	clone.Parent = model
end

local FOUNTAIN_STONE = RoadConstants.ROUNDABOUT_ISLAND_CURB_COLOR
local FOUNTAIN_WATER = Color3.fromRGB(78, 138, 176)

-- The island's own surface plus whatever the preset puts on it. Mesh parts go into `builder`;
-- planted models are parented to `model` after the bake.
local function addCentrePreset(builder: any, center: Vector3, rIsland: number, surfaceY: number, preset: string, elevated: boolean)
	local plants: { { key: string, pos: Vector3, width: number, yaw: number } } = {}
	local function plant(key: string, pos: Vector3, width: number, yaw: number)
		table.insert(plants, { key = key, pos = pos, width = width, yaw = yaw })
	end
	local function ring(key: string, r: number, count: number, width: number, phase: number)
		for i = 0, count - 1 do
			local a = phase + i * 2 * math.pi / count
			plant(key, center + Vector3.new(r * math.cos(a), 0, r * math.sin(a)) + Vector3.new(0, surfaceY - center.Y, 0), width, a)
		end
	end
	local mid = Vector3.new(center.X, surfaceY, center.Z)
	-- Grass everywhere (paved on an elevated deck, where nothing grows).
	builder:addFan(mid, circlePts(center, rIsland, surfaceY, circleCount(rIsland)), RoadConstants.SIDEWALK_HEIGHT + KERB_SKIRT,
		if elevated then RoadConstants.ROUNDABOUT_ISLAND_CURB_COLOR else RoadConstants.ROUNDABOUT_ISLAND_COLOR)
	if preset == "Tree" then
		-- One big tree whose crown fills the island.
		plant("OakTree", mid, math.min(rIsland * 1.75, 90), 0.7)
	elseif preset == "Garden" then
		plant("CherryTree", mid, math.min(rIsland * 0.6, 30), 0.3)
		ring("HedgeSphere", rIsland * 0.45, math.clamp(math.floor(rIsland / 5), 6, 24), 3.5, 0)
		ring("FlowerBushPink", rIsland * 0.62, math.clamp(math.floor(rIsland / 3.5), 8, 36), 3, 0.1)
		ring("FlowerBushYellow", rIsland * 0.78, math.clamp(math.floor(rIsland / 3), 10, 44), 3, 0.25)
		ring("FlowerBush", rIsland * 0.9, math.clamp(math.floor(rIsland / 2.6), 12, 52), 3, 0.05)
	elseif preset == "Palms" then
		local n = if rIsland < 25 then 3 else 5
		plant("CoconutPalm", mid, math.min(rIsland * 0.45, 22), 0)
		ring("FloridaPalm", rIsland * 0.55, n, math.min(rIsland * 0.35, 18), 0.4)
		ring("BushRound", rIsland * 0.85, math.clamp(math.floor(rIsland / 4), 8, 36), 3, 0)
	elseif preset == "Fountain" then
		-- A round basin: stone rim, water, and a stone pedestal in the middle.
		local rBasin = math.clamp(rIsland * 0.55, 6, 40)
		local rimW = math.max(1, rBasin * 0.08)
		local rimTop = surfaceY + math.max(1, rBasin * 0.08)
		local waterY = rimTop - 0.4
		addKerbRing(builder, center, rBasin - rimW, rBasin, surfaceY, rimTop, FOUNTAIN_STONE)
		builder:addFan(Vector3.new(center.X, waterY, center.Z), circlePts(center, rBasin - rimW, waterY, circleCount(rBasin)), 0.3, FOUNTAIN_WATER)
		local rPed = math.max(1, rBasin * 0.18)
		local pedTop = rimTop + math.max(2, rBasin * 0.35)
		addKerbRing(builder, center, 0.01, rPed, waterY, pedTop, FOUNTAIN_STONE)
		builder:addFan(Vector3.new(center.X, pedTop, center.Z), circlePts(center, rPed, pedTop, circleCount(rPed)), 0.3, FOUNTAIN_STONE)
		local rBowl = rPed * 2.2
		local bowlY = pedTop - 0.2
		addKerbRing(builder, center, rBowl - 0.6, rBowl, bowlY - 0.8, bowlY, FOUNTAIN_STONE)
		builder:addFan(Vector3.new(center.X, bowlY - 0.3, center.Z), circlePts(center, rBowl - 0.6, bowlY - 0.3, circleCount(rBowl)), 0.3, FOUNTAIN_WATER)
		ring("BushRound", (rBasin + rIsland) * 0.5, math.clamp(math.floor(rIsland / 4), 8, 36), 3, 0)
	end
	return plants
end

local function presetOf(p: any): string
	for _, k in RoadConstants.ROUNDABOUT_CENTRE_PRESETS do
		if p == k then return k end
	end
	return "Empty"
end

local function buildRoundaboutCentre(raId: number, center: Vector3, radius: number, roadType: string, preset: string): Model?
	local spec = RoadTypeCatalog.getOrDefault(roadType)
	local cw = RoadTypeCatalog.carriagewayWidth(spec)
	local laneW = cw / math.max(1, spec.laneCount)
	local roadTop = center.Y + RoadConstants.ROAD_THICKNESS * 0.5
	local rCI, rCO = radius - cw * 0.5, radius + cw * 0.5
	local edgeW = RoadConstants.ROUNDABOUT_APRON_EDGE_WIDTH
	local rApron = rCI - math.clamp(rCI * 0.2, 2.5, RoadConstants.ROUNDABOUT_APRON_WIDTH)
	local rIsland = rApron - RoadConstants.ROUNDABOUT_KERB_WIDTH
	local apronTop = roadTop + RoadConstants.ROUNDABOUT_APRON_RISE
	local kerbTop = roadTop + RoadConstants.SIDEWALK_HEIGHT

	-- On an elevated deck there's no ground to plant: the island is paved.
	local groundY = RoadConstants.getGroundY()
	local okH, h = pcall(_getSurfaceY, center.X, center.Z)
	if okH then groundY = h end
	local elevated = (center.Y - groundY) > RoadConstants.ELEVATED_PILLAR_MIN_HEIGHT

	local builder = RoadMeshBuilder.new()
	-- Asphalt under the whole circulating carriageway, a hair below the ring's own surface:
	-- invisible where the arcs cover it, plain road in the wedges a junction's straight-sided
	-- fill leaves against the circle.
	local n = circleCount(rCO)
	builder:addSurfaceStrip(circlePts(center, math.max(0.5, rApron), roadTop - 0.03, n), circlePts(center, rCO, roadTop - 0.03, n),
		RoadConstants.ROAD_COLOR, RoadConstants.ROAD_THICKNESS)
	-- Truck apron: brick, with a light mountable kerb band against the carriageway.
	if rApron > 1 then
		local na = circleCount(rCI)
		builder:addSurfaceStrip(circlePts(center, rApron, apronTop, na), circlePts(center, rCI - edgeW, apronTop, na),
			RoadConstants.ROUNDABOUT_APRON_COLOR, RoadConstants.ROUNDABOUT_APRON_RISE + KERB_SKIRT)
		addKerbRing(builder, center, rCI - edgeW, rCI, roadTop, apronTop + 0.02, RoadConstants.ROUNDABOUT_ISLAND_CURB_COLOR)
	end
	-- Island kerb, then the island.
	local plants = {}
	if rIsland > 1 then
		addKerbRing(builder, center, rIsland, rApron, apronTop, kerbTop, RoadConstants.ROUNDABOUT_ISLAND_CURB_COLOR)
		plants = addCentrePreset(builder, center, rIsland, kerbTop - 0.1, if elevated then "Empty" else preset, elevated)
	end
	-- The ring's inner edge line and lane dividers, unbroken through every arm.
	local lineY = roadTop + RoadConstants.ZFIGHT_OFFSET * 3
	if spec.edgeLineColor then
		local ew = spec.edgeLineWidth or 0.4
		addCircleMarking(builder, center, rCI + ew * 0.5 + 0.05, lineY, ew, spec.edgeLineColor, false)
	end
	if spec.laneLineColor then
		for k = 1, spec.laneCount - 1 do
			addCircleMarking(builder, center, rCI + k * laneW, lineY, spec.laneLineWidth or 0.3, spec.laneLineColor, spec.laneLineDashed == true)
		end
	end
	-- Splitter islands at the arms.
	for _, seg in _network:getSegments() do
		if seg.isRoundabout and seg.roundaboutId == raId then
			for _, nid in { seg.startNode, seg.endNode } do
				local node = _network:getNodes()[nid]
				for _, sid in (node and node.segments or {}) do
					local arm = _network:getSegment(sid)
					-- Each arm once: from the ring arc that STARTS at its node.
					if arm and not arm.isRoundabout and nid == seg.startNode then
						local okS, err = pcall(addSplitterIsland, builder, nid, arm, cw * 0.5, roadTop)
						if not okS then warn(`[RoadSceneRenderer] splitter island at node {nid} failed: {err}`) end
					end
				end
			end
		end
	end

	local model = builder:bake({
		name = `Roundabout_{raId}`,
		anchored = true,
		canCollide = true,
	})
	if not model then return nil end
	model.Name = `Roundabout_{raId}`
	model:SetAttribute("RoundaboutId", raId)
	-- Rebuilt when any of these change (syncRoundabouts compares them).
	model:SetAttribute("RingType", roadType)
	model:SetAttribute("RingCenter", center)
	model:SetAttribute("CentrePreset", preset)
	if RunService:IsServer() then
		for _, p in plants do
			plantCentreModel(model, p.key, p.pos, p.width, p.yaw)
		end
	end
	model.Parent = _roadsFolder
	return model
end

local function activeRoundabouts(): { [number]: { center: Vector3, radius: number, roadType: string, preset: string } }
	local active = {}
	for _, seg in _network:getSegments() do
		if seg.isRoundabout and seg.roundaboutId and seg.roundaboutCenter and seg.roundaboutRadius then
			if not active[seg.roundaboutId] then
				active[seg.roundaboutId] = {
					center = seg.roundaboutCenter,
					radius = seg.roundaboutRadius,
					roadType = seg.roadType,
					preset = presetOf(seg.roundaboutPreset),
				}
			end
		end
	end
	return active
end

local function rebuildCentre(id: number, info: any)
	local old = _islands[id]
	local ok, modelOrErr = pcall(buildRoundaboutCentre, id, info.center, info.radius, info.roadType, info.preset)
	if not ok then
		warn(`[RoadSceneRenderer] roundabout {id} centre failed -- keeping previous visual: {modelOrErr}`)
		return
	end
	if old then old:Destroy() end
	_islands[id] = modelOrErr
end

-- Diff the live roundabouts against rendered centres: build new ones, drop stale.
function RoadSceneRenderer.syncRoundabouts()
	if not _network then return end
	local active = activeRoundabouts()
	for id, model in _islands do
		local info = active[id]
		local at = model:GetAttribute("RingCenter")
		if not info or model:GetAttribute("RingType") ~= info.roadType
			or model:GetAttribute("CentrePreset") ~= info.preset
			or typeof(at) ~= "Vector3" or (at - info.center).Magnitude > 0.05 then
			model:Destroy()
			_islands[id] = nil
		end
	end
	for id, info in active do
		if not _islands[id] then
			rebuildCentre(id, info)
		end
	end
end

-- The splitter islands are shaped by the lane graph, which is rebuilt AFTER the render pass
-- (RoadService.flushNavRebuild). Rebuild the centre of every roundabout one of these segments
-- touches -- a ring arc, or an arm at a ring node -- once the graph is current.
-- nil = every roundabout (after a full rebuild).
function RoadSceneRenderer.refreshRoundaboutsFor(segmentIds: { [number]: boolean }?)
	if not _network then return end
	if segmentIds == nil then
		for id, info in activeRoundabouts() do rebuildCentre(id, info) end
		return
	end
	local ids: { [number]: boolean } = {}
	local nodes = _network:getNodes()
	for sid in segmentIds do
		local seg = _network:getSegment(sid)
		if not seg then continue end
		if seg.isRoundabout and seg.roundaboutId then ids[seg.roundaboutId] = true end
		for _, nid in { seg.startNode, seg.endNode } do
			local node = nodes[nid]
			for _, other in (node and node.segments or {}) do
				local o = _network:getSegment(other)
				if o and o.isRoundabout and o.roundaboutId then ids[o.roundaboutId] = true end
			end
		end
	end
	if next(ids) == nil then return end
	local active = activeRoundabouts()
	for id in ids do
		local info = active[id]
		if info then rebuildCentre(id, info) end
	end
end

function RoadSceneRenderer.removeSegmentModel(id: Types.SegmentId)
	local m = _models[id]
	if m then
		m:Destroy()
		_models[id] = nil
	end
end

function RoadSceneRenderer.removeNodeVisuals(nodeId: Types.NodeId)
	_ungradeConnector(nodeId)
	_mergeSepCache[nodeId] = nil
	local cap = _caps[nodeId]
	if cap then
		cap:Destroy()
		_caps[nodeId] = nil
	end
	local inter = _intersections[nodeId]
	if inter then
		inter:Destroy()
		_intersections[nodeId] = nil
	end
end

-- Reconcile dead-end bulbs against the live graph: a cap survives only while its node is
-- still a one-arm dead end. Every other exit left the turnaround bulb (and its U-turn
-- arrows) stranded mid-road -- the node grew a second road, a corner/junction build failed
-- and returned early before swapIn, or the node vanished without a dead flag.
function RoadSceneRenderer.syncDeadEnds()
	if not _network then
		return
	end
	for nodeId, cap in _caps do
		if not _network:getNodes()[nodeId] or nodeStyle(nodeId) ~= "deadend" then
			cap:Destroy()
			_caps[nodeId] = nil
		end
	end
end

RoadSceneRenderer.renderSegment = renderSegment
RoadSceneRenderer.refreshNode = refreshNode
RoadSceneRenderer.rerenderIntersectionApproaches = rerenderIntersectionApproaches
RoadSceneRenderer.armMarkingSetback = armMarkingSetback
RoadSceneRenderer.armJunctionBoundary = armJunctionBoundary
RoadSceneRenderer.crosswalkSeat = crosswalkSeat

-- Surface trim renderSegment applies at nodeId's end of segId (0 at plain ends).
-- RoadService injects this into RoadNetwork.dissolveSwallowedArms so the graph can
-- drop nodes whose arm segment the junction mouth + far trim would swallow whole.
function RoadSceneRenderer.endSurfaceTrim(nodeId: Types.NodeId, segId: Types.SegmentId): number
	local style = nodeStyle(nodeId)
	if style == "intersection" then
		return armJunctionBoundary(nodeId, segId)
	elseif style == "corner" then
		return nodeArmBoundary(nodeId, segId)
	elseif style == "merge" then
		return mergeTrim(nodeId, segId)
	end
	return 0
end

return RoadSceneRenderer
