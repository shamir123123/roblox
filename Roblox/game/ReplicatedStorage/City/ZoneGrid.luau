--!strict
-- ZoneGrid
-- City scale constants. The world is 2 studs per metre: roads get there through
-- RoadConstants.WORLD_SCALE, buildings through BUILDING_SCALE below.
-- Terrain's own grid is voxel-/save-baked and stays full size (see TerrainConstants); this
-- only scales what sits ON the ground.
--
-- Was the shared lot-grid generator; the tile grid is retired (burgage plots via
-- PlotGeometry/PlotService are the only zoning system), so only the scale survived.
--
-- Pure library: no lifecycle, no state, no side effects on require.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)

local WORLD_SCALE = RoadConstants.WORLD_SCALE

local ZoneGrid = {}

ZoneGrid.WORLD_SCALE = WORLD_SCALE

-- The Authoring builders (and the code-drawn service/school buildings) draw at 3 studs
-- per metre -- LOT = 16, a 2.0 m door is 6 studs. BUILDING_SCALE turns that into the
-- world's 2 studs per metre (RoadConstants.STUD_TO_METER), and it is BAKED IN when a
-- builder saves a template: BuildingService never rescales a template, so a template's
-- size in ServerStorage is exactly what gets built (StudsPerMetre = 2 on each one).
ZoneGrid.BUILDING_SCALE = 2 / 3
ZoneGrid.LOT_SIZE    = 16 * ZoneGrid.BUILDING_SCALE -- one lot unit: building footprints are measured in these
ZoneGrid.LOT_GAP     = 3 * ZoneGrid.BUILDING_SCALE  -- kerb-to-building setback (LotDressingService)

return table.freeze(ZoneGrid)
