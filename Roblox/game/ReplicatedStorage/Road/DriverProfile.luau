--!strict
-- DriverProfile
-- Every driver gets its own MIND: a small frozen set of traits derived from one
-- integer seed. Two cars given the same start and goal no longer produce the same
-- route, because each one weighs the road differently -- one is a jam-averse Waze
-- addict who will happily add a block to skip a queue, another is a stubborn
-- straight-liner who sits in it, a third simply mis-prices a few streets.
--
-- Traits are DETERMINISTIC per seed and cached, so a driver's opinion of the city is
-- stable for its whole life. That matters: random-per-query costs would make a car
-- flip-flop between two routes every time it re-planned. Same seed -> same mind,
-- forever.
--
-- Read by NavRouter (route costs) and NPCDriverService (speed, patience, reroute
-- appetite). Pure data + pure functions; requires nothing but RoadConstants-free
-- maths, so it is safe on both sides of the network boundary.

local DriverProfile = {}

-- == Trait ranges ==============================================================
-- Each is (min, max) for a uniform draw. Widen for a more chaotic city, narrow for
-- a more uniform one. The MIDDLE of every range is roughly the old fixed behaviour,
-- so the average driver still behaves like it always did.
local RANGES = table.freeze({
	-- Multiplies RoadConstants.NAV_CONGESTION_WEIGHT. 0.35 = barely notices traffic
	-- (radio on, no nav app); 2.2 = obsessive jam-dodger.
	jamAversion    = { 0.35, 2.20 },
	-- Multiplies booked (anticipated) load. Some drivers read the city ahead and pick
	-- an emptier corridor; others only react to what is physically in front of them.
	foresight      = { 0.10, 1.60 },
	-- Multiplies every turn cost. High = prefers to stay on one road / hates junctions
	-- (the arterial driver); low = happily rat-runs through back streets.
	turnAversion   = { 0.55, 1.75 },
	-- Valhalla's use_highways dial, 0..1, neutral at 0.5: 0 sticks to surface streets
	-- even when the motorway is quicker, 1 gets on the big road at every opportunity.
	useHighways    = { 0.05, 0.95 },
	-- How much this driver weighs FUEL against time. 0.3 = barely thinks about the
	-- gas bill and just wants to arrive; 1.8 = watches the pump and will take the
	-- steadier, thriftier road rather than blast down the motorway to save a minute.
	fuelSensitivity = { 0.30, 1.80 },
	-- Per-edge cost misperception, +/- this fraction. THE diversity lever: with all
	-- other traits equal, this alone splits drivers across near-tied alternatives.
	explore        = { 0.02, 0.22 },
	-- Cruise speed as a fraction of the posted limit.
	speedFactor    = { 0.86, 1.12 },
	-- Scales how long a jam must last before this driver even considers a new route.
	patience       = { 0.45, 1.90 },
	-- Fraction a new route must beat the old one by before the driver commits.
	-- Low = twitchy re-router, high = "I've started, I'll finish".
	detourTrigger  = { 0.12, 0.55 },
})

-- Extra reroutes this driver allows itself per trip, on top of the base budget.
local EXTRA_REROUTE_MAX = 3

export type Profile = {
	seed: number,
	jamAversion: number,
	foresight: number,
	turnAversion: number,
	useHighways: number,
	fuelSensitivity: number,
	explore: number,
	speedFactor: number,
	patience: number,
	detourTrigger: number,
	extraReroutes: number,
	label: string,
	-- Set only on a withToken view: identifies THIS trip's route booking so the
	-- router can discount the driver's own reservation when pricing a road.
	token: number?,
}

-- == Deterministic hashing =====================================================
-- Edge ids are strings and get hashed on EVERY A* edge expansion, so the string
-- walk is done once per edge id and cached; the per-driver mix is then pure bit32
-- (exact on 32-bit ints, unlike float multiply-hashing which silently loses the
-- low bits past 2^53).
local _edgeHash: { [string]: number } = {}
local HASH_MOD = 2147483647

local function edgeHash(edgeId: string): number
	local cached = _edgeHash[edgeId]
	if cached then
		return cached
	end
	local h = 5381
	for i = 1, #edgeId do
		h = (h * 33 + string.byte(edgeId, i)) % HASH_MOD
	end
	_edgeHash[edgeId] = h
	return h
end

-- Stable 0..1 noise for (driver, edge). xorshift32 avalanche: neighbouring edge ids
-- and adjacent seeds decorrelate, so two cars spawned back to back do not end up
-- with the same opinion of the same street.
function DriverProfile.edgeNoise(seed: number, edgeId: string): number
	local x = bit32.bxor(edgeHash(edgeId), bit32.band(seed * 2654435 + 0x9E3779B9, 0xFFFFFFFF))
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	return x / 4294967296
end

-- Signed cost multiplier this driver applies to an edge: 1 +/- explore.
function DriverProfile.edgeBias(profile: Profile?, edgeId: string): number
	if not profile or profile.explore <= 0 then
		return 1
	end
	return 1 + (DriverProfile.edgeNoise(profile.seed, edgeId) - 0.5) * 2 * profile.explore
end

-- == Profiles ==================================================================
local _bySeed: { [number]: Profile } = {}

-- Human-readable archetype, purely for debug overlays / admin readouts. Picked from
-- the two traits that dominate how a route actually comes out.
local function labelFor(jamAversion: number, turnAversion: number, explore: number): string
	if jamAversion < 0.7 then
		return if turnAversion > 1.3 then "Stubborn arterial" else "Oblivious"
	elseif jamAversion > 1.6 then
		return if explore > 0.15 then "Restless nav-app" else "Jam dodger"
	elseif turnAversion < 0.85 then
		return "Rat-runner"
	elseif turnAversion > 1.4 then
		return "Main-road regular"
	end
	return if explore > 0.15 then "Wanderer" else "Average commuter"
end

-- The whole mind from one integer. Cached, so re-planning is free and a driver's
-- traits never drift mid-trip.
function DriverProfile.forSeed(rawSeed: number): Profile
	local seed = math.floor(math.abs(rawSeed)) % 1048576
	local cached = _bySeed[seed]
	if cached then
		return cached
	end

	local rng = Random.new(seed)
	local function draw(range: { number }): number
		return rng:NextNumber(range[1], range[2])
	end

	local jamAversion  = draw(RANGES.jamAversion)
	local turnAversion = draw(RANGES.turnAversion)
	local explore      = draw(RANGES.explore)

	local profile: Profile = table.freeze({
		seed          = seed,
		jamAversion   = jamAversion,
		foresight     = draw(RANGES.foresight),
		turnAversion  = turnAversion,
		useHighways   = draw(RANGES.useHighways),
		fuelSensitivity = draw(RANGES.fuelSensitivity),
		explore       = explore,
		speedFactor   = draw(RANGES.speedFactor),
		patience      = draw(RANGES.patience),
		detourTrigger = draw(RANGES.detourTrigger),
		-- A jam-averse driver grants itself more chances to change its mind.
		extraReroutes = math.floor(jamAversion / 2.2 * EXTRA_REROUTE_MAX + 0.5),
		label         = labelFor(jamAversion, turnAversion, explore),
	})
	_bySeed[seed] = profile
	return profile
end

-- Persona for a vehicle model. The seed is stamped on the model the first time it is
-- asked for, so the same car keeps the same mind across re-plans, reroutes and the
-- hand-offs between CitizenService and NPCDriverService.
function DriverProfile.fromModel(model: Instance?): Profile?
	if not model then
		return nil
	end
	local existing = model:GetAttribute("DriverSeed")
	if typeof(existing) == "number" then
		return DriverProfile.forSeed(existing)
	end
	local seed = math.random(0, 1048575)
	model:SetAttribute("DriverSeed", seed)
	return DriverProfile.forSeed(seed)
end

-- A per-TRIP view of a per-DRIVER mind. Traits are shared and frozen (one table per
-- seed, however many cars roll that seed); the token is unique to one live trip, so
-- the router can tell "this road is booked by five OTHER cars" from "...including
-- me". Without that a driver would price its own reservation as competition and
-- talk itself into a detour around itself.
function DriverProfile.withToken(profile: Profile?, token: number): Profile?
	if not profile then
		return nil
	end
	return (setmetatable({ token = token }, { __index = profile }) :: any) :: Profile
end

DriverProfile.RANGES = RANGES

return DriverProfile
