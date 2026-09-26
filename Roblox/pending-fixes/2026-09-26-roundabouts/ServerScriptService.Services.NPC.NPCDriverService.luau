--!strict
-- NPCDriverService
-- Spawns NPC cars and drives them along the nav graph.
-- Dead ends: NPCs stop, wait briefly, then U-turn back.
-- Normal edges: NPCs follow outgoing connections and roam indefinitely.
-- Replication, smoothing, proximity culling, and edge geometry live in the
-- shared PathFollower module.

local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local NetMiddleware     = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local RoadConstants     = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog   = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadRules         = require(ReplicatedStorage.Road.RoadRules)
local BezierUtil        = require(ReplicatedStorage.Road.BezierUtil)
local IntersectionRenderer = require(ReplicatedStorage.Road.IntersectionRenderer)
local PathFollower      = require(ServerScriptService.Services.Util.PathFollower)
local TrafficSignalService = require(ServerScriptService.Services.Traffic.TrafficSignalService)
local TrafficConfig     = require(ServerScriptService.Services.Traffic.TrafficConfig)
local VehicleTypes      = require(ReplicatedStorage.Road.VehicleTypes)
local VehicleFactory    = require(ServerScriptService.Services.NPC.VehicleFactory)
local DriverProfile     = require(ReplicatedStorage.Road.DriverProfile)

local NPCDriverService = {}

-- == Config ====================================================================
local TAG            = "NPCDriver"
-- Ambient traffic keeps the world moving while the household sim ramps up.
-- Set Workspace.AmbientTrafficCount to tune it, or set RandomTrafficEnabled=false
-- to disable the background cruisers entirely.
-- Half-size world (RoadConstants.WORLD_SCALE): speeds, accels and stud distances below
-- scale together, so traffic covers the same city blocks per second as at full size.
local WS = RoadConstants.WORLD_SCALE
-- The turn that cuts the oncoming carriageway, and so has to accept a gap unless it holds
-- a protected phase. "left" on a right-hand-drive map, "right" on a left-hand one.
-- Yielding is written against this rather than a literal so the rules hold whichever side
-- the player picked. A FUNCTION, not a cached string: the side can change at runtime, and
-- this service is long-lived, so a module-level copy would go stale the moment it did.
local function crossingTurn(): string
	return RoadRules.getCrossingTurn()
end
local NPC_COUNT        = 12
local MAX_AMBIENT_TRAFFIC = 32
local DEAD_END_WAIT    = 0
local MAX_STEPS        = 8
local MAX_SIM_DT       = 0.1
local DRIVER_TICK      = 1 / 20 -- nearby server AI rate
-- Simulation level of detail. A car further than FAR_LOD_DIST from every player's camera
-- (and its ground look-at point) still drives the full traffic AI -- queues, signals, lane
-- changes, jams all real -- but thinks FAR_TICK times less often; nobody is close enough to
-- see the steps, and the client draws only a sample out there (PathFollower / NPCDriverView).
local FAR_LOD_DIST     = 1000   -- studs (500 m)
local FAR_LOD_DIST_SQ  = FAR_LOD_DIST * FAR_LOD_DIST
local FAR_TICK         = 1 / 4  -- s between far-car updates
local FAR_MAX_DT       = 0.3    -- longest step a far car integrates in one go
local LOD_RECHECK      = 1      -- s between a car's near/far re-evaluations
local EXIT_CLEARANCE    = 12 * WS  -- reduced from 30; was causing exit-lane deadlocks
local STOP_DECEL_DISTANCE = 5 * WS
local STOP_LINE_CAR_BUFFER = 3 * WS
local FOLLOW_MIN_GAP    = 16 * WS   -- centre-to-centre FLOOR (~one car length); followGap sizes the rest
local FOLLOW_BUMPER     = 2 * WS    -- clear air left between two stopped vehicles' bumpers
local FOLLOW_LOOKAHEAD  = 42 * WS
local QUEUE_TIE_EPSILON = 0.05
local UNSTUCK_BACKUP_RATE = 18 * WS
local ACCEL_RATE        = 28 * WS
local BRAKE_RATE        = 60 * WS
-- Traffic is never cleared by a timer. A queue, a full exit, a red or a gridlocked box holds
-- every car in it until the road clears -- or until the player rebuilds the road. Only a
-- car the traffic rules cannot explain (see waitingInTraffic) counts as bugged, and only a
-- bugged car is pushed through or removed.
local IMPATIENCE_TIME   = 6    -- s a car waits for a gap at a junction before it noses out (never into a full exit or across a car in the box)
local AT_LINE_DIST      = 2    -- studs short of its stop line a car counts as waiting at it
-- Turn-taking at junctions WITHOUT signals: how long a car waits at its line before it may
-- take its turn (and approaching cross traffic lets it in). Roads of equal priority take turns
-- like an all-way stop; a side road meeting a main road waits longer, but always gets in.
local TURN_WAIT_EQUAL   = 2
local TURN_WAIT_MINOR   = 5
local SIGNAL_FAULT_TIME = 180  -- s of one unbroken red before the signal counts as broken (no working cycle is this long)
local CONNECTOR_STANDOFF_ESCAPE = 4  -- s two cars blocking EACH OTHER wait before one of them creeps through
local RESCUE_CLEAR_DIST = 30 * WS    -- studs a rescued (bugged) car must cover before it obeys traffic again
local TURN_SLOW_ZONE    = 20 * WS   -- studs before the stop line over which cars ease down to turn entry speed
local CONNECTOR_LAT_ACCEL = 14 * WS -- studs/s^2 comfortable lateral accel through a turn
local MIN_TURN_SPEED    = 6 * WS    -- studs/s floor so tight U-turns never crawl to a stop
local TURN_ENTRY_SPEED: { [string]: number } = table.freeze({ left = 12 * WS, right = 10 * WS, uturn = 7 * WS })
local STALL_RESCUE_TIME  = 60   -- s of zero movement before the watchdog re-seats a car (legit waits are bounded far below)
local STALL_MOVE_EPSILON = 0.25 * WS -- studs of movement that count as progress for the watchdog
local ROUNDABOUT_YIELD_DIST = RoadConstants.ROUNDABOUT_YIELD_DIST or 30 * WS -- studs a circulating car blocks an entry
local ADMIN_TEST_CAR_MAX_COUNT = 80
local ADMIN_TEST_CAR_DEFAULT_COUNT = 12
local ADMIN_TEST_CAR_DEFAULT_RADIUS = 260 * WS
local TEST_SPAWN_FRACTIONS = table.freeze({ 0.18, 0.42, 0.66, 0.86 })
local CONGESTION_UPDATE_INTERVAL = RoadConstants.NAV_CONGESTION_UPDATE_INTERVAL or 0.75
local CONGESTION_SMOOTHING = RoadConstants.NAV_CONGESTION_SMOOTHING or 0.35
local CONGESTION_JAM_SPEED_RATIO = RoadConstants.NAV_CONGESTION_JAM_SPEED_RATIO or 0.35
local CONGESTION_MIN_QUEUE = RoadConstants.NAV_CONGESTION_MIN_QUEUE or 3
local TRAFFIC_REROUTE_JAM_TIME = RoadConstants.NAV_REROUTE_JAM_TIME or 7
local TRAFFIC_REROUTE_COOLDOWN = RoadConstants.NAV_REROUTE_COOLDOWN or 30
local TRAFFIC_REROUTE_MIN_IMPROVEMENT = RoadConstants.NAV_REROUTE_MIN_IMPROVEMENT or 0.3
local TRAFFIC_REROUTE_MAX_PER_TRIP = RoadConstants.NAV_REROUTE_MAX_PER_TRIP or 2
local TRAFFIC_REROUTE_REVERSAL_LOCK = RoadConstants.NAV_REROUTE_REVERSAL_LOCK or 60
local LANE_MOVE_MIN_SAVING = 3 -- s a same-roads plan on another lane must save, beyond the move itself
local ROAMER_LANE_KEEP = 2.5   -- extra cars an ambient roamer accepts in its own lane before moving over at a junction

-- Camera-pos rate limiting is handled entirely by NetMiddleware.RegisterServerRateLimit.
local CAM_REPORT_MIN_DT = 1 / 15  -- 15 Hz max, passed to NetMiddleware

-- == State =====================================================================
local _roadService: any = nil
local _heartbeat: RBXScriptConnection? = nil
local _spawnedOnce = false
local _bound = false

local _nodeMetaById: { [number]: any } = {}
local _edgeDriverIndex: { [string]: { any } } = {}
local _connectorByNextEdgeIndex: { [string]: { any } } = {}
-- Lane-change occupants by lane: cars mid-move (under BOTH lanes) and cars waiting to merge
-- (under the lane they want). Rebuilt with the other indexes every tick.
local _laneChangeIndex: { [string]: { any } } = {}
-- Cars crossing a junction (or a join), by the lane they left: see getNearestQueueLeader.
local _connectorByFromEdgeIndex: { [string]: { any } } = {}
local _edgeCongestion: { [string]: number } = {}
local _lastCongestionUpdate = 0

-- == Types =====================================================================
-- A mid-block lane change in progress: its ribbon, both lanes, and where on them it starts/lands.
type LaneChange = { pts: { Vector3 }, from: string, to: string, d0: number, d1: number }

type DriverState = PathFollower.FollowerState & {
	edgeId:        string,
	edgeDist:      number,
	graphVersion: number,
	connector:    { Vector3 }?,
	connCum:      { number }?,
	connDist:     number,
	nextEdgeId:   string?,
	nextEdgeDist: number,
	pendingNextEdgeId: string?,
	atDeadEnd:    boolean,
	deadEndTimer: number,
	speed:        number,
	currentSpeed: number?, -- Keeps track of smoothed speed for fluid acceleration/deceleration
	vehicleClass: VehicleTypes.VehicleClass,
	blockedTime:  number?, -- seconds spent yielding at the current junction (drives impatience)
	waitSince:    number?, -- _simClock when this wait at the line began (orders turns at the junction)
	stuckTime:    number?, -- seconds stopped at a junction for ANY reason (jam readouts)
	redTime:      number?, -- seconds of the current unbroken red (drives SIGNAL_FAULT_TIME)
	connSpeedCap: number?, -- max speed through the current connector (set from its tightest bend)
	connBlockedTime: number?, -- seconds wedged in a standoff (drives the push-through escape)
	blockedBy:    Model?,  -- the car right in front with no room left to it (nil when clear)
	rescueFrom:   Vector3?, -- set by the stall watchdog: a bugged car pushes through until it has left here
	lastProgressPos: Vector3?, -- watchdog: where the car last made real progress
	noProgressTime: number?,   -- watchdog: seconds without real movement
	rescueCount: number?,      -- watchdog: consecutive rescues without progress between them
	stopReason: string?,       -- debug: WHY the car is at its current speed (in-memory; read by GetSpeedDebug, never replicated)
	debugTagAdded: boolean?,   -- directed trips temporarily opt into NPCDriver client/debug tracking
	-- Directed-trip mode (nil on ambient roamers): follow a fixed edge route to a
	-- destination, then stop and hand back instead of roaming forever.
	route:        { string }?,  -- ordered lane-edge ids (FindPath's 2nd return)
	routeIndex:   number?,      -- index in `route` of the current edgeId
	goalPos:      Vector3?,     -- trip destination, kept so a directed car can re-route if its road is replaced
	finalDist:    number?,      -- distance along the LAST route edge to stop at (the lot entry)
	onArrive:     (() -> ())?,  -- fired once on reaching the destination
	onAbort:      (() -> ())?,  -- fired if the route can't be followed (road changed / wedged)
	arrived:      boolean?,     -- latch so onArrive fires exactly once
	halfLength:   number?,      -- vehicle half-length (centre->nose) for stop-line placement
	trafficJamTime: number?,    -- sustained queue time before considering a new route
	nextTrafficRerouteAt: number?, -- os.clock cooldown; prevents route oscillation
	trafficReroutes: number?,   -- debug counter
	lastTrafficRerouteAt: number?,
	lastTrafficAbandonedNextEdgeId: string?, -- blocks an immediate flip back to the old branch
	-- This driver's own mind (DriverProfile): how it prices roads, how fast it likes to
	-- go, how long it tolerates a queue. Stable for the vehicle's whole life, so a car
	-- does not change personality mid-trip. Carries a per-trip booking token.
	profile:      DriverProfile.Profile?,
	bookingToken: number?,      -- identifies this trip's route reservation on the graph
	laneChangeWait: number?,    -- seconds held at the end of a lane-change window with no gap
	laneChangeMissed: string?,  -- lane edge whose window this car overran at speed and re-planned from
	lodFar: boolean?,           -- far from every player: thinks at FAR_TICK (see FAR_LOD_DIST)
	lodAccum: number?,          -- sim time banked since this car last thought
	lodCheckAt: number?,        -- os.clock of the next near/far re-evaluation
	blockerDot: number?,        -- heading agreement with whatever blocks us (1 = queued behind it)
	laneChange: LaneChange?,    -- the move in progress; only valid while `connector` is its ribbon
	mergeInto: string?,         -- lane this car has waited MERGE_COURTESY_WAIT+ to move into (zipper)
	mergeHoldAt: number?,       -- swap tie-break winner: hold point pulled up past the other car
}

-- Route bookings are keyed by an integer that must be unique across LIVE trips, so a
-- released token is never reused by an overlapping one.
local _nextBookingToken = 0

-- MEMORY LEAK FIX: We make _drivers a WEAK-KEYED table so that when an NPC model is 
-- destroyed, its driver state is auto-garbage-collected, preventing a slow memory leak.
local _drivers: { [Model]: DriverState } = setmetatable({}, { __mode = "k" }) :: any
-- Simulated seconds since the service started (advances once per driver tick, times game speed).
local _simClock = 0
local _nextDebugId = 0

local function ensureDebugId(model: Model): string
	local existing = model:GetAttribute("NPCDebugId")
	if typeof(existing) == "string" and existing ~= "" then
		return existing
	end
	_nextDebugId += 1
	local id = string.format("%s#%d", model.Name, _nextDebugId)
	model:SetAttribute("NPCDebugId", id)
	return id
end

-- Who goes first when two cars are exactly level. Model names are not unique (every through
-- car is an "IntercityCar"), so a name tie-break let neither go; the debug id is unique.
local function goesFirst(a: DriverState, b: DriverState): boolean
	return ensureDebugId(a.model) < ensureDebugId(b.model)
end

local function clearDirectedDebugTag(state: DriverState)
	local model = state.model
	if state.debugTagAdded and model and model.Parent and CollectionService:HasTag(model, TAG) then
		CollectionService:RemoveTag(model, TAG)
	end
	state.debugTagAdded = nil
	if model and model.Parent then
		model:SetAttribute("NPCStatus", nil)
		model:SetAttribute("NPCDestX", nil)
		model:SetAttribute("NPCDestZ", nil)
	end
end

-- Version of the nav graph that was current when we last flushed the cum cache.
-- Used to ensure flushCache() fires exactly once per rebuild, not once per NPC.
local _lastFlushedVersion = -1

-- == Helpers ===================================================================
local function nav(): any?
	return _roadService and _roadService.getNavigationGraph()
end

-- Tags the car model with its current routing info so clients can read it.
-- Avoids redundant attribute updates to save network traffic.
local function tagCarInfo(state: DriverState, status: string, targetEdgeId: string?)
	local model = state.model
	if not model or not model.Parent then return end
	ensureDebugId(model)
	-- These attributes replicate to every client regardless of distance, so skip
	-- them for cars no player can see -- cuts bandwidth as the city grows.
	if not PathFollower.isInRange(model) then return end

	if model:GetAttribute("NPCStatus") ~= status then
		model:SetAttribute("NPCStatus", status)
	end

	if targetEdgeId then
		local g = nav()
		if g then
			local edge = g:GetEdge(targetEdgeId)
			if edge and edge.points and #edge.points > 0 then
				local ep = edge.points[#edge.points]
				local destX = math.round(ep.X)
				local destZ = math.round(ep.Z)
				if model:GetAttribute("NPCDestX") ~= destX then
					model:SetAttribute("NPCDestX", destX)
				end
				if model:GetAttribute("NPCDestZ") ~= destZ then
					model:SetAttribute("NPCDestZ", destZ)
				end
			end
		end
	else
		if model:GetAttribute("NPCDestX") ~= nil then
			model:SetAttribute("NPCDestX", nil)
		end
		if model:GetAttribute("NPCDestZ") ~= nil then
			model:SetAttribute("NPCDestZ", nil)
		end
	end
end

local function getStatePosition(state: DriverState): Vector3
	return if state.smoothCFrame then state.smoothCFrame.Position else state.model:GetPivot().Position
end

-- A car mid lane change straddles both lanes: still in the way on the one it is leaving,
-- already in the way on the one it is joining. Its distance along either lane is how far
-- through the move it is (the lanes of one road share a distance scale).
local function laneChangeOf(state: DriverState): LaneChange?
	local lc = state.laneChange
	if lc and state.connector == lc.pts then return lc end
	return nil
end

-- Where `state` stands along `laneId`: its own distance on its lane; mid lane change, how
-- far through the move it is (it straddles both lanes); on a connector INTO `laneId` (a
-- junction turn or a join between road pieces) the landing distance less what is left of the
-- connector -- negative while still short of the lane, so a queue carries straight across.
local function lanePos(state: DriverState, laneId: string): number
	if not state.connector then return state.edgeDist end
	local cum = state.connCum
	local total = if cum then cum[#cum] else 0
	local lc = laneChangeOf(state)
	if lc then
		local f = if total > 0 then math.clamp(state.connDist / total, 0, 1) else 1
		return lc.d0 + (lc.d1 - lc.d0) * f
	end
	if state.nextEdgeId == laneId then
		return state.nextEdgeDist - math.max(0, total - state.connDist)
	end
	return state.edgeDist
end

-- Centre-to-centre spacing this car has to keep behind `lead`. FOLLOW_MIN_GAP on its own is
-- one CAR length, so a queue holding anything longer -- a box truck, an artic -- packed its
-- followers into the trailer. Both half-lengths plus a bumper is the real minimum.
local function followGap(state: DriverState, lead: DriverState?): number
	if not lead then return FOLLOW_MIN_GAP end
	return math.max(FOLLOW_MIN_GAP, (state.halfLength or 0) + (lead.halfLength or 0) + FOLLOW_BUMPER)
end

local function clearDriverIndexes()
	table.clear(_edgeDriverIndex)
	table.clear(_connectorByNextEdgeIndex)
	table.clear(_laneChangeIndex)
	table.clear(_connectorByFromEdgeIndex)
end

local function addToIndex(index: { [string]: { any } }, key: string, state: DriverState)
	local bucket = index[key]
	if not bucket then
		bucket = {}
		index[key] = bucket
	end
	table.insert(bucket, state)
end

local function rebuildDriverIndexes()
	clearDriverIndexes()
	for _, other in pairs(_drivers) do
		if not other.model.Parent then continue end
		if other.connector and other.nextEdgeId then
			addToIndex(_connectorByNextEdgeIndex, other.nextEdgeId, other)
			local lc = laneChangeOf(other)
			if lc then
				addToIndex(_laneChangeIndex, lc.from, other)
				addToIndex(_laneChangeIndex, lc.to, other)
			else
				addToIndex(_connectorByFromEdgeIndex, other.edgeId, other)
			end
		else
			addToIndex(_edgeDriverIndex, other.edgeId, other)
			if other.mergeInto then
				addToIndex(_laneChangeIndex, other.mergeInto, other)
			end
		end
	end
end

local function edgeHasOutgoing(edge: any, targetEdgeId: string): boolean
	for _, outId in ipairs(edge.out) do
		if outId == targetEdgeId then
			return true
		end
	end
	return false
end

-- The lane edge carries its speed limit (studs/s), baked at graph-build time from
-- the segment's road type + any per-segment override. Fallback covers a stale
-- edge from before the field existed.
local function edgeSpeed(edge: any): number
	return edge.speedLimit or 56
end

-- Cruise speed for THIS driver on this lane. Personas sit either side of the posted
-- limit, so traffic is never a column of identically-paced cars: a slow driver ahead
-- is a real reason for the one behind to bunch up, and that bunching is what feeds
-- the congestion signal the router reacts to.
local function driverSpeed(edge: any, state: DriverState): number
	local limit = edgeSpeed(edge)
	local profile = state.profile
	return if profile then limit * profile.speedFactor else limit
end

-- Publish a sparse, smoothed pressure map to the nav graph. This reuses the
-- per-edge driver census already built for car-following, so congestion tracking
-- adds no world scans and does not rebuild road geometry.
local function publishCongestionSnapshot(g: any)
	local now = os.clock()
	if now - _lastCongestionUpdate < CONGESTION_UPDATE_INTERVAL then
		return
	end
	_lastCongestionUpdate = now

	local target: { [string]: number } = {}
	for edgeId, bucket in _edgeDriverIndex do
		local edge = g:GetEdge(edgeId)
		if not edge then continue end

		local entering = #(_connectorByNextEdgeIndex[edgeId] or {})
		local vehicleCount = #bucket + entering * 0.5
		if vehicleCount < CONGESTION_MIN_QUEUE then continue end

		local slowCount = 0
		local slowLimit = edgeSpeed(edge) * CONGESTION_JAM_SPEED_RATIO
		for _, state in bucket do
			if (state.currentSpeed or state.speed or 0) <= slowLimit then
				slowCount += 1
			end
		end

		local capacity = math.max(CONGESTION_MIN_QUEUE, edge.length / FOLLOW_MIN_GAP)
		local densityPressure = math.clamp((vehicleCount - 1) / capacity, 0, 1)
		local queuePressure = math.clamp((slowCount - 1) / capacity, 0, 1)
		target[edgeId] = math.clamp(densityPressure * 0.55 + queuePressure * 0.85, 0, 1)
	end

	local snapshot: { [string]: number } = {}
	for edgeId, pressure in target do
		local previous = _edgeCongestion[edgeId] or 0
		local blended = previous + (pressure - previous) * CONGESTION_SMOOTHING
		if blended > 0.01 then snapshot[edgeId] = blended end
	end
	for edgeId, previous in _edgeCongestion do
		if target[edgeId] == nil and g:GetEdge(edgeId) then
			local faded = previous * (1 - CONGESTION_SMOOTHING)
			if faded > 0.01 then snapshot[edgeId] = faded end
		end
	end

	_edgeCongestion = snapshot
	g:SetCongestionSnapshot(snapshot)

	-- Same cadence, same reason: bookings whose owner vanished without releasing (a
	-- car destroyed mid-trip) must not keep a road looking busy forever.
	g:PruneBookings()
end

-- Whether this vehicle's class is permitted on the given lane edge. A nil set
-- means no restriction.
local function edgeAllows(edge: any, class: string): boolean
	local allowed = edge.allowedVehicles
	return allowed == nil or allowed[class] == true
end

local function getPendingNextEdgeId(g: any, state: DriverState, edge: any): string?
	-- Directed trip: take the NEXT edge on the route, not a random exit. On the final
	-- route edge there's no onward edge (return nil), which the update loop turns into
	-- an arrival. If the route's next edge isn't a valid exit here (road changed under
	-- us), fall through to the roamer pick so the car keeps moving; the graph-version
	-- guard aborts the trip cleanly next frame.
	if state.route then
		local nextRouteId = state.route[(state.routeIndex or 1) + 1]
		if not nextRouteId then
			state.pendingNextEdgeId = nil
			return nil
		end
		if edgeHasOutgoing(edge, nextRouteId) and g:GetEdge(nextRouteId) then
			state.pendingNextEdgeId = nextRouteId
			return nextRouteId
		end
		-- A mid-block lane change comes first; no junction exit is pending on this lane.
		if g:GetLaneChangeWindow(edge.id, nextRouteId) then
			state.pendingNextEdgeId = nil
			return nil
		end
	end
	local pending = state.pendingNextEdgeId
	if pending and edgeHasOutgoing(edge, pending) and g:GetEdge(pending) then
		return pending
	end
	-- Clear stale pending only if the edge truly has no outgoing that matches;
	-- always re-use a valid pending choice so the car waits for the SAME exit it
	-- originally picked rather than re-rolling every frame and deadlocking.
	state.pendingNextEdgeId = nil
	if #edge.out == 0 then
		return nil
	end
	-- Pick a random exit this vehicle's class is allowed on and LOCK it in for the
	-- lifetime of this stop. Falls back to any exit if (unexpectedly) none are
	-- allowed, so a mis-tagged vehicle can never deadlock at a junction.
	local allowed: { string } = {}
	for _, outId in ipairs(edge.out) do
		local outEdge = g:GetEdge(outId)
		if outEdge and edgeAllows(outEdge, state.vehicleClass) then
			table.insert(allowed, outId)
		end
	end
	local pool = if #allowed > 0 then allowed else edge.out
	-- Pick a ROAD, then a lane on it. A uniform pick over LANE EDGES gave a multi-lane
	-- onward road one vote per lane: at a ROUNDABOUT node the outs are {ring lane 1, ring
	-- lane 2, the exit}, so the ring outvoted the exit 2:1 at every arm and a roamer lapped
	-- it ~1.1 times on a 3-arm ring (worst measured: 7 laps) instead of ~0.7 -- and it
	-- re-rolled between the ring's OWN two lanes on the way round, which is the weaving.
	local lanesBySegment: { [number]: { string } } = {}
	local segmentIds: { number } = {}
	for _, outId in ipairs(pool) do
		local outEdge = g:GetEdge(outId)
		local segmentId = if outEdge then outEdge.segmentId else 0
		local lanes = lanesBySegment[segmentId]
		if not lanes then
			lanes = {}
			lanesBySegment[segmentId] = lanes
			table.insert(segmentIds, segmentId)
		end
		table.insert(lanes, outId)
	end
	local lanes = lanesBySegment[segmentIds[math.random(1, #segmentIds)]]
	-- Of the lanes this exit allows, take the emptiest, staying in lane unless another is
	-- clearly emptier: ambient cars spread over a wide road instead of stacking in one lane,
	-- but a one-car difference is not worth a swerve across the box at every road join.
	local nextId, fewest = lanes[1], math.huge
	for _, id in lanes do
		local outEdge = g:GetEdge(id)
		local load = #(_edgeDriverIndex[id] or {})
			+ (if outEdge and outEdge.laneOrdinal == edge.laneOrdinal then 0 else ROAMER_LANE_KEEP)
		if load < fewest then
			fewest = load
			nextId = id
		end
	end
	state.pendingNextEdgeId = nextId
	return nextId
end

local flatUnit: (Vector3?) -> Vector3

local function clearGraphCaches()
	table.clear(_nodeMetaById)
end

local function getNodeMeta(g: any, nodeId: number): any
	local cached = _nodeMetaById[nodeId]
	if cached then return cached end

	local network = _roadService and _roadService.getNetwork and _roadService.getNetwork()
	local node = network and network:getNodes()[nodeId]
	local armCount = if node and node.segments then #node.segments else 0
	local incomingEdges = g._edgesByToNode[nodeId] or {}
	local outgoingEdges = g._edgesByFromNode[nodeId] or {}

	local isRoundabout = network ~= nil and network.isRoundaboutNode ~= nil and network:isRoundaboutNode(nodeId)
	local meta = {
		isIntersection = armCount >= 3,
		isRoundabout = isRoundabout,
		stopLineGap = if armCount >= 3 then 20.0 else 1.5,
		stopLineGapBySegment = {},
		armPriority = {},
		uTurnByLane = {},
		uTurnFallback = nil,
	}

	if node and armCount >= 3 then
		local renderArms: { IntersectionRenderer.Arm } = {}
		local renderSegIds: { number } = {}
		for _, sid in node.segments do
			local seg = network and network:getSegment(sid)
			if not seg or seg.isArc then continue end

			local raw: Vector3
			if seg.startNode == nodeId then
				raw = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, 0)
			else
				raw = -BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, 1)
			end
			if raw.Magnitude < 1e-6 then
				raw = if seg.startNode == nodeId then (seg.p3 - seg.p0) else (seg.p0 - seg.p3)
			end
			if raw.Magnitude > 1e-6 then
				local corner, offset = IntersectionRenderer.armOverrides(seg, nodeId)
				table.insert(renderArms, {
					dir = raw.Unit,
					width = RoadTypeCatalog.getOrDefault(seg.roadType).width,
					corner = corner,
					offset = offset,
				})
				table.insert(renderSegIds, sid)
			end
		end

		local boundaryDistances = IntersectionRenderer.armBoundaryDistances(node.position, renderArms)
		for i, sid in renderSegIds do
			local boundary = boundaryDistances[i] or 0
			-- Match the renderer: steep approaches get an extended junction apron and the
			-- visual stop line moves out with it, so cars must hold at the same distance.
			if _roadService and _roadService.armJunctionBoundary then
				boundary = _roadService.armJunctionBoundary(nodeId, sid) or boundary
			end
			meta.stopLineGapBySegment[sid] = boundary
				+ RoadConstants.CROSSWALK_SETBACK
				+ RoadConstants.CROSSWALK_DEPTH
				+ RoadConstants.CROSSWALK_GAP_FROM_STOP
				+ RoadConstants.STOP_LINE_DEPTH * 0.5
				+ STOP_LINE_CAR_BUFFER
		end
	end

	-- Right-of-way priority per arm. Road class wins: arterial arms are "major"
	-- and local arms "minor", so a small road yields to the bigger road it meets.
	-- With no arterial present (e.g. an all-local T) fall back to opposing-through
	-- geometry: the straight-through pair is major, a joining stem is minor.
	local segIsArterial: { [number]: boolean } = {}
	local anyArterial = false
	if node then
		for _, sid in node.segments do
			local seg = network and network:getSegment(sid)
			if seg then
				local arterial = RoadRules.roadClass(RoadTypeCatalog.getOrDefault(seg.roadType)) == "arterial"
				segIsArterial[sid] = arterial
				anyArterial = anyArterial or arterial
			end
		end
	end

	for _, edge in ipairs(incomingEdges) do
		local priority: string
		if anyArterial then
			priority = if segIsArterial[edge.segmentId] then "major" else "minor"
		else
			local myDir = flatUnit(edge.toDir)
			local hasOpposite = false
			for _, other in ipairs(incomingEdges) do
				if other.segmentId ~= edge.segmentId and flatUnit(other.toDir):Dot(myDir) < -0.7 then
					hasOpposite = true
					break
				end
			end
			priority = if hasOpposite then "major" else "minor"
		end
		meta.armPriority[edge.id] = priority
	end

	-- An OUTSIDE CONNECTION (a degree-1 node at the map edge) is an open exit, not a
	-- dead-end -- it gets NO U-turn fallback, so a car never turns around there.
	local h = RoadConstants.MAP_HALF_EXTENT
	local p = node and node.position
	local isConnection = node ~= nil and p ~= nil and #node.segments <= 1
		and (math.abs(math.abs(p.X) - h) <= 30 or math.abs(math.abs(p.Z) - h) <= 30)
	meta.isConnection = isConnection
	if not isConnection then
		for _, edge in ipairs(outgoingEdges) do
			if not meta.uTurnFallback then
				meta.uTurnFallback = edge
			end
			if not meta.uTurnByLane[edge.laneOrdinal] then
				meta.uTurnByLane[edge.laneOrdinal] = edge
			end
		end
	end

	_nodeMetaById[nodeId] = meta
	return meta
end

local function isIntersectionNode(g: any, nodeId: number): boolean
	return getNodeMeta(g, nodeId).isIntersection == true
end

local function isSignalizedIntersection(nodeId: number): boolean
	return TrafficSignalService.HasSignal ~= nil and TrafficSignalService.HasSignal(nodeId) == true
end

-- Returns how far back from the target node a car center should stop.
-- The gap matches the painted stop line/crosswalk setback, plus a front-bumper buffer
-- so the car nose stays behind the stripe instead of its center landing on it.
local function getStopLineGap(g: any, nodeId: number, edge: any?): number
	local meta = getNodeMeta(g, nodeId)
	if edge and edge.segmentId then
		return meta.stopLineGapBySegment[edge.segmentId] or meta.stopLineGap
	end
	return meta.stopLineGap
end

function flatUnit(v: Vector3?): Vector3
	if not v then return Vector3.zAxis end
	local flatX = v.X
	local flatZ = v.Z
	local mag = math.sqrt(flatX * flatX + flatZ * flatZ)
	if mag < 1e-6 then return Vector3.zAxis end
	return Vector3.new(flatX / mag, 0, flatZ / mag)
end

local function isOpposite(dirA: Vector3?, dirB: Vector3?): boolean
	local a = flatUnit(dirA)
	local b = flatUnit(dirB)
	return a:Dot(b) < -0.7
end

-- Classifies an approach arm at an unsignaled 3-way T-junction.
-- If the arm aligns straight through with an opposing arm, it is a "major" road.
-- If the arm has no opposing straight counterpart (joining stem), it is a "minor" road.
local function getArmPriority(g: any, nodeId: number, edgeId: string): string
	return getNodeMeta(g, nodeId).armPriority[edgeId] or "minor"
end

local function getUTurnEdge(g: any, edge: any): any?
	local meta = getNodeMeta(g, edge.toNode)
	local sameLane = meta.uTurnByLane[edge.laneOrdinal]
	if sameLane and sameLane.id ~= edge.id then
		return sameLane
	end
	local fallback = meta.uTurnFallback
	if fallback and fallback.id ~= edge.id then
		return fallback
	end
	return nil
end

local function exitLaneHasRoom(g: any, state: DriverState, nextEdgeId: string): boolean
	local nextEdge = g:GetEdge(nextEdgeId)
	if not nextEdge then return false end

	-- Only block if another car is ACTIVELY crossing into this exit (connector phase).
	-- Checking _connectorByNextEdgeIndex is sufficient; we no longer block on cars
	-- that are merely sitting further along the exit edge, which was causing phantom
	-- "no room" deadlocks when traffic backed up on long roads.
	-- ponytail: block only on a car still occupying the exit MOUTH. Blocking on ANY car
	-- mid-turn onto this edge is what froze every other arm of a 4-way.
	local mouth = if nextEdge.points and #nextEdge.points > 0 then nextEdge.points[1] else nil
	for _, other in ipairs(_connectorByNextEdgeIndex[nextEdgeId] or {}) do
		if other ~= state and other.model.Parent then
			if not mouth or (getStatePosition(other) - mouth).Magnitude < EXIT_CLEARANCE then
				return false
			end
		end
	end

	-- Only block on cars very close to the entry of the exit edge (within EXIT_CLEARANCE
	-- of the start, i.e. edgeDist < EXIT_CLEARANCE).
	for _, other in ipairs(_edgeDriverIndex[nextEdgeId] or {}) do
		if other ~= state and other.model.Parent and other.edgeDist < EXIT_CLEARANCE then
			return false
		end
	end

	return true
end

-- A crossing car only holds us while it is still near enough to conflict with
-- our first stretch into the box. Beyond that, a fresh green goes immediately
-- -- mouth-to-mouth connectors are long, and waiting for the FULL crossing to
-- clear held green-light cars hostage. The proximity hard clamp still guards
-- genuine close calls inside the box.
local CROSS_CLEAR_RADIUS = 22

-- Cars yield rules at a GREEN signal: nearby cross traffic still clearing the
-- box is yielded to; a permissive crossing turn yields to oncoming through/nearside.
local function signalizedClear(g: any, state: DriverState, edge: any, nodeId: number, myDir: Vector3, myMove: string): boolean
	local myPos = getStatePosition(state)
	for _, other in pairs(_drivers) do
		if other == state or not other.model.Parent then continue end

		-- Other car is actively crossing this node right now (connector phase).
		if other.connector and other.nextEdgeId then
			local otherNextEdge = g:GetEdge(other.nextEdgeId)
			if otherNextEdge and otherNextEdge.fromNode == nodeId then
				if other.edgeId ~= edge.id then
					local otherEdge = g:GetEdge(other.edgeId)
					if otherEdge then
						if isOpposite(myDir, otherEdge.toDir) then
							-- Oncoming: only our crossing turn conflicts with their straight/nearside.
							local otherMove = otherEdge.outMovement and otherEdge.outMovement[other.nextEdgeId] or "straight"
							if myMove == crossingTurn() and otherMove ~= crossingTurn() then
								return false
							end
						elseif (getStatePosition(other) - myPos).Magnitude < CROSS_CLEAR_RADIUS then
							-- Perpendicular cross traffic clearing right in front of us:
							-- yield. A car exiting the far side of a big box does not
							-- hold our green.
							return false
						end
					end
				end
			end
		end

		-- Permissive crossing turn: give way to oncoming through/nearside traffic on green
		-- AND is close enough to actually conflict (within 45 studs of stop line).
		-- Guard: only apply when the oncoming car is still approaching (not connector),
		-- otherwise a car that already committed and is inside the box keeps blocking us.
		if myMove == crossingTurn() and not other.connector then
			local otherEdge = g:GetEdge(other.edgeId)
			if otherEdge and otherEdge.toNode == nodeId and isOpposite(myDir, otherEdge.toDir) then
				local otherNext = other.pendingNextEdgeId
			local otherMove = "straight"
				if otherNext then
					otherMove = otherEdge.outMovement and otherEdge.outMovement[otherNext] or "straight"
				end
				if otherMove ~= crossingTurn() and TrafficSignalService.CanGo(other.edgeId, otherNext) then
					local cum = PathFollower.getCum(otherEdge)
					local total = cum and cum[#cum] or 0
					local gap = getStopLineGap(g, nodeId, otherEdge)
					local stopLine = total - gap
					local distToStop = stopLine - other.edgeDist
					-- Only yield if the oncoming car is within 40 studs of the stop line
					-- (approaching) but not already past it (committed inside the box).
					if distToStop > 0 and distToStop < 40 then
						return false
					end
				end
			end
		end
	end
	return true
end

-- Gap acceptance at a give-way junction: yield only to cross traffic that will
-- actually REACH the line within this many seconds.
local CROSS_GAP_TIME = 3

-- Seconds until `other` reaches this node's stop line; math.huge when it is not
-- moving. A stationary car is queued or yielding to us, never a conflict -- waiting
-- on one is what made an unsignalised crossing behave like a red light: four cars
-- stopped at the line, each holding the next, until the impatience timer let them
-- trickle through one at a time.
-- Extra centre setback so the NOSE halts ~1 stud before the painted stop line, whatever
-- the vehicle length. getStopLineGap already bakes a car-sized buffer into the gap;
-- this adds the difference for anything longer than that (the truck-overruns-line fix).
local function noseSetback(state: DriverState): number
	return math.max(0, (state.halfLength or STOP_LINE_CAR_BUFFER) - STOP_LINE_CAR_BUFFER) + 1
end

local function etaToStopLine(g: any, other: DriverState, otherEdge: any, nodeId: number): number
	local speed = other.currentSpeed or 0
	if speed < 1 then return math.huge end
	local cum = PathFollower.getCum(otherEdge)
	local total = cum and cum[#cum] or 0
	local dist = total - getStopLineGap(g, nodeId, otherEdge) - other.edgeDist
	if dist <= 0 then return 0 end
	return dist / speed
end

-- Right-of-way at an unsignalized intersection (rare fallback -- every >=3-arm
-- node normally gets a signal). Minor arms yield to major; equal-priority cross
-- traffic yields to whoever is closer to the line, with a deterministic tie-break.
local function unsignalizedClear(g: any, state: DriverState, edge: any, nodeId: number, myDir: Vector3, myMove: string): boolean
	local myPriority = getArmPriority(g, nodeId, edge.id)
	local myPos = getStatePosition(state)

	for _, other in pairs(_drivers) do
		if other == state or not other.model.Parent then continue end

		-- Cars crossing the node now.
		if other.connector and other.nextEdgeId then
			local otherNextEdge = g:GetEdge(other.nextEdgeId)
			if otherNextEdge and otherNextEdge.fromNode == nodeId and other.edgeId ~= edge.id then
				local otherEdge = g:GetEdge(other.edgeId)
				if otherEdge then
					if isOpposite(myDir, otherEdge.toDir) then
						local otherMove = otherEdge.outMovement and otherEdge.outMovement[other.nextEdgeId] or "straight"
						if myMove == crossingTurn() and otherMove ~= crossingTurn() then return false end
					elseif (getStatePosition(other) - myPos).Magnitude < CROSS_CLEAR_RADIUS then
						return false -- perpendicular crossing traffic right in front of us
					end
				end
			end
		end

		-- Approaching cars near the line.
		if not other.connector then
			local otherEdge = g:GetEdge(other.edgeId)
			if otherEdge and otherEdge.toNode == nodeId and otherEdge.id ~= edge.id then
				if etaToStopLine(g, other, otherEdge, nodeId) < CROSS_GAP_TIME then
					if isOpposite(myDir, otherEdge.toDir) then
						-- Oncoming: only our crossing turn yields to their straight/nearside.
						if myMove == crossingTurn() then
							local otherNext = other.pendingNextEdgeId
							local otherMove = "straight"
							if otherNext then
								otherMove = otherEdge.outMovement and otherEdge.outMovement[otherNext] or "straight"
							end
							if otherMove ~= crossingTurn() then return false end
						end
					else
						-- Cross traffic.
						local otherPriority = getArmPriority(g, nodeId, otherEdge.id)
						if myPriority == "minor" and otherPriority == "major" then
							return false
						elseif myPriority == otherPriority then
							-- Left-before-right: yield to equal-priority cross traffic approaching from
							-- our left. Anti-symmetric, so exactly one of a pair yields (the
							-- impatience escape above breaks any 4-way circular wait).
							local leftX, leftZ = myDir.Z, -myDir.X
							if (-otherEdge.toDir.X) * leftX + (-otherEdge.toDir.Z) * leftZ > 0 then
								return false
							end
						end
					end
				end
			end
		end
	end
	return true
end

-- Roundabout give-way. A car entering the ring from an approach yields to traffic
-- already circulating that is about to pass its entry node; a car already on the
-- ring has priority. Circulating conflicts: a car on the ring arc whose toNode is
-- our entry (within ROUNDABOUT_YIELD_DIST), or one mid-crossing onto a ring arc
-- leaving our node.
local function roundaboutClear(g: any, state: DriverState, nodeId: number, nodePos: Vector3): boolean
	for _, other in pairs(_drivers) do
		if other == state or not other.model.Parent then continue end
		local otherEdge = g:GetEdge(other.edgeId)
		if not otherEdge then continue end
		if other.connector then
			-- A car crossing our node onto the ring, or one that has just reached our
			-- node on a ring arc, is circulating through -- give way.
			local nextE = other.nextEdgeId and g:GetEdge(other.nextEdgeId)
			if nextE and nextE.isRoundabout and nextE.fromNode == nodeId then
				return false
			end
			if otherEdge.isRoundabout and otherEdge.toNode == nodeId then
				return false
			end
		elseif otherEdge.isRoundabout and otherEdge.toNode == nodeId then
			-- A circulating car on the arc heading into our node, close enough to
			-- conflict. Euclidean distance to the node is robust (no cum lookup).
			if (getStatePosition(other) - nodePos).Magnitude < ROUNDABOUT_YIELD_DIST then
				return false
			end
		end
	end
	return true
end

-- True while a car on a CONFLICTING path is physically inside this junction (on its connector
-- through the node). The impatience escape exists to break standoffs between cars WAITING at
-- the lines; it must never send a car into one that is already crossing -- that is how
-- traffic drove straight through itself. A car held in the box by the queue on its exit is
-- traffic, and the cars behind it wait for it like any other jam.
-- Whether a movement from another arm crosses ours. Compatible pairs: the same approach arm
-- (parallel lanes, excluded by the callers), oncoming traffic when neither or both of the pair
-- cut across it, and two nearside turns.
local function movesConflict(myDir: Vector3, myMove: string, otherEdge: any, otherMove: string): boolean
	local cross = crossingTurn()
	local myCross = myMove == cross
	if isOpposite(myDir, otherEdge.toDir) then
		return myCross ~= (otherMove == cross)
	end
	local myNear = myMove ~= "straight" and myMove ~= "uturn" and not myCross
	local otherNear = otherMove ~= "straight" and otherMove ~= "uturn" and otherMove ~= cross
	return not (myNear and otherNear)
end

-- How far a car's nose is from its stop line at `nodeId` (negative once it is over it).
local function distToStopLine(g: any, other: DriverState, otherEdge: any, nodeId: number): number
	local cum = PathFollower.getCum(otherEdge)
	return cum[#cum] - getStopLineGap(g, nodeId, otherEdge) - noseSetback(other) - other.edgeDist
end

local function boxHasConflict(g: any, state: DriverState, edge: any, nodeId: number, myDir: Vector3, myMove: string): boolean
	for _, other in pairs(_drivers) do
		if other == state or not other.connector or not other.nextEdgeId or not other.model.Parent then continue end
		local otherNext = g:GetEdge(other.nextEdgeId)
		if not otherNext or otherNext.fromNode ~= nodeId then continue end
		local otherEdge = g:GetEdge(other.edgeId)
		if not otherEdge or otherEdge.segmentId == edge.segmentId then continue end
		local otherMove = otherEdge.outMovement and otherEdge.outMovement[other.nextEdgeId] or "straight"
		if movesConflict(myDir, myMove, otherEdge, otherMove) then return true end
	end
	-- A car over its stop line has committed and will not stop, but its path through the box
	-- only starts at the junction mouth a few studs on: until then it is in the box all the same.
	for _, inEdge in g._edgesByToNode[nodeId] or {} do
		if inEdge.segmentId == edge.segmentId then continue end
		for _, other in _edgeDriverIndex[inEdge.id] or {} do
			local otherNextId = other.pendingNextEdgeId
			if other == state or other.connector or not otherNextId or not other.model.Parent then continue end
			if distToStopLine(g, other, inEdge, nodeId) >= -0.1 then continue end
			local otherMove = inEdge.outMovement and inEdge.outMovement[otherNextId] or "straight"
			if movesConflict(myDir, myMove, inEdge, otherMove) then return true end
		end
	end
	return false
end

-- How long a car on `edge` waits at a junction without signals before it takes its turn.
local function turnWait(g: any, nodeId: number, edge: any): number
	if getArmPriority(g, nodeId, edge.id) == "minor" then
		for _, p in getNodeMeta(g, nodeId).armPriority do
			if p == "major" then return TURN_WAIT_MINOR end
		end
	end
	return TURN_WAIT_EQUAL
end

-- Courtesy at a junction without signals. The car that has waited longest at its line (its
-- turn wait plus CLAIM_EXTRA, with room on its exit) is let in: every car whose path crosses
-- its path holds at the line until it is through. One such car per junction at a time --
-- when every stopped car could claim, each car held for one became a claimant in turn and
-- the junction ran as an all-way stop. Without it a steady stream on one road, or the queue
-- behind one car waiting to turn across it, starved the other approaches for minutes.
-- Turns go by when the wait BEGAN (waitSince), never by blockedTime: that grows during each
-- car's own update, so two cars compared mid-tick could each see the other as the longer
-- waiter and both hold for good.
local CLAIM_EXTRA = 6 -- s past its turn wait before the others stop to let a car in
local function junctionClaimant(g: any, nodeId: number): (DriverState?, any)
	local best, bestEdge, bestSince = nil, nil, 0
	for _, inEdge in g._edgesByToNode[nodeId] or {} do
		local threshold = turnWait(g, nodeId, inEdge) + CLAIM_EXTRA
		for _, other in _edgeDriverIndex[inEdge.id] or {} do
			if other.connector or not other.model.Parent then continue end
			local wait = other.blockedTime or 0
			if wait < threshold then continue end
			local since = other.waitSince or (_simClock - wait)
			if best and (since > bestSince or (since == bestSince and goesFirst(best, other))) then continue end
			local nextId = other.pendingNextEdgeId
			if not nextId or not exitLaneHasRoom(g, other, nextId) then continue end
			if distToStopLine(g, other, inEdge, nodeId) > AT_LINE_DIST then continue end
			best, bestEdge, bestSince = other, inEdge, since
		end
	end
	return best, bestEdge
end

local function owesCourtesy(g: any, state: DriverState, edge: any, nodeId: number, myDir: Vector3, myMove: string): boolean
	local claimant, claimEdge = junctionClaimant(g, nodeId)
	if not claimant or claimant == state or claimEdge.segmentId == edge.segmentId then return false end
	local claimMove = claimEdge.outMovement and claimEdge.outMovement[claimant.pendingNextEdgeId] or "straight"
	return movesConflict(myDir, myMove, claimEdge, claimMove)
end

-- A join between two pieces of road has no right-of-way rules, but where two lanes become one
-- (a lane drop) or swap across it, two cars can arrive side by side. Hold back while a car
-- from another lane of this road is crossing the join close by on a path that meets or
-- crosses ours; it is through in a moment, and the queue spacing takes over from there.
local function joinClear(g: any, state: DriverState, edge: any, nextEdgeId: string): boolean
	local target = g:GetEdge(nextEdgeId)
	if not target then return true end
	local myPos = getStatePosition(state)
	for _, outId in edge.out do
		local out = if outId == nextEdgeId then target else g:GetEdge(outId)
		if not out then continue end
		for _, other in _connectorByNextEdgeIndex[outId] or {} do
			if other == state or other.edgeId == edge.id or not other.model.Parent or laneChangeOf(other) then continue end
			local src = g:GetEdge(other.edgeId)
			if not src or src.toNode ~= edge.toNode then continue end
			local meets = outId == nextEdgeId
				or ((edge.laneOrdinal or 0) - (src.laneOrdinal or 0)) * ((target.laneOrdinal or 0) - (out.laneOrdinal or 0)) < 0
			if meets and (getStatePosition(other) - myPos).Magnitude < 2 * followGap(state, other) then
				return false
			end
		end
	end
	return true
end

local function canEnterIntersection(g: any, state: DriverState, edge: any, nextEdgeId: string): boolean
	-- A bugged car the stall watchdog is rescuing is pushed through; nothing else is.
	if state.rescueFrom then
		return true
	end
	local nodeId = edge.toNode
	if not isIntersectionNode(g, nodeId) then
		-- A dead-end U-turn back onto the same road needs the same one-at-a-time
		-- gating an intersection gets. Without it, cars commit U-turns into a full
		-- return lane and clump at the cul-de-sac mouth until the road gridlocks.
		-- A jammed return lane is traffic: wait until it has room.
		local myMove = edge.outMovement and edge.outMovement[nextEdgeId]
		if myMove == "uturn" then
			-- Same-segment only: a sharp bend onto ANOTHER road classifies as a
			-- U-turn by angle but is ordinary through-traffic around the corner --
			-- gating it made cars queue at (and creep past) the bend apex.
			local nextEdge = g:GetEdge(nextEdgeId)
			if not nextEdge or nextEdge.segmentId ~= edge.segmentId then
				return true
			end
			return exitLaneHasRoom(g, state, nextEdgeId)
		end
		return joinClear(g, state, edge, nextEdgeId)
	end

	-- Roundabout right-of-way -- decided on the lane flags (not node meta), so it can
	-- never silently fall back to ordinary junction logic. A circulating car has
	-- absolute priority and never yields at a ring node (the follower clearance keeps
	-- it off the car ahead, so no node-by-node stutter). An entering car gives way to
	-- circulating traffic, but noses in after the impatience escape so a busy ring
	-- cannot hold it -- never onto a full ring lane.
	if edge.isRoundabout then
		return true
	end
	do
		local nextEdge = g:GetEdge(nextEdgeId)
		if nextEdge and nextEdge.isRoundabout then
			if not exitLaneHasRoom(g, state, nextEdgeId) then
				return false
			end
			if (state.blockedTime or 0) >= IMPATIENCE_TIME then
				return true
			end
			local nodePos = if edge.points and #edge.points > 0 then edge.points[#edge.points] else getStatePosition(state)
			return roundaboutClear(g, state, nodeId, nodePos)
		end
	end

	local signalized = isSignalizedIntersection(nodeId)
	local myMove = edge.outMovement and edge.outMovement[nextEdgeId] or "straight"
	local myDir  = edge.toDir
	-- A red that outlasts any real cycle is a broken signal, not traffic: the junction
	-- works as a give-way until the light changes again.
	local signalFault = signalized and (state.redTime or 0) >= SIGNAL_FAULT_TIME

	-- A red or yellow light is an unconditional stop.
	if signalized and not signalFault and not TrafficSignalService.CanGo(edge.id, nextEdgeId) then
		return false
	end

	-- Don't enter unless the exit lane has room. However long it has been full, a full exit
	-- is a jam: a gridlocked box stays gridlocked until the queue ahead moves or the player
	-- changes the roads.
	if not exitLaneHasRoom(g, state, nextEdgeId) then
		return false
	end

	if signalFault then
		return not boxHasConflict(g, state, edge, nodeId, myDir, myMove)
	end

	if not signalized and owesCourtesy(g, state, edge, nodeId, myDir, myMove) then
		return false
	end

	-- Impatience backstop / taking a turn: after waiting its time for a gap, the car goes, so
	-- a busy road can never block a yielding car forever. Without signals that time is short
	-- (turnWait): the others let it in (owesCourtesy). Never runs a red light (handled above),
	-- still respects exit-lane room (above), and never pulls out into a car already crossing
	-- the box (boxHasConflict).
	local patience = if signalized then IMPATIENCE_TIME else turnWait(g, nodeId, edge)
	if (state.blockedTime or 0) >= patience
		and not boxHasConflict(g, state, edge, nodeId, myDir, myMove) then
		return true
	end

	if signalized then
		return signalizedClear(g, state, edge, nodeId, myDir, myMove)
	end
	-- Give-way junctions: one conflicting movement in the box at a time. The gap rules
	-- below only see crossing cars within CROSS_CLEAR_RADIUS, and a large box lets a car
	-- still mid-crossing sit farther out than that, right across our path.
	if boxHasConflict(g, state, edge, nodeId, myDir, myMove) then
		return false
	end
	return unsignalizedClear(g, state, edge, nodeId, myDir, myMove)
end

local function chooseEnterableNextEdgeId(g: any, state: DriverState, edge: any, currentNextId: string?): (string?, boolean)
	if not currentNextId then
		return nil, false
	end
	if canEnterIntersection(g, state, edge, currentNextId) then
		return currentNextId, true
	end

	-- If the approach itself is red/yellow/all-red, changing turns will not help.
	if isSignalizedIntersection(edge.toNode) and not TrafficSignalService.CanGo(edge.id, currentNextId) then
		return currentNextId, false
	end

	-- ponytail: never re-roll the turn while blocked. getPendingNextEdgeId locks the exit
	-- in on purpose; re-rolling it every tick made a yielding pair flip their decision
	-- against each other (livelock), and could shove a DIRECTED car off its route.
	return currentNextId, false
end

-- Max comfortable speed through a connector polyline, from its tightest bend:
-- v = sqrt(a_lat * r). Stops cars taking 90-deg turns and U-turns at the full
-- road speed limit, which read as snapping at the wheel.
local function connectorSpeedCap(pts: { Vector3 }): number?
	if #pts < 3 then return nil end
	local minRadius = math.huge
	for i = 2, #pts - 1 do
		local a = pts[i] - pts[i - 1]
		local b = pts[i + 1] - pts[i]
		local la, lb = a.Magnitude, b.Magnitude
		if la > 1e-4 and lb > 1e-4 then
			local angle = math.acos(math.clamp(a:Dot(b) / (la * lb), -1, 1))
			if angle > 1e-3 then
				minRadius = math.min(minRadius, ((la + lb) * 0.5) / angle)
			end
		end
	end
	if minRadius == math.huge then return nil end
	return math.max(math.sqrt(CONNECTOR_LAT_ACCEL * minRadius), MIN_TURN_SPEED)
end

-- Connector Y interpolates mouth-to-mouth, but a graded junction's interior is
-- a blended surface that can bow away from that line -- cars sank into the
-- slab mid-box. Ground each interior point on the real rendered junction
-- surface (junction surface parts are CanQuery for exactly this). Points with
-- no junction surface under them (corners, dead-end bulbs) keep their Y.
local GROUND_RAY_UP   = Vector3.new(0, 4, 0)
local GROUND_RAY_DOWN = Vector3.new(0, -16, 0)
local GROUND_MAX_SNAP = 3
local _groundParams: RaycastParams? = nil

local function groundParams(): RaycastParams?
	-- ONLY the road geometry folder. Filtering all of _City snapped connector
	-- points onto NPC click-hitboxes and zoning lots -- cars climbed each other.
	-- Inside Roads, junction surfaces are the only CanQuery parts.
	local city = Workspace:FindFirstChild("_City")
	local roads = city and city:FindFirstChild("Roads")
	if not roads then
		return nil
	end
	local p = _groundParams
	if not p or p.FilterDescendantsInstances[1] ~= roads then
		p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Include
		p.FilterDescendantsInstances = { roads }
		_groundParams = p
	end
	return p
end

-- Lane points (RoadNavigationGraph) run down the MIDDLE of the road slab -- the road renderer's
-- convention -- while the asphalt is half a slab higher. NPCHeightOffset is a vehicle's clearance
-- above what it drives on, so every road placement adds this. Without it every car rode half a
-- slab (a quarter metre) sunk into the road, and dropped into it leaving a driveway.
local LANE_SURFACE = RoadConstants.ROAD_THICKNESS * 0.5

local function groundConnectorPoints(pts: { Vector3 })
	if #pts < 3 then
		return
	end
	local params = groundParams()
	if not params then
		return
	end
	local halfThick = RoadConstants.ROAD_THICKNESS * 0.5
	for i = 2, #pts - 1 do
		local p = pts[i]
		local hit = Workspace:Raycast(p + GROUND_RAY_UP, GROUND_RAY_DOWN, params)
		-- Pillars are queryable for placement checks; never a driving surface.
		if hit and hit.Instance.Name ~= "ElevationPillar" then
			local y = hit.Position.Y - halfThick
			if math.abs(y - p.Y) <= GROUND_MAX_SNAP then
				pts[i] = Vector3.new(p.X, y, p.Z)
			end
		end
	end
end

local function startConnector(
	state:        DriverState,
	pts:          { Vector3 },
	nextId:       string,
	resumeDist:   number
)
	groundConnectorPoints(pts)
	-- Pre-compute and cache the cum-distances for the connector arc once.
	local cum = PathFollower.cumOf(pts)
	if #pts < 2 or (cum[#cum] or 0) < 0.5 then
		state.connector    = nil
		state.connCum      = nil
		state.connDist     = 0
		state.connSpeedCap = nil
		state.connBlockedTime = 0
		state.nextEdgeId   = nil
		state.nextEdgeDist = 0
		state.pendingNextEdgeId = nil
		state.edgeId       = nextId
		state.edgeDist     = resumeDist
		return
	end
	state.connector    = pts
	state.connCum      = cum
	state.connDist     = 0
	state.connSpeedCap = connectorSpeedCap(pts)
	state.connBlockedTime = 0
	state.nextEdgeId   = nextId
	state.nextEdgeDist = resumeDist
	state.pendingNextEdgeId = nil
end

local function buildUTurnArc(fromEdge: any, toEdge: any): { Vector3 }
	local pts = fromEdge.points
	local p0  = pts[#pts]
	local tp  = toEdge.points
	local p3  = tp[1]

	-- Tangent-continuous teardrop: both bezier handles push forward into the
	-- dead end, so the car leaves its lane straight, loops around, and lands
	-- straight on the return lane. The old constant-radius arc put its centre
	-- FORWARD of the lane tips, so p0/p3 sat sqrt(2)x off the circle and the
	-- car snapped sideways at both ends of the turn.
	local fwd    = flatUnit(fromEdge.toDir)
	local outDir = flatUnit(toEdge.fromDir)

	local gap    = Vector3.new(p3.X - p0.X, 0, p3.Z - p0.Z).Magnitude
	local handle = math.max(gap * 0.9, 4)
	local p1 = p0 + fwd * handle
	local p2 = p3 - outDir * handle

	local SAMPLES = 20
	local out: { Vector3 } = table.create(SAMPLES + 1)
	for i = 0, SAMPLES do
		table.insert(out, BezierUtil.point(p0, p1, p2, p3, i / SAMPLES))
	end
	return out
end

-- Max distance to the nearest surviving lane before a stranded car despawns
-- instead of re-anchoring. Snapping survivors onto a random distant edge read
-- as cars teleporting across the map when the road was deleted under them.
local REANCHOR_MAX_DIST = 80

-- == Route bookings ============================================================
-- The nav-app effect. A driver that commits to a route reserves capacity along it,
-- so the NEXT driver to plan already prices that corridor as filling and peels off
-- onto an alternative. Without this, a wave of cars leaving at the same moment all
-- see the same empty road, all choose it, and build the jam together -- the exact
-- behaviour real drivers avoid by being told where everyone else is going.
--
-- Booked -> released as a pair: every path that drops a driver from _drivers must
-- release, or the road stays permanently "busy". The graph also expires bookings on
-- a TTL as a backstop for cars destroyed out from under us.
local function bookRoute(state: DriverState)
	local g = nav()
	local route = state.route
	if not g or not route then return end
	local token = state.bookingToken
	if not token then
		_nextBookingToken += 1
		token = _nextBookingToken
		state.bookingToken = token
		state.profile = DriverProfile.withToken(state.profile, token)
	end
	g:BookRoute(token, route, state.routeIndex or 1)
end

local function releaseBooking(state: DriverState)
	local token = state.bookingToken
	if not token then return end
	state.bookingToken = nil
	local g = nav()
	if g then g:ReleaseBooking(token) end
end

local function despawnDriver(state: DriverState)
	local model = state.model
	releaseBooking(state)
	_drivers[model] = nil
	PathFollower.forget(model)
	model:Destroy()
end

-- End a directed trip WITHOUT destroying the car: drop it from the driver pool and
-- hand control back to the caller (onAbort), which parks the citizen/delivery car
-- where it is. Used when the road changes under a routed car or it wedges for good.
local function abortDirected(state: DriverState)
	local cb = state.onAbort
	releaseBooking(state)
	clearDirectedDebugTag(state)
	state.route = nil
	state.onArrive = nil
	state.onAbort = nil
	_drivers[state.model] = nil
	PathFollower.forget(state.model)
	if cb then task.spawn(cb) end
end

local function anchorToNearest(state: DriverState): boolean
	if not state.model.Parent then return false end
	local g = nav()
	if not g or not g:HasEdges() then
		-- No roads left at all.
		despawnDriver(state)
		return false
	end
	local result = g:NearestEdge(getStatePosition(state))
	if not result or result.distance > REANCHOR_MAX_DIST then
		-- Road under us was deleted with no lane nearby: despawn rather than
		-- teleport to a random edge.
		despawnDriver(state)
		return false
	end
	state.edgeId       = result.edge.id
	local d = 0
	for i = 2, math.clamp(result.index, 1, #result.edge.points) do
		d += (result.edge.points[i] - result.edge.points[i-1]).Magnitude
	end
	state.edgeDist     = d
	state.graphVersion = g:Version()
	state.connector    = nil
	state.connCum      = nil
	state.connDist     = 0
	state.nextEdgeId   = nil
	state.nextEdgeDist = 0
	state.pendingNextEdgeId = nil
	state.atDeadEnd    = false
	state.deadEndTimer = 0
	return true
end

-- Distance along an edge to the point on it nearest a world position.
-- Distance along a lane of the point on it closest to `pos`.
--
-- This projects onto each CHORD, not onto the sample points. Snapping to the nearest
-- vertex (which this used to do) quantised every answer to the lane's sampling, and a
-- straight lane is sampled at NAV_WAYPOINT_SPACING = 56 studs -- so a car could be placed
-- up to 28 studs from where it actually was, and a whole queue spaced FOLLOW_MIN_GAP
-- (8 studs) apart collapsed onto one or two vertices. Every caller wants the real nearest
-- point: DriveDirected uses it to seat a car at the start of a trip, anchorToNearest to
-- rejoin a car whose road was edited, and the save/restore path to put a jam back exactly
-- where it stood.
local function distAlongEdgeNearest(edge: any, pos: Vector3): number
	local cum = PathFollower.getCum(edge)
	local pts = edge.points
	if #pts == 0 then return 0 end
	if #pts == 1 then return cum[1] or 0 end
	local best, bestSq = 0, math.huge
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local abx, abz = b.X - a.X, b.Z - a.Z
		local len2 = abx * abx + abz * abz
		local t = 0
		if len2 > 1e-9 then
			t = math.clamp(((pos.X - a.X) * abx + (pos.Z - a.Z) * abz) / len2, 0, 1)
		end
		local dx = (a.X + abx * t) - pos.X
		local dz = (a.Z + abz * t) - pos.Z
		local sq = dx * dx + dz * dz
		if sq < bestSq then
			bestSq = sq
			best = (cum[i] or 0) + math.sqrt(len2) * t
		end
	end
	return best
end

-- A directed car whose current edge was deleted (road replaced/upgraded under it)
-- tries to rejoin the network: snap to the nearest surviving lane and re-plan a
-- fresh route from there to the same destination, so the trip continues on the new
-- road instead of being aborted. Returns false if there is no lane in range or no
-- path to the goal -- the caller then falls back to abortDirected.
local function tryReroute(state: DriverState): boolean
	local g = nav()
	if not g or not g:HasEdges() then return false end
	local goal = state.goalPos
	if not goal then return false end
	if not state.model.Parent then return false end

	local pos = getStatePosition(state)
	local nearest = g:NearestEdge(pos)
	if not nearest or nearest.distance > REANCHOR_MAX_DIST then return false end

	local _, route = g:FindPath(pos, goal, nil, state.vehicleClass, state.profile)
	if typeof(route) ~= "table" or #route == 0 then return false end
	local firstEdge = g:GetEdge(route[1])
	local lastEdge = g:GetEdge(route[#route])
	if not firstEdge or not lastEdge then return false end

	state.route        = route
	state.routeIndex   = 1
	state.edgeId       = route[1]
	state.edgeDist     = distAlongEdgeNearest(firstEdge, pos)
	state.finalDist    = distAlongEdgeNearest(lastEdge, goal)
	state.graphVersion = g:Version()
	state.connector    = nil
	state.connCum      = nil
	state.connDist     = 0
	state.connSpeedCap = nil
	state.nextEdgeId   = nil
	state.nextEdgeDist = 0
	state.pendingNextEdgeId = nil
	state.atDeadEnd    = false
	state.deadEndTimer = 0
	state.arrived      = false
	state.trafficJamTime = 0
	state.nextTrafficRerouteAt = os.clock() + TRAFFIC_REROUTE_COOLDOWN
	bookRoute(state)
	return true
end

local function sameRemainingRoute(oldRoute: { string }, oldIndex: number, newRoute: { string }): boolean
	local remaining = #oldRoute - oldIndex + 1
	if remaining ~= #newRoute then return false end
	for i = 1, #newRoute do
		if oldRoute[oldIndex + i - 1] ~= newRoute[i] then
			return false
		end
	end
	return true
end

local function firstRouteDivergence(oldRoute: { string }, oldIndex: number, newRoute: { string }): (string?, string?)
	local remaining = #oldRoute - oldIndex + 1
	for offset = 2, math.max(remaining, #newRoute) do
		local oldEdgeId = oldRoute[oldIndex + offset - 1]
		local newEdgeId = newRoute[offset]
		if oldEdgeId ~= newEdgeId then
			return oldEdgeId, newEdgeId
		end
	end
	return nil, nil
end

-- The same roads in the same order, only on other lanes: a move over, not a detour.
local function sameRoads(g: any, oldRoute: { string }, oldIndex: number, newRoute: { string }): boolean
	local function roads(route: { string }, from: number): { number }
		local out: { number } = {}
		for i = from, #route do
			local edge = g:GetEdge(route[i])
			local segmentId = if edge then edge.segmentId else -1
			if out[#out] ~= segmentId then table.insert(out, segmentId) end
		end
		return out
	end
	local a, b = roads(oldRoute, oldIndex), roads(newRoute, 1)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- Traffic reroutes never snap the car to another lane. They only replace the
-- untravelled route tail when A* finds a meaningfully cheaper path that begins on
-- the exact edge the car is already following. A plan that keeps every road and only
-- moves over a lane (out of a queue into the empty lane beside it) is a lane change, not a
-- detour: it needs to beat the old plan by seconds, not by a share of the whole trip, and
-- it spends none of the driver's detour budget.
local function tryTrafficReroute(state: DriverState): boolean
	local g = nav()
	local route = state.route
	local goal = state.goalPos
	if not g or not route or not goal or state.connector or not state.model.Parent then return false end
	local profile = state.profile
	local rerouteCount = state.trafficReroutes or 0
	-- A jam-averse driver gives itself more chances to change its mind than a
	-- fatalistic one, who commits and sits in it.
	local rerouteBudget = TRAFFIC_REROUTE_MAX_PER_TRIP + (if profile then profile.extraReroutes else 0)
	local routeIndex = state.routeIndex or 1
	if routeIndex >= #route then return false end

	local pos = getStatePosition(state)
	local _, candidate = g:FindPath(pos, goal, nil, state.vehicleClass, profile)
	if typeof(candidate) ~= "table" or #candidate == 0 or candidate[1] ~= state.edgeId then
		return false
	end
	if sameRemainingRoute(route, routeIndex, candidate) then
		return false
	end

	-- Hysteresis: once a car abandons a branch, do not let small traffic-score
	-- fluctuations send it straight back toward that same branch.
	local now = os.clock()
	local abandonedBranch, candidateBranch = firstRouteDivergence(route, routeIndex, candidate)
	if candidateBranch
		and candidateBranch == state.lastTrafficAbandonedNextEdgeId
		and now - (state.lastTrafficRerouteAt or 0) < TRAFFIC_REROUTE_REVERSAL_LOCK then
		return false
	end

	-- Both routes are priced with the SAME mind (this driver's), or every reroute
	-- would look like an improvement purely from the change of scorer.
	local oldCost = g:EstimatePathCost(route, routeIndex, profile)
	local newCost = g:EstimatePathCost(candidate, 1, profile)
	if oldCost == math.huge then return false end
	local laneMove = sameRoads(g, route, routeIndex, candidate)
	if laneMove then
		if newCost > oldCost - LANE_MOVE_MIN_SAVING then return false end
	else
		if rerouteCount >= rerouteBudget then return false end
		-- How much better the alternative must be before this driver commits to it.
		-- Persona sets the baseline (twitchy re-router vs "I've started, I'll finish");
		-- each reroute already taken raises the bar further, so nobody oscillates.
		local baseImprovement = if profile then profile.detourTrigger else TRAFFIC_REROUTE_MIN_IMPROVEMENT
		local requiredImprovement = math.min(0.6, baseImprovement + rerouteCount * 0.1)
		if newCost >= oldCost * (1 - requiredImprovement) then
			return false
		end
	end

	local lastEdge = g:GetEdge(candidate[#candidate])
	if not lastEdge then return false end
	state.lastTrafficAbandonedNextEdgeId = abandonedBranch
	state.lastTrafficRerouteAt = now
	state.route = candidate
	state.routeIndex = 1
	state.finalDist = distAlongEdgeNearest(lastEdge, goal)
	state.pendingNextEdgeId = nil
	state.trafficJamTime = 0
	if not laneMove then state.trafficReroutes = rerouteCount + 1 end
	-- Re-reserve: free the abandoned corridor for everyone else and stake a claim on
	-- the new one, so the next planner sees where this car actually went.
	bookRoute(state)
	tagCarInfo(state, "Rerouting", candidateBranch or candidate[2] or candidate[1])
	return true
end

-- == Stall watchdog ============================================================
-- Last-resort safety net for BUGGED cars only. A car held by traffic (see
-- waitingInTraffic) waits as long as the traffic does -- a gridlock is part of the
-- simulation and the player's to fix. Zero movement for STALL_RESCUE_TIME with no
-- traffic reason means something is truly wedged: dump the full state for diagnosis,
-- then re-seat the car and let it push through. If it stalls again with no progress
-- in between, respawn it on a random edge.
local function dumpStall(state: DriverState)
	warn(`[NPCDriverService] {state.model.Name} stalled {STALL_RESCUE_TIME}s -- rescuing.`
		.. ` edge={state.edgeId}@{string.format("%.1f", state.edgeDist)}`
		.. ` conn={state.connector ~= nil}@{string.format("%.1f", state.connDist)}`
		.. ` next={state.nextEdgeId or "-"} pending={state.pendingNextEdgeId or "-"}`
		.. ` deadEnd={state.atDeadEnd} speed={string.format("%.1f", state.currentSpeed or 0)}`
		.. ` blocked={string.format("%.1f", state.blockedTime or 0)}`
		.. ` stuck={string.format("%.1f", state.stuckTime or 0)}`
		.. ` standoff={string.format("%.1f", state.connBlockedTime or 0)}`
		.. ` rescues={state.rescueCount or 0}`)
end

-- One index bucket's nearest car ahead of `myPos` on `laneId`. Equal positions break by
-- name so exactly one of a pair waits.
local function queueScan(bucket: { any }?, state: DriverState, laneId: string, myPos: number,
	onlyConnectors: boolean, nearest: DriverState?, nearestGap: number): (DriverState?, number)
	for _, other in bucket or {} do
		if other == state or not other.model.Parent then continue end
		if onlyConnectors then
			if not other.connector then continue end
		elseif other.connector and not laneChangeOf(other) then
			continue -- turned off this lane since the index was built
		end
		local rawGap = lanePos(other, laneId) - myPos
		local tied = math.abs(rawGap) <= QUEUE_TIE_EPSILON and goesFirst(other, state)
		if rawGap > QUEUE_TIE_EPSILON or tied then
			local gap = math.max(0, rawGap)
			if gap < nearestGap then
				nearestGap = gap
				nearest = other
			end
		end
	end
	return nearest, nearestGap
end

-- Nearest car ahead in this car's lane, and the gap to it. On a connector "this lane" is the
-- one it lands on, so a queue runs unbroken through joins, turns and lane changes: cars
-- crossing into the lane and cars mid lane change out of it are in the way at their lanePos.
local function getNearestQueueLeader(state: DriverState): (DriverState?, number?)
	local laneId = if state.connector then state.nextEdgeId else state.edgeId
	if not laneId then return nil, nil end
	local myPos = lanePos(state, laneId)
	local nearest, nearestGap = queueScan(_edgeDriverIndex[laneId], state, laneId, myPos, false, nil, math.huge)
	nearest, nearestGap = queueScan(_connectorByNextEdgeIndex[laneId], state, laneId, myPos, true, nearest, nearestGap)
	nearest, nearestGap = queueScan(_laneChangeIndex[laneId], state, laneId, myPos, true, nearest, nearestGap)
	-- Inside the box, a car that left OUR lane ahead of us is still in front of us until it is
	-- through, whichever exit it takes: going straight on behind a slow turner from the same
	-- lane, we wait for it instead of driving through it where the two paths still overlap.
	-- Both measure from the same lane mouth, so distance along the connector compares.
	if state.connector and not laneChangeOf(state) then
		-- Round a roundabout the paths out of a ring lane part within a car length: one car
		-- carrying on round, the other turning off. Waiting for the whole of the other's turn
		-- there made each car leaving the ring queue behind one carrying on, and a busy ring
		-- locked solid -- so off the ring, the other is in the way only until its tail clears.
		local g = nav()
		local fromEdge = if g then g:GetEdge(state.edgeId) else nil
		local ring = fromEdge ~= nil and fromEdge.isRoundabout == true
		for _, other in _connectorByFromEdgeIndex[state.edgeId] or {} do
			if other == state or not other.model.Parent then continue end
			if ring and other.nextEdgeId ~= state.nextEdgeId
				and other.connDist - state.connDist > (other.halfLength or STOP_LINE_CAR_BUFFER) + 1 then
				continue
			end
			local gap = other.connDist - state.connDist
			local tied = math.abs(gap) <= QUEUE_TIE_EPSILON and goesFirst(other, state)
			if (gap > QUEUE_TIE_EPSILON or tied) and gap < nearestGap then
				nearestGap = math.max(0, gap)
				nearest = other
			end
		end
	end
	-- The same holds for a car that has already left our lane (the one we are on, or landing
	-- on) into the junction ahead: it is in front of us until it is through. The gap runs to
	-- where it left the lane plus how far along its connector it has got. Without this, a car
	-- coming to the end of a lane where nothing makes it stop -- a join, a bend, a short arc
	-- of a roundabout ring between two entries -- found the slow car ahead only by the late
	-- proximity check, and drove into it.
	-- One heading somewhere else is in the way only until its tail has cleared the lane
	-- mouth: past that its path has left ours. Holding on for it longer locked a busy
	-- roundabout solid -- a car leaving the ring waited on one carrying on round it, which
	-- waited on the car ahead of it, all the way round.
	local myNext: string? = if state.connector
		then (if state.route then state.route[(state.routeIndex or 1) + 2] else nil)
		else state.pendingNextEdgeId
	for _, other in _connectorByFromEdgeIndex[laneId] or {} do
		if other == state or not other.model.Parent then continue end
		if other.nextEdgeId ~= myNext and (other.connDist or 0) > (other.halfLength or STOP_LINE_CAR_BUFFER) + 1 then continue end
		local gap = (other.edgeDist - myPos) + (other.connDist or 0)
		if gap > QUEUE_TIE_EPSILON and gap < nearestGap then
			nearestGap = gap
			nearest = other
		end
	end
	return nearest, if nearest then nearestGap else nil
end

-- Two cars each other's blocker: nose to nose or locked across each other in a box. No
-- traffic can ever clear that, so it is a fault, not a jam.
local function inMutualStandoff(state: DriverState): boolean
	local blocker = state.blockedBy
	local other = if blocker then _drivers[blocker] else nil
	return other ~= nil and other.blockedBy == state.model
end

-- Standing still for a reason a driver would recognise: in a queue behind another car, at a
-- red, waiting for a gap or a merge, held by a full exit, or blocked by a car that is itself
-- held up. A jam is traffic, not a fault -- it stays until the player fixes the road, so
-- none of these ever counts toward a rescue. A blocker with no driver behind it is not
-- traffic: nothing will ever move it out of the way.
local function waitingInTraffic(state: DriverState): boolean
	local blocker = state.blockedBy
	if blocker then
		return _drivers[blocker] ~= nil and not inMutualStandoff(state)
	end
	local reason = state.stopReason
	if reason == "carAhead" or reason == "redLight" or reason == "laneChange" or reason == "merge"
		or reason == "yield" or reason == "blocked" then
		return true
	end
	return getNearestQueueLeader(state) ~= nil
end

local function stallWatchdog(state: DriverState, dt: number)
	local pos = getStatePosition(state)
	local from = state.rescueFrom
	if from and (pos - from).Magnitude > RESCUE_CLEAR_DIST then
		state.rescueFrom = nil
	end
	local last = state.lastProgressPos
	if not last or (pos - last).Magnitude > STALL_MOVE_EPSILON or waitingInTraffic(state) then
		state.lastProgressPos = pos
		state.noProgressTime = 0
		state.rescueCount = 0
		return
	end
	state.noProgressTime = (state.noProgressTime or 0) + dt
	if (state.noProgressTime or 0) < STALL_RESCUE_TIME then
		return
	end
	dumpStall(state)
	if state.route then
		-- A routed car truly wedged (not queued -- see waitingInTraffic): re-plan the same
		-- trip from the lane it is on and creep past whatever gated it. Only a car with no
		-- lane or no path left is handed back.
		state.noProgressTime = 0
		state.lastProgressPos = nil
		if tryReroute(state) then
			state.rescueFrom = getStatePosition(state)
		else
			abortDirected(state)
		end
		return
	end
	state.noProgressTime = 0
	state.lastProgressPos = nil
	state.rescueCount = (state.rescueCount or 0) + 1

	local g = nav()
	if not g or not g:HasEdges() then return end

	if state.rescueCount >= 2 then
		-- Re-seating did not free it: move the car to a random edge, away from
		-- whatever it is wedged into.
		local edges = g:GetEdges()
		local e = edges[math.random(1, #edges)]
		state.edgeId       = e.id
		state.edgeDist     = 0
		state.graphVersion = g:Version()
		state.connector    = nil
		state.connCum      = nil
		state.connDist     = 0
		state.connSpeedCap = nil
		state.connBlockedTime = 0
		state.nextEdgeId   = nil
		state.nextEdgeDist = 0
		state.pendingNextEdgeId = nil
		state.atDeadEnd    = false
		state.deadEndTimer = 0
		state.blockedTime  = 0
		state.stuckTime    = 0
		state.currentSpeed = 0
		local cum = PathFollower.getCum(e)
		local p, d = PathFollower.pointAtDist(e.points, cum, 0)
		state.smoothCFrame = nil
		PathFollower.place(state, p, d)
		return
	end

	-- First rescue: clear every bit of maneuver state, re-seat on the nearest
	-- lane, and let it push past whatever gated it.
	state.connector = nil
	state.connCum = nil
	state.connDist = 0
	state.connSpeedCap = nil
	state.atDeadEnd = false
	state.deadEndTimer = 0
	anchorToNearest(state)
	if state.model.Parent then
		state.rescueFrom = getStatePosition(state)
	end
end

local function getNearestQueueGap(state: DriverState): number?
	local _, gap = getNearestQueueLeader(state)
	return gap
end


local function updateTrafficReroute(state: DriverState, dt: number)
	local route = state.route
	if not route or state.connector or (state.routeIndex or 1) >= #route then
		state.trafficJamTime = 0
		return
	end

	local g = nav()
	local edge = g and g:GetEdge(state.edgeId)
	local speedLimit = if edge then edgeSpeed(edge) else state.speed
	local slowEnough = (state.currentSpeed or 0) <= math.max(2, speedLimit * CONGESTION_JAM_SPEED_RATIO)
	local queueGap = getNearestQueueGap(state)
	local reason = state.stopReason
	local trafficBlocked = reason == "carAhead" or (reason == "blocked" and queueGap ~= nil)

	if trafficBlocked and slowEnough then
		state.trafficJamTime = (state.trafficJamTime or 0) + dt
	else
		state.trafficJamTime = math.max(0, (state.trafficJamTime or 0) - dt * 2)
		return
	end

	-- Patience is personal: some drivers reach for an alternative after a few seconds
	-- in a queue, others sit through it. Same jam, different reactions -- which is what
	-- keeps a blocked road from emptying all at once into the same side street.
	local profile = state.profile
	local jamThreshold = TRAFFIC_REROUTE_JAM_TIME * (if profile then profile.patience else 1)
	local now = os.clock()
	if (state.trafficJamTime or 0) < jamThreshold
		or now < (state.nextTrafficRerouteAt or 0) then
		return
	end

	-- Cool down failed attempts too. A dense queue may have no alternate road, and
	-- repeated A* searches every driver tick would turn the cure into its own spike.
	state.nextTrafficRerouteAt = now + TRAFFIC_REROUTE_COOLDOWN
	state.trafficJamTime = 0
	tryTrafficReroute(state)
end

-- Distance to the closest car BEHIND us on the same edge (nil if none). Used to
-- ensure the unstuck back-up never reverses into a trailing car, which was
-- producing locked, overlapping pairs.
local function getNearestTrailing(state: DriverState): (DriverState?, number?)
	if state.connector then return nil, nil end
	local nearest = math.huge
	local driver: DriverState? = nil
	for _, other in ipairs(_edgeDriverIndex[state.edgeId] or {}) do
		if other ~= state and other.model.Parent and not other.connector then
			local gap = state.edgeDist - other.edgeDist
			if gap > QUEUE_TIE_EPSILON and gap < nearest then
				nearest = gap
				driver = other
			end
		end
	end
	return driver, if driver then nearest else nil
end

local function resolveQueueSpacing(state: DriverState, edge: any, cum: { number }, dt: number)
	-- Backing up moves a car along its lane; mid lane change it is on neither centreline.
	if state.connector then return end
	local lead, gap = getNearestQueueLeader(state)
	local minGap = followGap(state, lead)
	if not gap or gap >= minGap then
		return
	end

	local backup = math.min(minGap - gap, UNSTUCK_BACKUP_RATE * dt)
	-- Never reverse into the car behind us -- and its own length decides how close that is.
	local trailer, trailing = getNearestTrailing(state)
	if trailer and trailing then
		backup = math.min(backup, math.max(0, trailing - followGap(trailer, state)))
	end
	if backup <= 1e-4 then
		return
	end

	local oldDist = state.edgeDist
	state.edgeDist = math.max(0, state.edgeDist - backup)
	if state.edgeDist < oldDist - 1e-4 then
		state.currentSpeed = 0
		local pos, dir = PathFollower.pointAtDist(edge.points, cum, state.edgeDist)
		PathFollower.place(state, pos, dir, dt)
	end
end

local function getQueueSpeedFactor(nearestGap: number?, currentSpeed: number, minGap: number): number
	if not nearestGap then
		return 1
	end
	if nearestGap <= minGap then
		return 0
	end

	local lookahead = math.max(FOLLOW_LOOKAHEAD, currentSpeed * 0.8)
	if nearestGap >= lookahead then
		return 1
	end

	local t = (nearestGap - minGap) / math.max(lookahead - minGap, 1)
	return math.clamp(t * t, 0, 1)
end

-- Vehicle half-length (centre to nose), read from its Hitbox so long trucks stop the
-- same distance before the line as short cars instead of overrunning it.
local function vehicleHalfLength(model: Model): number
	local hb = model:FindFirstChild("Hitbox")
	if hb and hb:IsA("BasePart") then
		return math.max(hb.Size.X, hb.Size.Z) * 0.5
	end
	local sz = model:GetExtentsSize()
	return math.max(sz.X, sz.Z) * 0.5
end

-- A DIRECTED car that leaves at the map edge did not arrive -- it lost its route on the
-- way (getPendingNextEdgeId falls through to the roamer pick when the route's next edge
-- is not an exit of the lane the car is on). Letting it leave is right; being NOISY about
-- it is how the desync itself stays visible. Silence is the normal state.
local _lostRouteExits = 0
local _lastLostRouteWarn = 0
local LOST_ROUTE_WARN_INTERVAL = 60

-- == Mid-block lane changes ====================================================
-- NavRouter plans a step onto a neighbouring lane of the same road wherever the lane line
-- is dashed. The driver makes it as soon as the window opens (just past the last junction)
-- and the target lane has room, so it is lined up for its turn long before the stop line
-- instead of swerving across at the last second. With no gap it holds at the end of the
-- window. Room is never faked: waiting trims only the speed margin a car leaves, never the
-- car length it needs. The target lane makes the room instead -- the first car behind a
-- waiting merger that can still stop does, and lets it in (a zipper).
local LANE_CHANGE_TIME = 2.2      -- s a move-over takes at cruise speed (sets its length)
local LANE_CHANGE_KEEP_SPEED = 0.9 -- a move whose bend cap is below this share of the car's speed is too short to start
local LANE_CHANGE_HOLD_SPEED = 16 * WS -- studs/s: on a highway, faster than this a car out of window re-plans instead of stopping
local LANE_CHANGE_PATIENCE = 8    -- s of waiting over which the speed margin shrinks to its floor
local LANE_CHANGE_REPLAN = 20     -- s trying with no gap at all before re-planning from this lane
local MERGE_COURTESY_WAIT = 1     -- s a merger waits before the lane beside it makes room
local MERGE_ROOM = 1              -- studs past a follow gap a yielding car leaves, so the merger's check passes
local SWAP_PULL_UP_MAX = 14       -- studs past the window end a swap winner may pull up (lands <= 7 into the solid zone)

-- The route's next step when it is a lane change on this road: target lane plus the stretch
-- of this lane over which the move may start. nil when the next step is a junction.
local function routeLaneChange(g: any, state: DriverState, edge: any): (string?, number, number)
	local route = state.route
	if not route then return nil, 0, 0 end
	local nextId = route[(state.routeIndex or 1) + 1]
	if not nextId then return nil, 0, 0 end
	local earliest, latest = g:GetLaneChangeWindow(edge.id, nextId)
	if not earliest or not latest then return nil, 0, 0 end
	return nextId, earliest, latest
end

-- Room on the target lane between [d0, d1] (our start and landing distances): nobody from a
-- follow gap plus a speed margin behind us to a follow gap past where we land, nobody mid-move
-- through that stretch, nobody turning into it. Second return: a blocker that is itself
-- waiting for OUR lane -- a swap, which only the tie-break in waitForMerge can undo.
local function laneChangeGapClear(state: DriverState, targetId: string, d0: number, d1: number): (boolean, DriverState?)
	local squeeze = math.max(0.35, 1 - (state.laneChangeWait or 0) / LANE_CHANGE_PATIENCE)
	local clear = true
	for _, other in _edgeDriverIndex[targetId] or {} do
		if other ~= state and other.model.Parent then
			local p = lanePos(other, targetId)
			local behind = followGap(other, state) + (other.currentSpeed or 0) * 1.2 * squeeze
			if p > d0 - behind and p < d1 + followGap(state, other) then
				if other.mergeInto == state.edgeId then return false, other end
				clear = false
			end
		end
	end
	if not clear then return false, nil end
	for _, other in _laneChangeIndex[targetId] or {} do
		if other ~= state and other.model.Parent and laneChangeOf(other) then
			local p = lanePos(other, targetId)
			if p > d0 - followGap(other, state) and p < d1 + followGap(state, other) then
				return false, nil
			end
		end
	end
	for _, other in _connectorByNextEdgeIndex[targetId] or {} do
		if other ~= state and other.model.Parent
			and math.abs(other.nextEdgeDist - d1) < (d1 - d0) + followGap(state, other) then
			return false, nil
		end
	end
	return true, nil
end

-- Third return: true when what is left of this road piece is too short to move over at the
-- car's speed -- the squeezed ribbon's bend cap would brake it across both lanes. That is a
-- geometry refusal, not a missing gap, so the lane beside is not asked to make room.
local function tryStartLaneChange(g: any, state: DriverState, edge: any, targetId: string, latest: number): (boolean, DriverState?, boolean)
	local target = g:GetEdge(targetId)
	if not target then return false, nil, false end
	local minLength = g.LANE_CHANGE_MIN_LENGTH or 14
	local fromCum = PathFollower.getCum(edge)
	local toCum = PathFollower.getCum(target)
	-- Land no nearer the junction than the window's own shortest move would.
	local margin = math.max(0, fromCum[#fromCum] - latest - minLength)
	local d0 = state.edgeDist
	local length = math.max(minLength, (state.currentSpeed or 0) * LANE_CHANGE_TIME)
	-- A car held past the window end (swap winner, re-plan) still gets the shortest move.
	local shortest = d0 + minLength * 0.5
	local d1 = math.clamp(d0 + length, shortest, math.max(shortest, toCum[#toCum] - margin))
	local pts = g:GetLaneChangeRibbon(edge.id, targetId, d0, d1)
	local cap = connectorSpeedCap(pts)
	if cap and cap < (state.currentSpeed or 0) * LANE_CHANGE_KEEP_SPEED then
		return false, nil, true
	end
	local clear, swapWith = laneChangeGapClear(state, targetId, d0, d1)
	if not clear then return false, swapWith, false end
	startConnector(state, pts, targetId, d1)
	state.laneChange = if state.connector == pts
		then { pts = pts, from = edge.id, to = targetId, d0 = d0, d1 = d1 }
		else nil
	state.laneChangeWait = 0
	state.mergeInto = nil
	state.mergeHoldAt = nil
	tagCarInfo(state, "ChangingLane", targetId)
	return true, nil, false
end

-- Too little of this piece left to move over at speed: make the move on the next piece of
-- the road instead, from the start of its window, the way a driver who missed the gap tries
-- again further on. Only when the route carries on along the target lane onto a next piece
-- this lane also feeds, and that piece allows the same move. The route is copied, never
-- edited in place: a caller may hold the table it passed to DriveDirected.
local function deferLaneChange(g: any, state: DriverState, edge: any, targetId: string): boolean
	local route = state.route
	local i = state.routeIndex or 1
	if not route or route[i + 1] ~= targetId then return false end
	local afterId = route[i + 2]
	local after = if afterId then g:GetEdge(afterId) else nil
	if not after or after.segmentId == edge.segmentId then return false end
	for _, outId in edge.out do
		local stay = g:GetEdge(outId)
		if stay and stay.segmentId == after.segmentId and stay.forward == after.forward
			and edgeAllows(stay, state.vehicleClass) and g:GetLaneChangeWindow(outId, afterId) then
			local deferred = table.clone(route)
			deferred[i + 1] = outId
			state.route = deferred
			state.pendingNextEdgeId = nil
			bookRoute(state)
			return true
		end
	end
	return false
end

-- A move refused this tick: count the wait, ask the lane beside to make room, and settle a
-- swap. Two cars side by side each waiting for the other's lane can never both go; the
-- tie-break winner pulls up past the other and merges in front of it, freeing the loser's gap.
local function waitForMerge(state: DriverState, targetId: string, latest: number, swapWith: DriverState?, dt: number)
	state.laneChangeWait = (state.laneChangeWait or 0) + dt
	if (state.laneChangeWait or 0) >= MERGE_COURTESY_WAIT then
		state.mergeInto = targetId
	end
	if swapWith and not swapWith.connector and goesFirst(state, swapWith) then
		state.mergeHoldAt = math.min(lanePos(swapWith, targetId) + followGap(state, swapWith) + MERGE_ROOM, latest + SWAP_PULL_UP_MAX)
	end
end

-- Zipper: the nearest car waiting to merge into this lane that we can still stop behind (a
-- follow gap or more ahead), as a stand-in leader held MERGE_ROOM short of it. One nearer
-- than that is passed; the car behind us lets it in.
local function getMergeCourtesy(state: DriverState): (DriverState?, number?)
	if state.connector then return nil, nil end
	local merger: DriverState? = nil
	local best = math.huge
	for _, other in _laneChangeIndex[state.edgeId] or {} do
		if other ~= state and other.mergeInto == state.edgeId and not other.connector and other.model.Parent then
			local ahead = other.edgeDist - state.edgeDist
			if ahead >= followGap(state, other) and ahead < best then
				best = ahead
				merger = other
			end
		end
	end
	return merger, if merger then best - MERGE_ROOM else nil
end

-- == Per-vehicle tick ==========================================================
local function updateDriver(state: DriverState, dt: number)
	local g = nav()
	if not g or not state.model.Parent then return end

	local currentVersion = g:Version()
	if state.graphVersion ~= currentVersion then
		if _lastFlushedVersion ~= currentVersion then
			_lastFlushedVersion = currentVersion
			PathFollower.flushCache()
			clearGraphCaches()
		end
		-- ANY road edit bumps the GLOBAL graph version, even a road placed far away (the
		-- rebuild is incremental, so unrelated edges keep their ids). React only if THIS
		-- car's own road actually changed, so an unrelated placement doesn't disturb every
		-- car on the map.
		if state.connector and state.nextEdgeId and g:GetEdge(state.nextEdgeId) then
			-- Mid-turn and the landing edge survived: keep the arc.
			state.graphVersion = currentVersion
		elseif not state.connector and state.edgeId and g:GetEdge(state.edgeId) then
			-- Our current edge survived the edit: keep driving on it, just adopt the new
			-- version. Onward edges are re-derived as the car goes. Covers ambient AND
			-- directed cars whose own road was untouched, so an unrelated placement no
			-- longer resets every car on the map (the brief mid-road hitch on each edit).
			state.graphVersion = currentVersion
		elseif state.route then
			-- Directed car whose current edge (or mid-turn landing) vanished -- typically
			-- its road was replaced/upgraded under it. Re-plan from the nearest surviving
			-- lane to the same goal so it rejoins the new road instead of despawning the
			-- trip. Only abort if there is no lane in range or no path.
			if not tryReroute(state) then
				abortDirected(state)
				return
			end
		elseif not anchorToNearest(state) then
			-- Ambient roamer stranded by a deleted road: snap to the nearest lane, or
			-- despawn if nothing survived within range.
			return
		end
	end

	updateTrafficReroute(state, dt)

	-- Waiting at dead end
	if state.atDeadEnd then
		state.deadEndTimer -= dt
		if state.deadEndTimer > 0 then return end
		local edge = g:GetEdge(state.edgeId)
		if not edge then
			state.atDeadEnd = false
			return
		end
		local uEdge = getUTurnEdge(g, edge)
		if uEdge then
			-- Wait until the exit is clear so cars turn one at a time instead of
			-- piling on top of each other at the dead end. A jammed return lane is
			-- traffic: the dead end waits as long as it does.
			if not exitLaneHasRoom(g, state, uEdge.id) and not state.rescueFrom then
				state.blockedTime = (state.blockedTime or 0) + 0.25
				state.deadEndTimer = 0.25
				-- This branch skips the tick that records why the car is stopped; say it
				-- here, or the stall watchdog would take a jam for a fault.
				state.stopReason = "blocked"
				state.blockedBy = nil
				return
			end
			state.blockedTime = 0
			local connPts = buildUTurnArc(edge, uEdge)
			startConnector(state, connPts, uEdge.id, 0)
			tagCarInfo(state, "TurningAround", uEdge.id)
		elseif getNodeMeta(g, edge.toNode).isConnection then
			-- An outside connection is an EXIT, not a turnaround -- for every car, not just an
			-- ambient one. A directed car only reaches here having lost its route (it never hit
			-- its final edge), and this branch used to skip it: the `else` below snapped it to
			-- edgeDist 0, so it drove the same lane back out at the map edge, again, forever --
			-- the "cars teleport to the intersection and try to leave again" loop. Hand it back
			-- instead (through traffic despawns, a citizen's car parks where it stands).
			if state.route then
				_lostRouteExits += 1
				if os.clock() - _lastLostRouteWarn > LOST_ROUTE_WARN_INTERVAL then
					_lastLostRouteWarn = os.clock()
					warn(string.format("[NPCDriverService] %d directed cars left at the map edge without finishing their route -- route desync", _lostRouteExits))
					_lostRouteExits = 0
				end
				abortDirected(state)
			else
				despawnDriver(state)
			end
			return
		else
			state.edgeDist = 0
		end
		state.atDeadEnd    = false
		state.deadEndTimer = 0
		return
	end

	local carPos = getStatePosition(state)
	local carDir = if state.smoothCFrame then state.smoothCFrame.LookVector else Vector3.zAxis
	local currentSpeed = state.currentSpeed or state.speed
	local proximitySpeedFactor, forwardClearance, blockerDot, blocker =
		PathFollower.getMotionLimits(state.model, carPos, carDir)
	state.blockerDot = blockerDot
	state.blockedBy = if forwardClearance <= 0.5 then blocker else nil

	-- Check stopping requirements on the current edge ahead of execution
	local edge = g:GetEdge(state.edgeId)
	if edge and not state.connector then
		state.speed = driverSpeed(edge, state)
	end
	local mustStop = false
	local interReason: string? = nil
	local distToStop = 0
	local stopDist = 0

	if edge then
		local cum = PathFollower.getCum(edge)
		local total = cum[#cum]
		local nextId = if #edge.out > 0 then getPendingNextEdgeId(g, state, edge) else nil
		local gap = getStopLineGap(g, edge.toNode, edge)
		stopDist = math.max(0, total - gap - noseSetback(state))
		distToStop = stopDist - state.edgeDist

		-- Emergency preemption: an approaching emergency vehicle leases the signal
		-- green for its own arm. Refreshed every frame; lapses once it clears the box.
		if VehicleTypes.canPreempt(state.vehicleClass)
			and distToStop < TrafficConfig.PREEMPT_APPROACH_DIST
			and distToStop > -5
			and isSignalizedIntersection(edge.toNode) then
			TrafficSignalService.RequestEmergencyPreemption(edge.toNode, edge.id)
		end

		-- Only OUR approach being yellow lets us commit; a red arm must not move when
		-- the crossing group goes yellow.
		local isYellow = TrafficSignalService.IsApproachYellow(edge.id)
		local safeStoppingDistance = currentSpeed * 1.5
		local committed = (state.edgeDist > stopDist + 0.1) or (isYellow and distToStop < safeStoppingDistance)

		if nextId and not committed then
			local chosenNextId, canEnter = chooseEnterableNextEdgeId(g, state, edge, nextId)
			nextId = chosenNextId
			if not canEnter then
				mustStop = true
				-- blockedTime counts only time yielding (NOT at a red -- the light will
				-- change) so impatience can take a gap; stuckTime counts ALL waiting for the
				-- jam readouts; redTime counts one unbroken red, so only a broken signal
				-- (SIGNAL_FAULT_TIME) ever lets a car past a red.
				local atRed = isSignalizedIntersection(edge.toNode)
					and not TrafficSignalService.CanGo(edge.id, nextId)
				-- Only waiting AT the line counts: slowing for a car far ahead, or queueing
				-- behind the car at the line, is not a turn waited for.
				if distToStop > AT_LINE_DIST then
					state.blockedTime = 0
				elseif not atRed then
					if (state.blockedTime or 0) == 0 then state.waitSince = _simClock end
					state.blockedTime = (state.blockedTime or 0) + dt
				end
				state.stuckTime   = (state.stuckTime or 0) + dt
				state.redTime     = if atRed then (state.redTime or 0) + dt else 0
				interReason = if atRed then "redLight"
					elseif not isIntersectionNode(g, edge.toNode) and not (edge.outMovement and edge.outMovement[nextId] == "uturn") then "merge"
					elseif nextId and not exitLaneHasRoom(g, state, nextId) then "blocked"
					else "yield"
			else
				-- Allowed in. blockedTime is kept until the car is over the line (the branch
				-- below): zeroing it here, with the car still behind the line, took the turn
				-- straight back -- the move step asked again with no wait on the clock and
				-- the car stayed put, so a car whose turn had come never actually went.
				if distToStop > AT_LINE_DIST then state.blockedTime = 0 end
				state.stuckTime   = 0
				state.redTime     = 0
			end
		else
			state.blockedTime = 0
			state.stuckTime   = 0
			state.redTime     = 0
		end

		resolveQueueSpacing(state, edge, cum, dt)
		currentSpeed = state.currentSpeed or currentSpeed
	end

	-- A lane change the route wants next is tried every tick from the moment its window
	-- opens, moving or queued: a car stuck in its old lane still looks across for a gap.
	state.mergeInto = nil
	if edge and not state.connector then
		local lcTarget, lcEarliest, lcLatest = routeLaneChange(g, state, edge)
		if not lcTarget then
			state.laneChangeWait = 0
			state.mergeHoldAt = nil
		elseif state.edgeDist >= lcEarliest then
			local started, swapWith, tooShort = tryStartLaneChange(g, state, edge, lcTarget, lcLatest)
			if tooShort then
				-- Keep cruising in lane: move over on the next piece, or (if this was the
				-- last chance) re-plan at the window end -- see the hold in the move loop.
				deferLaneChange(g, state, edge, lcTarget)
			elseif not started then
				waitForMerge(state, lcTarget, lcLatest, swapWith, dt)
				if (state.laneChangeWait or 0) > LANE_CHANGE_REPLAN then
					state.laneChangeWait = 0
					state.mergeHoldAt = nil
					tryReroute(state)
					return
				end
			end
		end
	end

	local queueLead, queueGap = getNearestQueueLeader(state)
	local merger, mergeGap = getMergeCourtesy(state)
	if mergeGap and (not queueGap or mergeGap < queueGap) then
		queueLead, queueGap = merger, mergeGap
	end
	local queueMinGap = followGap(state, queueLead)
	local queueSpeedFactor = getQueueSpeedFactor(queueGap, currentSpeed, queueMinGap)
	local speedFactor = math.min(proximitySpeedFactor, queueSpeedFactor)

	-- debug: classify WHY this car is at its current speed (in-memory only, read
	-- by GetSpeedDebug -- never a replicated attribute, no per-frame allocation).
	if queueSpeedFactor < 0.5 and queueSpeedFactor <= proximitySpeedFactor then
		state.stopReason = "carAhead"
	elseif interReason then
		state.stopReason = interReason
	elseif state.connector then
		state.stopReason = "turn"
	elseif proximitySpeedFactor < 0.6 then
		state.stopReason = "blocked"
	elseif edge and distToStop > -1 and distToStop < TURN_SLOW_ZONE and state.pendingNextEdgeId then
		state.stopReason = "turn"
	elseif speedFactor < 0.85 then
		state.stopReason = "slow"
	else
		state.stopReason = "cruise"
	end

	-- == Smoothed Target Speed Calculation (Processed ONCE per frame) ==
	local targetSpeed = state.speed * speedFactor
	if mustStop then
		-- FIX: Guard distToStop so that an NPC that is already past the stop
		-- line (distToStop < 0) is never forced to slow down. The old code let
		-- a negative distToStop feed into the quadratic, producing a small
		-- positive t² and an artificially low targetSpeed that stalled the car
		-- well in front of the line -- exactly the "stops way before the red
		-- light" bug.
		if distToStop > 0 then
			-- Only feather speed right at the stop line; cars should keep cruising
			-- until they are close enough to actually stop for the light.
			if distToStop <= STOP_DECEL_DISTANCE then
				local t = distToStop / STOP_DECEL_DISTANCE
				targetSpeed = targetSpeed * (t * t)
			end
		else
			-- Already at or past the stop line; committed -- don't impose any
			-- additional braking here (committed flag handles re-entry above).
			-- Setting targetSpeed = 0 here would cause jitter when mustStop flips.
			mustStop = false
		end
	end

	-- Slow into turns: a connector is capped by its tightest bend, and the
	-- approach eases down so the car arrives at a speed it can actually hold
	-- through the arc instead of whipping around the corner at road speed.
	if state.connector then
		if state.connSpeedCap then
			targetSpeed = math.min(targetSpeed, state.connSpeedCap)
		end
	elseif edge and distToStop > -1 and distToStop < TURN_SLOW_ZONE then
		local pendingId = state.pendingNextEdgeId
		local movement = if pendingId and edge.outMovement then edge.outMovement[pendingId] else nil
		local entrySpeed = if movement then TURN_ENTRY_SPEED[movement] else nil
		if entrySpeed and entrySpeed < targetSpeed then
			local t = math.clamp(distToStop / TURN_SLOW_ZONE, 0, 1)
			targetSpeed = entrySpeed + (targetSpeed - entrySpeed) * t
		end
	end

	-- Smoothly interpolate currentSpeed towards targetSpeed
	if currentSpeed < targetSpeed then
		currentSpeed = math.min(currentSpeed + ACCEL_RATE * dt, targetSpeed)
	else
		currentSpeed = math.max(currentSpeed - BRAKE_RATE * dt, targetSpeed)
	end
	state.currentSpeed = currentSpeed

	-- Calculate frame travel remaining (calculated ONCE per frame update to avoid speed compounding bug)
	local queueTravelLimit = if queueGap then math.max(0, queueGap - queueMinGap) else math.huge
	-- Hard spacing clamp against ALL nearby cars (other edges, mid-turn connectors,
	-- and the intersection box) -- not just same-edge queue mates. This is what
	-- stops cars clipping through each other while turning or crossing a junction.
	-- forwardClearance and blockerDot were produced with proximitySpeedFactor
	-- above, so the nearby-car buckets are queried only once per driver tick.

	-- Two cars blocking EACH OTHER (nose to nose at a dead-end U-turn bulb, or locked
	-- across each other in a box) can never clear by themselves, so after a short wait
	-- the tie-break winner creeps through and the other waits for it. Anything else in
	-- the way is traffic and holds us as long as it stands -- a car stuck in a jam in the
	-- box included. A rescued (bugged) car pushes through at once. Stop lines stay
	-- respected: this only lifts the proximity clamp, never the red-light/yield limit.
	local blockerState = if state.blockedBy then _drivers[state.blockedBy] else nil
	local standoffWinner = blockerState ~= nil and inMutualStandoff(state) and goesFirst(state, blockerState)
	if state.blockedBy and (standoffWinner or state.rescueFrom) then
		state.connBlockedTime = (state.connBlockedTime or 0) + dt
		if state.rescueFrom or state.connBlockedTime >= CONNECTOR_STANDOFF_ESCAPE then
			forwardClearance = math.huge
			currentSpeed = math.max(currentSpeed, MIN_TURN_SPEED * 0.5)
			state.currentSpeed = currentSpeed
		end
	else
		state.connBlockedTime = 0
	end

	local remaining = math.min(currentSpeed * dt, queueTravelLimit, forwardClearance)

	local remainingSteps = MAX_STEPS
	for _ = 1, remainingSteps do
		if remaining <= 1e-4 then break end

		-- Travelling a connector arc
		if state.connector then
			local pts = state.connector :: { Vector3 }
			local connCum: { number } = state.connCum or (function()
				local c: { number } = table.create(#pts, 0)
				c[1] = 0
				for i = 2, #pts do c[i] = c[i-1] + (pts[i] - pts[i-1]).Magnitude end
				state.connCum = c
				return c
			end)()
			local totalConn = connCum[#connCum] or 0

			if #pts < 2 or totalConn < 1e-4 then
				local landed0 = state.nextEdgeId :: string
				state.connector    = nil
				state.connCum      = nil
				state.connDist     = 0
				state.connSpeedCap = nil
				state.connBlockedTime = 0
				state.edgeId       = landed0
				state.edgeDist     = 0
				state.nextEdgeId   = nil
				state.nextEdgeDist = 0
				if state.route and state.routeIndex and state.route[state.routeIndex + 1] == landed0 then
					state.routeIndex += 1
				end
				continue
			end

			local move = math.min(remaining, totalConn - state.connDist)
			state.connDist += move
			remaining -= move

			local pos, dir = PathFollower.pointAtDist(pts, connCum, state.connDist)
			PathFollower.place(state, pos, dir, dt)

			if state.connDist >= totalConn - 1e-4 then
				-- Connector done -- land on the next edge
				local landedEdge    = state.nextEdgeId :: string
				state.connector     = nil
				state.connCum       = nil
				state.connDist      = 0
				state.connSpeedCap  = nil
				state.connBlockedTime = 0
				state.edgeId        = landedEdge
				state.edgeDist      = state.nextEdgeDist
				state.nextEdgeId    = nil
				state.nextEdgeDist  = 0
				if state.route and state.routeIndex and state.route[state.routeIndex + 1] == landedEdge then
					state.routeIndex += 1
				end
				tagCarInfo(state, "Cruising", landedEdge)
				break
			end
			continue
		end

		-- Normal edge travel
		local currentEdge = g:GetEdge(state.edgeId)
		if not currentEdge then
			-- Edge under us vanished: a directed car hands back (keeps the trip contract);
			-- an ambient roamer re-anchors to the nearest lane or despawns.
			if state.route then abortDirected(state) else anchorToNearest(state) end
			break
		end

		local cum    = PathFollower.getCum(currentEdge)
		local total  = cum[#cum]

		-- Directed arrival: on the LAST route edge, ease to the lot-entry distance,
		-- stop, hand the car back (onArrive), and leave the driver pool so the caller
		-- runs the off-graph pull-in. Done before any junction logic.
		if state.route and not state.arrived and (state.routeIndex or 1) >= #state.route then
			local arriveDist = math.clamp(state.finalDist or total, 0, total)
			local astep = math.min(remaining, math.max(0, arriveDist - state.edgeDist))
			state.edgeDist += astep
			remaining = 0
			local apos, adir = PathFollower.pointAtDist(currentEdge.points, cum, state.edgeDist)
			PathFollower.place(state, apos, adir, dt)
			if state.edgeDist >= arriveDist - 0.5 then
				state.arrived = true
				state.currentSpeed = 0
				local cb = state.onArrive
				state.onArrive = nil
				-- Trip over: hand the corridor back so it stops deterring other drivers.
				releaseBooking(state)
				clearDirectedDebugTag(state)
				_drivers[state.model] = nil
				-- Near cars move on the pose stream, not the instance, so leave the model
				-- standing where it actually stopped: the owner's next leg starts from here.
				local stopped = state.smoothCFrame
				local root = state.model.PrimaryPart
				if stopped and root then root.CFrame = stopped elseif stopped then state.model:PivotTo(stopped) end
				PathFollower.forget(state.model)
				if cb then task.spawn(cb) end
			end
			break
		end

		-- Lane change pending (tried before the move, above): drive on and hold at the end of
		-- the window until it starts. On a highway a car still at speed there does not stop
		-- dead: it keeps its lane and re-plans, like a driver who missed the exit. On a city
		-- street it holds for the gap, as a driver waiting to get into a turn lane does.
		-- Once per lane edge, so a re-plan that still wants this move falls back to the hold.
		local lcTarget, _, lcLatest = routeLaneChange(g, state, currentEdge)
		if lcTarget then
			local holdAt = math.max(lcLatest, state.mergeHoldAt or 0, state.edgeDist)
			local lcMove = math.min(remaining, holdAt - state.edgeDist)
			state.edgeDist += lcMove
			remaining -= lcMove
			local lcPos, lcDir = PathFollower.pointAtDist(currentEdge.points, cum, state.edgeDist)
			PathFollower.place(state, lcPos, lcDir, dt)
			if state.edgeDist >= holdAt - 1e-4 then
				if currentEdge.roadClass == "highway" and (state.currentSpeed or 0) > LANE_CHANGE_HOLD_SPEED
					and state.laneChangeMissed ~= currentEdge.id then
					state.laneChangeMissed = currentEdge.id
					if tryReroute(state) then break end
				end
				state.currentSpeed = 0
				state.stopReason = "laneChange"
				break
			end
			if lcMove <= 1e-4 then break end
			continue
		end

		local nextId = if #currentEdge.out > 0 then getPendingNextEdgeId(g, state, currentEdge) else nil
		local gap = getStopLineGap(g, currentEdge.toNode, currentEdge)
		local stopDistVal = math.max(0, total - gap - noseSetback(state))

		-- Recheck stopping on current step
		local isYellow = TrafficSignalService.IsApproachYellow(currentEdge.id)
		local distToStopVal = stopDistVal - state.edgeDist
		local safeStoppingDistance = currentSpeed * 1.5
		local committed = (state.edgeDist > stopDistVal + 0.1) or (isYellow and distToStopVal < safeStoppingDistance)

		local loopMustStop = false
		if nextId and not committed then
			local chosenNextId, canEnter = chooseEnterableNextEdgeId(g, state, currentEdge, nextId)
			nextId = chosenNextId
			if not canEnter then
				loopMustStop = true
			end
		end

		if loopMustStop then
			if distToStopVal <= 1e-4 then
				state.edgeDist = stopDistVal
				state.currentSpeed = 0
			else
				local stepRemaining = math.min(remaining, distToStopVal)
				state.edgeDist += stepRemaining
				if stepRemaining >= distToStopVal - 1e-4 then
					state.edgeDist = stopDistVal
					state.currentSpeed = 0
				end
			end
			remaining = 0

			local pos, dir = PathFollower.pointAtDist(currentEdge.points, cum, state.edgeDist)
			PathFollower.place(state, pos, dir, dt)
			break
		end

		-- Normal forward travel. With an exit chosen, the edge effectively ends
		-- at the junction mouth: the connector takes over there, so cars turn on
		-- the junction surface instead of driving to the node centre first.
		local edgeEnd = total
		if nextId then
			local fromSetback = g:GetConnectionSetbacks(currentEdge.id, nextId)
			edgeEnd = math.max(0, total - fromSetback)
		end
		local move = math.min(remaining, math.max(0, edgeEnd - state.edgeDist))
		state.edgeDist += move
		remaining -= move

		local pos, dir = PathFollower.pointAtDist(currentEdge.points, cum, state.edgeDist)
		PathFollower.place(state, pos, dir, dt)

		if state.edgeDist >= edgeEnd - 1e-4 then
			if nextId then
				local nextEdge = g:GetEdge(nextId)
				if nextEdge and (committed or canEnterIntersection(g, state, currentEdge, nextId)) then
					local connPts, _, resumeDist = g:GetConnectionPoints(currentEdge.id, nextId)
					startConnector(state, connPts, nextId, resumeDist)
					tagCarInfo(state, "Cruising", nextId)
					break
				else
					-- Keep stopped cleanly behind the stop line (never snap forward
					-- past the mouth if the stop line sits beyond it).
					state.edgeDist = math.min(stopDistVal, state.edgeDist)
					state.currentSpeed = 0
					local pos2, dir2 = PathFollower.pointAtDist(currentEdge.points, cum, state.edgeDist)
					PathFollower.place(state, pos2, dir2, dt)
					break
				end
			else
				-- DEAD END
				state.atDeadEnd    = true
				state.deadEndTimer = DEAD_END_WAIT
				state.pendingNextEdgeId = nil
				state.currentSpeed = 0
				tagCarInfo(state, "Stopped", nil)
				break
			end
		end

		if move <= 1e-4 then break end
	end
end

-- == Car builder ===============================================================
-- VehicleFactory is the ONE place a vehicle is cloned, sized and welded. This was a
-- second copy of that assembly which never scaled at all, so ambient traffic spawned
-- at raw authored scale -- ~2x every other vehicle in the half-scale world, and wider
-- than the lane it drove in. Keep the delegation: a car built anywhere else drifts.
local function buildCar(name: string, colorIdx: number): Model
	return VehicleFactory.build(name, colorIdx)
end

-- == Spawning ==================================================================
local function ensureFolder(): Folder
	local cityFolder = Workspace:FindFirstChild("_City")
	if not cityFolder then
		cityFolder = Instance.new("Folder")
		cityFolder.Name = "_City"
		cityFolder.Parent = Workspace
	end
	local f = cityFolder:FindFirstChild("NPCDrivers")
	if not f then
		f = Instance.new("Folder")
		f.Name   = "NPCDrivers"
		f.Parent = cityFolder
	end
	return f :: Folder
end

local function clearOld(folder: Folder)
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") and CollectionService:HasTag(child, TAG) then
			PathFollower.forget(child :: Model)
			child:Destroy()
		end
	end
end

local function placeOnEdge(model: Model, edge: any, frac: number)
	local pts = edge.points
	if #pts < 2 then return end
	local totalLen = 0
	for i = 2, #pts do totalLen += (pts[i] - pts[i-1]).Magnitude end
	local target = totalLen * frac
	local dist = 0
	for i = 2, #pts do
		local seg = (pts[i] - pts[i-1]).Magnitude
		if dist + seg >= target then
			local alpha = if seg > 1e-6 then (target - dist) / seg else 0
			local pos   = pts[i-1]:Lerp(pts[i], alpha)
			local dir   = (pts[i] - pts[i-1])
			local flat  = Vector3.new(dir.X, 0, dir.Z)
			if flat.Magnitude < 1e-6 then flat = Vector3.zAxis end
			local up = pos + Vector3.new(0, 0.6, 0)
			model:PivotTo(CFrame.lookAt(up, up + flat.Unit))
			return
		end
		dist += seg
	end
end

local function trySpawn(): boolean
	if Workspace:GetAttribute("RandomTrafficEnabled") == false then return true end

	local configuredCount = Workspace:GetAttribute("AmbientTrafficCount")
	local targetCount = NPC_COUNT
	if typeof(configuredCount) == "number" then
		targetCount = math.clamp(math.floor(configuredCount), 0, MAX_AMBIENT_TRAFFIC)
	end
	if targetCount <= 0 then return true end

	local g = nav()
	if not g or not g:HasEdges() then return false end
	local edges = g:GetEdges()
	if #edges == 0 then return false end

	local folder = ensureFolder()
	clearOld(folder)
	-- Drop only AMBIENT driver states here. Directed (citizen/delivery) cars live in a
	-- separate folder and must keep their state so their onArrive/onAbort contract holds
	-- (a bare table.clear froze them mid-trip and leaked the directed-car count).
	for model, state in pairs(_drivers) do
		if not state.route then _drivers[model] = nil end
	end
	PathFollower.flushCache()

	-- Minimum studs between any two cars on the same edge at spawn.
	local MIN_SPAWN_GAP = 12

	type Slot = { edgeId: string, dist: number, edge: any }
	local slots: { Slot } = {}

	for _, edge in ipairs(edges) do
		local pts = edge.points
		local totalLen = 0
		for i = 2, #pts do totalLen += (pts[i] - pts[i-1]).Magnitude end
		if totalLen < MIN_SPAWN_GAP then continue end

		local d = MIN_SPAWN_GAP * 0.5
		while d + MIN_SPAWN_GAP * 0.5 <= totalLen do
			table.insert(slots, { edgeId = edge.id, dist = d, edge = edge })
			d += MIN_SPAWN_GAP
		end
	end

	if #slots == 0 then
		for _, edge in ipairs(edges) do
			local pts = edge.points
			local totalLen = 0
			for i = 2, #pts do totalLen += (pts[i] - pts[i-1]).Magnitude end
			table.insert(slots, { edgeId = edge.id, dist = totalLen * 0.5, edge = edge })
		end
	end

	-- Shuffle slots
	for i = #slots, 2, -1 do
		local j = math.random(1, i)
		slots[i], slots[j] = slots[j], slots[i]
	end

	-- Spawn up to the requested ambient count.
	local count = math.min(targetCount, #slots)
	for i = 1, count do
		local slot = slots[i]
		local edge = slot.edge

		local car = buildCar("NPCDriver_" .. i, i)
		car.Parent = folder
		CollectionService:AddTag(car, TAG)
		CollectionService:AddTag(car, VehicleTypes.tagFor(VehicleTypes.Car))

		-- Ambient roamers get a mind too: they are the background traffic the routed
		-- cars have to share the road with, so they must not all drive identically.
		local profile = DriverProfile.fromModel(car)
		local spd = edgeSpeed(edge) * (if profile then profile.speedFactor else 1)
		local hgt = car:GetAttribute("NPCHeightOffset") or 0.6
		car:SetAttribute("NPCSpeed", math.round(spd))  -- debug readout (DebugService)

		local pts = edge.points
		local totalLen = 0
		for j = 2, #pts do totalLen += (pts[j] - pts[j-1]).Magnitude end
		local frac = math.clamp(slot.dist / math.max(totalLen, 1), 0, 1)
		placeOnEdge(car, edge, frac)

		local state = {
			model          = car,
			vehicleClass   = VehicleTypes.Car,
			profile        = profile,
			edgeId         = slot.edgeId,
			edgeDist       = slot.dist,
			graphVersion   = g:Version(),
			connector      = nil,
			connCum        = nil,
			connDist       = 0,
			nextEdgeId     = nil,
			nextEdgeDist   = 0,
			pendingNextEdgeId = nil,
			atDeadEnd      = false,
			deadEndTimer   = 0,
			speed          = spd,
			currentSpeed   = spd, -- Start spawned cars smoothly matching their target cruising speed
			blockedTime    = 0,
			stuckTime      = 0,
			connBlockedTime = 0,
			heightOffset   = hgt + LANE_SURFACE,
			halfLength     = vehicleHalfLength(car),
			smoothCFrame   = nil,
			lastSentCFrame = nil,
			replicateAccum = 0,
		}
		_drivers[car] = state

		local cum: { number } = table.create(#pts, 0)
		cum[1] = 0
		for j = 2, #pts do cum[j] = cum[j-1] + (pts[j] - pts[j-1]).Magnitude end
		local spawnPos, spawnDir = PathFollower.pointAtDist(pts, cum, slot.dist)
		local flat = Vector3.new(spawnDir.X, 0, spawnDir.Z)
		if flat.Magnitude < 1e-6 then flat = Vector3.zAxis end
		local cf = CFrame.lookAt(spawnPos + Vector3.new(0, hgt, 0), spawnPos + Vector3.new(0, hgt, 0) + flat.Unit)
		state.smoothCFrame   = cf
		state.lastSentCFrame = cf

		tagCarInfo(state, "Cruising", slot.edgeId)
		PathFollower.seedProximity(car, (i - 1) * (PathFollower.PROXIMITY_CHECK_DT / math.max(count, 1)))
	end

	return true
end

-- == Public API ================================================================

-- Directed trip: drive `model` along `route` (ordered lane-edge ids -- the 2nd
-- return of RoadNavigationGraph:FindPath) using the FULL traffic AI (correct lane,
-- stop lines, signals, yielding, no overlap). Seats the car at the point on the
-- first edge nearest `startPos`; stops at the point on the last edge nearest
-- `goalPos`, fires `onArrive`, then leaves the driver pool so the caller can run
-- the off-graph lot pull-in. Fires `onAbort` if the route can't be followed.
-- Returns true if the trip started.
-- `exactStartDist` seats the car at a KNOWN distance along route[1] instead of projecting
-- startPos onto it. Only a caller restoring a saved vehicle has that number (it saved the
-- car's own edgeDist), and using it keeps a reloaded queue in exactly the order and
-- spacing it was saved in rather than one re-derived from rounded world positions.
function NPCDriverService.DriveDirected(model: Model, startPos: Vector3, goalPos: Vector3, route: { string }, onArrive: (() -> ())?, onAbort: (() -> ())?, exactStartDist: number?): boolean
	local g = nav()
	if not g or not g:HasEdges() or typeof(route) ~= "table" or #route == 0 then return false end
	local firstEdge = g:GetEdge(route[1])
	local lastEdge = g:GetEdge(route[#route])
	if not firstEdge or not lastEdge then return false end

	local startDist
	if typeof(exactStartDist) == "number" and exactStartDist == exactStartDist then
		startDist = math.clamp(exactStartDist, 0, firstEdge.length or exactStartDist)
	else
		startDist = distAlongEdgeNearest(firstEdge, startPos)
	end
	local finalDist = distAlongEdgeNearest(lastEdge, goalPos)
	if #route == 1 and finalDist < startDist then finalDist = startDist end

	local hgt = model:GetAttribute("NPCHeightOffset")
	local addedDebugTag = false
	if not CollectionService:HasTag(model, TAG) then
		CollectionService:AddTag(model, TAG)
		addedDebugTag = true
	end
	ensureDebugId(model)
	if typeof(hgt) ~= "number" then
		local _, sz = model:GetBoundingBox()
		hgt = sz.Y * 0.5 + 0.05
		model:SetAttribute("NPCHeightOffset", hgt)
	end

	-- The vehicle's own mind, stamped on the model so it survives the hand-offs
	-- between CitizenService and this service and stays the same car's personality.
	_nextBookingToken += 1
	local bookingToken = _nextBookingToken
	local profile = DriverProfile.withToken(DriverProfile.fromModel(model), bookingToken)

	local state: DriverState = {
		model          = model,
		-- Tagged by whoever built it (bus / emergency / train); untagged models read as Car.
		vehicleClass   = VehicleTypes.classOf(model),
		profile        = profile,
		bookingToken   = bookingToken,
		edgeId         = route[1],
		edgeDist       = startDist,
		graphVersion   = g:Version(),
		connector      = nil,
		connCum        = nil,
		connDist       = 0,
		nextEdgeId     = nil,
		nextEdgeDist   = 0,
		pendingNextEdgeId = nil,
		atDeadEnd      = false,
		deadEndTimer   = 0,
		speed          = edgeSpeed(firstEdge) * (if profile then profile.speedFactor else 1),
		currentSpeed   = 0,
		blockedTime    = 0,
		stuckTime      = 0,
		connBlockedTime = 0,
		heightOffset   = (hgt :: number) + LANE_SURFACE,
		halfLength     = vehicleHalfLength(model),
		smoothCFrame   = nil,
		lastSentCFrame = nil,
		replicateAccum = 0,
		debugTagAdded  = addedDebugTag,
		route          = route,
		routeIndex     = 1,
		goalPos        = goalPos,
		finalDist      = finalDist,
		onArrive       = onArrive,
		onAbort        = onAbort,
		arrived        = false,
		trafficJamTime = 0,
		nextTrafficRerouteAt = os.clock() + TRAFFIC_REROUTE_COOLDOWN,
		trafficReroutes = 0,
		lastTrafficRerouteAt = nil,
		lastTrafficAbandonedNextEdgeId = nil,
	}
	_drivers[model] = state
	-- Stake this route out so every driver planning after us can see it is taken.
	bookRoute(state)
	tagCarInfo(state, "Directed", route[1])
	PathFollower.seedProximity(model, 0)
	return true
end

local function flatDistSq(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return dx * dx + dz * dz
end

local function pointOnEdge(edge: any, frac: number): Vector3?
	local pts = edge.points
	if typeof(pts) ~= "table" or #pts < 2 then
		return nil
	end
	local cum = PathFollower.getCum(edge)
	local total = cum[#cum] or 0
	if total <= 0 then
		return pts[1]
	end
	local pos = PathFollower.pointAtDist(pts, cum, math.clamp(total * frac, 0, total))
	return pos
end

function NPCDriverService.SpawnTestCarsNear(center: Vector3?, count: number?, radius: number?): { [string]: any }
	local g = nav()
	if not g or not g:HasEdges() then
		return { ok = false, error = "No roads are loaded." }
	end

	local requested = math.clamp(math.floor((tonumber(count) or ADMIN_TEST_CAR_DEFAULT_COUNT) + 0.5), 1, ADMIN_TEST_CAR_MAX_COUNT)
	local r = math.clamp(math.floor((tonumber(radius) or ADMIN_TEST_CAR_DEFAULT_RADIUS) + 0.5), 40, 1500)
	local radiusSq = r * r

	type TestSlot = { edge: any, frac: number, pos: Vector3, score: number }
	local nearSlots: { TestSlot } = {}
	local fallbackSlots: { TestSlot } = {}
	local goalEdges: { any } = {}

	for _, edge in ipairs(g:GetEdges()) do
		if not edge or not edgeAllows(edge, VehicleTypes.Car) then
			continue
		end
		local pts = edge.points
		if typeof(pts) ~= "table" or #pts < 2 then
			continue
		end
		table.insert(goalEdges, edge)
		for _, frac in ipairs(TEST_SPAWN_FRACTIONS) do
			local pos = pointOnEdge(edge, frac)
			if not pos then
				continue
			end
			local score = if center then flatDistSq(pos, center) else #nearSlots
			local slot = { edge = edge, frac = frac, pos = pos, score = score }
			if center and score > radiusSq then
				table.insert(fallbackSlots, slot)
			else
				table.insert(nearSlots, slot)
			end
		end
	end

	local slots = nearSlots
	if #slots == 0 then
		slots = fallbackSlots
	end
	table.sort(slots, function(a: TestSlot, b: TestSlot)
		return a.score < b.score
	end)

	if #slots == 0 or #goalEdges == 0 then
		return { ok = false, error = "No usable car lanes were found.", spawned = 0, requested = requested }
	end

	local function findGoal(startPos: Vector3, ordinal: number): (Vector3?, { string }?)
		local edgeCount = #goalEdges
		local attempts = math.min(edgeCount, 10)
		for attempt = 1, attempts do
			local goalEdge = goalEdges[((ordinal * 17 + attempt * 31) % edgeCount) + 1]
			local goal = pointOnEdge(goalEdge, 0.82)
			if goal and flatDistSq(startPos, goal) >= 1600 then
				local ok, _, route = pcall(function()
					return g:FindPath(startPos, goal)
				end)
				if ok and typeof(route) == "table" and #route > 0 then
					return goal, route :: { string }
				end
			end
		end
		return nil, nil
	end

	local folder = ensureFolder()
	local spawned = 0
	for i, slot in ipairs(slots) do
		if spawned >= requested then
			break
		end
		local goal, route = findGoal(slot.pos, i + spawned)
		if not goal or not route then
			continue
		end

		local car = buildCar("AdminTestCar_" .. tostring(math.floor(os.clock() * 1000)) .. "_" .. tostring(i), i)
		car:SetAttribute("AdminTestCar", true)
		placeOnEdge(car, slot.edge, slot.frac)
		car.Parent = folder
		CollectionService:AddTag(car, TAG)
		CollectionService:AddTag(car, VehicleTypes.tagFor(VehicleTypes.Car))

		local function cleanup()
			if car.Parent then
				car:Destroy()
			end
		end

		if NPCDriverService.DriveDirected(car, slot.pos, goal, route, cleanup, cleanup) then
			spawned += 1
		else
			car:Destroy()
		end
	end

	return {
		ok = spawned > 0,
		spawned = spawned,
		requested = requested,
		candidates = #slots,
		radius = r,
		fallback = #nearSlots == 0,
	}
end

-- Silently drop a directed car from the driver pool WITHOUT firing onArrive/onAbort
-- (the caller is destroying it / taking it over). Returns true if it was directed.
function NPCDriverService.ReleaseDirected(model: Model): boolean
	local state = _drivers[model]
	if state and state.route then
		releaseBooking(state)
		clearDirectedDebugTag(state)
		_drivers[model] = nil
		PathFollower.forget(model)
		return true
	end
	return false
end

function NPCDriverService.IsDirected(model: Model): boolean
	local state = _drivers[model]
	return state ~= nil and state.route ~= nil
end

-- Whether `model` is driving on the traffic AI right now (any trip, or an ambient roamer).
function NPCDriverService.IsOnRoad(model: Model): boolean
	return _drivers[model] ~= nil
end

-- Is any vehicle within `radius` studs of `pos`? PathFollower streams a near car's pose to
-- the clients and STOPS writing its instance CFrame, so a workspace overlap query sees the
-- car parked on the spawn point it left minutes ago -- which is why every outside connection
-- read as jammed with stalled cars while those cars were visibly driving. Driver state is
-- the only live position the server has, so spawn gates must ask here, not the world.
-- ponytail: linear scan of active drivers; called a few times a second at spawn gates, not
-- per frame. Bucket by nav cell if the fleet ever makes it show up in a profile.
-- Moving heavy vehicles and how loud each one is, for CoverageService's traffic-noise layer.
-- A full-size truck is the loudest thing on the road (one heavy truck ~ 10-30 cars in the
-- FHWA Traffic Noise Model), a van a fraction of that, a bus in between. Cars are left out:
-- stamping thousands of them would cost far more than their faint share tells.
local NOISE_CLASS_WEIGHT = table.freeze({ [VehicleTypes.Truck] = 1, [VehicleTypes.Bus] = 0.6 })
local NOISE_FULL_HALF_LENGTH = 12 -- studs: a vehicle this long or longer is full-size

function NPCDriverService.GetNoiseSources(): { { pos: Vector3, weight: number } }
	local out = {}
	for model, state in _drivers do
		local w = NOISE_CLASS_WEIGHT[state.vehicleClass]
		if w and model.Parent and (state.currentSpeed or 0) > 1 then
			local size = math.clamp((state.halfLength or NOISE_FULL_HALF_LENGTH) / NOISE_FULL_HALF_LENGTH, 0.25, 1)
			table.insert(out, { pos = getStatePosition(state), weight = w * size })
		end
	end
	return out
end

-- City vehicles (not intercity through traffic) on motorway lanes right now: the share of
-- the motorway ThroughTrafficService gives up to the people who live here.
function NPCDriverService.CountCityCarsOnHighways(): number
	local g = nav()
	if not g then return 0 end
	local n = 0
	for model, state in _drivers do
		if model.Parent and not state.connector and model:GetAttribute("Through") ~= true then
			local edge = g:GetEdge(state.edgeId)
			if edge and edge.roadClass == "highway" then n += 1 end
		end
	end
	return n
end

function NPCDriverService.IsPointClear(pos: Vector3, radius: number): boolean
	local r2 = radius * radius
	for model, state in _drivers do
		if not model.Parent then continue end
		local p = getStatePosition(state)
		local dx, dz = p.X - pos.X, p.Z - pos.Z
		if dx * dx + dz * dz < r2 then return false end
	end
	return true
end

-- The gap a driver waits for before pulling out of a driveway or turning across the
-- oncoming lanes into one: no vehicle on ANY lane of the road beside `pos` is alongside it or
-- will reach it within `seconds` at its current speed (cars still turning onto the road
-- count too). Both directions are checked, because the move may cross both.
function NPCDriverService.RoadGapClear(pos: Vector3, seconds: number): boolean
	local g = nav()
	if not g then return true end
	local nearest = g:NearestEdge(pos)
	if not nearest or nearest.distance > REANCHOR_MAX_DIST then return true end
	for _, edge in g:GetEdgesForSegment(nearest.edge.segmentId) do
		local at = distAlongEdgeNearest(edge, pos)
		for _, other in _edgeDriverIndex[edge.id] or {} do
			local body = (other.halfLength or FOLLOW_MIN_GAP * 0.5) + FOLLOW_BUMPER * 2
			local ahead = at - other.edgeDist
			if ahead > -body and ahead < (other.currentSpeed or 0) * seconds + body then
				return false
			end
		end
		for _, other in _connectorByNextEdgeIndex[edge.id] or {} do
			local ahead = at - other.nextEdgeDist
			if ahead > -FOLLOW_MIN_GAP and ahead < (other.currentSpeed or 0) * seconds + FOLLOW_LOOKAHEAD then
				return false
			end
		end
	end
	return true
end

-- Queue census for TrafficSignalService's adaptive timing. Bootstrap injects
-- this as the signal service's queue provider (the signal service must not
-- require this module back -- NPCDriverService already requires it, so the
-- injection avoids a require cycle). Counts cars that are slow and near the
-- stop line on the given approach edges; the second return is how many of
-- those are waiting to turn left (or U-turn).
local SPEED_DEBUG_CAP = 250

-- Read-only: derives WHY each in-range car is at its current speed, from state
-- the driver already keeps. Called at debug-poll cadence (never per frame), so
-- it never perturbs the sim or adds replicated attributes.
local function classifySpeedReason(state: DriverState, g: any, spd: number): (string, number?)
	local limit: number? = nil
	if g and state.edgeId then
		local e = g:GetEdge(state.edgeId)
		if e then limit = e.speedLimit end
	end
	if state.connector then
		return "turn", state.connSpeedCap or limit
	end
	if spd < 0.5 then
		if (state.connBlockedTime or 0) > 0.1 then return "standoff", limit end
		if (state.blockedTime or 0) > 0.1 then return "yield", limit end
		return "stopped", limit
	end
	if (state.blockedTime or 0) > 0.1 or (state.stuckTime or 0) > 0.1 then
		return "follow", limit
	end
	if limit and spd < limit - 1 then
		return "slow", limit
	end
	return "cruise", limit
end

-- Where this vehicle is ON THE LANE GRAPH: the lane edge it occupies and how far along
-- it. This is the anchor a save needs -- edge ids are "S<segmentId>:L<laneIndex>:<F|R>",
-- built entirely from a segment id (which RoadSerializer preserves verbatim) and geometry
-- (which does not renumber), so they survive a save/load for any road left unedited.
-- A world position does NOT survive as well: it has to be re-projected onto a lane on the
-- way back in, which is where a queue loses its spacing.
--
-- A car mid-turn (on a junction connector) reports the lane it is LEAVING, at that lane's
-- end -- restoring it there simply has it make the turn again.
-- How far along the lane the entry path leads before the traffic AI takes over. Long enough
-- that the last movement of the off-graph leg is unmistakably ALONG the lane (so the vehicle
-- ends up facing down it), short enough to stay inside a normal first edge.
local LANE_ENTRY_LEAD = 6

-- Where a road leg would seat a vehicle, plus a short lead along the lane after it.
--
-- DriveDirected seats a vehicle at the point of route[1] nearest the position it is given.
-- An off-graph leg (a driveway pull-out, a depot yard, an arrival at the map edge) ends at a
-- lot mouth or a kerb, which is metres to the SIDE of the lane centreline and usually facing
-- across it -- so the vehicle jumped sideways onto the lane and span to the lane heading in a
-- single frame. That is the "teleport" coming out of a driveway.
--
-- Finish the off-graph leg on the points this returns and the road leg starts exactly where
-- the vehicle already stands, pointing the way it is already pointing. Returns nil when the
-- edge is unknown, so a caller can fall back to the old behaviour rather than fail the trip.
function NPCDriverService.LaneEntryPath(edgeId: string, fromPos: Vector3, lead: number?): { Vector3 }?
	local g = nav()
	if not g or typeof(edgeId) ~= "string" then return nil end
	local edge = g:GetEdge(edgeId)
	if not edge or not edge.points or #edge.points < 2 then return nil end
	local cum = PathFollower.getCum(edge)
	local total = cum[#cum] or 0
	if total <= 0 then return nil end
	local d0 = math.clamp(distAlongEdgeNearest(edge, fromPos), 0, total)
	local entry = PathFollower.pointAtDist(edge.points, cum, d0)
	-- Never lead so far that the vehicle is seated at the very end of the first edge: capped
	-- to a fraction of it, a short edge simply gets a shorter lead.
	local step = math.min(lead or LANE_ENTRY_LEAD, total * 0.4)
	local d1 = math.min(total, d0 + step)
	-- On the asphalt, not the slab middle: the off-graph leg follows these at the vehicle's
	-- plain clearance (see LANE_SURFACE), so the road leg it hands over to starts level.
	local lift = Vector3.new(0, LANE_SURFACE, 0)
	if d1 - d0 < 0.05 then return { entry + lift } end
	-- Parenthesised: pointAtDist returns (position, tangent), and a bare call in the LAST
	-- slot of a table constructor expands BOTH -- which appended the tangent as a third
	-- "waypoint" near the world origin for the vehicle to drive to.
	return { entry + lift, (PathFollower.pointAtDist(edge.points, cum, d1)) + lift }
end

function NPCDriverService.GetLaneAnchor(model: Model): { edgeId: string, dist: number }?
	local state = _drivers[model]
	if not state or not model.Parent then return nil end
	if typeof(state.edgeId) ~= "string" then return nil end
	return { edgeId = state.edgeId, dist = state.edgeDist or 0 }
end

function NPCDriverService.GetDriverRouteDebug(model: Model): { [string]: any }?
	local state = _drivers[model]
	local g = nav()
	if not state or not g or not model.Parent then return nil end

	local points: { Vector3 } = {}
	local function appendPoint(point: Vector3)
		local last = points[#points]
		if #points < 600 and (not last or (last - point).Magnitude > 0.05) then
			table.insert(points, point)
		end
	end
	local function appendEdge(edge: any, fromDist: number, toDist: number)
		local cum = PathFollower.getCum(edge)
		local total = cum[#cum] or edge.length or 0
		local first = math.clamp(fromDist, 0, total)
		local last = math.clamp(toDist, first, total)
		local startPos = PathFollower.pointAtDist(edge.points, cum, first)
		appendPoint(startPos)
		for i, distance in cum do
			if distance > first and distance < last then appendPoint(edge.points[i]) end
		end
		local endPos = PathFollower.pointAtDist(edge.points, cum, last)
		appendPoint(endPos)
	end

	appendPoint(getStatePosition(state))
	local route = state.route
	local routeIndex = state.routeIndex or 1
	if state.connector and state.connCum then
		local connectorTotal = state.connCum[#state.connCum] or 0
		local startPos = PathFollower.pointAtDist(state.connector, state.connCum, state.connDist)
		appendPoint(startPos)
		for i, distance in state.connCum do
			if distance > state.connDist then appendPoint(state.connector[i]) end
		end
		if connectorTotal > state.connDist then
			local endPos = PathFollower.pointAtDist(state.connector, state.connCum, connectorTotal)
			appendPoint(endPos)
		end
	end

	if route then
		local firstIndex = if state.connector then routeIndex + 1 else routeIndex
		for i = firstIndex, #route do
			local edge = g:GetEdge(route[i])
			if edge then
				local fromDist = if i == routeIndex then state.edgeDist
					elseif i == firstIndex and state.connector then state.nextEdgeDist
					else 0
				local toDist = if i == #route then (state.finalDist or edge.length) else edge.length
				appendEdge(edge, fromDist, toDist)
				local nextId = route[i + 1]
				if nextId then
					for _, p in g:GetConnectionPoints(edge.id, nextId) do appendPoint(p) end
				end
			end
		end
	else
		local edge = g:GetEdge(state.edgeId)
		if edge and not state.connector then appendEdge(edge, state.edgeDist, edge.length) end
		local nextId = state.nextEdgeId or state.pendingNextEdgeId
		local nextEdge = nextId and g:GetEdge(nextId)
		if edge and nextEdge then
			for _, p in g:GetConnectionPoints(edge.id, nextEdge.id) do appendPoint(p) end
			appendEdge(nextEdge, state.nextEdgeDist or 0, nextEdge.length)
		end
	end

	local congestion = if state.edgeId then g:GetEdgeCongestion(state.edgeId) else 0
	return {
		kind = if route then "directed vehicle" else "ambient vehicle",
		name = model.Name,
		polyline = points,
		destination = state.goalPos,
		routeIndex = state.routeIndex,
		routeLength = if route then #route else nil,
		speed = state.currentSpeed or state.speed or 0,
		stopReason = state.stopReason or "moving",
		congestion = congestion,
		trafficReroutes = state.trafficReroutes or 0,
		reason = if route
			then "A* chose the lowest distance plus live-congestion cost. The car only reroutes after a sustained jam and a meaningful improvement."
			else "Ambient traffic follows its lane and locks one legal outgoing road before entering each junction.",
	}
end

function NPCDriverService.GetSpeedDebug(): { any }
	local out: { any } = {}
	local g = nav()
	local n = 0
	for model, state in _drivers do
		if n >= SPEED_DEBUG_CAP then break end
		if model and model.Parent then
			local spd = state.currentSpeed or state.speed or 0
			local reason, limit = classifySpeedReason(state, g, spd)
			if state.stopReason then reason = state.stopReason end
			n += 1
			table.insert(out, {
				id = ensureDebugId(model),
				model = model,
				name = model.Name,
				kind = if state.route then "directed" else "ambient",
				speed = math.round(spd),
				limit = limit,
				reason = reason,
				routeIndex = state.routeIndex,
				routeLength = if state.route then #state.route else nil,
				congestion = if g and state.edgeId then g:GetEdgeCongestion(state.edgeId) else 0,
				trafficReroutes = state.trafficReroutes or 0,
			})
		end
	end
	return out
end

-- ----------------------------------------------------------- dev panel --
-- Read-only feeds for the Developer panel (DeveloperService aggregates them).
-- Never mutate sim state, never add replicated attributes; called at poll cadence.

local DEV_STOPLINE_CAP = 3500
local DEV_STOPLINE_WIDTH = 7
local DEV_STUCK_SECONDS = 3

local function devWithinRadius(camPos: Vector3?, radiusSq: number, p: Vector3): boolean
	if not camPos then return true end
	local dx = p.X - camPos.X
	local dz = p.Z - camPos.Z
	return (dx * dx + dz * dz) <= radiusSq
end

-- Live driver census: counts, average speed, reroute total, and a histogram of the
-- WHY-stopped reasons. Cheap (walks _drivers only), so the report polls it directly.
function NPCDriverService.GetTrafficStats(): { [string]: any }
	local g = nav()
	local active, moving, stopped, stuck, directed, ambient, reroutes = 0, 0, 0, 0, 0, 0, 0
	local speedSum = 0
	local reasons: { [string]: number } = {}
	for model, state in _drivers do
		if not model.Parent then continue end
		active += 1
		local spd = state.currentSpeed or state.speed or 0
		speedSum += spd
		if state.route then directed += 1 else ambient += 1 end
		reroutes += state.trafficReroutes or 0
		if (state.stuckTime or 0) > DEV_STUCK_SECONDS then stuck += 1 end
		if spd < 0.5 then stopped += 1 else moving += 1 end
		local reason = classifySpeedReason(state, g, spd)
		if state.stopReason then reason = state.stopReason end
		reasons[reason] = (reasons[reason] or 0) + 1
	end
	return {
		active = active, moving = moving, stopped = stopped, stuck = stuck,
		directed = directed, ambient = ambient, reroutes = reroutes,
		avgSpeed = if active > 0 then speedSum / active else 0,
		reasons = reasons,
	}
end

-- Stop-line geometry: for every intersection-approach lane within radius, WHERE a car
-- should stop (the painted stop line / setback the AI actually uses) plus the live
-- right-of-way state -- signal go/stop, or unsignalized priority/yield. The Developer
-- panel draws these so "where they should stop" can be compared against where they do.
function NPCDriverService.GetTrafficDebug(camPos: Vector3?, radius: number?): { [string]: any }
	local g = nav()
	if not g or not g:HasEdges() then
		return { stopLines = {}, stats = NPCDriverService.GetTrafficStats(), truncated = false }
	end

	local r = if typeof(radius) == "number" and radius == radius then radius else 1e9
	local radiusSq = r * r
	local stopLines: { any } = {}
	local truncated = false

	for _, edge in g:GetEdges() do
		if #stopLines >= DEV_STOPLINE_CAP then
			truncated = true
			break
		end
		local pts = edge.points
		if typeof(pts) ~= "table" or #pts < 2 then continue end
		if not devWithinRadius(camPos, radiusSq, pts[#pts]) then continue end
		if not isIntersectionNode(g, edge.toNode) then continue end

		local cum = PathFollower.getCum(edge)
		local total = cum[#cum] or edge.length or 0
		local stopDist = math.max(0, total - getStopLineGap(g, edge.toNode, edge))
		local pos = PathFollower.pointAtDist(pts, cum, stopDist)
		local dir = flatUnit(edge.toDir)

		local state: string
		if isSignalizedIntersection(edge.toNode) then
			state = if TrafficSignalService.CanGo(edge.id) then "go" else "stop"
		else
			state = if getArmPriority(g, edge.toNode, edge.id) == "major" then "priority" else "yield"
		end

		table.insert(stopLines, { pos = pos, dir = dir, w = DEV_STOPLINE_WIDTH, state = state })
	end

	return { stopLines = stopLines, stats = NPCDriverService.GetTrafficStats(), truncated = truncated }
end

-- Drivable lane network within radius: each lane's centreline + its live congestion
-- (0 clear .. 1 jammed) for colour-coding, and the end-points of dead-end lanes (no
-- legal non-U-turn exit) -- a direct "broken road graph" signal for the Developer panel.
function NPCDriverService.GetLaneDebug(camPos: Vector3?, radius: number?): { [string]: any }
	local g = nav()
	if not g or not g:HasEdges() then
		return { lanes = {}, deadEnds = {}, truncated = false }
	end

	local r = if typeof(radius) == "number" and radius == radius then radius else 1e9
	local radiusSq = r * r
	local lanes: { any } = {}
	local deadEnds: { Vector3 } = {}
	local truncated = false

	for _, edge in g:GetEdges() do
		if #lanes >= DEV_STOPLINE_CAP then
			truncated = true
			break
		end
		local pts = edge.points
		if typeof(pts) ~= "table" or #pts < 2 then continue end
		if not devWithinRadius(camPos, radiusSq, pts[1]) then continue end

		table.insert(lanes, { p = pts, c = g:GetEdgeCongestion(edge.id) or 0 })

		local hasExit = false
		for _, toId in edge.out do
			if edge.outMovement[toId] ~= "uturn" then
				hasExit = true
				break
			end
		end
		if not hasExit then
			table.insert(deadEnds, pts[#pts])
		end
	end

	return { lanes = lanes, deadEnds = deadEnds, truncated = truncated }
end

-- Hotspot feed for the Developer panel's jam heatmap. It reuses the same driver state
-- and stop-reason classifier as the speed debugger, but returns only compact positions
-- so the overlay can draw local-only heat pillars without touching replicated state.
function NPCDriverService.GetJamDebug(camPos: Vector3?, radius: number?): { any }
	local g = nav()
	local r = if typeof(radius) == "number" and radius == radius then radius else 1e9
	local radiusSq = r * r
	local out: { any } = {}

	for model, state in _drivers do
		if #out >= SPEED_DEBUG_CAP then break end
		if not model.Parent then continue end
		local pos = getStatePosition(state)
		if not devWithinRadius(camPos, radiusSq, pos) then continue end

		local spd = state.currentSpeed or state.speed or 0
		local reason = classifySpeedReason(state, g, spd)
		if state.stopReason then reason = state.stopReason end
		local stuckSeconds = math.max(state.stuckTime or 0, state.blockedTime or 0, state.connBlockedTime or 0)
		local congestion = if g and state.edgeId then (g:GetEdgeCongestion(state.edgeId) or 0) else 0
		if stuckSeconds >= 0.4 or congestion >= 0.35 or spd < 2 then
			table.insert(out, {
				pos = pos,
				seconds = stuckSeconds,
				speed = spd,
				reason = reason,
				congestion = congestion,
				name = model.Name,
				kind = if state.route then "directed" else "ambient",
			})
		end
	end

	table.sort(out, function(a, b)
		local aw = (tonumber(a.seconds) or 0) + (tonumber(a.congestion) or 0) * 8
		local bw = (tonumber(b.seconds) or 0) + (tonumber(b.congestion) or 0) * 8
		return aw > bw
	end)
	return out
end

function NPCDriverService.GetSignalQueue(edgeIds: { string }): (number, number)
	local g = nav()
	if not g then return 0, 0 end

	local total, left = 0, 0
	for _, edgeId in ipairs(edgeIds) do
		local bucket = _edgeDriverIndex[edgeId]
		if not bucket then continue end
		local edge = g:GetEdge(edgeId)
		if not edge then continue end

		local cum = PathFollower.getCum(edge)
		local stopDist = (cum[#cum] or 0) - getStopLineGap(g, edge.toNode, edge)
		for _, other in ipairs(bucket) do
			if not other.model.Parent then continue end
			local distToStop = stopDist - other.edgeDist
			if distToStop > -2 and distToStop <= TrafficConfig.QUEUE_ZONE
				and (other.currentSpeed or 0) <= TrafficConfig.QUEUE_MAX_SPEED then
				total += 1
				local nextId = other.pendingNextEdgeId
				local movement = if nextId and edge.outMovement then edge.outMovement[nextId] else nil
				if movement == crossingTurn() or movement == "uturn" then
					left += 1
				end
			end
		end
	end
	return total, left
end

function NPCDriverService.Init(roadService: any)
	_roadService = roadService
end

function NPCDriverService.Bind()
	if _bound then return end
	_bound = true

	local RS  = game:GetService("ReplicatedStorage")
	local Net = require(RS:WaitForChild("Networker"))

	NetMiddleware.RegisterServerRateLimit(Net.ReportCameraPos, CAM_REPORT_MIN_DT)

	Net.ReportCameraPos.OnServerEvent:Connect(function(player: Player, camPos: any)
		if not NetMiddleware.CheckServerRate(Net.ReportCameraPos, player) then return end
		local pos: Vector3? = nil
		local focus: Vector3? = nil
		if typeof(camPos) == "Vector3" then
			pos = camPos
		elseif typeof(camPos) == "table" and typeof(camPos.pos) == "Vector3" then
			pos = camPos.pos
			-- Ground look-at from {pos, yaw, pitch}, as Bootstrap's streaming focus does.
			local yaw, pitch = tonumber(camPos.yaw), tonumber(camPos.pitch)
			if yaw and pitch and yaw == yaw and pitch == pitch then
				local cosP = math.cos(math.rad(pitch))
				local dir = Vector3.new(-math.sin(math.rad(yaw)) * cosP, math.sin(math.rad(pitch)), -math.cos(math.rad(yaw)) * cosP)
				if dir.Y < -0.05 then
					local hit = camPos.pos + dir * ((RoadConstants.getGroundY() - camPos.pos.Y) / dir.Y)
					local h = RoadConstants.MAP_HALF_EXTENT
					focus = Vector3.new(math.clamp(hit.X, -h, h), hit.Y, math.clamp(hit.Z, -h, h))
				end
			end
		end
		if pos then
			PathFollower.setCameraPos(player, pos, focus)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		PathFollower.clearPlayer(player)
		NetMiddleware.OnPlayerRemoving(player)
	end)
end

-- A car that reaches an outside connection heading OUTWARD has left the city: despawn it
-- so it vanishes cleanly at the edge instead of driving off the map into the void. Arrivals
-- head INWARD here (look.Dot(normal) < 0), so they are never caught. Injected after boot.
local _outsideConnService: any = nil
function NPCDriverService.SetOutsideConnService(svc: any)
	_outsideConnService = svc
end

local CONN_DESPAWN_RADIUS = 12 -- studs from a connection: heading OUT here = left the city
local CONN_NEAR_RADIUS    = 40 -- studs from a connection: counts as "at the entrance"
-- Counted on the watchdog's no-progress clock, which a car waiting in traffic never runs, so
-- a queue at the entrance is never culled. Real wedges still clear well before the watchdog.
local STUCK_DESPAWN_TIME  = 15 -- s stalled (bugged) at the entrance, either direction, before we clear it
local _lastConnDespawnWarn = 0
-- True if this car should be cleared at an outside connection: it is either heading OUT
-- (left the city) or it has been wedged at the entrance too long (the recurring jam). Logs
-- why, rate-limited, so a stuck car at a connection is self-explaining in the output.
local function despawnAtConnection(model: Model, state: DriverState): boolean
	if not _outsideConnService then return false end
	local ok, cf = pcall(function() return model:GetPivot() end)
	if not ok then return false end
	local pos, look = cf.Position, cf.LookVector
	for _, c in _outsideConnService.list() do
		local dx, dz = pos.X - c.outer.X, pos.Z - c.outer.Z
		local dist2 = dx * dx + dz * dz
		local outward = look:Dot(c.normal) > 0.3
		-- Waiting in traffic is not wedged, however long the jam. Culling the head of the
		-- queue there ate a busy entrance one car at a time, and the queue behind simply fed
		-- the next victim forward -- which is most of what "cars keep despawning" looks like
		-- on a packed road. noProgressTime only runs while no traffic reason explains the
		-- stop (waitingInTraffic), so only a bugged car is cleared here.
		local wedged = (state.noProgressTime or 0) >= STUCK_DESPAWN_TIME
		if (dist2 < CONN_DESPAWN_RADIUS * CONN_DESPAWN_RADIUS and outward)
			or (dist2 < CONN_NEAR_RADIUS * CONN_NEAR_RADIUS and wedged) then
			-- Only the wedged case is worth a line. A car pointing outward at a connection is
			-- simply leaving the map -- the single commonest event in the whole sim -- and
			-- logging it buried everything else in the Output. Being WEDGED means it had to be
			-- force-cleared, which is a fault and still reports itself.
			if not outward and os.clock() - _lastConnDespawnWarn > 10 then
				_lastConnDespawnWarn = os.clock()
				warn(("[NPCDriverService] cleared WEDGED car at outside connection %s (stuck %.1fs, %.0f studs, reason=%s)")
					:format(tostring(c.id), state.noProgressTime or 0, math.sqrt(dist2), tostring(state.stopReason)))
			end
			return true
		end
	end
	return false
end

function NPCDriverService.Start()
	if _heartbeat then
		_heartbeat:Disconnect()
		_heartbeat = nil
	end

	_spawnedOnce = trySpawn()

	local tickAccum = 0
	_heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		tickAccum += math.min(dt, MAX_SIM_DT)
		if tickAccum < DRIVER_TICK then return end
		local simDt = math.min(tickAccum, MAX_SIM_DT)
		tickAccum = 0
		PathFollower.keepalive()

		if not _spawnedOnce then
			if trySpawn() then
				_spawnedOnce = true
			end
			return
		end

		-- Every car runs at the full DRIVER_TICK rate. The old 4 Hz off-screen tier saved
		-- AI work but moved distant cars in 0.25 s lurches, which was visible from well
		-- outside the 200-stud bubble. DRIVER_TICK is the knob if this ever costs frames.
		local speed = math.clamp(math.floor(tonumber(workspace:GetAttribute("GameSpeed")) or 1), 0, 3)

		for model, state in pairs(_drivers) do
			if not model.Parent then
				releaseBooking(state)
				_drivers[model] = nil
				PathFollower.forget(model)
			end
		end

		local tickStart = os.clock()
		for _ = 1, speed do
			_simClock += simDt
			rebuildDriverIndexes()
			local g = nav()
			if g then publishCongestionSnapshot(g) end
			for model, state in pairs(_drivers) do
				if not model.Parent then continue end
				if tickStart >= (state.lodCheckAt or 0) then
					state.lodCheckAt = tickStart + LOD_RECHECK * (0.75 + math.random() * 0.5)
					state.lodFar = PathFollower.nearestPlayerDistSq(getStatePosition(state)) > FAR_LOD_DIST_SQ
				end
				state.lodAccum = (state.lodAccum or 0) + simDt
				if state.lodFar and state.lodAccum < FAR_TICK then continue end
				local stepDt = math.min(state.lodAccum, FAR_MAX_DT)
				state.lodAccum = 0

				if despawnAtConnection(model, state) then
					-- A DIRECTED car belongs to its service (citizen/delivery) and its
					-- onArrive/onAbort contract must hold. despawnDriver() destroyed the
					-- model with neither fired, so the caller's directed-trip and car
					-- counters leaked +1 per kill until every budget read full -- then
					-- move-in drive-ins silently stopped and arrivals sat at entrances
					-- in retry loops (the recurring entrance jam). Abort instead: the
					-- owner parks the car at its destination and the books stay right.
					if state.route then
						abortDirected(state)
					else
						despawnDriver(state)
					end
				else
					updateDriver(state, stepDt)
					if model.Parent then stallWatchdog(state, stepDt) end
				end
			end
		end
	end)
end

return NPCDriverService