--!strict
-- RoadPlacementSnapper
-- Placement math for the road tool: client-side topology mirror (nodes /
-- segments / intersections synced from the server), control-point construction
-- for each draw mode, parallel-mode offsetting, segment picking and client-side
-- pre-validation of a candidate curve. No instances, no input, no rendering --
-- RoadPlacementController feeds it state and draws elsewhere.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local RoadConstants   = require(ReplicatedStorage.Road.RoadConstants)
local SnapConstants   = require(ReplicatedStorage.Road.SnapUtil.SnapConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadRules       = require(ReplicatedStorage.Road.RoadRules)
local BezierUtil      = require(ReplicatedStorage.Road.BezierUtil)
local IntersectionRenderer = require(ReplicatedStorage.Road.IntersectionRenderer)
local ApproachBend    = require(ReplicatedStorage.Road.ApproachBend)
local RoadNetwork     = require(ReplicatedStorage.Road.RoadNetwork)
local SnapUtil        = require(ReplicatedStorage.Road.SnapUtil)
local CursorRay       = require(script.Parent.Parent.Core.CursorRay)

local RoadPlacementSnapper = {}

type Seg = { id: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string, startNode: number?, endNode: number?, isRoundabout: boolean?,
	-- Ring identity rides along with the mirror: the move tool grabs a roundabout as one object.
	roundaboutId: number?, roundaboutCenter: Vector3?, roundaboutRadius: number? }

export type CurveOpts = {
	mode: string,
	phase: string,
	start: Vector3?,
	curve: Vector3?,
	curve2: Vector3?,
	freeformTangent: Vector3?,
	angleSnapEnabled: boolean,
	lastSnapType: string?,
}

local _nodes: { Vector3 } = {}
local _segments: { Seg } = {}
local _nodeById: { [number]: Vector3 } = {}
local _segmentById: { [number]: Seg } = {}
local _segmentBounds: { [number]: { cx: number, cz: number, r: number, minY: number, maxY: number } } = {}
local _intersectionById: { [number]: Vector3 } = {}

-- Single change listener (the one-way arrow overlay), fired after the segment mirror
-- updates so the overlay rebuilds without polling.
local _changeListener: (() -> ())? = nil
local function notifyChange()
	if _changeListener then
		local ok, err = pcall(_changeListener :: any)
		if not ok then warn("[RoadPlacementSnapper] change listener failed: " .. tostring(err)) end
	end
end

local _lastValidateSig: string? = nil
local _lastValidateResult: string? = nil
-- The mirror as a RoadNetwork, for the dry runs validate borrows from the server. Built on
-- first use, dropped whenever the mirror is rebuilt.
local _topology: RoadNetwork.RoadNetwork? = nil

-- Live heading/length readout from the last angle-snapped controlPoints() call. Read by the
-- controller and shown in the preview card; cleared whenever angle snap did not apply.
local _headingDeg: number? = nil
local _headingRel: boolean? = nil
local _rawLen: number? = nil
local _snapLen: number? = nil
local _lenSnapped: boolean = false
local function clearHeadingInfo()
	_headingDeg = nil
	_headingRel = nil
	_rawLen = nil
	_snapLen = nil
	_lenSnapped = false
end

-- ------------------------------------------------------------------ caches --

local function rebuildNodeArray()
	local out: { Vector3 } = {}
	for _, pos in _nodeById do
		table.insert(out, pos)
	end
	_nodes = out
	_topology = nil
end

local function updateSegmentBounds(seg: Seg)
	local cx = (seg.p0.X + seg.p1.X + seg.p2.X + seg.p3.X) * 0.25
	local cz = (seg.p0.Z + seg.p1.Z + seg.p2.Z + seg.p3.Z) * 0.25
	local r = 0
	local minY = math.huge
	local maxY = -math.huge
	for _, p in { seg.p0, seg.p1, seg.p2, seg.p3 } do
		local dx, dz = p.X - cx, p.Z - cz
		r = math.max(r, math.sqrt(dx * dx + dz * dz))
		minY = math.min(minY, p.Y)
		maxY = math.max(maxY, p.Y)
	end
	_segmentBounds[seg.id] = { cx = cx, cz = cz, r = r, minY = minY, maxY = maxY }
end

local function rebuildSegmentArray()
	local out: { Seg } = {}
	table.clear(_segmentBounds)
	for _, seg in _segmentById do
		table.insert(out, seg)
		updateSegmentBounds(seg)
	end
	_segments = out
	_topology = nil
end

function RoadPlacementSnapper.invalidateCaches()
	_lastValidateSig = nil
	_lastValidateResult = nil
end

-- Server-sync ingestion. The controller owns the remote connections and routes
-- payloads (already shape-checked) here.
function RoadPlacementSnapper.setNodesFull(rows: { any })
	table.clear(_nodeById)
	for _, row in rows do
		if typeof(row) == "table" and typeof(row.id) == "number" and typeof(row.position) == "Vector3" then
			_nodeById[row.id] = row.position
		end
	end
	rebuildNodeArray()
end

function RoadPlacementSnapper.applyNodeDelta(delta: any)
	if typeof(delta) ~= "table" then return end
	local changed = delta.changed
	if typeof(changed) == "table" then
		for _, row in changed do
			if typeof(row) == "table" and typeof(row.id) == "number" and typeof(row.position) == "Vector3" then
				_nodeById[row.id] = row.position
			end
		end
	end
	local removed = delta.removed
	if typeof(removed) == "table" then
		for _, id in removed do
			if typeof(id) == "number" then
				_nodeById[id] = nil
			end
		end
	end
	rebuildNodeArray()
end

function RoadPlacementSnapper.setSegmentsFull(segs: { any })
	table.clear(_segmentById)
	for _, seg in segs do
		if typeof(seg) == "table" and typeof(seg.id) == "number" and typeof(seg.p0) == "Vector3" and typeof(seg.p1) == "Vector3" and typeof(seg.p2) == "Vector3" and typeof(seg.p3) == "Vector3" then
			seg.roadType = if typeof(seg.roadType) == "string" then seg.roadType else ""
			seg.startNode = if typeof(seg.startNode) == "number" then seg.startNode else nil
			seg.endNode = if typeof(seg.endNode) == "number" then seg.endNode else nil
			_segmentById[seg.id] = seg
		end
	end
	rebuildSegmentArray()
	SnapUtil.setSegments(_segmentById)
	RoadPlacementSnapper.invalidateCaches()
	notifyChange()
end

function RoadPlacementSnapper.applySegmentDelta(delta: any)
	if typeof(delta) ~= "table" then return end
	local changed = delta.changed
	if typeof(changed) == "table" then
		for _, seg in changed do
			if typeof(seg) == "table" and typeof(seg.id) == "number" and typeof(seg.p0) == "Vector3" and typeof(seg.p1) == "Vector3" and typeof(seg.p2) == "Vector3" and typeof(seg.p3) == "Vector3" then
				seg.roadType = if typeof(seg.roadType) == "string" then seg.roadType else ""
				seg.startNode = if typeof(seg.startNode) == "number" then seg.startNode else nil
				seg.endNode = if typeof(seg.endNode) == "number" then seg.endNode else nil
				_segmentById[seg.id] = seg
			end
		end
	end
	local removed = delta.removed
	if typeof(removed) == "table" then
		for _, id in removed do
			if typeof(id) == "number" then
				_segmentById[id] = nil
			end
		end
	end
	rebuildSegmentArray()
	SnapUtil.setSegments(_segmentById)
	RoadPlacementSnapper.invalidateCaches()
	notifyChange()
end

function RoadPlacementSnapper.applyIntersectionsPayload(payload: any)
	if typeof(payload) ~= "table" then return end
	local changed = payload.changed
	local removed = payload.removed
	if typeof(changed) == "table" then
		for _, entry in changed do
			if typeof(entry) == "table" and typeof(entry.id) == "number" and typeof(entry.position) == "Vector3" then
				_intersectionById[entry.id] = entry.position
			end
		end
	end
	if typeof(removed) == "table" then
		for _, id in removed do
			if typeof(id) == "number" then
				_intersectionById[id] = nil
			end
		end
	end
	local out: { Vector3 } = {}
	for _, pos in _intersectionById do
		table.insert(out, pos)
	end
	SnapUtil.setIntersectionCentres(out)
end

-- -------------------------------------------------------------- validation --

local function sameElevationLayer(a: Vector3, b: Vector3): boolean
	return math.abs(a.Y - b.Y) <= RoadConstants.VERTICAL_CONNECT_TOLERANCE
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function segmentNearCandidate(seg: Seg, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, padding: number): boolean
	local b = _segmentBounds[seg.id]
	if not b then return true end
	local cx = (p0.X + p1.X + p2.X + p3.X) * 0.25
	local cz = (p0.Z + p1.Z + p2.Z + p3.Z) * 0.25
	local r = 0
	local minY = math.huge
	local maxY = -math.huge
	for _, p in { p0, p1, p2, p3 } do
		local dx, dz = p.X - cx, p.Z - cz
		r = math.max(r, math.sqrt(dx * dx + dz * dz))
		minY = math.min(minY, p.Y)
		maxY = math.max(maxY, p.Y)
	end
	local dx, dz = cx - b.cx, cz - b.cz
	if math.sqrt(dx * dx + dz * dz) > r + b.r + padding then
		return false
	end
	local yPad = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	return maxY >= b.minY - yPad and minY <= b.maxY + yPad
end

-- First interior XZ crossing of the (pre-sampled) candidate against an existing segment, mirroring
-- the server's segHit. Returns the candidate/segment params at the crossing, or nil.
local function candidateCrossing(candPts: { Vector3 }, seg: Seg, samples: number): (number?, number?)
	for i = 0, samples - 1 do
		local a1 = candPts[i + 1]
		local a2 = candPts[i + 2]
		local rx, rz = a2.X - a1.X, a2.Z - a1.Z
		for j = 0, samples - 1 do
			local b1 = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, j / samples)
			local b2 = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, (j + 1) / samples)
			local sx, sz = b2.X - b1.X, b2.Z - b1.Z
			local rxs = rx * sz - rz * sx
			if math.abs(rxs) > 1e-9 then
				local qpx, qpz = b1.X - a1.X, b1.Z - a1.Z
				local t = (qpx * sz - qpz * sx) / rxs
				local u = (qpx * rz - qpz * rx) / rxs
				if t >= 0 and t <= 1 and u >= 0 and u <= 1 then
					local ya = a1.Y + (a2.Y - a1.Y) * t
					local yb = b1.Y + (b2.Y - b1.Y) * u
					if math.abs(ya - yb) <= RoadConstants.VERTICAL_CONNECT_TOLERANCE then
						return (i + t) / samples, (j + u) / samples
					end
				end
			end
		end
	end
	return nil
end

local function validateSig(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): string
	local function q(v: number): number return math.round(v * 10) end
	return table.concat({
		tostring(q(p0.X)), tostring(q(p0.Y)), tostring(q(p0.Z)),
		tostring(q(p1.X)), tostring(q(p1.Y)), tostring(q(p1.Z)),
		tostring(q(p2.X)), tostring(q(p2.Y)), tostring(q(p2.Z)),
		tostring(q(p3.X)), tostring(q(p3.Y)), tostring(q(p3.Z)),
	}, "|")
end

-- Client-side pre-check of a candidate curve so the ghost can show rejection
-- before a round-trip. The server re-validates authoritatively.
function RoadPlacementSnapper.validate(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): string?
	for _, p in { p0, p1, p2, p3 } do
		if not BezierUtil.isFiniteVector(p) then
			return "invalid road geometry"
		end
	end
	local sig = validateSig(p0, p1, p2, p3)
	if sig == _lastValidateSig then
		return _lastValidateResult
	end

	local function commit(result: string?): string?
		_lastValidateSig = sig
		_lastValidateResult = result
		return result
	end

	-- Both dirs point AWAY from their own endpoint, INTO the candidate road -- the convention
	-- the corner gate below and the server's RoadNetwork.validateAngles both use. tanEnd was
	-- (p3-p2), i.e. outward PAST p3, so drawing a dead-straight continuation INTO a junction
	-- measured 180deg off and any wobble read as a "too shallow" reject. The same road drawn
	-- outward from that junction passed.
	local tanStart = Vector3.new(p1.X - p0.X, 0, p1.Z - p0.Z)
	local tanEnd   = Vector3.new(p2.X - p3.X, 0, p2.Z - p3.Z)
	if tanStart.Magnitude < 1e-3 then tanStart = Vector3.new(p3.X - p0.X, 0, p3.Z - p0.Z) end
	if tanEnd.Magnitude   < 1e-3 then tanEnd   = Vector3.new(p0.X - p3.X, 0, p0.Z - p3.Z) end
	local dirStart = tanStart.Unit
	local dirEnd   = tanEnd.Unit

	local minR = BezierUtil.minRadius(p0, p1, p2, p3, 20)
	local minCurve = RoadTypeCatalog.minCurveRadius(RoadTypeCatalog.getOrDefault(SnapUtil.getActiveRoadType()))
	if minR < minCurve then
		return commit(string.format("curve too tight (radius %.1f < min %.0f studs)", minR, minCurve))
	end

	-- No grade gate, mirroring the server: height is unrestricted.

	if BezierUtil.selfIntersects(p0, p1, p2, p3, 28, RoadConstants.VERTICAL_CONNECT_TOLERANCE) then
		return commit("road would cross itself")
	end

	-- Reject a body crossing that meets an existing road too sharply (mirrors server
	-- RoadNetwork.checkCrossingAngle so the ghost reads red BEFORE the click, not on reject).
	if RoadConstants.MIN_CROSSING_ANGLE_RAD > 1e-6 and #_segments > 0 then
		local thr = RoadConstants.MIN_CROSSING_ANGLE_RAD
		local CS = 24
		local candPts = table.create(CS + 1)
		for i = 0, CS do candPts[i + 1] = BezierUtil.point(p0, p1, p2, p3, i / CS) end
		for _, seg in _segments do
			if seg.isRoundabout then continue end
			if not segmentNearCandidate(seg, p0, p1, p2, p3, RoadConstants.SNAP_SEGMENT_RADIUS) then continue end
			local ha, hb = candidateCrossing(candPts, seg, CS)
			if ha and hb and ha > 0.05 and ha < 0.95 and hb > 0.05 and hb < 0.95 then
				local ta = BezierUtil.tangent(p0, p1, p2, p3, ha)
				local tb = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, hb)
				local af = Vector3.new(ta.X, 0, ta.Z)
				local bf = Vector3.new(tb.X, 0, tb.Z)
				if af.Magnitude > 1e-4 and bf.Magnitude > 1e-4 then
					local ang = math.acos(math.clamp(math.abs(af.Unit:Dot(bf.Unit)), 0, 1))
					if ang < thr then
						return commit(string.format("crossing too sharp (%.0f deg)", math.deg(ang)))
					end
				end
			end
		end
	end

	if RoadConstants.MIN_INTERSECTION_ANGLE_RAD > 1e-6 then
		local threshold = RoadConstants.MIN_INTERSECTION_ANGLE_RAD
		for _, endpointInfo in {
			{ pos = p0, dir = dirStart },
			{ pos = p3, dir = dirEnd },
			} do
			local pos = endpointInfo.pos
			local candidateDir = endpointInfo.dir
			for _, n in _nodes do
				local nd = if sameElevationLayer(n, pos) then flatDistance(n, pos) else math.huge
				if nd > RoadConstants.SNAP_RADIUS then continue end
				for _, seg in _segments do
					local s0dist = if sameElevationLayer(seg.p0, n) then flatDistance(seg.p0, n) else math.huge
					local s3dist = if sameElevationLayer(seg.p3, n) then flatDistance(seg.p3, n) else math.huge
					-- Arm direction = the tangent leaving the node, not the p0->p3 chord: on a curved
					-- road those differ by the whole bend, so the chord false-rejected joins the
					-- server accepts. Mirrors RoadNetwork.validateAngles.
					local armRaw: Vector3?
					if s0dist <= RoadConstants.NODE_WELD_RADIUS then
						armRaw = seg.p1 - seg.p0
						if armRaw.Magnitude < 1e-3 then armRaw = seg.p3 - seg.p0 end
					elseif s3dist <= RoadConstants.NODE_WELD_RADIUS then
						armRaw = seg.p2 - seg.p3
						if armRaw.Magnitude < 1e-3 then armRaw = seg.p0 - seg.p3 end
					end
					if armRaw and armRaw.Magnitude > 1e-3 then
						local existDir = Vector3.new(armRaw.X, 0, armRaw.Z).Unit
						local dot = math.clamp(candidateDir:Dot(existDir), -1, 1)
						local angle = math.acos(dot)
						if angle > 1e-3 and angle < threshold then
							return commit(string.format("angle too shallow (%.0f deg)", math.deg(angle)))
						end
					end
				end
			end
		end
	end

	-- Corner-connector fold gate (mirrors RoadNetwork.checkCornerRadius). An endpoint welding to
	-- an existing dead-end forms a degree-2 bend the renderer fills with a connector arc; too sharp
	-- a bend folds that arc's inner curb. Reject before the round-trip so the ghost turns red.
	do
		local newSpec = RoadTypeCatalog.getOrDefault(SnapUtil.getActiveRoadType())
		local newHw = newSpec.width * 0.5
		for _, ep in {
			{ pos = p0, away = Vector3.new(p1.X - p0.X, 0, p1.Z - p0.Z) },
			{ pos = p3, away = Vector3.new(p2.X - p3.X, 0, p2.Z - p3.Z) },
		} do
			local existSeg: Seg? = nil
			local existRaw: Vector3? = nil
			local count = 0
			for _, seg in _segments do
				-- The weld disc the SERVER will use (RoadNetwork.getOrCreateJunctionNode), which
				-- scales with the host's width: 20.5 studs on the widest highway against a flat
				-- NODE_WELD_RADIUS of 12. With the narrow radius the ghost stayed green across
				-- that band and the shallow bend was welded anyway.
				local weld = math.max(
					RoadConstants.NODE_WELD_RADIUS,
					RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5 + RoadConstants.JUNCTION_MARGIN
				)
				local raw: Vector3? = nil
				if sameElevationLayer(seg.p0, ep.pos) and flatDistance(seg.p0, ep.pos) <= weld then
					raw = seg.p1 - seg.p0
				elseif sameElevationLayer(seg.p3, ep.pos) and flatDistance(seg.p3, ep.pos) <= weld then
					raw = seg.p2 - seg.p3
				end
				if raw then
					count += 1
					existSeg = seg
					existRaw = raw
				end
			end
			-- ponytail: count > 1 (a junction, or two ends in the widened disc) skips the gate and
			-- leaves the ghost green; the server still refuses on click. Mirror RoadNetwork's
			-- per-node test here if that green-then-refused flash starts mattering.
			if count == 1 and existSeg and existRaw then
				local existDir = Vector3.new(existRaw.X, 0, existRaw.Z)
				if existDir.Magnitude > 1e-3 and ep.away.Magnitude > 1e-3 then
					local existSpec = RoadTypeCatalog.getOrDefault(existSeg.roadType)
					local minR = IntersectionRenderer.connectorMinRadius(existDir.Unit, existSpec.width * 0.5, ep.away.Unit, newHw)
					local connSpec = if existSpec.width <= newSpec.width then existSpec else newSpec
					local limit = RoadTypeCatalog.minCornerRadius(connSpec)
					if minR < limit then
						return commit(string.format("turn too sharp (corner radius %.1f < min %.0f)", minR, limit))
					end
				end
			end
		end
	end

	if #_segments > 0 then
		local newSpec = RoadTypeCatalog.getOrDefault(SnapUtil.getActiveRoadType())
		local newHalf = newSpec.width * 0.5
		-- Footprint half = carriageway + sidewalk: overlap is judged on the full surface so two roads
		-- whose sidewalks (not just lanes) glitch through each other are rejected.
		local newFoot = newHalf + (if newSpec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
		local widthFactor = RoadConstants.PLACEMENT_OVERLAP_WIDTH_FACTOR
		local parallelCos = RoadConstants.PLACEMENT_OVERLAP_PARALLEL_COS
		-- Broad-phase pad covers the widest road's surface reach (max half-width 30) so a wide
		-- segment whose centre is far but whose surface overlaps isn't culled out.
		local cullPad = newHalf + 30 + RoadConstants.SNAP_SEGMENT_RADIUS
		local SAMPLES = 32
		-- Length-based overlap (mirrors server): flag a sustained overlap with any SINGLE road in
		-- studs, so a long road that runs over another for only a short stretch (under the
		-- whole-candidate fraction) is still caught.
		local totalLen = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
		local minOverlapSamples = math.max(2, math.ceil(RoadConstants.PLACEMENT_OVERLAP_MIN_LENGTH / math.max(totalLen / SAMPLES, 1e-3)))
		local near = 0
		local overlapBySeg: { [number]: number } = {}
		for s = 1, SAMPLES - 1 do
			local t = s / SAMPLES
			local cp = BezierUtil.point(p0, p1, p2, p3, t)
			local ctan = BezierUtil.tangent(p0, p1, p2, p3, t)
			local cflat = Vector3.new(ctan.X, 0, ctan.Z)
			if cflat.Magnitude < 1e-4 then continue end
			cflat = cflat.Unit
			for segKey, seg in _segments do
				if not segmentNearCandidate(seg, p0, p1, p2, p3, cullPad) then continue end
				local st = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, cp, 12)
				local sp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, st)
				if sameElevationLayer(sp, cp) then
					local d = flatDistance(sp, cp)
					local existSpec = RoadTypeCatalog.getOrDefault(seg.roadType)
					local existFoot = existSpec.width * 0.5 + (if existSpec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
					-- st interior = dragged ALONG the existing road's middle; st ~0/1 = an end-to-end
					-- connection at its endpoint, which must not count (else joining dead-ends is blocked).
					if d < (newFoot + existFoot) * widthFactor and st > 0.05 and st < 0.95 then
						local stan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, st)
						local sflat = Vector3.new(stan.X, 0, stan.Z)
						if sflat.Magnitude > 1e-4 and math.abs(cflat:Dot(sflat.Unit)) > parallelCos then
							near += 1
							overlapBySeg[segKey] = (overlapBySeg[segKey] or 0) + 1
							break
						end
					end
				end
			end
		end
		if near / (SAMPLES - 1) > RoadConstants.PLACEMENT_OVERLAP_FRACTION then
			return commit("overlaps an existing road")
		end
		for _, cnt in overlapBySeg do
			if cnt >= minOverlapSamples then
				return commit("overlaps an existing road")
			end
		end

	end

	-- Junctions are never refused for being close, and a road may run straight across one:
	-- close ones weld into a single bigger intersection, further ones stay separate and the
	-- link between them keeps its own crosswalks. The old junction-approach and minimum-
	-- spacing gates lived here and are gone.

	-- The server's last check (RoadNetwork.checkParallelTwin), so a road that would end up
	-- running right beside another between the same two junctions reads red before the click.
	if not _topology then
		_topology = RoadNetwork.fromTopology(_nodeById, _segmentById :: any)
	end
	local twinErr = (_topology :: RoadNetwork.RoadNetwork):checkParallelTwin(p0, p1, p2, p3, SnapUtil.getActiveRoadType())
	if twinErr then
		return commit(twinErr)
	end

	return commit(nil)
end

-- ----------------------------------------------------------- curve building --

-- The one circular arc that leaves `s` along `tangent` and lands on `e`: the exit tangent
-- is `tangent` mirrored about the chord, and handles of 2L/(3(1+cos t)) reproduce that arc
-- (L/3 when straight, 2L/3 for a semicircle). Chaining these keeps every join tangent-
-- continuous at a constant radius, which is what a real road does through a bend.
local function arcControlPoints(s: Vector3, tangent: Vector3, e: Vector3): (Vector3, Vector3, Vector3, Vector3)
	local chord = Vector3.new(e.X - s.X, 0, e.Z - s.Z)
	local len = chord.Magnitude
	if len < 0.001 then return s, s, e, e end
	local c = chord / len
	local t = Vector3.new(tangent.X, 0, tangent.Z)
	t = if t.Magnitude > 1e-4 then t.Unit else c
	local cosT = math.clamp(t:Dot(c), -1, 1)
	-- Approaching a full reversal the arc grows to a whole circle. Cap the handles so the
	-- ghost stays finite and let validate() reject the hairpin on its radius.
	local h = math.min(2 * len / (3 * math.max(1 + cosT, 0.08)), len * 2)
	local out = c * (2 * cosT) - t
	local dy = (e.Y - s.Y) / 3
	local p1 = s + t * h
	local p2 = e - out * h
	return s,
		Vector3.new(p1.X, s.Y + dy, p1.Z),
		Vector3.new(p2.X, e.Y - dy, p2.Z),
		e
end

function RoadPlacementSnapper.exitTangent(p2: Vector3, p3: Vector3): Vector3
	local d = p3 - p2
	if d.Magnitude < 0.001 then return Vector3.new(1, 0, 0) end
	return Vector3.new(d.X, 0, d.Z).Unit
end

local function straightControlPoints(s: Vector3, e: Vector3): (Vector3, Vector3, Vector3, Vector3)
	local chord = e - s
	return s, s + chord / 3, s + chord * (2 / 3), e
end

local function applyAngleSnap(s: Vector3, cursor: Vector3, angleSnapEnabled: boolean, lastSnapType: string?): Vector3
	if not angleSnapEnabled then return cursor end

	-- Real geometry wins over the angle magnet: a node weld, a kerb or a building frontage
	-- is a thing that is THERE, and must never be dragged off to a round angle.
	-- A guideline is NOT in that list. It is a suggestion, and a player squaring off a 90deg
	-- turn means the turn -- so the magnet is asked first, and the guide's answer is what we
	-- keep when the heading is nowhere near a right angle.
	if lastSnapType == "center" or lastSnapType == "intersection" or lastSnapType == "building" then
		return cursor
	end

	local r = SnapUtil.angleSnap(s, RoadPlacementSnapper.continuationDirAt(s), cursor)
	if not r then
		return cursor
	end

	_headingDeg = r.angleDeg
	_headingRel = r.angleRelative
	_rawLen = flatDistance(s, r.position)
	return r.position
end

-- Perpendicular T-junction snap. When the endpoint being placed sits on a road body
-- ("center" snap, not a node weld) and the approach comes in near a right angle, slide
-- the join along the host to the exact perpendicular foot from `anchor` -- the control
-- point that owns the curve's end tangent -- so the T lands at a true 90deg.
local function applyPerpSnap(anchor: Vector3, cursor: Vector3, lastSnapType: string?): Vector3
	if lastSnapType ~= "center" then return cursor end
	if not SnapUtil.isAngleSnapEnabled() or SnapUtil.isAngleFreeOverride() then return cursor end
	local segId = RoadPlacementSnapper.nearestSegmentId(cursor)
	if not segId then return cursor end
	local seg = _segmentById[segId]
	if not seg or seg.isRoundabout then return cursor end
	-- Node welds stay welded: never slide an endpoint join off its node.
	for _, p in { seg.p0, seg.p3 } do
		if sameElevationLayer(p, cursor) and flatDistance(p, cursor) <= RoadConstants.NODE_WELD_RADIUS then
			return cursor
		end
	end
	local head = Vector3.new(cursor.X - anchor.X, 0, cursor.Z - anchor.Z)
	if head.Magnitude < 1 then return cursor end
	local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, cursor, 24)
	local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local flatTan = Vector3.new(tan.X, 0, tan.Z)
	if flatTan.Magnitude < 1e-3 then return cursor end
	-- |unit dot| = sin(deviation from perpendicular)
	if math.abs(head.Unit:Dot(flatTan.Unit)) > math.sin(SnapConstants.PERP_SNAP_TOL) then return cursor end
	local tf = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, anchor, 32)
	local foot = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, tf)
	if flatDistance(foot, cursor) > SnapConstants.PERP_SNAP_MAX_SLIDE then return cursor end
	for _, p in { seg.p0, seg.p3 } do
		if flatDistance(foot, p) <= RoadConstants.NODE_WELD_RADIUS then return cursor end
	end
	return foot
end

-- Highway ramp join. A one-way highway drawn INTO another highway's body always lands
-- as a merging ramp: the end tangent is bent to blend with the host's travel direction
-- (the shallower side on a two-way host), whatever angle the player approached at.
-- Exits are free -- a road drawn FROM a highway may leave at any legal angle -- and a
-- two-way road crossing a highway still forms an ordinary intersection.
local function applyHighwayMerge(p0: Vector3?, p1: Vector3?, p2: Vector3?, p3: Vector3?, lastSnapType: string?): (Vector3?, Vector3?, Vector3?, Vector3?)
	if not (p0 and p1 and p2 and p3) then return p0, p1, p2, p3 end
	if lastSnapType ~= "center" then return p0, p1, p2, p3 end
	local newSpec = RoadTypeCatalog.getOrDefault(SnapUtil.getActiveRoadType())
	if not (newSpec.isHighway and newSpec.oneWay) then return p0, p1, p2, p3 end
	local segId = RoadPlacementSnapper.nearestSegmentId(p3)
	local seg = if segId then _segmentById[segId] else nil
	if not seg or seg.isRoundabout then return p0, p1, p2, p3 end
	local hostSpec = RoadTypeCatalog.getOrDefault(seg.roadType)
	if not hostSpec.isHighway then return p0, p1, p2, p3 end
	-- An endpoint welded onto the host's node keeps the normal join behavior.
	for _, p in { seg.p0, seg.p3 } do
		if sameElevationLayer(p, p3) and flatDistance(p, p3) <= RoadConstants.NODE_WELD_RADIUS then
			return p0, p1, p2, p3
		end
	end
	local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, p3, 24)
	local hostTan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local hd = Vector3.new(hostTan.X, 0, hostTan.Z)
	if hd.Magnitude < 1e-3 then return p0, p1, p2, p3 end
	hd = hd.Unit
	local approach = Vector3.new(p3.X - p2.X, 0, p3.Z - p2.Z)
	if approach.Magnitude < 1e-3 then approach = Vector3.new(p3.X - p0.X, 0, p3.Z - p0.Z) end
	if approach.Magnitude < 1e-3 then return p0, p1, p2, p3 end
	approach = approach.Unit
	-- One-way host: always merge downstream (one-way travel runs p0->p3). Divided host: into
	-- the carriageway on the ramp's OWN side -- the other one is across the median, and the
	-- junction is right-in/right-out, so a ramp aimed at it would lead nowhere. Other
	-- two-way host: whichever direction needs the smaller bend from the approach.
	local perp = approach - hd * approach:Dot(hd)
	if hostSpec.median and not hostSpec.oneWay and perp.Magnitude > 1e-3 then
		-- A direction's lanes lie on laneSide * (travel x up); the ramp comes in from -perp.
		local ownSide = hd:Cross(Vector3.yAxis) * RoadRules.getLaneSideSign()
		if ownSide:Dot(-perp) < 0 then
			hd = -hd
		end
	elseif not hostSpec.oneWay and approach:Dot(hd) < 0 then
		hd = -hd
	end
	-- Keep a hint of the approach side so the ramp leans into the carriageway like a
	-- real gore instead of kissing it dead-parallel.
	local a = SnapConstants.MERGE_JOIN_ANGLE_RAD
	local endDir = if perp.Magnitude > 1e-3
		then (hd * math.cos(a) + perp.Unit * math.sin(a)).Unit
		else hd
	local handle = math.min((p3 - p0).Magnitude * 0.34, SnapConstants.MERGE_HANDLE_MAX)
	return p0, p1, p3 - endDir * handle, p3
end

-- Control points for the current draw mode/phase, or nil when the gesture has
-- no curve yet.
local function controlPointsRaw(opts: CurveOpts, cursor: Vector3): (Vector3?, Vector3?, Vector3?, Vector3?)
	clearHeadingInfo()
	if opts.mode == "Straight" and opts.phase == "HasStart" and opts.start then
		local s = opts.start :: Vector3
		local e = applyAngleSnap(s, cursor, opts.angleSnapEnabled, opts.lastSnapType)
		e = applyPerpSnap(s, e, opts.lastSnapType)
		return straightControlPoints(s, e)

	elseif opts.mode == "Curved" then
		if opts.phase == "HasStart" and opts.start then
			local s, e = opts.start :: Vector3, cursor
			return s, s + (e - s) / 3, s + (e - s) * 2 / 3, e
		elseif opts.phase == "HasCurve" and opts.start and opts.curve then
			local s, q, e = opts.start :: Vector3, opts.curve :: Vector3, cursor
			e = applyPerpSnap(q, e, opts.lastSnapType)
			local firstHandle = s + (q - s) * (2 / 3)
			return s, firstHandle, e + (q - e) * (2 / 3), e
		end

	elseif opts.mode == "Freeform" then
		-- CS2 "Continuous": bend + end set the FIRST segment and with it the road's heading.
		-- After that every click is one whole segment -- the arc off the previous exit
		-- tangent to the cursor -- so the chain flows without ever placing another bend.
		if opts.phase == "HasStart" and opts.start then
			local s = opts.start :: Vector3
			if opts.freeformTangent then
				return arcControlPoints(s, opts.freeformTangent :: Vector3, applyPerpSnap(s, cursor, opts.lastSnapType))
			end
			-- No heading yet: this click picks the bend, so preview only the leg to it.
			return straightControlPoints(s, applyAngleSnap(s, cursor, opts.angleSnapEnabled, opts.lastSnapType))
		elseif opts.phase == "HasCurve" and opts.start and opts.curve then
			local s, q = opts.start :: Vector3, opts.curve :: Vector3
			local e = applyPerpSnap(q, cursor, opts.lastSnapType)
			return s, s + (q - s) * (2 / 3), e + (q - e) * (2 / 3), e
		end

	elseif opts.mode == "AdvancedCurve" then
		if opts.phase == "HasStart" and opts.start then
			local s, e = opts.start :: Vector3, cursor
			local ch = e - s
			return s, s + ch / 3, s + ch * (2 / 3), e
		elseif opts.phase == "HasCurve" and opts.start and opts.curve then
			local s, p1 = opts.start :: Vector3, opts.curve :: Vector3
			local tailHandle = cursor + (p1 - cursor) * (1 / 3)
			return s, p1, tailHandle, cursor
		elseif opts.phase == "HasCurve2" and opts.start and opts.curve and opts.curve2 then
			local c2 = opts.curve2 :: Vector3
			return opts.start :: Vector3, opts.curve :: Vector3, c2, applyPerpSnap(c2, cursor, opts.lastSnapType)
		end
	end
	return nil, nil, nil, nil
end

-- Arm directions already leaving the junction an endpoint at `pos` would join, each pointing
-- AWAY from the node. The client's copy of RoadNetwork.armDirsAt, over the mirrored graph, so
-- the ghost bends around exactly what the server will bend around.
local function armDirsAt(pos: Vector3): { Vector3 }
	local out: { Vector3 } = {}
	local node: Vector3? = nil
	local best = RoadConstants.SNAP_RADIUS
	for _, n in _nodes do
		if not sameElevationLayer(n, pos) then continue end
		local d = flatDistance(n, pos)
		if d <= best then best = d; node = n end
	end
	if node then
		local nodePos = node :: Vector3
		for _, seg in _segments do
			local raw: Vector3? = nil
			if sameElevationLayer(seg.p0, nodePos) and flatDistance(seg.p0, nodePos) <= RoadConstants.NODE_WELD_RADIUS then
				raw = seg.p1 - seg.p0
				if raw.Magnitude < 1e-3 then raw = seg.p3 - seg.p0 end
			elseif sameElevationLayer(seg.p3, nodePos) and flatDistance(seg.p3, nodePos) <= RoadConstants.NODE_WELD_RADIUS then
				raw = seg.p2 - seg.p3
				if raw.Magnitude < 1e-3 then raw = seg.p0 - seg.p3 end
			end
			if raw then
				local f = Vector3.new(raw.X, 0, raw.Z)
				if f.Magnitude > 1e-4 then out[#out + 1] = f.Unit end
			end
		end
		if #out > 0 then return out end
	end
	-- Not on a node: a T-join into a road BODY splits the host, so its tangent is two arms.
	local segId = RoadPlacementSnapper.nearestSegmentId(pos)
	local seg = if segId then _segmentById[segId] else nil
	if not seg then return out end
	local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, pos, 24)
	local cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local band = RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5 + RoadConstants.SEGMENT_SPLIT_TOLERANCE
	if not sameElevationLayer(cp, pos) or flatDistance(cp, pos) > band then return out end
	local raw = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local f = Vector3.new(raw.X, 0, raw.Z)
	if f.Magnitude > 1e-4 then
		out[1] = f.Unit
		out[2] = -f.Unit
	end
	return out
end

function RoadPlacementSnapper.controlPoints(opts: CurveOpts, cursor: Vector3): (Vector3?, Vector3?, Vector3?, Vector3?)
	local p0, p1, p2, p3 = controlPointsRaw(opts, cursor)
	p0, p1, p2, p3 = applyHighwayMerge(p0, p1, p2, p3, opts.lastSnapType)
	if p0 and p1 and p2 and p3 then
		-- CS2 approach shaping: an end meeting a junction shallower than the bend minimum is
		-- CURVED clear of the arms already there instead of turning the ghost red. The server
		-- re-applies the same module to the same graph, so what is drawn is what gets placed.
		local spec = RoadTypeCatalog.getOrDefault(SnapUtil.getActiveRoadType())
		p1, p2 = ApproachBend.apply(p0, p1, p2, p3, armDirsAt(p0), armDirsAt(p3), RoadTypeCatalog.minCurveRadius(spec))
	end
	return p0, p1, p2, p3
end

-- Every known segment id. The bulldozer's box / brush region delete iterates these and
-- tests each segment midpoint against the region.
function RoadPlacementSnapper.allSegmentIds(): { number }
	local ids: { number } = {}
	for id in _segmentById do
		ids[#ids + 1] = id
	end
	return ids
end

-- ------------------------------------------------------ picking / parallel --

-- Direction to CONTINUE a road straight off the node nearest `pos` (within weld radius):
-- points away from the connected segment's interior. Feeds relative-angle snap so 0deg = a
-- dead-straight continuation of the road you started on. nil when pos is not on a node.
function RoadPlacementSnapper.continuationDirAt(pos: Vector3): Vector3?
	local bestNodeId: number? = nil
	local bestD = RoadConstants.NODE_WELD_RADIUS
	for id, npos in _nodeById do
		if math.abs(npos.Y - pos.Y) > RoadConstants.VERTICAL_CONNECT_TOLERANCE then continue end
		local d = flatDistance(npos, pos)
		if d < bestD then bestD = d; bestNodeId = id end
	end
	if not bestNodeId then
		-- Not on a node: a start welded to a road BODY (mid-span T start) has no continuation,
		-- but the host tangent still makes the right reference -- relative angle steps then
		-- read 0deg = along the road and the strong 45deg pull makes a 90deg exit sticky.
		local segId = RoadPlacementSnapper.nearestSegmentId(pos)
		if not segId then return nil end
		local seg = _segmentById[segId]
		if not seg then return nil end
		local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, pos, 16)
		local cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		if not sameElevationLayer(cp, pos) or flatDistance(cp, pos) > 2 then return nil end
		local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local flat = Vector3.new(tan.X, 0, tan.Z)
		if flat.Magnitude < 1e-3 then return nil end
		return flat.Unit
	end
	for _, seg in _segments do
		local d: Vector3? = nil
		if seg.startNode == bestNodeId then
			d = Vector3.new(seg.p0.X - seg.p1.X, 0, seg.p0.Z - seg.p1.Z)
			if d.Magnitude < 1e-3 then d = Vector3.new(seg.p0.X - seg.p3.X, 0, seg.p0.Z - seg.p3.Z) end
		elseif seg.endNode == bestNodeId then
			d = Vector3.new(seg.p3.X - seg.p2.X, 0, seg.p3.Z - seg.p2.Z)
			if d.Magnitude < 1e-3 then d = Vector3.new(seg.p3.X - seg.p0.X, 0, seg.p3.Z - seg.p0.Z) end
		end
		if d and d.Magnitude > 1e-3 then
			return d.Unit
		end
	end
	return nil
end

-- Heading/length readout from the last controlPoints() call (angle-snapped modes only).
function RoadPlacementSnapper.getHeadingInfo(): { headingDeg: number?, relative: boolean?, rawLen: number?, snapLen: number?, lenSnapped: boolean }
	return {
		headingDeg = _headingDeg,
		relative   = _headingRel,
		rawLen     = _rawLen,
		snapLen    = _snapLen,
		lenSnapped = _lenSnapped,
	}
end

-- `maxDist` -- how far off a centreline still counts as this segment.
--   Omitted (SNAPPING callers): SNAP_SEGMENT_RADIUS * 1.5 = 30 studs, the existing
--   behaviour. That is a snapping tolerance and is deliberately NOT scaled by WORLD_SCALE
--   (see the note in RoadConstants) -- do not "fix" it here.
--   Supplied (PICKING callers): a screen-space tolerance from CursorRay.pickRadius. 30
--   studs is far too loose for "which road did I click" -- it grabbed roads a whole
--   carriageway away from the cursor -- and too tight zoomed right out.
-- `sameLayerOnly` gates on elevation. The distance test is XZ-only, so without it a bridge
-- deck or elevated highway passing overhead reads as being under the cursor. Off by
-- default so snapping behaviour is untouched.
function RoadPlacementSnapper.nearestSegmentId(worldPos: Vector3, maxDist: number?, sameLayerOnly: boolean?): number?
	-- Runs every RenderStepped frame while a delete/bulldoze hover is active: cull by the
	-- maintained bounding circles before any closestParam. The uncelled scan visited the
	-- whole city per frame -- the "opening the road/bulldoze tool lags" cost.
	local limit = maxDist or (SnapConstants.SNAP_SEGMENT_RADIUS * 1.5)
	local yPad = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	local bestId: number? = nil
	local bestDist = math.huge
	for _, seg in _segments do
		local b = _segmentBounds[seg.id]
		if b then
			local dx, dz = worldPos.X - b.cx, worldPos.Z - b.cz
			local reach = b.r + limit
			if dx * dx + dz * dz > reach * reach then continue end
			-- Cheap vertical cull off the same maintained bounds.
			if sameLayerOnly and (worldPos.Y < b.minY - yPad or worldPos.Y > b.maxY + yPad) then continue end
		end
		local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, worldPos, 16)
		local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		if sameLayerOnly and not sameElevationLayer(p, worldPos) then continue end
		local d = (Vector3.new(p.X, 0, p.Z) - Vector3.new(worldPos.X, 0, worldPos.Z)).Magnitude
		if d < bestDist then
			bestDist = d
			bestId = seg.id
		end
	end
	if bestDist <= limit then
		return bestId
	end
	return nil
end

-- "Which road did the player click?" -- the ONE answer to that question. Every tool that
-- picks a road (bulldoze, road delete/upgrade, one-way flip) goes through here so they all
-- agree; nearestSegmentId's bare default is a SNAPPING radius and must not be used for it.
--
-- Floor is a default road's own footprint, so clicking anywhere on the visible surface
-- always works and it scales with WORLD_SCALE for free (road widths already do). Above the
-- floor it widens to a constant on-screen allowance, so the click is no harder to land
-- zoomed out than it is up close. Elevation-gated: an overhead deck is not "under" a
-- cursor pointing at the street below it.
local PICK_PX = 14
local PICK_MAX = 60
function RoadPlacementSnapper.segmentUnderPoint(worldPos: Vector3): number?
	local floor = RoadConstants.ROAD_WIDTH * 0.5 + RoadConstants.SIDEWALK_WIDTH
	local slop = math.max(floor, CursorRay.pickRadius(worldPos, PICK_PX, 0, PICK_MAX))
	return RoadPlacementSnapper.nearestSegmentId(worldPos, slop, true)
end

-- Closest point on the nearest road's centreline to worldPos, or nil if no road is
-- within picking range. The roundabout drop tool uses this to centre the ring on a road.
-- Move tool: the nearest synced node within maxDist (flat) of a world point.
function RoadPlacementSnapper.nearestNodeId(worldPos: Vector3, maxDist: number): number?
	local bestId: number? = nil
	local best = maxDist
	for id, pos in _nodeById do
		local d = Vector2.new(pos.X - worldPos.X, pos.Z - worldPos.Z).Magnitude
		if d < best then
			best = d
			bestId = id
		end
	end
	return bestId
end

function RoadPlacementSnapper.getNodePos(id: number): Vector3?
	return _nodeById[id]
end

-- Live node mirror (id -> position). Read-only for callers; the Move tool's
-- marquee select iterates it. Do not mutate.
function RoadPlacementSnapper.getNodes(): { [number]: Vector3 }
	return _nodeById
end

function RoadPlacementSnapper.nearestRoadPoint(worldPos: Vector3): Vector3?
	local id = RoadPlacementSnapper.nearestSegmentId(worldPos)
	if not id then return nil end
	local seg = _segmentById[id]
	if not seg then return nil end
	local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, worldPos, 16)
	return BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
end

function RoadPlacementSnapper.getSegmentInfo(segmentId: number): { [string]: any }?
	local seg = _segmentById[segmentId]
	if not seg then
		return nil
	end

	return {
		id = seg.id,
		p0 = seg.p0,
		p1 = seg.p1,
		p2 = seg.p2,
		p3 = seg.p3,
		roadType = seg.roadType,
		startNode = seg.startNode,
		endNode = seg.endNode,
		isRoundabout = seg.isRoundabout,
		roundaboutId = seg.roundaboutId,
		roundaboutCenter = seg.roundaboutCenter,
		roundaboutRadius = seg.roundaboutRadius,
	}
end

function RoadPlacementSnapper.setChangeListener(fn: (() -> ())?)
	_changeListener = fn
end

-- The live segment-mirror array. Read-only for callers (the one-way arrow overlay
-- iterates it); do not mutate.
function RoadPlacementSnapper.getSegments(): { Seg }
	return _segments
end

-- Connected-road path (inclusive) from one segment to another over the node graph,
-- as an ordered list of segment ids. Empty when the two are on disjoint networks.
-- Drives the bulldozer drag: it lights up the whole run of road between anchor and cursor.
-- ponytail: rebuilds node->segments each call; cache on a segment-version stamp only if a
-- huge network ever makes the drag stutter (BFS is O(V+E), fine for normal cities).
function RoadPlacementSnapper.pathSegmentsBetween(fromId: number, toId: number): { number }
	if fromId == toId then
		return { fromId }
	end
	if not _segmentById[fromId] or not _segmentById[toId] then
		return {}
	end

	local byNode: { [number]: { number } } = {}
	for id, seg in _segmentById do
		for _, n in { seg.startNode, seg.endNode } do
			if typeof(n) == "number" then
				local list = byNode[n]
				if not list then
					list = {}
					byNode[n] = list
				end
				table.insert(list, id)
			end
		end
	end

	local prev: { [number]: number } = {}
	local visited: { [number]: boolean } = { [fromId] = true }
	local queue: { number } = { fromId }
	local head = 1
	local found = false
	while head <= #queue do
		local cur = queue[head]
		head += 1
		if cur == toId then
			found = true
			break
		end
		local seg = _segmentById[cur]
		if seg then
			for _, n in { seg.startNode, seg.endNode } do
				local neighbours = if typeof(n) == "number" then byNode[n] else nil
				if neighbours then
					for _, nb in neighbours do
						if not visited[nb] then
							visited[nb] = true
							prev[nb] = cur
							table.insert(queue, nb)
						end
					end
				end
			end
		end
	end

	if not found then
		return {}
	end

	local path: { number } = {}
	local node: number? = toId
	while node do
		table.insert(path, 1, node)
		if node == fromId then
			break
		end
		node = prev[node]
	end
	return path
end

-- Perpendicular offset vector for a parallel twin road: left of the primary's travel
-- direction (p0->p3), `dist` studs. nil for a degenerate curve.
function RoadPlacementSnapper.parallelOffsetVector(p0: Vector3, p3: Vector3, dist: number): Vector3?
	local dir = Vector3.new(p3.X - p0.X, 0, p3.Z - p0.Z)
	if dir.Magnitude < 1e-3 then return nil end
	dir = dir.Unit
	return Vector3.new(-dir.Z, 0, dir.X) * dist
end

-- @deprecated: parallel mode now places a twin road (RoadPlacementController), not a
-- sideways shift. Kept as a no-op passthrough so existing call sites compile.
function RoadPlacementSnapper.maybeParallelize(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, _hintPos: Vector3, _parallelMode: boolean, _roadType: string): (Vector3, Vector3, Vector3, Vector3)
	return p0, p1, p2, p3
end

-- ------------------------------------------------------------- zone checker --


return RoadPlacementSnapper
