--!strict
-- CitizenModel
-- Pure builder for the stylized low-poly people that populate the city: commuter
-- pedestrians (NPCWalkingService) and the idle residents/workers standing at buildings
-- (CitizenPresenceView). No lifecycle, no state, no side effects on require -- just
-- `build(opts)` -> a fresh Model whose PrimaryPart is an anchored root the whole figure
-- welds to, so moving the root (or PivotTo) moves the whole person.
--
-- A figure is 5 parts (invisible root, torso, head, two legs) to keep the part budget low
-- when hundreds are on screen at once. Adults are full height; kids scale down. Shirt
-- colour reads gender at a glance (blue-ish male / pink-ish female), matching the roster
-- UI's gender glyphs. The root centre sits at the figure's FEET, so placing the root on a
-- ground surface stands the person on it -- the old capsule sank because it was centred.

local RoadConstants = require(game:GetService("ReplicatedStorage").Road.RoadConstants)

local CitizenModel = {}

export type Appearance = {
	gender: string,
	kind: string,
	seed: number?,
}

local SKIN_TONES = table.freeze({
	Color3.fromRGB(244, 213, 184),
	Color3.fromRGB(225, 184, 147),
	Color3.fromRGB(188, 137, 99),
	Color3.fromRGB(126, 82, 58),
	Color3.fromRGB(82, 53, 42),
})
local SHIRTS = table.freeze({
	Color3.fromRGB(67, 143, 202),
	Color3.fromRGB(212, 104, 121),
	Color3.fromRGB(76, 165, 118),
	Color3.fromRGB(224, 166, 70),
	Color3.fromRGB(126, 104, 180),
	Color3.fromRGB(67, 75, 88),
})
local PANTS = table.freeze({
	Color3.fromRGB(45, 52, 66),
	Color3.fromRGB(72, 74, 79),
	Color3.fromRGB(51, 74, 96),
	Color3.fromRGB(91, 68, 54),
})
local HAIR = table.freeze({
	Color3.fromRGB(43, 31, 25),
	Color3.fromRGB(89, 57, 35),
	Color3.fromRGB(177, 132, 71),
	Color3.fromRGB(38, 38, 42),
	Color3.fromRGB(132, 64, 50),
})
local FEET_Y = 0
-- An adult is 1.75 m in the world's metres; the figure below is built legs + torso + head
-- = 0.88 + 1.02 + 0.64 studs tall at s = 1.
local WORLD_FIT = 1.75 / RoadConstants.STUD_TO_METER / (0.88 + 1.02 + 0.64)

local function pick<T>(items: { T }, seed: number, salt: number): T
	return items[((seed * 37 + salt * 101) % #items) + 1]
end

local function bodyPart(name: string, size: Vector3, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Shape = shape or Enum.PartType.Block
	p.Anchored = false
	p.Massless = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function weld(child: BasePart, root: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = child
	w.Parent = root
end

local function attach(model: Model, root: BasePart, part: BasePart, cf: CFrame)
	part.CFrame = cf
	part.Parent = model
	weld(part, root)
end

function CitizenModel.build(opts: Appearance): Model
	local seed = math.max(1, math.floor(tonumber(opts.seed) or 1))
	local kid = opts.kind == "kid"
	local heightVariation = 0.94 + ((seed * 17) % 13) / 100
	local s = (if kid then 0.64 else 1) * heightVariation
	local skin = pick(SKIN_TONES, seed, 1)
	local shirt = pick(SHIRTS, seed, if opts.gender == "F" then 7 else 3)
	local pants = pick(PANTS, seed, 11)
	local hair = pick(HAIR, seed, 17)

	local model = Instance.new("Model")
	model.Name = "Citizen"
	model:SetAttribute("AppearanceSeed", seed)

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(0.7, 0.7, 0.7)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Parent = model
	model.PrimaryPart = root

	local legH = 0.88 * s
	local torsoH = 1.02 * s
	local torsoW = 1.02 * s
	local headSz = 0.64 * s
	local armW = 0.25 * s
	local armH = 0.84 * s
	local base = root.CFrame

	attach(model, root,
		bodyPart("Torso", Vector3.new(torsoW, torsoH, 0.58 * s), shirt, Enum.Material.Fabric),
		base * CFrame.new(0, FEET_Y + legH + torsoH * 0.5, 0))

	local headY = FEET_Y + legH + torsoH + headSz * 0.5
	attach(model, root,
		bodyPart("Head", Vector3.new(headSz, headSz, headSz), skin, nil, Enum.PartType.Ball),
		base * CFrame.new(0, headY, 0))

	local hairPart = bodyPart("Hair", Vector3.new(headSz * 0.82, headSz * 0.3, headSz * 0.78), hair)
	attach(model, root, hairPart, base * CFrame.new(0, headY + headSz * 0.34, 0.02 * s))

	for index, sx in { -1, 1 } do
		attach(model, root,
			bodyPart(if index == 1 then "LeftLeg" else "RightLeg", Vector3.new(0.4 * s, legH, 0.48 * s), pants, Enum.Material.Fabric),
			base * CFrame.new(sx * 0.27 * s, FEET_Y + legH * 0.5, 0))
		attach(model, root,
			bodyPart(if index == 1 then "LeftArm" else "RightArm", Vector3.new(armW, armH, 0.34 * s), shirt, Enum.Material.Fabric),
			base * CFrame.new(sx * (torsoW * 0.5 + armW * 0.62), FEET_Y + legH + torsoH * 0.58, 0))
	end

	-- Root is at the feet, so the figure still stands on the ground.
	model:ScaleTo(WORLD_FIT)

	return model
end

return CitizenModel
