--!strict
-- TransitBuildingModel
-- Procedural builders for the transit placeables: the Bus Depot (a layover yard whose
-- apron carries PARK_COUNT marked bays where the always-present fleet sits) and the Bus
-- Stop shelter. Server-only -- TransitService is the sole caller; the client placement
-- ghost draws its own crude placeholder, so this never needs to replicate. Mirrors
-- SchoolModel: pure builder, no lifecycle, no state, +Z faces the road.
--
-- The depot bakes Park1..PARK_COUNT Attachments onto its Root. BusDispatchService reads
-- their WorldCFrame to sit each parked bus on the apron, nose toward the road, so a
-- dispatched bus pulls straight out.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local BuildingTextures = require(ReplicatedStorage.City.BuildingTextures)
local TransitTypes = require(ReplicatedStorage.Transit.TransitTypes)

local TransitBuildingModel = {}

-- Buses are ~48 long x ~10 wide; the depot parks PARK_COUNT of them in PARK_ROWS rows
-- of PARK_COLS, both rows facing the road across a central drive aisle.
local PARK_ROWS = 2
local PARK_COLS = 10
TransitBuildingModel.PARK_COUNT = PARK_ROWS * PARK_COLS
local BUS_LEN = 48
local APRON_TOP = 0.55 -- local Y a parked bus root sits at (apron slab top + a hair)

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material

-- Realistic, muted palette (no neon): asphalt yard, concrete buildings, metal doors.
local C_ASPHALT = Color3.fromRGB(46, 48, 52)
local C_DOOR    = Color3.fromRGB(96, 99, 105)
local C_GLASS   = Color3.fromRGB(150, 178, 196)
local C_DARK    = Color3.fromRGB(70, 73, 80)
local C_CONCRETE = Color3.fromRGB(150, 150, 154)
local C_WHITE   = Color3.fromRGB(228, 228, 222)

-- One lean part. `role` (Wall/Roof/Accent) lets TransitService recolour to the spec;
-- only the building mass casts a shadow so a placed depot keeps a silhouette without
-- multiplying shadow casters for trim/glass/markings.
local function newPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, role: string?): Part
	local p = Instance.new("Part")
	p.Name = name; p.Size = size; p.CFrame = cf
	p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false
	p.Color = color; p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
	p.CastShadow = (role == "Wall" or role == "Roof")
	if role then p:SetAttribute("PaintRole", role) end
	p.Parent = parent
	return p
end

local function signText(parent: Instance, text: string)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Front
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 40
	sg.LightInfluence = 0.6
	sg.MaxDistance = 400
	sg.Parent = parent
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(0.92, 0.78)
	lbl.Position = UDim2.fromScale(0.04, 0.11)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.Text = text
	lbl.TextColor3 = C_WHITE
	lbl.TextScaled = true
	lbl.Parent = sg
end

-- ============================================================================
-- Bus Depot -- a large realistic layover yard. A maintenance garage (one corrugated
-- bay door per service lane) and a taller two-storey admin office run along the back;
-- the asphalt yard parks PARK_COUNT buses in PARK_ROWS rows facing the road across a
-- central drive aisle. Root is the base-centre pivot (TransitService seats it at road
-- level). PARK_COUNT Attachments mark where the parked fleet sits.
-- ============================================================================
function TransitBuildingModel.buildDepot(spec: TransitTypes.DepotSpec, footprint: Vector3): Model
	local fx, fz = footprint.X, footprint.Z
	local hx, hz = fx * 0.5, fz * 0.5
	local h = spec.height

	local model = Instance.new("Model")
	model.Name = "BusDepot"

	local root = newPart(model, "Root", V(2, 1, 2), CF(0, 0, 0), C_DARK, M.SmoothPlastic)
	root.Transparency = 1
	model.PrimaryPart = root

	-- Paved yard.
	newPart(model, "Apron", V(fx - 2, 0.5, fz - 2), CF(0, 0.25, 0), C_ASPHALT, M.Asphalt)

	-- Back building: a wide maintenance garage on the left, a taller two-storey admin
	-- office on the right -- realistic depot massing spanning the back edge.
	local bldgD = 18
	local bldgZ = -hz + bldgD * 0.5
	local bldgFront = bldgZ + bldgD * 0.5
	local officeW = 34
	local garageW = (fx - 2) - officeW
	local garageCx = -hx + 1 + garageW * 0.5
	local officeCx = hx - 1 - officeW * 0.5

	newPart(model, "GarageBody", V(garageW, h - 1, bldgD), CF(garageCx, (h - 1) * 0.5, bldgZ), spec.wall, M.Concrete, "Wall")
	newPart(model, "GarageRoof", V(garageW + 1, 0.8, bldgD + 1), CF(garageCx, h - 0.6, bldgZ), spec.roof, M.Concrete, "Roof")
	local doorCount = 6
	local doorStep = garageW / doorCount
	for i = 1, doorCount do
		local x = garageCx - garageW * 0.5 + doorStep * (i - 0.5)
		newPart(model, "BayDoor" .. i, V(doorStep - 2, h - 6, 0.4), CF(x, (h - 6) * 0.5, bldgFront + 0.2), C_DOOR, M.DiamondPlate)
	end

	local officeH = h + 4
	newPart(model, "Office", V(officeW, officeH, bldgD), CF(officeCx, officeH * 0.5, bldgZ), spec.wall, M.Concrete, "Wall")
	newPart(model, "OfficeRoof", V(officeW + 1, 0.8, bldgD + 1), CF(officeCx, officeH + 0.4, bldgZ), spec.roof, M.Concrete, "Roof")
	for f = 1, 2 do
		local win = newPart(model, "OfficeWin" .. f, V(officeW - 6, 3.4, 0.3), CF(officeCx, f * officeH / 3, bldgFront + 0.18), spec.wall, M.SmoothPlastic)
		local dec = Instance.new("Decal")
		dec.Texture = BuildingTextures.WINDOW_SINGLE
		dec.Face = Enum.NormalId.Front
		dec.Parent = win
	end
	local board = newPart(model, "SignBoard", V(officeW - 4, 2.4, 0.4), CF(officeCx, officeH - 2.2, bldgFront + 0.3), spec.accent, M.SmoothPlastic, "Accent")
	signText(board, "CITY TRANSIT")

	-- Ground-floor office entrance: glass doors under a small accent canopy.
	local officeDoor = newPart(model, "OfficeDoor", V(6, 7, 0.4), CF(officeCx, 3.5, bldgFront + 0.2), C_GLASS, M.Glass)
	officeDoor.Transparency = 0.35
	newPart(model, "OfficeCanopy", V(8, 0.5, 3), CF(officeCx, 7.4, bldgFront + 1.5), spec.accent, M.SmoothPlastic, "Accent")

	-- Clerestory glass band + accent fascia above the garage doors so the long garage
	-- face reads as a building instead of a blank wall.
	local clerestory = newPart(model, "GarageClerestory", V(garageW - 2, 2.2, 0.3), CF(garageCx, h - 3.4, bldgFront + 0.15), C_GLASS, M.Glass)
	clerestory.Transparency = 0.3
	newPart(model, "GarageFascia", V(garageW, 1.0, 0.4), CF(garageCx, h - 1.4, bldgFront + 0.25), spec.accent, M.SmoothPlastic, "Accent")

	-- Rooftop plant on the garage (AC/vent blocks).
	for i = 1, 3 do
		local ux = garageCx - garageW * 0.5 + garageW * (i - 0.5) / 3
		newPart(model, "RoofUnit" .. i, V(6, 2.2, 5), CF(ux, h + 0.7, bldgZ - 2), C_DOOR, M.DiamondPlate)
	end

	-- Perimeter kerb walls along the two side edges (front stays open to the road).
	local wallH = 3
	newPart(model, "YardWallL", V(0.8, wallH, fz - 2), CF(-hx + 1.4, wallH * 0.5, 0), C_CONCRETE, M.Concrete)
	newPart(model, "YardWallR", V(0.8, wallH, fz - 2), CF(hx - 1.4, wallH * 0.5, 0), C_CONCRETE, M.Concrete)

	-- Yard light poles, hugging the walls clear of the bays (lit heads read at night).
	local poleN = 0
	for _, lx in { -hx + 2.2, hx - 2.2 } do
		for _, lz in { 1, hz - 6 } do
			poleN += 1
			newPart(model, "YardLightPole" .. poleN, V(0.6, 14, 0.6), CF(lx, 7, lz), C_DARK, M.Metal)
			newPart(model, "YardLightHead" .. poleN, V(2.4, 0.4, 1.2), CF(lx, 14.2, lz), Color3.fromRGB(255, 238, 200), M.Neon)
		end
	end

	-- Entrance driveway: a darker strip with painted edge lines where buses roll out.
	newPart(model, "Driveway", V(20, 0.52, 16), CF(0, 0.26, hz - 9), Color3.fromRGB(58, 60, 64), M.Asphalt)
	for _, sx in { -1, 1 } do
		newPart(model, "DriveLine" .. (if sx < 0 then "L" else "R"), V(0.5, 0.06, 16), CF(sx * 10, 0.55, hz - 9), Color3.fromRGB(214, 178, 90), M.SmoothPlastic)
	end

	-- Two rows of bays facing the road (+Z) across a central drive aisle; a bus pathfinds
	-- onto the road from wherever it is parked, so the rows can pack tight.
	local aisle = 14
	local rowZ = {
		bldgFront + BUS_LEN * 0.5,             -- back row, flush to the building
		bldgFront + BUS_LEN * 1.5 + aisle,    -- front row, across the aisle
	}
	local colStep = fx / PARK_COLS
	local i = 0
	for r = 1, PARK_ROWS do
		for c = 1, PARK_COLS do
			i += 1
			local att = Instance.new("Attachment")
			att.Name = "Park" .. i
			att.CFrame = CF(-hx + colStep * (c - 0.5), APRON_TOP, rowZ[r])
			att.Parent = root
		end
		-- One tiled stall-stripe plate per row (cheap vs a part per painted line).
		local stripes = newPart(model, "BayStripes" .. r, V(fx - 4, 0.06, BUS_LEN), CF(0, 0.54, rowZ[r]), C_WHITE, M.SmoothPlastic)
		stripes.Transparency = 1
		local tex = Instance.new("Texture")
		tex.Name = "StallStripeTexture"
		tex.Texture = RoadConstants.PARKING_STALL_TEXTURE
		tex.Face = Enum.NormalId.Top
		tex.Color3 = C_WHITE
		tex.StudsPerTileU = colStep
		tex.StudsPerTileV = BUS_LEN
		tex.Parent = stripes
	end

	-- Half-size world: scale the depot (incl. the baked Park attachments) so the half-size
	-- buses dock correctly. Root is base-centre, so it stays seated on the ground.
	if RoadConstants.WORLD_SCALE ~= 1 then
		model:ScaleTo(RoadConstants.WORLD_SCALE)
	end

	return model
end

-- ============================================================================
-- Bus Stop -- kerbside pole + cantilever shelter. Pole is the PrimaryPart, centred at
-- the model origin (TransitService lifts the pivot by half the pole height so the base
-- sits on the ground). The sign + open side are on +Z so the existing placement flip
-- faces them at the road; the back glass is on -Z.
-- ============================================================================
function TransitBuildingModel.buildStop(spec: TransitTypes.StopSpec): Model
	local model = Instance.new("Model")
	model.Name = "BusStop"

	local groundY = -spec.poleHeight * 0.5
	local sh = spec.shelterSize
	local shX, shY, shZ = sh.X, sh.Y, sh.Z

	local pole = newPart(model, "Pole", V(0.5, spec.poleHeight, 0.5), CF(0, 0, 0), C_DARK, M.Metal)
	model.PrimaryPart = pole
	newPart(model, "PoleFoot", V(1.2, 0.5, 1.2), CF(0, groundY + 0.25, 0), C_DARK, M.Metal)

	-- Sidewalk pad under the shelter (+Z open side toward the road).
	newPart(model, "Pad", V(shX + 1, 0.4, shZ + 2), CF(0, groundY + 0.2, -shZ * 0.5 - 0.5), C_CONCRETE, M.Concrete)

	-- Sign blade near the pole top, facing the road (+Z), with a "BUS" face.
	local blade = newPart(model, "SignBlade", V(2.8, 1.6, 0.25), CF(0, spec.poleHeight * 0.5 - 1.2, 0.25), spec.accent, M.SmoothPlastic, "Accent")
	local bladeGui = Instance.new("SurfaceGui")
	bladeGui.Face = Enum.NormalId.Back -- +Z, the road side
	bladeGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	bladeGui.PixelsPerStud = 50
	bladeGui.LightInfluence = 0.4
	bladeGui.MaxDistance = 220
	bladeGui.Parent = blade
	local bladeLbl = Instance.new("TextLabel")
	bladeLbl.Size = UDim2.fromScale(1, 1)
	bladeLbl.BackgroundTransparency = 1
	bladeLbl.Font = Enum.Font.GothamBold
	bladeLbl.Text = "BUS"
	bladeLbl.TextColor3 = C_WHITE
	bladeLbl.TextScaled = true
	bladeLbl.Parent = bladeGui

	-- Cantilever shelter behind the pole (-Z): roof, accent lip, back + side glass, bench.
	local backZ = -shZ - 0.4
	local midZ = -shZ * 0.5 - 0.4
	newPart(model, "Roof", V(shX, 0.3, shZ), CF(0, groundY + shY, midZ), C_DARK, M.SmoothPlastic)
	newPart(model, "RoofLip", V(shX + 0.4, 0.3, shZ + 0.4), CF(0, groundY + shY - 0.25, midZ), spec.accent, M.SmoothPlastic, "Accent")
	for _, sx in { -1, 1 } do
		newPart(model, "Post", V(0.3, shY, 0.3), CF(sx * (shX * 0.5 - 0.2), groundY + shY * 0.5, backZ + 0.2), C_DARK, M.Metal)
		local sg = newPart(model, "SideGlass", V(0.18, shY - 1.2, shZ - 0.4), CF(sx * (shX * 0.5 - 0.2), groundY + shY * 0.5 - 0.3, midZ), C_GLASS, M.Glass)
		sg.Transparency = 0.4
	end
	local bg = newPart(model, "BackGlass", V(shX - 0.6, shY - 1.2, 0.18), CF(0, groundY + shY * 0.5 - 0.3, backZ), C_GLASS, M.Glass)
	bg.Transparency = 0.4
	newPart(model, "Bench", V(shX - 1.4, 0.3, 1.1), CF(0, groundY + 1.5, midZ - 0.2), Color3.fromRGB(120, 124, 130), M.Metal)
	newPart(model, "BenchBack", V(shX - 1.4, 1.0, 0.2), CF(0, groundY + 2.1, backZ + 0.3), Color3.fromRGB(120, 124, 130), M.Metal)
	for _, sx in { -1, 1 } do
		newPart(model, "BenchLeg" .. (if sx < 0 then "L" else "R"), V(0.3, 1.4, 0.9), CF(sx * (shX * 0.5 - 1.6), groundY + 0.7, midZ - 0.2), C_DARK, M.Metal)
	end

	-- Soft lit strip under the roof so the shelter reads at dusk.
	local roofLight = newPart(model, "RoofLight", V(shX - 1.5, 0.15, 0.8), CF(0, groundY + shY - 0.5, midZ), Color3.fromRGB(255, 240, 205), M.Neon)
	roofLight.Transparency = 0.15

	-- Route-map / ad panel on the outside of the back glass, accent-framed.
	newPart(model, "AdFrame", V(2.8, 3.6, 0.2), CF(shX * 0.25, groundY + shY * 0.5 - 0.3, backZ - 0.16), spec.accent, M.SmoothPlastic, "Accent")
	newPart(model, "AdPanel", V(2.3, 3.1, 0.24), CF(shX * 0.25, groundY + shY * 0.5 - 0.3, backZ - 0.18), C_WHITE, M.SmoothPlastic)

	-- Litter bin on the pad beside the shelter.
	newPart(model, "Bin", V(1.1, 1.6, 1.1), CF(shX * 0.5 - 0.2, groundY + 0.8, 0.4), C_DARK, M.Metal)
	newPart(model, "BinLid", V(1.2, 0.2, 1.2), CF(shX * 0.5 - 0.2, groundY + 1.7, 0.4), spec.accent, M.SmoothPlastic, "Accent")

	-- Click hitbox spanning the whole shelter (selection raycasts).
	local hit = newPart(model, "Hitbox", V(shX + 0.5, shY + 1, shZ + 1.2), CF(0, groundY + (shY + 1) * 0.5, midZ), C_DARK, M.SmoothPlastic)
	hit.Transparency = 1
	hit.CanQuery = true

	-- Half-size world: scale the shelter. The pole PrimaryPart stays centred, so TransitService's
	-- seat lift (poleHeight * 0.5 * WORLD_SCALE) drops the base onto the sidewalk.
	if RoadConstants.WORLD_SCALE ~= 1 then
		model:ScaleTo(RoadConstants.WORLD_SCALE)
	end

	return model
end

-- ============================================================================
-- Train Station -- a raised side platform with a canopy. Same pivot conventions as
-- the Bus Stop: Pole is the PrimaryPart centred at the origin, +Z faces the track
-- (TransitService's existing placement flip + seat lift work unchanged). The
-- platform slab runs along X (spec.shelterSize.X) with its long edge at the track.
-- ============================================================================
function TransitBuildingModel.buildStation(spec: TransitTypes.StopSpec): Model
	local model = Instance.new("Model")
	model.Name = "TrainStation"

	local groundY = -spec.poleHeight * 0.5
	local sh = spec.shelterSize
	local shX, shY, shZ = sh.X, sh.Y, sh.Z
	local PLAT_H = 2.4 -- platform slab height above ground

	local pole = newPart(model, "Pole", V(0.6, spec.poleHeight, 0.6), CF(0, 0, 0), C_DARK, M.Metal)
	model.PrimaryPart = pole

	-- Station sign near the pole top, facing the track (+Z).
	local blade = newPart(model, "SignBlade", V(6, 1.8, 0.25), CF(0, spec.poleHeight * 0.5 - 1.4, 0.3), spec.accent, M.SmoothPlastic, "Accent")
	signText(blade, "RAIL")
	blade:FindFirstChildOfClass("SurfaceGui").Face = Enum.NormalId.Back

	-- Raised platform slab: long edge (+Z side) at the track, top level for boarding.
	local platMidZ = -shZ * 0.5 - 0.4
	newPart(model, "Platform", V(shX, PLAT_H, shZ + 1.5), CF(0, groundY + PLAT_H * 0.5, platMidZ), C_CONCRETE, M.Concrete)
	-- Tactile / warning strip along the platform edge.
	newPart(model, "EdgeStrip", V(shX, 0.12, 1.0), CF(0, groundY + PLAT_H + 0.06, platMidZ + shZ * 0.5 + 0.2), Color3.fromRGB(214, 178, 90), M.SmoothPlastic)

	-- Canopy over the back half of the platform, on paired posts.
	local canopyZ = platMidZ - shZ * 0.22
	local postN = math.max(2, math.floor(shX / 24))
	for i = 1, postN do
		local x = -shX * 0.5 + shX * (i - 0.5) / postN
		newPart(model, "CanopyPost" .. i, V(0.5, shY - PLAT_H, 0.5), CF(x, groundY + PLAT_H + (shY - PLAT_H) * 0.5, canopyZ), C_DARK, M.Metal)
	end
	newPart(model, "CanopyRoof", V(shX - 2, 0.35, shZ * 0.6), CF(0, groundY + shY, canopyZ), C_DARK, M.SmoothPlastic)
	newPart(model, "CanopyLip", V(shX - 1.6, 0.3, shZ * 0.6 + 0.4), CF(0, groundY + shY - 0.28, canopyZ), spec.accent, M.SmoothPlastic, "Accent")
	local strip = newPart(model, "CanopyLight", V(shX - 4, 0.15, 0.8), CF(0, groundY + shY - 0.5, canopyZ), Color3.fromRGB(255, 240, 205), M.Neon)
	strip.Transparency = 0.15

	-- Benches under the canopy.
	for _, sx in { -1, 1 } do
		newPart(model, "Bench" .. (if sx < 0 then "L" else "R"), V(shX * 0.22, 0.3, 1.2), CF(sx * shX * 0.22, groundY + PLAT_H + 1.4, canopyZ - 1), Color3.fromRGB(120, 124, 130), M.Metal)
	end

	-- Click hitbox spanning the platform (selection raycasts).
	local hit = newPart(model, "Hitbox", V(shX + 0.5, shY + 1, shZ + 2), CF(0, groundY + (shY + 1) * 0.5, platMidZ), C_DARK, M.SmoothPlastic)
	hit.Transparency = 1
	hit.CanQuery = true

	if RoadConstants.WORLD_SCALE ~= 1 then
		model:ScaleTo(RoadConstants.WORLD_SCALE)
	end

	return model
end

return TransitBuildingModel
