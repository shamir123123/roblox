--!strict
-- TravelModeChoice
-- How a citizen gets somewhere: on foot, by public transport, or in their own car. Pure
-- library: CitizenService gathers the facts of one trip and this turns them into a choice.
--
-- It is the model transport planners use (random-utility mode choice). Every mode gets a
-- GENERALISED COST in seconds: time, with the unpleasant parts weighted up, plus money
-- converted through the value of time. The person takes the cheapest. The randomness is
-- PERSONAL and stable -- each citizen carries a fixed taste per mode, seeded by their pid --
-- so the same person makes the same choice for the same trip day after day (a habit), while
-- two neighbours can differ. What changes a habit is the city: a bus line that arrives, a
-- street whose parking fills up, a fare the player raises.
--
-- Where the weights come from:
--   * Walking to a stop and waiting for it are felt at ~2-2.5x the same time spent riding
--     (TCRP Report 166 app. E; FTA mode-choice guidance).
--   * A car trip carries "terminal time" at each end -- getting to the car, parking it,
--     walking in -- on top of the drive, ~1-5 min per end (four-step model practice), plus
--     the search for a bay: seconds where bays are free, 3.5-14 min in a full downtown
--     (Shoup 2006; Millard-Ball 2020). Here it is the real distance to the nearest free bay.
--   * ~92% of US households own a car and there are ~1.9 per household (ACS 2022), so about
--     nine adults in ten have one of their own.
--   * The average US walk trip is under a mile (NHTS 2017); long walks fall off fast.
--   * Seniors weigh comfort ahead of time (the Cities: Skylines II agent model).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local WS = RoadConstants.WORLD_SCALE

local TravelModeChoice = {}

-- Speeds the estimate assumes -- the SAME speeds the sim moves people at, or every choice
-- would be made on a lie.
local WALK_SPEED        = 5 * WS  -- studs/s, NPCWalkingService.WALK_SPEED (1.25 m/s)
local WALK_DETOUR       = 1.2     -- straight line -> pavement distance
local DRIVE_SPEED       = 13      -- studs/s door to door incl. junctions (~23 km/h urban)
local DRIVE_DETOUR      = 1.3     -- straight line -> road distance

local OUT_OF_VEHICLE    = 2.0     -- weight on walking to/from a vehicle
local WAIT_WEIGHT       = 2.5     -- weight on standing at a stop
local WALK_FATIGUE      = 600     -- s of walking after which it feels twice as long
local TERMINAL_SECONDS  = 60      -- per trip end: to the car, into and out of the bay
local BOARDING_SECONDS  = 60      -- the hassle of a bus itself: ticket, crowd, timetable
local NO_PARKING_SECONDS = 900    -- nowhere legal to leave the car at all
local MONEY_SECONDS     = 7       -- seconds of travel one unit of city money is worth
local CAR_BASE_COST     = 3       -- per trip: fuel for the short hops, wear
local CAR_COST_PER_1K   = 2       -- per 1000 studs driven
local TASTE_SPREAD      = 0.35    -- personal taste: each mode's cost scaled by e^(+-0.35)
local SENIOR_AGE        = 60
local SENIOR_WALK_PER_YEAR = 0.04 -- extra weight on walking per year past SENIOR_AGE
local CAR_OWNERSHIP     = 0.9     -- share of adults with a car of their own

export type TransitOption = {
	timeSeconds: number, fare: number,
	walkSeconds: number, waitSeconds: number, rideSeconds: number,
}

export type Trip = {
	pid: number,
	age: number,
	distance: number,          -- flat studs, door to door
	canDrive: boolean,         -- owns a car and it is free for this trip
	parkWalk: number?,         -- studs from the nearest free bay to the door; nil = none
	congestion: number?,       -- slowdown on the roads between (1 = free flow, BPR factor)
	transit: TransitOption?,   -- best public-transport option, if any line serves the trip
}

export type Costs = { walk: number, drive: number?, transit: number? }

-- Stable 0..1 per (person, salt). Same person, same answer, forever.
local function unit(pid: number, salt: number): number
	return Random.new(pid * 16 + salt):NextNumber()
end

local function taste(pid: number, salt: number): number
	return math.exp((unit(pid, salt) * 2 - 1) * TASTE_SPREAD)
end

function TravelModeChoice.ownsCar(pid: number): boolean
	return unit(pid, 7) < CAR_OWNERSHIP
end

function TravelModeChoice.walkCost(trip: Trip): number
	local seconds = trip.distance * WALK_DETOUR / WALK_SPEED
	local weight = 1 + math.max(0, trip.age - SENIOR_AGE) * SENIOR_WALK_PER_YEAR
	return seconds * weight * (1 + seconds / WALK_FATIGUE) * taste(trip.pid, 1)
end

function TravelModeChoice.driveCost(trip: Trip): number?
	if not trip.canDrive then
		return nil
	end
	local road = trip.distance * DRIVE_DETOUR
	local driveSeconds = road / DRIVE_SPEED * (trip.congestion or 1)
	local terminal = TERMINAL_SECONDS * 2
	if trip.parkWalk then
		-- Walk from the bay, plus cruising the block to find it.
		terminal += trip.parkWalk / WALK_SPEED + trip.parkWalk / DRIVE_SPEED
	else
		terminal += NO_PARKING_SECONDS
	end
	local money = CAR_BASE_COST + CAR_COST_PER_1K * road / 1000
	return (driveSeconds + terminal * OUT_OF_VEHICLE + money * MONEY_SECONDS) * taste(trip.pid, 2)
end

function TravelModeChoice.transitCost(trip: Trip): number?
	local t = trip.transit
	if not t then
		return nil
	end
	local comfort = 1 + math.max(0, trip.age - SENIOR_AGE) * SENIOR_WALK_PER_YEAR * 0.5
	return (t.rideSeconds + t.walkSeconds * OUT_OF_VEHICLE * comfort + t.waitSeconds * WAIT_WEIGHT
		+ BOARDING_SECONDS + t.fare * MONEY_SECONDS) * taste(trip.pid, 3)
end

-- "walk" | "transit" | "drive", plus every cost it weighed (for the inspect panel).
function TravelModeChoice.choose(trip: Trip): (string, Costs)
	local costs: Costs = {
		walk = TravelModeChoice.walkCost(trip),
		drive = TravelModeChoice.driveCost(trip),
		transit = TravelModeChoice.transitCost(trip),
	}
	local mode, best = "walk", costs.walk
	if costs.transit and costs.transit < best then
		mode, best = "transit", costs.transit
	end
	if costs.drive and costs.drive < best then
		mode = "drive"
	end
	return mode, costs
end

return TravelModeChoice
