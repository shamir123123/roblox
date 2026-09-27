--!strict
-- SchoolTypes
-- Shared, immutable catalog of the Education service buildings: the three schools
-- (elementary / high / university) and the library. Read by the server (EducationService
-- places them + serves age-matched pupils), the placement UI (cards + footprint ghost) and
-- SchoolModel (placeholder geometry until the Blender meshes land). Pure data -- no
-- lifecycle, no side effects on require.
--
-- Footprints are measured in LOTS (16-stud zone tiles) so a placed building occupies a
-- block of the very grid the player zones on. `footprint` (studs) is derived from the lot
-- size and kept for the geometry builder. `coverageRadius` is the education reach in studs.
-- `eduTier` is the level this building grants a pupil: 1 Educated, 2 Well-educated,
-- 3 Highly-educated; 0 means it grants no diploma (Library).

local LOT_SIZE = 16 -- full-size lot unit; SchoolModel ScaleTo()s the finished building
-- Half-size world: coverage reach scales so a school serves the same houses.
local WORLD_SCALE = require(game:GetService("ReplicatedStorage").Road.RoadConstants).WORLD_SCALE

local SchoolTypes = {}

export type Spec = {
	key: string,
	name: string,
	desc: string,
	category: string,       -- "School" | "Library"
	widthLots: number,      -- footprint along the road, in lots
	depthLots: number,      -- footprint back from the road, in lots
	height: number,         -- placeholder body height, studs
	ageMin: number,         -- youngest pupil served (0 for Library)
	ageMax: number,         -- oldest pupil served (0 for Library)
	eduTier: number,        -- education tier granted (0 = none)
	capacity: number,       -- pupil seats (0 for Library)
	coverageRadius: number, -- education reach, studs
	cost: number,
	footprint: Vector3,     -- derived X*Z ground size (studs), Y body height
	wall: Color3,
	roof: Color3,
	accent: Color3,
}

local DEFS: { [string]: Spec } = {
	Elementary = {
		key = "Elementary", name = "Elementary School", desc = "Ages 5-10. Grants an Educated diploma.",
		category = "School", widthLots = 3, depthLots = 2, height = 12,
		ageMin = 5, ageMax = 10, eduTier = 1, capacity = 200, coverageRadius = 120 * WORLD_SCALE, cost = 4000,
		footprint = Vector3.new(3 * LOT_SIZE, 12, 2 * LOT_SIZE),
		wall = Color3.fromRGB(232, 196, 120), roof = Color3.fromRGB(170, 80, 66), accent = Color3.fromRGB(245, 210, 95),
	},
	HighSchool = {
		key = "HighSchool", name = "High School", desc = "Ages 11-17. Grants a Well-educated diploma.",
		category = "School", widthLots = 4, depthLots = 3, height = 16,
		ageMin = 11, ageMax = 17, eduTier = 2, capacity = 400, coverageRadius = 180 * WORLD_SCALE, cost = 9000,
		footprint = Vector3.new(4 * LOT_SIZE, 16, 3 * LOT_SIZE),
		wall = Color3.fromRGB(196, 120, 96), roof = Color3.fromRGB(90, 100, 120), accent = Color3.fromRGB(120, 170, 210),
	},
	University = {
		key = "University", name = "University", desc = "Ages 18-22. Grants a Highly-educated degree.",
		category = "School", widthLots = 6, depthLots = 4, height = 22,
		ageMin = 18, ageMax = 22, eduTier = 3, capacity = 800, coverageRadius = 260 * WORLD_SCALE, cost = 20000,
		footprint = Vector3.new(6 * LOT_SIZE, 22, 4 * LOT_SIZE),
		wall = Color3.fromRGB(210, 205, 196), roof = Color3.fromRGB(120, 90, 70), accent = Color3.fromRGB(150, 60, 60),
	},
	Library = {
		key = "Library", name = "Library", desc = "Boosts education and land value nearby. No pupils.",
		category = "Library", widthLots = 2, depthLots = 2, height = 12,
		ageMin = 0, ageMax = 0, eduTier = 0, capacity = 0, coverageRadius = 100 * WORLD_SCALE, cost = 3000,
		footprint = Vector3.new(2 * LOT_SIZE, 12, 2 * LOT_SIZE),
		wall = Color3.fromRGB(184, 172, 150), roof = Color3.fromRGB(110, 95, 80), accent = Color3.fromRGB(150, 120, 80),
	},
}
for _, spec in DEFS do table.freeze(spec) end
table.freeze(DEFS)

SchoolTypes.LOT_SIZE = LOT_SIZE
SchoolTypes.Order = table.freeze({ "Elementary", "HighSchool", "University", "Library" })

function SchoolTypes.get(key: string): Spec?
	return DEFS[key]
end

function SchoolTypes.all(): { [string]: Spec }
	return DEFS
end

-- Footprint ground size in studs: X = width along the road, Z = depth back from it.
function SchoolTypes.footprintStuds(spec: Spec): Vector3
	return Vector3.new(spec.widthLots * LOT_SIZE, spec.height, spec.depthLots * LOT_SIZE)
end

return SchoolTypes
