--!strict
-- Tunables for Outside Connections (map-edge road links). Immutable, shared.

local OutsideConnectionConstants = {
	-- How far inward (studs) a connection's stub road runs from the map edge. This
	-- is the drivable piece players hook their own roads onto.
	STUB_LENGTH = 80,

	-- Outer endpoint inset from the exact boundary (studs) so geometry + terrain
	-- height reads stay a hair inside +/-MAP_HALF_EXTENT.
	EDGE_INSET = 2,

	-- Minimum gap (studs) a connection keeps from a map corner along its edge, so a
	-- stub is never wedged into the corner.
	CORNER_MARGIN = 120,

	-- How far BEYOND the edge off-map traffic spawns / despawns (Phase 4+).
	SPAWN_DIST = 160,

	-- Default road class for a new connection (a wide two-way from RoadTypeCatalog).
	DEFAULT_ROAD_TYPE = "CollectorRoad",

	-- Replication: workspace folder holding one marker part per live connection.
	FOLDER_NAME = "_OutsideConnections",

	-- Stable-id prefix. Each connection's id is PREFIX .. n; n is never reused.
	ID_PREFIX = "oc",
}

-- Flow direction through a connection.
OutsideConnectionConstants.Direction = table.freeze({
	IN = "in",     -- traffic / goods only ENTER the city here
	OUT = "out",   -- only LEAVE here
	BOTH = "both", -- both ways (default)
})

-- Which map boundary a connection sits on.
OutsideConnectionConstants.Side = table.freeze({
	EAST = "East",   -- +X
	WEST = "West",   -- -X
	NORTH = "North", -- -Z
	SOUTH = "South", -- +Z
})

-- Arrow tint by direction (client view, Phase 2).
OutsideConnectionConstants.DirColor = table.freeze({
	["in"]   = Color3.fromRGB(95, 200, 120),
	["out"]  = Color3.fromRGB(225, 150, 70),
	["both"] = Color3.fromRGB(228, 228, 236),
})

return table.freeze(OutsideConnectionConstants)
