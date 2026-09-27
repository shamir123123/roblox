--!strict
-- TransitTypes
-- Shared, immutable catalog for the public-transit (bus) system: the Bus Depot and
-- Bus Stop placeables, the Bus vehicle, and every tunable the feature reads. Pure
-- data -- no lifecycle, no side effects on require. Mirrors ServiceTypes / SchoolTypes
-- so the placement UI and renderers can treat it the same way.
--
-- Read by: TransitService (placement / validation / sim), BusDispatchService (spawn /
-- drive), the placement + overview controllers, and the Bus model template builder.

local LOT_SIZE = 16 -- must match ZoneService.LOT_SIZE (the depot snaps to the zone grid)

local TransitTypes = {}

-- ============================================================================
-- Depot -- a garage; each one raises the city-wide bus allowance by busCapacity.
-- ============================================================================
export type DepotSpec = {
	key: string,
	name: string,
	desc: string,
	category: string,        -- UI grouping ("Transit")
	widthLots: number,       -- footprint along the road, in lots
	depthLots: number,       -- footprint back from the road, in lots
	height: number,          -- body height, studs
	cost: number,            -- treasury cost to place
	busCapacity: number,     -- buses this depot lets the city run (the per-depot limit)
	upkeep: number,          -- monthly upkeep while it stands
	footprint: Vector3,      -- derived X*Z ground size (studs), Y body height
	wall: Color3,
	roof: Color3,
	accent: Color3,
}

local DEPOTS: { [string]: DepotSpec } = {
	BusDepot = {
		key = "BusDepot", name = "Bus Depot",
		desc = "A full bus garage. Its fleet of buses lives here and rolls out to serve your routes.",
		category = "Transit", widthLots = 7, depthLots = 9, height = 16,
		cost = 16000, busCapacity = 20, upkeep = 400,
		footprint = Vector3.new(7 * LOT_SIZE, 16, 9 * LOT_SIZE),
		wall = Color3.fromRGB(198, 196, 190), roof = Color3.fromRGB(92, 95, 102), accent = Color3.fromRGB(46, 84, 140),
	},
}

-- ============================================================================
-- Stop -- a roadside pole/shelter citizens board at. Snaps to the kerb, faces road.
-- ============================================================================
export type StopSpec = {
	key: string,
	name: string,
	desc: string,
	category: string,
	cost: number,
	poleHeight: number,      -- sign pole height, studs
	shelterSize: Vector3,    -- shelter footprint: X along the curb, Y, Z out from the curb
	curbOffset: number,      -- studs from the road edge out to the shelter centre
	accent: Color3,
	mode: string?,           -- "bus" (nil) | "train": which network the stop boards from
}

local STOPS: { [string]: StopSpec } = {
	BusStop = {
		key = "BusStop", name = "Bus Stop",
		desc = "Citizens wait here to board. Place along a road, on either side -- it faces the road.",
		category = "Transit", cost = 400,
		-- 4 studs = 1 metre:
		--   poleHeight = 3 m = 12 studs (tall transit pole)
		--   shelterSize: X = 3 m = 12 studs (along curb), Y = 2.2 m = 8.8 studs (shelter body height), Z = 1.2 m = 4.8 studs (depth from curb)
		--   curbOffset = how far from the road edge the shelter sits (sidewalk is ~2-3 m wide = 8-12 studs from carriageway edge)
		poleHeight = 12,
		shelterSize = Vector3.new(12, 8.8, 4.8), curbOffset = 4.2,
		-- CITY TRANSIT brand blue, shared with the depot accent.
		accent = Color3.fromRGB(46, 84, 140),
	},
	TrainStation = {
		key = "TrainStation", name = "Train Station",
		desc = "Passengers board trains here. Place beside a train track; trains on a line stop at its platform.",
		category = "Transit", cost = 6000,
		poleHeight = 14,
		-- shelterSize doubles as the platform: X along the track, Y canopy height, Z platform depth.
		shelterSize = Vector3.new(96, 9, 10), curbOffset = 5,
		accent = Color3.fromRGB(140, 62, 54), -- rail brick red, distinct from bus blue
		mode = "train",
	},
}

-- ============================================================================
-- Bus -- the vehicle. Dimensions are authored to the world scale used by the car
-- templates in ServerStorage.Vehicles (cars are ~7.5 wide x ~10 long; a bus reads
-- as longer). The Bus template model is built to these dims; VehicleFactory clones it.
-- ============================================================================
export type BusSpec = {
	length: number, width: number, height: number,
	capacity: number,  -- nominal passenger capacity (the usage % basis)
	speedKmh: number,  -- cruise speed; NPCDriverService still obeys the lane limit
	body: Color3,
}

TransitTypes.Bus = table.freeze({
	length = 46, width = 9.6, height = 10,
	capacity = 30, speedKmh = 50,
	body = Color3.fromRGB(228, 228, 222),
}) :: BusSpec

-- The articulated ("bendy") bus: same route, more than twice the seats. A depot keeps a
-- share of these and sends them where a line is busy (BusDispatchService).
TransitTypes.BusArticulated = table.freeze({
	length = 72, width = 9.6, height = 10,
	capacity = 70, speedKmh = 50,
	body = Color3.fromRGB(228, 228, 222),
}) :: BusSpec
TransitTypes.ARTICULATED_EVERY = 3      -- every 3rd depot slot parks an articulated bus
TransitTypes.BUSY_LINE_USAGE = 60       -- % full at which a line is sent articulated buses

-- ============================================================================
-- Train -- a locomotive + coaches. carLength/width/height are per-car dims authored
-- at the same scale as the Bus above; capacity is the WHOLE train (usage % basis).
-- ============================================================================
export type TrainSpec = {
	carLength: number, width: number, height: number,
	carCount: number,   -- cars per train incl. the locomotive
	carGap: number,     -- coupling gap between cars, studs
	capacity: number,   -- passengers per whole train
	speedKmh: number,   -- cruise speed on open track
	body: Color3,       -- coach body
	loco: Color3,       -- locomotive body
}

TransitTypes.Train = table.freeze({
	carLength = 44, width = 10, height = 12,
	carCount = 3, carGap = 2,
	capacity = 90, speedKmh = 120,
	body = Color3.fromRGB(228, 228, 222),
	loco = Color3.fromRGB(140, 62, 54),
}) :: TrainSpec

-- ============================================================================
-- Tunables
-- ============================================================================
TransitTypes.LOT_SIZE = LOT_SIZE
TransitTypes.BUSES_PER_DEPOT = 20         -- mirrors DepotSpec.busCapacity; the always-parked fleet each depot owns
TransitTypes.DEFAULT_BUSES_PER_ROUTE = 2
TransitTypes.DEFAULT_TRAINS_PER_ROUTE = 1
TransitTypes.MAX_TRAINS_PER_ROUTE = 4    -- per line; trains need no depot, this is the only cap
TransitTypes.TRAIN_UPKEEP = 400          -- monthly upkeep per assigned train
TransitTypes.TRAIN_STOP_DWELL = 4        -- seconds a train holds at a station
TransitTypes.DEFAULT_FARE = 2             -- cents per boarding
TransitTypes.MIN_FARE = 0
TransitTypes.MAX_FARE = 12
TransitTypes.STOP_MIN_SPACING = 24        -- min studs between two stops
TransitTypes.STOP_BOARD_RADIUS = 12       -- a bus within this of a stop's road point is "at" it
TransitTypes.STOP_DWELL = 1.5             -- seconds a bus pauses at a stop
TransitTypes.BOARD_SECONDS = 0.4          -- ...plus this per passenger getting on or off
TransitTypes.MAX_STOPS_PER_ROUTE = 24
TransitTypes.MAX_WAYPOINTS_PER_LEG = 8
TransitTypes.BUS_UPKEEP = 120             -- monthly upkeep per running bus
-- Walking reach a citizen will use to get to/from a stop (studs). Beyond this, a stop
-- is too far and transit is not an option for that trip.
TransitTypes.STOP_WALK_REACH = 800           -- studs (~400 m): the standard bus catchment -- a
                                             -- 5-minute walk; the mode choice prices the walk itself
-- Line colours cycled as routes are created. Muted, transit-map hues -- distinct from
-- each other but desaturated to sit with the champagne/glass UI instead of flat-UI neon.
TransitTypes.ROUTE_COLORS = table.freeze({
	Color3.fromRGB(192, 80, 77), Color3.fromRGB(74, 122, 178), Color3.fromRGB(97, 160, 105),
	Color3.fromRGB(212, 165, 74), Color3.fromRGB(138, 103, 165), Color3.fromRGB(200, 118, 66),
	Color3.fromRGB(84, 148, 150), Color3.fromRGB(180, 96, 128),
})

-- ============================================================================
-- Accessors
-- ============================================================================
function TransitTypes.getDepot(key: string): DepotSpec?
	return DEPOTS[key]
end

function TransitTypes.getStop(key: string): StopSpec?
	return STOPS[key]
end

-- Depot footprint ground size in studs: X = width along the road, Z = depth back from it.
function TransitTypes.depotFootprintStuds(spec: DepotSpec): Vector3
	return Vector3.new(spec.widthLots * LOT_SIZE, spec.height, spec.depthLots * LOT_SIZE)
end

-- A deterministic line colour for the Nth route created (wraps the palette).
function TransitTypes.routeColor(index: number): Color3
	local n = #TransitTypes.ROUTE_COLORS
	return TransitTypes.ROUTE_COLORS[((index - 1) % n) + 1]
end

for _, spec in DEPOTS do table.freeze(spec) end
for _, spec in STOPS do table.freeze(spec) end
table.freeze(DEPOTS)
table.freeze(STOPS)

TransitTypes.Depots = DEPOTS
TransitTypes.Stops = STOPS
TransitTypes.DepotOrder = table.freeze({ "BusDepot" })
TransitTypes.StopOrder = table.freeze({ "BusStop", "TrainStation" })

return TransitTypes
