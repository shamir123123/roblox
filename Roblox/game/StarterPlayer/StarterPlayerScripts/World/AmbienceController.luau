--!strict
-- AmbienceController
-- Camera-driven ambient audio. Every SAMPLE_INTERVAL it senses what is actually around the
-- camera and crossfades one looping bed per category toward its target volume.
--
-- Every bed is tied to something you can SEE from here, never to "the map has one somewhere":
--   Sea     -- terrain water found by a small grid of downward rays around the camera
--   Traffic -- NPCDriver cars within earshot
--   Chatter -- NPCWalker pedestrians close by
--   Birds   -- houses or trees close by
-- Zooming out fades everything: the city reads as a map, not a place. Music lives in
-- RadioController (menu theme + in-game stations).

local CollectionService = game:GetService("CollectionService")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local AmbienceController = {}

local SAMPLE_INTERVAL = 0.8
local SENSE_RADIUS = 110       -- earshot: half-extent of the overlap box / NPC radius
local NEAR_RADIUS = 70         -- "right next to it": houses, pedestrians
local FADE_PER_SEC = 1.5       -- volume units/sec toward target
local HIGH_FADE_START = 150    -- camera height where ambience starts fading
local HIGH_FADE_END = 600      -- fully faded (map overview)

-- What counts as "enough of it here" for a bed at full volume.
local PARTS_FULL = 25          -- scenery parts inside the box
local CARS_FULL = 6            -- NPCDriver cars within SENSE_RADIUS
local WALKERS_FULL = 5         -- NPCWalker pedestrians within NEAR_RADIUS
local WATER_FULL = 0.35        -- fraction of sea probes that hit water

-- Sea probe: a 5x5 grid of rays dropped through the terrain around the camera. Only a
-- Water hit counts, so dry land is silent -- WaterField.isDryAt cannot answer this (it
-- only flags DUG below-sea pits, so it reads "not dry" over every hill on the map, which
-- is why the waves used to play everywhere).
local WATER_STEP = 45          -- stud spacing of the probe grid
local WATER_SPAN = 2           -- grid runs -WATER_SPAN..WATER_SPAN on both axes
local RAY_TOP = 4096           -- above any terrain
local RAY_DROP = Vector3.new(0, -8192, 0)

local AMBIENT: { { name: string, id: number, maxVol: number } } = {
	{ name = "Traffic", id = 9112888010, maxVol = 0.30 }, -- city traffic, honks, moderately busy
	{ name = "Chatter", id = 9112879470, maxVol = 0.22 }, -- street crowd walla, footsteps, no traffic
	{ name = "Birds",   id = 9116969965, maxVol = 0.28 }, -- morning birds + distant dog barks
	{ name = "Sea",     id = 9119676058, maxVol = 0.45 }, -- surf, waves crashing
}


local _sounds: { [string]: Sound } = {}
local _targets: { [string]: number } = {}
local _overlap = OverlapParams.new()
_overlap.FilterType = Enum.RaycastFilterType.Include
_overlap.MaxParts = 40
local _ray = RaycastParams.new()
_ray.FilterType = Enum.RaycastFilterType.Include

local _started = false
local _volMult = 1 -- ambienceVolume * masterVolume, cached for the Heartbeat loop

local function makeLoop(name: string, id: number): Sound
	local s = Instance.new("Sound")
	s.Name = "Ambient_" .. name
	s.SoundId = "rbxassetid://" .. id
	s.Looped = true
	s.Volume = 0
	s.Parent = SoundService
	s:Play()
	return s
end

-- Parts of `folder` inside a box of `radius` around the camera, as a 0..1 density.
local function density(folder: Instance?, center: Vector3, radius: number): number
	if not folder then return 0 end
	_overlap.FilterDescendantsInstances = { folder }
	local parts = Workspace:GetPartBoundsInBox(
		CFrame.new(center),
		Vector3.new(radius * 2, 200, radius * 2),
		_overlap
	)
	return math.min(#parts / PARTS_FULL, 1)
end

-- Tagged NPCs within `radius` of the camera, as a 0..1 density. Distance is 3D, so flying
-- up off a busy street quiets it before the altitude fade even starts.
local function crowd(tag: string, center: Vector3, radius: number, full: number): number
	local n = 0
	for _, inst in CollectionService:GetTagged(tag) do
		local p: Vector3? = nil
		if inst:IsA("BasePart") then
			p = inst.Position
		elseif inst:IsA("Model") then
			local root = inst.PrimaryPart
			if root then p = root.Position end
		end
		if p and (p - center).Magnitude <= radius then
			n += 1
			if n >= full then return 1 end
		end
	end
	return math.min(n / full, 1)
end

-- Fraction of the probe grid standing over terrain water.
local function seaFraction(center: Vector3): number
	local wet, total = 0, 0
	for i = -WATER_SPAN, WATER_SPAN do
		for j = -WATER_SPAN, WATER_SPAN do
			total += 1
			local hit = Workspace:Raycast(
				Vector3.new(center.X + i * WATER_STEP, RAY_TOP, center.Z + j * WATER_STEP),
				RAY_DROP,
				_ray
			)
			if hit and hit.Material == Enum.Material.Water then wet += 1 end
		end
	end
	return math.min((wet / total) / WATER_FULL, 1)
end

local function sample()
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local pos = cam.CFrame.Position

	-- Zoomed way out: the city reads as a map, so every bed fades out of it.
	local high = math.clamp(1 - (pos.Y - HIGH_FADE_START) / (HIGH_FADE_END - HIGH_FADE_START), 0, 1)

	local city = Workspace:FindFirstChild("_City")
	local nature  = if city then city:FindFirstChild("Nature") else nil
	local houses  = if city then city:FindFirstChild("ZonedBuildings") else nil

	-- One bird bed for both sources: houses and woods get the same recording, and layering
	-- two different bird loops over a leafy street just sounds muddy.
	local birds = math.max(density(houses, pos, NEAR_RADIUS), density(nature, pos, SENSE_RADIUS))

	_targets.Traffic = crowd("NPCDriver", pos, SENSE_RADIUS, CARS_FULL) * high
	_targets.Chatter = crowd("NPCWalker", pos, NEAR_RADIUS, WALKERS_FULL) * high
	_targets.Birds   = birds * high
	_targets.Sea     = seaFraction(pos) * high
end

function AmbienceController.Start()
	if _started then return end
	_started = true

	_ray.FilterDescendantsInstances = { Workspace.Terrain }

	for _, def in AMBIENT do
		_sounds[def.name] = makeLoop(def.name, def.id)
		_targets[def.name] = 0
	end

	local function refreshVolMult()
		_volMult = (tonumber(Settings.get("ambienceVolume")) or 1) * (tonumber(Settings.get("masterVolume")) or 1)
	end
	refreshVolMult()
	Settings.onChanged("ambienceVolume", refreshVolMult)
	Settings.onChanged("masterVolume", refreshVolMult)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc >= SAMPLE_INTERVAL then
			acc = 0
			sample()
		end
		-- Smooth every frame toward targets (cheap: 4 sounds).
		for _, def in AMBIENT do
			local s = _sounds[def.name]
			local target = (_targets[def.name] or 0) * def.maxVol * _volMult
			local v = s.Volume
			if math.abs(v - target) > 0.005 then
				s.Volume = v + math.clamp(target - v, -FADE_PER_SEC * dt, FADE_PER_SEC * dt)
			end
		end
	end)
end

return AmbienceController
