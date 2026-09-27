--!strict
-- ServiceBuildingModel
-- Clones pre-made models from ServerStorage.Templates.Asset.Building.Services when they
-- exist; otherwise builds procedurally from the ServiceTypes spec: emergency kinds get
-- the shared office body + per-kind flourish, utilities get dedicated landmark builds
-- (buildUtility). No templates ship today, so the procedural path is what players see.
-- `ghost` makes every part translucent + non-collidable for the placement preview.
-- PrimaryPart is "Root" (invisible, at base centre). +Z faces the road.

local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local ServerStorage     = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServiceTypes      = require(script.Parent.ServiceTypes)
local ZoneGrid          = require(ReplicatedStorage.City.ZoneGrid)

-- ONE folder, ReplicatedStorage.City.ServiceTemplates, for both sides. These used to
-- sit in ServerStorage with a mirrored copy here for the client ghost, but a MeshPart
-- cloned out of ServerStorage does not carry its mesh across to the client -- the placed
-- buildings rendered blank while the ghost looked right. Building art is not a secret, so
-- ReplicatedStorage is where it belongs (see CLAUDE.md 1). Resolved lazily on the first
-- build() call so requiring this module never blocks.
local _templateFolder: Folder? = nil

local function getFolder(): Folder?
	if _templateFolder then return _templateFolder end
	local city = ReplicatedStorage:FindFirstChild("City")
	local t = city and city:FindFirstChild("ServiceTemplates")
	if not (t and t:IsA("Folder")) then return nil end
	_templateFolder = t :: Folder
	return _templateFolder
end

local ServiceBuildingModel = {}

local function getTemplate(key: string): Model?
	local folder = getFolder()
	if not folder then return nil end
	local t = folder:FindFirstChild(key)
	return if t and t:IsA("Model") then t else nil
end

-- Procedural building: foundation, body with per-floor window bands, glass
-- entrance + canopy, roof parapet, and per-kind architecture (garage doors,
-- smokestacks, elevated tank, treatment basins, helipad...). Built at origin
-- with the base at Y=0; +Z is the road-facing front.
local GLASS_DARK  = Color3.fromRGB(40, 50, 62)
local TRIM_LIGHT  = Color3.fromRGB(226, 228, 231)
local METAL_GREY  = Color3.fromRGB(128, 132, 138)
local METAL_DARK  = Color3.fromRGB(70, 72, 78)
local ASPHALT     = Color3.fromRGB(52, 54, 58)

-- Utility landmarks. Each utility gets bespoke geometry instead of the shared
-- office body; proportions follow the classic city-builder look: a dark coal
-- hall with banded stacks + coal pile/conveyor, a slim white wind turbine (its
-- "Rotor" sub-model is tagged so WindTurbineView spins it client-side), a
-- drum-on-column water tower, and clarifier-basin sewage works.
local function buildUtility(model: Model, key: string, spec: ServiceTypes.Spec, fp: Vector3,
	part: (Vector3, CFrame, Color3, Enum.Material, Enum.PartType?) -> Part,
	column: (number, number, CFrame, Color3, Enum.Material) -> Part)

	if key == "WindTurbine" then
		-- Service cabinet at the base.
		part(Vector3.new(3.4, 2.6, 2.4), CFrame.new(4.6, 1.8, 4.6), TRIM_LIGHT, Enum.Material.SmoothPlastic)
		part(Vector3.new(1.2, 1.8, 0.3), CFrame.new(4.6, 1.4, 5.85), METAL_DARK, Enum.Material.Metal)
		-- Tapered white tower.
		local white = spec.wall
		local seg1 = column(3.2, 14, CFrame.new(0, 7.5, 0), white, Enum.Material.SmoothPlastic)
		seg1.Name = "Body"; seg1.CanCollide = true; seg1.CanQuery = true
		column(2.5, 13, CFrame.new(0, 20.5, 0), white, Enum.Material.SmoothPlastic)
		column(2.0, 12, CFrame.new(0, 33, 0), white, Enum.Material.SmoothPlastic)
		-- Nacelle + rear vent cap.
		local nacelle = part(Vector3.new(2.4, 2.4, 4.8), CFrame.new(0, 40, 0.2), white, Enum.Material.SmoothPlastic)
		nacelle.CanQuery = true
		part(Vector3.new(2.0, 2.0, 0.7), CFrame.new(0, 40, -2.4), spec.roof, Enum.Material.Metal)
		-- Rotor: hub + nose + three blades, spun by WindTurbineView on the client.
		local rotor = Instance.new("Model")
		rotor.Name = "Rotor"
		local hubCF = CFrame.new(0, 40, 2.9)
		local hub = part(Vector3.new(1.7, 1.7, 1.7), hubCF, white, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		hub.Parent = rotor
		local nose = part(Vector3.new(1.0, 1.1, 1.1), hubCF * CFrame.new(0, 0, 1.0) * CFrame.Angles(0, math.rad(90), 0), white, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		nose.Parent = rotor
		for i = 0, 2 do
			local blade = part(Vector3.new(0.9, 12.5, 0.35),
				hubCF * CFrame.Angles(0, 0, math.rad(i * 120)) * CFrame.new(0, 6.6, 0), white, Enum.Material.SmoothPlastic)
			blade.Parent = rotor
		end
		rotor.PrimaryPart = hub
		rotor.Parent = model
		CollectionService:AddTag(rotor, "WindTurbineRotor")

	elseif key == "PowerPlant" then
		-- Turbine hall (tall) + annex (low), dark industrial metal.
		local hall = part(Vector3.new(30, 16, 24), CFrame.new(-11, 8.5, 3), spec.wall, Enum.Material.Metal)
		hall.Name = "Body"; hall.CanCollide = true; hall.CanQuery = true
		part(Vector3.new(31, 1, 25), CFrame.new(-11, 17, 3), spec.roof, Enum.Material.Metal)
		local annex = part(Vector3.new(20, 10, 18), CFrame.new(14, 5.5, 6), spec.wall:Lerp(Color3.new(1, 1, 1), 0.12), Enum.Material.Metal)
		annex.CanCollide = true; annex.CanQuery = true
		part(Vector3.new(21, 0.8, 19), CFrame.new(14, 10.9, 6), spec.roof, Enum.Material.Metal)
		-- Front control glass + hazard stripes.
		part(Vector3.new(24, 3.2, 0.4), CFrame.new(-11, 11, 15.2), GLASS_DARK, Enum.Material.Glass)
		part(Vector3.new(30, 1.4, 0.4), CFrame.new(-11, 2.6, 15.2), spec.accent, Enum.Material.SmoothPlastic)
		part(Vector3.new(20, 1.2, 0.4), CFrame.new(14, 2.4, 15.2), spec.accent, Enum.Material.SmoothPlastic)
		-- Twin banded smokestacks behind the hall.
		for _, x in { -19, -5 } do
			column(6, 34, CFrame.new(x, 17.5, -17), Color3.fromRGB(168, 168, 162), Enum.Material.Concrete)
			column(6.25, 1.8, CFrame.new(x, 33.7, -17), Color3.fromRGB(186, 62, 54), Enum.Material.SmoothPlastic)
			column(5.0, 0.8, CFrame.new(x, 35.1, -17), METAL_DARK, Enum.Material.Metal)
		end
		-- Coal pile (stacked rubble boxes) + conveyor ramp feeding the annex.
		local COAL = Color3.fromRGB(28, 28, 30)
		part(Vector3.new(14, 3.4, 10), CFrame.new(19, 2.2, -15) * CFrame.Angles(0, math.rad(14), 0), COAL, Enum.Material.Slate)
		part(Vector3.new(9, 2.4, 7), CFrame.new(18.5, 5.1, -15) * CFrame.Angles(0, math.rad(-9), 0), COAL, Enum.Material.Slate)
		part(Vector3.new(5, 1.6, 4), CFrame.new(18, 7.1, -15) * CFrame.Angles(0, math.rad(23), 0), COAL, Enum.Material.Slate)
		local ramp = CFrame.new(16, 8.5, -3) * CFrame.Angles(math.rad(-30), 0, 0)
		part(Vector3.new(3.4, 0.6, 21), ramp, METAL_GREY, Enum.Material.DiamondPlate)
		part(Vector3.new(0.4, 1.4, 21), ramp * CFrame.new(-1.7, 0.9, 0), METAL_DARK, Enum.Material.Metal)
		part(Vector3.new(0.4, 1.4, 21), ramp * CFrame.new(1.7, 0.9, 0), METAL_DARK, Enum.Material.Metal)
		column(0.8, 7, CFrame.new(16, 3.5, 2), METAL_DARK, Enum.Material.Metal)
		-- Transformer yard on the front apron.
		for i = 0, 2 do
			local tx = CFrame.new(26, 0, 14 - i * 7)
			part(Vector3.new(3.4, 3.4, 2.6), tx * CFrame.new(0, 2.2, 0), METAL_DARK, Enum.Material.DiamondPlate)
			column(0.5, 1.4, tx * CFrame.new(-0.8, 4.6, 0), TRIM_LIGHT, Enum.Material.SmoothPlastic)
			column(0.5, 1.4, tx * CFrame.new(0.8, 4.6, 0), TRIM_LIGHT, Enum.Material.SmoothPlastic)
		end

	elseif key == "WaterTower" then
		-- Drum-on-column: concrete stem, wide drum with the accent band, stepped
		-- dome cap, riser pipe + small pump house.
		local stem = column(7, 13, CFrame.new(0, 7, 0), Color3.fromRGB(186, 186, 180), Enum.Material.Concrete)
		stem.Name = "Body"; stem.CanCollide = true; stem.CanQuery = true
		part(Vector3.new(2.2, 3.2, 0.4), CFrame.new(0, 2.2, 3.55), METAL_DARK, Enum.Material.Metal)
		local drum = column(21, 8, CFrame.new(0, 17.5, 0), spec.wall, Enum.Material.Metal)
		drum.CanCollide = true; drum.CanQuery = true
		column(21.3, 1.5, CFrame.new(0, 17.5, 0), spec.accent, Enum.Material.SmoothPlastic)
		column(21.3, 0.8, CFrame.new(0, 14.0, 0), METAL_GREY, Enum.Material.Metal)
		column(17.5, 1.6, CFrame.new(0, 22.2, 0), spec.wall, Enum.Material.Metal)
		column(12, 1.2, CFrame.new(0, 23.5, 0), spec.wall, Enum.Material.Metal)
		column(5.5, 0.9, CFrame.new(0, 24.4, 0), spec.wall, Enum.Material.Metal)
		column(0.7, 1.8, CFrame.new(0, 25.6, 0), METAL_GREY, Enum.Material.Metal)
		column(1.2, 13, CFrame.new(4.2, 7, 0), METAL_GREY, Enum.Material.Metal)
		local house = part(Vector3.new(6.5, 4.5, 5), CFrame.new(9.5, 2.75, 9.5), Color3.fromRGB(200, 200, 194), Enum.Material.Concrete)
		house.CanCollide = true; house.CanQuery = true
		part(Vector3.new(7.1, 0.6, 5.6), CFrame.new(9.5, 5.2, 9.5), spec.roof, Enum.Material.Slate)
		part(Vector3.new(1.8, 2.8, 0.3), CFrame.new(9.5, 1.9, 12.05), METAL_DARK, Enum.Material.Metal)

	elseif key == "SewagePlant" then
		local WATER = Color3.fromRGB(58, 76, 60)
		local RIM = Color3.fromRGB(178, 178, 170)
		-- Three circular clarifier basins: concrete rim, murky water, hub + skimmer arm.
		local basins = { { x = -12, z = -10, d = 19 }, { x = 12, z = -12, d = 19 }, { x = 14, z = 10, d = 15 } }
		for i, b in basins do
			local rim = column(b.d, 3, CFrame.new(b.x, 2, b.z), RIM, Enum.Material.Concrete)
			rim.CanCollide = true; rim.CanQuery = true
			column(b.d - 1.8, 3.1, CFrame.new(b.x, 2.05, b.z), WATER, Enum.Material.SmoothPlastic)
			column(1.6, 1.4, CFrame.new(b.x, 4.2, b.z), METAL_GREY, Enum.Material.Metal)
			part(Vector3.new(0.9, 0.5, b.d * 0.5), CFrame.new(b.x, 3.9, b.z) * CFrame.Angles(0, math.rad(i * 77), 0) * CFrame.new(0, 0, b.d * 0.25), METAL_GREY, Enum.Material.Metal)
		end
		-- Rectangular aeration tank with divider walls.
		part(Vector3.new(16, 3, 10), CFrame.new(-2, 2, 13), RIM, Enum.Material.Concrete)
		part(Vector3.new(14.6, 2.9, 8.6), CFrame.new(-2, 2.1, 13), WATER, Enum.Material.SmoothPlastic)
		part(Vector3.new(0.5, 0.9, 8.6), CFrame.new(-5.5, 3.8, 13), RIM, Enum.Material.Concrete)
		part(Vector3.new(0.5, 0.9, 8.6), CFrame.new(1.5, 3.8, 13), RIM, Enum.Material.Concrete)
		-- Connecting pipe runs on the ground between basins.
		part(Vector3.new(6, 1.2, 1.2), CFrame.new(0, 1.1, -11), METAL_GREY, Enum.Material.Metal, Enum.PartType.Cylinder)
		part(Vector3.new(8, 1.1, 1.1), CFrame.new(13, 1.0, -1) * CFrame.Angles(0, math.rad(90), 0), METAL_GREY, Enum.Material.Metal, Enum.PartType.Cylinder)
		-- Admin office up front-left.
		local office = part(Vector3.new(11, 7, 8), CFrame.new(-16, 4, 16), spec.wall, Enum.Material.Concrete)
		office.Name = "Body"; office.CanCollide = true; office.CanQuery = true
		part(Vector3.new(11.6, 0.7, 8.6), CFrame.new(-16, 7.7, 16), spec.roof, Enum.Material.Slate)
		part(Vector3.new(9, 1.9, 0.35), CFrame.new(-16, 4.9, 20.1), GLASS_DARK, Enum.Material.Glass)
		part(Vector3.new(2, 3.4, 0.35), CFrame.new(-13.4, 2.2, 20.1), METAL_DARK, Enum.Material.Metal)
		part(Vector3.new(11, 0.9, 0.4), CFrame.new(-16, 0.9, 20.15), spec.accent, Enum.Material.SmoothPlastic)
	else
		-- ponytail: placeholder art -- a block in the card's colours with an accent band --
		-- until the real model lands in ServiceTemplates under this key.
		local body = part(Vector3.new(fp.X - 4, fp.Y, fp.Z - 4), CFrame.new(0, fp.Y * 0.5 + 0.5, 0), spec.wall, Enum.Material.SmoothPlastic)
		body.Name = "Body"; body.CanCollide = true; body.CanQuery = true
		part(Vector3.new(fp.X - 3, 1, fp.Z - 3), CFrame.new(0, fp.Y + 1, 0), spec.roof, Enum.Material.SmoothPlastic)
		part(Vector3.new(fp.X - 3.8, 1.2, fp.Z - 3.8), CFrame.new(0, fp.Y * 0.6, 0), spec.accent, Enum.Material.Neon)
	end
end

-- == Healthcare ================================================================
-- Four DISTINCT buildings, not one shape at four scales: a brick neighbourhood
-- clinic, a brick ward wing under a glazed barrel atrium, a white slab-on-podium
-- hospital with green glazing bands, and a multi-wing general hospital with a
-- helipad. What they share is the vocabulary below -- rooftop plant, two glazing
-- styles, the red star of life, and marked bays with an ambulance parked in each.
-- The fleet size per tier comes from ServiceTypes.ambulances (3 / 5 / 6 / 10).
local BRICK       = Color3.fromRGB(150, 84, 68)
local BRICK_TRIM  = Color3.fromRGB(226, 214, 190)
local ROOF_DARK   = Color3.fromRGB(62, 54, 50)
local GLASS_GREEN = Color3.fromRGB(84, 152, 104)
local HVAC_GREY   = Color3.fromRGB(158, 160, 164)
local LINE_WHITE  = Color3.fromRGB(236, 238, 240)
local TARMAC      = Color3.fromRGB(70, 72, 76)
local AMB_LIME    = Color3.fromRGB(206, 226, 64)
local SIREN_BLUE  = Color3.fromRGB(48, 96, 235)

-- One parking bay, and the depth the row of them occupies.
local BAY_W = 8.4
local BAY_D = 17
-- Front strip reserved for the apron: one bay row on the small tiers, two on the big.
local APRON_1 = 19
local APRON_2 = 38

type PartFn = (Vector3, CFrame, Color3, Enum.Material, Enum.PartType?) -> Part
type ColumnFn = (number, number, CFrame, Color3, Enum.Material) -> Part

-- Rooftop plant: the HVAC boxes and vents that make a roof read as institutional.
local function roofPlant(part: PartFn, cx: number, cz: number, w: number, d: number, y: number, count: number)
	for i = 0, count - 1 do
		local row = math.floor(i / 2)
		local bx = cx + w * (if i % 2 == 0 then -0.24 else 0.2)
		local bz = cz + d * (-0.26 + row * 0.24)
		local bw = math.min(w * (0.13 + (i % 3) * 0.03), 7)
		local bd = math.min(d * 0.18, 5)
		part(Vector3.new(bw, 1.7, bd), CFrame.new(bx, y + 0.85, bz), HVAC_GREY, Enum.Material.Metal)
		part(Vector3.new(bw * 0.45, 0.8, bd * 0.45), CFrame.new(bx, y + 2.05, bz), METAL_DARK, Enum.Material.Metal)
	end
end

-- Continuous glazing band per floor -- the modern-hospital look.
local function glazingBands(part: PartFn, cx: number, cz: number, w: number, d: number,
	h: number, floors: number, tint: Color3, skipFront: boolean)
	local fh = h / floors
	for f = 1, floors do
		local y = 0.5 + fh * (f - 0.5)
		local wh = fh * 0.38
		if not (skipFront and f == 1) then
			part(Vector3.new(w - 2.4, wh, 0.3), CFrame.new(cx, y, cz + d * 0.5 + 0.08), tint, Enum.Material.Glass)
		end
		part(Vector3.new(w - 2.4, wh, 0.3), CFrame.new(cx, y, cz - d * 0.5 - 0.08), tint, Enum.Material.Glass)
		part(Vector3.new(0.3, wh, d - 2.4), CFrame.new(cx + w * 0.5 + 0.08, y, cz), tint, Enum.Material.Glass)
		part(Vector3.new(0.3, wh, d - 2.4), CFrame.new(cx - w * 0.5 - 0.08, y, cz), tint, Enum.Material.Glass)
	end
end

-- Individual punched openings -- the brick tiers.
local function punchedWindows(part: PartFn, cx: number, cz: number, w: number, d: number,
	h: number, floors: number, cols: number)
	local fh = h / floors
	local pitch = w / cols
	for f = 1, floors do
		local y = 0.5 + fh * (f - 0.5)
		for c = 0, cols - 1 do
			local x = cx + (c - (cols - 1) * 0.5) * pitch
			for _, sz in { -1, 1 } do
				part(Vector3.new(pitch * 0.44, fh * 0.46, 0.3),
					CFrame.new(x, y, cz + sz * (d * 0.5 + 0.08)), GLASS_DARK, Enum.Material.Glass)
			end
		end
	end
end

-- Star of life: the red six-spoke emblem the reference hospitals carry.
local function starOfLife(part: PartFn, cf: CFrame, size: number, color: Color3)
	for i = 0, 2 do
		part(Vector3.new(size * 0.26, size, 0.3), cf * CFrame.Angles(0, 0, math.rad(i * 60)), color, Enum.Material.Neon)
	end
end

-- ponytail: a parked ambulance is seven boxes -- it is only ever seen from the city
-- camera. When the bespoke mesh is uploaded this becomes one MeshPart clone and no
-- builder below has to change. Nose points -Z, so a bay faces the building.
local function parkedAmbulance(part: PartFn, cf: CFrame)
	part(Vector3.new(7.2, 3.2, 15.4), cf * CFrame.new(0, 2.1, 0), LINE_WHITE, Enum.Material.SmoothPlastic)
	part(Vector3.new(7.2, 2.8, 10.2), cf * CFrame.new(0, 5.1, 2.5), AMB_LIME, Enum.Material.SmoothPlastic)
	part(Vector3.new(7.3, 0.3, 10.4), cf * CFrame.new(0, 6.6, 2.5), LINE_WHITE, Enum.Material.SmoothPlastic)
	part(Vector3.new(6.6, 1.7, 5.2), cf * CFrame.new(0, 4.55, -5.1), AMB_LIME, Enum.Material.SmoothPlastic)
	part(Vector3.new(6.2, 1.6, 0.3), cf * CFrame.new(0, 4.6, -7.65), GLASS_DARK, Enum.Material.Glass)
	for _, sx in { -1, 1 } do
		part(Vector3.new(0.26, 1.1, 12.0), cf * CFrame.new(sx * 3.66, 3.4, 1.2), SIREN_BLUE, Enum.Material.SmoothPlastic)
	end
	part(Vector3.new(4.4, 0.5, 1.1), cf * CFrame.new(0, 5.6, -4.4), SIREN_BLUE, Enum.Material.Neon)
end

-- A row of `n` marked bays, right-aligned to xRight, each with an ambulance in it.
local function bayRow(part: PartFn, n: number, xRight: number, z: number, accent: Color3)
	for i = 0, n - 1 do
		local x = xRight - BAY_W * (i + 0.5)
		part(Vector3.new(BAY_W - 0.4, 0.14, BAY_D), CFrame.new(x, 0.57, z), TARMAC, Enum.Material.Concrete)
		part(Vector3.new(0.3, 0.16, BAY_D), CFrame.new(x - BAY_W * 0.5, 0.6, z), LINE_WHITE, Enum.Material.SmoothPlastic)
		part(Vector3.new(BAY_W - 0.4, 0.16, 0.5), CFrame.new(x, 0.6, z - BAY_D * 0.5 + 0.4), accent, Enum.Material.SmoothPlastic)
		parkedAmbulance(part, CFrame.new(x, 0.5, z + 0.8))
	end
	part(Vector3.new(0.3, 0.16, BAY_D), CFrame.new(xRight, 0.6, z), LINE_WHITE, Enum.Material.SmoothPlastic)
end

-- Tier 1: neighbourhood clinic. Single storey, brick with a white parapet band and a
-- dark flat roof, glazed entrance off to one side, three bays on the other.
local function buildClinic(model: Model, spec: ServiceTypes.Spec, fp: Vector3, part: PartFn, column: ColumnFn)
	local wx, wz = fp.X * 0.5, fp.Z * 0.5
	local h = fp.Y
	local d = fp.Z - APRON_1 - 0.5
	local cz = -wz + 0.5 + d * 0.5
	local w = fp.X - 3

	local body = part(Vector3.new(w, h, d), CFrame.new(0, h * 0.5 + 0.5, cz), BRICK, Enum.Material.Brick)
	body.Name = "Body"
	body.CanCollide = true
	body.CanQuery = true
	part(Vector3.new(w + 0.7, 1.1, d + 0.7), CFrame.new(0, h + 0.05, cz), BRICK_TRIM, Enum.Material.Concrete)
	part(Vector3.new(w + 1.1, 0.5, d + 1.1), CFrame.new(0, h + 0.85, cz), ROOF_DARK, Enum.Material.Slate)

	local fz = cz + d * 0.5
	local ex = -w * 0.3
	part(Vector3.new(11, h - 1.6, 0.4), CFrame.new(ex, (h - 1.6) * 0.5 + 0.5, fz + 0.1), GLASS_DARK, Enum.Material.Glass)
	part(Vector3.new(0.5, h - 1.6, 0.45), CFrame.new(ex, (h - 1.6) * 0.5 + 0.5, fz + 0.16), LINE_WHITE, Enum.Material.Metal)
	part(Vector3.new(13, 0.5, 3.6), CFrame.new(ex, h - 0.5, fz + 1.8), spec.accent, Enum.Material.SmoothPlastic)
	for _, sx in { -1, 1 } do
		column(0.5, h - 1.1, CFrame.new(ex + sx * 5.6, (h - 1.1) * 0.5 + 0.5, fz + 3.2), LINE_WHITE, Enum.Material.Metal)
	end

	punchedWindows(part, w * 0.26, cz, w * 0.42, d, h, 1, 3)
	for _, sx in { -1, 1 } do
		part(Vector3.new(0.3, h * 0.46, d - 3), CFrame.new(sx * (w * 0.5 + 0.08), h * 0.5 + 0.5, cz), GLASS_DARK, Enum.Material.Glass)
	end

	roofPlant(part, 0, cz, w, d, h + 1.1, 2)
	starOfLife(part, CFrame.new(-w * 0.3, h + 2.6, fz + 0.3), 3.4, spec.accent)
	bayRow(part, spec.ambulances or 3, wx - 1.5, wz - 0.5 - BAY_D * 0.5, spec.accent)
end

-- Tier 2: small hospital. Two brick ward wings of unequal height meeting at a glazed
-- atrium under a barrel vault, red awning over the doors, five bays.
local function buildSmallHospital(model: Model, spec: ServiceTypes.Spec, fp: Vector3, part: PartFn, column: ColumnFn)
	local wx, wz = fp.X * 0.5, fp.Z * 0.5
	local h = fp.Y
	local d = fp.Z - APRON_1 - 0.5
	local cz = -wz + 0.5 + d * 0.5
	local w = fp.X - 4

	local leftW = w * 0.4
	local rightW = w * 0.32
	local atriumW = w - leftW - rightW
	local leftX = -(w - leftW) * 0.5
	local rightX = (w - rightW) * 0.5

	local left = part(Vector3.new(leftW, h, d), CFrame.new(leftX, h * 0.5 + 0.5, cz), BRICK, Enum.Material.Brick)
	left.Name = "Body"
	left.CanCollide = true
	left.CanQuery = true
	part(Vector3.new(leftW + 0.8, 0.9, d + 0.8), CFrame.new(leftX, h + 0.6, cz), ROOF_DARK, Enum.Material.Slate)
	punchedWindows(part, leftX, cz, leftW, d, h, 2, 4)
	roofPlant(part, leftX, cz, leftW, d, h + 1.05, 4)

	local rightH = h * 0.68
	local rightD = d * 0.74
	local rightZ = cz - (d - rightD) * 0.5
	local right = part(Vector3.new(rightW, rightH, rightD), CFrame.new(rightX, rightH * 0.5 + 0.5, rightZ), BRICK, Enum.Material.Brick)
	right.CanCollide = true
	right.CanQuery = true
	part(Vector3.new(rightW + 0.8, 0.9, rightD + 0.8), CFrame.new(rightX, rightH + 0.6, rightZ), ROOF_DARK, Enum.Material.Slate)
	punchedWindows(part, rightX, rightZ, rightW, rightD, rightH, 2, 3)

	local atriumD = d * 0.6
	local atriumZ = cz + (d - atriumD) * 0.5
	local atriumH = h * 0.84
	part(Vector3.new(atriumW, atriumH, atriumD), CFrame.new(0, atriumH * 0.5 + 0.5, atriumZ), BRICK_TRIM, Enum.Material.Concrete)
	local fz = atriumZ + atriumD * 0.5
	part(Vector3.new(atriumW - 1.6, atriumH - 1.4, 0.4), CFrame.new(0, atriumH * 0.5 + 0.5, fz + 0.1), GLASS_DARK, Enum.Material.Glass)
	-- Barrel vault: cylinder axis turned to run front-to-back, so the curve arches
	-- across the atrium's width.
	part(Vector3.new(atriumD, atriumW * 0.92, atriumW * 0.92),
		CFrame.new(0, atriumH, atriumZ) * CFrame.Angles(0, math.rad(90), 0), GLASS_DARK, Enum.Material.Glass, Enum.PartType.Cylinder)
	for i = -1, 1 do
		part(Vector3.new(0.45, atriumH - 1.4, 0.5), CFrame.new(i * atriumW * 0.27, atriumH * 0.5 + 0.5, fz + 0.18), BRICK_TRIM, Enum.Material.Metal)
	end
	part(Vector3.new(atriumW * 0.74, 0.5, 4.4), CFrame.new(0, 6.4, fz + 2.2), spec.accent, Enum.Material.SmoothPlastic)
	for _, sx in { -1, 1 } do
		column(0.6, 5.8, CFrame.new(sx * atriumW * 0.3, 3.4, fz + 4.0), LINE_WHITE, Enum.Material.Metal)
	end

	starOfLife(part, CFrame.new(rightX, rightH - 2.6, rightZ + rightD * 0.5 + 0.3), 4.4, spec.accent)
	bayRow(part, spec.ambulances or 5, wx - 1.5, wz - 0.5 - BAY_D * 0.5, spec.accent)
end

-- Tier 3: hospital. A clean white ward slab on a lower glazed podium, four floors of
-- green-tinted bands, deep emergency canopy, two rows of three bays.
local function buildHospital(model: Model, spec: ServiceTypes.Spec, fp: Vector3, part: PartFn, column: ColumnFn)
	local wx, wz = fp.X * 0.5, fp.Z * 0.5
	local h = fp.Y
	local d = fp.Z - APRON_2 - 0.5
	local cz = -wz + 0.5 + d * 0.5
	local w = fp.X - 4

	local slabD = d * 0.66
	local slabZ = cz - (d - slabD) * 0.5
	local slab = part(Vector3.new(w, h, slabD), CFrame.new(0, h * 0.5 + 0.5, slabZ), spec.wall, Enum.Material.Concrete)
	slab.Name = "Body"
	slab.CanCollide = true
	slab.CanQuery = true
	glazingBands(part, 0, slabZ, w, slabD, h, 4, GLASS_GREEN, false)
	part(Vector3.new(w + 1.0, 0.7, slabD + 1.0), CFrame.new(0, h + 0.85, slabZ), spec.roof, Enum.Material.Slate)
	roofPlant(part, 0, slabZ, w, slabD, h + 1.2, 6)

	local podD = d - slabD
	local podW = w * 0.84
	local podZ = cz + (d - podD) * 0.5
	local podH = h * 0.36
	local pod = part(Vector3.new(podW, podH, podD), CFrame.new(0, podH * 0.5 + 0.5, podZ), spec.wall, Enum.Material.Concrete)
	pod.CanCollide = true
	pod.CanQuery = true
	glazingBands(part, 0, podZ, podW, podD, podH, 2, GLASS_DARK, true)
	part(Vector3.new(podW + 0.9, 0.6, podD + 0.9), CFrame.new(0, podH + 0.8, podZ), spec.roof, Enum.Material.Slate)
	roofPlant(part, 0, podZ, podW, podD, podH + 1.1, 2)

	-- Emergency entrance on the left, clear of the bays on the right.
	local fz = podZ + podD * 0.5
	local ex = -w * 0.26
	part(Vector3.new(w * 0.3, podH - 1.6, 0.4), CFrame.new(ex, (podH - 1.6) * 0.5 + 0.5, fz + 0.12), GLASS_DARK, Enum.Material.Glass)
	local canopyY = podH - 0.3
	part(Vector3.new(w * 0.38, 0.7, 9.0), CFrame.new(ex, canopyY, fz + 4.5), spec.accent, Enum.Material.SmoothPlastic)
	for _, sx in { -1, 1 } do
		for _, cz2 in { fz + 1.6, fz + 7.6 } do
			column(0.7, canopyY - 0.85, CFrame.new(ex + sx * w * 0.16, (canopyY - 0.85) * 0.5 + 0.5, cz2), LINE_WHITE, Enum.Material.Metal)
		end
	end
	starOfLife(part, CFrame.new(-w * 0.36, h * 0.74, slabZ + slabD * 0.5 + 0.3), 6.5, spec.accent)

	local n = spec.ambulances or 6
	local half = math.ceil(n / 2)
	bayRow(part, half, wx - 2, wz - 0.5 - BAY_D * 0.5, spec.accent)
	bayRow(part, n - half, wx - 2, wz - 2.5 - BAY_D * 1.5, spec.accent)
end

-- Tier 4: general hospital. Three ward slabs of different heights around a glazed
-- link block, rooftop helipad on the low wing, and ten bays in two rows.
local function buildGeneralHospital(model: Model, spec: ServiceTypes.Spec, fp: Vector3, part: PartFn, column: ColumnFn)
	local wx, wz = fp.X * 0.5, fp.Z * 0.5
	local h = fp.Y
	local d = fp.Z - APRON_2 - 0.5
	local cz = -wz + 0.5 + d * 0.5
	local w = fp.X - 4

	-- Tall centre slab.
	local midW = w * 0.34
	local midD = d * 0.58
	local midZ = cz - (d - midD) * 0.5
	local mid = part(Vector3.new(midW, h, midD), CFrame.new(0, h * 0.5 + 0.5, midZ), spec.wall, Enum.Material.Concrete)
	mid.Name = "Body"
	mid.CanCollide = true
	mid.CanQuery = true
	glazingBands(part, 0, midZ, midW, midD, h, 6, GLASS_GREEN, false)
	part(Vector3.new(midW + 1.0, 0.7, midD + 1.0), CFrame.new(0, h + 0.85, midZ), spec.roof, Enum.Material.Slate)
	roofPlant(part, 0, midZ, midW, midD, h + 1.2, 4)

	-- Left wing: mid height, deep. Right wing: low and wide, and it carries the pad.
	local leftW = w * 0.3
	local leftH = h * 0.62
	local leftD = d * 0.7
	local leftX = -(w - leftW) * 0.5
	local leftZ = cz - (d - leftD) * 0.5
	local leftWing = part(Vector3.new(leftW, leftH, leftD), CFrame.new(leftX, leftH * 0.5 + 0.5, leftZ), spec.wall, Enum.Material.Concrete)
	leftWing.Name = "Wing"
	leftWing.CanCollide = true
	leftWing.CanQuery = true
	glazingBands(part, leftX, leftZ, leftW, leftD, leftH, 4, GLASS_GREEN, false)
	part(Vector3.new(leftW + 0.9, 0.7, leftD + 0.9), CFrame.new(leftX, leftH + 0.85, leftZ), spec.roof, Enum.Material.Slate)
	roofPlant(part, leftX, leftZ, leftW, leftD, leftH + 1.2, 4)

	local rightW = w * 0.32
	local rightH = h * 0.4
	local rightD = d * 0.62
	local rightX = (w - rightW) * 0.5
	local rightZ = cz - (d - rightD) * 0.5
	local rightWing = part(Vector3.new(rightW, rightH, rightD), CFrame.new(rightX, rightH * 0.5 + 0.5, rightZ), spec.wall, Enum.Material.Concrete)
	rightWing.Name = "Wing"
	rightWing.CanCollide = true
	rightWing.CanQuery = true
	glazingBands(part, rightX, rightZ, rightW, rightD, rightH, 2, GLASS_GREEN, false)
	part(Vector3.new(rightW + 0.9, 0.7, rightD + 0.9), CFrame.new(rightX, rightH + 0.85, rightZ), spec.roof, Enum.Material.Slate)

	-- Rooftop helipad on the low wing.
	local pad = math.min(rightW - 3, rightD - 3, 20)
	local padY = rightH + 1.6
	column(pad, 0.4, CFrame.new(rightX, padY, rightZ), ASPHALT, Enum.Material.Concrete)
	column(pad * 0.86, 0.3, CFrame.new(rightX, padY + 0.25, rightZ), LINE_WHITE, Enum.Material.SmoothPlastic)
	column(pad * 0.7, 0.3, CFrame.new(rightX, padY + 0.4, rightZ), ASPHALT, Enum.Material.Concrete)
	local hs = pad * 0.34
	for _, sx in { -1, 1 } do
		part(Vector3.new(hs * 0.24, 0.2, hs), CFrame.new(rightX + sx * hs * 0.36, padY + 0.6, rightZ), LINE_WHITE, Enum.Material.SmoothPlastic)
	end
	part(Vector3.new(hs * 0.5, 0.2, hs * 0.24), CFrame.new(rightX, padY + 0.6, rightZ), LINE_WHITE, Enum.Material.SmoothPlastic)

	-- Glazed link block bridging the slabs across the front.
	local linkD = d - midD
	local linkZ = cz + (d - linkD) * 0.5
	local linkH = h * 0.3
	part(Vector3.new(w * 0.9, linkH, linkD), CFrame.new(0, linkH * 0.5 + 0.5, linkZ), spec.wall, Enum.Material.Concrete)
	glazingBands(part, 0, linkZ, w * 0.9, linkD, linkH, 2, GLASS_DARK, true)
	part(Vector3.new(w * 0.9 + 0.9, 0.6, linkD + 0.9), CFrame.new(0, linkH + 0.8, linkZ), spec.roof, Enum.Material.Slate)

	-- Main entrance on the left, bays on the right.
	local fz = linkZ + linkD * 0.5
	local ex = -w * 0.3
	part(Vector3.new(w * 0.26, linkH - 1.6, 0.4), CFrame.new(ex, (linkH - 1.6) * 0.5 + 0.5, fz + 0.12), GLASS_DARK, Enum.Material.Glass)
	local canopyY = linkH - 0.3
	part(Vector3.new(w * 0.32, 0.7, 10.0), CFrame.new(ex, canopyY, fz + 5.0), spec.accent, Enum.Material.SmoothPlastic)
	for _, sx in { -1, 1 } do
		for _, cz2 in { fz + 1.8, fz + 8.4 } do
			column(0.8, canopyY - 0.85, CFrame.new(ex + sx * w * 0.13, (canopyY - 0.85) * 0.5 + 0.5, cz2), LINE_WHITE, Enum.Material.Metal)
		end
	end
	starOfLife(part, CFrame.new(0, h * 0.8, midZ + midD * 0.5 + 0.3), 8, spec.accent)
	starOfLife(part, CFrame.new(leftX, leftH - 3, leftZ + leftD * 0.5 + 0.3), 5, spec.accent)

	local n = spec.ambulances or 10
	local half = math.ceil(n / 2)
	bayRow(part, half, wx - 2, wz - 0.5 - BAY_D * 0.5, spec.accent)
	bayRow(part, n - half, wx - 2, wz - 2.5 - BAY_D * 1.5, spec.accent)
end

local HEALTHCARE_BUILDERS: { [string]: (Model, ServiceTypes.Spec, Vector3, PartFn, ColumnFn) -> () } = {
	Clinic = buildClinic,
	SmallHospital = buildSmallHospital,
	Hospital = buildHospital,
	GeneralHospital = buildGeneralHospital,
}

local function buildPlaceholder(key: string): Model?
	local spec = ServiceTypes.get(key)
	if not spec then return nil end
	local fp = ServiceTypes.footprintStuds(spec) -- X wide, Y body height, Z deep

	local model = Instance.new("Model")
	model.Name = key

	local function part(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		if shape then p.Shape = shape end
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		return p
	end

	-- Vertical cylinder helper (Part cylinders lie on X; stand them up).
	local function column(diameter: number, height: number, cf: CFrame, color: Color3, material: Enum.Material): Part
		return part(Vector3.new(height, diameter, diameter), cf * CFrame.Angles(0, 0, math.rad(90)), color, material, Enum.PartType.Cylinder)
	end

	local root = part(Vector3.new(fp.X, 0.2, fp.Z), CFrame.new(0, 0.1, 0), spec.wall, Enum.Material.SmoothPlastic)
	root.Name = "Root"
	root.Transparency = 1
	model.PrimaryPart = root

	local kind = spec.kind

	-- Utilities are landmark structures, not offices: dedicated per-key builds
	-- (they lay their own foundation and return before the office path).
	if spec.category == "Utilities" then
		part(Vector3.new(fp.X, 0.5, fp.Z), CFrame.new(0, 0.25, 0), ASPHALT, Enum.Material.Concrete)
		buildUtility(model, key, spec, fp, part, column)
		return model
	end

	-- Cemetery: not an office -- a walled lawn with headstone rows, a gravel path
	-- and a small stone chapel at the back.
	if kind == "Deathcare" then
		local GRASS = Color3.fromRGB(92, 134, 78)
		local STONE = Color3.fromRGB(172, 174, 176)
		local wx, wz = fp.X * 0.5, fp.Z * 0.5
		part(Vector3.new(fp.X, 0.5, fp.Z), CFrame.new(0, 0.25, 0), GRASS, Enum.Material.Grass)
		-- Perimeter wall; the front (+Z) leaves a 6-stud gate at the centre.
		part(Vector3.new(fp.X, 2.2, 0.8), CFrame.new(0, 1.4, -wz + 0.4), STONE, Enum.Material.Concrete)
		part(Vector3.new(0.8, 2.2, fp.Z), CFrame.new(-wx + 0.4, 1.4, 0), STONE, Enum.Material.Concrete)
		part(Vector3.new(0.8, 2.2, fp.Z), CFrame.new(wx - 0.4, 1.4, 0), STONE, Enum.Material.Concrete)
		local gateW = 6
		local segW = (fp.X - gateW) * 0.5
		part(Vector3.new(segW, 2.2, 0.8), CFrame.new(-(gateW + segW) * 0.5, 1.4, wz - 0.4), STONE, Enum.Material.Concrete)
		part(Vector3.new(segW, 2.2, 0.8), CFrame.new((gateW + segW) * 0.5, 1.4, wz - 0.4), STONE, Enum.Material.Concrete)
		-- Gravel path from the gate to the chapel.
		part(Vector3.new(4, 0.2, fp.Z - 2), CFrame.new(0, 0.6, 0), Color3.fromRGB(148, 142, 130), Enum.Material.Sand)
		-- Chapel at the back: stone body, slate roof, accent door + rooftop cross.
		local chapel = part(Vector3.new(12, fp.Y, 9), CFrame.new(0, fp.Y * 0.5 + 0.5, -wz + 5.5), spec.wall, Enum.Material.Concrete)
		chapel.Name = "Body"; chapel.CanCollide = true; chapel.CanQuery = true
		part(Vector3.new(13, 1, 10), CFrame.new(0, fp.Y + 1, -wz + 5.5), spec.roof, Enum.Material.Slate)
		part(Vector3.new(2.4, 4, 0.4), CFrame.new(0, 2.5, -wz + 10.2), spec.accent, Enum.Material.Wood)
		part(Vector3.new(0.6, 3, 0.6), CFrame.new(0, fp.Y + 2.8, -wz + 5.5), TRIM_LIGHT, Enum.Material.SmoothPlastic)
		part(Vector3.new(1.8, 0.6, 0.6), CFrame.new(0, fp.Y + 3.2, -wz + 5.5), TRIM_LIGHT, Enum.Material.SmoothPlastic)
		-- Headstone rows flanking the path.
		for _, sx in { -1, 1 } do
			for row = 0, 2 do
				for col = 0, 2 do
					local x = sx * (5.5 + col * 5.5)
					local z = wz - 6 - row * 7
					part(Vector3.new(1.6, 1.8, 0.5), CFrame.new(x, 1.4, z), STONE, Enum.Material.Concrete)
					part(Vector3.new(2, 0.4, 3), CFrame.new(x, 0.7, z - 1.6), Color3.fromRGB(120, 116, 108), Enum.Material.Concrete)
				end
			end
		end
		return model
	end

	-- Healthcare: four distinct buildings, one builder each.
	if kind == "Hospital" then
		part(Vector3.new(fp.X, 0.5, fp.Z), CFrame.new(0, 0.25, 0), ASPHALT, Enum.Material.Concrete)
		local build = HEALTHCARE_BUILDERS[key] or buildHospital
		build(model, spec, fp, part, column)
		return model
	end

	local bodyW = fp.X - 4
	local bodyD = fp.Z - 4
	local bodyH = fp.Y

	-- Foundation pad across the whole footprint.
	part(Vector3.new(fp.X, 0.5, fp.Z), CFrame.new(0, 0.25, 0), ASPHALT, Enum.Material.Concrete)

	local bodyCF = CFrame.new(0, 0, 0)

	local wallMat = if kind == "Fire" then Enum.Material.Brick else Enum.Material.Concrete
	local body = part(Vector3.new(bodyW, bodyH, bodyD), bodyCF * CFrame.new(0, bodyH * 0.5 + 0.5, 0), spec.wall, wallMat)
	body.Name = "Body"
	body.CanCollide = true
	body.CanQuery = true

	-- Roof slab + parapet lip.
	part(Vector3.new(bodyW + 0.8, 0.8, bodyD + 0.8), bodyCF * CFrame.new(0, bodyH + 0.9, 0), spec.roof, Enum.Material.Slate)
	part(Vector3.new(bodyW + 1.2, 0.6, bodyD + 1.2), bodyCF * CFrame.new(0, bodyH + 1.4, 0), TRIM_LIGHT, Enum.Material.SmoothPlastic)

	-- Window bands: one dark-glass strip per floor on every face (skipped for the
	-- fire station's front, which gets garage doors instead).
	local floorH = 5
	local floors = math.max(1, math.floor((bodyH - 1) / floorH))
	for f = 1, floors do
		local y = 0.5 + floorH * (f - 0.5) + 0.6
		local winH = floorH * 0.42
		if kind ~= "Fire" or f > 1 then
			part(Vector3.new(bodyW - 3, winH, 0.35), bodyCF * CFrame.new(0, y, bodyD * 0.5 + 0.1), GLASS_DARK, Enum.Material.Glass)
		end
		part(Vector3.new(bodyW - 3, winH, 0.35), bodyCF * CFrame.new(0, y, -(bodyD * 0.5 + 0.1)), GLASS_DARK, Enum.Material.Glass)
		part(Vector3.new(0.35, winH, bodyD - 3), bodyCF * CFrame.new(bodyW * 0.5 + 0.1, y, 0), GLASS_DARK, Enum.Material.Glass)
		part(Vector3.new(0.35, winH, bodyD - 3), bodyCF * CFrame.new(-(bodyW * 0.5 + 0.1), y, 0), GLASS_DARK, Enum.Material.Glass)
	end

	-- Glass entrance + canopy on the road-facing front (garage kinds skip it).
	if kind ~= "Fire" then
		local frontZ = bodyCF.Z + bodyD * 0.5
		part(Vector3.new(6, 7, 0.5), CFrame.new(bodyCF.X, 4, frontZ + 0.2), GLASS_DARK, Enum.Material.Glass)
		part(Vector3.new(0.6, 7, 0.5), CFrame.new(bodyCF.X, 4, frontZ + 0.25), TRIM_LIGHT, Enum.Material.Metal)
		part(Vector3.new(8, 0.5, 3), CFrame.new(bodyCF.X, 7.8, frontZ + 1.4), spec.accent, Enum.Material.SmoothPlastic)
	end

	if kind == "Police" then
		-- Blue beacon strip over the door + comms mast.
		part(Vector3.new(8, 1, 0.6), CFrame.new(0, 8.8, bodyD * 0.5 + 0.3), spec.accent, Enum.Material.Neon)
		column(0.6, 8, CFrame.new(-bodyW * 0.3, bodyH + 5, -bodyD * 0.25), METAL_GREY, Enum.Material.Metal)
		part(Vector3.new(1, 1, 1), CFrame.new(-bodyW * 0.3, bodyH + 9.2, -bodyD * 0.25), spec.accent, Enum.Material.Neon, Enum.PartType.Ball)
	elseif kind == "Fire" then
		-- Three garage bays with light roll-up doors + red/white trim + drill tower.
		local frontZ = bodyD * 0.5
		for i = -1, 1 do
			local x = i * (bodyW * 0.28)
			part(Vector3.new(bodyW * 0.22, 8.5, 0.5), CFrame.new(x, 4.8, frontZ + 0.15), TRIM_LIGHT, Enum.Material.Metal)
			for s = 1, 3 do
				part(Vector3.new(bodyW * 0.22, 0.25, 0.55), CFrame.new(x, 1.8 + s * 2, frontZ + 0.16), METAL_GREY, Enum.Material.Metal)
			end
		end
		part(Vector3.new(bodyW, 1.2, 0.5), CFrame.new(0, 9.8, frontZ + 0.2), spec.accent, Enum.Material.SmoothPlastic)
		local tower = part(Vector3.new(6, bodyH + 8, 6), CFrame.new(-bodyW * 0.5 + 3, (bodyH + 8) * 0.5 + 0.5, -bodyD * 0.5 + 3), spec.wall, Enum.Material.Brick)
		tower.Name = "Tower"
		part(Vector3.new(6.8, 0.8, 6.8), CFrame.new(-bodyW * 0.5 + 3, bodyH + 8.9, -bodyD * 0.5 + 3), spec.roof, Enum.Material.Slate)
	end

	return model
end

-- Clone the pre-made model for `key`. `ghost` makes it translucent + non-queryable
-- for the placement preview ghost.
function ServiceBuildingModel.build(key: string, ghost: boolean?): Model?
	local template = getTemplate(key)
	local model: Model? = if template then template:Clone() else buildPlaceholder(key)
	if not model then
		warn("[ServiceBuildingModel] no template or spec for key: " .. tostring(key))
		return nil
	end
	model.Name = key

	if ghost then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Transparency = math.max(d.Transparency, 0.55)
				d.CanCollide  = false
				d.CanQuery    = false
				d.CastShadow  = false
			end
		end
	end

	-- A template is stored at exactly the size it is built, so it is never rescaled. Only
	-- the code-drawn placeholder is authored full size and takes the city's building scale.
	if not template then
		model:ScaleTo(ZoneGrid.BUILDING_SCALE)
	end

	return model
end

-- Where people/vehicles enter: a few studs out from the front door at ground level.
function ServiceBuildingModel.entrance(key: string, cf: CFrame): Vector3
	local spec = ServiceTypes.get(key)
	local depth = if spec then ServiceTypes.footprintStuds(spec).Z else 20
	return (cf * CFrame.new(0, 0, depth * 0.5 + 5)).Position
end

return ServiceBuildingModel
