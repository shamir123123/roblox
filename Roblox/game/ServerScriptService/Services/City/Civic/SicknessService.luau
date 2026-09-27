--!strict
-- SicknessService
-- Citizens can fall ill when healthcare coverage is low. A sick adult's productivity
-- drops (they stop commuting / applying for jobs). A household inside a Hospital's
-- coverage gets an AMBULANCE, and recovers when it arrives -- coverage on the map is
-- not treatment. Persistent illness with no hospital causes the household to leave.
--
-- This service does NOT own citizens directly. It holds a sick-set (homeId -> sickData)
-- and CitizenService calls our hooks each sim step to apply effects.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SicknessService = {}

-- == Tuning ====================================================================
local SICK_TICK           = 8.0   -- game-seconds between sickness passes
local BASE_SICK_CHANCE    = 0.015 -- per-household per-tick base illness chance
local COVERAGE_MULT       = 3.0   -- how much low coverage amplifies sickness risk
-- A sick adult recovers by reaching a Hospital. Without hospital access they take
-- RECOVER_TICKS_NO_HOSPITAL ticks before they leave (household departs).
local RECOVER_TICKS_NO_HOSPITAL = 8
local TOAST_COOLDOWN      = 10
local MAX_AMBULANCES      = 4     -- concurrent ambulances out at base funding

-- == State =====================================================================
local _buildingService: any
local _emergencyService: any
local _cityStatsService: any
local _economyService: any
local _dispatch: any
local _rng = Random.new()
local _running = false
local _lastToastAt = 0

-- Per-household sickness state. We store homeId (stable across restores) and
-- a sickTicks counter -- if it reaches the cap the household leaves.
type SickRecord = { homeId: string, sickTicks: number, recovering: boolean, trip: any }
local _sick: { [string]: SickRecord } = {}  -- homeId -> record

-- == Helpers ===================================================================
-- Health funding buys a bigger fleet, the same way it widens coverage radius.
local function maxAmbulances(): number
	local mult = if _economyService and _economyService.getFunding then _economyService.getFunding("Health") else 1
	return math.max(1, math.floor(MAX_AMBULANCES * mult + 0.5))
end

local function notify(text: string)
	local now = os.clock()
	if now - _lastToastAt < TOAST_COOLDOWN then return end
	_lastToastAt = now
	local ok, Net = pcall(require, ReplicatedStorage:WaitForChild("Networker"))
	if ok and Net and Net.Notify then
		Net.Notify:FireAllClients({ text = text, kind = "sickness" })
	end
end

local function tagHome(homeId: string, intensity: number)
	local model = _buildingService.getModel and _buildingService.getModel(homeId)
	if not model then return end
	model:SetAttribute("SicknessIntensity", intensity)
	if not CollectionService:HasTag(model, "HasSickness") then
		CollectionService:AddTag(model, "HasSickness")
	end
end

local function untagHome(homeId: string)
	local model = _buildingService.getModel and _buildingService.getModel(homeId)
	if not model then return end
	CollectionService:RemoveTag(model, "HasSickness")
	model:SetAttribute("SicknessIntensity", nil)
end

-- == Public API (called by CitizenService / Bootstrap) =========================

-- True if a household's home is currently sick (CitizenService can idle its adults).
function SicknessService.isHouseholdSick(homeId: string): boolean
	return _sick[homeId] ~= nil
end

-- Called when an ambulance reaches the home, or when a sick household's adult reaches
-- a Hospital under their own steam (CitizenService).
function SicknessService.markRecovered(homeId: string)
	local rec = _sick[homeId]
	if not rec then return end
	if rec.trip and _dispatch then _dispatch.release(rec.trip) end
	rec.trip = nil
	untagHome(homeId)
	_sick[homeId] = nil
end

-- Send an ambulance from the nearest hospital. The household recovers when it arrives.
local function dispatchAmbulance(homeId: string, rec: SickRecord, pos: Vector3)
	if not _dispatch or rec.trip then return end
	local hospitalPos = _dispatch.nearestStation(pos, "Healthcare")
	if not hospitalPos then return end
	rec.trip = _dispatch.send({
		kind = "Ambulance",
		from = hospitalPos,
		to = pos,
		maxActive = maxAmbulances(),
		onArrive = function() SicknessService.markRecovered(homeId) end,
	})
end

-- Fraction of households currently sick (0..1). CityStatsService uses this for happiness.
function SicknessService.getSickFraction(): number
	if not _buildingService then return 0 end
	local homes = _buildingService.getOccupiedHomeCount and _buildingService.getOccupiedHomeCount() or 0
	if homes <= 0 then return 0 end
	local n = 0
	for _ in _sick do n += 1 end
	return n / homes
end

function SicknessService.getSickCount(): number
	local n = 0
	for _ in _sick do n += 1 end
	return n
end

function SicknessService.clear()
	for homeId, rec in _sick do
		if rec.trip and _dispatch then _dispatch.cancel(rec.trip) end
		untagHome(homeId)
	end
	table.clear(_sick)
end

-- == Tick ======================================================================
local function tick()
	if not _buildingService or not _emergencyService then return end

	local stats = _emergencyService.getStats()
	local healthCoverage = if stats then (stats.health or 1) else 1

	-- Illness risk is higher when healthcare coverage is low
	local riskMultiplier = 1 + (1 - healthCoverage) * COVERAGE_MULT
	local sickChance = BASE_SICK_CHANCE * riskMultiplier

	local views = _buildingService.listBuildings()
	local toLeave: { string } = {}

	for _, b in views do
		if b.zone ~= "Residential" or b.abandoned then continue end
		local homeId = b.bpId
		local residents = tonumber(b.residents) or 0
		if residents <= 0 then continue end

		local rec = _sick[homeId]
		if rec then
			-- Already sick: progress
			rec.sickTicks += 1
			local pos = b.position or Vector3.zero
			tagHome(homeId, math.clamp(rec.sickTicks / RECOVER_TICKS_NO_HOSPITAL, 0, 1))

			if _emergencyService.coversAt(pos, "Hospital") then
				-- Covered: an ambulance is sent and recovery happens on arrival. If the
				-- fleet is at its cap the call is simply retried next tick -- the household
				-- stays ill but does not escalate, because help IS coming.
				dispatchAmbulance(homeId, rec, pos)
			else
				-- No hospital: escalate toward departure
				if rec.sickTicks >= RECOVER_TICKS_NO_HOSPITAL then
					table.insert(toLeave, homeId)
				end
			end
		else
			-- New illness roll
			if _rng:NextNumber() < sickChance then
				_sick[homeId] = { homeId = homeId, sickTicks = 0, recovering = false, trip = nil }
				tagHome(homeId, 0)
				notify("Illness outbreak reported!")
			end
		end
	end

	-- Households with no hospital access that have been sick too long leave the city.
	-- We signal abandonment through BuildingService; CitizenService's existing removal
	-- loop picks it up on the next sim step.
	for _, homeId in toLeave do
		local rec = _sick[homeId]
		if rec and rec.trip and _dispatch then _dispatch.cancel(rec.trip) end
		untagHome(homeId)
		_sick[homeId] = nil
		if _buildingService.flagForAbandonment then
			_buildingService.flagForAbandonment(homeId, "sickness")
		end
	end

	-- Push stats to CityStatsService
	if _cityStatsService and _cityStatsService.setSicknessStats then
		_cityStatsService.setSicknessStats({
			sickFraction = SicknessService.getSickFraction(),
			coverage = healthCoverage,
		})
	end
end

-- == Lifecycle =================================================================
function SicknessService.Init(buildingService: any, emergencyService: any, cityStatsService: any, dispatch: any?, economyService: any?)
	assert(buildingService, "[SicknessService] missing buildingService")
	assert(emergencyService, "[SicknessService] missing emergencyService")
	_buildingService = buildingService
	_emergencyService = emergencyService
	_cityStatsService = cityStatsService
	_dispatch = dispatch
	_economyService = economyService
end

function SicknessService.Bind() end

function SicknessService.Start()
	if _running then return end
	_running = true
	task.spawn(function()
		while _running do
			local speed = math.clamp(tonumber(workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
			task.wait(SICK_TICK / math.max(1, speed))
			if speed <= 0 then continue end
			local ok, err = pcall(tick)
			if not ok then warn("[SicknessService] tick failed: " .. tostring(err)) end
		end
	end)
end

return SicknessService
