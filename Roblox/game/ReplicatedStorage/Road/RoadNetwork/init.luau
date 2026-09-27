--!strict

local RoadConstants = require(script.Parent.RoadConstants)
local BezierUtil = require(script.Parent.BezierUtil)
local RoadTypeCatalog = require(script.Parent.RoadTypeCatalog)
local RoadMoveGeometry = require(script.Parent.RoadMoveGeometry)
-- Pure corner geometry (armBoundaryDistances / connectorMinRadius); requiring it runs no
-- rendering -- it builds parts only when build() is called, which the validator never does.
local IntersectionRenderer = require(script.Parent.IntersectionRenderer)
local Types = require(script.Parent.RoadTypes)

type Node = Types.Node
type Segment = Types.Segment
type NodeId = Types.NodeId
type SegmentId = Types.SegmentId

local RoadNetwork = {}
RoadNetwork.__index = RoadNetwork

local CROSS_SAMPLES = 24

-- How far apart two segments between the same pair of nodes may run and still be the SAME
-- road stacked twice. A merge copies the path exactly (measured: 0.0000 over 275 stacked
-- pairs), so this is slack for float drift, not a similarity threshold.
local DUPLICATE_PATH_TOLERANCE = 1

-- Horizontal (XZ-plane) distance. Endpoint welding compares positions in the
-- ground plane and gates separately on height, so roads on different elevation
-- layers (a flyover over a surface street) are never welded together.
local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Which of two nodes survives a merge. HARD RULE: an intersection that is already there
-- NEVER moves because a road connected to it. Node ids only ever increase, so between
-- two junctions the lower id is the one that was already standing -- it stays, and the
-- road just drawn is what gives. Otherwise the busier end wins (a junction anchors, a
-- bend gives); ties go to the older node, so the outcome never depends on which
-- direction the host road happened to be drawn in.
local function survivingNode(a: Node, b: Node): (Node, Node)
	local da, db = #a.segments, #b.segments
	if da >= 3 and db >= 3 then
		if b.id < a.id then
			return b, a
		end
		return a, b
	end
	if db > da or (db == da and b.id < a.id) then
		return b, a
	end
	return a, b
end

-- Bounding circle (XZ) + Y range over a cubic's control points; the curve always lies
-- inside its control hull, so this always contains it. Cheap (~40 flops) so it is
-- computed per call instead of cached -- no invalidation to get wrong when control
-- points move. Broad-phase for every segment-vs-segment sweep below.
-- ponytail: per-call bounds, no spatial hash; add grid cells only if profiling ever
-- shows the surviving candidate count hot on mega-cities.
type SegBounds = { cx: number, cz: number, r: number, minY: number, maxY: number }
local function boundsOf(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): SegBounds
	local cx = (p0.X + p1.X + p2.X + p3.X) * 0.25
	local cz = (p0.Z + p1.Z + p2.Z + p3.Z) * 0.25
	local r2 = 0
	local minY, maxY = math.huge, -math.huge
	for _, p in { p0, p1, p2, p3 } do
		local dx, dz = p.X - cx, p.Z - cz
		local d2 = dx * dx + dz * dz
		if d2 > r2 then r2 = d2 end
		if p.Y < minY then minY = p.Y end
		if p.Y > maxY then maxY = p.Y end
	end
	return { cx = cx, cz = cz, r = math.sqrt(r2), minY = minY, maxY = maxY }
end

local function boundsNear(a: SegBounds, b: SegBounds, pad: number): boolean
	local dx, dz = a.cx - b.cx, a.cz - b.cz
	local reach = a.r + b.r + pad
	if dx * dx + dz * dz > reach * reach then
		return false
	end
	local vtol = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	return a.maxY >= b.minY - vtol and a.minY <= b.maxY + vtol
end

local function segHit(A: Segment, B: Segment): (number?, number?, Vector3?)
	-- Body crossings only weld within the same layer. Different layers never meet at-grade: an
	-- elevated flyover (or a low Elevated ramp) passes OVER a street, a tunnel passes UNDER it.
	if A.vMode ~= B.vMode then return nil end
	-- Same layer: beziers may sit a few studs apart at the crossing (terrain-following),
	-- covered by the vertical tolerance below. Ground pairs get NO blanket bypass any more:
	-- a lifted run (constant slope / valley span) drawn across a low street welded into an
	-- at-grade junction, kinking both roads to the midpoint Y and folding the junction.
	-- Past the tolerance they pass over/under instead.
	-- Sample both curves once up front; B's samples were recomputed inside the nested
	-- loop (24x redundant bezier math per pair -- the placement-validation hot spot).
	local aPts = table.create(CROSS_SAMPLES + 1)
	local bPts = table.create(CROSS_SAMPLES + 1)
	for i = 0, CROSS_SAMPLES do
		aPts[i + 1] = BezierUtil.point(A.p0, A.p1, A.p2, A.p3, i / CROSS_SAMPLES)
		bPts[i + 1] = BezierUtil.point(B.p0, B.p1, B.p2, B.p3, i / CROSS_SAMPLES)
	end
	-- B's footprint: a piece of A outside it cannot cross B, so its 24 tests are skipped.
	-- Only a cull -- the tests that do run, and their order, are unchanged.
	local bMinX, bMaxX, bMinZ, bMaxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in bPts do
		if p.X < bMinX then bMinX = p.X end
		if p.X > bMaxX then bMaxX = p.X end
		if p.Z < bMinZ then bMinZ = p.Z end
		if p.Z > bMaxZ then bMaxZ = p.Z end
	end
	for i = 0, CROSS_SAMPLES - 1 do
		local a1 = aPts[i + 1]
		local a2 = aPts[i + 2]
		if math.max(a1.X, a2.X) < bMinX or math.min(a1.X, a2.X) > bMaxX
			or math.max(a1.Z, a2.Z) < bMinZ or math.min(a1.Z, a2.Z) > bMaxZ then
			continue
		end
		local r = a2 - a1
		for j = 0, CROSS_SAMPLES - 1 do
			local b1 = bPts[j + 1]
			local b2 = bPts[j + 2]
			local s = b2 - b1
			local rxs = r.X * s.Z - r.Z * s.X
			if math.abs(rxs) > 1e-9 then
				local qpx = b1.X - a1.X
				local qpz = b1.Z - a1.Z
				local t = (qpx * s.Z - qpz * s.X) / rxs
				local u = (qpx * r.Z - qpz * r.X) / rxs
				if t >= 0 and t <= 1 and u >= 0 and u <= 1 then
					local hitA = a1 + r * t
					local hitB = b1 + s * u
					if math.abs(hitA.Y - hitB.Y) <= RoadConstants.VERTICAL_CONNECT_TOLERANCE then
						return (i + t) / CROSS_SAMPLES, (j + u) / CROSS_SAMPLES, (hitA + hitB) * 0.5
					end
				end
			end
		end
	end
	return nil
end

export type RoundaboutInfo = {
	id: number,
	center: Vector3,
	radius: number,
	roadType: string,
	arcCount: number,
}

export type RoadNetwork = typeof(setmetatable(
	{} :: {
		_nodes: { [NodeId]: Node },
		_segments: { [SegmentId]: Segment },
		_nextNodeId: number,
		_nextSegmentId: number,
		_nextRoundaboutId: number,
		_roundabouts: { [number]: RoundaboutInfo },
		_dirtySeg: { [SegmentId]: boolean },
		_dirtyNode: { [NodeId]: boolean },
		_deadNode: { [NodeId]: boolean },
	},
	RoadNetwork
	))

function RoadNetwork.new(): RoadNetwork
	return setmetatable({
		_nodes = {},
		_segments = {},
		_nextNodeId = 1,
		_nextSegmentId = 1,
		_nextRoundaboutId = 1,
		_roundabouts = {},
		_dirtySeg = {},
		_dirtyNode = {},
		_deadNode = {},
	}, RoadNetwork)
end

function RoadNetwork.findNodeNear(self: RoadNetwork, pos: Vector3): Node?
	local best: Node? = nil
	local bestDist = RoadConstants.SNAP_RADIUS
	local vtol = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	for _, node in self._nodes do
		if math.abs(node.position.Y - pos.Y) > vtol then continue end
		local d = (node.position - pos).Magnitude
		if d <= bestDist then
			best = node
			bestDist = d
		end
	end
	return best
end

function RoadNetwork._createNode(self: RoadNetwork, pos: Vector3): Node
	local id = self._nextNodeId
	self._nextNodeId += 1
	local node: Node = { id = id, position = pos, segments = {} }
	self._nodes[id] = node
	self._dirtyNode[id] = true
	return node
end

-- Mark a node dirty without changing topology, so the next applyChanges re-renders it
-- and its arms. For edits that only reshape a junction (the node tool) -- nothing moved,
-- nothing was added or removed, so no other dirty flag would ever fire.
function RoadNetwork.touchNode(self: RoadNetwork, id: NodeId)
	if not self._nodes[id] then return end
	self._dirtyNode[id] = true
end

-- Translate a whole roundabout -- every ring arc, every ring node and the descriptor -- by
-- `delta`. IN PLACE: nothing is removed or re-added, so the arcs keep their ids, their ring
-- metadata and the arms welded to their nodes. Returns the ring's node ids (the caller owns
-- the arms hanging off them: their curves have to stretch to follow).
function RoadNetwork.moveRoundaboutBy(self: RoadNetwork, raId: number, delta: Vector3): { NodeId }
	local nodeIds: { NodeId } = {}
	local seen: { [NodeId]: boolean } = {}
	for id, s in self._segments do
		if s.isRoundabout and s.roundaboutId == raId then
			s.p0 += delta
			s.p1 += delta
			s.p2 += delta
			s.p3 += delta
			if s.roundaboutCenter then s.roundaboutCenter += delta end
			self._dirtySeg[id] = true
			for _, nid in { s.startNode, s.endNode } do
				local node = if seen[nid] then nil else self._nodes[nid]
				if node then
					seen[nid] = true
					node.position += delta
					self._dirtyNode[nid] = true
					nodeIds[#nodeIds + 1] = nid
				end
			end
		end
	end
	local info = self._roundabouts[raId]
	if info and info.center then info.center += delta end
	return nodeIds
end

-- In-place segment edit (a re-type, a rigid translate): mark it for the render/broadcast
-- pass without going through remove + re-add, which mints a new id and drops the segment's
-- metadata. Twin of touchNode.
function RoadNetwork.touchSegment(self: RoadNetwork, id: SegmentId)
	if not self._segments[id] then return end
	self._dirtySeg[id] = true
end

function RoadNetwork.consumeChanges(self: RoadNetwork): ({ [SegmentId]: boolean }, { [NodeId]: boolean }, { [NodeId]: boolean })
	local s, n, d = self._dirtySeg, self._dirtyNode, self._deadNode
	self._dirtySeg = {}
	self._dirtyNode = {}
	self._deadNode = {}
	return s, n, d
end

function RoadNetwork.getOrCreateNode(self: RoadNetwork, pos: Vector3): Node
	return self:findNodeNear(pos) or self:_createNode(pos)
end

function RoadNetwork.getNodeKind(self: RoadNetwork, nodeId: NodeId): string
	local node = self._nodes[nodeId]
	if not node then
		return "endpoint"
	end
	local n = #node.segments
	if n >= 3 then
		return "intersection"
	elseif n == 2 then
		return "corner"
	end
	return "endpoint"
end

function RoadNetwork.splitSegment(self: RoadNetwork, segId: SegmentId, t: number): Node
	local seg = self._segments[segId]
	if not seg then
		error(`[RoadNetwork] splitSegment: no segment {segId}`)
	end
	if t <= 1e-3 then
		return self._nodes[seg.startNode]
	elseif t >= 1 - 1e-3 then
		return self._nodes[seg.endNode]
	end

	local lp0, lp1, lp2, lp3, rp0, rp1, rp2, rp3 =
		BezierUtil.splitAt(seg.p0, seg.p1, seg.p2, seg.p3, t)

	local newNode = self:_createNode(lp3)
	local oldEndId = seg.endNode

	seg.p0, seg.p1, seg.p2, seg.p3 = lp0, lp1, lp2, lp3
	seg.endNode = newNode.id

	local newId = self._nextSegmentId
	self._nextSegmentId += 1
	local newSeg: Segment = {
		id = newId,
		startNode = newNode.id,
		endNode = oldEndId,
		roadType = seg.roadType,
		-- Both halves keep the street name: a split is one road, not two.
		name = seg.name,
		p0 = rp0,
		p1 = rp1,
		p2 = rp2,
		p3 = rp3,

		-- Splitting a roundabout arc keeps both halves part of the ring so the new
		-- node (where a road connects in) reads as a roundabout node.
		isRoundabout = seg.isRoundabout,
		roundaboutId = seg.roundaboutId,
		roundaboutCenter = seg.roundaboutCenter,
		roundaboutRadius = seg.roundaboutRadius,
		roundaboutPreset = seg.roundaboutPreset,
		vMode = seg.vMode,
		constSlope = seg.constSlope,

		-- Node-tool shaping belongs to the NODE an end meets, so the far end's settings
		-- travel to the half that still meets that node. The two new ends at the split
		-- point are a brand-new junction and start at the defaults.
		endCorner = seg.endCorner,
		endOffset = seg.endOffset,
		endFlat = seg.endFlat,
	}
	seg.endCorner = nil
	seg.endOffset = nil
	seg.endFlat = nil
	self._segments[newId] = newSeg

	local oldEnd = self._nodes[oldEndId]
	if oldEnd then
		local idx = table.find(oldEnd.segments, segId)
		if idx then
			oldEnd.segments[idx] = newId
		end
	end
	table.insert(newNode.segments, segId)
	table.insert(newNode.segments, newId)

	self._dirtySeg[segId] = true
	self._dirtySeg[newId] = true
	self._dirtyNode[newNode.id] = true
	self._dirtyNode[oldEndId] = true
	return newNode
end

function RoadNetwork.getOrCreateJunctionNode(self: RoadNetwork, pos: Vector3): Node

	local margin = RoadConstants.SEGMENT_SPLIT_TOLERANCE
	local vtol = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	local bestId: SegmentId? = nil
	local bestT = 0
	local bestDist = math.huge
	for id, seg in self._segments do
		-- Broad-phase: skip segments whose control hull can't reach this endpoint.
		local b = boundsOf(seg.p0, seg.p1, seg.p2, seg.p3)
		local reach = b.r + RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5 + margin
		local bdx, bdz = pos.X - b.cx, pos.Z - b.cz
		if bdx * bdx + bdz * bdz > reach * reach then continue end
		if pos.Y < b.minY - vtol or pos.Y > b.maxY + vtol then continue end
		local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, pos, RoadConstants.SNAP_SEGMENT_SAMPLES)
		local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		-- Elevation-aware: a road passing far above/below this endpoint is a flyover,
		-- not a junction. Gate on height, then measure reach in the ground plane.
		if math.abs(p.Y - pos.Y) > vtol then continue end
		local d = flatDist(p, pos)
		local band = RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5 + margin
		if d <= band and d < bestDist then
			bestDist = d
			bestId = id
			bestT = t
		end
	end
	if bestId then
		local seg = self._segments[bestId]

		local hostHalf = RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5
		local endWeld = math.max(RoadConstants.NODE_WELD_RADIUS, hostHalf + RoadConstants.JUNCTION_MARGIN)
		-- A roundabout ring is 8 octant arcs whose shared nodes are tessellation artifacts at
		-- 45 deg spacing, not real junctions. The wide weld snapped every connecting road to its
		-- nearest octant node -- locking entries to 45 deg regardless of the snap toggles, and
		-- bunching close entries onto one node so their approaches overlapped. Split the arc at
		-- the true crossing instead; only weld when essentially ON an octant node (avoids a
		-- zero-length arc sliver).
		if seg.isRoundabout then
			endWeld = RoadConstants.SEGMENT_SPLIT_TOLERANCE
		end
		local sN = self._nodes[seg.startNode]
		local eN = self._nodes[seg.endNode]
		-- A JUNCTION pulls harder than an ordinary end: an endpoint landing inside its paved
		-- reach joins IT, so a road drawn right beside an intersection gives one bigger
		-- intersection instead of a second one splitting an arm a few studs away.
		local function weldFor(n: Node): number
			if seg.isRoundabout or #n.segments < 3 then
				return endWeld
			end
			return math.max(endWeld, self:junctionMergeRadius(n.id))
		end
		if sN and math.abs(sN.position.Y - pos.Y) <= vtol and flatDist(sN.position, pos) <= weldFor(sN) then
			return sN
		end
		if eN and math.abs(eN.position.Y - pos.Y) <= vtol and flatDist(eN.position, pos) <= weldFor(eN) then
			return eN
		end
		return self:splitSegment(bestId, bestT)
	end

	local best: Node? = nil
	local bestDist = RoadConstants.SNAP_RADIUS
	for _, node in self._nodes do
		if #node.segments > 0 and math.abs(node.position.Y - pos.Y) <= vtol then
			local d = (node.position - pos).Magnitude
			if d <= bestDist then
				best = node
				bestDist = d
			end
		end
	end
	return best or self:_createNode(pos)
end

-- Two segments joining the SAME pair of nodes along the SAME path are one road placed
-- twice. They stack, so only one of them bakes any geometry -- but BOTH still dress their
-- own furniture, which is how a single crossing sprouts a second set of name blades at the
-- junction. mergeNodes is where they come from: re-pointing a dropped node's arms onto the
-- survivor can land an arm right beside one the survivor already had (the collapsed-link
-- guard in there only catches arms joining the two nodes being merged). checkParallelTwin
-- refuses to DRAW one; nothing stopped a merge from creating one.
-- A deliberate bypass -- two roads between the same junctions taking different paths -- is
-- left alone: a duplicate is one the merge STACKED, so its path matches to the stud. Watch
-- the direction: the two are stored end for end as often as not, and sampling both at the
-- same t then reads a genuine duplicate as half its own length apart.
function RoadNetwork.dedupeParallel(self: RoadNetwork, nodeId: NodeId): number
	local node = self._nodes[nodeId]
	if not node then
		return 0
	end
	local function samePath(a: Segment, b: Segment): boolean
		if a.vMode ~= b.vMode then
			return false
		end
		local aligned = a.startNode == b.startNode
		for _, t in { 0.25, 0.5, 0.75 } do
			local pa = BezierUtil.point(a.p0, a.p1, a.p2, a.p3, t)
			local pb = BezierUtil.point(b.p0, b.p1, b.p2, b.p3, if aligned then t else 1 - t)
			if flatDist(pa, pb) > DUPLICATE_PATH_TOLERANCE then
				return false
			end
		end
		return true
	end
	local seen: { [NodeId]: SegmentId } = {}
	local drop: { SegmentId } = {}
	for _, sid in table.clone(node.segments) do
		local s = self._segments[sid]
		if not s or s.isArc or s.isRoundabout then
			continue
		end
		local far = if s.startNode == nodeId then s.endNode else s.startNode
		if far == nodeId then
			continue
		end
		local prevId = seen[far]
		local prev = if prevId then self._segments[prevId] else nil
		if not prev or not samePath(prev, s) then
			seen[far] = sid
			continue
		end
		-- The older piece stays: a road already standing is never the one that gives.
		local keepId: SegmentId, dropId: SegmentId = prevId :: SegmentId, sid
		if sid < keepId then
			keepId, dropId = sid, keepId
		end
		local keep, dead = self._segments[keepId], self._segments[dropId]
		if keep and dead and dead.name and not keep.name then
			keep.name = dead.name
		end
		seen[far] = keepId
		drop[#drop + 1] = dropId
	end
	for _, sid in drop do
		self:removeSegment(sid)
	end
	return #drop
end

function RoadNetwork.mergeNodes(self: RoadNetwork, keepId: NodeId, dropId: NodeId)
	if keepId == dropId then
		return
	end
	local keep = self._nodes[keepId]
	local drop = self._nodes[dropId]
	if not keep or not drop then
		return
	end
	-- A segment joining the two nodes being merged collapses to zero span: both ends
	-- land on `keep` and it becomes a self-loop, which renders as a degenerate blob and
	-- routes nowhere. Drop those first (removeSegment mutates drop.segments, so collect
	-- before removing rather than deleting mid-iteration).
	local collapsed: { SegmentId } = {}
	for _, sid in drop.segments do
		local s = self._segments[sid]
		if s and ((s.startNode == dropId and s.endNode == keepId)
			or (s.endNode == dropId and s.startNode == keepId)) then
			collapsed[#collapsed + 1] = sid
		end
	end
	for _, sid in collapsed do
		self:removeSegment(sid)
	end

	for _, sid in drop.segments do
		local s = self._segments[sid]
		if s then
			-- A stub whose far end is still a dead end SLIDES onto the surviving node --
			-- whole piece, drawn heading intact -- instead of pivoting about that far end
			-- and arriving at an angle nobody drew (the lopsided-X junction). Anything
			-- anchored at both ends has nowhere to give and keeps the pivot below.
			local farId = if s.startNode == dropId then s.endNode else s.startNode
			local far = self._nodes[farId]
			if far and farId ~= keepId and #far.segments == 1 and not s.isRoundabout and not s.isArc then
				local at = if s.startNode == dropId then s.p0 else s.p3
				local f = Vector3.new(keep.position.X - at.X, 0, keep.position.Z - at.Z)
				if f.Magnitude > 1e-4 then
					s.p0, s.p1, s.p2, s.p3 = s.p0 + f, s.p1 + f, s.p2 + f, s.p3 + f
					far.position += f
					self._dirtyNode[farId] = true
				end
			end
			if s.startNode == dropId then
				s.startNode = keepId
				s.p0, s.p1, s.p2, s.p3 = RoadMoveGeometry.movedEndpoint(s.p0, s.p1, s.p2, s.p3, true, keep.position)
			end
			if s.endNode == dropId then
				s.endNode = keepId
				s.p0, s.p1, s.p2, s.p3 = RoadMoveGeometry.movedEndpoint(s.p0, s.p1, s.p2, s.p3, false, keep.position)
			end
			if not table.find(keep.segments, sid) then
				table.insert(keep.segments, sid)
			end
			self._dirtySeg[sid] = true
		end
	end
	self._nodes[dropId] = nil
	self._dirtyNode[keepId] = true
	self._deadNode[dropId] = true
	self._dirtyNode[dropId] = nil

	self:dedupeParallel(keepId)
end

-- A junction mouth plus the neighbouring corner's trim can swallow a short arm
-- segment whole: the graph says the segment exists, but the renderer draws NOTHING
-- for it (empty Segment_N model -- the invisible-road bug). Rather than teach every
-- tool (place, move, crossing-split, undo, restore) the renderer's dynamic reach,
-- dissolve the offending degree-2 node after the fact: the arm then runs
-- junction -> next real node as one segment, which always has room to render.
-- `trimAt` is injected by the caller (renderer reach math) so this module stays
-- renderer-free. Returns true when anything merged so the caller can re-consume.
-- Covers every end pairing except dead ends (degree 1): a stub is player-placed
-- road and is never auto-deleted -- it renders its cap even when cramped. And never
-- junction to junction: the renderer already meets their mouths at the link's midpoint,
-- and a merge drags every arm of the dropped one -- a crossing laid on an existing road
-- pulled that road 35 studs sideways onto the new road's own junction.
function RoadNetwork.dissolveSwallowedArms(self: RoadNetwork, segIds: { SegmentId }, trimAt: (NodeId, SegmentId) -> number): boolean
	local mergedAny = false
	for _, sid in segIds do
		local seg = self._segments[sid]
		if seg and not seg.isArc and not seg.isRoundabout then
			local nA = self._nodes[seg.startNode]
			local nB = self._nodes[seg.endNode]
			if nA and nB and #nA.segments >= 2 and #nB.segments >= 2
				and (#nA.segments == 2 or #nB.segments == 2)
				and not self:isRoundaboutNode(nA.id)
				and not self:isRoundaboutNode(nB.id) then
				local keepN, dropN = survivingNode(nA, nB)
				local len = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 16)
				if len <= trimAt(nA.id, sid) + trimAt(nB.id, sid) + RoadConstants.SEGMENT_SWALLOW_MARGIN then
					-- Keep a player rename alive on the street's continuation. Only a
					-- degree-2 drop end has an unambiguous continuation to carry it.
					if seg.name and #dropN.segments == 2 then
						for _, osid in dropN.segments do
							local other = self._segments[osid]
							if other and osid ~= sid and not other.name then
								other.name = seg.name
							end
						end
					end
					self:mergeNodes(keepN.id, dropN.id)
					mergedAny = true
				end
			end
		end
	end
	return mergedAny
end

function RoadNetwork.resolveCrossings(self: RoadNetwork, seedIds: { SegmentId })
	local cand: { [SegmentId]: boolean } = {}
	for _, id in seedIds do
		cand[id] = true
	end
	-- A crossing this close (in curve param) to a piece's end meets AT that end: the
	-- endpoint welds into the other road instead of splitting off a sliver. The old code
	-- SKIPPED these crossings entirely, so a road crossing two others could leave its
	-- second crossing unresolved -- two roads overlapping unconnected (the mangled
	-- double-crossing junction with sidewalks poking through).
	local EDGE = 0.02
	local guard = 0
	while guard < 500 do
		guard += 1
		local aId: SegmentId?, bId: SegmentId?, tA: number?, tB: number?, pt: Vector3?
		for cId in cand do
			local A = self._segments[cId]
			if A then
				local boundsA = boundsOf(A.p0, A.p1, A.p2, A.p3)
				for oId, B in self._segments do
					if oId ~= cId
						and A.startNode ~= B.startNode and A.startNode ~= B.endNode
						and A.endNode ~= B.startNode and A.endNode ~= B.endNode
						and boundsNear(boundsA, boundsOf(B.p0, B.p1, B.p2, B.p3), 0) then
						local ha, hb, hp = segHit(A, B)
						if ha and hb then
							aId, bId, tA, tB, pt = cId, oId, ha, hb, hp
							break
						end
					end
				end
			end
			if aId then
				break
			end
		end
		if not aId then
			break
		end

		local A = self._segments[aId :: SegmentId] :: Segment
		local B = self._segments[bId :: SegmentId] :: Segment
		local tAv, tBv = tA :: number, tB :: number
		-- "At the end" = the param edge band OR the hit lying inside an end node's weld
		-- disc -- the SAME distance rule checkPlacement uses to exempt crossings that merge
		-- into an existing node, so validation and resolution can never disagree (a crossing
		-- 10 studs from an existing junction must MERGE into it, not spawn a junction beside
		-- it). Ring arcs keep the tiny split tolerance: welding entries to their octant
		-- nodes is the old roundabout-snap bug.
		local function endNodeNear(seg: Segment, t: number, hit: Vector3): NodeId?
			if t <= EDGE then return seg.startNode end
			if t >= 1 - EDGE then return seg.endNode end
			local base = if seg.isRoundabout
				then RoadConstants.SEGMENT_SPLIT_TOLERANCE
				else math.max(RoadConstants.NODE_WELD_RADIUS, RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5 + RoadConstants.JUNCTION_MARGIN)
			local sN = self._nodes[seg.startNode]
			local eN = self._nodes[seg.endNode]
			-- A crossing landing inside an existing JUNCTION's paved reach merges into it: one
			-- big intersection, not two fills fighting over the same asphalt. Ordinary ends keep
			-- the narrow weld, ring arcs the tiny split tolerance (see the roundabout note above).
			local function wr(n: Node): number
				if seg.isRoundabout or #n.segments < 3 then
					return base
				end
				return math.max(base, self:junctionMergeRadius(n.id))
			end
			local dS = if sN then flatDist(hit, sN.position) - wr(sN) else math.huge
			local dE = if eN then flatDist(hit, eN.position) - wr(eN) else math.huge
			if math.min(dS, dE) > 0 then return nil end
			return if dS <= dE then seg.startNode else seg.endNode
		end
		local aNear = endNodeNear(A, tAv, pt :: Vector3)
		local bNear = endNodeNear(B, tBv, pt :: Vector3)
		if aNear or bNear then
			-- Weld through survivingNode: the junction that was already standing stays put
			-- and the small position kink lands on the loose end.
			-- Translate a whole piece so its curve passes through `target`, carrying its end
			-- nodes along. Only safe while both ends are still loose -- an end shared with
			-- another road has nowhere to give, so those keep the old (kinking) path.
			-- ponytail: translation only. A piece anchored at BOTH ends still kinks; give it a
			-- proper re-fit only if that turns up in practice.
			local function slideOnto(seg: Segment, target: Vector3): boolean
				local sN, eN = self._nodes[seg.startNode], self._nodes[seg.endNode]
				if not sN or not eN then return false end
				if #sN.segments > 1 or #eN.segments > 1 then return false end
				local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, target, RoadConstants.SNAP_SEGMENT_SAMPLES)
				local d = target - BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
				if d.Magnitude < 1e-4 then return true end
				seg.p0, seg.p1, seg.p2, seg.p3 = seg.p0 + d, seg.p1 + d, seg.p2 + d, seg.p3 + d
				sN.position, eN.position = seg.p0, seg.p3
				self._dirtySeg[seg.id] = true
				self._dirtyNode[sN.id] = true
				self._dirtyNode[eN.id] = true
				return true
			end
			local function weld(idKeep: NodeId, idDrop: NodeId)
				local keep = self._nodes[idKeep]
				local drop = self._nodes[idDrop]
				if not keep or not drop then return end
				local k, d = survivingNode(keep, drop)
				self:mergeNodes(k.id, d.id)
			end
			if aNear and bNear then
				-- Two ends kiss: fuse them into one node.
				weld(bNear, aNear)
			elseif aNear then
				-- The piece ENDS on B's body: T-join its end node into a split of B. The
				-- split point is guaranteed clear of B's ends (bNear is nil), so no sliver.
				local nodeB = self:splitSegment(bId :: SegmentId, tBv)
				weld(nodeB.id, aNear)
			else
				-- The crossing lands at B's end node: split A there and weld into it.
				-- A's BODY passes the node, up to a weld radius off its line. Splitting at the
				-- crossing and letting the merge drag that point onto the node re-aimed each
				-- half independently -- a straight road came out V-kinked at the junction, and
				-- nothing in the client preview predicts it. Slide the whole piece onto the node
				-- first (shape preserved, no kink), then split where it actually passes through.
				local wp = (self._nodes[bNear :: NodeId] :: Node).position
				local segA = self._segments[aId :: SegmentId] :: Segment
				slideOnto(segA, wp)
				local tw = BezierUtil.closestParam(segA.p0, segA.p1, segA.p2, segA.p3, wp, RoadConstants.SNAP_SEGMENT_SAMPLES)
				local aEdgeHalf = self._nextSegmentId
				local nodeA = self:splitSegment(aId :: SegmentId, tw)
				cand[aEdgeHalf] = true
				weld(bNear :: NodeId, nodeA.id)
			end
			continue
		end

		local aHalf = self._nextSegmentId
		local nodeA = self:splitSegment(aId :: SegmentId, tAv)
		cand[aHalf] = true
		local nodeB = self:splitSegment(bId :: SegmentId, tBv)
		nodeA.position = pt :: Vector3
		self:mergeNodes(nodeA.id, nodeB.id)
		-- `pt` is the polyline hit averaged across both curves, so it sits slightly off
		-- each half's own endpoint. Move through movedEndpoint (same as mergeNodes and
		-- addSegment) -- assigning p0/p3 raw left the handles on the old line and kinked
		-- both roads at the junction.
		for _, sid in nodeA.segments do
			local s = self._segments[sid]
			if s then
				if s.startNode == nodeA.id then
					s.p0, s.p1, s.p2, s.p3 = RoadMoveGeometry.movedEndpoint(s.p0, s.p1, s.p2, s.p3, true, pt :: Vector3)
				end
				if s.endNode == nodeA.id then
					s.p0, s.p1, s.p2, s.p3 = RoadMoveGeometry.movedEndpoint(s.p0, s.p1, s.p2, s.p3, false, pt :: Vector3)
				end
				self._dirtySeg[sid] = true
			end
		end

		-- A crossing landing just shy of an existing road's dead-end leaves a tiny stub
		-- (its rounded cap + U-turn) buried in the new junction. Drop any junction arm whose
		-- far node is a dead-end sitting inside the junction footprint so the long arm T-joins
		-- cleanly -- the same result as crossing exactly at the road end. Never absorb a piece
		-- of the road being drawn (everything in `cand`).
		local junctionHalf = 0
		for _, sid in nodeA.segments do
			local s = self._segments[sid]
			if s then
				junctionHalf = math.max(junctionHalf, RoadTypeCatalog.getOrDefault(s.roadType).width * 0.5)
			end
		end
		local stubs: { SegmentId } = {}
		for _, sid in nodeA.segments do
			if cand[sid] then continue end
			local s = self._segments[sid]
			if not s then continue end
			local farId = if s.startNode == nodeA.id then s.endNode else s.startNode
			local far = self._nodes[farId]
			-- Absorb by RENDERED footprints, not raw widths: the junction's furniture (stop
			-- line + crosswalk) reaches JUNCTION_FURNITURE_DEPTH past the fill and a dead-end
			-- bulb reaches half-width + sidewalk past its node. A stub whose cap merely
			-- collided visually used to survive topologically (the buried-cap bug).
			local stubSpec = RoadTypeCatalog.getOrDefault(s.roadType)
			local bulb = stubSpec.width * 0.5 + (if stubSpec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
			if far and #far.segments == 1
				and flatDist(pt :: Vector3, far.position) <= junctionHalf + RoadConstants.JUNCTION_FURNITURE_DEPTH + bulb + RoadConstants.JUNCTION_MARGIN then
				stubs[#stubs + 1] = sid
			end
		end
		for _, sid in stubs do
			self:removeSegment(sid)
		end
	end

	-- Phase 2: connect existing dead-end tips that land on the new road's body. segHit's interior
	-- guard (param 0.02..0.98) skips a crossing AT an existing road's endpoint, so a road drawn
	-- ACROSS a dead-end would clip past it. Weld each degree-1 node lying on a candidate piece's
	-- interior into it -- splitting there so the dead-end T-joins the road instead of clipping.
	-- Runs over `cand` (every piece of the new road, post-crossing) plus the halves it splits.
	local work: { SegmentId } = {}
	for cId in cand do work[#work + 1] = cId end
	local vtol = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	local absGuard = 0
	while #work > 0 and absGuard < 300 do
		absGuard += 1
		local sid = table.remove(work) :: SegmentId
		local seg = self._segments[sid]
		if not seg then continue end
		local bspec = RoadTypeCatalog.getOrDefault(seg.roadType)
		-- Reach the new road's full footprint (carriageway + sidewalk), not just the carriageway, so a
		-- dead-end drawn right up to the road T-joins it instead of overlapping it unconnected.
		local newFoot = bspec.width * 0.5 + (if bspec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
		-- AABB pad: the new footprint plus room for the dead-end's own footprint, so a dead-end whose
		-- cap merely touches still reaches the precise per-tip test below.
		local pad = newFoot + RoadConstants.ROAD_WIDTH
		-- Cheap AABB so a big city isn't scanned node-by-node per piece.
		local minX = math.min(seg.p0.X, seg.p1.X, seg.p2.X, seg.p3.X) - pad
		local maxX = math.max(seg.p0.X, seg.p1.X, seg.p2.X, seg.p3.X) + pad
		local minZ = math.min(seg.p0.Z, seg.p1.Z, seg.p2.Z, seg.p3.Z) - pad
		local maxZ = math.max(seg.p0.Z, seg.p1.Z, seg.p2.Z, seg.p3.Z) + pad
		local found: Node? = nil
		local foundT = 0
		local weldTarget: Node? = nil  -- when set, weld the dead-end into this existing node instead of splitting
		for nodeId, node in self._nodes do
			if #node.segments ~= 1 then continue end -- dead-ends only; bodies cross-resolve in phase 1
			if nodeId == seg.startNode or nodeId == seg.endNode then continue end
			local np = node.position
			if np.X < minX or np.X > maxX or np.Z < minZ or np.Z > maxZ then continue end
			local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, np, RoadConstants.SNAP_SEGMENT_SAMPLES)
			local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
			local deadSeg = self._segments[node.segments[1]]
			-- Same-layer rule as phase 1: a dead-end welds to a road body only on its own layer.
			if seg.vMode ~= (if deadSeg then deadSeg.vMode else nil) then continue end
			if seg.vMode ~= nil and math.abs(p.Y - np.Y) > vtol then continue end
			-- Weld when the two footprints meet: the new road's footprint plus the dead-end's half-width.
			local deadHalf = if deadSeg then RoadTypeCatalog.getOrDefault(deadSeg.roadType).width * 0.5 else 0
			if flatDist(p, np) > newFoot + deadHalf + RoadConstants.SEGMENT_SPLIT_TOLERANCE then continue end
			-- If the foot lands on a node already at the end of this piece -- e.g. the opposing dead-end
			-- welded there a step earlier -- join that node instead of splitting again. Otherwise two
			-- facing dead-ends become two offset T-junctions whose fills overlap, or the interior guard
			-- (foot near t=0/1) drops the second one entirely and only one side connects.
			local sNode = self._nodes[seg.startNode]
			local eNode = self._nodes[seg.endNode]
			if sNode and flatDist(p, sNode.position) <= newFoot then
				weldTarget, found = sNode, node
				break
			elseif eNode and flatDist(p, eNode.position) <= newFoot then
				weldTarget, found = eNode, node
				break
			elseif t > 0.02 and t < 0.98 then
				found, foundT = node, t
				break
			end
		end
		if found then
			if weldTarget then
				self:mergeNodes(weldTarget.id, found.id)
				work[#work + 1] = sid
			else
				local secondId = self._nextSegmentId
				local newNode = self:splitSegment(sid, foundT)
				self:mergeNodes(newNode.id, found.id)
				work[#work + 1] = sid
				work[#work + 1] = secondId
			end
		end
	end
end

function RoadNetwork.addSegment(self: RoadNetwork, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string, vMode: string?, constSlope: boolean?): Segment
	local startNode = self:getOrCreateJunctionNode(p0)
	local endNode = self:getOrCreateJunctionNode(p3)

	-- A welded endpoint can sit off the drawn line (up to the weld radius). While the far
	-- end is still loose the road SLIDES onto the node -- whole piece, drawn heading
	-- intact. Pivoting it about the far end instead swung it off the angle the player
	-- aimed with (the 90 deg on the readout arrived as 80), so a road drawn square into
	-- an existing junction rendered as a lopsided X. Anchored at BOTH ends there is
	-- nowhere to give, so those still pivot. XZ only: the loose end keeps its own ground
	-- height and the handle rebuild below carries the Y.
	local q0, q1, q2, q3 = p0, p1, p2, p3
	local function slideOntoWeld(delta: Vector3, loose: Node)
		local f = Vector3.new(delta.X, 0, delta.Z)
		if f.Magnitude <= 1e-4 then return end
		q0, q1, q2, q3 = q0 + f, q1 + f, q2 + f, q3 + f
		loose.position += f
		self._dirtyNode[loose.id] = true
	end
	if #startNode.segments > 0 and #endNode.segments == 0 then
		slideOntoWeld(startNode.position - q0, endNode)
	elseif #endNode.segments > 0 and #startNode.segments == 0 then
		slideOntoWeld(endNode.position - q3, startNode)
	end
	-- Rebuild the handles for whatever is still off (a pivot, or the Y the slide left):
	-- straight stays straight, instead of handles on the old line bowing the road.
	if (startNode.position - q0).Magnitude > 1e-4 then
		q0, q1, q2, q3 = RoadMoveGeometry.movedEndpoint(q0, q1, q2, q3, true, startNode.position)
	end
	if (endNode.position - q3).Magnitude > 1e-4 then
		q0, q1, q2, q3 = RoadMoveGeometry.movedEndpoint(q0, q1, q2, q3, false, endNode.position)
	end

	local id = self._nextSegmentId
	self._nextSegmentId += 1

	local seg: Segment = {
		id = id,
		startNode = startNode.id,
		endNode = endNode.id,
		roadType = roadType,
		p0 = q0,
		p1 = q1,
		p2 = q2,
		p3 = q3,
		vMode = vMode,
		constSlope = constSlope,
	}
	self._segments[id] = seg
	table.insert(startNode.segments, id)
	table.insert(endNode.segments, id)
	self._dirtySeg[id] = true
	self._dirtyNode[startNode.id] = true
	self._dirtyNode[endNode.id] = true

	self:resolveCrossings({ id })
	return seg
end

-- Add a road the placement cut into pieces, in drawn order. A piece that welds slides onto
-- its node (addSegment), so each next piece starts where the previous one actually LANDED --
-- fed the drawn point instead, two pieces sat side by side too far apart to weld. The LAST
-- piece must not carry that slide when its drawn end meets a road: the shift pulled the end
-- off the road it was aimed at and left a dead end short of it (a start inside a junction's
-- merge radius slides the whole chain by up to that radius). It pivots about its landed start.
-- ponytail: the whole correction is one kink at the last joint, at most
-- atan(slide / piece length); spread it over the pieces if that kink ever shows.
function RoadNetwork.addChain(self: RoadNetwork, curves: { { p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3 } }, roadType: string, vMode: string?, constSlope: boolean?): { Segment }
	local added: { Segment } = {}
	local slide = Vector3.zero
	for i, c in curves do
		local p0, p1, p2, p3 = c.p0 + slide, c.p1 + slide, c.p2 + slide, c.p3 + slide
		if i == #curves and slide.Magnitude > 1e-4 and #self:armDirsAt(c.p3) > 0 then
			p0, p1, p2, p3 = RoadMoveGeometry.movedEndpoint(c.p0, c.p1, c.p2, c.p3, true, p0)
		end
		local seg = self:addSegment(p0, p1, p2, p3, roadType, vMode, constSlope)
		added[i] = seg
		slide = seg.p3 - c.p3
	end
	return added
end

-- Create a segment between explicit endpoints, welding each end to an existing
-- node within SNAP_RADIUS or creating a fresh one. Unlike addSegment it runs NO
-- crossing resolution or junction-band splitting: the caller owns the geometry
-- (roundabout rings, save restore), so the placement heuristics are neither
-- needed nor wanted (they can spuriously split short ring arcs).
-- Nearest node within `radius`, or a new one. The restore path welds with a tiny radius:
-- saved pieces share bit-identical endpoint positions, while the placement snap radius
-- (SNAP_RADIUS / NODE_WELD_RADIUS) would merge nodes that were deliberately distinct in
-- the save (a tight fillet's tangent pair, close T-nodes) -- the "loading warped my
-- roads" bug.
function RoadNetwork.getOrCreateNodeWithin(self: RoadNetwork, pos: Vector3, radius: number): Node
	local best: Node? = nil
	local bestDist = radius
	for _, node in self._nodes do
		local d = (node.position - pos).Magnitude
		if d <= bestDist then
			best = node
			bestDist = d
		end
	end
	return best or self:_createNode(pos)
end

function RoadNetwork._directAddSegment(self: RoadNetwork, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string, meta: any?): Segment
	local weld: number? = if meta then meta.weld else nil
	local startNode = if weld then self:getOrCreateNodeWithin(p0, weld) else self:getOrCreateNode(p0)
	local endNode = if weld then self:getOrCreateNodeWithin(p3, weld) else self:getOrCreateNode(p3)
	-- A city restore passes the SAVED id (meta.id) so anything keyed on segment ids --
	-- plot groups above all -- still points at the same road after a reload. Auto-assign
	-- only when no id is given or it is already taken.
	local wanted = if meta then meta.id else nil
	local id = if typeof(wanted) == "number" and not self._segments[wanted] then wanted else self._nextSegmentId
	if id >= self._nextSegmentId then
		self._nextSegmentId = id + 1
	end
	local seg: Segment = {
		id = id,
		startNode = startNode.id,
		endNode = endNode.id,
		roadType = roadType,
		p0 = startNode.position,
		p1 = p1,
		p2 = p2,
		p3 = endNode.position,
	}
	if meta then
		seg.name = meta.name
		seg.vMode = meta.vMode
		seg.constSlope = meta.constSlope
		seg.isRoundabout = meta.isRoundabout
		seg.roundaboutId = meta.roundaboutId
		seg.roundaboutCenter = meta.center
		seg.roundaboutRadius = meta.radius
		seg.roundaboutPreset = meta.preset
		seg.startCorner = meta.startCorner
		seg.endCorner = meta.endCorner
		seg.startOffset = meta.startOffset
		seg.endOffset = meta.endOffset
		seg.startFlat = meta.startFlat
		seg.endFlat = meta.endFlat
		if meta.isRoundabout and meta.roundaboutId then
			if not self._roundabouts[meta.roundaboutId] then
				self._roundabouts[meta.roundaboutId] = {
					id = meta.roundaboutId, center = meta.center, radius = meta.radius,
					roadType = roadType, arcCount = 0,
				}
			end
			if meta.roundaboutId >= self._nextRoundaboutId then
				self._nextRoundaboutId = meta.roundaboutId + 1
			end
		end
	end
	self._segments[id] = seg
	table.insert(startNode.segments, id)
	table.insert(endNode.segments, id)
	self._dirtySeg[id] = true
	self._dirtyNode[startNode.id] = true
	self._dirtyNode[endNode.id] = true
	return seg
end

-- Stamp a roundabout: a closed loop of one-way arcs (one circulating lane) of the
-- given roadType. `radius` is to the lane centerline. Circulates CLOCKWISE viewed
-- from above (left-hand drive: entering traffic gives way to the right). Returns
-- the ring info plus its created segment/node ids.
function RoadNetwork.addRoundabout(self: RoadNetwork, center: Vector3, radius: number, roadType: string, arcCount: number?, preset: string?): { id: number, center: Vector3, radius: number, segmentIds: { SegmentId }, nodeIds: { NodeId } }
	local N = math.max(4, arcCount or RoadConstants.ROUNDABOUT_ARC_COUNT)
	local raId = self._nextRoundaboutId
	self._nextRoundaboutId += 1
	local delta = (2 * math.pi) / N
	local h = (4 / 3) * radius * math.tan(delta / 4)

	local function ptAt(k: number): Vector3
		local theta = -k * delta
		return Vector3.new(center.X + radius * math.cos(theta), center.Y, center.Z + radius * math.sin(theta))
	end
	-- Unit travel tangent for clockwise (decreasing-angle) motion.
	local function tanAt(k: number): Vector3
		local theta = -k * delta
		return Vector3.new(math.sin(theta), 0, -math.cos(theta))
	end

	local meta = { isRoundabout = true, roundaboutId = raId, center = center, radius = radius, preset = preset }
	local segIds: { SegmentId } = {}
	local nodeIds: { NodeId } = {}
	local seenNode: { [NodeId]: boolean } = {}
	for k = 0, N - 1 do
		local p0 = ptAt(k)
		local p3 = ptAt(k + 1)
		local t0 = tanAt(k)
		local t1 = tanAt(k + 1)
		local seg = self:_directAddSegment(p0, p0 + t0 * h, p3 - t1 * h, p3, roadType, meta)
		table.insert(segIds, seg.id)
		if not seenNode[seg.startNode] then seenNode[seg.startNode] = true; table.insert(nodeIds, seg.startNode) end
		if not seenNode[seg.endNode] then seenNode[seg.endNode] = true; table.insert(nodeIds, seg.endNode) end
	end

	self._roundabouts[raId] = { id = raId, center = center, radius = radius, roadType = roadType, arcCount = N }
	return { id = raId, center = center, radius = radius, segmentIds = segIds, nodeIds = nodeIds }
end

-- The centre preset of a roundabout (RoadConstants.ROUNDABOUT_CENTRE_PRESETS). It rides on
-- every arc of the ring, like the centre and radius, so splits, saves and undo keep it.
-- Returns false when no ring has this id.
function RoadNetwork.setRoundaboutPreset(self: RoadNetwork, raId: number, preset: string?): boolean
	local found = false
	for _, s in self._segments do
		if s.isRoundabout and s.roundaboutId == raId then
			s.roundaboutPreset = preset
			found = true
		end
	end
	return found
end

-- True when the node has at least one roundabout ring arc -- i.e. it sits on a
-- roundabout (a ring node, or an entry/exit where a road joined the ring).
function RoadNetwork.isRoundaboutNode(self: RoadNetwork, nodeId: NodeId): boolean
	local node = self._nodes[nodeId]
	if not node then return false end
	for _, sid in node.segments do
		local s = self._segments[sid]
		if s and s.isRoundabout then return true end
	end
	return false
end

-- The roundabout (center/radius) a node belongs to, or nil.
function RoadNetwork.getRoundaboutForNode(self: RoadNetwork, nodeId: NodeId): RoundaboutInfo?
	local node = self._nodes[nodeId]
	if not node then return nil end
	for _, sid in node.segments do
		local s = self._segments[sid]
		if s and s.isRoundabout then
			if s.roundaboutId and self._roundabouts[s.roundaboutId] then
				return self._roundabouts[s.roundaboutId]
			end
			if s.roundaboutCenter and s.roundaboutRadius then
				return { id = s.roundaboutId or 0, center = s.roundaboutCenter, radius = s.roundaboutRadius, roadType = s.roadType, arcCount = 0 }
			end
		end
	end
	return nil
end

function RoadNetwork.getRoundabouts(self: RoadNetwork): { [number]: RoundaboutInfo }
	return self._roundabouts
end

-- == Ring re-tessellation =====================================================
-- A ring's arcs are TESSELLATION, not roads: their shared nodes are artifacts of
-- slicing a circle, and only the nodes an approach road joins mean anything. An entry
-- splits whatever arc it lands on, so entering a few degrees off an octant leaves a
-- stub arc shorter than the junction mouth that swallows it -- the renderer then draws
-- nothing there and the kerb steps sideways at the entry (the notch), the circulating
-- lane loses its markings, and a bare wedge opens inside the ring.
--
-- reflowRoundabout re-lays the whole ring between its real nodes, cutting each gap into
-- equal arcs no wider than one default slice. It is a no-op while every arc is already
-- a sane slice, so ids stay stable across saves and repeated calls.
local RING_MAX_SPAN = (2 * math.pi) / RoadConstants.ROUNDABOUT_ARC_COUNT
local RING_MIN_SPAN = RING_MAX_SPAN / 3

local function linkRingArc(self: RoadNetwork, a: Node, b: Node, p1: Vector3, p2: Vector3, roadType: string, meta: any): Segment
	local id = self._nextSegmentId
	self._nextSegmentId += 1
	local seg: Segment = {
		id = id,
		startNode = a.id,
		endNode = b.id,
		roadType = roadType,
		p0 = a.position,
		p1 = p1,
		p2 = p2,
		p3 = b.position,
		isRoundabout = true,
		roundaboutId = meta.roundaboutId,
		roundaboutCenter = meta.center,
		roundaboutRadius = meta.radius,
		roundaboutPreset = meta.preset,
	}
	self._segments[id] = seg
	table.insert(a.segments, id)
	table.insert(b.segments, id)
	self._dirtySeg[id] = true
	self._dirtyNode[a.id] = true
	self._dirtyNode[b.id] = true
	return seg
end

-- `trimAt` is the renderer's junction reach, injected by the caller the same way
-- dissolveSwallowedArms takes it, so this module stays renderer-free. Without it the
-- too-close-entry merge below is skipped and this is a pure re-tessellation.
function RoadNetwork.reflowRoundabout(self: RoadNetwork, raId: number, trimAt: ((NodeId, SegmentId) -> number)?): boolean
	local info = self._roundabouts[raId]
	if not info or info.radius <= 1e-3 then
		return false
	end
	local center, radius = info.center, info.radius
	local function angleAt(p: Vector3): number
		return math.atan2(p.Z - center.Z, p.X - center.X)
	end

	local ringIds: { SegmentId } = {}
	local onRing: { [NodeId]: boolean } = {}
	for id, s in self._segments do
		if s.isRoundabout and s.roundaboutId == raId then
			ringIds[#ringIds + 1] = id
			onRing[s.startNode] = true
			onRing[s.endNode] = true
		end
	end
	if #ringIds == 0 then
		return false
	end

	-- Real = an approach road joins here.
	local real: { { id: NodeId, angle: number } } = {}
	local isReal: { [NodeId]: boolean } = {}
	for nid in onRing do
		local node = self._nodes[nid]
		if not node then continue end
		for _, sid in node.segments do
			local s = self._segments[sid]
			if s and not (s.isRoundabout and s.roundaboutId == raId) then
				isReal[nid] = true
				real[#real + 1] = { id = nid, angle = angleAt(node.position) }
				break
			end
		end
	end

	-- Two entries can land closer together than the junction mouths they need: the arc
	-- between them is shorter than the trim taken off both its ends, so the renderer draws
	-- NOTHING for it -- a hole in the ring with a stray kerb hook floating in it. Dropping a
	-- roundabout onto an existing intersection does this whenever the ring lands off the
	-- junction's centre. Neither pass below catches it (the re-tessellation treats an entry
	-- pair as irreducible, dissolveSwallowedArms skips everything on a ring), so fuse the
	-- pair into one entry here. Both nodes sit ON the circle, so the arcs re-laid below still
	-- follow it and the two approaches share one mouth. Same swallow test the arm dissolve
	-- uses; entry counts are single digits, so rescanning after each merge is free.
	local merged = false
	while trimAt do
		local swallowed: SegmentId? = nil
		for _, id in ringIds do
			local s = self._segments[id]
			if s and s.startNode ~= s.endNode and isReal[s.startNode] and isReal[s.endNode]
				and BezierUtil.length(s.p0, s.p1, s.p2, s.p3, 16)
					<= trimAt(s.startNode, id) + trimAt(s.endNode, id) + RoadConstants.SEGMENT_SWALLOW_MARGIN then
				swallowed = id
				break
			end
		end
		if not swallowed then
			break
		end
		local s = self._segments[swallowed] :: Segment
		local a = self._nodes[s.startNode] :: Node
		local b = self._nodes[s.endNode] :: Node
		-- Keep the busier entry so the bigger junction stays put; mergeNodes drops the
		-- arc between them on its own (it would collapse to a self-loop).
		local keep, drop = a, b
		if #b.segments > #a.segments then
			keep, drop = b, a
		end
		self:mergeNodes(keep.id, drop.id)
		isReal[drop.id] = nil
		merged = true
	end
	if merged then
		local kept: { { id: NodeId, angle: number } } = {}
		for _, e in real do
			if self._nodes[e.id] then
				kept[#kept + 1] = e
			end
		end
		real = kept
	end

	local needs = merged
	for _, id in ringIds do
		local s = self._segments[id]
		-- A fused pair collapsed its arc; mergeNodes already dropped it.
		if not s then
			continue
		end
		local span = angleAt(s.p0) - angleAt(s.p3)
		if span <= 0 then span += 2 * math.pi end
		-- A stub between two entries is irreducible -- the player put them there.
		if span > RING_MAX_SPAN + 1e-4
			or (span < RING_MIN_SPAN and not (isReal[s.startNode] and isReal[s.endNode])) then
			needs = true
			break
		end
	end
	if not needs then
		return false
	end

	-- Target node ring, walking CLOCKWISE (decreasing angle) the way traffic circulates.
	table.sort(real, function(a, b)
		return a.angle < b.angle
	end)
	local seq: { { id: NodeId?, angle: number } } = {}
	if #real == 0 then
		local n = RoadConstants.ROUNDABOUT_ARC_COUNT
		for k = 0, n - 1 do
			seq[#seq + 1] = { angle = -k * RING_MAX_SPAN }
		end
	else
		for i = #real, 1, -1 do
			local hi = real[i]
			local loAngle = if i > 1 then real[i - 1].angle else real[#real].angle - 2 * math.pi
			seq[#seq + 1] = { id = hi.id, angle = hi.angle }
			local span = hi.angle - loAngle
			local cuts = math.max(1, math.ceil(span / RING_MAX_SPAN))
			for k = 1, cuts - 1 do
				seq[#seq + 1] = { angle = hi.angle - span * k / cuts }
			end
		end
	end

	-- Old arcs go, and their tessellation nodes with them (removeSegment drops a node
	-- once nothing is left on it). Real nodes survive on their approach road. The centre
	-- preset lives on the arcs, so carry it over to the new ones.
	local preset: string? = nil
	for _, id in ringIds do
		local s = self._segments[id]
		preset = preset or (s and s.roundaboutPreset)
		self:removeSegment(id)
	end

	local nodes: { Node } = {}
	for i, e in seq do
		local existing = if e.id then self._nodes[e.id] else nil
		nodes[i] = existing
			or self:_createNode(Vector3.new(center.X + radius * math.cos(e.angle), center.Y, center.Z + radius * math.sin(e.angle)))
	end

	local meta = { isRoundabout = true, roundaboutId = raId, center = center, radius = radius, preset = preset }
	for i = 1, #nodes do
		local a = nodes[i]
		local b = nodes[(i % #nodes) + 1]
		local span = angleAt(a.position) - angleAt(b.position)
		if span <= 1e-6 then span += 2 * math.pi end
		local h = (4 / 3) * radius * math.tan(span / 4)
		local t0 = angleAt(a.position)
		local t1 = angleAt(b.position)
		linkRingArc(self, a, b,
			a.position + Vector3.new(math.sin(t0), 0, -math.cos(t0)) * h,
			b.position - Vector3.new(math.sin(t1), 0, -math.cos(t1)) * h,
			info.roadType, meta)
	end

	-- removeSegment dropped the descriptor with the last old arc; the ring is still here.
	self._roundabouts[raId] = info
	return true
end

-- Re-lay every ring an edit touched. Called once per mutation batch.
function RoadNetwork.reflowDirtyRoundabouts(self: RoadNetwork, trimAt: ((NodeId, SegmentId) -> number)?): boolean
	local rings: { [number]: boolean } = {}
	for nid in self._dirtyNode do
		local info = self:getRoundaboutForNode(nid)
		if info and self._roundabouts[info.id] then
			rings[info.id] = true
		end
	end
	local any = false
	for raId in rings do
		-- Re-tessellating can itself join two entries into one arc the mouths swallow, and
		-- fusing that pair re-lays the ring again -- so run until it settles. Each pass either
		-- changes the ring or stops, and each merge drops an entry, so this is a handful of
		-- passes at worst; the cap is only there to make that impossible to get wrong.
		for _ = 1, 4 do
			if not self:reflowRoundabout(raId, trimAt) then
				break
			end
			any = true
		end
	end
	return any
end

export type FilletResult = {
	changed: { SegmentId },
	arcId: SegmentId,
	removedNode: NodeId,
}

function RoadNetwork.filletCorner(self: RoadNetwork, nodeId: NodeId, radius: number): FilletResult?
	local V = self._nodes[nodeId]
	if not V or #V.segments ~= 2 then
		return nil
	end
	local idA, idB = V.segments[1], V.segments[2]
	if idA == idB then
		return nil
	end
	local A, B = self._segments[idA], self._segments[idB]
	if not A or not B then
		return nil
	end
	local vpos = V.position

	local aStart = A.startNode == nodeId
	local bStart = B.startNode == nodeId
	local farA = if aStart then A.p3 else A.p0
	local farB = if bStart then B.p3 else B.p0

	local va, vb = farA - vpos, farB - vpos
	local lenA, lenB = va.Magnitude, vb.Magnitude
	if lenA < 1e-3 or lenB < 1e-3 then
		return nil
	end

	local rawDA = if aStart then (A.p1 - A.p0) else (A.p2 - A.p3)
	local rawDB = if bStart then (B.p1 - B.p0) else (B.p2 - B.p3)
	local magDA, magDB = rawDA.Magnitude, rawDB.Magnitude

	local da = if magDA > 1e-3 then rawDA / magDA else va / lenA
	local db = if magDB > 1e-3 then rawDB / magDB else vb / lenB

	if (da + db).Magnitude < 1e-3 then
		return nil
	end

	local maxHalfWidth = math.max(
		RoadTypeCatalog.getOrDefault(A.roadType).width,
		RoadTypeCatalog.getOrDefault(B.roadType).width
	) * 0.5
	local minCenterRadius = maxHalfWidth
		+ RoadConstants.SIDEWALK_WIDTH * 0.5
		+ RoadConstants.JUNCTION_MIN_INNER_CURB_RADIUS
	local centerRadius = math.max(radius, minCenterRadius)
	local turnAngle = math.acos(math.clamp(da:Dot(db), -1, 1))
	local tangentPullback = centerRadius / math.max(math.tan(turnAngle * 0.5), 1e-3)
	local t = math.min(tangentPullback, lenA * 0.45, lenB * 0.45)
	if t < 0.5 then
		return nil
	end

	local T1 = vpos + da * t
	local T2 = vpos + db * t

	local arcLenA = BezierUtil.length(A.p0, A.p1, A.p2, A.p3, 16)
	local arcLenB = BezierUtil.length(B.p0, B.p1, B.p2, B.p3, 16)
	local sA = math.clamp(t / math.max(arcLenA, 1e-3), 0, 0.9)
	local sB = math.clamp(t / math.max(arcLenB, 1e-3), 0, 0.9)

	if aStart then

		local _, _, _, _, rp0, rp1, rp2, rp3 =
			BezierUtil.splitAt(A.p0, A.p1, A.p2, A.p3, sA)
		T1 = rp0
		A.p0, A.p1, A.p2, A.p3 = rp0, rp1, rp2, rp3
	else

		local lp0, lp1, lp2, lp3 =
			BezierUtil.splitAt(A.p0, A.p1, A.p2, A.p3, 1 - sA)
		T1 = lp3
		A.p0, A.p1, A.p2, A.p3 = lp0, lp1, lp2, lp3
	end
	if bStart then
		local _, _, _, _, rp0, rp1, rp2, rp3 =
			BezierUtil.splitAt(B.p0, B.p1, B.p2, B.p3, sB)
		T2 = rp0
		B.p0, B.p1, B.p2, B.p3 = rp0, rp1, rp2, rp3
	else
		local lp0, lp1, lp2, lp3 =
			BezierUtil.splitAt(B.p0, B.p1, B.p2, B.p3, 1 - sB)
		T2 = lp3
		B.p0, B.p1, B.p2, B.p3 = lp0, lp1, lp2, lp3
	end

	local nT1 = self:_createNode(T1)
	local nT2 = self:_createNode(T2)
	if aStart then A.startNode = nT1.id else A.endNode = nT1.id end
	if bStart then B.startNode = nT2.id else B.endNode = nT2.id end
	table.insert(nT1.segments, idA)
	table.insert(nT2.segments, idB)

	local tanT1 = if aStart
		then BezierUtil.tangent(A.p0, A.p1, A.p2, A.p3, 0).Unit
		else -BezierUtil.tangent(A.p0, A.p1, A.p2, A.p3, 1).Unit
	local tanT2 = if bStart
		then BezierUtil.tangent(B.p0, B.p1, B.p2, B.p3, 0).Unit
		else -BezierUtil.tangent(B.p0, B.p1, B.p2, B.p3, 1).Unit
	local actualRadius = t * math.tan(turnAngle * 0.5)
	local k = actualRadius * (4 / 3) * math.tan(turnAngle * 0.25)
	local arcId = self._nextSegmentId
	self._nextSegmentId += 1
	local arc: Segment = {
		id = arcId,
		startNode = nT1.id,
		endNode = nT2.id,
		roadType = A.roadType,
		name = A.name,
		p0 = T1,
		p1 = T1 - tanT1 * k,
		p2 = T2 - tanT2 * k,
		p3 = T2,
		isArc = true,
	}
	self._segments[arcId] = arc
	table.insert(nT1.segments, arcId)
	table.insert(nT2.segments, arcId)

	table.clear(V.segments)

	self._dirtySeg[idA] = true
	self._dirtySeg[idB] = true
	self._dirtySeg[arcId] = true
	self._dirtyNode[nT1.id] = true
	self._dirtyNode[nT2.id] = true
	self._dirtyNode[nodeId] = true

	return { changed = { idA, idB }, arcId = arcId, removedNode = nodeId }
end

-- Closest segment whose surface band (half-width + split tolerance) covers `pos` on its own
-- layer -- the same probe getOrCreateJunctionNode uses to decide what a drawn endpoint joins.
local function nearestBandSegment(self: RoadNetwork, pos: Vector3): (Segment?, number?)
	local margin = RoadConstants.SEGMENT_SPLIT_TOLERANCE
	local vtol = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	local bestSeg: Segment? = nil
	local bestT: number? = nil
	local bestDist = math.huge
	for _, seg in self._segments do
		local band = RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5 + margin
		-- Hull broad-phase before the ~35 curve evaluations in closestParam: on a grown city
		-- almost every segment is nowhere near this point, and this probe runs over the whole
		-- network twice per placement.
		if not BezierUtil.hullNear(seg.p0, seg.p1, seg.p2, seg.p3, pos, band, vtol) then continue end
		local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, pos, RoadConstants.SNAP_SEGMENT_SAMPLES)
		local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		if math.abs(p.Y - pos.Y) > vtol then continue end
		local d = flatDist(p, pos)
		if d <= band and d < bestDist then
			bestDist = d
			bestSeg = seg
			bestT = t
		end
	end
	return bestSeg, bestT
end

-- Paved reach of a junction: how far its fill and corner fans actually extend from the node.
-- Two junctions closer together than this are ONE junction -- their fills would sit on top of
-- each other -- so the graph welds them instead of drawing both. Beyond it they stay separate
-- and the link between them keeps its own crosswalks, which is what tells the player there are
-- two. Nothing is ever refused for being close; this only decides merge-or-not.
function RoadNetwork.junctionMergeRadius(self: RoadNetwork, nodeId: NodeId): number
	local node = self._nodes[nodeId]
	if not node then
		return RoadConstants.NODE_WELD_RADIUS
	end
	local maxHw = 0
	for _, sid in node.segments do
		local s = self._segments[sid]
		if s then
			maxHw = math.max(maxHw, RoadTypeCatalog.getOrDefault(s.roadType).width * 0.5)
		end
	end
	return maxHw + RoadConstants.JUNCTION_CORNER_RADIUS + RoadConstants.JUNCTION_MERGE_MARGIN
end

-- Every arm already leaving the junction an endpoint at `pos` would join, each direction
-- pointing AWAY from the node -- the convention validateAngles measures against and
-- ApproachBend bends clear of. An endpoint welding to a node reports that node's segments;
-- one T-joining a road BODY reports the host's tangent both ways, since the split makes two
-- arms out of it. Empty in open ground, which is the "nothing to bend around" answer.
function RoadNetwork.armDirsAt(self: RoadNetwork, pos: Vector3): { Vector3 }
	local out: { Vector3 } = {}
	local node = self:findNodeNear(pos)
	if not node then
		local hostSeg, hostT = nearestBandSegment(self, pos)
		if not hostSeg or not hostT then
			return out
		end
		local hostHw = RoadTypeCatalog.getOrDefault(hostSeg.roadType).width * 0.5
		local endWeld = if hostSeg.isRoundabout
			then RoadConstants.SEGMENT_SPLIT_TOLERANCE
			else math.max(RoadConstants.NODE_WELD_RADIUS, hostHw + RoadConstants.JUNCTION_MARGIN)
		local sN = self._nodes[hostSeg.startNode]
		local eN = self._nodes[hostSeg.endNode]
		if sN and flatDist(pos, sN.position) <= endWeld then
			node = sN
		elseif eN and flatDist(pos, eN.position) <= endWeld then
			node = eN
		else
			local raw = BezierUtil.tangent(hostSeg.p0, hostSeg.p1, hostSeg.p2, hostSeg.p3, hostT)
			local hf = Vector3.new(raw.X, 0, raw.Z)
			if hf.Magnitude > 1e-4 then
				out[1] = hf.Unit
				out[2] = -hf.Unit
			end
			return out
		end
	end
	if not node then
		return out
	end
	for _, sid in node.segments do
		local s = self._segments[sid]
		if not s then continue end
		local raw: Vector3
		if s.startNode == node.id then
			raw = s.p1 - s.p0
			if raw.Magnitude < 1e-3 then raw = s.p3 - s.p0 end
		else
			raw = s.p2 - s.p3
			if raw.Magnitude < 1e-3 then raw = s.p0 - s.p3 end
		end
		local f = Vector3.new(raw.X, 0, raw.Z)
		if f.Magnitude > 1e-4 then
			out[#out + 1] = f.Unit
		end
	end
	return out
end

function RoadNetwork.validateAngles(self: RoadNetwork, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string?): string?
	local threshold = RoadConstants.MIN_INTERSECTION_ANGLE_RAD
	if threshold <= 1e-6 then
		return nil
	end
	local newHw = RoadTypeCatalog.getOrDefault(roadType).width * 0.5
	local candLen = BezierUtil.length(p0, p1, p2, p3, 16)

	local tanStart = Vector3.new(p1.X - p0.X, 0, p1.Z - p0.Z)
	-- Away from the node at BOTH ends, matching the away-from-node arm directions below.
	-- The old into-the-node tanEnd measured 180-minus the real angle at p3: shallow end
	-- joins passed the gate (the giant paved delta) and near-straight continuations
	-- tripped it.
	local tanEnd = Vector3.new(p2.X - p3.X, 0, p2.Z - p3.Z)
	local chord = p3 - p0
	if tanStart.Magnitude < 1e-3 then
		tanStart = Vector3.new(chord.X, 0, chord.Z)
	end
	if tanEnd.Magnitude < 1e-3 then
		tanEnd = Vector3.new(-chord.X, 0, -chord.Z)
	end
	if tanStart.Magnitude < 1e-3 then return nil end
	local startDir = tanStart.Unit
	local endDir = tanEnd.Unit

	for _, endpointInfo in {
		{ pos = p0, candidateDir = startDir },
		{ pos = p3, candidateDir = endDir },
		} do
		local pos = endpointInfo.pos
		local candidateDir: Vector3 = endpointInfo.candidateDir
		local node = self:findNodeNear(pos)
		if not node then
			-- The endpoint can still merge into an end node whose weld disc is wider than
			-- SNAP_RADIUS (endWeld grows with the host's width), or T-split the host's
			-- body. Both build junction corner fillets, so both face the angle gate here
			-- instead of blowing out at render time.
			local hostSeg, hostT = nearestBandSegment(self, pos)
			if hostSeg and hostT then
				local hostHw = RoadTypeCatalog.getOrDefault(hostSeg.roadType).width * 0.5
				local endWeld = if hostSeg.isRoundabout
					then RoadConstants.SEGMENT_SPLIT_TOLERANCE
					else math.max(RoadConstants.NODE_WELD_RADIUS, hostHw + RoadConstants.JUNCTION_MARGIN)
				local sN = self._nodes[hostSeg.startNode]
				local eN = self._nodes[hostSeg.endNode]
				if sN and flatDist(pos, sN.position) <= endWeld then
					node = sN
				elseif eN and flatDist(pos, eN.position) <= endWeld then
					node = eN
				else
					-- T-join into the body: same fillet geometry as a crossing, same minimum.
					local raw = BezierUtil.tangent(hostSeg.p0, hostSeg.p1, hostSeg.p2, hostSeg.p3, hostT)
					local hf = Vector3.new(raw.X, 0, raw.Z)
					if hf.Magnitude > 1e-4 then
						local tAng = math.acos(math.clamp(math.abs(candidateDir:Dot(hf.Unit)), 0, 1))
						if tAng < RoadConstants.MIN_CROSSING_ANGLE_RAD then
							return string.format(
								"joins the road too sharply (%.0f deg < %.0f deg min)",
								math.deg(tAng), math.deg(RoadConstants.MIN_CROSSING_ANGLE_RAD)
							)
						end
					end
				end
			end
		end
		if not node then continue end
		for _, sid in node.segments do
			local s = self._segments[sid]
			if not s then continue end

			local raw: Vector3
			if s.startNode == node.id then
				raw = s.p1 - s.p0
				if raw.Magnitude < 1e-3 then
					raw = s.p3 - s.p0
				end
			else
				raw = s.p2 - s.p3
				if raw.Magnitude < 1e-3 then
					raw = s.p0 - s.p3
				end
			end
			if raw.Magnitude < 1e-3 then continue end
			local existDir = Vector3.new(raw.X, 0, raw.Z).Unit

			local dot = math.clamp(candidateDir:Dot(existDir), -1, 1)
			local angle = math.acos(dot)

			if angle > 1e-3 and angle < threshold then
				return string.format(
					"angle too shallow (%.1f deg < %.0f deg min)",
					math.deg(angle),
					math.deg(threshold)
				)
			end

			-- Shallow fork: both arms leave the node on the same side. The renderer pushes
			-- BOTH mouths back ~(hw1+hw2+nose)/(2 sin(angle/2)) so a corner curb fits the
			-- gore; an arm shorter than roughly twice that pushback can't honour it and the
			-- approaches pile up (overlapping sidewalks, buried crosswalks). Reject instead.
			if angle > 1e-3 and dot >= RoadConstants.FORK_COS_MIN then
				local armHw = RoadTypeCatalog.getOrDefault(s.roadType).width * 0.5
				local req = (newHw + armHw + RoadConstants.FORK_NOSE_MARGIN) / (2 * math.max(math.sin(angle * 0.5), 1e-3))
				local armLen = BezierUtil.length(s.p0, s.p1, s.p2, s.p3, 16)
				local needed = req * 2 + 4
				if math.min(armLen, candLen) < needed then
					return string.format(
						"roads fork too tightly (%.0f deg needs ~%.0f studs of road on both sides)",
						math.deg(angle), needed
					)
				end
			end
		end
	end
	return nil
end

-- Reject a body-to-body crossing that meets an existing road at too shallow an angle. Such a
-- crossing's junction must span (otherHalf / sin angle) along each road -- past the renderer's
-- reach cap below ~20deg -- so the fill/markings can't cover it and the road tears. A hit inside
-- an end node's weld disc merges into that node (resolveCrossings' rule), so the candidate is
-- checked against EVERY arm already at that node instead of being skipped like the old
-- interior-only gate did. Endpoint joins are handled by validateAngles.
-- Extra reach checkPlacement's parallel-overlap sweep wants beyond the candidate's own
-- footprint; the widest pad any single validation pass asks for, so the shared scan below
-- collects to it and tighter passes just re-test the bounds it already cached.
local OVERLAP_SCAN_PAD = 40

-- One broad-phase for a whole placement validation.
--
-- checkCrossingAngle, checkJunctionCurvature and checkPlacement each walked EVERY segment
-- recomputing boundsOf, and the first two then re-ran the very same segHit sweep the third
-- had already done -- four passes over the network per placement, three of them duplicating
-- work, each segHit re-sampling BOTH curves into fresh tables (25 points each) to test 576
-- chord pairs. Building this once and handing it to all three collapses that to a single pass.
--
--   bounds : the candidate's own control hull
--   near   : every segment within OVERLAP_SCAN_PAD + footprint, each with its bounds cached
--            so a consumer wanting a TIGHTER pad re-tests without recomputing them
--   hits   : segHit result per segment id, over the pad-0 subset, computed exactly once
--
-- Only valid while the network is unmutated -- it is built and consumed inside one validate().
export type PlacementScan = {
	bounds: SegBounds,
	near: { { seg: Segment, bounds: SegBounds } },
	hits: { [SegmentId]: { ha: number, hb: number, hp: Vector3 } },
}

function RoadNetwork.scanPlacement(self: RoadNetwork, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string?): PlacementScan
	local spec = RoadTypeCatalog.getOrDefault(roadType)
	local newFoot = spec.width * 0.5 + (if spec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
	local candBounds = boundsOf(p0, p1, p2, p3)
	-- vMode nil matches what all three consumers passed to segHit before this existed.
	local cand = { p0 = p0, p1 = p1, p2 = p2, p3 = p3, vMode = nil } :: any
	local near: { { seg: Segment, bounds: SegBounds } } = {}
	local hits: { [SegmentId]: { ha: number, hb: number, hp: Vector3 } } = {}
	for _, seg in self._segments do
		local b = boundsOf(seg.p0, seg.p1, seg.p2, seg.p3)
		if not boundsNear(candBounds, b, newFoot + OVERLAP_SCAN_PAD) then continue end
		near[#near + 1] = { seg = seg, bounds = b }
		if boundsNear(candBounds, b, 0) then
			local ha, hb, hp = segHit(cand, seg)
			if ha and hb and hp then
				hits[seg.id] = { ha = ha :: number, hb = hb :: number, hp = hp :: Vector3 }
			end
		end
	end
	return { bounds = candBounds, near = near, hits = hits }
end

function RoadNetwork.checkCrossingAngle(self: RoadNetwork, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string?, scan: PlacementScan?): string?
	local threshold = RoadConstants.MIN_CROSSING_ANGLE_RAD
	if threshold <= 1e-6 then return nil end
	-- Standalone callers (specs, tooling) still work: they just pay for their own scan.
	local sc = scan or self:scanPlacement(p0, p1, p2, p3, roadType)
	for _, entry in sc.near do
		local B = entry.seg
		if B.isArc or B.isRoundabout then continue end
		if not boundsNear(sc.bounds, entry.bounds, 0) then continue end
		local hit = sc.hits[B.id]
		if not hit then continue end
		local hav, hbv, hpv = hit.ha, hit.hb, hit.hp
		local ta = BezierUtil.tangent(p0, p1, p2, p3, hav)
		local af = Vector3.new(ta.X, 0, ta.Z)
		if af.Magnitude < 1e-4 then continue end
		af = af.Unit

		-- Which of B's end nodes (if any) this hit welds into -- the same rule
		-- resolveCrossings.endNodeNear uses, so validation judges the junction that
		-- will actually be built.
		local hostHw = RoadTypeCatalog.getOrDefault(B.roadType).width * 0.5
		local wr = math.max(RoadConstants.NODE_WELD_RADIUS, hostHw + RoadConstants.JUNCTION_MARGIN)
		local sN = self._nodes[B.startNode]
		local eN = self._nodes[B.endNode]
		local weldNode: Node? = nil
		if hbv <= 0.02 then
			weldNode = sN
		elseif hbv >= 0.98 then
			weldNode = eN
		else
			local dS = if sN then flatDist(hpv, sN.position) else math.huge
			local dE = if eN then flatDist(hpv, eN.position) else math.huge
			if math.min(dS, dE) <= wr then
				weldNode = if dS <= dE then sN else eN
			end
		end

		if weldNode then
			-- The candidate's own end welding at the same spot is an endpoint JOIN
			-- (one smoothed arm) -- validateAngles owns that case.
			local candWeld = math.max(RoadConstants.NODE_WELD_RADIUS, RoadTypeCatalog.getOrDefault(roadType).width * 0.5 + RoadConstants.JUNCTION_MARGIN)
			local endKiss = hav <= 0.02 or hav >= 0.98
				or flatDist(hpv, p0) <= candWeld or flatDist(hpv, p3) <= candWeld
			if not endKiss then
				-- The candidate runs THROUGH the welded node (two opposite arms), so it
				-- must clear the crossing minimum against every arm already there -- a
				-- shallow pair blows the corner fillets out to the reach cap (the giant
				-- stretched junction).
				for _, sid in weldNode.segments do
					local s = self._segments[sid]
					if not s then continue end
					local raw = if s.startNode == weldNode.id then s.p1 - s.p0 else s.p2 - s.p3
					if raw.Magnitude < 1e-3 then
						raw = if s.startNode == weldNode.id then s.p3 - s.p0 else s.p0 - s.p3
					end
					local bf = Vector3.new(raw.X, 0, raw.Z)
					if bf.Magnitude < 1e-4 then continue end
					local ang = math.acos(math.clamp(math.abs(af:Dot(bf.Unit)), 0, 1))
					if ang < threshold then
						return string.format("crosses the junction too sharply (%.0f deg < %.0f deg min)", math.deg(ang), math.deg(threshold))
					end
				end
			end
		elseif hav > 0.05 and hav < 0.95 and hbv > 0.05 and hbv < 0.95 then
			local tb = BezierUtil.tangent(B.p0, B.p1, B.p2, B.p3, hbv)
			local bf = Vector3.new(tb.X, 0, tb.Z)
			if bf.Magnitude > 1e-4 then
				local ang = math.acos(math.clamp(math.abs(af:Dot(bf.Unit)), 0, 1))
				if ang < threshold then
					return string.format("crossing too sharp (%.0f deg < %.0f deg min)", math.deg(ang), math.deg(threshold))
				end
			end
		end
	end
	return nil
end

-- Max flat-tangent rotation (radians) within `reach` arc-length of param t0, walking both
-- directions and clamping to the curve's ends.
local function bendWithinReach(s0: Vector3, s1: Vector3, s2: Vector3, s3: Vector3, t0: number, reach: number): number
	local refRaw = BezierUtil.tangent(s0, s1, s2, s3, t0)
	local ref = Vector3.new(refRaw.X, 0, refRaw.Z)
	if ref.Magnitude < 1e-4 then
		return 0
	end
	ref = ref.Unit
	local worst = 0
	for _, dirSign in { -1, 1 } do
		local span = if dirSign < 0 then t0 else 1 - t0
		if span > 1e-4 then
			local steps = 16
			local acc = 0
			local prev = BezierUtil.point(s0, s1, s2, s3, t0)
			for i = 1, steps do
				local t = t0 + dirSign * span * (i / steps)
				local pt = BezierUtil.point(s0, s1, s2, s3, t)
				acc += (pt - prev).Magnitude
				prev = pt
				local raw = BezierUtil.tangent(s0, s1, s2, s3, t)
				local flat = Vector3.new(raw.X, 0, raw.Z)
				if flat.Magnitude > 1e-4 then
					worst = math.max(worst, math.acos(math.clamp(ref:Dot(flat.Unit), -1, 1)))
				end
				if acc >= reach then
					break
				end
			end
		end
	end
	return worst
end

-- Reject a crossing or T-join where either road BENDS hard within the junction's reach of
-- the join point. Arm mouths anchor to the real curve, but the corner fillet/curb geometry
-- needs the arms to leave the node roughly straight; past this bend the rim loop folds (the
-- mangled junction on a sharp curve). checkCrossingAngle rejects shallow ANGLES at the hit
-- point; this rejects sharp TURNS around it.
function RoadNetwork.checkJunctionCurvature(self: RoadNetwork, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string?, scan: PlacementScan?): string?
	local maxBend = RoadConstants.JUNCTION_APPROACH_MAX_BEND
	if maxBend <= 1e-6 then
		return nil
	end
	local candHw = RoadTypeCatalog.getOrDefault(roadType).width * 0.5
	local sc = scan or self:scanPlacement(p0, p1, p2, p3, roadType)

	local function fail(bend: number, reach: number): string
		return string.format(
			"road bends too sharply for a junction here (%.0f deg within %.0f studs -- cross on a straighter stretch)",
			math.deg(bend), reach
		)
	end

	for _, entry in sc.near do
		local B = entry.seg
		if B.isArc or B.isRoundabout then continue end
		if not boundsNear(sc.bounds, entry.bounds, 0) then continue end
		local hostHw = RoadTypeCatalog.getOrDefault(B.roadType).width * 0.5
		local reach = RoadConstants.JUNCTION_MAX_REACH_FACTOR * math.max(candHw, hostHw)

		-- Body-to-body crossing: both roads turn through the junction, check both.
		local hit = sc.hits[B.id]
		if hit then
			local bendHost = bendWithinReach(B.p0, B.p1, B.p2, B.p3, hit.hb, reach)
			if bendHost > maxBend then
				return fail(bendHost, reach)
			end
			local bendCand = bendWithinReach(p0, p1, p2, p3, hit.ha, reach)
			if bendCand > maxBend then
				return fail(bendCand, reach)
			end
		end

		-- Drawn endpoint landing on B's body (a T-join; segHit's interior guard skips these):
		-- placement splits B there, so B's turn through the reach matters the same way.
		for _, pos in { p0, p3 } do
			local t = BezierUtil.closestParam(B.p0, B.p1, B.p2, B.p3, pos, RoadConstants.SNAP_SEGMENT_SAMPLES)
			local cp = BezierUtil.point(B.p0, B.p1, B.p2, B.p3, t)
			if flatDist(cp, pos) <= hostHw + RoadConstants.SEGMENT_SPLIT_TOLERANCE then
				local sN = self._nodes[B.startNode]
				local eN = self._nodes[B.endNode]
				local endWeld = math.max(RoadConstants.NODE_WELD_RADIUS, hostHw + RoadConstants.JUNCTION_MARGIN)
				local weldsIntoEnd = (sN ~= nil and flatDist(pos, sN.position) <= endWeld)
					or (eN ~= nil and flatDist(pos, eN.position) <= endWeld)
				if not weldsIntoEnd then
					local bendHost = bendWithinReach(B.p0, B.p1, B.p2, B.p3, t, reach)
					if bendHost > maxBend then
						return fail(bendHost, reach)
					end
				end
			end
		end
	end
	return nil
end

function RoadNetwork.checkCurvature(self: RoadNetwork, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string?): string?
	local minR = BezierUtil.minRadius(p0, p1, p2, p3, 20)
	local limit = RoadTypeCatalog.minCurveRadius(RoadTypeCatalog.getOrDefault(roadType))
	if minR < limit then
		return string.format("curve too tight (radius %.1f < min %.1f studs)", minR, limit)
	end
	return nil
end

-- The dead-end node an endpoint at `pos` will actually WELD to, with its segment.
--
-- It has to be found the way addSegment finds it (getOrCreateJunctionNode): that weld disc
-- scales with the host's width -- max(NODE_WELD_RADIUS, hostHalf + JUNCTION_MARGIN) -- while
-- findNodeNear is a flat SNAP_RADIUS of 12. Only the WIDE roads are wide enough to open a gap
-- between the two: 20.5 studs against 12 on Highway5W, 18.5 on Highway4, 17 on Highway4W,
-- 13.5 on Highway3W, and none at all below that. Every endpoint inside that band skipped this
-- gate (findNodeNear saw no node) while addSegment welded it anyway and slid the whole piece
-- onto the node, so a shallow wide-highway bend was placed with no corner check at all and
-- rendered as two overlapping carriageways.
local function deadEndWeldTarget(self: RoadNetwork, pos: Vector3): (Node?, Segment?)
	local vtol = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	local bestNode: Node? = nil
	local bestSeg: Segment? = nil
	local bestDist = math.huge
	for _, node in self._nodes do
		if #node.segments ~= 1 then continue end
		if math.abs(node.position.Y - pos.Y) > vtol then continue end
		local seg = self._segments[node.segments[1]]
		if not seg or seg.isRoundabout then continue end
		local hostHw = RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5
		local weld = math.max(RoadConstants.NODE_WELD_RADIUS, hostHw + RoadConstants.JUNCTION_MARGIN)
		local d = flatDist(node.position, pos)
		if d <= weld and d < bestDist then
			bestDist = d
			bestNode = node
			bestSeg = seg
		end
	end
	return bestNode, bestSeg
end

-- Each endpoint that welds to an existing dead-end (a degree-1 node) turns it into a degree-2
-- corner, and RoadSceneRenderer fills that bend with a connector arc. That arc bypasses
-- checkCurvature, so a sharp enough weld folds its inner curb (the mangled 3-stud sliver).
-- A degree-2 bend also gets none of the shallow-fork gore pushback (RoadSceneRenderer's
-- forkRequiredReach and friends all return early below 3 arms), so this gate is the only
-- thing standing between a shallow weld and two overlapping carriageways.
-- Reject the placement when the connector would fall below the road's fold radius.
function RoadNetwork.checkCornerRadius(self: RoadNetwork, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string?): string?
	local newSpec = RoadTypeCatalog.getOrDefault(roadType)
	local newHw = newSpec.width * 0.5
	for _, ep in {
		{ pos = p0, away = p1 - p0 },
		{ pos = p3, away = p2 - p3 },
	} do
		local node, seg = deadEndWeldTarget(self, ep.pos)
		if not node or not seg then continue end
		local existRaw = if seg.startNode == node.id then (seg.p1 - seg.p0) else (seg.p2 - seg.p3)
		local existDir = Vector3.new(existRaw.X, 0, existRaw.Z)
		local newDir = Vector3.new(ep.away.X, 0, ep.away.Z)
		if existDir.Magnitude < 1e-3 or newDir.Magnitude < 1e-3 then continue end
		local existSpec = RoadTypeCatalog.getOrDefault(seg.roadType)
		local minR = IntersectionRenderer.connectorMinRadius(existDir.Unit, existSpec.width * 0.5, newDir.Unit, newHw)
		-- The connector matches the narrower arm, so judge it against that arm's fold radius.
		local connSpec = if existSpec.width <= newSpec.width then existSpec else newSpec
		local limit = RoadTypeCatalog.minCornerRadius(connSpec)
		if minR < limit then
			return string.format("turn too sharp (corner radius %.1f < min %.0f studs)", minR, limit)
		end
	end
	return nil
end

-- Reject a curve sweeping through a foreign node's paving without connecting to it.
-- `ignore`: node ids that belong to the caller's own edit (a moved segment's ends).
-- `weldHits`: crossing points resolveCrossings will weld into an end node -- the node
-- they land on is a legitimate connection. `crossedSegs`: segments the curve truly
-- crosses; a bend node on a crossed segment is exempt (the split + sliver dissolve
-- own that geometry). Shared by checkPlacement and the Move tool.
function RoadNetwork.checkNodeFootprintOverlap(self: RoadNetwork, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string?, ignore: { [NodeId]: boolean }?, weldHits: { Vector3 }?, crossedSegs: { [SegmentId]: boolean }?): string?
	local newSpec = RoadTypeCatalog.getOrDefault(roadType)
	local newFoot = newSpec.width * 0.5 + (if newSpec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
	local candBounds = boundsOf(p0, p1, p2, p3)
	local DISC_SAMPLES = 24
	for _, node in self._nodes do
		local deg = #node.segments
		if deg == 0 then continue end
		if ignore and ignore[node.id] then continue end
		local maxHw = 0
		for _, sid in node.segments do
			local s = self._segments[sid]
			if s then
				maxHw = math.max(maxHw, RoadTypeCatalog.getOrDefault(s.roadType).width * 0.5)
			end
		end
		-- Endpoints welding into this node become a legitimate new arm -- exempt.
		local weldR = math.max(RoadConstants.NODE_WELD_RADIUS, maxHw + RoadConstants.JUNCTION_MARGIN)
		if flatDist(p0, node.position) <= weldR or flatDist(p3, node.position) <= weldR then continue end
		-- A crossing that welds into this node is a connection, not an overlap.
		if weldHits then
			local welded = false
			for _, hp in weldHits do
				if flatDist(hp, node.position) <= weldR then
					welded = true
					break
				end
			end
			if welded then continue end
		end
		-- A node on a segment the curve truly crosses: the crossing splits that segment and
		-- welds into the node, so this is a CONNECTION, not an overlap. That now covers
		-- junctions (deg 3+) as well as bends -- driving a road straight across an existing
		-- intersection is a legal move that puts a point on it, and used to be refused with
		-- "too close to an existing intersection".
		-- ponytail: crossing a segment far away while ALSO clipping its bend elsewhere
		-- slips this exemption; the parallel-overlap check is the net for that.
		if deg >= 2 and crossedSegs then
			local crossed = false
			for _, sid in node.segments do
				if crossedSegs[sid] then
					crossed = true
					break
				end
			end
			if crossed then continue end
		end
		local guard = if deg >= 3
			then maxHw + RoadConstants.JUNCTION_CORNER_RADIUS + newFoot
			elseif deg == 1 then maxHw + RoadConstants.SIDEWALK_WIDTH + newFoot
			else maxHw + newFoot
		local dx, dz = node.position.X - candBounds.cx, node.position.Z - candBounds.cz
		local rr = candBounds.r + guard
		if dx * dx + dz * dz > rr * rr then continue end
		for i = 0, DISC_SAMPLES do
			local sp = BezierUtil.point(p0, p1, p2, p3, i / DISC_SAMPLES)
			if math.abs(sp.Y - node.position.Y) <= RoadConstants.VERTICAL_CONNECT_TOLERANCE
				and flatDist(sp, node.position) < guard then
				return if deg >= 3
					then "clips an intersection without connecting -- cross it or keep clear"
					else "runs over the end of an existing road -- connect to it or keep clear"
			end
		end
	end
	return nil
end

function RoadNetwork.checkPlacement(self: RoadNetwork, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string?, scan: PlacementScan?): string?
	local sc = scan or self:scanPlacement(p0, p1, p2, p3, roadType)

	-- Crossings that weld into an existing end node, and every segment the curve truly
	-- crosses: both feed the node-footprint check below so a genuine connection is never
	-- mistaken for a silent overlap.
	local weldHits: { Vector3 } = {}
	local crossedSegs: { [SegmentId]: boolean } = {}

	for _, entry in sc.near do
		local B = entry.seg
		if not boundsNear(sc.bounds, entry.bounds, 0) then continue end
		local hit = sc.hits[B.id]
		if hit then
			local ha, hb, hp = hit.ha, hit.hb, hit.hp
			-- Corner fillet arcs are exempt from every angle/bend gate (checkCrossingAngle,
			-- checkJunctionCurvature skip isArc), so a crossing landing ON one dodges all
			-- validation and mangles the corner when resolveCrossings splits it. Not allowed.
			if B.isArc then
				return "can't cross a smoothed corner -- aim past it"
			end
			-- A crossing inside a segment-end weld radius merges into that node when placed
			-- (resolveCrossings welds it), so the node it lands on is a legitimate connection
			-- rather than paving the node's footprint over -- that is all weldHits is for.
			local hostHalf = RoadTypeCatalog.getOrDefault(B.roadType).width * 0.5
			local endWeld = if B.isRoundabout
				then RoadConstants.SEGMENT_SPLIT_TOLERANCE
				else math.max(RoadConstants.NODE_WELD_RADIUS, hostHalf + RoadConstants.JUNCTION_MARGIN)
			local sN = self._nodes[B.startNode]
			local eN = self._nodes[B.endNode]
			if (sN ~= nil and flatDist(hp :: Vector3, sN.position) <= endWeld)
				or (eN ~= nil and flatDist(hp :: Vector3, eN.position) <= endWeld) then
				weldHits[#weldHits + 1] = hp :: Vector3
			end
			crossedSegs[B.id] = true
		end
	end

	local margin = RoadConstants.SEGMENT_SPLIT_TOLERANCE
	for _, pos in { p0, p3 } do
		local bestSeg: Segment? = nil
		local bestDist = math.huge
		for _, seg in self._segments do
			local band = RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5 + margin
			-- Hull broad-phase first (same reason as nearestBandSegment): d below is a 3D
			-- distance, so `band` is a sound reject radius on both the plan and vertical gaps.
			if not BezierUtil.hullNear(seg.p0, seg.p1, seg.p2, seg.p3, pos, band, band) then continue end
			local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, pos, RoadConstants.SNAP_SEGMENT_SAMPLES)
			local cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
			local d = (cp - pos).Magnitude

			if d <= band and d < bestDist then
				bestDist = d; bestSeg = seg
			end
		end
		-- A drawn endpoint may not T-join a corner fillet arc: no angle gate covers those,
		-- and splitting one folds the corner geometry.
		if bestSeg and bestSeg.isArc then
			return "can't join onto a smoothed corner"
		end
	end

	-- No minimum spacing. Junctions may sit as close as the player likes: closer than a
	-- junction's paved reach they WELD into one big intersection (junctionMergeRadius,
	-- applied by resolveCrossings and getOrCreateJunctionNode), and further apart they stay
	-- two, with the link between them carrying its own crosswalks. The renderer already
	-- drops arrows and the speed numeral on a link with no room for them, so a cramped pair
	-- degrades its markings instead of being refused.

	local newSpec = RoadTypeCatalog.getOrDefault(roadType)
	-- Footprint half = carriageway + sidewalk. Overlap is judged on the full surface so two roads
	-- whose SIDEWALKS (not just lanes) glitch through each other are rejected, not only lane overlaps.
	local newFoot = newSpec.width * 0.5 + (if newSpec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
	local widthFactor = RoadConstants.PLACEMENT_OVERLAP_WIDTH_FACTOR
	local parallelCos = RoadConstants.PLACEMENT_OVERLAP_PARALLEL_COS
	local SAMPLES = 40
	-- Length-based overlap: a long road that runs over another for only a short stretch never
	-- reaches the whole-candidate fraction, so it slipped through. Also flag a sustained overlap
	-- with any SINGLE road, measured in studs (independent of the drawn road's length).
	local totalLen = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
	local minOverlapSamples = math.max(2, math.ceil(RoadConstants.PLACEMENT_OVERLAP_MIN_LENGTH / math.max(totalLen / SAMPLES, 1e-3)))
	local near = 0
	local overlapBySeg: { [number]: number } = {}
	-- Broad-phase once per segment (not per sample): only segments whose hull can reach
	-- the candidate's surface take part in the 40-sample overlap scan.
	local nearSegs: { Segment } = {}
	local nearBounds: { SegBounds } = {}
	for _, entry in sc.near do
		if boundsNear(sc.bounds, entry.bounds, newFoot + OVERLAP_SCAN_PAD) then
			nearSegs[#nearSegs + 1] = entry.seg
			nearBounds[#nearSegs] = entry.bounds
		end
	end
	for i = 1, SAMPLES - 1 do
		local t = i / SAMPLES
		local cp = BezierUtil.point(p0, p1, p2, p3, t)
		local ctan = BezierUtil.tangent(p0, p1, p2, p3, t)
		local cflat = Vector3.new(ctan.X, 0, ctan.Z)
		if cflat.Magnitude < 1e-4 then continue end
		cflat = cflat.Unit
		for k, seg in nearSegs do
			-- The curve lies inside its bounds circle, so a sample further than the overlap
			-- distance from the circle cannot count: skip the closest-point search. Exact.
			local b = nearBounds[k]
			local reachK = b.r + (newFoot + RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5 + RoadConstants.SIDEWALK_WIDTH) * widthFactor
			local bx, bz = cp.X - b.cx, cp.Z - b.cz
			if bx * bx + bz * bz > reachK * reachK then continue end
			local st = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, cp, 12)
			local sp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, st)
			if math.abs(sp.Y - cp.Y) <= RoadConstants.VERTICAL_CONNECT_TOLERANCE then
				local d = (Vector3.new(sp.X - cp.X, 0, sp.Z - cp.Z)).Magnitude
				local existSpec = RoadTypeCatalog.getOrDefault(seg.roadType)
				local existFoot = existSpec.width * 0.5 + (if existSpec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
				-- st in (0.05, 0.95) = the close point is in the existing road's INTERIOR, i.e. a road
				-- dragged ALONG its middle. A road CONNECTING end-to-end meets it at its endpoint
				-- (st ~0/1), which must NOT count or every joined dead-end reads as an overlap.
				if d < (newFoot + existFoot) * widthFactor and st > 0.05 and st < 0.95 then
					local stan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, st)
					local sflat = Vector3.new(stan.X, 0, stan.Z)
					if sflat.Magnitude > 1e-4 and math.abs(cflat:Dot(sflat.Unit)) > parallelCos then
						near += 1
						overlapBySeg[seg.id] = (overlapBySeg[seg.id] or 0) + 1
						break
					end
				end
			end
		end
	end
	if near / (SAMPLES - 1) > RoadConstants.PLACEMENT_OVERLAP_FRACTION then
		return "road overlaps an existing road"
	end
	for _, cnt in overlapBySeg do
		if cnt >= minOverlapSamples then
			return "road overlaps an existing road"
		end
	end

	-- A road may not cut through the paved footprint of ANY existing node -- junction
	-- fill + corner fans, a dead end's cul-de-sac cap, a bend's corner paving -- unless
	-- it genuinely connects there. Clipping a footprint crosses no centerline and runs
	-- perpendicular, so neither the crossing sweep nor the parallel overlap check sees
	-- it; it renders as two roads glitched through each other (the dangling dead-end-
	-- under-a-road bug).
	do
		local err = self:checkNodeFootprintOverlap(p0, p1, p2, p3, roadType, nil, weldHits, crossedSegs)
		if err then
			return err
		end
	end

	-- Roundabout entries must not crowd each other. Two approaches landing close together on
	-- the same ring merge into one overspilling junction: their carriageways and sidewalks
	-- overlap and the give-way markings get shoved back (the picture-1 bug). Reject a new
	-- entry that lands closer than the combined footprint -- both carriageways + both
	-- sidewalks + a junction margin -- to an existing entry on that ring. An endpoint is "on
	-- the ring" when its nearest roundabout arc is within that arc's connect band.
	local newHalf = RoadTypeCatalog.getOrDefault(roadType).width * 0.5
	for _, pos in { p0, p3 } do
		local ring: Segment? = nil
		local ringDist = math.huge
		for _, seg in self._segments do
			if not seg.isRoundabout then continue end
			local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, pos, RoadConstants.SNAP_SEGMENT_SAMPLES)
			local cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
			local d = (cp - pos).Magnitude
			local band = RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5 + margin
			if d <= band and d < ringDist then ring, ringDist = seg, d end
		end
		if ring then
			for _, node in self._nodes do
				local onSameRing, entryHalf = false, 0
				for _, sid in node.segments do
					local s = self._segments[sid]
					if s then
						if s.isRoundabout and s.roundaboutId == ring.roundaboutId then
							onSameRing = true
						elseif not s.isArc then
							entryHalf = math.max(entryHalf, RoadTypeCatalog.getOrDefault(s.roadType).width * 0.5)
						end
					end
				end
				if onSameRing and entryHalf > 0 then
					local need = newHalf + entryHalf + 2 * RoadConstants.SIDEWALK_WIDTH + RoadConstants.JUNCTION_MARGIN
					if (node.position - pos).Magnitude < need then
						return string.format("roundabout entries too close (keep %.0f studs apart)", need)
					end
				end
			end
		end
	end

	return nil
end

-- A network over topology that is already resolved: every row carries its node ids, so
-- nothing is welded or re-split. The placement preview builds one over its mirror of the
-- server graph, so it runs the same dry runs the server does.
function RoadNetwork.fromTopology(nodePositions: { [NodeId]: Vector3 }, segments: { [SegmentId]: Segment }): RoadNetwork
	local net = RoadNetwork.new()
	for id, pos in nodePositions do
		net._nodes[id] = { id = id, position = pos, segments = {} }
		net._nextNodeId = math.max(net._nextNodeId, id + 1)
	end
	for _, row in segments do
		local a, b = net._nodes[row.startNode], net._nodes[row.endNode]
		if not a or not b then continue end
		local seg = table.clone(row)
		net._segments[seg.id] = seg
		table.insert(a.segments, seg.id)
		table.insert(b.segments, seg.id)
		net._nextSegmentId = math.max(net._nextSegmentId, seg.id + 1)
	end
	return net
end

-- A private copy of just the roads an add can touch, to dry-run it on. The scan's pad
-- (candidate footprint + OVERLAP_SCAN_PAD) outreaches every weld, split and merge radius,
-- and every road at those roads' nodes rides along so each node's degree -- dead end,
-- joint, junction -- reads the same as in the real network. Copying everything instead cost
-- 42 ms on a 3000-segment city, every frame the preview moved.
local function nearbyCopy(self: RoadNetwork, scan: PlacementScan): RoadNetwork
	local rows: { [SegmentId]: Segment } = {}
	for _, entry in scan.near do
		for _, nodeId in { entry.seg.startNode, entry.seg.endNode } do
			local node = self._nodes[nodeId]
			if not node then continue end
			for _, sid in node.segments do
				rows[sid] = self._segments[sid]
			end
		end
	end
	local positions: { [NodeId]: Vector3 } = {}
	for _, s in rows do
		for _, nodeId in { s.startNode, s.endNode } do
			local node = self._nodes[nodeId]
			if node then positions[nodeId] = node.position end
		end
	end
	local trial = RoadNetwork.fromTopology(positions, rows)
	-- Ids continue past the REAL network's, so a trial id never aliases a live one.
	trial._nextNodeId = self._nextNodeId
	trial._nextSegmentId = self._nextSegmentId
	return trial
end

local function footprintHalf(seg: Segment): number
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	return spec.width * 0.5 + (if spec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
end

-- A road that ends up linking the same two nodes as an existing road while running right
-- beside it renders as two roads fused at both ends -- e.g. an alley whose crossing welds
-- into one junction and whose end T-joins the other alley just past it. Which nodes a road
-- links is only settled once crossings resolve, so dry-run the add on a copy. A bypass that
-- swings clear of the other road is a real second route and passes.
function RoadNetwork.checkParallelTwin(self: RoadNetwork, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string, vMode: string?, constSlope: boolean?, scan: PlacementScan?): string?
	local trial = nearbyCopy(self, scan or self:scanPlacement(p0, p1, p2, p3, roadType))
	local firstNew = trial._nextSegmentId
	trial:addSegment(p0, p1, p2, p3, roadType, vMode, constSlope)
	for id, s in trial._segments do
		local start = trial._nodes[s.startNode]
		if id < firstNew or not start or s.startNode == s.endNode then continue end
		for _, otherId in start.segments do
			local o = trial._segments[otherId]
			if not o or otherId == id then continue end
			local sameEnds = (o.startNode == s.startNode and o.endNode == s.endNode)
				or (o.startNode == s.endNode and o.endNode == s.startNode)
			if not sameEnds then continue end
			local reach = footprintHalf(s) + footprintHalf(o) + RoadConstants.SIDEWALK_WIDTH
			local beside = true
			for _, t in { 0.25, 0.5, 0.75 } do
				local p = BezierUtil.point(s.p0, s.p1, s.p2, s.p3, t)
				local ot = BezierUtil.closestParam(o.p0, o.p1, o.p2, o.p3, p, RoadConstants.SNAP_SEGMENT_SAMPLES)
				if flatDist(p, BezierUtil.point(o.p0, o.p1, o.p2, o.p3, ot)) > reach then
					beside = false
					break
				end
			end
			if beside then
				return "runs right beside an existing road between the same two junctions"
			end
		end
	end
	return nil
end

-- ============================ Integrity audit ============================
-- Self-heal pass: verifies the node<->segment graph and segment geometry, repairing
-- what it can when `fix` is true. Every repair lands in the dirty sets, so the owning
-- service's normal applyChanges pipeline re-renders/re-grades exactly the touched items.
export type AuditReport = {
	badGeometry: number,
	refFixes: number,
	endpointPins: number,
	duplicates: number,
	orphanNodes: number,
	crossingsResolved: number,
}

local function finiteVec(v: Vector3): boolean
	return v == v and v.Magnitude < math.huge
end

function RoadNetwork.audit(self: RoadNetwork, fix: boolean): AuditReport
	local rep: AuditReport = {
		badGeometry = 0, refFixes = 0, endpointPins = 0,
		duplicates = 0, orphanNodes = 0, crossingsResolved = 0,
	}

	-- 1) Segment geometry: non-finite or near-zero-length segments can't render or route.
	-- Duplicates (same curve, same type, stacked) double-render and double-count.
	local drop: { SegmentId } = {}
	local dupKey: { [string]: boolean } = {}
	for id, s in self._segments do
		if not (finiteVec(s.p0) and finiteVec(s.p1) and finiteVec(s.p2) and finiteVec(s.p3))
			or BezierUtil.length(s.p0, s.p1, s.p2, s.p3, 8) < 1 then
			rep.badGeometry += 1
			drop[#drop + 1] = id
		else
			local key = string.format("%.3f,%.3f,%.3f|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f|%s|%s|%s",
				s.p0.X, s.p0.Y, s.p0.Z, s.p1.X, s.p1.Y, s.p1.Z, s.p3.X, s.p3.Y, s.p3.Z,
				s.roadType, tostring(s.vMode), tostring(s.isRoundabout == true))
			if dupKey[key] then
				rep.duplicates += 1
				drop[#drop + 1] = id
			else
				dupKey[key] = true
			end
		end
	end
	if fix then
		for _, id in drop do
			self:removeSegment(id)
		end
	end

	-- 2) Node -> segment refs: drop entries pointing at dead segments or segments that
	-- don't reference this node back.
	for nid, node in self._nodes do
		for i = #node.segments, 1, -1 do
			local sid = node.segments[i]
			local s = self._segments[sid]
			if not s or (s.startNode ~= nid and s.endNode ~= nid) then
				rep.refFixes += 1
				if fix then
					table.remove(node.segments, i)
					self._dirtyNode[nid] = true
				end
			end
		end
	end

	-- 3) Segment -> node refs: recreate lost node records, re-list missing memberships.
	-- Memoized per lost id so every segment that referenced the same dead node reattaches
	-- to ONE recreated node (not a stack of coincident dead-ends).
	local recreated: { [NodeId]: Node } = {}
	for id, s in self._segments do
		local ends = { s.startNode, s.endNode }
		for i, nid in ends do
			local node = self._nodes[nid]
			if not node then
				rep.refFixes += 1
				if fix then
					local newNode = recreated[nid]
					if not newNode then
						newNode = self:_createNode(if i == 1 then s.p0 else s.p3)
						recreated[nid] = newNode
					end
					if i == 1 then s.startNode = newNode.id else s.endNode = newNode.id end
					if not table.find(newNode.segments, id) then
						table.insert(newNode.segments, id)
					end
					self._dirtySeg[id] = true
				end
			elseif not table.find(node.segments, id) then
				rep.refFixes += 1
				if fix then
					table.insert(node.segments, id)
					self._dirtyNode[nid] = true
				end
			end
		end
	end

	-- 3b) Parallel duplicates: two segments on the same path between the same pair of
	-- nodes. Step 1's key is the exact curve, so a pair whose handles differ slips past
	-- it -- which is every pair a merge produced. Heals saves written before the fix.
	if fix then
		local nids: { NodeId } = {}
		for nid in self._nodes do
			nids[#nids + 1] = nid
		end
		for _, nid in nids do
			rep.duplicates += self:dedupeParallel(nid)
		end
	end

	-- 4) Endpoint pin: a segment's p0/p3 must sit ON its node (mergeNodes/splits keep
	-- this; drift here means a torn junction mouth).
	for id, s in self._segments do
		local sn = self._nodes[s.startNode]
		if sn and (s.p0 - sn.position).Magnitude > 0.05 then
			rep.endpointPins += 1
			if fix then
				s.p0 = sn.position
				self._dirtySeg[id] = true
			end
		end
		local en = self._nodes[s.endNode]
		if en and (s.p3 - en.position).Magnitude > 0.05 then
			rep.endpointPins += 1
			if fix then
				s.p3 = en.position
				self._dirtySeg[id] = true
			end
		end
	end

	-- 5) Orphan nodes.
	for nid, node in self._nodes do
		if #node.segments == 0 then
			rep.orphanNodes += 1
			if fix then
				self._nodes[nid] = nil
				self._deadNode[nid] = true
				self._dirtyNode[nid] = nil
			end
		end
	end

	-- 6) Unresolved same-layer body crossings (two roads overlapping with no shared
	-- node): legacy saves / older placement bugs. resolveCrossings splits and welds them
	-- exactly like a fresh placement would have.
	local ids: { SegmentId } = {}
	local segBounds: { [SegmentId]: SegBounds } = {}
	for id, s in self._segments do
		ids[#ids + 1] = id
		segBounds[id] = boundsOf(s.p0, s.p1, s.p2, s.p3)
	end
	local seeds: { SegmentId } = {}
	local seeded: { [SegmentId]: boolean } = {}
	for i = 1, #ids do
		local A = self._segments[ids[i]]
		if not A or A.isArc then continue end
		for j = i + 1, #ids do
			local B = self._segments[ids[j]]
			if not B or B.isArc then continue end
			if A.isRoundabout and B.isRoundabout then continue end
			if A.startNode == B.startNode or A.startNode == B.endNode
				or A.endNode == B.startNode or A.endNode == B.endNode then continue end
			if not boundsNear(segBounds[ids[i]], segBounds[ids[j]], 0) then continue end
			local ha, hb = segHit(A, B)
			if ha and hb then
				rep.crossingsResolved += 1
				if not seeded[ids[i]] then
					seeded[ids[i]] = true
					seeds[#seeds + 1] = ids[i]
				end
				break
			end
		end
	end
	if fix and #seeds > 0 then
		self:resolveCrossings(seeds)
	end

	return rep
end

function RoadNetwork.getSegment(self: RoadNetwork, id: SegmentId): Segment?
	return self._segments[id]
end

function RoadNetwork.getSegments(self: RoadNetwork): { [SegmentId]: Segment }
	return self._segments
end

function RoadNetwork.getNodes(self: RoadNetwork): { [NodeId]: Node }
	return self._nodes
end

function RoadNetwork.removeSegment(self: RoadNetwork, id: SegmentId)
	local seg = self._segments[id]
	if not seg then
		return
	end
	local removedRoundaboutId = if seg.isRoundabout then seg.roundaboutId else nil
	self._segments[id] = nil
	self._dirtySeg[id] = true
	for _, nodeId in { seg.startNode, seg.endNode } do
		local node = self._nodes[nodeId]
		if node then
			local idx = table.find(node.segments, id)
			if idx then
				table.remove(node.segments, idx)
			end
			if #node.segments == 0 then
				self._nodes[nodeId] = nil
				self._deadNode[nodeId] = true
				self._dirtyNode[nodeId] = nil
			else
				self._dirtyNode[nodeId] = true
			end
		end
	end

	-- Drop the roundabout descriptor once its last ring arc is gone.
	if removedRoundaboutId then
		local stillThere = false
		for _, s in self._segments do
			if s.roundaboutId == removedRoundaboutId then
				stillThere = true
				break
			end
		end
		if not stillThere then
			self._roundabouts[removedRoundaboutId] = nil
		end
	end
end

return RoadNetwork
