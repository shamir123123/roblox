--!strict
-- CrimeService
-- Crime incidents spawn at uncovered buildings over time.
-- A PoliceStation within coverage radius suppresses/clears incidents quickly.
-- Uncovered incidents persist and cause a happiness + demand penalty in CityStatsService.
-- A police car rolls out of the nearest station and clears the incident on arrival
-- (EmergencyDispatch owns the drive).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CrimeService = {}

-- == Tuning ====================================================================
local CRIME_TICK        = 6.0   -- game-seconds between crime passes (GameSpeed-scaled)
local INCIDENT_BASE     = 0.06  -- per-tick chance a new incident spawns somewhere
local INCIDENT_PER_BLDG = 0.0008-- + per building (bigger city, higher baseline crime)
local INCIDENT_MAX      = 0.30  -- cap on per-tick spawn chance
local RESOLVE_TICKS     = 3     -- ticks an uncovered incident persists before it escalates
local ESCALATE_ABANDON_TICKS = 12 -- ticks before an uncovered incident flags for abandonment
local TOAST_COOLDOWN    = 8     -- real-seconds between notifications

-- == State =====================================================================
local _buildingService: any
local _emergencyService: any
local _cityStatsService: any
local _economyService: any
local _dispatch: any
local _net: any
local _rng = Random.new()
local _running = false
local _lastToastAt = 0

type Incident = {
	bpId: string,
	pos: Vector3,
	age: number,        -- ticks since spawned
	responding: boolean,-- a police car is already en route
	trip: any,          -- EmergencyDispatch.Trip while one is
}
local _incidents: { [string]: Incident } = {}
local MAX_POLICE_CARS = 6

-- Police funding scales how many response cars can be out at once (more vehicles).
local function maxPoliceCars(): number
	local mult = if _economyService and _economyService.getFunding then _economyService.getFunding("Police") else 1
	return math.max(1, math.floor(MAX_POLICE_CARS * mult + 0.5))
end

-- == Helpers ===================================================================
local function notify(text: string)
	local now = os.clock()
	if now - _lastToastAt < TOAST_COOLDOWN then return end
	_lastToastAt = now
	if _net then
		local ok, Net = pcall(require, ReplicatedStorage:WaitForChild("Networker"))
		if ok and Net and Net.Notify then
			Net.Notify:FireAllClients({ text = text, kind = "crime" })
		end
	end
end

local function tagBuilding(bpId: string, age: number)
	local model = _buildingService.getModel and _buildingService.getModel(bpId)
	if not model then return end
	model:SetAttribute("CrimeIntensity", math.clamp(age / ESCALATE_ABANDON_TICKS, 0, 1))
	if not CollectionService:HasTag(model, "HasCrime") then
		CollectionService:AddTag(model, "HasCrime")
	end
end

local function untagBuilding(bpId: string)
	local model = _buildingService.getModel and _buildingService.getModel(bpId)
	if not model then return end
	CollectionService:RemoveTag(model, "HasCrime")
	model:SetAttribute("CrimeIntensity", nil)
end

local function clearIncident(bpId: string)
	local inc = _incidents[bpId]
	if not inc then return end
	_incidents[bpId] = nil
	untagBuilding(bpId)
	if inc.trip and _dispatch then _dispatch.release(inc.trip) end
	inc.trip = nil
end

-- A patrol car leaves the nearest station and clears the incident when it gets
-- there. Refused (and retried next tick) when the fleet is already at its cap.
local function dispatchPolice(incident: Incident)
	if not _dispatch then return end
	local stationPos = _dispatch.nearestStation(incident.pos, "PoliceStation")
	if not stationPos then return end

	local bpId = incident.bpId
	local trip = _dispatch.send({
		kind = "Police",
		from = stationPos,
		to = incident.pos,
		maxActive = maxPoliceCars(),
		onArrive = function() clearIncident(bpId) end,
	})
	if not trip then return end

	incident.responding = true
	incident.trip = trip
end

-- == Public ====================================================================
function CrimeService.getIncidentCount(): number
	local n = 0
	for _ in _incidents do n += 1 end
	return n
end

-- Coverage fraction (0..1) of populated homes with police within radius.
-- Delegates to EmergencyService which already computes this.
function CrimeService.getCoverageFraction(): number
	if not _emergencyService then return 1 end
	local stats = _emergencyService.getStats()
	return stats and stats.police or 1
end

function CrimeService.clear()
	for bpId, inc in _incidents do
		untagBuilding(bpId)
		if inc.trip and _dispatch then _dispatch.cancel(inc.trip) end
	end
	table.clear(_incidents)
end

local function tick()
	if not _buildingService then return end
	local views = _buildingService.listBuildings()
	local total = #views

	-- Spawn new incidents
	local spawnChance = math.min(INCIDENT_BASE + INCIDENT_PER_BLDG * total, INCIDENT_MAX)
	if _rng:NextNumber() < spawnChance then
		local candidates: { any } = {}
		for _, b in views do
			if b.abandoned then continue end
			if _incidents[b.bpId] then continue end
			-- Prefer uncovered buildings (2x weight)
			local covered = _emergencyService and _emergencyService.coversAt(b.position or Vector3.zero, "Police")
			local weight = if covered then 1 else 2
			for _ = 1, weight do table.insert(candidates, b) end
		end
		if #candidates > 0 then
			local pick = candidates[_rng:NextInteger(1, #candidates)]
			local pos = pick.position or (pick.bpId and _buildingService.getBuildingPosition and _buildingService.getBuildingPosition(pick.bpId)) or Vector3.zero
			_incidents[pick.bpId] = { bpId = pick.bpId, pos = pos, age = 0, responding = false, trip = nil }
			notify("Crime reported near " .. (pick.bpId or "a building") .. "!")
		end
	end

	-- Progress existing incidents
	local toResolve: { string } = {}
	for bpId, inc in _incidents do
		local covered = _emergencyService and _emergencyService.coversAt(inc.pos, "Police")
		inc.age += 1
		tagBuilding(bpId, inc.age)

		if covered then
			-- Covered: dispatch police if not already responding, resolve quickly
			if not inc.responding then
				dispatchPolice(inc)
			end
			-- Also auto-resolve after RESOLVE_TICKS even without a car (fallback)
			if inc.age >= RESOLVE_TICKS and not inc.responding then
				table.insert(toResolve, bpId)
			end
		else
			-- Uncovered: escalate toward abandonment
			if inc.age >= ESCALATE_ABANDON_TICKS then
				if _buildingService.flagForAbandonment then
					_buildingService.flagForAbandonment(bpId, "crime")
				end
				table.insert(toResolve, bpId) -- remove incident (abandonment is handled)
			end
		end
	end
	for _, bpId in toResolve do
		local inc = _incidents[bpId]
		if inc and inc.trip and _dispatch then _dispatch.cancel(inc.trip) end
		untagBuilding(bpId)
		_incidents[bpId] = nil
	end

	-- Push crime stats into CityStatsService happiness
	if _cityStatsService and _cityStatsService.setCrimeStats then
		_cityStatsService.setCrimeStats({
			coverage = CrimeService.getCoverageFraction(),
			incidents = CrimeService.getIncidentCount(),
		})
	end
end

-- == Lifecycle =================================================================
function CrimeService.Init(buildingService: any, emergencyService: any, cityStatsService: any, economyService: any?, dispatch: any?)
	assert(buildingService, "[CrimeService] missing buildingService")
	assert(emergencyService, "[CrimeService] missing emergencyService")
	_buildingService = buildingService
	_emergencyService = emergencyService
	_cityStatsService = cityStatsService
	_economyService = economyService
	_dispatch = dispatch
end

function CrimeService.Bind() end

function CrimeService.Start()
	if _running then return end
	_running = true
	task.spawn(function()
		while _running do
			local speed = math.clamp(tonumber(workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
			task.wait(CRIME_TICK / math.max(1, speed))
			if speed <= 0 then continue end
			local ok, err = pcall(tick)
			if not ok then warn("[CrimeService] tick failed: " .. tostring(err)) end
		end
	end)
end

return CrimeService
