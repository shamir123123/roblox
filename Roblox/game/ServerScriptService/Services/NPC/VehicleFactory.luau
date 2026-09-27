--!strict
-- VehicleFactory
-- Single source for NPC car models. Clones a premade vehicle out of
-- ServerStorage.Vehicles (which are pre-sized in place to the right scale) and
-- welds every visual part to ONE anchored root placed at the car's BOTTOM-centre.
--
-- The bottom-centre root is deliberate: it makes ride-height placement
-- car-height-independent. A caller drops the root at (road + small clearance) and
-- the wheels land on the road no matter how tall the model is -- so the traffic,
-- commuter and move-in spawners can all share this with no per-model height math.
-- Moving the single anchored root also replicates one CFrame per car (welded parts
-- ride along on each client), the biggest car-bandwidth win.

local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")
local VehicleCatalog = require(game:GetService("ReplicatedStorage").Road.VehicleCatalog)
local VehicleTypes = require(game:GetService("ReplicatedStorage").Road.VehicleTypes)
local RoadConstants = require(game:GetService("ReplicatedStorage").Road.RoadConstants)
local RoadTypeCatalog = require(game:GetService("ReplicatedStorage").Road.RoadTypeCatalog)

local _templates = ServerStorage:WaitForChild("Templates"):WaitForChild("Vehicles")
local VEHICLE_FOLDER = _templates:WaitForChild("CivilianVehicles") :: Folder
-- Bus models live separately so citizens cannot be randomly assigned a bus.
local BUS_FOLDER = _templates:WaitForChild("Transportation"):WaitForChild("Buses"):WaitForChild("Default") :: Folder

local VehicleFactory = {}

-- Clearance between the road and the wheels (the lift callers feed PathFollower).
VehicleFactory.RIDE_CLEARANCE = 0.05

-- Real-world footprint each template stands in for, in metres: { length, width }.
-- The low-poly models are authored stubby AND were all normalised to one width, so
-- WORLD_SCALE alone leaves a pickup exactly as wide as a hatchback. Scaling each model
-- so its footprint AREA matches the real vehicle restores the class differences and the
-- lane fit in a single UNIFORM scale. Deliberately not a per-axis stretch: matching
-- length exactly would ovalise the wheels, which reads worse than a short car.
local FOOTPRINT_M: { [string]: { number } } = table.freeze({
	Car_1_1            = { 4.20, 1.78 },  -- compact hatchback
	LowPolyWagon       = { 4.80, 1.85 },  -- estate
	LowPolyPickupTruck = { 5.70, 2.03 },  -- full-size pickup
	LowPolyVan         = { 5.40, 2.02 },  -- panel van
	LowPolyCoupe       = { 4.50, 1.85 },  -- coupe
	Bus                = { 12.00, 2.55 }, -- 12 m rigid city bus
})

-- Narrowest lane a civilian car is ever routed down. Cars are capped to it so two can
-- pass in an alley without overlapping. The bus is exempt: 2.55 m IS its real width, and
-- one shrunk to clear an alley would read undersized on every other road.
local ALLEY_LANE_M = (RoadTypeCatalog.carriagewayWidth(RoadTypeCatalog.Types.Alley)
	/ RoadTypeCatalog.Types.Alley.laneCount) * RoadConstants.STUD_TO_METER

-- Absolute scale to spawn a template at. Model:ScaleTo is ABSOLUTE against the model's
-- IMPORTED size, so the authored scale has to be carried through explicitly -- a bare
-- ScaleTo(WORLD_SCALE) silently discards the artist's pre-sizing in ServerStorage.
local function spawnScale(model: Model, isBus: boolean): number
	local base = model:GetScale() * RoadConstants.WORLD_SCALE
	local target = FOOTPRINT_M[model.Name]
	if not target then
		return base
	end
	local _, size = model:GetBoundingBox()
	local widthM  = size.X * RoadConstants.WORLD_SCALE * RoadConstants.STUD_TO_METER
	local lengthM = size.Z * RoadConstants.WORLD_SCALE * RoadConstants.STUD_TO_METER
	if widthM <= 0 or lengthM <= 0 then
		return base
	end
	local fit = math.sqrt((target[1] * target[2]) / (lengthM * widthM))
	if not isBus then
		fit = math.min(fit, ALLEY_LANE_M / widthM)
	end
	return base * fit
end

local function getTemplates(): { Model }
	local list: { Model } = {}
	for _, child in VEHICLE_FOLDER:GetChildren() do
		if child:IsA("Model") then
			table.insert(list, child :: Model)
		end
	end
	return list
end

-- name: the model's Name. variant: optional 1-based index selecting a template
-- deterministically (wraps); nil picks at random. templateName: optional exact
-- template name (e.g. "LowPolyVan" for delivery trucks); used when present, else
-- falls back to variant/random.
function VehicleFactory.build(name: string, variant: number?, templateName: string?): Model
	local template: Model? = nil
	if templateName then
		-- The catalog fleet is authored into one folder per CLASS (Commercial / Service /
		-- Emergency / Transportation.Buses.Default) while the five hand-made templates sit in
		-- CivilianVehicles. One recursive lookup covers every folder, so a caller names the
		-- vehicle it wants and never has to know which class folder authored it.
		local found = _templates:FindFirstChild(templateName, true)
		if found and found:IsA("Model") then template = found :: Model end
	end
	if not template then
		local templates = getTemplates()
		assert(#templates > 0, "ServerStorage.Vehicles has no Model templates")
		local idx = variant or math.random(1, #templates)
		template = templates[((idx - 1) % #templates) + 1]
	end
	-- Read off the TEMPLATE: the clone is renamed to the caller's name below, which would
	-- break the FOOTPRINT_M lookup.
	local scale = spawnScale(template :: Model, (template :: Model).Parent == BUS_FOLDER)

	local model = (template :: Model):Clone()
	model.Name = name

	-- Half-size world + real-world footprint fit. Scale BEFORE the bbox/root math below so
	-- the bottom-centre root + hitbox fit the vehicle.
	model:ScaleTo(scale)
	-- the template's own origin (ground centre): HitchOffset is measured from it
	local pivot0 = model:GetPivot()

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored   = true
			d.CanCollide = false
			d.CanTouch   = false
			d.CanQuery   = false
			-- Cars MOVE, so a shadow-casting body part forces a shadow-map recompute every
			-- frame -- ~35 casters per car x dozens of cars is a dominant frame cost. NPC
			-- traffic reads fine without self/cast shadows at city-view distance.
			d.CastShadow = false
		end
	end

	local bboxCF, bboxSize = model:GetBoundingBox()
	local bottomCF = bboxCF * CFrame.new(0, -bboxSize.Y * 0.5, 0)

	-- Anchored root at the bottom centre, keeping the model's facing. Everything
	-- welds to it; only the root is anchored.
	local root = Instance.new("Part")
	root.Name        = "Root"
	root.Size        = Vector3.new(0.2, 0.2, 0.2)
	root.Transparency = 1
	root.Anchored    = true
	root.CanCollide  = false
	root.CanTouch    = false
	root.CanQuery    = false
	root.CastShadow  = false
	root.CFrame      = bottomCF
	root.Parent      = model
	model.PrimaryPart = root
	model.WorldPivot  = bottomCF

	-- Full-car click hitbox (selection raycasts), welded to the root.
	local hitbox = Instance.new("Part")
	hitbox.Name        = "Hitbox"
	hitbox.Size        = bboxSize
	hitbox.Anchored    = true
	hitbox.CanCollide  = false
	hitbox.CanTouch    = false
	hitbox.CanQuery    = true
	hitbox.CastShadow  = false
	hitbox.Transparency = 1
	hitbox.CFrame      = bboxCF
	hitbox.Parent      = model

	-- Articulated rigs (semi + trailer, bendy bus): the rear unit's parts (attribute Trailer)
	-- weld to a TrailerRoot that hangs off the Root by ONE Weld at the hitch. The server moves
	-- the rig as a single rigid piece, so its bounding box and spacing never change; each client
	-- swings that weld's C0 so the rear unit trails the front one (NPCDriverView).
	local trailerRoot: BasePart? = nil
	local hitch = model:GetAttribute("HitchOffset")
	if typeof(hitch) == "Vector3" then
		local hitchCF = CFrame.new((pivot0 * CFrame.new(hitch * scale)).Position) * bottomCF.Rotation
		local tr = Instance.new("Part")
		tr.Name        = "TrailerRoot"
		tr.Size        = Vector3.new(0.2, 0.2, 0.2)
		tr.Transparency = 1
		tr.Anchored    = false
		tr.CanCollide  = false
		tr.CanTouch    = false
		tr.CanQuery    = false
		tr.CastShadow  = false
		tr.CFrame      = hitchCF
		tr.Parent      = model
		local hinge = Instance.new("Weld")
		hinge.Name   = "HitchWeld"
		hinge.Part0  = root
		hinge.Part1  = tr
		hinge.C0     = root.CFrame:ToObjectSpace(hitchCF)
		hinge.Parent = tr
		trailerRoot = tr
		model:SetAttribute("TrailerAxle", ((model:GetAttribute("TrailerAxle") :: number?) or 0) * scale)
	end

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= root and d ~= trailerRoot then
			local base: BasePart = if trailerRoot and d:GetAttribute("Trailer") then trailerRoot else root
			if d:GetAttribute("Wheel") then
				-- A Weld, not a WeldConstraint: its C0 is the handle NPCDriverView turns to spin
				-- the wheel locally, with nothing replicated.
				local weld = Instance.new("Weld")
				weld.Name   = "WheelWeld"
				weld.Part0  = base
				weld.Part1  = d
				weld.C0     = base.CFrame:ToObjectSpace(d.CFrame)
				weld.Parent = d
			else
				local weld = Instance.new("WeldConstraint")
				weld.Part0  = base
				weld.Part1  = d
				weld.Parent = base
			end
			d.Anchored  = false
		end
	end

	-- Say what this vehicle IS. NPCDriverService reads the class off this tag
	-- (VehicleTypes.classOf) to pick lane rules and signal behaviour, and an untagged model
	-- reads as a car -- which is how delivery trucks came to be driven, and routed, as cars.
	-- Cars are left untagged: that is already the default, and adding a second class tag to a
	-- model another factory has tagged (bus, emergency) would shadow its real class.
	local entry = VehicleCatalog.get((template :: Model).Name)
	if entry and entry.class ~= VehicleTypes.Car then
		CollectionService:AddTag(model, VehicleTypes.tagFor(entry.class))
	end

	-- Mesh-kit vehicles (blender/vehicle_kit.py) carry one TintMask texture set: the spawn
	-- colour is the SurfaceAppearance tint, so one mesh drives in every catalog colour.
	if model:GetAttribute("MeshKit") then
		local paint = if entry then VehicleCatalog.paintFor(entry, math.random()) else Color3.new(1, 1, 1)
		for _, d in model:GetDescendants() do
			if d:IsA("SurfaceAppearance") then
				d.Color = paint
			end
		end
		-- the client picks full mesh vs LOD by screen-space error; hand it the error at spawn scale
		model:SetAttribute("LodError", (model:GetAttribute("LodError") or 0) * scale)
		-- stream the car as one unit: a body that arrives before its wheels is a visible glitch
		model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	end

	model:SetAttribute("NPCHeightOffset", VehicleFactory.RIDE_CLEARANCE)
	return model
end

return VehicleFactory
