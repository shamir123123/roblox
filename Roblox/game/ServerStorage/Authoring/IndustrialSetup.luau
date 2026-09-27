--!strict
-- Edit-time authoring tool (NOT runtime). Turns the 3D-Imported industrial kit
-- (Workspace.IN_W2..IN_W5, one Model per lot width, from Models/kits/IndustrialKit/, made by
-- blender/ind.py) into ServerStorage.Templates.Buildings.Industrial.<WxD>[.Level2|.Level3].<Design>:
-- the same design name at every level, so BuildingService swaps a works to its own upgraded self.
-- The old Part-built templates move (not deleted) to ServerStorage.IndustrialPartBuilt, and the
-- import is DESTROYED after a clean pass. indbuild_manifest.json (~1.9 MB) is passed in:
--   local json = game:GetService("HttpService"):GetAsync("http://127.0.0.1:<port>/indbuild_manifest.json")
--   require(game.ServerStorage.Authoring.IndustrialSetup).run(json [, w])
-- Needs Plugin capability (SurfaceAppearance maps can't be written from a game thread).
--
-- Parts (see BUILDING_PIPELINE.md): Walls/Base/Trim/Roof carry the player's colour on their
-- SurfaceAppearance (PaintRole); Detail_* parts are decoration the LOD system drops (attribute
-- LODDetail); LOD_* parts are the <500-tri LOD2 model, shipped invisible (attribute LOD2) until
-- a building LOD system shows them. Kit props ride as JSON attributes (KitProps, KitRoof,
-- KitSite, KitFence) for LotDressingService.

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local IndustrialSetup = {}

-- Colour maps of the tinted looks. The importer uploaded their normal / roughness maps but not
-- the colour (the Blender tint node hid it): combuild_pbr ids from CommercialLowSetup, plus the
-- three industrial-only ones uploaded 2026-09-25.
local COLOR_MAP = table.freeze({
	wall_brick = "rbxassetid://72150076658108",
	wall_brickmix = "rbxassetid://139136940257264",
	wall_cmu = "rbxassetid://127278047298003",
	trim = "rbxassetid://79524206353874",
	trim_smooth = "rbxassetid://134028487242206",
	roof_membrane = "rbxassetid://109808355491341",
	wall_trap = "rbxassetid://81441889690104",
	wall_sandwich = "rbxassetid://124256290762402",
	roof_metal = "rbxassetid://139634779102270",
})

local PAINT_ROLE = table.freeze({
	Walls = "Wall", Base = "Base", Trim = "Trim", Roof = "Roof",
	LOD_Walls = "Wall", LOD_Base = "Base", LOD_Roof = "Roof",
})
local LOOK_KEY = table.freeze({ Walls = "wall", Base = "base", Trim = "trim", Roof = "roof" })
local TINT_KEY = table.freeze({
	Walls = "wallTint", Base = "baseTint", Trim = "trimTint", Roof = "roofTint",
	LOD_Walls = "wallTint", LOD_Base = "baseTint", LOD_Roof = "roofTint",
})
local AVG_KEY = table.freeze({ LOD_Walls = "wallAvg", LOD_Base = "baseAvg", LOD_Roof = "roofAvg" })
local ALPHA = table.freeze({ Detail_Grime = true, Detail_Marking = true, Detail_Grate = true })
-- Negated with the importer's turn: every other attr is a Z or a half-width and survives it.
local X_ATTRS = table.freeze({ EntranceX = true, LotEntryX = true, LotEntryX2 = true })
local TOLERANCE = 0.05 -- studs a part may sit off the manifest before we refuse it

type Box = { number } -- minX, minY, minZ, maxX, maxY, maxZ in Blender axes (y = street, z = up)
type Map = (x: number, y: number, z: number) -> Vector3

-- Blender -> template (X, Y up, Z = street). The importer turns the kit 180 about Y (`turned`),
-- which leaves the street on +Z where BuildingService wants it; `plain` is an un-turned import.
local function turned(x: number, y: number, z: number): Vector3 return Vector3.new(-x, z, y) end
local function plain(x: number, y: number, z: number): Vector3 return Vector3.new(x, z, -y) end

local function box(p: any): Box
	return { p.min[1], p.min[2], p.min[3], p.max[1], p.max[2], p.max[3] }
end

local function centre(b: Box, map: Map): Vector3
	return map((b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2)
end

-- The mesh's own axes are the same under either map: X = x, Y = z, Z = y.
local function span(b: Box): Vector3
	return Vector3.new(b[4] - b[1], b[6] - b[3], b[5] - b[2])
end

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

-- How this building's parts came in: import scale, and which map lines their centres up.
local function detect(label: string, parts: { [string]: MeshPart }, boxes: { [string]: Box }): Map
	local s, n = 0, 0
	for role, p in parts do
		assert(p.Orientation.Magnitude < 0.01, p:GetFullName() .. " arrived rotated")
		local sp = span(boxes[role]).Magnitude
		if sp > 1 then
			s += p.Size.Magnitude / sp
			n += 1
		end
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

-- Fence infill, grime, ground markings, grating: MeshPart.TextureID ignores the PNG alpha, so
-- the importer's texture moves onto a SurfaceAppearance in Transparency mode.
local function alphaSkin(p: MeshPart, doubleSided: boolean)
	local sa = Instance.new("SurfaceAppearance")
	sa.Name = "Skin"
	sa.ColorMap = p.TextureID
	sa.AlphaMode = Enum.AlphaMode.Transparency
	sa.Parent = p
	p.TextureID = ""
	p.DoubleSided = doubleSided
end

local function dressPart(p: MeshPart, role: string, look: any)
	local sa = p:FindFirstChildOfClass("SurfaceAppearance")
	local stem = LOOK_KEY[role] and look[LOOK_KEY[role]]
	if stem then
		assert(sa, p:GetFullName() .. " has no SurfaceAppearance from the importer")
		local map = COLOR_MAP[stem]
		assert(map, "no colour map for look " .. tostring(stem))
		sa.ColorMap = map
		sa.Color = rgb(look[TINT_KEY[role]])
	elseif role == "Detail_EquipPaint" and sa then
		sa.Color = rgb(look.paintTint)
	elseif role:match("^Detail_Fence%d$") then
		alphaSkin(p, true) -- both faces are modelled, and the far side must read through the near
	elseif ALPHA[role] then
		alphaSkin(p, false)
	end
	if AVG_KEY[role] then -- untextured LOD2 shell: the player's colour x the texture's average tone
		local t, a = look[TINT_KEY[role]], look[AVG_KEY[role]]
		p.Color = Color3.fromRGB(t[1] * a[1] / 255, t[2] * a[2] / 255, t[3] * a[3] / 255)
	else
		p.Color = Color3.new(1, 1, 1) -- the import arrives grey, and Color multiplies
	end
	if PAINT_ROLE[role] then p:SetAttribute("PaintRole", PAINT_ROLE[role]) end
	if role:sub(1, 7) == "Detail_" then p:SetAttribute("LODDetail", true) end
	if role:sub(1, 4) == "LOD_" then
		p:SetAttribute("LOD2", true)
		p.Transparency = 1 -- until a building LOD system swaps it in
	end
	p.CastShadow = not (role == "Ground" or role:sub(1, 4) == "LOD_" or ALPHA[role])
end

-- Kit-prop placements in template studs, yaw in degrees: { {prop, x, y, z, yaw, kit?}, ... }.
-- The prop FBXs get the same importer turn, so a Blender yaw carries over unchanged.
local function props(list: any): { any }
	local out = {}
	for _, e in list do
		local v = turned(e.pos[1], e.pos[2], e.pos[3])
		table.insert(out, { e.prop, v.X, v.Y, v.Z, e.rot % 360, e.kit })
	end
	return out
end

local function layouts(ls: any): string
	local out = {}
	for i, l in ls do out[i] = props(l) end
	return HttpService:JSONEncode(out)
end

local function buildTemplate(name: string, design: any, lv: string, parts: { [string]: MeshPart }, map: Map): Model
	local lvInfo = design.levels[lv]
	local model = Instance.new("Model")
	model.Name = name
	local rot = if map == turned then CFrame.identity else CFrame.Angles(0, math.pi, 0)
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge

	for role, src in parts do
		local b = box(lvInfo.parts[role])
		local p = src:Clone()
		p.Name = role
		for _, c in p:GetChildren() do
			if not c:IsA("SurfaceAppearance") then c:Destroy() end
		end
		p.Size = span(b)
		p.CFrame = CFrame.new(centre(b, turned)) * rot
		p.Transparency = 0
		p.Anchored = true
		dressPart(p, role, design.look)
		p.Parent = model
		if role == "Walls" or role == "Base" or role == "Roof" then
			lo = lo:Min(p.Position - p.Size / 2)
			hi = hi:Max(p.Position + p.Size / 2)
		end
	end

	local lotW, lotD = design.lotStuds[1], design.lotStuds[2]
	-- Lot-sized marker so the model's bounding box IS the lot (BuildingService centres on it),
	-- and the frame LotDressingService seats the kit props in.
	invisiblePart("FootprintAnchor", Vector3.new(lotW, 0.2, lotD), CFrame.new(0, 0.1, 0), model)
	-- One box over the building is what selection hits; the markers ride on it.
	local body = invisiblePart("Body", hi - lo, CFrame.new((lo + hi) / 2), model)
	model.PrimaryPart = body
	for markName, mk in lvInfo.marks do
		local att = Instance.new("Attachment")
		att.Name = markName
		local at = turned(mk.pos[1], mk.pos[2], mk.pos[3])
		local cf = if mk.face then CFrame.lookAt(at, turned(mk.face[1], mk.face[2], mk.face[3])) else CFrame.new(at)
		att.CFrame = body.CFrame:ToObjectSpace(cf)
		att.Parent = body
	end

	for k, v in lvInfo.attrs do
		model:SetAttribute(k, if X_ATTRS[k] then -v else v)
	end
	model:SetAttribute("ParkingStyle", "baked") -- the yard, fences and gates are in the model
	model:SetAttribute("FenceMode", "none")
	model:SetAttribute("KitYard", true)
	model:SetAttribute("LODTiers", true) -- AssetLODView: LOD1 drops Detail_ + small props, LOD2 shows LOD_ only
	model:SetAttribute("StudsPerMetre", 2)
	model:SetAttribute("Industry", design.family)
	model:SetAttribute("Company", design.company)
	model:SetAttribute("Level", tonumber(lv))
	model:SetAttribute("LotW", design.w)
	model:SetAttribute("LotD", design.d)
	local fixed = props(lvInfo.equip)
	for _, e in props(lvInfo.fixture) do table.insert(fixed, e) end
	model:SetAttribute("KitProps", HttpService:JSONEncode(fixed))
	model:SetAttribute("KitRoof", layouts(lvInfo.roof)) -- goes with Detail_Plant<i>
	model:SetAttribute("KitSite", layouts(lvInfo.site))
	model:SetAttribute("KitFence", layouts(lvInfo.fenceItems)) -- goes with Detail_Fence<i>
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

-- The Part-built set moves aside (not deleted) the first time a size gets new templates.
local function retireOld(sizeFolder: Instance, sizeName: string)
	local old = folderAt(ServerStorage, "IndustrialPartBuilt")
	for _, c in sizeFolder:GetDescendants() do
		if c:IsA("Model") and not c.Name:match("^IN_") and c.Parent and c.Parent:IsA("Folder") then
			local dest = folderAt(folderAt(old, sizeName), c.Parent.Name == sizeName and "Level1" or c.Parent.Name)
			c.Parent = dest
		end
	end
end

function IndustrialSetup.run(manifestJson: string, onlyW: number?): string
	local manifest = HttpService:JSONDecode(manifestJson)
	local root = folderAt(folderAt(folderAt(ServerStorage, "Templates"), "Buildings"), "Industrial")
	local report: { string } = {}
	local retired: { [string]: boolean } = {}

	for w = 2, 5 do
		if onlyW and w ~= onlyW then continue end
		local import = Workspace:FindFirstChild("IN_W" .. w)
		if not import then
			table.insert(report, ("IN_W%d: not imported"):format(w))
			continue
		end
		-- design -> level -> part name -> part
		local found: { [string]: { [string]: { [string]: MeshPart } } } = {}
		for _, p in import:GetDescendants() do
			local design, lv, role = p.Name:match("^(IN_%d+x%d+_%w+)_L(%d)_([%w_]+)$")
			if design and p:IsA("MeshPart") then
				found[design] = found[design] or {}
				found[design][lv] = found[design][lv] or {}
				found[design][lv][role] = p
			end
		end

		local clean, made = true, 0
		for name, design in manifest do
			if name:sub(1, 1) == "_" or design.w ~= w then continue end
			local sizeName = ("%dx%d"):format(design.w, design.d)
			local sizeFolder = folderAt(root, sizeName)
			if not retired[sizeName] then
				retireOld(sizeFolder, sizeName)
				retired[sizeName] = true
			end
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
				local boxes = {}
				for role, p in info.parts do boxes[role] = box(p) end
				local map = detect(name .. " L" .. lv, parts :: any, boxes)
				local dest = if lv == "1" then sizeFolder else folderAt(sizeFolder, "Level" .. lv)
				local old = dest:FindFirstChild(name)
				if old then old:Destroy() end
				buildTemplate(name, design, lv, parts :: any, map).Parent = dest
				made += 1
			end
		end
		if clean then
			import:Destroy()
			table.insert(report, ("IN_W%d: %d templates, import removed"):format(w, made))
		else
			table.insert(report, ("IN_W%d: %d templates, import KEPT (see missing)"):format(w, made))
		end
	end
	return table.concat(report, "\n")
end

-- The kit props (Workspace.Ind_* / Gate_*, from Models/kits/IndustrialKit + FenceKit, made by
-- blender/ind_kit.py) -> ServerStorage.Templates.Asset.Props.Industrial.<Name>, at true size
-- (the importer brings them in at 50x), pivot = the Blender origin at ground with an identity
-- frame (LotDressingService seats them by it). <P>_Paint takes the main part's sheet maps and
-- the manifest's default tint; <P>_Grate is see-through; Smoke markers get an emitter. The
-- guard booth is PowerKit's Control_Shed, copied from Authoring.Sources.SolarFarm.
--   IndustrialSetup.props(HttpService:GetAsync(".../ind_manifest.json"))
function IndustrialSetup.props(manifestJson: string): string
	local man = HttpService:JSONDecode(manifestJson).props
	local assetRoot = folderAt(folderAt(folderAt(ServerStorage, "Templates"), "Asset"), "Props")
	local dest = folderAt(assetRoot, "Industrial")
	local report, done = {}, 0
	for _, m in Workspace:GetChildren() do
		local info = man[m.Name]
		if not (info and m:IsA("Model")) then continue end
		local pivot = m:GetPivot().Position
		local _, ext = m:GetBoundingBox()
		local want = Vector3.new(info.studs[1], info.studs[3], info.studs[2])
		local s = want.Magnitude / ext.Magnitude
		local mainSa: SurfaceAppearance? = nil
		for _, p in m:GetDescendants() do
			if p:IsA("MeshPart") and p.Name == m.Name then mainSa = p:FindFirstChildOfClass("SurfaceAppearance") end
		end
		local tall = want.Y > 3
		for _, p in m:GetDescendants() do
			if not p:IsA("MeshPart") then continue end
			p.Size *= s
			p.Position = pivot + (p.Position - pivot) * s
			p.Color = Color3.new(1, 1, 1)
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.CastShadow = tall
			p.DoubleSided = true -- the user: every kit prop double-sided (thin panels read from behind)
			local sa = p:FindFirstChildOfClass("SurfaceAppearance")
			if p.Name == m.Name .. "_Paint" and sa and mainSa then
				sa.ColorMap = mainSa.ColorMap
				if sa.NormalMap == "" then sa.NormalMap = mainSa.NormalMap end
				if sa.RoughnessMap == "" then sa.RoughnessMap = mainSa.RoughnessMap end
				if sa.MetalnessMap == "" then sa.MetalnessMap = mainSa.MetalnessMap end
				sa.Color = rgb(info.tint)
			elseif p.Name == m.Name .. "_Grate" then
				if sa then
					sa.AlphaMode = Enum.AlphaMode.Transparency
				elseif p.TextureID ~= "" then
					alphaSkin(p, true)
				end
				p.DoubleSided = true
				p.CastShadow = false
			end
		end
		m.WorldPivot = CFrame.new(pivot)
		m:PivotTo(CFrame.identity)
		for mk, v in info.markers do
			if mk:match("^Smoke") then
				local att = Instance.new("Attachment")
				att.Name = mk
				att.Position = turned(v.pos[1], v.pos[2], v.pos[3])
				local host = m:FindFirstChild(m.Name)
				att.Parent = if host and host:IsA("BasePart") then host else m:FindFirstChildWhichIsA("BasePart", true)
				att.WorldPosition = turned(v.pos[1], v.pos[2], v.pos[3])
				local pe = Instance.new("ParticleEmitter")
				pe.Name = "Smoke"
				pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
				pe.Color = ColorSequence.new(Color3.fromRGB(200, 200, 198), Color3.fromRGB(150, 150, 150))
				pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
				pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 9) })
				pe.Lifetime = NumberRange.new(5, 8)
				pe.Rate = 2
				pe.Speed = NumberRange.new(2, 3)
				pe.SpreadAngle = Vector2.new(8, 8)
				pe.Acceleration = Vector3.new(0.6, 0.4, 0)
				pe.LightInfluence = 1
				pe.Parent = att
			end
		end
		local old = dest:FindFirstChild(m.Name)
		if old then old:Destroy() end
		m.Parent = dest
		done += 1
	end
	if not dest:FindFirstChild("Control_Shed") then
		local src = ServerStorage:FindFirstChild("Authoring") and ServerStorage.Authoring:FindFirstChild("Sources")
			and ServerStorage.Authoring.Sources:FindFirstChild("SolarFarm") and ServerStorage.Authoring.Sources.SolarFarm:FindFirstChild("Control_Shed")
		if src then
			local c = src:Clone()
			local cf, ext = c:GetBoundingBox()
			c.WorldPivot = CFrame.new(cf.Position - Vector3.new(0, ext.Y / 2, 0))
			c:PivotTo(CFrame.identity)
			for _, p in c:GetDescendants() do
				if p:IsA("BasePart") then
					p.Anchored = true
					p.CanCollide = false
					p.CanQuery = false
					p.CanTouch = false
					if p:IsA("MeshPart") then p.DoubleSided = true end
				end
			end
			c.Parent = dest
			table.insert(report, "Control_Shed copied from Authoring.Sources.SolarFarm")
		end
	end
	local missing = {}
	for name in man do
		if not dest:FindFirstChild(name) then table.insert(missing, name) end
	end
	table.sort(missing)
	table.insert(report, ("%d props set up; missing: %s"):format(done, if #missing > 0 then table.concat(missing, ", ") else "none"))
	return table.concat(report, "\n")
end

return IndustrialSetup
