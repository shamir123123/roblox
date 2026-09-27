--!strict
-- MilestoneUnlocks
-- The milestone LADDER (XP thresholds + cash + Development Points) and what each milestone
-- hands the player, free, for growing the city. This is the "you need it, so here it is"
-- half of progression -- the police station, the fire station, the hospital, the schools,
-- the denser residential zones. Reaching the milestone IS the unlock.
--
-- The other half is DevelopmentTree: Development Points buy ADVANCED variants and
-- upgrades WITHIN a service the player already has. Modelled on Cities: Skylines 2.
-- Map tile PERMITS per milestone live beside the tile maths in TerritoryGrid.PERMITS.
--
-- PACING. XP is earned from real city growth (ProgressionService) and credited at no more
-- than XP_RATE_CAP_PER_MIN, in real time, whatever the game speed. Megalopolis needs
-- 22,500 XP, so a perfect player cannot finish in under three hours; a normal one takes
-- five or more, because early cities earn far below the cap. `spec` holds this.
--
-- Pure data, shared: ProgressionService enforces it, the client panel displays it.

local MilestoneUnlocks = {}

export type Milestone = { name: string, xp: number, money: number, dp: number }

export type Grant = {
	summary: string,          -- one line for the milestone detail pane
	placeables: { string }?,  -- ServiceTypes / SchoolTypes / TransitTypes keys
	roads: { string }?,       -- base road-type ids
	zones: { string }?,       -- residential density cards (Low is never gated)
}

MilestoneUnlocks.XP_RATE_CAP_PER_MIN = 125

-- Founding is the state a city starts in rather than one it reaches, so no payout fires
-- for it; its dp seeds the first point so the tree is usable from minute one. DP total is
-- 48 against a DevelopmentTree.totalCost() of 39: finishing every milestone affords the
-- whole tree, so the tree is a question of ORDER.
local LADDER: { Milestone } = {
	{ name = "Founding",               xp = 0,     money = 0,      dp = 1 },
	{ name = "Tiny Village",           xp = 100,   money = 5000,   dp = 1 },
	{ name = "Small Village",          xp = 250,   money = 8000,   dp = 1 },
	{ name = "Large Village",          xp = 450,   money = 12000,  dp = 1 },
	{ name = "Grand Village",          xp = 750,   money = 16000,  dp = 2 },
	{ name = "Tiny Town",              xp = 1150,  money = 20000,  dp = 2 },
	{ name = "Boom Town",              xp = 1650,  money = 25000,  dp = 2 },
	{ name = "Busy Town",              xp = 2250,  money = 30000,  dp = 2 },
	{ name = "Big Town",               xp = 3000,  money = 36000,  dp = 2 },
	{ name = "Great Town",             xp = 3900,  money = 42000,  dp = 2 },
	{ name = "Small City",             xp = 4950,  money = 50000,  dp = 3 },
	{ name = "Big City",               xp = 6150,  money = 60000,  dp = 3 },
	{ name = "Large City",             xp = 7500,  money = 70000,  dp = 3 },
	{ name = "Huge City",              xp = 9000,  money = 80000,  dp = 3 },
	{ name = "Grand City",             xp = 10700, money = 95000,  dp = 3 },
	{ name = "Metropolis",             xp = 12600, money = 110000, dp = 3 },
	{ name = "Thriving Metropolis",    xp = 14700, money = 125000, dp = 3 },
	{ name = "Flourishing Metropolis", xp = 17000, money = 145000, dp = 3 },
	{ name = "Expansive Metropolis",   xp = 19500, money = 165000, dp = 4 },
	{ name = "Megalopolis",            xp = 22500, money = 200000, dp = 4 },
}
for _, m in LADDER do table.freeze(m) end
MilestoneUnlocks.Ladder = table.freeze(LADDER)

-- index = Ladder index.
local GRANTS: { [number]: Grant } = {
	[1] = {
		summary = "Streets, power, water and low-density housing -- everything a settlement needs to exist.",
		roads = { "NarrowRoad", "OneWay", "Alley", "AlleyOneWay" },
		placeables = { "WindTurbine", "PowerPole", "WaterTower", "UtilityPipe", "WaterPipe", "SewagePipe" },
	},
	[2] = {
		summary = "Healthcare: clinics and hospitals treat the sick before illness empties your houses.",
		placeables = { "Clinic", "SmallHospital", "Hospital" },
	},
	[3] = {
		summary = "Medium-density housing, elementary schools, and sewage: from here homes need a drain. Outlets are cheap; pumping stations draw from the shore.",
		placeables = { "Elementary", "SewageOutlet", "WaterPumpingStation" },
		zones = { "Medium" },
	},
	[4] = {
		summary = "Fire & Rescue and Police: the services a town needs once it has something to lose.",
		placeables = { "FireStation", "PoliceStation" },
	},
	[5] = {
		summary = "Mixed housing and public transport: bus depots and stops take cars off your roads.",
		placeables = { "BusDepot", "BusStop" },
		zones = { "Mixed" },
	},
	[6] = {
		summary = "Deathcare and sewage treatment: clean wastewater instead of dumping it.",
		placeables = { "Cemetery", "SewagePlant" },
	},
	[7] = {
		summary = "High-density housing and high schools.",
		placeables = { "HighSchool" },
		zones = { "High" },
	},
	[8] = {
		summary = "Coal and solar power, battery storage, libraries and the general hospital for a city outgrowing its village utilities.",
		placeables = { "PowerPlant", "AdvancedWindTurbine", "SolarFarm", "BatteryStorage", "Library", "GeneralHospital" },
	},
	[9] = {
		summary = "Universities: a highly-educated workforce and the jobs that want one.",
		placeables = { "University" },
	},
	-- TRAINS OFF: milestone 10 used to grant rail track + the Train Station. Restore the
	-- entry (and LastGrantIndex 10) to bring rail back.
}

-- Highest milestone index that grants anything. Past this, milestones pay out only.
MilestoneUnlocks.LastGrantIndex = 9

local placeableAt: { [string]: number } = {}
local roadAt: { [string]: number } = {}
local zoneAt: { [string]: number } = {}
local function indexKeys(list: { string }?, into: { [string]: number }, at: number)
	if not list then return end
	table.freeze(list)
	for _, key in list do into[key] = at end
end
for at, grant in GRANTS do
	indexKeys(grant.placeables, placeableAt, at)
	indexKeys(grant.roads, roadAt, at)
	indexKeys(grant.zones, zoneAt, at)
	table.freeze(grant)
end
table.freeze(GRANTS)

MilestoneUnlocks.Grants = GRANTS
MilestoneUnlocks.PlaceableAt = table.freeze(placeableAt)
MilestoneUnlocks.RoadAt = table.freeze(roadAt)
MilestoneUnlocks.ZoneAt = table.freeze(zoneAt)

-- Milestone index that grants this key, or nil if no milestone does (then it is
-- either a DevelopmentTree purchase or ungated entirely).
function MilestoneUnlocks.placeableMilestone(key: string): number?
	return placeableAt[key]
end

function MilestoneUnlocks.roadMilestone(baseRoadId: string): number?
	return roadAt[baseRoadId]
end

function MilestoneUnlocks.zoneMilestone(density: string): number?
	return zoneAt[density]
end

function MilestoneUnlocks.get(index: number): Grant?
	return GRANTS[index]
end

-- Highest ladder index whose XP threshold `xp` meets. Thresholds ascend.
function MilestoneUnlocks.tierFor(xp: number): number
	local t = 1
	for i, m in LADDER do
		if xp < m.xp then break end
		t = i
	end
	return t
end

return MilestoneUnlocks
