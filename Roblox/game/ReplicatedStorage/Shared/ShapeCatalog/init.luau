--!strict
-- ShapeCatalog
-- The 50 building-block shapes, shared by the Creation Editor (where they are the
-- primitive palette) and the Nature tab (where they are placeable city props). One list
-- so the two can never drift.
--
-- A shape with a `native` def is built live from a part type or a SpecialMesh -- free, no
-- storage. Every other shape is CSG and is BAKED once by ServerStorage.Authoring
-- .ShapeBuilder into ReplicatedStorage.Nature.<key>, whose single BasePart is what
-- CreationBuilder.makePrimitive clones. Both are one BasePart either way, which is what
-- lets a shape carry its own size, colour, material and sound through the editor's
-- existing per-primitive serialization.
--
-- ORDER IS APPEND-ONLY: NatureCatalog.order is built from this list and a saved city
-- stores a prop's position in that array, not its key.

export type Native = {
	class: string,
	partType: Enum.PartType?,
	meshType: Enum.MeshType?,
	size: Vector3,
}

export type Shape = { key: string, name: string, native: Native? }

local function native(class: string, partType: Enum.PartType?, meshType: Enum.MeshType?, size: Vector3): Native
	return table.freeze({ class = class, partType = partType, meshType = meshType, size = size })
end

local B = Vector3.new(4, 4, 4)

local list: { Shape } = {
	-- native part types
	{ key = "Block",           name = "Block",            native = native("Part", Enum.PartType.Block, nil, B) },
	{ key = "Sphere",          name = "Sphere",           native = native("Part", Enum.PartType.Ball, nil, B) },
	{ key = "Cylinder",        name = "Cylinder",         native = native("Part", Enum.PartType.Cylinder, nil, B) },
	{ key = "Wedge",           name = "Wedge",            native = native("WedgePart", nil, nil, B) },
	{ key = "CornerWedge",     name = "Corner Wedge",     native = native("CornerWedgePart", nil, nil, B) },
	-- baked CSG. The legacy SpecialMesh types (Pyramid / Prism / ParallelRamp) no longer
	-- render, so those silhouettes are cut out of a block instead.
	{ key = "Pyramid",         name = "Pyramid" },
	{ key = "TrianglePrism",   name = "Triangle Prism" },
	{ key = "ParallelRamp",    name = "Parallel Ramp" },
	{ key = "Column",          name = "Column" },
	{ key = "Ellipsoid",       name = "Ellipsoid" },
	{ key = "Cone",            name = "Cone" },
	{ key = "Frustum",         name = "Frustum" },
	{ key = "Dome",            name = "Dome" },
	{ key = "Bowl",            name = "Bowl" },
	{ key = "Capsule",         name = "Capsule" },
	{ key = "Tube",            name = "Tube" },
	{ key = "SquareTube",      name = "Square Tube" },
	{ key = "Ring",            name = "Ring" },
	{ key = "HalfCylinder",    name = "Half Cylinder" },
	{ key = "QuarterCylinder", name = "Quarter Cylinder" },
	{ key = "HalfPipe",        name = "Half Pipe" },
	{ key = "Torus",           name = "Torus" },
	{ key = "PentPrism",       name = "Pentagon Prism" },
	{ key = "HexPrism",        name = "Hexagon Prism" },
	{ key = "OctPrism",        name = "Octagon Prism" },
	{ key = "Star6",           name = "Six-Point Star" },
	{ key = "Star8",           name = "Eight-Point Star" },
	{ key = "Cross",           name = "Cross" },
	{ key = "XCross",          name = "X Cross" },
	{ key = "LBeam",           name = "L Beam" },
	{ key = "TBeam",           name = "T Beam" },
	{ key = "IBeam",           name = "I Beam" },
	{ key = "UChannel",        name = "U Channel" },
	{ key = "Frame",           name = "Frame" },
	{ key = "OpenBox",         name = "Open Box" },
	{ key = "Stairs",          name = "Stairs" },
	{ key = "SpiralStairs",    name = "Spiral Stairs" },
	{ key = "Arch",            name = "Arch" },
	{ key = "Doorway",         name = "Doorway" },
	{ key = "Trapezoid",       name = "Trapezoid" },
	{ key = "ChamferBox",      name = "Chamfer Box" },
	{ key = "Octahedron",      name = "Octahedron" },
	{ key = "Funnel",          name = "Funnel" },
	{ key = "Barrel",          name = "Barrel" },
	{ key = "Gear",            name = "Gear" },
	{ key = "HexNut",          name = "Hex Nut" },
	{ key = "QuarterSphere",   name = "Quarter Sphere" },
	{ key = "ConcaveCorner",   name = "Concave Corner" },
	{ key = "CoveRamp",        name = "Cove Ramp" },
	{ key = "PyramidFrustum",  name = "Pyramid Frustum" },
	-- 3D numerals, seven-segment. Same one-BasePart contract as every other shape, so a
	-- house number reads as a shape the player sizes and colours like any other.
	{ key = "Number0",         name = "Number 0" },
	{ key = "Number1",         name = "Number 1" },
	{ key = "Number2",         name = "Number 2" },
	{ key = "Number3",         name = "Number 3" },
	{ key = "Number4",         name = "Number 4" },
	{ key = "Number5",         name = "Number 5" },
	{ key = "Number6",         name = "Number 6" },
	{ key = "Number7",         name = "Number 7" },
	{ key = "Number8",         name = "Number 8" },
	{ key = "Number9",         name = "Number 9" },
}

-- ADDED 2026-09-23, after the car parks in NatureCatalog.order (see there): the pieces the
-- first set lacked, meshed by blender/shape_kit.py. Never merge these into `list` above --
-- `order` is a contiguous index block every saved city depends on.
local added: { Shape } = {
	{ key = "InnerCornerWedge", name = "Inner Corner" },
	{ key = "EighthSphere",     name = "Eighth Sphere" },
	{ key = "PipeBend",         name = "Pipe Bend" },
	{ key = "ArchBeam",         name = "Arch Beam" },
	{ key = "RoofEnd",          name = "Roof End" },
	{ key = "Railing",          name = "Railing" },
}

-- Names the shelf shows. Keys never change (saves hold them); a clearer word can.
local RENAME: { [string]: string } = {
	Dome = "Half Sphere", CoveRamp = "Cove", Frame = "Window Frame", TrianglePrism = "Roof",
	Star6 = "Star", QuarterCylinder = "Quarter Cylinder", HalfCylinder = "Half Cylinder",
	IBeam = "I-Beam", CornerWedge = "Corner Wedge",
}

local order: { string } = {}
local addedOrder: { string } = {}
local all: { string } = {}
local byKey: { [string]: Shape } = {}
for _, s in list do
	table.insert(order, s.key)
end
for _, s in added do
	table.insert(addedOrder, s.key)
end
for _, group in { list, added } do
	for _, s in group do
		if RENAME[s.key] then s.name = RENAME[s.key] end
		table.insert(all, s.key)
		byKey[s.key] = table.freeze(s)
	end
end

local ShapeCatalog = {}

-- THE SHELF, by group, in the order a builder reaches for them. 2026-09-23: cut from sixty
-- odd shapes (gear, funnel, hex nut, barrel...) to the pieces people actually build with,
-- the way Theme Park Tycoon's primitives are. A shape missing here is HIDDEN -- still
-- loadable, so every prop already placed in a saved city survives, just not offered.
local GROUPS: { [string]: { string } } = {
	Blocks = { "Block", "Wedge", "CornerWedge", "InnerCornerWedge", "Pyramid", "Stairs" },
	Round = { "Sphere", "Dome", "QuarterSphere", "EighthSphere", "Cylinder", "HalfCylinder",
		"QuarterCylinder", "CoveRamp", "Cone", "Tube", "PipeBend", "Torus" },
	Building = { "Column", "Arch", "ArchBeam", "Doorway", "Frame", "TrianglePrism", "RoofEnd",
		"IBeam", "Railing" },
	Details = { "HexPrism", "OctPrism", "Star6" },
}
local groupOf: { [string]: string } = {}
local rankOf: { [string]: number } = {}
for group, keys in GROUPS do
	for i, k in keys do groupOf[k] = group; rankOf[k] = i end
end

-- Position inside its group, so a shelf reads Block, Wedge, Corner... rather than save order.
function ShapeCatalog.rankOf(key: string): number
	return rankOf[key] or tonumber(string.match(key, "%d+$")) or 99
end
ShapeCatalog.GROUP_ORDER = table.freeze({ "Blocks", "Round", "Building", "Details", "Numbers" })

-- "Numbers" for the numerals, "Hidden" for a retired shape.
function ShapeCatalog.groupOf(key: string): string
	if string.sub(key, 1, 6) == "Number" then return "Numbers" end
	return groupOf[key] or "Hidden"
end

function ShapeCatalog.isHidden(key: string): boolean
	return ShapeCatalog.groupOf(key) == "Hidden"
end

-- `order` is the ORIGINAL contiguous block (saves index it), `added` goes on after the car
-- parks, `all` is both, `shelf` is what a player is offered, grouped and ranked.
ShapeCatalog.order = table.freeze(order)
ShapeCatalog.added = table.freeze(addedOrder)
ShapeCatalog.all = table.freeze(all)
local shelf: { string } = {}
for _, g in ShapeCatalog.GROUP_ORDER do
	if g == "Numbers" then
		for d = 0, 9 do table.insert(shelf, "Number" .. d) end
	else
		for _, k in GROUPS[g] do table.insert(shelf, k) end
	end
end
ShapeCatalog.shelf = table.freeze(shelf)
ShapeCatalog.byKey = table.freeze(byKey)

function ShapeCatalog.get(key: any): Shape?
	if typeof(key) ~= "string" then return nil end
	return byKey[key]
end

return ShapeCatalog
