--!strict
-- SupplyService
-- The visible supply chain. Each industrial building makes stock into its own yard;
-- delivery trucks drive it to commercial buildings that have reached their order point;
-- citizens buy it off those shelves when they shop (CitizenService). Stock a plant holds
-- beyond the city's needs leaves as export -- "if commercial doesn't need it, industry
-- sells it" -- and the realised export income is handed to CityEconomyService each tick.
--
-- Trade with the outside world is carried by trucks too, through the map-edge road links
-- (OutsideConnectionService): an IMPORT truck drives in from the nearest connection to a
-- shop the city's own industry cannot stock, and an EXPORT truck loads surplus at a plant
-- and drives it out of the map; the sale is paid when it leaves. No road to the edge, no
-- trade -- shelves run dry and warehouses fill, and the player sees why.
--
-- Owns exactly one domain: per-building stock + the delivery fleet. It reads building
-- views from BuildingService and routes trucks on RoadService's nav graph (the same
-- PathFollower the citizen cars use). There is one good, STOCK: plants make it by the game
-- day, shops sell it and reorder it on their own sales forecast (order point / order-up-to).
--
-- Stock and TRUCKS are persisted (see serialize/restore). A delivery in flight is a
-- vehicle standing in traffic like any other, and dropping it on load also leaks the
-- _inbound reservation that stops a second truck being sent for the same delivery.

local RunService          = game:GetService("RunService")
local Workspace           = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local PathFollower   = require(ServerScriptService.Services.Util.PathFollower)
local VehicleFactory = require(ServerScriptService.Services.NPC.VehicleFactory)
local Const          = require(ServerScriptService.Services.City.CitySimConstants)
local NPCDriverService = require(ServerScriptService.Services.NPC.NPCDriverService)
local VehicleCatalog = require(game:GetService("ReplicatedStorage").Road.VehicleCatalog)
local VehicleTypes   = require(game:GetService("ReplicatedStorage").Road.VehicleTypes)

local SupplyService = {}

-- == Tuning (from constants) ===================================================
-- One good (STOCK_NAME), counted in units of one shopping trip. Plants make it by the
-- game DAY, shops reorder on their own sales forecast (see CitySimConstants for where the
-- numbers come from).
local DAY_SECONDS         = Const.DAY_SECONDS
local STOCK_NAME          = Const.SUPPLY_STOCK_NAME
local PRODUCE_PER_DAY     = Const.SUPPLY_PRODUCE_PER_DAY
local YARD_DAYS           = Const.SUPPLY_YARD_DAYS
local EXPORT_RESERVE_DAYS = Const.SUPPLY_EXPORT_RESERVE_DAYS
local SHOP_CAP            = Const.SUPPLY_SHOP_CAP
local SHOP_DEMAND_PRIOR   = Const.SUPPLY_SHOP_DEMAND_PRIOR
local TARGET_DAYS         = Const.SUPPLY_TARGET_DAYS
local REORDER_DAYS        = Const.SUPPLY_REORDER_DAYS
local MIN_ORDER           = Const.SUPPLY_MIN_ORDER
local DEMAND_SMOOTHING    = Const.SUPPLY_DEMAND_SMOOTHING
local TIER_CAPACITY       = Const.SUPPLY_TRUCK_TIER_CAPACITY
local TRUCK_CAPACITY      = TIER_CAPACITY[#TIER_CAPACITY] -- the biggest load anything carries
local MAX_TRUCKS          = Const.SUPPLY_MAX_TRUCKS
local MAX_TRUCKS_CEILING  = Const.SUPPLY_MAX_TRUCKS_CEILING
local TIER_LOTS           = Const.SUPPLY_TRUCK_TIER_LOTS
local TRUCK_SPEED         = Const.SUPPLY_TRUCK_SPEED
local PRODUCE_INTERVAL    = Const.SUPPLY_TICK
local DIRECT_SALE_PRICE   = Const.SUPPLY_DIRECT_SALE_PRICE
-- A shop the city's own industry cannot supply buys its stock in from outside instead --
-- the shelves stay full, the player just pays for goods they could have made at home. You
-- buy dearer than you sell, so importing is always the worse end of the same trade.
local IMPORT_PRICE        = DIRECT_SALE_PRICE * 2.5
-- The lift that puts a truck's WHEELS on the road. VehicleFactory roots every vehicle at its
-- bottom centre and publishes this as NPCHeightOffset, which is what the road AI holds it at;
-- the old 0.6 floated the truck through the yard and dropped it on hand-off.
local TRUCK_HEIGHT        = VehicleFactory.RIDE_CLEARANCE
local TRUCK_FALLBACK      = "LowPolyVan" -- used only if the catalog fleet was never built
-- Unloading is the part of a delivery you can actually watch, so it takes time and the
-- time scales with the load: the shelf fills when the last pallet is off the truck, not the
-- instant the bumper reaches the kerb.
local UNLOAD_BASE        = 2.5  -- game-seconds standing at the kerb per delivery
local UNLOAD_PER_UNIT    = 0.05 -- ...plus this per unit (a van ~4.5s, a full semi ~15.5s)

-- == Dependencies / state ======================================================
local _buildingService: any
local _roadService: any
local _citizenService: any
local _outsideConnService: any -- map-edge road links, for import / export trucks
local _folder: Folder
local _heartbeat: RBXScriptConnection?
local _running = false

local _warehouse: { [string]: number } = {}   -- industrial bpId -> units ready to ship
local _shelf: { [string]: number } = {}        -- commercial bpId -> units for sale
local _inbound: { [string]: number } = {}      -- commercial bpId -> units already en route
local _demand: { [string]: number } = {}       -- commercial bpId -> forecast units wanted per game day
local _wantedToday: { [string]: number } = {}  -- commercial bpId -> units shoppers asked for today, sold or not
local _dayAccum = 0                             -- game-seconds into the current forecasting day
local _directSaleRevenue = 0                    -- accrued export income, drained by the economy

-- cached supply-health stats for the HUD economy feed
local _statOutput = 0
local _statNeed = 0
local _statSupplyRatio = 1

local _produceAccum = 0

-- The on-road leg is driven by NPCDriverService.DriveDirected (real lane / stop-line
-- / yield / no-overlap AI). _trucks now just tracks delivery state + the post-drop
-- idle before the truck despawns.
type Truck = {
	model: Model, fromId: string, toId: string, load: number, delivered: boolean, dropTimer: number,
	-- arrived: at the shop, unloading. returning: running empty back to the depot.
	arrived: boolean, returning: boolean,
	jobSlot: boolean, -- true while this truck's driver holds an industrial job slot at fromId
	busy: boolean,    -- true while this truck still holds one of the fleet's delivery slots
	-- yard leg: garage (TruckOut) -> lot entry -> kerb, driven by stepTrucks before
	-- the road leg starts. nil once the truck is on the road (or spawned at the kerb).
	depart: { Vector3 }?, departIdx: number, startRoad: (() -> ())?,
	-- Trade with the outside world: `homePos` is the map-edge point an import truck came in
	-- by and leaves by; `export` trucks carry goods OUT and are paid when they reach it.
	homePos: Vector3?, export: boolean?,
	destPos: Vector3?, -- an export's map-edge point
}
local _trucks: { [Model]: Truck } = {}
local _truckCount = 0
-- Trucks holding a DELIVERY slot: loaded, or standing at the kerb with the load still on
-- board. A truck running home empty is scenery, not capacity. Counting the return leg made
-- every extra stud between a depot and a shop cost the fleet twice, which is most of why a
-- distant industrial district behaved as if deliveries had a range limit.
local _busyTrucks = 0
local _footprint: { [string]: number } = {}  -- industrial bpId -> lot units (width * depth)

-- == Helpers ===================================================================
local function gameSpeed(): number
	return math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
end

local function nav(): any?
	return _roadService and _roadService.getNavigationGraph()
end

local function lvl(b: any): number
	return math.clamp(b.level or 1, 1, 3)
end

-- Public: what a commercial/industrial building deals in (for per-product tax). One good.
function SupplyService.productOf(_bpId: string, _zone: string): string
	return STOCK_NAME
end

local function plantOutputPerDay(b: any): number
	return PRODUCE_PER_DAY[lvl(b)] or PRODUCE_PER_DAY[1]
end

local function plantYardCap(b: any): number
	return plantOutputPerDay(b) * YARD_DAYS
end

local function shopCap(b: any): number
	return SHOP_CAP[lvl(b)] or SHOP_CAP[1]
end

-- Units a shop expects to sell per game day: its own smoothed sales once it has some,
-- the level's prior until then.
local function shopDemand(b: any): number
	local d = _demand[b.bpId]
	if not d then
		d = SHOP_DEMAND_PRIOR[lvl(b)] or SHOP_DEMAND_PRIOR[1]
		_demand[b.bpId] = d
	end
	return d
end

-- A day has passed: fold what each shop's customers asked for into its forecast. Asked
-- for, not sold -- a shop that ran dry still had the customers, and ordering on its
-- empty-shelf sales would starve it for good.
local function rollDemand()
	for id, d in _demand do
		_demand[id] = d + ((_wantedToday[id] or 0) - d) * DEMAND_SMOOTHING
	end
	table.clear(_wantedToday)
end

-- == The delivery fleet ========================================================
-- The catalog's Truck class also holds special-purpose rigs -- a cement mixer, a tanker, a
-- tipper, a tow truck, a log hauler. Those belong to a building site or a breakdown, not to
-- a grocery restock, so they are not in the delivery fleet.
local NOT_DELIVERY = table.freeze({
	TruckMixer = true, TruckTanker = true, TruckTipper = true, TruckTow = true, TruckLogger = true,
})

-- Truck tier runs small (courier van) to large (semi rig), so grouping the fleet by tier
-- lets the LOAD choose the vehicle: six crates go in a van, a full restock in a box truck.
local _fleetByTier: { [number]: { string } } = {}
for _, key in VehicleCatalog.forClass(VehicleTypes.Truck) do
	local e = VehicleCatalog.get(key)
	if e and not NOT_DELIVERY[key] then
		local bucket = _fleetByTier[e.tier]
		if not bucket then bucket = {}; _fleetByTier[e.tier] = bucket end
		table.insert(bucket, key)
	end
end

local MAX_TIER = #TIER_LOTS + 1

-- The smallest truck the load fits in.
local function tierForLoad(load: number): number
	for tier = 1, MAX_TIER do
		if load <= (TIER_CAPACITY[tier] or TRUCK_CAPACITY) then return tier end
	end
	return MAX_TIER
end

-- ...and the CEILING comes from the depot itself. A two-lot industrial shed has a single
-- roller door and a yard a van can barely turn in, so it sends vans however big the order
-- is; the linehaul rig belongs to the plants with the footprint to match.
local function tierForFootprint(area: number?): number
	if not area or area <= 0 then return MAX_TIER end
	for i, maxLots in TIER_LOTS do
		if area <= maxLots then return i end
	end
	return MAX_TIER
end

local function pickFrom(keys: { string }?, roll: number): string?
	if not keys or #keys == 0 then return nil end
	local total = 0
	for _, k in keys do total += (VehicleCatalog.get(k) :: any).weight end
	if total <= 0 then return keys[1] end
	local target = math.clamp(roll, 0, 0.999999) * total
	local acc = 0
	for _, k in keys do
		acc += (VehicleCatalog.get(k) :: any).weight
		if target < acc then return k end
	end
	return keys[#keys]
end

-- The truck that turns up for one delivery. Size comes from the load; WHICH model of that
-- size comes from the origin building, so a given depot keeps a recognisable fleet instead
-- of re-rolling a different van every run.
local function truckKeyFor(fromId: string, load: number): string
	local h = 0
	for i = 1, #fromId do h = (h * 31 + string.byte(fromId, i)) % 2147483647 end
	local roll = VehicleCatalog.roll(h, 91)
	local tier = math.min(tierForLoad(load), tierForFootprint(_footprint[fromId]))
	-- Smaller first, larger only if nothing smaller exists: a depot that warrants a van must
	-- never be handed a rig just because its own tier bucket happened to be empty.
	for t = tier, 1, -1 do
		local k = pickFrom(_fleetByTier[t], roll)
		if k then return k end
	end
	for t = tier + 1, MAX_TIER do
		local k = pickFrom(_fleetByTier[t], roll)
		if k then return k end
	end
	return TRUCK_FALLBACK
end

-- The most one run from this plant can carry: the biggest truck its yard can turn.
local function depotLoadCap(fromId: string): number
	return TIER_CAPACITY[tierForFootprint(_footprint[fromId])] or TRUCK_CAPACITY
end

local function unloadSeconds(load: number): number
	return UNLOAD_BASE + UNLOAD_PER_UNIT * math.max(0, load)
end

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Trucks")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "Trucks"; f.Parent = city
	end
	return f :: Folder
end

-- == Public: stock access (CitizenService shopping) ============================
function SupplyService.getShelfStock(bpId: string): number
	return _shelf[bpId] or 0
end

-- Buy up to `want` units off a shop's shelf. Returns the amount actually sold
-- (0 if the shelf is empty -- the supply-chain penalty for an understocked shop).
-- Every request counts toward the shop's sales forecast, served or not.
function SupplyService.consumeStock(bpId: string, want: number): number
	if want <= 0 then return 0 end
	_wantedToday[bpId] = (_wantedToday[bpId] or 0) + want
	local have = _shelf[bpId] or 0
	if have <= 0 then return 0 end
	local sold = math.min(math.floor(have), want)
	_shelf[bpId] = have - sold
	return sold
end

-- == Public: economy feed ======================================================
-- Realised export income since the last call (reset on read).
function SupplyService.drainGoodsRevenue(): number
	local r = _directSaleRevenue
	_directSaleRevenue = 0
	return r
end

function SupplyService.getStats(): { [string]: number }
	return { output = _statOutput, need = _statNeed, supplyRatio = _statSupplyRatio, trucks = _truckCount }
end

-- == Trucks ====================================================================
-- Free the industrial job slot this truck's driver held (exactly once).
local function releaseTruckSlot(t: Truck)
	if t.jobSlot then
		t.jobSlot = false
		if _citizenService and _citizenService.releaseDriverJob then
			_citizenService.releaseDriverJob(t.fromId)
		end
	end
end

-- A truck stops holding a delivery slot the moment its load is off. Exactly once.
local function releaseDeliverySlot(t: Truck)
	if t.busy then
		t.busy = false
		_busyTrucks -= 1
	end
end

local function destroyTruck(truck: Model)
	local t = _trucks[truck]
	if t then releaseTruckSlot(t); releaseDeliverySlot(t); _trucks[truck] = nil; _truckCount -= 1 end
	NPCDriverService.ReleaseDirected(truck)
	PathFollower.forget(truck)
	if truck.Parent then truck:Destroy() end
end

-- Move `load` goods onto the destination shelf on arrival (once). An export's
-- "destination" is the map edge: the goods are sold as they leave the city.
local function deliver(t: Truck)
	if t.delivered then return end
	t.delivered = true
	if t.export then
		_directSaleRevenue += t.load * DIRECT_SALE_PRICE
		return
	end
	_shelf[t.toId] = (_shelf[t.toId] or 0) + t.load
	_inbound[t.toId] = math.max(0, (_inbound[t.toId] or 0) - t.load)
end

-- Reached the shop: stand at the kerb and unload. The goods land on the shelf when the
-- timer runs out (see stepTrucks), so a delivery is something the player can watch happen.
local function beginUnload(t: Truck)
	if t.arrived then return end
	t.arrived = true
	t.dropTimer = unloadSeconds(t.load)
end

-- The home leg. A delivery is a ROUND trip: the van that used to blink out of existence at
-- the shop kerb now drives back to the depot it loaded at and despawns there, so the player
-- watches a fleet in circulation instead of trucks appearing and vanishing at kerbs. Any
-- failure to route home just despawns it -- an empty truck owes the city nothing.
local function startReturn(t: Truck)
	if t.returning then return end
	t.returning = true
	releaseDeliverySlot(t) -- empty from here: it drives home on its own time, not the fleet's
	local truck = t.model
	local home = t.homePos or _buildingService.getKerb(t.fromId)
	local g = nav()
	if not (home and g and g:HasEdges() and truck.Parent) then destroyTruck(truck) return end
	-- The outbound trip has finished, so clear its driver state before booking the next one.
	NPCDriverService.ReleaseDirected(truck)
	local here = truck:GetPivot().Position
	local ok, path, edgeIds = pcall(function() return g:FindPath(here, home, true, VehicleTypes.Truck) end)
	if not ok or typeof(path) ~= "table" or #path == 0
		or typeof(edgeIds) ~= "table" or #(edgeIds :: any) == 0 then
		destroyTruck(truck)
		return
	end
	local function gone() destroyTruck(truck) end
	if not NPCDriverService.DriveDirected(truck, here, home, edgeIds :: { string }, gone, gone) then
		destroyTruck(truck)
	end
end

-- Dispatch one truck carrying `load` goods from industrial `fromId` to commercial
-- `toId`. The load leaves the warehouse now (reserved via _inbound) and lands on
-- the shelf on arrival. The ROAD leg runs on NPCDriverService's real traffic AI.
-- Returns true if a truck launched.
local function dispatch(fromId: string, toId: string, load: number): boolean
	if _truckCount >= MAX_TRUCKS_CEILING then return false end
	local g = nav()
	if not g or not g:HasEdges() then return false end
	local fromKerb = _buildingService.getKerb(fromId)
	local toKerb = _buildingService.getKerb(toId)
	if not fromKerb or not toKerb then return false end
	-- Routed AS A TRUCK, matching the tag VehicleFactory puts on it: a lane a truck may not
	-- use (a busway) must be excluded when the route is planned, not discovered by the driver.
	local ok, path, edgeIds = pcall(function() return g:FindPath(fromKerb, toKerb, nil, VehicleTypes.Truck) end)
	if not ok or not path or #path == 0 then return false end

	local truck = VehicleFactory.build("DeliveryTruck", nil, truckKeyFor(fromId, load))
	-- Spawn at the baked garage door (TruckOut marker) when the template has one and
	-- drive the yard leg out to the kerb before entering traffic; otherwise spawn at
	-- the kerb as before.
	local out: CFrame? = if _buildingService.getTruckOut then _buildingService.getTruckOut(fromId) else nil
	local leg: { Vector3 } = {}
	if out then
		truck:PivotTo(CFrame.new(out.Position + Vector3.new(0, TRUCK_HEIGHT, 0)) * out.Rotation)
		-- side garages bake a mid-corridor waypoint so the truck follows the lane
		local mid = if _buildingService.getTruckMid then _buildingService.getTruckMid(fromId) else nil
		if mid then table.insert(leg, mid) end
		local spots = _buildingService.getParkSpots(fromId)
		if spots and spots.lotEntry then table.insert(leg, spots.lotEntry) end
		table.insert(leg, fromKerb)
	else
		truck:PivotTo(CFrame.new(fromKerb + Vector3.new(0, TRUCK_HEIGHT, 0)))
	end
	-- Pull out ONTO the lane under the truck's own power rather than being reseated there by
	-- the road leg. This covers the depot with a garage AND the one without: a truck that
	-- simply spawned at the kerb used to jump onto the lane on its first driven frame.
	local firstEdge = if typeof(edgeIds) == "table" and #(edgeIds :: any) > 0 then (edgeIds :: { string })[1] else nil
	local laneEntry = if firstEdge then NPCDriverService.LaneEntryPath(firstEdge, fromKerb) else nil
	if laneEntry then for _, p in laneEntry do table.insert(leg, p) end end
	-- A depot with no garage marker spawns its truck standing on the kerb with no facing of
	-- its own, and the yard mover would spin it to face the lane on its first driven frame.
	-- Point it where it is about to go instead, so it is never seen turning on the spot.
	if not out and #leg > 0 then
		local p = truck:GetPivot().Position
		local aim = Vector3.new(leg[1].X, p.Y, leg[1].Z)
		if (aim - p).Magnitude > 0.1 then truck:PivotTo(CFrame.lookAt(p, aim)) end
	end
	local roadStart = if #leg > 0 then leg[#leg] else fromKerb
	local depart: { Vector3 }? = if #leg > 0 then leg else nil
	truck.Parent = _folder

	_warehouse[fromId] = math.max(0, (_warehouse[fromId] or 0) - load)
	_inbound[toId] = (_inbound[toId] or 0) + load
	_truckCount += 1
	_busyTrucks += 1
	-- The driver is on the clock: claim one of the origin industrial building's job slots
	-- for the duration of the run (CitizenService owns occupancy + the labour pool).
	local jobSlot = false
	if _citizenService and _citizenService.reserveDriverJob then
		_citizenService.reserveDriverJob(fromId)
		jobSlot = true
	end
	local t: Truck = { model = truck, fromId = fromId, toId = toId, load = load, delivered = false,
		dropTimer = 0, arrived = false, returning = false, jobSlot = jobSlot, busy = true, depart = depart, departIdx = 1 }
	_trucks[truck] = t

	local function arriveAndDrop() beginUnload(t) end
	local function startRoad()
		local started = false
		if typeof(edgeIds) == "table" and #(edgeIds :: any) > 0 then
			started = NPCDriverService.DriveDirected(truck, roadStart, toKerb, edgeIds :: { string }, arriveAndDrop, arriveAndDrop)
		end
		if not started then arriveAndDrop() end -- no lane route: drop at the kerb
	end
	if depart then
		t.startRoad = startRoad -- stepTrucks drives the yard leg, then hands off
	else
		startRoad()
	end
	return true
end

-- Trucks DRIVE on NPCDriverService.DriveDirected; this only ages out a delivered
-- truck (idle at the kerb, then despawn) and reconciles reserved inbound stock if
-- a truck is destroyed before it delivers.
local function stepTrucks(dt: number)
	for truck, t in _trucks do
		if not truck.Parent then
			if not t.delivered and not t.export then _inbound[t.toId] = math.max(0, (_inbound[t.toId] or 0) - t.load) end
			releaseTruckSlot(t)
			releaseDeliverySlot(t)
			_trucks[truck] = nil; _truckCount -= 1; PathFollower.forget(truck); continue
		end
		if t.depart then
			-- yard leg: constant-speed crawl garage -> gate -> kerb, then enter traffic
			local wp = t.depart[t.departIdx]
			local pos = truck:GetPivot().Position
			local target = Vector3.new(wp.X, wp.Y + TRUCK_HEIGHT, wp.Z)
			local delta = target - pos
			local step = TRUCK_SPEED * 0.5 * dt
			if delta.Magnitude <= step then
				truck:PivotTo(truck:GetPivot() - pos + target)
				t.departIdx += 1
				if t.departIdx > #t.depart then
					t.depart = nil
					local start = t.startRoad
					t.startRoad = nil
					if start then start() end
				end
			else
				local dir = delta.Unit
				local nxt = pos + dir * step
				local flat = Vector3.new(dir.X, 0, dir.Z)
				if flat.Magnitude > 0.01 then
					truck:PivotTo(CFrame.lookAt(nxt, nxt + flat))
				else
					truck:PivotTo(truck:GetPivot() - pos + nxt)
				end
			end
			continue
		end
		if t.arrived and not t.returning then
			t.dropTimer -= dt
			if t.dropTimer <= 0 then
				deliver(t)      -- the shelf fills when the last crate is off, not on arrival
				startReturn(t)  -- then the truck runs home empty instead of blinking out
			end
		end
	end
end

-- == Trade with the outside world ============================================
-- Where trade trucks meet the map edge: a lane point a little inside the connection,
-- on the inbound side (coming in) or the outbound side (going out).
local TRADE_EDGE_OFFSET = 24

local function edgePoint(g: any, conn: any, inbound: boolean): Vector3?
	local aim = if inbound then conn.outer - conn.normal * 200 else conn.outer + conn.normal * 200
	local res = g:NearestEdgeToward(conn.outer, aim)
	if not (res and res.edge and res.edge.points and #res.edge.points >= 2) then return nil end
	local pts = res.edge.points
	local acc = 0
	if inbound then
		for i = 2, #pts do
			acc += (pts[i] - pts[i - 1]).Magnitude
			if acc >= TRADE_EDGE_OFFSET then return pts[i] end
		end
		return pts[#pts]
	end
	for i = #pts - 1, 1, -1 do
		acc += (pts[i + 1] - pts[i]).Magnitude
		if acc >= TRADE_EDGE_OFFSET then return pts[i] end
	end
	return pts[1]
end

-- The connection nearest `pos` that traffic can use in the wanted direction.
local function nearestConnection(pos: Vector3, inbound: boolean): any?
	if not _outsideConnService then return nil end
	local best, bestD = nil, math.huge
	for _, c in _outsideConnService.list() do
		if (inbound and c.dir == "out") or (not inbound and c.dir == "in") then continue end
		local dx, dz = c.outer.X - pos.X, c.outer.Z - pos.Z
		local d = dx * dx + dz * dz
		if d < bestD then bestD = d; best = c end
	end
	return best
end

-- One trade truck on the road: from `src` to `dst`, then `arrived`. False if nothing drives.
local function launchTrade(t: Truck, src: Vector3, dst: Vector3, arrived: () -> ()): boolean
	local g = nav()
	if not g then return false end
	local ok, path, edgeIds = pcall(function() return g:FindPath(src, dst, true, VehicleTypes.Truck) end)
	if not ok or typeof(path) ~= "table" or #path == 0 or typeof(edgeIds) ~= "table" or #(edgeIds :: any) == 0 then
		return false
	end
	t.model:PivotTo(CFrame.new(src + Vector3.new(0, TRUCK_HEIGHT, 0)))
	t.model.Parent = _folder
	_trucks[t.model] = t
	_truckCount += 1
	_busyTrucks += 1
	if not NPCDriverService.DriveDirected(t.model, src, dst, edgeIds :: { string }, arrived, arrived) then
		arrived()
	end
	return true
end

-- A shop no local plant can stock orders from outside: the goods drive in from the nearest
-- connection, billed dearer than they would sell for. False when there is no way in.
local function dispatchImport(toId: string, load: number): boolean
	if _truckCount >= MAX_TRUCKS_CEILING then return false end
	local g = nav()
	local toKerb = _buildingService.getKerb(toId)
	local conn = toKerb and nearestConnection(toKerb, true)
	if not g or not conn then return false end
	local src = edgePoint(g, conn, true)
	local home = edgePoint(g, conn, false) or src
	if not src then return false end
	local truck = VehicleFactory.build("ImportTruck", nil, truckKeyFor("import:" .. tostring(conn.id), load))
	local t: Truck = { model = truck, fromId = "", toId = toId, load = load, delivered = false,
		dropTimer = 0, arrived = false, returning = false, jobSlot = false, busy = true, depart = nil,
		departIdx = 1, homePos = home }
	if not launchTrade(t, src, toKerb, function() beginUnload(t) end) then
		truck:Destroy()
		return false
	end
	_inbound[toId] = (_inbound[toId] or 0) + load
	_directSaleRevenue -= load * IMPORT_PRICE
	return true
end

-- Surplus nobody in the city wants leaves by road and is paid for at the edge. The
-- driver is on the plant's books for the run, like any delivery driver.
local function dispatchExport(fromId: string, load: number): boolean
	if _truckCount >= MAX_TRUCKS_CEILING then return false end
	local g = nav()
	local fromKerb = _buildingService.getKerb(fromId)
	local conn = fromKerb and nearestConnection(fromKerb, false)
	if not g or not conn then return false end
	local dst = edgePoint(g, conn, false)
	if not dst then return false end
	local truck = VehicleFactory.build("ExportTruck", nil, truckKeyFor(fromId, load))
	local t: Truck = { model = truck, fromId = fromId, toId = "", load = load, delivered = false,
		dropTimer = 0, arrived = false, returning = false, jobSlot = false, busy = true, depart = nil,
		departIdx = 1, export = true, destPos = dst }
	if not launchTrade(t, fromKerb, dst, function() deliver(t); destroyTruck(truck) end) then
		truck:Destroy()
		return false
	end
	_warehouse[fromId] = math.max(0, (_warehouse[fromId] or 0) - load)
	if _citizenService and _citizenService.reserveDriverJob then
		_citizenService.reserveDriverJob(fromId)
		t.jobSlot = true
	end
	return true
end

-- Put a saved trade truck, or an empty one heading home, back on the road (see serialize).
local function resumeTrade(kind: string, fromId: string, toId: string, load: number, at: CFrame,
	anchor: { edgeId: string, dist: number }?, point: Vector3)
	local g = nav()
	if not g or not g:HasEdges() then return end
	local dst = if kind == "i" then _buildingService.getKerb(toId) else point
	if not dst then return end
	local src = at.Position
	local anchorEdge = if anchor then g:GetEdge(anchor.edgeId) else nil
	if anchorEdge and anchorEdge.points and #anchorEdge.points > 0 then
		src = (PathFollower.pointAtDist(anchorEdge.points, PathFollower.getCum(anchorEdge), anchor.dist))
	end
	local name = if kind == "e" then "ExportTruck" elseif kind == "i" then "ImportTruck" else "DeliveryTruck"
	local truck = VehicleFactory.build(name, nil, truckKeyFor(if fromId ~= "" then fromId else "import:" .. toId, load))
	local t: Truck = { model = truck, fromId = fromId, toId = toId, load = load, delivered = kind == "x",
		dropTimer = 0, arrived = false, returning = kind == "x", jobSlot = false, busy = true, depart = nil,
		departIdx = 1, homePos = if kind == "i" then point else nil, export = kind == "e",
		destPos = if kind == "e" then point else nil }
	local arrived = if kind == "i" then function() beginUnload(t) end
		elseif kind == "e" then function() deliver(t); destroyTruck(truck) end
		else function() destroyTruck(truck) end
	if not launchTrade(t, src, dst, arrived) then
		truck:Destroy()
		return
	end
	if kind == "x" then releaseDeliverySlot(t) end -- empty: holds no delivery slot
	if kind == "i" then _inbound[toId] = (_inbound[toId] or 0) + load end
	if kind == "e" and fromId ~= "" and _citizenService and _citizenService.reserveDriverJob then
		_citizenService.reserveDriverJob(fromId)
		t.jobSlot = true
	end
end

-- == Persistence ==============================================================
-- The fleet and the stock. A saved truck is {pose, from, to, load}: the load has ALREADY
-- left its warehouse (dispatch deducted it), so restore re-establishes the inbound
-- reservation and re-drives the run rather than deducting anything a second time. Stock
-- (v2) is saved because it is days of production and sales, not something a few ticks
-- rebuild: dropping it emptied every shop at once and sent a truck to each on load.
--
-- Buildings are referenced by saveKey, not bpId -- bpIds regenerate on load, saveKeys are
-- the stable cross-save handle (the same one CitizenService links homes and jobs by).
local SAVE_VERSION = 2

-- 2 decimals, the precision CitizenService and ThroughTrafficService already save a
-- vehicle pose at.
local function r2(n: number): number
	return math.floor(n * 100 + 0.5) / 100
end

-- Each restored truck runs an A*; budget them across frames like every other restore.
local RESTORE_FRAME_BUDGET = 0.008

-- Drop the whole fleet and every goods figure derived from it.
--
-- Nothing else sweeps Workspace._City.Trucks on a city load -- unlike the Citizens folder,
-- which CitizenService.restore clears -- so without this the outgoing city's trucks keep
-- driving on roads that no longer exist, and their _inbound reservations sit on bpIds the
-- new city has reissued, permanently blocking those shops from being restocked.
function SupplyService.clear()
	for truck, t in _trucks do
		releaseTruckSlot(t)
		releaseDeliverySlot(t)
		NPCDriverService.ReleaseDirected(truck)
		PathFollower.forget(truck)
		if truck.Parent then truck:Destroy() end
	end
	_trucks = {}
	_truckCount = 0
	_busyTrucks = 0
	table.clear(_footprint)
	if _folder then
		for _, m in _folder:GetChildren() do
			if m:IsA("Model") then
				NPCDriverService.ReleaseDirected(m)
				PathFollower.forget(m)
				m:Destroy()
			end
		end
	end
	table.clear(_warehouse)
	table.clear(_shelf)
	table.clear(_inbound)
	table.clear(_demand)
	table.clear(_wantedToday)
	_dayAccum = 0
	_directSaleRevenue = 0
	_produceAccum = 0
	_statOutput, _statNeed, _statSupplyRatio = 0, 0, 1
end

-- Put a saved delivery back on the road. Mirrors dispatch minus the parts that already
-- happened before the save: the goods are out of the warehouse and the shelf has not had
-- them yet, so only the inbound reservation and the driver's job slot are re-taken.
local function resumeTruck(fromId: string, toId: string, load: number, at: CFrame, anchor: { edgeId: string, dist: number }?): boolean
	local g = nav()
	if not g or not g:HasEdges() then return false end
	local toKerb = _buildingService.getKerb(toId)
	if not toKerb then return false end
	local anchorEdge = if anchor then g:GetEdge(anchor.edgeId) else nil

	local function routeFrom(p: Vector3)
		local ok, path, edgeIds = pcall(function() return g:FindPath(p, toKerb, nil, VehicleTypes.Truck) end)
		if not ok or typeof(path) ~= "table" or #path == 0 then return nil end
		if typeof(edgeIds) ~= "table" or #(edgeIds :: any) == 0 then return nil end
		return edgeIds :: { string }
	end

	local src = at.Position
	local edgeIds: { string }? = nil
	local startDist: number? = nil

	if anchor and anchorEdge and anchorEdge.points and #anchorEdge.points > 0 then
		-- A truck sitting in traffic is already on a known lane, and re-snapping a world
		-- position would not reliably find it again: NearestEdge measures to lane VERTICES,
		-- which sit up to 56 studs apart, so a point mid-chord on this lane can read as
		-- nearer to the lane alongside (or the opposing one, where distance-along runs
		-- backwards). Plan the REMAINDER instead -- finish this lane, then route on from its
		-- end -- and put the lane it is on back at the front of the route.
		local pts = anchorEdge.points
		src = PathFollower.pointAtDist(pts, PathFollower.getCum(anchorEdge), anchor.dist)
		at = CFrame.new(src + Vector3.new(0, TRUCK_HEIGHT, 0)) * (at - at.Position)
		local tail = routeFrom(pts[#pts])
		if tail then
			if tail[1] == anchor.edgeId then
				edgeIds = tail
			else
				for _, o in anchorEdge.out or {} do
					if o == tail[1] then
						local joined = table.clone(tail)
						table.insert(joined, 1, anchor.edgeId)
						edgeIds = joined
						break
					end
				end
			end
			if edgeIds then startDist = anchor.dist end
		end
	end

	if not edgeIds then
		edgeIds = routeFrom(src)
	end
	if not edgeIds then
		-- Saved mid-yard (the garage leg is off the lane graph), or the lane it was on has
		-- been edited away. Fall back to the origin kerb, which is where the yard leg was
		-- driving to anyway.
		local fromKerb = _buildingService.getKerb(fromId)
		if not fromKerb then return false end
		src = fromKerb
		at = CFrame.new(fromKerb + Vector3.new(0, TRUCK_HEIGHT, 0))
		startDist = nil -- moved off the saved lane, so the saved distance no longer applies
		edgeIds = routeFrom(src)
		if not edgeIds then return false end
	end

	local truck = VehicleFactory.build("DeliveryTruck", nil, truckKeyFor(fromId, load))
	truck:PivotTo(at)
	truck.Parent = _folder

	_inbound[toId] = (_inbound[toId] or 0) + load
	_truckCount += 1
	_busyTrucks += 1
	local jobSlot = false
	if _citizenService and _citizenService.reserveDriverJob then
		_citizenService.reserveDriverJob(fromId)
		jobSlot = true
	end
	local t: Truck = { model = truck, fromId = fromId, toId = toId, load = load, delivered = false,
		dropTimer = 0, arrived = false, returning = false, jobSlot = jobSlot, busy = true, depart = nil, departIdx = 1 }
	_trucks[truck] = t

	local function arriveAndDrop() beginUnload(t) end
	if not NPCDriverService.DriveDirected(truck, src, toKerb, edgeIds, arriveAndDrop, arriveAndDrop, startDist) then
		arriveAndDrop()
	end
	return true
end

function SupplyService.serialize(): { [string]: any }?
	if not _buildingService then return nil end
	local keys: { string } = {}
	local keyIndex: { [string]: number } = {}
	local function intern(key: string?): number?
		if not key then return nil end
		local existing = keyIndex[key]
		if existing then return existing end
		local idx = #keys + 1
		keys[idx] = key
		keyIndex[key] = idx
		return idx
	end

	local keyById: { [string]: string } = {}
	for _, b in _buildingService.listBuildings() do
		if typeof(b.saveKey) == "string" and b.saveKey ~= "" then keyById[b.bpId] = b.saveKey end
	end

	local rows: { any } = {}
	for truck, t in _trucks do
		-- Every truck on the road comes back: deliveries in flight, empties running home, and
		-- trade trucks (row[10] kind: "i" import to a shop, "e" export to the edge, "x"
		-- heading out/home empty; row[11..13] the edge or home point it is driving to). A
		-- delivered truck still unloading at the kerb is past the point worth carrying.
		local kind = if t.export then "e" elseif t.returning then "x" elseif t.homePos then "i" else nil
		local point = if kind == "e" then t.destPos
			elseif kind == "x" then (t.homePos or _buildingService.getKerb(t.fromId))
			elseif kind == "i" then t.homePos else nil
		local fromIdx = intern(keyById[t.fromId])
		local toIdx = intern(keyById[t.toId])
		local keep = if kind == nil then (not t.delivered and fromIdx ~= nil and toIdx ~= nil)
			elseif kind == "i" then (not t.delivered and toIdx ~= nil and point ~= nil)
			else point ~= nil
		if truck.Parent and keep then
			do
				local cf = truck:GetPivot()
				local pos = cf.Position
				local look = cf.LookVector
				local yaw = math.deg(math.atan2(-look.X, -look.Z))
				local row = { r2(pos.X), r2(pos.Y), r2(pos.Z), r2(yaw), fromIdx, toIdx, t.load }
				-- The exact lane anchor, so a truck queued in traffic comes back in the queue
				-- and not projected onto the nearest lane vertex. Absent while it is still on
				-- the off-graph yard leg, which restores from the origin kerb instead.
				local anchor = NPCDriverService.GetLaneAnchor(truck)
				if anchor then
					local eIdx = intern(anchor.edgeId)
					row[8] = eIdx
					row[9] = r2(anchor.dist)
				end
				if kind and point then
					row[5], row[6] = fromIdx or 0, toIdx or 0
					row[10], row[11], row[12], row[13] = kind, r2(point.X), r2(point.Y), r2(point.Z)
				end
				table.insert(rows, row)
			end
		end
	end
	-- Stock rows: {building key, units on hand, units/day forecast (shops only)}.
	local stock: { any } = {}
	for id, units in _warehouse do
		local k = intern(keyById[id])
		if k and units >= 0.5 then table.insert(stock, { k, r2(units) }) end
	end
	for id, daily in _demand do
		local k = intern(keyById[id])
		if k then table.insert(stock, { k, r2(_shelf[id] or 0), r2(daily) }) end
	end
	if #rows == 0 and #stock == 0 then return nil end
	return { version = SAVE_VERSION, keys = keys, trucks = rows, stock = stock }
end

-- Put saved stock back, clamped to what each building can hold now (it may have been
-- re-levelled or re-zoned). Untrusted: anything not a finite non-negative number is dropped.
local function restoreStock(rows: any, keys: { any }, bySaveKey: { [string]: any })
	if typeof(rows) ~= "table" then return end
	for _, row in rows do
		if typeof(row) ~= "table" or typeof(row[1]) ~= "number" then continue end
		local key = keys[row[1]]
		local b = if typeof(key) == "string" then bySaveKey[key] else nil
		local units = tonumber(row[2])
		if not b or not units or units ~= units or units < 0 or units == math.huge then continue end
		if b.zone == "Industrial" then
			_warehouse[b.bpId] = math.min(units, plantYardCap(b))
		elseif b.zone == "Commercial" then
			_shelf[b.bpId] = math.min(units, shopCap(b))
			local daily = tonumber(row[3])
			if daily and daily == daily and daily > 0 and daily < math.huge then
				_demand[b.bpId] = daily
			end
		end
	end
end

-- CitySerializer calls this after buildings and plots are back (the kerbs and saveKeys
-- below need them) and BEFORE citizens, so the job slots these drivers hold are already
-- taken when CitizenService assigns the rest of the workforce.
function SupplyService.restore(blob: any)
	SupplyService.clear()
	if typeof(blob) ~= "table" then return end
	-- v1 saved only the fleet; its loads are in the old goods units, close enough to resume.
	local version = tonumber(blob.version)
	if version ~= 1 and version ~= SAVE_VERSION then return end
	local keys = if typeof(blob.keys) == "table" then blob.keys else {}

	local bySaveKey: { [string]: any } = {}
	for _, b in _buildingService.listBuildings() do
		if typeof(b.saveKey) == "string" and b.saveKey ~= "" then bySaveKey[b.saveKey] = b end
		-- Truck size is keyed off the depot's footprint, so it has to be known before the
		-- saved runs are rebuilt or a reloaded delivery comes back in a different vehicle.
		_footprint[b.bpId] = b.footprint
	end
	-- Stock first: the trucks below add their loads to the shops' inbound on top of it.
	restoreStock(blob.stock, keys, bySaveKey)

	if typeof(blob.trucks) ~= "table" then return end
	local g = nav()
	if not g or not g:HasEdges() then return end

	local frameStart = os.clock()
	for _, row in blob.trucks do
		if _truckCount >= MAX_TRUCKS_CEILING then break end
		if os.clock() - frameStart > RESTORE_FRAME_BUDGET then
			task.wait()
			frameStart = os.clock()
		end
		if typeof(row) == "table" then
			local x, y, z = tonumber(row[1]), tonumber(row[2]), tonumber(row[3])
			local yaw, load = tonumber(row[4]), tonumber(row[7])
			local fromKey = if typeof(row[5]) == "number" then keys[row[5]] else nil
			local toKey = if typeof(row[6]) == "number" then keys[row[6]] else nil
			local fromView = if typeof(fromKey) == "string" then bySaveKey[fromKey] else nil
			local toView = if typeof(toKey) == "string" then bySaveKey[toKey] else nil
			-- The blob is untrusted: NaN or an off-map pose would leave the driver AI
			-- re-anchoring the truck forever. Either end demolished between saves means the
			-- run has nowhere to come from or go to, so it is simply not resumed -- the goods
			-- were already out of the warehouse, so nothing has to be handed back.
			local kind = if typeof(row[10]) == "string" then row[10] else nil
			local px, py, pz = tonumber(row[11]), tonumber(row[12]), tonumber(row[13])
			local poseOk = x and y and z and yaw and load
				and x == x and y == y and z == z and yaw == yaw and load == load and load > 0
			if kind and poseOk and px and py and pz and px == px and py == py and pz == pz then
				local edgeKey = if typeof(row[8]) == "number" then keys[row[8]] else nil
				local edgeDist = tonumber(row[9])
				local anchor = if typeof(edgeKey) == "string" and edgeDist and edgeDist == edgeDist
					then { edgeId = edgeKey, dist = edgeDist } else nil
				resumeTrade(kind, if fromView then fromView.bpId else "", if toView then toView.bpId else "",
					math.min(load, TRUCK_CAPACITY), CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yaw), 0),
					anchor, Vector3.new(px, py, pz))
				continue
			end
			local sane = poseOk and fromView and toView
			if sane then
				local edgeKey = if typeof(row[8]) == "number" then keys[row[8]] else nil
				local edgeDist = tonumber(row[9])
				local anchor: { edgeId: string, dist: number }? = nil
				if typeof(edgeKey) == "string" and edgeDist and edgeDist == edgeDist and edgeDist >= 0 then
					anchor = { edgeId = edgeKey, dist = edgeDist }
				end
				resumeTruck(fromView.bpId, toView.bpId, math.min(load, TRUCK_CAPACITY),
					CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yaw), 0), anchor)
			end
		end
	end
end

-- == Production + dispatch ====================================================
-- Which depot sends the truck: the NEAREST one holding at least `atLeast` units, not a
-- random one. Range is not banned here -- a lone industrial park on the far side of the
-- map still supplies the whole city -- it just stops a shop with a plant across the road
-- pulling from one twenty blocks away and paying the fleet for the whole round trip.
-- Falls back to any such depot when a view has no pivot to measure from.
local function nearestSupplier(suppliers: { any }, need: any, atLeast: number): any?
	local to = need.position
	local best: any, fallback: any = nil, nil
	local bestDistSq = math.huge
	for _, cand in suppliers do
		if (_warehouse[cand.bpId] or 0) < atLeast then continue end
		if not fallback then fallback = cand end
		local from = cand.position
		if not (to and from) then continue end
		local dx, dz = from.X - to.X, from.Z - to.Z
		local d = dx * dx + dz * dz
		if d < bestDistSq then
			bestDistSq = d
			best = cand
		end
	end
	return best or fallback
end

-- One pass: plants make `dt` game-seconds of output, shops at their order point order,
-- plants with surplus export it.
local function produceAndDispatch(dt: number)
	local views = _buildingService.listBuildings()

	-- prune stock for buildings that no longer exist
	local alive: { [string]: boolean } = {}
	for _, b in views do alive[b.bpId] = true end
	for id in _warehouse do if not alive[id] then _warehouse[id] = nil end end
	for id in _shelf do if not alive[id] then _shelf[id] = nil end end
	for id in _inbound do if not alive[id] then _inbound[id] = nil end end
	for id in _footprint do if not alive[id] then _footprint[id] = nil end end
	for id in _demand do if not alive[id] then _demand[id] = nil end end
	for id in _wantedToday do if not alive[id] then _wantedToday[id] = nil end end

	local dayShare = dt / DAY_SECONDS
	local suppliers: { any } = {}   -- industrial with stock
	local orders: { { shop: any, qty: number } } = {} -- commercial at its order point
	local totalOutput, totalDemand, totalShelf, totalTarget = 0, 0, 0, 0

	for _, b in views do
		if b.abandoned then continue end
		if b.zone == "Industrial" then
			_footprint[b.bpId] = b.footprint
			local cap = plantYardCap(b)
			-- A dark plant makes nothing. Its yard keeps whatever was already in it and still
			-- ships, so the line only goes quiet once the shelves it stocked run out -- and then
			-- the shops it fed start importing instead. A full yard stops the line too.
			local perDay = if b.powered == false then 0 else plantOutputPerDay(b)
			totalOutput += perDay
			_warehouse[b.bpId] = math.min(cap, (_warehouse[b.bpId] or 0) + perDay * dayShare)
			if (_warehouse[b.bpId] or 0) >= 1 then table.insert(suppliers, b) end
			_buildingService.setSupplyInfo(b.bpId, STOCK_NAME, _warehouse[b.bpId], cap)
		elseif b.zone == "Commercial" then
			-- Order point / order-up-to: when what is on the shelf plus what is already on its
			-- way falls to REORDER_DAYS of sales, order back up to TARGET_DAYS (never past what
			-- the shop can hold, never less than a pallet).
			local cap = shopCap(b)
			local daily = shopDemand(b)
			local target = math.min(cap, TARGET_DAYS * daily)
			local onShelf = _shelf[b.bpId] or 0
			local position = onShelf + (_inbound[b.bpId] or 0)
			totalDemand += daily
			totalShelf += math.min(onShelf, target)
			totalTarget += target
			_buildingService.setSupplyInfo(b.bpId, STOCK_NAME, onShelf, cap)
			if position <= REORDER_DAYS * daily then
				local qty = math.min(math.ceil(math.max(MIN_ORDER, target - position)), math.floor(cap - position))
				if qty > 0 then table.insert(orders, { shop = b, qty = qty }) end
			end
		end
	end

	_statOutput = totalOutput
	_statNeed = totalDemand
	_statSupplyRatio = if totalTarget > 0 then math.clamp(totalShelf / totalTarget, 0, 1) else 1

	-- Fill orders: one truck per shop per pass. The cap tracks how many shops are actually
	-- waiting rather than sitting at a flat 20, because a flat 20 IS the range limit: every
	-- slot a far depot's round trip held was a slot no other shop could be restocked from.
	local fleetCap = math.clamp(#orders, MAX_TRUCKS, MAX_TRUCKS_CEILING)
	for _, order in orders do
		local shop = order.shop
		-- No spare truck is a QUEUE, not a shortage -- the stock exists, it is just waiting
		-- for a lorry, so the shop waits for the next pass rather than importing.
		if _busyTrucks >= fleetCap then break end
		-- The nearest plant that can fill the whole order; failing that the nearest with a
		-- pallet or more, sending what it has.
		local pick = nearestSupplier(suppliers, shop, order.qty) or nearestSupplier(suppliers, shop, MIN_ORDER)
		if pick then
			local load = math.min(order.qty, math.floor(_warehouse[pick.bpId] or 0), depotLoadCap(pick.bpId))
			dispatch(pick.bpId, shop.bpId, load)
		else
			-- No plant in the city has it: the shop imports, by truck from the nearest outside
			-- connection. This is what an industrial blackout costs: the shops keep trading,
			-- on someone else's factory, at import prices.
			dispatchImport(shop.bpId, math.min(order.qty, TRUCK_CAPACITY))
		end
	end

	-- Export: a plant ships what it holds beyond a few days' reserve for the city's shops,
	-- one FULL truck at a time -- nobody runs a lorry to the border half empty. A full yard
	-- ships regardless. With no road to the edge the yard fills and the plant stops.
	for _, b in views do
		if b.abandoned or b.zone ~= "Industrial" then continue end
		if _busyTrucks >= fleetCap then break end
		local have = _warehouse[b.bpId] or 0
		local truckLoad = depotLoadCap(b.bpId)
		local surplus = have - EXPORT_RESERVE_DAYS * plantOutputPerDay(b)
		if surplus >= truckLoad or (have >= plantYardCap(b) and have >= truckLoad) then
			dispatchExport(b.bpId, truckLoad)
		end
	end
end

-- == Lifecycle =================================================================
function SupplyService.Init(buildingService: any, roadService: any)
	assert(buildingService and roadService, "[SupplyService] requires BuildingService + RoadService")
	_buildingService = buildingService
	_roadService = roadService
	_folder = ensureFolder()
end

-- CitizenService owns city occupancy + the labour pool. Injected after both services
-- exist (see Bootstrap event-linking) so each active delivery truck occupies one
-- industrial job slot. Optional: trucks still run if it is never set.
function SupplyService.SetCitizenService(citizenService: any)
	_citizenService = citizenService
end

function SupplyService.SetOutsideConnService(svc: any)
	_outsideConnService = svc
end

function SupplyService.Bind() end

function SupplyService.Start()
	if _running then return end
	_running = true
	_heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		local sdt = math.min(dt, 0.1) * gameSpeed()
		if sdt <= 0 then return end
		local ok, err = pcall(stepTrucks, sdt)
		if not ok then warn("[SupplyService] truck step failed: " .. tostring(err)) end
		_dayAccum += sdt
		if _dayAccum >= DAY_SECONDS then
			_dayAccum -= DAY_SECONDS
			rollDemand()
		end
		_produceAccum += sdt
		if _produceAccum >= PRODUCE_INTERVAL then
			local passDt = _produceAccum
			_produceAccum = 0
			local ok2, err2 = pcall(produceAndDispatch, passDt)
			if not ok2 then warn("[SupplyService] produce/dispatch failed: " .. tostring(err2)) end
		end
	end)
end

return SupplyService
