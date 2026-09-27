--!strict
-- DevelopmentTree
-- Shared, immutable catalog of the Development Tree: the DP-purchasable unlock nodes
-- (CS2-style). Read by ProgressionService (owns XP/DP state, validates unlocks and
-- placement gating) and the client progression panel (renders the tree). Pure data --
-- no lifecycle, no side effects on require.
--
-- The DP half of progression. Everything here is OPTIONAL and BOUGHT.
--
-- The city's actual needs -- police station, fire station, hospital, schools, the
-- basic road set -- are handed out free by MILESTONES (see MilestoneUnlocks). This
-- tree only sells what goes ON TOP of a service the player already has: advanced road
-- classes, and permanent upgrades that make a service reach further and field more
-- vehicles. A player who never opens this panel still has a complete, playable city.
--
-- Modelled on Cities: Skylines 2, including its tier pricing -- tier 1 costs 1 point,
-- tier 2 costs 2, tier 3 costs 4, tier 4 costs 8 -- and its one-tree-per-service
-- shape. Finishing every milestone banks more points than the whole tree costs, so
-- the tree is a choice about ORDER, not a wall.
--
-- `boost` multiplies a funding category's EFFECT (coverage radius, fleet size, school
-- capacity) without raising its upkeep -- see CityEconomyService.getFunding.
--
-- `roads` lists the BASE road-type ids the node gates (per-placement config suffixes
-- "|k=v" are stripped before lookup); `placeables` lists ServiceTypes / SchoolTypes /
-- TransitTypes keys. Anything neither a node nor a milestone claims is never gated.

local DevelopmentTree = {}

export type Node = {
	id: string,
	name: string,
	desc: string,
	cat: string,
	tier: number,
	cost: number,            -- Development Points; 0 = granted free at its milestone
	milestone: number?,      -- MILESTONES index required before this node is available (nil / 1 = from the start)
	requires: { string },    -- node ids that must be unlocked first
	roads: { string }?,      -- base road-type ids gated by this node
	placeables: { string }?, -- ServiceTypes/SchoolTypes/TransitTypes keys gated by this node
	boost: { category: string, mult: number }?, -- EXTRAS only: funding-effect multiplier
}

-- CS2 tier pricing. A node's cost is a function of its depth, nothing else.
local TIER_COST = table.freeze({ 1, 2, 4, 8 })

DevelopmentTree.TierCost = TIER_COST
DevelopmentTree.Categories = table.freeze({ "Roads", "Fire & Rescue", "Police", "Healthcare", "Education", "Utilities" })

local NODES: { Node } = {
	-- Roads. The biggest tree, as in CS2: each node is a new road class on top of the
	-- basic streets every city starts with.
	{ id = "road_collector", name = "Collector Roads", desc = "Wider avenues and multi-lane one-way roads.",
		cat = "Roads", tier = 1, cost = TIER_COST[1], requires = {},
		roads = { "CollectorRoad", "OneWay2Lane", "OneWay3Lane" } },
	{ id = "road_bus_lanes", name = "Bus Lanes", desc = "Kerbside bus lanes, and dedicated busways only buses and emergency vehicles may use.",
		cat = "Roads", tier = 2, cost = TIER_COST[2], requires = { "road_collector" },
		roads = { "CollectorRoadBus", "OneWay3LaneBus", "BuswayOneWay", "BuswayTwoWay" } },
	{ id = "road_roundabout", name = "Roundabouts", desc = "Roundabout intersections in three sizes.",
		cat = "Roads", tier = 2, cost = TIER_COST[2], requires = { "road_collector" },
		roads = { "Roundabout", "Roundabout1", "Roundabout3" } },
	{ id = "road_highway", name = "Highways", desc = "High-speed highways and merging ramps.",
		cat = "Roads", tier = 3, cost = TIER_COST[3], requires = { "road_collector" },
		roads = { "Highway2", "Highway1W", "Highway2W" } },
	{ id = "road_highway_major", name = "Major Highways", desc = "Divided and 3-5 lane highway carriageways.",
		cat = "Roads", tier = 4, cost = TIER_COST[4], requires = { "road_highway" },
		roads = { "Highway4", "Highway3W", "Highway4W", "Highway5W" } },

	-- Fire & Rescue. The station itself comes from milestone 4; these make it better.
	{ id = "fire_training", name = "Fire Training Academy", desc = "+25% fire station reach and one more engine on call.",
		cat = "Fire & Rescue", tier = 1, cost = TIER_COST[1], requires = {},
		boost = { category = "Fire", mult = 1.25 } },
	{ id = "fire_aerial", name = "Aerial Fire Response", desc = "A further +25% fire reach and fleet size.",
		cat = "Fire & Rescue", tier = 3, cost = TIER_COST[3], requires = { "fire_training" },
		boost = { category = "Fire", mult = 1.25 } },

	-- Police
	{ id = "police_academy", name = "Police Academy", desc = "+25% police station reach and one more patrol car.",
		cat = "Police", tier = 1, cost = TIER_COST[1], requires = {},
		boost = { category = "Police", mult = 1.25 } },
	{ id = "police_air", name = "Police Helicopter Unit", desc = "A further +25% police reach and fleet size.",
		cat = "Police", tier = 3, cost = TIER_COST[3], requires = { "police_academy" },
		boost = { category = "Police", mult = 1.25 } },

	-- Healthcare
	{ id = "health_medschool", name = "Medical School", desc = "+25% hospital reach and one more ambulance.",
		cat = "Healthcare", tier = 1, cost = TIER_COST[1], requires = {},
		boost = { category = "Health", mult = 1.25 } },
	{ id = "health_air_ambulance", name = "Air Ambulance", desc = "A further +25% hospital reach and fleet size.",
		cat = "Healthcare", tier = 3, cost = TIER_COST[3], requires = { "health_medschool" },
		boost = { category = "Health", mult = 1.25 } },

	-- Education
	{ id = "edu_teacher_training", name = "Teacher Training", desc = "+25% school reach and class sizes.",
		cat = "Education", tier = 1, cost = TIER_COST[1], requires = {},
		boost = { category = "Education", mult = 1.25 } },
	{ id = "edu_research", name = "Research Grants", desc = "A further +25% school reach and class sizes.",
		cat = "Education", tier = 3, cost = TIER_COST[3], requires = { "edu_teacher_training" },
		boost = { category = "Education", mult = 1.25 } },

	-- Utilities. Same lever, applied to the power and water coverage radii.
	{ id = "util_grid", name = "National Grid", desc = "+25% reach on every power source.",
		cat = "Utilities", tier = 2, cost = TIER_COST[2], requires = {},
		boost = { category = "Power", mult = 1.25 } },
	{ id = "util_mains", name = "Mains Pressure", desc = "+25% reach on every water source.",
		cat = "Utilities", tier = 2, cost = TIER_COST[2], requires = {},
		boost = { category = "Water", mult = 1.25 } },
}

local byId: { [string]: Node } = {}
local roadNode: { [string]: string } = {}
local placeableNode: { [string]: string } = {}
for _, node in NODES do
	table.freeze(node.requires)
	local roads = node.roads
	if roads then
		table.freeze(roads)
		for _, r in roads do roadNode[r] = node.id end
	end
	local placeables = node.placeables
	if placeables then
		table.freeze(placeables)
		for _, p in placeables do placeableNode[p] = node.id end
	end
	if node.boost then table.freeze(node.boost) end
	table.freeze(node)
	byId[node.id] = node
end

DevelopmentTree.Nodes = table.freeze(NODES)
DevelopmentTree.ById = table.freeze(byId)
DevelopmentTree.RoadNode = table.freeze(roadNode)
DevelopmentTree.PlaceableNode = table.freeze(placeableNode)

-- Base id of a possibly config-encoded road type ("CollectorRoad|md=c" -> "CollectorRoad").
function DevelopmentTree.baseRoadId(roadType: string): string
	local sepAt = string.find(roadType, "|", 1, true)
	return if sepAt then string.sub(roadType, 1, sepAt - 1) else roadType
end

-- Total DP cost of every purchasable node (sanity ceiling for milestone DP rewards).
function DevelopmentTree.totalCost(): number
	local sum = 0
	for _, node in NODES do sum += node.cost end
	return sum
end

-- Milestone index this node needs the city to have reached. 1 = available immediately.
function DevelopmentTree.milestoneFor(id: string): number
	local node = byId[id]
	return if node and node.milestone then node.milestone else 1
end

-- True if this node is a free milestone grant rather than a DP purchase. The client
-- panel uses it to label the two halves of the tree differently.
function DevelopmentTree.isGranted(id: string): boolean
	local node = byId[id]
	return node ~= nil and node.cost == 0
end

return DevelopmentTree
