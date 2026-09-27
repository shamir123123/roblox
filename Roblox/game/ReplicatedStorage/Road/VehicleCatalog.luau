--!strict
-- VehicleCatalog -- the 90 road vehicles the city spawns, as pure data. One Model per key
-- is authored into ServerStorage.Templates.Vehicles by ServerStorage.Authoring.VehicleBuilder,
-- and VehicleFactory clones them. This module holds NO geometry: it states what each vehicle
-- IS (class, segment, tier, fleet share) and how big it is, and the builder turns that into parts.
--
-- WHY THERE IS A TIER AT ALL -- READ THIS BEFORE CHANGING A NUMBER
-- Before this catalog every citizen drew uniformly from five templates, so a trailer park and
-- a waterfront street ran the identical car mix. `tier` (1 beater .. 5 exotic) plus the
-- LV_TIER_WEIGHTS matrix below is the whole fix: land value picks a TIER BAND, then `weight`
-- picks a model inside it. That ordering matters -- weighting all 54 cars by one global share
-- would put a supercar outside a tenement about as often as outside a mansion, just rarely.
--
-- WHERE THE NUMBERS COME FROM -- SAME CAVEAT AS ACUnitCatalog
-- The mm envelopes are modelled from general knowledge of each vehicle class, good to roughly
-- the nearest 50 mm. They are real-world SEGMENT dimensions (a full-size pickup really is
-- ~5.9 m long), not measurements of a specific product, and deliberately so -- see the naming
-- note below. Fleet shares are a plausible US city mix, not a cited statistic; tune them freely.
--
-- NAMING AND COPYRIGHT: every marque here is an invented word and every silhouette the builder
-- draws is generic to its SEGMENT. No entry reproduces a real manufacturer's name, badge or
-- distinctive body shape, which is what keeps the fleet clear of both trademark and Roblox
-- asset moderation. Do not "improve" an entry by making it resemble a specific real car.
--
-- THE ORDER ARRAY IS APPEND-ONLY.
-- Nothing in a save stores a catalog INDEX today (households resolve their car by key), and it
-- must stay that way -- the nature catalog learned this the hard way, where saves stored a
-- POSITION and inserting one tree mid-list corrupted every existing save. Add new vehicles at
-- the END of their class block. Never reorder, never delete: retire a vehicle by setting its
-- weight to 0 so old saves can still resolve the key.
--
-- PART COUNT IS THE COST HERE, NOT DRAW CALLS.
-- Vehicles are the one asset class AssetLODView does NOT tier -- workspace._City's dynamic
-- folders stream their own poses, so there is no baked FAR mesh to collapse a car into. Every
-- part on a car is a part it carries at every distance, on every instance, forever. The builder
-- therefore targets ~22-34 parts; that budget, not visual ambition, is what caps the detail.

local VehicleTypes = require(script.Parent.VehicleTypes)

local VehicleCatalog = {}

export type Entry = {
	key      : string,
	name     : string,
	class    : VehicleTypes.VehicleClass,
	segment  : string,
	-- Geometry archetype. VehicleBuilder.BODY_PROFILE has one entry per value here and
	-- switches on it; a body with no profile fails the build loudly rather than silently
	-- drawing a box.
	body     : string,
	-- 1 beater .. 5 exotic. Drives WHICH BAND land value draws from, never the geometry.
	tier     : number,
	-- Relative share INSIDE its own (class, tier) group. Not a global probability.
	-- 0 retires a vehicle without breaking saves that still name it.
	weight   : number,
	-- Real-world envelope in MILLIMETRES: { length, width, height }. Authored in mm so it
	-- can be checked against a segment spec, and converted exactly once, by the builder.
	mm       : { number },
	-- Wheel DIAMETER in mm (tyre outer, not rim).
	wheelMm  : number,
	-- Palette key into VehicleCatalog.paint. Cars pick a body colour at spawn instead;
	-- this is the fallback and the colour service/commercial vehicles are locked to.
	paint    : string,
}

-- =====================================================================================
-- PAINT
-- Body colours a civilian car may spawn in. Deliberately a SHORT list of believable car
-- colours: real traffic is overwhelmingly white/black/grey/silver, and a rainbow street is
-- the single fastest way to make a city read as a toy. The first four carry most of the fleet.
-- =====================================================================================
VehicleCatalog.paint = table.freeze({
	White      = Color3.fromRGB(232, 233, 235),
	Silver     = Color3.fromRGB(178, 182, 188),
	Grey       = Color3.fromRGB(122, 126, 132),
	Black      = Color3.fromRGB(38, 40, 44),
	Red        = Color3.fromRGB(158, 44, 44),
	Blue       = Color3.fromRGB(52, 84, 138),
	DarkBlue   = Color3.fromRGB(36, 52, 88),
	Green      = Color3.fromRGB(58, 92, 66),
	Beige      = Color3.fromRGB(196, 184, 160),
	Maroon     = Color3.fromRGB(96, 40, 48),
	Yellow     = Color3.fromRGB(214, 172, 52),
	Orange     = Color3.fromRGB(198, 106, 44),
	WhiteVan   = Color3.fromRGB(238, 238, 238),
	FleetBlue  = Color3.fromRGB(40, 70, 120),
	FleetGreen = Color3.fromRGB(44, 88, 62),
	EmergRed   = Color3.fromRGB(176, 32, 32),
	Police     = Color3.fromRGB(28, 32, 40),
	Ambulance  = Color3.fromRGB(240, 240, 242),
	SchoolBus  = Color3.fromRGB(232, 168, 30),
	Transit    = Color3.fromRGB(64, 108, 152),
	Utility    = Color3.fromRGB(226, 176, 44),
	Refuse     = Color3.fromRGB(74, 96, 78),
})

-- Relative frequency of each civilian paint. Independent of tier except that the builder
-- nudges tier 5 toward the darker end, which is what a luxury street actually looks like.
VehicleCatalog.paintWeight = table.freeze({
	White = 24, Silver = 17, Grey = 15, Black = 16,
	Blue = 8, DarkBlue = 5, Red = 6, Green = 3,
	Beige = 3, Maroon = 2, Yellow = 1, Orange = 1,
})

-- =====================================================================================
-- ROWS
-- Positional rather than one frozen table literal per entry (the ACUnitCatalog style): at 90
-- entries the literal form costs ~450 lines of punctuation and makes the fleet impossible to
-- scan or rebalance. Column order is fixed and decoded once, below.
--
--   key, name, segment, body, tier, weight, lengthMm, widthMm, heightMm, wheelMm, paint
-- =====================================================================================

type Row = { any }

-- -------------------------------------------------------------------------------------
-- CARS -- 54 entries. A US city fleet: crossovers and pickups dominate, hatchbacks are
-- a minority, and estates are nearly extinct. Tier 1-2 carry the volume.
-- -------------------------------------------------------------------------------------
local CAR_ROWS: { Row } = {
	-- TIER 1 -- beaters. Old, small, faded. The car a first job buys.
	{ "CarHatchAdet",    "Ardyn A1",        "CityHatch",   "hatch",     1, 10, 3700, 1690, 1500, 580, "Silver" },
	{ "CarHatchBrixe",   "Brixe 3",         "CityHatch",   "hatch",     1,  9, 3820, 1710, 1490, 590, "White" },
	{ "CarSedanCald",    "Caldene 40",      "CompactSdn",  "sedan",     1, 10, 4480, 1760, 1440, 620, "Grey" },
	{ "CarSedanDunm",    "Dunmoor DL",      "CompactSdn",  "sedan",     1,  9, 4520, 1780, 1450, 620, "Beige" },
	{ "CarWagonFenr",    "Fenrow Estate",   "Wagon",       "wagon",     1,  4, 4720, 1770, 1500, 620, "Green" },
	{ "CarSuvHalb",      "Halbrook 2",      "SmallSUV",    "suvSmall",  1,  7, 4300, 1800, 1640, 660, "Maroon" },
	{ "CarPickIven",     "Ivenne 100",      "MidPickup",   "pickupMid", 1,  8, 5200, 1850, 1780, 700, "Blue" },
	{ "CarVanJast",      "Jastra Wagonlet", "Minivan",     "minivan",   1,  5, 4780, 1830, 1720, 640, "Silver" },
	{ "CarCoupeKelv",    "Kelvane SR",      "Coupe",       "coupe",     1,  3, 4460, 1780, 1390, 620, "Red" },
	{ "CarSedanLomv",    "Lomvar Classic",  "MidSedan",    "sedan",     1,  6, 4780, 1810, 1460, 630, "White" },

	-- TIER 2 -- mainstream economy. The single largest slice of the fleet.
	{ "CarHatchMerr",    "Merrow 5",        "CompactHatch","hatch",     2,  8, 4200, 1780, 1480, 620, "White" },
	{ "CarSedanNord",    "Nordell 200",     "CompactSdn",  "sedan",     2, 12, 4610, 1800, 1440, 640, "Silver" },
	{ "CarSedanOstr",    "Ostreth LE",      "MidSedan",    "sedan",     2, 13, 4880, 1840, 1450, 650, "Grey" },
	{ "CarSedanPell",    "Pellan 300",      "MidSedan",    "sedan",     2, 11, 4900, 1850, 1460, 650, "Black" },
	{ "CarSuvQuor",      "Quorra CX",       "SmallSUV",    "suvSmall",  2, 12, 4480, 1830, 1660, 680, "White" },
	{ "CarSuvRenv",      "Renval Trail",    "MidSUV",      "suvMid",    2, 13, 4820, 1900, 1720, 700, "Silver" },
	{ "CarSuvSolv",      "Solvane Path",    "MidSUV",      "suvMid",    2, 11, 4760, 1880, 1700, 700, "Grey" },
	{ "CarPickTarn",     "Tarnick 150",     "FullPickup",  "pickupFull",2, 14, 5890, 2030, 1930, 760, "White" },
	{ "CarPickUlva",     "Ulvane Ranger",   "MidPickup",   "pickupMid", 2, 10, 5350, 1870, 1800, 720, "Blue" },
	{ "CarVanVest",      "Vestral Family",  "Minivan",     "minivan",   2,  8, 5150, 1990, 1760, 660, "Beige" },
	{ "CarHatchWynd",    "Wyndar GT",       "CompactHatch","hatch",     2,  6, 4280, 1790, 1470, 630, "Red" },
	{ "CarCoupeYarr",    "Yarrow Coupe",    "Coupe",       "coupe",     2,  4, 4600, 1820, 1400, 640, "Black" },
	{ "CarWagonZeth",    "Zetheim Tourer",  "Wagon",       "wagon",     2,  4, 4850, 1820, 1500, 640, "DarkBlue" },
	{ "CarSedanArdb",    "Ardyn B2",        "CompactSdn",  "sedan",     2,  9, 4560, 1790, 1435, 630, "Blue" },

	-- TIER 3 -- comfortable mainstream. Bigger, newer, better trimmed.
	{ "CarSedanBrix5",   "Brixe 5",         "MidSedan",    "sedan",     3, 11, 4920, 1860, 1450, 660, "Black" },
	{ "CarSedanCald6",   "Caldene 60",      "LargeSedan",  "sedan",     3,  9, 5050, 1880, 1470, 670, "Silver" },
	{ "CarSuvDunmX",     "Dunmoor XT",      "MidSUV",      "suvMid",    3, 13, 4900, 1920, 1740, 720, "White" },
	{ "CarSuvFenrL",     "Fenrow Lodge",    "FullSUV",     "suvFull",   3, 11, 5180, 2000, 1870, 760, "Grey" },
	{ "CarSuvHalbG",     "Halbrook Grand",  "FullSUV",     "suvFull",   3, 10, 5260, 2010, 1900, 770, "Black" },
	{ "CarPickIvenS",    "Ivenne 250 SC",   "FullPickup",  "pickupFull",3, 12, 6100, 2060, 1980, 790, "DarkBlue" },
	{ "CarPickJastH",    "Jastra Haul",     "FullPickup",  "pickupFull",3, 10, 5980, 2040, 1950, 780, "Maroon" },
	{ "CarVanKelvT",     "Kelvane Tour",    "Minivan",     "minivan",   3,  8, 5220, 2000, 1780, 680, "Silver" },
	{ "CarSedanLomvS",   "Lomvar Signature","LargeSedan",  "sedan",     3,  8, 5090, 1890, 1465, 680, "DarkBlue" },
	{ "CarCoupeMerrC",   "Merrow Club",     "Coupe",       "coupe",     3,  5, 4680, 1850, 1385, 660, "Red" },
	{ "CarSuvNordC",     "Nordell Cross",   "MidSUV",      "suvMid",    3, 10, 4840, 1900, 1710, 710, "Green" },
	{ "CarWagonOstrA",   "Ostreth Avant",   "Wagon",       "wagon",     3,  4, 4960, 1860, 1490, 660, "Grey" },
	{ "CarHatchPellR",   "Pellan RS",       "HotHatch",    "hotHatch",  3,  5, 4340, 1820, 1440, 660, "Yellow" },
	{ "CarSedanQuorE",   "Quorra Executive","LargeSedan",  "sedan",     3,  7, 5010, 1875, 1460, 670, "White" },

	-- TIER 4 -- premium. Executive saloons, big luxury SUVs, proper sports cars.
	{ "CarSedanRenvP",   "Renval Prestige", "Executive",   "sedan",     4, 12, 5180, 1900, 1470, 700, "Black" },
	{ "CarSedanSolvE",   "Solvane Elan",    "Executive",   "sedan",     4, 11, 5120, 1890, 1460, 700, "DarkBlue" },
	{ "CarSuvTarnV",     "Tarnick Vantage", "LuxSUV",      "suvFull",   4, 13, 5300, 2020, 1850, 790, "Black" },
	{ "CarSuvUlvaC",     "Ulvane Crest",    "LuxSUV",      "suvFull",   4, 11, 5220, 2000, 1830, 780, "Silver" },
	{ "CarCoupeVestG",   "Vestral GTC",     "GrandTourer", "coupe",     4,  7, 4880, 1900, 1360, 690, "Maroon" },
	{ "CarSportWyndS",   "Wyndar Spyder",   "Roadster",    "roadster",  4,  5, 4380, 1840, 1280, 670, "Red" },
	{ "CarSedanYarrL",   "Yarrow Lumina",   "Executive",   "sedan",     4,  9, 5060, 1880, 1455, 690, "Grey" },
	{ "CarSuvZethR",     "Zetheim Ridge",   "LuxSUV",      "suvFull",   4, 10, 5150, 1990, 1810, 780, "White" },
	{ "CarSportArdyS",   "Ardyn S7",        "SportsCar",   "sports",    4,  6, 4520, 1880, 1300, 680, "Blue" },
	{ "CarSedanBrixL",   "Brixe L9",        "Executive",   "sedan",     4,  8, 5140, 1895, 1465, 700, "White" },

	-- TIER 5 -- exotics and limousines. Vanishingly rare, and only where land value is top.
	{ "CarExotCaldV",    "Caldene Veloce",  "Supercar",    "supercar",  5, 10, 4520, 1990, 1180, 700, "Red" },
	{ "CarExotDunmF",    "Dunmoor Furia",   "Supercar",    "supercar",  5,  9, 4600, 2010, 1160, 710, "Yellow" },
	{ "CarExotFenrS",    "Fenrow Strada",   "Supercar",    "supercar",  5,  8, 4560, 1980, 1190, 700, "Orange" },
	{ "CarSportHalbR",   "Halbrook R",      "SportsCar",   "sports",    5, 12, 4620, 1920, 1290, 690, "Black" },
	{ "CarLimoIvenS",    "Ivenne State",    "Limousine",   "limo",      5,  9, 6400, 1990, 1500, 720, "Black" },
	{ "CarSedanJastP",   "Jastra Paragon",  "LuxSedan",    "sedan",     5, 14, 5340, 1950, 1500, 720, "DarkBlue" },
}

-- -------------------------------------------------------------------------------------
-- TRUCKS -- 16 entries. Goods vehicles: SupplyService picks these for deliveries, so the
-- small end must outnumber the big end or every corner shop gets a semi.
-- -------------------------------------------------------------------------------------
local TRUCK_ROWS: { Row } = {
	{ "TruckVanCourier", "Kelvane Courier", "CargoVan",    "van",       1, 16, 5100, 1980, 1980, 660, "WhiteVan" },
	{ "TruckVanPanel",   "Lomvar Panel",    "PanelVan",    "van",       1, 15, 5400, 2020, 2100, 680, "WhiteVan" },
	{ "TruckVanHigh",    "Merrow Hightop",  "HighRoofVan", "van",       2, 13, 5900, 2050, 2550, 700, "WhiteVan" },
	{ "TruckVanCrew",    "Nordell Crew",    "CrewVan",     "van",       2, 10, 5700, 2030, 2200, 690, "FleetBlue" },
	{ "TruckBoxSmall",   "Ostreth Box 3",   "SmallBox",    "boxTruck",  2, 12, 6600, 2150, 2900, 760, "WhiteVan" },
	{ "TruckBoxMed",     "Pellan Box 7",    "MediumBox",   "boxTruck",  3, 10, 7800, 2350, 3200, 850, "WhiteVan" },
	{ "TruckBoxLarge",   "Quorra Freight",  "LargeBox",    "boxTruck",  3,  7, 9200, 2450, 3450, 900, "FleetBlue" },
	{ "TruckFlatbed",    "Renval Flatdeck", "Flatbed",     "flatbed",   2,  8, 7400, 2350, 2450, 850, "FleetGreen" },
	{ "TruckTipper",     "Solvane Tipper",  "Tipper",      "tipper",    3,  6, 7100, 2400, 3050, 900, "Utility" },
	{ "TruckMixer",      "Tarnick Mixer",   "CementMixer", "mixer",     4,  4, 8600, 2500, 3600, 950, "Utility" },
	{ "TruckTractor",    "Ulvane Roadmaster","SemiTractor","semiTractor",3, 5, 6800, 2500, 3500, 1000, "FleetBlue" },
	{ "TruckSemiBox",    "Ulvane Linehaul", "SemiBoxRig",  "semiRig",   4,  5,16500, 2550, 4100, 1000, "WhiteVan" },
	{ "TruckTanker",     "Vestral Tanker",  "TankerRig",   "tanker",    4,  3,15800, 2550, 3900, 1000, "Silver" },
	{ "TruckReefer",     "Wyndar Coldline", "Refrigerated","boxTruck",  3,  6, 8400, 2400, 3350, 880, "WhiteVan" },
	{ "TruckTow",        "Yarrow Recovery", "TowTruck",    "tow",       3,  4, 6900, 2280, 2750, 820, "Orange" },
	{ "TruckLogger",     "Zetheim Timber",  "LogHauler",   "flatbed",   3,  2, 9800, 2450, 2900, 950, "FleetGreen" },
}

-- -------------------------------------------------------------------------------------
-- SERVICE -- 8 entries. Municipal vehicles. Class Service shares the kerbside lane with
-- buses and emergency (VehicleTypes.BusLaneClasses), which is why they are not Trucks.
-- -------------------------------------------------------------------------------------
local SERVICE_ROWS: { Row } = {
	{ "SvcRefuseRear",   "Ardyn Sanitation","RefuseTruck", "refuse",    2, 14, 8800, 2500, 3400, 900, "Refuse" },
	{ "SvcRefuseSmall",  "Brixe Kerbside",  "SmallRefuse", "refuse",    2,  9, 7200, 2300, 3050, 820, "Refuse" },
	-- retired 2026-09-25 (weight 0, key kept for old saves): the city runs no street sweeper
	{ "SvcSweeper",      "Caldene Sweeper", "StreetSweeper","sweeper",  2,  0, 6100, 2200, 2900, 760, "Utility" },
	{ "SvcUtilityBucket","Dunmoor Lift",    "BucketTruck", "bucket",    3,  8, 7600, 2350, 3200, 860, "Utility" },
	{ "SvcUtilityVan",   "Fenrow Works",    "UtilityVan",  "van",       2, 15, 5500, 2020, 2250, 680, "Utility" },
	{ "SvcMailVan",      "Halbrook Post",   "MailVan",     "van",       2, 16, 5200, 1990, 2150, 670, "WhiteVan" },
	{ "SvcSnowPlough",   "Ivenne Winter",   "SnowPlough",  "plough",    3,  5, 7800, 2450, 3150, 900, "Utility" },
	{ "SvcTaxi",         "Jastra Cab",      "Taxi",        "sedan",     2, 18, 4900, 1850, 1465, 650, "Yellow" },
}

-- -------------------------------------------------------------------------------------
-- EMERGENCY -- 7 entries. EmergencyVehicleFactory maps its `kind` strings onto these keys;
-- the Emergency folder was empty before this catalog, so every dispatch fell back to a
-- civilian body. Emergency may preempt signals (VehicleTypes.canPreempt).
-- -------------------------------------------------------------------------------------
local EMERGENCY_ROWS: { Row } = {
	{ "EmgPoliceCruiser","Kelvane Patrol",  "PoliceCruiser","sedan",    3, 16, 4980, 1870, 1480, 660, "Police" },
	{ "EmgPoliceSUV",    "Lomvar Interceptor","PoliceSUV", "suvMid",    3, 12, 4900, 1920, 1750, 720, "Police" },
	{ "EmgPoliceVan",    "Merrow Riot",     "PoliceVan",   "van",       3,  5, 5600, 2030, 2300, 700, "Police" },
	{ "EmgAmbulance",    "Nordell Medic",   "Ambulance",   "ambulance", 3, 14, 6200, 2200, 2750, 760, "Ambulance" },
	{ "EmgFirePumper",   "Ostreth Pumper",  "FireEngine",  "fireEngine",4, 12, 8200, 2500, 3300, 950, "EmergRed" },
	{ "EmgFireLadder",   "Pellan Ladder",   "LadderTruck", "fireLadder",4,  7,11400, 2550, 3550, 980, "EmergRed" },
	{ "EmgFireChief",    "Quorra Command",  "ChiefSUV",    "suvFull",   3,  6, 5150, 1990, 1860, 760, "EmergRed" },
}

-- -------------------------------------------------------------------------------------
-- BUSES -- 5 entries. VehicleFactory looks buses up in Templates.Vehicles.Transportation
-- .Buses.Default and exempts them from the alley width cap: 2.55 m IS a real bus.
-- -------------------------------------------------------------------------------------
local BUS_ROWS: { Row } = {
	{ "BusCityRigid",    "Renval Transit",  "CityBus",     "bus",       2, 20,12000, 2550, 3150, 1000, "Transit" },
	{ "BusArticulated",  "Solvane Bendi",   "ArticBus",    "busArtic",  3,  8,18000, 2550, 3150, 1000, "Transit" },
	{ "BusMinibus",      "Tarnick Shuttle", "Minibus",     "minibus",   2, 12, 7200, 2200, 2750, 800, "Transit" },
	{ "BusSchool",       "Ulvane Scholar",  "SchoolBus",   "bus",       2, 14,11000, 2440, 3050, 950, "SchoolBus" },
	{ "BusCoach",        "Vestral Voyager", "Coach",       "coach",     3,  6,12500, 2550, 3600, 1000, "White" },
}

-- =====================================================================================
-- DECODE
-- =====================================================================================

local COL = table.freeze({
	key = 1, name = 2, segment = 3, body = 4, tier = 5,
	weight = 6, len = 7, wid = 8, hei = 9, wheel = 10, paint = 11,
})

VehicleCatalog.order = {} :: { string }
local byKey: { [string]: Entry } = {}

local function ingest(rows: { Row }, class: VehicleTypes.VehicleClass)
	for _, r in rows do
		local key = r[COL.key] :: string
		assert(byKey[key] == nil, "VehicleCatalog: duplicate key " .. key)
		byKey[key] = table.freeze({
			key     = key,
			name    = r[COL.name] :: string,
			class   = class,
			segment = r[COL.segment] :: string,
			body    = r[COL.body] :: string,
			tier    = r[COL.tier] :: number,
			weight  = r[COL.weight] :: number,
			mm      = table.freeze({ r[COL.len] :: number, r[COL.wid] :: number, r[COL.hei] :: number }),
			wheelMm = r[COL.wheel] :: number,
			paint   = r[COL.paint] :: string,
		}) :: Entry
		table.insert(VehicleCatalog.order, key)
	end
end

-- Class blocks are ingested in this order and `order` is append-only WITHIN each block.
ingest(CAR_ROWS,       VehicleTypes.Car)
ingest(TRUCK_ROWS,     VehicleTypes.Truck)
ingest(SERVICE_ROWS,   VehicleTypes.Service)
ingest(EMERGENCY_ROWS, VehicleTypes.Emergency)
ingest(BUS_ROWS,       VehicleTypes.Bus)

VehicleCatalog.byKey = table.freeze(byKey)
table.freeze(VehicleCatalog.order)

-- =====================================================================================
-- SELECTION
-- =====================================================================================

-- Land value (0..1) -> relative weight over tiers 1..5. Five bands rather than a formula so
-- the mix of any given district can be read and tuned directly.
--
-- Read the corners: a bottom band never produces a tier 5 AT ALL (a supercar in a slum is the
-- single most immersion-breaking car the old uniform picker could spawn), and a top band still
-- produces tier 2s, because rich streets do have ordinary cars parked on them. The gradient in
-- between is deliberately gentle -- a hard cutoff makes districts read as colour-coded.
local LV_TIER_WEIGHTS = table.freeze({
	table.freeze({ 55, 30, 12,  3,  0 }), -- lv < 0.20  struggling
	table.freeze({ 30, 38, 22,  9,  1 }), -- lv < 0.40  modest
	table.freeze({ 14, 30, 34, 18,  4 }), -- lv < 0.60  average
	table.freeze({  5, 18, 34, 32, 11 }), -- lv < 0.80  comfortable
	table.freeze({  2,  8, 25, 40, 25 }), -- lv >= 0.80 affluent
})

local function bandFor(lv: number): number
	return math.clamp(math.floor(math.clamp(lv, 0, 1) * 5) + 1, 1, 5)
end

-- Keys of one class and tier, in catalog order. Built once: the fleet never changes at runtime.
local _byClassTier: { [string]: { string } } = {}
for _, key in VehicleCatalog.order do
	local e = byKey[key]
	local bucket = e.class .. tostring(e.tier)
	local list = _byClassTier[bucket]
	if not list then list = {}; _byClassTier[bucket] = list end
	table.insert(list, key)
end

-- Weighted pick over a key list. `roll` is 0..1 so the caller owns the randomness -- that is
-- what lets a household derive a STABLE car from its own id instead of re-rolling every load.
local function weightedPick(keys: { string }, roll: number): string?
	if #keys == 0 then return nil end
	local total = 0
	for _, k in keys do total += byKey[k].weight end
	if total <= 0 then return keys[1] end
	local target = math.clamp(roll, 0, 0.999999) * total
	local acc = 0
	for _, k in keys do
		acc += byKey[k].weight
		if target < acc then return k end
	end
	return keys[#keys]
end

function VehicleCatalog.get(key: string): Entry?
	return byKey[key]
end

function VehicleCatalog.forClass(class: string): { string }
	local out = {}
	for _, key in VehicleCatalog.order do
		if byKey[key].class == class then table.insert(out, key) end
	end
	return out
end

function VehicleCatalog.forClassTier(class: string, tier: number): { string }
	return _byClassTier[class .. tostring(tier)] or {}
end

-- Picks a TIER for a land value. Two rolls, not one: tierRoll chooses the band's tier and
-- modelRoll chooses within it, so a caller with one stable seed can vary one and fix the other.
function VehicleCatalog.tierForLandValue(lv: number, tierRoll: number): number
	local w = LV_TIER_WEIGHTS[bandFor(lv)]
	local total = 0
	for _, x in w do total += x end
	local target = math.clamp(tierRoll, 0, 0.999999) * total
	local acc = 0
	for tier, x in w do
		acc += x
		if target < acc then return tier end
	end
	return 3
end

-- THE MAIN ENTRY POINT for civilian traffic. Returns a catalog key.
-- Falls DOWN then UP through neighbouring tiers if a band is empty, so a class that has no
-- tier 5 (trucks, buses) still resolves instead of returning nil at the top of the range.
function VehicleCatalog.pick(class: string, lv: number, tierRoll: number, modelRoll: number): string?
	local tier = VehicleCatalog.tierForLandValue(lv, tierRoll)
	for step = 0, 4 do
		for _, t in { tier - step, tier + step } do
			if t >= 1 and t <= 5 then
				local keys = VehicleCatalog.forClassTier(class, t)
				if #keys > 0 then
					local k = weightedPick(keys, modelRoll)
					if k then return k end
				end
			end
		end
	end
	return nil
end

-- Picks ignoring land value -- for classes whose model is a role, not a status symbol
-- (a refuse truck is a refuse truck on every street).
function VehicleCatalog.pickAnyOfClass(class: string, roll: number): string?
	return weightedPick(VehicleCatalog.forClass(class), roll)
end

-- Deterministic 0..1 from an integer id and a salt. Households call this with their own
-- stable id so the family keeps the SAME car across saves without the save storing anything
-- new -- and, critically, without storing a catalog INDEX, which is the thing that made the
-- nature catalog unsafe to reorder.
function VehicleCatalog.roll(id: number, salt: number): number
	local h = (id * 2654435761 + salt * 40503) % 2147483647
	h = (h * 1103515245 + 12345) % 2147483647
	return h / 2147483647
end

-- A believable body colour. Tier 5 is biased dark/red because that is what the top of the
-- market actually looks like; everything else draws the normal traffic palette.
function VehicleCatalog.paintFor(entry: Entry, roll: number): Color3
	if entry.class ~= VehicleTypes.Car then
		return VehicleCatalog.paint[entry.paint] or VehicleCatalog.paint.White
	end
	local total = 0
	for _, w in VehicleCatalog.paintWeight do total += w end
	local target = math.clamp(roll, 0, 0.999999) * total
	local acc = 0
	for name, w in VehicleCatalog.paintWeight do
		acc += w
		if target < acc then return VehicleCatalog.paint[name] end
	end
	return VehicleCatalog.paint.White
end

return VehicleCatalog
