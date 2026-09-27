--!strict
-- Top-level bulldoze tool with its own dock page. Pick a delete mode from the tabs:
--   Click -- click one road / building / stop to remove it.
--   Brush -- hold LMB and sweep; everything under the round brush is removed on release.
--   Box   -- drag a rectangle; everything inside is removed on release.
-- Roads batch through RequestRemoveRoadSegments (one transaction per commit, chunked at
-- the server cap); buildings / stops demolish through their owning remotes. Reuses
-- DeleteHoverController for the white outlines and RoadPlacementSnapper for road picking.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Snapper = require(script.Parent.RoadPlacementSnapper)
local DeleteHover = require(script.Parent:WaitForChild("DeleteHoverController"))
local WaterPipeController = require(script.Parent:WaitForChild("WaterPipeController"))
local TransitClient = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("TransitClient"))
local SoundFX = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("SoundFX"))
local Theme = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Theme"))
local RoadConstants = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadConstants"))
local BezierUtil = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("BezierUtil"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))
local Glass = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Kit"):WaitForChild("Glass"))

local BulldozeController = {}

export type Mode = "Click" | "Brush" | "Box"

local MAX_BATCH_REMOVE = 256
local BRUSH_MIN, BRUSH_MAX, BRUSH_STEP = 12, 90, 6
local ACCUM_INTERVAL = 0.04
local DELETE_TINT = Color3.fromRGB(236, 98, 100)
local TARGET_FOLDERS = { "ZonedBuildings", "EmergencyServices", "Schools", "Transit", "Nature", "Creations", "PowerLines", "WaterPipes" }
local NATURE_CHUNK = 64  -- must not exceed NaturePlaceService.MAX_PER_CALL
-- Click-pick allowance around a prop's pivot (trunk base), in SCREEN pixels. This was a
-- fixed 7 studs, which is two completely different tools depending on zoom: a 58-pixel
-- grab radius with the camera close in (deleting props nowhere near the cursor) and a
-- 1.2-pixel target at 2500 studs out (nothing deletable at all). The clamps keep it sane
-- at both ends of the range.
local NATURE_PICK_PX = 22
local NATURE_PICK_MIN, NATURE_PICK_MAX = 2, 25
-- Props stand on the terrain and so does the ground point, so a small vertical gate costs
-- nothing on normal ground but stops a click on a bridge deck deleting the trees beneath it.
local NATURE_PICK_MAX_DY = 16

local _inited = false
local _bound = false
local _enabled = false
local _renderConn: RBXScriptConnection? = nil
local _inputConn: RBXScriptConnection? = nil
local _upConn: RBXScriptConnection? = nil
local _listener: ((enabled: boolean) -> ())? = nil

local _mode: Mode = "Click"
-- The underground view: pipes are buried, so the bulldozer only reaches them with this on
-- (ground see-through, pipes drawn). Off, a buried pipe must not catch a click aimed at
-- the house above it.
local _pipesView = false
local _brushRadius = 30
local _dragging = false
local _boxAnchor: Vector3? = nil
-- Last ground point seen during a box drag. Releasing over sky/water gives no ground hit,
-- and reading only the release point then dropped the whole selection on the floor.
local _boxLast: Vector3? = nil
-- Box orientation, captured at drag start from the camera yaw so the rectangle is drawn in
-- the player's view frame (rotatable by orbiting) instead of locked to the world axes.
local _boxRight: Vector3? = nil
local _boxFwd: Vector3? = nil
local _selectedSegments: { [number]: Vector3 } = {}
local _selectionOrder: { number } = {}
local _selectedBuildings: { Model } = {}
local _seenBuilding: { [Model]: boolean } = {}
local _accum = 0
local _outlineAccum = 0  -- throttles the dashed-outline rebuild (raycasts) off the frame rate

local _removeSegsRemote: RemoteEvent? = nil
local _demolishRemote: RemoteEvent? = nil
local _removeServiceRemote: RemoteEvent? = nil
local _transitCommandRemote: RemoteEvent? = nil
local _removeNatureRemote: RemoteEvent? = nil

local _panel: Frame? = nil
local _modeButtons: { [string]: TextButton } = {}
local _brushRow: Frame? = nil
local _brushValue: TextLabel? = nil

-- No RaycastParams here on purpose: every query below goes through Core.CursorRay, which
-- owns the filters, the ignore list (character + the whole _UI preview root) and the one
-- ray length. This tool used to keep three of its own and they drifted from its siblings'.

local function previewFolder(): Folder
	return UiScratch.folder("BulldozePreview")
end

-- Resolved fresh each call. The old code cached this list and only rebuilt it when it was
-- EMPTY, which needs all five folders to vanish at once -- so one folder destroyed and
-- recreated (TransitClient does exactly that) left a dead instance in the filter and made
-- that whole target class permanently unclickable until the tool was toggled off and on.
local function targetFolders(): { Instance }
	local targets: { Instance } = {}
	for _, name in TARGET_FOLDERS do
		if name == "WaterPipes" and not _pipesView then continue end
		local f = CursorRay.cityFolder(name)
		if f then table.insert(targets, f) end
	end
	return targets
end

local function groundPoint(): Vector3?
	return CursorRay.ground()
end

-- A horizontal (right, forward) basis from the camera's yaw. The box is drawn/tested in
-- this frame, so "forward" points into the screen and the rectangle rotates with the view.
local function groundFrame(): (Vector3, Vector3)
	local cam = Workspace.CurrentCamera
	local r = if cam then cam.CFrame.RightVector else Vector3.xAxis
	r = Vector3.new(r.X, 0, r.Z)
	r = if r.Magnitude > 1e-4 then r.Unit else Vector3.xAxis
	return r, Vector3.new(-r.Z, 0, r.X) -- forward = right rotated 90 deg in the ground plane
end

local function buildingUnderCursor(): Model?
	local hit = CursorRay.hitIn(targetFolders())
	return if hit then DeleteHover.FindBuildingFromInstance(hit.Instance) else nil
end

-- Nature props are non-queryable (CanQuery=false), so a raycast slips through them. Pick
-- the closest prop whose footprint the ground point lands inside instead -- same pivot
-- basis the brush/box use, so Click stays consistent with them.
local function natureUnderCursor(): Model?
	local p = groundPoint()
	if not p then return nil end
	local f = CursorRay.cityFolder("Nature")
	if not f then return nil end
	return CursorRay.nearestPivot(f, p, NATURE_PICK_PX, NATURE_PICK_MIN, NATURE_PICK_MAX, NATURE_PICK_MAX_DY)
end

local function flatDist(a: Vector3, b: Vector3): number
	return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
end

-- Cubic-bezier midpoint (t=0.5): a point guaranteed to sit on the segment.
local function segMidpoint(info: any): Vector3
	return info.p0 * 0.125 + info.p1 * 0.375 + info.p2 * 0.375 + info.p3 * 0.125
end

-- Region tests walk the whole curve, not just its midpoint: a segment long enough to cross
-- the brush/box can carry its midpoint well outside, which is why sweeps left roads standing.
local SEG_SAMPLES = 8
local function segCrosses(info: any, inside: (Vector3) -> boolean): boolean
	for i = 0, SEG_SAMPLES do
		if inside(BezierUtil.point(info.p0, info.p1, info.p2, info.p3, i / SEG_SAMPLES)) then
			return true
		end
	end
	return false
end

-- --------------------------------------------------------------- previews
-- Brush/box draw a white dashed outline made of camera-facing beams carrying the road dash
-- texture. A FIXED number of beams is used per shape (RING_SEGS / BOX_EDGE_SEGS*4): keeping
-- the count constant means beams are only ever re-posed, never toggled on/off between frames.
-- Toggling a boundary beam as an edge crossed a segment multiple was the flicker. Each beam's
-- TextureLength = its own length, so one dash+gap tile fills it. LIFT clears terrain bumps so
-- the billboard is never occluded (the other half of the flicker).
local RING_SEGS = 48       -- brush circle: fixed segment count
local BOX_EDGE_SEGS = 14   -- box: fixed segments per edge (4 edges -> 56 beams)
local OUTLINE_MIN_DT = 1 / 30  -- rebuild the outline at most 30x/s (the raycasts are the cost)
local DASH_THICK = 1.5     -- beam width (studs)
local LIFT = 2.5           -- studs above terrain: clears bumps so the billboard isn't occluded
local OUTLINE_COLOR = Color3.new(1, 1, 1)
-- The outline is drawn with camera-facing Beams, not Parts. A FaceCamera beam renders as a
-- flat ribbon that always squarely faces the camera, so it can't z-fight the terrain or
-- shimmer the way a thin neon Part does at grazing angles -- that was the flicker. Beams
-- and their attachments hang off one invisible host part and are pooled + toggled.
local _beamHost: Part? = nil
local _beamPool: { Beam } = {}
local _beamUsed = 0

local function terrainY(x: number, z: number): number
	return CursorRay.terrainY(x, z) or 0
end

local function beamHost(): Part
	if _beamHost and _beamHost.Parent then return _beamHost end
	local p = Instance.new("Part")
	p.Name = "BulldozeOutlineHost"
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false
	p.Transparency = 1; p.Size = Vector3.new(0.05, 0.05, 0.05); p.CFrame = CFrame.identity
	p.Parent = previewFolder()
	_beamHost = p
	return p
end

local function acquireBeam(i: number): Beam
	local beam = _beamPool[i]
	if beam then return beam end
	local host = beamHost()
	local a0 = Instance.new("Attachment"); a0.Parent = host
	local a1 = Instance.new("Attachment"); a1.Parent = host
	beam = Instance.new("Beam")
	beam.Attachment0 = a0; beam.Attachment1 = a1
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Width0 = DASH_THICK; beam.Width1 = DASH_THICK
	beam.Color = ColorSequence.new(OUTLINE_COLOR)
	beam.LightEmission = 1
	beam.Transparency = NumberSequence.new(0)
	-- Reuse the road's dashed line image. TextureLength is set per-beam to the segment
	-- length in drawDashedLoop, so exactly one dash+gap tile fills each segment -> a uniform
	-- dashed loop regardless of how the perimeter was sampled, and no per-frame phase flicker.
	beam.Texture = RoadConstants.DASH_TEXTURE
	beam.TextureMode = Enum.TextureMode.Wrap
	beam.Parent = host
	_beamPool[i] = beam
	return beam
end

local function hideOutline()
	for i = 1, _beamUsed do
		local b = _beamPool[i]
		if b then b.Enabled = false end
	end
	_beamUsed = 0
end
-- No hideRing/hideBox pair: brush and box share ONE beam pool, so there is only ever one
-- outline. "Hide the other shape" hid the shape being drawn -- every frame, while the
-- redraw ran at OUTLINE_MIN_DT -- which is what made both tools flicker.

-- Draw a closed loop, one textured beam per segment. Each beam's TextureLength = its own
-- length so a single dash+gap tile fills it: the road dash image supplies the dashes and
-- they stay uniform as the shape grows (no per-frame phase flicker).
local function drawDashedLoop(pts: { Vector3 })
	local n = #pts
	if n < 2 then hideOutline(); return end
	local used = 0
	for i = 1, n do
		local a = pts[i]
		local b = pts[(i % n) + 1]
		local len = (b - a).Magnitude
		if len > 1e-4 then
			used += 1
			local beam = acquireBeam(used)
			beam.Attachment0.WorldPosition = a
			beam.Attachment1.WorldPosition = b
			beam.TextureLength = len
			beam.Enabled = true
		end
	end
	for j = used + 1, _beamUsed do
		local b = _beamPool[j]
		if b then b.Enabled = false end
	end
	_beamUsed = used
end

local function updateRing(center: Vector3)
	local pts: { Vector3 } = table.create(RING_SEGS)
	for i = 0, RING_SEGS - 1 do
		local ang = (i / RING_SEGS) * math.pi * 2
		local x = center.X + math.cos(ang) * _brushRadius
		local z = center.Z + math.sin(ang) * _brushRadius
		pts[i + 1] = Vector3.new(x, terrainY(x, z) + LIFT, z)
	end
	drawDashedLoop(pts)
end

local function updateBox(a: Vector3, b: Vector3)
	local right = _boxRight or Vector3.xAxis
	local fwd = _boxFwd or Vector3.zAxis
	local au, av = a:Dot(right), a:Dot(fwd)
	local bu, bv = b:Dot(right), b:Dot(fwd)
	local uMin, uMax = math.min(au, bu), math.max(au, bu)
	local vMin, vMax = math.min(av, bv), math.max(av, bv)
	local function corner(u: number, v: number): Vector3 return right * u + fwd * v end
	local corners = { corner(uMin, vMin), corner(uMax, vMin), corner(uMax, vMax), corner(uMin, vMax) }
	local pts: { Vector3 } = {}
	for c = 1, 4 do
		local p0 = corners[c]
		local p1 = corners[(c % 4) + 1]
		local edge = p1 - p0
		for s = 0, BOX_EDGE_SEGS - 1 do
			local t = s / BOX_EDGE_SEGS
			local x = p0.X + edge.X * t
			local z = p0.Z + edge.Z * t
			pts[#pts + 1] = Vector3.new(x, terrainY(x, z) + LIFT, z)
		end
	end
	drawDashedLoop(pts)
end

-- --------------------------------------------------------------- selection
local function refreshRoadHighlight()
	local segments: { any } = {}
	for _, segId in _selectionOrder do
		if _selectedSegments[segId] then
			local segment = Snapper.getSegmentInfo(segId)
			if segment then table.insert(segments, segment) end
		end
	end
	DeleteHover.ShowRoadSelection(segments, "Bulldoze")
end

local function addSegment(segId: number)
	if _selectedSegments[segId] then return end
	local info = Snapper.getSegmentInfo(segId)
	if not info then return end
	_selectedSegments[segId] = segMidpoint(info)
	table.insert(_selectionOrder, segId)
end

local function addBuilding(m: Model)
	if _seenBuilding[m] then return end
	_seenBuilding[m] = true
	table.insert(_selectedBuildings, m)
end

local function clearSelection()
	table.clear(_selectedSegments)
	table.clear(_selectionOrder)
	table.clear(_selectedBuildings)
	table.clear(_seenBuilding)
end

-- Segments (midpoint) + buildings (pivot) within `radius` of `center`. Throttled by the
-- caller. ponytail: O(segments+buildings) per tick -- fine for these city sizes; add a
-- spatial grid if a huge map ever makes the brush stutter.
local function accumulateRadius(center: Vector3)
	local radius = _brushRadius
	local function inside(p: Vector3): boolean
		return flatDist(center, p) <= radius
	end
	for _, segId in Snapper.allSegmentIds() do
		local info = Snapper.getSegmentInfo(segId)
		if info and segCrosses(info, inside) then addSegment(segId) end
	end
	for _, f in targetFolders() do
		for _, m in f:GetChildren() do
			if m:IsA("Model") and flatDist(center, m:GetPivot().Position) <= _brushRadius then addBuilding(m) end
		end
	end
	refreshRoadHighlight()
	DeleteHover.ShowBuildingSelection(_selectedBuildings, "Bulldoze")
end

local function gatherRect(a: Vector3, b: Vector3)
	local right = _boxRight or Vector3.xAxis
	local fwd = _boxFwd or Vector3.zAxis
	local au, av = a:Dot(right), a:Dot(fwd)
	local bu, bv = b:Dot(right), b:Dot(fwd)
	local uMin, uMax = math.min(au, bu), math.max(au, bu)
	local vMin, vMax = math.min(av, bv), math.max(av, bv)
	local function inside(p: Vector3): boolean
		local pu, pv = p:Dot(right), p:Dot(fwd)
		return pu >= uMin and pu <= uMax and pv >= vMin and pv <= vMax
	end
	for _, segId in Snapper.allSegmentIds() do
		local info = Snapper.getSegmentInfo(segId)
		if info and segCrosses(info, inside) then addSegment(segId) end
	end
	for _, f in targetFolders() do
		for _, m in f:GetChildren() do
			if m:IsA("Model") and inside(m:GetPivot().Position) then addBuilding(m) end
		end
	end
	refreshRoadHighlight()
	DeleteHover.ShowBuildingSelection(_selectedBuildings, "Bulldoze")
end

-- --------------------------------------------------------------- removal
local function demolishBuilding(building: Model)
	SoundFX.play("Bulldoze")
	if building:GetAttribute("NatureKey") ~= nil then
		if _removeNatureRemote then _removeNatureRemote:FireServer({ building }) end
		return
	end
	-- Checked BEFORE BlueprintId: that attribute belongs to zoned buildings and means an
	-- entirely different id, so a creation must never fall through to it.
	local creationId = building:GetAttribute("CreationId")
	if typeof(creationId) == "number" then
		if _removeServiceRemote then _removeServiceRemote:FireServer("Creation", creationId) end
		return
	end
	local bpId = building:GetAttribute("BlueprintId")
	if typeof(bpId) == "string" then
		if _demolishRemote then _demolishRemote:FireServer(bpId) end
		return
	end
	local stopId = building:GetAttribute("StopId")
	if typeof(stopId) == "number" then
		if _transitCommandRemote then _transitCommandRemote:FireServer("removeStop", { id = stopId }) end
		return
	end
	local depotId = building:GetAttribute("DepotId")
	if typeof(depotId) == "number" then
		if _removeServiceRemote then _removeServiceRemote:FireServer("Transit", depotId) end
		return
	end
	local serviceId = building:GetAttribute("ServiceId")
	if typeof(serviceId) == "number" then
		-- Power poles carry a ServiceId too, but PowerService owns them and numbers its own
		-- poles from 1. Sending one down the "Emergency" path would delete whichever
		-- service building happened to share that id.
		-- Same story for a pipe run: WaterPipeService numbers its own segments from 1.
		local svcKind = building:GetAttribute("ServiceKind")
		local kind = if svcKind == "PowerLine" then "Power" elseif svcKind == "Pipe" then "Pipe" else "Emergency"
		if _removeServiceRemote then _removeServiceRemote:FireServer(kind, serviceId) end
		return
	end
	local schoolId = building:GetAttribute("SchoolId")
	if typeof(schoolId) == "number" then
		if _removeServiceRemote then _removeServiceRemote:FireServer("Education", schoolId) end
		return
	end
end

-- Send the staged selection: roads chunked into server-cap batches (one transaction each),
-- buildings/stops one at a time, spaced so the demolish remote is not spammed.
local function commitSelection()
	local batches: { { { id: number, point: Vector3 } } } = {}
	local cur: { { id: number, point: Vector3 } } = {}
	for _, segId in _selectionOrder do
		local point = _selectedSegments[segId]
		if point and Snapper.getSegmentInfo(segId) then
			cur[#cur + 1] = { id = segId, point = point }
			if #cur >= MAX_BATCH_REMOVE then batches[#batches + 1] = cur; cur = {} end
		end
	end
	if #cur > 0 then batches[#batches + 1] = cur end

	-- Nature props remove through their own batched remote (chunked at the server cap);
	-- everything else demolishes through its owning remote one at a time.
	local nature: { Model } = {}
	local buildings: { Model } = {}
	for _, m in _selectedBuildings do
		if m:GetAttribute("NatureKey") ~= nil then nature[#nature + 1] = m else buildings[#buildings + 1] = m end
	end
	if #batches > 0 or #nature > 0 or #buildings > 0 then SoundFX.play("Bulldoze") end
	clearSelection()
	DeleteHover.ClearRoad()
	DeleteHover.ClearBuildingSelection()

	local natureRemote = _removeNatureRemote
	if #nature > 0 and natureRemote then
		task.spawn(function()
			local chunk: { Model } = {}
			for _, m in nature do
				chunk[#chunk + 1] = m
				if #chunk >= NATURE_CHUNK then natureRemote:FireServer(chunk); chunk = {}; task.wait(0.1) end
			end
			if #chunk > 0 then natureRemote:FireServer(chunk) end
		end)
	end

	local segRemote = _removeSegsRemote
	if #batches > 0 and segRemote then
		task.spawn(function()
			for i, b in batches do
				if i > 1 then task.wait(0.15) end
				segRemote:FireServer(b)
			end
		end)
	end
	if #buildings > 0 then
		task.spawn(function()
			for _, m in buildings do
				if m.Parent then demolishBuilding(m) end
				task.wait(0.05)
			end
		end)
	end
end

-- --------------------------------------------------------------- hover / gesture
local function updateHover(dt: number)
	if not _enabled then return end

	_outlineAccum += dt
	local redraw = _outlineAccum >= OUTLINE_MIN_DT
	if redraw then _outlineAccum = 0 end

	if _mode == "Click" then
		hideOutline()
		local building = buildingUnderCursor() or natureUnderCursor()
		if building then DeleteHover.ClearRoad(); DeleteHover.ShowBuilding(building, "Bulldoze"); return end
		DeleteHover.ClearBuilding()
		local p = groundPoint()
		local segId = if p then Snapper.segmentUnderPoint(p) else nil
		if segId and p then
			DeleteHover.ShowRoadSegment(Snapper.getSegmentInfo(segId) :: any, "Bulldoze")
		else
			DeleteHover.ClearRoad()
		end
		return
	end

	if _mode == "Brush" then
		local center = groundPoint()
		if center then
			if redraw then updateRing(center) end
		else
			hideOutline()
		end
		if _dragging and center then
			_accum += dt
			if _accum >= ACCUM_INTERVAL then
				_accum = 0
				accumulateRadius(center)
			end
		end
		return
	end

	-- Box
	if _dragging and _boxAnchor then
		local cur = groundPoint()
		if cur then _boxLast = cur end
		if _boxLast and redraw then updateBox(_boxAnchor, _boxLast) end
	else
		hideOutline()
	end
end

local function beginAction()
	if not _enabled then return end

	if _mode == "Click" then
		local building = buildingUnderCursor() or natureUnderCursor()
		if building and building.Parent then
			DeleteHover.ClearBuilding()
			demolishBuilding(building)
			return
		end
		local p = groundPoint()
		local segId = if p then Snapper.segmentUnderPoint(p) else nil
		if segId then
			local info = Snapper.getSegmentInfo(segId)
			if info and _removeSegsRemote then
				DeleteHover.ClearRoad() -- the outline's target is about to be destroyed
				_removeSegsRemote:FireServer({ { id = segId, point = segMidpoint(info) } })
			end
		end
		return
	end

	if _mode == "Brush" then
		_dragging = true
		_accum = ACCUM_INTERVAL
		clearSelection()
		local center = groundPoint()
		if center then accumulateRadius(center) end
		return
	end

	-- Box
	_dragging = true
	_boxAnchor = groundPoint()
	_boxLast = _boxAnchor
	_boxRight, _boxFwd = groundFrame()
	clearSelection()
end

local function endDrag()
	if not _dragging then return end
	_dragging = false

	if _mode == "Box" then
		local a = _boxAnchor
		_boxAnchor = nil
		local cur = groundPoint() or _boxLast
		_boxLast = nil
		if a and cur then gatherRect(a, cur) end
		hideOutline()
	end
	commitSelection()
end

local function cancelAction()
	_dragging = false
	_boxAnchor = nil
	_boxLast = nil
	clearSelection()
	hideOutline()
	DeleteHover.Clear()
end

local function onInputBegan(input: InputObject, processed: boolean)
	if not _enabled then return end
	-- Escape only. Right mouse belongs to the camera now, so it must not drop the tool.
	if Settings.pressed("Back", input) then
		if _dragging or #_selectionOrder > 0 or #_selectedBuildings > 0 then
			cancelAction()
		else
			BulldozeController.setEnabled(false)
		end
		return
	end
	if processed then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		beginAction()
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		endDrag()
	end
end

-- --------------------------------------------------------------- mode + UI
-- The mode caption was a how-to line ("Click a road, building or stop to
-- remove it"), dropped with every other one; the panel's row labels say
-- what each control is.
local function refreshCaption() end

function BulldozeController.setMode(mode: Mode)
	if mode ~= "Click" and mode ~= "Brush" and mode ~= "Box" then return end
	_mode = mode
	cancelAction()
	hideOutline()
	for key, b in _modeButtons do
		local on = key == mode
		b.BackgroundColor3 = if on then Theme.Color.Accent else Theme.Color.BgRaised
		b.BackgroundTransparency = if on then 0 else 0.25
		b.TextColor3 = if on then Theme.Color.OnAccent else Theme.Color.TextSecondary
	end
	if _brushRow then _brushRow.Visible = mode == "Brush" end
	refreshCaption()
end

function BulldozeController.getMode(): Mode return _mode end

function BulldozeController.setStateListener(fn: (enabled: boolean) -> ())
	_listener = fn
end

function BulldozeController.setEnabled(on: boolean)
	if on == _enabled then return end
	_enabled = on
	WaterPipeController.showPipes(on and _pipesView)
	if on then
		TransitClient.setMode("bulldoze", true)
		if _panel then _panel.Visible = true end
		BulldozeController.setMode(_mode)
	else
		_dragging = false
		_boxAnchor = nil
		_boxLast = nil
		clearSelection()
		DeleteHover.Clear()
		hideOutline()
		TransitClient.setMode("bulldoze", false)
		if _panel then _panel.Visible = false end
	end
	if _listener then _listener(_enabled) end
end

function BulldozeController.isEnabled(): boolean
	return _enabled
end

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = inst
end

-- OPTIONS PANEL, not a dock page. Bulldoze is a TOOL, not a build category: it
-- has no catalogue to show, so a full-bleed shelf gave it a screen-wide surface
-- to hold three mode chips and a stepper. This is a small floating card above
-- the rail instead -- a label per row, its controls right-aligned.
function BulldozeController.InitPanel(gui: ScreenGui)
	local ToolRail = require(script.Parent:WaitForChild("ToolRail"))

	local root = Instance.new("Frame")
	root.Name = "BulldozeOptions"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -ToolRail.bottomInset())
	root.Size = UDim2.fromOffset(292, 0)
	root.AutomaticSize = Enum.AutomaticSize.Y
	root.Visible = false
	root.ZIndex = Theme.Z.Flyout
	Glass.apply(root, Theme.Radius.LG)
	root.Parent = gui
	_panel = root

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = root

	local col = Instance.new("UIListLayout")
	col.FillDirection = Enum.FillDirection.Vertical
	col.SortOrder = Enum.SortOrder.LayoutOrder
	col.Padding = UDim.new(0, 8)
	col.Parent = root

	-- One row: name on the left, controls hard right. Returns the controls holder.
	local function row(order: number, labelText: string): (Frame, Frame)
		local r = Instance.new("Frame")
		r.Name = labelText
		r.BackgroundTransparency = 1
		r.Size = UDim2.new(1, 0, 0, 26)
		r.LayoutOrder = order
		r.Parent = root

		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.AnchorPoint = Vector2.new(0, 0.5)
		l.Position = UDim2.new(0, 0, 0.5, 0)
		l.Size = UDim2.fromOffset(96, 22)
		l.Text = labelText
		l.TextColor3 = Theme.Color.TextPrimary
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextSize = Theme.TextSize.SM
		l.FontFace = Theme.Font.Label
		l.Parent = r

		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.AnchorPoint = Vector2.new(1, 0.5)
		holder.Position = UDim2.new(1, 0, 0.5, 0)
		holder.AutomaticSize = Enum.AutomaticSize.X
		holder.Size = UDim2.fromOffset(0, 26)
		holder.Parent = r

		local hl = Instance.new("UIListLayout")
		hl.FillDirection = Enum.FillDirection.Horizontal
		hl.VerticalAlignment = Enum.VerticalAlignment.Center
		hl.SortOrder = Enum.SortOrder.LayoutOrder
		hl.Padding = UDim.new(0, 4)
		hl.Parent = holder
		return r, holder
	end

	-- Mode: the three bulldoze gestures, as chips.
	local _, modeHolder = row(1, "Mode")
	local modeBtns: { [string]: TextButton } = {}
	for i, key in { "Click", "Brush", "Box" } do
		local b = Instance.new("TextButton")
		b.Name = key
		b.AutoButtonColor = false
		b.AutomaticSize = Enum.AutomaticSize.X
		b.Size = UDim2.fromOffset(0, 24)
		b.Text = key
		b.TextSize = Theme.TextSize.XS
		b.FontFace = Theme.Font.Bold
		b.TextColor3 = Theme.Color.TextSecondary
		b.BackgroundColor3 = Theme.Color.BgRaised
		b.BackgroundTransparency = 0.25
		b.BorderSizePixel = 0
		b.LayoutOrder = i
		b.Parent = modeHolder
		corner(b, 6)
		local bp = Instance.new("UIPadding")
		bp.PaddingLeft = UDim.new(0, 10)
		bp.PaddingRight = UDim.new(0, 10)
		bp.Parent = b
		b.Activated:Connect(function()
			BulldozeController.setMode(key :: any)
		end)
		modeBtns[key] = b
	end
	_modeButtons = modeBtns

	-- Brush size: only meaningful while the Brush gesture is up.
	local brushRow, brushHolder = row(2, "Brush size")
	brushRow.Visible = false
	_brushRow = brushRow
	local function stepBtn(txt: string, order: number, delta: number)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(24, 24)
		b.BackgroundColor3 = Theme.Color.BgRaised
		b.BackgroundTransparency = 0.2
		b.Text = txt
		b.TextColor3 = Theme.Color.TextPrimary
		b.TextSize = 16
		b.FontFace = Theme.Font.Bold
		b.AutoButtonColor = true
		b.BorderSizePixel = 0
		b.LayoutOrder = order
		b.Parent = brushHolder
		corner(b, 6)
		b.Activated:Connect(function()
			_brushRadius = math.clamp(_brushRadius + delta, BRUSH_MIN, BRUSH_MAX)
			if _brushValue then
				_brushValue.Text = tostring(_brushRadius)
			end
		end)
	end
	stepBtn("\u{2212}", 1, -BRUSH_STEP)
	local val = Instance.new("TextLabel")
	val.BackgroundTransparency = 1
	val.Size = UDim2.fromOffset(34, 24)
	val.Text = tostring(_brushRadius)
	val.TextColor3 = Theme.Color.TextPrimary
	val.TextSize = Theme.TextSize.SM
	val.FontFace = Theme.Font.Bold
	val.LayoutOrder = 2
	val.Parent = brushHolder
	_brushValue = val
	stepBtn("+", 3, BRUSH_STEP)

	-- Pipes: the underground view on or off.
	local _, pipeHolder = row(3, "Pipes")
	local pipeBtn = Instance.new("TextButton")
	pipeBtn.AutoButtonColor = false
	pipeBtn.AutomaticSize = Enum.AutomaticSize.X
	pipeBtn.Size = UDim2.fromOffset(0, 24)
	pipeBtn.TextSize = Theme.TextSize.XS
	pipeBtn.FontFace = Theme.Font.Bold
	pipeBtn.BackgroundColor3 = Theme.Color.BgRaised
	pipeBtn.BackgroundTransparency = 0.25
	pipeBtn.BorderSizePixel = 0
	pipeBtn.Parent = pipeHolder
	corner(pipeBtn, 6)
	local pbp = Instance.new("UIPadding")
	pbp.PaddingLeft = UDim.new(0, 10)
	pbp.PaddingRight = UDim.new(0, 10)
	pbp.Parent = pipeBtn
	local function paintPipeBtn()
		pipeBtn.Text = if _pipesView then "Showing" else "Hidden"
		pipeBtn.TextColor3 = if _pipesView then Theme.Color.TextPrimary else Theme.Color.TextSecondary
	end
	pipeBtn.Activated:Connect(function()
		_pipesView = not _pipesView
		paintPipeBtn()
		WaterPipeController.showPipes(_enabled and _pipesView)
	end)
	paintPipeBtn()

	BulldozeController.setMode(_mode)
end

function BulldozeController.Init()
	if _inited then return end
	_inited = true
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_removeSegsRemote = Net.RequestRemoveRoadSegments
	_demolishRemote = Net.RequestDemolishBuilding
	_removeServiceRemote = Net.RequestRemoveService
	_transitCommandRemote = Net.RequestTransitCommand
	_removeNatureRemote = Net.RequestRemoveNature
end

function BulldozeController.Bind()
	if _bound then return end
	_bound = true
	_renderConn = RunService.RenderStepped:Connect(updateHover)
	_inputConn = UserInputService.InputBegan:Connect(onInputBegan)
	_upConn = UserInputService.InputEnded:Connect(onInputEnded)
	-- No CharacterAdded hook: CursorRay resolves the character on every query, so a respawn
	-- can no longer leave a stale ignore list behind.
end

function BulldozeController.Unbind()
	if _renderConn then _renderConn:Disconnect() _renderConn = nil end
	if _inputConn then _inputConn:Disconnect() _inputConn = nil end
	if _upConn then _upConn:Disconnect() _upConn = nil end
	_bound = false
end

function BulldozeController.Cleanup()
	BulldozeController.setEnabled(false)
	BulldozeController.Unbind()
	DeleteHover.Clear()
	_inited = false
end

return BulldozeController
