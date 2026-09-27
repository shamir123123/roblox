--!strict
-- FireService
-- The city fire sim. Buildings occasionally catch fire. A fire within a Fire Station's
-- coverage gets an ENGINE sent to it, and only burns down once the crew is on scene;
-- an UNCOVERED fire grows, destroys the building, and spreads to neighbouring buildings
-- -- so a city with no fire cover can burn block by block.
--
-- Coverage alone does not put a fire out: the engine has to physically arrive. A fire
-- station on the far side of an unconnected road network is a station that cannot help.
--
-- One domain: active fires. It does NOT own buildings (BuildingService) or coverage
-- (EmergencyService) -- it asks them. Burning buildings carry the replicated "OnFire" tag
-- + "FireIntensity" attribute; the client FireView turns those into flames. Fires are
-- transient and never persisted.

local CollectionService = game:GetService("CollectionService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FireService = {}

-- == Tuning ====================================================================
local FIRE_TICK         = 4.0   -- game-seconds between fire passes (GameSpeed-scaled)
-- Random ignition was OFF (0 / 0) for a while: at the old rates (0.04 / 0.0006) spontaneous
-- fires levelled whole neighbourhoods, because nothing actually put them out. Now that a
-- covered fire gets an engine, ignition is back on at roughly a sixth of the old rate --
-- enough that fire stations matter, low enough that one unlucky tick is not a catastrophe.
local IGNITE_BASE       = 0.006 -- per-tick chance a new fire starts somewhere
local IGNITE_PER_BLDG   = 0.0001-- + this per standing building
local IGNITE_MAX        = 0.05  -- cap on the per-tick ignition chance
local START_INTENSITY   = 0.6
local GROW_PER_TICK     = 1.0   -- fire with no crew on scene grows this much per tick
local DECAY_PER_TICK    = 1.6   -- fire with an engine on scene shrinks this much per tick
local DESTROY_AT        = 3.0   -- intensity at which the building burns down + spreads
local SPREAD_RADIUS     = 76    -- studs: neighbours this close catch fire when one burns down
local TOAST_COOLDOWN    = 6     -- min real seconds between fire toasts
local MAX_ENGINES       = 4     -- concurrent engines out at base funding

local _buildingService: any
local _emergencyService: any
local _economyService: any
local _dispatch: any
local _net: any
local _running = false
local _rng = Random.new()
local _lastToastAt = 0

-- trip: the engine sent to this fire (nil = none en route). onScene: it has arrived,
-- so the fire is being fought rather than just watched from a station on the map.
type Fire = { intensity: number, pos: Vector3, trip: any, onScene: boolean }
local _fires: { [string]: Fire } = {}

-- Fire funding buys a bigger fleet, the same way it widens coverage radius.
local function maxEngines(): number
	local mult = if _economyService and _economyService.getFunding then _economyService.getFunding("Fire") else 1
	return math.max(1, math.floor(MAX_ENGINES * mult + 0.5))
end

local function notify(text: string, kind: string)
	local now = os.clock()
	if now - _lastToastAt < TOAST_COOLDOWN then return end
	_lastToastAt = now
	if _net then _net.Notify:FireAllClients({ text = text, kind = kind }) end
end

local function tagModel(bpId: string, intensity: number)
	local model = _buildingService.getModel and _buildingService.getModel(bpId)
	if not model then return end
	model:SetAttribute("FireIntensity", intensity)
	if not CollectionService:HasTag(model, "OnFire") then
		CollectionService:AddTag(model, "OnFire")
	end
end

local function untagModel(bpId: string)
	local model = _buildingService.getModel and _buildingService.getModel(bpId)
	if not model then return end
	CollectionService:RemoveTag(model, "OnFire")
	model:SetAttribute("FireIntensity", nil)
end

-- == Public ====================================================================
-- Start a fire at a specific building (no-op if it does not exist or already burns).
function FireService.ignite(bpId: string): boolean
	if _fires[bpId] then return false end
	if not _buildingService then return false end
	local pos = _buildingService.getBuildingPosition and _buildingService.getBuildingPosition(bpId)
	if typeof(pos) ~= "Vector3" then return false end
	_fires[bpId] = { intensity = START_INTENSITY, pos = pos, trip = nil, onScene = false }
	tagModel(bpId, START_INTENSITY)
	return true
end

-- Send an engine from the nearest station. It PARKS at the fire (park = true) and
-- stays until the fire is out or the building is gone -- an engine that drove off the
-- moment it arrived would leave nothing fighting the fire.
local function dispatchEngine(bpId: string, fire: Fire)
	if not _dispatch or fire.trip then return end
	local stationPos = _dispatch.nearestStation(fire.pos, "FireStation")
	if not stationPos then return end
	fire.trip = _dispatch.send({
		kind = "Fire",
		from = stationPos,
		to = fire.pos,
		park = true,
		maxActive = maxEngines(),
		onArrive = function()
			local live = _fires[bpId]
			if live then live.onScene = true end
		end,
	})
end

-- Release whatever engine this fire is holding (put out, burned down, or cleared).
local function recallEngine(fire: Fire)
	if fire.trip and _dispatch then _dispatch.release(fire.trip) end
	fire.trip = nil
	fire.onScene = false
end

-- Pick a random standing, non-abandoned, non-burning building and set it alight.
function FireService.igniteRandom(): boolean
	if not _buildingService or not _buildingService.listBuildings then return false end
	local candidates: { string } = {}
	for _, view in _buildingService.listBuildings() do
		if view.abandoned then continue end
		if _fires[view.bpId] then continue end
		table.insert(candidates, view.bpId)
	end
	if #candidates == 0 then return false end
	return FireService.ignite(candidates[_rng:NextInteger(1, #candidates)])
end

function FireService.getActiveFireCount(): number
	local n = 0
	for _ in _fires do n += 1 end
	return n
end

-- Drop all active fires (city unload / reload). Fires are never persisted.
function FireService.clear()
	for bpId, fire in _fires do
		untagModel(bpId)
		recallEngine(fire)
	end
	_fires = {}
end

-- == Sim =======================================================================
local function spreadFrom(origin: Vector3)
	for _, view in _buildingService.listBuildings() do
		if view.abandoned or _fires[view.bpId] then continue end
		local pos = _buildingService.getBuildingPosition(view.bpId)
		if typeof(pos) ~= "Vector3" then continue end
		local dx, dz = pos.X - origin.X, pos.Z - origin.Z
		if dx * dx + dz * dz <= SPREAD_RADIUS * SPREAD_RADIUS then
			_fires[view.bpId] = { intensity = START_INTENSITY, pos = pos, trip = nil, onScene = false }
			tagModel(view.bpId, START_INTENSITY)
		end
	end
end

local function tick()
	if not _buildingService or not _emergencyService then return end

	local spreadOrigins: { Vector3 } = {}
	local doomed: { string } = {}

	for bpId, fire in _fires do
		local pos = _buildingService.getBuildingPosition(bpId)
		if typeof(pos) ~= "Vector3" then
			-- building already gone (bulldozed / burned): drop the fire
			recallEngine(fire)
			_fires[bpId] = nil
			continue
		end
		fire.pos = pos

		-- Covered fires get an engine on the way. Until it arrives the fire still grows:
		-- response TIME is the thing coverage buys you, not immunity.
		if _emergencyService.coversAt(pos, "Fire") and not fire.trip then
			dispatchEngine(bpId, fire)
		end

		if fire.onScene then
			fire.intensity -= DECAY_PER_TICK
			if fire.intensity <= 0 then
				untagModel(bpId)
				recallEngine(fire)
				_fires[bpId] = nil
			else
				tagModel(bpId, fire.intensity)
			end
		else
			fire.intensity += GROW_PER_TICK
			if fire.intensity >= DESTROY_AT then
				table.insert(doomed, bpId)
				table.insert(spreadOrigins, pos)
			else
				tagModel(bpId, fire.intensity)
			end
		end
	end

	-- Burn down the doomed buildings, then spread from where each stood. Collect first:
	-- demolish() mutates the building set, and spread re-reads it.
	for _, bpId in doomed do
		local fire = _fires[bpId]
		if fire then recallEngine(fire) end
		_fires[bpId] = nil
		_buildingService.demolish(bpId) -- destroys the model (tag goes with it)
	end
	for _, origin in spreadOrigins do
		spreadFrom(origin)
	end

	if #doomed > 0 then
		notify("\u{1F525} Fire spreading -- no fire coverage!", "danger")
	end

	-- New ignition: independent of coverage (fires start anywhere); the fire station only
	-- decides whether they get put out.
	local buildingCount = 0
	for _, view in _buildingService.listBuildings() do
		if not view.abandoned then buildingCount += 1 end
	end
	if buildingCount > 0 then
		local chance = math.min(IGNITE_MAX, IGNITE_BASE + buildingCount * IGNITE_PER_BLDG)
		if _rng:NextNumber() < chance then
			if FireService.igniteRandom() then
				notify("\u{1F525} A fire broke out in the city!", "warning")
			end
		end
	end
end

-- == Lifecycle =================================================================
function FireService.Init(buildingService: any, emergencyService: any, dispatch: any?, economyService: any?)
	assert(buildingService, "[FireService] missing buildingService")
	assert(emergencyService, "[FireService] missing emergencyService")
	_buildingService = buildingService
	_emergencyService = emergencyService
	_dispatch = dispatch
	_economyService = economyService
	_net = require(ReplicatedStorage:WaitForChild("Networker"))
end

function FireService.Bind() end

function FireService.Start()
	if _running then return end
	_running = true
	task.spawn(function()
		while _running do
			local speed = math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
			task.wait(FIRE_TICK / math.max(1, speed))
			if speed <= 0 then continue end
			local ok, err = pcall(tick)
			if not ok then
				warn("[FireService] tick failed: " .. tostring(err))
			end
		end
	end)
end

return FireService
