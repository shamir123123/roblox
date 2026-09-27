--!strict
-- CityEconomyService
-- Owns the city treasury and the product economy. Industry produces goods,
-- commerce consumes them; locally-supplied goods earn a margin while any
-- shortfall is imported at a higher per-unit cost (the user's "imports cost more
-- money"). Ticks at 1 Hz (GameSpeed-scaled), reads filled capacity from
-- BuildingService and population from CityStatsService, updates the treasury, and
-- broadcasts the breakdown to clients. Treasury persists with the city slot.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Const = require(script.Parent.Parent.CitySimConstants)
local NetMiddleware = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local Telemetry = require(script.Parent.Parent.Parent.Util.Telemetry)

local CityEconomyService = {}

-- PowerService (optional): meters electricity bought from and sold to the outside world.
-- Injected in Bootstrap -- it boots after the economy, and an unwired economy simply
-- reports no trade rather than failing.
local _powerService: any
function CityEconomyService.setPowerService(svc: any)
	_powerService = svc
end

-- TerritoryService.getMonthlyUpkeep (optional, injected in Bootstrap): the land line.
local _landUpkeep: (() -> number)? = nil
function CityEconomyService.setLandUpkeep(fn: (() -> number)?)
	_landUpkeep = fn
end

local CAP = table.freeze({
	Commercial = table.freeze({ 3, 7, 14 }),
	Industrial = table.freeze({ 5, 11, 20 }),
})

local TICK = 1.0

-- Sandbox cities (chosen at creation, replicated on workspace) run with the treasury
-- pinned here: every affordability check downstream passes, nothing goes bankrupt, and
-- the HUD swaps the figure for an infinity glyph. Not math.huge -- that would poison
-- the budget arithmetic and the save blob.
local SANDBOX_TREASURY = 1e9

local function isSandbox(): boolean
	return workspace:GetAttribute("Sandbox") == true
end

-- The treasury changes by `net` every tick (1 tick = 1s at 1x). The HUD shows a
-- steady MONTHLY rate instead of this per-second figure. The calendar lives in
-- CitySimConstants (DAY_SECONDS x DAYS_PER_MONTH), shared with TimeService.
local MONTHLY_TICKS = Const.MONTH_TICKS

local _buildingService: any
local _cityStatsService: any
local _supplyService: any
local _roadService: any
local _emergencyService: any
local _educationService: any
local _citizenService: any
local _transitService: any
local _syncRemote: RemoteEvent
local _notifyRemote: RemoteEvent
local _bankruptRemote: RemoteEvent
local _setBudgetRemote: RemoteEvent
local _treasury = Const.ECON_START_TREASURY
local _running = false
local _lastPayload: any = nil
local _lastSupplyRatio = 1

-- Player-adjustable tax rates (percent). Persisted with the city slot. _tax is the per-zone
-- MASTER rate; the override tables fine-tune individual subtypes (nil entry = use master).
-- Residential is taxed by education level (0-3 = income brackets); commercial/industrial by
-- product type.
local _tax = { R = Const.TAX_DEFAULT_RATE, C = Const.TAX_DEFAULT_RATE, I = Const.TAX_DEFAULT_RATE }
local _taxResBracket: { [number]: number } = {}
local _taxCommProduct: { [string]: number } = {}
local _taxIndProduct: { [string]: number } = {}

-- Road upkeep is cached and only recomputed when the road network changes.
local _roadMetersCache = 0
local _roadUpkeepCache = 0
local _roadMetersDirty = true

-- Bankruptcy state. _redTicks counts consecutive ticks below the debt floor.
local _bankrupt = false
local _redTicks = 0
local _debtWarnTick = 0

local BUDGET_COOLDOWN = 0.2
local _lastBudgetAt: { [Player]: number } = {}

-- Per-service funding (percent). Raising a category widens its coverage / capacity /
-- vehicle count AND scales its upkeep cost by the same factor.
local _funding = {
	Police = Const.FUNDING_DEFAULT_PCT,
	Fire = Const.FUNDING_DEFAULT_PCT,
	Health = Const.FUNDING_DEFAULT_PCT,
	Education = Const.FUNDING_DEFAULT_PCT,
}

-- Retail (shop) income accrues from citizen purchases between ticks; drained each
-- tick so the budget panel can show it as its own line. Retail + export are bursty,
-- so the displayed monthly figures use an EMA while the treasury accrues the raw amount.
local _retailAccum = 0
local _retailEMA = 0
local _exportEMA = 0
local _fareEMA = 0
-- Display smoothing: every monthly figure shown to the player is a slow EMA so the
-- panel reads as a steady estimate instead of flickering each tick. Treasury still
-- accrues the raw per-tick amount; only the DISPLAY is smoothed.
local EMA_ALPHA = 0.02
local _emaTaxRes = 0
local _emaTaxComm = 0
local _emaTaxInd = 0

-- Loans: a borrowed balance that accrues monthly interest (added to expenses).
local _loanPrincipal = 0

local function capacityOf(byLevel: { number }, cap: { number }): number
	local total = 0
	for level = 1, #cap do
		total += (byLevel[level] or 0) * cap[level]
	end
	return total
end

local function clampRate(r: any): number
	return math.clamp(math.floor((tonumber(r) or Const.TAX_DEFAULT_RATE) + 0.5), Const.TAX_MIN_RATE, Const.TAX_MAX_RATE)
end

local function clampFunding(v: any): number
	return math.clamp(math.floor((tonumber(v) or Const.FUNDING_DEFAULT_PCT) + 0.5), Const.FUNDING_MIN_PCT, Const.FUNDING_MAX_PCT)
end

local function canEdit(player: Player): boolean
	if workspace:GetAttribute("RoadEditOpen") == true then return true end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

-- Monthly running costs, itemised. Roads by the metre; each service category costs a
-- fraction of its building stock's build price, scaled by that category's funding.
-- Road length is cached (refreshed on topology change).
local function monthlyUpkeep(): { [string]: number }
	if _roadMetersDirty and _roadService then
		if _roadService.getMonthlyRoadUpkeep then
			local ok, v = pcall(_roadService.getMonthlyRoadUpkeep)
			if ok then _roadUpkeepCache = v; _roadMetersDirty = false end
		elseif _roadService.getTotalRoadLengthMeters then
			local ok, m = pcall(_roadService.getTotalRoadLengthMeters)
			if ok then _roadMetersCache = m; _roadUpkeepCache = m * Const.UPKEEP_ROAD_PER_METER; _roadMetersDirty = false end
		end
	end
	local frac = Const.UPKEEP_SERVICE_FRACTION
	local byKind = (_emergencyService and _emergencyService.getServiceCostByKind and _emergencyService.getServiceCostByKind()) or {}
	local eduCost = (_educationService and _educationService.getServiceCostTotal and _educationService.getServiceCostTotal()) or 0
	local road = _roadUpkeepCache
	local police = (byKind.Police or 0) * frac * (_funding.Police / 100)
	local fire   = (byKind.Fire or 0) * frac * (_funding.Fire / 100)
	local health = (byKind.Hospital or 0) * frac * (_funding.Health / 100)
	local education = eduCost * frac * (_funding.Education / 100)
	-- Transit upkeep: depot upkeep + per-bus running cost (TransitService owns the figure).
	local transit = (_transitService and _transitService.getMonthlyUpkeep and _transitService.getMonthlyUpkeep()) or 0
	-- Electricity bought from outside the city. Not a funding category: it is metered, and
	-- the way to cut it is to build generation rather than to move a slider.
	local power = 0
	if _powerService and _powerService.getTradeMonthly then
		power = (select(1, _powerService.getTradeMonthly()))
	end
	-- Utilities: generators, water, sewage, deathcare. EmergencyService already collects
	-- their build cost by kind -- the economy simply never charged for any of it.
	local ufrac = Const.UPKEEP_UTILITY_FRACTION
	local utilities = ((byKind.Power or 0) + (byKind.Water or 0) + (byKind.Sewage or 0)
		+ (byKind.Deathcare or 0)) * ufrac
	-- Power lines: PowerService owns the poles, so they never appear in byKind.
	local poles = 0
	if _powerService and _powerService.getPoleCount then
		local ok, n = pcall(_powerService.getPoleCount)
		if ok then poles = (tonumber(n) or 0) * Const.UPKEEP_POLE_EACH end
	end
	-- Bought map tiles.
	local land = 0
	if _landUpkeep then
		local ok, v = pcall(_landUpkeep)
		if ok then land = tonumber(v) or 0 end
	end
	-- Zoned buildings: a small standing cost each, by level.
	local buildings = 0
	if _buildingService and _buildingService.getBuildingCounts then
		local ok, counts = pcall(_buildingService.getBuildingCounts)
		if ok and type(counts) == "table" then
			local perLevel = Const.UPKEEP_ZONED_BY_LEVEL
			for _, byLevel in counts do
				if type(byLevel) == "table" then
					for level, n in byLevel do
						buildings += (tonumber(n) or 0) * (perLevel[level] or 0)
					end
				end
			end
		end
	end
	return {
		road = road, police = police, fire = fire, health = health, education = education,
		transit = transit, power = power,
		utilities = utilities, poles = poles, buildings = buildings, land = land,
		total = road + police + fire + health + education + transit + power
			+ utilities + poles + buildings + land,
	}
end

local function notify(text: string, kind: string)
	if _notifyRemote then _notifyRemote:FireAllClients({ text = text, kind = kind }) end
end

local function declareBankruptcy()
	if _bankrupt then return end
	_bankrupt = true
	workspace:SetAttribute("Bankrupt", true)
	workspace:SetAttribute("GameSpeed", 0) -- freeze the whole simulation
	local population = 0
	pcall(function() population = _cityStatsService.getPopulation() end)
	if _bankruptRemote then
		_bankruptRemote:FireAllClients({ money = math.floor(_treasury + 0.5), population = population })
	end
	notify("\u{1F4B8} Your city has gone bankrupt!", "danger")
	Telemetry.custom("CityBankrupt", population)
end

function CityEconomyService.tick()
	if _bankrupt then return end
	if isSandbox() then _treasury = SANDBOX_TREASURY end

	local filled = _buildingService.getFilledByLevel()
	local population = _cityStatsService.getPopulation()

	local filledC = capacityOf(filled.Commercial, CAP.Commercial)
	local filledI = capacityOf(filled.Industrial, CAP.Industrial)

	-- Tax income, split by zone. RES/COMM/IND_TAX are the yield at the default rate;
	-- actual income scales linearly with the chosen rate.
	local rf = 1 / Const.TAX_DEFAULT_RATE

	-- Residential: tax each education bracket (income bracket) by its own rate (override or
	-- the master residential rate). Population is split across brackets by the adult mix.
	local edu = (_citizenService and _citizenService.getEducationBreakdown and _citizenService.getEducationBreakdown())
		or { counts = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }, total = 0 }
	local resBracket = {}
	local taxRes = 0
	for lvl = 0, 3 do
		local frac = if edu.total > 0 then (edu.counts[lvl] or 0) / edu.total elseif lvl == 0 then 1 else 0
		local residents = population * frac
		local rate = _taxResBracket[lvl] or _tax.R
		local inc = residents * Const.RES_TAX * (rate * rf)
		taxRes += inc
		-- Array (not a 0-indexed dict) so the [0] Uneducated bracket survives the remote.
		resBracket[#resBracket + 1] = { key = lvl, rate = rate, income = inc * MONTHLY_TICKS, units = math.floor(residents + 0.5) }
	end

	-- Commercial + Industrial: bucket filled capacity by product, tax each product by its
	-- own rate (override or master).
	local ciFill = (_buildingService.getCommercialIndustrialFill and _buildingService.getCommercialIndustrialFill()) or {}
	local commFilled, indFilled = {}, {}
	for _, b in ciFill do
		local capList = if b.zone == "Industrial" then CAP.Industrial else CAP.Commercial
		local cap = capList[math.clamp(b.level, 1, #capList)] or 0
		local filled = (b.fill or 0) * cap
		if filled <= 0 then continue end
		local product = (_supplyService.productOf and _supplyService.productOf(b.bpId, b.zone)) or "Other"
		local bucket = if b.zone == "Industrial" then indFilled else commFilled
		bucket[product] = (bucket[product] or 0) + filled
	end

	local taxComm, commProd = 0, {}
	for _, product in Const.SUPPLY_COMMERCIAL_PRODUCTS do
		local filled = commFilled[product] or 0
		local rate = _taxCommProduct[product] or _tax.C
		local inc = filled * Const.COMM_TAX * (rate * rf)
		taxComm += inc
		commProd[#commProd + 1] = { key = product, rate = rate, income = inc * MONTHLY_TICKS, units = math.floor(filled + 0.5) }
	end

	local taxInd, indProd = 0, {}
	for _, product in Const.SUPPLY_INDUSTRIAL_PRODUCTS do
		local filled = indFilled[product] or 0
		local rate = _taxIndProduct[product] or _tax.I
		local inc = filled * Const.IND_TAX * (rate * rf)
		taxInd += inc
		indProd[#indProd + 1] = { key = product, rate = rate, income = inc * MONTHLY_TICKS, units = math.floor(filled + 0.5) }
	end

	local taxRevenue = taxRes + taxComm + taxInd

	-- Realised supply-chain income: retail (citizen purchases, accumulated) + export surplus.
	local retailIncome = _retailAccum
	_retailAccum = 0
	local exportIncome = _supplyService.drainGoodsRevenue()
	-- Bus fares booked since the last tick (riders x per-route fare, TransitService).
	local fareIncome = (_transitService and _transitService.drainFareRevenue and _transitService.drainFareRevenue()) or 0
	-- Surplus electricity sold out of the city through a map-edge pole. Monthly figure
	-- from PowerService, taken per tick like every other income line here.
	local powerExportMonthly = 0
	if _powerService and _powerService.getTradeMonthly then
		powerExportMonthly = (select(2, _powerService.getTradeMonthly()))
	end
	local powerIncome = powerExportMonthly / MONTHLY_TICKS
	local supply = _supplyService.getStats()
	_lastSupplyRatio = supply.supplyRatio

	-- Itemised running costs + loan interest.
	local up = monthlyUpkeep()
	local monthlyInterest = _loanPrincipal * (Const.LOAN_ANNUAL_RATE / 12)
	local upkeepPerTick = up.total / MONTHLY_TICKS
	local interestPerTick = monthlyInterest / MONTHLY_TICKS
	local grossIncome = taxRevenue + retailIncome + exportIncome + fareIncome + powerIncome
	local net = grossIncome - upkeepPerTick - interestPerTick

	_treasury += net

	-- Slow-EMA every component so the displayed monthly figures are a steady estimate.
	_emaTaxRes += (taxRes - _emaTaxRes) * EMA_ALPHA
	_emaTaxComm += (taxComm - _emaTaxComm) * EMA_ALPHA
	_emaTaxInd += (taxInd - _emaTaxInd) * EMA_ALPHA
	_retailEMA += (retailIncome - _retailEMA) * EMA_ALPHA
	_exportEMA += (exportIncome - _exportEMA) * EMA_ALPHA
	_fareEMA += (fareIncome - _fareEMA) * EMA_ALPHA
	local dispGross = _emaTaxRes + _emaTaxComm + _emaTaxInd + _retailEMA + _exportEMA + _fareEMA
	local dispNet = dispGross - upkeepPerTick - interestPerTick

	-- High taxes (above the comfort rate) dent happiness and per-zone demand.
	-- Low taxes (below the default rate) give a small bonus instead — a negative
	-- penalty downstream — capped so cheap taxes never carry a city on their own.
	-- Between default and comfort the effect is zero.
	local function over(rate: number): number
		return math.max(0, rate - Const.TAX_COMFORT_RATE) + math.min(0, rate - Const.TAX_DEFAULT_RATE)
	end
	local function capBonus(v: number): number return math.max(v, -Const.TAX_LOW_BONUS_MAX) end
	_cityStatsService.setBudgetStats({
		happinessPenalty = capBonus((over(_tax.R) + over(_tax.C) + over(_tax.I)) / 3 * Const.TAX_HAPPINESS_PER_PCT),
		demandPenalty = {
			R = capBonus(over(_tax.R) * Const.TAX_DEMAND_PER_PCT),
			C = capBonus(over(_tax.C) * Const.TAX_DEMAND_PER_PCT),
			I = capBonus(over(_tax.I) * Const.TAX_DEMAND_PER_PCT),
		},
	})

	-- Bankruptcy watch: warn while in debt; declare game-over after the grace
	-- period below the debt floor.
	if _treasury < Const.BANKRUPTCY_DEBT_FLOOR then
		_redTicks += 1
		if _redTicks % Const.BANKRUPTCY_WARN_EVERY == 0 then
			notify("\u{26A0} Bankruptcy imminent -- fix your finances now!", "danger")
		end
		if _redTicks >= Const.BANKRUPTCY_GRACE_TICKS then
			declareBankruptcy()
		end
	elseif _treasury < 0 then
		_redTicks = 0
		_debtWarnTick += 1
		if _debtWarnTick % Const.BANKRUPTCY_WARN_EVERY == 0 then
			notify("\u{1F4C9} Treasury in the red -- raise taxes or cut spending.", "warning")
		end
	else
		_redTicks = 0
		_debtWarnTick = 0
	end

	_lastPayload = {
		money = math.floor(_treasury + 0.5),
		net = net,
		monthlyNet = dispNet * MONTHLY_TICKS,
		revenue = dispGross,
		monthlyIncome = dispGross * MONTHLY_TICKS,
		monthlyUpkeep = up.total,
		-- income breakdown (monthly)
		taxResidential = _emaTaxRes * MONTHLY_TICKS,
		taxCommercial = _emaTaxComm * MONTHLY_TICKS,
		taxIndustrial = _emaTaxInd * MONTHLY_TICKS,
		retailIncome = _retailEMA * MONTHLY_TICKS,
		exportIncome = _exportEMA * MONTHLY_TICKS,
		fareIncome = _fareEMA * MONTHLY_TICKS,
		powerIncome = powerExportMonthly,
		-- expense breakdown (monthly)
		upkeepRoads = up.road,
		upkeepPolice = up.police,
		upkeepFire = up.fire,
		upkeepHealth = up.health,
		upkeepEducation = up.education,
		upkeepTransit = up.transit,
		upkeepPower = up.power,
		upkeepUtilities = up.utilities,
		upkeepPoles = up.poles,
		upkeepBuildings = up.buildings,
		upkeepLand = up.land,
		-- loans
		loanInterest = monthlyInterest,
		loanPrincipal = _loanPrincipal,
		loanLimit = Const.LOAN_BASE_LIMIT + population * Const.LOAN_LIMIT_PER_POP,
		loanAnnualRate = Const.LOAN_ANNUAL_RATE,
		-- legacy fields kept for older consumers
		upkeep = upkeepPerTick,
		importCost = 0,
		output = supply.output,
		need = supply.need,
		imported = 0,
		supplyRatio = supply.supplyRatio,
		taxRates = { R = _tax.R, C = _tax.C, I = _tax.I },
		taxBreakdown = { residential = resBracket, commercial = commProd, industrial = indProd },
		funding = { Police = _funding.Police, Fire = _funding.Fire, Health = _funding.Health, Education = _funding.Education },
		bankrupt = _bankrupt,
	}
	_syncRemote:FireAllClients(_lastPayload)
end

function CityEconomyService.getTreasury(): number
	return _treasury
end

function CityEconomyService.getSupplyRatio(): number
	return _lastSupplyRatio
end

function CityEconomyService.setTaxRates(r: any, c: any, i: any)
	_tax.R = clampRate(r)
	_tax.C = clampRate(c)
	_tax.I = clampRate(i)
end

function CityEconomyService.getTaxRates(): { R: number, C: number, I: number }
	return { R = _tax.R, C = _tax.C, I = _tax.I }
end

-- Set a zone's MASTER rate, which also snaps every subtype in that zone to it (the
-- collapsed slider moves all brackets/products together). Individual overrides set
-- afterwards diverge again until the master is moved next.
function CityEconomyService.setZoneMaster(field: string, value: any)
	local r = clampRate(value)
	if field == "R" then
		_tax.R = r
		for lvl = 0, 3 do _taxResBracket[lvl] = r end
	elseif field == "C" then
		_tax.C = r
		for _, p in Const.SUPPLY_COMMERCIAL_PRODUCTS do _taxCommProduct[p] = r end
	elseif field == "I" then
		_tax.I = r
		for _, p in Const.SUPPLY_INDUSTRIAL_PRODUCTS do _taxIndProduct[p] = r end
	end
end

-- Per-subtype rate overrides. `res` keyed by education level (0-3), `comm`/`ind` by product.
function CityEconomyService.setTaxSubtypes(res: any, comm: any, ind: any)
	if typeof(res) == "table" then
		for k, v in res do
			local lvl = tonumber(k)
			if lvl and typeof(v) == "number" and v == v then _taxResBracket[math.clamp(math.floor(lvl), 0, 3)] = clampRate(v) end
		end
	end
	if typeof(comm) == "table" then
		for product, v in comm do
			if typeof(product) == "string" and typeof(v) == "number" and v == v then _taxCommProduct[product] = clampRate(v) end
		end
	end
	if typeof(ind) == "table" then
		for product, v in ind do
			if typeof(product) == "string" and typeof(v) == "number" and v == v then _taxIndProduct[product] = clampRate(v) end
		end
	end
end

function CityEconomyService.isBankrupt(): boolean
	return _bankrupt
end

-- Funding multiplier (e.g. 1.5 at 150%) for a service category. Services read this to
-- scale coverage radius / capacity / vehicle count. Unknown category -> 1.
-- Development Tree EXTRAS multiplier (ProgressionService.getFundingBoost), injected by
-- Bootstrap. Deliberately applied HERE and not to the upkeep sums above: a DP upgrade
-- makes a service reach further and field more vehicles, it does not raise the bill.
-- getFundingLevels (what the budget UI shows) stays the raw player-set percentage.
local _fundingBoost: ((string) -> number)? = nil

function CityEconomyService.setFundingBoost(fn: ((string) -> number)?)
	_fundingBoost = fn
end

function CityEconomyService.getFunding(category: string): number
	local base = (_funding[category] or Const.FUNDING_DEFAULT_PCT) / 100
	local boost = _fundingBoost
	return if boost then base * boost(category) else base
end

function CityEconomyService.getFundingLevels(): { [string]: number }
	return { Police = _funding.Police, Fire = _funding.Fire, Health = _funding.Health, Education = _funding.Education }
end

function CityEconomyService.setFunding(levels: any)
	if typeof(levels) ~= "table" then return end
	if levels.Police ~= nil then _funding.Police = clampFunding(levels.Police) end
	if levels.Fire ~= nil then _funding.Fire = clampFunding(levels.Fire) end
	if levels.Health ~= nil then _funding.Health = clampFunding(levels.Health) end
	if levels.Education ~= nil then _funding.Education = clampFunding(levels.Education) end
end

-- Retail income from a citizen shop purchase; accumulated and drained by the tick.
function CityEconomyService.addRetailIncome(amount: number)
	if typeof(amount) == "number" and amount == amount then
		_retailAccum += math.max(0, amount)
	end
end

local function loanLimit(): number
	local population = 0
	pcall(function() population = _cityStatsService.getPopulation() end)
	return Const.LOAN_BASE_LIMIT + population * Const.LOAN_LIMIT_PER_POP
end

function CityEconomyService.getLoanInfo(): { [string]: number }
	return {
		principal = _loanPrincipal,
		limit = loanLimit(),
		annualRate = Const.LOAN_ANNUAL_RATE,
		monthlyCost = _loanPrincipal * (Const.LOAN_ANNUAL_RATE / 12),
	}
end

-- Set the loan balance to `target` (clamped to [0, limit]). Borrowing pays cash into
-- the treasury now; repaying takes it back out (only as much as can be afforded).
function CityEconomyService.setLoan(target: any)
	if typeof(target) ~= "number" or target ~= target then return end
	target = math.clamp(math.floor(target + 0.5), 0, loanLimit())
	local diff = target - _loanPrincipal
	if diff > 0 then
		_loanPrincipal += diff
		_treasury += diff
	elseif diff < 0 then
		local repay = math.min(-diff, math.max(0, _treasury))
		_loanPrincipal -= repay
		_treasury -= repay
	end
end

-- Spend/earn hook for other systems (e.g. build costs later). Returns false if
-- the city cannot afford a positive spend.
function CityEconomyService.trySpend(amount: number): boolean
	if isSandbox() then return true end
	if amount > 0 and _treasury < amount then return false end
	_treasury -= amount
	return true
end

function CityEconomyService.credit(amount: number)
	_treasury += amount
end

function CityEconomyService.serialize(): { [string]: any }
	return {
		treasury = _treasury,
		loan = _loanPrincipal,
		tax = { R = _tax.R, C = _tax.C, I = _tax.I },
		taxRes = _taxResBracket,
		taxComm = _taxCommProduct,
		taxInd = _taxIndProduct,
		funding = { Police = _funding.Police, Fire = _funding.Fire, Health = _funding.Health, Education = _funding.Education },
	}
end

function CityEconomyService.restore(blob: any)
	-- A reload always clears bankruptcy and re-arms the upkeep cache.
	_bankrupt = false
	_redTicks = 0
	_debtWarnTick = 0
	_roadMetersDirty = true
	_retailAccum = 0
	_retailEMA = 0
	_exportEMA = 0
	_fareEMA = 0
	_emaTaxRes = 0
	_emaTaxComm = 0
	_emaTaxInd = 0
	_loanPrincipal = 0
	workspace:SetAttribute("Bankrupt", false)

	if typeof(blob) == "table" and typeof(blob.treasury) == "number" then
		_treasury = blob.treasury
	else
		_treasury = Const.ECON_START_TREASURY
	end

	local t = if typeof(blob) == "table" then blob.tax else nil
	if typeof(t) == "table" then
		_tax.R = clampRate(t.R)
		_tax.C = clampRate(t.C)
		_tax.I = clampRate(t.I)
	else
		_tax.R, _tax.C, _tax.I = Const.TAX_DEFAULT_RATE, Const.TAX_DEFAULT_RATE, Const.TAX_DEFAULT_RATE
	end

	-- Per-subtype overrides (number keys arrive as strings from the DataStore).
	_taxResBracket = {}
	_taxCommProduct = {}
	_taxIndProduct = {}
	local br = if typeof(blob) == "table" then blob.taxRes else nil
	if typeof(br) == "table" then
		for k, v in br do
			local lvl = tonumber(k)
			if lvl and tonumber(v) then _taxResBracket[math.clamp(math.floor(lvl), 0, 3)] = clampRate(v) end
		end
	end
	local bc = if typeof(blob) == "table" then blob.taxComm else nil
	if typeof(bc) == "table" then
		for p, v in bc do
			if typeof(p) == "string" and tonumber(v) then _taxCommProduct[p] = clampRate(v) end
		end
	end
	local bi = if typeof(blob) == "table" then blob.taxInd else nil
	if typeof(bi) == "table" then
		for p, v in bi do
			if typeof(p) == "string" and tonumber(v) then _taxIndProduct[p] = clampRate(v) end
		end
	end

	local f = if typeof(blob) == "table" then blob.funding else nil
	if typeof(f) == "table" then
		CityEconomyService.setFunding(f)
	else
		_funding.Police, _funding.Fire, _funding.Health, _funding.Education =
			Const.FUNDING_DEFAULT_PCT, Const.FUNDING_DEFAULT_PCT, Const.FUNDING_DEFAULT_PCT, Const.FUNDING_DEFAULT_PCT
	end

	if typeof(blob) == "table" and typeof(blob.loan) == "number" then
		_loanPrincipal = math.max(0, blob.loan)
	end

	-- One-time mercy: a city reloaded already past the debt floor would re-bankrupt
	-- on the first tick. Give it a $0 fresh start so the slot stays recoverable.
	if _treasury < Const.BANKRUPTCY_DEBT_FLOOR then _treasury = 0 end
end

-- Public transit (fares as income, depot/bus upkeep as cost). Injected in Bootstrap
-- after TransitService exists. Optional: the economy runs fine if it is never set.
function CityEconomyService.SetTransitService(ts: any)
	_transitService = ts
end

function CityEconomyService.Init(buildingService: any, cityStatsService: any, supplyService: any, roadService: any?, emergencyService: any?, educationService: any?, citizenService: any?)
	assert(buildingService and cityStatsService and supplyService, "[CityEconomyService] requires BuildingService + CityStatsService + SupplyService")
	_buildingService = buildingService
	_cityStatsService = cityStatsService
	_supplyService = supplyService
	_roadService = roadService
	_emergencyService = emergencyService
	_educationService = educationService
	_citizenService = citizenService

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_syncRemote = Net.SyncEconomy
	_notifyRemote = Net.Notify
	_bankruptRemote = Net.Bankruptcy
	_setBudgetRemote = Net.RequestSetBudget

	-- Road upkeep is cached; flag a refresh whenever the road network changes.
	if roadService and roadService.onTopologyChanged then
		roadService.onTopologyChanged(function() _roadMetersDirty = true end)
	end
end

function CityEconomyService.Bind()
	Players.PlayerAdded:Connect(function(player: Player)
		if _lastPayload then
			_syncRemote:FireClient(player, _lastPayload)
		end
	end)

	if _setBudgetRemote then
		_setBudgetRemote.OnServerEvent:Connect(function(player: Player, payload: any)
			if not canEdit(player) then return end
			local now = os.clock()
			if now - (_lastBudgetAt[player] or 0) < BUDGET_COOLDOWN then return end
			_lastBudgetAt[player] = now
			if typeof(payload) ~= "table" then return end
			-- Granular: each control sends only the field it changed, so moving funding never
			-- wipes per-subtype tax overrides. A master field snaps all its subtypes.
			if typeof(payload.R) == "number" and payload.R == payload.R then CityEconomyService.setZoneMaster("R", payload.R) end
			if typeof(payload.C) == "number" and payload.C == payload.C then CityEconomyService.setZoneMaster("C", payload.C) end
			if typeof(payload.I) == "number" and payload.I == payload.I then CityEconomyService.setZoneMaster("I", payload.I) end
			if typeof(payload.res) == "table" or typeof(payload.comm) == "table" or typeof(payload.ind) == "table" then
				CityEconomyService.setTaxSubtypes(payload.res, payload.comm, payload.ind)
			end
			if typeof(payload.funding) == "table" then
				CityEconomyService.setFunding(payload.funding)
			end
			if typeof(payload.loan) == "number" and payload.loan == payload.loan then
				CityEconomyService.setLoan(payload.loan)
			end
		end)
	end

	Players.PlayerRemoving:Connect(function(p: Player) _lastBudgetAt[p] = nil end)
end

function CityEconomyService.Start()
	if _running then return end
	_running = true
	task.spawn(function()
		while _running do
			local speed = math.clamp(tonumber(workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
			task.wait(TICK / math.max(1, speed))
			if speed <= 0 then continue end
			local ok, err = pcall(CityEconomyService.tick)
			if not ok then
				warn("[CityEconomyService] tick failed: " .. tostring(err))
			end
		end
	end)
end

return CityEconomyService
