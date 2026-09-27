--!strict
-- NodeToolView -- the Cities: Skylines "Node Controller", in-game.
--
-- Pick a junction, then set its corner RADIUS, choose whether its plate is FLAT or rides
-- the roads' grades, and per arm: push the mouth IN or OUT of the junction and swing the
-- ANGLE the road arrives at.
--
-- The arm dot IS the arm's control -- drag it along its road to set the setback, swing it
-- round the node to set the angle. Every value is a typed field as well, and none of them
-- is a slider: a junction should be settable to a round number, not to whichever number a
-- pixel column happened to land on.
--
-- Radius, setback and flat are stored per segment END (RoadTypes.Segment.startCorner/...)
-- and consumed by IntersectionRenderer, so the junction mesh, the lane paths, the plot
-- clearances and the NPC stop lines all move off one number.
-- Angle is NOT stored: it rotates that end's own bezier handle, which is ordinary road
-- geometry, so it rides the existing move remote and is priced and undone like any move.
--
-- The client sends ids and values only. RoadService.shapeJunction clamps every value to
-- RoadConstants.NODE_* and owns all writes.

local NodeToolView = {}
local _started = false

function NodeToolView.Start()
	if _started then return end
	_started = true

	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local UserInputService = game:GetService("UserInputService")
	local Workspace = game:GetService("Workspace")

	local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
	local uiFolder = script.Parent.Parent:WaitForChild("UI")
	-- Rides the same UIScale as CityUI: this gui's pill and side panel are positioned to sit
	-- alongside scaled HUD surfaces, so it has to shrink with them or they cross over.
	local HudScale = require(uiFolder:WaitForChild("HudScale"))
	local UITheme = require(uiFolder:WaitForChild("Theme"))
	local PanelSlots = require(uiFolder:WaitForChild("PanelSlots"))
	local Icons = require(uiFolder:WaitForChild("Icons"))
	-- Panel chrome and buttons come from the shared Kit, so this tool inherits the HUD's
	-- glass, capsules, hover/press states and click sound instead of drawing its own.
	local kitFolder = uiFolder:WaitForChild("Kit")
	local Glass = require(kitFolder:WaitForChild("Glass"))
	local KitButton = require(kitFolder:WaitForChild("Button"))
	local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
	local BezierUtil = require(ReplicatedStorage.Road.BezierUtil)
	local RoadMoveGeometry = require(ReplicatedStorage.Road.RoadMoveGeometry)
	local IntersectionRenderer = require(ReplicatedStorage.Road.IntersectionRenderer)
	local DataCache = require(ReplicatedStorage.DataCache)
	local LOD = require(ReplicatedStorage.Shared.LOD)

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
	local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))
	local moveRemote = Net:WaitForRemote("RequestMoveRoad") :: RemoteEvent
	if not moveRemote then
		warn("[NodeToolView] RequestMoveRoad missing -- aborting")
		_started = false
		return
	end

	-- Chrome is the shared Theme's, so whatever restyles the HUD restyles this tool too --
	-- it used to carry its own near-black palette and Gotham type, which is what made it
	-- read as a different game's UI. Selection is the HUD accent (cyan chrome is banned
	-- project-wide; see the SnapConstants indicator palette).
	local COL_TEXT   = UITheme.Color.TextPrimary
	local COL_MUTED  = UITheme.Color.TextSecondary
	local COL_FIELD  = UITheme.Color.BgRaised
	local COL_ACCENT = UITheme.Color.Accent
	-- The two world-space dot colours stay local: they are marks painted on the ground
	-- against grass and asphalt, not chrome, so the panel palette has no say over them.
	local COL_NODE   = Color3.fromRGB(150, 150, 158)
	local COL_ARM    = Color3.fromRGB(244, 244, 248)

	local CORNER_MIN = RoadConstants.NODE_CORNER_MIN
	local CORNER_MAX = RoadConstants.NODE_CORNER_MAX
	local OFFSET_MIN = RoadConstants.NODE_OFFSET_MIN
	local OFFSET_MAX = RoadConstants.NODE_OFFSET_MAX
	local ANGLE_MAX  = RoadConstants.NODE_ANGLE_MAX_DEG
	local DEFAULT_CORNER = RoadConstants.JUNCTION_CORNER_RADIUS

	-- Screen pixels the cursor must travel before a press on a dot becomes a drag rather
	-- than a click. Below it the gesture still selects, so picking an arm stays a click.
	local DRAG_SLOP = 4
	-- Degrees of swing a setback drag absorbs before it counts as an angle edit. A drag
	-- along the arm is never perfectly straight, and an angle edit REBUILDS the road (new
	-- segment id, priced move) -- so nudging a mouth in and out must not quietly do that.
	local ANGLE_DEADZONE = 2.5

	type Arm = {
		segId: number,
		atStart: boolean,
		dir: Vector3,
		width: number,
		corner: number?,
		offset: number?,
		-- Node-level, carried on every arm (see RoadTypes.Segment.startFlat).
		flat: boolean?,
		mouth: number,
	}

	local _active = false
	local _nodeId: number? = nil
	local _segId: number? = nil
	-- Set when an angle edit is in flight: the server rebuilds that segment under a NEW
	-- id, so the old selection dies. Re-pick the arm pointing the same way once the
	-- refreshed segments arrive, instead of dumping the player back to the node.
	local _reselectDir: Vector3? = nil
	-- Handles as they stood when the arm was selected. The angle is absolute against
	-- THAT, so coming back to 0 restores exactly what was there.
	local _baseP1: Vector3? = nil
	local _baseP2: Vector3? = nil

	local _armsByNode: { [number]: { Arm } } = {}

	-- Live arm-dot drag. Nothing is sent while it is in hand: the dot and the panel fields
	-- preview the values and ONE commit goes out on release, so a junction rebuilds once per
	-- gesture rather than once per mouse-move.
	local _dragArm: Arm? = nil
	local _dragDir: Vector3? = nil    -- the arm's heading when the drag began
	local _dragCenter: Vector3? = nil -- its node's position, likewise
	local _dragBase = 0
	local _dragOffset = 0
	local _dragAngle = 0
	local _dragMoved = false
	local _pressPart: BasePart? = nil
	local _pressStart: Vector2? = nil
	local _pressWasPicked = false

	-- ------------------------------------------------------------------ data --

	local function rebuildArms()
		local byNode: { [number]: { Arm } } = {}
		for _, seg in DataCache.GetSegments() do
			if seg.isArc or seg.isRoundabout then continue end
			for _, atStart in { true, false } do
				local nodeId = if atStart then seg.startNode else seg.endNode
				if typeof(nodeId) ~= "number" then continue end
				local raw = if atStart
					then BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, 0)
					else -BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, 1)
				local flat = Vector3.new(raw.X, 0, raw.Z)
				if flat.Magnitude < 1e-6 then
					flat = if atStart
						then Vector3.new(seg.p3.X - seg.p0.X, 0, seg.p3.Z - seg.p0.Z)
						else Vector3.new(seg.p0.X - seg.p3.X, 0, seg.p0.Z - seg.p3.Z)
				end
				if flat.Magnitude < 1e-6 then continue end
				local list = byNode[nodeId]
				if not list then
					list = {}
					byNode[nodeId] = list
				end
				table.insert(list, {
					segId = seg.id,
					atStart = atStart,
					dir = flat.Unit,
					width = RoadTypeCatalog.getOrDefault(seg.roadType).width,
					corner = if atStart then seg.startCorner else seg.endCorner,
					offset = if atStart then seg.startOffset else seg.endOffset,
					flat = if atStart then seg.startFlat else seg.endFlat,
					mouth = 0,
				})
			end
		end

		_armsByNode = {}
		for nodeId, list in byNode do
			-- A single arm is a dead end: no corner to round, no gore to push out of.
			local pos = DataCache.GetNodeById(nodeId)
			if not pos or #list < 2 then continue end
			-- The same call the server trims with, so the arm dots land on the mouths the
			-- player can see. (It omits the server's steep-approach apron extension, which
			-- only matters for picking a dot, not for the value being edited.)
			local dists = IntersectionRenderer.armBoundaryDistances(pos, list :: any)
			for i, arm in list do
				arm.mouth = dists[i] or arm.width * 0.5
			end
			table.sort(list, function(a, b) return a.segId < b.segId end)
			_armsByNode[nodeId] = list
		end
	end

	local function armsOf(nodeId: number?): { Arm }?
		return if nodeId then _armsByNode[nodeId] else nil
	end

	local function selectedArm(): Arm?
		local arms = armsOf(_nodeId)
		if not arms or not _segId then return nil end
		for _, arm in arms do
			if arm.segId == _segId then return arm end
		end
		return nil
	end

	-- The node's corner radius: the largest any of its arms asks for, since a corner
	-- rounds at the larger of its pair. nil anywhere means that arm is on the default.
	local function nodeCornerRadius(nodeId: number): number
		local arms = armsOf(nodeId)
		if not arms then return DEFAULT_CORNER end
		local best = 0
		for _, arm in arms do
			best = math.max(best, arm.corner or DEFAULT_CORNER)
		end
		return if best > 0 then best else DEFAULT_CORNER
	end

	-- Whether this junction's plate is levelled. Node-level, so any arm carrying the flag
	-- answers for the node -- an arm drawn in after the fact arrives without it.
	local function nodeIsFlat(nodeId: number): boolean
		local arms = armsOf(nodeId)
		if not arms then return false end
		for _, arm in arms do
			if arm.flat then return true end
		end
		return false
	end

	-- The distance the junction geometry puts this arm's mouth at on its own, with the
	-- player's setback taken back out: the zero the arm dot is dragged relative to.
	local function baseMouth(arm: Arm): number
		return arm.mouth - (arm.offset or 0)
	end

	-- ---------------------------------------------------------------- world --

	local _dots = Instance.new("Folder")
	_dots.Name = "NodeToolDots"
	_dots.Parent = Workspace

	local _nodePool: { BasePart } = {}
	local _armPool: { BasePart } = {}
	local _nodeCount = 0
	local _armCount = 0

	local DISC_THICK = 0.15
	local DISC_LIFT = 0.6

	local refreshPanel: () -> ()
	local render: () -> ()

	local function discCFrame(pos: Vector3): CFrame
		return CFrame.new(pos.X, pos.Y + DISC_LIFT, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
	end

	-- ponytail: no ClickDetector any more. It reports a completed CLICK and nothing else --
	-- no press, no release -- which cannot express a drag, and it fired on the release of
	-- one, deselecting the arm the player had just finished dragging. Picking is a raycast
	-- against this folder instead (CanQuery is already on for exactly that).
	local function pooledDisc(pool: { BasePart }, idx: number): BasePart
		local part = pool[idx]
		if part then
			part.Parent = _dots
			return part
		end
		part = Instance.new("Part")
		part.Shape = Enum.PartType.Cylinder
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CastShadow = false
		part.CanQuery = true
		part.Material = Enum.Material.Neon
		part.Parent = _dots
		pool[idx] = part
		return part
	end

	-- Where an arm's dot belongs: on its real mouth, or on the live preview while it is
	-- being dragged. Preview and commit both rotate the arm's start-of-drag heading with
	-- RoadMoveGeometry.rotateY, so what the dot shows is what the road ends up doing.
	local function armDotPos(center: Vector3, arm: Arm): Vector3
		local dir = _dragDir
		-- Matched by id, not by table identity: a replication tick mid-drag rebuilds every
		-- Arm table, and identity would silently drop the preview half way through a gesture.
		if dir and _dragArm and _dragArm.segId == arm.segId then
			local swung = RoadMoveGeometry.rotateY(dir, Vector3.zero, math.rad(_dragAngle))
			return center + swung * math.max(_dragBase + _dragOffset, 0.1)
		end
		return center + arm.dir * arm.mouth
	end

	local function onNodeClick(part: BasePart)
		local id = part:GetAttribute("NodeId")
		if typeof(id) ~= "number" then return end
		if _nodeId == id then
			_nodeId, _segId = nil, nil
		else
			_nodeId, _segId = id, nil
		end
		_baseP1, _baseP2, _reselectDir = nil, nil, nil
		render()
	end

	local selectArm: (segId: number) -> ()

	-- Letting go of the arm that was already selected. Picking a NEW one happens on press
	-- instead, so the drag that may follow already knows what it has (see beginPress).
	local function dropArm()
		_segId = nil
		_baseP1, _baseP2 = nil, nil
		render()
	end

	render = function()
		_nodeCount = 0
		_armCount = 0

		if _active then
			local camera = Workspace.CurrentCamera
			local eye = camera and camera.CFrame.Position

			for nodeId in _armsByNode do
				local pos = DataCache.GetNodeById(nodeId)
				if not pos or LOD.tierAt(pos, eye) >= LOD.CULL then continue end
				_nodeCount += 1
				local part = pooledDisc(_nodePool, _nodeCount)
				part.Name = "NodeDot"
				local picked = _nodeId == nodeId
				local d = if picked then 5.5 else 3.2
				part.Color = if picked then COL_ACCENT else COL_NODE
				part.Transparency = if picked then 0.1 else 0.35
				part.Size = Vector3.new(DISC_THICK, d, d)
				part.CFrame = discCFrame(pos)
				part:SetAttribute("NodeId", nodeId)
			end

			local arms = armsOf(_nodeId)
			local center = if _nodeId then DataCache.GetNodeById(_nodeId) else nil
			if arms and center then
				for _, arm in arms do
					_armCount += 1
					local part = pooledDisc(_armPool, _armCount)
					part.Name = "ArmDot"
					local picked = _segId == arm.segId
					local d = if picked then 4.2 else 3.0
					part.Color = if picked then COL_ACCENT else COL_ARM
					part.Transparency = if picked then 0 else 0.25
					part.Size = Vector3.new(DISC_THICK, d, d)
					part.CFrame = discCFrame(armDotPos(center, arm))
					part:SetAttribute("SegId", arm.segId)
				end
			end
		end

		for i = _nodeCount + 1, #_nodePool do _nodePool[i].Parent = nil end
		for i = _armCount + 1, #_armPool do _armPool[i].Parent = nil end
		refreshPanel()
	end

	-- ------------------------------------------------------------------- ui --

	local function corner(inst: Instance, radius: number)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, radius)
		c.Parent = inst
	end

	local function makeLabel(parent: Instance, text: string, size: number, colour: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.FontFace = UITheme.Font.Label
		l.Text = text
		l.TextSize = size
		l.TextColor3 = colour
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Size = UDim2.new(1, 0, 0, size + 4)
		l.Parent = parent
		return l
	end

	-- Every button here is the shared Kit capsule: same fill, hairline, hover / press /
	-- selected states and click sound as every other button in the game.
	local function makeButton(parent: Instance, text: string, order: number, onClick: (() -> ())?): KitButton.Button
		return KitButton.new({
			text = text,
			parent = parent,
			compact = true,
			size = UDim2.new(1, 0, 0, 26),
			layoutOrder = order,
			onClick = onClick,
		})
	end

	type NumberRow = { frame: Frame, set: (number) -> () }
	type ToggleRow = { frame: Frame, set: (boolean) -> () }

	type NumberSpec = {
		label: string,
		order: number,
		min: number,   -- stored units (studs / degrees), matching the server's clamp
		max: number,
		step: number,  -- one stepper press, in DISPLAYED units
		unit: string,
		fmt: string,
		toDisplay: ((number) -> number)?,
		fromDisplay: ((number) -> number)?,
		onCommit: (number) -> (),
	}

	-- A typed value, not a slider. ponytail: these rows WERE sliders, which read out in
	-- metres and degrees but were driven by pixel columns -- so a junction could never be
	-- set to a round number, and on a narrow panel one pixel was most of a metre. The field
	-- is now the value: type it, or nudge it a step at a time. Commit still fires once per
	-- change (the slider's release hook), so one junction rebuild per edit.
	local function numberRow(parent: Instance, spec: NumberSpec): NumberRow
		local toDisplay = spec.toDisplay or function(v: number): number return v end
		local fromDisplay = spec.fromDisplay or function(v: number): number return v end

		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 38)
		row.LayoutOrder = spec.order
		row.Parent = parent

		local caption = makeLabel(row, spec.label, UITheme.TextSize.XS, COL_MUTED)
		caption.Size = UDim2.new(1, 0, 0, 14)

		local box = Instance.new("TextBox")
		box.AnchorPoint = Vector2.new(0.5, 0)
		box.Position = UDim2.new(0.5, 0, 0, 16)
		box.Size = UDim2.new(1, -64, 0, 22)
		box.BackgroundColor3 = COL_FIELD
		box.BorderSizePixel = 0
		box.ClearTextOnFocus = false
		box.FontFace = UITheme.Font.Label
		box.Text = ""
		box.TextSize = UITheme.TextSize.XS
		box.TextColor3 = COL_TEXT
		box.Parent = row
		corner(box, UITheme.Radius.SM)
		local boxEdge = Instance.new("UIStroke")
		boxEdge.Color = UITheme.Color.StrokeSoft
		boxEdge.Thickness = UITheme.StrokeWidth.Thin
		boxEdge.Parent = box

		local value = math.clamp(0, spec.min, spec.max)
		local function show()
			box.Text = string.format(`{spec.fmt} %s`, toDisplay(value), spec.unit)
		end

		local function commit(v: number)
			local clamped = math.clamp(v, spec.min, spec.max)
			local changed = math.abs(clamped - value) > 1e-4
			value = clamped
			show()
			if changed then spec.onCommit(value) end
		end

		-- Steppers move by whole DISPLAY units (1 m, 1 deg) -- the point of the field is that
		-- the numbers on it are round -- so the step is taken in display space and converted.
		local function stepper(text: string, rightEdge: boolean, delta: number)
			-- Kit capsules, sized square and pinned to the row's two edges: the field sits in
			-- the gap between them (a UIListLayout can't express that, so these are placed).
			local b = KitButton.new({
				text = text,
				parent = row,
				compact = true,
				size = UDim2.fromOffset(26, 22),
				textSize = UITheme.TextSize.SM,
				onClick = function()
					commit(fromDisplay(toDisplay(value) + delta))
				end,
			})
			b.Instance.AnchorPoint = Vector2.new(if rightEdge then 1 else 0, 0)
			b.Instance.Position = UDim2.new(if rightEdge then 1 else 0, 0, 0, 16)
		end
		stepper("\u{2212}", false, -spec.step)
		stepper("+", true, spec.step)

		box.FocusLost:Connect(function()
			-- Take the first number out of whatever was typed, so "12", "12 m" and "-3.5m" all
			-- work; text with no number in it snaps back to the live value.
			local typed = tonumber(string.match(box.Text, "%-?%d+%.?%d*"))
			if typed then commit(fromDisplay(typed)) else show() end
		end)

		show()
		return { frame = row, set = function(v: number)
			value = math.clamp(v, spec.min, spec.max)
			show()
		end }
	end

	-- Two mutually exclusive chips on one row. A checkbox would leave the unticked state
	-- unnamed, and here BOTH states are a real, describable choice -- a levelled plate or
	-- one that rides the roads' grades -- so both get a label.
	local function toggleRow(parent: Instance, label: string, order: number, offText: string, onText: string, onCommit: (boolean) -> ()): ToggleRow
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 38)
		row.LayoutOrder = order
		row.Parent = parent

		local caption = makeLabel(row, label, UITheme.TextSize.XS, COL_MUTED)
		caption.Size = UDim2.new(1, 0, 0, 14)

		local chips: { KitButton.Button } = {}
		local state = false
		local function paint()
			for i, b in chips do
				-- The Kit's own selected look (accent fill, lighter ring) -- the same thing a
				-- selected road card or draw mode wears.
				b:SetSelected((i == 2) == state)
			end
		end
		for i, text in { offText, onText } do
			local want = i == 2
			local b = KitButton.new({
				text = text,
				parent = row,
				compact = true,
				size = UDim2.new(0.5, -3, 0, 22),
				onClick = function()
					if state == want then return end
					state = want
					paint()
					onCommit(want)
				end,
			})
			b.Instance.Position = UDim2.new(if i == 1 then 0 else 0.5, if i == 1 then 0 else 3, 0, 16)
			chips[i] = b
		end
		paint()
		return { frame = row, set = function(v: boolean)
			state = v
			paint()
		end }
	end

	local _gui: ScreenGui
	local _panel: Frame
	local _banner: Frame
	local _title: TextLabel
	local _hint: TextLabel
	local _armList: Frame
	local _armButtons: { KitButton.Button } = {}
	local _armSection: Frame
	local _radius: NumberRow
	local _flat: ToggleRow
	local _offset: NumberRow
	local _angle: NumberRow
	local _pill: TextButton
	local _pillEdge: UIStroke
	local _pillIcon: ImageLabel
	local _pillCaption: TextLabel

	-- The panel talks metres, the network talks studs. STUD_TO_METER rides WORLD_SCALE, so
	-- this is the same conversion every other measurement the player sees goes through.
	local function toMeters(studs: number): number
		return studs * RoadConstants.STUD_TO_METER
	end
	local function toStuds(meters: number): number
		return meters / RoadConstants.STUD_TO_METER
	end

	local function sendJunction(fields: { [string]: any })
		local nodeId = _nodeId
		if not nodeId then return end
		fields.kind = "junction"
		fields.node = nodeId
		moveRemote:FireServer(fields)
	end

	-- The handle pair the selected arm's end would have if it were swung `deg`, ready to
	-- post as a `handles` move. nil when there is nothing to swing.
	local function angleHandles(deg: number): { [string]: any }?
		local arm = selectedArm()
		local p1, p2 = _baseP1, _baseP2
		if not arm or not p1 or not p2 then return nil end
		local seg = DataCache.GetSegmentById(arm.segId)
		if not seg then return nil end
		local rad = math.rad(deg)
		-- Swing only the handle at THIS end; the far end keeps its shape, which is what
		-- "the angle the road arrives at" means. Same rotateY the server's move maths uses.
		local n1 = if arm.atStart then RoadMoveGeometry.rotateY(p1, seg.p0, rad) else p1
		local n2 = if arm.atStart then p2 else RoadMoveGeometry.rotateY(p2, seg.p3, rad)
		_reselectDir = arm.dir
		return { id = arm.segId, p1 = n1, p2 = n2 }
	end

	local function commitAngle(deg: number)
		local h = angleHandles(deg)
		if not h then return end
		h.kind = "handles"
		moveRemote:FireServer(h)
	end

	selectArm = function(segId: number)
		_segId = segId
		local seg = DataCache.GetSegmentById(segId)
		_baseP1 = if seg then seg.p1 else nil
		_baseP2 = if seg then seg.p2 else nil
		_angle.set(0)
		render()
	end

	-- ------------------------------------------------------------------ drag --

	-- The mouse/touch split this module always did by hand now lives in Core.CursorRay,
	-- which every tool shares.
	local pointerXY = CursorRay.position

	local _dotFilter: { Instance } = { _dots }

	local function dotUnder(input: InputObject?): BasePart?
		local hit = CursorRay.hitIn(_dotFilter, input)
		local part = hit and hit.Instance
		return if part and part:IsA("BasePart") then part else nil
	end

	-- Where the cursor sits on the horizontal plane through the node. Solved directly
	-- rather than raycast: the dot rides that plane, and a raycast would hand back a roof
	-- or a passing car the moment one crossed under the cursor mid-drag.
	local function pointerOnNodePlane(planeY: number, input: InputObject?): Vector3?
		local ray = CursorRay.ray(input)
		if not ray then return nil end
		if math.abs(ray.Direction.Y) < 1e-4 then return nil end
		local t = (planeY - ray.Origin.Y) / ray.Direction.Y
		if t <= 0 then return nil end
		return ray.Origin + ray.Direction * t
	end

	local function endDrag()
		_dragArm, _dragDir, _dragCenter = nil, nil, nil
		_dragBase, _dragOffset, _dragAngle = 0, 0, 0
		_dragMoved = false
		_pressPart, _pressStart = nil, nil
	end

	-- Split the cursor's offset from the node into the two things an arm mouth can be: how
	-- far out along its own road it sits (the setback), and how far round the node the road
	-- has been swung (the angle).
	local function updateDrag(input: InputObject?)
		local arm, dir, center = _dragArm, _dragDir, _dragCenter
		if not arm or not dir or not center then return end
		local hit = pointerOnNodePlane(center.Y, input)
		if not hit then return end
		local v = Vector3.new(hit.X - center.X, 0, hit.Z - center.Z)
		if v.Magnitude < 1e-3 then return end
		-- Distance from the node, not the projection onto the arm's old heading: the dot has
		-- to sit under the cursor, and a projection would leave it trailing behind on a swing.
		_dragOffset = math.clamp(v.Magnitude - _dragBase, OFFSET_MIN, OFFSET_MAX)
		-- Signed swing in rotateY's own convention, so the preview and the commit agree.
		local deg = math.deg(math.atan2(dir.X * v.Z - dir.Z * v.X, dir.X * v.X + dir.Z * v.Z))
		if math.abs(deg) < ANGLE_DEADZONE then deg = 0 end
		_dragAngle = math.clamp(deg, -ANGLE_MAX, ANGLE_MAX)
		_offset.set(_dragOffset)
		_angle.set(_dragAngle)
		render()
	end

	local function commitDrag()
		local arm = _dragArm
		local off, ang = _dragOffset, _dragAngle
		endDrag()
		if not arm then return end
		local movedSetback = math.abs(off - (arm.offset or 0)) > 1e-3
		local movedAngle = math.abs(ang) > 1e-3
		-- ONE request for the whole gesture. The move remote is rate-limited per player, so
		-- firing the setback and the swing separately would land the second inside the
		-- cooldown and drop it silently; the junction request carries both, and the server
		-- applies the setback first so the swing's rebuild inherits it.
		if movedSetback then
			sendJunction({
				seg = arm.segId,
				offset = off,
				handles = if movedAngle then angleHandles(ang) else nil,
			})
		elseif movedAngle then
			commitAngle(ang)
		end
	end

	local function beginPress(part: BasePart, input: InputObject?)
		_pressPart = part
		_pressStart = pointerXY(input)
		_dragMoved = false
		_pressWasPicked = false
		if part.Name ~= "ArmDot" then return end
		local id = part:GetAttribute("SegId")
		local arms = armsOf(_nodeId)
		local center = if _nodeId then DataCache.GetNodeById(_nodeId) else nil
		if typeof(id) ~= "number" or not arms or not center then return end
		_pressWasPicked = _segId == id
		-- Select on PRESS, not on release: the angle commit is measured against the handles
		-- as they stood when the arm was picked, so a drag needs them recorded before it
		-- moves anything.
		if not _pressWasPicked then selectArm(id) end
		for _, arm in arms do
			if arm.segId == id then
				_dragArm, _dragDir, _dragCenter = arm, arm.dir, center
				_dragBase = baseMouth(arm)
				_dragOffset = arm.offset or 0
				_dragAngle = 0
				break
			end
		end
	end

	local function buildGui()
		_gui = Instance.new("ScreenGui")
		_gui.Name = "NodeTool"
		_gui.ResetOnSpawn = false
		_gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		-- Was left at the default 0, tied with three other guis; ties draw in undefined order.
		_gui.DisplayOrder = UITheme.Layer.Tool + 2
		_gui.Parent = playerGui
		HudScale.attach(_gui)

		-- Pill under the LANES pill: deliberately the same anatomy (icon, caption, keycap),
		-- the same footprint and margin, and the same Theme tokens, so the two tool pills
		-- read as one stack rather than two designs. Not a Kit capsule -- Kit's side padding
		-- insets where scale 1 lands for children, which fights the icon and keycap.
		_pill = Instance.new("TextButton")
		_pill.Name = "NodeToolButton"
		_pill.AutoButtonColor = false
		_pill.AnchorPoint = Vector2.new(1, 0)
		_pill.Position = UDim2.new(1, -10, 0, 84)
		_pill.Size = UDim2.fromOffset(110, 30)
		_pill.BackgroundColor3 = UITheme.Color.BgRaised
		_pill.BorderSizePixel = 0
		_pill.Text = ""
		_pill.Parent = _gui
		corner(_pill, 15)
		_pillEdge = Instance.new("UIStroke")
		_pillEdge.Color = UITheme.Color.StrokeSoft
		_pillEdge.Thickness = UITheme.StrokeWidth.Thin
		_pillEdge.Parent = _pill

		_pillIcon = Instance.new("ImageLabel")
		_pillIcon.Name = "Icon"
		_pillIcon.BackgroundTransparency = 1
		_pillIcon.AnchorPoint = Vector2.new(0, 0.5)
		_pillIcon.Position = UDim2.new(0, 10, 0.5, 0)
		_pillIcon.Size = UDim2.fromOffset(16, 16)
		_pillIcon.ScaleType = Enum.ScaleType.Fit
		_pillIcon.Image = Icons.Snap.image
		_pillIcon.ImageColor3 = UITheme.Color.TextSecondary
		_pillIcon.Parent = _pill

		_pillCaption = makeLabel(_pill, "NODES", UITheme.TextSize.XS, UITheme.Color.TextPrimary)
		_pillCaption.Name = "Caption"
		_pillCaption.FontFace = UITheme.Font.Bold
		_pillCaption.AnchorPoint = Vector2.new(0.5, 0.5)
		_pillCaption.Position = UDim2.new(0.5, -2, 0.5, 0)
		_pillCaption.Size = UDim2.new(1, -58, 1, 0)
		_pillCaption.TextXAlignment = Enum.TextXAlignment.Center

		local key = Instance.new("Frame")
		key.Name = "Key"
		key.AnchorPoint = Vector2.new(1, 0.5)
		key.Position = UDim2.new(1, -6, 0.5, 0)
		key.Size = UDim2.fromOffset(18, 18)
		key.BackgroundColor3 = UITheme.Color.BgHover
		key.BorderSizePixel = 0
		key.Parent = _pill
		corner(key, 9)
		local keyLabel = makeLabel(key, "N", UITheme.TextSize.XS, COL_MUTED)
		keyLabel.Size = UDim2.fromScale(1, 1)
		keyLabel.FontFace = UITheme.Font.Bold
		keyLabel.TextXAlignment = Enum.TextXAlignment.Center

		_banner = Instance.new("Frame")
		_banner.AnchorPoint = Vector2.new(0.5, 0)
		_banner.Position = UDim2.new(0.5, 0, 0, 14)
		_banner.Size = UDim2.fromOffset(392, 30)
		_banner.Visible = false
		_banner.Parent = _gui
		Glass.apply(_banner, UITheme.Radius.MD)
		local bl = makeLabel(_banner, "", UITheme.TextSize.XS, UITheme.Color.Brand)
		bl.FontFace = UITheme.Font.Header
		bl.RichText = true
		-- #A3A096 is Theme.Color.TextSecondary; RichText needs it as a literal.
		bl.Text = 'NODE TOOL <font color="#A3A096"> · click a junction, then drag an arm dot · N to exit</font>'
		bl.Size = UDim2.fromScale(1, 1)
		bl.TextXAlignment = Enum.TextXAlignment.Center

		-- Same shell as the Move It panel: glass at radius 14, 8/10 padding, 6px stack.
		_panel = Instance.new("Frame")
		_panel.AnchorPoint = Vector2.new(1, 0.5)
		_panel.Position = UDim2.new(1, -16, 0.5, 0)
		_panel.Size = UDim2.new(0, 236, 0, 0)
		_panel.AutomaticSize = Enum.AutomaticSize.Y
		_panel.Visible = false
		_panel.Parent = _gui
		Glass.apply(_panel, 14)
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 8)
		pad.PaddingBottom = UDim.new(0, 10)
		pad.PaddingLeft = UDim.new(0, 10)
		pad.PaddingRight = UDim.new(0, 10)
		pad.Parent = _panel
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = _panel

		-- Masthead: accent chip + tool name, the header every panel in this HUD wears.
		local header = Instance.new("Frame")
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, 30)
		header.LayoutOrder = 0
		header.Parent = _panel

		local chip = Instance.new("Frame")
		chip.Size = UDim2.fromOffset(26, 26)
		chip.Position = UDim2.fromOffset(0, 2)
		chip.BackgroundColor3 = COL_ACCENT
		chip.BorderSizePixel = 0
		chip.Parent = header
		corner(chip, 13)
		local chipIcon = Instance.new("ImageLabel")
		chipIcon.BackgroundTransparency = 1
		chipIcon.AnchorPoint = Vector2.new(0.5, 0.5)
		chipIcon.Position = UDim2.fromScale(0.5, 0.5)
		chipIcon.Size = UDim2.fromScale(0.62, 0.62)
		chipIcon.ScaleType = Enum.ScaleType.Fit
		chipIcon.Image = Icons.Snap.image
		chipIcon.ImageColor3 = UITheme.Color.OnAccent
		chipIcon.Parent = chip

		local headLabel = makeLabel(header, "NODE TOOL", UITheme.TextSize.MD, UITheme.Color.Brand)
		headLabel.FontFace = UITheme.Font.Header
		headLabel.Position = UDim2.fromOffset(34, 0)
		headLabel.Size = UDim2.new(1, -34, 1, 0)

		local rule = Instance.new("Frame")
		rule.BackgroundColor3 = UITheme.Color.StrokeSoft
		rule.BackgroundTransparency = 0.5
		rule.BorderSizePixel = 0
		rule.Size = UDim2.new(1, 0, 0, 1)
		rule.LayoutOrder = 1
		rule.Parent = _panel

		-- Which junction is selected reads as a section heading, not a second masthead.
		_title = makeLabel(_panel, "JUNCTION", UITheme.TextSize.SM, UITheme.Color.Brand)
		_title.FontFace = UITheme.Font.Header
		_title.LayoutOrder = 2

		_radius = numberRow(_panel, {
			label = "INTERSECTION RADIUS",
			order = 3, min = CORNER_MIN, max = CORNER_MAX, step = 1,
			unit = "m", fmt = "%.1f",
			toDisplay = toMeters, fromDisplay = toStuds,
			onCommit = function(v: number)
				sendJunction({ corner = v })
			end,
		})

		-- Node-level like the radius, so it sits above the arm list rather than inside it.
		-- "Sloped", not "follows the roads": two words have to fit a half-width capsule, and
		-- sloped/flat is the pair the Node Controller players know it by. The hint spells it out.
		_flat = toggleRow(_panel, "JUNCTION SURFACE", 4, "Sloped", "Flat", function(on: boolean)
			sendJunction({ flat = on })
		end)

		_armList = Instance.new("Frame")
		_armList.BackgroundTransparency = 1
		_armList.Size = UDim2.new(1, 0, 0, 0)
		_armList.AutomaticSize = Enum.AutomaticSize.Y
		_armList.LayoutOrder = 5
		_armList.Parent = _panel
		local armLayout = Instance.new("UIListLayout")
		armLayout.SortOrder = Enum.SortOrder.LayoutOrder
		armLayout.Padding = UDim.new(0, 4)
		armLayout.Parent = _armList

		_armSection = Instance.new("Frame")
		_armSection.BackgroundTransparency = 1
		_armSection.Size = UDim2.new(1, 0, 0, 0)
		_armSection.AutomaticSize = Enum.AutomaticSize.Y
		_armSection.LayoutOrder = 6
		_armSection.Visible = false
		_armSection.Parent = _panel
		local secLayout = Instance.new("UIListLayout")
		secLayout.SortOrder = Enum.SortOrder.LayoutOrder
		secLayout.Padding = UDim.new(0, 6)
		secLayout.Parent = _armSection

		_offset = numberRow(_armSection, {
			label = "ARM SETBACK (IN / OUT)",
			order = 1, min = OFFSET_MIN, max = OFFSET_MAX, step = 1,
			unit = "m", fmt = "%.1f",
			toDisplay = toMeters, fromDisplay = toStuds,
			onCommit = function(v: number)
				if _segId then sendJunction({ seg = _segId, offset = v }) end
			end,
		})
		-- Always shown as 0: the angle is a one-shot swing against the handles as they stood
		-- when the arm was picked, not a stored property, so after a commit the arm's new
		-- heading IS the zero. Typing 5 twice turns the road 5 degrees, then 5 more.
		_angle = numberRow(_armSection, {
			label = "ARM ANGLE",
			order = 2, min = -ANGLE_MAX, max = ANGLE_MAX, step = 1,
			unit = "deg", fmt = "%.0f",
			onCommit = commitAngle,
		})

		makeButton(_armSection, "Reset this arm", 3, function()
			if _segId then sendJunction({ seg = _segId, reset = true }) end
		end)

		makeButton(_panel, "Reset junction", 7, function()
			sendJunction({ reset = true })
		end)

		_hint = makeLabel(_panel, "", UITheme.TextSize.XS, COL_MUTED)
		_hint.TextWrapped = true
		-- Grows to the copy instead of a fixed box: the two hints are different lengths, and
		-- at theme type in a 216px column the longer one runs to five lines.
		_hint.Size = UDim2.new(1, 0, 0, 0)
		_hint.AutomaticSize = Enum.AutomaticSize.Y
		_hint.LayoutOrder = 8
	end

	refreshPanel = function()
		local nodeId = _nodeId
		local arms = armsOf(nodeId)
		if not _active or not nodeId or not arms then
			_panel.Visible = false
			return
		end
		_panel.Visible = true
		_title.Text = if #arms >= 3 then `INTERSECTION {nodeId}` else `BEND {nodeId}`
		_radius.set(nodeCornerRadius(nodeId))
		_flat.set(nodeIsFlat(nodeId))
		-- A 2-arm node renders as a bend CONNECTOR, not a junction plate, so there is no
		-- surface for flat to level -- don't offer a control that would do nothing.
		_flat.frame.Visible = #arms >= 3

		for i = #arms + 1, #_armButtons do
			_armButtons[i].Instance.Visible = false
		end
		for i, arm in arms do
			local b = _armButtons[i]
			if not b then
				local idx = i
				b = makeButton(_armList, "", i, function()
					local live = armsOf(_nodeId)
					local target = live and live[idx]
					if target then
						if _segId == target.segId then
							dropArm()
						else
							selectArm(target.segId)
						end
					end
				end)
				_armButtons[i] = b
			end
			b.Instance.Visible = true
			local bearing = math.round((math.deg(math.atan2(arm.dir.X, arm.dir.Z)) + 360) % 360)
			-- Kit buttons render caps, so set the text already upper -- otherwise the label
			-- the factory uppercased once and the one written here disagree.
			b.Instance.Text = string.upper(`Arm {i}  ·  {bearing}°`)
			b:SetSelected(_segId == arm.segId)
		end

		local arm = selectedArm()
		_armSection.Visible = arm ~= nil
		if arm then
			-- A drag re-renders every mouse-move and lands here; leave the fields showing the
			-- preview it is writing rather than snapping them back to the committed value.
			if not _dragArm then
				_offset.set(arm.offset or 0)
			end
			_hint.Text = "Drag this arm's dot: out along the road for setback, round the node for angle. An angle change rebuilds the road."
		else
			_hint.Text = "Radius rounds every corner here. Flat levels the junction; sloped lets it ride the roads' grade. Pick an arm for its setback and angle."
		end
	end

	-- --------------------------------------------------------------- toggle --

	local function setActive(on: boolean)
		_active = on
		_banner.Visible = on
		if on then
			-- The lane connector's banner and side panel occupy exactly these coordinates, so
			-- claiming the slot closes it rather than letting the two draw over each other.
			PanelSlots.claim("toolPanel", "NodeTool", function()
				setActive(false)
			end)
		else
			PanelSlots.release("toolPanel", "NodeTool")
			endDrag()
			_nodeId, _segId = nil, nil
			_baseP1, _baseP2, _reselectDir = nil, nil, nil
		end
		-- Active tool = the HUD's accent fill with the lighter accent ring, exactly what a
		-- selected Kit button wears. (It used to go red, which nothing else in the HUD does.)
		_pill.BackgroundColor3 = if on then UITheme.Color.Accent else UITheme.Color.BgRaised
		_pillEdge.Color = if on then UITheme.Color.AccentHover else UITheme.Color.StrokeSoft
		_pillEdge.Thickness = if on then UITheme.StrokeWidth.Thick else UITheme.StrokeWidth.Thin
		_pillCaption.TextColor3 = if on then UITheme.Color.OnAccent else UITheme.Color.TextPrimary
		_pillIcon.ImageColor3 = if on then UITheme.Color.OnAccent else UITheme.Color.TextSecondary
		render()
	end

	buildGui()
	rebuildArms()

	DataCache.On("segments", function()
		rebuildArms()
		-- An angle edit rebuilt its segment under a new id. Re-pick the arm that now
		-- points closest to where the old one did, so the arm's fields stay live.
		local want = _reselectDir
		local arms = armsOf(_nodeId)
		if want and arms then
			local best: Arm? = nil
			local bestDot = -2
			for _, arm in arms do
				local d = arm.dir:Dot(want)
				if d > bestDot then
					bestDot = d
					best = arm
				end
			end
			_reselectDir = nil
			if best then
				selectArm(best.segId)
				return
			end
		end
		if _segId and not selectedArm() then
			_segId = nil
			_baseP1, _baseP2 = nil, nil
		end
		if _nodeId and not armsOf(_nodeId) then
			_nodeId, _segId = nil, nil
		end
		render()
	end)

	DataCache.On("nodes", function()
		rebuildArms()
		if _nodeId and not armsOf(_nodeId) then
			_nodeId, _segId = nil, nil
		end
		render()
	end)

	_pill.Activated:Connect(function()
		setActive(not _active)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if Settings.pressed("NodeTool", input) then
			setActive(not _active)
			return
		end
		if not _active then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
		-- Only a press that actually lands on one of this tool's dots is taken; every other
		-- click falls through untouched, the way the ClickDetectors used to leave them.
		local part = dotUnder(input)
		if part then beginPress(part, input) end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not _pressPart or not _dragArm then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
		if not _dragMoved then
			local start = _pressStart
			if start and (pointerXY(input) - start).Magnitude < DRAG_SLOP then return end
			_dragMoved = true
		end
		updateDrag(input)
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
		local part = _pressPart
		if not part then return end
		if _dragMoved and _dragArm then
			commitDrag()
			return
		end
		local wasPicked = _pressWasPicked
		endDrag()
		-- A press that never travelled is a click: on a node it picks or drops the junction,
		-- on an arm it drops the one already picked (a new one was picked on the press).
		if part.Name == "NodeDot" then
			onNodeClick(part)
		elseif wasPicked then
			dropArm()
		end
	end)

	-- Session singleton, like LaneConnectorView: no respawn teardown, because nothing
	-- ever calls Start() a second time to bring it back.
end

return NodeToolView
