--!strict
-- PlotService
-- Server-authoritative owner of Manor Lords burgage plots. The client sends dragged frontage
-- spans (seg, side, t0..t1); the server CLIPS each against already-occupied frontage AND the
-- shared road index (junction mouths, dead-end caps, road-overlap), packs the free runs into
-- lot-multiple plots, and asks BuildingService to develop one building per plot. A group
-- persists BOTH its span (the intent) and the seats it produced (the result) -- a load
-- replays the seats verbatim and never re-plans, so a city comes back exactly as it stood.
--
-- Owns the plot domain. Reads roads through RoadService (segment lookup); drives BuildingService.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local ZoneTypes     = require(ReplicatedStorage.City.ZoneTypes)
local BezierUtil    = require(ReplicatedStorage.Road.BezierUtil)
local PlotGeometry  = require(ReplicatedStorage.City.PlotGeometry)
local ZoneGrid      = require(ReplicatedStorage.City.ZoneGrid)
local NetMiddleware = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local PlacementFit  = require(ReplicatedStorage.Shared.PlacementFit)

local PlotService = {}

-- One seated building: the pivot it was placed at, its template size in lots, and the
-- plot footprint the terrain pad covers. This is what a save stores and a load replays.
-- bpId is runtime-only (never persisted -- a load mints fresh ids): it is how serialize
-- tells a seat whose building still stands from one the player has since bulldozed.
-- t0/t1 are this ONE building's slice of the road frontage: the group's claimed span is
-- the union of its seats, so demolishing a house gives back exactly the stretch it sat on.
-- (Absent on seats from a save written before spans were stored.)
export type Seat = { pivot: CFrame, w: number, d: number, fw: number, fd: number, bpId: string?, t0: number?, t1: number? }

export type PlotGroup = {
	id          : number,
	segmentId   : number,
	side        : number,
	t0          : number,
	t1          : number,
	depth       : number,
	width       : number,
	uniform     : boolean?,  -- only exact-width plots (player's size-mode choice)
	bw          : number?,   -- building width lots (polygon parcels persist their curve-trim)
	zone        : string,
	building    : string?,   -- a specific template name (single-building picker); nil = random variant
	density     : string?,   -- "Medium" = mid-rise blocks (Residential only); nil = low (houses)
	buildingIds : { string },
	-- Where the buildings ACTUALLY stand. The span (t0/t1) is the intent; this is the
	-- result, and only the result reloads exactly.
	placed      : { Seat }?,
}

local LOT            = ZoneGrid.LOT_SIZE -- plots are measured in lots, like the buildings on them
local MIN_DEPTH      = 2 * LOT -- the smallest building depth, so the house fits its plot
local MAX_DEPTH      = PlotGeometry.MAX_PARCEL_DEPTH
local MAX_WIDTH      = 7.5 * LOT
local DEFAULT_DEPTH  = 3 * LOT
local PLACE_COOLDOWN = 0.05
-- Refit reach: studs past a changed road's control points a standing house could still
-- overlap it from (widest road half-width + sidewalk, plus the deepest building's half
-- diagonal). Only seats inside that box are re-tested after an edit.
local REFIT_REACH    = 96
-- More segments than this in one change is a bulk rebuild -- a city load, an undo, a
-- snapshot restore -- not a player edit. Those replace the plots wholesale straight after,
-- so refitting against them is churn at best and demolishes the outgoing city at worst.
local MAX_REFIT_SEGS = 24
local MAX_PER_PLACE  = 240  -- a single drag may create at most this many buildings

local _roadService : any
local _building    : any
local _net         : any
local _groups      : { [number]: PlotGroup } = {}
local _nextId      = 0
local _bound       = false
local _lastPlaceAt : { [Player]: number } = {}
local _topoDisc    : (() -> ())? = nil
local _bldgDisc    : (() -> ())? = nil
local _densityAllowed : ((density: string) -> boolean)? = nil

local function canEdit(player: Player): boolean
	if Workspace:GetAttribute("RoadEditOpen") == true then return true end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

local function segmentById(id: number): any
	if not _roadService then return nil end
	return _roadService.getNetwork():getSegments()[id]
end

local function isFinite(n: any): boolean
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- The save grid. Seats are quantised HERE, before the building is placed, so the pivot held
-- in memory is bit-identical to the one persisted. BuildingService derives its saveKey (the
-- handle for level / occupancy / residents / the resident family) from this position, and a
-- pivot that shifted by one rounding step on reload would orphan all of it.
local function r1(n: number): number
	return math.floor(n * 10 + 0.5) / 10
end

-- Plot edges are 0..1 curve parameters, so r1 would move them up to a stud on a long road.
-- Six decimals is <= 0.002 stud on a 2,000-stud road, far inside the 1e-3 run-adjacency
-- tolerance, and saves ~30% of the plot section over raw 17-digit floats.
local function r6(n: number): number
	return math.round(n * 1e6) / 1e6
end

-- Plot pivots are pure yaw: PlotGeometry.buildingRect flattens the look vector to XZ.
-- Normalised to [0, 360) so a save -> load -> save cycle is a fixed point: without it
-- atan2 returns -180 for the same facing it wrote as 180, and the blob never settles.
local function yawDegOf(cf: CFrame): number
	return r1(math.deg(math.atan2(-cf.LookVector.X, -cf.LookVector.Z))) % 360
end

local function seatPivot(cf: CFrame): CFrame
	local p = cf.Position
	return CFrame.new(r1(p.X), r1(p.Y), r1(p.Z)) * CFrame.Angles(0, math.rad(yawDegOf(cf)), 0)
end

local function toWire(g: PlotGroup): any
	return { id = g.id, seg = g.segmentId, side = g.side, t0 = g.t0, t1 = g.t1,
		depth = g.depth, width = g.width, zone = g.zone, uniform = g.uniform == true }
end

-- Road index (bands / caps / junction clearances) rebuilt lazily after topology changes.
local _roadIndexCache: PlotGeometry.RoadIndex? = nil
local function roadIndex(): PlotGeometry.RoadIndex
	local idx = _roadIndexCache
	if not idx then
		idx = PlotGeometry.buildRoadIndex(
			if _roadService then _roadService.getNetwork():getSegments() else {},
			PlacementFit.seatOccupied
		)
		_roadIndexCache = idx
	end
	return idx
end

-- Placements of a group: re-plan its span through the SAME pipeline the client previews
-- with. Deterministic, so a restore rebuilds exactly what was placed.
local function groupPlacements(g: PlotGroup): { PlotGeometry.Placement }
	local seg = segmentById(g.segmentId)
	if not seg then return {} end
	if g.side == 2 or g.side == -2 then -- dead-end cap ring (its own occupancy lane)
		return PlotGeometry.planCapRing(roadIndex(), seg, g.side == 2, g.t0, g.t1, g.depth, g.width, g.uniform)
	end
	return PlotGeometry.planSpan(roadIndex(), seg, g.side, g.t0, g.t1, g.depth, g.width, g.uniform)
end

-- Develop one building per placement. Blocked placements never build. A polygon parcel
-- persists its trimmed building width (bw); the terrain pad covers the WHOLE parcel.
local function developGroup(g: PlotGroup, mode: string, placements: { PlotGeometry.Placement }?): number
	if not _building then return 0 end
	local ids: { string } = {}
	local seats: { Seat } = {}
	for _, pl in (placements or groupPlacements(g)) do
		if not pl.blocked then
			local w = g.bw or pl.w
			local pivot = pl.pivot
			if w ~= pl.w then
				pivot = PlotGeometry.buildingRect(pl.plot, w, pl.d)
			end
			pivot = seatPivot(pivot)
			local fw, fd = r1(pl.plot.frontage), r1(pl.plot.depth)
			local bpId = _building.developPlot(pivot, g.zone, w, pl.d, mode, g.segmentId, g.building, fw, fd, g.density)
			if bpId then
				table.insert(ids, bpId)
				table.insert(seats, { pivot = pivot, w = w, d = pl.d, fw = fw, fd = fd, bpId = bpId,
					t0 = pl.plot.t0, t1 = pl.plot.t1 })
			end
		end
	end
	g.buildingIds = ids
	g.placed = seats
	return #ids
end

-- Rebuild a group from its SAVED seats: no re-planning, no road index, no blocking test.
-- Every building goes back exactly where it stood. A load must not re-derive the city --
-- planSpan reads the whole road network, so any road added, moved or repaired since the
-- save would silently move, drop, or invent houses.
local function developSeats(g: PlotGroup, seats: { Seat }): number
	local ids: { string } = {}
	if _building then
		for _, s in seats do
			s.bpId = _building.developPlot(s.pivot, g.zone, s.w, s.d, "instant", g.segmentId, g.building, s.fw, s.fd, g.density)
			if s.bpId then table.insert(ids, s.bpId) end
		end
	end
	g.buildingIds = ids
	g.placed = seats
	return #ids
end

-- Decode persisted seats. A save blob is untrusted input, so a row only survives as a full
-- set of finite, on-map numbers; anything else is dropped rather than fed into a CFrame.
local function readSeats(raw: any): { Seat }?
	if typeof(raw) ~= "table" or #raw == 0 then return nil end
	local out: { Seat } = {}
	for _, r in raw do
		if typeof(r) == "table" and (#r == 8 or #r == 10) then
			local ok = true
			for i = 1, #r do
				if not isFinite(r[i]) or math.abs(r[i]) > 1e6 then ok = false break end
			end
			if ok then
				table.insert(out, {
					pivot = CFrame.new(r[1], r[2], r[3]) * CFrame.Angles(0, math.rad(r[4]), 0),
					w = math.clamp(math.floor(r[5]), 2, 5),
					d = math.clamp(math.floor(r[6]), 2, 5),
					fw = math.max(0, r[7]),
					fd = math.max(0, r[8]),
					t0 = if #r == 10 then math.clamp(r[9], 0, 1) else nil,
					t1 = if #r == 10 then math.clamp(r[10], 0, 1) else nil,
				})
			end
		end
	end
	return if #out > 0 then out else nil
end

-- Set while this service is tearing groups down itself. Demolishing a building fires
-- BuildingService's removal signal straight back at us, and reacting to it mid-teardown
-- would mutate _groups while restore/clear are iterating it -- inserting a split group
-- during a `for id in _groups` loop is undefined behaviour, not just wasted work.
local _pruning = false

-- Contiguous runs of seats, in frontage order. Bulldozing a house out of the MIDDLE of a
-- run splits it in two, so the gap it leaves becomes buildable again instead of staying
-- locked behind the old span.
local function seatRuns(seats: { Seat }): { { Seat } }
	table.sort(seats, function(a, b) return (a.t0 :: number) < (b.t0 :: number) end)
	local runs: { { Seat } } = {}
	local cur: { Seat } = {}
	for _, s in seats do
		if #cur > 0 and (s.t0 :: number) - (cur[#cur].t1 :: number) > 1e-3 then
			table.insert(runs, cur)
			cur = {}
		end
		table.insert(cur, s)
	end
	if #cur > 0 then table.insert(runs, cur) end
	return runs
end

local function eraseGroup(id: number)
	local g = _groups[id]
	if not g then return end
	local wasPruning = _pruning
	_pruning = true
	if _building then
		for _, bpId in g.buildingIds do
			_building.demolish(bpId)
		end
	end
	_pruning = wasPruning
	_groups[id] = nil
end

-- Occupied frontage intervals on (segId, side): every existing group there, plus any `extra`
-- intervals created earlier in the same batch (so two cells in one drag can't both take a spot).
local function occupiedFor(segId: number, side: number, extra: { { number } }?): { { number } }
	local occ: { { number } } = {}
	for _, g in _groups do
		if g.segmentId == segId and g.side == side then
			occ[#occ + 1] = { g.t0, g.t1 }
		end
	end
	if extra then
		for _, iv in extra do occ[#occ + 1] = iv end
	end
	return occ
end

-- Parts of [a,b] not covered by any interval in `occ` -- so a placement fills only free frontage.
local function freeIntervals(a: number, b: number, occ: { { number } }): { { number } }
	table.sort(occ, function(x, y) return x[1] < y[1] end)
	local free: { { number } } = {}
	local cur = a
	for _, o in occ do
		if o[2] <= cur or o[1] >= b then continue end
		if o[1] > cur then free[#free + 1] = { cur, math.min(o[1], b) } end
		cur = math.max(cur, o[2])
		if cur >= b then break end
	end
	if cur < b - 1e-4 then free[#free + 1] = { cur, b } end
	return free
end

-- ---- corner lots -------------------------------------------------------------------------
-- Cities: Skylines puts a building on the outside corner of a bend. The rows here stopped at
-- the node and left that whole corner as bare grass. When a zoned row runs right up to a bend
-- that turns AWAY from it, one more parcel carries the row on past the node: the row's depth,
-- as wide as the parcel beside it (narrower if that is all that fits), its front facing the
-- end of the road and the bend. TerrainPadService's gap fill grades the strip left between it
-- and the row on the other road. The seat is stored with the group like any other (a zero-
-- length slice at the row's end), so saves, loads and the bulldozer treat it the same.
local CORNER_TURN_DOT = -0.5 -- the other road must turn at least ~30 deg away from the row

local function flatUnit(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude < 1e-4 then Vector3.xAxis else f.Unit
end

-- The corner parcels past the row's node end, widest first (nil when this end is not the
-- outside of a bend). `edge` is the row's parcel at that end.
local function cornerCandidates(seg: any, side: number, atEnd: boolean, edge: PlotGeometry.Placement, minLots: number): { PlotGeometry.Placement }
	local out: { PlotGeometry.Placement } = {}
	if not _roadService or (side ~= 1 and side ~= -1) then return out end
	local net = _roadService.getNetwork()
	local nodeId = if atEnd then seg.endNode else seg.startNode
	local node = nodeId and net:getNodes()[nodeId]
	if not node or #node.segments ~= 2 then return out end -- a junction or a dead end
	if net.getRoundaboutForNode and net:getRoundaboutForNode(nodeId) then return out end
	local other = segmentById(if node.segments[1] == seg.id then node.segments[2] else node.segments[1])
	if not other or other.id == seg.id then return out end
	local otherAtEnd = other.endNode == nodeId

	local tanHere = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, if atEnd then 1 else 0)
	local along = flatUnit(if atEnd then tanHere else -tanHere) -- carries the row on past the node
	local tanOther = BezierUtil.tangent(other.p0, other.p1, other.p2, other.p3, if otherAtEnd then 1 else 0)
	local away = flatUnit(if otherAtEnd then -tanOther else tanOther) -- the other road leaving the node
	local inward = flatUnit(Vector3.new(-tanHere.Z, 0, tanHere.X) * side) -- toward the row's backyards
	if inward:Dot(away) > CORNER_TURN_DOT then return out end -- the inside of the bend, or barely one

	local plot = edge.plot
	local front = if (plot.frontB - plot.frontA):Dot(along) >= 0 then plot.frontB else plot.frontA
	local depth = plot.depth
	local t = if atEnd then plot.t1 else plot.t0
	local dLots = PlotGeometry.fitDepthLots(depth)
	local idx = roadIndex()

	-- Widest first: a parcel whose yard runs right out to where the other road's row ends
	-- (its back line, at the same depth), so the corner is one lot rather than a lot and a
	-- leftover strip. The building on it is as wide as a template gets and sits centred.
	local sizes: { { number } } = {}
	local otherIn = flatUnit(Vector3.new(-tanOther.Z, 0, tanOther.X))
	if otherIn:Dot(along) < 0 then otherIn = -otherIn end -- the other road's outside: the corner
	local reachOut = otherIn:Dot(along)
	if reachOut > 0.2 then
		local otherSide = if (Vector3.new(-tanOther.Z, 0, tanOther.X)):Dot(otherIn) > 0 then 1 else -1
		local backLine = PlotGeometry.frontOffset(other.roadType, otherSide) + depth
		local nodePos = if atEnd then seg.p3 else seg.p0
		local W = (backLine - Vector3.new(front.X - nodePos.X, 0, front.Z - nodePos.Z):Dot(otherIn)) / reachOut
		local lots = math.min(5, math.floor(W / LOT + 1e-3))
		if lots >= minLots and W <= 7 * LOT then table.insert(sizes, { W, lots }) end
	end
	for lots = math.max(edge.parcelLots, minLots), minLots, -1 do
		table.insert(sizes, { lots * LOT, lots })
	end

	for _, size in sizes do
		local W, lots = size[1], size[2]
		local fA, fB = front, front + along * W
		local cp: PlotGeometry.Plot = {
			frontA = fA, frontB = fB, backB = fB + inward * depth, backA = fA + inward * depth,
			center = fA + along * (W * 0.5) + inward * (depth * 0.5),
			frontage = W, depth = depth, angleDeg = math.deg(math.atan2(along.X, along.Z)),
			t0 = t, t1 = t,
		}
		local pivot, corners = PlotGeometry.buildingRect(cp, lots, dLots)
		if not PlotGeometry.buildingBlocked(idx, corners, seg.id)
			and not PlotGeometry.rectOnRoad(idx, { cp.frontA, cp.frontB, cp.backB, cp.backA }, seg.id) then
			table.insert(out, { plot = cp, segId = seg.id, side = side, parcelLots = lots, w = lots, d = dLots,
				pivot = pivot, corners = corners, blocked = false } :: any)
		end
	end
	return out
end

-- Try the corner lot at one end of a freshly developed row; adds its seat to the group.
local function developCorner(g: PlotGroup, seg: any, atEnd: boolean, edge: PlotGeometry.Placement, mode: string)
	if not _building or not g.placed then return end
	local minLots = if g.zone == "Residential" and not g.density then PlotGeometry.MIN_HOUSE_LOTS else 2
	for _, pl in cornerCandidates(seg, g.side, atEnd, edge, minLots) do
		local pivot = seatPivot(pl.pivot)
		local fw, fd = r1(pl.plot.frontage), r1(pl.plot.depth)
		local bpId = _building.developPlot(pivot, g.zone, pl.w, pl.d, mode, g.segmentId, g.building, fw, fd, g.density)
		if bpId then
			table.insert(g.buildingIds, bpId)
			table.insert(g.placed, { pivot = pivot, w = pl.w, d = pl.d, fw = fw, fd = fd, bpId = bpId,
				t0 = pl.plot.t0, t1 = pl.plot.t1 })
			return
		end
	end
end

-- Full snapshot to a joining player (or everyone after a restore).
function PlotService.broadcastFull(target: Player?)
	if not _net then return end
	local list: { any } = {}
	for _, g in _groups do table.insert(list, toWire(g)) end
	local payload = { full = true, groups = list }
	if target then
		_net.SyncPlots:FireClient(target, payload)
	else
		_net.SyncPlots:FireAllClients(payload)
	end
end

local function place(player: Player, data: any)
	if not canEdit(player) then return end
	if typeof(data) ~= "table" then return end

	local now = os.clock()
	local last = _lastPlaceAt[player]
	if last and now - last < PLACE_COOLDOWN then return end
	_lastPlaceAt[player] = now

	-- Erase: remove the group by id (the client picks it under the cursor).
	if isFinite(data.erase) then
		local id = data.erase
		if _groups[id] then
			eraseGroup(id)
			_net.SyncPlots:FireAllClients({ removed = { id } })
		end
		return
	end

	if not (ZoneTypes.isValid(data.zone) and data.zone ~= "None") then return end
	local zone = data.zone
	local depth = math.clamp(if isFinite(data.depth) then data.depth else DEFAULT_DEPTH, MIN_DEPTH, MAX_DEPTH)
	local width = math.clamp(if isFinite(data.width) then data.width else PlotGeometry.DEFAULT_PLOT_WIDTH,
		PlotGeometry.MIN_PLOT_WIDTH, MAX_WIDTH)
	local mode = if data.immediate == true then "stamp" else "grow"
	local building = if typeof(data.building) == "string" then data.building else nil
	local uniform = data.uniform == true
	-- Only Medium has its own stock so far; High/Mixed (and anything else) build houses.
	-- ponytail: add "High"/"Mixed" here when their templates exist.
	local density = if data.density == "Medium" and zone == "Residential" then "Medium" else nil
	if density and _densityAllowed and not _densityAllowed(density) then
		warn(("[PlotService] place: %s asked for locked density %s"):format(player.Name, density))
		return
	end
	if zone == "Residential" and not density then
		width = math.max(width, PlotGeometry.MIN_HOUSE_LOTS * LOT)
	end

	local created: { any } = {}
	local batchExtra: { [string]: { { number } } } = {}

	local function spanFree(segId: number, side: number, t0: number, t1: number): boolean
		local key = tostring(segId) .. ":" .. tostring(side)
		batchExtra[key] = batchExtra[key] or {}
		for _, o in occupiedFor(segId, side, batchExtra[key]) do
			if t0 < o[2] - 1e-4 and t1 > o[1] + 1e-4 then return false end
		end
		return true
	end

	-- Manor Lords area zoning: a node-polygon. Planned through the SAME pipeline the client
	-- previewed; every buildable parcel becomes its own group (own span, own depth).
	if typeof(data.poly) == "table" then
		local poly: { Vector3 } = {}
		local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
		for _, p in data.poly do
			if typeof(p) ~= "Vector3" or not (isFinite(p.X) and isFinite(p.Y) and isFinite(p.Z)) then return end
			poly[#poly + 1] = p
			minX = math.min(minX, p.X); maxX = math.max(maxX, p.X)
			minZ = math.min(minZ, p.Z); maxZ = math.max(maxZ, p.Z)
		end
		if #poly < 3 or #poly > 10 then return end
		if maxX - minX > 2048 or maxZ - minZ > 2048 then return end
		local segsAll = if _roadService then _roadService.getNetwork():getSegments() else {}
		for _, pl in PlotGeometry.planPolygon(segsAll, roadIndex(), poly, width, uniform) do
			if #created >= MAX_PER_PLACE then break end
			if not pl.blocked and spanFree(pl.segId, pl.side, pl.plot.t0, pl.plot.t1) then
				_nextId += 1
				local g: PlotGroup = {
					id = _nextId, segmentId = pl.segId, side = pl.side,
					t0 = pl.plot.t0, t1 = pl.plot.t1,
					-- width is STUDS everywhere: the group re-plans from it on reload.
					depth = pl.plot.depth, width = pl.parcelLots * LOT, uniform = true, bw = pl.w,
					zone = zone, building = building, density = density, buildingIds = {},
				}
				if developGroup(g, mode, { pl }) > 0 then
					_groups[g.id] = g
					created[#created + 1] = toWire(g)
					table.insert(batchExtra[tostring(pl.segId) .. ":" .. tostring(pl.side)], { g.t0, g.t1 })
				else
					_nextId -= 1
				end
			end
		end
		if #created > 0 then _net.SyncPlots:FireAllClients({ groups = created }) end
		return
	end

	-- Accept a batch of cells (a drag) or a single cell (a click).
	local list: { any }
	if typeof(data.cells) == "table" then
		list = data.cells
	elseif isFinite(data.t0) then
		list = { { seg = data.seg, side = data.side, t0 = data.t0, t1 = data.t1 } }
	else
		return
	end

	for _, c in list do
		if #created >= MAX_PER_PLACE then break end
		if typeof(c) ~= "table" then continue end
		local segId = c.seg
		local side = c.side
		if not (isFinite(segId) and isFinite(c.t0) and isFinite(c.t1)) then continue end
		local isCap = side == 2 or side == -2 -- dead-end cap ring lane
		if not isCap and side ~= 1 and side ~= -1 then continue end
		if not segmentById(segId) then continue end

		local t0 = math.clamp(math.min(c.t0, c.t1), 0, 1)
		local t1 = math.clamp(math.max(c.t0, c.t1), 0, 1)
		if t1 - t0 < 1e-3 then continue end

		local key = tostring(segId) .. ":" .. tostring(side)
		batchExtra[key] = batchExtra[key] or {}
		local occ = occupiedFor(segId, side, batchExtra[key])
		local seg = segmentById(segId)
		local idx = roadIndex()

		-- One group per CONTIGUOUS run of buildable placements, so a blocked plot (road
		-- overlap on a curve, junction wrap) splits the span instead of claiming frontage
		-- nothing was built on.
		local run: { PlotGeometry.Placement } = {}
		-- Where this side's zonable frontage starts and ends: a row reaching either is at the
		-- node, and may carry on round the outside of a bend (developCorner).
		local loT: number?, hiT: number? = nil, nil
		if not isCap then loT, hiT = PlotGeometry.clampSpan(idx, seg, 0, 1, side) end
		local function flushRun()
			if #run == 0 then return end
			_nextId += 1
			local g: PlotGroup = {
				id = _nextId, segmentId = segId, side = side,
				t0 = run[1].plot.t0, t1 = run[#run].plot.t1,
				depth = depth, width = width, uniform = if uniform then true else nil,
				zone = zone, building = building, density = density, buildingIds = {},
			}
			if developGroup(g, mode, run) > 0 then
				if loT and hiT and not uniform and not building then
					if run[#run].plot.t1 >= hiT - 1e-3 then developCorner(g, seg, true, run[#run], mode) end
					if run[1].plot.t0 <= loT + 1e-3 then developCorner(g, seg, false, run[1], mode) end
				end
				_groups[g.id] = g
				created[#created + 1] = toWire(g)
				table.insert(batchExtra[key], { g.t0, g.t1 })
			else
				_nextId -= 1
			end
			run = {}
		end

		for _, iv in freeIntervals(t0, t1, occ) do
			local plans = if isCap
				then PlotGeometry.planCapRing(idx, seg, side == 2, iv[1], iv[2], depth, width, uniform)
				else PlotGeometry.planSpan(idx, seg, side, iv[1], iv[2], depth, width, uniform)
			for _, pl in plans do
				if pl.blocked then
					flushRun()
				elseif #run > 0 and pl.plot.t0 - run[#run].plot.t1 > 1e-3 then
					flushRun()
					table.insert(run, pl)
				else
					table.insert(run, pl)
				end
			end
			flushRun()
			if #created >= MAX_PER_PLACE then break end
		end
	end

	if #created > 0 then _net.SyncPlots:FireAllClients({ groups = created }) end
end

-- Placements for one seat's own stretch of frontage, through the same pipeline that planned
-- it originally -- so a replacement is whatever the planner would put there today.
local function planSub(g: PlotGroup, seg: any, t0: number, t1: number): { PlotGeometry.Placement }
	if g.side == 2 or g.side == -2 then
		return PlotGeometry.planCapRing(roadIndex(), seg, g.side == 2, t0, t1, g.depth, g.width, g.uniform)
	end
	return PlotGeometry.planSpan(roadIndex(), seg, g.side, t0, t1, g.depth, g.width, g.uniform)
end

-- Rebuild whatever still fits on one stretch of a group's frontage after the house that
-- held it came down. Appends to `seats` / g.buildingIds; returns how many went up (0 means
-- the road genuinely took the plot). Callers own the _pruning guard.
local function replanStretch(g: PlotGroup, seg: any, t0: number, t1: number, seats: { Seat }): number
	local built = 0
	for _, pl in planSub(g, seg, t0, t1) do
		if pl.blocked then continue end
		local pivot = seatPivot(pl.pivot)
		local fw, fd = r1(pl.plot.frontage), r1(pl.plot.depth)
		local bpId = _building.developPlot(pivot, g.zone, pl.w, pl.d, "instant", g.segmentId, g.building, fw, fd, g.density)
		if bpId then
			table.insert(g.buildingIds, bpId)
			table.insert(seats, { pivot = pivot, w = pl.w, d = pl.d, fw = fw, fd = fd,
				bpId = bpId, t0 = pl.plot.t0, t1 = pl.plot.t1 })
			built += 1
		end
	end
	return built
end

-- Put a bulldozed seat back somewhere it fits: its own stretch first, then whatever frontage
-- the group still has free. A road edit RE-ZONES the plot -- it never quietly costs the city a
-- building -- so a house the new pavement swallowed comes back beside it if there is room.
-- Only a deliberate bulldoze unzones. Callers own the _pruning guard.
local function rehouse(g: PlotGroup, seg: any, t0: number, t1: number, seats: { Seat }): number
	local built = replanStretch(g, seg, t0, t1, seats)
	if built > 0 then return built end
	local occ: { { number } } = {}
	for _, s in seats do
		if s.t0 and s.t1 then table.insert(occ, { s.t0, s.t1 }) end
	end
	for _, iv in freeIntervals(g.t0, g.t1, occ) do
		built = replanStretch(g, seg, iv[1], iv[2], seats)
		if built > 0 then return built end
	end
	return 0
end

-- XZ box around the segments a change touched, or nil when the change is a bulk rebuild
-- (or carries no usable segment list) and should be skipped.
local function refitBounds(change: any): { number }?
	if typeof(change) ~= "table" then return nil end
	local ids = change.segmentIds
	if typeof(ids) ~= "table" or #ids == 0 then return nil end
	local removedCount = if typeof(change.removedSegmentIds) == "table" then #change.removedSegmentIds else 0
	if #ids + removedCount > MAX_REFIT_SEGS then return nil end
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, id in ids do
		local seg = segmentById(id)
		if seg then
			for _, p in { seg.p0, seg.p1, seg.p2, seg.p3 } do
				minX = math.min(minX, p.X); maxX = math.max(maxX, p.X)
				minZ = math.min(minZ, p.Z); maxZ = math.max(maxZ, p.Z)
			end
		end
	end
	if minX > maxX then return nil end
	return { minX - REFIT_REACH, maxX + REFIT_REACH, minZ - REFIT_REACH, maxZ + REFIT_REACH }
end

-- A road drawn, moved or widened beside standing houses leaves some of them lapping over the
-- new pavement: RoadService only clears buildings whose CENTRE the road covers, so a corner
-- house keeps a wall in the carriageway. Re-test every seat near the edit against the rebuilt
-- road index; one that now overlaps is demolished and its own frontage re-planned, so a
-- smaller house that fits takes its place. Nothing that fits means the plot simply goes.
local function refitSeats(change: any)
	if not _building then return end
	local box = refitBounds(change)
	if not box then return end
	local idx = roadIndex()
	local removed: { number } = {}
	local changed: { any } = {}

	-- Erasing the CURRENT key while iterating is defined; nothing here inserts a group.
	for id, g in _groups do
		local seg = segmentById(g.segmentId)
		local seats = g.placed
		if seg and seats then
			local bad: { number } = {}
			for i, s in seats do
				local p = s.pivot.Position
				if p.X >= box[1] and p.X <= box[2] and p.Z >= box[3] and p.Z <= box[4]
					-- ponytail: nil, not g.segmentId. Connecting a road SPLITS the one it meets, and the far
				-- half gets a NEW segment id -- so every standing house on it stopped being "on its
				-- own road" and failed the stricter cross-street sidewalk test, which bulldozed and
				-- replanned a whole zoned street. Refit only judges real overlap with pavement
				-- (the lenient reach for every segment); sidewalk strictness stays a PLANNING rule.
				-- rectOnRoad, NOT buildingBlocked: the index carries an "is anything standing
				-- here?" predicate and a standing house occupies its own seat, so every house
				-- near any road edit read as blocked and was demolished + rebuilt on the spot --
				-- the houses-respawn-when-I-place-a-road churn. Only pavement counts here.
				and PlotGeometry.rectOnRoad(idx, PlotGeometry.seatCorners(s.pivot, s.w, s.d), nil) then
					table.insert(bad, i)
				end
			end
			if #bad > 0 then
				-- We do the seat bookkeeping right here, so the removal signal must not also
				-- run its own split/erase pass over the group we are editing.
				local wasPruning = _pruning
				_pruning = true
				for i = #bad, 1, -1 do
					local s = table.remove(seats, bad[i]) :: Seat
					if s.bpId then
						_building.demolish(s.bpId)
						local at = table.find(g.buildingIds, s.bpId)
						if at then table.remove(g.buildingIds, at) end
					end
					-- Seats saved before spans existed cannot say which stretch to re-plan.
					if s.t0 and s.t1 then
						rehouse(g, seg, s.t0, s.t1, seats)
					end
				end
				_pruning = wasPruning
				if #seats == 0 then
					eraseGroup(id)
					table.insert(removed, id)
				else
					table.sort(seats, function(a, b) return (a.t0 or 0) < (b.t0 or 0) end)
					-- ponytail: the group keeps its original span even when a seat was not
					-- replaced, so that stretch stays zoned rather than reopening. Split it
					-- through seatRuns if players ask to rebuild in the hole.
					table.insert(changed, toWire(g))
				end
			end
		end
	end

	if _net and (#removed > 0 or #changed > 0) then
		_net.SyncPlots:FireAllClients({
			removed = if #removed > 0 then removed else nil,
			groups = if #changed > 0 then changed else nil,
		})
	end
end

-- Studs of road movement a standing house is carried along by. Past this the street has
-- changed shape rather than just shifted, so the houses stay where they are and refitSeats
-- judges them like any other edit.
local MAX_SEAT_SHIFT = 32

-- The Move tool takes a leg OUT and puts it back under a NEW segment id. Without this every
-- group on it reads as "my road was deleted", so nudging a road one stud bulldozed every
-- zone on it. Re-point the groups at the new id, and slide each house by however far the
-- road actually moved under its own stretch of frontage. Returns true if anything moved.
local function followMovedRoads(moved: any): boolean
	if typeof(moved) ~= "table" or not _building then return false end
	local any = false
	for _, g in _groups do
		local mv = moved[g.segmentId]
		if typeof(mv) ~= "table" or not isFinite(mv.id) then continue end
		g.segmentId = mv.id
		any = true
		local a, b = mv.from, mv.to
		for _, s in (g.placed or {}) do
			local t = if s.t0 and s.t1 then (s.t0 + s.t1) * 0.5 else 0.5
			local shift = BezierUtil.point(b[1], b[2], b[3], b[4], t)
				- BezierUtil.point(a[1], a[2], a[3], a[4], t)
			local d = shift.Magnitude
			if s.bpId and d > 0.05 and d <= MAX_SEAT_SHIFT then
				local pivot = seatPivot(s.pivot + shift)
				if _building.relocate(s.bpId, pivot) then s.pivot = pivot end
			end
		end
	end
	return any
end

-- Follow the roads that MOVED, drop groups whose road segment no longer exists (road
-- deleted), then re-fit the houses the edit left overlapping pavement.
local function onTopology(change: any?)
	_roadIndexCache = nil
	local remapped = followMovedRoads(if typeof(change) == "table" then change.movedSegments else nil)
	local doomed: { number } = {}
	for id, g in _groups do
		if not segmentById(g.segmentId) then table.insert(doomed, id) end
	end
	if #doomed > 0 then
		for _, id in doomed do eraseGroup(id) end
		_net.SyncPlots:FireAllClients({ removed = doomed })
	end
	refitSeats(change)
	-- ponytail: a move re-syncs the whole plot list rather than carrying its own delta --
	-- every group on the leg changed segment id, and a move is a rare interactive edit.
	if remapped then PlotService.broadcastFull() end
end

-- A demolished building unzones the plot it stood on. Bulldozing and road-clearing both
-- live in BuildingService and never touch this service, so without this the frontage stays
-- claimed: the player cannot rebuild there, and the ghost preview still reads it as taken.
local function onBuildingRemoving(bpId: string, reason: string?)
	if _pruning then return end

	local owner: PlotGroup? = nil
	local seatIdx = 0
	for _, g in _groups do
		for i, s in (g.placed or {}) do
			if s.bpId == bpId then
				owner, seatIdx = g, i
				break
			end
		end
		if owner then break end
	end
	if not owner then return end

	local g = owner :: PlotGroup
	local seats = g.placed :: { Seat }
	local gone = table.remove(seats, seatIdx) :: Seat
	local at = table.find(g.buildingIds, bpId)
	if at then table.remove(g.buildingIds, at) end

	-- A road edit took this house, so the plot is RE-ZONED rather than handed back: whatever
	-- still fits beside the new pavement goes straight up. Nothing fits -> the span shrinks
	-- below, exactly as a bulldoze would. Only a deliberate demolition unzones.
	if reason == "road" and gone.t0 and gone.t1 then
		local seg = segmentById(g.segmentId)
		if seg then
			local wasPruning = _pruning
			_pruning = true
			rehouse(g, seg, gone.t0 :: number, gone.t1 :: number, seats)
			_pruning = wasPruning
		end
	end

	local removed: { number } = {}
	local changed: { any } = {}

	if #seats == 0 then
		-- Nothing left standing here: the zoning goes with it.
		eraseGroup(g.id)
		table.insert(removed, g.id)
	else
		-- Seats saved before spans existed cannot say which stretch to give back, so those
		-- groups keep their original span rather than shrink to a wrong one.
		local spanned = true
		for _, s in seats do
			if not (s.t0 and s.t1) then
				spanned = false
				break
			end
		end
		if spanned then
			for i, run in seatRuns(seats) do
				local target = g
				if i > 1 then
					_nextId += 1
					target = table.clone(g)
					target.id = _nextId
					_groups[target.id] = target
				end
				local ids: { string } = {}
				for _, s in run do
					if s.bpId then table.insert(ids, s.bpId) end
				end
				target.placed = run
				target.buildingIds = ids
				target.t0 = run[1].t0 :: number
				target.t1 = run[#run].t1 :: number
				table.insert(changed, toWire(target))
			end
		else
			table.insert(changed, toWire(g))
		end
	end

	if _net then
		_net.SyncPlots:FireAllClients({
			removed = if #removed > 0 then removed else nil,
			groups = if #changed > 0 then changed else nil,
		})
	end
end

-- Exposed for future queries.
function PlotService.getGroups(): { [number]: PlotGroup }
	return _groups
end

function PlotService.clear()
	for id in _groups do eraseGroup(id) end
	_groups = {}
	_nextId = 0
	PlotService.broadcastFull()
end

-- Persistence: groups are the source; buildings rebuild on restore (mode "instant" = no crane).
function PlotService.serialize(): { any }
	local out: { any } = {}
	for _, g in _groups do
		-- b: the seated buildings as flat numbers {x, y, z, yawDeg, w, d, frontage, depth}.
		-- Re-snapped to the save grid on the way out: a CFrame holds float32, so reading a
		-- pivot back yields 123.4000015 for the 123.4 that went in. Left alone that noise
		-- would ride into the blob (longer numbers, and the first save after a load would
		-- differ from the one before it for no reason).
		-- Drop seats whose building is gone -- bulldozed, or cleared by a road laid over it.
		-- Neither of those paths goes through this service, so g.placed is stale by the time
		-- a save runs; without this the next load rebuilds a house the player demolished.
		-- A seat that never produced a building (no template for its size) is KEPT: dropping
		-- it would erase the plot from the save for good.
		local live: { Seat } = {}
		for _, s in (g.placed or {}) do
			if not s.bpId or not _building or _building.exists(s.bpId) then
				table.insert(live, s)
			end
		end
		g.placed = live

		local rows: { any } = {}
		for _, s in live do
			local p = s.pivot.Position
			if s.t0 and s.t1 then
				table.insert(rows, { r1(p.X), r1(p.Y), r1(p.Z), yawDegOf(s.pivot), s.w, s.d, r1(s.fw), r1(s.fd), r6(s.t0), r6(s.t1) })
			else
				table.insert(rows, { r1(p.X), r1(p.Y), r1(p.Z), yawDegOf(s.pivot), s.w, s.d, r1(s.fw), r1(s.fd) })
			end
		end
		-- s = 1 marks the seated format: b is the COMPLETE list of buildings on this frontage,
		-- so an empty b means "the player cleared them all", not "re-plan me". Without the
		-- marker a fully bulldozed group would come back fully rebuilt on the next load.
		table.insert(out, { seg = g.segmentId, side = g.side, t0 = r6(g.t0), t1 = r6(g.t1),
			depth = r6(g.depth), width = g.width, zone = g.zone, building = g.building,
			uniform = if g.uniform then true else nil, bw = g.bw, b = rows, s = 1, den = g.density })
	end
	return out
end

function PlotService.restore(list: any)
	_roadIndexCache = nil -- roads were just restored; rebuild against the new network
	for id in _groups do eraseGroup(id) end
	_groups = {}
	_nextId = 0
	if typeof(list) == "table" then
		for _, e in list do
			if typeof(e) == "table" and isFinite(e.seg) and (e.side == 1 or e.side == -1 or e.side == 2 or e.side == -2)
				and isFinite(e.t0) and isFinite(e.t1) and ZoneTypes.isValid(e.zone) and e.zone ~= "None" then
				_nextId += 1
				local g: PlotGroup = {
					id = _nextId, segmentId = e.seg, side = e.side,
					t0 = math.clamp(e.t0, 0, 1), t1 = math.clamp(e.t1, 0, 1),
					depth = math.clamp(if isFinite(e.depth) then e.depth else DEFAULT_DEPTH, MIN_DEPTH, MAX_DEPTH),
					width = if isFinite(e.width) then e.width else PlotGeometry.DEFAULT_PLOT_WIDTH,
					uniform = if e.uniform == true then true else nil,
					bw = if isFinite(e.bw) then math.clamp(e.bw, 2, 5) else nil,
					zone = e.zone, building = if typeof(e.building) == "string" then e.building else nil, buildingIds = {},
					-- Saves from before density existed carry no `den` and load as houses.
					density = if e.den == "Medium" and e.zone == "Residential" then "Medium" else nil,
				}
				-- Saved seats replay verbatim; only a pre-seat save re-plans from the roads.
				local seats = if e.s == 1 then (readSeats(e.b) or {}) else readSeats(e.b)
				if seats then
					local built = developSeats(g, seats)
					if built < #seats then
						warn(string.format("[PlotService] segment %d: restored %d of %d saved buildings",
							g.segmentId, built, #seats))
					end
					-- Kept even when nothing built (a missing template folder, say). Dropping
					-- the group here would erase those plots from the next save for good --
					-- the seats are the only remaining record of them.
					_groups[g.id] = g
				elseif developGroup(g, "instant") > 0 then
					_groups[g.id] = g
				else
					_nextId -= 1
				end
			end
		end
	end
	PlotService.broadcastFull()
end

-- Server-side density gate (ProgressionService.isDensityAllowed via Bootstrap). The
-- client greys a locked density card; this is what actually refuses it.
function PlotService.setUnlockCheck(fn: (density: string) -> boolean)
	_densityAllowed = fn
end

function PlotService.Init(roadService: any, net: any, buildingService: any)
	_roadService = roadService
	_net = net
	_building = buildingService
end

function PlotService.Bind()
	if _bound then return end
	_bound = true

	_net.RequestPlacePlots.OnServerEvent:Connect(place)

	_net.RequestBuildingCatalog.OnServerInvoke = function(_player: Player): any
		return if _building then _building.getCatalog() else {}
	end

	if _roadService.onTopologyChanged then
		_topoDisc = _roadService.onTopologyChanged(onTopology)
	end

	if _building and _building.onBuildingRemoving then
		_bldgDisc = _building.onBuildingRemoving(onBuildingRemoving)
	end

	Players.PlayerAdded:Connect(function(p: Player)
		PlotService.broadcastFull(p)
	end)
	for _, p in Players:GetPlayers() do
		PlotService.broadcastFull(p)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		_lastPlaceAt[p] = nil
	end)
end

function PlotService.Start() end

return PlotService
