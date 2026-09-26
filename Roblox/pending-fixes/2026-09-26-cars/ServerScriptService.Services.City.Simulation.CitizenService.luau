--!strict
-- CitizenService
-- The household life-sim. Citizens are not random NPCs: households arrive from
-- outside connections when there is housing + demand, move into homes (residents),
-- adults take jobs in commercial/industrial buildings, and commute by car to work
-- in the morning and home in the evening (real trips on the nav graph, capped +
-- proximity-culled). Families have children -- gated by healthcare coverage --
-- and leave the city if the adults stay jobless. Real occupancy drives building
-- fill (residents/jobs), which the stats + economy read.

local CollectionService   = game:GetService("CollectionService")
local RunService          = game:GetService("RunService")
local Workspace           = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local PathFollower = require(ServerScriptService.Services.Util.PathFollower)
local VehicleFactory = require(ServerScriptService.Services.NPC.VehicleFactory)
local NameGen = require(ServerScriptService.Services.City.NameGen)
local Const = require(ServerScriptService.Services.City.CitySimConstants)
local NPCDriverService = require(ServerScriptService.Services.NPC.NPCDriverService)
local NetMiddleware = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local DriverProfile = require(ReplicatedStorage.Road.DriverProfile)
local NavCost = require(ReplicatedStorage.Road.NavCost)
local TravelModeChoice = require(ServerScriptService.Services.City.Simulation.TravelModeChoice)
-- Half-size world: speeds and world-distance radii scale with the city.
local WS = RoadConstants.WORLD_SCALE

local CitizenService = {}

-- == Tuning ====================================================================
local FAMILY_MAX = Const.FAMILY_MAX -- people in ONE household; the BUILDING's ceiling is
                                    -- BuildingService.getResidentCap (households x this)
local function isResZone(z: any): boolean return z == "Residential" end
local JOB_CAP  = Const.JOB_CAP -- shared with PowerService, which bills these slots

local SIM_STEP          = 2.0   -- game-seconds between sim passes (GameSpeed-scaled)
local TRIP_TICK         = 1 / 20 -- local driveway/parking motion; clients see smoothed cars
local ARRIVE_BASE_CHANCE = 0.35 -- per-step arrival chance at zero R demand
local ARRIVE_MIN_CHANCE  = 0.02 -- floor: even negative demand trickles hopeful families in
local STARTER_HOUSEHOLDS = 4    -- seed real families so a loaded city is not visually empty
local HEALTH_RADIUS     = 220 * WS -- studs a clinic/hospital covers for births
local BIRTH_CHANCE      = 0.18  -- per eligible household per day (needs healthcare)
local MAX_KIDS          = 3
-- Every NPC carries an integer age in years. City days advance age (AGE_PER_DAY years
-- per day); a child promotes to a working adult at AGE_ADULT.
local AGE_ADULT          = 18
local AGE_PER_DAY        = 1
local PARENT_MIN_AGE     = 24   -- arriving couples are adults of child-rearing age
local PARENT_MAX_AGE     = 52
local KID_ARRIVE_MIN_AGE = 1
local KID_ARRIVE_MAX_AGE = 16
local SCHOOL_AGE_MIN     = 5    -- youngest child that walks to school
local SCHOOL_AGE_MAX     = 17   -- oldest child that attends (18 promotes to a working adult)
local SCHOOL_START_HOUR  = 8.0
local SCHOOL_END_HOUR    = 15.0
local SCHOOL_WINDOW_HOURS = 1.25
local MOTHER_FERTILE_MAX = 45   -- births only while the mother is under this age
local FAMILY_INFO_MIN_DT = 0.15 -- rate-limit (s) for the family-info panel request
local LEAVE_JOBLESS_DAYS = 5    -- adults jobless this long -> household leaves
local MAX_TRIP_CARS     = 5000  -- cars on the full traffic AI at once (commute + errands + arrivals);
                                -- past it -- or past the AI's frame budget -- a trip far from every
                                -- player drives unseen (driveTo)
local RESERVED_ARRIVAL_TRIPS = 6 -- of MAX_TRIP_CARS, only arrivals may claim: commuters
                                 -- can never fully starve the move-in drive-ins (they
                                 -- used to hold every slot in a busy city, so arrival
                                 -- cars never spawned). Arrival bursts are naturally
                                 -- small (MAX_ARRIVALS_PER_STEP), so commutes keep the rest.
local CAR_SPEED         = 24 * WS
local CAR_HEIGHT        = 0.6
local ROADSIDE_RADIUS   = 700 * WS -- how far a driver looks around the destination for a free bay
                                   -- (~175 m, a 2-3 minute walk); nearest first, car parks beyond
local ERRAND_COOLDOWN   = 15   -- real seconds between a household's errands (apply / shop)
local SHOP_CHANCE       = 0.12 -- per idle sim step, chance a household sets out to shop
local SHOP_SPEND_MIN    = 8
local SHOP_SPEND_RANGE  = 24   -- shopping spend = MIN + rand(0..RANGE) -> store revenue
local PRESENCE_RADIUS    = 1400 -- outer bound for people IN FRONT of the camera (the cap binds first)
local PRESENCE_CAP       = 140  -- max standing people returned per presence query (perf cap)
local PRESENCE_FRONT_COS = 0.17 -- only people within ~80 deg of the camera's look (in front) are rendered
local DRIVE_RETRY_DELAY  = 2.0  -- routing/cap failures wait in place instead of teleporting
local MAX_DRIVE_RETRIES  = 30   -- ~60s of failed retries, then the trip completes at its goal
local MAX_ARRIVAL_RETRIES = 3   -- arrivals are cosmetic: bail to a home-park fast so a car that
                                -- can't start its road leg never squats on the entrance spawn
                                -- points and jams every later move-in
local TRIP_STALL_RESCUE  = 12   -- s a lot-leg line-follow may sit blocked before skipping to the leg's end


-- == Dependencies / state ======================================================
local _roadService: any
local _buildingService: any
local _cityStatsService: any
local _timeService: any
local _parkingService: any
local _walkingService: any
local _economyService: any
local _supplyService: any
local _educationService: any
local _folder: Folder
local _heartbeat: RBXScriptConnection?
local _running = false
local _restoring = false
local _rng = Random.new()
local _accum = 0

-- Every citizen is a Person (name + gender "M"/"F" + age in years) with a stable person
-- id `pid` used to locate them in the UI. Adults additionally run their OWN activity
-- FSM: each working adult commutes to their own workplace (one drives the family car,
-- the rest walk), so two adults in one home can be at two different buildings. Kids age
-- up each day and promote to an Adult at AGE_ADULT.
type Person = { name: string, gender: string, age: number, pid: number }
type Adult = {
	name: string, gender: string, age: number, pid: number,
	jobId: string?, joblessDays: number, eduLevel: number,
	-- Per-person activity FSM. `stage` is one of: atHome, transit, atWork. `tripId` is a
	-- monotonic token; a leg's async callback only acts while a.tripId still matches
	-- (late/superseded fires are ignored). `walkerId` is this adult's live commuter
	-- pedestrian, if any. `outKind`/`outDestId` describe the current trip (work / apply /
	-- shop) and its target. `usingCar` is true while this adult's own car is out with them.
	stage: string, tripId: number, walkerId: number?,
	outKind: string?, outDestId: string?, usingCar: boolean,
	-- Their OWN car (about nine adults in ten have one, TravelModeChoice.ownsCar) and where
	-- it stands: the plot's driveway if this adult holds it, else a bay / lot stall, plus how
	-- to leave that spot next trip (in-lot egress + the road hand-off point).
	ownsCar: boolean?, car: Model?, homeParkCF: CFrame?, parkSpotId: string?, parkStallKey: string?,
	-- On public transport: their place in TransitService's rider list, and while they are
	-- still standing at the stop, where (so the stop shows its crowd).
	riderId: number?, waitPos: Vector3?,
	driveKey: string?, parkEgress: { Vector3 }?, parkGraphPoint: Vector3?,
	tripTargetId: string?, tripTargetHome: boolean,
	commutedWorkDay: number, commutedHomeDay: number, nextErrandAt: number,
}
type Kid = {
	name: string, gender: string, age: number, pid: number,
	-- School-run FSM (walk-only, mirrors the adult one): atHome / transit / atSchool.
	stage: string, tripId: number, walkerId: number?, schoolPos: Vector3?, schoolId: number?,
	commutedSchoolDay: number, commutedHomeDay: number, bestTier: number,
}
type Household = {
	id: number, homeId: string, adults: { Adult }, kids: { Kid }, foundedDay: number, arriving: boolean,
	familyName: string,
	-- Set only while this family's house is gone: the moment they give up searching, and
	-- where the search has walked them to so far. `lastHomePos` is kept for every household
	-- (refreshed each sim step) because by the time we notice the home is gone, there is
	-- nothing left to ask where it stood.
	homelessUntil: number?, homelessPos: Vector3?, lastHomePos: Vector3?,
	-- Game-seconds this family's home has gone without power, water or a drain.
	unservedFor: number?,
}

local _households: { [number]: Household } = {}
local _nextHouseholdId = 0
local _nextPersonId = 0
local _workers: { [string]: number } = {}    -- bpId -> citizen workers assigned (filled jobs)
local _driverJobs: { [string]: number } = {} -- industrial bpId -> delivery-truck drivers currently out
local _population = 0
local _travelDebugByPid: { [number]: { [string]: any } } = {}
local _lastDayProcessed = 0
local _reconciledIds: { [string]: boolean } = {}
-- Simulation level-of-detail: scheduler cursor, pid index and the education histogram.
-- Packed into ONE table on purpose -- this module sits at Luau's 200-local-register limit
-- for its main chunk (`Pipe` below is packed for exactly the same reason), so new
-- module-level state has to be fields rather than locals.
--
-- doActivities is the per-step scheduler and its cost grows with the population, so it no
-- longer sweeps every household on every step: it walks a snapshot of household ids with a
-- cursor, spends at most FRAME_BUDGET per step, and resumes where it stopped. The snapshot
-- holds ids, not tables, so a household removed mid-sweep just resolves to nil and is
-- skipped, and one created mid-sweep joins the next sweep -- no insertion or removal site
-- has to know this exists.
-- CORRECTNESS CONSTRAINT: a full sweep must finish inside the narrowest commute window, or
-- an adult sleeps straight through their shift. That window is SHIFT/SCHOOL_WINDOW_HOURS
-- wide (1.25h); at TimeService.DAY_SECONDS 1800 that is ~94 real seconds, i.e. ~47 sim
-- steps at 1x. Keep sweeps well under it -- debugSnapshot reports `sweepSteps` and we warn
-- past SWEEP_WARN, so a city that outgrows the budget shows up instead of going silently
-- still.
local LOD: any = {
	FRAME_BUDGET = 0.004, -- s of scheduler work per sim step
	SWEEP_WARN   = 30,    -- sim steps per full sweep before we warn
	EDU_EVERY    = 4,     -- sim steps between school-demand recomputes

	step = 0,             -- sim steps since boot
	order = {},           -- snapshot of household ids for the sweep in progress
	cursor = 1,           -- resume point into `order`
	sweepSteps = 0,       -- sim steps spent on the sweep in progress
	lastSweepSteps = 0,   -- sim steps the last COMPLETE sweep took

	-- pid -> { h, person, kind }, so the roster "locate" poll is O(1) instead of a full
	-- household scan. Rebuilt at most once per sim step, and only when a lookup misses or a
	-- known mutation (birth / promotion / removal / restore) bumps `pidGen`.
	pidMap = {},
	pidGen = 0,
	pidBuiltGen = -1,
	pidBuiltStep = -1,

	-- Adult education histogram, refreshed by the fused workforce pass. CityEconomyService
	-- polls it at 1Hz and used to trigger a second full households-x-adults scan of its own.
	eduCounts = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 },
	eduTotal = 0,
	eduFresh = false,
}

-- _trips is now ONLY the short off-graph lot pull-out / pull-in line-follows. The
-- on-road leg between two lots is driven by NPCDriverService.DriveDirected (real
-- lane / stop-line / yield / no-overlap AI). onDone fires at the last waypoint.
type Trip = PathFollower.FollowerState & {
	path: { Vector3 }, cum: { number }, dist: number, speed: number,
	onDone: (() -> ())?,
	lastDist: number?, stallTime: number?,
	-- Held at the start until this says go: the gap in traffic a driver waits for before
	-- pulling out of a driveway or turning across the road into one. gateWait caps it.
	gate: (() -> boolean)?, gateWait: number?,
}
local _trips: { [Model]: Trip } = {}
-- Every driveTo call owns one generation. Late arrival/abort callbacks from an older
-- generation cannot move a car after a newer trip has claimed it.
local _carDriveTokens: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local _tripCount = 0       -- cars in an off-graph line-follow leg
local _directedCount = 0   -- cars on the NPCDriverService road leg
local _carCount = 0    -- total citizen cars (driving + parked)
-- One car per household; parked cars are anchored and cheap. The old cap of 90 silently
-- made every household past ~90 carless (newCar() returned nil), which read as "arrival
-- cars never spawn" once the city grew. ponytail: flat cap; despawn far parked cars if
-- model count ever becomes a perf problem.
local MAX_CARS_TOTAL = 12000

local _transitService: any -- public transit; injected in Bootstrap after TransitService exists
-- Tier 2 of the population (CitizenAgentService): a trip with no free slot on the traffic
-- AI, far from every player, still drives its real route in real time -- just unrendered.
local _agentService: any
-- How an adult travels (walk / transit / own car) is TravelModeChoice's call; this file
-- only gathers the facts of the trip. A transit rider leaves the car at home, so every
-- trip a bus line wins is a car that never enters traffic.

-- == Helpers ===================================================================
-- 0 = paused, otherwise the sim/car-movement multiplier.
local function gameSpeed(): number
	return math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
end

local function nav(): any?
	return _roadService and _roadService.getNavigationGraph()
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Citizens")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "Citizens"; f.Parent = city
	end
	return f :: Folder
end

local function buildCar(): Model
	return VehicleFactory.build("CitizenCar", _rng:NextInteger(1, 99))
end

local _outsideConnService: any = nil
-- Staffed service buildings (a solar farm's `jobs`) live in EmergencyService, not in the
-- plot-derived building records. This state hangs off the module table instead of module
-- locals on purpose: the outer scope here is at Luau's 200-local ceiling.
CitizenService._svcKerb = {}

-- Every building view the sim reasons about: BuildingService's plot records plus any
-- staffed service building. Service views carry zone "Service", so the residential and
-- store filters skip them untouched -- only the job tests look at `jobs`.
function CitizenService._svcViews(): { any }
	local views = _buildingService.listBuildings()
	local svc = CitizenService._svc
	if svc and svc.getWorkplaceViews then
		local ok, extra = pcall(svc.getWorkplaceViews)
		if ok and type(extra) == "table" then
			table.clear(CitizenService._svcKerb)
			for _, v in extra do
				table.insert(views, v)
				if typeof(v.kerb) == "Vector3" then CitizenService._svcKerb[v.bpId] = v.kerb end
			end
		end
	end
	return views
end

-- Injected after boot (OutsideConnectionService is created later). Lets arrivals spawn at
-- REAL outside connections (roads dragged to the map edge) instead of any dead-end.
function CitizenService.SetOutsideConnService(svc: any)
	_outsideConnService = svc
end

-- Service buildings (a solar farm, a hospital) that employ staff. Injected in Bootstrap
-- after EmergencyService exists, the same way TransitService is.
function CitizenService.SetEmergencyService(svc: any)
	CitizenService._svc = svc
end

local function roadTip(g: any): Vector3?
	for _, edge in g:GetEdges() do
		if #edge.out == 0 and edge.points and #edge.points > 0 then
			return edge.points[#edge.points]
		end
	end
	return g:RandomPoint()
end

-- How far BEYOND the road network a household spawns -- the length of the imaginary
-- off-map road it drives in on. Deliberately short: a full map-edge trek (thousands of
-- studs over empty grass) drove every arrival for ~80s, which saturated the driving-car
-- budget so every in-city commute/errand teleported instead of driving (empty roads).
local OUTSIDE_SPAWN_DIST = 160

-- An "outside connection": a real road ENTRY point on the graph plus a spawn point just
-- outside it. A newly-arriving household spawns there and drives a short imaginary road in
-- to the entry, then follows real roads to its home -- visibly arriving from outside the
-- city without the off-map trek.
-- Prefers a REAL outside connection (a road dragged to the map edge) picked at random so
-- arrivals spread across the city's entrances instead of all stacking on the one dead-end
-- roadTip() always returned first -- that pile-up gridlocked the cars and starved the
-- driving-car budget, so in-city commutes teleported instead of driving. A small lateral
-- jitter on the spawn keeps cars off each other's exact spot. Falls back to a dead-end
-- when no connection has been placed yet.
-- Spawn point for a new arrival: directly ON the road at a real outside connection (a
-- road dragged to the map edge), picked at random across eligible (in/both) connections.
-- No off-map staging -- the car appears on the connection road and drives straight to its
-- home. Falls back to a dead-end tip when no connection has been placed yet.
-- The ONLY way into the city: a real outside connection (a road dragged to the map edge),
-- picked at random across the eligible (in/both) ones. Returns nil when the map has no
-- connection -- then nobody moves in. There is NO dead-end fallback: this is a simulation,
-- so a household is never conjured onto a random road or into a home from thin air.
-- Rate-limited diagnostic so it's obvious in the output WHY no one is moving in.
local _lastArrivalDiag = 0
local function arrivalDiag(msg: string)
	if os.clock() - _lastArrivalDiag > 15 then
		_lastArrivalDiag = os.clock()
		warn("[CitizenService] move-in blocked: " .. msg)
	end
end

-- Entrance pipes, packed into ONE table: the main chunk sits near Luau's
-- 200-local-register limit, so no new module-scope locals.
-- Pipe rule: a car may spawn at a connection only after the previous car spawned
-- THERE has pulled CLEAR_DIST away (or despawned / stalled out). Different
-- connections admit cars independently, so several movers can enter at once
-- without ever stacking up at a single entrance.
local Pipe = {
	CLEAR_DIST = 60,        -- previous car must pull this far from its spawn point
	TIMEOUT = 30,           -- a stuck/despawned car frees its entrance after this
	REGISTER_TIMEOUT = 180, -- limbo watchdog: family moves in even if the drive dies
	MAX_ARRIVALS_PER_STEP = 4, -- full-demand move-in budget (free entrances self-limit)
	entries = {} :: { { car: Model, spawn: Vector3, at: number } },
}
function Pipe.clearAt(pos: Vector3): boolean
	for i = #Pipe.entries, 1, -1 do
		local e = Pipe.entries[i]
		local cleared = not e.car.Parent or os.clock() - e.at > Pipe.TIMEOUT
		if not cleared then
			-- Same stale-instance trap: a car that is DRIVING reads at its spawn pose for
			-- ever, so the pipe never opened. Ask the sim whether the spawn is still occupied.
			cleared = NPCDriverService.IsPointClear(e.spawn, Pipe.CLEAR_DIST)
			if not cleared then
				local p = e.car:GetPivot().Position
				local dx, dz = p.X - e.spawn.X, p.Z - e.spawn.Z
				cleared = dx * dx + dz * dz > Pipe.CLEAR_DIST * Pipe.CLEAR_DIST
			end
		end
		if cleared then
			table.remove(Pipe.entries, i)
		else
			local dx, dz = pos.X - e.spawn.X, pos.Z - e.spawn.Z
			if dx * dx + dz * dz < Pipe.CLEAR_DIST * Pipe.CLEAR_DIST then return false end
		end
	end
	return true
end
function Pipe.add(car: Model, spawn: Vector3)
	table.insert(Pipe.entries, { car = car, spawn = spawn, at = os.clock() })
end

-- True if any vehicle (household car, through-car, truck, bus) is still sitting
-- within SPAWN_CLEAR_RADIUS of pos. Physical query, so cars owned by other services
-- (ThroughTrafficService) count too. Arrivals defer (retry next pass) rather than
-- spawn on top of a car that has not yet pulled away from the entrance.
local SPAWN_CLEAR_RADIUS = 16
local function spawnBlocked(pos: Vector3): boolean
	local city = Workspace:FindFirstChild("_City")
	if not city then return false end
	local include = {}
	for _, name in { "Citizens", "Trucks", "Buses" } do
		local f = city:FindFirstChild(name)
		if f then table.insert(include, f) end
	end
	if #include == 0 then return false end
	-- A DRIVING car's instance is frozen at its spawn pose (NPCDriverService.IsPointClear),
	-- so ask the sim about those and let the overlap query speak only for PARKED vehicles.
	-- Reading the world alone is what left every entrance "jammed with stalled cars".
	if not NPCDriverService.IsPointClear(pos, SPAWN_CLEAR_RADIUS) then return true end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include
	for _, part in Workspace:GetPartBoundsInRadius(pos, SPAWN_CLEAR_RADIUS, params) do
		local m = part:FindFirstAncestorOfClass("Model")
		if m and not NPCDriverService.IsDirected(m) then return true end
	end
	return false
end

-- ponytail: a car with nowhere legal to park does not stand in the road -- it goes in
-- the household's pocket (out of Workspace: no client renders it, no traffic or spawn
-- query hits it) and comes back at the kerb when someone actually drives. Packed as one
-- table so the main chunk gains a single local (see Pipe -- near Luau's 200-register cap).
local Garage = { folder = nil :: Folder? }
-- Every adult may own a car (TravelModeChoice.ownsCar); the per-car helpers hang off this
-- table further down. One table, not locals, for the same register-limit reason as Garage.
local Cars: any = {
	GATE_MAX_WAIT = 15, -- s a car waits at a driveway for a gap before nosing out anyway
	GAP_SECONDS = 3,    -- s of clear road a driver wants before pulling out or turning in
	UNSEEN_SPEED = 13,  -- studs/s door to door for a car driving its route unrendered
	                    -- (TravelModeChoice's urban average incl. junctions)
	NEAR_SQ = 1000 * 1000, -- within 500 m of a player a trip always drives for real
	-- car -> Tier-2 agent driving it unrendered right now (its real position for a save)
	unseen = setmetatable({}, { __mode = "k" }) :: { [Model]: number },
}
function Garage.stow(car: Model?)
	if not car then return end
	local f = Garage.folder
	if not f then
		f = Instance.new("Folder")
		f.Name = "PocketedCars"
		f.Parent = game:GetService("ServerStorage")
		Garage.folder = f
	end
	PathFollower.forget(car)
	car.Parent = f
end
function Garage.fetch(car: Model?)
	if car and Garage.folder and car.Parent == Garage.folder then car.Parent = _folder end
end
function Garage.clear()
	if Garage.folder then Garage.folder:ClearAllChildren() end
end
-- A mid-rise block's underground garage (BuildingService.getParkSpots.garage). Every flat
-- owns a bay behind the door, so there is nothing to claim: the car drives the baked
-- route (kerb cut -> lot edge -> door), is stowed there like any pocketed car -- out of
-- Workspace, so a full block costs nothing to render or simulate -- and comes back AT
-- the door, facing out, to drive the route in reverse on its next trip. A ParkChoice.
function Garage.home(homeId: string): any
	local spots = _buildingService.getParkSpots(homeId)
	local route = spots and spots.garageRoute
	if not route or not spots.garage then return nil end
	return { cf = spots.garage, approach = route, egress = { route[2], route[1] },
		lotEntry = spots.lotEntry, pocket = true, garage = true }
end

local function newCar(): Model?
	if _carCount >= MAX_CARS_TOTAL then return nil end
	local car = buildCar()
	car.Parent = _folder
	_carCount += 1
	return car
end

local function destroyCar(car: Model?)
	if not car then return end
	_carDriveTokens[car] = (_carDriveTokens[car] or 0) + 1
	if _trips[car] then _trips[car] = nil; _tripCount -= 1 end
	if NPCDriverService.ReleaseDirected(car) then _directedCount = math.max(0, _directedCount - 1) end
	PathFollower.forget(car)
	if car.Parent then car:Destroy() end
	_carDriveTokens[car] = nil
	_carCount -= 1
end

-- A short off-graph line-follow: the in-lot pull-OUT / pull-IN legs (stall <-> lot
-- mouth). Follows the waypoints then fires onDone. The on-road leg BETWEEN two lots
-- is NOT this -- it goes through NPCDriverService.DriveDirected for the real traffic
-- AI (correct lane, stop lines, signals, yielding, no overlap).
-- `lift` overrides the ride height for this leg. A leg that hands the car to the road AI
-- passes the car's own NPCHeightOffset -- the height the AI will hold it at -- so the car does
-- not drop on hand-off; legs that end at a parking stall keep CAR_HEIGHT.
local function lineFollow(car: Model, waypoints: { Vector3 }, speed: number, onDone: (() -> ())?, lift: number?, gate: (() -> boolean)?)
	if #waypoints < 2 then if onDone then onDone() end return end
	local cum = PathFollower.cumOf(waypoints)
	if (cum[#cum] or 0) < 0.5 then if onDone then onDone() end return end
	if _trips[car] == nil then _tripCount += 1 end
	_trips[car] = {
		model = car, heightOffset = lift or CAR_HEIGHT, smoothCFrame = nil, lastSentCFrame = nil, replicateAccum = 0,
		path = waypoints, cum = cum, dist = 0, speed = speed, onDone = onDone, gate = gate,
	}
	PathFollower.seedProximity(car, 0)
end

-- Drive an existing car from its current spot to parkCF along the road graph; it
-- PARKS at parkCF on arrival (not destroyed) and is reused next trip. Falls back
-- to an instant park when there is no path or the driving cap is full.
-- routeFrom (optional) is the position used to PATHFIND onto the graph; the car still
-- starts physically at its own pivot. For an outside-connection arrival this is the real
-- road entry, so the prepended pivot->entry leg becomes the imaginary off-map road.
-- isArrival trips use a lower cap so they can't consume the slots reserved for in-city trips.
-- opts let a trip drive the WHOLE way into / out of a lot, not just to the kerb:
--   fromGraphPoint : where the car re-enters the road graph (the lot it's leaving
--                    hands off here); defaults to the car's current position
--   egress         : in-lot waypoints from the car to fromGraphPoint (pull-out)
--   toGraphPoint   : where the car leaves the road graph (the destination lot mouth);
--                    defaults to parkCF
--   approach       : in-lot waypoints from toGraphPoint to the stall (drive-in)
type DriveOpts = {
	isArrival: boolean?,
	fromGraphPoint: Vector3?,
	toGraphPoint: Vector3?,
	egress: { Vector3 }?,
	approach: { Vector3 }?,
	isValid: (() -> boolean)?,
	attempts: number?,
}
local function driveTo(car: Model, parkCF: CFrame, onArrive: (() -> ())?, opts: DriveOpts?)
	local o = opts or {}
	local token = (_carDriveTokens[car] or 0) + 1
	_carDriveTokens[car] = token

	-- Enforce a single movement owner even if two asynchronous state changes collide.
	if _trips[car] then
		_trips[car] = nil
		_tripCount = math.max(0, _tripCount - 1)
		PathFollower.forget(car)
	end
	if NPCDriverService.ReleaseDirected(car) then
		_directedCount = math.max(0, _directedCount - 1)
	end

	local function active(): boolean
		if not car.Parent or _carDriveTokens[car] ~= token then return false end
		return o.isValid == nil or o.isValid() == true
	end

	local function retry(alreadyOnRoad: boolean)
		task.delay(DRIVE_RETRY_DELAY, function()
			if not active() then return end
			local retryOpts: DriveOpts = table.clone(o)
			retryOpts.attempts = (o.attempts or 0) + 1
			if alreadyOnRoad then
				retryOpts.fromGraphPoint = nil
				retryOpts.egress = nil
			end
			driveTo(car, parkCF, onArrive, retryOpts)
		end)
	end

	local g = nav()
	local from = car:GetPivot().Position
	local graphStart = o.fromGraphPoint or from
	local graphEnd = o.toGraphPoint or parkCF.Position
	local cap = if o.isArrival then MAX_TRIP_CARS else (MAX_TRIP_CARS - RESERVED_ARRIVAL_TRIPS)
	local parkPos = parkCF.Position + Vector3.new(0, CAR_HEIGHT, 0)
	local function parkAndArrive()
		if not active() then return end
		car:PivotTo(parkCF)
		if onArrive then onArrive() end
	end
	-- Retries are bounded: a goal that stays unroutable (or a permanently full trip
	-- budget) must not leave the car sitting at the entrance for the rest of the
	-- session -- after ~60s of failed attempts the trip completes instantly instead.
	if (o.attempts or 0) >= (if o.isArrival then MAX_ARRIVAL_RETRIES else MAX_DRIVE_RETRIES) then
		parkAndArrive()
		return
	end
	if not g or not g:HasEdges() then
		retry(false)
		return
	end

	-- A trip may pull out of (or turn into) a driveway across the centre line, as US law
	-- allows over dashed and double-yellow lines alike (never a median -- NavRouter): both
	-- lot legs below hold at the kerb for a gap in traffic first. Route with THIS car's own
	-- mind, not a shared optimum: two neighbours driving to the same place get different
	-- roads, and each prices the traffic others have committed to by how much it cares.
	local profile = DriverProfile.fromModel(car)
	local ok, road, edgeIds = pcall(function() return g:FindPath(graphStart, graphEnd, true, nil, profile) end)
	if not ok or not road or #road == 0 then
		retry(false)
		return
	end

	-- No room on the traffic AI (the trip cap, or its frame budget). Within 500 m of a player
	-- the trip always gets a real car -- it waits for a slot if the cap is full, since a car
	-- cannot be seen to ghost; far from everyone -- or after waiting its turn -- it drives its
	-- real route unrendered, in the time the route takes, and parks at the other end. Never a
	-- teleport: the family arrives when a car would have.
	local full = (_tripCount + _directedCount) >= cap
	local near = PathFollower.nearestPlayerDistSq(from) <= Cars.NEAR_SQ
	if full or (not near and not NPCDriverService.HasBudget()) then
		local waited = (o.attempts or 0) >= MAX_DRIVE_RETRIES - 1
		if not _agentService or (full and near and not waited) then
			retry(false)
			return
		end
		Garage.stow(car)
		local agentId = _agentService.adoptRoute(road, Cars.UNSEEN_SPEED, function()
			Cars.unseen[car] = nil
			if not active() then return end
			Garage.fetch(car)
			parkAndArrive()
		end)
		if agentId == 0 then
			Garage.fetch(car)
			parkAndArrive()
		else
			Cars.unseen[car] = agentId
		end
		return
	end

	if typeof(edgeIds) ~= "table" or #(edgeIds :: any) == 0 then
		-- No lane-edge route (very short / off-graph): plain line-follow the whole way.
		local path: { Vector3 } = { from }
		if o.egress then for _, p in o.egress do table.insert(path, p) end end
		for _, p in road do table.insert(path, p) end
		if o.approach then for _, p in o.approach do table.insert(path, p) end end
		table.insert(path, parkPos)
		lineFollow(car, path, CAR_SPEED, parkAndArrive)
		return
	end

	local edgeRoute = edgeIds :: { string }
	-- Where the off-graph pull-OUT ends and the road AI begins: the lot mouth we're
	-- leaving, or (no lot) the first road waypoint so the car drives out to the lane.
	local roadHandoff = o.fromGraphPoint or road[1]
	-- Finish the pull-out ON the lane instead of letting the road leg reseat the car there:
	-- these points are the seat the road leg would have snapped to, then a short lead along
	-- the lane, so the car drives that last bit itself and arrives already facing down it.
	local laneEntry = NPCDriverService.LaneEntryPath(edgeRoute[1], roadHandoff)
	local roadStart = if laneEntry then laneEntry[#laneEntry] else roadHandoff

	-- Leg C: turn in from where the car stopped on the lane (across the oncoming lanes when
	-- the route ended on the far side), over the lot mouth, to the stall.
	local function startApproach()
		if not active() then return end
		local stoppedAt = car:GetPivot().Position - Vector3.new(0, CAR_HEIGHT, 0)
		local appPts: { Vector3 } = { stoppedAt, graphEnd }
		if o.approach then for _, p in o.approach do table.insert(appPts, p) end end
		table.insert(appPts, parkPos)
		lineFollow(car, appPts, CAR_SPEED, parkAndArrive, nil,
			function() return NPCDriverService.RoadGapClear(stoppedAt, Cars.GAP_SECONDS) end)
	end

	-- Leg B: drive the ROAD on NPCDriverService's real traffic AI.
	local function startRoad()
		if not active() then return end
		_directedCount += 1
		local started = NPCDriverService.DriveDirected(car, roadStart, graphEnd, edgeRoute,
			function()
				_directedCount = math.max(0, _directedCount - 1)
				if active() then startApproach() end
			end,
			function()
				-- The road leg gave up: the car wedged for good (60s of no progress) or the
				-- road changed under it with no reroute. Re-driving from the same spot just
				-- re-wedges and freezes the lane behind it, so place the car at its
				-- destination instead -- the trip still completes (onArrive fires) and the
				-- road is cleared. This is what stops cars freezing mid-road in a conga-line.
				_directedCount = math.max(0, _directedCount - 1)
				if active() then parkAndArrive() end
			end)
		if not started then
			_directedCount = math.max(0, _directedCount - 1)
			if active() then retry(true) end
		end
	end

	-- Leg A: pull OUT from the current stall across the lot to the road handoff.
	local egressPts: { Vector3 } = { from }
	if o.egress then for _, p in o.egress do table.insert(egressPts, p) end end
	table.insert(egressPts, roadHandoff)
	if laneEntry then for _, p in laneEntry do table.insert(egressPts, p) end end
	lineFollow(car, egressPts, CAR_SPEED, startRoad, tonumber(car:GetAttribute("NPCHeightOffset")),
		function() return NPCDriverService.RoadGapClear(roadHandoff, Cars.GAP_SECONDS) end)
end

local function stepTrips(dt: number)
	-- onDone callbacks may re-add the car to _trips (the next leg) or hand it to
	-- NPCDriverService, so defer them until after the iteration -- never mutate
	-- _trips while iterating it.
	local done: { () -> () } = {}
	for car, t in _trips do
		if not car.Parent then _trips[car] = nil; _tripCount -= 1; PathFollower.forget(car); continue end
		if t.gate then
			-- ponytail: a fixed cap, then go regardless (the proximity clamp still stops a
			-- collision). Give way properly for longer if impatient pull-outs read badly.
			if not t.gate() and (t.gateWait or 0) < Cars.GATE_MAX_WAIT then
				t.gateWait = (t.gateWait or 0) + dt
				continue
			end
			t.gate = nil
		end
		local total = t.cum[#t.cum]
		local dir = if t.smoothCFrame then t.smoothCFrame.LookVector else Vector3.zAxis
		local factor, blocker = PathFollower.getSpeedFactor(car, car:GetPivot().Position, dir)
		t.dist = math.min(total, t.dist + t.speed * dt * factor)
		-- Lot legs never wait at signals. Held by a car on the road network is traffic
		-- (a queue across the driveway): wait for it like any jam. Sustained zero progress
		-- with no such blocker means a mutual block (two cars nose-to-nose at a lot mouth):
		-- skip to the leg's end so the trip continues -- these cars used to freeze at odd
		-- angles across the road forever. A stalled road car is the traffic AI's to rescue.
		if t.dist <= (t.lastDist or -1) + 1e-3 then
			if blocker and NPCDriverService.IsOnRoad(blocker) then
				t.stallTime = 0
			else
				t.stallTime = (t.stallTime or 0) + dt
			end
			if (t.stallTime or 0) > TRIP_STALL_RESCUE then
				t.dist = total
			end
		else
			t.lastDist = t.dist
			t.stallTime = 0
		end
		local pos, pdir = PathFollower.pointAtDist(t.path, t.cum, t.dist)
		PathFollower.place(t, pos, pdir, dt)
		if t.dist >= total - 1e-3 then
			_trips[car] = nil; _tripCount -= 1
			if t.onDone then table.insert(done, t.onDone) end
		end
	end
	for _, cb in done do cb() end
end

-- == Building views ============================================================
local function levelClamp(lvl: number): number
	return math.clamp(lvl or 1, 1, 3)
end

local function jobCapacity(zone: string, level: number): number
	local t = JOB_CAP[zone]
	return if t then t[levelClamp(level)] else 0
end

-- A workplace's slot count: a service building states its own (spec.jobs), a zoned one
-- reads the shared JOB_CAP table by zone and level.
function CitizenService._svcCapacity(b: any): number
	local j = tonumber(b.jobs)
	if j then return math.max(0, math.floor(j)) end
	return jobCapacity(b.zone, b.level)
end

local function isResidentialHomeView(b: any?): boolean
	return typeof(b) == "table" and isResZone(b.zone) and b.abandoned ~= true
end

local function isJobView(b: any?): boolean
	return typeof(b) == "table"
		and (b.zone == "Commercial" or b.zone == "Industrial" or (tonumber(b.jobs) or 0) > 0)
		and b.abandoned ~= true
end

local function homeFocusPosition(homeId: string): Vector3?
	local p = _buildingService.getKerb(homeId)
	if typeof(p) == "Vector3" then return p end
	if _buildingService.getDoor then
		p = _buildingService.getDoor(homeId)
		if typeof(p) == "Vector3" then return p end
	end
	if _buildingService.getBuildingPosition then
		p = _buildingService.getBuildingPosition(homeId)
		if typeof(p) == "Vector3" then return p end
	end
	return nil
end

-- Recompute building fill from real occupancy (residents / workers).
local function syncFill(b: any)
	if isResZone(b.zone) then
		local cap = _buildingService.getResidentCap(b.bpId)
		_buildingService.setOccupancy(b.bpId, b.residents, cap, "residents", b.level)
	elseif b.zone == "Commercial" or b.zone == "Industrial" then
		local cap = jobCapacity(b.zone, b.level)
		-- Citizens plus any delivery drivers currently out from this industrial building
		-- (each active truck occupies one job slot), capped at the building's capacity.
		local filled = (_workers[b.bpId] or 0) + (_driverJobs[b.bpId] or 0)
		_buildingService.setOccupancy(b.bpId, math.min(filled, cap), cap, "jobs", b.level)
	end
end

-- == Population accounting =====================================================
local function recountPopulation()
	local n = 0
	for _, h in _households do
		if not h.arriving then n += #h.adults + #h.kids end
	end
	_population = n
end

function CitizenService.getPopulation(): number
	return _population
end

-- Debug-only live snapshot of the citizen sim (graph readiness, stage histogram,
-- employment, car/trip counts) for diagnosing why agents do or don't move.
function CitizenService.debugSnapshot(): { [string]: any }
	local stages: { [string]: number } = {}
	local withCar, employed, hh = 0, 0, 0
	for _, h in _households do
		hh += 1
		for _, a in h.adults do
			if a.car then withCar += 1 end
			stages[a.stage] = (stages[a.stage] or 0) + 1
			if a.walkerId then stages._walking = (stages._walking or 0) + 1 end
			if a.jobId then employed += 1 end
		end
	end
	local g = nav()
	return {
		households = hh, stages = stages, withCar = withCar, employed = employed,
		cars = _carCount, driving = _tripCount,
		-- Scheduler health: sim steps the last COMPLETE activity sweep took. As this
		-- approaches LOD.SWEEP_WARN the population has outgrown the per-step budget and
		-- adults will start missing their shift windows.
		sweepSteps = LOD.lastSweepSteps, sweepPending = math.max(0, #LOD.order - LOD.cursor + 1),
		navEdges = (g ~= nil and g:HasEdges()) or false,
		sidewalkBuilt = (_walkingService ~= nil and _walkingService.isBuilt ~= nil and _walkingService.isBuilt()) or false,
	}
end

function CitizenService.getStats(): { [string]: number }
	local hh, adults, kids, employed = 0, 0, 0, 0
	for _, h in _households do
		if h.arriving then continue end
		hh += 1; kids += #h.kids
		for _, a in h.adults do
			adults += 1
			if a.jobId then employed += 1 end
		end
	end
	return { households = hh, adults = adults, kids = kids, employed = employed, population = _population, cars = _carCount, driving = _tripCount }
end

-- A delivery truck launching from industrial building `bpId` puts its driver on the
-- clock: claim one of the building's job slots while the truck is out. SupplyService
-- (the fleet owner) calls these; CitizenService stays the sole authority on occupancy.
function CitizenService.reserveDriverJob(bpId: string)
	if typeof(bpId) ~= "string" then return end
	_driverJobs[bpId] = (_driverJobs[bpId] or 0) + 1
end

function CitizenService.releaseDriverJob(bpId: string)
	if typeof(bpId) ~= "string" then return end
	local n = (_driverJobs[bpId] or 0) - 1
	_driverJobs[bpId] = if n > 0 then n else nil
end

-- Healthcare coverage for births, against a clinic list the caller snapshots ONCE. This
-- used to run CollectionService:GetTagged plus a pcall'd GetPivot PER HOUSEHOLD inside a
-- single dailyTick frame -- O(households x clinics) pivot reads in one step. Clinic
-- positions only move when one is built or demolished, so dailyTick gathers them once and
-- every household tests the snapshot.
local function hasHealthcare(clinics: { Vector3 }, pos: Vector3): boolean
	for _, p in clinics do
		if (p - pos).Magnitude <= HEALTH_RADIUS then return true end
	end
	return false
end

-- == Household lifecycle =======================================================
-- Occupied building-lot stalls, keyed bpId.."#"..stallIndex. Without this, stalls were
-- assigned by household-id hash alone and two cars could park inside each other.
local _stallTaken: { [string]: boolean } = {}

-- Free the parking an adult's car currently occupies -- the on-street spot and/or the
-- building-lot stall (no-op if it's parked in a driveway or is driving). Called on
-- every departure and on removal.
local function releaseSpot(a: Adult)
	if a.parkSpotId then
		_parkingService.release(a.parkSpotId)
		a.parkSpotId = nil
	end
	if a.parkStallKey then
		_stallTaken[a.parkStallKey] = nil
		a.parkStallKey = nil
	end
end

-- The driveway is ONE space. The first household on the plot claims it for as long as it
-- lives there -- not per trip, so it is never released by releaseSpot -- and every other
-- household in the building street-parks or uses a car park instead of stacking cars on the
-- same slab. Claims share _stallTaken with the building-lot stalls (one namespace, one
-- clear); "#drive" cannot collide with the numeric stall keys.
local function claimDriveway(homeId: string): (CFrame?, string?)
	local spots = _buildingService.getParkSpots(homeId)
	local cf = if spots then spots.home else nil
	if not cf then return nil, nil end
	local key = homeId .. "#drive"
	if _stallTaken[key] then return nil, nil end
	_stallTaken[key] = true
	return cf, key
end

local function releaseDriveway(a: Adult)
	if not a.driveKey then return end
	_stallTaken[a.driveKey] = nil
	a.driveKey = nil
	a.homeParkCF = nil
end


-- Give the car up entirely: its parking, the driveway it held, the model.
function Cars.drop(a: Adult)
	releaseSpot(a)
	releaseDriveway(a)
	destroyCar(a.car)
	a.car = nil
	a.usingCar = false
end

-- Resolve a pid to its household. A cached entry is trusted only while its household is
-- still the live one under that id. `rebuild` is nested rather than a sibling local so it
-- costs a register in THIS frame instead of the main chunk's (see LOD).
local function findPerson(pid: number): { h: any, person: any, kind: string }?
	local function rebuild()
		table.clear(LOD.pidMap)
		for _, h in _households do
			for _, a in h.adults do LOD.pidMap[a.pid] = { h = h, person = a, kind = "adult" } end
			for _, k in h.kids do LOD.pidMap[k.pid] = { h = h, person = k, kind = "kid" } end
		end
		LOD.pidBuiltGen = LOD.pidGen
	end
	if LOD.pidBuiltGen ~= LOD.pidGen then rebuild() end
	local e = LOD.pidMap[pid]
	if e and _households[e.h.id] == e.h then return e end
	-- Miss: the pid may belong to a citizen created by a path that does not bump the
	-- generation (arrival / restore). Rebuild at most once per sim step, so a UI polling a
	-- dead pid cannot spin a full scan on every request.
	if LOD.pidBuiltStep ~= LOD.step then
		LOD.pidBuiltStep = LOD.step
		rebuild()
		e = LOD.pidMap[pid]
		if e and _households[e.h.id] == e.h then return e end
	end
	return nil
end

local function removeHousehold(id: number, byId: { [string]: any })
	local h = _households[id]
	if not h then return end
	LOD.pidGen += 1
	-- Invalidate every adult's in-flight commute callback and pull its pedestrian, so a
	-- removed household leaves no orphan walker and no late async fire touches freed state.
	for _, a in h.adults do
		_travelDebugByPid[a.pid] = nil
		a.tripId += 1
		if a.walkerId then _walkingService.despawnCommuter(a.walkerId); a.walkerId = nil end
		if a.riderId then _transitService.cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
		if a.jobId then
			_workers[a.jobId] = math.max(0, (_workers[a.jobId] or 1) - 1)
			a.jobId = nil
		end
	end
	for _, kid in h.kids do
		kid.tripId += 1
		if kid.walkerId then _walkingService.despawnCommuter(kid.walkerId); kid.walkerId = nil end
		if kid.stage == "atSchool" and _educationService and _educationService.leaveSchool then
			_educationService.leaveSchool(kid.schoolId)
		end
	end
	if byId[h.homeId] then
		for _ = 1, #h.adults + #h.kids do
			_buildingService.removeResident(h.homeId)
		end
	end
	for _, a in h.adults do Cars.drop(a) end -- the next family to move in gets the drive
	_buildingService.removeHousehold(h.homeId)
	_buildingService.setFamilyName(h.homeId, nil)
	_households[id] = nil
end

-- People factories. Every citizen has a gender and an age; adults also hold a job + jobless
-- timer. Arriving kids are already a few years old; newborns (births) start at age 0.
local function nextPid(): number
	_nextPersonId += 1
	return _nextPersonId
end

local function makeAdult(gender: string, age: number): Adult
	local pid = nextPid()
	return {
		name = NameGen.firstName(_rng, gender), gender = gender, age = age, pid = pid, eduLevel = 0,
		jobId = nil, joblessDays = 0,
		stage = "atHome", tripId = 0, walkerId = nil,
		outKind = nil, outDestId = nil, usingCar = false, ownsCar = TravelModeChoice.ownsCar(pid),
		tripTargetId = nil, tripTargetHome = false,
		commutedWorkDay = 0, commutedHomeDay = 0, nextErrandAt = 0,
	}
end

local function makeKid(): Kid
	local gender = if _rng:NextNumber() < 0.5 then "M" else "F"
	return {
		name = NameGen.firstName(_rng, gender), gender = gender,
		age = _rng:NextInteger(KID_ARRIVE_MIN_AGE, KID_ARRIVE_MAX_AGE), pid = nextPid(), bestTier = 0,
		stage = "atHome", tripId = 0, walkerId = nil, schoolPos = nil, schoolId = nil,
		commutedSchoolDay = 0, commutedHomeDay = 0,
	}
end

-- A kid's final education level on reaching adulthood: the highest school tier they enrolled
-- in, plus university (tier 3) if they finished high school and a university covers home.
local function graduateEduLevel(kid: Kid, home: Vector3?): number
	local level = kid.bestTier
	if level >= 2 and typeof(home) == "Vector3" and _educationService and _educationService.coversTier then
		if _educationService.coversTier(home, 3) then level = 3 end
	end
	return level
end

-- A household can have children only with both a mother and a father present.
local function hasCouple(h: Household): boolean
	local male, female = false, false
	for _, a in h.adults do
		if a.gender == "M" then male = true elseif a.gender == "F" then female = true end
	end
	return male and female
end

local function youngestFemaleAge(h: Household): number
	local best = math.huge
	for _, a in h.adults do
		if a.gender == "F" and a.age < best then best = a.age end
	end
	return best
end

-- A point a short way INTO the city on the connection's inbound lane (the lane heading
-- toward map centre). An arrival spawns HERE rather than on the degree-1 node at the very
-- edge: that tip is shared by the inbound lane and the exit-less outbound (dead-end) lane,
-- so a car that snaps to the latter never gets a route and just sits. 24 studs in removes
-- the ambiguity -- the car is unmistakably on the lane that drives into the city.
local INBOUND_SPAWN_MIN = 24    -- first spawn point in from the edge (clear of the shared dead-end tip)
local INBOUND_SPAWN_STEP = 32   -- step further in to clear a car stalled at the entrance
local INBOUND_SPAWN_TRIES = 5   -- inbound points to consider per connection
-- Spawn points for a connection, grouped BY INBOUND LANE: every lane leaving the map-edge
-- node -- read off the nav graph, not guessed from geometry -- sampled at INBOUND_SPAWN_MIN
-- in and then every STEP further. Several points per lane let an arrival spawn PAST a car
-- stalled at the mouth; several LANES matter because junction turns are assigned per lane,
-- so the single innermost lane the old geometric pick always returned can be a dead end for
-- a given home while the kerbside lane of the same road routes to it fine.
local function inboundLanePoints(g: any, c: any): { { Vector3 } }
	local lanes: { any } = {}
	if g.GetOutgoingEdgesFromNode and typeof(c.nodeId) == "number" then
		lanes = g:GetOutgoingEdgesFromNode(c.nodeId)
	end
	if #lanes == 0 and g.NearestEdgeToward then
		-- Fallback (node id gone stale between rescans): "inbound" = away from the map edge,
		-- opposite the connection's outward normal. Robust when the road meets the edge at an
		-- angle or near a corner, where "toward map centre" picks the outbound lane.
		local normal = c.normal
		local target = if typeof(normal) == "Vector3" and normal.Magnitude > 1e-3
			then c.outer - normal * 200 else Vector3.zero
		local res = g:NearestEdgeToward(c.outer, target)
		if res and res.edge then lanes = { res.edge } end
	end
	local out: { { Vector3 } } = {}
	for _, edge in lanes do
		local pts = edge.points
		if typeof(pts) ~= "table" or #pts < 2 then continue end
		local result: { Vector3 } = {}
		local acc, nextWanted = 0, INBOUND_SPAWN_MIN
		for i = 2, #pts do
			acc += (pts[i] - pts[i - 1]).Magnitude
			while acc >= nextWanted and #result < INBOUND_SPAWN_TRIES do
				-- Coarsely sampled lanes cross two thresholds on one point; taking it twice
				-- would spend a try on a spawn that is not actually further past the stall.
				if result[#result] ~= pts[i] then result[#result + 1] = pts[i] end
				nextWanted += INBOUND_SPAWN_STEP
			end
			if #result >= INBOUND_SPAWN_TRIES then break end
		end
		if #result == 0 then result[1] = pts[#pts] end
		out[#out + 1] = result
	end
	if #out == 0 then out[1] = { c.outer } end
	return out
end

-- Choose an arrival spawn point: scan eligible outside connections (random start so arrivals
-- spread across entrances) and return the first inbound point that is clear of other cars AND
-- whose lane can actually route to the home. Scanning all connections and walking past a
-- stalled car means a single car stuck at one entrance no longer halts all move-ins.
local function pickArrivalSpawn(g: any, homeKerb: Vector3): Vector3?
	if not _outsideConnService then
		arrivalDiag("no outside connection found -- drag a road to the map edge so traffic can enter")
		return nil
	end
	local eligible = {}
	for _, c in _outsideConnService.list() do
		if c.dir ~= "out" then eligible[#eligible + 1] = c end
	end
	if #eligible == 0 then
		arrivalDiag("no outside connection found -- drag a road to the map edge so traffic can enter")
		return nil
	end
	-- Every inbound LANE of every connection that can actually route to this home, in a
	-- random connection order so consecutive arrivals spread across entrances instead of
	-- stacking on one (a stack conga-lines and wedges at the entrance junction).
	local start = _rng:NextInteger(1, #eligible)
	local routable: { { Vector3 } } = {}
	local laneCount = 0
	for k = 0, #eligible - 1 do
		local c = eligible[((start - 1 + k) % #eligible) + 1]
		for _, points in inboundLanePoints(g, c) do
			laneCount += 1
			-- The same search the drive will use (driveTo: allowCrossing), so a home the car
			-- can reach is never reported unreachable: it may finish on EITHER side of the
			-- home's street, which is what failed for a house whose kerb-side lane only runs
			-- away from the entrance. The start is priced, not guessed, so an outbound
			-- dead-end lane at the map edge can no longer be picked. Plain pick as fallback.
			local pathOk, road = pcall(function() return g:FindPath(points[1], homeKerb, true) end)
			if not (pathOk and typeof(road) == "table" and #road > 0) then
				pathOk, road = pcall(function() return g:FindPath(points[1], homeKerb) end)
			end
			if pathOk and typeof(road) == "table" and #road > 0 then
				routable[#routable + 1] = points
			end
		end
	end
	if #routable == 0 then
		-- Name the exact home, the lane the home itself sits on, and every spawn lane tried,
		-- so a broken road join is findable on the map instead of a mystery (LANES overlay
		-- marks dead-end lanes). No home lane at all means the house is not on the network.
		local detail = {}
		for _, c in eligible do
			for _, pts in inboundLanePoints(g, c) do
				table.insert(detail, ("%s spawn=(%d,%d)"):format(tostring(c.id), pts[1].X, pts[1].Z))
			end
		end
		local nearOk, homeNear = pcall(function() return g:NearestEdge(homeKerb) end)
		if not nearOk then homeNear = nil end
		arrivalDiag(("can't route from any of %d inbound lane(s) to the empty home at (%d, %d) [home lane: %s] -- check that its street joins the network (LANES overlay shows dead-end lanes red). tried: %s")
			:format(laneCount, homeKerb.X, homeKerb.Z,
				tostring(homeNear and homeNear.edge and homeNear.edge.id or "NONE"),
				table.concat(detail, ", ")))
		return nil
	end
	-- Prefer a clear entrance point (spreads arrivals across connections).
	for _, points in routable do
		if not spawnBlocked(points[1]) and Pipe.clearAt(points[1]) then return points[1] end
	end
	-- Every entrance is occupied: walk PAST the stalled car, further in on any connection.
	for _, points in routable do
		for i = 2, #points do
			if not spawnBlocked(points[i]) and Pipe.clearAt(points[i]) then return points[i] end
		end
	end
	arrivalDiag("every outside connection that can reach a home is jammed with stalled cars at the entrance")
	return nil
end

-- A move-in is PHYSICAL: the family spawns in a car at an outside connection (any
-- routable one, picked at random), drives to the home, and only counts as resident
-- when the car actually gets there. No car, no route, no parking, no clear entrance
-- -> no move-in this step; the next step simply tries again. driveTo's bounded
-- retries guarantee onArrive eventually fires, and a watchdog registers the family
-- anyway if the drive somehow dies -- so a wedged car can't strand a family in
-- limbo (reserved home, zero residents), the failure that forced the old
-- register-instantly design.
local function tryArrival(home: any): boolean
	local homeKerb = _buildingService.getKerb(home.groupId)
	if not homeKerb then return false end

	local g = nav()
	if not g or not g:HasEdges() or (_tripCount + _directedCount) >= MAX_TRIP_CARS then return false end
	local src = pickArrivalSpawn(g, homeKerb)
	if not src then return false end

	-- Home parking, in order: this plot's driveway if no other household already holds it,
	-- else a free on-street bay near the door, else (inside reserveNearest) a car-park stall
	-- anywhere in reach -- they park there and walk the rest of the way home.
	-- A block with a garage houses every car; only a house has the one-car driveway.
	local garage = Garage.home(home.groupId)
	local homeParkCF, driveKey = nil, nil
	if not garage then homeParkCF, driveKey = claimDriveway(home.groupId) end
	local initialPark: CFrame? = if garage then garage.cf else homeParkCF
	local parkSpotId: any = nil
	if not initialPark then
		local spotId, cf = _parkingService.reserveNearest(homeKerb, ROADSIDE_RADIUS)
		if cf then initialPark = cf; parkSpotId = spotId end
	end
	-- Driveway taken, no free bay AND no car park in reach: the last resort (Cars.roadStop) --
	-- they pull over on the road outside and the car goes in the pocket. Hard-failing here
	-- blocked move-ins outright on roads with no bays. Build a car park and this stops firing.
	if not initialPark then
		initialPark = Cars.roadStop(homeKerb).cf
	end

	local car = newCar()
	if not car then
		if parkSpotId then _parkingService.release(parkSpotId) end
		if driveKey then _stallTaken[driveKey] = nil end
		arrivalDiag("citizen car cap reached -- no car free for a mover")
		return false
	end

	-- The slot is claimed here, at the commit point: everything above can still bail.
	if not _buildingService.addHousehold(home.groupId) then
		destroyCar(car)
		if parkSpotId then _parkingService.release(parkSpotId) end
		if driveKey then _stallTaken[driveKey] = nil end
		return false
	end
	_nextHouseholdId += 1
	local id = _nextHouseholdId
	local hh: Household = {
		id = id, homeId = home.groupId, adults = {}, kids = {},
		foundedDay = _timeService.getDay(), arriving = true,
		familyName = NameGen.familyName(_rng),
	}
	-- A founding couple: one adult male, one adult female, both of child-rearing age,
	-- plus 0-2 children who arrive already a few years old.
	table.insert(hh.adults, makeAdult("M", _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE)))
	table.insert(hh.adults, makeAdult("F", _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE)))
	for _ = 1, _rng:NextInteger(0, 2) do
		table.insert(hh.kids, makeKid())
	end
	-- They arrive in one car, the first car owner's. A family with no car still arrives by
	-- road (a hire car); it goes back once they are in. The other owners' cars appear at
	-- home once the family has moved in (doActivities hands them out).
	local driver = hh.adults[1]
	for _, a in hh.adults do
		if a.ownsCar then driver = a; break end
	end
	driver.car, driver.homeParkCF, driver.parkSpotId, driver.driveKey = car, homeParkCF, parkSpotId, driveKey
	_households[id] = hh
	_buildingService.setFamilyName(home.groupId, hh.familyName)

	-- The family becomes resident when its car reaches the home, not before.
	local registered = false
	local function register()
		if registered or _households[id] ~= hh then return end
		registered = true
		for _ = 1, #hh.adults + #hh.kids do
			if _buildingService.canAcceptResident(home.groupId) then
				_buildingService.addResident(home.groupId)
			end
		end
		hh.arriving = false
	end

	car:PivotTo(CFrame.new(src + Vector3.new(0, CAR_HEIGHT, 0)))
	Pipe.add(car, src)
	driveTo(car, initialPark, function()
		if garage then
			driver.parkEgress = garage.egress
			driver.parkGraphPoint = garage.lotEntry
			Garage.stow(car)
		elseif not homeParkCF and not parkSpotId then
			Garage.stow(car)
			Cars.notePocket(id)
		end
		register()
		if not driver.ownsCar then Cars.drop(driver) end
	end, {
		isArrival = true,
		fromGraphPoint = src,
		toGraphPoint = if garage then garage.lotEntry else nil,
		approach = if garage then garage.approach else nil,
		isValid = function() return _households[id] == hh and driver.car == car end,
	})
	task.delay(Pipe.REGISTER_TIMEOUT, register)
	return true
end

local function seedStarterHouseholds()
	if next(_households) ~= nil then return end
	local launched = 0
	for _, home in _buildingService.getEmptyHomes() do
		if launched >= STARTER_HOUSEHOLDS then break end
		if tryArrival(home) then
			launched += 1
		end
	end
end

local function door(bpId: string): Vector3?
	return _buildingService.getDoor(bpId) or _buildingService.getKerb(bpId) or CitizenService._svcKerb[bpId]
end

-- Buildings with a job opening (commercial/industrial, served, not abandoned, below
-- capacity). A workplace without power, water or a drain hires NOBODY: nothing runs in there, so the shifts it would
-- have offered do not exist. That is the whole penalty -- the staff already on the books
-- keep their jobs, so the demand PowerService bills does not collapse the moment the lights
-- go out and start the grid flapping on and off. What it costs the player is growth: the
-- locals it would have employed stay jobless, and jobless locals are what stops new
-- families moving in (CityStatsService weights unemployment against residential demand).
local function openJobs(views: { any }): { string }
	local out: { string } = {}
	for _, b in views do
		if (b.zone == "Commercial" or b.zone == "Industrial" or (tonumber(b.jobs) or 0) > 0)
			and not b.abandoned and b.powered ~= false and b.watered ~= false and b.drained ~= false then
			-- Delivery drivers out from an industrial building hold real job slots, so a
			-- citizen can only take a slot they leave free.
			local filled = (_workers[b.bpId] or 0) + (_driverJobs[b.bpId] or 0)
			if filled < CitizenService._svcCapacity(b) then
				table.insert(out, b.bpId)
			end
		end
	end
	return out
end

-- Commercial stores a household can shop at.
local function stores(views: { any }): { string }
	local out: { string } = {}
	for _, b in views do
		if b.zone == "Commercial" and not b.abandoned then
			table.insert(out, b.bpId)
		end
	end
	return out
end

-- A chosen parking spot plus how to drive into and out of it. For a lot stall,
-- `approach` is the in-lot path from `lotEntry` to the stall and `egress` is its
-- reverse; both are nil for a roadside / driveway spot (straight drive). `spotId`
-- is set only for a reserved roadside apron spot. `pocket` means there was no legal
-- spot at ALL: the car is stowed out of the world rather than left standing in the road.
type ParkChoice = { cf: CFrame, spotId: string?, stallKey: string?, approach: { Vector3 }?, egress: { Vector3 }?, lotEntry: Vector3?, pocket: boolean?, garage: boolean? }

local function reverseRoute(route: { Vector3 }): { Vector3 }
	local out: { Vector3 } = {}
	for i = #route, 1, -1 do table.insert(out, route[i]) end
	return out
end

-- Where a household's car parks at a destination building: a lot stall (drives the
-- baked in-lot route), else a free on-street apron spot near it, else pocketed at the kerb.
local function pickBuildingPark(h: Household, bpId: string): ParkChoice?
	local spots = _buildingService.getParkSpots(bpId)
	if spots and #spots.stalls > 0 then
		-- First FREE stall, scanning from the household hash so cars still spread across
		-- the lot. Reserved here, released via releaseSpot; a full lot falls through to
		-- roadside/kerb instead of stacking two cars in one stall.
		local n = #spots.stalls
		local start = (h.id - 1) % n
		for k = 0, n - 1 do
			local i = ((start + k) % n) + 1
			local key = bpId .. "#" .. tostring(i)
			if not _stallTaken[key] then
				_stallTaken[key] = true
				local stall = spots.stalls[i]
				return { cf = stall.cf, stallKey = key, approach = stall.route, egress = reverseRoute(stall.route), lotEntry = spots.lotEntry }
			end
		end
	end
	local kerb = _buildingService.getKerb(bpId)
	if kerb then
		local id, cf = _parkingService.reserveNearest(kerb, ROADSIDE_RADIUS)
		if cf then return { cf = cf, spotId = id } end
		return Cars.roadStop(kerb)
	end
	return nil
end

-- Where an adult's car parks at HOME: the driveway if THIS adult holds it (one per plot),
-- else a roadside apron spot near the door, else the nearest car-park stall in reach
-- (reserveNearest's own fallback) and the driver walks home from it, else pocketed.
local function pickHomePark(h: Household, a: Adult): ParkChoice?
	local garage = Garage.home(h.homeId)
	if garage then return garage end
	if a.homeParkCF then return { cf = a.homeParkCF } end
	local kerb = _buildingService.getKerb(h.homeId)
	if kerb then
		local id, cf = _parkingService.reserveNearest(kerb, ROADSIDE_RADIUS)
		if cf then return { cf = cf, spotId = id } end
		return Cars.roadStop(kerb)
	end
	return nil
end

-- A car owner without a car gets one, parked at home: a new adult, a family that just
-- moved in or was re-housed, a car lost to a despawn. `parkedAt` (a restored save) puts it
-- back in the bay it stood in when that bay still exists; `away` means it was left away from
-- home (at work), so it goes back there even if its owner holds the driveway.
function Cars.give(h: Household, a: Adult, parkedAt: CFrame?, away: boolean?)
	local car = newCar()
	if not car then return end
	a.car = car
	if not a.driveKey then a.homeParkCF, a.driveKey = claimDriveway(h.homeId) end
	local park: ParkChoice? = nil
	if parkedAt and (away or not a.homeParkCF) then
		local id, cf = _parkingService.reserveNearest(parkedAt.Position, 6)
		if cf and (cf.Position - parkedAt.Position).Magnitude <= 6 then
			park = { cf = cf, spotId = id }
		elseif id then
			_parkingService.release(id)
		end
		-- ponytail: a workplace lot stall is CitizenService's own (_stallTaken), not a
		-- ParkingService bay, and its key is not saved -- stand the car where it was, unreserved.
		if not park and away then park = { cf = parkedAt } end
	end
	park = park or pickHomePark(h, a)
	if not park then return end
	car:PivotTo(park.cf)
	a.parkSpotId = park.spotId
	a.parkEgress = park.egress
	a.parkGraphPoint = park.lotEntry
	if park.pocket then Garage.stow(car) end
end

-- The last resort when there is nowhere legal to leave the car: pull over on the road
-- outside, the driver gets out and the car goes in the pocket (Garage) -- it stands nowhere
-- and blocks nothing, and comes back on the road right there when they drive off. Never on
-- the pavement. Costs happiness (notePocket -> CityStatsService).
function Cars.roadStop(kerb: Vector3): ParkChoice
	local g = nav()
	local near = g and g:NearestEdge(kerb)
	if near and near.distance < ROADSIDE_RADIUS then
		local pts = near.edge.points
		local p = pts[near.index]
		local q = pts[math.min(near.index + 1, #pts)]
		if (q - p).Magnitude < 1e-3 then q = p + near.edge.toDir end
		local stop = p + Vector3.new(0, RoadConstants.ROAD_THICKNESS * 0.5, 0)
		return { cf = CFrame.lookAt(stop, stop + Vector3.new(q.X - p.X, 0, q.Z - p.Z)), pocket = true }
	end
	return { cf = CFrame.new(kerb), pocket = true }
end

-- Households that had nowhere to park today (dailyTick turns it into a happiness stat).
Cars.pocketedToday = {} :: { [number]: boolean }
function Cars.notePocket(householdId: number)
	Cars.pocketedToday[householdId] = true
end

-- A pocketed car comes back on the road only when that bit of road is clear, so it never
-- appears inside another car; `go` runs once it is out (or straight away if it was parked).
-- A jam over the spot holds it as long as the jam lasts, like any car waiting to pull out.
function Cars.fetchWhenClear(car: Model, go: () -> ())
	if not (Garage.folder and car.Parent == Garage.folder) then go(); return end
	if NPCDriverService.IsPointClear(car:GetPivot().Position, 10) then
		Garage.fetch(car)
		go()
		return
	end
	task.delay(0.5, Cars.fetchWhenClear, car, go)
end

-- Studs from the nearest place this adult's car could be left to `toDoor`, as they would
-- judge it before setting off; nil when there is nowhere at all. Home with a driveway or a
-- garage is at the door; a destination with a free lot stall is too.
function Cars.parkWalk(h: Household, a: Adult, destId: string?, toDoor: Vector3): number?
	if destId == h.homeId and (a.homeParkCF or Garage.home(h.homeId)) then return 0 end
	if destId and destId ~= h.homeId then
		local spots = _buildingService.getParkSpots(destId)
		for i = 1, if spots then #spots.stalls else 0 do
			if not _stallTaken[destId .. "#" .. tostring(i)] then return 0 end
		end
	end
	return _parkingService.distanceToFree(toDoor, ROADSIDE_RADIUS)
end

-- How much slower than free-flow the roads between two points are right now: the BPR
-- slowdown averaged over a few lanes sampled along the way. Jams make the car dearer, so
-- when the roads fill up the people a bus line serves start taking it.
function Cars.congestion(g: any, from: Vector3, to: Vector3): number
	local sum, n = 0, 0
	for i = 1, 5 do
		local near = g:NearestEdge(from:Lerp(to, (i - 0.5) / 5))
		if near and near.distance < ROADSIDE_RADIUS then
			sum += NavCost.bprFactor(g:GetEdgeCongestion(near.edge.id))
			n += 1
		end
	end
	return if n > 0 then sum / n else 1
end

-- A citizen's display label for its pedestrian model: the person's name + family name.
local function personLabel(h: Household, a: Adult): string
	return a.name .. " " .. h.familyName
end

local function kidLabel(h: Household, k: Kid): string
	return k.name .. " " .. h.familyName
end

-- == Displaced families ========================================================
-- A house coming down does not delete the people inside it. They take to the street, walk
-- vacancy to vacancy for SECS looking for a room, move in if they find one, and leave the
-- city only if they don't. Packed into ONE table for the same reason as LOD/Pipe: this
-- chunk sits at Luau's 200-local-register limit, so new state goes in fields.
local Homeless: any = {
	SECS = 90, -- real seconds of house-hunting before a family gives up on the city
}

-- Take the vacancy they walked to, if it is still free when they get there.
function Homeless.moveIn(h: Household, bpId: string): boolean
	if not h.homelessUntil then return false end
	if not _buildingService.addHousehold(bpId) then return false end
	h.homeId = bpId
	h.homelessUntil = nil
	h.homelessPos = nil
	for _ = 1, #h.adults + #h.kids do
		if _buildingService.canAcceptResident(bpId) then _buildingService.addResident(bpId) end
	end
	_buildingService.setFamilyName(bpId, h.familyName)
	return true
end

-- One step for a household whose home view is gone. Returns true when it is time to remove
-- them: the search ran out, or they were still moving in and never really arrived.
function Homeless.step(h: Household): boolean
	if h.arriving then return true end

	if not h.homelessUntil then
		h.homelessUntil = os.clock() + Homeless.SECS
		h.homelessPos = h.lastHomePos
		-- Give the old address back. A no-op when the house is rubble, but an ABANDONED home
		-- still holds their household slot and residents, and they do not live there now.
		for _ = 1, #h.adults + #h.kids do _buildingService.removeResident(h.homeId) end
		_buildingService.removeHousehold(h.homeId)
		_buildingService.setFamilyName(h.homeId, nil)
		-- The driveway went with the house; they search on foot.
		for _, a in h.adults do Cars.drop(a) end
		for _, a in h.adults do
			a.tripId += 1
			if a.walkerId then _walkingService.despawnCommuter(a.walkerId); a.walkerId = nil end
			if a.riderId then _transitService.cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
			a.stage, a.outKind, a.outDestId, a.usingCar = "atHome", nil, nil, false
			a.tripTargetId, a.tripTargetHome = nil, false
		end
		for _, k in h.kids do
			k.tripId += 1
			if k.walkerId then _walkingService.despawnCommuter(k.walkerId); k.walkerId = nil end
			k.stage = "atHome"
		end
	end
	if os.clock() >= h.homelessUntil then return true end

	-- ponytail: ONE walker represents the family on the hunt -- they knock on one vacancy at
	-- a time. Walk everybody if a crowd of movers ever needs to be visible.
	local a = h.adults[1]
	if not a or a.walkerId or not h.homelessPos then return false end
	local vacancies = _buildingService.getEmptyHomes()
	if #vacancies == 0 then return false end -- nowhere to knock: wait out the clock and leave
	local pick = vacancies[_rng:NextInteger(1, #vacancies)]
	if typeof(pick.doorPos) ~= "Vector3" then return false end

	a.tripId += 1
	local trip = a.tripId
	a.walkerId = _walkingService.spawnCommuter(h.homelessPos, pick.doorPos, function()
		if _households[h.id] ~= h or a.tripId ~= trip then return end
		a.walkerId = nil
		h.homelessPos = pick.doorPos
		Homeless.moveIn(h, pick.groupId)
	end, personLabel(h, a), { gender = a.gender, kind = "adult", seed = a.pid })
	return false
end

-- Walk, bus or own car for one adult's trip: TravelModeChoice decides from the facts
-- gathered here (distance, the car, where it could park, traffic on the way, the best bus).
local function chooseTravelMode(
	h: Household,
	a: Adult,
	fromDoor: Vector3?,
	toDoor: Vector3?,
	canDrive: boolean
): (string, any?)
	if not fromDoor or not toDoor then
		return if canDrive then "drive" else "walk", nil
	end

	-- A citizen who drove out must bring that same car back. Allowing a fresh choice here
	-- stranded cars at workplaces and stations.
	if a.usingCar and canDrive then
		_travelDebugByPid[a.pid] = {
			chosen = "drive",
			reason = "Drove here, so this trip must bring the car home.",
			directDistance = flatDist(fromDoor, toDoor),
			forced = true,
		}
		return "drive", nil
	end

	local destId = if a.tripTargetHome then h.homeId else a.tripTargetId
	local g = nav()
	local transitEstimate = if _transitService then _transitService.estimateTrip(fromDoor, toDoor) else nil
	local trip: TravelModeChoice.Trip = {
		pid = a.pid,
		age = a.age,
		distance = flatDist(fromDoor, toDoor),
		canDrive = canDrive,
		parkWalk = if canDrive then Cars.parkWalk(h, a, destId, toDoor) else nil,
		congestion = if canDrive and g then Cars.congestion(g, fromDoor, toDoor) else 1,
		transit = if transitEstimate and transitEstimate.usable then transitEstimate else nil,
	}
	local chosen, costs = TravelModeChoice.choose(trip)
	_travelDebugByPid[a.pid] = {
		chosen = chosen,
		reason = if chosen == "transit" then "Public transport has the lowest door-to-door time, fare and hassle."
			elseif chosen == "drive" then "Driving has the lowest travel, parking and fuel cost."
			else "Walking has the lowest combined time and effort.",
		directDistance = trip.distance,
		walkScore = costs.walk,
		driveScore = costs.drive,
		transitScore = costs.transit,
		transitTime = if transitEstimate then transitEstimate.timeSeconds else nil,
		transitFare = if transitEstimate then transitEstimate.fare else nil,
		parkWalk = trip.parkWalk,
		congestion = trip.congestion,
		canDrive = canDrive,
	}
	return chosen, if chosen == "transit" then transitEstimate else nil
end

function CitizenService.AdminAddPopulation(requested: number): { [string]: any }
	local remaining = math.clamp(math.floor(tonumber(requested) or 0), 1, 5000)
	local added = 0
	local householdsAdded = 0
	for _, home in _buildingService.getEmptyHomes() do
		if remaining <= 0 then break end
		local cap = FAMILY_MAX
		local take = math.min(remaining, cap)
		if take <= 0 then continue end
		if not _buildingService.addHousehold(home.groupId) then continue end

		_nextHouseholdId += 1
		local h: Household = {
			id = _nextHouseholdId,
			homeId = home.groupId,
			adults = {},
			kids = {},
			foundedDay = _timeService.getDay(),
			arriving = false,
			familyName = NameGen.familyName(_rng),
		}
		local adultCount = math.min(take, 2)
		for i = 1, adultCount do
			table.insert(h.adults, makeAdult(if i % 2 == 1 then "M" else "F", _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE)))
		end
		for _ = adultCount + 1, take do table.insert(h.kids, makeKid()) end

		for _, a in h.adults do
			if a.ownsCar then Cars.give(h, a) end
		end

		_households[h.id] = h
		_buildingService.setFamilyName(h.homeId, h.familyName)
		for _ = 1, take do
			if _buildingService.canAcceptResident(h.homeId) then _buildingService.addResident(h.homeId) end
		end
		_buildingService.setOccupancy(h.homeId, take, cap, "residents", home.level)
		added += take
		remaining -= take
		householdsAdded += 1
	end
	recountPopulation()
	return {
		ok = added > 0,
		added = added,
		population = _population,
		households = householdsAdded,
		error = if added > 0 then nil else "No empty residential capacity is available.",
	}
end

local function isSchoolAge(k: Kid): boolean
	return k.age >= SCHOOL_AGE_MIN and k.age <= SCHOOL_AGE_MAX
end

-- Inject the transit data owner (Bootstrap event-linking). Optional: commuters fall back
-- to driving / walking if it is never set.
function CitizenService.SetTransitService(ts: any)
	_transitService = ts
end

function CitizenService.SetAgentService(svc: any)
	_agentService = svc
end

-- A real ride for one adult: walk to the board stop, wait there until a vehicle of the line
-- comes with a free seat, ride it to the alight stop, walk on to the door. If nothing with
-- room comes in their patience they walk the whole way from the stop instead.
local function rideTransit(h: Household, a: Adult, trip: number, fromDoor: Vector3, toDoor: Vector3,
	estimate: any, board: any, label: string, look: any, onArrive: () -> ())
	local function stale(): boolean
		return _households[h.id] == nil or a.tripId ~= trip
	end
	local function walkOn(from: Vector3)
		a.riderId = nil
		a.waitPos = nil
		if stale() then return end
		a.walkerId = _walkingService.spawnCommuter(from, toDoor, function()
			if stale() then return end
			a.walkerId = nil
			onArrive()
		end, label, look)
	end
	a.walkerId = _walkingService.spawnCommuter(fromDoor, board.pos, function()
		if stale() then return end
		a.walkerId = nil
		a.waitPos = board.pos
		a.riderId = _transitService.waitForRide(estimate.routeId, estimate.boardStopId, estimate.alightStopId,
			function() a.waitPos = nil end,
			walkOn,
			function() walkOn(board.pos) end)
	end, label, look)
end

-- Generic one-way journey for one adult, fully simulated: walked, ridden or driven in their
-- own car, as chooseTravelMode decides. `parkPicker` is called only on the drive path.
-- onArrive fires once at the destination. Every callback is tripId-guarded on the adult,
-- so a superseded / restarted trip can't desync the legs.
local function journey(h: Household, a: Adult, trip: number, fromDoor: Vector3?, toDoor: Vector3?,
	wantCar: boolean, parkPicker: (() -> ParkChoice?)?, onArrive: () -> ())
	local label = personLabel(h, a)
	local look = { gender = a.gender, kind = "adult", seed = a.pid }
	local function stale(): boolean
		return _households[h.id] == nil or a.tripId ~= trip
	end
	local canDrive = wantCar and a.car ~= nil and parkPicker ~= nil
	local mode, transitEstimate = chooseTravelMode(h, a, fromDoor, toDoor, canDrive)

	if mode == "transit" and transitEstimate and fromDoor and toDoor and _transitService then
		local board = _transitService.getStop(transitEstimate.boardStopId)
		local alight = _transitService.getStop(transitEstimate.alightStopId)
		if board and alight then
			rideTransit(h, a, trip, fromDoor, toDoor, transitEstimate, board, label, look, onArrive)
			return
		end
		mode = "walk"
	end

	if mode ~= "drive" then
		a.walkerId = _walkingService.spawnCommuter(fromDoor, toDoor, function()
			if stale() then return end
			a.walkerId = nil
			onArrive()
		end, label, look)
		return
	end

	a.usingCar = true
	local car = a.car :: Model
	car:SetAttribute("CitizenPid", a.pid)
	car:SetAttribute("TripPurpose", if a.tripTargetHome then "Returning home"
		elseif a.outKind == "work" then "Commuting to assigned workplace"
		elseif a.outKind == "shop" then "Shopping errand"
		elseif a.outKind == "apply" then "Travelling to a job application"
		else "Citizen trip")
	-- Leg 1: walk from the door to the parked car.
	a.walkerId = _walkingService.spawnCommuter(fromDoor, car:GetPivot().Position, function()
		if stale() then return end
		a.walkerId = nil
		releaseSpot(a) -- pull the car out of the spot it currently occupies
		local choice = (parkPicker :: any)() :: ParkChoice?
		if not choice or not choice.cf then
			-- Parking disappeared while the citizen was walking to the car. Leave the car
			-- where it is and finish this leg on foot instead of moving it invisibly.
			a.usingCar = false
			if toDoor then
				a.walkerId = _walkingService.spawnCommuter(car:GetPivot().Position, toDoor, function()
					if stale() then return end
					a.walkerId = nil
					onArrive()
				end, label, look)
			else
				onArrive()
			end
			return
		end
		a.parkSpotId = choice.spotId
		a.parkStallKey = choice.stallKey
		-- How to LEAVE the spot the car is in right now (stored when it last parked).
		local prevEgress = a.parkEgress
		local prevGraph = a.parkGraphPoint
		-- Leg 2: pull out of the old spot, drive the road, drive INTO the new stall. A car
		-- that was pocketed reappears on the road where it was left, once that is clear.
		Cars.fetchWhenClear(car, function()
		if stale() then return end
		driveTo(car, choice.cf, function()
			if stale() then return end
			-- Remember how to leave THIS spot on the next trip.
			a.parkEgress = choice.egress
			a.parkGraphPoint = choice.lotEntry
			-- Into the block's own garage: the car is gone and its driver is already indoors.
			if choice.garage then
				Garage.stow(car)
				onArrive()
				return
			end
			-- No legal spot: they got out on the road and the car goes in the pocket now.
			if choice.pocket then
				Garage.stow(car)
				Cars.notePocket(h.id)
			end
			-- Leg 3: walk from the parked car to the destination door, then enter.
			a.walkerId = _walkingService.spawnCommuter(choice.cf.Position, toDoor, function()
				if stale() then return end
				a.walkerId = nil
				onArrive()
			end, label, look)
		end, {
			fromGraphPoint = prevGraph,
			egress = prevEgress,
			toGraphPoint = choice.lotEntry,
			approach = choice.approach,
			isValid = function() return not stale() end,
		})
		end)
	end, label, look)
end

-- Walk/drive one adult home and settle them to "atHome". If they took the family car out,
-- they bring it back and release it here.
local function returnHome(h: Household, a: Adult)
	if _households[h.id] == nil then return end
	a.tripId += 1
	local trip = a.tripId
	if a.walkerId then _walkingService.despawnCommuter(a.walkerId); a.walkerId = nil end
	if a.riderId then _transitService.cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
	local fromDoor = if a.outDestId then door(a.outDestId) else nil
	a.stage = "transit"
	a.tripTargetId = h.homeId
	a.tripTargetHome = true
	journey(h, a, trip, fromDoor, door(h.homeId), a.usingCar, function() return pickHomePark(h, a) end, function()
		a.stage = "atHome"
		a.outKind = nil
		a.outDestId = nil
		a.tripTargetId = nil
		a.tripTargetHome = false
		a.usingCar = false
	end)
end

-- On arrival at a workplace to APPLY: this adult takes a still-open job if one remains.
-- Delivery drivers out from the building also hold slots, so count them against capacity.
local function applyForJob(h: Household, a: Adult, destId: string, cap: number)
	if a.jobId then return end
	if ((_workers[destId] or 0) + (_driverJobs[destId] or 0)) >= cap then return end
	if not (_buildingService.getKerb(destId) or CitizenService._svcKerb[destId]) then return end -- gone while travelling
	_workers[destId] = (_workers[destId] or 0) + 1
	a.jobId = destId
	a.joblessDays = 0
end

-- On arrival at a store to SHOP: spend money, crediting the store's revenue to the city.
local function doShopping(h: Household, destId: string)
	if not _buildingService.getKerb(destId) then return end
	-- Buy real goods off the store's shelf. An empty shelf earns nothing -- the
	-- supply-chain penalty for an understocked shop -- which keeps commercial demand
	-- up until the player builds the industry + roads to keep it stocked.
	local bought = _supplyService.consumeStock(destId, Const.SUPPLY_SHOP_BASKET)
	if bought <= 0 then return end
	-- Retail income is tracked (drained by the economy tick) so the budget panel can
	-- show it as its own line, instead of silently appearing in the treasury.
	if _economyService.addRetailIncome then
		_economyService.addRetailIncome(bought * Const.SUPPLY_SHOP_PRICE)
	else
		_economyService.credit(bought * Const.SUPPLY_SHOP_PRICE)
	end
end

-- One adult's daily WORK trip out; they stay at work until their own homebound window.
local function startWork(h: Household, a: Adult, jobId: string)
	a.tripId += 1
	local trip = a.tripId
	if a.walkerId then _walkingService.despawnCommuter(a.walkerId); a.walkerId = nil end
	if a.riderId then _transitService.cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
	a.stage = "transit"
	a.outKind = "work"
	a.outDestId = jobId
	a.tripTargetId = jobId
	a.tripTargetHome = false
	journey(h, a, trip, door(h.homeId), door(jobId), true, function() return pickBuildingPark(h, jobId) end, function()
		a.stage = "atWork"
		a.tripTargetId = nil
		a.tripTargetHome = false
	end)
end

-- An errand round-trip for one adult: go to a workplace/store, do the action (apply /
-- shop) on arrival, return home.
local function startErrand(h: Household, a: Adult, kind: string, destId: string, cap: number)
	a.tripId += 1
	local trip = a.tripId
	if a.walkerId then _walkingService.despawnCommuter(a.walkerId); a.walkerId = nil end
	if a.riderId then _transitService.cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
	a.stage = "transit"
	a.outKind = kind
	a.outDestId = destId
	a.tripTargetId = destId
	a.tripTargetHome = false
	journey(h, a, trip, door(h.homeId), door(destId), true, function() return pickBuildingPark(h, destId) end, function()
		if kind == "apply" then
			applyForJob(h, a, destId, cap)
		elseif kind == "shop" then
			doShopping(h, destId)
		end
		returnHome(h, a)
	end)
end

local function startSchool(h: Household, k: Kid): boolean
	if not _educationService or not _educationService.getNearestSchool or not isSchoolAge(k) then return false end
	local fromDoor = door(h.homeId)
	if not fromDoor then return false end
	local schoolPos, schoolId = _educationService.getNearestSchool(fromDoor, k.age, k.schoolId)
	if typeof(schoolPos) ~= "Vector3" or typeof(schoolId) ~= "number" then
		k.schoolId = nil
		k.schoolPos = nil
		return false
	end
	k.tripId += 1
	local trip = k.tripId
	if k.walkerId then _walkingService.despawnCommuter(k.walkerId); k.walkerId = nil end
	k.stage = "transit"
	k.schoolPos = schoolPos
	k.schoolId = schoolId
	local function stale(): boolean
		return _households[h.id] == nil or k.tripId ~= trip
	end
	k.walkerId = _walkingService.spawnCommuter(fromDoor, schoolPos, function()
		if stale() then return end
		k.walkerId = nil
		if _educationService.hasSchool and not _educationService.hasSchool(schoolId, k.age) then
			k.stage = "atHome"
			k.schoolId = nil
			k.schoolPos = nil
			return
		end
		if _educationService.enterSchool then _educationService.enterSchool(schoolId) end
		k.stage = "atSchool"
	end, kidLabel(h, k), { gender = k.gender, kind = "kid" })
	return true
end

local function returnFromSchool(h: Household, k: Kid): boolean
	if _households[h.id] == nil then return false end
	local toDoor = door(h.homeId)
	local fromDoor = k.schoolPos
	if typeof(toDoor) ~= "Vector3" then return false end
	if typeof(fromDoor) ~= "Vector3" then
		k.stage = "atHome"
		k.schoolPos = nil
		return true
	end
	k.tripId += 1
	local trip = k.tripId
	if k.walkerId then _walkingService.despawnCommuter(k.walkerId); k.walkerId = nil end
	if k.stage == "atSchool" and _educationService and _educationService.leaveSchool then
		_educationService.leaveSchool(k.schoolId)
	end
	k.stage = "transit"
	local function stale(): boolean
		return _households[h.id] == nil or k.tripId ~= trip
	end
	k.walkerId = _walkingService.spawnCommuter(fromDoor, toDoor, function()
		if stale() then return end
		k.walkerId = nil
		k.stage = "atHome"
		k.schoolPos = nil
		if k.schoolId and _educationService and _educationService.hasSchool and not _educationService.hasSchool(k.schoolId, k.age) then
			k.schoolId = nil
		end
	end, kidLabel(h, k), { gender = k.gender, kind = "kid" })
	return true
end

local SHIFT_WINDOW_HOURS = 1.25

-- Where people go and why. One table, not locals (register limit, see LOD).
--   Destinations follow the planners' gravity model: a place is chosen in proportion to
--   1 / (distance + D0)^BETA, so the corner shop wins most trips and a store across the
--   city only some. Shopping decays steeply (BETA 2), jobs gently (BETA 1): people commute
--   much further than they walk for milk. Before this every trip picked uniformly from the
--   whole city, which is where half the cross-town traffic came from.
--   Walks: an adult at home in the day now and then goes out for a stroll -- a real walk
--   to a spot a few blocks off and back, on the pavement, like any other trip.
local Trips: any = {
	SHOP_BETA = 2, JOB_BETA = 1, D0 = 100,
	WALK_CHANCE = 0.02,          -- per idle sim step, while it is light out
	WALK_MIN = 150, WALK_MAX = 450, -- studs out from the door
	WALK_FROM_HOUR = 8, WALK_TO_HOUR = 20,
}

function Trips.pickNear(ids: { string }, from: Vector3?, beta: number): string?
	if #ids == 0 then return nil end
	if not from then return ids[_rng:NextInteger(1, #ids)] end
	local weights, total = table.create(#ids), 0
	for i, id in ids do
		local p = door(id)
		local w = if p then 1 / (flatDist(from, p) + Trips.D0) ^ beta else 0
		weights[i] = w
		total += w
	end
	if total <= 0 then return ids[_rng:NextInteger(1, #ids)] end
	local roll = _rng:NextNumber() * total
	for i, w in weights do
		roll -= w
		if roll <= 0 then return ids[i] end
	end
	return ids[#ids]
end

function Trips.walk(h: Household, a: Adult): boolean
	local home = door(h.homeId)
	if not home then return false end
	local angle = _rng:NextNumber() * math.pi * 2
	local reach = _rng:NextNumber(Trips.WALK_MIN, Trips.WALK_MAX)
	local spot = _walkingService.getNearestPoint(home + Vector3.new(math.cos(angle), 0, math.sin(angle)) * reach, 60)
	if typeof(spot) ~= "Vector3" then return false end
	a.tripId += 1
	local trip = a.tripId
	a.stage = "transit"
	a.outKind = "walk"
	local label = personLabel(h, a)
	local look = { gender = a.gender, kind = "adult", seed = a.pid }
	local function stale(): boolean
		return _households[h.id] == nil or a.tripId ~= trip
	end
	a.walkerId = _walkingService.spawnCommuter(home, spot, function()
		if stale() then return end
		a.walkerId = _walkingService.spawnCommuter(spot, home, function()
			if stale() then return end
			a.walkerId = nil
			a.stage = "atHome"
			a.outKind = nil
		end, label, look)
	end, label, look)
	return true
end

local function idHash(text: string): number
	local n = 0
	for i = 1, #text do n = (n * 31 + string.byte(text, i)) % 9973 end
	return n
end

local function inHourWindow(frac: number, startHour: number, endHour: number): boolean
	local startFrac = (startHour % 24) / 24
	local endFrac = (endHour % 24) / 24
	if startFrac <= endFrac then
		return frac >= startFrac and frac < endFrac
	end
	return frac >= startFrac or frac < endFrac
end

local function shiftHours(jobView: any): (number, number)
	local hash = idHash(tostring(jobView.bpId or ""))
	if jobView.zone == "Industrial" then
		if hash % 7 == 0 then return 18, 26 end -- night production crew
		return 6, 14
	elseif jobView.zone == "Commercial" then
		if hash % 11 == 0 then return 18, 26 end -- late shop / service shift
		if hash % 3 == 0 then return 11, 20 end -- lunch/evening retail overlap
		return 9, 18
	end
	return 7, 16
end

local function householdShiftOffsetHours(householdId: number): number
	return ((householdId * 17) % 50) / 60
end

local function schoolShiftOffsetHours(pid: number): number
	return ((pid * 13) % 45) / 60
end

local function isShiftStart(jobView: any, householdId: number): boolean
	local startHour = shiftHours(jobView)
	local offset = householdShiftOffsetHours(householdId)
	return inHourWindow(_timeService.getDayFraction(), startHour + offset, startHour + offset + SHIFT_WINDOW_HOURS)
end

local function isShiftEnd(jobView: any, householdId: number): boolean
	local _, endHour = shiftHours(jobView)
	local offset = householdShiftOffsetHours(householdId)
	return inHourWindow(_timeService.getDayFraction(), endHour + offset, endHour + offset + SHIFT_WINDOW_HOURS)
end

local function isSchoolStart(k: Kid): boolean
	local offset = schoolShiftOffsetHours(k.pid)
	return inHourWindow(_timeService.getDayFraction(), SCHOOL_START_HOUR + offset, SCHOOL_START_HOUR + offset + SCHOOL_WINDOW_HOURS)
end

local function isSchoolEnd(k: Kid): boolean
	local offset = schoolShiftOffsetHours(k.pid)
	return inHourWindow(_timeService.getDayFraction(), SCHOOL_END_HOUR + offset, SCHOOL_END_HOUR + offset + SCHOOL_WINDOW_HOURS)
end

-- Educated adults (well/highly) prefer commercial/office work; everyone falls back to any
-- opening. Soft preference -- they still take an industrial job if that's all there is, which
-- surfaces as the over-education pressure stat rather than a hard block.
local function pickJobFor(a: Adult, jobs: { string }, byId: { [string]: any }, home: Vector3?): string?
	if #jobs == 0 then return nil end
	if a.eduLevel >= 2 then
		local pref: { string } = {}
		for _, id in jobs do
			local b = byId[id]
			if b and b.zone == "Commercial" then table.insert(pref, id) end
		end
		if #pref > 0 then return Trips.pickNear(pref, home, Trips.JOB_BETA) end
	end
	return Trips.pickNear(jobs, home, Trips.JOB_BETA)
end

-- Per-step citizen scheduler. Each employed ADULT commutes to their OWN workplace on
-- that workplace's shift; an unemployed adult travels to an opening to APPLY; any idle
-- adult makes occasional SHOPPING trips. Adults act independently -- two in one home can
-- be at two different buildings -- so the family car is claimed first-come (others walk).
local function doActivities(views: { any }, byId: { [string]: any })
	local day = _timeService.getDay()
	local globalToWork = _timeService.isWorkboundWindow()
	local globalToHome = _timeService.isHomeboundWindow()
	local now = os.clock()

	local cachedJobs: { string }? = nil
	local cachedStores: { string }? = nil

	-- Resume the round-robin sweep; a finished sweep re-snapshots the household ids.
	if LOD.cursor > #LOD.order then
		table.clear(LOD.order)
		for id in _households do table.insert(LOD.order, id) end
		LOD.cursor = 1
		LOD.lastSweepSteps = LOD.sweepSteps
		if LOD.sweepSteps > LOD.SWEEP_WARN then
			warn(string.format("[CitizenService] activity sweep took %d sim steps for %d households -- adults may miss shift windows; raise LOD.FRAME_BUDGET", LOD.sweepSteps, #LOD.order))
		end
		LOD.sweepSteps = 0
	end
	LOD.sweepSteps += 1
	local deadline = os.clock() + LOD.FRAME_BUDGET

	while LOD.cursor <= #LOD.order do
		local h = _households[LOD.order[LOD.cursor]]
		LOD.cursor += 1
		-- A homeless family runs its own search loop (Homeless.step); every routine below
		-- reads h.homeId, which no longer resolves to anything.
		if h == nil or h.arriving or h.homelessUntil then continue end
		-- Every car owner at home has their car: a new adult buys one, a family that just
		-- moved in or was re-housed gets theirs, and a car despawned out from under us (e.g.
		-- cleared while wedged at an outside connection) is replaced rather than used dead.
		for _, a in h.adults do
			if a.car and not a.car.Parent and not a.usingCar then Cars.drop(a) end
			if a.ownsCar and not a.car and a.stage == "atHome" then Cars.give(h, a) end
		end

		for _, k in h.kids do
			if not isSchoolAge(k) or k.stage == "transit" then continue end
			local hasSchool = k.schoolId ~= nil and _educationService and _educationService.hasSchool and _educationService.hasSchool(k.schoolId, k.age)
			if hasSchool and _educationService.getSchoolTier then k.bestTier = math.max(k.bestTier, _educationService.getSchoolTier(k.schoolId)) end
			if k.stage == "atSchool" and not hasSchool then
				returnFromSchool(h, k)
				continue
			end
			if k.stage == "atHome" and k.commutedSchoolDay ~= day and isSchoolStart(k) then
				if startSchool(h, k) then k.commutedSchoolDay = day end
				continue
			elseif k.stage == "atSchool" and k.commutedHomeDay ~= day and isSchoolEnd(k) then
				if returnFromSchool(h, k) then k.commutedHomeDay = day end
				continue
			end
		end

		for _, a in h.adults do
			if a.stage == "transit" then continue end

			local jobId = a.jobId
			local jobView = if jobId then byId[jobId] else nil

			-- Self-heal: an adult stuck atWork whose workplace vanished (abandoned or
			-- removed) would dead-end there forever. Send them home so they re-seek work.
			if a.stage == "atWork" and not jobView then
				returnHome(h, a)
				continue
			end

			local toWork = if jobView then isShiftStart(jobView, h.id) else globalToWork
			local toHome = if jobView then isShiftEnd(jobView, h.id) else globalToHome

			-- Daily work commute for an employed adult.
			if jobId then
				if toWork and a.stage == "atHome" and a.commutedWorkDay ~= day then
					a.commutedWorkDay = day
					startWork(h, a, jobId)
					continue
				elseif toHome and a.stage == "atWork" and a.commutedHomeDay ~= day then
					a.commutedHomeDay = day
					returnHome(h, a)
					continue
				end
			end

			-- Everything below acts only from home.
			if a.stage ~= "atHome" then continue end

			-- Job hunt: an unemployed adult heads to an opening to apply. A short randomised
			-- stagger keeps a wave of arrivals from flooding the roads on the same step; the
			-- transit state self-throttles each adult to one application trip at a time.
			if not jobId and now >= a.nextErrandAt then
				cachedJobs = cachedJobs or openJobs(views)
				if #cachedJobs > 0 then
					local destId = pickJobFor(a, cachedJobs, byId, door(h.homeId))
					if not destId then continue end
					local b = byId[destId]
					a.nextErrandAt = now + _rng:NextNumber(2, 6)
					startErrand(h, a, "apply", destId, if b then jobCapacity(b.zone, b.level) else 0)
					continue
				end
			end

			-- Shopping: an occasional trip to a commercial store, earning it money. Kept
			-- allowed during the work day so idle adults keep commercial traffic alive.
			if now < a.nextErrandAt then continue end
			if _rng:NextNumber() < SHOP_CHANCE then
				cachedStores = cachedStores or stores(views)
				local destId = Trips.pickNear(cachedStores :: { string }, door(h.homeId), Trips.SHOP_BETA)
				if destId then
					a.nextErrandAt = now + ERRAND_COOLDOWN
					startErrand(h, a, "shop", destId, 0)
					continue
				end
			end

			-- A walk for its own sake, while it is light out.
			local hour = _timeService.getDayFraction() * 24
			if hour >= Trips.WALK_FROM_HOUR and hour <= Trips.WALK_TO_HOUR
				and _rng:NextNumber() < Trips.WALK_CHANCE and Trips.walk(h, a) then
				a.nextErrandAt = now + ERRAND_COOLDOWN
				continue
			end
		end

		if os.clock() >= deadline then break end
	end
end

-- Families do not sit out a dark, dry or backed-up home forever. Past a grace period each
-- household rolls every sim step to pack up and leave the city -- likelier with each
-- utility missing -- so a street without water empties over minutes, one family at a
-- time, not all at once. Fixing it resets the clock. A table of fields, not locals: the
-- main chunk is at the register limit (see LOD).
local Utility: any = {
	GRACE        = 120,  -- game-seconds a home may go without before anyone thinks of leaving
	LEAVE_CHANCE = 0.03, -- per sim step, per missing utility, once past the grace
}

-- Out on a trip right now. Removing a household mid-trip despawns the car and the citizen
-- the instant they meet -- the "parked roadside car vanishes as the person gets in" glitch
-- -- so a family that has decided to leave does it once everyone is home.
function Utility.midTrip(h: Household): boolean
	for _, a in h.adults do
		if a.stage == "transit" or a.walkerId ~= nil then return true end
		if a.car and (_trips[a.car] ~= nil or NPCDriverService.IsDirected(a.car)) then return true end
	end
	for _, kid in h.kids do
		if kid.stage == "transit" or kid.walkerId ~= nil then return true end
	end
	return false
end

function Utility.step(byId: { [string]: any })
	local leaving: { number } = {}
	for id, h in _households do
		if h.arriving then continue end
		local home = byId[h.homeId]
		if not home then continue end
		local missing = (if home.powered == false then 1 else 0)
			+ (if home.watered == false then 1 else 0)
			+ (if home.drained == false then 1 else 0)
		if missing == 0 then h.unservedFor = nil; continue end
		h.unservedFor = (h.unservedFor or 0) + SIM_STEP
		if h.unservedFor >= Utility.GRACE and _rng:NextNumber() < Utility.LEAVE_CHANCE * missing
			and not Utility.midTrip(h) then
			leaving[#leaving + 1] = id
		end
	end
	for _, id in leaving do removeHousehold(id, byId) end
end

local function dailyTick(byId: { [string]: any })
	local toRemove: { number } = {}
	-- Snapshot clinic positions once for the whole daily pass (see hasHealthcare).
	local clinics: { Vector3 } = {}
	for _, inst in CollectionService:GetTagged("Healthcare") do
		if inst:IsA("Model") or inst:IsA("BasePart") then
			local ok, p = pcall(function() return inst:GetPivot().Position end)
			if ok then table.insert(clinics, p) end
		end
	end
	for id, h in _households do
		if h.arriving then continue end

		local anyJob = false
		local allJoblessLong = #h.adults > 0
		for _, a in h.adults do
			if a.jobId then anyJob = true; a.joblessDays = 0 else a.joblessDays += 1 end
			if a.joblessDays < LEAVE_JOBLESS_DAYS then allJoblessLong = false end
		end

		if allJoblessLong then
			-- They leave on a later tick once everyone is settled back home.
			if not Utility.midTrip(h) then
				table.insert(toRemove, id)
			end
			continue
		end

		-- Everyone ages one step. Kids who reach adulthood become job-seeking adults.
		for _, a in h.adults do a.age += AGE_PER_DAY end
		for i = #h.kids, 1, -1 do
			local kid = h.kids[i]
			kid.age += AGE_PER_DAY
			if kid.age >= AGE_ADULT then
				if kid.walkerId then _walkingService.despawnCommuter(kid.walkerId) end
				if kid.stage == "atSchool" and _educationService and _educationService.leaveSchool then
					_educationService.leaveSchool(kid.schoolId)
				end
				table.remove(h.kids, i)
				LOD.pidGen += 1
				table.insert(h.adults, {
					name = kid.name, gender = kid.gender, age = kid.age, pid = kid.pid, eduLevel = graduateEduLevel(kid, door(h.homeId)), tripTargetId = nil, tripTargetHome = false,
					jobId = nil, joblessDays = 0,
					stage = "atHome", tripId = 0, walkerId = nil,
					outKind = nil, outDestId = nil, usingCar = false, ownsCar = TravelModeChoice.ownsCar(kid.pid),
					commutedWorkDay = 0, commutedHomeDay = 0, nextErrandAt = 0,
				})
			end
		end

		-- Birth: a mother+father couple (mother still of child-bearing age), with healthcare
		-- coverage and room, occasionally has a baby (starts at age 0).
		if #h.kids < MAX_KIDS and anyJob and hasCouple(h) and youngestFemaleAge(h) <= MOTHER_FERTILE_MAX then
			local homeKerb = _buildingService.getKerb(h.homeId)
			if homeKerb and hasHealthcare(clinics, homeKerb) and _buildingService.canAcceptResident(h.homeId) then
				if _rng:NextNumber() < BIRTH_CHANCE then
					local baby = makeKid()
					baby.age = 0
					table.insert(h.kids, baby)
					LOD.pidGen += 1
					_buildingService.addResident(h.homeId)
				end
			end
		end
	end
	for _, id in toRemove do removeHousehold(id, byId) end
	-- Share of households that found nowhere to park today: a city without parking is an
	-- unhappy one (CityStatsService).
	local households, pocketed = 0, 0
	for id in _households do
		households += 1
		if Cars.pocketedToday[id] then pocketed += 1 end
	end
	table.clear(Cars.pocketedToday)
	if _cityStatsService.setParkingStats then
		_cityStatsService.setParkingStats({ pocketedFraction = if households > 0 then pocketed / households else 0 })
	end
end

local function syncEducationDemand()
	if not _educationService or not _educationService.setPupilDemand then return end
	local eligible = 0
	local assigned = 0
	for _, h in _households do
		if h.arriving then continue end
		local home = door(h.homeId)
		for _, k in h.kids do
			if not isSchoolAge(k) then continue end
			eligible += 1
			local schoolId = k.schoolId
			if schoolId and _educationService.hasSchool and _educationService.hasSchool(schoolId, k.age) then
				assigned += 1
			elseif typeof(home) == "Vector3" and _educationService.getNearestSchool then
				local _, candidateId = _educationService.getNearestSchool(home, k.age, nil)
				if typeof(candidateId) == "number" then assigned += 1 end
			end
		end
	end
	_educationService.setPupilDemand(eligible, assigned)
end

-- Summarise the adult workforce's education for the economy: the educated share, and the
-- share of EMPLOYED adults over-educated for their job (well/highly-educated stuck in basic
-- industry). CityStatsService turns over-education into commercial demand + lower happiness.
-- One traversal, two consumers: the workforce summary CityStatsService reads, and the
-- education histogram CityEconomyService taxes on. These were two separate full
-- households-x-adults scans per sim step.
local function pushWorkforceEducation(byId: { [string]: any })
	local total, employed, educated, over = 0, 0, 0, 0
	local c0, c1, c2, c3 = 0, 0, 0, 0
	for _, h in _households do
		if h.arriving then continue end
		for _, a in h.adults do
			total += 1
			local lvl = math.clamp(math.floor(tonumber(a.eduLevel) or 0), 0, 3)
			if lvl == 0 then c0 += 1 elseif lvl == 1 then c1 += 1 elseif lvl == 2 then c2 += 1 else c3 += 1 end
			if a.eduLevel >= 2 then educated += 1 end
			if a.jobId then
				employed += 1
				local jv = byId[a.jobId]
				if a.eduLevel >= 2 and jv and jv.zone == "Industrial" then over += 1 end
			end
		end
	end
	LOD.eduCounts[0], LOD.eduCounts[1], LOD.eduCounts[2], LOD.eduCounts[3] = c0, c1, c2, c3
	LOD.eduTotal = total
	LOD.eduFresh = true
	if not _cityStatsService or not _cityStatsService.setWorkforce then return end
	_cityStatsService.setWorkforce({
		totalAdults = total,
		employed = employed,
		educatedFraction = if total > 0 then educated / total else 0,
		overeducatedFraction = if employed > 0 then over / employed else 0,
	})
	-- Ridership rides along on the same push: a used bus network lifts residential
	-- move-in demand (CityStatsService's `transit` factor).
	if _cityStatsService.setTransitStats and _transitService and _transitService.getMonthlyRiders then
		_cityStatsService.setTransitStats({ riders = _transitService.getMonthlyRiders() })
	end
end

-- Adult population split by education level (0 Uneducated, 1 Educated, 2 Well, 3 Highly).
-- The economy uses this to tax residents by income bracket. Served from the histogram the
-- workforce pass already built; the live scan below is the fallback for callers that ask
-- before the first sim step has run (or during a restore).
function CitizenService.getEducationBreakdown(): { counts: { [number]: number }, total: number }
	if LOD.eduFresh then
		return { counts = table.clone(LOD.eduCounts), total = LOD.eduTotal }
	end
	local counts = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
	local total = 0
	for _, h in _households do
		if h.arriving then continue end
		for _, a in h.adults do
			local lvl = math.clamp(math.floor(tonumber(a.eduLevel) or 0), 0, 3)
			counts[lvl] += 1
			total += 1
		end
	end
	return { counts = counts, total = total }
end

local function simStep()
	if _restoring then return end
	LOD.step += 1
	local views = CitizenService._svcViews()
	local byId: { [string]: any } = {}
	for _, b in views do byId[b.bpId] = b end

	-- CitizenService is the sole authority on occupancy. Take over each building the
	-- first time we see it -- clearing the old abstract sim's baked residents/fill so
	-- real households become the only source of fill. This is per-building (not a
	-- one-shot flag) on purpose: the city slot loads its buildings AFTER this loop
	-- first runs at boot, and the old one-shot reconcile consumed itself over an empty
	-- building set, so every restored building kept its baked fill -- which
	-- CityStatsService read as a half-full city, driving residential demand negative so
	-- no household ever moved in and the city froze at the starter seed.
	for _, b in views do
		if not _reconciledIds[b.bpId] then
			_reconciledIds[b.bpId] = true
			if isResZone(b.zone) and b.residents then
				for _ = 1, b.residents do _buildingService.removeResident(b.bpId) end
			elseif b.zone == "Commercial" or b.zone == "Industrial" then
				_workers[b.bpId] = nil
			end
		end
	end

	-- Drop reconcile marks for buildings that no longer exist.
	for bpId in _reconciledIds do
		if not byId[bpId] then _reconciledIds[bpId] = nil end
	end

	-- Homes/jobs that no longer exist or no longer match their role. One traversal:
	-- a household whose home is gone goes on the removal list and skips job validation
	-- (removeHousehold releases its job slots anyway); everyone else is validated in place.
	-- This was two full passes, the second of them households-x-adults.
	local deadHomes: { number } = {}
	for id, h in _households do
		local homeView = byId[h.homeId]
		if not isResidentialHomeView(homeView) then
			-- Not "delete the family": they go house-hunting, and only the ones who find
			-- nothing inside Homeless.SECS actually leave the city.
			if Homeless.step(h) then table.insert(deadHomes, id) end
			continue
		end
		-- Where the search starts from if this house ever comes down.
		h.lastHomePos = homeView.position or h.lastHomePos
		-- A home can come BACK (an abandoned one recovers). Clear the search state or the
		-- family stays skipped by doActivities forever, living in a house they never leave.
		h.homelessUntil = nil
		h.homelessPos = nil
		for _, a in h.adults do
			if a.jobId and not isJobView(byId[a.jobId]) then
				_workers[a.jobId] = math.max(0, (_workers[a.jobId] or 1) - 1)
				a.jobId = nil
			end
		end
	end
	for _, id in deadHomes do removeHousehold(id, byId) end
	Utility.step(byId)

	local day = _timeService.getDay()
	if day > _lastDayProcessed then
		_lastDayProcessed = day
		dailyTick(byId)
	end

	pushWorkforceEducation(byId)
	seedStarterHouseholds()

	-- Demand scales the ARRIVAL RATE instead of hard-gating it: full demand fills the
	-- whole per-step budget, low demand is a slow trickle, and even a struggling city
	-- gets the odd hopeful family (who leave again via the jobless churn if it stays
	-- bad) -- so arrivals can never deadlock and the city always feels alive.
	-- Movers are pulled by jobs/reputation, not pushed away by the empty homes they
	-- move into -- vacancy only suppresses the construction-gating demand bar.
	local rDemand = if _cityStatsService.getMoveInDemand
		then tonumber(_cityStatsService.getMoveInDemand()) or 0
		else tonumber(_cityStatsService.getDemand().R) or 0
	local arriveChance = math.clamp(ARRIVE_BASE_CHANCE + rDemand, ARRIVE_MIN_CHANCE, 1)
	-- Several movers may enter at once -- one per free entrance (the per-connection
	-- spawn pipes keep them from stacking) -- scaled by how badly people want in.
	local budget = if _rng:NextNumber() < arriveChance
		then math.max(1, math.ceil(math.clamp(rDemand, 0, 1) * Pipe.MAX_ARRIVALS_PER_STEP))
		else 0
	if budget > 0 then
		local launched = 0
		for _, home in _buildingService.getEmptyHomes() do
			if launched >= budget then break end
			if tryArrival(home) then
				launched += 1
			end
		end
	end

	doActivities(views, byId)
	-- School demand only feeds the education panel and coverage bar, so it does not need
	-- recomputing every step; the per-kid getNearestSchool probes are the expensive part.
	if LOD.step % LOD.EDU_EVERY == 0 then syncEducationDemand() end

	for _, b in views do syncFill(b) end
	recountPopulation()
end

local function cframeToData(cf: CFrame): { number }
	return { cf:GetComponents() }
end

local function dataToCFrame(data: any): CFrame?
	if typeof(data) ~= "table" then return nil end
	local c: { number } = table.create(12)
	for i = 1, 12 do
		local n = tonumber(data[i])
		if not n then return nil end
		c[i] = n
	end
	return CFrame.new(table.unpack(c))
end

local function roundCarNumber(n: number): number
	return math.floor(n * 100 + 0.5) / 100
end

local function cframeToCarData(cf: CFrame): { number }
	local pos = cf.Position
	local look = cf.LookVector
	local yaw = math.deg(math.atan2(-look.X, -look.Z))
	return { roundCarNumber(pos.X), roundCarNumber(pos.Y), roundCarNumber(pos.Z), roundCarNumber(yaw) }
end

local function carDataToCFrame(data: any): CFrame?
	if typeof(data) ~= "table" then return nil end
	local x = tonumber(data[1])
	local y = tonumber(data[2])
	local z = tonumber(data[3])
	local yaw = tonumber(data[4])
	if not x or not y or not z or not yaw then return nil end
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yaw), 0)
end

local function buildingSaveKey(view: any): string?
	return if typeof(view) == "table" and typeof(view.saveKey) == "string" and view.saveKey ~= "" then view.saveKey else nil
end

local function resolveSavedKey(keys: any, value: any): string?
	if typeof(value) == "number" and typeof(keys) == "table" then
		local key = keys[value]
		return if typeof(key) == "string" then key else nil
	end
	return if typeof(value) == "string" then value else nil
end

local function makeKeyIndexer(): ({ string }, (string?) -> number?)
	local keys: { string } = {}
	local byKey: { [string]: number } = {}
	local function intern(key: string?): number?
		if not key then return nil end
		local existing = byKey[key]
		if existing then return existing end
		local idx = #keys + 1
		keys[idx] = key
		byKey[key] = idx
		return idx
	end
	return keys, intern
end

local function activeCarState(h: Household, holderIdx: number, byId: { [string]: any }, intern: (string?) -> number?, homeKeyIdx: number): any?
	local holder = h.adults[holderIdx]
	local car = holder.car
	if not car or not car.Parent or holder.stage ~= "transit" or holder.usingCar ~= true then
		return nil
	end
	-- A car driving unrendered stands wherever its plan says, not where it was stowed.
	local unseenAt = if Cars.unseen[car] and _agentService then _agentService.getPosition(Cars.unseen[car]) else nil
	local pose = if unseenAt then CFrame.new(unseenAt + Vector3.new(0, CAR_HEIGHT, 0)) else car:GetPivot()

	local homeTarget = holder.tripTargetHome == true
	local targetId = if homeTarget then h.homeId else (holder.tripTargetId or holder.outDestId)
	if typeof(targetId) ~= "string" then return nil end

	local targetKeyIdx = homeKeyIdx
	if not homeTarget then
		local targetView = byId[targetId]
		if not targetView then return nil end
		targetKeyIdx = intern(buildingSaveKey(targetView))
		if not targetKeyIdx then return nil end
	end

	return {
		c = cframeToCarData(pose),
		a = holderIdx,
		d = targetKeyIdx,
		hm = if homeTarget then true else nil,
		k = holder.outKind,
	}
end

function CitizenService.serialize(): { [string]: any }
	local views = CitizenService._svcViews()
	local byId: { [string]: any } = {}
	for _, b in views do
		byId[b.bpId] = b
	end

	local keys, intern = makeKeyIndexer()
	local homes: { any } = {}
	for _, h in _households do
		if h.arriving then continue end
		local homeView = byId[h.homeId]
		if not isResidentialHomeView(homeView) then continue end
		local homeKeyIdx = intern(buildingSaveKey(homeView))
		if not homeKeyIdx then continue end

		local edu = { 0, 0, 0, 0 }
		local jobsByKey: { [string]: number } = {}
		for _, a in h.adults do
			local level = math.clamp(math.floor(tonumber(a.eduLevel) or 0), 0, 3)
			edu[level + 1] += 1
			local jobView = if a.jobId then byId[a.jobId] else nil
			local jobKey = buildingSaveKey(jobView)
			if jobKey then
				jobsByKey[jobKey] = (jobsByKey[jobKey] or 0) + 1
			end
		end

		local jobs: { any } = {}
		for jobKey, count in jobsByKey do
			local jobKeyIdx = intern(jobKey)
			if jobKeyIdx then
				table.insert(jobs, { jobKeyIdx, count })
			end
		end

		local row = {
			h = homeKeyIdx,
			a = #h.adults,
			k = #h.kids,
			e = edu,
			j = jobs,
			f = h.foundedDay,
		}
		-- Per adult (index into the restored adults): `o` who owns a car, `cv` cars out on a
		-- trip, `cp` parked cars saved where they stand -- one left in a car park belongs back
		-- in that stall on load, not at the kerb. A pocketed car (ServerStorage) stands
		-- nowhere, so it re-picks a spot on load. Pre-2026-09-25 saves carry one household
		-- car as `v` / `p` instead; restore reads both.
		-- `w`: adults at work at save time (they come back there, not at home). A parked car
		-- entry's 3rd field marks a car left at the workplace, which its driver takes home.
		local owners, driving, parked, atWork = {}, {}, {}, {}
		for i, a in h.adults do
			if a.ownsCar then table.insert(owners, i) end
			if a.stage == "atWork" and a.jobId then table.insert(atWork, i) end
			local vehicle = activeCarState(h, i, byId, intern, homeKeyIdx)
			if vehicle then
				table.insert(driving, vehicle)
			elseif a.car and not _trips[a.car] and a.car:IsDescendantOf(Workspace) then
				table.insert(parked, { i, cframeToCarData(a.car:GetPivot()), if a.usingCar then true else nil })
			end
		end
		row.o = if #owners > 0 then owners else nil
		row.cv = if #driving > 0 then driving else nil
		row.cp = if #parked > 0 then parked else nil
		row.w = if #atWork > 0 then atWork else nil
		table.insert(homes, row)
	end

	return {
		version = 2,
		nextHouseholdId = _nextHouseholdId,
		nextPersonId = _nextPersonId,
		keys = keys,
		homes = homes,
	}
end

local function makeRestoredHousehold(homeId: string, foundedDay: any): Household
	_nextHouseholdId += 1
	return {
		id = _nextHouseholdId,
		homeId = homeId,
		adults = {},
		kids = {},
		foundedDay = math.max(1, math.floor(tonumber(foundedDay) or _timeService.getDay())),
		arriving = false,
		familyName = NameGen.familyName(_rng),
	}
end

local function addRestoredPeople(h: Household, adultCount: number, kidCount: number, eduCounts: any)
	local eduRemaining = { 0, 0, 0, 0 }
	if typeof(eduCounts) == "table" then
		for i = 1, 4 do
			eduRemaining[i] = math.max(0, math.floor(tonumber(eduCounts[i]) or 0))
		end
	end

	for i = 1, adultCount do
		local gender = if i % 2 == 1 then "M" else "F"
		local adult = makeAdult(gender, _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE))
		for level = 3, 0, -1 do
			local idx = level + 1
			if eduRemaining[idx] > 0 then
				eduRemaining[idx] -= 1
				adult.eduLevel = level
				break
			end
		end
		table.insert(h.adults, adult)
	end

	for _ = 1, kidCount do
		table.insert(h.kids, makeKid())
	end
end

local function assignRestoredJobs(h: Household, jobs: any, keys: any, bySaveKey: { [string]: any })
	if typeof(jobs) ~= "table" then return end
	local adultIndex = 1
	for _, row in jobs do
		if adultIndex > #h.adults then break end
		if typeof(row) ~= "table" then continue end
		local jobKey = resolveSavedKey(keys, row[1] or row.j)
		local count = math.max(0, math.floor(tonumber(row[2] or row.n) or 0))
		local jobView = if jobKey then bySaveKey[jobKey] else nil
		if count <= 0 or not isJobView(jobView) then continue end

		local jobId = jobView.bpId
		local cap = jobCapacity(jobView.zone, jobView.level)
		local open = math.max(0, cap - (_workers[jobId] or 0) - (_driverJobs[jobId] or 0))
		local take = math.min(count, open, #h.adults - adultIndex + 1)
		for _ = 1, take do
			local adult = h.adults[adultIndex]
			adult.jobId = jobId
			adult.stage = "atHome"
			_workers[jobId] = (_workers[jobId] or 0) + 1
			adultIndex += 1
		end
	end
end

-- Cars as saved: who owns one, and the parked ones back where they stood (Cars.give reserves
-- that bay by position; a spot edited away since falls back to the normal home pick). A
-- car that was out driving is resumed by resumeRestoredCar; owners with neither get theirs
-- from doActivities. Legacy saves had ONE household car: it goes to the first owner.
local function restoreCars(h: Household, row: any)
	if typeof(row.o) == "table" then
		for _, a in h.adults do a.ownsCar = false end
		for _, i in row.o do
			local a = h.adults[tonumber(i) or 0]
			if a then a.ownsCar = true end
		end
	end
	if typeof(row.w) == "table" then
		for _, i in row.w do
			local a = h.adults[tonumber(i) or 0]
			if a and a.jobId then
				a.stage, a.outKind, a.outDestId = "atWork", "work", a.jobId
			end
		end
	end
	if typeof(row.cp) == "table" then
		for _, entry in row.cp do
			local a = if typeof(entry) == "table" then h.adults[tonumber(entry[1]) or 0] else nil
			if a and a.ownsCar and not a.car then
				local away = entry[3] == true and a.stage == "atWork"
				Cars.give(h, a, carDataToCFrame(entry[2]), away)
				a.usingCar = away
			end
		end
	elseif row.p then
		for _, a in h.adults do
			if a.ownsCar then Cars.give(h, a, carDataToCFrame(row.p)); break end
		end
	end
end

local function finishRestoredHousehold(h: Household, homeView: any)
	local homeId = h.homeId
	_households[h.id] = h
	_buildingService.addHousehold(homeId)
	_buildingService.setFamilyName(homeId, h.familyName)

	local total = #h.adults + #h.kids
	for _ = 1, total do
		if _buildingService.canAcceptResident(homeId) then
			_buildingService.addResident(homeId)
		end
	end

	_buildingService.setOccupancy(homeId, total, _buildingService.getResidentCap(homeId), "residents", homeView.level)
end

local function resumeRestoredCar(h: Household, carState: any, keys: any, bySaveKey: { [string]: any }, homeView: any)
	if typeof(carState) ~= "table" then return end
	local cf = carDataToCFrame(carState.c)
	if not cf then return end

	local adultIndex = math.floor(tonumber(carState.a) or 0)
	local adult = h.adults[adultIndex]
	if not adult then return end

	local homeTarget = carState.hm == true
	local targetView = homeView
	if not homeTarget then
		local targetKey = resolveSavedKey(keys, carState.d)
		targetView = if targetKey then bySaveKey[targetKey] else nil
		if typeof(targetView) ~= "table" then return end
	end
	local targetId = if homeTarget then h.homeId else targetView.bpId
	if typeof(targetId) ~= "string" then return end

	-- The car is out with them, so it is theirs whatever the ownership roll says.
	adult.ownsCar = true
	if not adult.car then
		adult.car = newCar()
		if not adult.car then return end
		if not adult.driveKey then adult.homeParkCF, adult.driveKey = claimDriveway(h.homeId) end
	end
	local car = adult.car :: Model
	releaseSpot(adult)
	Garage.fetch(car)
	car:PivotTo(cf)
	local choice = if homeTarget then pickHomePark(h, adult) else pickBuildingPark(h, targetId)
	if not choice or not choice.cf then return end
	-- Stall is reserved at pick time: record it NOW so a household removed mid-drive
	-- still frees it through releaseSpot instead of leaking an occupied stall.
	adult.parkStallKey = choice.stallKey

	local kind = if typeof(carState.k) == "string" then carState.k else if adult.jobId == targetId then "work" else "shop"
	adult.tripId += 1
	local trip = adult.tripId
	adult.stage = "transit"
	adult.walkerId = nil
	adult.usingCar = true
	adult.tripTargetId = targetId
	adult.tripTargetHome = homeTarget
	if not homeTarget then
		adult.outKind = kind
		adult.outDestId = targetId
	end

	driveTo(car, choice.cf, function()
		if _households[h.id] ~= h or adult.tripId ~= trip then return end
		adult.parkSpotId = choice.spotId
		adult.parkEgress = choice.egress
		adult.parkGraphPoint = choice.lotEntry
		adult.tripTargetId = nil
		adult.tripTargetHome = false
		if choice.pocket then Garage.stow(car) end -- no legal spot: pocket it

		if homeTarget then
			adult.stage = "atHome"
			adult.outKind = nil
			adult.outDestId = nil
			adult.usingCar = false
		elseif kind == "work" then
			adult.stage = "atWork"
		elseif kind == "apply" and isJobView(targetView) then
			applyForJob(h, adult, targetId, jobCapacity(targetView.zone, targetView.level))
			returnHome(h, adult)
		elseif kind == "shop" then
			doShopping(h, targetId)
			returnHome(h, adult)
		else
			adult.stage = if adult.jobId == targetId then "atWork" else "atHome"
			if adult.stage == "atHome" then
				adult.outKind = nil
				adult.outDestId = nil
				adult.usingCar = false
			end
		end
	end, {
		fromGraphPoint = cf.Position,
		toGraphPoint = choice.lotEntry,
		approach = choice.approach,
		isValid = function() return _households[h.id] == h and adult.tripId == trip end,
	})
end

-- City restore: budget the household loop -- each iteration clones a car model and
-- may kick off resume pathfinding, and doing all of them in one frame is part of the
-- post-load client freeze (see BuildingService.RESTORE_FRAME_BUDGET, same pattern).
local RESTORE_FRAME_BUDGET = 0.008

local function restoreCompactHomes(data: any, bySaveKey: { [string]: any }): number
	local restored = 0
	local keys = data.keys
	local frameStart = os.clock()
	for _, row in data.homes do
		if os.clock() - frameStart > RESTORE_FRAME_BUDGET then
			task.wait()
			frameStart = os.clock()
		end
		if typeof(row) ~= "table" then continue end
		local homeKey = resolveSavedKey(keys, row.h)
		local homeView = if homeKey then bySaveKey[homeKey] else nil
		if not isResidentialHomeView(homeView) then continue end

		local adultCount = math.max(0, math.floor(tonumber(row.a) or 0))
		local kidCount = math.max(0, math.floor(tonumber(row.k) or 0))
		local total = math.min(adultCount + kidCount, FAMILY_MAX)
		if total <= 0 then continue end
		if adultCount > total then
			adultCount = total
			kidCount = 0
		else
			kidCount = math.min(kidCount, total - adultCount)
		end

		local h = makeRestoredHousehold(homeView.bpId, row.f)
		addRestoredPeople(h, adultCount, kidCount, row.e)
		assignRestoredJobs(h, row.j, keys, bySaveKey)
		finishRestoredHousehold(h, homeView)
		restoreCars(h, row)
		if typeof(row.cv) == "table" then
			for _, carState in row.cv do resumeRestoredCar(h, carState, keys, bySaveKey, homeView) end
		else
			resumeRestoredCar(h, row.v, keys, bySaveKey, homeView)
		end
		restored += 1
	end
	return restored
end

local function restoreBakedResidentHomes(bakedHomes: { any }, byId: { [string]: any }): number
	local restored = 0
	for _, row in bakedHomes do
		local homeView = byId[row.bpId]
		if not isResidentialHomeView(homeView) then continue end
		local total = math.min(math.max(0, math.floor(tonumber(row.residents) or 0)), FAMILY_MAX)
		if total <= 0 then continue end

		local adultCount = math.min(total, 2)
		local kidCount = total - adultCount
		local h = makeRestoredHousehold(homeView.bpId, _timeService.getDay())
		addRestoredPeople(h, adultCount, kidCount, nil)
		finishRestoredHousehold(h, homeView)
		restored += 1
	end
	return restored
end

local function clearRuntimeHouseholds()
	for _, h in _households do
		for _, a in h.adults do
			if a.walkerId then _walkingService.despawnCommuter(a.walkerId) end
			if a.riderId then _transitService.cancelRider(a.riderId) end
		end
		for _, kid in h.kids do
			if kid.walkerId then _walkingService.despawnCommuter(kid.walkerId) end
			if kid.stage == "atSchool" and _educationService and _educationService.leaveSchool then
				_educationService.leaveSchool(kid.schoolId)
			end
		end
	end
	for car in _trips do
		PathFollower.forget(car)
		if car.Parent then car:Destroy() end
	end
	table.clear(_trips)
	table.clear(_carDriveTokens)
	for _, child in _folder:GetChildren() do
		if child:IsA("Model") then
			PathFollower.forget(child)
			child:Destroy()
		end
	end
	Garage.clear()
	-- Free each household's reserved on-street spot before dropping them. removeHousehold
	-- does this per departure; the bulk clear must too, or reservations leak when the
	-- parking grid is not rebuilt under us.
	for _, h in _households do
		for _, a in h.adults do releaseSpot(a) end
	end
	table.clear(_households)
	table.clear(_stallTaken)
	table.clear(_travelDebugByPid)
	table.clear(_workers)
	_buildingService.clearHouseholds()
	table.clear(Pipe.entries)
	_tripCount = 0
	_directedCount = 0
	_carCount = 0
	_population = 0
	if _educationService and _educationService.setPupilDemand then
		_educationService.setPupilDemand(0, 0)
	end
end

function CitizenService.restore(data: any)
	-- Clear FIRST, bail second. An absent citizens key means "this city has none" -- which is
	-- what a map template and an in-place city switch both send -- and returning early left
	-- the outgoing city's households, walkers and cars standing in the new one.
	_restoring = true
	clearRuntimeHouseholds()
	table.clear(_reconciledIds)
	recountPopulation()

	local compact = typeof(data) == "table" and typeof(data.homes) == "table"
	if not compact and (typeof(data) ~= "table" or typeof(data.households) ~= "table") then
		_restoring = false
		return
	end

	local views = CitizenService._svcViews()
	local byId: { [string]: any } = {}
	local bySaveKey: { [string]: any } = {}
	local bakedHomes: { any } = {}
	for _, b in views do
		byId[b.bpId] = b
		local key = buildingSaveKey(b)
		if key then bySaveKey[key] = b end
		_reconciledIds[b.bpId] = true
		if b.zone == "Residential" then
			local bakedResidents = math.max(0, math.floor(tonumber(b.residents) or 0))
			if bakedResidents > 0 then
				table.insert(bakedHomes, { bpId = b.bpId, residents = bakedResidents })
			end
			for _ = 1, bakedResidents do
				_buildingService.removeResident(b.bpId)
			end
		end
	end

	_nextHouseholdId = math.max(0, math.floor(tonumber(data.nextHouseholdId) or 0))
	_nextPersonId = math.max(_nextPersonId, math.floor(tonumber(data.nextPersonId) or 0))

	if compact then
		local restoredCount = restoreCompactHomes(data, bySaveKey)
		if restoredCount == 0 and #bakedHomes > 0 then
			restoreBakedResidentHomes(bakedHomes, byId)
		end
		recountPopulation()
		_accum = 0
		_restoring = false
		return
	end

	local restoredCount = 0
	for _, row in data.households do
		if typeof(row) ~= "table" or typeof(row.homeId) ~= "string" then continue end
		local homeId = row.homeId :: string
		local home = byId[homeId]
		if not isResidentialHomeView(home) then continue end

		local id = math.floor(tonumber(row.id) or 0)
		if id <= 0 or _households[id] ~= nil then
			_nextHouseholdId += 1
			id = _nextHouseholdId
		end
		_nextHouseholdId = math.max(_nextHouseholdId, id)

		local h: Household = {
			id = id,
			homeId = homeId,
			adults = {},
			kids = {},
			foundedDay = math.max(1, math.floor(tonumber(row.foundedDay) or _timeService.getDay())),
			arriving = false,
			familyName = if typeof(row.familyName) == "string" then row.familyName else NameGen.familyName(_rng),
		}

		if typeof(row.adults) == "table" then
			for _, a in row.adults do
				if typeof(a) ~= "table" then continue end
				local savedJobId = if typeof(a.jobId) == "string" then a.jobId else nil
				local jobId = if savedJobId and isJobView(byId[savedJobId]) then savedJobId else nil
				-- Legacy saves predate gender/age: make the first two adults a couple and
				-- give every adult a plausible age so the family sim has something to grow.
				local gender = if a.gender == "M" or a.gender == "F" then a.gender
					elseif #h.adults == 0 then "M"
					elseif #h.adults == 1 then "F"
					elseif _rng:NextNumber() < 0.5 then "M" else "F"
				local atWork = a.atWork == true and jobId ~= nil
				local pid = nextPid()
				table.insert(h.adults, {
					name = if typeof(a.name) == "string" then a.name else NameGen.firstName(_rng, gender),
					gender = gender,
					age = math.max(AGE_ADULT, math.floor(tonumber(a.age) or _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE))),
					pid = pid,
					ownsCar = TravelModeChoice.ownsCar(pid),
					jobId = jobId,
					joblessDays = math.max(0, math.floor(tonumber(a.joblessDays) or 0)), eduLevel = math.clamp(math.floor(tonumber(a.eduLevel) or 0), 0, 3),
					stage = if atWork then "atWork" else "atHome",
					tripId = 0, walkerId = nil,
					outKind = if atWork then "work" else nil,
					outDestId = if atWork then jobId else nil,
					usingCar = false,
					tripTargetId = nil, tripTargetHome = false,
					commutedWorkDay = 0, commutedHomeDay = 0, nextErrandAt = 0,
				})
				if jobId then _workers[jobId] = (_workers[jobId] or 0) + 1 end
			end
		end
		if #h.adults == 0 then
			table.insert(h.adults, makeAdult("M", _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE)))
		end

		-- Children. New saves store per-kid records; legacy saves stored a bare count.
		if typeof(row.kids) == "table" then
			for _, k in row.kids do
				if typeof(k) ~= "table" then continue end
				local gender = if k.gender == "M" or k.gender == "F" then k.gender
					elseif _rng:NextNumber() < 0.5 then "M" else "F"
				table.insert(h.kids, {
					name = if typeof(k.name) == "string" then k.name else NameGen.firstName(_rng, gender),
					gender = gender,
					age = math.clamp(math.floor(tonumber(k.age) or _rng:NextInteger(KID_ARRIVE_MIN_AGE, KID_ARRIVE_MAX_AGE)), 0, AGE_ADULT - 1),
					pid = nextPid(),
					stage = "atHome", tripId = 0, walkerId = nil, schoolPos = nil,
					schoolId = if typeof(k.schoolId) == "number" then math.floor(k.schoolId) else nil, bestTier = math.clamp(math.floor(tonumber(k.bestTier) or 0), 0, 2),
					commutedSchoolDay = 0, commutedHomeDay = 0,
				})
			end
		elseif typeof(row.kids) == "number" then
			for _ = 1, math.clamp(math.floor(row.kids), 0, MAX_KIDS) do
				table.insert(h.kids, makeKid())
			end
		end

		for _, a in h.adults do
			if a.ownsCar then Cars.give(h, a, dataToCFrame(row.car)); break end
		end

		_households[id] = h
		restoredCount += 1
		_buildingService.addHousehold(homeId)
		_buildingService.setFamilyName(homeId, h.familyName)
		for _ = 1, #h.adults + #h.kids do
			if _buildingService.canAcceptResident(homeId) then
				_buildingService.addResident(homeId)
			end
		end
	end

	if restoredCount == 0 and #bakedHomes > 0 then
		restoreBakedResidentHomes(bakedHomes, byId)
	end

	recountPopulation()
	-- A restore replaces the whole population: drop the cached education histogram and
	-- invalidate the pid index so nothing serves numbers from the pre-load city.
	LOD.eduFresh = false
	LOD.pidGen += 1
	_accum = 0
	_restoring = false
end

-- == Lifecycle =================================================================
function CitizenService.Init(roadService: any, buildingService: any, cityStatsService: any, timeService: any, parkingService: any, walkingService: any, economyService: any, supplyService: any, educationService: any?)
	assert(roadService and buildingService and cityStatsService and timeService and parkingService and walkingService and economyService and supplyService, "[CitizenService] missing dependency")
	_roadService = roadService
	_buildingService = buildingService
	_cityStatsService = cityStatsService
	_timeService = timeService
	_parkingService = parkingService
	_walkingService = walkingService
	_economyService = economyService
	_supplyService = supplyService
	_educationService = educationService
	_folder = ensureFolder()
end

-- Family roster for the building info panel: the resident household's surname plus
-- every member (adults first, oldest first, then children) with gender + age. Single-
-- family, so at most one household per home. Returns nil for a vacant/non-home lot.
function CitizenService.getFamilyInfo(homeId: string): { familyName: string, members: { { name: string, gender: string, age: number, role: string, employed: boolean, pid: number } } }?
	local homeZone = if _buildingService.getBuildingZone then _buildingService.getBuildingZone(homeId) else nil
	if homeZone ~= "Residential" then return nil end

	local here: { Household } = {}
	for _, h in _households do
		if h.homeId == homeId then table.insert(here, h) end
	end
	if #here == 0 then return nil end
	table.sort(here, function(a, b) return a.id < b.id end)

	-- A big home holds several families, so the roster is every household's people in
	-- turn. Surnames are only worth spelling out once there is more than one family.
	local showSurname = #here > 1
	local members: { any } = {}
	for _, h in here do
		local adults = table.clone(h.adults)
		table.sort(adults, function(a, b) return a.age > b.age end)
		local kids = table.clone(h.kids)
		table.sort(kids, function(a, b) return a.age > b.age end)
		local function label(name: string): string
			return if showSurname then name .. " " .. h.familyName else name
		end
		for _, a in adults do
			table.insert(members, { name = label(a.name), gender = a.gender, age = a.age, role = "Adult", employed = a.jobId ~= nil, pid = a.pid })
		end
		for _, k in kids do
			table.insert(members, { name = label(k.name), gender = k.gender, age = k.age, role = "Child", employed = false, pid = k.pid })
		end
	end

	return { familyName = here[1].familyName, households = #here, members = members }
end

-- Workforce roster for a commercial/industrial building's info panel: everyone whose
-- job is here, with their family name + age + gender + a safe focus point for the
-- residential home they live in. Oldest first.
function CitizenService.getWorkforceInfo(workplaceId: string): { workers: { { name: string, familyName: string, age: number, gender: string, homeId: string, homePos: Vector3?, pid: number } } }?
	local workers: { any } = {}
	for _, h in _households do
		local homeZone = if _buildingService.getBuildingZone then _buildingService.getBuildingZone(h.homeId) else nil
		if homeZone ~= "Residential" then continue end
		for _, a in h.adults do
			if a.jobId == workplaceId then
				local homePos = homeFocusPosition(h.homeId)
				table.insert(workers, {
					name = a.name, familyName = h.familyName, age = a.age, gender = a.gender,
					homeId = h.homeId, homePos = homePos,
					pid = a.pid,
				})
			end
		end
	end
	table.sort(workers, function(a, b) return a.age > b.age end)
	return { workers = workers }
end

-- Where a person is RIGHT NOW, for the "locate" dot on a roster row, keyed by their
-- stable pid. A MOVING citizen (driving the family car, or walking a leg) returns the
-- live part to FOLLOW so the camera tracks them continuously; a settled one (at work / at
-- home / a child) returns a static point to fly to once.
function CitizenService.getAdminPersonDebug(pid: number): { [string]: any }?
	local found = findPerson(pid)
	if not found then return nil end
	local h = found.h
	do
		for _, a in h.adults do
			if a.pid == pid then
				local targetId = a.tripTargetId or a.outDestId
				return {
					kind = "adult",
					pid = pid,
					name = personLabel(h, a),
					age = a.age,
					stage = a.stage,
					homeId = h.homeId,
					jobId = a.jobId,
					destinationId = targetId,
					destinationPos = if targetId then door(targetId) else nil,
					purpose = if a.tripTargetHome then "Returning home"
						elseif a.outKind == "work" then "Commuting to assigned workplace"
						elseif a.outKind == "shop" then "Shopping errand"
						elseif a.outKind == "apply" then "Travelling to a job application"
						elseif a.outKind == "walk" then "Out for a walk"
						else "No active destination",
					walkerId = a.walkerId,
					car = if a.usingCar then a.car else nil,
					ownsCar = a.ownsCar == true,
					usingCar = a.usingCar,
					modeDecision = _travelDebugByPid[pid],
				}
			end
		end
		for _, k in h.kids do
			if k.pid == pid then
				return {
					kind = "kid",
					pid = pid,
					name = kidLabel(h, k),
					age = k.age,
					stage = k.stage,
					homeId = h.homeId,
					destinationPos = k.schoolPos,
					purpose = if k.stage == "atSchool" then "Attending school" elseif k.stage == "transit" then "School commute" else "At home",
					walkerId = k.walkerId,
					modeDecision = {
						chosen = "walk",
						reason = "School pupils currently use the protected sidewalk and crosswalk network.",
					},
				}
			end
		end
	end
	return nil
end

function CitizenService.getPersonWhereabouts(pid: number): { pos: Vector3, status: string, follow: BasePart? }?
	local found = findPerson(pid)
	if not found then return nil end
	local h = found.h
	do
		for _, a in h.adults do
			if a.pid == pid then
				if a.stage == "transit" then
					-- Driving their car: follow the car.
					if a.usingCar and a.car and a.car.Parent then
						local root = a.car.PrimaryPart or a.car:FindFirstChildWhichIsA("BasePart")
						local verb = if a.outKind == "shop" then "Driving to the shops"
							elseif a.outKind == "apply" then "Driving to a job interview"
							else "Driving to work"
						if root then return { pos = root.Position, status = verb, follow = root } end
					end
					-- Walking a leg: follow the pedestrian.
					if a.walkerId then
						local root = _walkingService.getCommuterRoot(a.walkerId)
						local verb = if a.outKind == "shop" then "Walking to the shops"
							elseif a.outKind == "apply" then "Walking to a job interview"
							elseif a.outKind == "walk" then "Out for a walk"
							else "Walking to work"
						if root then return { pos = root.Position, status = verb, follow = root } end
					end
					-- Between legs (parked, no live part yet): fall back to a static point.
					local k = if a.outDestId then _buildingService.getKerb(a.outDestId) else nil
					if k then return { pos = k, status = "On the way" } end
				end
				if a.stage == "atWork" and a.outDestId then
					local k = _buildingService.getKerb(a.outDestId)
					if k then return { pos = k, status = "At work" } end
				end
				local hk = homeFocusPosition(h.homeId)
				if hk then return { pos = hk, status = "At home" } end
				return nil
			end
		end
		-- A child: they stay home, so locate flies to the family home.
		for _, k in h.kids do
			if k.pid == pid then
				if k.stage == "transit" and k.walkerId then
					local root = _walkingService.getCommuterRoot(k.walkerId)
					if root then return { pos = root.Position, status = "Walking to/from school", follow = root } end
				end
				if k.stage == "atSchool" and typeof(k.schoolPos) == "Vector3" then
					return { pos = k.schoolPos, status = "At school" }
				end
				local hk = homeFocusPosition(h.homeId)
				if hk then return { pos = hk, status = "At home" } end
				return nil
			end
		end
	end
	return nil
end

-- Outdoor background presence near `center`, for the client's local-only renderer.
-- Settled adults at home/work and children at school are inside buildings, so they are
-- not rendered. At-home children can appear as daytime yard play in the background;
-- transit citizens are omitted because walkers/cars already represent them.
function CitizenService.getPresenceNear(camCF: CFrame, radius: number, cap: number): { any }
	if typeof(camCF) ~= "CFrame" then return {} end
	local center = camCF.Position
	local look = camCF.LookVector
	local bySpot: { [string]: { id: string, pos: Vector3, dist: number, people: { any } } } = {}
	local order: { any } = {}
	local dayFrac = if _timeService and _timeService.getDayFraction then _timeService.getDayFraction() else 0.5
	local kidsCanPlayOutside = dayFrac >= 0.34 and dayFrac <= 0.72
	local function addAt(id: string, pos: Vector3, gender: string, kind: string, pid: number)
		local e = bySpot[id]
		if not e then
			local off = pos - center
			local d = off.Magnitude
			if d > radius then return end
			-- Only spots IN FRONT of the camera (any distance up to radius); behind it the
			-- player can't see them, so they are never rendered.
			if d > 1 and off.Unit:Dot(look) < PRESENCE_FRONT_COS then return end
			e = { id = id, pos = pos, dist = d, people = {} }
			bySpot[id] = e
			table.insert(order, e)
		end
		table.insert(e.people, { g = gender, k = kind, p = pid })
	end
	for _, h in _households do
		if h.arriving then continue end
		for _, a in h.adults do
			if a.waitPos then addAt(`stop:{a.waitPos}`, a.waitPos, a.gender, "adult", a.pid) end
		end
		if kidsCanPlayOutside and _buildingService.getOutdoorPlaySpot then
			local playSpot = _buildingService.getOutdoorPlaySpot(h.homeId)
			if typeof(playSpot) == "Vector3" then
				for _, kid in h.kids do
					if kid.stage == nil or kid.stage == "atHome" then
						addAt(h.homeId .. ":play", playSpot, kid.gender, "kid", kid.pid)
					end
				end
			end
		end
	end
	table.sort(order, function(p, q) return p.dist < q.dist end)
	local out: { any } = {}
	local total = 0
	for _, e in order do
		if total >= cap then break end
		-- Stable order within a building so a person keeps the same stand spot between polls.
		table.sort(e.people, function(p, q)
			if p.k ~= q.k then return p.k < q.k end
			return p.g < q.g
		end)
		table.insert(out, { id = e.id, pos = e.pos, people = e.people })
		total += #e.people
	end
	return out
end

function CitizenService.Bind()
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	NetMiddleware.RegisterServerRateLimit(Net.RequestFamilyInfo, FAMILY_INFO_MIN_DT)
	Net.RequestFamilyInfo.OnServerInvoke = function(player: Player, bpId: any): any
		if not NetMiddleware.CheckServerRate(Net.RequestFamilyInfo, player) then return nil end
		if typeof(bpId) ~= "string" then return nil end
		return CitizenService.getFamilyInfo(bpId)
	end

	NetMiddleware.RegisterServerRateLimit(Net.RequestWorkforceInfo, FAMILY_INFO_MIN_DT)
	Net.RequestWorkforceInfo.OnServerInvoke = function(player: Player, bpId: any): any
		if not NetMiddleware.CheckServerRate(Net.RequestWorkforceInfo, player) then return nil end
		if typeof(bpId) ~= "string" then return nil end
		return CitizenService.getWorkforceInfo(bpId)
	end

	NetMiddleware.RegisterServerRateLimit(Net.RequestCitizenPos, FAMILY_INFO_MIN_DT)
	Net.RequestCitizenPos.OnServerInvoke = function(player: Player, pid: any): any
		if not NetMiddleware.CheckServerRate(Net.RequestCitizenPos, player) then return nil end
		if typeof(pid) ~= "number" then return nil end
		return CitizenService.getPersonWhereabouts(pid)
	end

	NetMiddleware.RegisterServerRateLimit(Net.RequestPresenceNear, 0.5)
	Net.RequestPresenceNear.OnServerInvoke = function(player: Player, camCF: any): any
		if not NetMiddleware.CheckServerRate(Net.RequestPresenceNear, player) then return nil end
		if typeof(camCF) ~= "CFrame" then return nil end
		return CitizenService.getPresenceNear(camCF, PRESENCE_RADIUS, PRESENCE_CAP)
	end
end

function CitizenService.Start()
	if _running then return end
	_running = true
	local tripAccum = 0
	_heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		tripAccum += math.min(dt, 0.1)
		if tripAccum < TRIP_TICK then return end
		local simDt = math.min(tripAccum, 0.1) * gameSpeed()
		tripAccum = 0

		local ok, err = pcall(stepTrips, simDt)
		if not ok then warn("[CitizenService] trip step failed: " .. tostring(err)) end
		_accum += simDt
		if _accum >= SIM_STEP then
			_accum -= SIM_STEP
			local ok2, err2 = pcall(simStep)
			if not ok2 then warn("[CitizenService] sim step failed: " .. tostring(err2)) end
		end
	end)
end

return CitizenService
