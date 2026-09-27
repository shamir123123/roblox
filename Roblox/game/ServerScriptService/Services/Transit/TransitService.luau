--!strict
-- TransitService
-- Owns the public-transit domain: player-placed Bus Depots and Bus Stops, and the bus
-- ROUTES drawn between stops. It is the single source of truth for that data -- it
-- validates the placement/route remotes, snaps stops to the kerb, names them, auto-paths
-- each route along the road network, persists everything, answers "is transit a good
-- option for this trip?" for CitizenService, and feeds the economy fares + upkeep.
--
-- It does NOT drive the buses -- BusDispatchService owns the runtime fleet and reads
-- routes/stops/depots from here. Mirrors EmergencyService for placement + persistence
-- and exposes a small wire snapshot via SyncTransit for the route overlay + overview UI.

local CollectionService   = game:GetService("CollectionService")
local Workspace           = game:GetService("Workspace")
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

local TransitTypes     = require(ReplicatedStorage.Transit.TransitTypes)
local RoadTypeCatalog  = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadConstants    = require(ReplicatedStorage.Road.RoadConstants)
local BezierUtil       = require(ReplicatedStorage.Road.BezierUtil)
local VehicleTypes     = require(ReplicatedStorage.Road.VehicleTypes)
local Quant            = require(ReplicatedStorage.Shared.Quant)
local NetMiddleware    = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local TerrainPadService = require(ServerScriptService.Services.Terrain.TerrainPadService)
local TransitBuildingModel = require(ServerScriptService.Services.Transit.TransitBuildingModel)
local ServicePlacement = require(ServerScriptService.Services.City.ServicePlacement)
local AddressBook      = require(ReplicatedStorage.City.AddressBook)

local TransitService = {}

-- == Tuning ====================================================================
local CMD_COOLDOWN     = 0.05  -- per-player min gap between transit commands
local PLACE_COOLDOWN   = 0.15
local STOP_MAX_ROAD_DIST = 36 * RoadConstants.WORLD_SCALE  -- a stop guess further than this from any lane is rejected
local STOP_SEGMENT_LINK_TOLERANCE = 18 * RoadConstants.WORLD_SCALE -- handles segment ids changed by splits/reforms
local SYNC_INTERVAL    = 1.5   -- seconds between live-stat broadcasts
local ROUTE_REBUILD_DEBOUNCE = 0.15
local WALK_SPEED       = 5 * RoadConstants.WORLD_SCALE -- studs/s, NPCWalkingService.WALK_SPEED: the estimate uses the pace people really walk
local BUS_SPEED_EST    = 24 * RoadConstants.WORLD_SCALE -- studs/s, effective bus speed incl. stops (for the estimate)
local TRAIN_SPEED_EST  = 55 * RoadConstants.WORLD_SCALE -- studs/s, effective train speed incl. station dwells
local RIDE_DETOUR      = 1.25  -- straight-line distance -> ride distance fudge

-- == Stop naming ===============================================================
-- A stop is named for the landmark it serves when there is one within sight, and
-- for its street address otherwise -- the convention every real transit map uses.
-- Street names themselves come from AddressBook (the city-wide source of truth),
-- not from anything transit owns.
local LANDMARK_RADIUS = 90 * RoadConstants.WORLD_SCALE
-- ServiceName is the display name EmergencyService + EducationService already
-- stamp on their models, so no new data is needed to name a stop after one.
local LANDMARK_FOLDERS = { "EmergencyServices", "Schools" }

-- addressIndex + landmarkNear live further down, next to placeStop: they read
-- _roadService, which is not declared until the state section below.


-- == State =====================================================================
type Depot = {
	id: number, key: string, cf: CFrame, entrance: Vector3, model: Model,
}
type Stop = {
	id: number, key: string, pos: Vector3, roadPos: Vector3, facing: CFrame,
	segmentId: number, edgeId: string?, name: string, model: Model,
	mode: string, -- "bus" | "train": which nav graph the stop boards from
	-- live ridership stat (boardings this economy-month; runtime only, not persisted)
	boardings: number, displayBoardings: number,
}
type Route = {
	id: number, name: string, color: Color3, colorIndex: number, enabled: boolean,
	mode: string, -- "bus" | "train"; busCount counts vehicles of that mode
	fare: number, busCount: number, closed: boolean,
	stops: { number },                 -- ordered stop ids
	waypoints: { [number]: { Vector3 } }, -- leg index -> shaping points
	pending: { Vector3 },              -- waypoints accumulating for the next leg
	-- derived
	path: { Vector3 },
	legEdges: { { string } },
	legPaths: { { Vector3 } }, -- per-leg polylines (TrainDispatchService rides these; server-only)
	lengthStuds: number,
	-- live (set by BusDispatchService)
	activeBuses: number, passengers: number, displayPassengers: number, usage: number,
	-- live fare income this economy-month (runtime only, not persisted)
	revenue: number, displayRevenue: number,
}

local _net: any
local _roadService: any
local _buildingService: any
local _economyService: any
local _folder: Folder
-- True once Start() has run (CitySlotService calls this only after a city has
-- actually loaded). Gates the PlayerAdded join-sync below so a player sitting in
-- the main menu (no city loaded yet) doesn't get a SyncTransit fire for nothing.
local _started = false

local _depots: { [number]: Depot } = {}
local _stops: { [number]: Stop } = {}
local _routes: { [number]: Route } = {}
local _depotId, _stopId, _routeId, _routeColorSeq = 0, 0, 0, 0
local _fareRevenue = 0

-- == Riders ======================================================================
-- Ridership is REAL. A citizen who chose transit stands at the board stop until a bus or
-- train of their line pulls in with a free seat, rides it, and gets off when it reaches
-- their stop; the fare is paid on boarding. A full vehicle leaves them waiting for the next
-- one, and a line with nothing running leaves them waiting until they give up and walk.
type Rider = {
	id: number, routeId: number, boardStopId: number, alightStopId: number,
	waited: number, patience: number,
	onBoard: (() -> ())?, onAlight: (Vector3) -> (), onGiveUp: () -> (),
	vehicle: any?,
}
local _riders: { [number]: Rider } = {}
local _riderSeq = 0
local RIDER_PATIENCE_MIN = 90   -- game-seconds a rider waits at minimum before walking instead
local RIDER_PATIENCE_HEADWAYS = 2.5 -- ...or this many expected headways, whichever is longer
local _lastCmdAt: { [Player]: number } = {}
local _lastPlaceAt: { [Player]: number } = {}
local _dirty = false
local _routeRebuildQueued = false
local _routeRebuildVersion = 0
local _fleetClearer: (() -> ())? = nil -- BusDispatchService.clear, injected in Bootstrap

-- == Helpers ===================================================================
local function nav(): any?
	return _roadService and _roadService.getNavigationGraph()
end

local function railNav(): any?
	return _roadService and _roadService.getRailGraph and _roadService.getRailGraph()
end

local function graphFor(mode: string?): any?
	return if mode == "train" then railNav() else nav()
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function flatDistSq(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return dx * dx + dz * dz
end

local function nearestPointOnEdge(edge: any, pos: Vector3): (number, Vector3, number)
	local points = edge and edge.points
	if typeof(points) ~= "table" or #points == 0 then
		return 1, pos, math.huge
	end
	local bestIndex = 1
	local bestPoint = points[1]
	local bestD = math.huge
	for i, p in points do
		local d = flatDistSq(p, pos)
		if d < bestD then
			bestD = d
			bestIndex = i
			bestPoint = p
		end
	end
	return bestIndex, bestPoint, bestD
end

local function nearestBoardingEdge(g: any, segmentId: number?, curbPos: Vector3, fallbackEdge: any?): (any?, number?, Vector3?)
	local bestEdge = nil
	local bestIndex = nil
	local bestPoint = nil
	local bestD = math.huge
	for _, edge in g:GetEdges() do
		if not segmentId or edge.segmentId == segmentId then
			local idx, point, d = nearestPointOnEdge(edge, curbPos)
			if d < bestD then
				bestD = d
				bestEdge = edge
				bestIndex = idx
				bestPoint = point
			end
		end
	end
	if bestEdge then
		return bestEdge, bestIndex, bestPoint
	end
	if fallbackEdge then
		local idx, point = nearestPointOnEdge(fallbackEdge, curbPos)
		return fallbackEdge, idx, point
	end
	return nil, nil, nil
end

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Transit")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "Transit"; f.Parent = city
	end
	return f :: Folder
end

local function canEdit(player: Player): boolean
	if Workspace:GetAttribute("RoadEditOpen") == true then return true end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

-- == Model builders ============================================================
local function newPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name; p.Size = size; p.CFrame = cf; p.Color = color
	p.Material = mat or Enum.Material.SmoothPlastic
	p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false
	p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Geometry is built procedurally (TransitBuildingModel); the depot bakes Park1..N
-- attachments BusDispatchService reads to seat the parked fleet.
local function buildDepotModel(spec: TransitTypes.DepotSpec, footprint: Vector3): Model
	return TransitBuildingModel.buildDepot(spec, footprint)
end

local function buildStopModel(spec: TransitTypes.StopSpec): Model
	if spec.mode == "train" then
		return TransitBuildingModel.buildStation(spec)
	end
	return TransitBuildingModel.buildStop(spec)
end

-- Development Tree gate (ProgressionService.isPlaceableAllowed), injected by Bootstrap.
-- The client hiding a locked card is presentation; THIS is the rule.
local _isPlaceableAllowed: ((string) -> boolean)? = nil

function TransitService.setUnlockCheck(fn: ((string) -> boolean)?)
	_isPlaceableAllowed = fn
end

local function isUnlocked(key: string): boolean
	local check = _isPlaceableAllowed
	return check == nil or check(key) == true
end

-- Territory gate (TerritoryService.isBoxAllowed), injected by Bootstrap. The unlock check
-- above answers "is this building available"; this answers "is this GROUND yours". Asked of
-- the whole FOOTPRINT, not the pivot: half a building over the border is not a building you
-- are allowed to put up. No check injected (tests, tooling) means nothing is gated.
local _territoryCheck: ((Vector3, number, number) -> boolean)? = nil

local function isOnOwnedLand(pos: Vector3, hx: number, hz: number): boolean
	local check = _territoryCheck
	return check == nil or check(pos, hx, hz) == true
end
function TransitService.setTerritoryCheck(fn: ((Vector3, number, number) -> boolean)?)
	_territoryCheck = fn
end

-- == Depot placement (free placement; ServicePlacement.prepareFree) ============
local function spawnDepot(id: number, key: string, pivot: CFrame, entrance: Vector3): Depot?
	local spec = TransitTypes.getDepot(key)
	if not spec then return nil end
	local fp = TransitTypes.depotFootprintStuds(spec)
	local model = buildDepotModel(spec, fp)
	model:PivotTo(pivot)
	model:SetAttribute("DepotId", id)
	model:SetAttribute("TransitKind", "Depot")
	CollectionService:AddTag(model, "BusDepot")
	model.Parent = _folder
	pcall(TerrainPadService.padFootprint, "transit:" .. id, pivot, fp.X, fp.Z, pivot.Position.Y)
	local depot: Depot = { id = id, key = key, cf = pivot, entrance = entrance, model = model }
	_depots[id] = depot
	return depot
end

-- `actor` only decides who gets the cost tag and the build sound back; the depot is city
-- state and replicates to everyone either way.
function TransitService.placeDepot(key: string, pivotIn: CFrame, actor: Player?): (boolean, string?)
	local spec = TransitTypes.getDepot(key)
	if not spec then return false, "unknown depot" end
	if not isUnlocked(key) then return false, "that depot is not unlocked yet" end

	local fp = TransitTypes.depotFootprintStuds(spec)
	local pivot, reason = ServicePlacement.prepareFree(fp, pivotIn)
	if not pivot then return false, reason end

	-- After prepareFree, so the land test sees where the depot actually lands. STOPS are
	-- deliberately not gated here: a stop must sit on a road, and a road can only have been
	-- built on land the city owns.
	if not isOnOwnedLand(pivot.Position, fp.X * 0.5, fp.Z * 0.5) then
		return false, "you do not own this land"
	end

	if _economyService and _economyService.trySpend then
		if not _economyService.trySpend(spec.cost) then return false, "can't afford" end
	end

	local entrance = (pivot * CFrame.new(0, 0, fp.Z * 0.5 + 4)).Position

	_depotId += 1
	if not spawnDepot(_depotId, key, pivot, entrance) then
		if _economyService and _economyService.credit then _economyService.credit(spec.cost) end
		return false, "build failed"
	end
	if _net and _economyService and actor then _net.PlacementCharged:FireClient(actor, pivot.Position, spec.cost, "Building") end
	_dirty = true
	return true
end

local function releaseDepot(d: Depot)
	pcall(TerrainPadService.unpadFootprint, "transit:" .. d.id)
	if d.model and d.model.Parent then d.model:Destroy() end
end

function TransitService.removeDepot(id: number)
	local d = _depots[id]
	if not d then return end
	releaseDepot(d)
	_depots[id] = nil
	-- Buses are allowed again only up to the remaining depot capacity; clamp route assignments.
	TransitService._clampBusAssignments()
	_dirty = true
end

local function addressIndex(): AddressBook.Index
	local net = _roadService and _roadService.getNetwork and _roadService.getNetwork()
	return AddressBook.buildIndex(if net then net:getSegments() else {})
end

-- Nearest civic building worth naming a stop after.
local function landmarkNear(pos: Vector3): string?
	local city = Workspace:FindFirstChild("_City")
	if not city then return nil end
	local best: string? = nil
	local bestD = LANDMARK_RADIUS
	for _, folderName in LANDMARK_FOLDERS do
		local folder = city:FindFirstChild(folderName)
		if not folder then continue end
		for _, model in folder:GetChildren() do
			local name = model:GetAttribute("ServiceName")
			if typeof(name) ~= "string" or not model:IsA("Model") then continue end
			local p = model:GetPivot().Position
			local dx, dz = p.X - pos.X, p.Z - pos.Z
			local d = math.sqrt(dx * dx + dz * dz)
			if d < bestD then
				best, bestD = name, d
			end
		end
	end
	return best
end

-- == Stop placement (curbside, faces the road) =================================
-- `guess` is the client's cursor hit near a road. The server snaps to the nearest lane,
-- rejects if there is no road close by, and offsets the shelter out to the kerb on the
-- side the cursor is on so it faces the carriageway.
-- `info` is either a bare cursor Vector3 (legacy) or { pos = cursor, road = centreline,
-- seg = segmentId } sent by the client. The bus BOARDS at the nearest lane point; the
-- shelter sits just outside the carriageway on the side the cursor is on (the sidewalk),
-- facing the road.
-- `actor` as in placeDepot: the cost tag and build sound are theirs alone.
function TransitService.placeStop(key: string, info: any, actor: Player?): (boolean, any)
	local spec = TransitTypes.getStop(key)
	if not spec then return false, "unknown stop" end
	if not isUnlocked(key) then return false, "that stop is not unlocked yet" end
	local mode = spec.mode or "bus"
	local g = graphFor(mode)
	local nearMsg = if mode == "train" then "not near a track" else "not near a road"
	if not g then return false, if mode == "train" then "no track" else "no roads" end

	local cursor: Vector3, center: Vector3?, segId: number?
	if typeof(info) == "Vector3" then
		cursor = info
	elseif typeof(info) == "table" then
		cursor = info.pos
		center = if typeof(info.road) == "Vector3" then info.road else nil
		segId = if typeof(info.seg) == "number" then info.seg else nil
	end
	if typeof(cursor) ~= "Vector3" or cursor ~= cursor then return false, "bad position" end

	local ref = center or cursor
	local ok, res = pcall(function() return g:NearestEdge(ref) end)
	if not ok or not res or not res.edge then return false, nearMsg end
	local pts = res.edge.points
	local idx = math.clamp(res.index or 1, 1, #pts)
	local nearestLanePoint = pts[idx]
	if flatDist(nearestLanePoint, cursor) > STOP_MAX_ROAD_DIST then return false, nearMsg end

	local net = _roadService.getNetwork and _roadService.getNetwork()
	local seg = net and ((segId and net:getSegment(segId)) or net:getSegment(res.edge.segmentId))
	local segmentId = (seg and seg.id) or res.edge.segmentId
	local halfW = 8
	if seg then halfW = RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5 end

	local cp = center or nearestLanePoint
	local outward = Vector3.new(cursor.X - cp.X, 0, cursor.Z - cp.Z)
	if outward.Magnitude < 0.5 then
		local nextP = pts[math.min(idx + 1, #pts)]
		local prevP = pts[math.max(idx - 1, 1)]
		local tangent = Vector3.new(nextP.X - prevP.X, 0, nextP.Z - prevP.Z)
		if tangent.Magnitude < 1e-3 then tangent = Vector3.xAxis end
		tangent = tangent.Unit
		outward = Vector3.new(-tangent.Z, 0, tangent.X)
	end

	local curbGuess = cp + outward.Unit * (halfW + spec.curbOffset * RoadConstants.WORLD_SCALE)
	local boardEdge, _, boardPos = nearestBoardingEdge(g, segmentId, curbGuess, res.edge)
	if not boardEdge or not boardPos then return false, nearMsg end
	if flatDist(boardPos, cursor) > STOP_MAX_ROAD_DIST then return false, nearMsg end

	-- Spacing only applies to stops on the same side of the same road segment, so a
	-- stop can be placed directly opposite another one across the carriageway --
	-- that's the normal one-stop-per-direction pattern, not crowding.
	for _, s in _stops do
		if s.mode == mode and s.segmentId == segmentId then
			local sOutward = Vector3.new(s.pos.X - s.roadPos.X, 0, s.pos.Z - s.roadPos.Z)
			local sameSide = sOutward:Dot(outward) > 0
			if sameSide and flatDist(s.roadPos, boardPos) < TransitTypes.STOP_MIN_SPACING then
				return false, "too close to another stop"
			end
		end
	end

	local y = boardPos.Y
	local curbPos = Vector3.new(curbGuess.X, y, curbGuess.Z)
	-- The Pole (PrimaryPart) is poleHeight studs tall; PivotTo places its centre.
	-- Lift the pivot by half the pole height so the base sits on the ground.
	local poleHalfH = spec.poleHeight * 0.5 * RoadConstants.WORLD_SCALE
	local pivotPos = Vector3.new(curbPos.X, y + poleHalfH, curbPos.Z)
	-- The shelter open/sign side must face the road; the template's sign is on +Z,
	-- BackGlass on -Z. CFrame.lookAt makes +Z point at the road centre, so we
	-- rotate 180 degrees around Y to flip the shelter so its open side faces the road.
	-- curbOffset keeps the pad on the sidewalk, just outside the carriageway edge.
	local baseCF = CFrame.lookAt(pivotPos, Vector3.new(cp.X, pivotPos.Y, cp.Z))
	local facing = baseCF * CFrame.Angles(0, math.pi, 0)

	if _economyService and _economyService.trySpend then
		if not _economyService.trySpend(spec.cost) then return false, "can't afford" end
	end

	_stopId += 1
	local model = buildStopModel(spec)
	model:PivotTo(facing)
	model:SetAttribute("StopId", _stopId)
	model:SetAttribute("RoadSegmentId", segmentId)
	model:SetAttribute("TransitKind", "Stop")
	CollectionService:AddTag(model, if mode == "train" then "TrainStation" else "BusStop")
	model.Parent = _folder

	local index = addressIndex()
	local street = AddressBook.nameOf(index, segmentId)
	local landmark = landmarkNear(curbPos)
	local name: string
	if mode == "train" then
		-- Stations take a single word: "Riverside Station", not "14 Riverside Road Station".
		name = (landmark or (street and string.match(street, "^%S+")) or "Central") .. " Station"
	elseif landmark then
		name = landmark .. " Stop"
	elseif street then
		name = tostring(AddressBook.numberAt(index, segmentId, curbPos)) .. " " .. street
	else
		name = "Bus Stop " .. tostring(_stopId)
	end
	model:SetAttribute("StopName", name)
	local stop: Stop = {
		id = _stopId, key = key, pos = curbPos, roadPos = boardPos, facing = facing,
		segmentId = segmentId, edgeId = boardEdge.id, name = name, model = model, mode = mode,
		boardings = 0, displayBoardings = 0,
	}
	_stops[_stopId] = stop
	if _net and _economyService and actor then _net.PlacementCharged:FireClient(actor, curbPos, spec.cost, "Building") end
	_dirty = true
	return true, _stopId
end

-- Removing the stop at `index` merges legs index-1 and index into one; their shaping
-- waypoints no longer apply, and every later leg's waypoints shift down one slot.
-- Without this, waypoints stay keyed to the OLD leg indices and attach to the wrong
-- legs after any mid-route stop removal. `oldCount` is the stop count before removal
-- (the closing leg, index oldCount, touches stop 1).
local function shiftWaypointsForRemoval(route: Route, index: number, oldCount: number)
	local out: { [number]: { Vector3 } } = {}
	for leg, list in route.waypoints do
		local touches = leg == index or leg == index - 1 or (index == 1 and leg == oldCount)
		if not touches then
			out[if leg > index then leg - 1 else leg] = list
		end
	end
	route.waypoints = out
end

local function detachStopFromRoutes(stopId: number)
	for _, route in _routes do
		local changed = false
		for i = #route.stops, 1, -1 do
			if route.stops[i] == stopId then
				local oldCount = #route.stops
				table.remove(route.stops, i)
				shiftWaypointsForRemoval(route, i, oldCount)
				changed = true
			end
		end
		if changed then
			if #route.stops < 2 then route.closed = false end
			TransitService._recomputeRoute(route)
		end
	end
end

function TransitService.removeStop(id: number)
	local s = _stops[id]
	if not s then return end
	if s.model and s.model.Parent then s.model:Destroy() end
	_stops[id] = nil
	detachStopFromRoutes(id)
	_dirty = true
end

function TransitService.removeStopsForSegment(segmentId: number)
	local segment = nil
	if _roadService and _roadService.getNetwork then
		local network = _roadService.getNetwork()
		segment = network and network:getSegment(segmentId) or nil
	end

	local ids: { number } = {}
	for id, stop in _stops do
		local attached = stop.segmentId == segmentId
		if not attached and segment then
			-- A crossing split or road re-form can replace segment ids after the stop was
			-- placed. Its boarding point remains on the owning curve, so use that as a
			-- robust fallback while the segment still exists (the callback runs pre-remove).
			local t = BezierUtil.closestParam(segment.p0, segment.p1, segment.p2, segment.p3, stop.roadPos, 16)
			local point = BezierUtil.point(segment.p0, segment.p1, segment.p2, segment.p3, t)
			attached = flatDist(point, stop.roadPos) <= STOP_SEGMENT_LINK_TOLERANCE
		end
		if attached then table.insert(ids, id) end
	end
	for _, id in ids do
		TransitService.removeStop(id)
	end
end

-- == Routes ====================================================================
-- Re-path route legs along the road network. While the player is still building,
-- only draw stop1->stop2->...->lastStop. Once closed, add lastStop->stop1 so buses loop.
function TransitService._recomputeRoute(route: Route)
	route.path = {}
	route.legEdges = {}
	route.legPaths = {}
	route.lengthStuds = 0
	local g = graphFor(route.mode)
	if not g then return end
	local n = #route.stops
	if n < 2 then return end
	local legCount = if route.closed then n else n - 1
	for i = 1, legCount do
		local a = _stops[route.stops[i]]
		local nextIndex = if i == n then 1 else i + 1
		local b = _stops[route.stops[nextIndex]]
		if not a or not b then continue end
		local pts: { Vector3 } = { a.roadPos }
		local wps = route.waypoints[i]
		if wps then for _, w in wps do table.insert(pts, w) end end
		table.insert(pts, b.roadPos)
		local legEdgeIds: { string } = {}
		local legPath: { Vector3 } = {}
		for k = 1, #pts - 1 do
			local ok, poly, edgeIds = pcall(function() return g:FindPath(pts[k], pts[k + 1], nil, VehicleTypes.Bus) end)
			if ok and poly and #poly > 0 then
				for pi, p in poly do
					if not (pi == 1 and #route.path > 0) then table.insert(route.path, p) end
					if not (pi == 1 and #legPath > 0) then table.insert(legPath, p) end
				end
				if typeof(edgeIds) == "table" then
					for _, e in edgeIds do table.insert(legEdgeIds, e) end
				end
			else
				-- No road route for this sub-leg (e.g. a one-way/divided road the graph
				-- can't connect back). Keep the route continuous with a direct segment so
				-- the loop still closes instead of leaving a visible gap.
				if #route.path == 0 then table.insert(route.path, pts[k]) end
				table.insert(route.path, pts[k + 1])
				if #legPath == 0 then table.insert(legPath, pts[k]) end
				table.insert(legPath, pts[k + 1])
			end
		end
		route.legEdges[i] = legEdgeIds
		route.legPaths[i] = legPath
	end
	for i = 2, #route.path do
		route.lengthStuds += (route.path[i] - route.path[i - 1]).Magnitude
	end
end

function TransitService.getBusAllowance(): number
	local total = 0
	for _, d in _depots do
		local spec = TransitTypes.getDepot(d.key)
		total += if spec then spec.busCapacity else 0
	end
	return total
end

function TransitService.getBusesAssigned(): number
	local n = 0
	for _, r in _routes do
		if r.closed and r.mode ~= "train" then n += r.busCount end
	end
	return n
end

function TransitService.getTrainsAssigned(): number
	local n = 0
	for _, r in _routes do
		if r.closed and r.mode == "train" then n += r.busCount end
	end
	return n
end

-- Trim route bus counts so the total never exceeds the depot allowance (after a depot
-- is removed). Trims in descending route-id order so the newest routes give up buses first.
function TransitService._clampBusAssignments()
	local allowance = TransitService.getBusAllowance()
	local ids: { number } = {}
	for id in _routes do table.insert(ids, id) end
	table.sort(ids)
	local running = 0
	for _, id in ids do
		local r = _routes[id]
		if not r.closed or r.mode == "train" then continue end -- trains need no depot allowance
		local allowed = math.max(0, allowance - running)
		if r.busCount > allowed then r.busCount = allowed end
		running += r.busCount
	end
end

function TransitService.createRoute(firstStopId: number): number?
	local first = _stops[firstStopId]
	if not first then return nil end
	local mode = first.mode
	_routeId += 1
	_routeColorSeq += 1
	-- Trains need no depot: a line gets its default trains outright. Buses draw on the depot allowance.
	local count: number
	if mode == "train" then
		count = TransitTypes.DEFAULT_TRAINS_PER_ROUTE
	else
		local allowance = TransitService.getBusAllowance()
		count = math.min(TransitTypes.DEFAULT_BUSES_PER_ROUTE, math.max(0, allowance - TransitService.getBusesAssigned()))
	end
	local route: Route = {
		id = _routeId, name = (if mode == "train" then "Train Line " else "Bus Line ") .. _routeId, mode = mode,
		color = TransitTypes.routeColor(_routeColorSeq), colorIndex = _routeColorSeq,
		enabled = true, fare = TransitTypes.DEFAULT_FARE,
		busCount = count, closed = false,
		stops = { firstStopId }, waypoints = {}, pending = {},
		path = {}, legEdges = {}, legPaths = {}, lengthStuds = 0,
		activeBuses = 0, passengers = 0, displayPassengers = 0, usage = 0,
		revenue = 0, displayRevenue = 0,
	}
	_routes[_routeId] = route
	_dirty = true
	return _routeId
end

function TransitService.addStop(routeId: number, stopId: number): boolean
	local route = _routes[routeId]
	local stop = _stops[stopId]
	if not route or not stop then return false end
	if stop.mode ~= route.mode then return false end -- bus stops on bus lines, stations on train lines
	-- Click the first stop again (>=2 stops, open route) closes the loop.
	if not route.closed and #route.stops >= 2 and stopId == route.stops[1] then
		local legIndex = #route.stops -- close the loop from current last stop back to the first
		if #route.pending > 0 then
			route.waypoints[legIndex] = route.pending
			route.pending = {}
		end
		route.closed = true
		TransitService._clampBusAssignments()
		TransitService._recomputeRoute(route)
		_dirty = true
		return true
	end
	-- Adding a stop to a closed line reopens it so the new stop joins the loop; the
	-- player clicks the first stop again to re-close it.
	if route.closed then route.closed = false end
	if #route.stops >= TransitTypes.MAX_STOPS_PER_ROUTE then return false end
	if route.stops[#route.stops] == stopId then return false end -- no immediate repeat
	table.insert(route.stops, stopId)
	local legIndex = #route.stops - 1
	if #route.pending > 0 then
		route.waypoints[legIndex] = route.pending
		route.pending = {}
	end
	TransitService._recomputeRoute(route)
	_dirty = true
	return true
end

-- Remove ONE stop from a line (Overview stop-chip click). Dropping below 2 stops reopens it.
function TransitService.removeRouteStop(routeId: number, stopId: number)
	local route = _routes[routeId]
	if not route then return end
	local removed = false
	for i = #route.stops, 1, -1 do
		if route.stops[i] == stopId then
			local oldCount = #route.stops
			table.remove(route.stops, i)
			shiftWaypointsForRemoval(route, i, oldCount)
			removed = true
			break
		end
	end
	if not removed then return end
	if #route.stops < 2 then route.closed = false end
	TransitService._clampBusAssignments()
	TransitService._recomputeRoute(route)
	_dirty = true
end

function TransitService.addWaypoint(routeId: number, pos: Vector3): boolean
	local route = _routes[routeId]
	if not route or route.closed or typeof(pos) ~= "Vector3" then return false end
	if #route.pending >= TransitTypes.MAX_WAYPOINTS_PER_LEG then return false end
	table.insert(route.pending, pos)
	_dirty = true
	return true
end

function TransitService.undoRoute(routeId: number)
	local route = _routes[routeId]
	if not route then return end
	if route.closed then
		route.closed = false
		route.waypoints[#route.stops] = nil
		TransitService._recomputeRoute(route)
		_dirty = true
		return
	end
	if #route.pending > 0 then
		table.remove(route.pending)
	elseif #route.stops > 0 then
		local legIndex = #route.stops - 1
		route.waypoints[legIndex] = nil
		table.remove(route.stops)
		if #route.stops == 0 then
			_routes[routeId] = nil
		else
			TransitService._recomputeRoute(route)
		end
	end
	_dirty = true
end

function TransitService.deleteRoute(routeId: number)
	if _routes[routeId] then _routes[routeId] = nil; _dirty = true end
end

function TransitService.setRouteBuses(routeId: number, n: number)
	local route = _routes[routeId]
	if not route or typeof(n) ~= "number" or n ~= n then return end
	if route.mode == "train" then
		route.busCount = math.clamp(math.floor(n), 0, TransitTypes.MAX_TRAINS_PER_ROUTE)
	else
		local allowance = TransitService.getBusAllowance()
		local others = TransitService.getBusesAssigned() - route.busCount
		local maxForRoute = math.max(0, allowance - others)
		route.busCount = math.clamp(math.floor(n), 0, maxForRoute)
	end
	_dirty = true
end

function TransitService.setRouteFare(routeId: number, fare: number)
	local route = _routes[routeId]
	if not route or typeof(fare) ~= "number" or fare ~= fare then return end
	route.fare = math.clamp(math.floor(fare), TransitTypes.MIN_FARE, TransitTypes.MAX_FARE)
	_dirty = true
end

function TransitService.setRouteColor(routeId: number, index: number)
	local route = _routes[routeId]
	if not route or typeof(index) ~= "number" then return end
	route.colorIndex = math.floor(index)
	route.color = TransitTypes.routeColor(route.colorIndex)
	_dirty = true
end

function TransitService.toggleRoute(routeId: number, enabled: boolean)
	local route = _routes[routeId]
	if not route then return end
	route.enabled = enabled == true
	_dirty = true
end

function TransitService.renameRoute(routeId: number, name: string)
	local route = _routes[routeId]
	if not route or typeof(name) ~= "string" then return end
	local clean = string.sub(name:gsub("[%c]", ""), 1, 28)
	if #clean > 0 then route.name = clean; _dirty = true end
end

-- == Ridership + live stats ====================================================
-- A citizen committed to riding `routeId` for one trip (CitizenService, abstract riders).
function TransitService.recordRider(routeId: number, boardStopId: number?)
	local route = _routes[routeId]
	if not route then return end
	route.passengers += 1
	route.revenue += route.fare
	_fareRevenue += route.fare
	if boardStopId then
		local stop = _stops[boardStopId]
		if stop then stop.boardings += 1 end
	end
end

-- A citizen at `boardStopId` waiting for `routeId` to take them to `alightStopId`. The
-- callbacks fire at most once each: onBoard when they get on, then onAlight(stopPos) where
-- they get off -- or onGiveUp if nothing with room comes. Returns a rider id for cancelRider.
function TransitService.waitForRide(routeId: number, boardStopId: number, alightStopId: number,
	onBoard: (() -> ())?, onAlight: (Vector3) -> (), onGiveUp: () -> ()): number
	local route = _routes[routeId]
	local headway = if route then route.lengthStuds / (BUS_SPEED_EST * math.max(1, route.busCount)) else 0
	_riderSeq += 1
	_riders[_riderSeq] = {
		id = _riderSeq, routeId = routeId, boardStopId = boardStopId, alightStopId = alightStopId,
		waited = 0, patience = math.max(RIDER_PATIENCE_MIN, headway * RIDER_PATIENCE_HEADWAYS),
		onBoard = onBoard, onAlight = onAlight, onGiveUp = onGiveUp, vehicle = nil,
	}
	return _riderSeq
end

-- Drop a rider without firing anything (their household left, or their trip was replaced).
function TransitService.cancelRider(id: number?)
	if id then _riders[id] = nil end
end

-- A vehicle of `routeId` standing at `stopId`: riders for this stop get off, then riders
-- waiting here for this line get on while there are seats. Returns how many moved, which the
-- dispatcher turns into dwell time (boarding takes time).
function TransitService.vehicleAtStop(vehicle: any, routeId: number, stopId: number, capacity: number): number
	local stop = _stops[stopId]
	if not stop then return 0 end
	local moved, aboard = 0, 0
	local leaving: { Rider } = {}
	for _, r in _riders do
		if r.vehicle == vehicle then
			if r.alightStopId == stopId then
				table.insert(leaving, r)
			else
				aboard += 1
			end
		end
	end
	for _, r in leaving do
		_riders[r.id] = nil
		moved += 1
		task.spawn(r.onAlight, stop.pos)
	end
	for _, r in _riders do
		if aboard >= capacity then break end
		if not r.vehicle and r.routeId == routeId and r.boardStopId == stopId then
			r.vehicle = vehicle
			aboard += 1
			moved += 1
			TransitService.recordRider(routeId, stopId)
			if r.onBoard then task.spawn(r.onBoard) end
		end
	end
	if vehicle and typeof(vehicle) == "Instance" then vehicle:SetAttribute("Passengers", aboard) end
	return moved
end

-- A vehicle leaving service (back to the depot, retired, destroyed): everyone aboard gets
-- off where it stands and finishes on foot.
function TransitService.vehicleOutOfService(vehicle: any, pos: Vector3)
	for id, r in _riders do
		if r.vehicle == vehicle then
			_riders[id] = nil
			task.spawn(r.onAlight, pos)
		end
	end
end

-- Riders standing at a stop, for the stop's own crowd (and its board count in the UI).
function TransitService.getWaitingCount(stopId: number): number
	local n = 0
	for _, r in _riders do
		if not r.vehicle and r.boardStopId == stopId then n += 1 end
	end
	return n
end

local function stepRiders(dt: number)
	for id, r in _riders do
		if r.vehicle then continue end
		r.waited += dt
		if r.waited >= r.patience then
			_riders[id] = nil
			task.spawn(r.onGiveUp)
		end
	end
end

-- BusDispatchService reports how many buses are live on a route (for the overview).
function TransitService.setRouteActiveBuses(routeId: number, n: number)
	local route = _routes[routeId]
	if route then route.activeBuses = n end
end

-- == Trip estimate (CitizenService mode choice) ================================
type StopCandidate = { id: number, stop: Stop, distance: number }

local function nearbyStops(pos: Vector3, reach: number): { StopCandidate }
	local out: { StopCandidate } = {}
	for id, stop in _stops do
		local distance = flatDist(stop.pos, pos)
		if distance <= reach then
			table.insert(out, { id = id, stop = stop, distance = distance })
		end
	end
	table.sort(out, function(a, b) return a.distance < b.distance end)
	while #out > 6 do table.remove(out) end
	return out
end

local function routeServes(route: Route, boardId: number, alightId: number): boolean
	if not route.enabled or route.closed ~= true or route.busCount <= 0 or #route.stops < 2 then return false end
	local hasBoard, hasAlight = false, false
	for _, sid in route.stops do
		if sid == boardId then hasBoard = true end
		if sid == alightId then hasAlight = true end
	end
	return hasBoard and hasAlight
end

-- Best transit option for a home->job trip, or nil if none is viable. The result is the
-- estimated door-to-door time + the fare so CitizenService can weigh it against driving.
export type TripEstimate = {
	usable: boolean, timeSeconds: number, fare: number,
	routeId: number, boardStopId: number, alightStopId: number,
	walkSeconds: number, waitSeconds: number, rideSeconds: number,
}
function TransitService.estimateTrip(homePos: Vector3, jobPos: Vector3): TripEstimate?
	if typeof(homePos) ~= "Vector3" or typeof(jobPos) ~= "Vector3" then return nil end
	local reach = TransitTypes.STOP_WALK_REACH
	local boards = nearbyStops(homePos, reach)
	local alights = nearbyStops(jobPos, reach)
	if #boards == 0 or #alights == 0 then return nil end

	local best: TripEstimate? = nil
	for _, boardCandidate in boards do
		for _, alightCandidate in alights do
			if boardCandidate.id == alightCandidate.id then continue end
			for _, route in _routes do
				if not routeServes(route, boardCandidate.id, alightCandidate.id) then continue end
				local walkIn = boardCandidate.distance / WALK_SPEED
				local walkOut = alightCandidate.distance / WALK_SPEED
				local rideSpeed = if route.mode == "train" then TRAIN_SPEED_EST else BUS_SPEED_EST
				local rideDist = flatDist(boardCandidate.stop.roadPos, alightCandidate.stop.roadPos) * RIDE_DETOUR
				local ride = rideDist / rideSpeed
				local loopLen = math.max(1, route.lengthStuds)
				local headway = loopLen / (rideSpeed * math.max(1, route.busCount))
				local wait = headway * 0.5
				local total = walkIn + wait + ride + walkOut
				if not best or total < best.timeSeconds then
					best = {
						usable = true,
						timeSeconds = total,
						fare = route.fare,
						routeId = route.id,
						boardStopId = boardCandidate.id,
						alightStopId = alightCandidate.id,
						walkSeconds = walkIn + walkOut,
						waitSeconds = wait,
						rideSeconds = ride,
					}
				end
			end
		end
	end
	return best
end

-- == Economy ===================================================================
function TransitService.drainFareRevenue(): number
	local r = _fareRevenue
	_fareRevenue = 0
	-- snapshot ridership into the usage stat, then reset the per-tick rider counter
	for _, route in _routes do
		local vehCap = if route.mode == "train" then TransitTypes.Train.capacity else TransitTypes.Bus.capacity
		local cap = math.max(1, route.busCount * vehCap)
		route.usage = math.clamp(route.passengers / cap, 0, 1) * 100
		route.displayPassengers = route.passengers
		route.passengers = 0
		route.displayRevenue = route.revenue
		route.revenue = 0
	end
	for _, stop in _stops do
		stop.displayBoardings = stop.boardings
		stop.boardings = 0
	end
	return r
end

-- Total boardings across all lines this economy-month (live count, or last month's
-- snapshot right after a drain -- whichever is larger). CitizenService pushes this to
-- CityStatsService so a used bus network pulls new residents in.
function TransitService.getMonthlyRiders(): number
	local riders = 0
	for _, r in _routes do
		riders += math.max(r.displayPassengers, r.passengers)
	end
	return riders
end

function TransitService.getMonthlyUpkeep(): number
	local upkeep = 0
	for _, d in _depots do
		local spec = TransitTypes.getDepot(d.key)
		upkeep += if spec then spec.upkeep else 0
	end
	upkeep += TransitService.getBusesAssigned() * TransitTypes.BUS_UPKEEP
	upkeep += TransitService.getTrainsAssigned() * TransitTypes.TRAIN_UPKEEP
	return upkeep
end

-- == Getters for BusDispatchService ============================================
function TransitService.getDepots(): { Depot } local o = {}; for _, d in _depots do table.insert(o, d) end; return o end
function TransitService.getRoute(routeId: number): Route? return _routes[routeId] end
function TransitService.getStop(stopId: number): Stop? return _stops[stopId] end
function TransitService.getRouteIds(): { number } local o = {}; for id in _routes do table.insert(o, id) end; return o end

-- Nearest depot entrance to a position (where a bus spawns/returns), or nil if no depot.
function TransitService.nearestDepotEntrance(pos: Vector3): Vector3?
	local best, bestD = nil, math.huge
	for _, d in _depots do
		local dist = flatDist(d.entrance, pos)
		if dist < bestD then bestD = dist; best = d.entrance end
	end
	return best
end

-- The runtime fleet lives in BusDispatchService; let it wipe its buses when the whole
-- transit domain is cleared (city unload / reload) instead of waiting for a reconcile.
function TransitService.setFleetClearer(fn: () -> ())
	_fleetClearer = fn
end

function TransitService.clear()
	if _fleetClearer then pcall(_fleetClearer) end
	for id, d in _depots do releaseDepot(d); _depots[id] = nil end
	for id, s in _stops do if s.model and s.model.Parent then s.model:Destroy() end; _stops[id] = nil end
	table.clear(_routes)
	_depotId, _stopId, _routeId, _routeColorSeq, _fareRevenue = 0, 0, 0, 0, 0
	table.clear(_riders)
	_dirty = true
end

-- == Wire snapshot + broadcast =================================================
local function snapshot(): any
	local depots = {}
	for _, d in _depots do
		local spec = TransitTypes.getDepot(d.key)
		table.insert(depots, { id = d.id, pos = d.cf.Position, cap = if spec then spec.busCapacity else 0 })
	end
	local stops = {}
	for _, s in _stops do table.insert(stops, { id = s.id, pos = s.pos, name = s.name, mode = s.mode, boardings = s.displayBoardings }) end
	local routes = {}
	local totalRevenue = 0
	for _, r in _routes do
		local outPath = {}
		local stepN = math.max(1, math.floor(#r.path / 160))
		for i = 1, #r.path, stepN do table.insert(outPath, r.path[i]) end
		if #r.path > 0 and outPath[#outPath] ~= r.path[#r.path] then table.insert(outPath, r.path[#r.path]) end
		totalRevenue += r.displayRevenue
		table.insert(routes, {
			id = r.id, name = r.name, color = r.color, enabled = r.enabled, fare = r.fare, mode = r.mode,
			busCount = r.busCount, closed = r.closed, stops = table.clone(r.stops), path = outPath,
			length = r.lengthStuds, passengers = r.displayPassengers, usage = r.usage, activeBuses = r.activeBuses,
			revenue = r.displayRevenue,
		})
	end
	return {
		depots = depots, stops = stops, routes = routes,
		allowance = TransitService.getBusAllowance(), assigned = TransitService.getBusesAssigned(),
		upkeep = TransitService.getMonthlyUpkeep(), revenue = totalRevenue,
	}
end

function TransitService.broadcast()
	if _net then _net.SyncTransit:FireAllClients(snapshot()) end
	_dirty = false
end

-- == Persistence ===============================================================
local function v3arr(v: Vector3): { number } return { v.X, v.Y, v.Z } end
local function arrV3(t: any): Vector3?
	if typeof(t) ~= "table" or #t ~= 3 then return nil end
	return Vector3.new(tonumber(t[1]) or 0, tonumber(t[2]) or 0, tonumber(t[3]) or 0)
end

function TransitService.serialize(): any
	local depots = {}
	for _, d in _depots do
		table.insert(depots, { id = d.id, key = d.key, pivot = Quant.packPivot(d.cf), ent = v3arr(d.entrance) })
	end
	local stops = {}
	for _, s in _stops do
		table.insert(stops, {
			id = s.id, key = s.key, pos = v3arr(s.pos), road = v3arr(s.roadPos),
			facing = Quant.packPivot(s.facing), seg = s.segmentId, edge = s.edgeId, name = s.name,
		})
	end
	local routes = {}
	for _, r in _routes do
		local wps = {}
		for leg, list in r.waypoints do
			local arr = {}
			for _, w in list do table.insert(arr, v3arr(w)) end
			wps[tostring(leg)] = arr
		end
		table.insert(routes, {
			id = r.id, name = r.name, colorIndex = r.colorIndex, enabled = r.enabled, mode = r.mode,
			fare = r.fare, busCount = r.busCount, closed = r.closed, stops = table.clone(r.stops), wps = wps,
		})
	end
	return { version = 1, depotId = _depotId, stopId = _stopId, routeId = _routeId, colorSeq = _routeColorSeq,
		depots = depots, stops = stops, routes = routes }
end

function TransitService.restore(data: any)
	TransitService.clear()
	if typeof(data) ~= "table" then return end
	_depotId = math.max(0, math.floor(tonumber(data.depotId) or 0))
	_stopId  = math.max(0, math.floor(tonumber(data.stopId) or 0))
	_routeId = math.max(0, math.floor(tonumber(data.routeId) or 0))
	_routeColorSeq = math.max(0, math.floor(tonumber(data.colorSeq) or 0))

	if typeof(data.depots) == "table" then
		for _, row in data.depots do
			if typeof(row) ~= "table" or typeof(row.key) ~= "string" or not TransitTypes.getDepot(row.key) then continue end
			local pivot = Quant.unpackPivot(row.pivot)
			if not pivot then continue end
			local entrance = arrV3(row.ent) or pivot.Position
			local id = math.floor(tonumber(row.id) or 0)
			if id <= 0 then _depotId += 1; id = _depotId end
			_depotId = math.max(_depotId, id)
			spawnDepot(id, row.key, pivot, entrance)
		end
	end

	if typeof(data.stops) == "table" then
		for _, row in data.stops do
			if typeof(row) ~= "table" or typeof(row.key) ~= "string" or not TransitTypes.getStop(row.key) then continue end
			local pos = arrV3(row.pos); local road = arrV3(row.road)
			if not pos or not road then continue end
			local facing = Quant.unpackPivot(row.facing) or CFrame.new(pos)
			local segmentId = math.floor(tonumber(row.seg) or 0)
			local edgeId = if typeof(row.edge) == "string" then row.edge else nil
			local stopSpec = TransitTypes.getStop(row.key) :: TransitTypes.StopSpec
			local mode = stopSpec.mode or "bus"
			local g = graphFor(mode)
			if g then
				local edge = if edgeId then g:GetEdge(edgeId) else nil
				if edge then
					local _, snapped = nearestPointOnEdge(edge, pos)
					road = snapped
				else
					local pickedEdge, _, snapped = nearestBoardingEdge(g, if segmentId > 0 then segmentId else nil, pos, nil)
					if pickedEdge and snapped then
						edgeId = pickedEdge.id
						road = snapped
					end
				end
			end
			local model = buildStopModel(stopSpec)
			model:PivotTo(facing)
			local id = math.floor(tonumber(row.id) or 0)
			if id <= 0 then _stopId += 1; id = _stopId end
			_stopId = math.max(_stopId, id)
			model:SetAttribute("StopId", id)
			model:SetAttribute("RoadSegmentId", segmentId)
			model:SetAttribute("TransitKind", "Stop")
			model:SetAttribute("StopName", tostring(row.name or ""))
			CollectionService:AddTag(model, if mode == "train" then "TrainStation" else "BusStop")
			model.Parent = _folder
			_stops[id] = {
				id = id, key = row.key, pos = pos, roadPos = road, facing = facing,
				segmentId = segmentId, edgeId = edgeId, name = tostring(row.name or ""), model = model, mode = mode,
				boardings = 0, displayBoardings = 0,
			}
		end
	end

	if typeof(data.routes) == "table" then
		for _, row in data.routes do
			if typeof(row) ~= "table" then continue end
			local stops = {}
			if typeof(row.stops) == "table" then
				for _, sid in row.stops do local n = math.floor(tonumber(sid) or 0); if _stops[n] then table.insert(stops, n) end end
			end
			if #stops == 0 then continue end
			local wps = {}
			if typeof(row.wps) == "table" then
				for legKey, arr in row.wps do
					local leg = math.floor(tonumber(legKey) or 0)
					if leg > 0 and typeof(arr) == "table" then
						local list = {}
						for _, w in arr do local v = arrV3(w); if v then table.insert(list, v) end end
						if #list > 0 then wps[leg] = list end
					end
				end
			end
			local id = math.floor(tonumber(row.id) or 0)
			if id <= 0 then _routeId += 1; id = _routeId end
			_routeId = math.max(_routeId, id)
			local ci = math.floor(tonumber(row.colorIndex) or id)
			local mode = if typeof(row.mode) == "string" then row.mode else ((_stops[stops[1]] and _stops[stops[1]].mode) or "bus")
			local route: Route = {
				id = id, name = tostring(row.name or ((if mode == "train" then "Train Line " else "Bus Line ") .. id)), mode = mode,
				color = TransitTypes.routeColor(ci), colorIndex = ci,
				enabled = row.enabled ~= false,
				fare = math.clamp(math.floor(tonumber(row.fare) or TransitTypes.DEFAULT_FARE), TransitTypes.MIN_FARE, TransitTypes.MAX_FARE),
				busCount = math.max(0, math.floor(tonumber(row.busCount) or 0)),
				closed = row.closed ~= false,
				stops = stops, waypoints = wps, pending = {},
				path = {}, legEdges = {}, legPaths = {}, lengthStuds = 0,
				activeBuses = 0, passengers = 0, displayPassengers = 0, usage = 0,
				revenue = 0, displayRevenue = 0,
			}
			_routes[id] = route
			TransitService._recomputeRoute(route)
		end
		TransitService._clampBusAssignments()
	end
	_dirty = true
end

-- == Remote command dispatch ===================================================
local function handleCommand(player: Player, action: any, payload: any)
	if not canEdit(player) then return end
	if typeof(action) ~= "string" then return end
	local now = os.clock()
	if now - (_lastCmdAt[player] or 0) < CMD_COOLDOWN then return end
	_lastCmdAt[player] = now
	local p = if typeof(payload) == "table" then payload else {}

	if action == "placeStop" then
		local key = if typeof(p.key) == "string" and TransitTypes.getStop(p.key) then p.key else "BusStop"
		local ok, res = TransitService.placeStop(key, p, player)
		if not ok and typeof(res) == "string" then
			_net.Notify:FireClient(player, { text = "Can't place: " .. res, kind = "danger", duration = 3 })
		end
	elseif action == "removeStop" then
		if typeof(p.id) == "number" then TransitService.removeStop(p.id) end
	elseif action == "createRoute" then
		if typeof(p.stopId) == "number" then TransitService.createRoute(p.stopId) end
	elseif action == "addStop" then
		if typeof(p.routeId) == "number" and typeof(p.stopId) == "number" then TransitService.addStop(p.routeId, p.stopId) end
	elseif action == "removeRouteStop" then
		if typeof(p.routeId) == "number" and typeof(p.stopId) == "number" then TransitService.removeRouteStop(p.routeId, p.stopId) end
	elseif action == "addWaypoint" then
		if typeof(p.routeId) == "number" then TransitService.addWaypoint(p.routeId, p.pos) end
	elseif action == "undo" then
		if typeof(p.routeId) == "number" then TransitService.undoRoute(p.routeId) end
	elseif action == "delete" then
		if typeof(p.routeId) == "number" then TransitService.deleteRoute(p.routeId) end
	elseif action == "setBuses" then
		if typeof(p.routeId) == "number" and typeof(p.n) == "number" then TransitService.setRouteBuses(p.routeId, p.n) end
	elseif action == "setFare" then
		if typeof(p.routeId) == "number" and typeof(p.fare) == "number" then TransitService.setRouteFare(p.routeId, p.fare) end
	elseif action == "setColor" then
		if typeof(p.routeId) == "number" and typeof(p.index) == "number" then TransitService.setRouteColor(p.routeId, p.index) end
	elseif action == "toggle" then
		if typeof(p.routeId) == "number" then TransitService.toggleRoute(p.routeId, p.enabled == true) end
	elseif action == "rename" then
		if typeof(p.routeId) == "number" and typeof(p.name) == "string" then TransitService.renameRoute(p.routeId, p.name) end
	end
	TransitService.broadcast()
end

-- == Lifecycle =================================================================
function TransitService.Init(net: any, roadService: any, buildingService: any, economyService: any)
	assert(net and roadService and buildingService, "[TransitService] missing dependencies")
	_net = net
	_roadService = roadService
	_buildingService = buildingService
	_economyService = economyService
	_folder = ensureFolder()
end

function TransitService.Bind()
	_net.RequestPlaceService.OnServerEvent:Connect(function(player: Player, kind: any, key: any, pivot: any)
		if kind ~= "Transit" then return end
		if not canEdit(player) then return end
		local now = os.clock()
		if now - (_lastPlaceAt[player] or 0) < PLACE_COOLDOWN then return end
		_lastPlaceAt[player] = now
		if typeof(key) ~= "string" or typeof(pivot) ~= "CFrame" then return end
		local ok, reason = TransitService.placeDepot(key, pivot, player)
		if not ok and typeof(reason) == "string" then
			_net.Notify:FireClient(player, { text = "Can't place: " .. reason, kind = "danger", duration = 3 })
		end
		TransitService.broadcast()
	end)
	_net.RequestRemoveService.OnServerEvent:Connect(function(player: Player, kind: any, id: any)
		if kind ~= "Transit" then return end
		if not canEdit(player) then return end
		if typeof(id) ~= "number" then return end
		TransitService.removeDepot(id)
		TransitService.broadcast()
	end)
	_net.RequestTransitCommand.OnServerEvent:Connect(handleCommand)
	Players.PlayerRemoving:Connect(function(pl)
		_lastCmdAt[pl] = nil; _lastPlaceAt[pl] = nil
	end)
	Players.PlayerAdded:Connect(function(pl)
		task.delay(2, function()
			if pl.Parent and _net and _started then _net.SyncTransit:FireClient(pl, snapshot()) end
		end)
	end)
	-- Road edits can arrive in bursts (especially undo/redo and intersection splits).
	-- Re-route after the navigation graph's deferred rebuild, and spread larger route sets
	-- across frames so transit never blocks the road-edit frame.
	local function queueRouteRebuild()
		_routeRebuildVersion += 1
		if _routeRebuildQueued then return end
		_routeRebuildQueued = true
		task.delay(ROUTE_REBUILD_DEBOUNCE, function()
			local version = _routeRebuildVersion
			local processed = 0
			for _, route in _routes do
				pcall(TransitService._recomputeRoute, route)
				processed += 1
				if processed % 4 == 0 then
					task.wait()
				end
			end
			_dirty = true
			_routeRebuildQueued = false
			if version ~= _routeRebuildVersion then
				queueRouteRebuild()
			end
		end)
	end
	if _roadService.onSegmentRemoving then
		_roadService.onSegmentRemoving(TransitService.removeStopsForSegment)
	end
	if _roadService.onTopologyChanged then
		_roadService.onTopologyChanged(queueRouteRebuild)
	end
end

function TransitService.Start()
	_started = true
	local accum = 0
	local riderAccum = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accum += dt
		riderAccum += dt
		if riderAccum >= 1 then
			stepRiders(riderAccum * math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3))
			riderAccum = 0
		end
		-- Interval broadcasts only matter while routes exist (live line stats);
		-- otherwise only broadcast on _dirty so an empty/no-transit city costs nothing.
		if _dirty or (accum >= SYNC_INTERVAL and next(_routes) ~= nil) then
			accum = 0
			pcall(TransitService.broadcast)
		end
	end)
end

return TransitService
