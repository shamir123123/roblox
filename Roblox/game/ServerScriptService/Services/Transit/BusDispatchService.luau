--!strict
-- BusDispatchService
-- The visible bus fleet, modelled as depot-owned pools. Every Bus Depot keeps its full
-- fleet PARKED on its apron (one bus per Park attachment) the moment it is placed. When a
-- route is runnable, idle buses roll OUT of the nearest depot and drive it as a continuous
-- loop -- stop to stop on the real traffic AI (NPCDriverService.DriveDirected), pausing to
-- "board" -- and when the route closes, shrinks or is deleted they drive BACK and re-park.
-- A bus is destroyed only when its home depot is removed (or no depot can take it back).
--
-- It owns exactly the runtime fleet: bus models + their per-bus state. Ridership itself is
-- abstract -- CitizenService decides who rides and tells TransitService; this service just
-- makes the buses visible and moving. Reads routes / stops / depots from TransitService.

local RunService          = game:GetService("RunService")
local Workspace           = game:GetService("Workspace")
local CollectionService   = game:GetService("CollectionService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local VehicleFactory   = require(ServerScriptService.Services.NPC.VehicleFactory)
local NPCDriverService = require(ServerScriptService.Services.NPC.NPCDriverService)
local PathFollower     = require(ServerScriptService.Services.Util.PathFollower)
local TransitTypes     = require(ReplicatedStorage.Transit.TransitTypes)
local VehicleTypes     = require(ReplicatedStorage.Road.VehicleTypes)

local BusDispatchService = {}

local RECONCILE_INTERVAL = 1.5 -- seconds between reconciles (also staggers spawns + dispatch)
local SPAWN_PER_PASS = 4       -- parked buses created per depot per reconcile (staggers the fill)
local BUS_LIFT = 0.6           -- ride lift while pathing; the driver corrects ride height

-- A bus is always owned by a home depot. It is either PARKED in one of the depot's Park
-- slots, rolling OUT to a route (toRoute), looping a route (onRoute) or heading BACK to
-- re-park (toDepot). It is destroyed only when its home depot is removed.
type Bus = {
	model: Model,
	homeDepotId: number,
	state: string,        -- "parked" | "toRoute" | "onRoute" | "toDepot"
	slotIndex: number?,   -- occupied Park slot while parked
	routeId: number?,     -- the route it serves (toRoute / onRoute)
	legIndex: number,
	phase: string,        -- onRoute sub-state: "driving" | "dwelling"
	dwellTimer: number,
	retire: boolean,      -- return to the depot at the next stop
	capacity: number,     -- seats: 30 standard, 70 articulated
}

local _transit: any
local _roadService: any
local _folder: Folder
local _buses: { [Model]: Bus } = {}
local _busSeq = 0
local _reconcileAccum = 0
local _running = false
-- Buses from a save, waiting for their route to finish re-pathing after the load (see
-- restore / adoptSaved). Dropped if their line never comes back.
local _pending: { any } = {}
local _pendingUntil = 0
local PENDING_GRACE = 30

local function gameSpeed(): number
	return math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
end

local function nav(): any?
	return _roadService and _roadService.getNavigationGraph()
end

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Buses")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "Buses"; f.Parent = city
	end
	return f :: Folder
end

local function destroyBus(model: Model)
	_transit.vehicleOutOfService(model, model:GetPivot().Position)
	_buses[model] = nil
	NPCDriverService.ReleaseDirected(model)
	PathFollower.forget(model)
	if model.Parent then model:Destroy() end
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- The Park attachments baked onto a depot model, in slot order.
local function parkSlots(model: Model): { Attachment }
	local out: { Attachment } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Attachment") and string.match(d.Name, "^Park%d+$") then
			out[#out + 1] = d :: Attachment
		end
	end
	table.sort(out, function(a, b)
		return (tonumber(string.match(a.Name, "%d+")) or 0) < (tonumber(string.match(b.Name, "%d+")) or 0)
	end)
	return out
end

local function depotById(id: number): any?
	for _, d in _transit.getDepots() do
		if d.id == id then return d end
	end
	return nil
end

local function depotCapacity(depot: any): number
	local spec = TransitTypes.getDepot(depot.key)
	return if spec then spec.busCapacity else TransitTypes.BUSES_PER_DEPOT
end

-- First Park slot of a depot not already held by one of its parked buses.
local function freeSlot(depotId: number, model: Model): (number?, Attachment?)
	local atts = parkSlots(model)
	local occupied: { [number]: boolean } = {}
	for _, b in _buses do
		if b.homeDepotId == depotId and b.state == "parked" and b.slotIndex then
			occupied[b.slotIndex] = true
		end
	end
	for i = 1, #atts do
		if not occupied[i] then return i, atts[i] end
	end
	return nil, nil
end

-- forward declares (callbacks reference each other)
local driveLeg: (Bus) -> ()
local arrive: (Bus) -> ()

-- Seat a bus idle in a free slot of `depot`. False if the depot is full / gone.
local function parkBus(bus: Bus, depot: any): boolean
	local idx, att = freeSlot(depot.id, depot.model)
	if not idx or not att then return false end
	NPCDriverService.ReleaseDirected(bus.model)
	PathFollower.forget(bus.model)
	bus.homeDepotId = depot.id
	bus.state = "parked"
	bus.slotIndex = idx
	bus.routeId = nil
	bus.retire = false
	if bus.model.PrimaryPart then bus.model.PrimaryPart.Anchored = true end
	bus.model:PivotTo(att.WorldCFrame)
	return true
end

-- Send a bus back to re-park: its home depot if it still has a slot, else the nearest
-- depot that does. Destroyed only if no depot can take it.
local function returnToDepot(bus: Bus)
	bus.state = "toDepot"
	bus.routeId = nil
	local pos = bus.model:GetPivot().Position
	_transit.vehicleOutOfService(bus.model, pos)
	local depot = depotById(bus.homeDepotId)
	if not (depot and (freeSlot(depot.id, depot.model))) then
		local best, bestD = nil, math.huge
		for _, d in _transit.getDepots() do
			if (freeSlot(d.id, d.model)) then
				local dist = flatDist(d.entrance, pos)
				if dist < bestD then bestD = dist; best = d end
			end
		end
		depot = best
	end
	if not depot then destroyBus(bus.model); return end
	local target = depot
	local g = nav()
	local function finish()
		local d = depotById(target.id)
		if not (d and parkBus(bus, d)) then destroyBus(bus.model) end
	end
	local ok, _, edges = pcall(function() return g and g:FindPath(pos, target.entrance, nil, VehicleTypes.Bus) end)
	local started = false
	if g and ok and typeof(edges) == "table" and #edges > 0 then
		started = NPCDriverService.DriveDirected(bus.model, pos, target.entrance, edges, finish, finish)
	end
	if not started then finish() end
end

function arrive(bus: Bus)
	local route = bus.routeId and _transit.getRoute(bus.routeId)
	if not route or #route.stops < 2 then returnToDepot(bus); return end
	if bus.retire then returnToDepot(bus); return end
	bus.legIndex = (bus.legIndex % #route.stops) + 1
	bus.phase = "dwelling"
	local moved = _transit.vehicleAtStop(bus.model, route.id, route.stops[bus.legIndex], bus.capacity)
	bus.dwellTimer = TransitTypes.STOP_DWELL + moved * TransitTypes.BOARD_SECONDS
end

local function onAbort(bus: Bus)
	-- Leg blocked / road changed under the bus: advance to the next stop so it never stalls.
	if bus.model.Parent then arrive(bus) else destroyBus(bus.model) end
end

function driveLeg(bus: Bus)
	local route = bus.routeId and _transit.getRoute(bus.routeId)
	if not route or #route.stops < 2 then returnToDepot(bus); return end
	local n = #route.stops
	local i = bus.legIndex
	local fromStop = _transit.getStop(route.stops[i])
	local toStop = _transit.getStop(route.stops[(i % n) + 1])
	if not fromStop or not toStop then returnToDepot(bus); return end
	local edges = route.legEdges[i]
	bus.phase = "driving"
	local started = false
	if typeof(edges) == "table" and #edges > 0 then
		started = NPCDriverService.DriveDirected(bus.model, fromStop.roadPos, toStop.roadPos, edges,
			function() arrive(bus) end, function() onAbort(bus) end)
	end
	if not started then
		-- No drivable leg: hop to the next stop so the loop keeps progressing.
		bus.model:PivotTo(CFrame.new(toStop.roadPos + Vector3.new(0, BUS_LIFT, 0)))
		arrive(bus)
	end
end

-- Roll a parked bus out of its depot to serve `routeId`, entering at stop `startIndex`.
local function dispatchBus(bus: Bus, routeId: number, startIndex: number): boolean
	local route = _transit.getRoute(routeId)
	if not route or #route.stops < 2 then return false end
	local g = nav()
	if not g then return false end
	local n = #route.stops
	startIndex = ((startIndex - 1) % n) + 1
	local startStop = _transit.getStop(route.stops[startIndex])
	if not startStop then return false end

	bus.state = "toRoute"
	bus.slotIndex = nil
	bus.routeId = routeId
	bus.retire = false
	bus.legIndex = startIndex
	local pos = bus.model:GetPivot().Position
	local function reachedFirst()
		bus.state = "onRoute"
		bus.legIndex = startIndex
		bus.phase = "dwelling"
		local moved = _transit.vehicleAtStop(bus.model, routeId, route.stops[startIndex], bus.capacity)
		bus.dwellTimer = TransitTypes.STOP_DWELL + moved * TransitTypes.BOARD_SECONDS
	end
	local ok, _, edges = pcall(function() return g:FindPath(pos, startStop.roadPos, nil, VehicleTypes.Bus) end)
	local started = false
	if ok and typeof(edges) == "table" and #edges > 0 then
		started = NPCDriverService.DriveDirected(bus.model, pos, startStop.roadPos, edges, reachedFirst, function() onAbort(bus) end)
	end
	if not started then
		bus.model:PivotTo(CFrame.new(startStop.roadPos + Vector3.new(0, BUS_LIFT, 0)))
		reachedFirst()
	end
	return true
end

-- Create one parked bus in a free slot of `depot`.
local function spawnParked(depot: any): boolean
	local idx, att = freeSlot(depot.id, depot.model)
	if not idx or not att then return false end
	_busSeq += 1
	-- the mesh-kit city bus; the old hand-made "Bus" template sits in the pre-mesh backup
	local articulated = idx % TransitTypes.ARTICULATED_EVERY == 0
	local spec = if articulated then TransitTypes.BusArticulated else TransitTypes.Bus
	local model = VehicleFactory.build("Bus_" .. tostring(_busSeq), nil, if articulated then "BusArticulated" else "BusCityRigid")
	CollectionService:AddTag(model, VehicleTypes.Tag.Bus)
	model:SetAttribute("Capacity", spec.capacity)
	model.Parent = _folder
	local bus: Bus = {
		model = model, homeDepotId = depot.id, state = "parked", slotIndex = idx,
		routeId = nil, legIndex = 1, phase = "dwelling", dwellTimer = 0, retire = false,
		capacity = spec.capacity,
	}
	_buses[model] = bus
	model:PivotTo(att.WorldCFrame)
	return true
end

-- The parked bus nearest `pos` (idle and available to dispatch), of the size the line
-- wants if one is free: articulated for a busy line, standard otherwise.
local function nearestParkedBus(pos: Vector3, wantBig: boolean): Bus?
	local best, bestD = nil, math.huge
	for _, b in _buses do
		if b.state == "parked" then
			local d = flatDist(b.model:GetPivot().Position, pos)
			if (b.capacity > TransitTypes.Bus.capacity) ~= wantBig then d += 1e6 end
			if d < bestD then bestD = d; best = b end
		end
	end
	return best
end

-- A saved bus back on the street where it was: dwelling at its stop, mid-leg, rolling out to
-- its route or back to the depot. Needs its route's legs re-pathed first; false = not yet.
local function adoptSaved(row: any): boolean
	local depot = depotById(row.d)
	if not depot then return true end -- its depot is gone: nothing to come back to
	local route = if row.r then _transit.getRoute(row.r) else nil
	if row.s ~= "toDepot" and not (route and #route.stops >= 2 and #route.legEdges > 0) then
		return false
	end
	local g = nav()
	local edge = if g and row.e then g:GetEdge(row.e) else nil
	local pos: Vector3? = nil
	if edge and edge.points and #edge.points > 0 then
		pos = (PathFollower.pointAtDist(edge.points, PathFollower.getCum(edge), tonumber(row.x) or 0))
	elseif route then
		local stop = _transit.getStop(route.stops[math.clamp(tonumber(row.l) or 1, 1, #route.stops)])
		pos = if stop then stop.roadPos else nil
	end
	if not pos then return true end

	_busSeq += 1
	local spec = if row.big then TransitTypes.BusArticulated else TransitTypes.Bus
	local model = VehicleFactory.build("Bus_" .. tostring(_busSeq), nil, if row.big then "BusArticulated" else "BusCityRigid")
	CollectionService:AddTag(model, VehicleTypes.Tag.Bus)
	model:SetAttribute("Capacity", spec.capacity)
	model:PivotTo(CFrame.new(pos + Vector3.new(0, BUS_LIFT, 0)))
	model.Parent = _folder
	local bus: Bus = {
		model = model, homeDepotId = depot.id, state = row.s, slotIndex = nil,
		routeId = row.r, legIndex = math.max(1, math.floor(tonumber(row.l) or 1)),
		phase = if row.p == "dwelling" then "dwelling" else "driving",
		dwellTimer = tonumber(row.w) or TransitTypes.STOP_DWELL, retire = false, capacity = spec.capacity,
	}
	_buses[model] = bus
	if row.s == "toDepot" or not route then
		returnToDepot(bus)
	elseif row.s == "toRoute" then
		dispatchBus(bus, route.id, bus.legIndex)
	elseif bus.phase == "driving" then
		-- Finish the leg it was on: from here to the leg's end stop.
		local n = #route.stops
		local toStop = _transit.getStop(route.stops[(bus.legIndex % n) + 1])
		local ok, _, edges = pcall(function() return g and g:FindPath(pos, toStop.roadPos, nil, VehicleTypes.Bus) end)
		local started = ok and typeof(edges) == "table" and #edges > 0
			and NPCDriverService.DriveDirected(model, pos, toStop.roadPos, edges, function() arrive(bus) end, function() onAbort(bus) end)
		if not started then arrive(bus) end
	end
	return true
end

-- Keep every depot stocked with its parked fleet, and keep each runnable route supplied with
-- buses drawn from the nearest depot. One spawn + one dispatch step per pass staggers the work
-- and spreads buses around each loop instead of bunching them at the depot.
local function reconcile()
	-- prune destroyed buses
	for model in _buses do if not model.Parent then _buses[model] = nil end end

	-- Saved buses first, so the depot restock below counts them as out on the road.
	for i = #_pending, 1, -1 do
		if adoptSaved(_pending[i]) then table.remove(_pending, i) end
	end
	if #_pending > 0 and os.clock() > _pendingUntil then table.clear(_pending) end

	local depots = _transit.getDepots()
	local present: { [number]: boolean } = {}
	for _, d in depots do present[d.id] = true end

	-- Buses whose home depot is gone: parked ones vanish with it; en-route ones finish their
	-- leg and retire to whatever depot remains (or are destroyed if none do).
	for model, bus in _buses do
		if not present[bus.homeDepotId] then
			if bus.state == "parked" then
				destroyBus(model)
			else
				bus.retire = true
				local alt = depots[1]
				if alt then bus.homeDepotId = alt.id end
			end
		end
	end

	-- Stock each depot up to its capacity (parked + the buses it has out on routes).
	for _, d in depots do
		local owned = 0
		for _, b in _buses do if b.homeDepotId == d.id then owned += 1 end end
		local toSpawn = math.min(depotCapacity(d) - owned, SPAWN_PER_PASS)
		for _ = 1, toSpawn do
			if not spawnParked(d) then break end
		end
	end

	-- Match each route's live bus count to its assignment.
	for _, routeId in _transit.getRouteIds() do
		local route = _transit.getRoute(routeId)
		if not route then continue end
		local runnable = route.enabled and route.closed == true and #route.stops >= 2 and #route.legEdges > 0
		local desired = if runnable then route.busCount else 0
		local have = 0
		for _, b in _buses do
			if b.routeId == routeId and not b.retire and (b.state == "toRoute" or b.state == "onRoute") then
				have += 1
			end
		end
		if have < desired then
			local startStop = _transit.getStop(route.stops[1])
			local bus = if startStop then nearestParkedBus(startStop.roadPos, route.usage >= TransitTypes.BUSY_LINE_USAGE) else nil
			if bus then
				local spacing = math.max(1, math.floor(#route.stops / math.max(1, desired)))
				dispatchBus(bus, routeId, have * spacing + 1)
				have += 1
			end
		elseif have > desired then
			for _, b in _buses do
				if b.routeId == routeId and not b.retire and (b.state == "toRoute" or b.state == "onRoute") then
					b.retire = true; have -= 1; break
				end
			end
		end
		_transit.setRouteActiveBuses(routeId, have)
	end

	-- Buses whose route vanished out from under them: retire to the depot.
	for _, bus in _buses do
		if (bus.state == "toRoute" or bus.state == "onRoute") and not bus.retire then
			if not bus.routeId or not _transit.getRoute(bus.routeId) then bus.retire = true end
		end
	end
end

local function step(dt: number)
	local speed = gameSpeed()
	for model, bus in _buses do
		if not model.Parent then _buses[model] = nil; continue end
		if bus.state == "onRoute" and bus.phase == "dwelling" then
			bus.dwellTimer -= dt * speed
			if speed > 0 and bus.dwellTimer <= 0 then driveLeg(bus) end
		end
	end
	_reconcileAccum += dt
	if _reconcileAccum >= RECONCILE_INTERVAL then
		_reconcileAccum = 0
		pcall(reconcile)
	end
end

-- == Public ====================================================================
-- Despawn the whole fleet (city unload / reload). TransitService.restore rebuilds routes;
-- buses respawn on the next reconcile.
function BusDispatchService.clear()
	for model in _buses do destroyBus(model) end
	table.clear(_buses)
	table.clear(_pending)
end

-- Every bus out on the streets, for the city save; parked ones are simply re-stocked.
function BusDispatchService.serialize(): { any }?
	local rows = {}
	for model, bus in _buses do
		if bus.state == "parked" or not model.Parent then continue end
		local anchor = NPCDriverService.GetLaneAnchor(model)
		table.insert(rows, {
			d = bus.homeDepotId, r = bus.routeId, s = bus.state, l = bus.legIndex, p = bus.phase,
			w = math.floor(bus.dwellTimer * 100 + 0.5) / 100,
			big = if bus.capacity > TransitTypes.Bus.capacity then true else nil,
			e = if anchor then anchor.edgeId else nil,
			x = if anchor then math.floor(anchor.dist * 100 + 0.5) / 100 else nil,
		})
	end
	return if #rows > 0 then rows else nil
end

-- Saved buses come back once TransitService has restored their routes (reconcile adopts
-- them as each route's legs finish re-pathing).
function BusDispatchService.restore(rows: any)
	table.clear(_pending)
	if typeof(rows) ~= "table" then return end
	for _, row in rows do
		local state = if typeof(row) == "table" then row.s else nil
		if (state == "onRoute" or state == "toRoute" or state == "toDepot") and typeof(row.d) == "number" then
			table.insert(_pending, row)
		end
	end
	_pendingUntil = os.clock() + PENDING_GRACE
end

-- == Lifecycle =================================================================
function BusDispatchService.Init(transitService: any, roadService: any)
	assert(transitService and roadService, "[BusDispatchService] requires TransitService + RoadService")
	_transit = transitService
	_roadService = roadService
	_folder = ensureFolder()
end

function BusDispatchService.Bind() end

function BusDispatchService.Start()
	if _running then return end
	_running = true
	RunService.Heartbeat:Connect(function(dt: number)
		local sdt = math.min(dt, 0.1)
		local ok, err = pcall(step, sdt)
		if not ok then warn("[BusDispatchService] step failed: " .. tostring(err)) end
	end)
end

return BusDispatchService
