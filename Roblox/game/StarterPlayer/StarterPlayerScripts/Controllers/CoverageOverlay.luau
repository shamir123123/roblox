--!strict
-- CoverageOverlay
-- ONE owner of the client-side coverage visuals.
-- Two styles:
--   "grey" -- placement tool: reach discs + uncovered buildings greyed out
--   "heat" -- heatmap view: no discs; buildings get a Citystate-style colour
--             wash (green = covered, red = not) that keeps each part's own
--             light/dark detail, and the baked road meshes are tinted to match.
-- Pure client-side recolour: server colours are untouched and restored on clear.
-- Shared by EmergencyPlacementController (grey) and HeatmapController (heat) so
-- the two can never fight over a building's saved colours.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))
local ServiceTypes = require(game:GetService("ReplicatedStorage").City.ServiceTypes)

local CoverageOverlay = {}

local REFRESH = 1.5
-- Repaint budget per frame: the city is tinted a slice at a time so toggling the
-- heatmap never stalls a frame, it sweeps in over a few frames instead.
local FRAME_BUDGET = 0.0015
-- Parts smaller than this (studs^3) are never tinted: trim, window frames, lane
-- markings. They carry most of the part count and almost none of the look.
local MIN_PART_VOLUME = 1.5
-- Short on purpose: a long crossfade leaves the map showing in-between colours
-- that aren't real data. Fade should read as polish, not as information.
local FADE_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local UNCOVERED_GREY = Color3.fromRGB(112, 114, 118)
local HEAT_COVERED   = Color3.fromRGB(150, 235, 190)
local HEAT_UNCOVERED = Color3.fromRGB(244, 96, 84)
local ROAD_NEUTRAL   = Color3.new(1, 1, 1) -- baked road meshes ship white

local RING_COLOR: { [string]: Color3 } = {
	Hospital  = Color3.fromRGB(214, 96, 92),
	Police    = Color3.fromRGB(86, 140, 210),
	Fire      = Color3.fromRGB(240, 150, 60),
	Power     = Color3.fromRGB(132, 176, 240),
	Water     = Color3.fromRGB(80, 170, 235),
	Sewage    = Color3.fromRGB(150, 190, 90),
	Deathcare = Color3.fromRGB(142, 168, 142),
	Education = Color3.fromRGB(170, 130, 220),
}
local RING_FALLBACK = Color3.fromRGB(120, 200, 140)
-- Most supply areas the power view will fold into its region at once (nearest first).
local POWER_AREA_CAP = 400
-- Raster cell for that region, studs. Small enough that the edge does not read as stairs,
-- big enough that a district is a few hundred parts rather than a few thousand.
local POWER_CELL = 8

type Station = { pos: Vector3, radius: number }
type Style = "grey" | "heat"

local _kind: string? = nil
local _style: Style = "grey"
local _savedColors: { [Model]: { [BasePart]: Color3 } } = {}
local _origFlat: { [BasePart]: Color3 } = {} -- flat part->original for fast lookup
local _tintApplied: { [Model]: string } = {} -- model -> applied tint tag (skip redundant repaints)

type Job = { tag: string, color: Color3?, wash: boolean }
local _pending: { [Model]: Job } = {}
local _pendingCount = 0
local _pumpConn: RBXScriptConnection? = nil
local _rings: { BasePart } = {}
local _regionImage: any = nil -- strong ref: an EditableImage is not parented, so GC eats it
local _nextRefreshAt = 0

local function cityFolder(name: string): Folder?
	local city = Workspace:FindFirstChild("_City")
	local f = city and city:FindFirstChild(name)
	return if f and f:IsA("Folder") then f else nil
end

function CoverageOverlay.ringColor(kind: string): Color3
	return RING_COLOR[kind] or RING_FALLBACK
end

-- Flat translucent reach disc; caller positions it via CoverageOverlay.discTo.
function CoverageOverlay.makeDisc(radius: number, color: Color3): BasePart
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(0.3, radius * 2, radius * 2)
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Transparency = 0.8
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = UiScratch.folder("CoverageOverlay")
	return p
end

function CoverageOverlay.discTo(p: BasePart, pos: Vector3)
	p.CFrame = CFrame.new(pos + Vector3.new(0, 1.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
end

-- Placed same-kind service buildings, read off the replicated models' attributes.
-- "Education" reads the Schools folder; everything else EmergencyServices by kind.
-- ponytail: base radius only -- the server widens reach with funding, not mirrored here.
-- Where a model MEETS THE GROUND, not where its pivot is. A model's pivot sits at its
-- bounding-box centre, so anything drawn off it floats at mid-wall -- which is what put the
-- power region's slab through the middle of every house instead of on the floor under them.
local function groundOf(m: Model): Vector3
	local cf, size = m:GetBoundingBox()
	local p = cf.Position
	return Vector3.new(p.X, p.Y - size.Y * 0.5, p.Z)
end

local function stations(kind: string): { Station }
	local out: { Station } = {}
	local folder = if kind == "Education" then cityFolder("Schools") else cityFolder("EmergencyServices")
	if folder then
		for _, m in folder:GetChildren() do
			if not m:IsA("Model") then continue end
			if kind ~= "Education" and m:GetAttribute("ServiceKind") ~= kind then continue end
			local r = tonumber(m:GetAttribute("CoverageRadius")) or 0
			if r > 0 then table.insert(out, { pos = groundOf(m), radius = r }) end
		end
	end

	-- Electricity is not a station-and-radius service. What matters is where a POLE has to
	-- stand for a building to take power from it, so the discs are the buildings' own
	-- supply areas alongside each generator's yard -- the blue areas of the power view.
	-- Capped and camera-sorted: a full city is thousands of buildings and every disc is a
	-- part. ponytail: nearest N; a merged mesh is the upgrade path if the cap ever shows.
	if kind == "Power" then
		local reach = ServiceTypes.PowerBuildingReach
		local zoned = cityFolder("ZonedBuildings")
		if zoned and reach > 0 then
			local eye = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position or Vector3.zero
			-- Ranked on the pivot (free) and grounded only for the ones kept: groundOf walks
			-- a model's descendants, and a full city is thousands of buildings for 400 slots.
			local near: { { d: number, model: Model } } = {}
			for _, m in zoned:GetChildren() do
				if not m:IsA("Model") then continue end
				near[#near + 1] = { d = (m:GetPivot().Position - eye).Magnitude, model = m }
			end
			table.sort(near, function(a, b) return a.d < b.d end)
			for i = 1, math.min(#near, POWER_AREA_CAP) do
				table.insert(out, { pos = groundOf(near[i].model), radius = reach })
			end
		end
	end

	-- Water and sewage stopped being a station and a radius the day pipes shipped: the MAIN
	-- delivers, and a tower with nothing plugged into it covers nothing at all. So the towers
	-- gathered above are dropped and the pipes sampled instead, one disc every reach along
	-- each run -- the same band the pipe tool paints.
	-- ponytail: coverage only. The client cannot see which networks are actually FED, so a
	-- stranded main still reads as covered here; the badge on its loose end says otherwise.
	if kind == "Water" or kind == "Sewage" then
		table.clear(out)
		local pipes = cityFolder("WaterPipes")
		local reach = ServiceTypes.PipeReach
		if pipes then
			for _, m in pipes:GetChildren() do
				if not m:IsA("Model") then continue end
				if m:GetAttribute(kind) ~= true then continue end
				local ax, az = tonumber(m:GetAttribute("AX")), tonumber(m:GetAttribute("AZ"))
				local bx, bz = tonumber(m:GetAttribute("BX")), tonumber(m:GetAttribute("BZ"))
				if not (ax and az and bx and bz) then continue end
				local a, b = Vector3.new(ax, 0, az), Vector3.new(bx, 0, bz)
				local y = m:GetPivot().Position.Y
				local steps = math.max(1, math.ceil((b - a).Magnitude / reach))
				for i = 0, steps do
					local p = a:Lerp(b, i / steps)
					table.insert(out, { pos = Vector3.new(p.X, y, p.Z), radius = reach })
				end
			end
		end
	end
	return out
end

local function fadeColor(p: BasePart, c: Color3)
	if p.Color == c then return end -- already correct: never re-fade
	TweenService:Create(p, FADE_INFO, { Color = c }):Play()
end

-- Citystate-style wash: keep the part's own light/dark detail, swap its hue.
local function washColor(tint: Color3, original: Color3): Color3
	local l = 0.45 + 0.55 * (0.299 * original.R + 0.587 * original.G + 0.114 * original.B)
	return Color3.new(tint.R * l, tint.G * l, tint.B * l)
end

local function coveredAt(list: { Station }, pos: Vector3): boolean
	for _, s in list do
		local dx, dz = s.pos.X - pos.X, s.pos.Z - pos.Z
		if dx * dx + dz * dz <= s.radius * s.radius then return true end
	end
	return false
end

-- RoadMeshView bakes each road piece to one white MeshPart with vertex colours,
-- so Color is a free whole-piece tint. nil list restores neutral.
local function tintRoads(list: { Station }?)
	local meshes = Workspace:FindFirstChild("_RoadMeshes")
	if not meshes then return end
	for _, mp in meshes:GetChildren() do
		if not mp:IsA("MeshPart") then continue end
		fadeColor(mp, if list then (if coveredAt(list, mp.Position) then HEAT_COVERED else HEAT_UNCOVERED) else ROAD_NEUTRAL)
	end
end

local function restoreModel(model: Model)
	local saved = _savedColors[model]
	_tintApplied[model] = nil
	if not saved then return end
	_savedColors[model] = nil
	for part, color in saved do
		_origFlat[part] = nil
		if part.Parent then fadeColor(part, color) end
	end
end

local function applyJob(model: Model, job: Job)
	local color = job.color
	if color == nil then
		restoreModel(model)
		return
	end
	local saved = _savedColors[model]
	if not saved then
		saved = {}
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Size.X * d.Size.Y * d.Size.Z >= MIN_PART_VOLUME then
				saved[d] = d.Color
				_origFlat[d] = d.Color
			end
		end
		_savedColors[model] = saved
	end
	for part, orig in saved :: { [BasePart]: Color3 } do
		if part.Parent then
			fadeColor(part, if job.wash then washColor(color, orig) else color)
		end
	end
	_tintApplied[model] = job.tag
end

local function pump()
	local deadline = os.clock() + FRAME_BUDGET
	repeat
		local model, job = next(_pending)
		if model == nil or job == nil then break end
		_pending[model] = nil
		_pendingCount -= 1
		if model.Parent then applyJob(model, job) end
	until os.clock() >= deadline
	if next(_pending) == nil then
		_pendingCount = 0
		local conn = _pumpConn
		if conn then conn:Disconnect(); _pumpConn = nil end
	end
end

local function ensurePump()
	if not _pumpConn then
		_pumpConn = RunService.Heartbeat:Connect(pump)
	end
end

-- Latest desired state per model; overwriting a pending job is free, so the
-- queue always converges on the newest refresh even mid-sweep.
local function queueTint(model: Model, tag: string, color: Color3?, wash: boolean)
	local pending = _pending[model]
	if color == nil and not _savedColors[model] then
		-- Nothing painted, nothing to restore: cancel any stale pending tint.
		if pending then _pending[model] = nil; _pendingCount -= 1 end
		return
	end
	if _tintApplied[model] == tag then
		if pending then _pending[model] = nil; _pendingCount -= 1 end
		return
	end
	if pending and pending.tag == tag then return end
	if not pending then _pendingCount += 1 end
	_pending[model] = { tag = tag, color = color, wash = wash }
	ensurePump()
end

-- Electricity is drawn as ONE REGION, not a disc per building and not a stack of slabs.
-- The union of every supply area is rasterised into an EditableImage and shown on a single
-- quad: bilinear filtering plus a one-pixel blur turns the union of circles into the soft
-- rounded outline the info view wants, and the whole city costs ONE part instead of
-- hundreds. Discs read as confetti, left gaps between neighbours on the same grid, and
-- stacked darker where they overlapped.
-- ponytail: one flat quad at the mean FLOOR height (groundOf, not the pivot -- averaging
-- pivots floated it up through the houses), so it still clips on steep relief. Slicing it
-- into per-tile quads is the upgrade path if that ever shows.
local POWER_TEX  = 256 -- texture edge in px; the quad is stretched over the region
local POWER_PAD  = 24  -- studs of margin so the blurred edge has room to fade out

local function buildPowerRegion(list: { Station }, color: Color3)
	if #list == 0 then return end

	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	local sumY, count = 0, 0
	for _, s in list do
		if s.radius <= 0 then continue end
		minX = math.min(minX, s.pos.X - s.radius); maxX = math.max(maxX, s.pos.X + s.radius)
		minZ = math.min(minZ, s.pos.Z - s.radius); maxZ = math.max(maxZ, s.pos.Z + s.radius)
		sumY += s.pos.Y; count += 1
	end
	if count == 0 then return end
	minX -= POWER_PAD; maxX += POWER_PAD
	minZ -= POWER_PAD; maxZ += POWER_PAD

	-- Square the region so texels stay square; a stretched texel blurs unevenly.
	local width, depth = maxX - minX, maxZ - minZ
	local span = math.max(width, depth)
	local cx, cz = (minX + maxX) * 0.5, (minZ + maxZ) * 0.5
	minX, minZ = cx - span * 0.5, cz - span * 0.5
	local perPx = span / POWER_TEX

	-- Coverage mask, one byte per texel.
	local cov = buffer.create(POWER_TEX * POWER_TEX)
	for _, s in list do
		local r = s.radius
		if r <= 0 then continue end
		local rPx = r / perPx
		-- On a Top-face SurfaceGui the image axes are TRANSPOSED and REVERSED against the
		-- world: image X runs along world -Z, image Y along world +X. Measured by painting
		-- one corner of the mask and seeing where it landed, not assumed.
		local ox = (minZ + span - s.pos.Z) / perPx
		local oz = (s.pos.X - minX) / perPx
		local px0 = math.max(0, math.floor(ox - rPx))
		local px1 = math.min(POWER_TEX - 1, math.ceil(ox + rPx))
		local pz0 = math.max(0, math.floor(oz - rPx))
		local pz1 = math.min(POWER_TEX - 1, math.ceil(oz + rPx))
		local r2 = rPx * rPx
		for pz = pz0, pz1 do
			local dz = pz + 0.5 - oz
			local row = pz * POWER_TEX
			for px = px0, px1 do
				local dx = px + 0.5 - ox
				if dx * dx + dz * dz <= r2 then buffer.writeu8(cov, row + px, 255) end
			end
		end
	end

	-- One-pixel separable blur: this is what turns a stepped union into a rounded edge.
	local tmp = buffer.create(POWER_TEX * POWER_TEX)
	for z = 0, POWER_TEX - 1 do
		local row = z * POWER_TEX
		for x = 0, POWER_TEX - 1 do
			local l = if x > 0 then buffer.readu8(cov, row + x - 1) else 0
			local c = buffer.readu8(cov, row + x)
			local r = if x < POWER_TEX - 1 then buffer.readu8(cov, row + x + 1) else 0
			buffer.writeu8(tmp, row + x, (l + c + c + r) // 4)
		end
	end
	for z = 0, POWER_TEX - 1 do
		local row = z * POWER_TEX
		for x = 0, POWER_TEX - 1 do
			local u = if z > 0 then buffer.readu8(tmp, row - POWER_TEX + x) else 0
			local c = buffer.readu8(tmp, row + x)
			local d = if z < POWER_TEX - 1 then buffer.readu8(tmp, row + POWER_TEX + x) else 0
			buffer.writeu8(cov, row + x, (u + c + c + d) // 4)
		end
	end

	local rgba = buffer.create(POWER_TEX * POWER_TEX * 4)
	local cr = math.floor(color.R * 255)
	local cg = math.floor(color.G * 255)
	local cb = math.floor(color.B * 255)
	for i = 0, POWER_TEX * POWER_TEX - 1 do
		local o = i * 4
		buffer.writeu8(rgba, o, cr)
		buffer.writeu8(rgba, o + 1, cg)
		buffer.writeu8(rgba, o + 2, cb)
		-- 0.72 alpha at full coverage, matching what the discs used to read as.
		buffer.writeu8(rgba, o + 3, (buffer.readu8(cov, i) * 72) // 100)
	end

	local okImg, img = pcall(function()
		return game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(POWER_TEX, POWER_TEX) })
	end)
	if not okImg or not img then return end
	img:WritePixelsBuffer(Vector2.zero, img.Size, rgba)
	_regionImage = img

	local quad = Instance.new("Part")
	quad.Name = "PowerRegion"
	quad.Size = Vector3.new(span, 0.3, span)
	quad.CFrame = CFrame.new(cx, sumY / count + 1.4, cz)
	quad.Transparency = 1 -- the part itself is invisible; the image is the visual
	quad.Anchored = true
	quad.CanCollide = false
	quad.CanQuery = false
	quad.CanTouch = false
	quad.CastShadow = false
	quad.Parent = UiScratch.folder("CoverageOverlay")

	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Top
	sg.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	sg.CanvasSize = Vector2.new(POWER_TEX, POWER_TEX)
	sg.AlwaysOnTop = false
	sg.Parent = quad

	local label = Instance.new("ImageLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Parent = sg
	-- Assigned LAST, once the label is parented and the surface is sized. Set before that
	-- and the surface never paints it -- the instance tree looks perfect and nothing draws.
	label.ImageContent = Content.fromObject(img)

	table.insert(_rings, quad)
end

function CoverageOverlay.refresh()
	local kind = _kind
	if not kind then return end
	local list = stations(kind)
	local ringColor = CoverageOverlay.ringColor(kind)

	for _, r in _rings do r:Destroy() end
	table.clear(_rings)
	if _style == "grey" then
		if kind == "Power" then
			buildPowerRegion(list, ringColor)
		else
			for _, s in list do
				local disc = CoverageOverlay.makeDisc(s.radius, ringColor)
				CoverageOverlay.discTo(disc, s.pos)
				table.insert(_rings, disc)
			end
		end
	end

	-- The power view greys nothing: every building sits inside its own supply area, so
	-- "covered" would be true for all of them and mean nothing. Whether a building is
	-- actually LIT depends on the grid, which is not replicated per building.
	-- ponytail: a Powered attribute stamped by PowerService is the upgrade path.
	local folder = if kind == "Power" then nil else cityFolder("ZonedBuildings")
	if folder then
		for _, m in folder:GetChildren() do
			if not m:IsA("Model") then continue end
			local covered = coveredAt(list, m:GetPivot().Position)
			if _style == "grey" then
				queueTint(m, if covered then "none" else "grey", if covered then nil else UNCOVERED_GREY, false)
			else
				queueTint(m, if covered then "hot" else "cold", if covered then HEAT_COVERED else HEAT_UNCOVERED, true)
			end
		end
	end

	tintRoads(if _style == "heat" then list else nil)

	-- Pieces whose mesh bake failed stay part-rendered; tint the source models too.
	-- (For baked pieces the source parts are locally hidden, so this is invisible.)
	if _style == "heat" then
		local roads = cityFolder("Roads")
		if roads then
			local meshes = Workspace:FindFirstChild("_RoadMeshes")
			for _, m in roads:GetChildren() do
				if not m:IsA("Model") then continue end
				-- Baked pieces render via the mesh; their source parts are locally
				-- invisible, so tinting them would be pure wasted work.
				if meshes and meshes:FindFirstChild(m.Name .. "_Mesh") then continue end
				local covered = coveredAt(list, m:GetPivot().Position)
				queueTint(m, if covered then "hot" else "cold", if covered then HEAT_COVERED else HEAT_UNCOVERED, true)
			end
		end
	end

	-- Drop saved entries for buildings demolished while tinted.
	for model, saved in _savedColors do
		if not model.Parent then
			for part in saved do _origFlat[part] = nil end
			_savedColors[model] = nil
			_tintApplied[model] = nil
		end
	end
end

-- == The colourless info view ==================================================
-- The water view drains the whole city of colour so the mains are the only thing left with
-- any. There is no post-processing route to this: a ColorCorrectionEffect has no way to
-- exempt an object from itself, so everything the player is meant to still SEE in colour
-- would go grey with the rest. It is a bulk recolour instead, riding the same budgeted
-- pump and the same saved-colour restore as every other tint in this file.
local WASH_TAG  = "wash"
local WASH_GREY = Color3.fromRGB(124, 126, 130)
local WASH_FOLDERS = { "ZonedBuildings", "Roads", "Schools", "EmergencyServices", "Nature", "PowerLines", "Creations", "Transit" }
-- Terrain is most of the screen, so leaving it green undoes the whole effect.
-- SetMaterialColor is a LOCAL change -- it does not replicate -- and the saved originals
-- put it back exactly.
local WASH_TERRAIN = {
	Enum.Material.Grass, Enum.Material.LeafyGrass, Enum.Material.Ground, Enum.Material.Mud,
	Enum.Material.Sand, Enum.Material.Rock, Enum.Material.Slate, Enum.Material.Basalt,
	Enum.Material.Limestone, Enum.Material.Sandstone, Enum.Material.Asphalt,
	Enum.Material.Concrete, Enum.Material.Cobblestone, Enum.Material.Snow,
}
local _washed = false
local _terrainSaved: { [Enum.Material]: Color3 } = {}
local _waterSaved: Color3? = nil

local function greyOf(c: Color3): Color3
	local l = 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
	return Color3.new(l, l, l)
end

-- What keeps its colour: the towers, the plants and the mains. Read off the attribute the
-- server already stamps, so nothing here has to know the catalog.
local function isWaterThing(m: Model): boolean
	local k = m:GetAttribute("ServiceKind")
	return k == "Water" or k == "Sewage" or k == "Pipe"
end

function CoverageOverlay.washCity(on: boolean)
	if on == _washed then return end
	_washed = on

	for _, name in WASH_FOLDERS do
		local f = cityFolder(name)
		if not f then continue end
		for _, m in f:GetChildren() do
			if not m:IsA("Model") then continue end
			if on and isWaterThing(m) then continue end
			queueTint(m, if on then WASH_TAG else "none", if on then WASH_GREY else nil, true)
		end
	end

	local meshes = Workspace:FindFirstChild("_RoadMeshes")
	if meshes then
		for _, mp in meshes:GetChildren() do
			if mp:IsA("MeshPart") then fadeColor(mp, if on then WASH_GREY else ROAD_NEUTRAL) end
		end
	end

	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if not terrain then return end
	if on then
		table.clear(_terrainSaved)
		for _, mat in WASH_TERRAIN do
			local ok, c = pcall(terrain.GetMaterialColor, terrain, mat)
			if ok and typeof(c) == "Color3" then
				_terrainSaved[mat] = c
				pcall(terrain.SetMaterialColor, terrain, mat, greyOf(c))
			end
		end
		_waterSaved = terrain.WaterColor
		terrain.WaterColor = greyOf(terrain.WaterColor)
	else
		for mat, c in _terrainSaved do
			pcall(terrain.SetMaterialColor, terrain, mat, c)
		end
		table.clear(_terrainSaved)
		if _waterSaved then terrain.WaterColor = _waterSaved; _waterSaved = nil end
	end
end

-- Cheap per-frame hook: re-scans on a slow timer while active.
function CoverageOverlay.maybeRefresh()
	if not _kind then return end
	if os.clock() < _nextRefreshAt then return end
	_nextRefreshAt = os.clock() + REFRESH
	CoverageOverlay.refresh()
end

function CoverageOverlay.show(kind: string, style: Style)
	if _kind == kind and _style == style then return end
	_kind = kind
	_style = style
	-- Queue a restore for everything painted; refresh() immediately overwrites the
	-- jobs for models the new mode still tints, so each part repaints at most once.
	for model in _savedColors do queueTint(model, "none", nil, false) end
	_nextRefreshAt = os.clock() + REFRESH
	CoverageOverlay.refresh()
end

function CoverageOverlay.clear()
	_regionImage = nil
	if not _kind then return end
	_kind = nil
	table.clear(_pending)
	_pendingCount = 0
	for model in _savedColors do queueTint(model, "none", nil, false) end
	for _, r in _rings do r:Destroy() end
	table.clear(_rings)
	tintRoads(nil)
end

-- True colour of a part while an overlay tint may be applied. RoadMeshView bakes
-- from this so a heat-tinted road never gets frozen into a mesh's vertex colours.
function CoverageOverlay.originalColor(p: BasePart): Color3
	return _origFlat[p] or p.Color
end

function CoverageOverlay.activeKind(): string?
	return _kind
end

function CoverageOverlay.activeStyle(): string
	return _style
end

return CoverageOverlay
