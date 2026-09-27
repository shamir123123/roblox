--!strict
-- MaterialCatalog
-- The materials a player may paint a placed prop with, in one ordered list shared by the
-- picker, the server's validation and the save blob.
--
-- `order` is APPEND-ONLY. A saved prop stores its INDEX in this list, exactly as a nature
-- prop stores its index in NatureCatalog.order, so inserting a material in the middle would
-- silently repaint every city ever saved. New materials go on the END.
--
-- Index 0 is not in the list: it means "leave the template's own materials alone", which is
-- what every prop placed before the picker existed is.

local MaterialCatalog = {}

MaterialCatalog.order = table.freeze({
	"Plastic", "SmoothPlastic", "Neon", "Glass", "ForceField",
	"Wood", "WoodPlanks",
	"Concrete", "Brick", "Cobblestone", "Pebble", "Slate", "Granite", "Marble",
	"Sandstone", "Limestone", "Basalt", "Rock", "CrackedLava", "Asphalt",
	"Metal", "DiamondPlate", "CorrodedMetal", "Foil",
	"Fabric", "Leather", "Cardboard", "Carpet", "Plaster", "Pavement",
	"Grass", "LeafyGrass", "Ground", "Mud", "Sand", "Salt", "Snow", "Ice", "Glacier",
})

-- name -> index, built once so a lookup is not a linear scan of forty strings.
local _index: { [string]: number } = {}
for i, name in MaterialCatalog.order do _index[name] = i end

-- The Enum for an index, or nil for 0 / anything out of range. nil is the honest answer
-- for "no override", and every caller has to handle it anyway.
function MaterialCatalog.get(idx: number?): Enum.Material?
	if not idx or idx ~= idx then return nil end
	local name = MaterialCatalog.order[idx]
	if not name then return nil end
	local ok, mat = pcall(function() return (Enum.Material :: any)[name] end)
	return if ok then mat else nil
end

function MaterialCatalog.indexOf(name: string): number
	return _index[name] or 0
end

return MaterialCatalog
