--!strict
-- Edit-time authoring tool (NOT runtime). Generates ONE simple variant per size for
-- Commercial / Office / Industrial into Templates.Buildings.<Zone>.<WxD>. Plain textured
-- boxes (wall texture + glass window bands + flat roof/parapet + sign + entrance), carrying
-- the dressing contract (BuildingHalfWidth/FrontFaceZ/ParkingStyle), PrimaryPart=Body,
-- PaintRole tags, front authored on +Z. BuildingService clones these; LotDressingService
-- adds the parking lot / recolour per placement -- same path the residential houses use.
--
-- Run: require(game.ServerStorage.Authoring.SimpleBuildingBuilder).build()

local ServerStorage    = game:GetService("ServerStorage")
local BuildingTextures = require(game:GetService("ReplicatedStorage").City.BuildingTextures)
local ZoneGrid         = require(game:GetService("ReplicatedStorage").City.ZoneGrid)

local SimpleBuildingBuilder = {}

local LOT   = 16
local SIDE  = 3.0   -- gap between the building wall and the lot edge
local FLOOR = 0.7
local V, CF, ANG, M = Vector3.new, CFrame.new, CFrame.Angles, Enum.Material
local GLASS = BuildingTextures.WINDOW_SINGLE

type Style = {
	wall: { id: string, tile: number },
	wallColor: Color3, floors: number, floorH: number,
	signColor: Color3, glassColor: Color3, roofColor: Color3,
	industrial: boolean,
}

local STYLES: { [string]: Style } = {
	Commercial = {
		wall = BuildingTextures.WALL[3], wallColor = Color3.fromRGB(228, 224, 214),
		floors = 2, floorH = 4.6, signColor = Color3.fromRGB(208, 96, 72),
		glassColor = Color3.fromRGB(152, 188, 208), roofColor = Color3.fromRGB(120, 120, 126),
		industrial = false,
	},
	Office = {
		wall = BuildingTextures.WALL[6], wallColor = Color3.fromRGB(150, 168, 190),
		floors = 4, floorH = 4.2, signColor = Color3.fromRGB(86, 128, 170),
		glassColor = Color3.fromRGB(132, 168, 198), roofColor = Color3.fromRGB(96, 104, 116),
		industrial = false,
	},
	Industrial = {
		wall = BuildingTextures.WALL[7], wallColor = Color3.fromRGB(178, 172, 158),
		floors = 1, floorH = 9.5, signColor = Color3.fromRGB(196, 168, 96),
		glassColor = Color3.fromRGB(150, 160, 168), roofColor = Color3.fromRGB(112, 110, 106),
		industrial = true,
	},
}

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, role: string?): Part
	local p = Instance.new("Part")
	p.Name, p.Size, p.CFrame = name, size, cf
	p.Anchored = true
	p.Color, p.Material = color, material
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	if role then p:SetAttribute("PaintRole", role) end
	p.Parent = parent
	return p
end

local function texWalls(p: Part, tex: string, tile: number, color: Color3)
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right } do
		local t = Instance.new("Texture")
		t.Texture, t.Face = tex, face
		t.StudsPerTileU, t.StudsPerTileV = tile, tile
		t.Color3 = color
		t.Parent = p
	end
end

-- A thin glass band hugging one wall face, carrying the curtain-wall decal on its outward face.
local function band(parent: Instance, side: string, bodyW: number, bodyD: number, y: number, h: number, color: Color3)
	local p: Part, faceN: Enum.NormalId
	if side == "F" then
		p = part(parent, "Window", V(bodyW * 0.9, h, 0.3), CF(0, y, bodyD * 0.5 + 0.16), color, M.Glass)
		faceN = Enum.NormalId.Front
	elseif side == "B" then
		p = part(parent, "Window", V(bodyW * 0.9, h, 0.3), CF(0, y, -bodyD * 0.5 - 0.16), color, M.Glass)
		faceN = Enum.NormalId.Back
	elseif side == "L" then
		p = part(parent, "Window", V(0.3, h, bodyD * 0.9), CF(-bodyW * 0.5 - 0.16, y, 0), color, M.Glass)
		faceN = Enum.NormalId.Left
	else
		p = part(parent, "Window", V(0.3, h, bodyD * 0.9), CF(bodyW * 0.5 + 0.16, y, 0), color, M.Glass)
		faceN = Enum.NormalId.Right
	end
	local d = Instance.new("Decal")
	d.Texture, d.Face, d.Color3 = GLASS, faceN, color
	d.Parent = p
end

local function buildVariant(zone: string, w: number, d: number): Model
	local s = STYLES[zone]
	local bodyW = w * LOT - SIDE * 2
	local bodyD = d * LOT - SIDE * 2
	local height = s.floors * s.floorH
	local frontZ = bodyD * 0.5

	local model = Instance.new("Model")

	-- Full-lot invisible anchor: makes the model bbox == the lot so BuildingService centres
	-- the LOT (not the body) on the road, like the residential templates.
	local anchor = part(model, "FootprintAnchor", V(w * LOT, 0.2, d * LOT), CF(0, 0.1, 0), s.wallColor, Enum.Material.SmoothPlastic)
	anchor.Transparency = 1
	anchor.CastShadow = false

	part(model, "Foundation", V(bodyW + 1.2, FLOOR * 2, bodyD + 1.2), CF(0, FLOOR, 0), Color3.fromRGB(122, 120, 116), Enum.Material.Concrete, "Foundation")

	local body = part(model, "Body", V(bodyW, height, bodyD), CF(0, FLOOR + height * 0.5, 0), s.wallColor, Enum.Material.Brick, "Wall")
	texWalls(body, s.wall.id, s.wall.tile, s.wallColor)

	if s.industrial then
		-- Warehouse: a roller door + a clerestory window band high up, no glass curtain.
		part(model, "RollerDoor", V(bodyW * 0.34, height * 0.6, 0.4), CF(-bodyW * 0.22, FLOOR + height * 0.3, frontZ + 0.18), Color3.fromRGB(90, 92, 98), Enum.Material.DiamondPlate)
		part(model, "ManDoor", V(2.4, 4.2, 0.4), CF(bodyW * 0.3, FLOOR + 2.1, frontZ + 0.18), Color3.fromRGB(70, 72, 78), M.Metal, "Door")
		band(model, "F", bodyW, bodyD, FLOOR + height * 0.82, 1.6, s.glassColor)
		band(model, "L", bodyW, bodyD, FLOOR + height * 0.82, 1.6, s.glassColor)
		band(model, "R", bodyW, bodyD, FLOOR + height * 0.82, 1.6, s.glassColor)
	else
		-- Shop / office: a glass band per floor on all four faces.
		for i = 1, s.floors do
			local y = FLOOR + (i - 0.5) * s.floorH
			for _, side in { "F", "B", "L", "R" } do
				band(model, side, bodyW, bodyD, y, s.floorH * 0.55, s.glassColor)
			end
		end
		-- Ground-floor entrance.
		part(model, "Entrance", V(3.2, 4.6, 0.4), CF(0, FLOOR + 2.3, frontZ + 0.18), Color3.fromRGB(74, 70, 66), M.Glass, "Door")
	end

	-- Flat roof + a thin parapet rim.
	local roofY = FLOOR + height
	part(model, "Roof", V(bodyW + 0.6, 0.5, bodyD + 0.6), CF(0, roofY + 0.25, 0), s.roofColor, Enum.Material.Concrete, "Roof")
	local sideX = bodyW * 0.5 + 0.4
	for _, e in {
		{ V(bodyW + 0.8, 1.0, 0.5), CF(0, roofY + 0.5, frontZ + 0.4) },
		{ V(bodyW + 0.8, 1.0, 0.5), CF(0, roofY + 0.5, -frontZ - 0.4) },
		{ V(0.5, 1.0, bodyD + 0.8), CF(sideX, roofY + 0.5, 0) },
		{ V(0.5, 1.0, bodyD + 0.8), CF(-sideX, roofY + 0.5, 0) },
	} do
		part(model, "Parapet", e[1], e[2], s.roofColor, Enum.Material.Concrete)
	end

	-- Sign band across the front, just under the roof.
	part(model, "Sign", V(bodyW * 0.7, 1.6, 0.5), CF(0, roofY - 1.1, frontZ + 0.2), s.signColor, Enum.Material.SmoothPlastic)

	body.Name = "Body"
	model.PrimaryPart = body
	model.Name = zone .. "_" .. w .. "x" .. d .. "_v01"
	-- Drawn at 3 studs per metre (LOT = 16) but STORED at world size: BuildingService never
	-- rescales a template, so what is saved here is what gets built.
	local s = ZoneGrid.BUILDING_SCALE
	model:ScaleTo(s)
	model:SetAttribute("BuildingHalfWidth", bodyW * 0.5 * s)
	model:SetAttribute("FrontFaceZ", frontZ * s)
	model:SetAttribute("ParkingStyle", "small")
	model:SetAttribute("StudsPerMetre", 2)
	return model
end

local function ensureFolder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then return f end
	if f then f:Destroy() end
	f = Instance.new("Folder"); f.Name = name; f.Parent = parent
	return f
end

function SimpleBuildingBuilder.build(): string
	local root = ensureFolder(ServerStorage:WaitForChild("Templates"), "Buildings")
	local built = 0
	for _, zone in { "Commercial", "Office", "Industrial" } do
		local zoneFolder = ensureFolder(root, zone)
		for w = 2, 5 do
			for d = 2, 5 do
				local sizeFolder = ensureFolder(zoneFolder, w .. "x" .. d)
				for _, c in sizeFolder:GetChildren() do
					if c:IsA("Model") then c:Destroy() end
				end
				local m = buildVariant(zone, w, d)
				m.Parent = sizeFolder
				built += 1
			end
		end
	end
	return "SimpleBuildingBuilder: built " .. built .. " C/O/I building templates"
end

return SimpleBuildingBuilder
