--!strict
-- DeathcareService
-- Citizens die over time (much faster in sick households). A death leaves a body
-- at the home; a Cemetery (ServiceTypes kind "Deathcare") covering the home sends a
-- real hearse while the city has grave capacity left, and the body is buried when it
-- arrives. Uncollected bodies drag happiness down, and a home with too many drives
-- the family out.
--
-- Mirrors SicknessService: does NOT own citizens -- holds a body-set keyed by
-- homeId, reads buildings + coverage through injected services, pushes stats to
-- CityStatsService each pass.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ServiceTypes = require(ReplicatedStorage.City.ServiceTypes)

local DeathcareService = {}

-- == Tuning ====================================================================
local DEATH_TICK        = 10.0  -- game-seconds between deathcare passes
local BASE_DEATH_CHANCE = 0.002 -- per occupied home per pass
local SICK_DEATH_MULT   = 6     -- sick households are far more likely to lose someone
local HEARSE_TICKS      = 2     -- passes before a covered body is called in
local ABANDON_BODIES    = 3     -- a home with this many unburied bodies is abandoned
local TOAST_COOLDOWN    = 10
local MAX_HEARSES       = 3     -- concurrent hearses out

-- == State =====================================================================
local _buildingService: any
local _emergencyService: any
local _sicknessService: any
local _cityStatsService: any
local _dispatch: any
local _rng = Random.new()
local _running = false
local _lastToastAt = 0
-- ponytail: grave fill is transient like sickness -- a city reload starts with
-- empty graves. Add serialize/restore if persistent fill ever matters.
local _buried = 0

type BodyRecord = { homeId: string, pos: Vector3, count: number, ticks: number, trip: any }
local _bodies: { [string]: BodyRecord } = {} -- homeId -> record

-- == Helpers ===================================================================
local function notify(text: string, toastKind: string)
	local now = os.clock()
	if now - _lastToastAt < TOAST_COOLDOWN then return end
	_lastToastAt = now
	local ok, Net = pcall(require, ReplicatedStorage:WaitForChild("Networker"))
	if ok and Net and Net.Notify then
		Net.Notify:FireAllClients({ text = text, kind = toastKind })
	end
end

local function tagHome(homeId: string, count: number)
	local model = _buildingService.getModel and _buildingService.getModel(homeId)
	if not model then return end
	model:SetAttribute("UnburiedBodies", count)
	if not CollectionService:HasTag(model, "HasBodies") then
		CollectionService:AddTag(model, "HasBodies")
	end
end

local function untagHome(homeId: string)
	local model = _buildingService.getModel and _buildingService.getModel(homeId)
	if not model then return end
	CollectionService:RemoveTag(model, "HasBodies")
	model:SetAttribute("UnburiedBodies", nil)
end

local function graveCapacity(): number
	if not _emergencyService then return 0 end
	local total = 0
	for _, b in _emergencyService.list() do
		if b.kind ~= "Deathcare" then continue end
		local spec = ServiceTypes.get(b.key)
		total += if spec and spec.capacity then spec.capacity else 0
	end
	return total
end

-- == Public API ================================================================
function DeathcareService.getUnburiedCount(): number
	local n = 0
	for _, rec in _bodies do n += rec.count end
	return n
end

function DeathcareService.getBuriedCount(): number
	return _buried
end

function DeathcareService.getGraveCapacity(): number
	return graveCapacity()
end

-- One hearse carries one body. Called when the vehicle reaches the home.
local function collectBody(homeId: string)
	local rec = _bodies[homeId]
	if not rec then return end
	if rec.trip and _dispatch then _dispatch.release(rec.trip) end
	rec.trip = nil
	rec.count -= 1
	rec.ticks = 0
	_buried += 1
	if rec.count <= 0 then
		_bodies[homeId] = nil
		untagHome(homeId)
	else
		tagHome(homeId, rec.count)
	end
end

local function dispatchHearse(homeId: string, rec: BodyRecord)
	if not _dispatch or rec.trip then return end
	local cemeteryPos = _dispatch.nearestStation(rec.pos, "Cemetery")
	if not cemeteryPos then return end
	rec.trip = _dispatch.send({
		kind = "Hearse",
		from = cemeteryPos,
		to = rec.pos,
		maxActive = MAX_HEARSES,
		onArrive = function() collectBody(homeId) end,
	})
end

function DeathcareService.clear()
	for homeId, rec in _bodies do
		if rec.trip and _dispatch then _dispatch.cancel(rec.trip) end
		untagHome(homeId)
	end
	table.clear(_bodies)
	_buried = 0
end

-- == Tick ======================================================================
local function tick()
	if not _buildingService or not _emergencyService then return end

	-- Death rolls over occupied homes; sickness multiplies the odds.
	local homes = 0
	for _, b in _buildingService.listBuildings() do
		if b.zone ~= "Residential" or b.abandoned then continue end
		if (tonumber(b.residents) or 0) <= 0 then continue end
		homes += 1
		local chance = BASE_DEATH_CHANCE
		if _sicknessService and _sicknessService.isHouseholdSick(b.bpId) then
			chance *= SICK_DEATH_MULT
		end
		if _rng:NextNumber() < chance then
			local rec = _bodies[b.bpId]
			if rec then
				rec.count += 1
			else
				rec = { homeId = b.bpId, pos = b.position or Vector3.zero, count = 1, ticks = 0, trip = nil }
				_bodies[b.bpId] = rec
			end
			tagHome(b.bpId, rec.count)
			notify("\u{1FAA6} A citizen has passed away.", "deathcare")
		end
	end

	-- Hearse pass: after HEARSE_TICKS a covered body is called in, and buried when the
	-- hearse actually reaches the house. A body with no cemetery in range (or no graves
	-- left) is stranded and starts counting toward abandonment.
	local capacity = graveCapacity()
	local unburied, stranded = 0, 0
	local toLeave: { string } = {}
	for homeId, rec in _bodies do
		rec.ticks += 1
		if rec.ticks >= HEARSE_TICKS then
			if _buried < capacity and _emergencyService.coversAt(rec.pos, "Deathcare") then
				dispatchHearse(homeId, rec)
			else
				stranded += rec.count
				if rec.count >= ABANDON_BODIES then table.insert(toLeave, homeId) end
			end
		end
		local live = _bodies[homeId]
		if live then unburied += live.count end
	end

	-- Homes left grieving with no cemetery service: the family moves out. Same
	-- abandonment channel SicknessService uses.
	for _, homeId in toLeave do
		local rec = _bodies[homeId]
		if rec and rec.trip and _dispatch then _dispatch.cancel(rec.trip) end
		untagHome(homeId)
		_bodies[homeId] = nil
		if _buildingService.flagForAbandonment then
			_buildingService.flagForAbandonment(homeId, "deathcare")
		end
	end

	if stranded > 0 then
		notify(if capacity <= _buried
			then "\u{26B0} Cemeteries are full -- build another!"
			else "\u{26B0} The deceased have nowhere to rest -- build a cemetery!", "danger")
	end

	if _cityStatsService and _cityStatsService.setDeathcareStats then
		_cityStatsService.setDeathcareStats({
			unburiedFraction = if homes > 0 then math.min(1, unburied / homes) else 0,
		})
	end
end

-- == Lifecycle =================================================================
function DeathcareService.Init(buildingService: any, emergencyService: any, sicknessService: any, cityStatsService: any, dispatch: any?)
	assert(buildingService, "[DeathcareService] missing buildingService")
	assert(emergencyService, "[DeathcareService] missing emergencyService")
	_buildingService = buildingService
	_emergencyService = emergencyService
	_sicknessService = sicknessService
	_cityStatsService = cityStatsService
	_dispatch = dispatch
end

function DeathcareService.Bind() end

function DeathcareService.Start()
	if _running then return end
	_running = true
	task.spawn(function()
		while _running do
			local speed = math.clamp(tonumber(workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
			task.wait(DEATH_TICK / math.max(1, speed))
			if speed <= 0 then continue end
			local ok, err = pcall(tick)
			if not ok then warn("[DeathcareService] tick failed: " .. tostring(err)) end
		end
	end)
end

return DeathcareService
