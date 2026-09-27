--!strict
-- CitizenAgentService
-- Tier 2 of the citizen population: agents that are REAL -- they have a route, a live
-- position and an honest travel time -- but no body, no parts and no replication.
--
-- The three tiers, and what decides which one a citizen is in:
--   Tier 1  embodied    NPCWalkingService, hard-capped at MAX_WALKERS. Visible, streamed.
--   Tier 2  simulated   here. The position exists; nothing renders it.
--   Tier 3  statistical CitizenService. Indoors or in a vehicle: no position at all.
--
-- Before this layer existed there was no Tier 2, and Tier-1 overflow fell straight to a
-- teleport: spawnCommuter returned 0 at the cap and fired onArrive on the next frame, so
-- a citizen who could not get a body arrived instantly. That is invisible at 20 walkers
-- and a lie at 2000 -- every travel time the rest of the sim reads stops meaning
-- anything. This layer takes that overflow and walks it properly.
--
-- THE INVARIANT that makes the tiers cheap: an agent's position is a PURE FUNCTION OF
-- TIME. We store the PLAN (route polyline + speed + departure stamp), never a stepped
-- position, so:
--   * ticking costs one float compare per agent -- there is no per-agent position write;
--   * demotion is free -- drop the body, keep the plan;
--   * promotion is EXACT rather than reconstructed -- the body appears precisely where
--     the plan already said the agent was, so there is no pop to hide.
-- Break that invariant (start mutating a stored position) and promotion stops being free.

local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PathFollower  = require(ServerScriptService.Services.Util.PathFollower)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local WS = RoadConstants.WORLD_SCALE

local CitizenAgentService = {}

-- == Tuning ====================================================================
local AGENT_TICK   = 1 / 5   -- arrival/promotion cadence. Position is parametric, so this
                             -- rate does NOT affect accuracy -- only arrival granularity.
local MAX_AGENTS   = 20000    -- flat-array ceiling; past this, overflow teleports as before
local SNAP_RADIUS  = 60      -- must match NPCWalkingService.COMMUTER_SNAP_RADIUS
local WALK_SPEED   = 5 * WS  -- must match NPCWalkingService.WALK_SPEED

-- Tier-1 walkers slow to CROSSWALK_SPEED (0.7x) over zebras and can idle at a kerb for up
-- to CROSS_WAIT_MAX before committing. A plan that ignores both makes Tier-2 agents arrive
-- systematically EARLY -- the classic proxy-simulation bias -- which reads as Tier-2
-- commutes beating Tier-1 commutes over the same route. This pads the plan to the travel
-- time a real walker actually averages.
-- CALIBRATE IT: log Tier-1 vs Tier-2 durations over matched routes and move this until the
-- means agree. Validate on the mean, not on individual trips.
local TRAVEL_PAD   = 0.88

-- Promotion band. Hysteresis + dwell exist because thrash at the boundary is the single
-- biggest source of visible popping: PROMOTE_DIST is deliberately well inside
-- PathFollower.REPLICATE_RANGE (200) so a promoted body is already inside the pose stream
-- when it appears, rather than materialising exactly at the replication horizon.
local PROMOTE_DIST     = 900    -- studs; NPCWalkingService gives up a body past DEMOTE_RANGE (hysteresis)
local PROMOTE_DIST_SQ  = PROMOTE_DIST * PROMOTE_DIST
local PROMOTE_RETRY    = 1.5  -- sim-seconds before a failed promotion is retried
local PROMOTE_RESERVE  = 8    -- walker slots never taken by promotion, so a genuinely new
                              -- commute can always get a body ahead of a promoted one
local PROMOTE_SCAN_PER_TICK = 24 -- agents distance-checked per tick (round-robin)

-- == State =====================================================================
local _walkingService: any
local _heartbeat: RBXScriptConnection?
local _running = false

-- The single sim clock every plan is expressed against. It advances by dt * GameSpeed, so
-- pausing the game (GameSpeed 0) freezes every agent mid-route for free, and 3x speed
-- moves them all without touching a single agent record.
local _simClock = 0

type Agent = {
	id: number,
	idx: number,              -- index into _agents, kept valid by removeAt
	route: { Vector3 },
	cum: { number },          -- cumulative arc length at each waypoint
	total: number,            -- route length in studs
	speed: number,            -- studs per sim-second
	departAt: number,         -- _simClock stamp at departure
	arriveAt: number,         -- _simClock stamp at arrival == departAt + total/speed
	destPos: Vector3,
	onArrive: (() -> ())?,
	label: string?,
	appearance: any,
	graphVer: number,         -- sidewalk graph version this route was planned against
	promoteAt: number,        -- earliest _simClock at which promotion may be attempted
	-- A car trip driving its road route unrendered (CitizenService overflow). Never promoted
	-- to a pedestrian: there is no body for it on the pavement.
	drive: boolean?,
}

local _agents: { Agent } = {}
local _byId: { [number]: Agent } = {}
local _nextAgentId = 0     -- decrements: Tier-2 ids are NEGATIVE, Tier-1 ids are positive
local _promoteCursor = 1

-- Lifetime counters for the F6 panel.
local _adopted, _arrived, _promoted, _overflowed = 0, 0, 0, 0

-- == Helpers ===================================================================
local function gameSpeed(): number
	return math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
end

-- Swap-remove. Keeps `idx` correct on the element swapped into the hole, which is what
-- lets retire() be O(1) instead of a scan.
local function removeAt(i: number)
	local n = #_agents
	local a = _agents[i]
	if not a then return end
	_byId[a.id] = nil
	local last = _agents[n]
	_agents[i] = last
	last.idx = i
	_agents[n] = nil
end

local function retire(a: Agent)
	if _agents[a.idx] == a then removeAt(a.idx) end
end

-- THE parametric evaluation. No stored position is read or written.
local function positionOf(a: Agent): Vector3
	local travelled = math.clamp((_simClock - a.departAt) * a.speed, 0, a.total)
	local pos = PathFollower.pointAtDist(a.route, a.cum, travelled)
	return pos
end

-- == Public API ================================================================

-- Adopt a walk that Tier 1 could not give a body to. Returns a NEGATIVE agent id (Tier-1
-- commuter ids are positive, 0 means "no agent at all"), or 0 if the walk could not be
-- planned -- in which case the caller keeps its existing instant-arrival fallback.
function CitizenAgentService.adopt(fromPos: Vector3, toPos: Vector3, onArrive: (() -> ())?, label: string?, appearance: any): number
	if not _running or not _walkingService then return 0 end
	if typeof(fromPos) ~= "Vector3" or typeof(toPos) ~= "Vector3" then return 0 end
	if #_agents >= MAX_AGENTS then
		_overflowed += 1
		return 0
	end

	local route = _walkingService.findPath(fromPos, toPos, SNAP_RADIUS)
	if not route or #route < 2 then return 0 end

	local cum = PathFollower.cumOf(route)
	local total = PathFollower.pathLen(route)
	if total <= 0 then return 0 end

	local speed = WALK_SPEED * TRAVEL_PAD
	_nextAgentId -= 1
	local a: Agent = {
		id = _nextAgentId,
		idx = #_agents + 1,
		route = route,
		cum = cum,
		total = total,
		speed = speed,
		departAt = _simClock,
		arriveAt = _simClock + total / speed,
		destPos = toPos,
		onArrive = onArrive,
		label = label,
		appearance = appearance,
		graphVer = _walkingService.getVersion(),
		promoteAt = _simClock,
	}
	_agents[a.idx] = a
	_byId[a.id] = a
	_adopted += 1
	return a.id
end

-- A car with no slot on the traffic AI drives its real road `route` at `speed` without a
-- model: same parametric plan as a walk, so it arrives exactly when the drive would have.
-- Returns a NEGATIVE id, or 0 if the route is empty (the caller parks it itself).
function CitizenAgentService.adoptRoute(route: { Vector3 }, speed: number, onArrive: (() -> ())?, label: string?): number
	if not _running or typeof(route) ~= "table" or #route < 2 or #_agents >= MAX_AGENTS then return 0 end
	local total = PathFollower.pathLen(route)
	if total <= 0 or speed <= 0 then return 0 end
	_nextAgentId -= 1
	local a: Agent = {
		id = _nextAgentId,
		idx = #_agents + 1,
		route = route,
		cum = PathFollower.cumOf(route),
		total = total,
		speed = speed,
		departAt = _simClock,
		arriveAt = _simClock + total / speed,
		destPos = route[#route],
		onArrive = onArrive,
		label = label,
		appearance = nil,
		graphVer = -1,
		promoteAt = math.huge,
		drive = true,
	}
	_agents[a.idx] = a
	_byId[a.id] = a
	_adopted += 1
	return a.id
end

-- Cancel an agent WITHOUT firing its arrival callback -- the Tier-2 twin of
-- NPCWalkingService.despawnCommuter, for a household that was removed mid-walk.
function CitizenAgentService.release(id: number?)
	if not id or id >= 0 then return end
	local a = _byId[id]
	if not a then return end
	a.onArrive = nil
	retire(a)
end

-- Where a Tier-2 agent is right now. There is no part to follow (that is the whole point
-- of the tier), so the locate camera gets a point rather than a live handle.
function CitizenAgentService.getPosition(id: number?): Vector3?
	if not id or id >= 0 then return nil end
	local a = _byId[id]
	if not a then return nil end
	return positionOf(a)
end

function CitizenAgentService.isAgent(id: number?): boolean
	return id ~= nil and id < 0 and _byId[id] ~= nil
end

-- Remaining route of a Tier-2 agent, for the debug overlay.
function CitizenAgentService.getDebug(id: number?): { [string]: any }?
	if not id or id >= 0 then return nil end
	local a = _byId[id]
	if not a then return nil end
	local travelled = math.clamp((_simClock - a.departAt) * a.speed, 0, a.total)
	return {
		id = id,
		tier = 2,
		name = a.label,
		pos = positionOf(a),
		destPos = a.destPos,
		travelled = travelled,
		total = a.total,
		etaSeconds = math.max(0, a.arriveAt - _simClock),
		staleGraph = a.graphVer ~= (_walkingService and _walkingService.getVersion()),
	}
end

function CitizenAgentService.getStats(): { [string]: number }
	return {
		active = #_agents,
		adopted = _adopted,
		arrived = _arrived,
		promoted = _promoted,
		overflowed = _overflowed,
	}
end

function CitizenAgentService.debugSnapshot(): { [string]: any }
	local stale = 0
	local ver = _walkingService and _walkingService.getVersion()
	for _, a in _agents do
		if a.graphVer ~= ver then stale += 1 end
	end
	return {
		active = #_agents,
		capacity = MAX_AGENTS,
		staleGraph = stale,
		simClock = _simClock,
		adopted = _adopted, arrived = _arrived, promoted = _promoted, overflowed = _overflowed,
	}
end

-- Drop every agent without firing arrivals. Called when a city is unloaded, alongside the
-- Workspace._City sweep that clears Tier-1 bodies.
function CitizenAgentService.clear()
	table.clear(_agents)
	table.clear(_byId)
	_promoteCursor = 1
end

-- == Simulation ================================================================

-- Hand a plan to a real body, starting exactly where the plan says the agent is. The
-- callback moves with it, so the citizen's FSM neither knows nor cares which tier walked
-- the leg.
local function promote(a: Agent)
	local pos = positionOf(a)
	local id = _walkingService.spawnCommuter(pos, a.destPos, a.onArrive, a.label, a.appearance)
	-- spawnCommuter returning 0 means it took the leg over as an instant arrival (no graph,
	-- or a path failure) and has ALREADY deferred onArrive. It cannot mean "pool full":
	-- promotions are capped by walkerHeadroom in the same single-threaded tick, so no other
	-- code can claim a slot in between. Either way the callback now belongs to Tier 1, so we
	-- clear our reference -- that is what prevents a double fire -- and retire.
	a.onArrive = nil
	retire(a)
	if id ~= 0 then
		_promoted += 1
		-- The citizen still holds the agent id: let it cancel / follow the new body.
		_walkingService.alias(a.id, id)
	end
end

local function tick(dt: number)
	local gs = gameSpeed()
	if gs <= 0 then return end          -- paused: plans freeze where they are
	_simClock += dt * gs

	-- Arrivals. Parametric plans make this one float compare per agent -- there is no
	-- position integration to do. Iterating backwards means removeAt's swap only ever
	-- moves an element we have already visited, so nothing is skipped.
	local arrived: { Agent }? = nil
	for i = #_agents, 1, -1 do
		local a = _agents[i]
		if _simClock >= a.arriveAt then
			removeAt(i)
			arrived = arrived or {}
			table.insert(arrived, a)
		end
	end

	-- Promotion. Round-robin a slice so the cost per tick is bounded by
	-- PROMOTE_SCAN_PER_TICK regardless of population. The cursor walks an array that
	-- swap-removal shuffles, so fairness is approximate -- that is fine, every agent is
	-- reached within a few sweeps and nothing is starved for long.
	local toPromote: { Agent }? = nil
	if _walkingService and #_agents > 0 and _walkingService.walkerHeadroom then
		local slots = _walkingService.walkerHeadroom() - PROMOTE_RESERVE
		if slots > 0 then
			local ver = _walkingService.getVersion()
			local scans = math.min(PROMOTE_SCAN_PER_TICK, #_agents)
			for _ = 1, scans do
				if toPromote and #toPromote >= slots then break end
				if _promoteCursor > #_agents then _promoteCursor = 1 end
				local a = _agents[_promoteCursor]
				_promoteCursor += 1
				-- A route planned against a since-rebuilt graph may cut a road that moved,
				-- so it stays invisible: let it finish as a plan rather than spawning a body
				-- onto stale geometry.
				if a and not a.drive and a.graphVer == ver and _simClock >= a.promoteAt then
					local d = PathFollower.nearestPlayerDistSq(positionOf(a))
					if d <= PROMOTE_DIST_SQ then
						toPromote = toPromote or {}
						table.insert(toPromote, a)
					end
				end
			end
		end
	end

	-- Mutate only after both scans are done: a promotion spawns a walker and an arrival
	-- callback re-enters CitizenService, which can call straight back into adopt().
	if toPromote then
		for _, a in toPromote do promote(a) end
	end
	if arrived then
		for _, a in arrived do
			_arrived += 1
			local cb = a.onArrive
			if cb then
				local ok, err = pcall(cb)
				if not ok then warn("[CitizenAgentService] arrival callback failed: " .. tostring(err)) end
			end
		end
	end
end

-- == Lifecycle =================================================================
function CitizenAgentService.Init(walkingService: any)
	assert(walkingService, "[CitizenAgentService] missing dependency: walkingService")
	_walkingService = walkingService
end

function CitizenAgentService.Bind() end

function CitizenAgentService.Start()
	if _running then return end
	_running = true
	local accum = 0
	_heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		accum += math.min(dt, 0.1)
		if accum < AGENT_TICK then return end
		local step = accum
		accum = 0
		local ok, err = pcall(tick, step)
		if not ok then warn("[CitizenAgentService] tick failed: " .. tostring(err)) end
	end)
end

function CitizenAgentService.Stop()
	_running = false
	if _heartbeat then _heartbeat:Disconnect(); _heartbeat = nil end
	CitizenAgentService.clear()
end

return CitizenAgentService
