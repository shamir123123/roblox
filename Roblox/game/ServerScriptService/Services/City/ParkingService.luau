--!strict
-- ParkingService
-- Owns parking. For every eligible road segment it DERIVES parallel parking spots (pure
-- Lua data: a CFrame + an occupied flag, NEVER Instances) along both kerbs, and hands the
-- nearest free one to CitizenService as a FALLBACK when a citizen's home driveway or
-- workplace lot has no room. Spots are derived from the live road network and rebuilt on
-- topology change; nothing is persisted and nothing is rendered here (RoadSceneRenderer
-- paints the lane; the only car that ever appears is the citizen's own car when it parks).
--
-- A car has to END UP SOMEWHERE. When nothing is free near the destination, reserveNearest
-- falls through to the nearest free stall in ANY car park within LOT_FALLBACK_RADIUS -- the
-- driver parks there and walks the rest (CitizenService's leg 3 already does the walking).
-- Kerbside bays stay radius-bound: a bay two districts away is not somewhere anyone would
-- leave a car, but a car park is exactly that.
--
-- A PLACED CAR PARK feeds the same index. The three standalone lots (NatureCatalog kind
-- "Lot") are baked with a `Stall` Attachment per bay, so every lot the player drops adds
-- its stalls here and reserveNearest starts handing them out -- no consumer changed, the
-- capacity is simply there. The lot model is the source of truth: it is what persists,
-- and the spots are re-derived from it whenever it appears, moves or is bulldozed.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NatureCatalog   = require(ReplicatedStorage.Nature.NatureCatalog)
local RoadConstants   = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local BezierUtil      = require(ReplicatedStorage.Road.BezierUtil)

local ParkingService = {}

-- segId is set for a kerbside spot, lot for a car-park stall. Exactly one of the two.
type Spot = { id: string, segId: number?, lot: boolean?, cf: CFrame, pos: Vector3, occupied: boolean }

local SPOT_SPACING     = 13   -- spot pitch (studs). Longest civilian car spawns ~10.5 long.
-- Gap between the last bay and the painted crossing. A car parked on the zebra hides the
-- pedestrian on it from the traffic that has to stop for them.
local CROSSING_CLEAR   = 4
-- A free end (dead end, or a plain bend between two segments of one street) carries no
-- stop line and no zebra, so a bay there only has to clear the segment's own tip.
local FREE_END_SETBACK = 6
local EDGE_INSET       = 0.8  -- pull the bay in from the very road edge
local CAR_SIT_Y        = 0.6  -- match CitizenService.CAR_HEIGHT so a parked car sits like a driving one
-- How far a driver will go OUT OF THEIR WAY to a car park once their own street is full.
local LOT_FALLBACK_RADIUS = 1200
local CELL             = RoadConstants.NAV_SPATIAL_CELL_SIZE
local UP               = Vector3.yAxis

local _roadService: any = nil
local _spots: { [string]: Spot } = {}
local _bySeg: { [number]: { string } } = {}
local _cells: { [string]: { string } } = {}
local _topoDisconnect: (() -> ())? = nil
-- Placed car parks -> the spot ids derived from them, plus the connection watching that
-- lot's slab for a move (the Move tool re-pivots planted props).
local _byLot: { [Model]: { ids: { string }, conn: RBXScriptConnection? } } = {}
local _lotSerial = 0
local _tagConns: { RBXScriptConnection } = {}

local function cellKey(cx: number, cz: number): string
	return tostring(cx) .. "," .. tostring(cz)
end

local function addToCell(spot: Spot)
	local key = cellKey(math.floor(spot.pos.X / CELL), math.floor(spot.pos.Z / CELL))
	local list = _cells[key]
	if not list then list = {}; _cells[key] = list end
	table.insert(list, spot.id)
end

local function removeFromCell(spot: Spot)
	local key = cellKey(math.floor(spot.pos.X / CELL), math.floor(spot.pos.Z / CELL))
	local list = _cells[key]
	if not list then return end
	local i = table.find(list, spot.id)
	if i then
		local n = #list
		list[i] = list[n]
		list[n] = nil
	end
end

local function dropSegment(segId: number)
	local ids = _bySeg[segId]
	if not ids then return end
	for _, id in ids do
		local spot = _spots[id]
		if spot then
			removeFromCell(spot)
			_spots[id] = nil
		end
	end
	_bySeg[segId] = nil
end

-- ------------------------------------------------------------------- car parks
local function isLot(model: Model): boolean
	local key = model:GetAttribute("NatureKey")
	local entry = if typeof(key) == "string" then NatureCatalog.get(key) else nil
	return entry ~= nil and entry.kind == "Lot"
end

local function forgetLotSpots(rec: { ids: { string } })
	for _, id in rec.ids do
		local spot = _spots[id]
		if spot then
			removeFromCell(spot)
			_spots[id] = nil
		end
	end
	table.clear(rec.ids)
end

local function dropLot(model: Model)
	local rec = _byLot[model]
	if not rec then return end
	if rec.conn then rec.conn:Disconnect() end
	forgetLotSpots(rec)
	_byLot[model] = nil
end

-- Re-derive one lot's stalls from its baked `Stall` attachments. Ids are reissued on every
-- rebuild, so a car holding a reservation across a move or a reload loses it and the stall
-- comes back free -- release() on a stale id is already a no-op.
local function buildLot(model: Model)
	local rec = _byLot[model]
	if rec then
		forgetLotSpots(rec)
	else
		rec = { ids = {} }
		_byLot[model] = rec
	end
	_lotSerial += 1
	local n = 0
	for _, d in model:GetDescendants() do
		if d:IsA("Attachment") and d.Name == "Stall" then
			n += 1
			local cf = d.WorldCFrame
			local p = cf.Position + Vector3.new(0, CAR_SIT_Y, 0)
			local id = "lot" .. tostring(_lotSerial) .. "#" .. tostring(n)
			local spot: Spot = { id = id, lot = true, cf = CFrame.lookAt(p, p + cf.LookVector, UP), pos = p, occupied = false }
			_spots[id] = spot
			addToCell(spot)
			table.insert(rec.ids, id)
		end
	end
	if not rec.conn then
		local slab = model:FindFirstChild("Slab")
		if slab and slab:IsA("BasePart") then
			rec.conn = slab:GetPropertyChangedSignal("CFrame"):Connect(function()
				buildLot(model)
			end)
		end
	end
end

-- Roadside parking only on ground-level streets whose type carries a parking lane.
-- Never on bridges/tunnels (no kerb), roundabout rings, or render-only arcs.
local function eligible(seg: any): boolean
	if not seg or seg.isArc or seg.isRoundabout then return false end
	if seg.vMode == "Elevated" or seg.vMode == "Tunnel" then return false end
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	return spec.parkingLane == true
end

-- Sample the curve into a polyline with cumulative arc length so spots can be spaced
-- by real distance and oriented along the true tangent.
local function sample(seg: any): ({ Vector3 }, { number })
	local n = 48
	local pts = table.create(n + 1)
	local cum = table.create(n + 1)
	local prev = seg.p0
	pts[1] = prev
	cum[1] = 0
	for i = 1, n do
		local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, i / n)
		pts[i + 1] = p
		cum[i + 1] = cum[i] + (p - prev).Magnitude
		prev = p
	end
	return pts, cum
end

local function atDistance(pts: { Vector3 }, cum: { number }, d: number): (Vector3, Vector3)
	local total = cum[#cum]
	d = math.clamp(d, 0, total)
	for i = 2, #cum do
		if cum[i] >= d then
			local span = cum[i] - cum[i - 1]
			local f = if span > 1e-6 then (d - cum[i - 1]) / span else 0
			local a, b = pts[i - 1], pts[i]
			local tan = b - a
			if tan.Magnitude < 1e-6 then tan = Vector3.new(0, 0, 1) end
			return a:Lerp(b, f), tan.Unit
		end
	end
	local last = pts[#pts] - pts[#pts - 1]
	return pts[#pts], (if last.Magnitude > 1e-6 then last.Unit else Vector3.new(0, 0, 1))
end

-- How far in from one END of a segment the first bay may sit. At a junction that is the
-- junction plate plus the whole painted approach band (stop line, gap, zebra, gap), so the
-- last bay stands BEHIND the crossing instead of on it or inside the intersection.
-- ponytail: mirrors RoadSceneRenderer's armMarkingSetback with the node's widest arm in
-- place of the exact per-arm junction boundary -- the fillet geometry that computes lives
-- in the renderer, and a bay is 13 studs long, not 0.1. If bays ever creep onto a zebra at
-- a shallow fork, that boundary is the number to plumb through.
-- Second value: the width this road narrows to at that end when its bays run on into the taper.
local function endSetback(net: any, seg: any, nodeId: number?): (number, number?)
	local node = if nodeId then net:getNodes()[nodeId] else nil
	if not node then return FREE_END_SETBACK, nil end
	if #node.segments == 2 then
		-- A join onto a NARROWER road (street -> alley) is not a plain bend: the renderer tapers
		-- this road down to it over ROAD_WIDTH_TRANSITION_LENGTH (RoadSceneRenderer.transitionAtNode).
		-- If that road parks too, the bays run on and follow the kerb in; if not, they stop before
		-- the taper instead of standing in the merge.
		-- ponytail: half the own width stands in for the renderer's corner hold (0 on a straight
		-- join), and "parks at all" for "parks on this side". Plumb nodeArmBoundary / per-side
		-- parking through if bays creep into a sharp-corner taper or a one-sided merge.
		local ownWidth = RoadTypeCatalog.getOrDefault(seg.roadType).width
		for _, sid in node.segments do
			local other = if sid ~= seg.id then net:getSegment(sid) else nil
			local nextSpec = if other then RoadTypeCatalog.getOrDefault(other.roadType) else nil
			if nextSpec and nextSpec.width < ownWidth - 1e-3 then
				if nextSpec.parkingLane then return FREE_END_SETBACK, nextSpec.width end
				return ownWidth * 0.5 + RoadConstants.ROAD_WIDTH_TRANSITION_LENGTH, nil
			end
		end
	end
	if #node.segments < 3 then return FREE_END_SETBACK, nil end
	local maxHalf = 0
	for _, sid in node.segments do
		local s = net:getSegment(sid)
		if s then
			maxHalf = math.max(maxHalf, RoadTypeCatalog.getOrDefault(s.roadType).width * 0.5)
		end
	end
	return maxHalf
		+ RoadConstants.JUNCTION_MARGIN
		+ RoadConstants.CROSSWALK_SETBACK
		+ RoadConstants.JUNCTION_FURNITURE_DEPTH
		+ CROSSING_CLEAR, nil
end

-- How far the kerb has come in, `fromNode` studs back from a join where this road narrows
-- from `ownWidth` to `toWidth` -- the renderer's smoothstep taper.
local function taperInset(ownWidth: number, toWidth: number?, fromNode: number): number
	if not toWidth then return 0 end
	local t = math.clamp(fromNode / RoadConstants.ROAD_WIDTH_TRANSITION_LENGTH, 0, 1)
	return (ownWidth - toWidth) * 0.5 * (1 - t * t * (3 - 2 * t))
end

local function buildSegment(seg: any)
	dropSegment(seg.id) -- regenerate cleanly; geometry/state may have changed
	if not eligible(seg) then return end
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	local plW = spec.parkingLaneWidth or 5
	-- Centre of the apron: half a lane out from the carriageway edge. Matches the
	-- apron strip RoadRenderer paints, so cars sit on the coloured parking lane and
	-- never overlap the driving carriageway.
	local lateral = RoadTypeCatalog.carriagewayWidth(spec) * 0.5 + plW * 0.5
	if lateral <= 1 then return end
	-- Spots only on the side(s) that actually carry the apron.
	local sides: { number } = if (spec.parkingSides or 2) >= 2 then { -1, 1 } else { 1 }

	local pts, cum = sample(seg)
	local total = cum[#cum]
	local ids: { string } = {}
	local n = 0
	-- Each end is measured on its own: a street can run from a signalised avenue junction
	-- (wide plate, full marking band) to a dead end (nothing to stand behind).
	local net = _roadService and _roadService.getNetwork()
	local headSetback, tailSetback = FREE_END_SETBACK, FREE_END_SETBACK
	local headTaper: number?, tailTaper: number? = nil, nil
	if net then
		headSetback, headTaper = endSetback(net, seg, seg.startNode)
		tailSetback, tailTaper = endSetback(net, seg, seg.endNode)
	end
	local d = headSetback + SPOT_SPACING * 0.5
	-- The BODY has to clear the crossing, not just the bay's centre point.
	local last = total - tailSetback - SPOT_SPACING * 0.5
	while d <= last do
		local pos, tan = atDistance(pts, cum, d)
		local side = Vector3.new(-tan.Z, 0, tan.X)
		if side.Magnitude > 1e-6 then side = side.Unit end
		local inset = taperInset(spec.width, headTaper, d) + taperInset(spec.width, tailTaper, total - d)
		for _, s in sides do
			local p = Vector3.new(pos.X, pos.Y + CAR_SIT_Y, pos.Z) + side * (s * (lateral - inset))
			n += 1
			local id = tostring(seg.id) .. "#" .. tostring(n)
			local spot: Spot = { id = id, segId = seg.id, cf = CFrame.lookAt(p, p + tan, UP), pos = p, occupied = false }
			_spots[id] = spot
			addToCell(spot)
			table.insert(ids, id)
		end
		d += SPOT_SPACING
	end
	if n > 0 then _bySeg[seg.id] = ids end
end

local function rebuildAll()
	table.clear(_spots)
	table.clear(_bySeg)
	table.clear(_cells)
	-- Car-park stalls live in the same index, so a wholesale rebuild has to re-derive them
	-- too -- otherwise every lot in the city quietly stops existing the next time the road
	-- network changes shape.
	for model in _byLot do
		if model.Parent then buildLot(model) else dropLot(model) end
	end
	if not _roadService then return end
	local net = _roadService.getNetwork()
	if not net then return end
	for _, seg in net:getSegments() do
		buildSegment(seg)
	end
end

local function onTopology(change: any?)
	if not _roadService then return end
	if not change then
		rebuildAll()
		return
	end
	local net = _roadService.getNetwork()
	if not net then return end
	if change.removedSegmentIds then
		for _, id in change.removedSegmentIds do dropSegment(id) end
	end
	if change.segmentIds then
		for _, id in change.segmentIds do
			local seg = net:getSegment(id)
			if seg then buildSegment(seg) else dropSegment(id) end
		end
	end
end

-- Face a parked car WITH the adjacent lane's traffic. The stored spot CFrame faces the
-- segment tangent, but on a two-way street one kerb's lane runs the OTHER way, so half
-- the spots would point a parked car into oncoming traffic (reads as "going the wrong
-- way"). Snap to the nearest lane edge's direction (handedness-proof).
local function orientWithTraffic(spot: Spot): CFrame
	-- A stall faces the way the bay was painted; there is no lane alongside it to agree with.
	if spot.lot then return spot.cf end
	local g = _roadService and _roadService.getNavigationGraph and _roadService.getNavigationGraph()
	if g then
		local ok, res = pcall(function() return g:NearestEdge(spot.pos) end)
		if ok and res and res.edge and res.edge.points and #res.edge.points >= 2 then
			local pts = res.edge.points
			local i = math.clamp(res.index or 2, 2, #pts)
			local dir = pts[i] - pts[i - 1]
			local flat = Vector3.new(dir.X, 0, dir.Z)
			if flat.Magnitude > 1e-3 then
				return CFrame.lookAt(spot.pos, spot.pos + flat.Unit, UP)
			end
		end
	end
	return spot.cf
end

-- Overflow: the nearest free CAR-PARK stall in the city (lots only -- the kerbside index is
-- radius-bound above). This is what stops a car being pocketed out of the world when its
-- own street is full.
-- ponytail: scans every stall of every lot. If a city ever holds thousands, keep a free
-- count per lot and pick the lot first, the stall second.
local function nearestFreeLotStall(pos: Vector3): Spot?
	local best: Spot? = nil
	local bestD2 = LOT_FALLBACK_RADIUS * LOT_FALLBACK_RADIUS
	for _, rec in _byLot do
		for _, id in rec.ids do
			local spot = _spots[id]
			if spot and not spot.occupied then
				local dx = spot.pos.X - pos.X
				local dz = spot.pos.Z - pos.Z
				local d2 = dx * dx + dz * dz
				if d2 < bestD2 then
					bestD2 = d2
					best = spot
				end
			end
		end
	end
	return best
end

-- The nearest FREE spot to `pos` within `r` (flat distance), else the nearest car-park
-- stall in the city. Nothing is reserved.
local function nearestFree(pos: Vector3, r: number): Spot?
	local cxMin, cxMax = math.floor((pos.X - r) / CELL), math.floor((pos.X + r) / CELL)
	local czMin, czMax = math.floor((pos.Z - r) / CELL), math.floor((pos.Z + r) / CELL)
	local best: Spot? = nil
	local bestD2 = r * r
	for cx = cxMin, cxMax do
		for cz = czMin, czMax do
			local list = _cells[cellKey(cx, cz)]
			if list then
				for _, id in list do
					local spot = _spots[id]
					if spot and not spot.occupied then
						local dx = spot.pos.X - pos.X
						local dz = spot.pos.Z - pos.Z
						local d2 = dx * dx + dz * dz
						if d2 < bestD2 then
							bestD2 = d2
							best = spot
						end
					end
				end
			end
		end
	end
	return best or nearestFreeLotStall(pos)
end

-- Reserve and return the nearest free spot (see nearestFree).
-- Returns the spot id + its CFrame (oriented with traffic), or nil/nil. The caller MUST
-- release(id) when the car leaves so the spot frees up.
function ParkingService.reserveNearest(pos: Vector3, maxRadius: number?): (string?, CFrame?)
	if typeof(pos) ~= "Vector3" then return nil, nil end
	local best = nearestFree(pos, maxRadius or 400)
	if best then
		best.occupied = true
		return best.id, orientWithTraffic(best)
	end
	return nil, nil
end

-- How far from `pos` the nearest free bay (or car-park stall) is, WITHOUT taking it: what a
-- citizen weighs before deciding the car is worth it. nil = nowhere to park at all.
function ParkingService.distanceToFree(pos: Vector3, maxRadius: number?): number?
	if typeof(pos) ~= "Vector3" then return nil end
	local best = nearestFree(pos, maxRadius or 400)
	if not best then return nil end
	return Vector3.new(best.pos.X - pos.X, 0, best.pos.Z - pos.Z).Magnitude
end

function ParkingService.release(id: string?)
	if not id then return end
	local spot = _spots[id]
	if spot then spot.occupied = false end
end

-- Developer panel: total / occupied / free spot counts (cheap census of _spots).
function ParkingService.GetParkingStats(): { [string]: number }
	local total, occupied = 0, 0
	for _, s in _spots do
		total += 1
		if s.occupied then occupied += 1 end
	end
	return { total = total, occupied = occupied, free = total - occupied }
end

-- Developer panel: on-street spots within radius, each { pos, occ }. Uses the spatial
-- grid so a camera-local query stays cheap on a big map. Read-only.
function ParkingService.GetParkingDebug(camPos: Vector3?, radius: number?): { any }
	local out: { any } = {}
	if typeof(camPos) ~= "Vector3" then
		for _, s in _spots do
			table.insert(out, { pos = s.pos, occ = s.occupied })
		end
		return out
	end
	local r = radius or 600
	local rSq = r * r
	local cxMin, cxMax = math.floor((camPos.X - r) / CELL), math.floor((camPos.X + r) / CELL)
	local czMin, czMax = math.floor((camPos.Z - r) / CELL), math.floor((camPos.Z + r) / CELL)
	for cx = cxMin, cxMax do
		for cz = czMin, czMax do
			local list = _cells[cellKey(cx, cz)]
			if list then
				for _, id in list do
					local s = _spots[id]
					if s then
						local dx = s.pos.X - camPos.X
						local dz = s.pos.Z - camPos.Z
						if dx * dx + dz * dz <= rSq then
							table.insert(out, { pos = s.pos, occ = s.occupied })
						end
					end
				end
			end
		end
	end
	return out
end

function ParkingService.Init(roadService: any)
	assert(roadService, "[ParkingService] requires RoadService")
	_roadService = roadService
end

function ParkingService.Bind()
	if _topoDisconnect then _topoDisconnect() end
	_topoDisconnect = _roadService.onTopologyChanged(onTopology)

	-- Every planted prop is tagged by NaturePlaceService, which is the one hook that covers
	-- placing, bulldozing AND a city load without this service knowing anything about the
	-- folder those props live in.
	for _, conn in _tagConns do conn:Disconnect() end
	table.clear(_tagConns)
	table.insert(_tagConns, CollectionService:GetInstanceAddedSignal("NatureProp"):Connect(function(inst: Instance)
		if inst:IsA("Model") and isLot(inst) then buildLot(inst) end
	end))
	table.insert(_tagConns, CollectionService:GetInstanceRemovedSignal("NatureProp"):Connect(function(inst: Instance)
		if inst:IsA("Model") then dropLot(inst) end
	end))
end

function ParkingService.Start()
	for _, inst in CollectionService:GetTagged("NatureProp") do
		if inst:IsA("Model") and isLot(inst) then buildLot(inst) end
	end
	rebuildAll()
end

return ParkingService
