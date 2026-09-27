--!strict

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityStatsService = {}

local CAP = table.freeze({
	Residential = table.freeze({ 4, 10, 20 }),
	Commercial  = table.freeze({ 3, 7, 14 }),
	Industrial  = table.freeze({ 5, 11, 20 }),
})

local TICK             = 1.0
local DISPLAY_LERP     = 0.25
local SCALE_BASE       = 18
local SCALE_POP_FACTOR = 0.5
local NEW_CITY_FADE_POP = 250 -- head start: all demands pegged high on a fresh map, fading as residents arrive
local C_PER_POP        = 0.35 -- shop capacity one resident's spending supports
-- Baseline pull per zone: the region around the city keeps growing, so a healthy city
-- always advertises SOME demand for everything. A pure tuning knob -- it keeps the bars
-- off zero between the counted factors below, so zoning never feels pointless.
local REGION_W = table.freeze({ R = 0.15, C = 0.10, I = 0.10 })
-- Uncovered utility share -> happiness loss (fraction of homes without coverage).
local UTILITY_HAPPINESS_W = table.freeze({ power = 0.15, water = 0.12, sewage = 0.08 })
-- Citizen-grounded factor weights. Every factor is a counted fact from the live sim
-- (open job slots, jobless adults, unserved shoppers, goods imports) normalized by
-- `scale`; signed single factors replace opposing max(0, a-b) pairs so no factor
-- needs another positive one to move first -- the all-zero deadlock cannot form.
local GOODS_C_W    = 0.4 -- goods surplus pulls shops in; imports eat their margins
local ORDERS_I_W   = 0.6 -- goods shortfall (imports) pulls industry in; surplus repels
local LABOR_I_W    = 0.5 -- jobless adults attract industry
local UNEMPLOYMENT_R_W = 0.6 -- jobless locals repel new residents -- a drag, never a wall
-- Vacancy rule: past healthy churn (TOL) empty buildings drag demand down, reaching
-- full strength (-VACANCY_W) by VACANCY_FULL. It is a "stop zoning this, let it fill"
-- signal and nothing more: capped below 1 so a freshly zoned street can never zero the
-- bar by itself (the old 15%/40% rule did exactly that -- ten new houses beside twenty
-- read as a housing glut and punished the player for expanding).
local VACANCY_TOL    = 0.30
local VACANCY_FULL   = 0.80
local VACANCY_W      = 0.6
-- CS2 shortage rule: a nearly-full zone pushes demand UP -- more people/companies
-- want in than there are places. This is the main positive pressure in a healthy
-- city, so the bars sit visibly filled instead of hovering at zero.
local SHORTAGE_START = 0.70
local SHORTAGE_W     = 0.6
local REPUTATION_R_W = 0.25 -- happy city pulls residents in; unhappy repels
local REPUTATION_BASE = 0.5 -- happiness above this attracts, below repels
-- A USED bus network makes the city easier to live in, so it pulls new residents in.
-- The factor is monthly boardings per resident (capped at 1 ride/resident/month), so
-- empty ghost lines attract nobody -- only actual ridership counts.
local TRANSIT_R_W = 0.3
-- A client cannot perceive a sub-pixel bar move; below this the per-tick demand
-- broadcast is skipped, so a settled city stops fanning out entirely.
local BROADCAST_EPS    = 0.004

local _buildingService: any
local _educationService: any
local _supplyService: any -- SupplyService (optional): real goods flow (output vs need)
local _coverage: any      -- CoverageService (optional): the noise raster residents live in
local _syncRemote: RemoteEvent
local _real = { R = 0, C = 0, I = 0 }
local _moveInR = 0
-- Per-zone factor breakdown of _real (id -> signed contribution); ships to the client
-- so the demand gauges can explain themselves.
local _factors: { [string]: { [string]: number } } = { R = {}, C = {}, I = {} }
local _disp = { R = 0, C = 0, I = 0 }
local _population = 0
local _jobs = 0
local _lastPayload: any = nil
-- Last values actually broadcast. R seeds to huge so the first tick always sends.
local _lastSent = { R = math.huge, C = 0, I = 0, pop = -1, jobs = -1, eduEligible = -1, eduAssigned = -1, eduAttending = -1, eduCapacity = -1, eduCoverage = -1, happiness = -1 }
local _lastTickError: string? = nil
local _running = false
local OVEREDUCATION_C_BOOST = 0.25 -- an over-educated glut lifts commercial/office demand
local _workforce = { educatedFraction = 0, overeducatedFraction = 0, employed = 0, totalAdults = 0 }
local _happiness = 1
local _crimeStats   = { coverage = 1, incidents = 0 }
local _sicknessStats = { sickFraction = 0, coverage = 1 }
-- DeathcareService pushes the unburied-body pressure here each pass.
local _deathcareStats = { unburiedFraction = 0 }
-- CityEconomyService pushes the budget pressure here: high taxes dent happiness and
-- per-zone demand. Defaults are neutral so an un-wired economy changes nothing.
local _budgetStats = { happinessPenalty = 0, demandPenalty = { R = 0, C = 0, I = 0 } }
-- CitizenService pushes TransitService's monthly ridership here each sim step.
local _transitStats = { riders = 0 }
-- PowerService pushes the electricity grid's totals here each pass (kW), so the HUD rides
-- the SyncCityStats broadcast instead of opening a second remote for it.
local _powerStats = { production = 0, consumption = 0, imported = 0, exported = 0, stored = 0, storage = 0, covered = 1, grids = 0 }
local _lastSentPower = { production = -1, consumption = -1, imported = -1, exported = -1 }
-- WaterService pushes the water and sewage pools here each pass: m3/week, plus the share of
-- homes each one actually serves (1 while the player has built none of it).
local _waterStats = { waterCapacity = 0, waterUse = 0, sewageCapacity = 0, sewage = 0, watered = 1, drained = 1, sewageNeeded = 0 }
local _lastSentWater: { [string]: number } = {}

-- CitizenService pushes the adult workforce's education summary here each sim step.
function CityStatsService.setWorkforce(w: any)
	if typeof(w) ~= "table" then return end
	_workforce = {
		educatedFraction = math.clamp(tonumber(w.educatedFraction) or 0, 0, 1),
		overeducatedFraction = math.clamp(tonumber(w.overeducatedFraction) or 0, 0, 1),
		employed = math.max(0, tonumber(w.employed) or 0),
		totalAdults = math.max(0, tonumber(w.totalAdults) or 0),
	}
end

function CityStatsService.getHappiness(): number
	return _happiness
end

local function clamp1(x: number): number
	return math.clamp(x, -1, 1)
end

local function capacityOf(byLevel: { number }, cap: { number }): number
	local total = 0

	for level = 1, #cap do
		total += (byLevel[level] or 0) * cap[level]
	end

	return total
end

-- Crime and sickness stats pushed by CrimeService / SicknessService each tick.
function CityStatsService.setCrimeStats(stats: any)
	if typeof(stats) ~= "table" then return end
	_crimeStats = {
		coverage  = math.clamp(tonumber(stats.coverage) or 1, 0, 1),
		incidents = math.max(0, math.floor(tonumber(stats.incidents) or 0)),
	}
end

function CityStatsService.setSicknessStats(stats: any)
	if typeof(stats) ~= "table" then return end
	_sicknessStats = {
		sickFraction = math.clamp(tonumber(stats.sickFraction) or 0, 0, 1),
		coverage     = math.clamp(tonumber(stats.coverage) or 1, 0, 1),
	}
end

function CityStatsService.setDeathcareStats(stats: any)
	if typeof(stats) ~= "table" then return end
	_deathcareStats = { unburiedFraction = math.clamp(tonumber(stats.unburiedFraction) or 0, 0, 1) }
end

-- CityEconomyService pushes tax pressure each tick: a happiness penalty and a
-- per-zone demand penalty, both already computed from the chosen tax rates.
-- Negative values are a low-tax bonus (economy caps how big it can get).
function CityStatsService.setPowerStats(stats: any)
	if typeof(stats) ~= "table" then return end
	_powerStats = {
		production  = math.max(0, tonumber(stats.production) or 0),
		consumption = math.max(0, tonumber(stats.consumption) or 0),
		imported    = math.max(0, tonumber(stats.imported) or 0),
		exported    = math.max(0, tonumber(stats.exported) or 0),
		stored      = math.max(0, tonumber(stats.stored) or 0),
		storage     = math.max(0, tonumber(stats.storage) or 0),
		covered     = math.clamp(tonumber(stats.covered) or 1, 0, 1),
		grids       = math.max(0, math.floor(tonumber(stats.grids) or 0)),
	}
end

function CityStatsService.setWaterStats(stats: any)
	if typeof(stats) ~= "table" then return end
	_waterStats = {
		waterCapacity  = math.max(0, tonumber(stats.waterCapacity) or 0),
		waterUse       = math.max(0, tonumber(stats.waterUse) or 0),
		sewageCapacity = math.max(0, tonumber(stats.sewageCapacity) or 0),
		sewage         = math.max(0, tonumber(stats.sewage) or 0),
		watered        = math.clamp(tonumber(stats.watered) or 1, 0, 1),
		drained        = math.clamp(tonumber(stats.drained) or 1, 0, 1),
		sewageNeeded   = if tonumber(stats.sewageNeeded) == 1 then 1 else 0,
	}
end

-- Residents living with noise above what people shrug off, 0..1 (sampled every few ticks:
-- it walks every home). Noise also lowers each building's land value (LandValueService).
local NOISE_COMFORT = 0.25
local NOISE_HAPPINESS_W = 0.2
local NOISE_SAMPLE_EVERY = 10
local _noise = { exposure = 0, tick = 0 }
local function noiseExposure(): number
	_noise.tick += 1
	if not _coverage or _noise.tick % NOISE_SAMPLE_EVERY ~= 1 then return _noise.exposure end
	local weighted, people = 0, 0
	for _, b in _buildingService.listBuildings() do
		local residents = tonumber(b.residents) or 0
		if b.zone == "Residential" and residents > 0 and b.position then
			weighted += math.max(0, _coverage.getNoiseAt(b.position) - NOISE_COMFORT) / (1 - NOISE_COMFORT) * residents
			people += residents
		end
	end
	_noise.exposure = if people > 0 then weighted / people else 0
	return _noise.exposure
end

-- CitizenService pushes, once a day, the share of households that had nowhere legal to
-- park and had to put the car in their pocket.
local PARKING_HAPPINESS_W = 0.15
local _parkingStats = { pocketedFraction = 0 }
function CityStatsService.setParkingStats(stats: any)
	if typeof(stats) ~= "table" then return end
	_parkingStats = { pocketedFraction = math.clamp(tonumber(stats.pocketedFraction) or 0, 0, 1) }
end

function CityStatsService.setTransitStats(stats: any)
	if typeof(stats) ~= "table" then return end
	_transitStats = { riders = math.max(0, tonumber(stats.riders) or 0) }
end

function CityStatsService.setBudgetStats(stats: any)
	if typeof(stats) ~= "table" then return end
	local dp = if typeof(stats.demandPenalty) == "table" then stats.demandPenalty else {}
	_budgetStats = {
		happinessPenalty = math.clamp(tonumber(stats.happinessPenalty) or 0, -1, 1),
		demandPenalty = {
			R = math.clamp(tonumber(dp.R) or 0, -1, 1),
			C = math.clamp(tonumber(dp.C) or 0, -1, 1),
			I = math.clamp(tonumber(dp.I) or 0, -1, 1),
		},
	}
end

function CityStatsService.tick()
	local filled = _buildingService.getFilledByLevel()
	local counts = _buildingService.getBuildingCounts()
	-- Straight headcount. Residential fill is per-household (1 = occupied), so
	-- capacityOf(filled.Residential, ...) would now read back as "every home holds a
	-- maximum-size family". Commercial/industrial fill is still per job slot.
	local population = _buildingService.getResidentCount()
	local jobsC = capacityOf(filled.Commercial, CAP.Commercial)
	local jobsI = capacityOf(filled.Industrial, CAP.Industrial)
	local jobs = jobsC + jobsI

	local maxPop = capacityOf(counts.Residential, CAP.Residential)
	-- Residential vacancy and shortage are measured in HOUSEHOLD SLOTS, not in people
	-- slots: a home fits householdCapFor(lot, level) families (1 for a small lot, up to
	-- 5 for a big one at level 3) and each of those is one fillable slot. Measured in
	-- PEOPLE instead, a city where every house had a family in it still read as 60-90%
	-- empty, which pinned the vacancy factor at full strength and held residential
	-- demand at zero permanently.
	local homes = if _buildingService.getHomeCensus then _buildingService.getHomeCensus() else nil
	local homesTotal    = if homes then homes.total else 0
	local homesOccupied = if homes then homes.occupied else 0

	local scale = math.max(SCALE_BASE, maxPop * SCALE_POP_FACTOR)

	local capC = capacityOf(counts.Commercial, CAP.Commercial)
	local capI = capacityOf(counts.Industrial, CAP.Industrial)
	local openJobs = math.max(0, capC + capI - jobs)
	local jobless = math.max(0, _workforce.totalAdults - _workforce.employed)
	local education = if _educationService and _educationService.getStats then _educationService.getStats() else nil
	local eduCoverage = if education then tonumber(education.coverage) or 1 else 1
	local eduEligible = if education then tonumber(education.eligible) or 0 else 0
	-- Real goods flow from the supply chain: industry produces `output`, shops need
	-- `need`; the signed gap is export surplus (+) or imports (-), normalized to [-1,1].
	local goodsOutput, goodsNeed = 0, 0
	if _supplyService and _supplyService.getStats then
		local supply = _supplyService.getStats()
		goodsOutput = math.max(0, tonumber(supply.output) or 0)
		goodsNeed   = math.max(0, tonumber(supply.need) or 0)
	end
	local goodsGap = (goodsOutput - goodsNeed) / math.max(goodsOutput, goodsNeed, 1)

	-- Demand = clamped sum of named factors, each a counted fact from the live sim.
	-- The factor tables ship to the client so the gauges can show WHY each demand
	-- sits where it does (CS2-style) and what the player can do about it. Reputation
	-- uses last tick's happiness (1 Hz lag is imperceptible). New-city head start:
	-- an empty map advertises max demand across R/C/I so the first zones of every
	-- kind grow immediately; fades over the first NEW_CITY_FADE_POP residents.
	local newCityBoost = math.max(0, 1 - population / NEW_CITY_FADE_POP)
	-- Scaled by (1 - newCityBoost) so the head start still lets a fresh map's first
	-- (necessarily empty) zones grow; vacancy phases in as the city fills out.
	local function vacancyPenalty(filledN: number, capN: number): number
		if capN <= 0 then return 0 end
		local vacant = math.max(0, capN - filledN) / capN
		local severity = math.min(1, math.max(0, vacant - VACANCY_TOL) / (VACANCY_FULL - VACANCY_TOL))
		return -severity * VACANCY_W * (1 - newCityBoost)
	end
	local function shortagePressure(filledN: number, capN: number): number
		if capN <= 0 then return 0 end
		local occupancy = filledN / capN
		return math.max(0, occupancy - SHORTAGE_START) / (1 - SHORTAGE_START) * SHORTAGE_W
	end
	_factors = {
		R = {
			boost        = newCityBoost,
			region       = REGION_W.R,
			jobs         = openJobs / scale,
			shortage     = shortagePressure(homesOccupied, homesTotal),
			unemployment = -math.min(1, jobless / scale) * UNEMPLOYMENT_R_W,
			reputation   = (_happiness - REPUTATION_BASE) * REPUTATION_R_W,
			transit      = math.min(1, _transitStats.riders / math.max(population, 1)) * TRANSIT_R_W,
			vacancy      = vacancyPenalty(homesOccupied, homesTotal),
			taxes        = -_budgetStats.demandPenalty.R,
		},
		C = {
			boost     = newCityBoost,
			region    = REGION_W.C,
			customers = (population * C_PER_POP - capC) / scale,
			goods     = goodsGap * GOODS_C_W,
			educated  = _workforce.overeducatedFraction * OVEREDUCATION_C_BOOST,
			shortage  = shortagePressure(jobsC, capC),
			vacancy   = vacancyPenalty(jobsC, capC),
			taxes     = -_budgetStats.demandPenalty.C,
		},
		I = {
			boost  = newCityBoost,
			region = REGION_W.I,
			orders = -goodsGap * ORDERS_I_W,
			labor  = jobless / scale * LABOR_I_W,
			shortage = shortagePressure(jobsI, capI),
			vacancy = vacancyPenalty(jobsI, capI),
			taxes  = -_budgetStats.demandPenalty.I,
		},
	}
	local function factorSum(t: { [string]: number }): number
		local s = 0
		for _, v in t do s += v end
		return s
	end
	_real.R = clamp1(factorSum(_factors.R))
	_real.C = clamp1(factorSum(_factors.C))
	_real.I = clamp1(factorSum(_factors.I))
	-- Move-in pull excludes the vacancy drag: empty homes are what arrivals move INTO
	-- (CS2: the bar gates construction, not movers). Letting vacancy choke arrivals
	-- froze a half-empty city solid -- no movers, so homes never filled.
	_moveInR = clamp1(factorSum(_factors.R) - _factors.R.vacancy)
	-- Sandbox city (chosen at creation, replicated on workspace): every zone advertises
	-- full demand, so anything the player paints fills up. One named factor so the
	-- gauge tooltip still explains itself.
	if workspace:GetAttribute("Sandbox") == true then
		_factors = { R = { sandbox = 1 }, C = { sandbox = 1 }, I = { sandbox = 1 } }
		_real.R, _real.C, _real.I = 1, 1, 1
		_moveInR = 1
	end
	local unemployment = if _workforce.totalAdults > 0 then 1 - _workforce.employed / _workforce.totalAdults else 0
	local crimePenalty     = (1 - _crimeStats.coverage) * 0.20
	local sicknessPenalty = _sicknessStats.sickFraction * 0.18
	local deathPenalty    = _deathcareStats.unburiedFraction * 0.25
	-- Homes a utility does not serve dent happiness. WaterService reports the share of homes
	-- its pools actually reach, and 1 while the city has built no tower or plant.
	local utilityPenalty = (1 - _waterStats.watered) * UTILITY_HAPPINESS_W.water
		+ (1 - _waterStats.drained) * UTILITY_HAPPINESS_W.sewage
	-- Power is a GRID, not a coverage radius, so its share of lit homes comes from
	-- PowerService rather than from a station's reach. It reports 1 while the city has no
	-- generator, so nothing is docked before the player has any way to supply it.
	utilityPenalty += (1 - _powerStats.covered) * UTILITY_HAPPINESS_W.power
	local happiness = math.clamp(0.72 + 0.28 * eduCoverage
		- 0.45 * _workforce.overeducatedFraction
		- 0.35 * unemployment
		- crimePenalty
		- sicknessPenalty
		- deathPenalty
		- utilityPenalty
		- NOISE_HAPPINESS_W * noiseExposure()
		- PARKING_HAPPINESS_W * _parkingStats.pocketedFraction
		- _budgetStats.happinessPenalty, 0, 1)
	_happiness = happiness

	_disp.R += (_real.R - _disp.R) * DISPLAY_LERP
	_disp.C += (_real.C - _disp.C) * DISPLAY_LERP
	_disp.I += (_real.I - _disp.I) * DISPLAY_LERP

	_population = population
	_jobs = jobs

	_lastPayload = {
		population = population,
		jobs = jobs,
		demand = { R = _disp.R, C = _disp.C, I = _disp.I },
		demandFactors = _factors,
		education = education,
		happiness = happiness,
		power = _powerStats,
		water = _waterStats,
		tickError = _lastTickError,
	}

	-- Only broadcast when something a client can observe actually changed. _disp
	-- eases toward _real, so once the city settles the demand stops moving and we
	-- stop broadcasting entirely -- removing a permanent 1 Hz fan-out to every
	-- client. A late joiner still gets the latest via the PlayerAdded send in
	-- Bind(); an active tick error is always sent so the debug overlay sees it.
	local eduAssigned = if education then tonumber(education.assigned) or 0 else 0
	local eduAttending = if education then tonumber(education.attending) or 0 else 0
	local eduCapacity = if education then tonumber(education.capacity) or 0 else 0
	local waterChanged = false
	for k, v in _waterStats do
		if _lastSentWater[k] ~= v then waterChanged = true; break end
	end
	local changed = _lastTickError ~= nil
		or population ~= _lastSent.pop
		or jobs ~= _lastSent.jobs
		or eduEligible ~= _lastSent.eduEligible
		or eduAssigned ~= _lastSent.eduAssigned
		or eduAttending ~= _lastSent.eduAttending
		or eduCapacity ~= _lastSent.eduCapacity
		or math.abs(eduCoverage - _lastSent.eduCoverage) > BROADCAST_EPS
		or math.abs(happiness - _lastSent.happiness) > BROADCAST_EPS
		or math.abs(_disp.R - _lastSent.R) > BROADCAST_EPS
		or math.abs(_disp.C - _lastSent.C) > BROADCAST_EPS
		or math.abs(_disp.I - _lastSent.I) > BROADCAST_EPS
		or _powerStats.production ~= _lastSentPower.production
		or _powerStats.consumption ~= _lastSentPower.consumption
		or _powerStats.imported ~= _lastSentPower.imported
		or _powerStats.exported ~= _lastSentPower.exported
		or waterChanged

	if changed then
		_lastSent.pop  = population
		_lastSent.jobs = jobs
		_lastSent.R, _lastSent.C, _lastSent.I = _disp.R, _disp.C, _disp.I
		_lastSent.eduEligible = eduEligible
		_lastSent.eduAssigned = eduAssigned
		_lastSent.eduAttending = eduAttending
		_lastSent.eduCapacity = eduCapacity
		_lastSent.eduCoverage = eduCoverage
		_lastSent.happiness = happiness
		_lastSentPower.production  = _powerStats.production
		_lastSentPower.consumption = _powerStats.consumption
		_lastSentPower.imported    = _powerStats.imported
		_lastSentPower.exported    = _powerStats.exported
		_lastSentWater = table.clone(_waterStats)
		_syncRemote:FireAllClients(_lastPayload)
	end
end

function CityStatsService.getPopulation(): number
	return _population
end

-- The sim (arrivals, upgrades, demand-gated construction) reads REAL demand. _disp is
-- only the eased value the HUD bars display -- handing it out here made every consumer
-- react tens of seconds late to what the city actually needed.
function CityStatsService.getDemand(): { R: number, C: number, I: number }
	return { R = _real.R, C = _real.C, I = _real.I }
end

-- How attractive the city is to NEW households (jobs, reputation, taxes), without
-- the vacancy drag. CitizenService scales its arrival rate with this.
function CityStatsService.getMoveInDemand(): number
	return _moveInR
end

function CityStatsService.Init(buildingService: any, educationService: any?, supplyService: any?, coverageService: any?)
	_buildingService = buildingService
	_educationService = educationService
	_supplyService = supplyService
	_coverage = coverageService

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_syncRemote = Net.SyncCityStats
end

function CityStatsService.Bind()
	Players.PlayerAdded:Connect(function(player: Player)
		if _lastPayload then
			_syncRemote:FireClient(player, _lastPayload)
		end
	end)
end

function CityStatsService.Start()
	if _running then return end

	_running = true

	task.spawn(function()
		while _running do
			local speed = math.clamp(tonumber(workspace:GetAttribute("GameSpeed")) or 1, 0, 3)

			task.wait(TICK / math.max(1, speed))

			if speed <= 0 then continue end

			local ok, err = pcall(CityStatsService.tick)

			if not ok then
				_lastTickError = tostring(err)
				warn("[CityStatsService] tick failed: " .. _lastTickError)
			else
				_lastTickError = nil
			end
		end
	end)
end

return CityStatsService