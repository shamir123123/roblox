--!strict
-- WaterService
-- Owns the city's water: what the towers and pumps deliver, what the buildings use, and
-- where the wastewater goes. The model is Cities: Skylines', without pressure zones:
--
--   * ONE network. A building is on it when a PIPE reaches it and that pipe is fed by a
--     source (WaterPipeService owns the mains -- every road carries both -- and answers
--     that), and every source pours into the same pool, so a tower across town still helps.
--   * A source runs on ELECTRICITY. A tower, a pumping station or a treatment plant that
--     the grid did not reach this pass delivers nothing, so a blackout is also a drought.
--   * A pumping station within PUMP_SPOIL_RADIUS of a sewage outlet is drinking what the
--     outlet dumps, and pumps half.
--   * Water in is sewage out: a building sends down the drain exactly what it was given,
--     and the plants and outlets take it from one pooled capacity the same way.
--   * A pool that cannot meet demand is rationed CHEAPEST DEMAND FIRST (PowerService's rule),
--     so a shortfall leaves the most buildings served, and the same ones every tick.
--
-- Water is needed from the first house, like electricity. Sewage is needed from the moment
-- the city has unlocked a way to deal with it (or has built one) -- asking for a drain the
-- player cannot build yet would be a punishment, not a challenge.
--
-- It does NOT own the towers or plants -- EmergencyService places every service building and
-- this reads them back. CoverageService asks isServedAt; CityStatsService is pushed the totals;
-- what going without COSTS (families moving out) is CitizenService's, off the attributes.

local Workspace           = game:GetService("Workspace")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ServiceTypes = require(ReplicatedStorage.City.ServiceTypes)
local ZoneTypes    = require(ReplicatedStorage.City.ZoneTypes)
local Const        = require(ServerScriptService.Services.City.CitySimConstants)

local WaterService = {}

local TICK = 2.0
local CELL = 16 -- matches CoverageService, so a query lands on the cell its building was marked in
local EPS  = 1e-6

-- m3/week. CS1 asset data counts water in units of 16 m3/week, about one unit a head,
-- whether that head lives in the building or works there.
local PER_HEAD = 16
local PUMP_SPOIL_RADIUS = 256
local SEWAGE_UNLOCKS = table.freeze({ "SewageOutlet", "SewagePlant" })
local WARN_COOLDOWN = 180
local WARN_MIN_GAP  = 20

type Node = { bp: string, pos: Vector3, use: number, home: boolean }

local _net              : any
local _buildingService  : any
local _serviceBuildings : any -- EmergencyService: owns the placed towers and plants
local _pipes            : any -- WaterPipeService: owns the mains and which of them are fed
local _cityStats        : any
local _power            : any -- PowerService: whether a pump got its electricity
local _unlockCheck      : ((string) -> boolean)? = nil
-- Cells whose building went without, per kind. ponytail: keyed by 16-stud cell, so a
-- served house sharing a cell with a dry one reads dry too; key by bpId if that ever shows.
local _cut: { [string]: { [string]: boolean } } = { Water = {}, Sewage = {} }
local _running = false
local _warned: string? = nil
local _warnedAt = -math.huge

local function cellOf(pos: Vector3): string
	return tostring(math.floor(pos.X / CELL)) .. "|" .. tostring(math.floor(pos.Z / CELL))
end

local function usageOf(view: any): number
	if view.abandoned then return 0 end
	if ZoneTypes.isResidential(view.zone) then
		return (tonumber(view.residents) or 0) * PER_HEAD
	end
	local level = math.clamp(math.floor(tonumber(view.level) or 1), 1, 3)
	local slots = Const.JOB_CAP[view.zone]
	local jobs = if slots then slots[level] else 0
	return math.clamp(tonumber(view.fill) or 0, 0, 1) * jobs * PER_HEAD
end

local function sewageInPlay(): boolean
	if _serviceBuildings.hasKind("Sewage") then return true end
	local check = _unlockCheck
	if not check then return false end
	for _, key in SEWAGE_UNLOCKS do
		if check(key) then return true end
	end
	return false
end

local function inPlay(kind: string): boolean
	return kind == "Water" or sewageInPlay()
end

-- What a source actually delivers this pass: nothing without power, half beside an outlet.
local function deliveredBy(b: any, spec: any, outlets: { Vector3 }): number
	local rated = (spec.waterOutput or 0) + (spec.sewageCapacity or 0)
	if rated <= 0 then return 0 end
	if spec.powerUse and not (_power and _power.isServicePowered(b.id)) then return 0 end
	if spec.shore and (spec.waterOutput or 0) > 0 then
		for _, o in outlets do
			local dx, dz = o.X - b.cf.Position.X, o.Z - b.cf.Position.Z
			if dx * dx + dz * dz <= PUMP_SPOIL_RADIUS * PUMP_SPOIL_RADIUS then return rated * 0.5 end
		end
	end
	return rated
end

local function warnShort(message: string?)
	if message == nil then _warned = nil; return end
	local since = os.clock() - _warnedAt
	if since < WARN_MIN_GAP or (message == _warned and since < WARN_COOLDOWN) then return end
	_warned, _warnedAt = message, os.clock()
	if _net and _net.Notify then
		_net.Notify:FireAllClients({ text = message, kind = "danger", duration = 6 })
	end
end

local function rebuild()
	-- The mains first: whether a pipe is fed depends on where the towers are, and a tower
	-- placed this tick must not leave the whole network reading stranded until the next one.
	if _pipes and _pipes.rebuildNow then _pipes.rebuildNow() end

	local outlets: { Vector3 } = {}
	for _, b in _serviceBuildings.list() do
		local spec = ServiceTypes.get(b.key) :: any
		if spec and spec.shore and (spec.sewageCapacity or 0) > 0 and b.model and b.model.Parent then
			outlets[#outlets + 1] = b.cf.Position
		end
	end

	local waterCap, sewageCap, waterRated, unpowered = 0, 0, 0, 0
	for _, b in _serviceBuildings.list() do
		if not (b.model and b.model.Parent) then continue end
		local spec = ServiceTypes.get(b.key) :: any
		if not spec then continue end
		local got = deliveredBy(b, spec, outlets)
		if (spec.waterOutput or 0) > 0 then
			waterCap += got
			waterRated += spec.waterOutput
		else
			sewageCap += got
		end
		if spec.powerUse and got <= 0 then unpowered += 1 end
	end
	local sewageLive = sewageInPlay()

	local nodes: { Node } = {}
	for _, v in _buildingService.listBuildings() do
		if typeof(v.position) ~= "Vector3" then continue end
		nodes[#nodes + 1] = {
			bp = v.bpId, pos = v.position, use = usageOf(v),
			home = ZoneTypes.isResidential(v.zone) and not v.abandoned and (tonumber(v.residents) or 0) > 0,
		}
	end
	table.sort(nodes, function(a: Node, b: Node): boolean
		if a.use ~= b.use then return a.use < b.use end
		return a.bp < b.bp
	end)

	local dry: { [string]: boolean } = {}
	local backedUp: { [string]: boolean } = {}
	local wanted, drawn, treated = 0, 0, 0
	local homes, watered, drained, reached = 0, 0, 0, 0
	for _, n in nodes do
		wanted += n.use
		local piped = _pipes.servedAt(n.pos, "Water")
		local hasWater = piped and drawn + n.use <= waterCap + EPS
		local sewage = if hasWater then n.use else 0
		drawn += sewage
		local hasSewer = not sewageLive
			or (treated + sewage <= sewageCap + EPS and _pipes.servedAt(n.pos, "Sewage"))
		if hasSewer then treated += sewage end
		if not hasWater then dry[cellOf(n.pos)] = true end
		if not hasSewer then backedUp[cellOf(n.pos)] = true end
		-- Per building, not per cell: the badge goes over the house that actually went
		-- without, and CitizenService reads the same flags to decide who moves out.
		if _buildingService.setWatered then _buildingService.setWatered(n.bp, hasWater) end
		if _buildingService.setDrained then _buildingService.setDrained(n.bp, hasSewer) end
		if n.home then
			homes += 1
			if piped then reached += 1 end
			if hasWater then watered += 1 end
			if hasSewer then drained += 1 end
		end
	end
	_cut = { Water = dry, Sewage = backedUp }

	if _cityStats and _cityStats.setWaterStats then
		_cityStats.setWaterStats({
			waterCapacity  = waterCap,
			waterUse       = wanted,
			sewageCapacity = sewageCap,
			sewage         = drawn,
			watered        = if homes == 0 then 1 else watered / homes,
			drained        = if homes == 0 then 1 else drained / homes,
			sewageNeeded   = if sewageLive then 1 else 0,
		})
	end

	-- One notice for the most urgent thing, in the order a player would fix them.
	if homes == 0 or (watered == homes and drained == homes) then
		warnShort(nil)
	elseif waterRated <= 0 then
		warnShort("Your homes have no water! Build a Water Tower next to a road -- every road carries water pipes.")
	elseif unpowered > 0 and watered < homes then
		warnShort("A water building has no electricity, so it can't pump. Connect it to power.")
	elseif reached < homes then
		warnShort("Some homes are not connected to water. Connect them with a road or a water pipe.")
	elseif watered < homes then
		warnShort("Not enough water! Build another Water Tower or a Pumping Station.")
	elseif sewageCap <= 0 then
		warnShort("Homes need a drain now! Build a Sewage Outlet on the shore or a Treatment Plant by a road.")
	else
		warnShort("Sewage is backing up into homes! Build more sewage treatment.")
	end
end

-- Synchronous pass for tests and for a deterministic read straight after a load.
function WaterService.rebuildNow()
	rebuild()
end

-- Whether a building at `pos` gets `kind` ("Water" | "Sewage"): the network reaches it and
-- the pool was not spent on cheaper buildings first. An empty plot in reach reads served --
-- it would be connected the moment something is built on it.
function WaterService.isServedAt(pos: Vector3, kind: string): boolean
	if not inPlay(kind) then return true end
	local cut = _cut[kind]
	return _pipes.servedAt(pos, kind) and not (cut and cut[cellOf(pos)])
end

-- ProgressionService.isPlaceableAllowed, injected by Bootstrap: sewage is needed once a way
-- to deal with it is unlocked.
function WaterService.setUnlockCheck(fn: ((string) -> boolean)?)
	_unlockCheck = fn
end

function WaterService.Init(net: any, buildingService: any, serviceBuildings: any, pipeService: any, cityStats: any?, powerService: any?)
	assert(buildingService, "[WaterService] missing buildingService")
	assert(serviceBuildings, "[WaterService] missing serviceBuildings (EmergencyService)")
	assert(pipeService, "[WaterService] missing pipeService (WaterPipeService)")
	_net              = net
	_buildingService  = buildingService
	_serviceBuildings = serviceBuildings
	_pipes            = pipeService
	_cityStats        = cityStats
	_power            = powerService
end

function WaterService.Start()
	if _running then return end
	_running = true
	-- Every tick, not only when a tower moves: use follows residents and job slots.
	task.spawn(function()
		while _running do
			local speed = math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
			task.wait(TICK / math.max(1, speed))
			if speed <= 0 then continue end
			local ok, err = pcall(rebuild)
			if not ok then warn("[WaterService] rebuild failed: " .. tostring(err)) end
		end
	end)
end

return WaterService
