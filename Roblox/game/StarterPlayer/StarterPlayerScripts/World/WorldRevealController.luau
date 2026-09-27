--!strict
-- WorldRevealController -- the entrance a city makes when it is loaded.
--
-- The loading screen used to hold until the WHOLE scene was ready: terrain painted, every
-- road and building replicated, every mesh preloaded, the frame rate recovered. The player
-- then blinked into a finished city. This view splits that moment up. The loading screen now
-- ends as soon as the TERRAIN is standing, and the built world arrives on top of it in the
-- order it would really be built: roads first, then the buildings, then everything that
-- dresses them.
--
-- Each layer is held invisible until its turn and then dropped in from above, nearest to the
-- camera first, so a layer reads as one wave rolling out across the map rather than a
-- thousand independent pops.
--
-- THE WAITS DID NOT GO AWAY -- THEY MOVED
-- A layer is still gated on its own instances having finished replicating and its assets
-- having finished preloading. What changed is that the player spends that wait looking at
-- terrain instead of a progress bar, and that each layer only ever waits for ITSELF: the
-- roads drop as soon as the road meshes are baked, and the buildings still arriving behind
-- them cost the roads nothing.
--
-- WHY HIDING IS TRANSPARENCY AND NOT REPARENTING OR MOVING
-- The city is still replicating while this runs. Reparenting replicated instances on the
-- client fights the server, and moving a model that is only half arrived pins the parts that
-- HAVE arrived somewhere wrong -- the same "registered before its parts replicated" fault
-- AssetLODView documents. LocalTransparencyModifier / Enabled touch neither: a part that
-- lands after we armed simply gets hidden on arrival by the DescendantAdded hook.
--
-- The drop itself DOES move things, but only a layer whose instance count has already gone
-- quiet, and every unit has its own CFrame written back at the end rather than being left
-- wherever the last animation frame put it.
--
-- NOTHING HERE IS DESTRUCTIVE
-- Every hidden instance is recorded and restored exactly, and only instances that were
-- visible when we found them are ever recorded -- so a part some other view is already
-- holding translucent is left entirely alone. If a step throws, or the whole reveal overruns
-- its watchdog, release() puts the world back in one pass. A fault here costs the animation,
-- never the city.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ZoneGrid = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("ZoneGrid"))

local WorldRevealController = {}


-- How far above its resting place a piece starts. Scaled with the world so it stays the same
-- fraction of a building's height whatever ZoneGrid.BUILDING_SCALE is set to, which
-- owns that ratio for everything else too.
local DROP_STUDS = 36 * ZoneGrid.BUILDING_SCALE

-- One piece's fall. Deliberately short: what the player watches is the wave crossing the map,
-- not any single building, and a long fall only delays the next one.
local DROP_SECS = 0.4

local MIN_STAGGER = 0.004
local MAX_STAGGER = 0.09

-- WHAT BOUNDS THE FRAME COST -- measured, not guessed.
--
-- Timed in this place on a 500-building city: one Model:PivotTo costs about
--     0.009 ms + 0.0047 ms per part
-- so a unit's per-frame cost tracks (2 + its part count) closely enough to budget on. That
-- is the "weight" below, and it is why there is no per-content tuning table here: twenty
-- 40-part towers and a hundred and seventy 3-part trees are the same amount of work, and one
-- number admits the right number of either.
--
-- A fixed cap on the NUMBER of falling pieces cannot do this. 64 was the first thing tried
-- and it measured 13.5 ms a frame on 40-part buildings -- most of a 60 fps budget spent
-- before anything is drawn -- while being far too conservative for trees.
--
-- (Direct part.CFrame writes were measured too, at roughly twice the cost of PivotTo for the
-- same models, so the Model path is the cheap one. Road cells still write parts directly
-- because a baked cell is 1-4 loose MeshParts with no Model to pivot.)
local MS_PER_WEIGHT = 0.0047
-- What the falling set is allowed to cost per frame. Four milliseconds of a 16.7 ms budget,
-- leaving the rest for actually drawing the city that is arriving.
local LIFT_MS_BUDGET = 4
local LIFT_BUDGET = LIFT_MS_BUDGET / MS_PER_WEIGHT

-- Past this, a unit is revealed where it stands rather than dropped in. An 18-stud fall a
-- kilometre away is sub-pixel motion that costs exactly as much as a visible one, and it is
-- the same boundary AssetLODView calls DISTANT -- out there the player is looking at a coarse
-- baked stand-in, not the model.
local ANIM_MAX_DIST = 1000

-- How long a layer spends ANIMATING before the remainder is simply switched on, nearest
-- first. Without this the reveal is bounded by throughput instead of by design: 500 forty-
-- part buildings at the frame budget above is ten seconds of watching things fall, and the
-- pieces still falling at second nine are the ones too far away to see move.
local LAYER_ANIM_SECS: { [string]: number } = table.freeze({
	roads = 1.2,
	buildings = 1.8,
	props = 1.2,
})

-- The rate that remainder is handed over at, in WEIGHT per second rather than units per
-- second, and matched to what AssetLODView can re-tier: its sweep retiers at most 80 models
-- or 2 ms of work every 0.3 s, and a transition walks the model's descendants -- so what it
-- can keep up with scales with part count, exactly like the weight above. Revealing faster
-- than the ladder can follow leaves a backlog of full-detail buildings on screen (hundreds of
-- models at ~40 draw calls each against a ~1,000 budget), which is precisely the stall this
-- file exists to avoid.
--
-- Counting units instead was measured at four seconds of tail on a 500-building city, most of
-- it spent trickling in 3-part trees the ladder could have swallowed whole.
-- ~11,000/s is about 260 forty-part buildings or 2,200 three-part trees a second.
local TAIL_WEIGHT_PER_SEC = 11000
-- Release valve: past a certain size a brief backlog beats making the player watch a queue
-- drain, so a big enough tail is allowed to outrun the ladder and finish in this long.
local TAIL_MAX_SECS = 1.5

-- A layer waits for its own instance count to stop moving before anything is dropped: a
-- half-arrived layer would drop a road network with holes in it.
--
-- "Stopped moving" is deliberately not "identical twice running". Views that keep working in
-- the background -- construction scaffolding going up, street names being painted -- would
-- never give an exactly stable count, and a layer that waits for one spends the whole cap
-- waiting and then drops late. A handful of instances per tick is settled enough to drop on;
-- whatever lands after that is simply handed back visible at the end of the layer.
--
-- This is pure dead time in front of the player -- three layers' worth of it, spent looking
-- at terrain -- so it is kept as short as it can be while still meaning something.
local SETTLE_QUIET = 0.45
local SETTLE_TICK = 0.1
local SETTLE_TOLERANCE = 2
local SETTLE_CAP = 12
local PRELOAD_CAP = 20

-- Never-stuck backstop for the whole reveal. Whatever went wrong, the world is visible again
-- this long after the player entered it.
local TOTAL_BUDGET = 120

local ROAD_FOLDERS = table.freeze({ Roads = true })

local BUILDING_FOLDERS = table.freeze({
	ZonedBuildings = true,
	Schools = true,
	EmergencyServices = true,
	Transit = true,
})

-- Folders whose contents move and spawn on their own schedule. They are hidden with the rest
-- (a car driving down an invisible road is worse than no car at all) but never dropped --
-- a fall animation on something that is already driving somewhere reads as a glitch -- and
-- they are simply handed back when the last layer finishes.
local DYNAMIC_FOLDERS = table.freeze({
	Citizens = true,
	NPCDrivers = true,
	NPCWalkers = true,
	Trucks = true,
	Buses = true,
	Trains = true,
})

-- Scenery that belongs to a layer but is built by the CLIENT, and so lives beside _City
-- rather than inside it. Roads are the big one: what is actually on screen is RoadMeshView's
-- baked cells in _RoadMeshes, and the models in _City.Roads are mostly spec blobs and
-- invisible collision.
--
-- `static` is whether the thing also FALLS and counts towards its layer having arrived.
-- Street names are painted along the carriageway -- they must not float over terrain while
-- the road under them is still hidden, so they are hidden, but a label peeling off the sky is
-- not what anybody means by a road dropping in, so they just appear with their layer.
local SIBLINGS: { [string]: { layer: string, static: boolean } } = table.freeze({
	_RoadMeshes = { layer = "roads", static = true },
	_StreetNames = { layer = "roads", static = false },
	_OutsideConnections = { layer = "props", static = true },
})

type Hold = { [Instance]: boolean }

type Layer = {
	name: string,
	-- Everything this layer hides.
	roots: { Instance },
	-- The subset the drop animation is built from, and whose count decides when the layer has
	-- finished arriving. Excludes the dynamic folders, whose count never settles.
	staticRoots: { Instance },
	hold: Hold,
	-- Every Model this layer is holding invisible. AssetLODView asks about these by model (see
	-- setLodHoldPredicate): a model nobody can see must not be given a baked stand-in, because
	-- the stand-in lives outside _City where the hold cannot reach it.
	heldModels: { [Model]: boolean },
	-- Descendants seen arriving under this layer's roots, ever. This is how the layer knows it
	-- has finished replicating. It used to be measured with a GetDescendants sweep every
	-- 0.15 s, which on a 20,000-part city measured 18 ms -- a whole dropped frame, six times a
	-- second, while the player was already standing in the world looking at it. The
	-- DescendantAdded hook that does the hiding was already firing for every one of those
	-- instances, so counting there is exact and free.
	arrivals: number,
	-- When the last one landed. A layer that already went quiet while the PREVIOUS layer was
	-- dropping is finished the moment it is asked, and should not stand the player in front of
	-- empty terrain for another settle window to prove it.
	lastArrival: number,
	conns: { RBXScriptConnection },
	bound: { [Instance]: boolean },
	-- Set once this layer has been handed over. The listeners stay connected (dropping them
	-- would let discoverOnce rebind the same roots and start hiding all over again), so this
	-- is what stops a mesh RoadMeshView re-bakes ten seconds later from going invisible again
	-- behind a layer that is already on screen.
	done: boolean,
}

-- One thing that falls. Either a Model (moved by its pivot, one call for the whole thing) or
-- a loose set of parts -- which is what a baked road cell is, since RoadMeshView splits a
-- dense cell across several MeshParts.
type Unit = {
	model: Model?,
	parts: { BasePart }?,
	origin: CFrame?,
	origins: { CFrame }?,
	center: Vector3,
	dist: number,
	t: number,
	-- (2 + part count): what this unit costs to move for one frame, in the units LIFT_BUDGET
	-- is denominated in.
	weight: number,
	-- Whether this one falls at all, or is simply switched on where it stands.
	animate: boolean,
	-- Its own drop height. Jittered per unit so a street does not read as a machine stamping
	-- out identical parabolas.
	lift: number,
}

local _active = false
local _playing = false
local _layers: { [string]: Layer } = {}
local _watchdogToken = 0

-- ---------------------------------------------------------------------------
-- AssetLODView
-- ---------------------------------------------------------------------------
--
-- The LOD ladder replaces a distant building with a baked stand-in parented OUTSIDE _City, so
-- hiding the city does not hide the stand-in: a saved camera looking across a big city would
-- show its far half as floating proxies over bare terrain.
--
-- Suspending the ladder for the whole reveal fixes that and is the wrong trade. Suspended, it
-- puts the entire city back to full detail -- roughly twenty times over Roblox's draw-call
-- budget on a big save, which is the exact stall it exists to prevent -- for the several
-- seconds the animation runs. So it is suspended only for the instant it takes to hide the
-- city (see arm(), where the ordering is what matters), and for the animation itself it gets
-- a HOLD PREDICATE: it keeps tiering everything as normal and simply skips the models being
-- held invisible. See isHeldModel.
--
-- Required lazily rather than at the top of the file: this module is pulled in by the main
-- menu, which runs long before Bootstrap starts the world views, and nothing here should
-- reorder that boot.
local _lodView: any = nil

local function lodView(): any
	if _lodView == nil then
		local ok, mod = pcall(function()
			return require(script.Parent:WaitForChild("AssetLODView", 10) :: ModuleScript)
		end)
		_lodView = if ok and mod then mod else false
	end
	return if _lodView then _lodView else nil
end

local function setLodSuspended(on: boolean)
	local view = lodView()
	if view and view.setSuspended then
		pcall(view.setSuspended, on)
	end
end

local function setLodHoldPredicate(fn: ((Model) -> boolean)?)
	local view = lodView()
	if view and view.setHoldPredicate then
		pcall(view.setHoldPredicate, fn)
	end
end

-- ---------------------------------------------------------------------------
-- Hiding
-- ---------------------------------------------------------------------------

local function holdOne(hold: Hold, d: Instance)
	if hold[d] then
		return
	end
	-- Only ever record something that is visible RIGHT NOW. A part another view is already
	-- holding translucent, or an emitter authored off, is left exactly as we found it -- which
	-- is also what makes the restore below exact.
	if d:IsA("BasePart") or d:IsA("Decal") then
		if (d :: any).LocalTransparencyModifier ~= 0 then
			return
		end
		(d :: any).LocalTransparencyModifier = 1
	elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") or d:IsA("Light")
		or d:IsA("SurfaceGui") or d:IsA("BillboardGui") then
		if not (d :: any).Enabled then
			return
		end
		(d :: any).Enabled = false
	else
		return
	end
	hold[d] = true
end

-- Put one instance back the way we found it. Split out from releaseOne because the bulk path
-- below must NOT touch the hold table while walking it -- see releaseLayer.
local function restoreOne(d: Instance)
	if not d.Parent then
		return
	end
	if d:IsA("BasePart") or d:IsA("Decal") then
		(d :: any).LocalTransparencyModifier = 0
	else
		(d :: any).Enabled = true
	end
end

-- Release one instance by name. Callers are walking a MODEL's descendants, never the hold
-- itself, so removing the key as we go is safe here.
local function releaseOne(hold: Hold, d: Instance)
	if not hold[d] then
		return
	end
	hold[d] = nil
	restoreOne(d)
end

local function releaseLayer(layer: Layer)
	layer.done = true
	-- Restore WITHOUT removing entries as we go.
	--
	-- This loop used to call releaseOne, which cleared the very key the traversal was standing
	-- on. That is the kind of thing that works perfectly on a small table and quietly skips
	-- entries on a big one: measured on a 500-building city it stranded two buildings
	-- permanently invisible, with no error and nothing to notice unless you went counting.
	-- Removing them one at a time bought nothing anyway -- the whole table goes below.
	for d in layer.hold do
		restoreOne(d)
	end
	table.clear(layer.hold :: any)
	table.clear(layer.heldModels :: any)
end

-- Bind one root: hide what is already under it, and every instance that lands under it from
-- here on. The listener is what makes arming safe while the city is still replicating.
-- `counts` is whether arrivals under this root mean the layer is still coming in. The moving
-- sets are hidden like everything else but deliberately do NOT count: citizens and traffic
-- spawn for as long as the simulation runs, so a settle gate that watched them would never
-- see the layer go quiet and would spend its whole cap waiting.
local function bindRoot(layer: Layer, root: Instance, counts: boolean)
	if layer.bound[root] then
		return
	end
	layer.bound[root] = true
	table.insert(layer.conns, root.DescendantAdded:Connect(function(d)
		if counts then
			layer.arrivals += 1
			layer.lastArrival = os.clock()
		end
		if _active and not layer.done then
			if d:IsA("Model") then
				layer.heldModels[d] = true
			end
			holdOne(layer.hold, d)
		end
	end))
	for _, d in root:GetDescendants() do
		if counts then
			layer.arrivals += 1
		end
		if d:IsA("Model") then
			layer.heldModels[d] = true
		end
		holdOne(layer.hold, d)
	end
	if counts then
		layer.lastArrival = os.clock()
	end
end

local function newLayer(name: string): Layer
	return {
		name = name,
		roots = {},
		staticRoots = {},
		hold = {},
		heldModels = {},
		arrivals = 0,
		lastArrival = os.clock(),
		conns = {},
		bound = {},
		done = false,
	}
end

local function addRoot(layer: Layer, root: Instance, static: boolean)
	if layer.bound[root] then
		return
	end
	table.insert(layer.roots, root)
	if static then
		table.insert(layer.staticRoots, root)
	end
	bindRoot(layer, root, static)
end

-- Which layer a _City child folder belongs to. Anything not named as a road, a building or a
-- moving set is a prop -- including folders that do not exist yet, so a folder added next
-- month joins the reveal without touching this file (the same rule AssetLODView uses).
local function layerForCityFolder(name: string): (string, boolean)
	if ROAD_FOLDERS[name] then
		return "roads", true
	elseif BUILDING_FOLDERS[name] then
		return "buildings", true
	elseif DYNAMIC_FOLDERS[name] then
		return "props", false
	end
	return "props", true
end

-- POLLS rather than listening, for the reason AssetLODView spells out: _City is not parented
-- in under that name, RoadSceneRenderer renames an existing folder to it, and ChildAdded
-- never fires on a rename. A FindFirstChild per tick costs nothing and catches every case.
local function discoverOnce()
	local city = Workspace:FindFirstChild("_City")
	if city then
		for _, folder in city:GetChildren() do
			if folder:IsA("Folder") or folder:IsA("Model") then
				local name, static = layerForCityFolder(folder.Name)
				addRoot(_layers[name], folder, static)
			end
		end
	end
	for _, child in Workspace:GetChildren() do
		local sib = SIBLINGS[child.Name]
		if sib then
			addRoot(_layers[sib.layer], child, sib.static)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Waiting for a layer to finish arriving
-- ---------------------------------------------------------------------------

-- Hold until the layer has stopped growing for a beat, or the cap expires. An empty layer
-- (a fresh map with no roads, a city with no schools) returns immediately rather than burning
-- the cap waiting for something that is never going to arrive.
--
-- `gate` is an extra condition the layer cannot be considered arrived without. Roads need
-- one: their count is dominated by _City.Roads, which is fully replicated long before
-- RoadMeshView has baked a single visible mesh out of it, so counting alone would call the
-- layer settled while the thing the player actually sees is still empty.
local function waitSettled(layer: Layer, deadline: number, gate: (() -> boolean)?)
	if #layer.staticRoots == 0 then
		return
	end
	local cap = math.min(deadline, os.clock() + SETTLE_CAP)
	local last, stableFor = -1, 0
	while os.clock() < cap do
		discoverOnce() -- a folder for this layer may still be on its way

		-- Already quiet before we got here -- the usual case for every layer after the first,
		-- which spent the previous layer's whole animation finishing its replication. Leave at
		-- once rather than sampling a window to re-establish what is already known.
		if os.clock() - layer.lastArrival >= SETTLE_QUIET and (not gate or gate()) then
			return
		end

		-- Otherwise watch the rate. This is the path for a layer still arriving, and for one a
		-- background view keeps trickling into forever (see SETTLE_TOLERANCE) -- which the
		-- timestamp above would never call quiet.
		local count = layer.arrivals
		local delta = count - last
		last = count
		if delta >= 0 and delta <= SETTLE_TOLERANCE and (not gate or gate()) then
			stableFor += SETTLE_TICK
			if stableFor >= SETTLE_QUIET then
				return
			end
		else
			stableFor = 0
		end
		task.wait(SETTLE_TICK)
	end
end

-- PreloadAsync yields until every asset is in, which is exactly what we want and also why it
-- is run on its own thread: a layer that cannot finish preloading drops on schedule looking
-- slightly untextured, rather than holding the whole reveal open.
local function preloadLayer(layer: Layer, deadline: number)
	-- One representative per distinct piece of CONTENT, not one entry per instance. A city's
	-- five hundred houses are a few dozen meshes and textures wearing different colours;
	-- handing PreloadAsync twenty thousand instances asks it to do the same few dozen fetches
	-- over and over, and the list alone is most of the cost.
	--
	-- SurfaceAppearance is keyed off the mesh it dresses rather than its own maps ON PURPOSE:
	-- reading SurfaceAppearance.ColorMap succeeds in Studio and throws in a live game, and a
	-- preload is not worth taking the whole reveal down for.
	local assets: { Instance } = {}
	local seen: { [string]: boolean } = {}

	local function consider(d: Instance, key: string)
		if seen[key] then
			return
		end
		seen[key] = true
		table.insert(assets, d)
	end

	for _, r in layer.staticRoots do
		if not r.Parent then
			continue
		end
		for _, d in r:GetDescendants() do
			if d:IsA("MeshPart") then
				consider(d, "mesh:" .. d.MeshId .. "|" .. d.TextureID)
			elseif d:IsA("SpecialMesh") then
				consider(d, "spec:" .. d.MeshId .. "|" .. d.TextureId)
			elseif d:IsA("Decal") then -- Texture is a Decal subclass
				consider(d, "decal:" .. d.Texture)
			elseif d:IsA("ParticleEmitter") or d:IsA("Beam") then
				consider(d, "fx:" .. (d :: any).Texture)
			elseif d:IsA("SurfaceAppearance") then
				local host = d.Parent
				local id = if host and host:IsA("MeshPart") then host.MeshId else tostring(host and host.Name)
				consider(d, "surf:" .. id)
			end
		end
	end
	if #assets == 0 then
		return
	end

	local done = false
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(assets)
		end)
		done = true
	end)

	local cap = math.min(deadline, os.clock() + PRELOAD_CAP)
	while not done and os.clock() < cap do
		task.wait(0.05)
	end
end

-- ---------------------------------------------------------------------------
-- Collecting what falls
-- ---------------------------------------------------------------------------

-- Its own drop height, jittered per unit: a street where every roof falls exactly the same
-- distance at exactly the same speed reads as a machine stamping out parabolas. Costs one
-- multiply at collection time and nothing per frame.
local function jitteredLift(): number
	return DROP_STUDS * (0.8 + math.random() * 0.5)
end

-- Models only, recursing through Folders but never into a Model: an outer model is one unit,
-- so a building and its dressing fall together instead of coming apart in mid-air.
--
-- The descendant count is taken here, once, because it is what the frame budget is spent in
-- (see MS_PER_WEIGHT). Measured at ~2 ms for 500 buildings -- a one-off, against the 18 ms
-- PER TICK the old settle poll was costing for the same walk.
local function collectModels(inst: Instance, out: { Unit })
	for _, child in inst:GetChildren() do
		if child:IsA("Model") then
			local ok, pivot = pcall(function()
				return child:GetPivot()
			end)
			if ok and pivot then
				table.insert(out, {
					model = child,
					parts = nil,
					origin = pivot,
					origins = nil,
					center = pivot.Position,
					dist = 0,
					t = 0,
					weight = 2 + #child:GetDescendants(),
					animate = true,
					lift = jitteredLift(),
				})
			end
		elseif child:IsA("Folder") then
			collectModels(child, out)
		end
	end
end

local function modelUnits(layer: Layer): { Unit }
	local out: { Unit } = {}
	for _, r in layer.staticRoots do
		if r.Parent then
			collectModels(r, out)
		end
	end
	return out
end

-- Roads fall a CELL at a time, not a mesh at a time. RoadMeshView bakes per 256-stud map
-- cell and splits a dense one across several MeshParts to stay under the engine's triangle
-- cap, plus a separate mesh for the lane paint -- and half a cell landing before the other
-- half would read as a seam. The cell key is already in the part name, so this needs nothing
-- from RoadMeshView.
local function roadUnits(layer: Layer): { Unit }
	local byCell: { [string]: { BasePart } } = {}
	local order: { string } = {}

	for _, r in layer.staticRoots do
		if r.Name ~= "_RoadMeshes" or not r.Parent then
			continue
		end
		for _, p in r:GetChildren() do
			if not p:IsA("BasePart") then
				continue
			end
			local key = string.match(p.Name, "^RoadCell_(.+)$") or string.match(p.Name, "^RoadDetail_(.+)$")
				or tostring(math.floor(p.Position.X / 256)) .. "," .. tostring(math.floor(p.Position.Z / 256))
			local bucket = byCell[key]
			if not bucket then
				bucket = {}
				byCell[key] = bucket
				table.insert(order, key)
			end
			table.insert(bucket, p)
		end
	end

	local out: { Unit } = {}
	for _, key in order do
		local parts = byCell[key]
		local origins = table.create(#parts)
		local sum = Vector3.zero
		for i, p in parts do
			origins[i] = p.CFrame
			sum += p.Position
		end
		table.insert(out, {
			model = nil,
			parts = parts,
			origin = nil,
			origins = origins,
			center = sum / #parts,
			dist = 0,
			t = 0,
			weight = 2 + #parts,
			animate = true,
			lift = jitteredLift(),
		})
	end
	return out
end

-- ---------------------------------------------------------------------------
-- The drop
-- ---------------------------------------------------------------------------

local function liftUnit(u: Unit, dy: number)
	local offset = Vector3.new(0, dy, 0)
	local model, origin = u.model, u.origin
	if model and origin then
		if model.Parent then
			model:PivotTo(origin + offset)
		end
		return
	end
	local parts, origins = u.parts, u.origins
	if parts and origins then
		for i, p in parts do
			if p.Parent then
				p.CFrame = origins[i] + offset
			end
		end
	end
end

-- Hand this unit's own instances back the moment it starts falling. One pass per unit rather
-- than a transparency ramp per frame: the motion is what sells the arrival, and ramping
-- ~40 parts a frame across 64 live units is real cost for something nobody looks at.
local function revealUnit(layer: Layer, u: Unit)
	local model = u.model
	if model then
		-- Off the held list before anything else: that is what lets AssetLODView start tiering
		-- this model again, and it must be true by the time the parts become visible or the
		-- ladder spends a sweep believing a building nobody can see still needs no stand-in.
		layer.heldModels[model] = nil
		for _, d in model:GetDescendants() do
			if d:IsA("Model") then
				layer.heldModels[d] = nil
			end
			releaseOne(layer.hold, d)
		end
		return
	end
	local parts = u.parts
	if parts then
		for _, p in parts do
			releaseOne(layer.hold, p)
		end
	end
end

local function runLayer(layer: Layer, units: { Unit }, deadline: number)
	if #units == 0 then
		return
	end

	-- Nearest to the camera first, so the wave starts where the player is already looking and
	-- rolls outward -- and so that when the animation budget runs out, what is left to switch
	-- on silently is always the far half. Distance is precomputed: sorting on a magnitude
	-- computed inside the comparator is a square root per comparison.
	local cam = Workspace.CurrentCamera
	local eye = if cam then cam.CFrame.Position else Vector3.zero
	for _, u in units do
		u.dist = (u.center - eye).Magnitude
		u.animate = u.dist <= ANIM_MAX_DIST
	end
	table.sort(units, function(a, b)
		return a.dist < b.dist
	end)

	local animSecs = LAYER_ANIM_SECS[layer.name] or 2
	-- On a small city the frame budget never binds, so the wave needs a minimum spacing of its
	-- own or a hamlet's twelve houses all land on the same frame. On a big one this clamps to
	-- MIN_STAGGER and LIFT_BUDGET below becomes the real pace-setter.
	local stagger = math.clamp(animSecs / #units, MIN_STAGGER, MAX_STAGGER)

	local live: { Unit } = {}
	local liveWeight = 0
	local nextIndex = 1
	local pace = 0
	local tailCarry = 0
	local elapsed = 0

	local remainingWeight = 0
	for _, u in units do
		remainingWeight += u.weight
	end

	while nextIndex <= #units or #live > 0 do
		local dt = RunService.Heartbeat:Wait()

		if os.clock() >= deadline then
			break -- the watchdog will put everything back; do not fight it
		end

		elapsed += dt
		pace += dt

		local animating = elapsed < animSecs
		local tailRate = math.max(TAIL_WEIGHT_PER_SEC, remainingWeight / TAIL_MAX_SECS)
		-- Never bank more than a frame or two of the tail, or a stretch spent waiting on the
		-- falling set would dump hundreds of models on screen the moment it drains.
		tailCarry = math.min(tailCarry + tailRate * dt, tailRate * 0.05)

		while nextIndex <= #units do
			local u = units[nextIndex]
			local drop = animating and u.animate

			if drop then
				-- `#live > 0` so a single unit heavier than the whole budget still gets to
				-- fall, rather than deadlocking the layer against itself.
				if liveWeight + u.weight > LIFT_BUDGET and #live > 0 then
					break
				end
				if pace < stagger then
					break
				end
				pace -= stagger
			else
				if tailCarry < u.weight then
					break
				end
				tailCarry -= u.weight
			end

			nextIndex += 1
			remainingWeight -= u.weight
			revealUnit(layer, u)
			if drop then
				u.t = 0
				liftUnit(u, u.lift)
				liveWeight += u.weight
				table.insert(live, u)
			end
		end
		-- Same reason as tailCarry's clamp: no burst banked up while the falling set was full.
		if pace > stagger then
			pace = stagger
		end

		for k = #live, 1, -1 do
			local u = live[k]
			u.t += dt
			local a = math.clamp(u.t / DROP_SECS, 0, 1)
			if a >= 1 then
				-- Written back from the stored origin, never left on the last animation frame:
				-- a fraction of a stud of drift here is permanent.
				liftUnit(u, 0)
				liveWeight -= u.weight
				table.remove(live, k)
			else
				-- Cubic ease-out: most of the fall is over in the first third, so it lands like
				-- something set down rather than something lowered.
				local e = 1 - (1 - a) ^ 3
				liftUnit(u, u.lift * (1 - e))
			end
		end
	end

	-- Anything the loop never reached (the watchdog fired, or a unit arrived late) still has to
	-- end up visible and in place.
	for i = nextIndex, #units do
		local u = units[i]
		revealUnit(layer, u)
		liftUnit(u, 0)
	end
	for _, u in live do
		liftUnit(u, 0)
	end
end

-- Answers AssetLODView's one question: is this model currently being held invisible? Three
-- table lookups, once per model per 0.3 s sweep.
--
-- This is what replaced suspending the ladder outright for the length of the reveal. The
-- ladder has to keep running -- a 500-building city drawn at full detail is roughly twenty
-- times over Roblox's draw-call budget, which is the entire reason AssetLODView exists -- but
-- it must not hand a baked stand-in to a building the reveal is hiding, because the stand-in
-- lives outside _City where the hold cannot reach it. So it runs, and skips these.
local function isHeldModel(model: Model): boolean
	for _, layer in _layers do
		if layer.heldModels[model] then
			return true
		end
	end
	return false
end

-- Roads are only ready when RoadMeshView has actually produced geometry for them. A city
-- whose bakes all failed still has to enter -- SETTLE_CAP is what releases it -- but the
-- normal case must not drop an empty road layer and then pop the real roads in behind it.
local function roadMeshesReady(): boolean
	local roadModels = Workspace:FindFirstChild("_City")
	roadModels = if roadModels then roadModels:FindFirstChild("Roads") else nil
	if not roadModels or #roadModels:GetChildren() == 0 then
		return true -- nothing to bake
	end
	local meshes = Workspace:FindFirstChild("_RoadMeshes")
	return meshes ~= nil and #meshes:GetChildren() > 0
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Put the world back, now. Safe to call at any point and from any state -- it is both the
-- normal end of the reveal and the panic button.
function WorldRevealController.release()
	_active = false
	_playing = false
	_watchdogToken += 1
	for _, layer in _layers do
		for _, c in layer.conns do
			c:Disconnect()
		end
		table.clear(layer.conns)
		table.clear(layer.bound :: any)
		table.clear(layer.roots)
		table.clear(layer.staticRoots)
		releaseLayer(layer)
	end
	setLodHoldPredicate(nil)
	setLodSuspended(false)
end

-- Hide the built city and keep hiding it as the rest of it arrives. Call this BEFORE the
-- loading screen fades: from here until play() finishes, the player sees terrain and nothing
-- else. Arming twice is a no-op rather than a second set of listeners over the same folders.
function WorldRevealController.arm()
	if _active then
		return
	end

	WorldRevealController.release() -- clear anything a previous load left behind

	_layers = {
		roads = newLayer("roads"),
		buildings = newLayer("buildings"),
		props = newLayer("props"),
	}
	_active = true

	-- Order matters, and there are no yields between these four, so no LOD sweep can land in
	-- the middle of them:
	--   1. teach the ladder what "held" means, before anything is held
	--   2. stop it, which makes it put back everything it was hiding -- otherwise its own
	--      hidden-part bookkeeping is stale the moment we hide the same parts, and it would
	--      later hand them back visible underneath us
	--   3. hide the city
	--   4. start it again. It now skips what we hold and tiers everything else as normal, so
	--      the city is never drawn at full detail just because it is mid-reveal.
	-- The backstop is armed BEFORE any of the work below, not after.
	--
	-- Armed-but-never-played is the one failure that would be permanent: the city would sit
	-- invisible for the rest of the session with nothing left running to hand it back. Every
	-- caller has abort paths between arm() and play() -- a load that times out, a camera
	-- restore that throws -- so the backstop lives here rather than in each of them. play()
	-- and release() both move the token, which is what cancels this.
	--
	-- It used to be registered AFTER the discovery pass below, which meant a throw in that
	-- pass skipped the registration too: the one path that most needed recovering was the one
	-- path left with no watchdog on it.
	_watchdogToken += 1
	local armToken = _watchdogToken
	task.delay(TOTAL_BUDGET, function()
		if _watchdogToken == armToken and _active and not _playing then
			warn("[WorldRevealController] armed but never played -- showing the world as-is")
			WorldRevealController.release()
		end
	end)

	setLodHoldPredicate(isHeldModel)
	setLodSuspended(true)
	-- Guarded so the resume below ALWAYS runs. Suspending the LOD ladder and then throwing
	-- leaves it suspended for the rest of the session: it still reports that it started, its
	-- sweep returns immediately, and the entire city renders at full detail with nothing in
	-- the log to say why. The polling loop further down already pcalls this same call, so
	-- that it can throw was never in doubt -- only this copy of it was unprotected.
	local okDiscover, discoverErr = pcall(discoverOnce)
	setLodSuspended(false)
	if not okDiscover then
		warn("[WorldRevealController] initial discovery failed: " .. tostring(discoverErr))
	end

	-- Folders keep appearing for the whole load -- the server creates several of them lazily,
	-- as the first school or the first bus needs one -- so the sweep runs until play() takes
	-- over, not just once.
	task.spawn(function()
		while _active and not _playing do
			task.wait(0.2)
			local ok, err = pcall(discoverOnce)
			if not ok then
				warn("[WorldRevealController] discovery failed: " .. tostring(err))
			end
		end
	end)
end

-- Run the staged reveal: roads, then buildings, then props. Yields for the whole animation,
-- so callers spawn it. Does nothing at all if arm() was never called, which is what makes
-- this safe to fire on a load path that failed halfway.
function WorldRevealController.play()
	if not _active or _playing then
		return
	end
	_playing = true

	_watchdogToken += 1
	local token = _watchdogToken
	task.delay(TOTAL_BUDGET, function()
		if _watchdogToken == token then
			warn("[WorldRevealController] reveal overran its budget -- showing the world as-is")
			WorldRevealController.release()
		end
	end)

	local deadline = os.clock() + TOTAL_BUDGET

	local ok, err = pcall(function()
		for _, name in { "roads", "buildings", "props" } do
			if not _active then
				return
			end
			local layer = _layers[name]
			discoverOnce()
			waitSettled(layer, deadline, if name == "roads" then roadMeshesReady else nil)
			preloadLayer(layer, deadline)
			if not _active then
				return
			end
			local units = if name == "roads" then roadUnits(layer) else modelUnits(layer)
			runLayer(layer, units, deadline)
			-- Outside runLayer so a layer with nothing to drop -- a map with no roads yet, a
			-- city with no parks -- still hands its contents over at its own turn instead of
			-- staying dark until all three layers are done.
			releaseLayer(layer)
		end
	end)

	if not ok then
		warn("[WorldRevealController] reveal failed: " .. tostring(err))
	end

	-- Ends the same way whether it finished, was cut short, or threw: everything visible,
	-- the LOD ladder back on, listeners gone.
	WorldRevealController.release()
end

function WorldRevealController.isActive(): boolean
	return _active
end

return WorldRevealController
