--!strict
-- EmergencyDispatch
-- One domain: emergency vehicles that are out on a call. A civic service asks for
-- a vehicle to be sent from a station to a scene; this drives it there on the road
-- network, calls back on arrival, and cleans it up afterwards.
--
-- It exists so Crime / Fire / Sickness / Deathcare do not each carry their own copy
-- of the same spawn-drive-despawn loop. Those services decide WHEN and WHY a vehicle
-- goes out; this only knows HOW to get it there.
--
-- A trip with no drivable route still calls onArrive after FALLBACK_DELAY: the city
-- sim must not stall because two buildings happen to be unconnected.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PathFollower = require(ServerScriptService.Services.Util.PathFollower)
local EmergencyVehicleFactory = require(ServerScriptService.Services.NPC.EmergencyVehicleFactory)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local VehicleTypes = require(ReplicatedStorage.Road.VehicleTypes)

local EmergencyDispatch = {}

-- == Tuning ====================================================================
-- Same blocks-per-second at any world scale. Emergency vehicles out-run traffic.
local RESPONSE_SPEED = 34 * RoadConstants.WORLD_SCALE
local RIDE_HEIGHT = 0.6
local FALLBACK_DELAY = 2.5   -- seconds before an unroutable call resolves anyway
local PARK_TIMEOUT = 120     -- seconds a parked vehicle waits before giving up on release

-- == State =====================================================================
local _roadService: any
local _rng = Random.new()

export type Trip = {
	kind: string,
	model: Model?,
	conn: RBXScriptConnection?,
	parked: boolean,
	done: boolean,
	onArrive: (() -> ())?,
	parkedAt: number?,
}

type SendOptions = {
	kind: string,          -- EmergencyVehicleFactory kind: Police / Fire / Ambulance / Hearse
	from: Vector3,         -- station position
	to: Vector3,           -- scene position
	park: boolean?,        -- stay at the scene until release() instead of leaving on arrival
	maxActive: number?,    -- refuse the call if this many of the kind are already out
	onArrive: (() -> ())?,
}

local _trips: { [Trip]: true } = {}
local _activeByKind: { [string]: number } = {}

local function cityFolder(): Instance
	return Workspace:FindFirstChild("_City") or Workspace
end

local function gameSpeed(): number
	return math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
end

local function navGraph(): any
	if not _roadService then return nil end
	local ok, nav = pcall(_roadService.getNavigationGraph)
	if not ok or not nav then return nil end
	local hasEdges, result = pcall(function() return nav:HasEdges() end)
	return if hasEdges and result then nav else nil
end

-- Tear a trip down exactly once, from any path (arrival, release, cancel, clear).
local function retire(trip: Trip)
	if trip.done then return end
	trip.done = true
	if trip.conn then
		trip.conn:Disconnect()
		trip.conn = nil
	end
	local model = trip.model
	if model then
		trip.model = nil
		-- Siren parts carry CollectionService tags; Destroy drops them with the model.
		if model.Parent then model:Destroy() end
	end
	if _trips[trip] then
		_trips[trip] = nil
		_activeByKind[trip.kind] = math.max(0, (_activeByKind[trip.kind] or 1) - 1)
	end
end

-- Arrival: fire the caller's callback, then either park or leave. The callback runs
-- inside a pcall -- a civic service erroring on arrival must not strand the vehicle.
local function arrive(trip: Trip)
	if trip.done then return end
	if trip.conn then
		trip.conn:Disconnect()
		trip.conn = nil
	end
	local cb = trip.onArrive
	trip.onArrive = nil
	if cb then
		local ok, err = pcall(cb)
		if not ok then warn("[EmergencyDispatch] onArrive failed: " .. tostring(err)) end
	end
	if trip.parked then
		trip.parkedAt = os.clock()
		-- A caller that never releases (its incident vanished some other way) must not
		-- leak the vehicle -- give up after PARK_TIMEOUT.
		task.delay(PARK_TIMEOUT, function()
			if not trip.done then retire(trip) end
		end)
	else
		retire(trip)
	end
end

-- == Public ====================================================================
-- Send one vehicle. Returns the trip (so the caller can release/cancel it), or nil
-- if the call was refused -- over the cap, unknown kind, or the model failed to build.
function EmergencyDispatch.send(opts: SendOptions): Trip?
	local kind = opts.kind
	local cap = opts.maxActive
	if cap and (_activeByKind[kind] or 0) >= cap then return nil end

	local model = EmergencyVehicleFactory.build(kind, _rng:NextInteger(1, 99))
	if not model then return nil end

	model:PivotTo(CFrame.new(opts.from + Vector3.new(0, RIDE_HEIGHT, 0)))
	model.Parent = cityFolder()

	local trip: Trip = {
		kind = kind, model = model, conn = nil,
		parked = opts.park == true, done = false, onArrive = opts.onArrive,
	}
	_trips[trip] = true
	_activeByKind[kind] = (_activeByKind[kind] or 0) + 1

	local nav = navGraph()
	local path: { Vector3 }? = nil
	if nav then
		local ok, found = pcall(function() return nav:FindPath(opts.from, opts.to, nil, VehicleTypes.Emergency) end)
		if ok and found and #found > 1 then path = found end
	end

	if not path then
		-- No route (no roads yet, or the scene is off-network). The call still resolves;
		-- the vehicle just never visibly drives.
		task.delay(FALLBACK_DELAY, function() arrive(trip) end)
		return trip
	end

	local road = path :: { Vector3 }
	local state = {
		model = model, heightOffset = RIDE_HEIGHT,
		smoothCFrame = nil, lastSentCFrame = nil, replicateAccum = 0,
		path = road, cum = PathFollower.cumOf(road), dist = 0, speed = RESPONSE_SPEED,
	}
	local total = state.cum[#state.cum]

	trip.conn = RunService.Heartbeat:Connect(function(dt: number)
		if trip.done then return end
		if not model.Parent then retire(trip); return end
		local speed = gameSpeed()
		if speed <= 0 then return end
		state.dist = math.min(total, state.dist + state.speed * dt * speed)
		local pos, dir = PathFollower.pointAtDist(state.path, state.cum, state.dist)
		PathFollower.place(state, pos, dir, dt * speed)
		if state.dist >= total - 1e-3 then
			arrive(trip)
		end
	end)

	return trip
end

-- Release a parked vehicle: the job at the scene is finished, it can go.
function EmergencyDispatch.release(trip: Trip?)
	if trip then retire(trip) end
end

-- Abandon a trip before it arrives (incident resolved some other way). No callback.
function EmergencyDispatch.cancel(trip: Trip?)
	if not trip then return end
	trip.onArrive = nil
	retire(trip)
end

function EmergencyDispatch.activeCount(kind: string): number
	return _activeByKind[kind] or 0
end

-- Nearest station of a coverage domain, by its CollectionService tag. Emergency
-- vehicles roll out of the building that actually covers the scene, not from nowhere.
function EmergencyDispatch.nearestStation(pos: Vector3, tag: string): Vector3?
	local best: Vector3? = nil
	local bestDist = math.huge
	for _, inst in CollectionService:GetTagged(tag) do
		if not (inst:IsA("Model") or inst:IsA("BasePart")) then continue end
		local ok, p = pcall(function() return inst:GetPivot().Position end)
		if not ok then continue end
		local dx, dz = p.X - pos.X, p.Z - pos.Z
		local d = dx * dx + dz * dz
		if d < bestDist then bestDist = d; best = p end
	end
	return best
end

-- City unload: every vehicle out on a call goes with it.
function EmergencyDispatch.clear()
	for trip in _trips do retire(trip) end
	table.clear(_trips)
	table.clear(_activeByKind)
end

-- == Lifecycle =================================================================
function EmergencyDispatch.Init(roadService: any)
	assert(roadService, "[EmergencyDispatch] missing roadService")
	_roadService = roadService
end

function EmergencyDispatch.Bind() end

function EmergencyDispatch.Start()
	EmergencyVehicleFactory.startSirens()
end

return EmergencyDispatch
