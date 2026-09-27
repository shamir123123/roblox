--!strict
-- EmergencyVehicleFactory
-- The city's service fleet: police cars, fire trucks, ambulances and hearses.
-- Police, fire and ambulance use their own mesh-kit models (blender/vehicle_kit.py), which
-- carry their livery, lettering and light bars in the mesh -- nothing is bolted on. The
-- hearse is a civilian wagon in black. A legacy part-built template still gets the old
-- dress-up (repaint + neon light bar + prop), so a missing mesh degrades, not breaks.
-- Every vehicle is tagged Emergency, so the traffic AI already knows to give it
-- priority at signals (VehicleTypes.canPreempt).

local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleFactory = require(ServerScriptService.Services.NPC.VehicleFactory)
local VehicleTypes = require(ReplicatedStorage.Road.VehicleTypes)

local EmergencyVehicleFactory = {}

export type Kind = "Police" | "Fire" | "Ambulance" | "Hearse"

type Spec = {
	template: string,   -- CivilianVehicles model to dress up
	body: Color3,       -- repaints whatever the template's dominant body colour is
	trim: Color3,       -- the stripe / prop colour
	siren: boolean,     -- gets a flashing light bar
	prop: string?,      -- "ladder" | "cross" | nil
}

local SPECS: { [string]: Spec } = {
	Police = {
		template = "EmgPoliceCruiser", body = Color3.fromRGB(28, 34, 46), trim = Color3.fromRGB(238, 240, 244),
		siren = true,
	},
	Fire = {
		template = "EmgFirePumper", body = Color3.fromRGB(178, 34, 30), trim = Color3.fromRGB(238, 238, 240),
		siren = true, prop = "ladder",
	},
	Ambulance = {
		template = "EmgAmbulance", body = Color3.fromRGB(240, 242, 246), trim = Color3.fromRGB(206, 48, 44),
		siren = true, prop = "cross",
	},
	Hearse = {
		template = "CarWagonZeth", body = Color3.fromRGB(20, 20, 24), trim = Color3.fromRGB(120, 122, 128),
		siren = false,
	},
}
for _, spec in SPECS do table.freeze(spec) end
table.freeze(SPECS)

EmergencyVehicleFactory.Order = table.freeze({ "Police", "Fire", "Ambulance", "Hearse" })

-- Coverage domain (ServiceTypes.kind) -> the vehicle that answers a call there.
local KIND_FOR_DOMAIN: { [string]: string } = {
	Police = "Police", Fire = "Fire", Hospital = "Ambulance", Deathcare = "Hearse",
}
table.freeze(KIND_FOR_DOMAIN)

function EmergencyVehicleFactory.kindForDomain(domain: string): string?
	return KIND_FOR_DOMAIN[domain]
end

-- == Livery ====================================================================
local SIREN_TAG_A = "SirenLightA"
local SIREN_TAG_B = "SirenLightB"
local SIREN_PERIOD = 0.3
local COLOR_TOLERANCE = 0.12 -- how close a part must be to the dominant colour to be repainted

local function isDressablePart(d: Instance): boolean
	if not d:IsA("BasePart") then return false end
	if d.Name == "Root" or d.Name == "Hitbox" then return false end
	return d.Transparency <= 0.3
end

-- The template's body colour: the opaque colour covering the most surface area.
-- Derived rather than hardcoded per template, so a re-authored civilian model does
-- not silently stop being repainted.
local function dominantColor(model: Model): Color3?
	local areaByKey: { [string]: number } = {}
	local colorByKey: { [string]: Color3 } = {}
	for _, d in model:GetDescendants() do
		if not isDressablePart(d) then continue end
		local part = d :: BasePart
		local s = part.Size
		local c = part.Color
		local key = ("%d_%d_%d"):format(math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255))
		areaByKey[key] = (areaByKey[key] or 0) + (s.X * s.Y + s.Y * s.Z + s.Z * s.X)
		colorByKey[key] = c
	end
	local bestKey, bestArea = nil, 0
	for key, area in areaByKey do
		if area > bestArea then bestArea = area; bestKey = key end
	end
	return if bestKey then colorByKey[bestKey] else nil
end

local function colorsClose(a: Color3, b: Color3): boolean
	return math.abs(a.R - b.R) <= COLOR_TOLERANCE
		and math.abs(a.G - b.G) <= COLOR_TOLERANCE
		and math.abs(a.B - b.B) <= COLOR_TOLERANCE
end

local function repaint(model: Model, to: Color3)
	local from = dominantColor(model)
	if not from then return end
	for _, d in model:GetDescendants() do
		if not isDressablePart(d) then continue end
		local part = d :: BasePart
		if colorsClose(part.Color, from) then part.Color = to end
	end
end

-- Bolt a part onto the finished vehicle. VehicleFactory welds everything to the
-- anchored Root, so anything added afterwards has to join the same weld chain or
-- it stays behind when the car drives off.
local function attach(model: Model, root: BasePart, name: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.CFrame = root.CFrame * offset
	part.Parent = model
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = root
	return part
end

-- == Build =====================================================================
-- kind: "Police" | "Fire" | "Ambulance" | "Hearse". Returns nil for an unknown kind
-- rather than erroring -- a dispatch with no vehicle is a degraded call, not a crash.
function EmergencyVehicleFactory.build(kind: string, variant: number?): Model?
	local spec = SPECS[kind]
	if not spec then
		warn("[EmergencyVehicleFactory] unknown kind: " .. tostring(kind))
		return nil
	end

	local ok, model = pcall(VehicleFactory.build, kind .. "Vehicle", variant, spec.template)
	if not ok or not model then
		warn("[EmergencyVehicleFactory] build failed for " .. kind .. ": " .. tostring(model))
		return nil
	end

	local root = model.PrimaryPart
	local hitbox = model:FindFirstChild("Hitbox")
	if not root or not hitbox or not hitbox:IsA("BasePart") then return model end
	local size = hitbox.Size

	-- Mesh-kit models already wear their livery; only the hearse (a civilian wagon) needs
	-- its colour, which lives on the SurfaceAppearance tint rather than on part colours.
	if model:GetAttribute("MeshKit") then
		if kind == "Hearse" then
			for _, d in model:GetDescendants() do
				if d:IsA("SurfaceAppearance") then d.Color = spec.body end
			end
		end
		model:SetAttribute("EmergencyKind", kind)
		CollectionService:AddTag(model, VehicleTypes.tagFor(VehicleTypes.Emergency))
		return model
	end

	repaint(model, spec.body)

	-- Root sits at the vehicle's bottom centre (VehicleFactory), so Y offsets here
	-- are heights above the road, not above the model's middle.
	if spec.siren then
		local barY = size.Y + 0.04
		local barW = size.X * 0.34
		local barSize = Vector3.new(barW, size.Y * 0.06, size.Z * 0.07)
		local a = attach(model, root, "SirenA", barSize, CFrame.new(-barW * 0.55, barY, -size.Z * 0.12),
			Color3.fromRGB(220, 40, 40), Enum.Material.Neon)
		local b = attach(model, root, "SirenB", barSize, CFrame.new(barW * 0.55, barY, -size.Z * 0.12),
			Color3.fromRGB(40, 90, 230), Enum.Material.Neon)
		CollectionService:AddTag(a, SIREN_TAG_A)
		CollectionService:AddTag(b, SIREN_TAG_B)
	end

	if spec.prop == "ladder" then
		attach(model, root, "Ladder", Vector3.new(size.X * 0.16, size.Y * 0.05, size.Z * 0.72),
			CFrame.new(0, size.Y * 0.96, size.Z * 0.12), spec.trim, Enum.Material.Metal)
	elseif spec.prop == "cross" then
		-- One cross per flank.
		for _, sx in { -1, 1 } do
			local x = sx * (size.X * 0.5 + 0.02)
			attach(model, root, "CrossV", Vector3.new(0.04, size.Y * 0.26, size.Y * 0.09),
				CFrame.new(x, size.Y * 0.55, 0), spec.trim, Enum.Material.SmoothPlastic)
			attach(model, root, "CrossH", Vector3.new(0.04, size.Y * 0.09, size.Y * 0.26),
				CFrame.new(x, size.Y * 0.55, 0), spec.trim, Enum.Material.SmoothPlastic)
		end
	else
		-- No prop: a trim stripe down each flank keeps the livery readable at city zoom.
		for _, sx in { -1, 1 } do
			attach(model, root, "Stripe", Vector3.new(0.04, size.Y * 0.1, size.Z * 0.62),
				CFrame.new(sx * (size.X * 0.5 + 0.01), size.Y * 0.5, 0), spec.trim, Enum.Material.SmoothPlastic)
		end
	end

	model:SetAttribute("EmergencyKind", kind)
	CollectionService:AddTag(model, VehicleTypes.tagFor(VehicleTypes.Emergency))
	return model
end

-- == Siren flash ===============================================================
-- ONE timer for the whole city: every light bar alternates off the same beat, so
-- adding vehicles costs a table walk every SIREN_PERIOD, not a loop per vehicle.
local _flashing = false

local function setBank(tag: string, lit: boolean)
	for _, inst in CollectionService:GetTagged(tag) do
		if inst:IsA("BasePart") then
			inst.Transparency = if lit then 0 else 0.75
		end
	end
end

function EmergencyVehicleFactory.startSirens()
	if _flashing then return end
	_flashing = true
	task.spawn(function()
		local on = false
		while _flashing do
			task.wait(SIREN_PERIOD)
			on = not on
			local ok, err = pcall(function()
				setBank(SIREN_TAG_A, on)
				setBank(SIREN_TAG_B, not on)
			end)
			if not ok then warn("[EmergencyVehicleFactory] siren flash failed: " .. tostring(err)) end
		end
	end)
end

return EmergencyVehicleFactory
