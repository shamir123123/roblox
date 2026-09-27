--!strict
-- Frozen tuning + palettes for LotDressingService. Realistic house/roof/door
-- colours, fence kinds (weighted), path/driveway dimensions, backyard rules.
-- Per project rule 12 every table here is immutable.

local LotDressingConfig = {}

-- Realistic exterior wall colours.
--
-- Rebalanced for the MESH house stock. These values used to be read straight off
-- an untextured plastic part, so a pale cream WAS the finished wall. The mesh
-- houses tint a SurfaceAppearance over a grey atlas normalised to ~205, so every
-- entry comes back multiplied by ~0.80: seven of the old thirteen sat at
-- luminance >= 193 and landed back at white, which is why a whole street read as
-- unpainted. Three pale entries are kept on purpose -- real streets do have white
-- houses -- and the rest now carry enough value to survive the multiply.
LotDressingConfig.WALL_COLORS = table.freeze({
	Color3.fromRGB(240, 236, 224), -- cream
	Color3.fromRGB(212, 214, 208), -- light grey
	Color3.fromRGB(226, 216, 190), -- pale yellow
	Color3.fromRGB(150, 168, 138), -- sage
	Color3.fromRGB(122, 146, 170), -- colonial blue
	Color3.fromRGB(158, 74, 64),   -- barn red
	Color3.fromRGB(214, 186, 120), -- buttery yellow
	Color3.fromRGB(168, 148, 126), -- taupe
	Color3.fromRGB(108, 124, 140), -- slate
	Color3.fromRGB(132, 140, 104), -- olive
	Color3.fromRGB(182, 114, 86),  -- terracotta
	Color3.fromRGB(142, 126, 150), -- dusty purple
	Color3.fromRGB(96, 120, 98),   -- forest green
})

-- Roof colours: ONE dark-neutral family, five values.
--
-- The roof is the largest continuous surface on a house and sits highest in frame, so
-- varying its HUE is what makes a street read as a toy set. Varying VALUE inside a single
-- family gives rhythm without chaos, which is why real American subdivisions look cohesive
-- across a dozen wall colours. Charcoal, pewter and weathered-wood brown-grey are also
-- close to the entire actual US shingle market.
--
-- Removed: muted green rgb(74,96,72), terracotta rgb(150,78,58) and deep red rgb(122,58,48).
-- Those three ran at saturation 0.25-0.61 against a 0.12 target, and because this colour
-- MULTIPLIES the roof texture, a saturated tint fights whatever covering the builder chose
-- -- a brown-asphalt texture was coming out green. Terracotta belongs with barrel tile on
-- Spanish/Southwest stock, which this level-1 library does not contain.
-- Values raised ~45% for the mesh stock: the tint now multiplies a ~195-luminance
-- roof tile, so the old 46-84 range came out at 35-64 and every roof read as flat
-- black. The ONE-dark-neutral-family rule above is unchanged -- this is a value
-- shift only, no hue added.
LotDressingConfig.ROOF_COLORS = table.freeze({
	Color3.fromRGB(78, 82, 88),    -- charcoal
	Color3.fromRGB(88, 92, 98),    -- slate
	Color3.fromRGB(66, 70, 76),    -- deep charcoal
	Color3.fromRGB(104, 106, 110), -- pewter
	Color3.fromRGB(112, 100, 88),  -- weathered wood brown-grey
	Color3.fromRGB(124, 84, 72),   -- weathered brown-red
})

-- Front door accents.
LotDressingConfig.DOOR_COLORS = table.freeze({
	Color3.fromRGB(96, 64, 44),  -- wood
	Color3.fromRGB(58, 72, 96),  -- navy
	Color3.fromRGB(96, 52, 50),  -- barn red
	Color3.fromRGB(60, 80, 64),  -- forest
	Color3.fromRGB(42, 44, 48),  -- charcoal
})

-- Wall/roof MATERIAL variety, as five builds of one atlas.
--
-- A house's UVs point at fixed atlas cells, so the covering it was modelled with
-- is baked in: every placement of one plan showed the same siding. These variants
-- are the SAME atlas with the five wall tiles (and four roof tiles) cyclically
-- permuted, so slot "lap" holds brick in v1, stucco in v2, and so on. Every
-- variant keeps the tiles neutral, so tinting still works over any of them.
--
-- Only wall and roof cells are permuted -- trim, glass, door, concrete and the
-- garage door keep their own cells.
--
-- AUTHORING-TIME ONLY. `SurfaceAppearance.ColorMap` needs the Plugin capability
-- and throws "cannot write 'ColorMap'" from a game thread, so this cannot be
-- swapped per placement. Instead each template in
-- ServerStorage.Templates.Buildings.Residential is cloned into 3 material
-- variants (suffix _m1/_m2) with the ColorMap baked in, and BuildingService's
-- random pick over the folder is what makes a street varied. This list is the
-- record of the ids for that authoring pass; nothing reads it at runtime.
LotDressingConfig.HOUSE_ATLASES = table.freeze({
	"rbxassetid://81913685655225",  -- base: lap / brick / stucco / batten / shake
	"rbxassetid://81223601980048",  -- v1
	"rbxassetid://114326121379298", -- v2
	"rbxassetid://130419835209981", -- v3
	"rbxassetid://119797549531973", -- v4
})

-- Per-placement hue jitter (0..1 of a Lerp toward white/black).
LotDressingConfig.COLOR_JITTER = 0.06

LotDressingConfig.PATH = table.freeze({
	width = 4.3,
	thickness = 0.25,
	lift = 0.22,
	color = Color3.fromRGB(196, 192, 184),
	material = Enum.Material.Concrete,
})

-- width is FULL-SIZE studs; the do-block below multiplies by WORLD_SCALE (0.5), and
-- 1 in-world stud is 0.5 m. 13 -> 6.5 studs -> 3.25 m: a real single-car drive with room
-- to open a door. The old 7.5 came out at 1.87 m -- exactly the width of the car on it.
LotDressingConfig.DRIVE = table.freeze({
	width = 13,
	thickness = 0.25,
	lift = 0.22,
	color = Color3.fromRGB(78, 78, 82),
	material = Enum.Material.Asphalt,
})

-- Per-placement pavement variety (driveway + path), so neighbours differ.
LotDressingConfig.DRIVE_VARIANTS = table.freeze({
	table.freeze({ color = Color3.fromRGB(78, 78, 82),   material = Enum.Material.Asphalt }),
	table.freeze({ color = Color3.fromRGB(98, 98, 102),  material = Enum.Material.Asphalt }),
	table.freeze({ color = Color3.fromRGB(150, 148, 144), material = Enum.Material.Concrete }),
	table.freeze({ color = Color3.fromRGB(150, 120, 96),  material = Enum.Material.Cobblestone }),
})

LotDressingConfig.PATH_VARIANTS = table.freeze({
	table.freeze({ color = Color3.fromRGB(196, 192, 184), material = Enum.Material.Concrete }),
	table.freeze({ color = Color3.fromRGB(170, 150, 130), material = Enum.Material.Cobblestone }),
	table.freeze({ color = Color3.fromRGB(158, 156, 152), material = Enum.Material.Slate }),
})

-- Fence kinds. weight drives the weighted random pick (residential always fenced).
LotDressingConfig.FENCE = table.freeze({
	table.freeze({
		name = "Wood", weight = 0.45,
		height = 5.3, thickness = 0.32, color = Color3.fromRGB(186, 150, 110), material = Enum.Material.WoodPlanks,
		rail = true, post = true, postSize = 0.6, postColor = Color3.fromRGB(150, 116, 80),
	}),
	table.freeze({
		name = "Hedge", weight = 0.35,
		height = 5.7, thickness = 2.1, color = Color3.fromRGB(82, 120, 76), material = Enum.Material.LeafyGrass,
		rail = false, post = false, postSize = 0, postColor = Color3.fromRGB(82, 120, 76),
	}),
	table.freeze({
		name = "Metal", weight = 0.20,
		height = 4.6, thickness = 0.18, color = Color3.fromRGB(70, 72, 78), material = Enum.Material.Metal,
		rail = true, post = true, postSize = 0.39, postColor = Color3.fromRGB(60, 62, 68),
	}),
})

LotDressingConfig.FENCE_INSET = 0.9
LotDressingConfig.GATE_HALF = table.freeze({ path = 2.8, drive = 4.6 })

LotDressingConfig.BACKYARD = table.freeze({
	minProps = 2,
	maxProps = 5,
	margin = 1.2,   -- keep props this far inside the yard rect
	tries = 10,     -- placement attempts per prop
})

-- Commercial facade / sign / awning palettes (bolder than residential).
LotDressingConfig.COMM_WALL_COLORS = table.freeze({
	Color3.fromRGB(214, 210, 204), -- light grey
	Color3.fromRGB(176, 92, 74),   -- brick red
	Color3.fromRGB(226, 214, 188), -- cream
	Color3.fromRGB(150, 168, 178), -- blue-grey
	Color3.fromRGB(196, 176, 150), -- sandstone
	Color3.fromRGB(120, 150, 146), -- teal-grey
	Color3.fromRGB(238, 238, 236), -- white
})

LotDressingConfig.COMM_SIGN_COLORS = table.freeze({
	Color3.fromRGB(206, 74, 64),   -- red
	Color3.fromRGB(60, 120, 200),  -- blue
	Color3.fromRGB(60, 150, 90),   -- green
	Color3.fromRGB(226, 150, 50),  -- orange
	Color3.fromRGB(150, 80, 160),  -- purple
	Color3.fromRGB(40, 160, 170),  -- teal
})

LotDressingConfig.COMM_AWNING_COLORS = table.freeze({
	Color3.fromRGB(170, 60, 54),   -- burgundy
	Color3.fromRGB(46, 70, 120),   -- navy
	Color3.fromRGB(54, 110, 72),   -- forest
	Color3.fromRGB(60, 64, 70),    -- charcoal
	Color3.fromRGB(180, 140, 70),  -- ochre
})

LotDressingConfig.COMM_GLASS = Color3.fromRGB(120, 150, 165)

-- Parking lot in front of commercial buildings.
LotDressingConfig.PARKING = table.freeze({
	slabColor = Color3.fromRGB(74, 74, 78),
	slabMaterial = Enum.Material.Asphalt,
	lineColor = Color3.fromRGB(224, 218, 120),
	stallWidth = 9,
	stallDepth = 20,
	aisle = 14,
	lift = 0.22,
	margin = 1.2,
	carChance = 0.5,
	carColors = table.freeze({
		Color3.fromRGB(225, 225, 235), Color3.fromRGB(60, 70, 90),
		Color3.fromRGB(150, 40, 40), Color3.fromRGB(40, 90, 60),
		Color3.fromRGB(40, 44, 50), Color3.fromRGB(180, 150, 60),
	}),
})

-- Industrial facade palette + loading-yard.
LotDressingConfig.IND_WALL_COLORS = table.freeze({
	Color3.fromRGB(176, 178, 182), -- galvanized
	Color3.fromRGB(196, 188, 170), -- beige
	Color3.fromRGB(150, 152, 158), -- grey
	Color3.fromRGB(168, 150, 130), -- tan
	Color3.fromRGB(140, 158, 160), -- blue-grey
})

LotDressingConfig.YARD = table.freeze({
	apronColor = Color3.fromRGB(118, 118, 120),
	apronMaterial = Enum.Material.Concrete,
	lift = 0.22,
	margin = 1.2,
	containerColors = table.freeze({
		Color3.fromRGB(176, 96, 70), Color3.fromRGB(70, 110, 150),
		Color3.fromRGB(90, 130, 90), Color3.fromRGB(200, 170, 80),
	}),
})

-- Half-size world (RoadConstants.WORLD_SCALE): scale every stud DIMENSION (widths, heights,
-- depths, insets, margins) so the dressing matches the half-size buildings + lots. Colours,
-- materials, weights, counts and chances are left untouched.
do
	local WS = require(game:GetService("ReplicatedStorage").Road.RoadConstants).WORLD_SCALE
	if WS ~= 1 then
		local function scaled(t: any, fields: { string }): any
			local c = table.clone(t)
			for _, f in fields do if type(c[f]) == "number" then c[f] = c[f] * WS end end
			return table.freeze(c)
		end
		LotDressingConfig.PATH = scaled(LotDressingConfig.PATH, { "width", "thickness", "lift" })
		LotDressingConfig.DRIVE = scaled(LotDressingConfig.DRIVE, { "width", "thickness", "lift" })
		local fences = {}
		for i, f in LotDressingConfig.FENCE do fences[i] = scaled(f, { "height", "thickness", "postSize" }) end
		LotDressingConfig.FENCE = table.freeze(fences)
		LotDressingConfig.FENCE_INSET = LotDressingConfig.FENCE_INSET * WS
		LotDressingConfig.GATE_HALF = scaled(LotDressingConfig.GATE_HALF, { "path", "drive" })
		LotDressingConfig.PARKING = scaled(LotDressingConfig.PARKING, { "stallWidth", "stallDepth", "aisle", "lift", "margin" })
		LotDressingConfig.YARD = scaled(LotDressingConfig.YARD, { "lift", "margin" })
		LotDressingConfig.BACKYARD = scaled(LotDressingConfig.BACKYARD, { "margin" })
	end
end

return table.freeze(LotDressingConfig)
