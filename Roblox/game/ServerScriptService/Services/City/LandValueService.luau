--!strict

-- Owns land value at a point. Computes LV from coverage, pollution, noise, road
-- access and per-zone weights/gates. Hybrid model: if any hard gate fails LV is
-- 0; otherwise LV = clamp(LV_BASE + weighted bonus).
--
-- Phase A: LV is computed on demand (no caching). The only consumer is the sim,
-- which evaluates the handful of existing buildings each tick. Per-lot caching
-- with dirty tracking is a Phase C concern (overlays need every lot).
--
-- Gates (locked design):
--   Residential: road + power + water
--   Commercial:  road + power + water (+ nearby customers, deferred)
--   Industrial:  road + power
-- Service gates use CoverageService.getCoverageAt, which is stubbed to 1.0 in
-- Phase A, so they pass until Phase B places real services.

local Const = require(script.Parent.CitySimConstants)

local LandValueService = {}

export type Evaluation = {
	lv        : number,
	gatesPass : boolean,
	pollution : number,
	noise     : number,
}

local _coverage : any
local _education : any

local EDU_LV_BONUS = 0.2 -- nearby-school land-value lift, scaled by the best covering tier

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

local function gatesPassFor(zone: string, pos: Vector3): boolean
	-- Road access: a plot only exists alongside a road, so any real plot has it.
	local power = _coverage.getCoverageAt(pos, "power") > 0

	if zone == "Industrial" then
		return power
	end

	local water = _coverage.getCoverageAt(pos, "water") > 0
	return power and water
end

local function coverageStrength(pos: Vector3): number
	-- Average of the gating services; feeds the LV bonus.
	local power = _coverage.getCoverageAt(pos, "power")
	local water = _coverage.getCoverageAt(pos, "water")
	return (power + water) * 0.5
end

-- 0..1 land-value lift from the best school tier covering this point (uni > high > elementary).
local function educationStrength(pos: Vector3): number
	if not _education or not _education.coversTier then return 0 end
	for tier = 3, 1, -1 do
		if _education.coversTier(pos, tier) then return tier / 3 end
	end
	return 0
end

local function evaluateAt(zone: string, pos: Vector3): Evaluation
	local weights = Const.LV_WEIGHTS[zone]
	if not weights or not gatesPassFor(zone, pos) then
		return {
			lv = 0,
			gatesPass = false,
			pollution = _coverage.getPollutionAt(pos),
			noise = _coverage.getNoiseAt(pos),
		}
	end

	local pollution = _coverage.getPollutionAt(pos)
	local noise     = _coverage.getNoiseAt(pos)
	local services  = coverageStrength(pos)

	local bonus = weights.services * services
		+ weights.road * 1 -- road access guaranteed for a real plot
		+ EDU_LV_BONUS * educationStrength(pos)
		- weights.pollution * pollution
		- weights.noise * noise

	return {
		lv = clamp01(Const.LV_BASE + bonus),
		gatesPass = true,
		pollution = pollution,
		noise = noise,
	}
end

-- Public ------------------------------------------------------------------

-- Land value at an arbitrary world point.
function LandValueService.getLandValueAt(zone: string, pos: Vector3): number
	return evaluateAt(zone, pos).lv
end

-- Building-level evaluation, sampled at the plot pivot BuildingService.listBuildings
-- reports. The sim uses this.
function LandValueService.evaluateBuilding(view: { zone: string, position: Vector3? }): Evaluation
	local center = view.position
	if not center then
		return { lv = 0, gatesPass = false, pollution = 0, noise = 0 }
	end
	return evaluateAt(view.zone, center)
end

function LandValueService.Init(coverageService: any, educationService: any?)
	_coverage = coverageService
	_education = educationService
end

function LandValueService.Bind() end

function LandValueService.Start() end

return LandValueService
