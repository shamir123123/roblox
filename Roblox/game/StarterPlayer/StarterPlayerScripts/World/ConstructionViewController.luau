--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameSpeed = require(ReplicatedStorage:WaitForChild("GameSpeed"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local ConstructionViewController = {}

local _started = false
local _root: Folder? = nil
local _craneTemplate: Model? = nil

type SiteData = {
	model: Model,
	conn: RBXScriptConnection?,
}

local _sites: { [string]: SiteData } = {}
local _conns: { RBXScriptConnection } = {}

local CRANE_NATURAL_HEIGHT = 74.5
-- The slew swings back and forth over the plot instead of spinning full circles.
local SWING_AMP = 0.55 -- radians (~31 deg) each side of the building-facing aim
local SLEW_W    = 0.5  -- slew oscillation speed
local TROLLEY_W = 0.7  -- trolley in/out speed
local HOOK_W    = 1.1  -- hook raise/lower speed

-- Per-building colour variety for the rising frame (light->dark by storey).
local CONSTRUCTION_PALETTES: { { Color3 } } = {
	{ Color3.fromRGB(168, 170, 172), Color3.fromRGB(150, 154, 156), Color3.fromRGB(132, 138, 140), Color3.fromRGB(96, 100, 106) },  -- concrete
	{ Color3.fromRGB(188, 150, 112), Color3.fromRGB(170, 132, 96),  Color3.fromRGB(150, 114, 80),  Color3.fromRGB(120, 88, 60) },   -- brick / tan
	{ Color3.fromRGB(130, 150, 170), Color3.fromRGB(112, 134, 156), Color3.fromRGB(96, 118, 140),  Color3.fromRGB(70, 92, 114) },   -- blue steel
	{ Color3.fromRGB(150, 164, 150), Color3.fromRGB(132, 148, 132), Color3.fromRGB(114, 132, 114), Color3.fromRGB(84, 104, 84) },   -- green glass
	{ Color3.fromRGB(180, 172, 150), Color3.fromRGB(164, 156, 132), Color3.fromRGB(146, 138, 114), Color3.fromRGB(112, 104, 82) },  -- sandstone
}

local function ensureRoot(): Folder
	if _root and _root.Parent then
		return _root
	end
	local root = UiScratch.folder("LocalConstruction")
	_root = root
	return root
end

local function getCraneTemplate(): Model?
	if _craneTemplate then return _craneTemplate end
	local city = ReplicatedStorage:FindFirstChild("City")
	if not city then return nil end
	local tmpl = city:FindFirstChild("CraneTemplate")
	if tmpl and tmpl:IsA("Model") then
		_craneTemplate = tmpl
		return tmpl
	end
	return nil
end

local function clearSite(id: string)
	local site = _sites[id]
	if site then
		if site.conn then
			site.conn:Disconnect()
		end
		site.model:Destroy()
		_sites[id] = nil
	end
end

local function makePart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = material
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Construction is animated by a GameSpeed-scaled progress clock (see startSite), not
-- TweenService -- tweens cannot pause or run at 3x. Each rising part is a Seg driven by
-- normalised build progress; easeOutQuad / easeOutBack are the curves the old tweens used.
type Seg = {
	part: BasePart,
	t0: number,
	t1: number,
	fromSize: Vector3,
	toSize: Vector3,
	fromCF: CFrame,
	toCF: CFrame,
	fromT: number,
	toT: number,
	ease: (number) -> number,
}

local function easeOutQuad(t: number): number
	local inv = 1 - t
	return 1 - inv * inv
end

local function easeOutBack(t: number): number
	local c1 = 1.70158
	local m = t - 1
	return 1 + (c1 + 1) * m * m * m + c1 * m * m
end

local function startSite(payload: any)
	if typeof(payload) ~= "table" then return end
	if typeof(payload.id) ~= "string" or typeof(payload.pivot) ~= "CFrame" then return end

	local id = payload.id
	-- A re-sync (e.g. late-join replay) or a rebuild reusing the same blueprint id can
	-- deliver a second "start" while this id's crane is still animating. Without clearing
	-- it first, _sites[id] is overwritten below and the previous model + its Heartbeat
	-- connection leak (orphaned, never destroyed/disconnected). Clear the slot first.
	clearSite(id)
	local pivot = payload.pivot :: CFrame
	local width = math.clamp(tonumber(payload.width) or 2, 1, 8)
	local depth = math.clamp(tonumber(payload.depth) or 2, 1, 8)
	local duration = math.max(1, tonumber(payload.duration) or 7)
	local lotSize = tonumber(payload.lotSize) or 6

	-- Seed an RNG from the blueprint id so each building looks/moves distinct
	-- but stays stable across the construction.
	local seed = 0
	for i = 1, #id do
		seed = (seed * 31 + string.byte(id, i)) % 2147483647
	end
	local rng = Random.new(seed)

	local palette = CONSTRUCTION_PALETTES[rng:NextInteger(1, #CONSTRUCTION_PALETTES)]
	local phase    = rng:NextNumber(0, 2 * math.pi)
	local swingAmp = SWING_AMP * rng:NextNumber(0.6, 1.15)
	local slewW    = SLEW_W    * rng:NextNumber(0.75, 1.35)
	local trolleyW = TROLLEY_W * rng:NextNumber(0.75, 1.35)
	local hookW    = HOOK_W    * rng:NextNumber(0.75, 1.35)

	clearSite(id)

	local model = Instance.new("Model")
	model.Name = "Construction_" .. id
	model.Parent = ensureRoot()

	local footW = width * lotSize * 0.95
	local footD = depth * lotSize * 0.95
	local buildHeight = math.clamp((width + depth) * 1.45, 7, 14)
	local floorH = buildHeight / 3
	local stageDur = math.max(0.25, duration * 0.12)

	local dirt = makePart(model, "ConstructionLot", Vector3.new(footW * 1.12, 0.08, footD * 1.12), pivot * CFrame.new(0, 0.04, 0), Color3.fromRGB(166, 132, 82), Enum.Material.Ground)
	dirt.Transparency = 0.08

	-- Every rising part registers a Seg; one GameSpeed-scaled clock at the end of
	-- startSite drives them all (so the build holds at 0 and runs at 2x/3x).
	local anims: { Seg } = {}
	local lenFrac = stageDur / duration

	local pad = makePart(model, "BuildPad", Vector3.new(0.4, 0.18, 0.4), pivot * CFrame.new(0, 0.12, 0), Color3.fromRGB(222, 178, 78), Enum.Material.Concrete)
	table.insert(anims, {
		part = pad, t0 = 0, t1 = 0.08,
		fromSize = pad.Size, toSize = Vector3.new(footW, 0.28, footD),
		fromCF = pad.CFrame, toCF = pivot * CFrame.new(0, 0.14, 0),
		fromT = 0, toT = 0, ease = easeOutQuad,
	})

	local hw = footW * 0.42
	local hd = footD * 0.42
	for i, offset in {
		Vector3.new(-hw, 0, -hd),
		Vector3.new(hw, 0, -hd),
		Vector3.new(-hw, 0, hd),
		Vector3.new(hw, 0, hd),
	} do
		local post = makePart(model, "BuildPost" .. i, Vector3.new(0.28, 0.2, 0.28), pivot * CFrame.new(offset.X, 0.1, offset.Z), Color3.fromRGB(72, 74, 82), Enum.Material.Metal)
		local pt0 = 0.05 + i * 0.015
		table.insert(anims, {
			part = post, t0 = pt0, t1 = pt0 + lenFrac,
			fromSize = post.Size, toSize = Vector3.new(0.28, buildHeight, 0.28),
			fromCF = post.CFrame, toCF = pivot * CFrame.new(offset.X, buildHeight * 0.5, offset.Z),
			fromT = 0, toT = 0, ease = easeOutBack,
		})
	end

	local function stageBlock(name: string, startScale: number, y: number, h: number, inset: number, color: Color3)
		local block = makePart(model, name, Vector3.new(math.max(1, footW - inset), 0.12, math.max(1, footD - inset)), pivot * CFrame.new(0, 0.08, 0), color, Enum.Material.Concrete)
		block.Transparency = 0.22
		table.insert(anims, {
			part = block, t0 = startScale, t1 = startScale + lenFrac,
			fromSize = block.Size, toSize = Vector3.new(math.max(1, footW - inset), h, math.max(1, footD - inset)),
			fromCF = block.CFrame, toCF = pivot * CFrame.new(0, y, 0),
			fromT = 0.22, toT = 0.04, ease = easeOutQuad,
		})
	end

	stageBlock("FrameLevel1", 0.18, floorH * 0.5, floorH, 3.2, palette[1])
	stageBlock("FrameLevel2", 0.38, floorH * 1.5, floorH, 4.2, palette[2])
	stageBlock("FrameLevel3", 0.58, floorH * 2.5, floorH, 5.2, palette[3])
	stageBlock("RoofStage", 0.76, buildHeight + 0.32, 0.65, 2.4, palette[4])

	local mastHeight = math.max(10, buildHeight + 8)
	-- Crane stands at a random corner of the plot so neighbours don't line up.
	local cornerX = if rng:NextInteger(0, 1) == 0 then 1 else -1
	local cornerZ = if rng:NextInteger(0, 1) == 0 then 1 else -1
	local craneBase = pivot * CFrame.new(cornerX * (hw + mastHeight * 0.35), 0, cornerZ * (hd + mastHeight * 0.35))

	local craneStep: ((sdt: number) -> ())? = nil
	local template = getCraneTemplate()
	if template then
		local crane = template:Clone()
		crane.Name = "Crane"

		local targetScale = math.clamp(mastHeight * 2.5 / CRANE_NATURAL_HEIGHT * rng:NextNumber(0.85, 1.08), 0.3, 0.9)
		crane:ScaleTo(targetScale)

		for _, desc in crane:GetDescendants() do
			if desc:IsA("BasePart") then
				desc.Anchored = true
				desc.CanCollide = false
				desc.CanTouch = false
				desc.CanQuery = false
				desc.CastShadow = false
			end
		end

		crane:PivotTo(craneBase)
		crane.Parent = model

		local slewUnit = crane:FindFirstChild("SlewingUnit")
		local mainJib  = crane:FindFirstChild("MainJib")
		if slewUnit and slewUnit:IsA("Model") and mainJib and mainJib:IsA("Model") then
			local slewCenter = CFrame.new(slewUnit:GetPivot().Position)

			-- Aim the jib at the building centre, then swing around that aim.
			local jibDir = mainJib:GetPivot().Position - slewCenter.Position
			jibDir = Vector3.new(jibDir.X, 0, jibDir.Z)
			local want = pivot.Position - slewCenter.Position
			want = Vector3.new(want.X, 0, want.Z)

			local baseAngle = 0
			if jibDir.Magnitude > 1e-3 and want.Magnitude > 1e-3 then
				jibDir, want = jibDir.Unit, want.Unit
				baseAngle = math.atan2(jibDir:Cross(want).Y, jibDir:Dot(want))
			end

			-- Sub-assemblies that turn rigidly with the slew.
			local rotModels: { Model } = {}
			local rotRel: { CFrame } = {}
			for _, name in { "SlewingUnit", "Apex", "MainJib", "CounterJib", "Cables" } do
				local sub = crane:FindFirstChild(name)
				if sub and sub:IsA("Model") then
					table.insert(rotModels, sub)
					table.insert(rotRel, slewCenter:ToObjectSpace(sub:GetPivot()))
				end
			end

			-- Hoist = trolley + cables + hook. Trolley slides along the jib;
			-- the hook raises/lowers and the cables stretch to follow it.
			local hoist = crane:FindFirstChild("Hoist")
			local hoistRel = if hoist then slewCenter:ToObjectSpace(hoist:GetPivot()) else nil
			-- Trolley slides along the jib's own horizontal direction, not world Z.
			local radialDir = Vector3.zAxis
			local radialAmp = 0
			if hoistRel then
				local flat = Vector3.new(hoistRel.Position.X, 0, hoistRel.Position.Z)
				if flat.Magnitude > 1e-3 then
					radialDir = flat.Unit
					radialAmp = flat.Magnitude * 0.4
				end
			end
			-- Bob the whole Hoist (trolley + cables + hook) as one rigid unit so
			-- nothing detaches; small range keeps the trolley on the jib.
			local bobAmp = mastHeight * 0.10

			local t = 0
			craneStep = function(sdt: number)
				if not crane.Parent then return end
				t += sdt
				local s = t + phase

				local slewAngle = baseAngle + swingAmp * math.sin(s * slewW)
				local rotated = slewCenter * CFrame.Angles(0, slewAngle, 0)

				for i, mdl in rotModels do
					if mdl.Parent then mdl:PivotTo(rotated * rotRel[i]) end
				end

				if hoist and hoist.Parent and hoistRel then
					local slide = radialAmp * math.sin(s * trolleyW)
					local bob = bobAmp * (0.5 - 0.5 * math.cos(s * hookW))
					local pos = hoistRel.Position + radialDir * slide - Vector3.new(0, bob, 0)
					local hr = CFrame.new(pos) * (hoistRel - hoistRel.Position)
					hoist:PivotTo(rotated * hr)
				end
			end
		end
	end

	-- One GameSpeed-scaled clock drives the whole build -- rising parts AND the crane.
	-- elapsed advances by dt*GameSpeed, so the build holds on pause and runs at 2x/3x,
	-- then the site clears after duration + 1s of grace, all in scaled time.
	local elapsed = 0
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function(dt: number)
		if not model.Parent then
			if conn then conn:Disconnect() end
			return
		end
		local sdt = GameSpeed.scaled(dt)
		elapsed += sdt
		local p = elapsed / duration

		for _, a in anims do
			if a.part.Parent then
				local lp = if a.t1 > a.t0 then math.clamp((p - a.t0) / (a.t1 - a.t0), 0, 1) else 1
				local e = a.ease(lp)
				a.part.Size = a.fromSize:Lerp(a.toSize, e)
				a.part.CFrame = a.fromCF:Lerp(a.toCF, e)
				if a.fromT ~= a.toT then
					a.part.Transparency = a.fromT + (a.toT - a.fromT) * e
				end
			end
		end

		if craneStep then
			craneStep(sdt)
		end

		if elapsed >= duration + 1 then
			clearSite(id)
		end
	end)

	_sites[id] = { model = model, conn = conn }
end

-- The persistent "nest": a scaffold ring + foundation the player sees the moment a lot is
-- claimed. Unlike startSite it has NO finish timer -- it holds until the server sends a
-- "start" (demand arrived -> crane build, which clearSite-replaces it) or a "finish".
local function startNest(payload: any)
	if typeof(payload) ~= "table" then return end
	if typeof(payload.id) ~= "string" or typeof(payload.pivot) ~= "CFrame" then return end

	local id = payload.id
	clearSite(id)
	local pivot = payload.pivot :: CFrame
	local width = math.clamp(tonumber(payload.width) or 2, 1, 8)
	local depth = math.clamp(tonumber(payload.depth) or 2, 1, 8)
	local lotSize = tonumber(payload.lotSize) or 6

	local footW = width * lotSize * 0.95
	local footD = depth * lotSize * 0.95
	local postH = math.clamp((width + depth) * 0.9, 5, 9)

	local model = Instance.new("Model")
	model.Name = "Nest_" .. id
	model.Parent = ensureRoot()

	local SCAFFOLD = Color3.fromRGB(216, 172, 72) -- scaffold yellow

	makePart(model, "NestLot", Vector3.new(footW * 1.1, 0.3, footD * 1.1), pivot * CFrame.new(0, 0.15, 0), Color3.fromRGB(150, 120, 78), Enum.Material.Ground)
	local slab = makePart(model, "NestFoundation", Vector3.new(footW * 0.82, 0.5, footD * 0.82), pivot * CFrame.new(0, 0.3, 0), Color3.fromRGB(150, 150, 154), Enum.Material.Concrete)
	slab.Transparency = 0.05

	local hw = footW * 0.46
	local hd = footD * 0.46
	for i, c in { Vector3.new(-hw, 0, -hd), Vector3.new(hw, 0, -hd), Vector3.new(-hw, 0, hd), Vector3.new(hw, 0, hd) } do
		makePart(model, "NestPost" .. i, Vector3.new(0.5, postH, 0.5), pivot * CFrame.new(c.X, postH * 0.5, c.Z), SCAFFOLD, Enum.Material.Metal)
	end
	-- Top rails between the four posts (the ring) + a front plank.
	makePart(model, "NestRailF", Vector3.new(hw * 2, 0.35, 0.35), pivot * CFrame.new(0, postH, -hd), SCAFFOLD, Enum.Material.Metal)
	makePart(model, "NestRailB", Vector3.new(hw * 2, 0.35, 0.35), pivot * CFrame.new(0, postH, hd), SCAFFOLD, Enum.Material.Metal)
	makePart(model, "NestRailL", Vector3.new(0.35, 0.35, hd * 2), pivot * CFrame.new(-hw, postH, 0), SCAFFOLD, Enum.Material.Metal)
	makePart(model, "NestRailR", Vector3.new(0.35, 0.35, hd * 2), pivot * CFrame.new(hw, postH, 0), SCAFFOLD, Enum.Material.Metal)
	makePart(model, "NestPlank", Vector3.new(hw * 2, 0.25, 1.6), pivot * CFrame.new(0, postH * 0.55, -hd), Color3.fromRGB(168, 132, 86), Enum.Material.WoodPlanks)

	-- A hoisted crate that bobs up and down so the site reads as "work in progress".
	local baseCF = pivot * CFrame.new(hw * 0.4, 0, 0)
	local crate = makePart(model, "NestLoad", Vector3.new(2.2, 1.8, 2.2), baseCF * CFrame.new(0, postH * 0.6, 0), Color3.fromRGB(150, 116, 74), Enum.Material.WoodPlanks)
	local cable = makePart(model, "NestCable", Vector3.new(0.12, postH, 0.12), baseCF * CFrame.new(0, postH, 0), Color3.fromRGB(40, 40, 44), Enum.Material.Metal)

	local t = 0
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function(dt: number)
		if not model.Parent then
			if conn then conn:Disconnect() end
			return
		end
		t += GameSpeed.scaled(dt)
		local lift = postH * 0.55 + math.sin(t * 1.2) * postH * 0.18
		crate.CFrame = baseCF * CFrame.new(0, lift, 0)
		local cableLen = math.max(0.4, postH - lift)
		cable.Size = Vector3.new(0.12, cableLen, 0.12)
		cable.CFrame = baseCF * CFrame.new(0, lift + cableLen * 0.5, 0)
	end)

	_sites[id] = { model = model, conn = conn }
end

local function onConstruction(payload: any)
	if typeof(payload) ~= "table" then return end
	if payload.kind == "start" then
		startSite(payload)
	elseif payload.kind == "nest" then
		startNest(payload)
	elseif payload.kind == "finish" and typeof(payload.id) == "string" then
		clearSite(payload.id)
	end
end

function ConstructionViewController.Start()
	if _started then return end
	_started = true

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	table.insert(_conns, Net.SyncConstructionSites.OnClientEvent:Connect(onConstruction))
end

function ConstructionViewController.Cleanup()
	for _, conn in _conns do
		conn:Disconnect()
	end
	table.clear(_conns)
	for id in _sites do
		clearSite(id)
	end
	_craneTemplate = nil
	_started = false
end

return ConstructionViewController
