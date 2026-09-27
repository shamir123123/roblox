--!strict
-- Edit-time authoring tool (NOT runtime). Turns the 3D-Imported low-commercial kit
-- (Workspace.CL_W2..CL_W5, one Model per lot width, from Models/kits/CommercialKit/)
-- into ServerStorage.Templates.Buildings.Commercial.<WxD>[.Level2|.Level3].<Design>:
-- the same design name at every level, so BuildingService swaps a shop to its own
-- upgraded self on a level-up. The import is DESTROYED after a clean pass.
-- comlow_manifest.json (~0.9 MB) is too big for a ModuleScript, so it is passed in.
-- Serve Models/kits/_manifests over localhost, then from the command bar / MCP:
--   local json = game:GetService("HttpService"):GetAsync("http://127.0.0.1:<port>/comlow_manifest.json")
--   require(game.ServerStorage.Authoring.CommercialLowSetup).run(json)
-- Needs Plugin capability (SurfaceAppearance maps can't be written from a game thread).

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local CommercialLowSetup = {}

-- textures/out/combuild_pbr/<stem>_{color,normal,rough}.png (ambientCG CC0, tintable ones
-- greyed). UVs are already metres / tile size, so every map tiles at its real size.
local PBR = table.freeze({
	wall_board = { "rbxassetid://89221031962562", "rbxassetid://123063505699775", "rbxassetid://125801632864690" },
	wall_brick = { "rbxassetid://72150076658108", "rbxassetid://117426192866440", "rbxassetid://113582052910022" },
	wall_brickmix = { "rbxassetid://139136940257264", "rbxassetid://100141161807060", "rbxassetid://107053265186751" },
	wall_cmu = { "rbxassetid://127278047298003", "rbxassetid://126204064961245", "rbxassetid://79500115923087" },
	wall_eifs = { "rbxassetid://116716866117962", "rbxassetid://93513486041564", "rbxassetid://139315521072323" },
	wall_panel = { "rbxassetid://139289033576384", "rbxassetid://139750313932064", "rbxassetid://131377655544477" },
	wall_ribbed = { "rbxassetid://75962588913667", "rbxassetid://72839850409271", "rbxassetid://103119178036620" },
	wall_siding = { "rbxassetid://106189322806948", "rbxassetid://115670498824158", "rbxassetid://86984856171970" },
	wall_stone = { "rbxassetid://77903263304386", "rbxassetid://111891370213520", "rbxassetid://119754477363084" },
	wall_stucco = { "rbxassetid://87697973850679", "rbxassetid://131535674081122", "rbxassetid://111864923928213" },
	wall_tile = { "rbxassetid://112132292739007", "rbxassetid://110100196123696", "rbxassetid://125212030605765" },
	trim = { "rbxassetid://79524206353874", "rbxassetid://108362861905834", "rbxassetid://100480888530278" },
	trim_smooth = { "rbxassetid://134028487242206", "rbxassetid://137134616010950", "rbxassetid://72662390339338" },
	roof_gravel = { "rbxassetid://76548794894238", "rbxassetid://135619350183790", "rbxassetid://128276553669900" },
	roof_membrane = { "rbxassetid://109808355491341", "rbxassetid://115728070212757", "rbxassetid://79791541565452" },
	ground_asphalt = { "rbxassetid://120080415780352", "rbxassetid://79355365228190", "rbxassetid://109068372983887" },
})
-- textures/out/roofplant: one colourway per Plant layout, shared normal / rough / metal.
local RTU_COLOR = table.freeze({
	grey = "rbxassetid://85590259540515",
	tan = "rbxassetid://91004266669781",
	white = "rbxassetid://125332764160772",
})
local RTU_NORMAL = "rbxassetid://116021957319853"
local RTU_ROUGH = "rbxassetid://126886580637444"
local RTU_METAL = "rbxassetid://113221445147181"

local PAINT_ROLE = table.freeze({ Walls = "Wall", Trim = "Trim", Roof = "Roof" })
local TINT_KEY = table.freeze({ Walls = "wallTint", Trim = "trimTint", Roof = "roofTint" })
-- Negated with the importer's turn: every other attr is a Z or a half-width and survives it.
local X_ATTRS = table.freeze({ EntranceX = true, LotEntryX = true, LotEntryX2 = true })
local TOLERANCE = 0.05 -- studs a part may sit off the manifest before we refuse it

type Box = { number } -- minX, minY, minZ, maxX, maxY, maxZ in Blender axes (y = street, z = up)
type Map = (x: number, y: number, z: number) -> Vector3

-- Blender -> template (X, Y up, Z = street). The importer turns the kit 180 about Y, which
-- is exactly `turned`, and leaves the street on +Z where BuildingService wants it.
-- `plain` is the un-turned import; a part from one is spun 180 to match.
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

local function skin(p: MeshPart, color: string, normal: string?, rough: string?, metal: string?): SurfaceAppearance
	local sa = Instance.new("SurfaceAppearance")
	sa.Name = "Skin"
	sa.ColorMap = color
	if normal then sa.NormalMap = normal end
	if rough then sa.RoughnessMap = rough end
	if metal then sa.MetalnessMap = metal end
	sa.Parent = p
	return sa
end

-- Fence infill and grime decals: MeshPart.TextureID ignores the PNG alpha, so the importer's
-- texture moves onto a SurfaceAppearance in Transparency mode.
local function alphaSkin(p: MeshPart, doubleSided: boolean)
	local sa = skin(p, p.TextureID)
	sa.AlphaMode = Enum.AlphaMode.Transparency
	p.TextureID = ""
	p.DoubleSided = doubleSided
end

local function dressPart(p: MeshPart, role: string, design: any, lvInfo: any)
	local look = design.look
	local tex = if role == "Walls" then PBR[look.wall]
		elseif role == "Trim" then PBR[look.trim]
		elseif role == "Roof" then PBR[look.roof]
		elseif role == "Ground" then PBR.ground_asphalt
		else nil
	if tex then
		local sa = skin(p, tex[1], tex[2], tex[3])
		local tint = TINT_KEY[role] and look[TINT_KEY[role]]
		if tint then
			-- The baseline look from Blender; LotDressingService jitters it per placement.
			sa.Color = Color3.fromRGB(tint[1], tint[2], tint[3])
			p:SetAttribute("PaintRole", PAINT_ROLE[role])
		end
		p.CastShadow = role ~= "Ground"
		return
	end
	local plant = tonumber(role:match("^Plant(%d)$"))
	if plant then
		skin(p, RTU_COLOR[lvInfo.schemes[plant]], RTU_NORMAL, RTU_ROUGH, RTU_METAL)
	elseif role:match("^Fence%d$") then
		alphaSkin(p, true) -- both faces are modelled, and the far side must read through the near
	elseif role == "Grime" then
		alphaSkin(p, false)
		p.CastShadow = false
	end
	-- Sign and Fixed keep the atlas the importer uploaded as TextureID.
end

-- Three prop layouts in template studs, yaw in degrees: { { {prop, x, y, z, yaw}, ... } x3 }.
-- The prop FBXs get the same importer turn, so a Blender yaw carries over unchanged
-- ((x, y) -> (-x, y) maps a Blender Z rotation by theta onto a Roblox Y rotation by theta).
local function siteLayouts(site: any): string
	local out = {}
	for i, layout in site do
		local props = {}
		for _, e in layout do
			local v = turned(e.pos[1], e.pos[2], e.pos[3])
			table.insert(props, { e.prop, v.X, v.Y, v.Z, e.rot % 360 })
		end
		out[i] = props
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
		for _, c in p:GetChildren() do c:Destroy() end
		p.Size = span(b)
		p.CFrame = CFrame.new(centre(b, turned)) * rot
		p.Color = Color3.new(1, 1, 1) -- the import arrives grey, and Color multiplies
		p.Transparency = 0
		p.Anchored = true
		dressPart(p, role, design, lvInfo)
		p.Parent = model
		if role == "Walls" or role == "Trim" or role == "Roof" then
			lo = lo:Min(p.Position - p.Size / 2)
			hi = hi:Max(p.Position + p.Size / 2)
		end
	end

	local lotW, lotD = design.lotStuds[1], design.lotStuds[2]
	-- Lot-sized marker so the model's bounding box IS the lot (BuildingService centres on it),
	-- and the frame LotDressingService seats the site props in.
	invisiblePart("FootprintAnchor", Vector3.new(lotW, 0.2, lotD), CFrame.new(0, 0.1, 0), model)
	-- One box over the building is what selection hits; the parking markers ride on it.
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
	model:SetAttribute("StudsPerMetre", 2)
	model:SetAttribute("BusinessType", design.business)
	model:SetAttribute("Level", tonumber(lv))
	model:SetAttribute("LotW", design.w)
	model:SetAttribute("LotD", design.d)
	model:SetAttribute("SiteLayouts", siteLayouts(lvInfo.site))
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

function CommercialLowSetup.run(manifestJson: string): string
	local manifest = HttpService:JSONDecode(manifestJson)
	local root = folderAt(folderAt(folderAt(ServerStorage, "Templates"), "Buildings"), "Commercial")
	local report: { string } = {}

	for w = 2, 5 do
		local import = Workspace:FindFirstChild("CL_W" .. w)
		if not import then
			table.insert(report, ("CL_W%d: not imported"):format(w))
			continue
		end
		-- design -> level -> role -> part
		local found: { [string]: { [string]: { [string]: MeshPart } } } = {}
		for _, p in import:GetDescendants() do
			local design, lv, role = p.Name:match("^(CL_%d+x%d+_%w+)_L(%d)_(%w+)$")
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
				local boxes = {}
				for role, p in info.parts do boxes[role] = box(p) end
				local map = detect(name .. " L" .. lv, parts :: any, boxes)
				local dest = if lv == "1" then sizeFolder else folderAt(sizeFolder, "Level" .. lv)
				local old = dest:FindFirstChild(name)
				if old then old:Destroy() end
				buildTemplate(name, design, lv, parts :: any, map).Parent = dest
			end
		end
		if clean then
			import:Destroy()
			table.insert(report, ("CL_W%d: done, import removed"):format(w))
		end
	end
	return table.concat(report, "\n")
end

return CommercialLowSetup
