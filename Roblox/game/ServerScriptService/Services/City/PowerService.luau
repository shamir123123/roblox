--!strict
-- PowerService
-- Owns the city's electricity: the power lines the player draws, and the grid they form.
--
-- The model is Cities: Skylines'. Two rules, and they are deliberately different:
--
--   * Poles carry power to each other ONLY along a wire the player actually drew. Two
--     poles standing next to each other are NOT connected -- you have to run a line
--     between them. That is what `Pole.links` is, and it is what the wires draw.
--   * Everything else -- a house, a shop, a generator -- has a SUPPLY AREA around it, and
--     takes power from any pole standing inside that area. Neighbouring supply areas that
--     overlap merge into one, which is why a lit street lights the houses either side of
--     it without a pole at every door.
--
-- A generator's area is small on purpose (a turbine's yard, not a district): making power
-- is its job, and carrying that power to houses is the line's.
--
-- And every ROAD is a line (Cities: Skylines 2). A street carries power end to end, joins
-- every street it meets, and a pole standing beside it ties a drawn line into it. So the
-- easy game is "put a turbine by a road"; drawn lines are for reaching a generator out in
-- a field, joining two separate towns, or running to the map edge to trade.
--
-- Batteries sit on a grid like generators: they soak up surplus and give it back when the
-- generators fall short, before anything is bought from outside.
--
-- Each connected grid balances its own production against its own demand; a grid holding
-- a pole at the map edge is tied to the outside world and buys the shortfall or sells the
-- surplus there.
--
-- One domain: electricity. It does NOT own the turbines -- EmergencyService places those
-- and this reads them back through the injected reference -- and it does not own buildings.
-- CoverageService asks it whether a point has power; CityStatsService is pushed the
-- city-wide totals for the HUD.

local Players             = game:GetService("Players")
local Lighting            = game:GetService("Lighting")
local Workspace           = game:GetService("Workspace")
local CollectionService   = game:GetService("CollectionService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ServiceTypes     = require(ReplicatedStorage.City.ServiceTypes)
local ZoneTypes        = require(ReplicatedStorage.City.ZoneTypes)
local RoadConstants    = require(ReplicatedStorage.Road.RoadConstants)
local Quant            = require(ReplicatedStorage.Shared.Quant)
local BezierUtil       = require(ReplicatedStorage.Road.BezierUtil)
local NetMiddleware    = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local ServicePlacement = require(ServerScriptService.Services.City.ServicePlacement)
local PlacementFit     = require(ReplicatedStorage.Shared.PlacementFit)
local Const            = require(ServerScriptService.Services.City.CitySimConstants)

local PowerService = {}

local TICK           = 2.0
local CELL           = 16    -- supply raster cell, studs (matches CoverageService)
local PLACE_COOLDOWN = 0.15

-- Shared with the client overlay so the blue areas it draws are exactly the areas that
-- power a building. One source of truth (ServiceTypes), not a constant copied per side.
local BUILDING_REACH = ServiceTypes.PowerBuildingReach

-- Placement rules for a drawn run.
local SPAN         = 64  -- poles are dropped this far apart along a run
local MAX_SPAN     = ServiceTypes.PowerMaxSpan -- the longest single wire that may exist
local SNAP_DIST    = 24  -- start/end this close to a standing pole and it joins that pole
local MAX_RUN      = 4096 -- refuse a nonsense drag across the whole map in one go
-- A pole skipped for landing on a road leaves a two-span hole. The WIRE crosses a road
-- freely, so the poles either side of the hole still join -- otherwise a line drawn across
-- a street silently split into two grids. Two skipped in a row is a genuinely blocked
-- corridor, and there the line does break, which is what it looks like.
local CROSS_SPAN   = math.max(MAX_SPAN, SPAN * 2 + SNAP_DIST)

-- Demand, kW. Cities: Skylines counts electricity in kW and low-density homes draw 60 kW
-- per inhabitant. A workplace is billed PER JOB SLOT, off the same table CitizenService
-- fills, so a level-3 factory's twenty machinists cost twenty times one -- industry is
-- meant to dominate the bill, because the factory floor is what actually eats power.
local RESIDENT_KW = 60
local WORKER_KW   = table.freeze({ Commercial = 50, Industrial = 150, Office = 40 })
-- An empty unit is not a dark one: chillers, servers and machines idle. The share of a
-- full shift's draw that an UNFILLED job slot still costs.
local IDLE_SHARE  = 0.25
-- CS1: higher-level buildings carry their own solar and draw less from the grid.
local LEVEL_SOLAR = 0.06
local LEVEL_FLOOR = 0.5 -- never below half the base draw, however high the level

-- Roads: sampled this often (under the smallest yard's radius, so a road through a yard is
-- always caught), and a pole this close to one ties its line into the street.
local ROAD_STEP      = 16
local POLE_ROAD_JOIN = 24
-- Road points get their own fine hash (built with them, so free per pass): a building only
-- has to look BUILDING_REACH around itself for a street, not across the wide cells sized
-- for the biggest generator's yard -- which, full of road points, was most of the pass.
local ROAD_CELL = 64
-- The shortage notice repeats this often while the problem lasts, and never faster than
-- WARN_MIN_GAP however the problem changes.
local WARN_COOLDOWN = 180
local WARN_MIN_GAP  = 20
-- A pole this close to the map edge is an intertie: its grid can trade with the outside,
-- carrying at most INTERTIE_KW each way.
-- Headroom a grid must have spare before a derelict on it counts as re-powered. A ruin
-- draws nothing, so it fits ANY grid -- including one with no generation in it at all --
-- and would light up (and be rebuilt) for free the tick after it was abandoned. What
-- actually matters is whether the grid could run a household here, so that is the test.
local REVIVE_KW = 180
local EDGE_MARGIN  = 96
local INTERTIE_KW  = 20000
-- $ per kW per month. You buy dear and sell cheap, so a city that exports for profit has
-- to actually overbuild rather than idle on the connection.
local IMPORT_PRICE = 0.05
local EXPORT_PRICE = 0.02

-- The conductors. A line only reads as a line when you can see the wire, so every LINK
-- gets two strands drawn between the crossarms, dropped into a shallow catenary.
local WIRE_THICK    = 0.14
local WIRE_SEGMENTS = 3
local WIRE_SAG      = 0.016 -- of span; poles are only 21 studs, so a deep sag reads as slack
local WIRE_COLOR    = Color3.fromRGB(26, 26, 28)

type Node = {
	pos     : Vector3,
	reach   : number,  -- supply area; 0 for a pole, which connects by wire instead
	pole    : number?, -- pole id when this node IS a pole
	bp      : string?, -- building id when this node IS a building
	svc     : number?, -- service building id (generator, battery or a pump that draws power)
	model   : Model?,  -- a drawing service building's model, for its NoPower badge
	battery : number?, -- service building id when this node IS a battery
	road    : boolean?, -- a point on a street: carries power, joins only along the street
	produce : number,
	demand  : number,
	edge    : boolean,
	home    : boolean,
	dead    : boolean, -- already abandoned: draws nothing, so it needs the spare-capacity test
}

type Pole = {
	id      : number,
	cf      : CFrame,
	variant : string,
	model   : Model,
	links   : { [number]: boolean },
}

local _buildingService  : any
local _serviceBuildings : any -- EmergencyService: owns the placed generators
local _economyService   : any
local _cityStats        : any
local _folder           : Folder
local _wires            : Folder

local _poles   : { [number]: Pole } = {}
local _nextId  = 0
local _lastPlaceAt : { [Player]: number } = {}

-- Where a conductor leaves a pole: the two crossarms, measured off the authored template
-- in Init. Two different lines meeting at one pole take an arm each, so neither is drawn
-- buried inside the other.
local _wireLow    = 18.6
local _wireHigh   = 20.4
local _wireSpread = 1.9

local _suppliedCell : { [number]: boolean } = {}
local _roadService : any
local _roadPts   : { Vector3 }? = nil
local _roadNodes : { Node } = {} -- one grid node per road point, rebuilt with them
local _roadGrid  : { [number]: { number } } = {} -- ROAD_CELL cell -> indices into _roadPts
local _roadLinks : { { number } } = {}
local _roadsDirty = true
-- Battery state. ponytail: charge is not saved -- a loaded city's batteries start empty
-- and fill from the next surplus; persist `_charge` if players notice.
local _charge     : { [number]: number } = {} -- battery building id -> kWh held
local _batteryKey : { [number]: string } = {} -- battery building id -> ServiceTypes key
local _svcPowered : { [number]: boolean } = {} -- consumer service building id -> fed
local _lastClock  : number? = nil
local _warned     : string? = nil
local _warnedAt   = -math.huge
-- There is no "electricity is not in play" any more. Every building asks for power from the
-- day it is built, whether or not the player has laid a single pole -- otherwise the city
-- silently ran on nothing until the first turbine went up, and the whole system only
-- announced itself once you had already opted into it.
local _bucket = 192
local _stats = {
	production = 0, consumption = 0, imported = 0, exported = 0, stored = 0, storage = 0, covered = 1, grids = 0,
}
local _running = false

-- == Geometry ==================================================================

-- A number, not a "cx|cz" string: the grid pass hashes every node and stamps every lit
-- area each tick, and building strings for that was most of its cost. Unique while
-- |cz| < 32768 cells -- far beyond the map at any cell size used here.
local function cellKey(cx: number, cz: number): number
	return cx * 65536 + cz
end

local function cellOf(pos: Vector3): number
	return cellKey(math.floor(pos.X / CELL), math.floor(pos.Z / CELL))
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function stamp(pos: Vector3, radius: number)
	if radius <= 0 then radius = CELL * 0.5 end -- a pole still lights its own cell
	local minCx, maxCx = math.floor((pos.X - radius) / CELL), math.floor((pos.X + radius) / CELL)
	local minCz, maxCz = math.floor((pos.Z - radius) / CELL), math.floor((pos.Z + radius) / CELL)
	for cx = minCx, maxCx do
		for cz = minCz, maxCz do
			local dx = (cx + 0.5) * CELL - pos.X
			local dz = (cz + 0.5) * CELL - pos.Z
			if dx * dx + dz * dz <= radius * radius then _suppliedCell[cellKey(cx, cz)] = true end
		end
	end
end

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("PowerLines")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "PowerLines"; f.Parent = city
	end
	local w = f:FindFirstChild("Wires")
	if not w or not w:IsA("Folder") then
		if w then w:Destroy() end
		w = Instance.new("Folder"); w.Name = "Wires"; w.Parent = f
	end
	_wires = w :: Folder
	return f :: Folder
end

-- == The grid ==================================================================

local function find(parent: { number }, x: number): number
	while parent[x] ~= x do
		parent[x] = parent[parent[x]]
		x = parent[x]
	end
	return x
end

local function demandOf(view: any): number
	if view.abandoned then return 0 end
	local level = math.clamp(math.floor(tonumber(view.level) or 1), 1, 3)
	local base: number
	if ZoneTypes.isResidential(view.zone) then
		base = (tonumber(view.residents) or 0) * RESIDENT_KW
	else
		-- `fill` is 0..1 occupancy, so it has to be multiplied back up by the job slots to
		-- get a head count. Billing the fraction itself charged a full factory the same as
		-- a corner shop, which is why industry read as nearly free.
		local slots = Const.JOB_CAP[view.zone]
		local jobs = if slots then slots[level] else 0
		local filled = math.clamp(tonumber(view.fill) or 0, 0, 1) * jobs
		base = (filled + (jobs - filled) * IDLE_SHARE) * (WORKER_KW[view.zone] or 0)
	end
	return base * math.max(LEVEL_FLOOR, 1 - LEVEL_SOLAR * (level - 1))
end

-- How much of its noon peak a solar generator is making right now: 0 before dawn and
-- after dusk, 1 at midday. Lighting.ClockTime is TimeService's clock, and Roblox's sun
-- altitude is exactly this sine of it (measured: sunDir.Y / 0.954 matches to 3 decimals at
-- every hour, at any latitude), so a farm's output tracks the sun the player can see.
local SUNRISE_HOUR, SUNSET_HOUR = 6, 18 -- TimeService's, and the clock warp keeps them exact
local function sunFactor(): number
	local h = Lighting.ClockTime
	if h <= SUNRISE_HOUR or h >= SUNSET_HOUR then return 0 end
	return math.sin(math.pi * (h - SUNRISE_HOUR) / (SUNSET_HOUR - SUNRISE_HOUR))
end

-- Every road carries a distribution line (Cities: Skylines 2): a street is one conductor
-- end to end, and streets meeting at a junction are one. So a house on a lit street is lit,
-- and hooking a turbine up means reaching ANY road -- by standing it beside one, or by
-- running a line to one. Sampled finer than the smallest generator yard, so a road passing
-- through a turbine's yard always has a point inside it. Cached: roads change rarely, and
-- RoadService says when (markRoadsDirty).
local function buildRoads()
	local pts: { Vector3 } = {}
	local links: { { number } } = {}
	local net = _roadService and _roadService.getNetwork and _roadService.getNetwork()
	if net then
		local atNode: { [any]: number } = {}
		local function tie(i: number, nodeId: any)
			if nodeId == nil then return end
			local j = atNode[nodeId]
			if j then links[#links + 1] = { i, j } else atNode[nodeId] = i end
		end
		for _, seg in net:getSegments() do
			if typeof(seg.p0) ~= "Vector3" then continue end
			local chord = (seg.p1 - seg.p0).Magnitude + (seg.p2 - seg.p1).Magnitude + (seg.p3 - seg.p2).Magnitude
			local steps = math.clamp(math.ceil(chord / ROAD_STEP), 1, 256)
			local first = #pts + 1
			for s = 0, steps do
				pts[#pts + 1] = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, s / steps)
				if s > 0 then links[#links + 1] = { #pts - 1, #pts } end
			end
			tie(first, seg.startNode)
			tie(#pts, seg.endNode)
		end
	end
	-- The road points' grid nodes never change between road edits: built once here and
	-- shared by every pass, instead of a fresh table per point every tick.
	local roadNodes: { Node } = table.create(#pts)
	for i, p in pts do
		roadNodes[i] = {
			pos = p, reach = 0, pole = nil, road = true, produce = 0, demand = 0, edge = false,
			home = false, dead = false,
		}
	end
	local grid: { [number]: { number } } = {}
	for i, p in pts do
		local k = cellKey(math.floor(p.X / ROAD_CELL), math.floor(p.Z / ROAD_CELL))
		local cell = grid[k]
		if not cell then cell = {}; grid[k] = cell end
		cell[#cell + 1] = i
	end
	_roadPts, _roadLinks, _roadNodes, _roadGrid = pts, links, roadNodes, grid
	_roadsDirty = false
end

local function gatherNodes(): ({ Node }, { [number]: number }, number)
	local nodes: { Node } = {}
	local poleIndex: { [number]: number } = {} -- pole id -> index in `nodes`

	table.clear(_batteryKey)
	if _serviceBuildings and _serviceBuildings.list then
		for _, b in _serviceBuildings.list() do
			if not (b.model and b.model.Parent) then continue end
			local spec = ServiceTypes.get(b.key) :: any
			if not spec then continue end
			local rated = tonumber(spec.powerOutput) or 0
			-- Solar rates its PEAK, so what it delivers this tick rides the sun. The node goes
			-- in even at 0 kW: its yard is what joins the lines drawn to it, and a grid that
			-- re-split itself every dusk would balance against a different topology each night.
			local out = if rated > 0 and spec.solar then rated * sunFactor() else rated
			local use = tonumber(spec.powerUse) or 0
			if spec.battery then _batteryKey[b.id] = b.key end
			if rated > 0 or spec.battery then
				nodes[#nodes + 1] = {
					pos = b.cf.Position, reach = b.radius, pole = nil, svc = b.id,
					battery = if spec.battery then b.id else nil,
					produce = out, demand = 0, edge = false, home = false, dead = false,
				}
			elseif use > 0 then
				-- A pump or a treatment plant is a CUSTOMER: it takes power the way a house
				-- does, and WaterService asks whether it got any before it pumps a drop.
				nodes[#nodes + 1] = {
					pos = b.cf.Position, reach = BUILDING_REACH, pole = nil, svc = b.id, model = b.model,
					produce = 0, demand = use, edge = false, home = false, dead = false,
				}
			end
		end
	end

	local half = RoadConstants.MAP_HALF_EXTENT
	for id, p in _poles do
		local pos = p.cf.Position
		local edge = (half - math.max(math.abs(pos.X), math.abs(pos.Z))) <= EDGE_MARGIN
		nodes[#nodes + 1] = {
			pos = pos, reach = 0, pole = id, produce = 0, demand = 0, edge = edge,
			home = false, dead = false,
		}
		poleIndex[id] = #nodes
	end

	if _buildingService and _buildingService.listBuildings then
		for _, v in _buildingService.listBuildings() do
			if typeof(v.position) ~= "Vector3" then continue end
			nodes[#nodes + 1] = {
				pos = v.position, reach = BUILDING_REACH, pole = nil, bp = v.bpId,
				produce = 0, demand = demandOf(v), edge = false,
				home = ZoneTypes.isResidential(v.zone) and not v.abandoned and (tonumber(v.residents) or 0) > 0,
				dead = v.abandoned == true,
			}
		end
	end

	-- A demolished battery takes its charge with it.
	for id in _charge do
		if not _batteryKey[id] then _charge[id] = nil end
	end

	-- Road points go last, as zero-reach nodes like poles: a building or a yard takes power
	-- from one standing inside its area, and they never join each other by proximity --
	-- only down the street they sample (_roadLinks).
	if _roadsDirty or not _roadPts then buildRoads() end
	local roadBase = #nodes
	table.move(_roadNodes, 1, #_roadNodes, roadBase + 1, nodes)

	return nodes, poleIndex, roadBase
end

-- Game hours since the last pass, off TimeService's clock, so a battery charges by the
-- hour the player sees at any game speed. Capped so a time skip is not a free full charge.
local function hoursSinceLastPass(): number
	local now = Lighting.ClockTime
	local last = _lastClock
	_lastClock = now
	if not last then return 0 end
	local dt = now - last
	if dt < 0 then dt += 24 end
	return math.min(dt, 1)
end

-- One kid-readable line when the city first runs short, and again only after a cooldown.
-- The badge says WHICH building; this says what to do about it.
local function warnShort(message: string?)
	if message == nil then _warned = nil; return end
	local since = os.clock() - _warnedAt
	if since < WARN_MIN_GAP or (message == _warned and since < WARN_COOLDOWN) then return end
	_warned, _warnedAt = message, os.clock()
	local net = PowerService._net
	if net and net.Notify then
		net.Notify:FireAllClients({ text = message, kind = "danger", duration = 6 })
	end
end

local function rebuild()
	local nodes, poleIndex, roadBase = gatherNodes()
	local n = #nodes
	local dtH = hoursSinceLastPass()

	local parent = table.create(n)
	for i = 1, n do parent[i] = i end
	local function union(a: number, b: number)
		local ra, rb = find(parent, a), find(parent, b)
		if ra ~= rb then parent[ra] = rb end
	end

	-- 1. Wires. A pole reaches another pole ONLY down a line the player drew.
	for id, p in _poles do
		local ia = poleIndex[id]
		if not ia then continue end
		for other in p.links do
			local ib = poleIndex[other]
			if ib then union(ia, ib) end
		end
	end

	-- 1b. Streets. Every sample along a road, and every road meeting at a junction.
	for _, l in _roadLinks do union(roadBase + l[1], roadBase + l[2]) end

	-- 2. Supply areas. A building or generator is on the grid of any pole or road point
	--    standing inside its own area, and two overlapping areas merge. Poles and roads have
	--    no area of their own, so nothing joins through them except a wire or the street.
	-- 2a. Streets: every node with an area (and every pole, POLE_ROAD_JOIN) takes the road
	--     points inside it, off the road hash.
	for i = 1, roadBase do
		local a = nodes[i]
		local reach = if a.pole then POLE_ROAD_JOIN else a.reach
		if reach <= 0 then continue end
		local px, pz = a.pos.X, a.pos.Z
		local r2 = reach * reach
		for cx = math.floor((px - reach) / ROAD_CELL), math.floor((px + reach) / ROAD_CELL) do
			for cz = math.floor((pz - reach) / ROAD_CELL), math.floor((pz + reach) / ROAD_CELL) do
				local cell = _roadGrid[cellKey(cx, cz)]
				if not cell then continue end
				for _, k in cell do
					local o = _roadPts[k]
					local ox, oz = px - o.X, pz - o.Z
					if ox * ox + oz * oz <= r2 then union(i, roadBase + k) end
				end
			end
		end
	end
	-- 2b. Everything else (roads excluded): a pole only has to stand INSIDE an area; two areas
	--     have to overlap. Spatial hash: only nodes in neighbouring buckets can reach each other.
	local buckets: { [number]: { number } } = {}
	for i = 1, roadBase do
		local nd = nodes[i]
		local k = cellKey(math.floor(nd.pos.X / _bucket), math.floor(nd.pos.Z / _bucket))
		local b = buckets[k]
		if not b then b = {}; buckets[k] = b end
		b[#b + 1] = i
	end
	for i = 1, roadBase do
		local a = nodes[i]
		local reach = a.reach
		if a.pole or reach <= 0 then continue end -- poles only grab streets (2a)
		local bx = math.floor(a.pos.X / _bucket)
		local bz = math.floor(a.pos.Z / _bucket)
		for dx = -1, 1 do
			for dz = -1, 1 do
				local b = buckets[cellKey(bx + dx, bz + dz)]
				if not b then continue end
				for _, j in b do
					if j == i then continue end
					local o = nodes[j]
					local limit = if o.reach > 0 then reach + o.reach else reach
					if j > i or o.reach <= 0 then
						local ox, oz = a.pos.X - o.pos.X, a.pos.Z - o.pos.Z
						if ox * ox + oz * oz <= limit * limit then union(i, j) end
					end
				end
			end
		end
	end

	type Group = { produce: number, demand: number, tie: number, stored: number, rate: number, cells: { number } }
	local groups: { [number]: Group } = {}
	for i, nd in nodes do
		local g = find(parent, i)
		local acc = groups[g]
		if not acc then acc = { produce = 0, demand = 0, tie = 0, stored = 0, rate = 0, cells = {} }; groups[g] = acc end
		acc.produce += nd.produce
		acc.demand  += nd.demand
		if nd.edge then acc.tie += INTERTIE_KW end
		local cell = nd.battery
		if cell then
			local spec = ServiceTypes.get(_batteryKey[cell] or "") :: any
			acc.cells[#acc.cells + 1] = cell
			acc.stored += _charge[cell] or 0
			acc.rate += if spec then spec.batteryRate or 0 else 0
		end
	end

	-- Balance each grid on its own, then RATION what it has building by building. A grid
	-- that is short does NOT go black: the supply is handed out until it runs out, and only
	-- the buildings it did not stretch to go dark. Blacking out the whole grid meant one
	-- house too many switched off a whole district.
	--
	-- Cheapest demand first, so a shortfall leaves the most buildings lit -- and so the
	-- order is the same every tick rather than flickering a different set of houses each
	-- pass. Zero-demand nodes (poles, roads, generators, a derelict) always fit.
	--
	-- Supply order: the grid's own generators, then its batteries, then the outside world.
	local members: { [number]: { number } } = {}
	for i in nodes do
		local g = find(parent, i)
		local m = members[g]
		if not m then m = {}; members[g] = m end
		m[#m + 1] = i
	end

	local production, consumption, imported, exported = 0, 0, 0, 0
	local stored, storage = 0, 0
	local supplied: { [number]: boolean } = {} -- NODE index -> lit, not grid root
	local spare: { [number]: number } = {}     -- grid root -> capacity left after rationing
	local grids = 0
	local short = false
	for g, acc in groups do
		grids += 1
		production  += acc.produce
		consumption += acc.demand
		local fromCells = if dtH > 0 then math.min(acc.rate, acc.stored / dtH) else 0
		local budget = acc.produce + fromCells + acc.tie
		local m = members[g]
		table.sort(m, function(a: number, b: number): boolean
			local da, db = nodes[a].demand, nodes[b].demand
			if da ~= db then return da < db end
			return a < b
		end)
		local drawn = 0
		for _, i in m do
			local d = nodes[i].demand
			if drawn + d <= budget + 1e-6 then
				drawn += d
				supplied[i] = true
			end
		end
		-- A grid with nothing feeding it at all is not SHORT, it is unconnected.
		if drawn + 1e-6 < acc.demand and acc.produce + acc.tie + acc.rate > 0 then short = true end
		spare[g] = budget - drawn

		-- Settle the batteries: they cover what the generators could not, before a single
		-- kW is bought; and they soak up the surplus before a single kW is sold.
		local surplus = acc.produce - drawn
		local charge = 0 -- kW into (+) or out of (-) the batteries this pass
		if surplus < 0 then
			charge = -math.min(-surplus, fromCells)
			imported += -surplus + charge
		else
			charge = math.min(surplus, acc.rate)
			exported += math.min(surplus - charge, acc.tie)
		end
		-- Share the change out cell by cell, each up to its own rate and capacity.
		local energy = charge * dtH
		for _, cell in acc.cells do
			local spec = ServiceTypes.get(_batteryKey[cell] or "") :: any
			if not spec then continue end
			local have = _charge[cell] or 0
			local step = math.clamp(energy, -math.min(have, spec.batteryRate * dtH), math.min(spec.battery - have, spec.batteryRate * dtH))
			_charge[cell] = have + step
			energy -= step
			stored += have + step
			storage += spec.battery
		end
	end

	table.clear(_suppliedCell)
	table.clear(_svcPowered)
	local homes, poweredHomes = 0, 0
	for i, nd in nodes do
		local ok = supplied[i] == true
		-- A derelict draws nothing and so fits every grid, dead ones included. It counts as
		-- re-powered only where there is room to actually RUN the house it would be rebuilt
		-- into -- ZoneSimService reads this and does the rebuilding.
		if ok and nd.dead then ok = (spare[find(parent, i)] or 0) >= REVIVE_KW end
		if nd.home then
			homes += 1
			if ok then poweredHomes += 1 end
		end
		if ok and not nd.road then stamp(nd.pos, nd.reach) end
		if nd.svc and nd.demand > 0 then
			_svcPowered[nd.svc] = ok
			local m = nd.model
			if m and m:GetAttribute("NoPower") ~= not ok then m:SetAttribute("NoPower", not ok) end
		end

		-- A pole on a grid with nothing generating into it and no map-edge tie is wired to
		-- nowhere. The badge is the only thing that says so before the player wonders why a
		-- street they plainly connected is dark. Re-stamped every pass, so a line that later
		-- reaches a turbine clears itself.
		local poleId = nd.pole
		if poleId then
			local acc = groups[find(parent, i)]
			local stranded = acc ~= nil and acc.produce <= 0 and acc.tie <= 0 and acc.rate <= 0
			local p = _poles[poleId]
			local m = p and p.model
			if m and m.Parent and m:GetAttribute("Stranded") ~= stranded then
				m:SetAttribute("Stranded", stranded)
			end
		end

		-- Per-building power: the attribute is what puts the no-power icon over its roof.
		-- What going without COSTS is CitizenService's: families move out of a dark home
		-- one at a time, and nobody moves into one.
		local bp = nd.bp
		if bp and _buildingService.setPowered then _buildingService.setPowered(bp, ok) end
	end

	_stats = {
		production  = production,
		consumption = consumption,
		imported    = imported,
		exported    = exported,
		stored      = stored,
		storage     = storage,
		covered     = if homes == 0 then 1 else poweredHomes / homes,
		grids       = grids,
	}

	if _cityStats and _cityStats.setPowerStats then _cityStats.setPowerStats(_stats) end

	if homes > 0 and poweredHomes == 0 and production <= 0 and imported <= 0 then
		warnShort("Your homes have no electricity! Build a Wind Turbine next to a road -- every road carries power.")
	elseif short then
		warnShort("Not enough electricity! Some buildings are dark. Build more power, or batteries for the night.")
	elseif poweredHomes < homes then
		warnShort("Some homes are not connected to power. Connect them with a road or a power line.")
	else
		warnShort(nil)
	end
end

-- == Poles and wires ===========================================================

-- Which of the two authored poles to stand, and which way to face it -- decided by the
-- lines actually strung to it, not by what happens to be standing nearby. A pole whose
-- wires run straight through carries the Inline head (one crossarm); a corner, a T, the
-- end of a run or a lone pole gets the Cross head. The model's +Z runs along the line.
local function variantFor(id: number): (string, number)
	local me = _poles[id]
	local dirs: { Vector3 } = {}
	for other in me.links do
		local o = _poles[other]
		if not o then continue end
		local d = Vector3.new(o.cf.Position.X - me.cf.Position.X, 0, o.cf.Position.Z - me.cf.Position.Z)
		if d.Magnitude > 0.01 then dirs[#dirs + 1] = d.Unit end
	end
	if #dirs == 0 then return "PowerPole_Cross", 0 end
	local yaw = math.atan2(dirs[1].X, dirs[1].Z)
	if #dirs == 2 and dirs[1]:Dot(dirs[2]) <= -0.6 then return "PowerPole_Inline", yaw end
	return "PowerPole_Cross", yaw
end

-- The two authored heads do NOT agree on which way their crossarm runs: Inline's is along
-- the model's X, Cross's along its Z. Turning both by the same yaw stood every Cross pole
-- -- every dead end, corner and T -- broadside to its own line. Measured off the art.
local HEAD_YAW = table.freeze({
	PowerPole_Inline = 0,
	PowerPole_Cross  = math.pi * 0.5,
})

local function poleTemplate(variant: string): Model?
	local folder = ReplicatedStorage:FindFirstChild("Props")
	folder = folder and folder:FindFirstChild("PowerPoles")
	local t = folder and folder:FindFirstChild(variant)
	return if t and t:IsA("Model") then t :: Model else nil
end

local function skin(p: Pole)
	local variant, yaw = variantFor(p.id)
	local cf = CFrame.new(p.cf.Position) * CFrame.Angles(0, yaw + (HEAD_YAW[variant] or 0), 0)
	if p.model and p.model.Parent and p.variant == variant then
		p.model:PivotTo(cf)
		return
	end
	if p.model then p.model:Destroy() end
	local template = poleTemplate(variant)
	if not template then
		warn("[PowerService] missing pole template: " .. variant)
		return
	end
	local m = template:Clone()
	m.Name = variant
	m:PivotTo(cf)
	m:SetAttribute("ServiceId", p.id)
	m:SetAttribute("ServiceType", "PowerPole")
	m:SetAttribute("ServiceKind", "PowerLine")
	m:SetAttribute("ServiceName", "Power Line")
	CollectionService:AddTag(m, "PowerPole")
	m.Parent = _folder
	p.model = m
	p.variant = variant
end

local function strand(a: Vector3, b: Vector3)
	local len = (b - a).Magnitude
	if len < 0.05 then return end
	local p = Instance.new("Part")
	p.Name = "Wire"
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false -- must not swallow a click aimed at the pole behind it
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = WIRE_COLOR
	p.Size = Vector3.new(WIRE_THICK, WIRE_THICK, len)
	p.CFrame = CFrame.lookAt((a + b) * 0.5, b)
	p.Parent = _wires
end

-- Which crossarm each line leaves this pole on. A pole standing in the middle of ONE run
-- puts both its spans on the same arm, so the line reads as continuous; where two DIFFERENT
-- lines meet, each gets an arm of its own. Decided per pole, and a span is drawn sloping
-- between whichever arm each of its two ends chose, so the ends never have to agree.
local function armsOf(id: number): { [number]: number }
	local me = _poles[id]
	local order: { number } = {}
	local dir: { [number]: Vector3 } = {}
	for other in me.links do
		local o = _poles[other]
		if not o then continue end
		local d = Vector3.new(o.cf.Position.X - me.cf.Position.X, 0, o.cf.Position.Z - me.cf.Position.Z)
		if d.Magnitude < 0.01 then continue end
		order[#order + 1] = other
		dir[other] = d.Unit
	end
	table.sort(order) -- by id, so a redraw never reshuffles which line sits where
	local arm: { [number]: number } = {}
	local lowTaken = false
	for _, other in order do
		local mate: number? = nil
		for _, prev in order do
			if arm[prev] and dir[prev]:Dot(dir[other]) <= -0.8 then mate = prev; break end
		end
		if mate then
			arm[other] = arm[mate] -- the far half of the same straight line: same arm
		elseif not lowTaken then
			arm[other] = 0; lowTaken = true
		else
			arm[other] = 1
		end
	end
	return arm
end

-- Redraw every line. One span per LINK, so the wire is a picture of the graph and cannot
-- disagree with what is actually connected.
-- ponytail: rebuilds all spans on any edit. Per-link folders is the upgrade path if a big
-- grid starts hitching on placement.
local function restring()
	if not _wires then return end
	_wires:ClearAllChildren()
	local arms: { [number]: { [number]: number } } = {}
	for id in _poles do arms[id] = armsOf(id) end
	for idA, a in _poles do
		for idB in a.links do
			if idB <= idA then continue end -- each link once
			local b = _poles[idB]
			if not b then continue end
			local d = Vector3.new(b.cf.Position.X - a.cf.Position.X, 0, b.cf.Position.Z - a.cf.Position.Z)
			local len = d.Magnitude
			if len < 0.01 then continue end
			local dir = d / len
			local perp = Vector3.new(-dir.Z, 0, dir.X) * _wireSpread
			local sag = len * WIRE_SAG
			local liftA = Vector3.new(0, if arms[idA][idB] == 1 then _wireHigh else _wireLow, 0)
			local liftB = Vector3.new(0, if arms[idB][idA] == 1 then _wireHigh else _wireLow, 0)
			for _, side in ipairs({ -1, 1 }) do
				local from = a.cf.Position + liftA + perp * side
				local to   = b.cf.Position + liftB + perp * side
				local prev = from
				for i = 1, WIRE_SEGMENTS do
					local t = i / WIRE_SEGMENTS
					local pt = from:Lerp(to, t) - Vector3.new(0, sag * 4 * t * (1 - t), 0)
					strand(prev, pt)
					prev = pt
				end
			end
		end
	end
end

local function spawnPole(id: number, pivot: CFrame): Pole
	local p: Pole = { id = id, cf = pivot, variant = "", model = nil :: any, links = {} }
	_poles[id] = p
	skin(p)
	return p
end

local function linkPoles(a: number, b: number)
	if a == b then return end
	local pa, pb = _poles[a], _poles[b]
	if not pa or not pb then return end
	pa.links[b] = true
	pb.links[a] = true
end

-- Where a generator wants a pole: inside its own yard, on the side the run came from.
-- A yard is only 20-odd studs across, so without this the player has to drop a pole almost
-- exactly on the tower to hook the thing up.
local function generatorSnap(pos: Vector3): Vector3?
	if not _serviceBuildings or not _serviceBuildings.list then return nil end
	for _, b in _serviceBuildings.list() do
		local spec = ServiceTypes.get(b.key)
		local yard = spec and ((spec :: any).powerOutput or (spec :: any).battery) and spec.coverageRadius or 0
		if yard <= 0 then continue end
		local d = flatDist(b.cf.Position, pos)
		if d <= yard + SNAP_DIST then
			local away = Vector3.new(pos.X - b.cf.Position.X, 0, pos.Z - b.cf.Position.Z)
			local dir = if away.Magnitude > 0.01 then away.Unit else Vector3.new(1, 0, 0)
			return b.cf.Position + dir * (yard * 0.5)
		end
	end
	return nil
end

-- Where a pole would actually STAND, or why it can't: in the way, off the map, or in water.
-- prepareFree re-grounds the point onto the terrain, so the test has to run on ITS answer:
-- testing the raw point on the drawn line tested a spot hanging in mid-air over sloping
-- ground, the box missed the road underneath it, and the pole was then dropped onto the
-- carriageway -- the middle pole standing in the middle of the road.
local function seat(fp: Vector3, pos: Vector3): (CFrame?, string?)
	local pivot, why = ServicePlacement.prepareFree(fp, CFrame.new(pos), nil, true)
	if not pivot then return nil, why or "nowhere to put it" end -- off the map or in water
	local blocked = PlacementFit.poleBlockedBy(pivot.Position)
	return pivot, if blocked then "a pole can't stand on " .. blocked else nil
end

-- Nudge a pole along its own line until its footing is off whatever it landed on. Kept
-- under a third of a span either way, so the two wires either side of it stay inside
-- CROSS_SPAN. Returns the seat it found, or nil and the reason it is still blocked.
local SLIDE = table.freeze({ 0.12, -0.12, 0.24, -0.24, 0.3, -0.3 })
local function slideClear(fp: Vector3, want: Vector3, dir: Vector3): (CFrame?, string?)
	local pivot, blocked = seat(fp, want)
	if pivot and not blocked then return pivot, nil end
	for _, f in SLIDE do
		local try, why = seat(fp, want + dir * (SPAN * f))
		if try and not why then return try, nil end
	end
	return nil, blocked
end

-- The pole standing at `pos`, if one is close enough to join rather than duplicate.
local function poleNear(pos: Vector3, within: number): number?
	local best, bestD = nil, within
	for id, p in _poles do
		local d = flatDist(p.cf.Position, pos)
		if d <= bestD then best, bestD = id, d end
	end
	return best
end

-- == Public ====================================================================

-- Draw one run of line from `fromPos` to `toPos`: poles every SPAN studs, wired to each
-- other as they go. Either end SNAPS to a pole already standing there, which is how a new
-- line joins an existing one -- nothing connects by proximity alone.
-- Returns ok, reason, and the id of the pole the run ended on (the client chains from it).
function PowerService.placeRun(fromPos: Vector3, toPos: Vector3): (boolean, string?, number?)
	local spec = ServiceTypes.get("PowerPole")
	if not spec then return false, "unknown building" end
	if typeof(fromPos) ~= "Vector3" or typeof(toPos) ~= "Vector3" then return false, "bad run" end
	if fromPos ~= fromPos or toPos ~= toPos then return false, "bad run" end

	local runLen = flatDist(fromPos, toPos)
	if runLen > MAX_RUN then return false, "that line is too long" end

	-- Where poles want to go: both ends, plus enough in between that no span exceeds MAX.
	local wanted: { Vector3 } = {}
	if runLen < 0.5 then
		wanted[1] = fromPos
	else
		local steps = math.max(1, math.ceil(runLen / SPAN))
		for i = 0, steps do
			wanted[#wanted + 1] = fromPos:Lerp(toPos, i / steps)
		end
	end

	local flat = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	local dir = if flat.Magnitude > 0.5 then flat.Unit else Vector3.zAxis

	local fp = ServiceTypes.footprintStuds(spec)
	local ids: { number } = {}
	local built: { number } = {}
	local charged = 0
	local function undo()
		for _, id in built do
			local p = _poles[id]
			if p and p.model then p.model:Destroy() end
			_poles[id] = nil
		end
	end

	for i, want in wanted do
		-- An existing pole at this spot is joined, not duplicated. The ends snap generously
		-- (that is how you hook onto a line); the middle only merges near-exact overlaps.
		local snap = if i == 1 or i == #wanted then SNAP_DIST else SPAN * 0.35
		local existing = poleNear(want, snap)
		if existing then
			ids[#ids + 1] = existing
			continue
		end
		local ends = (i == 1 or i == #wanted)
		if ends then
			want = generatorSnap(want) or want
		end
		-- A pole may not stand ON a road or IN a building -- the WIRE is free to cross
		-- both, because only the footing is tested. A pole in the middle of a run slides
		-- along the line to find clear ground; the two the player actually clicked have to
		-- be where they clicked, so those refuse outright and say why.
		-- skipOverlap (inside seat): the footprint veto is the wrong test for a slim relay
		-- -- it would refuse the verge between a house and the kerb, which is exactly where a
		-- pole belongs. poleBlockedBy is the right one. Bounds, water, the re-grounded Y and
		-- the save-grid snap all still apply.
		local pivot: CFrame?
		local blocked: string?
		if ends then
			-- Off the map or in water refuses too: skipping a clicked end reported success
			-- with nothing built there, and the client chained its next run from thin air.
			pivot, blocked = seat(fp, want)
			if blocked then undo(); return false, blocked end
		else
			pivot, blocked = slideClear(fp, want, dir)
		end
		if not pivot then continue end -- a middle pole blocked, off the map or in water: skip it, keep the run
		_nextId += 1
		spawnPole(_nextId, pivot)
		ids[#ids + 1] = _nextId
		built[#built + 1] = _nextId
		charged += spec.cost
	end

	if #ids == 0 then return false, "nowhere to put it" end

	if charged > 0 and _economyService and _economyService.trySpend then
		if not _economyService.trySpend(charged) then
			undo()
			return false, "can't afford"
		end
	end

	for i = 1, #ids - 1 do
		if flatDist(_poles[ids[i]].cf.Position, _poles[ids[i + 1]].cf.Position) <= CROSS_SPAN + 0.5 then
			linkPoles(ids[i], ids[i + 1])
		end
	end

	for _, id in ids do
		local p = _poles[id]
		if p then skin(p) end
	end
	restring()
	return true, nil, ids[#ids]
end

function PowerService.removePole(id: number)
	local p = _poles[id]
	if not p then return end
	for other in p.links do
		local o = _poles[other]
		if o then o.links[id] = nil end
	end
	if p.model and p.model.Parent then p.model:Destroy() end
	_poles[id] = nil
	for other in p.links do
		local o = _poles[other]
		if o then skin(o) end
	end
	restring()
end

function PowerService.clear()
	for id, p in _poles do
		if p.model and p.model.Parent then p.model:Destroy() end
		_poles[id] = nil
	end
	_nextId = 0
	if _wires then _wires:ClearAllChildren() end
end

-- Rebuild the grid synchronously. Start() ticks this on its own; callers use it when they
-- need the answer NOW (tests, and a deterministic read straight after a load).
function PowerService.rebuildNow()
	rebuild()
end

-- True when `pos` is being supplied. An unwired city supplies nothing -- power is asked for
-- from the first building, not from the first turbine.
function PowerService.isSuppliedAt(pos: Vector3): boolean
	return _suppliedCell[cellOf(pos)] == true
end

-- Whether the city has built any electricity at all -- a pole or a generator. Not a supply
-- test: isSuppliedAt is the one that answers "are the lights on here".
function PowerService.hasPower(): boolean
	return next(_poles) ~= nil or _stats.production > 0
end

function PowerService.getStats(): { [string]: number }
	return table.clone(_stats)
end

-- What this month's trading costs (import) and earns (export).
function PowerService.getTradeMonthly(): (number, number)
	return _stats.imported * IMPORT_PRICE, _stats.exported * EXPORT_PRICE
end

-- Two generators may not have their YARDS overlap -- the blue circles, which is the ground
-- the machine itself stands on. The amber `minSpacing` ring is advice about blade
-- clearance, not a veto: refusing on it turned away turbines that plainly fitted, because
-- that ring is three times the width of the tower inside it.
function PowerService.spacingBlockedAt(key: string, pos: Vector3, ignoreId: number?): boolean
	local spec = ServiceTypes.get(key)
	if not spec or (tonumber((spec :: any).powerOutput) or 0) <= 0 then return false end
	-- A generator whose plot is wider than its yard is already governed by the footprint
	-- overlap test, so a yard veto on top of it only refuses ground that is plainly free.
	if (spec :: any).yardVeto == false then return false end
	if not _serviceBuildings then return false end
	for _, b in _serviceBuildings.list() do
		if ignoreId and b.id == ignoreId then continue end
		local other = ServiceTypes.get(b.key)
		if not other or (tonumber((other :: any).powerOutput) or 0) <= 0 then continue end
		if flatDist(b.cf.Position, pos) < spec.coverageRadius + other.coverageRadius then return true end
	end
	return false
end

-- Where a drag can snap to: the pole nearest `pos`, within SNAP_DIST. The client asks so
-- its preview lands on the same pole the server will.
function PowerService.snapTarget(pos: Vector3): Vector3?
	local id = poleNear(pos, SNAP_DIST)
	if id then return _poles[id].cf.Position end
	return generatorSnap(pos)
end

-- How many poles are standing. CityEconomyService bills each one a monthly upkeep --
-- a drawn line is infrastructure like a road, not a one-off purchase.
function PowerService.getPoleCount(): number
	local n = 0
	for _ in _poles do n += 1 end
	return n
end

function PowerService.serialize(): { [string]: any }
	local out: { any } = {}
	for id, p in _poles do
		local links: { number } = {}
		for other in p.links do
			if other > id then links[#links + 1] = other end -- store each link once
		end
		table.insert(out, { id = id, pivot = Quant.packPivot(p.cf), links = links })
	end
	return { version = 2, nextId = _nextId, poles = out }
end

function PowerService.restore(data: any)
	PowerService.clear()
	if typeof(data) ~= "table" then return end
	local rows = if typeof(data.poles) == "table" then data.poles else data
	_nextId = math.max(0, math.floor(tonumber(data.nextId) or 0))
	local used: { [number]: boolean } = {}
	local pending: { { from: number, to: number } } = {}

	for _, row in rows do
		if typeof(row) ~= "table" then continue end
		local pivot = Quant.unpackPivot(row.pivot)
		if not pivot then continue end
		local id = math.floor(tonumber(row.id) or 0)
		if id <= 0 or used[id] then _nextId += 1; id = _nextId end
		used[id] = true
		_nextId = math.max(_nextId, id)
		spawnPole(id, pivot)
		if typeof(row.links) == "table" then
			for _, other in row.links do
				local o = math.floor(tonumber(other) or 0)
				if o > 0 then pending[#pending + 1] = { from = id, to = o } end
			end
		end
	end

	-- Links are applied once every pole is back, then heads and spans are settled -- both
	-- depend on the whole graph, so neither is right until it is complete.
	for _, l in pending do linkPoles(l.from, l.to) end
	for _, p in _poles do skin(p) end
	restring()
end

-- == Lifecycle =================================================================

local function canEdit(player: Player): boolean
	if Workspace:GetAttribute("RoadEditOpen") == true then return true end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

-- The road graph changed, so the streets carrying power did. RoadService fires this.
function PowerService.markRoadsDirty()
	_roadsDirty = true
end

-- Whether a service building that DRAWS power (a pump, a treatment plant) got it on the
-- last pass. False until the grid has run once, and for anything that is not a consumer.
function PowerService.isServicePowered(id: number): boolean
	return _svcPowered[id] == true
end

function PowerService.Init(net: any, buildingService: any, serviceBuildings: any, economyService: any?, cityStats: any?, roadService: any?)
	assert(net, "[PowerService] missing net")
	assert(buildingService, "[PowerService] missing buildingService")
	assert(serviceBuildings, "[PowerService] missing serviceBuildings (EmergencyService)")
	PowerService._net = net
	_buildingService  = buildingService
	_serviceBuildings = serviceBuildings
	_economyService   = economyService
	_cityStats        = cityStats
	_roadService      = roadService
	_folder = ensureFolder()

	-- Read the conductor attachment off the pole art: the top of the crossarm, spread to
	-- either side of it. Resizing the template moves the wires with it.
	local poles = ReplicatedStorage:FindFirstChild("Props")
	poles = poles and poles:FindFirstChild("PowerPoles")
	local sample = poles and poles:FindFirstChild("PowerPole_Inline")
	if sample then
		for _, d in ipairs(sample:GetDescendants()) do
			if d:IsA("BasePart") and string.find(d.Name, "Insulators") then
				-- That part spans BOTH crossarms, so its band gives both heights at once.
				-- Taking the top of it as the one height floated the wires level with the
				-- pole tip, sailing over the arms instead of sitting on them.
				local mid, h = d.Position.Y, d.Size.Y
				_wireLow    = mid - h * 0.5 + h * 0.18
				_wireHigh   = mid + h * 0.5 - h * 0.18
				_wireSpread = d.Size.X * 0.5 * 0.8
				break
			end
		end
	end

	-- Bucket the spatial hash at twice the widest supply area in play, read off the
	-- catalog so raising a generator's radius cannot silently split grids that should join.
	local widest = BUILDING_REACH
	for _, spec in ServiceTypes.all() do
		if (tonumber((spec :: any).powerOutput) or 0) > 0 then
			widest = math.max(widest, spec.coverageRadius)
		end
	end
	_bucket = widest * 2
end

function PowerService.Bind()
	local net = PowerService._net

	net.RequestPlaceService.OnServerEvent:Connect(function(player: Player, kind: any, key: any, payload: any)
		if kind ~= "PowerLine" then return end -- its own kind: this is a run, not a pivot
		if not canEdit(player) then return end
		local now = os.clock()
		if now - (_lastPlaceAt[player] or 0) < PLACE_COOLDOWN then return end
		_lastPlaceAt[player] = now
		if typeof(payload) ~= "table" then return end
		local from, to = payload.from, payload.to
		if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" then return end
		local ok, reason = PowerService.placeRun(from, to)
		if not ok and reason then
			net.Notify:FireClient(player, { text = "Can't build: " .. reason, kind = "danger", duration = 3 })
		end
	end)

	net.RequestRemoveService.OnServerEvent:Connect(function(player: Player, kind: any, id: any)
		if kind ~= "Power" then return end
		if not canEdit(player) then return end
		if typeof(id) ~= "number" then return end
		PowerService.removePole(id)
	end)

	Players.PlayerRemoving:Connect(function(p) _lastPlaceAt[p] = nil end)
end

function PowerService.Start()
	if _running then return end
	_running = true

	task.spawn(function()
		while _running do
			local speed = math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
			task.wait(TICK / math.max(1, speed))
			if speed <= 0 then continue end
			-- Rebuilt every tick, not only when a pole moves: demand follows residents and
			-- job slots, which change constantly without touching the wires.
			local ok, err = pcall(rebuild)
			if not ok then warn("[PowerService] rebuild failed: " .. tostring(err)) end
		end
	end)
end

return PowerService
