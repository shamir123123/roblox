--!strict
-- CitizenProxyCache -- one baked mesh standing in for a whole person, welded into the figure
-- so the engine moves it for free.
--
-- WHY THE MOVING SETS NEEDED THEIR OWN CACHE
-- AssetLODView excludes Citizens, NPCWalkers, NPCDrivers, Trucks, Buses and Trains from the
-- ladder, with a stated reason: "a baked stand-in is pinned where it was baked, and these move
-- every frame". That is true of how LODProxyCache PLACES a proxy -- parented to UiScratch at a
-- fixed CFrame -- but not of baking itself. The moving sets were therefore left with exactly
-- one lever: fully drawn, or fully hidden once under a few pixels. Nothing in between, for the
-- most numerous object in a busy city.
--
-- A citizen is eight parts, seven of them visible. At the eighty-walker cap plus the idle
-- residents standing at buildings, that is well over a thousand render objects, every one at
-- full detail right up to the moment it vanishes.
--
-- WHY IT IS WELDED AND NOT DRIVEN
-- A proxy that followed its model from a sweep would stutter at 0.3 s, and one driven per
-- frame would cost Luau this client does not currently spend: the figures move by REPLICATION
-- today, which costs the client nothing. Parenting the proxy into the model and welding it to
-- the root -- the same WeldConstraint the figure already uses for its own seven parts -- hands
-- the movement back to the engine. Seven draw calls become one and the per-frame cost stays
-- exactly zero.
--
-- WHY SO FEW KINDS
-- Keying the way LODProxyCache keys would explode: skin, shirt, pants and hair are each picked
-- from a palette, and CitizenModel jitters every figure's height thirteen ways, so the
-- signature would separate hundreds of near-identical people and every one would pay for its
-- own bake. Instead this bakes ONE canonical figure per shirt colour and scales the clone to
-- the instance's own height. At the range a citizen proxy is ever shown -- where the whole
-- person is under ten pixels -- the discarded variation is not resolvable, which is the same
-- trade the building cache already makes with its four-level colour quantisation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModelBaker = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ModelBaker"))
local CitizenModel = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("CitizenModel"))

local CitizenProxyCache = {}

-- ModelBaker's default MIN_FEATURE_STUDS is 0.6, which is tuned to buildings and would delete
-- a person outright: at WORLD_SCALE 0.5 the torso's longest side is ~0.51 studs and the head's
-- is ~0.32, so every part of the figure falls under it and `collect` returns nothing. The
-- figure is the thing being baked here, not detail on something larger, so the gate has to be
-- small enough to keep all of it.
local MIN_FEATURE = 0.04

-- The shirt palette CitizenModel picks from. Duplicated deliberately rather than reached for
-- through the module: these are the BUCKETS this cache bakes, and they must not silently
-- change count when the figure's palette is edited -- a new shirt colour should fall into the
-- nearest existing bucket until someone chooses to add a bake for it.
local SHIRTS: { Color3 } = table.freeze({
	Color3.fromRGB(67, 143, 202),
	Color3.fromRGB(212, 104, 121),
	Color3.fromRGB(76, 165, 118),
	Color3.fromRGB(224, 166, 70),
	Color3.fromRGB(126, 104, 180),
	Color3.fromRGB(67, 75, 88),
})

-- Parts wearing the shirt colour, so a template can be repainted before baking without
-- rebuilding it. Matches CitizenModel.build.
local SHIRT_PARTS: { [string]: boolean } = table.freeze({
	Torso = true,
	LeftArm = true,
	RightArm = true,
})

type Entry = {
	state: string, -- "pending" | "ready" | "failed"
	mesh: MeshPart?,
	center: Vector3, -- model-local offset from the figure's root to the geometry centre
	height: number, -- the template's own extents Y, so a clone can be scaled to any figure
}

local _cache: { [number]: Entry } = {}
local _baking = false
local _bakes = 0
local _fails = 0
local _attached = 0

local _warned = false
local function warnOnce(message: string)
	if _warned then
		return
	end
	_warned = true
	warn("[CitizenProxyCache] " .. message)
end

-- Nearest shirt bucket by squared RGB distance. A figure whose torso has been recoloured by
-- something else -- a uniform, a hi-vis vest -- still lands somewhere sensible instead of
-- claiming a bucket of its own.
local function bucketFor(color: Color3): number
	local best, bestD = 1, math.huge
	for i, c in SHIRTS do
		local dr, dg, db = c.R - color.R, c.G - color.G, c.B - color.B
		local d = dr * dr + dg * dg + db * db
		if d < bestD then
			best, bestD = i, d
		end
	end
	return best
end

-- The figure's own torso colour. Nil for anything that is not shaped like a citizen, which is
-- how a vehicle or a train falls straight through this cache rather than being mis-baked.
local function shirtOf(model: Model): Color3?
	local torso = model:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		return torso.Color
	end
	return nil
end

-- Built here rather than borrowed from the world: a live citizen is mid-walk, wearing whatever
-- height jitter it drew, and baking one would freeze that instance's proportions into every
-- copy. A fresh figure repainted to the bucket colour is the canonical one.
local function bakeBucket(index: number)
	local entry: Entry = { state = "pending", mesh = nil, center = Vector3.zero, height = 1 }
	_cache[index] = entry

	local ok, err = pcall(function()
		local template = CitizenModel.build({ gender = "M", kind = "adult", seed = 1 })
		for _, d in template:GetDescendants() do
			if d:IsA("BasePart") and SHIRT_PARTS[d.Name] then
				d.Color = SHIRTS[index]
			end
		end
		-- Parented to nil is fine for `collect`: it walks GetDescendants and reads CFrames,
		-- and never needs the model to be in the workspace.
		local bake = ModelBaker.collect(template, { minFeature = MIN_FEATURE })
		if not bake then
			template:Destroy()
			error("collect found nothing visible on a fresh figure")
		end
		entry.center = bake.center
		entry.height = math.max(bake.extents.Y, 1e-3)
		entry.mesh = ModelBaker.bakeMesh(bake, "LODCitizen_" .. index)
		template:Destroy()
	end)

	if not ok or not entry.mesh then
		entry.state = "failed"
		_fails += 1
		warnOnce("citizen bake failed, people stay part-drawn: " .. tostring(err))
		return
	end
	entry.state = "ready"
	_bakes += 1
end

-- Never blocks and never bakes on the caller's thread. A miss starts one bake and answers nil,
-- and the caller is expected to keep drawing the real figure until a later sweep finds it --
-- the same contract LODProxyCache.get offers.
local function entryFor(model: Model): Entry?
	local shirt = shirtOf(model)
	if not shirt then
		return nil
	end
	local index = bucketFor(shirt)
	local entry = _cache[index]
	if entry then
		return if entry.state == "ready" then entry else nil
	end
	if _baking then
		return nil -- one at a time; this bucket will be picked up on a later sweep
	end
	_baking = true
	task.spawn(function()
		local ok, err = pcall(bakeBucket, index)
		if not ok then
			warnOnce("bake threw: " .. tostring(err))
			_cache[index] = { state = "failed", mesh = nil, center = Vector3.zero, height = 1 }
		end
		_baking = false
	end)
	return nil
end

-- The proxy welded into `model`, or nil if none could be made. The figure keeps its own parts;
-- hiding them is the caller's job, and deliberately so -- the caller is the one that knows
-- whether the swap is being faded or applied outright.
function CitizenProxyCache.attach(model: Model): BasePart?
	local existing = model:FindFirstChild("_LODProxy")
	if existing and existing:IsA("BasePart") then
		return existing
	end

	local root = model.PrimaryPart
	if not root then
		return nil
	end
	local entry = entryFor(model)
	if not entry then
		return nil
	end
	local template = entry.mesh
	if not template then
		return nil
	end

	-- One scale carries both the height jitter and the adult/kid difference, which is why
	-- there is no separate kid bake: a child is simply a shorter figure.
	local okExtent, extent = pcall(function()
		return model:GetExtentsSize()
	end)
	local k = if okExtent and extent.Y > 1e-3 then extent.Y / entry.height else 1

	local ok, proxy = pcall(function()
		local p = template:Clone()
		p.Name = "_LODProxy"
		p.Size = template.Size * k
		-- Unanchored and welded, exactly as CitizenModel welds the body: the root is anchored
		-- and kinematic, so everything welded to it is carried along by the engine.
		p.Anchored = false
		p.Massless = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Locked = true
		p.CFrame = root.CFrame * CFrame.new(entry.center * k)
		p.Parent = model

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = p
		weld.Parent = p
		return p
	end)

	if not ok or not proxy then
		return nil
	end
	_attached += 1
	return proxy
end

function CitizenProxyCache.detach(model: Model)
	local existing = model:FindFirstChild("_LODProxy")
	if existing then
		existing:Destroy()
	end
end

-- Whether a part belongs to this cache rather than to the figure, so a caller walking a
-- model's descendants to hide them does not hide the stand-in it just put there.
function CitizenProxyCache.isProxy(inst: Instance): boolean
	return inst.Name == "_LODProxy"
end

function CitizenProxyCache.stats(): { [string]: any }
	local ready = 0
	for _, e in _cache do
		if e.state == "ready" then
			ready += 1
		end
	end
	return { buckets = ready, bakes = _bakes, fails = _fails, attached = _attached }
end

return CitizenProxyCache
