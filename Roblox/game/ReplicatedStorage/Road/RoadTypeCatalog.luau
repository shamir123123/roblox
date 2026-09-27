--!strict

local RoadConstants = require(script.Parent.RoadConstants)
local VehicleTypes = require(script.Parent.VehicleTypes)

-- Width (studs) of a planted grass verge carved off a carriageway edge (median left/both).
local VERGE_WIDTH = 4 * RoadConstants.WORLD_SCALE

export type RoadTypeSpec = {
	id: string,
	name: string,
	width: number,
	laneCount: number,
	surfaceColor: Color3,
	centerLineColor: Color3?,
	centerLineWidth: number,
	centerLineDashed: boolean?,
	centerLineDouble: boolean?,
	edgeLineColor: Color3?,
	-- Left-edge colour, when it differs from the right. See RoadRenderer.Options.
	edgeLineColorLeft: Color3?,
	edgeLineWidth: number?,
	laneLineColor: Color3?,
	laneLineWidth: number?,
	laneLineDashed: boolean?,
	oneWay: boolean?,
	-- Highway family: no sidewalks/crosswalks, highway-only junctions stay signal-free
	-- (RoadRules.nodeControl) and one-way highways drawn into a highway body join as
	-- merging ramps (RoadPlacementSnapper).
	isHighway: boolean?,
	parkingLane: boolean?,
	parkingLaneWidth: number?,
	-- Sides that carry the parking apron; default 2 (both kerbs, incl. one-way roads).
	-- A spec opts down to 1 explicitly; the model never single-sides on its own.
	parkingSides: number?,
	parkingSide: string?, -- "left" | "right" | "both": which kerb(s) carry the parking apron
	costPerMeter: number?,   -- build price per metre (interactive placement). Falls back to RoadConstants.ROAD_COST_PER_METER.
	median: boolean?,
	medianWidth: number?,
	medianColor: Color3?,
	-- Per-road config, decoded from an encoded roadType id (see RoadConfig below).
	sidewalkMode: string?, -- "none" | "left" | "right" | "both"; nil = both
	vergeMode: string?,    -- "left" | "both": planted grass strip carved off the carriageway edge(s)
	vergeWidth: number?,
	guardrail: boolean?,
	guardrailWidth: number?,
	guardrailHeight: number?,
	noSidewalk: boolean?,
	noCrosswalk: boolean?,
	-- Terrain path: no asphalt slab. Placement paints the terrain along the footprint with
	-- terrainMaterialId and drops an invisible drivable pad instead (RoadSceneRenderer +
	-- TerrainGradeService). Cars + sims use it through the nav graph like any other road.
	terrainPath: boolean?,
	terrainMaterialId: number?, -- TerrainConstants.Material id: 3 = ROCK (gravel), 5 = GROUND (dirt)
	speedLimit: number,
	allowedVehicles: { [string]: boolean }?,
	-- Kerbside lane of each direction is bus/emergency/service only (RoadRules.laneAllowedVehicleSet)
	-- and renders as a red band. Ignored where a direction has a single lane -- restricting that
	-- would block all traffic. Set per placement via the "bl" config code below.
	busLane: boolean?,
	-- Railway track: ballast slab + steel rails instead of asphalt + markings. Trains
	-- only (allowedVehicles); excluded from the car nav graph, routed on the rail graph.
	isRail: boolean?,
	-- Street trees: a ReplicatedStorage.Nature model key, planted along both kerbs by
	-- RoadSceneRenderer. Set per placement via the "tr" config code below.
	streetTrees: string?,
}

local NarrowRoad: RoadTypeSpec = table.freeze({
	id = "NarrowRoad",
	name = "Street",
	costPerMeter = 14,
	-- parkingSides marks a street type as PARKING-CAPABLE: the road tool turns parking on
	-- ("pk=b") for every new placement of one, so a road drawn from now on parks both kerbs.
	-- The base stays parkingLane = false so already-placed segments -- which persist the bare
	-- id -- keep the exact geometry they were built with. 10 authored = 5 world studs, and
	-- VehicleFactory caps a civilian car at 4.5 wide, so a parked car clears the travel lane.
	parkingLane = false,
	parkingLaneWidth = 10,
	parkingSides = 2,
	width = 36,
	laneCount = 2,
	speedLimit = 50,
	surfaceColor = RoadConstants.ROAD_COLOR,
	centerLineColor = RoadConstants.MARKING_YELLOW,
	centerLineWidth = 0.8,
	centerLineDashed = true,
	edgeLineColor = RoadConstants.MARKING_WHITE,
	edgeLineWidth = 0.6,
	laneLineColor = RoadConstants.MARKING_WHITE,
	laneLineWidth = 0.5,
	laneLineDashed = true,
})

local CollectorRoad: RoadTypeSpec = table.freeze({
	id = "CollectorRoad",
	name = "Avenue",
	costPerMeter = 28,
	parkingLane = false,
	parkingLaneWidth = 10,
	parkingSides = 2,
	width = 60,
	laneCount = 4,
	speedLimit = 70,
	surfaceColor = RoadConstants.ROAD_COLOR,
	-- Double solid yellow: MUTCD §3B.01 makes it mandatory on an undivided two-way road
	-- of four or more lanes.
	centerLineColor = RoadConstants.MARKING_YELLOW,
	centerLineWidth = 1.0,
	centerLineDouble = true,
	edgeLineColor = RoadConstants.MARKING_WHITE,
	edgeLineWidth = 0.8,
	laneLineColor = RoadConstants.MARKING_WHITE,
	laneLineWidth = 0.6,
	laneLineDashed = true,
})

local OneWay: RoadTypeSpec = table.freeze({
	id = "OneWay",
	name = "One-Way",
	costPerMeter = 10,
	width = 12,
	laneCount = 1,
	speedLimit = 50,
	surfaceColor = RoadConstants.ROAD_COLOR,
	centerLineColor = nil,
	centerLineWidth = 0,
	centerLineDashed = false,
	-- One-way carriageway: white right edge, yellow left edge (MUTCD §3A.03).
	edgeLineColor = RoadConstants.MARKING_WHITE,
	edgeLineColorLeft = RoadConstants.MARKING_YELLOW,
	edgeLineWidth = 0.8,
	oneWay = true,
})

local OneWay2Lane: RoadTypeSpec = table.freeze({
	id = "OneWay2Lane",
	name = "One-Way 2L",
	costPerMeter = 16,
	parkingLane = false,
	parkingLaneWidth = 10,
	parkingSides = 2,
	width = 36,
	laneCount = 2,
	speedLimit = 60,
	surfaceColor = RoadConstants.ROAD_COLOR,
	centerLineColor = nil,
	centerLineWidth = 0,
	centerLineDashed = false,
	edgeLineColor = RoadConstants.MARKING_WHITE,
	edgeLineColorLeft = RoadConstants.MARKING_YELLOW,
	edgeLineWidth = 0.8,
	laneLineColor = RoadConstants.MARKING_WHITE,
	laneLineWidth = 0.6,
	laneLineDashed = true,
	oneWay = true,
})

local OneWay3Lane: RoadTypeSpec = table.freeze({
	id = "OneWay3Lane",
	name = "One-Way 3L",
	costPerMeter = 22,
	parkingLane = false,
	parkingLaneWidth = 10,
	parkingSides = 2,
	width = 48,
	laneCount = 3,
	speedLimit = 70,
	surfaceColor = RoadConstants.ROAD_COLOR,
	centerLineColor = nil,
	centerLineWidth = 0,
	centerLineDashed = false,
	edgeLineColor = RoadConstants.MARKING_WHITE,
	edgeLineColorLeft = RoadConstants.MARKING_YELLOW,
	edgeLineWidth = 0.8,
	laneLineColor = RoadConstants.MARKING_WHITE,
	laneLineWidth = 0.6,
	laneLineDashed = true,
	oneWay = true,
})

-- == Highways ================================================================
-- One catalog family, seven members: two two-way highways and one-way carriageways
-- of 1-5 lanes. The 1-lane one-way doubles as the ramp: drawn into another highway's
-- body it bends to merge with the host's travel direction instead of forming a
-- crossing (see RoadPlacementSnapper). All are kerb-only: no sidewalk, no crosswalk,
-- no parking.
local function highwaySpec(id: string, name: string, lanes: number, width: number, speed: number, cost: number, twoWay: boolean, median: boolean): RoadTypeSpec
	return table.freeze({
		id = id,
		name = name,
		costPerMeter = cost,
		width = width,
		laneCount = lanes,
		speedLimit = speed,
		surfaceColor = RoadConstants.ROAD_COLOR,
		centerLineColor = if twoWay and not median then RoadConstants.MARKING_YELLOW else nil,
		centerLineWidth = if twoWay and not median then 0.8 else 0,
		centerLineDashed = if twoWay and not median then true else nil,
		edgeLineColor = RoadConstants.MARKING_WHITE,
		-- A one-way carriageway (ramp or one direction of a divided highway) carries a
		-- yellow left edge line; a two-way road's outer edges are both right-hand edges
		-- and stay white.
		edgeLineColorLeft = if twoWay then nil else RoadConstants.MARKING_YELLOW,
		edgeLineWidth = 1.0,
		laneLineColor = RoadConstants.MARKING_WHITE,
		laneLineWidth = 0.6,
		laneLineDashed = true,
		oneWay = if twoWay then nil else true,
		isHighway = true,
		median = if median then true else nil,
		medianWidth = if median then 6 else nil,
		noSidewalk = true,
		noCrosswalk = true,
	}) :: RoadTypeSpec
end

local Highway2  = highwaySpec("Highway2",  "Highway",     2, 34, 80,  45, true,  false)
local Highway4  = highwaySpec("Highway4",  "Divided Hwy", 4, 68, 100, 80, true,  true)
local Highway1W = highwaySpec("Highway1W", "Ramp",        1, 20, 80,  24, false, false)
local Highway2W = highwaySpec("Highway2W", "Hwy 2L",      2, 34, 100, 40, false, false)
local Highway3W = highwaySpec("Highway3W", "Hwy 3L",      3, 48, 120, 55, false, false)
local Highway4W = highwaySpec("Highway4W", "Hwy 4L",      4, 62, 120, 70, false, false)
local Highway5W = highwaySpec("Highway5W", "Hwy 5L",      5, 76, 120, 85, false, false)

-- Bus-lane variants: the same carriageway as the base road, with the kerbside lane of each
-- direction restricted to buses/emergency/service (RoadRules.laneAllowedVehicleSet) and
-- painted red. Their own catalog entries -- a road you draw, not a per-road option.
local function withBusLane(base: RoadTypeSpec, id: string, name: string, cost: number): RoadTypeSpec
	local d: any = table.clone(base)
	d.id = id
	d.name = name
	d.costPerMeter = cost
	d.busLane = true
	return table.freeze(d) :: RoadTypeSpec
end

local CollectorRoadBus = withBusLane(CollectorRoad, "CollectorRoadBus", "Bus Avenue", 34)
local OneWay3LaneBus = withBusLane(OneWay3Lane, "OneWay3LaneBus", "Bus One-Way", 26)

-- Dedicated busways: EVERY lane is bus/emergency/service only, so the whole carriageway
-- is red asphalt rather than a painted band. Ordinary traffic is never routed onto them.
local BuswayOneWay: RoadTypeSpec = table.freeze({
	id = "BuswayOneWay",
	name = "Busway 1-Way",
	costPerMeter = 12,
	width = 14,
	laneCount = 1,
	speedLimit = 50,
	oneWay = true,
	surfaceColor = RoadConstants.BUS_LANE_COLOR,
	centerLineColor = nil,
	centerLineWidth = 0,
	edgeLineColor = RoadConstants.MARKING_WHITE,
	edgeLineWidth = 0.6,
	allowedVehicles = VehicleTypes.BusLaneClasses,
	noCrosswalk = true,
})

local BuswayTwoWay: RoadTypeSpec = table.freeze({
	id = "BuswayTwoWay",
	name = "Busway",
	costPerMeter = 20,
	width = 28,
	laneCount = 2,
	speedLimit = 50,
	surfaceColor = RoadConstants.BUS_LANE_COLOR,
	centerLineColor = RoadConstants.MARKING_WHITE,
	centerLineWidth = 0.8,
	centerLineDashed = true,
	edgeLineColor = RoadConstants.MARKING_WHITE,
	edgeLineWidth = 0.6,
	allowedVehicles = VehicleTypes.BusLaneClasses,
	noCrosswalk = true,
})

local RoadTypeCatalog = {}

RoadTypeCatalog.DEFAULT_ID = "NarrowRoad"

local Alley: RoadTypeSpec = table.freeze({
	id = "Alley",
	name = "Alley",
	costPerMeter = 8,
	width = 18,
	laneCount = 2,
	speedLimit = 15,
	surfaceColor = RoadConstants.ROAD_COLOR,
	centerLineColor = nil,
	centerLineWidth = 0,
	noSidewalk = true,
	noCrosswalk = true,
})

local AlleyOneWay: RoadTypeSpec = table.freeze({
	id = "AlleyOneWay",
	name = "Alley 1-Way",
	costPerMeter = 6,
	width = 9,
	laneCount = 1,
	speedLimit = 15,
	surfaceColor = RoadConstants.ROAD_COLOR,
	centerLineColor = nil,
	centerLineWidth = 0,
	oneWay = true,
	noSidewalk = true,
	noCrosswalk = true,
})

-- == Rail ===================================================================
-- Double-track railway: two-way, one track per direction (laneCount 2 drives the
-- track centers exactly like lane centers). Trains only -- cars never see these
-- segments because RoadService builds its nav graph with rail filtered out.
local Rail: RoadTypeSpec = table.freeze({
	id = "Rail",
	name = "Rail",
	costPerMeter = 35,
	width = 24,
	laneCount = 2,
	speedLimit = 120,
	surfaceColor = Color3.fromRGB(104, 99, 93), -- ballast
	centerLineColor = nil,
	centerLineWidth = 0,
	noSidewalk = true,
	noCrosswalk = true,
	allowedVehicles = { Train = true },
	isRail = true,
})

-- The circulating carriageway of a roundabout: one-way rings in three lane counts
-- matched to the tool's size presets (Small=1, Medium=2, Large=3 lanes). Placed by
-- the roundabout tool only -- deliberately kept OUT of Order so they never show as
-- hand-drawable road types, only as the ring the tool stamps.
local Roundabout: RoadTypeSpec = table.freeze({
	id = "Roundabout",
	name = "Roundabout",
	costPerMeter = 20,
	width = 30,
	laneCount = 2,
	speedLimit = 25,
	oneWay = true,
	surfaceColor = RoadConstants.ROAD_COLOR,
	centerLineColor = nil,
	centerLineWidth = 0,
	edgeLineColor = RoadConstants.MARKING_WHITE,
	edgeLineWidth = 0.8,
	laneLineColor = RoadConstants.MARKING_WHITE,
	laneLineWidth = 0.5,
	laneLineDashed = true,
	noCrosswalk = true,
})

local Roundabout1: RoadTypeSpec = table.freeze({
	id = "Roundabout1",
	name = "Roundabout (1 lane)",
	costPerMeter = 16,
	width = 18,
	laneCount = 1,
	speedLimit = 20,
	oneWay = true,
	surfaceColor = RoadConstants.ROAD_COLOR,
	centerLineColor = nil,
	centerLineWidth = 0,
	edgeLineColor = RoadConstants.MARKING_WHITE,
	edgeLineWidth = 0.8,
	noCrosswalk = true,
})

local Roundabout3: RoadTypeSpec = table.freeze({
	id = "Roundabout3",
	name = "Roundabout (3 lanes)",
	costPerMeter = 26,
	width = 44,
	laneCount = 3,
	speedLimit = 30,
	oneWay = true,
	surfaceColor = RoadConstants.ROAD_COLOR,
	centerLineColor = nil,
	centerLineWidth = 0,
	edgeLineColor = RoadConstants.MARKING_WHITE,
	edgeLineWidth = 0.8,
	laneLineColor = RoadConstants.MARKING_WHITE,
	laneLineWidth = 0.5,
	laneLineDashed = true,
	noCrosswalk = true,
})

RoadTypeCatalog.Types = table.freeze({
	OneWay        = OneWay,
	Roundabout    = Roundabout,
	Roundabout1   = Roundabout1,
	Roundabout3   = Roundabout3,
	OneWay2Lane   = OneWay2Lane,
	OneWay3Lane   = OneWay3Lane,
	NarrowRoad    = NarrowRoad,
	CollectorRoad = CollectorRoad,
	CollectorRoadBus = CollectorRoadBus,
	OneWay3LaneBus   = OneWay3LaneBus,
	BuswayOneWay     = BuswayOneWay,
	BuswayTwoWay     = BuswayTwoWay,
	Alley         = Alley,
	AlleyOneWay   = AlleyOneWay,
	Rail          = Rail,
	Highway2      = Highway2,
	Highway4      = Highway4,
	Highway1W     = Highway1W,
	Highway2W     = Highway2W,
	Highway3W     = Highway3W,
	Highway4W     = Highway4W,
	Highway5W     = Highway5W,
} :: { [string]: RoadTypeSpec })

-- Half-size world (RoadConstants.WORLD_SCALE): every spec authors its widths at full size,
-- so scale the width-family fields once here. The catalog is the single width source the
-- renderer + nav derive from, so this halves road carriageways, lanes and offsets coherently.
do
	local WS = RoadConstants.WORLD_SCALE
	if WS ~= 1 then
		local WIDTH_KEYS = { "width", "parkingLaneWidth", "medianWidth", "vergeWidth", "guardrailWidth", "guardrailHeight" }
		local scaled: { [string]: RoadTypeSpec } = {}
		for id, spec in RoadTypeCatalog.Types do
			local t: any = table.clone(spec)
			for _, k in WIDTH_KEYS do
				if type(t[k]) == "number" then t[k] = t[k] * WS end
			end
			scaled[id] = table.freeze(t)
		end
		RoadTypeCatalog.Types = table.freeze(scaled)
	end
end

RoadTypeCatalog.Order = table.freeze({
	"NarrowRoad",
	"Alley",
	"AlleyOneWay",
	-- TRAINS OFF: "Rail" is kept OUT of Order so track is not hand-drawable, same trick as
	-- Roundabout above. The spec still exists, so saved cities keep their track.
	"CollectorRoad",
	"CollectorRoadBus",
	"OneWay",
	"OneWay2Lane",
	"OneWay3Lane",
	"OneWay3LaneBus",
	"BuswayTwoWay",
	"BuswayOneWay",
	"Highway2",
	"Highway4",
	"Highway1W",
	"Highway2W",
	"Highway3W",
	"Highway4W",
	"Highway5W",
})

-- Inner driving surface (carriageway) for a spec: the total width minus the parking
-- apron carved off each active side. Driving lanes, lane/edge markings and the nav
-- graph all derive from THIS so cars stay centred in the carriageway, never the apron.
-- Roads without a parking lane use their full width unchanged.
function RoadTypeCatalog.carriagewayWidth(spec: RoadTypeSpec): number
	-- A parking apron and a planted verge each carve drivable width off the edge(s), and a
	-- road may carry BOTH (verge outermost). They shrink the carriageway identically here so
	-- the nav graph, parking and renderer all agree on where cars may drive.
	local carve = 0
	if spec.parkingLane then
		carve += (spec.parkingSides or 2) * (spec.parkingLaneWidth or 0)
	end
	if spec.vergeMode then
		carve += (if spec.vergeMode == "both" then 2 else 1) * (spec.vergeWidth or VERGE_WIDTH)
	end
	if carve <= 0 then
		return spec.width
	end
	-- Floor it so a misconfigured spec can never collapse the carriageway.
	return math.max(spec.width - carve, spec.width * 0.4)
end

-- Apron width on the (+side, -side). +side always carries the apron when a parking
-- lane is present; the -side only when parkingSides >= 2 (the default).
function RoadTypeCatalog.parkingApron(spec: RoadTypeSpec): (number, number)
	if not spec.parkingLane then
		return 0, 0
	end
	local plW = spec.parkingLaneWidth or 0
	local sides = spec.parkingSides or 2
	if sides >= 2 then
		return plW, plW
	end
	return plW, 0
end

-- Tightest centerline radius a road of this type may be drawn at. The inner edge of a
-- curve sits at (radius - halfWidth - sidewalk); below the value returned here that inner
-- curb pinches to a cusp and self-intersects (the mangled inside of a hairpin turn).
-- Derived from the road's own width so wide avenues are held to gentler curves than narrow
-- alleys, instead of one global limit that fit neither. Sidewalk-less roads (alleys) only
-- need clearance past their own carriageway edge.
function RoadTypeCatalog.minCurveRadius(spec: RoadTypeSpec): number
	local sidewalk = if spec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH
	return spec.width * 0.5 + sidewalk + RoadConstants.CURVE_INNER_EDGE_CLEARANCE
end

-- The radius below which a corner connector's inner edge inverts and folds through itself
-- (a degree-2 bend's mangled inside). Unlike minCurveRadius this carries NO extra clearance:
-- a corner connector is short, so a pinched-but-not-inverted bend renders fine -- only the
-- actual fold is rejected. Equals the inner-edge offset: half-width plus the sidewalk.
function RoadTypeCatalog.minCornerRadius(spec: RoadTypeSpec): number
	local sidewalk = if spec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH
	return spec.width * 0.5 + sidewalk
end

-- == Per-road config ========================================================
-- A road's per-placement options (sidewalk side, median style, surface colour, speed
-- limit) are encoded INTO its roadType id as "BaseId|k=v;k=v". Every system already
-- resolves a road through get()/getOrDefault(id), so carrying the config in the id means
-- it persists, replicates, serialises, undoes and feeds the nav graph for free -- no new
-- per-segment fields threaded through the whole codebase.
-- ponytail: config lives in the id string. Ceiling: a handful of short keys. If the option
-- set grows large, promote to real Segment override fields + a resolver input instead.
local CONFIG_SEP = "|"

export type RoadConfig = {
	sidewalk: string?, -- "none" | "left" | "right" | "both"
	median: string?,   -- "none" | "center" | "left" | "both"
	parking: string?,  -- "none" | "left" | "right" | "both"
	trees: string?,    -- "none" or a NatureCatalog tree key ("OakTree")
	color: Color3?,
	speed: number?,
}

-- Whitelisted single-letter codes. Decoding is the SECURITY boundary: an id arrives from
-- the client verbatim, so every value is validated/clamped here before it reaches a spec.
local SIDEWALK_CODE = { none = "n", left = "l", right = "r", both = "b" }
local MEDIAN_CODE   = { none = "n", center = "c", left = "l", both = "b" }
local PARKING_CODE  = { none = "n", left = "l", right = "r", both = "b" }
local SIDEWALK_MODE = { n = "none", l = "left", r = "right", b = "both" }
local MEDIAN_MODE   = { n = "none", c = "center", l = "left", b = "both" }
local PARKING_MODE  = { n = "none", l = "left", r = "right", b = "both" }
local PARKING_LANE_WIDTH = 10 * RoadConstants.WORLD_SCALE

local function colorToHex(c: Color3): string
	return string.format("%02x%02x%02x",
		math.clamp(math.round(c.R * 255), 0, 255),
		math.clamp(math.round(c.G * 255), 0, 255),
		math.clamp(math.round(c.B * 255), 0, 255))
end

local function parseHexColor(s: string): Color3?
	if not string.match(s, "^%x%x%x%x%x%x$") then return nil end
	local r = tonumber(string.sub(s, 1, 2), 16)
	local g = tonumber(string.sub(s, 3, 4), 16)
	local b = tonumber(string.sub(s, 5, 6), 16)
	if r and g and b then return Color3.fromRGB(r, g, b) end
	return nil
end

-- Encode base + config to an id, omitting defaults so an unconfigured road keeps its bare
-- id (and identically-configured roads share one derived spec + cache entry).
function RoadTypeCatalog.encodeConfig(baseId: string, cfg: RoadConfig): string
	local parts: { string } = {}
	if cfg.sidewalk and SIDEWALK_CODE[cfg.sidewalk] then
		-- The default is the BASE's own: "both" on a normal road but "none" on the sidewalk-less
		-- types (alley, highway). Treating "both" as the default everywhere dropped it from an
		-- alley's id, so picking Sidewalk=Both there silently placed the bare alley.
		local base = RoadTypeCatalog.Types[baseId]
		local default = if base and base.noSidewalk then "none" else "both"
		if cfg.sidewalk ~= default then
			parts[#parts + 1] = "sw=" .. SIDEWALK_CODE[cfg.sidewalk]
		end
	end
	if cfg.median and cfg.median ~= "none" and MEDIAN_CODE[cfg.median] then
		parts[#parts + 1] = "md=" .. MEDIAN_CODE[cfg.median]
	end
	if cfg.parking and cfg.parking ~= "none" and PARKING_CODE[cfg.parking] then
		parts[#parts + 1] = "pk=" .. PARKING_CODE[cfg.parking]
	end
	if cfg.trees and cfg.trees ~= "none" and string.match(cfg.trees, "^%a%w*$") then
		parts[#parts + 1] = "tr=" .. cfg.trees
	end
	if cfg.color then
		parts[#parts + 1] = "col=" .. colorToHex(cfg.color)
	end
	if cfg.speed then
		parts[#parts + 1] = "spd=" .. tostring(math.clamp(math.round(cfg.speed), 10, 120))
	end
	if #parts == 0 then return baseId end
	return baseId .. CONFIG_SEP .. table.concat(parts, ";")
end

local _derivedCache: { [string]: RoadTypeSpec } = {}

local function buildDerived(fullId: string, base: RoadTypeSpec, paramStr: string): RoadTypeSpec
	local d: any = {}
	for k, v in base :: any do d[k] = v end
	d.id = fullId
	for kv in string.gmatch(paramStr, "[^;]+") do
		local k, v = string.match(kv, "^(%w+)=(.+)$")
		if k == "sw" then
			local mode = SIDEWALK_MODE[v]
			if mode then
				d.sidewalkMode = mode
				d.noSidewalk = mode == "none"
			end
		elseif k == "md" then
			local mode = MEDIAN_MODE[v]
			if mode == "center" then
				d.median = true
				d.medianWidth = base.medianWidth or 4
				d.vergeMode = nil
			elseif mode == "left" or mode == "both" then
				d.median = false
				d.vergeMode = mode
				d.vergeWidth = VERGE_WIDTH
			elseif mode == "none" then
				d.median = false
				d.vergeMode = nil
			end
		elseif k == "pk" then
			local mode = PARKING_MODE[v]
			if mode == "none" then
				d.parkingLane = false
				d.parkingSide = nil
			elseif mode then
				local plW = base.parkingLaneWidth or PARKING_LANE_WIDTH
				local sides = if mode == "both" then 2 else 1
				d.parkingLane = true
				d.parkingSide = mode
				d.parkingSides = sides
				d.parkingLaneWidth = plW
			end
		elseif k == "tr" and v then
			-- Never trusted as a path: the renderer only FindFirstChild's it under
			-- ReplicatedStorage.Nature, and a name that matches nothing plants nothing.
			if #v <= 24 and string.match(v, "^%a%w*$") then d.streetTrees = v end
		elseif k == "col" and v then
			local c = parseHexColor(v)
			if c then d.surfaceColor = c end
		elseif k == "spd" and v then
			local n = tonumber(v)
			if n then d.speedLimit = math.clamp(math.round(n), 10, 120) end
		end
	end
	-- Parking apron and planted verge are both bands added OUTSIDE the driving lanes and they
	-- STACK (verge outermost, against the kerb). Width is settled once here, off the BASE
	-- carriageway, so the two compose instead of overwriting each other and re-picking either
	-- option never widens the road a second time.
	local carW = RoadTypeCatalog.carriagewayWidth(base)
	local verge = if d.vergeMode then (if d.vergeMode == "both" then 2 else 1) * (d.vergeWidth or VERGE_WIDTH) else 0
	local park = if d.parkingLane then (d.parkingSides or 2) * (d.parkingLaneWidth or 0) else 0
	d.width = carW + verge + park
	local frozen = table.freeze(d) :: RoadTypeSpec
	_derivedCache[fullId] = frozen
	return frozen
end

function RoadTypeCatalog.get(id: string): RoadTypeSpec?
	local base = RoadTypeCatalog.Types[id]
	if base then return base end
	-- Encoded "BaseId|k=v;..." configured road?
	if #id > 128 then return nil end -- bound the client-supplied string
	local sepAt = string.find(id, CONFIG_SEP, 1, true)
	if not sepAt then return nil end
	local cached = _derivedCache[id]
	if cached then return cached end
	local baseId = string.sub(id, 1, sepAt - 1)
	local baseSpec = RoadTypeCatalog.Types[baseId]
	if not baseSpec then return nil end
	return buildDerived(id, baseSpec, string.sub(id, sepAt + 1))
end

function RoadTypeCatalog.getOrDefault(id: string?): RoadTypeSpec
	if id then
		local spec = RoadTypeCatalog.get(id)
		if spec then return spec end
	end
	return RoadTypeCatalog.Types[RoadTypeCatalog.DEFAULT_ID]
end

return RoadTypeCatalog
