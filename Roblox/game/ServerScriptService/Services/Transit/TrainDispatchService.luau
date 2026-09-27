--!strict
-- TrainDispatchService
-- The visible passenger train fleet. Trains need no depot: every closed, enabled
-- TRAIN route keeps route.busCount trains looping it, spawned at a station and
-- retired when the line closes, shrinks or is deleted. Trains do NOT ride the car
-- traffic AI (lanes/jams/signals are car concerns): each train advances a scalar
-- distance along its route's rail polylines (TransitService route.legPaths, computed
-- on the rail-only nav graph) and every car of the consist is placed by arc-length
-- behind the head, so multi-car trains articulate through curves for free.
--
-- ponytail: trains are invisible to the car AI -- cars don't yield at level
-- crossings. Ceiling: visual overlap at busy crossings. Upgrade: crossing gates
-- that hold road edges via TrafficSignalService when a train approaches.

local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TransitTypes  = require(ReplicatedStorage.Transit.TransitTypes)
local VehicleTypes  = require(ReplicatedStorage.Road.VehicleTypes)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)

local TrainDispatchService = {}

local RECONCILE_INTERVAL = 1.5
local TRAIN_LIFT = 0.45  -- ride lift above the rail polyline
local ACCEL = 12         -- studs/s^2 at world scale (acceleration AND braking)
-- km/h -> studs/s, the same conversion RoadRules uses (rides the WORLD_SCALE knob).
local STUDS_PER_KMH = (1 / 3.6) / RoadConstants.STUD_TO_METER
local TOP_SPEED = TransitTypes.Train.speedKmh * STUDS_PER_KMH

local WS = RoadConstants.WORLD_SCALE
local CAR_LEN = TransitTypes.Train.carLength * WS
local CAR_GAP = TransitTypes.Train.carGap * WS
local CONSIST_LEN = TransitTypes.Train.carCount * CAR_LEN + (TransitTypes.Train.carCount - 1) * CAR_GAP
-- Trail polyline kept behind the head (the consist + slack) before old points drop.
local TRAIL_KEEP = CONSIST_LEN + 40

type Train = {
	cars: { Model },     -- [1] = locomotive; each car pivots on a bottom-centre root
	routeId: number,
	legIndex: number,    -- leg being driven; the head arrives at that leg's end stop
	phase: string,       -- "driving" | "dwelling"
	dwellTimer: number,
	speed: number,       -- current studs/s along the trail
	headDist: number,    -- head position, arc-length along `trail`
	trail: { Vector3 },  -- rolling polyline: tail of previous legs + the current leg
	cum: { number },     -- cumulative arc length per trail point
	retire: boolean,     -- despawn at the next station
}

local _transit: any
local _folder: Folder
local _trains: { Train } = {}
local _trainSeq = 0
local _reconcileAccum = 0
local _running = false

local function gameSpeed(): number
	return math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
end

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Trains")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "Trains"; f.Parent = city
	end
	return f :: Folder
end

-- == Car models (procedural; no train templates exist in ServerStorage) ========
local M = Enum.Material
local C_WINDOW = Color3.fromRGB(52, 60, 70)
local C_SKIRT  = Color3.fromRGB(58, 60, 66)
local C_ROOF   = Color3.fromRGB(120, 122, 128)

local function carPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name; p.Size = size; p.CFrame = cf; p.Color = color; p.Material = mat
	p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- One car of the consist, authored at full scale (nose on local +Z) then shrunk to
-- WORLD_SCALE. Root is an anchored bottom-centre part (VehicleFactory convention):
-- pivoting it to a point ON the rail seats the wheels on the track.
local function buildCar(name: string, isLoco: boolean): Model
	local spec = TransitTypes.Train
	local L, W, H = spec.carLength, spec.width, spec.height
	local model = Instance.new("Model")
	model.Name = name
	local bodyC = if isLoco then spec.loco else spec.body
	local bodyH = H * 0.62
	local bodyY = H * 0.30 + bodyH * 0.5
	carPart(model, "Skirt", Vector3.new(W * 0.86, H * 0.30, L * 0.96), CFrame.new(0, H * 0.15, 0), C_SKIRT, M.Metal)
	local bodyL = if isLoco then L * 0.88 else L * 0.96
	carPart(model, "Body", Vector3.new(W, bodyH, bodyL), CFrame.new(0, bodyY, if isLoco then -L * 0.04 else 0), bodyC, M.SmoothPlastic)
	if isLoco then
		carPart(model, "Nose", Vector3.new(W * 0.9, bodyH * 0.7, L * 0.10), CFrame.new(0, bodyY - bodyH * 0.15, L * 0.42), bodyC, M.SmoothPlastic)
		carPart(model, "Headlight", Vector3.new(W * 0.5, 1.2, 0.4), CFrame.new(0, H * 0.34, L * 0.475), Color3.fromRGB(255, 244, 214), M.Neon)
		carPart(model, "CabWindow", Vector3.new(W * 0.8, bodyH * 0.35, 0.3), CFrame.new(0, bodyY + bodyH * 0.2, L * 0.37), C_WINDOW, M.Glass)
	else
		carPart(model, "Windows", Vector3.new(W + 0.12, bodyH * 0.42, L * 0.86), CFrame.new(0, bodyY + bodyH * 0.12, 0), C_WINDOW, M.Glass)
	end
	carPart(model, "Roof", Vector3.new(W * 0.94, H * 0.08, L * 0.94), CFrame.new(0, H * 0.96, 0), C_ROOF, M.Metal)

	if WS ~= 1 then model:ScaleTo(WS) end

	local bboxCF, bboxSize = model:GetBoundingBox()
	local root = Instance.new("Part")
	root.Name = "Root"; root.Size = Vector3.new(0.2, 0.2, 0.2); root.Transparency = 1
	root.Anchored = true; root.CanCollide = false; root.CanTouch = false; root.CanQuery = false; root.CastShadow = false
	root.CFrame = bboxCF * CFrame.new(0, -bboxSize.Y * 0.5, 0)
	root.Parent = model
	model.PrimaryPart = root
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root; weld.Part1 = d; weld.Parent = root
			d.Anchored = false
		end
	end
	return model
end

-- == Trail sampling ============================================================
local function buildCum(pts: { Vector3 }): { number }
	local cum = table.create(#pts)
	cum[1] = 0
	for i = 2, #pts do
		cum[i] = cum[i - 1] + (pts[i] - pts[i - 1]).Magnitude
	end
	return cum
end

local function trailTotal(t: Train): number
	return t.cum[#t.cum] or 0
end

-- Point + travel direction at arc-length d along the trail (clamped to its ends).
local function sampleTrail(t: Train, d: number): (Vector3, Vector3)
	local pts, cum = t.trail, t.cum
	local n = #pts
	if n == 0 then return Vector3.zero, Vector3.zAxis end
	if n == 1 then return pts[1], Vector3.zAxis end
	d = math.clamp(d, 0, cum[n])
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if cum[mid] <= d then lo = mid else hi = mid end
	end
	local span = cum[hi] - cum[lo]
	local f = if span > 1e-6 then (d - cum[lo]) / span else 0
	local dir = pts[hi] - pts[lo]
	dir = if dir.Magnitude > 1e-6 then dir.Unit else Vector3.zAxis
	return pts[lo]:Lerp(pts[hi], f), dir
end

-- Append a leg polyline to the trail, then drop points far behind the head.
local function extendTrail(t: Train, leg: { Vector3 })
	local pts = t.trail
	for i, p in leg do
		local last = pts[#pts]
		if not (i == 1 and last and (p - last).Magnitude < 0.5) then
			table.insert(pts, p)
		end
	end
	t.cum = buildCum(pts)
	local cutAt = t.headDist - TRAIL_KEEP
	local drop = 0
	for i = 1, #pts - 2 do
		if t.cum[i + 1] < cutAt then drop = i else break end
	end
	if drop > 0 then
		local shift = t.cum[drop + 1]
		for _ = 1, drop do table.remove(pts, 1) end
		t.headDist -= shift
		t.cum = buildCum(pts)
	end
end

-- Seat every car of the consist on the trail behind the head. Front/back probe
-- points give each car its pitch on grades and its chord through curves.
local function placeCars(t: Train)
	for k, car in t.cars do
		local center = t.headDist - (k - 1) * (CAR_LEN + CAR_GAP) - CAR_LEN * 0.5
		local half = CAR_LEN * 0.45
		local pF = sampleTrail(t, center + half)
		local pB = sampleTrail(t, center - half)
		local mid = (pF + pB) * 0.5 + Vector3.new(0, TRAIN_LIFT, 0)
		local dir = pF - pB
		if dir.Magnitude < 1e-4 then
			local _, d2 = sampleTrail(t, center)
			dir = d2
		end
		-- Cars are authored nose-on-+Z; lookAt points the LookVector (-Z), so aim it
		-- backwards to put local +Z along the travel direction.
		car:PivotTo(CFrame.lookAt(mid, mid - dir.Unit))
	end
end

-- == Fleet =====================================================================
local function destroyTrain(t: Train)
	local loco = t.cars[1]
	if loco then _transit.vehicleOutOfService(loco, loco:GetPivot().Position) end
	local idx = table.find(_trains, t)
	if idx then table.remove(_trains, idx) end
	for _, car in t.cars do
		if car.Parent then car:Destroy() end
	end
end

-- Spawn a train dwelling at stops[startIndex]. The trail seeds with a straight
-- run-in behind the platform so the consist starts formed instead of accordioning
-- out of a single point.
local function spawnTrain(routeId: number, startIndex: number): boolean
	local route = _transit.getRoute(routeId)
	if not route or #route.stops < 2 then return false end
	local n = #route.stops
	startIndex = ((startIndex - 1) % n) + 1
	local leg = route.legPaths and route.legPaths[startIndex]
	if typeof(leg) ~= "table" or #leg < 2 then return false end

	_trainSeq += 1
	local cars: { Model } = {}
	for k = 1, TransitTypes.Train.carCount do
		local car = buildCar(("Train_%d_Car%d"):format(_trainSeq, k), k == 1)
		car.Parent = _folder
		cars[k] = car
	end
	CollectionService:AddTag(cars[1], VehicleTypes.Tag.Train)

	local dirIn = leg[2] - leg[1]
	dirIn = if dirIn.Magnitude > 1e-4 then dirIn.Unit else Vector3.zAxis
	local runIn = CONSIST_LEN + 4
	local trail: { Vector3 } = { leg[1] - dirIn * runIn, leg[1] }

	local t: Train = {
		cars = cars, routeId = routeId,
		-- legIndex is the leg being driven; dwelling at stops[startIndex] means the
		-- NEXT departure drives leg startIndex, so start one before it.
		legIndex = startIndex - 1,
		phase = "dwelling", dwellTimer = TransitTypes.TRAIN_STOP_DWELL,
		speed = 0, headDist = runIn,
		trail = trail, cum = buildCum(trail), retire = false,
	}
	table.insert(_trains, t)
	placeCars(t)
	return true
end

local function arrive(t: Train)
	local route = _transit.getRoute(t.routeId)
	if not route or route.mode ~= "train" or #route.stops < 2 or not route.closed then
		destroyTrain(t); return
	end
	if t.retire then destroyTrain(t); return end
	t.phase = "dwelling"
	local stopId = route.stops[(t.legIndex % #route.stops) + 1]
	local moved = _transit.vehicleAtStop(t.cars[1], route.id, stopId, TransitTypes.Train.capacity)
	t.dwellTimer = TransitTypes.TRAIN_STOP_DWELL + moved * TransitTypes.BOARD_SECONDS
	t.speed = 0
end

local function depart(t: Train)
	local route = _transit.getRoute(t.routeId)
	if not route or route.mode ~= "train" or #route.stops < 2 or not route.closed then
		destroyTrain(t); return
	end
	local n = #route.stops
	local nextLeg = (t.legIndex % n) + 1
	local leg = route.legPaths and route.legPaths[nextLeg]
	if typeof(leg) ~= "table" or #leg < 2 then
		-- Leg has no path yet (track edited away / recompute pending): hold at the
		-- platform and retry after another dwell instead of stalling forever.
		t.dwellTimer = TransitTypes.TRAIN_STOP_DWELL
		return
	end
	t.legIndex = nextLeg
	extendTrail(t, leg)
	t.phase = "driving"
end

local function step(dt: number)
	local speed = gameSpeed()
	if speed <= 0 then return end
	local sdt = dt * speed
	for i = #_trains, 1, -1 do
		local t = _trains[i]
		local loco = t.cars[1]
		if not (loco and loco.Parent) then
			destroyTrain(t)
			continue
		end
		if t.phase == "dwelling" then
			t.dwellTimer -= sdt
			if t.dwellTimer <= 0 then depart(t) end
		else
			local total = trailTotal(t)
			local remaining = math.max(0, total - t.headDist)
			-- Accelerate, but never past the speed braking can shed before the platform.
			local vAllow = math.sqrt(2 * ACCEL * remaining)
			t.speed = math.min(t.speed + ACCEL * sdt, TOP_SPEED, math.max(vAllow, 2))
			t.headDist += t.speed * sdt
			if t.headDist >= total - 0.05 then
				t.headDist = total
				placeCars(t)
				arrive(t)
			else
				placeCars(t)
			end
		end
	end
end

-- Keep each runnable train route supplied; retire strays. Mirrors the bus
-- reconcile, minus every depot concern.
local function reconcile()
	for i = #_trains, 1, -1 do
		local t = _trains[i]
		local route = _transit.getRoute(t.routeId)
		if not route or route.mode ~= "train" then
			destroyTrain(t)
		elseif not (route.enabled and route.closed and #route.stops >= 2) then
			t.retire = true
		end
	end
	for _, routeId in _transit.getRouteIds() do
		local route = _transit.getRoute(routeId)
		if not route or route.mode ~= "train" then continue end
		local runnable = route.enabled and route.closed == true and #route.stops >= 2 and #route.legPaths > 0
		local desired = if runnable then route.busCount else 0
		local have = 0
		for _, t in _trains do
			if t.routeId == routeId and not t.retire then have += 1 end
		end
		if have < desired then
			local spacing = math.max(1, math.floor(#route.stops / math.max(1, desired)))
			if spawnTrain(routeId, have * spacing + 1) then have += 1 end
		elseif have > desired then
			for _, t in _trains do
				if t.routeId == routeId and not t.retire then t.retire = true; have -= 1; break end
			end
		end
		_transit.setRouteActiveBuses(routeId, have)
	end
end

-- == Public ====================================================================
-- Despawn the whole fleet (city unload / reload); trains respawn on reconcile.
function TrainDispatchService.clear()
	for i = #_trains, 1, -1 do
		destroyTrain(_trains[i])
	end
	table.clear(_trains)
end

-- == Lifecycle =================================================================
function TrainDispatchService.Init(transitService: any)
	assert(transitService, "[TrainDispatchService] requires TransitService")
	_transit = transitService
	_folder = ensureFolder()
end

function TrainDispatchService.Bind() end

function TrainDispatchService.Start()
	if _running then return end
	_running = true
	RunService.Heartbeat:Connect(function(dt: number)
		local sdt = math.min(dt, 0.1)
		local ok, err = pcall(step, sdt)
		if not ok then warn("[TrainDispatchService] step failed: " .. tostring(err)) end
		_reconcileAccum += dt
		if _reconcileAccum >= RECONCILE_INTERVAL then
			_reconcileAccum = 0
			pcall(reconcile)
		end
	end)
end

return TrainDispatchService
