--!strict
-- Shared nature-asset catalog: placeable trees / bushes / rocks / shapes. Templates live
-- beside this module in ReplicatedStorage.Nature (one Model per key). Pure data.
--
-- The Shape entries are DERIVED from ShapeCatalog rather than written out again here: the
-- same 60 primitives are the Creation Editor's palette, and two hand-kept lists of the
-- same thing would drift the first time anyone added a shape.

local ShapeCatalog = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ShapeCatalog"))

export type Entry = {
	key: string, name: string, kind: "Tree" | "Bush" | "Rock" | "Shape" | "Lot",
	minScale: number, maxScale: number, radius: number, tint: Color3, cost: number,
}

local NatureCatalog = {}

-- Shapes are placed at an EXACT size the player picks, not a jittered one, so the range is
-- wide and the placement tool reads the stepper instead of rolling inside it.
local SHAPE_TINT = Color3.fromRGB(150, 168, 196)

NatureCatalog.order = {
	"RoyalPalm", "CoconutPalm", "SylvesterPalm", "FloridaPalm", "PalmMedium", "PalmYoung", "SpruceTree", "PineTree", "OakTree", "ChestnutTree", "BirchTree", "PoplarTree", "ElderTree", "BroadleafTree", "BushRound", "BushLow", "BushTall", "BushWild", "FlowerBush", "FlowerBushPink", "FlowerBushYellow", "BerryBush", "HedgeSphere", "HedgeBox", "HedgeCone", "Rock01", "Rock02", "Rock03", "Rock04", "Rock05", "Rock06", "Rock07", "Rock08", "Rock09", "Rock10", "Rock11", "Rock12", "Rock13", "Rock14", "Rock15", "Pebbles01", "Pebbles02", "Pebbles03", "PebbleSingle",
} :: { string }

-- APPEND-ONLY, and appended AFTER the props above: a saved city stores each prop's index
-- in this array (NaturePlaceService), so inserting anywhere but the end reassigns keys on
-- every city already in the store.
for _, key in ShapeCatalog.order do
	table.insert(NatureCatalog.order, key)
end

-- Car parks were added after the shapes (2026-09-08) and so go after them here, for the
-- same reason the shapes went after the trees: every index already in a saved city keeps
-- pointing at the same prop. Anything added later goes on the END too.
for _, key in { "ParkingLotSmall", "ParkingLotMedium", "ParkingLotLarge", "ParkingLotRow", "ParkingLotAngled", "ParkingLotSuper" } do
	table.insert(NatureCatalog.order, key)
end

-- Shapes added 2026-09-23 (ShapeCatalog.added) go after the car parks, for the same reason.
for _, key in ShapeCatalog.added do
	table.insert(NatureCatalog.order, key)
end

NatureCatalog.byKey = table.freeze({
	RoyalPalm = table.freeze({ key = "RoyalPalm", name = "Royal Palm", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 3, tint = Color3.fromRGB(86, 150, 96), cost = 60 }),
	CoconutPalm = table.freeze({ key = "CoconutPalm", name = "Coconut Palm", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 3, tint = Color3.fromRGB(96, 160, 90), cost = 55 }),
	SylvesterPalm = table.freeze({ key = "SylvesterPalm", name = "Sylvester Palm", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 3, tint = Color3.fromRGB(70, 130, 80), cost = 50 }),
	FloridaPalm = table.freeze({ key = "FloridaPalm", name = "Florida Palm", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 3, tint = Color3.fromRGB(90, 150, 85), cost = 45 }),
	PalmMedium = table.freeze({ key = "PalmMedium", name = "Palm", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 3, tint = Color3.fromRGB(90, 150, 88), cost = 45 }),
	PalmYoung = table.freeze({ key = "PalmYoung", name = "Young Palm", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 2, tint = Color3.fromRGB(105, 165, 95), cost = 30 }),
	SpruceTree = table.freeze({ key = "SpruceTree", name = "Spruce", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 3, tint = Color3.fromRGB(50, 90, 58), cost = 45 }),
	PineTree = table.freeze({ key = "PineTree", name = "Pine", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 4, tint = Color3.fromRGB(70, 110, 64), cost = 45 }),
	OakTree = table.freeze({ key = "OakTree", name = "Oak", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 4, tint = Color3.fromRGB(96, 150, 74), cost = 50 }),
	ChestnutTree = table.freeze({ key = "ChestnutTree", name = "Chestnut", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 5, tint = Color3.fromRGB(85, 135, 68), cost = 60 }),
	BirchTree = table.freeze({ key = "BirchTree", name = "Birch", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 3, tint = Color3.fromRGB(130, 180, 100), cost = 40 }),
	PoplarTree = table.freeze({ key = "PoplarTree", name = "Poplar", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 3, tint = Color3.fromRGB(110, 165, 85), cost = 40 }),
	ElderTree = table.freeze({ key = "ElderTree", name = "Elder", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 3, tint = Color3.fromRGB(115, 160, 95), cost = 35 }),
	BroadleafTree = table.freeze({ key = "BroadleafTree", name = "Broadleaf Tree", kind = "Tree", minScale = 0.82, maxScale = 1.25, radius = 4, tint = Color3.fromRGB(90, 150, 78), cost = 48 }),
	BushRound = table.freeze({ key = "BushRound", name = "Round Bush", kind = "Bush", minScale = 0.75, maxScale = 1.35, radius = 2, tint = Color3.fromRGB(110, 150, 82), cost = 15 }),
	BushLow = table.freeze({ key = "BushLow", name = "Spreading Bush", kind = "Bush", minScale = 0.75, maxScale = 1.35, radius = 3, tint = Color3.fromRGB(118, 155, 85), cost = 15 }),
	BushTall = table.freeze({ key = "BushTall", name = "Tall Bush", kind = "Bush", minScale = 0.75, maxScale = 1.35, radius = 1, tint = Color3.fromRGB(112, 158, 84), cost = 15 }),
	BushWild = table.freeze({ key = "BushWild", name = "Wild Bush", kind = "Bush", minScale = 0.75, maxScale = 1.35, radius = 3, tint = Color3.fromRGB(104, 145, 78), cost = 12 }),
	FlowerBush = table.freeze({ key = "FlowerBush", name = "Flower Bush", kind = "Bush", minScale = 0.75, maxScale = 1.35, radius = 2, tint = Color3.fromRGB(222, 226, 212), cost = 20 }),
	FlowerBushPink = table.freeze({ key = "FlowerBushPink", name = "Pink Flower Bush", kind = "Bush", minScale = 0.75, maxScale = 1.35, radius = 2, tint = Color3.fromRGB(240, 170, 195), cost = 20 }),
	FlowerBushYellow = table.freeze({ key = "FlowerBushYellow", name = "Yellow Flower Bush", kind = "Bush", minScale = 0.75, maxScale = 1.35, radius = 2, tint = Color3.fromRGB(235, 215, 110), cost = 20 }),
	BerryBush = table.freeze({ key = "BerryBush", name = "Berry Bush", kind = "Bush", minScale = 0.75, maxScale = 1.35, radius = 2, tint = Color3.fromRGB(170, 60, 60), cost = 20 }),
	HedgeSphere = table.freeze({ key = "HedgeSphere", name = "Sphere Hedge", kind = "Bush", minScale = 0.75, maxScale = 1.35, radius = 1, tint = Color3.fromRGB(92, 138, 72), cost = 18 }),
	HedgeBox = table.freeze({ key = "HedgeBox", name = "Box Hedge", kind = "Bush", minScale = 0.75, maxScale = 1.35, radius = 2, tint = Color3.fromRGB(88, 132, 70), cost = 18 }),
	HedgeCone = table.freeze({ key = "HedgeCone", name = "Cone Hedge", kind = "Bush", minScale = 0.75, maxScale = 1.35, radius = 1, tint = Color3.fromRGB(84, 128, 68), cost = 18 }),
	Rock01 = table.freeze({ key = "Rock01", name = "Boulder", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 3, tint = Color3.fromRGB(130, 132, 136), cost = 25 }),
	Rock02 = table.freeze({ key = "Rock02", name = "Wide Boulder", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 3, tint = Color3.fromRGB(130, 132, 136), cost = 25 }),
	Rock03 = table.freeze({ key = "Rock03", name = "Tall Rock", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(110, 108, 102), cost = 20 }),
	Rock04 = table.freeze({ key = "Rock04", name = "Rock Slab", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 2, tint = Color3.fromRGB(130, 132, 136), cost = 20 }),
	Rock05 = table.freeze({ key = "Rock05", name = "Angular Boulder", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 2, tint = Color3.fromRGB(110, 108, 102), cost = 22 }),
	Rock06 = table.freeze({ key = "Rock06", name = "Rock", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(130, 132, 136), cost = 18 }),
	Rock07 = table.freeze({ key = "Rock07", name = "Flat Rock", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(110, 108, 102), cost = 18 }),
	Rock08 = table.freeze({ key = "Rock08", name = "Jagged Rock", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(130, 132, 136), cost = 18 }),
	Rock09 = table.freeze({ key = "Rock09", name = "Small Boulder", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(130, 132, 136), cost = 15 }),
	Rock10 = table.freeze({ key = "Rock10", name = "Low Slab", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(110, 108, 102), cost = 15 }),
	Rock11 = table.freeze({ key = "Rock11", name = "Small Rock", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(130, 132, 136), cost = 12 }),
	Rock12 = table.freeze({ key = "Rock12", name = "Small Angular Rock", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(110, 108, 102), cost = 12 }),
	Rock13 = table.freeze({ key = "Rock13", name = "Small Flat Rock", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(130, 132, 136), cost = 12 }),
	Rock14 = table.freeze({ key = "Rock14", name = "Huge Boulder", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 3, tint = Color3.fromRGB(130, 132, 136), cost = 30 }),
	Rock15 = table.freeze({ key = "Rock15", name = "Huge Angular Rock", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 3, tint = Color3.fromRGB(110, 108, 102), cost = 30 }),
	Pebbles01 = table.freeze({ key = "Pebbles01", name = "Pebble Patch", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(130, 132, 136), cost = 8 }),
	Pebbles02 = table.freeze({ key = "Pebbles02", name = "Small Pebble Patch", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(110, 108, 102), cost = 8 }),
	Pebbles03 = table.freeze({ key = "Pebbles03", name = "Wide Pebble Patch", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(130, 132, 136), cost = 8 }),
	PebbleSingle = table.freeze({ key = "PebbleSingle", name = "Pebble", kind = "Rock", minScale = 0.70, maxScale = 1.45, radius = 1, tint = Color3.fromRGB(130, 132, 136), cost = 5 }),
	-- Car parks (ServerStorage.Authoring.ParkingLotBuilder). The radius is deliberately
	-- small -- it is only the road/building exclusion probe, and a lot is meant to sit
	-- right against the kerb it is served from, not a footprint's width away from it.
	ParkingLotSmall = table.freeze({ key = "ParkingLotSmall", name = "Small Car Park", kind = "Lot", minScale = 0.75, maxScale = 1.5, radius = 3, tint = Color3.fromRGB(96, 96, 100), cost = 400 }),
	ParkingLotMedium = table.freeze({ key = "ParkingLotMedium", name = "Car Park", kind = "Lot", minScale = 0.75, maxScale = 1.5, radius = 3, tint = Color3.fromRGB(96, 96, 100), cost = 900 }),
	ParkingLotLarge = table.freeze({ key = "ParkingLotLarge", name = "Large Car Park", kind = "Lot", minScale = 0.75, maxScale = 1.5, radius = 3, tint = Color3.fromRGB(96, 96, 100), cost = 1600 }),
	ParkingLotRow = table.freeze({ key = "ParkingLotRow", name = "Roadside Bays", kind = "Lot", minScale = 0.75, maxScale = 1.5, radius = 3, tint = Color3.fromRGB(96, 96, 100), cost = 300 }),
	ParkingLotAngled = table.freeze({ key = "ParkingLotAngled", name = "Angled Car Park", kind = "Lot", minScale = 0.75, maxScale = 1.5, radius = 3, tint = Color3.fromRGB(96, 96, 100), cost = 550 }),
	ParkingLotSuper = table.freeze({ key = "ParkingLotSuper", name = "Superstore Car Park", kind = "Lot", minScale = 0.75, maxScale = 1.5, radius = 3, tint = Color3.fromRGB(96, 96, 100), cost = 3000 }),
}) :: { [string]: Entry }

do
	local withShapes: { [string]: Entry } = {}
	for k, v in NatureCatalog.byKey do withShapes[k] = v end
	for _, s in ShapeCatalog.all do
		local shape = ShapeCatalog.byKey[s]
		withShapes[s] = table.freeze({
			key = s, name = shape.name, kind = "Shape" :: "Shape",
			minScale = 0.25, maxScale = 6, radius = 2, tint = SHAPE_TINT, cost = 10,
		})
	end
	NatureCatalog.byKey = table.freeze(withShapes) :: { [string]: Entry }
end

function NatureCatalog.get(key: string): Entry?
	return NatureCatalog.byKey[key]
end

return NatureCatalog