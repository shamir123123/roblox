--!strict
-- Edit-time authoring tool (NOT runtime). Turns the 3D-Imported mid-rise v2 kit (Workspace.RM_W2..RM_W5,
-- one Model per lot width, from Models/kits/MidRiseKit/, made by blender/res_mid.py) into
-- ServerStorage.Templates.Buildings.ResidentialMedium.<WxD>[.Level2|.Level3].<Design>: the same design
-- name at every level, so a level-up swaps a block to its own taller self. The v1 MR_ templates move
-- (not deleted) to ServerStorage.MidRiseV1, and an import is DESTROYED after a clean pass.
-- resmid_manifest.json (~7 MB) is passed in:
--   local json = game:GetService("HttpService"):GetAsync("http://127.0.0.1:<port>/Models/kits/_manifests/resmid_manifest.json")
--   require(game.ServerStorage.Authoring.MidRiseV2Setup).run(json [, w])
-- .props() files the kit props those buildings use that Studio lacked (Workspace.ResMidProps_ALL, from
-- Models/kits/_bundles/ResMidProps_ALL.fbx + _manifests/resmid_props.json) into
-- Templates.Asset.Props.MidRise. Needs Plugin capability (SurfaceAppearance maps).
--
-- Parts (BUILDING_PIPELINE.md): Walls/Base/Trim/Roof/Mansard/Detail_Orn/Detail_Escape carry the design's
-- tint on their SurfaceAppearance; Detail_* are dropped at LOD1 (LODDetail); LOD_* are the <500-tri
-- LOD2 model, shipped invisible (LOD2). Kit props ride as JSON attributes for LotDressingService:
-- KitProps (canopies, water towers, hatch, bin corner), KitRoof / KitSite (three layouts each, one
-- kept per placement) and KitAC (every window that can take a unit; a random share is filled).

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local MidRiseV2Setup = {}

-- The importer brought only the normal maps of the tinted looks (the Blender tint node hid the
-- colour), so the colour and roughness maps were uploaded 2026-09-27; roof_slate is v1's.
local COLOR_MAP = table.freeze({
	rm_brick_buff = "rbxassetid://131490605932708",
	rm_brick_red = "rbxassetid://82275475977302",
	rm_brick_rustic = "rbxassetid://121332363555792",
	rm_stone_block = "rbxassetid://100544096020617",
	rm_trim = "rbxassetid://122201784196195",
	rm_roof_rolled = "rbxassetid://132411613827810",
	rm_ornament = "rbxassetid://72746188379714",
	rm_escape = "rbxassetid://88488213740667",
	roof_slate = "rbxassetid://134147666317846",
})
local ROUGH_MAP = table.freeze({
	rm_brick_buff = "rbxassetid://119754477363084",
	rm_brick_red = "rbxassetid://113582052910022",
	rm_brick_rustic = "rbxassetid://107053265186751",
	rm_stone_block = "rbxassetid://79500115923087",
	rm_trim = "rbxassetid://72662390339338",
	rm_roof_rolled = "rbxassetid://76109393011101",
	rm_ornament = "rbxassetid://116918027396017",
})

-- role -> the look key naming its texture, or the texture itself
local STEM = table.freeze({
	Walls = "wall", Base = "base", Trim = "=rm_trim", Roof = "=rm_roof_rolled", Mansard = "=roof_slate",
	Detail_Orn = "=rm_ornament", Detail_Escape = "=rm_escape",
})
local TINT_KEY = table.freeze({
	Walls = "wallTint", Base = "baseTint", Trim = "trimTint", Roof = "roofTint", Mansard = "mansardTint",
	Detail_Orn = "trimTint", Detail_Escape = "escapeTint",
	LOD_Walls = "wallTint", LOD_Base = "baseTint", LOD_Roof = "roofTint",
})
local AVG_KEY = table.freeze({ LOD_Walls = "wallAvg", LOD_Base = "baseAvg", LOD_Roof = "roofAvg" })
local PAINT_ROLE = table.freeze({
	Walls = "Wall", Base = "Base", Trim = "Trim", Roof = "Roof", Mansard = "Roof", Detail_Orn = "Trim",
	LOD_Walls = "Wall", LOD_Base = "Base", LOD_Roof = "Roof",
})
local NO_SHADOW = table.freeze({ Ground = true, Detail_Escape = true })
-- AC slot wall -> share bucket LotDressingService fills at (1 front, 2 side, 3 back / court)
local AC_WALL = table.freeze({ front = 1, corner = 1, side = 2 })
local TOLERANCE = 0.05 -- studs a part may sit off the manifest before we refuse it
local PROP_SHADOW_STUDS = 3 -- a kit prop this tall casts a shadow

type Box = { number } -- minX, minY, minZ, maxX, maxY, maxZ in Blender axes (y = street, z = up)
type Map = (x: number, y: number, z: number) -> Vector3

-- Blender -> template (X, Y up, Z = street). The importer turns the kit 180 about Y (`turned`);
-- `plain` is an un-turned import.
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

-- Which map lines the imported parts' centres up with the manifest boxes (the import scale drops out).
local function detect(label: string, parts: { [string]: MeshPart }, boxes: { [string]: Box }): Map
	local s, n = 0, 0
	for key, p in parts do
		assert(p.Orientation.Magnitude < 0.01, p:GetFullName() .. " arrived rotated")
		local sp = span(boxes[key]).Magnitude
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
		for key, p in parts do
			local o = p.Position - centre(boxes[key], map) * s
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

-- MeshPart.TextureID ignores the PNG alpha: the texture moves onto a SurfaceAppearance in
-- Transparency mode (fire escapes, the LOD window sheet, fence infill, tower ladders).
local function skin(p: MeshPart): SurfaceAppearance
	local sa = p:FindFirstChildOfClass("SurfaceAppearance")
	if sa then return sa end
	sa = Instance.new("SurfaceAppearance")
	sa.Name = "Skin"
	sa.ColorMap = p.TextureID
	sa.Parent = p
	p.TextureID = ""
	return sa :: SurfaceAppearance
end

local function dressPart(p: MeshPart, role: string, look: any)
	local stem = STEM[role]
	if stem then
		stem = if stem:sub(1, 1) == "=" then stem:sub(2) else look[stem]
		local map = COLOR_MAP[stem]
		assert(map, "no colour map for texture " .. tostring(stem))
		local sa = skin(p)
		sa.ColorMap = map
		sa.RoughnessMap = ROUGH_MAP[stem] or ""
		sa.Color = rgb(look[TINT_KEY[role]])
		if role == "Detail_Escape" then
			sa.AlphaMode = Enum.AlphaMode.Transparency
			p.DoubleSided = true -- a grating reads from both sides
		end
	elseif role == "LOD_Windows" then
		skin(p).AlphaMode = Enum.AlphaMode.Transparency
	end
	if AVG_KEY[role] then -- untextured LOD2 shell: the design's colour x the texture's average tone
		local t, a = look[TINT_KEY[role]], look[AVG_KEY[role]]
		p.Color = Color3.fromRGB(t[1] * a[1] / 255, t[2] * a[2] / 255, t[3] * a[3] / 255)
	else
		p.Color = Color3.new(1, 1, 1) -- the import arrives grey, and Color multiplies
	end
	if PAINT_ROLE[role] then p:SetAttribute("PaintRole", PAINT_ROLE[role]) end
	if role:sub(1, 7) == "Detail_" then p:SetAttribute("LODDetail", true) end
	if role:sub(1, 4) == "LOD_" then
		p:SetAttribute("LOD2", true)
		p.Transparency = 1 -- until AssetLODView swaps it in
	end
	p.CastShadow = not (NO_SHADOW[role] or role:sub(1, 4) == "LOD_")
end

-- Kit-prop placements in template studs, yaw in degrees: { {prop, x, y, z, yaw}, ... }. The prop
-- models get the same importer turn, so a Blender yaw carries over unchanged.
local function props(list: any): { any }
	local out = {}
	for _, e in list do
		local v = turned(e.pos[1], e.pos[2], e.pos[3])
		table.insert(out, { e.prop, v.X, v.Y, v.Z, e.rot % 360 })
	end
	return out
end

local function layouts(ls: any): string
	local out = {}
	for i, l in ls do out[i] = props(l) end
	return HttpService:JSONEncode(out)
end

-- { {x, y, z, yaw, wall}, ... } with wall = AC_WALL bucket (3 = back / court)
local function acSlots(slots: any): string
	local out = {}
	for _, s in slots do
		local v = turned(s.pos[1], s.pos[2], s.pos[3])
		table.insert(out, { v.X, v.Y, v.Z, s.rot % 360, AC_WALL[s.wall] or 3 })
	end
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
		if role == "Walls" or role == "Base" or role == "Roof" or role == "Mansard" then
			lo = lo:Min(p.Position - p.Size / 2)
			hi = hi:Max(p.Position + p.Size / 2)
		end
	end

	local lotW, lotD = design.lotStuds[1], design.lotStuds[2]
	-- Lot-sized marker so the model's bounding box IS the lot (BuildingService centres on it),
	-- and the frame LotDressingService seats the kit props in.
	invisiblePart("FootprintAnchor", Vector3.new(lotW, 0.2, lotD), CFrame.new(0, 0.1, 0), model)
	-- One box over the building is what selection hits, so an upper floor clicks too.
	local body = invisiblePart("Body", hi - lo, CFrame.new((lo + hi) / 2), model)
	model.PrimaryPart = body

	for k, v in lvInfo.attrs do model:SetAttribute(k, v) end
	model:SetAttribute("Density", "Medium")
	model:SetAttribute("Level", tonumber(lv))
	model:SetAttribute("LotW", design.w)
	model:SetAttribute("LotD", design.d)
	model:SetAttribute("StudsPerMetre", 2)
	model:SetAttribute("KitYard", true)
	model:SetAttribute("LODTiers", true) -- AssetLODView: LOD1 drops Detail_ + small props, LOD2 shows LOD_ only
	-- BuildingHalfWidth also marks a scripted template: BuildingService turns its +Z front to the road.
	model:SetAttribute("BuildingHalfWidth", (hi.X - lo.X) / 2)
	local door = lvInfo.marks.Door1
	if door then
		model:SetAttribute("DoorX", -door.pos[1])
		model:SetAttribute("BuildingFrontZ", door.pos[2])
	end
	local garage = lvInfo.marks.Garage
	model:SetAttribute("HasParking", garage ~= nil)
	if garage then -- residents' cars drive up to this door plane and are stowed
		model:SetAttribute("GarageX", -garage.pos[1])
		model:SetAttribute("GarageZ", garage.pos[2])
		model:SetAttribute("GarageWidth", garage.width)
	end
	local fixed = props(lvInfo.entry)
	for _, key in { "roofFixed", "siteFixed" } do
		for _, e in props(lvInfo[key]) do table.insert(fixed, e) end
	end
	model:SetAttribute("KitProps", HttpService:JSONEncode(fixed))
	model:SetAttribute("KitRoof", layouts(lvInfo.roof))
	model:SetAttribute("KitSite", layouts(lvInfo.site))
	model:SetAttribute("KitAC", acSlots(lvInfo.acSlots))
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

-- The v1 set moves aside (not deleted) the first time a size gets new templates.
local function retireOld(sizeFolder: Instance, sizeName: string)
	local old = folderAt(ServerStorage, "MidRiseV1")
	for _, c in sizeFolder:GetDescendants() do
		if c:IsA("Model") and c.Name:match("^MR_") and c.Parent and c.Parent:IsA("Folder") then
			c.Parent = folderAt(folderAt(old, sizeName), if c.Parent.Name == sizeName then "Level1" else c.Parent.Name)
		end
	end
end

function MidRiseV2Setup.run(manifestJson: string, onlyW: number?): string
	local manifest = HttpService:JSONDecode(manifestJson)
	local root = folderAt(folderAt(folderAt(ServerStorage, "Templates"), "Buildings"), "ResidentialMedium")
	local report: { string } = {}
	local retired: { [string]: boolean } = {}

	for w = 2, 5 do
		if onlyW and w ~= onlyW then continue end
		local import = Workspace:FindFirstChild("RM_W" .. w)
		if not import then
			table.insert(report, ("RM_W%d: not imported"):format(w))
			continue
		end
		-- design -> level -> part name -> part
		local found: { [string]: { [string]: { [string]: MeshPart } } } = {}
		for _, p in import:GetDescendants() do
			local design, lv, role = p.Name:match("^(RM_%d+x%d+_%w+)_L(%d)_([%w_]+)$")
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
			table.insert(report, ("RM_W%d: %d templates, import removed"):format(w, made))
		else
			table.insert(report, ("RM_W%d: %d templates, import KEPT (see missing)"):format(w, made))
		end
	end
	return table.concat(report, "\n")
end

-- The bundle's parts are named X_<Prop>[_Paint|_Alpha|_Mesh]; each prop sits on its own spot along
-- Blender +x. Every part is re-seated from its manifest box about its prop's origin (the Blender
-- origin at ground, identity pivot, as LotDressingService seats kit props), so the import scale and
-- turn drop out. ResKit paint parts get their tint back on SurfaceAppearance.Color; _Alpha / _Mesh
-- parts are see-through. Every kit prop double-sided (the user: thin panels read from behind).
function MidRiseV2Setup.props(manifestJson: string): string
	local man = HttpService:JSONDecode(manifestJson).props
	local import = Workspace:FindFirstChild("ResMidProps_ALL")
	assert(import, "import Models/kits/_bundles/ResMidProps_ALL.fbx first")
	local dest = folderAt(folderAt(folderAt(folderAt(ServerStorage, "Templates"), "Asset"), "Props"), "MidRise")
	local found: { [string]: MeshPart } = {}
	local boxes: { [string]: Box } = {}
	for _, p in import:GetDescendants() do
		local pn = p.Name:match("^X_(.+)$")
		if pn and p:IsA("MeshPart") then found[pn] = p end
	end
	for _, info in man do
		for pn, b in info.parts do
			if found[pn] then boxes[pn] = box(b) end
		end
	end
	local map = detect("ResMidProps_ALL", found, boxes)
	local rot = if map == turned then CFrame.identity else CFrame.Angles(0, math.pi, 0)

	local report, done = {}, 0
	for name, info in man do
		local model = Instance.new("Model")
		model.Name = name
		local o = info.origin
		local ok = true
		for pn, b in info.parts do
			local src = found[pn]
			if not src then
				table.insert(report, name .. " missing part " .. pn)
				ok = false
				continue
			end
			local bx = box(b)
			local p = src:Clone()
			p.Name = pn
			p.Size = span(bx)
			p.CFrame = CFrame.new(turned((bx[1] + bx[4]) / 2 - o[1], (bx[2] + bx[5]) / 2 - o[2], (bx[3] + bx[6]) / 2 - o[3])) * rot
			p.Color = Color3.new(1, 1, 1)
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.DoubleSided = true
			p.CastShadow = not b.alpha and span(bx).Y > PROP_SHADOW_STUDS
			if b.tint or b.alpha then
				local sa = skin(p)
				if b.tint then sa.Color = rgb(b.tint) end
				if b.alpha then sa.AlphaMode = Enum.AlphaMode.Transparency end
			end
			p.Parent = model
		end
		if not ok then
			model:Destroy()
			continue
		end
		model.WorldPivot = CFrame.identity
		local old = dest:FindFirstChild(name)
		if old then old:Destroy() end
		model.Parent = dest
		done += 1
	end
	if #report == 0 then import:Destroy() end
	table.sort(report)
	table.insert(report, ("%d props set up in Props.MidRise%s"):format(done, if #report == 0 then ", import removed" else ""))
	return table.concat(report, "\n")
end

return MidRiseV2Setup
