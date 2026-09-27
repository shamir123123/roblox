--!strict
-- Edit-time authoring tool (NOT runtime). Turns the 3D-Imported MidRiseKit FBXs
-- (Workspace.MR_W2..MR_W5, one Model per lot width, from Models/kits/MidRiseKit/)
-- into ServerStorage.Templates.Buildings.ResidentialMedium.<WxD>[.Level2|.Level3].<Design>:
-- the same design name at every level, so BuildingService swaps a block to its own
-- taller self on a level-up. Rerunnable per design; a re-import wipes nothing here.
-- The import is DESTROYED after a clean pass (re-import the FBX to run again).
-- Needs Plugin capability (SurfaceAppearance.ColorMap): run from the command bar / MCP:
--   require(game.ServerStorage.Authoring.MidRiseKitSetup).run()

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local ZoneGrid = require(game:GetService("ReplicatedStorage").City.ZoneGrid)

local MidRiseKitSetup = {}

-- Tiling, neutral-grey textures (textures/out/mid), tinted per placement by
-- LotDressingService.recolor through SurfaceAppearance.Color. Fixed / Plant keep the
-- TextureID the importer uploaded from the .fbm (never tinted); Rail moves its onto an
-- alpha SurfaceAppearance.
local WALL = table.freeze({
	brick = "rbxassetid://125667029398770",
	siding = "rbxassetid://81193713240526",
	stucco = "rbxassetid://102524407461927",
	panel = "rbxassetid://112581319537074",
})
local ROOF = table.freeze({
	membrane = "rbxassetid://131151331233755",
	gravel = "rbxassetid://83387404883082",
	tile = "rbxassetid://115439307678772",
	slate = "rbxassetid://134147666317846",
	metal = "rbxassetid://116855483186774",
})
local TRIM = "rbxassetid://114788415544005"
local PAINT_ROLE = table.freeze({ Walls = "Wall", Roof = "Roof", Trim = "Trim" })
local TOLERANCE = 0.05 -- template studs a part may sit off the manifest before we refuse it

type Box = { number } -- minX, minY, minZ, maxX, maxY, maxZ in Blender axes (y = street, z = up)
type Map = (x: number, y: number, z: number) -> Vector3

-- Blender -> template (X, Y up, Z = street). The importer turns the kit 180 about Y, which
-- is exactly `turned`, and leaves the street on +Z where BuildingService wants it.
-- `plain` is the un-turned import; a part from one is spun 180 to match.
local function turned(x: number, y: number, z: number): Vector3 return Vector3.new(-x, z, y) end
local function plain(x: number, y: number, z: number): Vector3 return Vector3.new(x, z, -y) end

local function centre(b: Box, map: Map): Vector3
	return map((b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2)
end

-- The mesh's own axes are the same under either map: X = x, Y = z, Z = y.
local function span(b: Box): Vector3
	return Vector3.new(b[4] - b[1], b[6] - b[3], b[5] - b[2])
end

-- How this building's parts came in: import scale, and which map lines their centres up.
local function detect(label: string, parts: { [string]: MeshPart }, boxes: { [string]: Box }): Map
	local s, n = 0, 0
	for role, p in parts do
		assert(p.Orientation.Magnitude < 0.01, p:GetFullName() .. " arrived rotated")
		s += p.Size.Magnitude / span(boxes[role]).Magnitude
		n += 1
	end
	s /= n
	local best: Map, bestErr = turned, math.huge
	for _, map in { turned, plain } :: { Map } do
		local o0: Vector3? = nil
		local err = 0
		for role, p in parts do
			local o = p.Position - centre(boxes[role], map) * s
			o0 = o0 or o
			err = math.max(err, (o - (o0 :: Vector3)).Magnitude / s)
		end
		if err < bestErr then best, bestErr = map, err end
	end
	for role, p in parts do
		local d = (p.Size / s - span(boxes[role])).Magnitude
		assert(d < TOLERANCE, ("%s size off the manifest by %.3f studs"):format(p:GetFullName(), d))
	end
	assert(bestErr < TOLERANCE, ("%s: parts do not line up with the manifest (%.3f studs)"):format(label, bestErr))
	return best
end

local function invisiblePart(name: string, size: Vector3, cf: CFrame, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function buildTemplate(name: string, design: any, lv: string, parts: { [string]: MeshPart }, map: Map): Model
	local boxes = design.levels[lv].parts
	local model = Instance.new("Model")
	model.Name = name
	local rot = if map == turned then CFrame.identity else CFrame.Angles(0, math.pi, 0)
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge

	for role, src in parts do
		local b: Box = boxes[role]
		local p = src:Clone()
		p.Name = role
		for _, c in p:GetChildren() do c:Destroy() end
		p.Size = span(b)
		p.CFrame = CFrame.new(centre(b, turned)) * rot
		p.Color = Color3.new(1, 1, 1) -- the import arrives grey, and Color multiplies
		p.Transparency = 0
		p.Anchored = true
		local map = if role == "Walls" then WALL[design.wall]
			elseif role == "Roof" then ROOF[design.roofTex]
			elseif role == "Trim" then TRIM
			else nil
		if map then
			local sa = Instance.new("SurfaceAppearance")
			sa.Name = "Skin"
			sa.ColorMap = map
			sa.Parent = p
			p:SetAttribute("PaintRole", PAINT_ROLE[role])
		elseif role == "Rail" then
			-- MeshPart.TextureID ignores the PNG's alpha, so the infill rendered as a solid
			-- dark sheet. The see-through look needs a SurfaceAppearance in Transparency mode,
			-- and DoubleSided so the quad reads from the street AND from the balcony.
			local sa = Instance.new("SurfaceAppearance")
			sa.Name = "Skin"
			sa.ColorMap = p.TextureID
			sa.AlphaMode = Enum.AlphaMode.Transparency
			sa.Parent = p
			p.TextureID = ""
			p.DoubleSided = true
		end
		p.Parent = model
		lo = lo:Min(p.Position - p.Size / 2)
		hi = hi:Max(p.Position + p.Size / 2)
	end

	local lotW, lotD = design.lotW, design.lotD
	if lo.X < -lotW / 2 - TOLERANCE or hi.X > lotW / 2 + TOLERANCE or lo.Z < -lotD / 2 - TOLERANCE or hi.Z > lotD / 2 + TOLERANCE then
		warn(("[MidRiseKitSetup] %s L%s overhangs its lot"):format(name, lv))
	end
	-- Lot-sized marker so the model's bounding box IS the lot (BuildingService centres on it).
	invisiblePart("FootprintAnchor", Vector3.new(lotW, 0.2, lotD), CFrame.new(0, 0.1, 0), model)
	-- One box over the whole block is what selection hits, so an upper floor clicks too.
	model.PrimaryPart = invisiblePart("Body", hi - lo, CFrame.new((lo + hi) / 2), model)

	-- The manifest is in 3 template studs per metre; the template is STORED at world size
	-- (BuildingService never rescales one), so bake the city's building scale in here.
	local s = ZoneGrid.BUILDING_SCALE
	model:ScaleTo(s)
	model:SetAttribute("StudsPerMetre", 2)

	local lvInfo = design.levels[lv]
	model:SetAttribute("Density", "Medium")
	model:SetAttribute("Level", tonumber(lv))
	model:SetAttribute("Storeys", lvInfo.storeys)
	model:SetAttribute("MaxHouseholds", lvInfo.households)
	model:SetAttribute("BuildingHalfWidth", (design.body[2] - design.body[1]) / 2 * s)
	model:SetAttribute("BuildingFrontZ", design.body[4] * s)
	model:SetAttribute("HasParking", design.parking)
	if design.doorX then model:SetAttribute("DoorX", -design.doorX * s) end
	if design.garageX then model:SetAttribute("GarageX", -design.garageX * s) end
	-- The garage door plane (template +Z) and opening: residents' cars drive up to it and are stowed.
	if design.garageY then model:SetAttribute("GarageZ", design.garageY * s) end
	if design.garageW then model:SetAttribute("GarageWidth", design.garageW * s) end
	model:SetAttribute("LotW", design.w)
	model:SetAttribute("LotD", design.d)
	return model
end

local function folderAt(parent: Instance, name: string): Instance
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f :: Instance
end

function MidRiseKitSetup.run(): string
	local manifest = HttpService:JSONDecode(require(script.Manifest) :: any)
	local root = folderAt(folderAt(folderAt(ServerStorage, "Templates"), "Buildings"), "ResidentialMedium")
	local report: { string } = {}

	for w = 2, 5 do
		local import = Workspace:FindFirstChild("MR_W" .. w)
		if not import then
			table.insert(report, ("MR_W%d: not imported"):format(w))
			continue
		end
		-- design -> level -> role -> part
		local found: { [string]: { [string]: { [string]: MeshPart } } } = {}
		for _, p in import:GetDescendants() do
			local design, lv, role = p.Name:match("^(MR_%d+x%d+_%a+)_L(%d)_(%w+)$")
			if design and p:IsA("MeshPart") then
				found[design] = found[design] or {}
				found[design][lv] = found[design][lv] or {}
				found[design][lv][role] = p
			end
		end

		local clean = true
		for name, design in manifest do
			if design.w ~= w then continue end
			local sizeFolder = folderAt(root, ("%dx%d"):format(design.w, design.d))
			for lv, info in design.levels do
				local parts = found[name] and found[name][lv]
				local missing = {}
				for role in info.parts do
					if not (parts and parts[role]) then table.insert(missing, role) end
				end
				if #missing > 0 then
					clean = false
					table.insert(report, ("%s L%s missing %s"):format(name, lv, table.concat(missing, ",")))
					continue
				end
				local map = detect(name .. " L" .. lv, parts :: any, info.parts)
				local dest = if lv == "1" then sizeFolder else folderAt(sizeFolder, "Level" .. lv)
				local old = dest:FindFirstChild(name)
				if old then old:Destroy() end
				buildTemplate(name, design, lv, parts :: any, map).Parent = dest
			end
		end
		if clean then
			import:Destroy()
			table.insert(report, ("MR_W%d: done, import removed"):format(w))
		end
	end
	return table.concat(report, "\n")
end

return MidRiseKitSetup
