--!strict
-- NavCost
-- How much a piece of road actually COSTS a driver, in SECONDS.
--
-- Every formula below is copied from how real routing engines and real transport
-- planning models do it, rather than invented for this game. The point is that the
-- route a car picks should respond to infrastructure the way a real driver's nav app
-- does: a wide fast road beats a narrow slow one even when it is longer, a junction
-- with a long red costs more than a free-flowing one, and a road already carrying
-- traffic gets worse faster the closer it is to capacity.
--
-- Sources (values kept at their published defaults unless noted):
--
--   Free-flow time & road-class speeds
--     OSRM's car profile costs every road as length / speed, with speed set by the
--     road's class (motorway 90 km/h ... residential 25 ... living_street 10).
--     https://github.com/Project-OSRM/osrm-backend/blob/master/profiles/car.lua
--     Our RoadTypeCatalog already carries a per-type speedLimit, so the class table
--     is already there -- it just has to be DIVIDED INTO the length instead of the
--     length being used raw.
--
--   Turn penalties
--     OSRM process_turn: a sigmoid over the turn angle that maxes out at
--     turn_penalty (7.5 s), plus u_turn_penalty (20 s) on a U-turn, with turn_bias
--     (1.075) making turns ACROSS oncoming traffic dearer than turns away from it.
--     turn_bias is inverted for left-hand driving. This city drives on the RIGHT
--     (RoadConstants.DRIVING_SIDE), so the bias is used as published and the
--     expensive turn is the LEFT one -- the turn that crosses oncoming traffic.
--
--   Fixed manoeuvre / road-class penalties
--     Valhalla auto costing defaults: maneuver_penalty 5 s, service_penalty 15 s,
--     use_highways 0.5 (a 0..1 dial, not a penalty -- 0 avoids motorways, 1 loves
--     them). https://valhalla.github.io/valhalla/api/route/api-reference/
--
--   Congestion
--     The BPR (US Bureau of Public Roads, 1964) volume-delay function, the standard
--     VDF in traffic assignment worldwide:
--         t = t0 * (1 + alpha * (v/c)^beta),  alpha = 0.15, beta = 4
--     Cheap, convex, and it has the right shape: almost free until a road nears
--     capacity, then very steep.
--
--   Signal delay
--     Webster's uniform delay, the classic model for average wait at a signalised
--     intersection given its cycle length and green split:
--         d = C * (1 - g/C)^2 / (2 * (1 - x * g/C))
--     This is what makes "big wait time or small" a real routing input: a short
--     green on a long cycle is expensive to route through, a long green is not.
--
--   Fuel
--     Generalized cost, the standard way transport economics prices a trip:
--         cost = value_of_time * time + fuel_price * fuel_burned
--     with fuel burn a convex (U-shaped) function of speed -- thirsty crawling in
--     stop-go, cheapest around 70-80 km/h, thirsty again at motorway speed where
--     aerodynamic drag takes over. This is what stops a motorway from being an
--     automatic win: it is faster, but it drinks more per km, so it only wins when
--     the time it saves is worth the extra fuel.
--
-- Everything is seconds, so the numbers add up and stay comparable. Fuel is
-- converted INTO seconds through the value of time, so one A* can weigh both.

local RoadConstants = require(script.Parent.RoadConstants)
local RoadRules = require(script.Parent.RoadRules)

local NavCost = {}

-- == OSRM: turns ===============================================================
local TURN_PENALTY   = 7.5   -- car.lua turn_penalty (s), the sigmoid's ceiling
local U_TURN_PENALTY = 20    -- car.lua u_turn_penalty (s), added on top
local TURN_BIAS      = 1.075 -- car.lua turn_bias
-- OSRM inverts the bias when the network drives on the left. Read per call rather than
-- cached here: the driving side is a player setting that can change at runtime, and a
-- module-level copy would freeze whichever value happened to be set when NavCost loaded.

-- == Valhalla: fixed penalties =================================================
local MANEUVER_PENALTY = 5   -- auto costing maneuver_penalty (s)
local SERVICE_PENALTY  = 15  -- auto costing service_penalty (s), for alleys/service roads
-- Valhalla's use_highways is a 0..1 preference dial with default 0.5 (neutral).
-- Away from 0.5 it scales motorway cost by up to this much either way.
local HIGHWAY_DIAL_RANGE = 0.6

-- == BPR: congestion ===========================================================
local BPR_ALPHA = 0.15
local BPR_BETA  = 4
-- Our congestion/booking pressures are smoothed and SATURATE at 1.0, whereas a real
-- v/c ratio runs well past 1 on an oversaturated road (which is where BPR's steep
-- tail lives). This maps our 0..1 pressure onto a realistic v/c range so the curve
-- is used over the span it was calibrated for -- the same calibration step a
-- transport model does against local counts.
local BPR_DEMAND_SCALE = 2.0

-- == Fuel ======================================================================
-- Litres per 100 km as a function of speed (km/h):
--
--     F(v) = a/v + b + c*v^2
--
--   a/v   engine idle + accessories spread over distance -- dominates when crawling
--   b     rolling resistance, roughly constant per km
--   c*v^2 aerodynamic drag; drag force goes as v^2, so work per km does too
--
-- Strictly convex with a minimum near 75 km/h, which is where real cars are most
-- efficient. Calibrated to roughly 8 L/100km at that optimum, ~9.6 at 120 km/h, and
-- over 20 crawling at 15 km/h.
local FUEL_IDLE_TERM = 295.3  -- a
local FUEL_ROLLING   = 2.09   -- b
local FUEL_DRAG      = 0.00035 -- c
local FUEL_MIN_SPEED_KMH = 5   -- floor: below this the a/v term runs away

function NavCost.litresPer100km(speedKmh: number): number
	local v = math.max(speedKmh, FUEL_MIN_SPEED_KMH)
	return FUEL_IDLE_TERM / v + FUEL_ROLLING + FUEL_DRAG * v * v
end

-- == Webster: signal delay =====================================================
-- Degree of saturation is capped below 1: Webster's uniform-delay term divides by
-- (1 - x*g/C) and blows up as x approaches 1. Standard practice is to cap it and
-- let the overflow term (which we do not model) carry the rest.
local WEBSTER_MAX_SATURATION = 0.95

-- == A* heuristic ==============================================================
-- Now that cost is seconds, the search's straight-line heuristic must be seconds
-- too -- a leftover distance heuristic would dwarf every real cost and quietly turn
-- A* into greedy best-first, returning whatever route happened to point at the goal.
-- To stay ADMISSIBLE it must never over-estimate, so it divides by the fastest
-- travel anything could possibly achieve: the top speed limit, further inflated by
-- the largest discount a persona's class preference and bias can stack up.
local STUDS_PER_KMH = (1 / 3.6) / RoadConstants.STUD_TO_METER
local MAX_SPEED_KMH = 120 -- fastest speedLimit in RoadTypeCatalog
local BEST_CASE_DISCOUNT = 0.5 -- floor on classFactor * edgeBias
local HEURISTIC_SPEED = MAX_SPEED_KMH * STUDS_PER_KMH / BEST_CASE_DISCOUNT

function NavCost.heuristicSeconds(distance: number): number
	return distance / HEURISTIC_SPEED
end

-- == Free-flow time ============================================================
-- The single most important line in this module: a road's cost is TIME, not
-- distance. speedLimit is studs/s (RoadRules.getSpeedLimitStuds), length is studs.
function NavCost.freeFlowSeconds(edge: any, distance: number?): number
	local length = distance or edge.length
	local speed = edge.speedLimit
	if not speed or speed <= 0 then
		speed = 56
	end
	return length / speed
end

-- == BPR volume-delay ==========================================================
-- `demand` is our 0..1 pressure (congestion, or congestion + booked intent).
-- Returns the MULTIPLIER on free-flow time, never below 1.
function NavCost.bprFactor(demand: number): number
	if demand <= 0 then
		return 1
	end
	local x = demand * BPR_DEMAND_SCALE
	return 1 + BPR_ALPHA * x ^ BPR_BETA
end

-- == Webster uniform delay =====================================================
-- cycle: full signal cycle length (s). green: effective green for this approach (s).
-- saturation: 0..1 demand/capacity on the approach.
-- Returns average seconds of wait a driver should EXPECT at this approach.
function NavCost.websterDelay(cycle: number, green: number, saturation: number?): number
	if cycle <= 0 or green <= 0 then
		return 0
	end
	local ratio = math.clamp(green / cycle, 0, 1)
	if ratio >= 1 then
		return 0
	end
	local x = math.clamp(saturation or 0, 0, WEBSTER_MAX_SATURATION)
	local denominator = 2 * (1 - x * ratio)
	if denominator <= 1e-6 then
		return cycle
	end
	return cycle * (1 - ratio) ^ 2 / denominator
end

-- == OSRM turn cost ============================================================
-- `angleRadians` is signed as THIS codebase measures it: positive = LEFT
-- (RoadNavigationGraph.signedTurnAngle). OSRM measures the opposite way, positive =
-- RIGHT, so the angle is negated into OSRM's frame and its formula then used
-- verbatim -- including the way it handles driving side, which is ONLY by inverting
-- turn_bias and never by swapping the branches. (Doing both, as an earlier version
-- of this did, cancels out and makes the turn across oncoming traffic the cheap one.)
--
-- Net effect on this right-hand-driving map: a right turn is cheap (~2.1 s at 90 deg),
-- a left turn crosses oncoming traffic and costs more (~5.4 s), and a U-turn is dear.
-- Flipping DRIVING_SIDE swaps the two without touching anything here.
function NavCost.turnSeconds(angleRadians: number, isUTurn: boolean?): number
	local angle = -math.deg(angleRadians) -- into OSRM's frame: positive = right
	local bias = if RoadRules.getDrivingSide() == "left" then 1 / TURN_BIAS else TURN_BIAS

	local duration: number
	if angle >= 0 then
		duration = TURN_PENALTY / (1 + math.exp(-((13 / bias) * angle / 180 - 6.5 * bias)))
	else
		duration = TURN_PENALTY / (1 + math.exp(-((13 * bias) * -angle / 180 - 6.5 / bias)))
	end

	if isUTurn then
		duration += U_TURN_PENALTY
	end
	return duration
end

-- Valhalla adds a flat manoeuvre cost for any move that is not simply staying on
-- the same road. Charged once per junction transition, on top of the turn sigmoid.
function NavCost.maneuverSeconds(movement: string): number
	if movement == "straight" then
		return 0
	end
	return MANEUVER_PENALTY
end

-- == Road class ================================================================
-- The "big road vs small road" dial. Time-based costing already prefers the big
-- road (it is faster); this layers on the PREFERENCE part -- real drivers overweight
-- arterials and underweight back alleys beyond what raw speed explains, and both
-- OSRM (class speeds) and Valhalla (use_highways, service_penalty) model that.
function NavCost.classifyRoad(spec: any): string
	if spec.isHighway then
		return "highway"
	end
	local speed = spec.speedLimit or 50
	if speed <= 20 then
		return "alley"
	end
	if (spec.laneCount or 2) >= 3 or speed >= 70 then
		return "arterial"
	end
	return "local"
end

-- Multiplier on an edge's time from its class and this driver's taste for motorways.
-- useHighways is Valhalla's 0..1 dial; 0.5 is neutral and leaves every class at 1.0.
function NavCost.classFactor(roadClass: string?, useHighways: number?): number
	local dial = useHighways or 0.5
	if roadClass == "highway" then
		return 1 + (0.5 - dial) * HIGHWAY_DIAL_RANGE
	elseif roadClass == "arterial" then
		-- Half the effect: an avenue is the mild version of the same preference.
		return 1 + (0.5 - dial) * HIGHWAY_DIAL_RANGE * 0.5
	end
	return 1
end

-- Flat seconds added for entering a service-grade road, per Valhalla's
-- service_penalty. Keeps traffic out of alleys unless they genuinely save time.
function NavCost.classPenaltySeconds(roadClass: string?): number
	return if roadClass == "alley" then SERVICE_PENALTY else 0
end

-- Money-per-second exchange rate between time and fuel.
local VALUE_OF_TIME_PER_SEC = (RoadConstants.NAV_VALUE_OF_TIME_PER_HOUR or 60) / 3600
local FUEL_PRICE = RoadConstants.NAV_FUEL_PRICE or 1.8
local STUDS_PER_KM = 1000 / RoadConstants.STUD_TO_METER

-- What the fuel for this stretch is WORTH, expressed in seconds, so it can simply be
-- added to travel time and the whole search stays one currency.
--
-- `effectiveSpeedStuds` is the speed actually achieved, not the posted limit: a
-- jammed motorway is priced at its crawling consumption, which is exactly why sitting
-- in traffic is expensive in fuel as well as in time.
function NavCost.fuelSeconds(distanceStuds: number, effectiveSpeedStuds: number): number
	if distanceStuds <= 0 or VALUE_OF_TIME_PER_SEC <= 0 then
		return 0
	end
	local speedKmh = effectiveSpeedStuds / STUDS_PER_KMH
	local litres = NavCost.litresPer100km(speedKmh) * (distanceStuds / STUDS_PER_KM) / 100
	return litres * FUEL_PRICE / VALUE_OF_TIME_PER_SEC
end

NavCost.FUEL_PRICE = FUEL_PRICE
NavCost.VALUE_OF_TIME_PER_SEC = VALUE_OF_TIME_PER_SEC
NavCost.TURN_PENALTY = TURN_PENALTY
NavCost.U_TURN_PENALTY = U_TURN_PENALTY
NavCost.MANEUVER_PENALTY = MANEUVER_PENALTY
NavCost.SERVICE_PENALTY = SERVICE_PENALTY
NavCost.BPR_ALPHA = BPR_ALPHA
NavCost.BPR_BETA = BPR_BETA
NavCost.HEURISTIC_SPEED = HEURISTIC_SPEED

return NavCost
