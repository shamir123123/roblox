--!strict
-- TrafficViolations
-- What a driver can be booked for, how much each one stings, and whether the
-- active region books it at all. Pure library -- no state, no lifecycle, no side
-- effects on require. RegionCatalog says what the rules ARE; this says what
-- happens when one is broken.
--
-- The weights are a GAME BALANCE curve, not a fine schedule. They are ordered by
-- how dangerous the act is to everyone else, which is roughly -- not exactly --
-- how real jurisdictions rank them. Tune them freely; they mean nothing legally.

local RegionCatalog = require(script.Parent.RegionCatalog)

type RegionRuleset = RegionCatalog.RegionRuleset

local TrafficViolations = {}

export type Violation =
	  "SchoolBusPassed" | "DrinkDriving" | "RecklessDriving" | "RailroadGateRun"
	| "EmergencyLaneBlocked" | "MoveOverFailure" | "RedLightRun" | "SpeedOver20"
	| "FailToYieldPedestrian" | "IllegalRightOnRed" | "RoundaboutFailToYield"
	| "SpeedOver10" | "IllegalUTurn" | "IllegalLaneSplitting" | "TractionLawViolation"
	| "HandheldPhone" | "LeftLaneCamping" | "NoSeatbelt" | "NoHelmet"
	| "ParkingViolation" | "MissingFrontPlate"

-- Base weight per violation. Multiplied by the region's penaltySeverity dial.
local WEIGHTS: { [string]: number } = table.freeze({
	-- Tier 1: kills people. Everywhere on earth treats these as the worst thing
	-- you can do short of causing the crash itself.
	SchoolBusPassed       = 100,
	DrinkDriving          = 100,
	RecklessDriving       = 90,
	RailroadGateRun       = 90,

	-- Tier 2: blocks or endangers the people whose job is to save the first tier.
	EmergencyLaneBlocked  = 75,
	MoveOverFailure       = 70,

	-- Tier 3: the ordinary dangerous stuff.
	RedLightRun           = 60,
	SpeedOver20           = 55,
	FailToYieldPedestrian = 50,

	-- Tier 4: region-dependent -- these are the ones that only exist because of
	-- where the city is, and are the whole point of shipping regional rules.
	IllegalRightOnRed     = 35,
	RoundaboutFailToYield = 35,
	SpeedOver10           = 30,
	IllegalUTurn          = 25,
	IllegalLaneSplitting  = 25,
	TractionLawViolation  = 25,

	-- Tier 5: mostly harms the driver, or is simply antisocial.
	HandheldPhone         = 20,
	LeftLaneCamping       = 15,
	NoSeatbelt            = 15,
	NoHelmet              = 15,
	ParkingViolation      = 10,
	MissingFrontPlate     = 5,
})

TrafficViolations.WEIGHTS = WEIGHTS

-- Which region field decides whether a violation exists here at all. A nil entry
-- means the violation is universal and always books.
local GATED_BY: { [string]: string } = table.freeze({
	IllegalRightOnRed     = "rightOnRed",       -- inverted: booking requires rightOnRed == FALSE
	IllegalUTurn          = "uTurnAllowed",     -- inverted
	IllegalLaneSplitting  = "laneSplitting",    -- inverted
	TractionLawViolation  = "chainLaws",
	HandheldPhone         = "handheldPhoneBanned",
	LeftLaneCamping       = "leftLanePassingOnly",
	MissingFrontPlate     = "frontPlateRequired",
	MoveOverFailure       = "moveOverCoversDisabled",
})

-- Gates whose flag reads "this is ALLOWED here", so the violation books when the
-- flag is false rather than true.
local INVERTED_GATE: { [string]: boolean } = table.freeze({
	IllegalRightOnRed    = true,
	IllegalUTurn         = true,
	IllegalLaneSplitting = true,
})

-- Violations a SECONDARY-enforcement region may only book alongside something else.
-- This is the whole practical meaning of "secondary enforcement": the officer cannot
-- pull you over for it, only add it once you are already stopped.
local SECONDARY_CANDIDATES: { [string]: string } = table.freeze({
	NoSeatbelt    = "seatbeltPrimary",
	HandheldPhone = "handheldEnforcementPrimary",
})

-- Does this region book this violation at all?
function TrafficViolations.isEnforced(region: RegionRuleset, violation: string): boolean
	local gate = GATED_BY[violation]
	if not gate then
		return true
	end
	local allowed = (region :: any)[gate] == true
	if INVERTED_GATE[violation] then
		return not allowed
	end
	return allowed
end

-- True when the region can only book this alongside another violation in the same
-- stop. Callers pass `alreadyStopped` from their own enforcement context.
function TrafficViolations.isSecondaryOnly(region: RegionRuleset, violation: string): boolean
	local field = SECONDARY_CANDIDATES[violation]
	if not field then
		return false
	end
	return (region :: any)[field] ~= true
end

-- Final score for one violation in one region, or 0 when the region does not book
-- it. `alreadyStopped` is the other-violation-in-this-stop flag that secondary
-- enforcement needs; pass true from crash/pursuit contexts where a stop is implied.
-- ponytail: flat multiply, no diminishing returns. A driver racking up twenty
-- offences scores twenty times one -- add a per-trip curve here if that reads badly.
function TrafficViolations.score(region: RegionRuleset, violation: string, alreadyStopped: boolean?): number
	local base = TrafficViolations.WEIGHTS[violation]
	if not base then
		return 0
	end
	if not TrafficViolations.isEnforced(region, violation) then
		return 0
	end
	if TrafficViolations.isSecondaryOnly(region, violation) and not alreadyStopped then
		return 0
	end
	return base * region.penaltySeverity
end

-- How likely the region is to NOTICE a violation with nobody watching. Camera-heavy
-- regions catch things an officer never would, which is the real felt difference
-- between driving in Montana and driving in Beijing.
local CAMERA_DETECTION: { [string]: number } = table.freeze({
	banned    = 0.0,
	none      = 0.05,
	limited   = 0.25,
	common    = 0.6,
	pervasive = 0.95,
})

function TrafficViolations.cameraDetectionChance(region: RegionRuleset): number
	return CAMERA_DETECTION[region.cameraEnforcement] or 0.25
end

return table.freeze(TrafficViolations)
