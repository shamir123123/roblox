--!strict

-- The zoning simulation brain. Ticks at 1Hz (GameSpeed-scaled). For each
-- building it drives fill, decides upgrades, and decides abandonment / recovery
-- from a two-axis model: global RCI demand (macro) AND per-building land value
-- (local eligibility). It owns the decisions and calls BuildingService to apply
-- them; BuildingService stays mechanical.
--
-- Timers accumulate in game-seconds (one SIM_TICK each tick) so all dwell /
-- cooldown thresholds are GameSpeed-scaled automatically.

local RS = game:GetService("ReplicatedStorage")

local Const     = require(script.Parent.Parent.CitySimConstants)
local ZoneTypes = require(RS.City.ZoneTypes)

local ZoneSimService = {}

type BuildingView = {
	bpId           : string,
	zone           : string,
	level          : number,
	fill           : number,
	abandoned      : boolean,
	powered        : boolean,
	occupiedLotIds : { string },
	residents      : number,
}

type SimState = {
	hardTimer    : number,
	softTimer    : number,
	vacTimer     : number,
	recoverTimer : number,
	lastUpgradeAt: number,
}

local _cityStats : any
local _landValue : any
local _building  : any
local _running   = false
local _gameTime  = 0
local _state     : { [string]: SimState } = {}
local _lastTickError: string? = nil

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

local function getState(bpId: string): SimState
	local st = _state[bpId]
	if not st then
		st = { hardTimer = 0, softTimer = 0, vacTimer = 0, recoverTimer = 0, lastUpgradeAt = -math.huge }
		_state[bpId] = st
	end
	return st
end

local function demandFor(zone: string, demand: { [string]: number }): number
	local key = ZoneTypes.getDemandKey(zone :: any)
	return if key then tonumber(demand[key]) or 0 else 0
end

-- Returns true if a build change was spent this tick.
local function tryUpgrade(view: BuildingView, eval: any, demand: number, st: SimState): boolean
	if view.abandoned or view.level >= 3 then return false end
	if not eval.gatesPass then return false end
	if (_gameTime - st.lastUpgradeAt) < Const.UPGRADE_COOLDOWN then return false end

	local lvNeed = Const.UPGRADE_LV[view.level]
	if not lvNeed then return false end

	local scoreOk = view.fill >= Const.UPGRADE_FILL
		and demand > Const.UPGRADE_DEMAND
		and eval.lv >= lvNeed

	if not scoreOk then return false end

	if _building.upgradeGroup(view.bpId) then
		st.lastUpgradeAt = _gameTime
		return true
	end

	return false
end

-- Abandonment removed (it caused the population bounce + the constant model "refresh"
-- from abandon<->recover churn rebuilding the model). Nothing goes derelict anymore --
-- BuildingService.abandonGroup is a no-op. The only remaining job is to HEAL any building
-- left abandoned by an older save so the city comes back clean.
--
-- ...except a building abandoned because it went DARK. Healing that one on the next tick
-- is what would make PowerService's abandonment invisible, so the heal now waits for the
-- power to come back -- and when it does, recoverGroup destroys the derelict and clones a
-- fresh template on the spot, which is the new house people then move into.
local function healIfAbandoned(view: BuildingView): boolean
	if not view.abandoned or view.powered == false then return false end
	return _building.recoverGroup(view.bpId)
end

function ZoneSimService.tick()
	local demand = _cityStats.getDemand()
	local views: { BuildingView } = _building.listBuildings()

	local alive: { [string]: boolean } = {}
	local changes = 0

	for _, view in views do
		alive[view.bpId] = true
		local st = getState(view.bpId)
		local eval = _landValue.evaluateBuilding(view)
		local d = demandFor(view.zone, demand)

		-- Fill is owned by CitizenService now (real residents/workers drive occupancy),
		-- not eased toward land value here.

		if changes < Const.MAX_CHANGES_PER_TICK and tryUpgrade(view, eval, d, st) then
			changes += 1
		end

		if changes < Const.MAX_CHANGES_PER_TICK and healIfAbandoned(view) then
			changes += 1
		end
	end

	-- Drop state for buildings that no longer exist.
	for bpId in _state do
		if not alive[bpId] then
			_state[bpId] = nil
		end
	end

	_gameTime += Const.SIM_TICK
end

function ZoneSimService.Init(cityStatsService: any, landValueService: any, buildingService: any)
	_cityStats = cityStatsService
	_landValue = landValueService
	_building  = buildingService
end

function ZoneSimService.Bind() end

function ZoneSimService.Start()
	if _running then return end
	_running = true

	task.spawn(function()
		while _running do
			local speed = math.clamp(tonumber(workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
			task.wait(Const.SIM_TICK / math.max(1, speed))

			if speed <= 0 then continue end

			local ok, err = pcall(ZoneSimService.tick)
			if not ok then
				_lastTickError = tostring(err)
				warn("[ZoneSimService] tick failed: " .. _lastTickError)
			else
				_lastTickError = nil
			end
		end
	end)
end

return ZoneSimService
