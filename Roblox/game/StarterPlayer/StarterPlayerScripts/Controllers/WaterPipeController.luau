--!strict
-- WaterPipeController
-- Drawing the mains, with the road tool's gestures rather than a cut-down version of them:
-- Straight, Curved, Advanced Curve and Freeform, an angle-snap toggle, a length readout on
-- the cursor, and a run that CHAINS -- the anchor stays on the end you just laid, so a main
-- across town is one gesture after another. Right-click drops the run in progress;
-- right-click again puts the tool away.
--
-- Snapping is the other half of the road feel: a drag end lands on the nearest point ON an
-- existing main -- anywhere along it, not only at its ends -- or on the standpipe under a
-- tower or plant, which is how a network gets fed. Real geometry beats the angle magnet,
-- exactly as it does for roads.
--
-- It also owns the WATER VIEW while it is live: the city drained of colour, the ground and
-- the road surfaces turned see-through, and every main -- all of them BURIED, BURY studs
-- under the surface -- showing through. Out of the view the pipes are not drawn at all.
--
-- THE ROAD MAINS ARE DRAWN HERE, not on the server. Every road carries water and sewage, so
-- a city of streets is thousands of cylinders that only ever show inside this view -- the
-- server reasons about them off the road graph and the client draws them from the graph it
-- already mirrors, so none of it replicates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local ServiceTypes = require(ReplicatedStorage.City.ServiceTypes)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local PipeArt = require(ReplicatedStorage.City.PipeArt)
local BezierUtil = require(ReplicatedStorage.Road.BezierUtil)
local DataCache = require(ReplicatedStorage:WaitForChild("DataCache"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))
local CoverageOverlay = require(script.Parent:WaitForChild("CoverageOverlay"))
local PlacementCostHud = require(script.Parent.Parent:WaitForChild("HUD"):WaitForChild("PlacementCostHud"))

local WaterPipeController = {}

export type Mode = "Straight" | "Curved" | "AdvancedCurve" | "Freeform"

local REACH     = ServiceTypes.PipeReach
local SNAP      = ServiceTypes.PipeSnapDist
local SRC_REACH = ServiceTypes.PipeSourceReach
local SPAN      = ServiceTypes.PipeSpan
local MAX_RUN   = ServiceTypes.PipeMaxRun

local WATER_COLOR  = PipeArt.WATER
local SEWAGE_COLOR = PipeArt.SEWAGE
local BAD_COLOR    = Color3.fromRGB(232, 106, 100)
local THICK   = 2.4
local LATERAL = 1.7
local ANGLE_STEP = math.rad(15) -- the magnet, when snapping is on
local PREVIEW_SAMPLES = 20
-- Road mains: thin, laid just outside each kerb, one colour a side.
-- Road mains: down the MIDDLE of every road, water and sewage side by side.
local ROAD_THICK = 1.6
local ROAD_LAT   = 1.4 -- each main's distance off the centreline
local ROAD_STEP  = 24   -- studs between samples along a road curve
local ROAD_CAP   = 180  -- nearest N segments drawn (x4 parts each step: two mains + collars)
local ROAD_REFRESH = 1.0
-- Every main lies this far under the surface (the server lays hand-drawn ones at the same
-- depth), and the ground and roads go this see-through while the mains are showing.
local BURY = ServiceTypes.PipeDepth
local SEE_THROUGH = 0.5
local SEE_FOLDERS = { "_Ground", "_RoadMeshes" }
-- A water building's standpipe catches a drag end from further out than a pipe does: the
-- cursor anywhere on the building should land on it.
local TAP_SNAP = SRC_REACH + 16

local _enabled = false
local _bound = false
local _key = "WaterPipe"
local _mode: Mode = "Straight"
local _phase = "Idle" -- "Idle" | "HasStart" | "HasCurve" | "HasCurve2"
local _start: Vector3? = nil
local _curve: Vector3? = nil
local _curve2: Vector3? = nil
local _tangent: Vector3? = nil -- Freeform: the heading the chain flows along
local _angleSnap = true
local _snapped = false -- the last cursor landed on real geometry, so the magnet stands down
local _stateListener: ((Mode, boolean) -> ())? = nil

local _renderConn: RBXScriptConnection? = nil
local _inputConn: RBXScriptConnection? = nil
local _folderConn: RBXScriptConnection? = nil
local _preview: { BasePart } = {}
local _roads: { BasePart } = {}
local _marker: BasePart? = nil
local _seeConns: { RBXScriptConnection } = {}
local _nextRoadsAt = 0

local function carries(): (boolean, boolean)
	return _key ~= "SewagePipe", _key ~= "WaterPipe"
end

local function folder(): Instance
	return UiScratch.folder("WaterPipePlacement")
end

local function pipeFolder(): Folder?
	local city = Workspace:FindFirstChild("_City")
	local f = city and city:FindFirstChild("WaterPipes")
	return if f and f:IsA("Folder") then f :: Folder else nil
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- == Buried or not =============================================================
-- The pipes are always in the world; outside the water view they are simply not drawn.
-- LocalTransparencyModifier, not Transparency: the server owns the real value, and a
-- second client must not inherit this one's view.
local _shown = false

local function applyVisibility(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then d.LocalTransparencyModifier = if _shown then 0 else 1 end
	end
end

local function seeThrough(d: Instance)
	if d:IsA("BasePart") then d.LocalTransparencyModifier = if _shown then SEE_THROUGH else 0 end
end

local function setPipesShown(on: boolean)
	if on == _shown then return end
	_shown = on
	local f = pipeFolder()
	if f then applyVisibility(f) end
	-- The ground and the road surfaces go see-through so the buried mains show; chunks the
	-- terrain streams in while the view is open get the same treatment.
	for _, c in _seeConns do c:Disconnect() end
	table.clear(_seeConns)
	for _, name in SEE_FOLDERS do
		local root = Workspace:FindFirstChild(name)
		if not root then continue end
		for _, d in root:GetDescendants() do seeThrough(d) end
		if on then _seeConns[#_seeConns + 1] = root.DescendantAdded:Connect(seeThrough) end
	end
end

-- == Snapping ==================================================================

-- Every laid main, as its four control points. The server stamps them on the model so the
-- client never has to re-derive a curve from a bag of cylinders.
local function eachPipe(fn: (Model, { Vector3 }) -> ())
	local f = pipeFolder()
	if not f then return end
	for _, m in f:GetChildren() do
		if not m:IsA("Model") then continue end
		local p: { Vector3 } = {}
		local ok = true
		for i = 1, 4 do
			local x = tonumber(m:GetAttribute("C" .. tostring(i) .. "X"))
			local z = tonumber(m:GetAttribute("C" .. tostring(i) .. "Z"))
			if not (x and z) then ok = false break end
			p[i] = Vector3.new(x, 0, z)
		end
		if ok then fn(m, p) end
	end
end

local function samplePoints(p: { Vector3 }, n: number): { Vector3 }
	local out = table.create(n + 1)
	for i = 0, n do
		local q = BezierUtil.point(p[1], p[2], p[3], p[4], i / n)
		out[i + 1] = Vector3.new(q.X, 0, q.Z)
	end
	return out
end

local function closestOnSeg(a: Vector3, b: Vector3, p: Vector3): (Vector3, number)
	local dx, dz = b.X - a.X, b.Z - a.Z
	local len2 = dx * dx + dz * dz
	if len2 < 1e-6 then return a, flatDist(a, p) end
	local t = math.clamp(((p.X - a.X) * dx + (p.Z - a.Z) * dz) / len2, 0, 1)
	local q = Vector3.new(a.X + dx * t, 0, a.Z + dz * t)
	return q, flatDist(q, p)
end

local function polyLength(pts: { Vector3 }): number
	local total = 0
	for i = 1, #pts - 1 do total += flatDist(pts[i], pts[i + 1]) end
	return total
end

-- Where a road's two mains run: down the middle, water one side of the centreline and
-- sewage the other. The same offset refreshRoadMains draws them at, so a snap lands on the
-- pipe the player can see.
local function roadMainOffset(_seg: any): number
	return ROAD_LAT
end

-- The snap points, in priority order: a water building's standpipe, then anywhere along a
-- hand-drawn main, then anywhere along the main under a road. None of them needs to be a
-- node -- the cursor is projected onto the pipe, wherever along it.
local function snapGeometry(pos: Vector3): Vector3?
	local f = pipeFolder()
	local tapFolder = f and f:FindFirstChild("Taps")
	if tapFolder then
		local water, sewage = carries()
		for _, m in tapFolder:GetChildren() do
			local x, z = tonumber(m:GetAttribute("TX")), tonumber(m:GetAttribute("TZ"))
			if not (x and z) then continue end
			local kind = m:GetAttribute("TapKind")
			if (kind == "Water" and not water) or (kind == "Sewage" and not sewage) then continue end
			if flatDist(Vector3.new(x, 0, z), pos) <= TAP_SNAP then return Vector3.new(x, pos.Y, z) end
		end
	end

	local best: Vector3? = nil
	local bestD: number = SNAP
	eachPipe(function(_, p)
		local pts = samplePoints(p, 24)
		for i = 1, #pts - 1 do
			local q, d = closestOnSeg(pts[i], pts[i + 1], pos)
			if d <= bestD then best, bestD = q, d end
		end
	end)
	if best then return Vector3.new((best :: Vector3).X, pos.Y, (best :: Vector3).Z) end

	-- Road mains. A water-only run snaps to the water side, a sewage run to the sewage side.
	local water, sewage = carries()
	for _, seg in DataCache.GetSegments() do
		if typeof(seg.p0) ~= "Vector3" then continue end
		local chord = flatDist(seg.p0, seg.p3)
		if flatDist((seg.p0 + seg.p3) * 0.5, pos) > chord * 0.75 + 64 then continue end
		local offset = roadMainOffset(seg)
		local steps = math.clamp(math.ceil(chord / ROAD_STEP), 1, 16)
		local prev = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, 0)
		for t = 1, steps do
			local q = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t / steps)
			local flat = Vector3.new(q.X - prev.X, 0, q.Z - prev.Z)
			if flat.Magnitude > 0.2 then
				local perp = Vector3.new(-flat.Unit.Z, 0, flat.Unit.X) * offset
				for _, side in { -1, 1 } do
					if (side < 0 and not water) or (side > 0 and not sewage) then continue end
					local c, d = closestOnSeg(prev + perp * side, q + perp * side, pos)
					if d <= bestD then best, bestD = c, d end
				end
			end
			prev = q
		end
	end
	if best then return Vector3.new((best :: Vector3).X, pos.Y, (best :: Vector3).Z) end
	return nil
end

-- The angle magnet: hold the heading from `from` to a 15 degree step. Only consulted when
-- the cursor did NOT land on real geometry -- a tap or a main that is actually there must
-- never be dragged off to a round angle.
local function applyAngleSnap(from: Vector3, cursor: Vector3): Vector3
	if not _angleSnap then return cursor end
	local d = Vector3.new(cursor.X - from.X, 0, cursor.Z - from.Z)
	local len = d.Magnitude
	if len < 4 then return cursor end
	local a = math.round(math.atan2(d.X, d.Z) / ANGLE_STEP) * ANGLE_STEP
	return Vector3.new(from.X + math.sin(a) * len, cursor.Y, from.Z + math.cos(a) * len)
end

-- Where the cursor actually is for this gesture: geometry first, magnet second.
local function resolveCursor(ground: Vector3): Vector3
	local hit = snapGeometry(ground)
	_snapped = hit ~= nil
	if hit then return hit end
	local from = if _phase == "Idle" then nil elseif _curve2 then _curve2 elseif _curve then _curve else _start
	return if from then applyAngleSnap(from, ground) else ground
end

-- == Control points ============================================================
-- The same four modes the road tool draws with, and the same click sequence, so a player
-- who can lay a road can lay a main without learning anything new.

local function straightCp(s: Vector3, e: Vector3): { Vector3 }
	local ch = e - s
	return { s, s + ch / 3, s + ch * (2 / 3), e }
end

-- The one circular arc leaving `s` along `tangent` and landing on `e` -- the road tool's
-- Freeform continuation, so a chained main keeps a constant radius through a bend.
local function arcCp(s: Vector3, tangent: Vector3, e: Vector3): { Vector3 }
	local chord = Vector3.new(e.X - s.X, 0, e.Z - s.Z)
	local len = chord.Magnitude
	if len < 0.001 then return { s, s, e, e } end
	local c = chord / len
	local t = Vector3.new(tangent.X, 0, tangent.Z)
	t = if t.Magnitude > 1e-4 then t.Unit else c
	local cosT = math.clamp(t:Dot(c), -1, 1)
	local h = math.min(2 * len / (3 * math.max(1 + cosT, 0.08)), len * 2)
	local out = c * (2 * cosT) - t
	return { s, s + t * h, e - out * h, e }
end

local function exitTangent(p2: Vector3, p3: Vector3): Vector3
	local d = p3 - p2
	if d.Magnitude < 0.001 then return Vector3.xAxis end
	return Vector3.new(d.X, 0, d.Z).Unit
end

local function controlPoints(cursor: Vector3): { Vector3 }?
	local s = _start
	if not s then return nil end

	if _mode == "Straight" then
		if _phase == "HasStart" then return straightCp(s, cursor) end

	elseif _mode == "Curved" then
		if _phase == "HasStart" then
			return straightCp(s, cursor)
		elseif _phase == "HasCurve" and _curve then
			local q, e = _curve :: Vector3, cursor
			return { s, s + (q - s) * (2 / 3), e + (q - e) * (2 / 3), e }
		end

	elseif _mode == "Freeform" then
		if _phase == "HasStart" then
			-- With a heading, every click is one whole segment off the last exit tangent.
			-- Without one, this click is only picking the bend.
			if _tangent then return arcCp(s, _tangent :: Vector3, cursor) end
			return straightCp(s, cursor)
		elseif _phase == "HasCurve" and _curve then
			local q, e = _curve :: Vector3, cursor
			return { s, s + (q - s) * (2 / 3), e + (q - e) * (2 / 3), e }
		end

	elseif _mode == "AdvancedCurve" then
		if _phase == "HasStart" then
			return straightCp(s, cursor)
		elseif _phase == "HasCurve" and _curve then
			local p1 = _curve :: Vector3
			return { s, p1, cursor + (p1 - cursor) / 3, cursor }
		elseif _phase == "HasCurve2" and _curve and _curve2 then
			return { s, _curve :: Vector3, _curve2 :: Vector3, cursor }
		end
	end
	return nil
end

-- == Drawing ===================================================================

local function scratch(pool: { BasePart }, i: number): BasePart
	local p = pool[i]
	if p then return p end
	p = Instance.new("Part")
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Parent = folder()
	pool[i] = p
	return p
end

local function trim(pool: { BasePart }, keep: number)
	for i = #pool, keep + 1, -1 do
		pool[i]:Destroy()
		pool[i] = nil
	end
end

-- One length of pipe plus the collar at its far end, from `pool` slots i+1.. Returns the
-- last slot used. Shared by the drag ghost and the road mains so they look the same.
local function pipeLength(pool: { BasePart }, i: number, a: Vector3, b: Vector3, color: Color3,
	thick: number, offset: number, transparency: number): number
	local p = scratch(pool, i + 1)
	if not PipeArt.shapePipe(p, a, b, color, thick, offset) then return i end
	p.Transparency = transparency
	local c = scratch(pool, i + 2)
	PipeArt.shapeCollar(c, b, b - a, color, thick, offset)
	c.Transparency = transparency
	return i + 2
end

local function ghostPipe(i: number, a: Vector3, b: Vector3, color: Color3, offset: number): number
	return pipeLength(_preview, i, a, b, color, THICK, offset, 0.3)
end

local function roadPiece(i: number, a: Vector3, b: Vector3, color: Color3, offset: number): number
	return pipeLength(_roads, i, a, b, color, ROAD_THICK, offset, 0)
end

-- Every road carries both mains, so the water view draws them along every street: down the
-- middle, where the server assumes they are. Nearest ROAD_CAP
-- segments only, rebuilt on a slow timer as the camera moves -- a whole city of streets at
-- once is tens of thousands of parts nobody can see the far end of.
local function refreshRoadMains(force: boolean)
	if not force and os.clock() < _nextRoadsAt then return end
	_nextRoadsAt = os.clock() + ROAD_REFRESH

	local segs = DataCache.GetSegments()
	local cam = Workspace.CurrentCamera
	local eye = if cam then cam.CFrame.Position else Vector3.zero
	local near: { { d: number, seg: any } } = {}
	for _, seg in segs do
		if typeof(seg.p0) ~= "Vector3" then continue end
		near[#near + 1] = { d = ((seg.p0 + seg.p3) * 0.5 - eye).Magnitude, seg = seg }
	end
	table.sort(near, function(a, b) return a.d < b.d end)

	local i = 0
	for k = 1, math.min(#near, ROAD_CAP) do
		local seg = near[k].seg
		local offset = roadMainOffset(seg)
		local chord = (seg.p3 - seg.p0).Magnitude
		local steps = math.clamp(math.ceil(chord / ROAD_STEP), 1, 16)
		local prev: Vector3? = nil
		for t = 0, steps do
			local q = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t / steps)
			q = Vector3.new(q.X, q.Y - BURY, q.Z)
			if prev then
				i = roadPiece(i, prev, q, WATER_COLOR, -offset)
				i = roadPiece(i, prev, q, SEWAGE_COLOR, offset)
			end
			prev = q
		end
	end
	trim(_roads, i)
end

-- The ring on the point a drag end has snapped to, so the player sees the connection before
-- they click. Hidden whenever the cursor is only on open ground.
local function showMarker(at: Vector3?)
	if not at then
		if _marker then _marker.Transparency = 1 end
		return
	end
	local m = _marker
	if not m then
		local p = Instance.new("Part")
		p.Name = "SnapMarker"
		p.Shape = Enum.PartType.Cylinder
		p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(255, 255, 255)
		p.Size = Vector3.new(0.4, 7, 7)
		p.Parent = folder()
		_marker = p
		m = p
	end
	local mk = m :: BasePart
	mk.Transparency = 0.2
	mk.CFrame = CFrame.new(at.X, at.Y - BURY, at.Z) * CFrame.Angles(0, 0, math.rad(90))
end

local function clearPreview()
	trim(_preview, 0)
	trim(_roads, 0)
	if _marker then _marker:Destroy(); _marker = nil end
end

local function resetGesture()
	_phase = "Idle"
	_start = nil
	_curve = nil
	_curve2 = nil
	_tangent = nil
	trim(_preview, 0)
end

local function costOf(len: number): number
	local spec = ServiceTypes.get(_key)
	return math.ceil(len / SPAN) * (if spec then spec.cost else 0)
end

local function metres(studs: number): string
	return string.format("%d m", math.round(studs * RoadConstants.STUD_TO_METER))
end

local function update()
	local ground = CursorRay.ground()
	if not ground then
		trim(_preview, 0)
		showMarker(nil)
		PlacementCostHud.hide()
		return
	end
	local cursor = resolveCursor(ground)
	showMarker(if _snapped then cursor else nil)
	refreshRoadMains(false)

	local cp = controlPoints(cursor)
	if not cp then
		trim(_preview, 0)
		PlacementCostHud.showCost(nil, nil, if _snapped then "click to start \u{00B7} snapped" else "click to start the run")
		return
	end

	local pts = samplePoints(cp, PREVIEW_SAMPLES)
	-- Under the ground, where the main will actually lie.
	for i, q in pts do pts[i] = Vector3.new(q.X, ground.Y - BURY, q.Z) end
	local len = polyLength(pts)
	local over = len > MAX_RUN
	local water, sewage = carries()
	local both = water and sewage

	local n = 0
	for i = 1, #pts - 1 do
		if water then n = ghostPipe(n, pts[i], pts[i + 1], if over then BAD_COLOR else WATER_COLOR, if both then -LATERAL else 0) end
		if sewage then n = ghostPipe(n, pts[i], pts[i + 1], if over then BAD_COLOR else SEWAGE_COLOR, if both then LATERAL else 0) end
	end
	trim(_preview, n)

	if over then
		PlacementCostHud.showCost(nil, "that run is too long", metres(len))
	else
		PlacementCostHud.showCost(costOf(len), nil, metres(len))
	end
end

local function notifyState()
	if _stateListener then _stateListener(_mode, _angleSnap) end
end

-- == Public ====================================================================

-- The bulldozer shows the buried pipes too -- it can only delete what the player can see,
-- and a hidden pipe must not catch a click aimed at the house behind it.
function WaterPipeController.showPipes(on: boolean)
	setPipesShown(on or _enabled)
end

function WaterPipeController.setPipeKind(key: string)
	_key = key
end

function WaterPipeController.setMode(mode: Mode)
	if _mode == mode then return end
	_mode = mode
	resetGesture()
	notifyState()
end

function WaterPipeController.getMode(): Mode
	return _mode
end

function WaterPipeController.setAngleSnapEnabled(on: boolean)
	_angleSnap = on
	notifyState()
end

function WaterPipeController.isAngleSnapEnabled(): boolean
	return _angleSnap
end

-- The tool strip mirrors this tool's state; it is handed a callback rather than polling.
function WaterPipeController.setStateListener(fn: ((Mode, boolean) -> ())?)
	_stateListener = fn
end

function WaterPipeController.setEnabled(enabled: boolean)
	if enabled == _enabled then return end
	_enabled = enabled
	resetGesture()
	setPipesShown(enabled)
	CoverageOverlay.washCity(enabled)
	if enabled then
		refreshRoadMains(true) -- the streets' mains show on the first frame, not in a second
	else
		clearPreview()
		PlacementCostHud.hide()
	end
end

function WaterPipeController.isEnabled(): boolean
	return _enabled
end

function WaterPipeController.Init() end

function WaterPipeController.Bind()
	if _bound then return end
	_bound = true

	-- Pipes are buried by default, including the ones that arrive on a city load or while
	-- another player is drawing, so this watches the folder whether the tool is live or not.
	local function watch()
		local f = pipeFolder()
		if not f then return end
		applyVisibility(f)
		if _folderConn then _folderConn:Disconnect() end
		_folderConn = f.DescendantAdded:Connect(function(d)
			if d:IsA("BasePart") then d.LocalTransparencyModifier = if _shown then 0 else 1 end
		end)
	end
	watch()
	local city = Workspace:FindFirstChild("_City")
	if city then city.ChildAdded:Connect(function(c) if c.Name == "WaterPipes" then watch() end end) end
	Workspace.ChildAdded:Connect(function(c)
		if c.Name ~= "_City" then return end
		watch()
		c.ChildAdded:Connect(function(f) if f.Name == "WaterPipes" then watch() end end)
	end)

	_renderConn = RunService.RenderStepped:Connect(function()
		if not _enabled then return end
		update()
	end)

	_inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not _enabled or gameProcessed then return end

		if Settings.pressed("Back", input) or input.UserInputType == Enum.UserInputType.MouseButton2 then
			-- First press drops the run in progress, second puts the tool away -- the same
			-- two-stage cancel the road tool uses.
			if _phase ~= "Idle" then resetGesture() else WaterPipeController.setEnabled(false) end
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		local ground = CursorRay.ground()
		if not ground then return end
		local point = resolveCursor(ground)

		if _phase == "Idle" then
			_start = point -- the first click ANCHORS; it does not dig
			_phase = "HasStart"
			return
		end

		-- One click short of the end, every mode is just collecting control points.
		if _mode == "Curved" and _phase == "HasStart" then
			_curve = point; _phase = "HasCurve"; return
		elseif _mode == "Freeform" and _phase == "HasStart" and not _tangent then
			_curve = point; _phase = "HasCurve"; return
		elseif _mode == "AdvancedCurve" and _phase == "HasStart" then
			_curve = point; _phase = "HasCurve"; return
		elseif _mode == "AdvancedCurve" and _phase == "HasCurve" then
			_curve2 = point; _phase = "HasCurve2"; return
		end

		local cp = controlPoints(point)
		if not cp then return end
		if polyLength(samplePoints(cp, PREVIEW_SAMPLES)) > MAX_RUN then return end -- the preview says why
		Net.RequestPlaceService:FireServer("Pipe", _key, { cp = cp })

		-- Carry on from the end just laid, so a long main is one gesture after another.
		if _mode == "Freeform" then _tangent = exitTangent(cp[3], cp[4]) end
		_start = point
		_curve = nil
		_curve2 = nil
		_phase = "HasStart"
	end)

	notifyState()
end

function WaterPipeController.Start() end

function WaterPipeController.Cleanup()
	if _renderConn then _renderConn:Disconnect(); _renderConn = nil end
	if _inputConn then _inputConn:Disconnect(); _inputConn = nil end
	if _folderConn then _folderConn:Disconnect(); _folderConn = nil end
	clearPreview()
	CoverageOverlay.washCity(false)
	_enabled = false
	_bound = false
end

return WaterPipeController
