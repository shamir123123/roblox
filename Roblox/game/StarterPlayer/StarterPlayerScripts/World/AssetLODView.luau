--!strict
-- AssetLODView -- client LOD for everything under workspace._City except Roads (RoadMeshView
-- runs its own ladder there).
--
-- STATIC MODELS ARE ALWAYS THE REAL MODEL. No baked meshes, no impostor pictures, no merged
-- cells: the bakes dropped tree leaves (the leaf SurfaceAppearance alpha does not survive a bake)
-- and turned houses into flat blocks and pictures. Roblox already batches identical parts and
-- meshes into instanced draws, which is the Cities: Skylines 2 recipe (instanced real meshes)
-- with nothing to bake.
--
-- NOTHING HERE MAY BE SEEN TO CHANGE. The only thing this view takes away is a part too small
-- to cover half a pixel (LOD.PIXEL_BUDGET), so hiding it is invisible by construction on any
-- screen and at any field of view. Shadows are left to the engine, which already fades them out
-- with distance -- switching CastShadow off at a fixed range popped them inside shadow range.
-- Distance is bucketed in doublings and judged at each bucket's NEAR edge, so a part hidden for
-- a bucket is under the budget everywhere in it. The Graphics "Draw distance" setting and
-- Core.RenderPressure still scale the distance.
--
-- MOVING SETS (citizens, cars, trucks, buses, trains) are drawn whole until the whole model is
-- about a pixel, then hidden. A citizen gets one baked stand-in (CitizenProxyCache) in between.
--
-- Client-only and non-destructive: LocalTransparencyModifier is restored exactly, and a part
-- another system already holds translucent is never touched.
--
-- BUILDINGS THAT SHIP LIGHTER LEVELS (LODTiers: the Blender industrial kit, BUILDING_PIPELINE.md)
-- are the exception, because the user asked for three levels for low-end devices: past
-- LOD1_BUCKET their small kit props and see-through decoration (Detail_Fence<i>, Grime, Marking,
-- Grate -- alpha is what costs a weak GPU) go, while the solid structure (cranes, pipes, roof
-- plant) stays; past
-- LOD2_BUCKET only their own <500-tri LOD_* model shows (those parts arrive Transparency 1 and are
-- shown locally here). The distance is the same scaled one, so a slow device or a short draw
-- distance reaches the lighter levels sooner.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LOD = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LOD"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local RenderPressure = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("RenderPressure"))
local CitizenProxyCache = require(script.Parent:WaitForChild("CitizenProxyCache"))

local AssetLODView = {}

-- Distance buckets double from BUCKET_NEAR; bucket 0 hides nothing. Leaving a bucket needs 8%
-- past its edge, so a model resting on a boundary never re-applies every sweep.
local BUCKET_NEAR = 256
local MAX_BUCKET = 7
local HYSTERESIS = 0.08
-- renderDistance DIVIDES distance; unclamped, a high setting kept the whole city at full detail.
local RENDER_SCALE_MIN = 0.5
local RENDER_SCALE_MAX = 2
local SWEEP_PERIOD = 0.3
-- A model registers on ChildAdded, before its parts replicate, so its pivot is re-read for a
-- few sweeps instead of trusting the first one.
local SETTLE_SWEEPS = 12
-- A zoom jump retiers the whole city; stragglers catch up on the next sweep.
local TRANSITION_BUDGET_SECS = 0.006
-- Moving models stop being drawn once the WHOLE model is under this many pixels: a dot that
-- small leaving the screen is not something anyone sees. A little sooner under pressure.
local CULL_MODEL_PX = 1
local CULL_MODEL_PX_LOW = 3
local LOD1_BUCKET = 2 -- 512 studs and out
local LOD2_BUCKET = 3 -- 1024 studs and out
local KEEP_PROP_STUDS = 6 -- a kit prop this tall (the plant: stacks, silos, tanks) stays at LOD1
local LOD1_DROP: { [string]: boolean } = table.freeze({ Detail_Grime = true, Detail_Marking = true, Detail_Grate = true })

local DYNAMIC: { [string]: boolean } = table.freeze({
	Citizens = true,
	NPCDrivers = true,
	NPCWalkers = true,
	Trucks = true,
	Buses = true,
	Trains = true,
})
local OWNED: { [string]: boolean } = table.freeze({
	Roads = true,
})

type Entry = {
	pos: Vector3,
	settle: number,
	bucket: number, -- -1 = nothing applied (held by the reveal)
	hidden: { BasePart },
	shown: { BasePart }, -- LOD2 parts made visible (LODTiers buildings)
}
local _entries: { [Model]: Entry } = {}

local function register(child: Instance)
	if child:IsA("Folder") then
		child.ChildAdded:Connect(register)
		for _, c in child:GetChildren() do
			register(c)
		end
		return
	end
	if not child:IsA("Model") or _entries[child] then
		return
	end
	_entries[child] = {
		pos = child:GetPivot().Position,
		settle = SETTLE_SWEEPS,
		bucket = 0,
		hidden = {},
		shown = {},
	}
end

local function restore(e: Entry)
	for _, p in e.hidden do
		if p.Parent then
			p.LocalTransparencyModifier = 0
		end
	end
	table.clear(e.hidden)
	for _, p in e.shown do
		if p.Parent then
			p.Transparency = 1
		end
	end
	table.clear(e.shown)
end

local function nearEdge(b: number): number
	return if b <= 0 then 0 else BUCKET_NEAR * 2 ^ (b - 1)
end

local function bucketAt(dist: number, current: number): number
	local b = if dist < BUCKET_NEAR then 0 else math.min(math.floor(math.log(dist / BUCKET_NEAR, 2)) + 1, MAX_BUCKET)
	if current >= 0 and b ~= current then
		local lo = nearEdge(current) * (1 - HYSTERESIS)
		local hi = if current >= MAX_BUCKET then math.huge else nearEdge(current + 1) * (1 + HYSTERESIS)
		if dist >= lo and dist < hi then
			return current
		end
	end
	return b
end

-- Restore-then-apply: dumber than diffing buckets, but a change is rare per model and the
-- touched list stays exact.
local function apply(model: Model, e: Entry, bucket: number)
	restore(e)
	e.bucket = bucket
	if bucket <= 0 then
		return
	end
	local tier = if not model:GetAttribute("LODTiers") then 0
		elseif bucket >= LOD2_BUCKET then 2
		elseif bucket >= LOD1_BUCKET then 1
		else 0
	if tier == 2 then
		-- Only the LOD_* model, plus the plain lot parts the dressing laid (the entrance strip).
		for _, d in model:GetDescendants() do
			if not d:IsA("BasePart") then
				continue
			end
			if d:GetAttribute("LOD2") then
				d.Transparency = 0
				table.insert(e.shown, d)
			elseif d.LocalTransparencyModifier == 0 and not (d.Parent and d.Parent.Name == "Yard") then
				d.LocalTransparencyModifier = 1
				table.insert(e.hidden, d)
			end
		end
		return
	end
	local dropProp: { [Instance]: boolean } = {}
	if tier == 1 then
		local yard = model:FindFirstChild("Yard")
		if yard then
			for _, prop in yard:GetChildren() do
				if prop:IsA("Model") and prop:GetExtentsSize().Y < KEEP_PROP_STUDS then
					dropProp[prop] = true
				end
			end
		end
	end
	-- Judged at the bucket's near edge, where parts look biggest: anything under the budget
	-- there is under it everywhere the bucket reaches.
	local minStuds = LOD.PIXEL_BUDGET / LOD.pixelsPerStud(nearEdge(bucket))
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.LocalTransparencyModifier == 0 then
			local s = d.Size
			local owner = d:FindFirstAncestorOfClass("Model")
			if math.max(s.X, s.Y, s.Z) < minStuds
				or (tier == 1 and (LOD1_DROP[d.Name] == true or d.Name:match("^Detail_Fence%d$") ~= nil
					or (owner ~= nil and dropProp[owner] == true))) then
				d.LocalTransparencyModifier = 1
				table.insert(e.hidden, d)
			end
		end
	end
end

-- ---- moving things -----------------------------------------------------------------------

local D_FULL = 0
local D_TRIM = 1 -- citizens only: one baked stand-in instead of eight parts
local D_GONE = 2

type Dyn = {
	extent: number,
	settle: number,
	level: number,
	hidden: { BasePart },
	proxy: BasePart?,
	root: BasePart?,
	-- Pixels-per-stud under which the thinnest part is sub-pixel: where a citizen's stand-in
	-- is indistinguishable from the figure.
	trimPps: number,
}
local _dyn: { [Model]: Dyn } = {}

local function measureDynamic(model: Model, d: Dyn)
	d.extent = model:GetExtentsSize().Magnitude
	d.root = model.PrimaryPart
	local thinnest = math.huge
	for _, x in model:GetDescendants() do
		if x:IsA("BasePart") and not CitizenProxyCache.isProxy(x) then
			local s = x.Size
			thinnest = math.min(thinnest, s.X, s.Y, s.Z)
		end
	end
	d.trimPps = if thinnest < math.huge and thinnest > 1e-3 then 1 / thinnest else 0
end

local function registerDynamic(child: Instance)
	if not child:IsA("Model") or _dyn[child] then
		return
	end
	local d: Dyn = { extent = 0, settle = SETTLE_SWEEPS, level = D_FULL, hidden = {}, proxy = nil, root = nil, trimPps = 0 }
	measureDynamic(child, d)
	_dyn[child] = d
end

local function restoreDynamic(d: Dyn)
	for _, x in d.hidden do
		if x.Parent then
			x.LocalTransparencyModifier = 0
		end
	end
	table.clear(d.hidden)
end

local function applyDynamic(model: Model, d: Dyn, level: number)
	restoreDynamic(d)
	if d.proxy and level ~= D_TRIM then
		CitizenProxyCache.detach(model)
		d.proxy = nil
	end
	d.level = level
	if level == D_TRIM and not d.proxy then
		d.proxy = CitizenProxyCache.attach(model) -- nil for anything not shaped like a citizen
	end
	-- Parts are hidden only when something covers them or the whole model is under the cull.
	-- Trimming "sub-pixel" parts per model used to freeze the pixel size at the moment the model
	-- entered the rung, so a parked car first seen from afar kept its roof, glass and wheels
	-- hidden at every zoom afterwards -- the empty parking lots.
	if level == D_FULL or (level == D_TRIM and not d.proxy) then
		return
	end
	for _, x in model:GetDescendants() do
		if x:IsA("BasePart") and not CitizenProxyCache.isProxy(x) and x.LocalTransparencyModifier == 0 then
			x.LocalTransparencyModifier = 1
			table.insert(d.hidden, x)
		end
	end
end

local function sweepDynamic(eye: Vector3, scale: number, cullPx: number)
	for model, d in _dyn do
		if not model:IsDescendantOf(Workspace) then
			_dyn[model] = nil
			continue
		end
		if d.settle > 0 then
			d.settle -= 1
			measureDynamic(model, d)
		end
		if d.extent <= 0 then
			continue
		end
		local root = d.root
		local at = if root and root.Parent then root.Position else model:GetPivot().Position
		local pps = LOD.pixelsPerStud((eye - at).Magnitude / scale)
		local level = if pps * d.extent < cullPx then D_GONE
			elseif d.trimPps > 0 and pps < d.trimPps then D_TRIM
			else D_FULL
		if level ~= d.level or (level == D_TRIM and not d.proxy and CitizenProxyCache.attach(model)) then
			applyDynamic(model, d, level)
		end
	end
end

-- ---- binding -------------------------------------------------------------------------------

local function adopt(folder: Instance)
	if not folder:IsA("Folder") or OWNED[folder.Name] then
		return
	end
	local reg = if DYNAMIC[folder.Name] then registerDynamic else register
	folder.ChildAdded:Connect(reg)
	for _, c in folder:GetChildren() do
		reg(c)
	end
end

-- Polled, not listened for: RoadSceneRenderer RENAMES an existing folder to "_City", and
-- ChildAdded never fires on a rename.
local _boundCity: Instance? = nil
local function pollCity()
	local city = Workspace:FindFirstChild("_City")
	if city == _boundCity or not (city and city:IsA("Folder")) then
		return
	end
	_boundCity = city
	city.ChildAdded:Connect(adopt)
	for _, f in city:GetChildren() do
		adopt(f)
	end
end

-- WorldRevealController suspends the ladder for the instant it hides the city, then installs a
-- hold predicate for the animation so held models are skipped.
local _suspended = false
local _cityLoaded = false
local _holdPredicate: ((Model) -> boolean)? = nil

local function sweep()
	if _suspended or not _cityLoaded then
		return
	end
	pollCity()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local eye = cam.CFrame.Position
	local scale = math.clamp(tonumber(Settings.get("renderDistance")) or 1, RENDER_SCALE_MIN, RENDER_SCALE_MAX)
		* RenderPressure.detail()
	local deadline = os.clock() + TRANSITION_BUDGET_SECS

	for model, e in _entries do
		if not model:IsDescendantOf(Workspace) then
			_entries[model] = nil
			continue
		end
		if _holdPredicate and _holdPredicate(model) then
			-- Left as is; -1 forces a clean apply once the hold lifts.
			e.bucket = -1
			continue
		end
		if e.settle > 0 then
			e.settle -= 1
			e.pos = model:GetPivot().Position
		end
		local bucket = bucketAt((eye - e.pos).Magnitude / scale, e.bucket)
		if bucket ~= e.bucket then
			apply(model, e, bucket)
			if os.clock() >= deadline then
				break
			end
		end
	end

	sweepDynamic(eye, scale, RenderPressure.lerp(CULL_MODEL_PX, CULL_MODEL_PX_LOW))
end

local function releaseWorld()
	for _, e in _entries do
		restore(e)
		e.bucket = 0
	end
	for model, d in _dyn do
		restoreDynamic(d)
		if d.proxy then
			CitizenProxyCache.detach(model)
			d.proxy = nil
		end
		d.level = D_FULL
	end
end

function AssetLODView.setHoldPredicate(fn: ((Model) -> boolean)?)
	_holdPredicate = fn
end

function AssetLODView.setSuspended(on: boolean)
	if _suspended == on then
		return
	end
	_suspended = on
	if on then
		releaseWorld()
	end
end

-- Open between UIEvents.GameEntered and ReturnToMainMenu; nothing is tiered behind the menu.
function AssetLODView.setCityLoaded(on: boolean)
	if _cityLoaded == on then
		return
	end
	_cityLoaded = on
	if not on then
		releaseWorld()
	end
end

local _started = false

function AssetLODView.Start()
	if _started then
		return
	end
	_started = true

	task.spawn(function()
		while true do
			task.wait(SWEEP_PERIOD)
			local ok, err = pcall(sweep)
			if not ok then
				warn("[AssetLODView] sweep failed: " .. tostring(err))
			end
		end
	end)

	local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents")) :: any
	UIEvents.GameEntered.Event:Connect(function()
		AssetLODView.setCityLoaded(true)
	end)
	UIEvents.ReturnToMainMenu.Event:Connect(function()
		AssetLODView.setCityLoaded(false)
	end)
end

return AssetLODView
