--!strict
-- ServiceTypes
-- Shared, immutable catalog of the service buildings: Hospital, Police Station, Fire
-- Station, Cemetery, plus the utilities (Wind Turbine, Power Plant, Water Tower, Sewage Plant). Read by the
-- server (EmergencyService places them + answers coverage),
-- the placement UI (cards + footprint ghost) and ServiceBuildingModel (placeholder geometry).
-- Pure data -- no lifecycle, no side effects on require. Mirrors SchoolTypes so the Services
-- flyout and ServiceFootprint can treat both catalogs the same way.
--
-- Footprints are measured in LOTS (16-stud zone tiles), so a placed building occupies a block
-- of the very grid the player zones on. `coverageRadius` is the service reach in studs. `kind`
-- is the coverage domain the building provides: "Hospital" (healthcare), "Police" or "Fire".

local LOT_SIZE = 16 -- full-size lot unit; ServiceBuildingModel ScaleTo()s the finished building
-- Half-size world: coverage/pollution reach scales so a station serves the same houses.
local WORLD_SCALE = require(game:GetService("ReplicatedStorage").Road.RoadConstants).WORLD_SCALE

local ServiceTypes = {}

export type Spec = {
	key: string,
	name: string,
	desc: string,
	kind: string,            -- "Hospital" | "Police" | "Fire" | "Deathcare" | "Power" | "Water" | "Sewage" | "Pipe" (coverage domain)
	category: string,        -- UI grouping label ("Emergency" | "Utilities")
	widthLots: number,       -- footprint along the road, in lots
	depthLots: number,       -- footprint back from the road, in lots
	height: number,          -- body height, studs
	coverageRadius: number,  -- service reach, studs
	cost: number,            -- treasury cost to place
	pollution: number?,      -- point-source pollution strength (dirty utilities)
	pollutionRadius: number?,-- pollution falloff radius, studs
	capacity: number?,       -- graves (Deathcare): burials this building holds
	powerOutput: number?,    -- kW this building generates (CS1 counts electricity in kW)
	solar: boolean?,         -- output follows the sun: powerOutput is the NOON PEAK, not a flat rate
	jobs: number?,           -- staff slots this building employs (CitizenService fills them)
	waterOutput: number?,    -- m3/week a water source pours into the network (WaterService)
	sewageCapacity: number?, -- m3/week of wastewater a plant treats (WaterService)
	powerUse: number?,       -- kW a facility draws; without it, it makes nothing (WaterService)
	shore: boolean?,         -- must stand with its edge in open water (pumps, outlets)
	battery: number?,        -- kWh a storage building holds (PowerService)
	batteryRate: number?,    -- kW it can charge or discharge at
	minSpacing: number?,     -- studs another building of its kind must keep clear
	yardVeto: boolean?,      -- false: this generator's yard may overlap another's (its own
	                         -- footprint is bigger than the yard, so the box test IS the rule)
	ambulances: number?,     -- healthcare: ambulances this building stations (also the
	                         -- number of marked bays on its apron)
	footprint: Vector3,      -- derived X*Z ground size (studs), Y body height
	wall: Color3,
	roof: Color3,
	accent: Color3,
}

-- Healthcare comes in four tiers: Clinic -> Small Hospital -> Hospital -> General
-- Hospital. Each is its OWN building on its OWN floor plan -- L, T, U and H -- with
-- parking reached by a driveway off the road. The authored meshes in
-- Templates.Asset.Building.Services are the real art; ServiceBuildingModel's four
-- procedural builders are the fallback, and both read the footprints below. Bigger tiers reach further, station more
-- ambulances and cost more to run; upkeep is a fraction of `cost`
-- (CityEconomyService.monthlyUpkeep), so the ladder balances itself.
local MED_WALL   = Color3.fromRGB(238, 240, 242)
local MED_ROOF   = Color3.fromRGB(176, 186, 196)
local MED_ACCENT = Color3.fromRGB(206, 70, 66)

local DEFS: { [string]: Spec } = {
	Clinic = {
		key = "Clinic", name = "Clinic", desc = "Basic care for one neighbourhood. Cheap to build, cheap to run, short reach.",
		kind = "Hospital", category = "Emergency", widthLots = 3, depthLots = 3, height = 10,
		coverageRadius = 120 * WORLD_SCALE, cost = 2500, ambulances = 3,
		footprint = Vector3.new(3 * LOT_SIZE, 10, 3 * LOT_SIZE),
		wall = MED_WALL, roof = MED_ROOF, accent = MED_ACCENT,
	},
	SmallHospital = {
		key = "SmallHospital", name = "Small Hospital", desc = "A T-plan brick ward wing under a glazed barrel atrium, with five ambulances on call.",
		kind = "Hospital", category = "Emergency", widthLots = 4, depthLots = 4, height = 15,
		coverageRadius = 170 * WORLD_SCALE, cost = 6500, ambulances = 5,
		footprint = Vector3.new(4 * LOT_SIZE, 15, 4 * LOT_SIZE),
		wall = MED_WALL, roof = MED_ROOF, accent = MED_ACCENT,
	},
	Hospital = {
		key = "Hospital", name = "Hospital", desc = "Keeps citizens healthy. Without one, people fall ill and die.",
		kind = "Hospital", category = "Emergency", widthLots = 5, depthLots = 4, height = 24,
		coverageRadius = 240 * WORLD_SCALE, cost = 15000, ambulances = 6,
		footprint = Vector3.new(5 * LOT_SIZE, 24, 4 * LOT_SIZE),
		wall = MED_WALL, roof = MED_ROOF, accent = MED_ACCENT,
	},
	GeneralHospital = {
		key = "GeneralHospital", name = "General Hospital", desc = "City-scale care: an H-plan of ward slabs around a ten-bay ambulance yard, with a rooftop helipad.",
		kind = "Hospital", category = "Emergency", widthLots = 6, depthLots = 5, height = 38,
		coverageRadius = 380 * WORLD_SCALE, cost = 32000, ambulances = 10,
		footprint = Vector3.new(6 * LOT_SIZE, 38, 5 * LOT_SIZE),
		wall = MED_WALL, roof = MED_ROOF, accent = MED_ACCENT,
	},
	PoliceStation = {
		key = "PoliceStation", name = "Police Station", desc = "Cuts crime nearby. Without one, robberies rise and happiness falls.",
		kind = "Police", category = "Emergency", widthLots = 3, depthLots = 2, height = 15,
		coverageRadius = 210 * WORLD_SCALE, cost = 8000,
		footprint = Vector3.new(3 * LOT_SIZE, 15, 2 * LOT_SIZE),
		wall = Color3.fromRGB(70, 82, 104), roof = Color3.fromRGB(40, 48, 64), accent = Color3.fromRGB(86, 140, 210),
	},
	FireStation = {
		key = "FireStation", name = "Fire Station", desc = "Puts out fires in range. Without one, fires spread house to house.",
		kind = "Fire", category = "Emergency", widthLots = 3, depthLots = 2, height = 15,
		coverageRadius = 210 * WORLD_SCALE, cost = 8000,
		footprint = Vector3.new(3 * LOT_SIZE, 15, 2 * LOT_SIZE),
		wall = Color3.fromRGB(150, 46, 40), roof = Color3.fromRGB(96, 30, 26), accent = Color3.fromRGB(244, 206, 96),
	},
	Cemetery = {
		key = "Cemetery", name = "Cemetery", desc = "Buries the deceased in range. Without one, bodies pile up and families leave.",
		kind = "Deathcare", category = "Emergency", widthLots = 3, depthLots = 3, height = 8,
		coverageRadius = 280 * WORLD_SCALE, cost = 7000, capacity = 60,
		footprint = Vector3.new(3 * LOT_SIZE, 8, 3 * LOT_SIZE),
		wall = Color3.fromRGB(206, 210, 214), roof = Color3.fromRGB(96, 104, 112), accent = Color3.fromRGB(142, 168, 142),
	},
	-- The city's ONLY generator today. `powerOutput` is CS1's land wind turbine at full
	-- output (8 MW, counted in kW); it is flat here rather than varying with the weather.
	-- `minSpacing` is the AMBER ring drawn while placing: the room the rotor wants, since
	-- it is ~21 studs across at world scale. It is advice, not a veto -- two amber rings
	-- may overlap. What placement actually refuses is yard on yard (`coverageRadius`, the
	-- blue circle), because that is the ground the machine itself stands on.
	WindTurbine = {
		key = "WindTurbine", name = "Wind Turbine", desc = "Clean power for a small area. Cheap to run, gentle on the air.",
		kind = "Power", category = "Utilities", widthLots = 1, depthLots = 1, height = 96,
		coverageRadius = 20, cost = 3500,
		powerOutput = 8000, minSpacing = 64,
		footprint = Vector3.new(1 * LOT_SIZE, 96, 1 * LOT_SIZE),
		wall = Color3.fromRGB(240, 242, 244), roof = Color3.fromRGB(126, 132, 140), accent = Color3.fromRGB(96, 180, 235),
	},
	-- The bigger tower: CS1's Advanced Wind Turbine, 20 MW against the standard 8. Same
	-- mesh at 1.5x, so the rotor spans 62 studs and the keep-out ring grows to match.
	AdvancedWindTurbine = {
		key = "AdvancedWindTurbine", name = "Advanced Wind Turbine",
		desc = "A far bigger tower on the same clean power. Two and a half times the output, and it needs the room to match.",
		kind = "Power", category = "Utilities", widthLots = 2, depthLots = 2, height = 144,
		coverageRadius = 28, cost = 12000,
		powerOutput = 20000, minSpacing = 96,
		footprint = Vector3.new(2 * LOT_SIZE, 144, 2 * LOT_SIZE),
		wall = Color3.fromRGB(240, 242, 244), roof = Color3.fromRGB(126, 132, 140), accent = Color3.fromRGB(96, 180, 235),
	},
	-- The one generator whose output MOVES. `powerOutput` is its noon peak; PowerService
	-- scales it by the sun's altitude, so it makes 12 MW at midday, less morning and
	-- evening, and nothing at all between dusk and dawn. Its yard has to cover the array
	-- itself (64 x 48 studs placed, half-diagonal 40) or a drawn line could not snap to it.
	-- ON: in `Order`, so it has a card. Footprint is 11 x 15 lots (117 x 160 studs): the
	-- array is 92 wide, leaving a 12.7-stud walkway down each side for staff. The yard
	-- reach has to cover the plot's half-diagonal (99) or a drawn line cannot snap to it.
	SolarFarm = {
		key = "SolarFarm", name = "Solar Farm",
		desc = "Twelve megawatts at noon and nothing at night. Clean and silent, but it needs something else awake after dark.",
		kind = "Power", category = "Utilities", widthLots = 11, depthLots = 15, height = 20,
		coverageRadius = 100, cost = 9000,
		powerOutput = 12000, solar = true, yardVeto = false, jobs = 15,
		footprint = Vector3.new(11 * LOT_SIZE, 20, 15 * LOT_SIZE),
		wall = Color3.fromRGB(46, 52, 66), roof = Color3.fromRGB(74, 74, 70), accent = Color3.fromRGB(246, 190, 74),
	},
	-- Not a building: a relay. PowerService owns these, not EmergencyService -- it is in
	-- this catalog so it rides the same Utilities card, ghost and placement remote as
	-- everything else on the page. `coverageRadius` is the reach PowerService wires with.
	PowerPole = {
		key = "PowerPole", name = "Power Line", desc = "Carries electricity to buildings a generator cannot reach. Run one to the map edge to buy and sell power.",
		kind = "PowerLine", category = "Utilities", widthLots = 1, depthLots = 1, height = 21,
		coverageRadius = 0, cost = 120,
		footprint = Vector3.new(1 * LOT_SIZE, 21, 1 * LOT_SIZE),
		wall = Color3.fromRGB(150, 140, 126), roof = Color3.fromRGB(96, 90, 82), accent = Color3.fromRGB(240, 206, 80),
	},
	-- The big dirty one: 40 MW day and night for a lot of smoke. `coverageRadius` is its
	-- YARD (what a line or a road has to touch), not a service area.
	PowerPlant = {
		key = "PowerPlant", name = "Coal Power Plant", desc = "40 MW day and night. Cheap power for a big city, but the smoke lowers land value around it.",
		kind = "Power", category = "Utilities", widthLots = 4, depthLots = 3, height = 18,
		coverageRadius = 40, cost = 20000,
		powerOutput = 40000, minSpacing = 48,
		pollution = 0.8, pollutionRadius = 80,
		footprint = Vector3.new(4 * LOT_SIZE, 18, 3 * LOT_SIZE),
		wall = Color3.fromRGB(88, 90, 96), roof = Color3.fromRGB(56, 58, 64), accent = Color3.fromRGB(240, 206, 80),
	},
	-- Stores what the grid has spare and gives it back when the grid is short -- the thing
	-- that carries a solar city through the night. Placeholder art (no template yet).
	BatteryStorage = {
		key = "BatteryStorage", name = "Battery Storage",
		desc = "Charges from spare power and gives it back when the grid runs short. Pairs with solar for the night.",
		kind = "Power", category = "Utilities", widthLots = 2, depthLots = 2, height = 8,
		coverageRadius = 24, cost = 8000,
		battery = 12000, batteryRate = 4000,
		footprint = Vector3.new(2 * LOT_SIZE, 8, 2 * LOT_SIZE),
		wall = Color3.fromRGB(226, 230, 236), roof = Color3.fromRGB(70, 90, 110), accent = Color3.fromRGB(110, 220, 120),
	},
	-- Water is counted in heads at WaterService's 16 m3/week a head: a tower serves 750, a
	-- pumping station 3,000. Every water facility runs on electricity -- no power, no
	-- pressure. `coverageRadius` is only the yard; the PIPES are the delivery.
	WaterTower = {
		key = "WaterTower", name = "Water Tower", desc = "12,000 m\u{00B3} of clean water a week, about 750 people. Needs power. Build it by a road -- every road carries water.",
		kind = "Water", category = "Utilities", widthLots = 2, depthLots = 2, height = 65,
		coverageRadius = 24, cost = 6000,
		waterOutput = 12000, powerUse = 80,
		footprint = Vector3.new(2 * LOT_SIZE, 65, 2 * LOT_SIZE),
		wall = Color3.fromRGB(196, 208, 220), roof = Color3.fromRGB(120, 136, 152), accent = Color3.fromRGB(80, 170, 235),
	},
	WaterPumpingStation = {
		key = "WaterPumpingStation", name = "Water Pumping Station",
		desc = "48,000 m\u{00B3} a week, about 3,000 people. Must stand on the shore and needs power. Keep sewage outlets away from it.",
		kind = "Water", category = "Utilities", widthLots = 3, depthLots = 3, height = 12,
		coverageRadius = 32, cost = 14000,
		waterOutput = 48000, powerUse = 480, shore = true,
		footprint = Vector3.new(3 * LOT_SIZE, 12, 3 * LOT_SIZE),
		wall = Color3.fromRGB(200, 214, 226), roof = Color3.fromRGB(70, 110, 150), accent = Color3.fromRGB(80, 170, 235),
	},
	-- A buried main. Three cards, one trench: water only, sewage only, or both laid
	-- together. `cost` is PER SPAN of pipe (ServiceTypes.PipeSpan studs), not per run.
	-- WaterPipeService owns these -- they ride this catalog only so they get a Utilities
	-- card like everything else. `kind = "Pipe"` is what routes the card to the drag tool.
	WaterPipe = {
		key = "WaterPipe", name = "Water Pipe", desc = "A buried water main. Anything within reach of a pipe fed by a tower gets water.",
		kind = "Pipe", category = "Utilities", widthLots = 1, depthLots = 1, height = 3,
		coverageRadius = 0, cost = 60,
		footprint = Vector3.new(1 * LOT_SIZE, 3, 1 * LOT_SIZE),
		wall = Color3.fromRGB(64, 176, 212), roof = Color3.fromRGB(38, 120, 150), accent = Color3.fromRGB(64, 176, 212),
	},
	SewagePipe = {
		key = "SewagePipe", name = "Sewage Pipe", desc = "A buried drain. Nothing treats what it carries yet -- lay it now, plug a plant into it later.",
		kind = "Pipe", category = "Utilities", widthLots = 1, depthLots = 1, height = 3,
		coverageRadius = 0, cost = 60,
		footprint = Vector3.new(1 * LOT_SIZE, 3, 1 * LOT_SIZE),
		wall = Color3.fromRGB(206, 170, 104), roof = Color3.fromRGB(140, 112, 64), accent = Color3.fromRGB(206, 170, 104),
	},
	UtilityPipe = {
		key = "UtilityPipe", name = "Water & Sewage", desc = "Both mains in one trench. Costs the two of them, saves digging twice.",
		kind = "Pipe", category = "Utilities", widthLots = 1, depthLots = 1, height = 3,
		coverageRadius = 0, cost = 110,
		footprint = Vector3.new(1 * LOT_SIZE, 3, 1 * LOT_SIZE),
		wall = Color3.fromRGB(64, 176, 212), roof = Color3.fromRGB(140, 112, 64), accent = Color3.fromRGB(120, 172, 172),
	},
	SewagePlant = {
		kind = "Sewage", key = "SewagePlant", name = "Sewage Treatment Plant", desc = "Cleans 16,000 m\u{00B3} of wastewater a week, about 1,000 people. Needs power.",
		category = "Utilities", widthLots = 3, depthLots = 3, height = 10,
		coverageRadius = 32, cost = 9000,
		sewageCapacity = 16000, powerUse = 300,
		pollution = 0.45, pollutionRadius = 52 * WORLD_SCALE,
		footprint = Vector3.new(3 * LOT_SIZE, 10, 3 * LOT_SIZE),
		wall = Color3.fromRGB(122, 118, 96), roof = Color3.fromRGB(84, 82, 66), accent = Color3.fromRGB(150, 190, 90),
	},
	-- The cheap answer: dump it in the water. Takes a lot, needs no power, pollutes the
	-- ground around it -- and a pumping station drinking near it pumps half.
	SewageOutlet = {
		key = "SewageOutlet", name = "Sewage Outlet",
		desc = "Dumps 40,000 m\u{00B3} of sewage a week into the water. Cheap and needs no power, but it pollutes and spoils pumps nearby.",
		kind = "Sewage", category = "Utilities", widthLots = 2, depthLots = 2, height = 6,
		coverageRadius = 24, cost = 3000,
		sewageCapacity = 40000, shore = true,
		pollution = 1.0, pollutionRadius = 96,
		footprint = Vector3.new(2 * LOT_SIZE, 6, 2 * LOT_SIZE),
		wall = Color3.fromRGB(120, 112, 96), roof = Color3.fromRGB(80, 74, 62), accent = Color3.fromRGB(170, 130, 70),
	},
}
for _, spec in DEFS do table.freeze(spec) end
table.freeze(DEFS)

-- The electricity grid's two shared numbers, here rather than inside PowerService so the
-- client overlay draws exactly the areas the server wires.
--   * A building takes power from any pole standing inside this radius of it, and two
--     overlapping areas merge into one grid. This is the blue area in the electricity view.
--   * A single span of wire may not exceed PowerMaxSpan, so a drawn run drops poles often
--     enough to stay under it.
-- Measured, not guessed. A deep house's pivot already sits ~29 studs from its kerb
-- (half of a 53-stud footprint plus the setback), the road adds up to another 17, and poles
-- land every PowerSpan studs so a house can be half a span off the nearest one. 26 left
-- most of a street dark with a line running right past it.
ServiceTypes.PowerBuildingReach = 64
ServiceTypes.PowerMaxSpan = 88
-- How a drawn run is laid out. Shared so the client's drag preview shows exactly the poles
-- the server will build, and snaps to the same pole the server will join.
ServiceTypes.PowerSpan = 64      -- poles dropped this far apart along a run
ServiceTypes.PowerSnapDist = 24  -- end a drag this close to a standing pole and it joins it

-- The pipe network's shared numbers, same deal: the client's drag preview and the served
-- band it paints have to be the ones WaterPipeService actually uses.
--   * PipeReach is how far EITHER SIDE of a pipe the service carries -- the pipe is the
--     delivery, the tower is only the source, so a tower with no pipe serves nobody.
--   * PipeSourceReach is how close a pipe END has to be to a tower or plant to tap it.
--     A tower is 32 studs across, so this is "touching the base", not "somewhere nearby".
ServiceTypes.PipeReach = 64
ServiceTypes.PipeSpan = 64       -- one card cost buys this much pipe
ServiceTypes.PipeSnapDist = 20   -- end a drag this close to a pipe joint and it joins it
ServiceTypes.PipeSourceReach = 40
ServiceTypes.PipeMaxRun = 2048
ServiceTypes.PipeDepth = 4       -- every main is laid this far under the surface

ServiceTypes.LOT_SIZE = LOT_SIZE
ServiceTypes.Order = table.freeze({
	"Clinic", "SmallHospital", "Hospital", "GeneralHospital", "PoliceStation", "FireStation", "Cemetery",
	"WindTurbine", "AdvancedWindTurbine", "SolarFarm", "PowerPlant", "BatteryStorage", "PowerPole",
	"WaterTower", "WaterPumpingStation", "UtilityPipe", "WaterPipe", "SewagePipe", "SewagePlant", "SewageOutlet",
})
-- Every utility is ON (2026-09-22). A key out of `Order` gets no card and nothing can place
-- one; old saves keep what they already have.

function ServiceTypes.get(key: string): Spec?
	return DEFS[key]
end

function ServiceTypes.all(): { [string]: Spec }
	return DEFS
end

-- Footprint ground size in studs: X = width along the road, Z = depth back from it.
function ServiceTypes.footprintStuds(spec: Spec): Vector3
	return Vector3.new(spec.widthLots * LOT_SIZE, spec.height, spec.depthLots * LOT_SIZE)
end

return ServiceTypes
