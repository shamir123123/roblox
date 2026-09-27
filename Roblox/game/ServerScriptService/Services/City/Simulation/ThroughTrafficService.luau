--!strict
-- ThroughTrafficService
-- Inter-city through traffic: background cars that enter at one outside connection,
-- cross the city on the real traffic AI (NPCDriverService), and despawn at another.
-- Pure street life -- no households. Self-healing by design: a car destroyed under us
-- (city reload sweeps the Citizens folder) is pruned on the next pass, and a drive that
-- aborts (roads edited away) despawns its car -- so no cross-service cleanup hooks are
-- needed.
--
-- This is the bulk of what fills a road, so it IS persisted (serialize/restore below):
-- a save taken mid-jam reloads with the queue still standing rather than an empty city
-- that trickles back to full over the next twenty minutes.

local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleFactory = require(ServerScriptService.Services.NPC.VehicleFactory)
local NPCDriverService = require(ServerScriptService.Services.NPC.NPCDriverService)
local PathFollower = require(ServerScriptService.Services.Util.PathFollower)
local DriverProfile = require(ReplicatedStorage.Road.DriverProfile)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)

local ThroughTrafficService = {}

-- Intercity traffic is NOT the citizens' own cars: it is named apart so it can be told
-- from a household car at a glance, in the explorer, in a click-inspect and in a log line.
local CAR_NAME       = "IntercityCar"
local STEP           = 2.0  -- seconds between spawn attempts (GameSpeed-scaled)
local CAR_HEIGHT     = 0.6
local EDGE_OFFSET    = 24   -- keep clear of the map-edge tip node shared by both lanes
local CLEAR_RADIUS   = 16   -- no spawn within this range of another vehicle

-- == How much through traffic there is ========================================
-- Not a balance number: it FOLLOWS from the roads the player dragged to the map edge,
-- which is what makes "small road, big traffic" a thing the player causes rather than a
-- thing the game decides. Every formula below is the standard transport-planning one,
-- matching how NavCost already prices a road.
--
--   Capacity of an entrance
--     HCM (Highway Capacity Manual) base saturation flow is 1900 passenger cars per
--     hour per lane for a through movement. A real approach does not run at base
--     saturation, so the volume actually ADMITTED is taken at the level-of-service D
--     threshold (~0.85 of capacity), which is where an urban approach sits at peak.
--
--   Concurrency from flow
--     Little's Law, L = lambda * W: the number of vehicles inside the city at any moment
--     is the arrival rate times how long a crossing takes. W follows the DISTANCE between
--     the entrance and the exits, so one inbound lane holds (crossing length / headway)
--     cars -- a road drawn clean across the map is packed end to end, while two
--     connections in the same corner carry a trickle. A one-lane alley entrance still
--     admits a fraction of what a five-lane highway does, off the same rule.
--
--   Daily profile
--     Two-peak weekday shape. Real hourly counts run ~9-11% of the daily total in each
--     peak hour against ~1% overnight, with the PM peak the taller of the two (trip
--     chaining -- errands ride home on the evening commute). Through traffic is FLATTER
--     than commuter traffic because freight runs all day, so these peaks are gentler
--     than the citizen commute's, and they are centred on the same TimeService windows
--     the household sim schedules against so the two flows peak together.
local CRUISE_HEADWAY = 26   -- studs between two cars in free flow (half-scale world)
local MIN_LANE_CARS  = 10   -- an entrance always admits something, however short the hop
local MAX_LANE_CARS  = 120  -- ...and a lane is bumper to bumper well before this
local MAX_CONCURRENT = 1500 -- absolute ceiling, whatever the player builds (server budget)
-- The motorway is never empty: long-distance freight and travel run all night. It is the
-- CITY's own traffic that swings with the clock, and through traffic gives way to it (step).
local NIGHT_FLOOR    = 0.35 -- 03:00 volume as a fraction of the PM peak
local MIDDAY_BASE    = 0.35 -- flat inter-peak daytime plateau (freight + non-commute)
-- Through traffic yields its share of the motorway one-for-one to city cars on it, but never
-- below this fraction of its own target: the city's commuters make it busier, not emptier.
local YIELD_FLOOR    = 0.3
local AM_PEAK        = 0.42
local PM_PEAK        = 0.58
local PEAK_SIGMA     = 0.045
-- Centres of TimeService's WORKBOUND (0.27-0.40) and HOMEBOUND (0.66-0.82) windows.
local AM_PEAK_CENTER = 0.335
local PM_PEAK_CENTER = 0.740
-- Traffic RAMPS into a peak; it does not appear. Fraction of the outstanding deficit
-- launched per step, and a hard per-step cap so a peak (or a load) cannot spike the
-- server with a hundred A* searches in one frame.
local RAMP_FRACTION      = 0.12
local MAX_SPAWNS_PER_STEP = 4
-- Studs between two cars entering at the same connection in one step. Must clear
-- CLEAR_RADIUS or the second car is refused as "too close to the first".
local SPAWN_STAGGER      = 24
-- Exits to try before a launch slot is given up. A city can hold connection pairs that
-- cannot reach each other at all -- a stub the player never joined to the network, a road
-- deleted out from under one -- and one random pick per slot spent most of the budget on
-- them, so the city sat far below target with a perfectly good pair going unused. Bounded
-- because each try is an A* search: at most EXIT_TRIES * MAX_SPAWNS_PER_STEP per step.
local EXIT_TRIES         = 3
-- Launches that found no route, and the last pair that failed. Reported once a minute:
-- silence here is normal, a steady stream means two ends of the city are not connected.
local _failedLaunches = 0
local _lastFailedPair: string? = nil
local _lastFailWarn = 0
local FAIL_WARN_INTERVAL = 60

type CarRec = { seed: number, variant: number, exitId: string }

local _roadService: any
local _outsideConnService: any
local _timeService: any
local _cars: { [Model]: CarRec } = {}
local _rng = Random.new()
local _running = false

-- A blocked spawn is not a fault: the entrance being occupied, or two map edges not yet
-- joined by road, are both ordinary states of a city being built. STEP retries every couple
-- of seconds, so these used to log forever at DIAG_INTERVAL and drowned the Output. Nothing
-- is dropped and nothing needs attention, so the attempt now just returns.

-- Same folder the citizen cars live in, so one sweep clears all street life.
local function carFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Citizens")
	if not f or not f:IsA("Folder") then
		f = Instance.new("Folder"); f.Name = "Citizens"; f.Parent = city
	end
	return f :: Folder
end

-- Physical clearance: any vehicle part near the spawn point defers the spawn --
-- covers citizen cars, trucks, buses and our own cars without shared state.
local function spawnClear(pos: Vector3): boolean
	local city = Workspace:FindFirstChild("_City")
	if not city then return true end
	local include = {}
	for _, name in { "Citizens", "Trucks", "Buses" } do
		local f = city:FindFirstChild(name)
		if f then table.insert(include, f) end
	end
	if #include == 0 then return true end
	-- A DRIVING car's instance is frozen at its spawn pose (see IsPointClear), so ask the
	-- sim about those and let the overlap query speak only for PARKED vehicles, whose
	-- instance pose is the real one.
	if not NPCDriverService.IsPointClear(pos, CLEAR_RADIUS) then return false end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include
	for _, part in Workspace:GetPartBoundsInRadius(pos, CLEAR_RADIUS, params) do
		local m = part:FindFirstAncestorOfClass("Model")
		if m and not NPCDriverService.IsDirected(m) then return false end
	end
	return true
end

-- A connection's map-edge tip node is shared by its inbound and outbound lane, so a
-- position AT the tip snaps ambiguously (an unreachable/dead-end lane makes A* return
-- nil). Both helpers return a point EDGE_OFFSET studs from the tip, unmistakably on
-- the wanted lane: inbound (drives into the city) to spawn on, outbound to exit on.
-- `minDist` is how far in along the inbound lane to come to rest, defaulting to the
-- EDGE_OFFSET that clears the shared tip node. Callers walk it further in to stagger
-- several arrivals at one connection (see step).
local function inboundPoint(g: any, conn: any, minDist: number?): Vector3?
	-- Spread arrivals across EVERY inbound lane. NearestEdgeToward returns ONE lane -- the
	-- same one on every call -- so a four-lane entrance sent all its traffic down a single
	-- lane and left the rest empty for the whole crossing: a car only changes lane at a gate,
	-- so the lane it enters on is the lane it drives the city in.
	local lanes: { any } = {}
	if g.GetOutgoingEdgesFromNode and typeof(conn.nodeId) == "number" then
		lanes = g:GetOutgoingEdgesFromNode(conn.nodeId)
	end
	local edge: any, startIndex: number = nil, 1
	if #lanes > 0 then
		edge = lanes[_rng:NextInteger(1, #lanes)]
	else
		if not g.NearestEdgeToward then return nil end
		local res = g:NearestEdgeToward(conn.outer, conn.outer - conn.normal * 200)
		if not res then return nil end
		edge = res.edge
		startIndex = res.index or 1
	end
	if not (edge and edge.points and #edge.points >= 2) then return nil end
	local want = minDist or EDGE_OFFSET
	local pts = edge.points
	local acc = 0
	for i = math.clamp(startIndex, 1, #pts - 1) + 1, #pts do
		acc += (pts[i] - pts[i - 1]).Magnitude
		if acc >= want then return pts[i] end
	end
	-- Asked for more lane than this entrance road has: nil rather than piling every
	-- surplus car onto the far end of it.
	return if want <= EDGE_OFFSET then pts[#pts] else nil
end

local function exitPoint(g: any, conn: any): Vector3?
	if not g.NearestEdgeToward then return nil end
	local res = g:NearestEdgeToward(conn.outer, conn.outer + conn.normal * 200)
	if not (res and res.edge and res.edge.points and #res.edge.points >= 2) then return nil end
	local pts = res.edge.points
	local acc = 0
	for i = #pts - 1, 1, -1 do
		acc += (pts[i + 1] - pts[i]).Magnitude
		if acc >= EDGE_OFFSET then return pts[i] end
	end
	return pts[1]
end

-- Live car count; prunes cars destroyed under us (e.g. a city load swept the folder).
local function liveCount(): number
	local n = 0
	for car in _cars do
		if car.Parent then n += 1 else _cars[car] = nil end
	end
	return n
end

-- == Demand ===================================================================

local function bell(x: number, mu: number, sigma: number): number
	local d = (x - mu) / sigma
	return math.exp(-0.5 * d * d)
end

-- 0..1 share of the evening peak that the clock says should be on the road now.
-- Without a clock (never loaded a city) traffic sits at the midday plateau.
local function diurnalFactor(): number
	if not (_timeService and _timeService.getDayFraction) then
		return NIGHT_FLOOR + MIDDAY_BASE
	end
	local frac = _timeService.getDayFraction()
	if typeof(frac) ~= "number" or frac ~= frac then
		return NIGHT_FLOOR + MIDDAY_BASE
	end
	-- Daytime plateau: rises through dawn, falls away after the evening peak.
	local up = math.clamp((frac - 0.20) / 0.10, 0, 1)
	local down = 1 - math.clamp((frac - 0.84) / 0.10, 0, 1)
	local plateau = MIDDAY_BASE * up * down
	local peaks = AM_PEAK * bell(frac, AM_PEAK_CENTER, PEAK_SIGMA)
		+ PM_PEAK * bell(frac, PM_PEAK_CENTER, PEAK_SIGMA)
	return math.clamp(NIGHT_FLOOR + plateau + peaks, 0, 1)
end

-- Inbound lanes an entrance offers. A two-way road splits its lanes between the two
-- directions exactly as RoadNavigationGraph does, so an entrance is rated on the lanes
-- that actually point INTO the city.
local function inboundLanes(conn: any): number
	local spec = RoadTypeCatalog.get(conn.roadType)
	if not spec then return 1 end
	local lanes = math.max(1, spec.laneCount or 2)
	if spec.oneWay then return lanes end
	return math.max(1, math.floor(lanes / 2))
end

local function totalInboundLanes(entries: { any }): number
	local lanes = 0
	for _, c in entries do
		lanes += inboundLanes(c)
	end
	return lanes
end

-- Mean straight-line distance from an entrance to an exit: how far a through-car has to
-- come. Straight-line under-reads the driven route, which is the safe direction to be
-- wrong in. A handful of connections, so it costs nothing to take it fresh each step and
-- it follows the player's roads without a cache to go stale.
local function meanCrossing(entries: { any }, exits: { any }): number
	local total, n = 0, 0
	for _, a in entries do
		for _, b in exits do
			if a.id ~= b.id then
				local dx, dz = a.outer.X - b.outer.X, a.outer.Z - b.outer.Z
				total += math.sqrt(dx * dx + dz * dz)
				n += 1
			end
		end
	end
	return if n > 0 then total / n else 0
end

-- Cars ONE inbound lane carries: the crossing it feeds, divided by the gap between two
-- cars at cruise. This is why a big road run from one map edge to the other fills up --
-- the length IS the demand.
local function laneCapacity(entries: { any }, exits: { any }): number
	return math.clamp(meanCrossing(entries, exits) / CRUISE_HEADWAY, MIN_LANE_CARS, MAX_LANE_CARS)
end

-- Concurrent through-cars the city should be carrying right now: every entrance's lane
-- capacity over the distance it feeds, scaled by the time of day. This is what a player
-- CHANGES by dragging a wider road to the map edge, or by carrying one right across --
-- and what turns a highway feeding a one-lane street into a standing queue rather than a
-- number someone tuned.
local function targetConcurrent(entries: { any }, exits: { any }): number
	local perLane = laneCapacity(entries, exits)
	return math.min(MAX_CONCURRENT, math.floor(totalInboundLanes(entries) * perLane * diurnalFactor() + 0.5))
end

-- Pick an entrance in proportion to its lane count: a five-lane highway link feeds five
-- times what a single-lane one does, instead of every entrance sending the same trickle.
local function pickWeighted(entries: { any }): any?
	local total = 0
	for _, c in entries do total += inboundLanes(c) end
	if total <= 0 then return nil end
	local roll = _rng:NextNumber() * total
	for _, c in entries do
		roll -= inboundLanes(c)
		if roll <= 0 then return c end
	end
	return entries[#entries]
end

-- Put one through-car on the road and hand it to the traffic AI. `atCF` is where it
-- starts: the entrance for a fresh spawn, its saved pose for a restored one -- which is
-- the whole reason spawn and restore share this and do not each grow their own copy.
-- One A* attempt. `towardGoal` is FindPath's preferTowardGoal, which decides whether the
-- START LANE is re-picked to face the destination -- see the caution in launch below.
local function tryPath(g: any, from: Vector3, to: Vector3, profile: any, towardGoal: boolean?): { string }?
	local ok, road, edgeIds = pcall(function() return g:FindPath(from, to, towardGoal, nil, profile) end)
	if not ok or typeof(road) ~= "table" or #road == 0 then return nil end
	if typeof(edgeIds) ~= "table" or #(edgeIds :: any) == 0 then return nil end -- too short for a road leg
	return edgeIds :: { string }
end

local function edgeLeadsTo(edge: any, nextId: string): boolean
	for _, o in edge.out or {} do
		if o == nextId then return true end
	end
	return false
end

local function launch(g: any, exitConn: any, atCF: CFrame, seed: number, variant: number, anchor: { edgeId: string, dist: number }?): boolean
	local src = atCF.Position
	local dst = exitPoint(g, exitConn)
	if not dst then return false end

	-- Through traffic is the worst herd in the city: car after car entering at the
	-- same connection bound for the same exit, i.e. the identical routing problem
	-- solved over and over. Give each one its own mind BEFORE planning (the seed is
	-- stamped on the car below, so the driver keeps the same personality), and the
	-- crossings fan out across parallel roads instead of grinding one corridor.
	local profile = DriverProfile.forSeed(seed)
	local edgeIds: { string }? = nil
	local startDist: number? = nil

	local anchorEdge = if anchor then g:GetEdge(anchor.edgeId) else nil
	if anchor and anchorEdge and anchorEdge.points and #anchorEdge.points > 0 then
		-- RESTORED CAR. It is already in traffic on a known lane, and the router must not be
		-- allowed to choose a different one.
		--
		-- FindPath's preferTowardGoal picks the start lane by `align - distance/30`
		-- (NavRouter.nearestEdgeToward): facing the goal is worth up to 2.0 while a whole
		-- lane-width of separation costs 0.3. That is right for a car pulling out of a
		-- driveway, and wrong for this one -- it will happily move a car onto the OPPOSING
		-- carriageway, where distance-along runs the other way, so the car reappears at
		-- roughly (length - dist) facing backwards. Even plain NearestEdge is unsafe here,
		-- because it measures to lane VERTICES and those sit up to 56 studs apart, so a
		-- point mid-chord on this lane can read as nearer to the next lane over.
		--
		-- So do not re-snap at all. The remaining trip is "finish this lane, then route on
		-- from its end" -- plan that tail and put the lane the car is on back at the front.
		local pts = anchorEdge.points
		src = PathFollower.pointAtDist(pts, PathFollower.getCum(anchorEdge), anchor.dist)
		local tail = tryPath(g, pts[#pts], dst, profile, false)
		if tail then
			if tail[1] == anchor.edgeId then
				edgeIds = tail
			elseif edgeLeadsTo(anchorEdge, tail[1]) then
				local joined = table.clone(tail)
				table.insert(joined, 1, anchor.edgeId)
				edgeIds = joined
			end
			if edgeIds then startDist = anchor.dist end
		end
	end

	if not edgeIds then
		-- Fresh spawn (or a restore whose lane is gone): here the goal-biased lane pick is
		-- exactly what is wanted -- a car entering at a connection should set off on the
		-- lane that heads into the city.
		edgeIds = tryPath(g, src, dst, profile, true) or tryPath(g, src, dst, profile, nil)
		startDist = nil
	end
	if not edgeIds then return false end

	local car = VehicleFactory.build(CAR_NAME, variant)
	car:SetAttribute("Through", true) -- observable marker: through-cars vs household cars
	car:SetAttribute("DriverSeed", seed) -- the mind this route was planned with
	car:PivotTo(atCF)
	car.Parent = carFolder()
	_cars[car] = { seed = seed, variant = variant, exitId = exitConn.id }
	local function despawn()
		if _cars[car] then
			_cars[car] = nil
			if car.Parent then car:Destroy() end
		end
	end
	if not NPCDriverService.DriveDirected(car, src, dst, edgeIds, despawn, despawn, startDist) then
		despawn()
		return false
	end
	return true
end

local function listEnds(): ({ any }, { any })
	local entries: { any }, exits: { any } = {}, {}
	for _, c in _outsideConnService.list() do
		if c.dir ~= "out" then table.insert(entries, c) end
		if c.dir ~= "in" then table.insert(exits, c) end
	end
	return entries, exits
end

local function step()
	local g = _roadService.getNavigationGraph()
	if not g or not g:HasEdges() then return end

	local entries, exits = listEnds()
	if #entries == 0 or #exits == 0 then return end

	-- The city carries as much through traffic as its entrances can admit at this hour.
	-- Below target it ramps up; above it (an evening peak passing, or the player deleting
	-- the road that fed it) nothing spawns and the surplus drains out through the exits
	-- on its own, so volume falls the way it rises rather than by despawning cars.
	local target = targetConcurrent(entries, exits)
	target = math.max(math.floor(target * YIELD_FLOOR), target - NPCDriverService.CountCityCarsOnHighways())
	local deficit = target - liveCount()
	if deficit <= 0 then return end
	-- Never launch more cars in one step than the city has inbound lanes to take them.
	local launches = math.min(MAX_SPAWNS_PER_STEP, totalInboundLanes(entries),
		math.max(1, math.floor(deficit * RAMP_FRACTION + 0.5)))

	local usedByEntry: { [string]: number } = {}
	for _ = 1, launches do
		local entry = pickWeighted(entries)
		if entry then
			-- A wide entrance admits several cars at once, staggered back along its own lane
			-- the way a run of arrivals actually enters. Without the stagger every launch
			-- after the first lands on the point the first is still sitting on and is refused
			-- by spawnClear -- so a five-lane highway would trickle in no faster than an alley
			-- and the lane weighting above would buy nothing.
			local nth = usedByEntry[entry.id] or 0
			local src = inboundPoint(g, entry, EDGE_OFFSET + nth * SPAWN_STAGGER)
			-- spawnClear is what makes demand self-limiting: an entrance already backed up
			-- with standing cars admits nobody, exactly as a real queue at a city limit
			-- does. Volume that cannot get in is simply never generated.
			if src and spawnClear(src) then
				local at = CFrame.new(src + Vector3.new(0, CAR_HEIGHT, 0))
				local launched = false
				-- Through traffic needs two ends, and not every pair can reach every other.
				for _ = 1, math.min(EXIT_TRIES, #exits) do
					local exit = exits[_rng:NextInteger(1, #exits)]
					if exit.id ~= entry.id
						and launch(g, exit, at, _rng:NextInteger(0, 1048575), _rng:NextInteger(1, 99)) then
						launched = true
						break
					elseif exit.id ~= entry.id then
						_lastFailedPair = tostring(entry.id) .. " -> " .. tostring(exit.id)
					end
				end
				if launched then
					usedByEntry[entry.id] = nth + 1
				else
					_failedLaunches += 1
				end
			end
		end
	end

	-- A city sitting far below target with every launch failing is a ROUTING fault, not a
	-- quiet hour: the two ends cannot reach each other. Say so, with the pair, once a minute.
	if _failedLaunches > 0 and os.clock() - _lastFailWarn > FAIL_WARN_INTERVAL then
		_lastFailWarn = os.clock()
		warn(string.format("[ThroughTrafficService] %d launches found no route (target %d, live %d). Last pair: %s -- check that both connections' roads join the rest of the network",
			_failedLaunches, targetConcurrent(entries, exits), liveCount(), tostring(_lastFailedPair)))
		_failedLaunches = 0
	end
end

-- == Persistence ==============================================================
-- Through traffic is most of what is standing on a road at any moment, so a save that
-- dropped it would reload a city that looked empty and then took twenty minutes to fill
-- back up -- and a jam the player saved mid-build would simply be gone.
--
-- Each car stores where it is, who is driving it (the seed IS the personality) and which
-- edge of the map it is bound for. The route itself is re-planned on the way back in --
-- the road network may have changed while the city was closed.
--
-- Position is stored TWICE, and the second one is what actually matters:
--
--   * the world pose, for the model's pivot; and
--   * the LANE ANCHOR -- the lane edge the car occupied and how far along it.
--
-- A world pose alone is not enough. Coming back in it has to be projected onto a lane,
-- and two cars a car-length apart can project onto the same place, which collapses a
-- standing queue into a heap the anti-overlap logic then scatters. The lane anchor is
-- exact. Edge ids are "S<segmentId>:L<laneIndex>:<F|R>", built only from a segment id
-- (which RoadSerializer preserves verbatim -- its spec tests exactly that) and lane
-- geometry (which is documented as never renumbered), so they survive a save for any road
-- the player did not edit. NODE ids do not survive; edge ids do.
--
-- Connection ids are stable too -- side plus the rounded coordinate along that side, see
-- OutsideConnectionService.connId -- so the destination is stored by id.
--
-- Fields 8 and 9 (the anchor) are optional: a save written before they existed still
-- loads, just by projection.
local SAVE_VERSION = 1

-- 2 decimals: the precision CitizenService already saves a commuting car's pose at, so
-- there is one convention for "where a car is", not two.
local function r2(n: number): number
	return math.floor(n * 100 + 0.5) / 100
end

function ThroughTrafficService.serialize(): { [string]: any }?
	local keys: { string } = {}
	local keyIndex: { [string]: number } = {}
	local cars: { any } = {}
	for car, rec in _cars do
		if not car.Parent then continue end
		local idx = keyIndex[rec.exitId]
		if not idx then
			idx = #keys + 1
			keys[idx] = rec.exitId
			keyIndex[rec.exitId] = idx
		end
		local cf = car:GetPivot()
		local pos = cf.Position
		local look = cf.LookVector
		local yaw = math.deg(math.atan2(-look.X, -look.Z))
		local row = { r2(pos.X), r2(pos.Y), r2(pos.Z), r2(yaw), rec.seed, rec.variant, idx }
		-- The lane anchor, when the traffic AI still has this car (it always should; a car
		-- it has dropped is about to be pruned anyway).
		local anchor = NPCDriverService.GetLaneAnchor(car)
		if anchor then
			local eIdx = keyIndex[anchor.edgeId]
			if not eIdx then
				eIdx = #keys + 1
				keys[eIdx] = anchor.edgeId
				keyIndex[anchor.edgeId] = eIdx
			end
			row[8] = eIdx
			row[9] = r2(anchor.dist)
		end
		table.insert(cars, row)
	end
	if #cars == 0 then return nil end
	return { version = SAVE_VERSION, keys = keys, cars = cars }
end

-- Each restored car re-plans a route, and a few hundred A* searches in one frame is the
-- post-load client freeze that BuildingService and CitizenService both budget against.
local RESTORE_FRAME_BUDGET = 0.008

-- CitySerializer calls this AFTER CitizenService.restore, which destroys every Model in
-- the Citizens folder these two services share -- anything spawned before that runs is
-- swept straight back out.
function ThroughTrafficService.restore(blob: any)
	-- Whatever is still standing belongs to the outgoing city.
	for car in _cars do
		if car.Parent then car:Destroy() end
	end
	_cars = {}

	if typeof(blob) ~= "table" or typeof(blob.cars) ~= "table" then return end
	if tonumber(blob.version) ~= SAVE_VERSION then return end
	local g = _roadService and _roadService.getNavigationGraph()
	if not g or not g:HasEdges() then return end
	local keys = if typeof(blob.keys) == "table" then blob.keys else {}
	local _, exits = listEnds()
	local half = RoadConstants.MAP_HALF_EXTENT

	local frameStart = os.clock()
	local restored, dropped = 0, 0
	for _, row in blob.cars do
		if restored >= MAX_CONCURRENT then break end
		if os.clock() - frameStart > RESTORE_FRAME_BUDGET then
			task.wait()
			frameStart = os.clock()
		end
		if typeof(row) ~= "table" then continue end
		local x, y, z = tonumber(row[1]), tonumber(row[2]), tonumber(row[3])
		local yaw, seed, variant = tonumber(row[4]), tonumber(row[5]), tonumber(row[6])
		if not (x and y and z and yaw and seed and variant) then continue end
		-- The blob is untrusted. A NaN or an off-map coordinate would drop a car nowhere
		-- and leave the driver AI re-anchoring it for the rest of the session.
		if x ~= x or y ~= y or z ~= z or yaw ~= yaw then continue end
		if math.abs(x) > half or math.abs(z) > half then continue end

		local exitKey = if typeof(row[7]) == "number" then keys[row[7]] else nil
		-- The road carrying this car's exit may have been bulldozed between saves. The car
		-- is still on the street and still has somewhere to be, so send it to any surviving
		-- exit rather than dropping it out of the city.
		local exitConn = if typeof(exitKey) == "string" then _outsideConnService.get(exitKey) else nil
		if not exitConn and #exits > 0 then
			exitConn = exits[_rng:NextInteger(1, #exits)]
		end
		-- The exact lane this car stood on, when the save carries it.
		local edgeKey = if typeof(row[8]) == "number" then keys[row[8]] else nil
		local edgeDist = tonumber(row[9])
		local anchor: { edgeId: string, dist: number }? = nil
		if typeof(edgeKey) == "string" and edgeDist and edgeDist == edgeDist and edgeDist >= 0 then
			anchor = { edgeId = edgeKey, dist = edgeDist }
		end

		if exitConn then
			local cf = CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yaw), 0)
			if launch(g, exitConn, cf, math.floor(seed), math.floor(variant), anchor) then
				restored += 1
			else
				dropped += 1
			end
		else
			dropped += 1
		end
	end

	-- Losing cars silently is what "the jam did not come back" looks like from the outside,
	-- so say so. A handful is normal after the road network was edited between saves; a
	-- large number means routing is failing and the count is the thing worth reporting.
	if dropped > 0 then
		warn(string.format("[ThroughTrafficService] restored %d of %d saved cars; %d could not be re-routed (road edited, or their exit is gone)",
			restored, #blob.cars, dropped))
	end
end

-- What the demand model thinks the city should be carrying right now, and what it
-- actually is. Answers "why is this road empty" / "why is it jammed" with the numbers:
-- an entrance count of 0 means nothing can get in, a target far above live means traffic
-- is still ramping, and a live count pinned at target means the peak has arrived.
function ThroughTrafficService.getDemand(): { [string]: any }
	local entries: { any } = {}
	local exits: { any } = {}
	if _outsideConnService then
		entries, exits = listEnds()
	end
	return {
		factor = diurnalFactor(),
		lanes = totalInboundLanes(entries),
		entries = #entries,
		exits = #exits,
		target = targetConcurrent(entries, exits),
		perLane = laneCapacity(entries, exits),
		crossing = meanCrossing(entries, exits),
		live = liveCount(),
	}
end

function ThroughTrafficService.Init(roadService: any, outsideConnService: any, timeService: any?)
	assert(roadService ~= nil, "[ThroughTrafficService] Init requires RoadService")
	assert(outsideConnService ~= nil, "[ThroughTrafficService] Init requires OutsideConnectionService")
	_roadService = roadService
	_outsideConnService = outsideConnService
	-- Optional: without a clock the demand curve sits flat at its midday plateau rather
	-- than erroring, so a harness can drive this service with two arguments.
	_timeService = timeService
end

function ThroughTrafficService.Start()
	if _running then return end
	_running = true
	task.spawn(function()
		while _running do
			local speed = math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
			task.wait(STEP / math.max(1, speed))
			if speed <= 0 then continue end
			local ok, err = pcall(step)
			if not ok then
				warn("[ThroughTrafficService] step failed: " .. tostring(err))
			end
		end
	end)
end

return ThroughTrafficService
